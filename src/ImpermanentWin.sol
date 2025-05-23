// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {UniswapV4ERC20} from "./UniswapV4ERC20.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {toBeforeSwapDelta, BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract ImpermanentWin is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error LiquidityDoesntMeetMinimum();
    error SenderMustBeHook();
    error ExpiredPastDeadline();
    error TooMuchSlippage();

    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int256 internal constant MAX_INT = type(int256).max;
    uint16 internal constant MINIMUM_LIQUIDITY = 1000;

    mapping(PoolId => uint256) simulateReserve0;
    mapping(PoolId => uint256) simulateReserve1;

    struct ImpermanentSwapParams {
        int256 amountCalculated;
        uint256 fictiveReserveIn;
        uint256 fictiveReserveOut;
        uint256 priceAverageIn;
        uint256 priceAverageOut;
        address token0;
        address token1;
        uint256 balanceIn;
        uint256 balanceOut;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

    struct ReserveInfo {
        uint128 simulateReserve0;
        uint128 simulateReserve1;
        uint128 priceAvg0;
        uint128 priceAvg1;
        uint40 priceAvgTimestamp;
        uint104 fee0;
        uint104 fee1;
    }

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 liquidity;
        uint256 deadline;
    }

    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => ReserveInfo) public reserveInfo;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint128 liquidity)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        PoolInfo storage pool = poolInfo[poolId];

        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );

        if (poolLiquidity == 0 && liquidity <= MINIMUM_LIQUIDITY) {
            revert LiquidityDoesntMeetMinimum();
        }
        BalanceDelta addedDelta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            })
        );

        if (poolLiquidity == 0) {
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            liquidity -= MINIMUM_LIQUIDITY;
            UniswapV4ERC20(pool.liquidityToken).mint(address(0), MINIMUM_LIQUIDITY);
        }

        UniswapV4ERC20(pool.liquidityToken).mint(params.to, liquidity);

        if (uint128(-addedDelta.amount0()) < params.amount0Min || uint128(-addedDelta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        public
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolInfo[poolId].liquidityToken);

        delta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(params.liquidity.toInt256()),
                salt: 0
            })
        );

        erc20.burn(msg.sender, params.liquidity);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();

        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                "UniV4",
                "-",
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );
        address poolToken = address(new UniswapV4ERC20(tokenSymbol, tokenSymbol));

        poolInfo[poolId] = PoolInfo({hasAccruedFees: false, liquidityToken: poolToken});

        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 unspecifiedAmount;

        // xustom vurve to replace by our code
        BeforeSwapDelta returnDelta;
        if (exactInput) {
            // in exact-input swaps, the specified token is a debt that gets paid down by the swapper
            // the unspecified token is credited to the PoolManager, that is claimed by the swapper
            unspecifiedAmount =
                getAmountOutFromExactInput(specifiedAmount, poolId, specified, unspecified, params.zeroForOne);
            specified.take(poolManager, address(this), specifiedAmount, true);
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);

            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            // exactOutput
            // in exact-output swaps, the unspecified token is a debt that gets paid down by the swapper
            // the specified token is credited to the PoolManager, that is claimed by the swapper
            unspecifiedAmount = getAmountInForExactOutput(specifiedAmount, unspecified, specified, params.zeroForOne);
            unspecified.take(poolManager, address(this), unspecifiedAmount, true);
            specified.settle(poolManager, address(this), specifiedAmount, true);

            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }

        if (!poolInfo[poolId].hasAccruedFees) {
            PoolInfo storage pool = poolInfo[poolId];
            pool.hasAccruedFees = true;
        }

        return (IHooks.beforeSwap.selector, returnDelta, 0);
    }

    function getAmountOutFromExactInput(uint256 amountIn, PoolId id, Currency, Currency, bool zeroForOne)
        internal
        pure
        returns (uint256 amountOut)
    {
        ReserveInfo memory info = ReserveInfo[id];

        (uint160 sqrtPriceX96,,,) = poolManager.getR(poolId);

        ImpermanentSwapParams memory _params = ImpermanentSwapParams({
            amountCalculated: 0,
            fictiveReserveIn: 0,
            fictiveReserveOut: 0,
            priceAverageIn: 0,
            priceAverageOut: 0,
            token0: token0,
            token1: token1,
            balanceIn: 0,
            balanceOut: 0
        });

        if (zeroForOne) {
            (
                _params.balanceIn,
                _params.balanceOut,
                _params.fictiveReserveIn,
                _params.fictiveReserveOut,
                _params.priceAverageIn,
                _params.priceAverageOut
            ) = (
                IERC20(_params.token0).balanceOf(address(this)) - feeToAmount0,
                IERC20(_params.token1).balanceOf(address(this)) - feeToAmount1,
                info.simulateReserve0,
                info.simulateReserve1,
                info.priceAvg0,
                info.priceAvg1
            );
        } else {
            (
                _params.balanceIn,
                _params.balanceOut,
                _params.fictiveReserveIn,
                _params.fictiveReserveOut,
                _params.priceAverageIn,
                _params.priceAverageOut
            ) = (
                IERC20(_params.token1).balanceOf(address(this)) - feeToAmount1,
                IERC20(_params.token0).balanceOf(address(this)) - feeToAmount0,
                info.simulateReserve1,
                info.simulateReserve0,
                info.priceAvg1,
                info.priceAvg0,
            );
        }
    }

    function getAmountInForExactOutput(uint256 amountOut, Currency, Currency, bool)
        internal
        pure
        returns (uint256 amountIn)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountIn = amountOut;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        key.currency0.settle(poolManager, sender, uint256(int256(-delta.amount0())), false);
        key.currency1.settle(poolManager, sender, uint256(int256(-delta.amount1())), false);
    }

    function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        poolManager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
        poolManager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
    }

    function _removeLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];

        if (pool.hasAccruedFees) {
            _rebalance(key);
        }

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            poolManager.getLiquidity(poolId),
            UniswapV4ERC20(pool.liquidityToken).totalSupply()
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
        pool.hasAccruedFees = false;
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            (delta,) = poolManager.modifyLiquidity(data.key, data.params, ZERO_BYTES);
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _rebalance(PoolKey memory key) public {
        PoolId poolId = key.toId();
        (BalanceDelta balanceDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        uint160 newSqrtPriceX96 = (
            FixedPointMathLib.sqrt(
                FullMath.mulDiv(uint128(balanceDelta.amount1()), FixedPoint96.Q96, uint128(balanceDelta.amount0()))
            ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
        ).toUint160();

        (uint160 sqrtPriceX96,,,) = poolManager.getSyncedReserves();

        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: -MAX_INT - 1, // equivalent of type(int256).min
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            uint256(uint128(balanceDelta.amount0())),
            uint256(uint128(balanceDelta.amount1()))
        );

        (BalanceDelta balanceDeltaAfter,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            }),
            ZERO_BYTES
        );

        // Donate any "dust" from the sqrtRatio change as fees
        uint128 donateAmount0 = uint128(balanceDelta.amount0() + balanceDeltaAfter.amount0());
        uint128 donateAmount1 = uint128(balanceDelta.amount1() + balanceDeltaAfter.amount1());

        poolManager.donate(key, donateAmount0, donateAmount1, ZERO_BYTES);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ImpermanentWin} from "../src/ImpermanentWin.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {UniswapV4ERC20} from "../src/UniswapV4ERC20.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

contract ImpermanentWinTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ImpermanentWin hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    MockERC20 token0;
    MockERC20 token1;

    uint16 constant LOCKED_LIQUIDITY = 1000;
    uint256 constant MAX_DEADLINE = 12329839823;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG)
                ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("ImpermanentWin.sol:ImpermanentWin", constructorArgs, flags);
        hook = ImpermanentWin(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        token0.approve(address(hook), Constants.MAX_UINT256);
        token1.approve(address(hook), Constants.MAX_UINT256);

        hook.addLiquidity(
            ImpermanentWin.AddLiquidityParams(
                key.currency0,
                key.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                address(this),
                MAX_DEADLINE
            )
        );
    }

    function testFullRange_addLiquidity_SubsequentAdd() public {
        uint256 prevBalance0 = key.currency0.balanceOfSelf();
        uint256 prevBalance1 = key.currency1.balanceOfSelf();

        (, address liquidityToken) = hook.poolInfo(poolId);
        uint256 prevLiquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        ImpermanentWin.AddLiquidityParams memory addLiquidityParams = ImpermanentWin.AddLiquidityParams(
            key.currency0, key.currency1, 3000, 10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE
        );

        hook.addLiquidity(addLiquidityParams);

        (bool hasAccruedFees,) = hook.poolInfo(poolId);
        uint256 liquidityTokenBal = UniswapV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(manager.getLiquidity(poolId), liquidityTokenBal + LOCKED_LIQUIDITY);

        assertEq(key.currency0.balanceOfSelf(), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOfSelf(), prevBalance1 - 10 ether);

        assertEq(liquidityTokenBal, prevLiquidityTokenBal + 10 ether);
        assertEq(hasAccruedFees, false);
    }
}

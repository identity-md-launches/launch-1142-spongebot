// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {SPONGEBOT} from "../../src/SPONGEBOT.sol";
import {SpongeBotHook} from "../../src/SpongeBotHook.sol";
import {SpongeBotVault} from "../../src/SpongeBotVault.sol";

/// @notice Shared scaffolding: mines the hook address, opens the launch pool from a "factory", seeds liquidity
/// and wraps the v4 test routers. Subclasses provide the PoolManager and fund IMD.
abstract contract HookTestBase is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    address internal constant FACTORY = address(0xFAC7);
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 internal constant IMD_ID = uint256(uint160(IMD));

    IPoolManager internal manager;
    SPONGEBOT internal token;
    SpongeBotHook internal hook;
    SpongeBotVault internal vault;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    PoolId internal poolId;
    bool internal imdIsCurrency0;

    /// @dev Provides the PoolManager (fresh or forked).
    function _poolManager() internal virtual returns (IPoolManager);
    /// @dev Gives `to` `amount` of IMD.
    function _fundImd(address to, uint256 amount) internal virtual;

    function _setUpPool(bool seedBothSides) internal {
        manager = _poolManager();
        token = new SPONGEBOT();
        hook = _deployHook();
        vault = hook.vault();
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        imdIsCurrency0 = IMD < address(token);
        (address c0, address c1) = imdIsCurrency0 ? (IMD, address(token)) : (address(token), IMD);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1_1);

        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(IMD).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(IMD).approve(address(swapRouter), type(uint256).max);

        if (seedBothSides) {
            _fundImd(address(this), 2_000_000 ether);
            _addLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 1_000_000 ether);
        } else {
            // Launch-like seeding: tokens only, above the current price.
            int24 lower = imdIsCurrency0 ? int24(-887_220) : int24(60);
            int24 upper = imdIsCurrency0 ? int24(-60) : int24(887_220);
            _addLiquidity(lower, upper, 1_000_000 ether);
            _fundImd(address(this), 2_000_000 ether);
        }
    }

    function _deployHook() internal returns (SpongeBotHook) {
        return _deployHook(0);
    }

    /// @dev Mines a CREATE2 salt from `startSalt` so the address carries exactly FLAGS, then deploys.
    function _deployHook(uint256 startSalt) internal returns (SpongeBotHook) {
        bytes memory creationCode =
            abi.encodePacked(type(SpongeBotHook).creationCode, abi.encode(address(manager), address(token)));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = startSalt; i < startSalt + 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            SpongeBotHook deployed = new SpongeBotHook{salt: bytes32(i)}(manager, address(token));
            assertEq(address(deployed), predicted, "create2 prediction");
            return deployed;
        }
        revert("no salt found");
    }

    function _addLiquidity(int24 lower, int24 upper, int256 liquidity) internal {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), "");
    }

    /// @dev Buys SPONGEBOT with IMD. `amountSpecified` < 0 is exact IMD in; > 0 is exact SPONGEBOT out.
    function _buy(int256 amountSpecified, uint160 priceLimit) internal returns (BalanceDelta) {
        return _swap(imdIsCurrency0, amountSpecified, priceLimit);
    }

    /// @dev Sells SPONGEBOT for IMD. `amountSpecified` < 0 is exact SPONGEBOT in; > 0 is exact IMD out.
    function _sell(int256 amountSpecified, uint160 priceLimit) internal returns (BalanceDelta) {
        return _swap(!imdIsCurrency0, amountSpecified, priceLimit);
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 priceLimit) internal returns (BalanceDelta) {
        return _swap(zeroForOne, amountSpecified, priceLimit, "");
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 priceLimit, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        if (priceLimit == 0) {
            priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        return swapRouter.swap(
            key, SwapParams(zeroForOne, amountSpecified, priceLimit), PoolSwapTest.TestSettings(false, false), hookData
        );
    }

    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolId);
    }

    function _imdBalance(address who) internal view returns (uint256) {
        return IERC20Minimal(IMD).balanceOf(who);
    }

    /// @dev Refund the swap router holds: IMD transferred to it plus IMD ERC-6909 claims minted to it.
    function _routerRefund() internal view returns (uint256) {
        return _imdBalance(address(swapRouter)) + manager.balanceOf(address(swapRouter), IMD_ID);
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int128) {
        return imdIsCurrency0 ? delta.amount0() : delta.amount1();
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int128) {
        return imdIsCurrency0 ? delta.amount1() : delta.amount0();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}

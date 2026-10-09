// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {ClaimRouter} from "./utils/ClaimRouter.sol";

/// @notice Mainnet-fork rehearsal: the real PoolManager and the real IMD token.
/// @dev Runs only when MAINNET_RPC_URL is set in the environment; skips cleanly otherwise (the verifier has no
/// network). Run with: MAINNET_RPC_URL=https://... forge test --match-contract Fork
contract SpongeBotHookForkTest is HookTestBase {
    /// @notice Uniswap v4 PoolManager on Ethereum mainnet.
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function _poolManager() internal pure override returns (IPoolManager) {
        return IPoolManager(MAINNET_POOL_MANAGER);
    }

    function _fundImd(address to, uint256 amount) internal override {
        deal(IMD, to, amount);
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _setUpPool(true);
    }

    function test_fork_poolManagerHasCode() public view {
        assertGt(MAINNET_POOL_MANAGER.code.length, 0);
        assertGt(IMD.code.length, 0);
        assertEq(hook.poolOpenBlock(), block.number);
    }

    function test_fork_buyExactInput() public {
        uint256 rate = hook.feeBps();
        uint256 amountIn = 1_000 ether;
        uint256 imdBefore = _imdBalance(address(this));
        _buy(-int256(amountIn), 0);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = _routerRefund();
        assertEq(imdBefore - _imdBalance(address(this)), amountIn);
        assertEq(fee, (amountIn - fee - refund) * rate / 10_000);
    }

    function test_fork_buyExactOutput() public {
        uint256 rate = hook.feeBps();
        uint256 imdBefore = _imdBalance(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        _buy(int256(100 ether), 0);
        assertEq(token.balanceOf(address(this)) - tokenBefore, 100 ether);
        uint256 paid = imdBefore - _imdBalance(address(this));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertEq(fee, (paid - fee) * rate / 10_000);
    }

    function test_fork_sellExactInput() public {
        uint256 rate = hook.feeBps();
        uint256 imdBefore = _imdBalance(address(this));
        _sell(-1_000 ether, 0);
        uint256 received = _imdBalance(address(this)) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertEq(fee, (received + fee) * rate / 10_000);
    }

    function test_fork_sellExactOutput() public {
        uint256 rate = hook.feeBps();
        uint256 imdBefore = _imdBalance(address(this));
        _sell(int256(100 ether), 0);
        uint256 received = _imdBalance(address(this)) - imdBefore;
        assertEq(received, 100 ether);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = _routerRefund();
        assertEq(fee, (received + fee + refund) * rate / 10_000);
    }

    function test_fork_partialFillsWithPriceLimit() public {
        uint256 rate = hook.feeBps();
        uint160 price = _sqrtPrice();
        uint160 buyLimit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        uint256 imdBefore = _imdBalance(address(this));
        _buy(-10_000 ether, buyLimit);
        uint256 paid = imdBefore - _imdBalance(address(this));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = _routerRefund();
        assertEq(fee, (paid - fee - refund) * rate / 10_000);
        assertGt(refund, 0);
    }

    function test_fork_sweepPaysRealImd() public {
        _buy(-1_000 ether, 0);
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        uint256 hackBefore = _imdBalance(hook.HACKATHON_VAULT());
        hook.sweep();
        assertEq(_imdBalance(hook.HACKATHON_VAULT()) - hackBefore, anti);
        assertEq(_imdBalance(address(vault)), staking);
        assertApproxEqAbs(vault.unstreamedRewards(), staking, 1, "all still to stream, minus the rate's floor");
    }

    function test_fork_permissionBitsAcceptedByTheRealManager() public view {
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), POOL_FEE));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(poolId));
    }

    function test_fork_exactOutputSellPartialFill() public {
        vm.roll(hook.poolOpenBlock() + 10);
        uint256 rate = hook.feeBps();
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 1_000 : price - price / 1_000;
        uint256 imdBefore = _imdBalance(address(this));
        _sell(int256(10_000 ether), limit);
        uint256 received = _imdBalance(address(this)) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = _routerRefund();
        assertEq(fee, (received + fee + refund) * rate / 10_000);
        assertGt(refund, 0);
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 0, "the funded manager refunds in real IMD");
    }

    /// @notice A self-routing swapper on the real manager, which holds IMD: the partial-fill refund comes back as
    /// real IMD in the swapper's own balance, no claim is minted and there is nothing to redeem.
    function test_fork_selfRoutingSwapperGetsRefundAsRealImd() public {
        uint256 rate = hook.feeBps();
        ClaimRouter router = new ClaimRouter(manager);
        router.setUseClaims(false);
        IERC20Minimal(IMD).transfer(address(router), 10_000 ether);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        router.swap(key, SwapParams(imdIsCurrency0, -int256(uint256(10_000 ether)), limit));
        uint256 refund = _imdBalance(address(router));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertGt(refund, fee, "most of the reservation came back, as IMD");
        assertEq(manager.balanceOf(address(router), IMD_ID), 0, "no claim on a funded manager");
        assertEq(fee, (10_000 ether - refund - fee) * rate / 10_000, "fee on what filled only");
        uint256 before = _imdBalance(address(this));
        assertEq(router.redeem(Currency.wrap(IMD)), 0, "nothing to redeem");
        assertEq(_imdBalance(address(this)), before);
    }

    function test_fork_stakersGetRealImdAfterSweep() public {
        address alice = makeAddr("alice");
        token.transfer(alice, 100 ether);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.stake(100 ether);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        _sell(-1_000 ether, 0);
        uint256 staking = hook.pendingStaking();
        hook.sweep();
        // The vault streams every distribution over REWARD_DURATION blocks and pays nothing in the sweep block.
        assertEq(vault.earned(alice), 0, "nothing is paid in the sweep block");
        assertApproxEqAbs(vault.unstreamedRewards(), staking, 1);
        vm.roll(vm.getBlockNumber() + vault.REWARD_DURATION());
        vm.prank(alice);
        uint256 paid = vault.claim();
        assertApproxEqAbs(paid, staking, 100);
        assertEq(_imdBalance(alice), paid);
    }
}

/// @notice Mainnet fork of the launch-like case: the real PoolManager holds no IMD for this pool before the first buy.
contract SpongeBotHookForkTokenOnlyTest is HookTestBase {
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function _poolManager() internal pure override returns (IPoolManager) {
        return IPoolManager(MAINNET_POOL_MANAGER);
    }

    function _fundImd(address to, uint256 amount) internal override {
        deal(IMD, to, amount);
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _setUpPool(false);
    }

    function test_fork_firstBuyOnTokenOnlyPoolThenSweep() public {
        uint256 rate = hook.feeBps();
        uint256 amountIn = 100 ether;
        _buy(-int256(amountIn), 0);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        assertEq(fee, (amountIn - fee - refund) * rate / 10_000);
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        uint256 hackBefore = _imdBalance(hook.HACKATHON_VAULT());
        hook.sweep();
        assertEq(_imdBalance(hook.HACKATHON_VAULT()) - hackBefore, anti);
        assertEq(_imdBalance(address(vault)), staking);
    }

    function test_fork_sellIntoEmptySideChargesNothing() public {
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 100 : price - price / 100;
        uint256 imdBefore = _imdBalance(address(this));
        _sell(-100 ether, limit);
        assertEq(_imdBalance(address(this)), imdBefore);
        assertEq(hook.pending(), 0);
    }
}

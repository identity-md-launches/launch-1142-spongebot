// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";

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
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
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
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
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
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
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
        assertEq(vault.queuedRewards(), staking);
    }
}

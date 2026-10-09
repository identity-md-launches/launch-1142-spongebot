// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Test router that pays its input before swapping: `sync`, transfer, `swap`, `settle`. While IMD is
/// the synced currency, a hook that transferred IMD out of the manager would corrupt this router's settle, so the
/// hook must refund with a claim instead. Takes the output and any unused input to the swapper.
contract PreSyncSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct Data {
        address sender;
        PoolKey key;
        SwapParams params;
        uint256 payAmount;
        bytes hookData;
    }

    error NotManager();
    error InputNotCovered();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 payAmount, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(Data(msg.sender, key, params, payAmount, hookData))), (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Data memory d = abi.decode(raw, (Data));
        (Currency input, Currency output) =
            d.params.zeroForOne ? (d.key.currency0, d.key.currency1) : (d.key.currency1, d.key.currency0);

        manager.sync(input);
        IERC20Minimal(Currency.unwrap(input)).transferFrom(d.sender, address(manager), d.payAmount);
        BalanceDelta delta = manager.swap(d.key, d.params, d.hookData);
        manager.settle();

        int256 inDelta = manager.currencyDelta(address(this), input);
        if (inDelta < 0) revert InputNotCovered();
        if (inDelta > 0) manager.take(input, d.sender, uint256(inDelta));
        int256 outDelta = manager.currencyDelta(address(this), output);
        if (outDelta > 0) manager.take(output, d.sender, uint256(outDelta));
        return abi.encode(delta);
    }
}

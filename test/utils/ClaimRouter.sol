// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice A swapper that is its own router. The hook mints its refund claim to the swap's `sender`; here that is
/// this contract, so the claim can be burned to pay the next swap or redeemed to the owner. Models a claim-aware
/// integrator, as opposed to the stateless v4 test router which keeps the claim.
/// @dev Pays from its own balance: the owner transfers input tokens here before swapping. Outputs go to the owner.
contract ClaimRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    address public immutable owner;
    /// @notice When true, claims held here are burned to pay a swap before any token is transferred.
    bool public useClaims = true;

    error NotOwner();
    error NotManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
        owner = msg.sender;
    }

    function setUseClaims(bool value) external {
        if (msg.sender != owner) revert NotOwner();
        useClaims = value;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta delta) {
        if (msg.sender != owner) revert NotOwner();
        bytes memory result = manager.unlock(abi.encode(uint8(0), abi.encode(key, params)));
        delta = abi.decode(result, (BalanceDelta));
    }

    /// @notice Burns every claim this router holds on `currency` and sends the tokens to the owner.
    function redeem(Currency currency) external returns (uint256 amount) {
        if (msg.sender != owner) revert NotOwner();
        bytes memory result = manager.unlock(abi.encode(uint8(1), abi.encode(currency)));
        amount = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (uint8 kind, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (kind == 1) {
            Currency currency = abi.decode(payload, (Currency));
            uint256 claims = manager.balanceOf(address(this), currency.toId());
            if (claims > 0) {
                manager.burn(address(this), currency.toId(), claims);
                manager.take(currency, owner, claims);
            }
            return abi.encode(claims);
        }
        (PoolKey memory key, SwapParams memory params) = abi.decode(payload, (PoolKey, SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        _settleOrTake(key.currency0);
        _settleOrTake(key.currency1);
        return abi.encode(delta);
    }

    /// @dev Pays a negative delta first with claims this router holds, then with tokens from its own balance;
    /// forwards a positive delta to the owner.
    function _settleOrTake(Currency currency) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            uint256 claims = useClaims ? manager.balanceOf(address(this), currency.toId()) : 0;
            uint256 burnAmount = claims < owed ? claims : owed;
            if (burnAmount > 0) manager.burn(address(this), currency.toId(), burnAmount);
            uint256 rest = owed - burnAmount;
            if (rest > 0) {
                manager.sync(currency);
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), rest);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, owner, uint256(delta));
        }
    }
}

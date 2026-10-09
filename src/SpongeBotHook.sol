// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SpongeBotVault} from "./SpongeBotVault.sol";

/// @title SpongeBot launch hook
/// @notice Hook of the SPONGEBOT/IMD launch pool. Two immutable fees, both in IMD (the paired currency), on top
/// of the pool's static LP fee:
///  - Anti-snipe: 30% at the block the pool opens, decaying linearly to 0% over the first 10 blocks. Accrues in
///    the hook; `sweep()` sends it to the SIMD Hackathon vault.
///  - Staking rewards: 1% of every swap. Accrues in the hook; `sweep()` moves it to the staking vault this hook
///    created in its constructor and calls `notifyReward`.
/// @dev Fees are collected through beforeSwap/afterSwap return deltas and held as ERC-6909 claims on the
/// PoolManager until swept. Nothing is swapped, burned or donated inside a swap callback. The fee is always
/// `rate x the IMD amount that actually moved through the pool`:
///  - IMD on the unspecified side (exact-input sell, exact-output buy): taken in afterSwap from the real delta.
///  - IMD on the specified side (exact-input buy, exact-output sell): reserved in beforeSwap from the specified
///    amount, then reconciled in afterSwap against the actual fill; the excess is refunded, so a price-limited
///    partial fill never pays more than the rate on what filled. The refund goes to the address encoded in
///    `hookData` (`abi.encode(address)`), or to the PoolManager's caller (the router) when hookData is empty: as
///    IMD transferred out of the PoolManager when its balance covers it, otherwise as an IMD ERC-6909 claim that
///    `redeemRefund` turns into IMD at any later time.
/// No owner, no setters, no proxies, no delegatecall, no selfdestruct.
contract SpongeBotHook is IUnlockCallback {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using CurrencyLibrary for Currency;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice The paired currency: IMD on Ethereum mainnet.
    address public constant PAIRED_CURRENCY = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @notice The SIMD Hackathon vault that receives the anti-snipe fee.
    address public constant HACKATHON_VAULT = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;

    uint256 public constant BPS = 10_000;
    /// @notice Anti-snipe fee at the opening block, in basis points of the IMD amount through the pool.
    uint256 public constant ANTI_SNIPE_START_BPS = 3_000;
    /// @notice Number of blocks over which the anti-snipe fee decays to zero.
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    /// @notice Staking reward fee on every swap, in basis points of the IMD amount through the pool.
    uint256 public constant STAKING_BPS = 100;

    // Transient slots (EIP-1153). Valid only within one transaction.
    // keccak256("SpongeBotHook.reservedFee")
    bytes32 internal constant RESERVED_FEE_SLOT = 0x28a3eb227cd5e3d321cddcf9ef2de698aa60d295fbd9bbcd7d28a7b3f15cd286;
    // keccak256("SpongeBotHook.sweeping"): the unlock this hook is running (0 none, UNLOCK_SWEEP, UNLOCK_REDEEM).
    bytes32 internal constant SWEEPING_SLOT = 0x816ae5434e0ef23ea59e1986d3a780ad61c76d05bb37a8b13b609af0dceb2f1a;
    uint256 internal constant UNLOCK_SWEEP = 1;
    uint256 internal constant UNLOCK_REDEEM = 2;
    // The PoolManager's transient slot holding the currency it last synced (CurrencyReserves.CURRENCY_SLOT).
    bytes32 internal constant MANAGER_SYNCED_CURRENCY_SLOT =
        0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;

    // ---------------------------------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    /// @notice The launch token.
    address public immutable token;
    /// @notice The staking vault created by this hook's constructor.
    SpongeBotVault public immutable vault;
    /// @dev True when IMD sorts before the launch token, i.e. IMD is currency0 of the pool.
    bool internal immutable pairedIsCurrency0;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Block at which the launch pool was initialized (0 until then).
    uint256 public poolOpenBlock;
    /// @notice Id of the launch pool. Only one pool may ever use this hook.
    PoolId public poolId;
    /// @notice Anti-snipe fee accrued and not yet swept to the hackathon vault.
    uint256 public pendingAntiSnipe;
    /// @notice Staking fee accrued and not yet swept to the staking vault.
    uint256 public pendingStaking;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, uint256 openBlock);
    event FeeAccrued(uint256 antiSnipe, uint256 staking, uint256 refunded);
    event Refunded(address indexed to, uint256 amount, bool asClaim);
    event Swept(uint256 antiSnipe, uint256 staking);
    event RefundRedeemed(address indexed holder, uint256 amount);

    error NotPoolManager();
    error AlreadyInitialized();
    error WrongPool();
    error DynamicFeeNotAllowed();
    error UnrepresentableFee();
    error NothingToSweep();
    error NotSweeping();
    error ZeroAddress();
    error ZeroAmount();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The Uniswap v4 PoolManager of the launch chain.
    /// @param token_ The launch token (SPONGEBOT), deployed just before the hook by the launch factory.
    constructor(IPoolManager poolManager_, address token_) {
        if (address(poolManager_) == address(0) || token_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        token = token_;
        pairedIsCurrency0 = PAIRED_CURRENCY < token_;
        vault = new SpongeBotVault(token_, PAIRED_CURRENCY, address(this));
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Total IMD fee accrued in the hook and not yet swept.
    function pending() external view returns (uint256) {
        return pendingAntiSnipe + pendingStaking;
    }

    /// @notice Current anti-snipe fee in basis points. 3000 at the opening block, 0 from the 10th block on.
    function antiSnipeBps() public view returns (uint256) {
        uint256 openBlock = poolOpenBlock;
        if (openBlock == 0) return ANTI_SNIPE_START_BPS;
        uint256 elapsed = block.number - openBlock;
        if (elapsed >= ANTI_SNIPE_BLOCKS) return 0;
        return ANTI_SNIPE_START_BPS * (ANTI_SNIPE_BLOCKS - elapsed) / ANTI_SNIPE_BLOCKS;
    }

    /// @notice Total hook fee in basis points right now (anti-snipe + staking).
    function feeBps() public view returns (uint256) {
        return antiSnipeBps() + STAKING_BPS;
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @notice Accepts exactly one pool: the launch token paired with IMD, at a static LP fee.
    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (poolOpenBlock != 0) revert AlreadyInitialized();
        (address expected0, address expected1) = pairedIsCurrency0 ? (PAIRED_CURRENCY, token) : (token, PAIRED_CURRENCY);
        if (Currency.unwrap(key.currency0) != expected0 || Currency.unwrap(key.currency1) != expected1) {
            revert WrongPool();
        }
        if (LPFeeLibrary.isDynamicFee(key.fee)) revert DynamicFeeNotAllowed();
        poolOpenBlock = block.number;
        PoolId id = key.toId();
        poolId = id;
        emit PoolOpened(id, block.number);
        return this.beforeInitialize.selector;
    }

    /// @notice Reserves the fee on the specified side when IMD is the specified currency; otherwise no-op.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_pairedIsSpecified(params)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 rate = feeBps();
        uint256 reserved;
        if (params.amountSpecified < 0) {
            // Exact input of IMD: take the fee out of the input so that fee == rate x (what the pool receives).
            if (params.amountSpecified == type(int256).min) revert UnrepresentableFee();
            uint256 amountIn = uint256(-params.amountSpecified);
            reserved = _ceilMulDiv(amountIn, rate, BPS + rate);
        } else {
            // Exact output of IMD: ask the pool for more so that fee == rate x (what the pool delivers).
            uint256 amountOut = uint256(params.amountSpecified);
            reserved = _ceilMulDiv(amountOut, rate, BPS - rate);
            if (reserved > uint256(type(int256).max - params.amountSpecified)) revert UnrepresentableFee();
        }
        if (reserved > uint256(uint128(type(int128).max))) revert UnrepresentableFee();
        _tstore(RESERVED_FEE_SLOT, reserved);
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(reserved)), 0), 0);
    }

    /// @notice Settles the fee against what actually filled.
    /// @dev `hookData` may carry `abi.encode(address)`: the address any specified-side refund is sent to. Without
    /// it the refund goes to `sender`, the PoolManager's caller.
    function afterSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        int128 pairedDelta = pairedIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 pairedAmount = pairedDelta < 0 ? uint256(uint128(-pairedDelta)) : uint256(uint128(pairedDelta));
        uint256 rate = feeBps();
        uint256 fee = pairedAmount * rate / BPS;
        uint256 refund;
        int128 hookDeltaUnspecified;

        if (_pairedIsSpecified(params)) {
            uint256 reserved = _tload(RESERVED_FEE_SLOT);
            _tstore(RESERVED_FEE_SLOT, 0);
            if (fee > reserved) fee = reserved;
            refund = reserved - fee;
            if (refund > 0) _refund(_refundRecipient(sender, hookData), refund);
        } else {
            hookDeltaUnspecified = int128(uint128(fee));
        }

        if (fee > 0) {
            poolManager.mint(address(this), _pairedId(), fee);
            uint256 staking = pairedAmount * STAKING_BPS / BPS;
            if (staking > fee) staking = fee;
            uint256 antiSnipe = fee - staking;
            pendingStaking += staking;
            pendingAntiSnipe += antiSnipe;
            emit FeeAccrued(antiSnipe, staking, refund);
        }
        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    // ---------------------------------------------------------------------------------------------
    // Sweep
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves every accrued fee out of the PoolManager: anti-snipe to the hackathon vault, staking
    /// rewards to the staking vault (followed by `notifyReward`). Anyone may call it, in its own transaction.
    function sweep() external {
        uint256 antiSnipe = pendingAntiSnipe;
        uint256 staking = pendingStaking;
        if (antiSnipe + staking == 0) revert NothingToSweep();
        pendingAntiSnipe = 0;
        pendingStaking = 0;
        _tstore(SWEEPING_SLOT, UNLOCK_SWEEP);
        poolManager.unlock(abi.encode(antiSnipe, staking, address(0)));
        _tstore(SWEEPING_SLOT, 0);
        emit Swept(antiSnipe, staking);
    }

    /// @notice Turns `amount` of the caller's IMD ERC-6909 claims (a refund minted while the PoolManager could not
    /// cover it in IMD) into IMD sent to the caller. The caller must first allow this hook to burn its claims:
    /// `poolManager.setOperator(hook, true)` or `poolManager.approve(hook, IMD id, amount)`.
    function redeemRefund(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _tstore(SWEEPING_SLOT, UNLOCK_REDEEM);
        poolManager.unlock(abi.encode(amount, uint256(0), msg.sender));
        _tstore(SWEEPING_SLOT, 0);
        emit RefundRedeemed(msg.sender, amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 action = _tload(SWEEPING_SLOT);
        Currency paired = Currency.wrap(PAIRED_CURRENCY);
        if (action == UNLOCK_SWEEP) {
            (uint256 antiSnipe, uint256 staking,) = abi.decode(data, (uint256, uint256, address));
            poolManager.burn(address(this), _pairedId(), antiSnipe + staking);
            if (antiSnipe > 0) poolManager.take(paired, HACKATHON_VAULT, antiSnipe);
            if (staking > 0) {
                poolManager.take(paired, address(vault), staking);
                vault.notifyReward(staking);
            }
        } else if (action == UNLOCK_REDEEM) {
            (uint256 amount,, address holder) = abi.decode(data, (uint256, uint256, address));
            poolManager.burn(holder, _pairedId(), amount);
            poolManager.take(paired, holder, amount);
        } else {
            revert NotSweeping();
        }
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev The specified currency is the input on exact-input swaps and the output on exact-output swaps.
    function _pairedIsSpecified(SwapParams calldata params) internal view returns (bool) {
        bool specifiedIsCurrency0 = params.zeroForOne == (params.amountSpecified < 0);
        return specifiedIsCurrency0 == pairedIsCurrency0;
    }

    function _pairedId() internal pure returns (uint256) {
        return uint256(uint160(PAIRED_CURRENCY));
    }

    /// @dev The address a refund goes to: `abi.encode(address)` in hookData, else the PoolManager's caller.
    function _refundRecipient(address sender, bytes calldata hookData) internal pure returns (address to) {
        if (hookData.length == 32) {
            // Low 160 bits of the word; never reverts on malformed data (a swap must not fail over hookData).
            to = address(uint160(uint256(bytes32(hookData))));
            if (to != address(0)) return to;
        }
        return sender;
    }

    /// @dev Pays `amount` of IMD the hook is owed back to `to`: transferred out of the PoolManager when the manager
    /// holds enough IMD and has not synced IMD for a pending settlement (a transfer then would corrupt the
    /// caller's settle), otherwise minted to `to` as an IMD ERC-6909 claim redeemable through `redeemRefund`.
    function _refund(address to, uint256 amount) internal {
        Currency paired = Currency.wrap(PAIRED_CURRENCY);
        bool synced = address(uint160(uint256(poolManager.exttload(MANAGER_SYNCED_CURRENCY_SLOT)))) == PAIRED_CURRENCY;
        if (!synced && paired.balanceOf(address(poolManager)) >= amount) {
            poolManager.take(paired, to, amount);
            emit Refunded(to, amount, false);
        } else {
            poolManager.mint(to, _pairedId(), amount);
            emit Refunded(to, amount, true);
        }
    }

    /// @dev ceil(a * b / d) with an explicit overflow check that reverts with UnrepresentableFee.
    function _ceilMulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (b == 0 || a == 0) return 0;
        // `a * b` must fit together with the `d - 1` the ceiling adds.
        if (a > (type(uint256).max - (d - 1)) / b) revert UnrepresentableFee();
        uint256 product = a * b;
        return (product + d - 1) / d;
    }

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}

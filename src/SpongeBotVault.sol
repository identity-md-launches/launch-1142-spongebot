// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title SpongeBot staking vault
/// @notice Holders stake SPONGEBOT and earn the paired currency (IMD) pro rata to stake and time.
/// @dev Time-weighted reward-per-token accumulator. Each `notifyReward` closes an epoch and distributes the
/// reward in proportion to the stake-blocks (stake x blocks held) every staker accumulated since the previous
/// distribution. A stake that exists for zero blocks around a distribution earns nothing from it, so the moment
/// `sweep()` is called (by anyone) cannot be used to capture rewards with a flash stake.
///
/// Accounting: epoch k has a start block, a reward rate `rate_k` (reward per stake-block, scaled by PRECISION)
/// fixed when it closes, and `cumulative_k` = sum of `rate_j x length_j` over every epoch j < k. A staker with
/// constant stake `s` from block t0 in epoch a to the start of the current epoch earned
/// `s x (cumulative_current - (cumulative_a + rate_a x (t0 - start_a)))`, plus `points x rate_a` for stake-blocks
/// it accumulated inside epoch a before t0. Everything is settled lazily on the staker's next action, in O(1).
///
/// Rewards are pushed by the hook through `notifyReward` after the hook has transferred them here. There is no
/// owner and no admin: nobody but a staker can move that staker's tokens. Rewards notified while no stake-blocks
/// have accrued (nothing staked, or everything staked in this very block) are queued and folded into the next
/// distribution that has stake-blocks.
contract SpongeBotVault {
    uint256 internal constant PRECISION = 1e18;

    struct Epoch {
        /// @dev Block at which the epoch began (the block of the previous distribution, or deployment).
        uint256 startBlock;
        /// @dev Sum of `rate x length` over every earlier epoch: the accumulator at this epoch's start.
        uint256 cumulativeRate;
        /// @dev Reward per stake-block in this epoch, scaled by PRECISION. Zero while the epoch is open.
        uint256 rate;
    }

    struct Account {
        /// @dev Epoch of the last update.
        uint256 epoch;
        /// @dev Block of the last update.
        uint256 lastBlock;
        /// @dev Stake-blocks accrued inside `epoch` up to `lastBlock`.
        uint256 points;
        /// @dev Rewards settled and not yet claimed.
        uint256 rewards;
    }

    /// @notice The token holders stake (the launch token).
    IERC20Minimal public immutable stakingToken;
    /// @notice The token rewards are paid in (the paired currency).
    IERC20Minimal public immutable rewardToken;
    /// @notice The only address allowed to notify rewards: the launch hook that created this vault.
    address public immutable hook;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedBalance;

    /// @notice Index of the open epoch. Every `notifyReward` that distributes something closes it.
    uint256 public currentEpoch;
    /// @notice Epoch data by index; `epochs(currentEpoch)` is the open one (rate 0).
    mapping(uint256 => Epoch) public epochs;
    /// @notice Stake-blocks accrued by everyone in the open epoch up to `lastUpdateBlock`.
    uint256 public totalPoints;
    /// @notice Block up to which `totalPoints` is accrued.
    uint256 public lastUpdateBlock;
    mapping(address => Account) internal accounts;
    /// @notice Rewards received while no stake-blocks had accrued, kept for the next distribution.
    uint256 public queuedRewards;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardAdded(uint256 amount, uint256 distributed, uint256 queued);

    error NotHook();
    error ZeroAmount();
    error InsufficientStake();
    error TransferFailed();

    constructor(address stakingToken_, address rewardToken_, address hook_) {
        stakingToken = IERC20Minimal(stakingToken_);
        rewardToken = IERC20Minimal(rewardToken_);
        hook = hook_;
        epochs[0].startBlock = block.number;
        lastUpdateBlock = block.number;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Rewards `account` can claim right now: everything from closed epochs. The open epoch's share is
    /// known only when it closes.
    function earned(address account) public view returns (uint256) {
        Account storage a = accounts[account];
        return a.rewards + _closedEpochRewards(a, stakedBalance[account]);
    }

    /// @notice Stake-blocks `account` has accrued in the open epoch so far (its weight in the next distribution).
    function points(address account) external view returns (uint256) {
        Account storage a = accounts[account];
        uint256 staked = stakedBalance[account];
        if (a.epoch < currentEpoch) return staked * (block.number - epochs[currentEpoch].startBlock);
        return a.points + staked * (block.number - a.lastBlock);
    }

    /// @notice Stake-blocks accrued by everyone in the open epoch so far.
    function currentTotalPoints() public view returns (uint256) {
        return totalPoints + totalStaked * (block.number - lastUpdateBlock);
    }

    // ---------------------------------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------------------------------

    /// @notice Stake `amount` of the launch token. Requires prior approval.
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);
        totalStaked += amount;
        stakedBalance[msg.sender] += amount;
        emit Staked(msg.sender, amount);
        _safeTransferFrom(stakingToken, msg.sender, address(this), amount);
    }

    /// @notice Unstake `amount` of the launch token. Earned rewards stay claimable.
    function unstake(uint256 amount) public {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakedBalance[msg.sender];
        if (staked < amount) revert InsufficientStake();
        _updateReward(msg.sender);
        unchecked {
            stakedBalance[msg.sender] = staked - amount;
            totalStaked -= amount;
        }
        emit Unstaked(msg.sender, amount);
        _safeTransfer(stakingToken, msg.sender, amount);
    }

    /// @notice Claim all earned rewards.
    function claim() public returns (uint256 amount) {
        _updateReward(msg.sender);
        Account storage a = accounts[msg.sender];
        amount = a.rewards;
        if (amount > 0) {
            a.rewards = 0;
            emit RewardPaid(msg.sender, amount);
            _safeTransfer(rewardToken, msg.sender, amount);
        }
    }

    /// @notice Unstake everything and claim all rewards.
    function exit() external {
        uint256 staked = stakedBalance[msg.sender];
        if (staked > 0) unstake(staked);
        claim();
    }

    // ---------------------------------------------------------------------------------------------
    // Rewards (hook only)
    // ---------------------------------------------------------------------------------------------

    /// @notice Account for `amount` of reward token the hook has just transferred to this vault.
    /// @dev Closes the open epoch: the amount (plus anything queued) is split over the stake-blocks accrued since
    /// the previous distribution. If none accrued, the amount is queued for the next distribution that has some.
    /// The part the rate's rounding cannot represent (under `points / PRECISION` wei) is queued as well; what
    /// stays unclaimable is under one wei per distribution plus one wei per staker per settlement.
    function notifyReward(uint256 amount) external {
        if (msg.sender != hook) revert NotHook();
        _updateGlobal();
        uint256 total = amount + queuedRewards;
        uint256 pointsTotal = totalPoints;
        if (pointsTotal == 0) {
            queuedRewards = total;
            emit RewardAdded(amount, 0, total);
            return;
        }
        uint256 rate = total * PRECISION / pointsTotal;
        // The rate floors, so `rate x points / PRECISION` is at most `total`. Book its ceiling as distributed: the
        // exact shares stakers accrue sum to at most that, so what is queued can never also be owed.
        uint256 distributed = (rate * pointsTotal + PRECISION - 1) / PRECISION;
        uint256 queued = total - distributed;
        queuedRewards = queued;

        uint256 closing = currentEpoch;
        Epoch storage e = epochs[closing];
        e.rate = rate;
        epochs[closing + 1] = Epoch({
            startBlock: block.number, cumulativeRate: e.cumulativeRate + rate * (block.number - e.startBlock), rate: 0
        });
        currentEpoch = closing + 1;
        totalPoints = 0;
        emit RewardAdded(amount, distributed, queued);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Rewards `a` is owed from closed epochs and has not settled yet.
    function _closedEpochRewards(Account storage a, uint256 staked) internal view returns (uint256) {
        uint256 current = currentEpoch;
        if (a.epoch >= current || (staked == 0 && a.points == 0)) return 0;
        Epoch storage e = epochs[a.epoch];
        uint256 rateAtLast = e.cumulativeRate + e.rate * (a.lastBlock - e.startBlock);
        return (a.points * e.rate + staked * (epochs[current].cumulativeRate - rateAtLast)) / PRECISION;
    }

    function _updateGlobal() internal {
        totalPoints += totalStaked * (block.number - lastUpdateBlock);
        lastUpdateBlock = block.number;
    }

    function _updateReward(address account) internal {
        _updateGlobal();
        Account storage a = accounts[account];
        uint256 staked = stakedBalance[account];
        uint256 current = currentEpoch;
        if (a.epoch < current) {
            a.rewards += _closedEpochRewards(a, staked);
            a.points = staked * (block.number - epochs[current].startBlock);
            a.epoch = current;
        } else {
            a.points += staked * (block.number - a.lastBlock);
        }
        a.lastBlock = block.number;
    }

    function _safeTransfer(IERC20Minimal token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20Minimal token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

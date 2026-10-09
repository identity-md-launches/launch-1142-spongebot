// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title SpongeBot staking vault
/// @notice Holders stake SPONGEBOT and earn the paired currency (IMD) pro rata to stake and time.
/// @dev Reward-per-token accumulator. Rewards are pushed by the hook through `notifyReward` after the hook has
/// transferred them here. There is no owner and no admin: nobody but a staker can move that staker's tokens.
/// Rewards notified while nothing is staked are queued and folded into the next distribution that has stakers.
contract SpongeBotVault {
    uint256 internal constant PRECISION = 1e18;

    /// @notice The token holders stake (the launch token).
    IERC20Minimal public immutable stakingToken;
    /// @notice The token rewards are paid in (the paired currency).
    IERC20Minimal public immutable rewardToken;
    /// @notice The only address allowed to notify rewards: the launch hook that created this vault.
    address public immutable hook;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedBalance;

    /// @notice Accumulated reward per staked token, scaled by PRECISION.
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    /// @notice Rewards received while nothing was staked, kept for the next distribution with stakers.
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
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Rewards `account` can claim right now.
    function earned(address account) public view returns (uint256) {
        return rewards[account] + stakedBalance[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account])
            / PRECISION;
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
        amount = rewards[msg.sender];
        if (amount > 0) {
            rewards[msg.sender] = 0;
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
    /// @dev If nothing is staked the amount is queued and distributed with the next notification that has stakers.
    function notifyReward(uint256 amount) external {
        if (msg.sender != hook) revert NotHook();
        uint256 total = amount + queuedRewards;
        if (totalStaked == 0) {
            queuedRewards = total;
            emit RewardAdded(amount, 0, total);
            return;
        }
        queuedRewards = 0;
        rewardPerTokenStored += total * PRECISION / totalStaked;
        emit RewardAdded(amount, total, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _updateReward(address account) internal {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
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

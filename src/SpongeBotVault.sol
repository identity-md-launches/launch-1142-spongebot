// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title SpongeBot staking vault
/// @notice Holders stake SPONGEBOT and earn the paired currency (IMD) pro rata to stake and time.
/// @dev Reward-per-token accumulator (the Synthetix StakingRewards pattern) with rewards streamed over a fixed
/// window instead of paid out at once. Each `notifyReward` folds what is still unstreamed of the previous
/// distribution into the new amount and streams the sum evenly over the next `REWARD_DURATION` blocks. A staker
/// earns, for every block it is staked, `its stake / total stake` of that block's streamed reward. Because the
/// time at which the anyone-callable `sweep()` triggers a distribution does not matter (nothing is paid in that
/// block, and the amount reaches stakers one block at a time), a stake that exists for a few blocks around a
/// distribution earns only those blocks' share, however large it is.
///
/// Rewards notified while nothing is staked are not lost: the stream pauses (its end block is pushed back by
/// every block without stake) and resumes when the next staker arrives, with no further call required.
///
/// Rewards are pushed by the hook through `notifyReward` after the hook has transferred them here. There is no
/// owner and no admin: nobody but a staker can move that staker's tokens.
contract SpongeBotVault {
    /// @notice Blocks over which each distribution is streamed (about one day at 12-second blocks).
    uint256 public constant REWARD_DURATION = 7_200;
    uint256 internal constant PRECISION = 1e30;

    /// @notice The token holders stake (the launch token).
    IERC20Minimal public immutable stakingToken;
    /// @notice The token rewards are paid in (the paired currency).
    IERC20Minimal public immutable rewardToken;
    /// @notice The only address allowed to notify rewards: the launch hook that created this vault.
    address public immutable hook;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedBalance;

    /// @notice Reward streamed per block, scaled by 1e30.
    uint256 public rewardRate;
    /// @notice Block at which the current stream ends. Pushed back by every block during which nothing is staked.
    uint256 public streamEnd;
    /// @notice Block up to which `rewardPerTokenStored` is accrued.
    uint256 public lastUpdateBlock;
    /// @notice Cumulative reward per staked wei, scaled by 1e30, up to `lastUpdateBlock`.
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) internal settledRewards;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardAdded(uint256 amount, uint256 streamed, uint256 streamEnd);

    error NotHook();
    error ZeroAmount();
    error InsufficientStake();
    error TransferFailed();

    constructor(address stakingToken_, address rewardToken_, address hook_) {
        stakingToken = IERC20Minimal(stakingToken_);
        rewardToken = IERC20Minimal(rewardToken_);
        hook = hook_;
        lastUpdateBlock = block.number;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Rewards `account` can claim right now.
    function earned(address account) public view returns (uint256) {
        return settledRewards[account] + stakedBalance[account] * (rewardPerToken() - userRewardPerTokenPaid[account])
            / PRECISION;
    }

    /// @notice Cumulative reward per staked wei (scaled by 1e30) as of this block.
    function rewardPerToken() public view returns (uint256) {
        uint256 staked = totalStaked;
        if (staked == 0) return rewardPerTokenStored;
        uint256 applicable = block.number < streamEnd ? block.number : streamEnd;
        if (applicable <= lastUpdateBlock) return rewardPerTokenStored;
        return rewardPerTokenStored + rewardRate * (applicable - lastUpdateBlock) / staked;
    }

    /// @notice Reward received but not yet streamed to stakers: paid out over the remaining stream blocks, which
    /// do not elapse while nothing is staked.
    function unstreamedRewards() public view returns (uint256) {
        return rewardRate * _remainingStreamBlocks() / PRECISION;
    }

    /// @notice Blocks of streaming left in the current distribution (frozen while nothing is staked).
    function remainingStreamBlocks() external view returns (uint256) {
        return _remainingStreamBlocks();
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
        amount = settledRewards[msg.sender];
        if (amount > 0) {
            settledRewards[msg.sender] = 0;
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
    /// @dev Starts a new stream of `amount` plus whatever the previous stream had not yet paid out, over the next
    /// `REWARD_DURATION` blocks. Nothing is paid in this block. The rate floors, so under `REWARD_DURATION / 1e30`
    /// wei per distribution is never streamed; a further `total stake / 1e30` wei per update is rounding dust.
    function notifyReward(uint256 amount) external {
        if (msg.sender != hook) revert NotHook();
        _updateGlobal();
        uint256 leftover = rewardRate * _remainingStreamBlocks();
        uint256 rate = (amount * PRECISION + leftover) / REWARD_DURATION;
        rewardRate = rate;
        uint256 end = block.number + REWARD_DURATION;
        streamEnd = end;
        emit RewardAdded(amount, rate * REWARD_DURATION / PRECISION, end);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Stream blocks left after `lastUpdateBlock`, minus those elapsed since if something is staked.
    function _remainingStreamBlocks() internal view returns (uint256) {
        uint256 end = streamEnd;
        uint256 from = totalStaked == 0 ? lastUpdateBlock : block.number;
        return end > from ? end - from : 0;
    }

    /// @dev Accrues the stream up to this block, or pauses it (pushes its end back) while nothing is staked.
    function _updateGlobal() internal {
        uint256 last = lastUpdateBlock;
        if (block.number == last) return;
        if (totalStaked == 0) {
            uint256 end = streamEnd;
            if (end > last) streamEnd = end + (block.number - last);
        } else {
            rewardPerTokenStored = rewardPerToken();
        }
        lastUpdateBlock = block.number;
    }

    function _updateReward(address account) internal {
        _updateGlobal();
        settledRewards[account] = earned(account);
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

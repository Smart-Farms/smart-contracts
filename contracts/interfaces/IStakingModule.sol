// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/**
 * @title IStakingModule Interface
 * @notice This module handles the logic for users staking tokens (represented internally as shares)
 * to earn rewards. It uses a snapshot mechanism tied to reward deposits and time to calculate
 * reward distribution.
 *
 * Rewards are accrued proportionally based on the user's share of the total staked amount over time.
 * Implements IERC6372 for clock functionality based on snapshot IDs.
 * The calculation involves tracking both "virtual" rewards (based on time and shares) and "actual"
 * rewards (based on deposited reward tokens) to distribute the actual tokens proportionally
 * to the accrued virtual rewards per snapshot period.
 */
interface IStakingModule is IERC6372 {
    /**
     * @notice Represents the staking state of a single user.
     * @param shares The amount of shares the user currently has staked.
     * @param cumulativeSum The global cumulative reward sum at the time of the user's last update.
     * Used to calculate rewards accrued since the last update.
     * @param owedValue Tracks the portion of virtual rewards accrued by the user in previous periods
     * but not yet converted into pending actual rewards. This is decreased as pending
     * rewards are calculated.
     */
    struct UserDistribution {
        uint256 shares;
        uint256 cumulativeSum;
        uint256 owedValue;
    }

    /**
     * @notice General data about the staking module's current state.
     * @param rewardToken The address of the ERC20 token used for distributing rewards.
     * @param totalStake The total amount of the underlying token staked in the module.
     * @param lastUpdateTime The timestamp of the last time the virtual rewards were updated.
     * @param snapshotId The ID of the current, active snapshot. Increments with each reward deposit.
     */
    struct StakingData {
        address rewardToken;
        uint256 totalStake;
        uint256 lastUpdateTime;
        uint256 snapshotId;
    }

    /**
     * @notice Data related to a specific historical snapshot.
     * @param depositTime The timestamp when the snapshot was created (typically coincides with a reward deposit).
     * @param cumulativeSum The global cumulative reward sum at the time this snapshot was taken.
     * @param totalActualRewards The total amount of actual reward tokens deposited up to and including this snapshot.
     * @param totalVirtualRewards The total amount of virtual rewards accrued up to and including this snapshot.
     */
    struct StakingAtData {
        uint256 depositTime;
        uint256 cumulativeSum;
        uint256 totalActualRewards;
        uint256 totalVirtualRewards;
    }

    /**
     * @notice Tracks the reward amounts (actual and virtual) that a user has effectively claimed or accounted for
     * up to their `lastProcessedSnapshot`.
     * @dev This is used to calculate the rewards for subsequent snapshots by determining the *new* rewards
     * (delta between snapshot totals and these claimed amounts) available for distribution in that period.
     * @param actualRewards The total actual rewards accounted for by the user.
     * @param virtualRewards The total virtual rewards accounted for by the user.
     */
    struct UserClaimedRewards {
        uint256 actualRewards;
        uint256 virtualRewards;
    }

    /**
     * @notice Comprehensive staking data for a specific user.
     * @param isDeposited Flag indicating if the user has ever staked (used for initialization logic).
     * @param stakedAmount The amount of shares the user has staked.
     * @param pendingRewards The amount of actual reward tokens calculated but not yet claimed by the user.
     * @param userDistribution The user's detailed distribution state (shares, cumulativeSum, owedValue).
     * @param claimedRewards Tracks the total actual and virtual rewards accounted for by the user up to their last processed snapshot.
     * @param lastProcessedSnapshot The ID of the last snapshot whose rewards have been calculated and included
     * in the user's `pendingRewards` or accounted for in `claimedRewards`.
     */
    struct UserStakingData {
        bool isDeposited;
        uint256 stakedAmount;
        uint256 pendingRewards;
        UserDistribution userDistribution;
        UserClaimedRewards claimedRewards;
        uint48 lastProcessedSnapshot;
    }

    /**
     * @notice Stakes a given amount of the underlying token for the caller.
     * @dev Updates the user's shares and related state. Triggers necessary reward updates.
     * @param amount_ The amount of the underlying token to stake.
     */
    function stake(uint256 amount_) external;

    /**
     * @notice Unstakes a given amount of the underlying token for the caller.
     * @dev Updates the user's shares and related state. Triggers necessary reward updates
     * before reducing shares. Requires the user to have sufficient staked balance.
     * @param amount_ The amount of the underlying token to unstake.
     */
    function unstake(uint256 amount_) external;

    /**
     * @notice Claims all currently pending rewards for the caller.
     * @dev Calculates rewards up to the current time (latest snapshot) and transfers the
     * `rewardToken` amount to the caller. Resets pending rewards to zero.
     */
    function claimRewards() external;

    /**
     * @notice Claims rewards for the caller, processing snapshots up to `snapshotId_`.
     * @dev Calculates rewards by iterating through snapshots from the user's last processed snapshot
     * up to (but not including) `snapshotId_`. Transfers the calculated `rewardToken` amount
     * to the caller and updates the user's `lastProcessedSnapshot` and `pendingRewards` state.
     * This allows for partial or batched reward claims.
     * @param snapshotId_ The ID of the snapshot *after* the last one to process rewards for.
     */
    function claimRewardsUntil(uint48 snapshotId_) external;

    /**
     * @notice Deposits reward tokens into the module to be distributed to stakers.
     * @dev Restricted to an owner. Triggers the creation of a new snapshot,
     * capturing the current state and incrementing `totalActualRewards`. Requires the caller
     * to have approved the module to spend the `rewardToken`.
     * @param amount_ The amount of `rewardToken` to deposit.
     */
    function depositRewards(uint256 amount_) external;

    /**
     * @notice Gets the current staking data for the module.
     * @return StakingData memory A struct containing global staking information.
     */
    function getStakingData() external view returns (StakingData memory);

    /**
     * @notice Gets the historical staking data associated with a specific snapshot.
     * @param snapshotId_ The ID of the snapshot to query.
     * @return StakingAtData memory A struct containing data captured at that snapshot.
     */
    function getStakingAtData(uint256 snapshotId_) external view returns (StakingAtData memory);

    /**
     * @notice Gets the staking data for a specific user account.
     * @param account_ The address of the user to query.
     * @return UserStakingData memory A struct containing the user's detailed staking information.
     */
    function getUserStakingData(address account_) external view returns (UserStakingData memory);

    /**
     * @notice Calculates and returns the currently pending (unclaimed) rewards for a specific user.
     * @dev Performs a read-only calculation by iterating through unprocessed snapshots, similar to
     * `claimRewardsUntil`, but does not change any state or transfer tokens.
     * @param account_ The address of the user to query.
     * @return uint256 The amount of `rewardToken` claimable by the user.
     */
    function getPendingRewards(address account_) external view returns (uint256);
}

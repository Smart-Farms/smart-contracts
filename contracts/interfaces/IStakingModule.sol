// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

interface IStakingModule is IERC6372 {
    struct StakingData {
        address rewardToken;
        uint256 totalStake;
        uint256 lastUpdateTime;
        uint256 snapshotId;
    }

    struct StakingAtData {
        uint256 depositTime;
        uint256 cumulativeSum;
        uint256 totalActualRewards;
        uint256 totalVirtualRewards;
    }

    struct UserClaimedRewards {
        uint256 actualRewards;
        uint256 virtualRewards;
    }

    struct UserStakingData {
        bool isDeposited;
        uint256 stakedAmount;
        uint256 pendingRewards;
        UserClaimedRewards claimedRewards;
        uint48 lastProcessedSnapshot;
    }

    function stake(uint256 amount_) external;

    function unstake(uint256 amount_) external;

    function claimRewards() external;

    function claimRewardsUntil(uint48 snapshotId_) external;

    function depositRewards(uint256 amount_) external;

    function getStakingData() external view returns (StakingData memory);

    function getStakingAtData(uint256 snapshotId_) external view returns (StakingAtData memory);

    function getUserStakingData(address account_) external view returns (UserStakingData memory);

    function getPendingRewards(address account_) external view returns (uint256);
}

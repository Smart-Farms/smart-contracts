// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStakingModule} from "./interfaces/IStakingModule.sol";

abstract contract StakingModule is IStakingModule, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 10 ** 25;

    /// @custom:storage-location erc7201:sfUSD.storage.StakingModule
    struct StakingModuleStorage {
        IERC20 rewardToken;
        uint256 totalStake;
        uint256 lastUpdateTime;
        uint256 totalShares;
        uint256 cumulativeSum;
        uint256 updatedAt;
        mapping(address user => bool isDeposited) isUserDeposited;
        mapping(address user => UserDistribution) userDistributions;
        mapping(address user => uint256 pendingRewards) userPendingRewards;
        mapping(address user => UserClaimedRewards claimedRewards) userClaimedRewards;
        mapping(address user => uint48 lastProcessedSnapshot) userLastProcessedSnapshot;
        uint48 snapshotId;
        mapping(uint48 snapshot => uint256 depositTime) snapshotDepositTime;
        mapping(uint48 snapshot => uint256 cumulativeSum) snapshotCumulativeSum;
        mapping(uint48 snapshot => uint256 totalActualRewards) snapshotTotalActualRewards;
        mapping(uint48 snapshot => uint256 totalVirtualRewards) snapshotTotalVirtualRewards;
    }

    event Checkpointed(uint256 snapshotId);

    event RewardsDeposited(uint256 amount);
    event UserStaked(address indexed account, uint256 amount);
    event UserUnstaked(address indexed account, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);

    error ProvidedZeroAmount();
    error NoRewardsToDistribute();
    error InvalidRewardTokenAddress();
    error InsufficientOwedValue(address account, uint256 balance, uint256 needed);
    error StakingModuleFutureLookup(uint256 snapshotId, uint256 currentsnapshotId);
    error InsufficientSharesAmount(address account, uint256 balance, uint256 needed);
    error InsufficientBalanceToUnstake(address account, uint256 currentStake, uint256 amount);

    // keccak256(abi.encode(uint256(keccak256("sfUSD.storage.StakingModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKING_MODULE_STORAGE_LOCATION =
        0x3fdbb0b6fbdc22aa6cfbfb60ef44b75ee821b09be8a4d5fffd8504bbf3dd9500;

    function _getStakingModuleStorage() internal pure returns (StakingModuleStorage storage $) {
        assembly {
            $.slot := STAKING_MODULE_STORAGE_LOCATION
        }
    }

    constructor() {
        _disableInitializers();
    }

    function __StakingModule_init(address rewardToken_) internal onlyInitializing {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        require(rewardToken_ != address(0), InvalidRewardTokenAddress());

        $.rewardToken = IERC20(rewardToken_);

        _snapshotOnRewardsDeposit(0);
    }

    function stake(uint256 amount_) external {
        require(amount_ > 0, ProvidedZeroAmount());

        _stake(_msgSender(), amount_);
    }

    function unstake(uint256 amount_) external {
        require(amount_ > 0, ProvidedZeroAmount());

        _unstake(_msgSender(), amount_);
    }

    function claimRewards() external {
        claimRewardsUntil(clock());
    }

    function claimRewardsUntil(uint48 snapshotId_) public {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        _updateUserPendingRewards(_msgSender(), snapshotId_);

        uint256 rewards_ = $.userPendingRewards[_msgSender()];
        if (rewards_ == 0) return;

        $.rewardToken.safeTransfer(_msgSender(), rewards_);

        $.userPendingRewards[_msgSender()] = 0;

        emit RewardsClaimed(_msgSender(), rewards_);
    }

    function depositRewards(uint256 amount_) external onlyOwner {
        require(amount_ > 0, ProvidedZeroAmount());

        _snapshotOnRewardsDeposit(amount_);

        StakingModuleStorage storage $ = _getStakingModuleStorage();
        $.rewardToken.safeTransferFrom(_msgSender(), address(this), amount_);

        emit RewardsDeposited(amount_);
    }

    function getUserStake(address account_) public view returns (uint256) {
        return _getStakingModuleStorage().userDistributions[account_].shares;
    }

    function getStakingData() external view returns (StakingData memory) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        return
            StakingData({
                rewardToken: address($.rewardToken),
                totalStake: $.totalStake,
                lastUpdateTime: $.lastUpdateTime,
                snapshotId: $.snapshotId
            });
    }

    function getStakingAtData(uint256 snapshotId_) external view returns (StakingAtData memory) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();
        uint48 currentSnapshot_ = clock();

        if (snapshotId_ > currentSnapshot_) {
            revert StakingModuleFutureLookup(snapshotId_, currentSnapshot_);
        }

        return
            StakingAtData({
                depositTime: $.snapshotDepositTime[currentSnapshot_],
                cumulativeSum: $.snapshotCumulativeSum[currentSnapshot_],
                totalActualRewards: $.snapshotTotalActualRewards[currentSnapshot_],
                totalVirtualRewards: $.snapshotTotalVirtualRewards[currentSnapshot_]
            });
    }

    function getUserStakingData(address account_) external view returns (UserStakingData memory) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        return
            UserStakingData({
                isDeposited: $.isUserDeposited[account_],
                stakedAmount: getUserStake(account_),
                pendingRewards: $.userPendingRewards[account_],
                userDistribution: $.userDistributions[account_],
                claimedRewards: $.userClaimedRewards[account_],
                lastProcessedSnapshot: $.userLastProcessedSnapshot[account_]
            });
    }

    function getPendingRewards(address account_) external view returns (uint256) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        uint48 userLastProcessedSnapshot_ = $.userLastProcessedSnapshot[account_];

        UserDistribution memory userDist_ = $.userDistributions[account_];

        uint256 userPendingRewards_ = $.userPendingRewards[account_];

        uint256 userClaimedRewardsActual_ = $.userClaimedRewards[account_].actualRewards;
        uint256 userClaimedRewardsVirtual_ = $.userClaimedRewards[account_].virtualRewards;

        uint48 currentSnapshot_ = clock();

        for (uint48 snapshot_ = userLastProcessedSnapshot_ + 1; snapshot_ < currentSnapshot_; ++snapshot_) {
            uint256 snapshotCumulativeSum_ = $.snapshotCumulativeSum[snapshot_];
            uint256 snapshotTotalActualRewards_ = $.snapshotTotalActualRewards[snapshot_];
            uint256 snapshotTotalVirtualRewards_ = $.snapshotTotalVirtualRewards[snapshot_];

            uint256 userVirtualRewards_;
            if (snapshot_ == userLastProcessedSnapshot_ + 1 && snapshotCumulativeSum_ > userDist_.cumulativeSum) {
                userVirtualRewards_ =
                    userDist_.owedValue +
                    Math.mulDiv(userDist_.shares, (snapshotCumulativeSum_ - userDist_.cumulativeSum), PRECISION);
            } else {
                userVirtualRewards_ = Math.mulDiv(
                    userDist_.shares,
                    (snapshotCumulativeSum_ - $.snapshotCumulativeSum[snapshot_ - 1]),
                    PRECISION
                );
            }

            if (userVirtualRewards_ == 0) {
                userClaimedRewardsActual_ = snapshotTotalActualRewards_;
                userClaimedRewardsVirtual_ = snapshotTotalVirtualRewards_;

                continue;
            }

            userPendingRewards_ += Math.mulDiv(
                userVirtualRewards_,
                snapshotTotalActualRewards_ - userClaimedRewardsActual_,
                snapshotTotalVirtualRewards_ - userClaimedRewardsVirtual_
            );

            userClaimedRewardsActual_ = snapshotTotalActualRewards_;
            userClaimedRewardsVirtual_ = snapshotTotalVirtualRewards_;
        }

        return userPendingRewards_;
    }

    function clock() public view returns (uint48) {
        return _getStakingModuleStorage().snapshotId;
    }

    function CLOCK_MODE() public view virtual returns (string memory) {
        return "mode=counter";
    }

    function _sfUSDTransfer(address from, address to, uint256 value) internal virtual;

    function _stake(address account_, uint256 amount_) internal {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        if ($.totalShares == 0) $.snapshotDepositTime[clock() - 1] = block.timestamp;
        if (!$.isUserDeposited[account_]) {
            uint48 previousSnapshot_ = clock() - 1;

            uint256 snapshotTotalActualRewards_ = $.snapshotTotalActualRewards[previousSnapshot_];
            uint256 snapshotTotalVirtualRewards_ = $.snapshotTotalVirtualRewards[previousSnapshot_];

            $.userClaimedRewards[account_] = UserClaimedRewards(
                snapshotTotalActualRewards_,
                snapshotTotalVirtualRewards_
            );
            $.userLastProcessedSnapshot[account_] = previousSnapshot_;

            $.isUserDeposited[account_] = true;
        }

        _addShares(account_, amount_);

        $.totalStake += amount_;

        emit UserStaked(account_, amount_);

        _sfUSDTransfer(account_, address(this), amount_);
    }

    function _unstake(address account_, uint256 amount_) internal {
        _removeShares(account_, amount_);

        StakingModuleStorage storage $ = _getStakingModuleStorage();
        $.totalStake -= amount_;

        emit UserUnstaked(account_, amount_);

        _sfUSDTransfer(address(this), account_, amount_);
    }

    function _updateUserPendingRewards(address account_, uint48 untilSnapshot_) private {
        _updateVirtualRewards();

        StakingModuleStorage storage $ = _getStakingModuleStorage();

        uint48 userLastProcessedSnapshot_ = $.userLastProcessedSnapshot[account_];

        UserDistribution memory userDist_ = $.userDistributions[account_];

        _update(account_);

        uint256 userClaimedRewardsActual_ = $.userClaimedRewards[account_].actualRewards;
        uint256 userClaimedRewardsVirtual_ = $.userClaimedRewards[account_].virtualRewards;

        for (uint48 snapshot_ = userLastProcessedSnapshot_ + 1; snapshot_ < untilSnapshot_; ++snapshot_) {
            uint256 snapshotCumulativeSum_ = $.snapshotCumulativeSum[snapshot_];
            uint256 snapshotTotalActualRewards_ = $.snapshotTotalActualRewards[snapshot_];
            uint256 snapshotTotalVirtualRewards_ = $.snapshotTotalVirtualRewards[snapshot_];

            uint256 userVirtualRewards_;
            if (snapshot_ == userLastProcessedSnapshot_ + 1 && snapshotCumulativeSum_ > userDist_.cumulativeSum) {
                userVirtualRewards_ =
                    userDist_.owedValue +
                    Math.mulDiv(userDist_.shares, (snapshotCumulativeSum_ - userDist_.cumulativeSum), PRECISION);
            } else {
                userVirtualRewards_ = Math.mulDiv(
                    userDist_.shares,
                    (snapshotCumulativeSum_ - $.snapshotCumulativeSum[snapshot_ - 1]),
                    PRECISION
                );
            }

            if (userVirtualRewards_ == 0) {
                userClaimedRewardsActual_ = snapshotTotalActualRewards_;
                userClaimedRewardsVirtual_ = snapshotTotalVirtualRewards_;

                continue;
            }

            // SAFE: full reward was distributed before the cycle started
            $.userDistributions[account_].owedValue -= userVirtualRewards_;

            $.userPendingRewards[account_] += Math.mulDiv(
                userVirtualRewards_,
                snapshotTotalActualRewards_ - userClaimedRewardsActual_,
                snapshotTotalVirtualRewards_ - userClaimedRewardsVirtual_
            );

            userClaimedRewardsActual_ = snapshotTotalActualRewards_;
            userClaimedRewardsVirtual_ = snapshotTotalVirtualRewards_;
        }

        $.userLastProcessedSnapshot[account_] = untilSnapshot_ - 1;

        UserClaimedRewards storage userClaimedRewards = $.userClaimedRewards[account_];
        userClaimedRewards.actualRewards = userClaimedRewardsActual_;
        userClaimedRewards.virtualRewards = userClaimedRewardsVirtual_;
    }

    function _snapshotOnRewardsDeposit(uint256 amount_) private returns (uint256) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        _update(address(0));
        _updateVirtualRewards();

        uint48 oldSnapshot_ = $.snapshotId++;

        require($.snapshotTotalVirtualRewards[oldSnapshot_] > 0 || amount_ == 0, NoRewardsToDistribute());

        $.snapshotDepositTime[oldSnapshot_] = block.timestamp;
        $.snapshotCumulativeSum[oldSnapshot_] = $.cumulativeSum;

        if (oldSnapshot_ != 0) {
            $.snapshotTotalActualRewards[oldSnapshot_] = $.snapshotTotalActualRewards[oldSnapshot_ - 1] + amount_;
            $.snapshotTotalVirtualRewards[oldSnapshot_] += $.snapshotTotalVirtualRewards[oldSnapshot_ - 1];
        }

        emit Checkpointed(oldSnapshot_);

        return oldSnapshot_;
    }

    function _updateVirtualRewards() private {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        $.snapshotTotalVirtualRewards[clock()] += _getValueToDistribute(block.timestamp, $.lastUpdateTime);

        $.lastUpdateTime = block.timestamp;
    }

    function _addShares(address user_, uint256 amount_) private {
        _updateUserPendingRewards(user_, clock());

        StakingModuleStorage storage $ = _getStakingModuleStorage();

        $.totalShares += amount_;
        $.userDistributions[user_].shares += amount_;
    }

    function _removeShares(address user_, uint256 amount_) private {
        StakingModuleStorage storage $ = _getStakingModuleStorage();
        UserDistribution storage _userDist = $.userDistributions[user_];

        require(amount_ <= _userDist.shares, InsufficientSharesAmount(user_, _userDist.shares, amount_));

        _updateUserPendingRewards(user_, clock());

        $.totalShares -= amount_;
        _userDist.shares -= amount_;
    }

    function _update(address user_) private {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        $.cumulativeSum = _getFutureCumulativeSum(block.timestamp);
        $.updatedAt = block.timestamp;

        if (user_ != address(0)) {
            UserDistribution storage _userDist = $.userDistributions[user_];

            _userDist.owedValue += Math.mulDiv(
                _userDist.shares,
                ($.cumulativeSum - _userDist.cumulativeSum),
                PRECISION
            );
            _userDist.cumulativeSum = $.cumulativeSum;
        }
    }

    function _getFutureCumulativeSum(uint256 timeUpTo_) private view returns (uint256) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        if ($.totalShares == 0) {
            return $.cumulativeSum;
        }

        uint256 value_ = _getValueToDistribute(timeUpTo_, $.updatedAt);

        return $.cumulativeSum + Math.mulDiv(value_, PRECISION, $.totalShares);
    }

    function _getValueToDistribute(uint256 timeUpTo_, uint256 timeLastUpdate_) private view returns (uint256) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        return Math.mulDiv((timeUpTo_ - timeLastUpdate_), $.totalShares, 1);
    }
}

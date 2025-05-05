// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStakingModule} from "./interfaces/IStakingModule.sol";

/**
 * @title StakingModule
 * @notice Provides the foundation for staking mechanisms where rewards are distributed proportionally
 * based on time and staked shares. Uses ERC7201 storage pattern.
 */
abstract contract StakingModule is IStakingModule, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /**
     * @dev High precision value used for fixed-point arithmetic in cumulative sum calculations.
     *      Chosen as 10**25 to minimize rounding errors over potentially long periods.
     */
    uint256 private constant PRECISION = 10 ** 25;

    /**
     * @notice Stores all state variables for the StakingModule to prevent storage collisions.
     * @custom:storage-location erc7201:sfUSD.storage.StakingModule
     * @param rewardToken The ERC20 token distributed as rewards.
     * @param totalStake Total amount of the underlying staked token (e.g., sfUSD) held by the module.
     * @param lastUpdateTime Timestamp of the last global reward state update.
     * @param totalShares Total shares currently staked by all users.
     * @param cumulativeSum Global accumulator representing cumulative virtual rewards per share over time.
     * @param updatedAt Timestamp when the `cumulativeSum` was last updated.
     * @param isUserDeposited Mapping track if a user has ever staked, for initialization.
     * @param userDistributions Mapping from user address to their distribution state (shares, owedValue, etc.).
     * @param userPendingRewards Mapping from user address to their currently claimable (but unclaimed) reward amount.
     * @param userClaimedRewards Mapping from user address to the total actual/virtual rewards accounted for.
     * @param userLastProcessedSnapshot Mapping from user address to the last snapshot ID processed for their rewards.
     * @param snapshotId The current snapshot ID counter, incremented on reward deposit.
     * @param snapshotDepositTime Mapping snapshot ID to its creation timestamp.
     * @param snapshotCumulativeSum Mapping snapshot ID to the global cumulative sum at that snapshot.
     * @param snapshotTotalActualRewards Mapping snapshot ID to the total actual rewards deposited up to that snapshot.
     * @param snapshotTotalVirtualRewards Mapping snapshot ID to the total virtual rewards accrued up to that snapshot.
     */
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

    /**
     * @notice Emitted when a new snapshot is created; emitted during reward deposit.
     * @param snapshotId The ID of the newly created snapshot.
     */
    event Checkpointed(uint256 snapshotId);

    /**
     * @notice Emitted when reward tokens are deposited into the module.
     * @param amount The amount of reward tokens deposited.
     */
    event RewardsDeposited(uint256 amount);

    /**
     * @notice Emitted when a user stakes tokens.
     * @param account The address of the user staking.
     * @param amount The amount of underlying tokens staked.
     */
    event UserStaked(address indexed account, uint256 amount);

    /**
     * @notice Emitted when a user unstakes tokens.
     * @param account The address of the user unstaking.
     * @param amount The amount of underlying tokens unstaked.
     */
    event UserUnstaked(address indexed account, uint256 amount);

    /**
     * @notice Emitted when a user claims their pending rewards.
     * @param account The address of the user claiming rewards.
     * @param amount The amount of reward tokens claimed.
     */
    event RewardsClaimed(address indexed account, uint256 amount);

    /// @notice Error reverted when attempting an operation (stake, unstake, deposit) with zero amount.
    error ProvidedZeroAmount();
    /// @notice Error reverted when trying to deposit rewards (`_snapshotOnRewardsDeposit`) when there are no virtual rewards generated yet (division by zero protection).
    error NoRewardsToDistribute();
    /// @notice Error reverted during initialization if the provided reward token address is the zero address.
    error InvalidRewardTokenAddress();
    /// @notice Error reverted in `_updateUserPendingRewards` if calculated owed value exceeds the user's stored owed value (internal inconsistency check).
    error InsufficientOwedValue(address account, uint256 balance, uint256 needed);
    /// @notice Error reverted when trying to look up data for a future snapshot ID.
    error StakingModuleFutureLookup(uint256 snapshotId, uint256 currentsnapshotId);
    /// @notice Error reverted when trying to remove more shares than a user possesses.
    error InsufficientSharesAmount(address account, uint256 balance, uint256 needed);
    /// @notice Error reverted during unstake if the user does not have enough staked shares.
    error InsufficientBalanceToUnstake(address account, uint256 currentStake, uint256 amount);

    // keccak256(abi.encode(uint256(keccak256("sfUSD.storage.StakingModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKING_MODULE_STORAGE_LOCATION =
        0x3fdbb0b6fbdc22aa6cfbfb60ef44b75ee821b09be8a4d5fffd8504bbf3dd9500;

    /**
     * @dev Gets the pointer to the StakingModuleStorage struct in storage.
     */
    function _getStakingModuleStorage() internal pure returns (StakingModuleStorage storage $) {
        assembly {
            $.slot := STAKING_MODULE_STORAGE_LOCATION
        }
    }

    /**
     * @notice Initializes the StakingModule.
     * @dev Sets the reward token address and performs the initial snapshot. Can only be called once.
     * @param rewardToken_ The address of the ERC20 reward token.
     */
    function __StakingModule_init(address rewardToken_) internal onlyInitializing {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        require(rewardToken_ != address(0), InvalidRewardTokenAddress());

        $.rewardToken = IERC20(rewardToken_);

        _snapshotOnRewardsDeposit(0);
    }

    /**
     * @inheritdoc IStakingModule
     * @dev Requires amount > 0. Calls internal `_stake` function.
     */
    function stake(uint256 amount_) external {
        require(amount_ > 0, ProvidedZeroAmount());

        _stake(_msgSender(), amount_);
    }

    /**
     * @inheritdoc IStakingModule
     * @dev Requires amount > 0. Calls internal `_unstake` function.
     */
    function unstake(uint256 amount_) external {
        require(amount_ > 0, ProvidedZeroAmount());

        _unstake(_msgSender(), amount_);
    }

    /**
     * @inheritdoc IStakingModule
     * @dev Claims rewards up to the current snapshot ID (current time).
     */
    function claimRewards() external {
        claimRewardsUntil(clock());
    }

    /**
     * @inheritdoc IStakingModule
     * @dev Updates pending rewards first, then transfers if rewards > 0.
     */
    function claimRewardsUntil(uint48 snapshotId_) public {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        _updateUserPendingRewards(_msgSender(), snapshotId_);

        uint256 rewards_ = $.userPendingRewards[_msgSender()];
        if (rewards_ == 0) return;

        $.userPendingRewards[_msgSender()] = 0;

        $.rewardToken.safeTransfer(_msgSender(), rewards_);

        emit RewardsClaimed(_msgSender(), rewards_);
    }

    /**
     * @inheritdoc IStakingModule
     */
    function depositRewards(uint256 amount_) external onlyOwner {
        require(amount_ > 0, ProvidedZeroAmount());

        _snapshotOnRewardsDeposit(amount_);

        StakingModuleStorage storage $ = _getStakingModuleStorage();
        $.rewardToken.safeTransferFrom(_msgSender(), address(this), amount_);

        emit RewardsDeposited(amount_);
    }

    /**
     * @notice Gets the number of shares staked by a specific user.
     * @dev This is used internally by implementing contracts (like sfUSD) to reconstruct total balance.
     * @param account_ The address of the user.
     * @return uint256 The number of shares staked by the user.
     */
    function getUserStake(address account_) public view returns (uint256) {
        return _getStakingModuleStorage().userDistributions[account_].shares;
    }

    /**
     * @inheritdoc IStakingModule
     */
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

    /**
     * @inheritdoc IStakingModule
     */
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

    /**
     * @inheritdoc IStakingModule
     */
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

    /**
     * @inheritdoc IStakingModule
     */
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

    /**
     * @inheritdoc IERC6372
     */
    function clock() public view virtual override returns (uint48) {
        return _getStakingModuleStorage().snapshotId;
    }

    /**
     * @inheritdoc IERC6372
     */
    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=counter";
    }

    /**
     * @dev Abstract internal function hook called during stake/unstake operations.
     * @param from The address sending the token (user during unstake, contract during stake).
     * @param to The address receiving the token (contract during unstake, user during stake).
     * @param value The amount of the underlying token being transferred.
     */
    function _sfUSDTransfer(address from, address to, uint256 value) internal virtual;

    /**
     * @dev Internal logic for staking.
     * Initializes user state if first deposit, adds shares, updates total stake,
     * emits event, and calls the `_sfUSDTransfer` hook.
     * @param account_ The user staking.
     * @param amount_ The amount being staked.
     */
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

    /**
     * @dev Internal logic for unstaking.
     * Removes shares, updates total stake, emits event, and calls the `_sfUSDTransfer` hook.
     * @param account_ The user unstaking.
     * @param amount_ The amount being unstaked.
     */
    function _unstake(address account_, uint256 amount_) internal {
        _removeShares(account_, amount_);

        StakingModuleStorage storage $ = _getStakingModuleStorage();
        $.totalStake -= amount_;

        emit UserUnstaked(account_, amount_);

        _sfUSDTransfer(address(this), account_, amount_);
    }

    /**
     * @dev Calculates and updates a user's pending rewards based on unprocessed snapshots.
     * Iterates from `userLastProcessedSnapshot + 1` up to `untilSnapshot_`.
     * Updates `userPendingRewards`, `userLastProcessedSnapshot`, and `userClaimedRewards` storage.
     * Also updates the user's `owedValue`.
     * @param account_ The user whose rewards are being updated.
     * @param untilSnapshot_ The snapshot ID *after* the last one to process.
     */
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

    /**
     * @dev Creates a new snapshot, capturing current state and updating reward totals.
     * @param amount_ The amount of actual rewards being deposited in this snapshot.
     * @return oldSnapshot_ The ID of the snapshot that was just created.
     */
    function _snapshotOnRewardsDeposit(uint256 amount_) private returns (uint48) {
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

    /**
     * @dev Updates the total virtual rewards for the *current* (in-progress) snapshot ID
     * based on time elapsed since the last update.
     */
    function _updateVirtualRewards() private {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        $.snapshotTotalVirtualRewards[clock()] += _getValueToDistribute(block.timestamp, $.lastUpdateTime);

        $.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Internal function to add shares for a user.
     * Updates user rewards first, then increases total and user shares.
     * @param user_ The user receiving shares.
     * @param amount_ The amount of shares to add.
     */
    function _addShares(address user_, uint256 amount_) private {
        _updateUserPendingRewards(user_, clock());

        StakingModuleStorage storage $ = _getStakingModuleStorage();

        $.totalShares += amount_;
        $.userDistributions[user_].shares += amount_;
    }

    /**
     * @dev Internal function to remove shares from a user.
     * Checks balance, updates user rewards first, then decreases total and user shares.
     * @param user_ The user losing shares.
     * @param amount_ The amount of shares to remove.
     */
    function _removeShares(address user_, uint256 amount_) private {
        StakingModuleStorage storage $ = _getStakingModuleStorage();
        UserDistribution storage _userDist = $.userDistributions[user_];

        require(amount_ <= _userDist.shares, InsufficientSharesAmount(user_, _userDist.shares, amount_));

        _updateUserPendingRewards(user_, clock());

        $.totalShares -= amount_;
        _userDist.shares -= amount_;
    }

    /**
     * @dev Updates the global cumulative sum and optionally a user's distribution state.
     * Calculates virtual rewards accrued since the last update and updates the global sum.
     * If a user is provided, updates their owed value and cumulative sum marker.
     * @param user_ The user to update (or address(0) for global update only).
     */
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

    /**
     * @dev Calculates the future global cumulative sum based on time elapsed.
     * @param timeUpTo_ The timestamp to calculate the sum up to.
     * @return uint256 The calculated cumulative sum.
     */
    function _getFutureCumulativeSum(uint256 timeUpTo_) private view returns (uint256) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        if ($.totalShares == 0) {
            return $.cumulativeSum;
        }

        uint256 value_ = _getValueToDistribute(timeUpTo_, $.updatedAt);

        return $.cumulativeSum + Math.mulDiv(value_, PRECISION, $.totalShares);
    }

    /**
     * @dev Calculates the amount of "virtual value" generated over a time period.
     * @param timeUpTo_ The end timestamp of the period.
     * @param timeLastUpdate_ The start timestamp of the period.
     * @return uint256 The calculated virtual value.
     */
    function _getValueToDistribute(uint256 timeUpTo_, uint256 timeLastUpdate_) private view returns (uint256) {
        StakingModuleStorage storage $ = _getStakingModuleStorage();

        return Math.mulDiv((timeUpTo_ - timeLastUpdate_), $.totalShares, 1);
    }
}

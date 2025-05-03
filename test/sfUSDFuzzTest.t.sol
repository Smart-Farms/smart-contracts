// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20Mock} from "../contracts/mocks/ERC20Mock.sol";
import {sfUSD, IStakingModule} from "../contracts/sfUSD.sol";

contract sfUSDFuzzTest is Test {
    sfUSD public system;
    ERC20Mock public rewardToken;

    address public user1;
    address public user2;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        system = new sfUSD();
        rewardToken = new ERC20Mock("Reward Token", "RT", 6);

        ERC1967Proxy proxy = new ERC1967Proxy(address(system), new bytes(0));
        system = sfUSD(address(proxy));

        system.__sfUSD_init("Token", "T", address(rewardToken));
    }

    function testFuzz_Mint(uint200 amount) public {
        amount = uint200(bound(amount, 1, 10**75));

        system.mint(user1, amount);

        IStakingModule.StakingData memory data = system.getStakingData();

        assertEqUint(system.totalSupply(), amount);
        assertEqUint(data.totalStake, amount);
    }

    function testFuzz_Burn(uint200 amount) public {
        amount = uint200(bound(amount, 1, 10**75));

        system.mint(user1, amount);
        system.burn(user1, amount);

        IStakingModule.StakingData memory data = system.getStakingData();

        assertEqUint(system.totalSupply(), 0);
        assertEqUint(data.totalStake, 0);
    }

    function testFuzz_partialClaims(
        uint200 stakeAmount,
        uint32[] memory periodLengths
    ) public {
        stakeAmount = uint200(bound(stakeAmount, 1, 10**55));

        if (periodLengths.length == 0) return;

        uint256 periodCount = bound(periodLengths.length, 1, 2000);

        system.mint(user1, stakeAmount);
        system.mint(user2, stakeAmount);

        uint256[] memory rewards = new uint256[](periodCount);

        for (uint256 i = 0; i < periodCount; i++) {
            uint256 periodLength = bound(periodLengths[i], 1 days, 1365 days);

            vm.warp(block.timestamp + periodLength);

            uint256 periodReward = bound(periodLengths[i], 1, 10**45);
            rewards[i] = periodReward;

            rewardToken.mint(address(this), periodReward);
            rewardToken.approve(address(system), periodReward);
            system.depositRewards(periodReward);
        }

        vm.prank(user1);
        system.claimRewards();

        for (uint256 i = 0; i < periodCount; i++) {
            vm.prank(user2);
            system.claimRewardsUntil(uint48(i) + 2);
        }

        uint256 user1RewardsReceived = rewardToken.balanceOf(user1);
        uint256 user2RewardsReceived = rewardToken.balanceOf(user2);

        assertApproxEqAbs(
            int256(user1RewardsReceived),
            int256(user2RewardsReceived),
            10**6
        );

        uint256 totalRewards = 0;
        for (uint256 i = 0; i < periodCount; i++) {
            totalRewards += rewards[i];
        }

        assertApproxEqAbs(
            int256(user1RewardsReceived),
            int256(totalRewards / 2),
            10**6
        );
    }

    function testFuzz_RewardDistributionAndClaiming(
        uint200 amount1,
        uint200 amount2,
        uint256 rewards
    ) public {
        amount1 = uint200(bound(amount1, 1, 10**55));
        amount2 = uint200(bound(amount2, 1, 10**55));
        rewards = bound(rewards, 1, 10**35);

        system.mint(user1, amount1);
        system.mint(user2, amount2);

        IStakingModule.StakingData memory data = system.getStakingData();
        assertEqUint(data.totalStake, amount1 + amount2);

        rewardToken.mint(address(this), rewards);
        rewardToken.approve(address(system), rewards);

        vm.warp(block.timestamp + 1 days);

        system.depositRewards(rewards);

        vm.prank(user1);
        system.claimRewards();

        vm.prank(user2);
        system.claimRewards();
    }

    function testFuzz_MultiplePeriodsWithRewards(
        uint200 amount1,
        uint200 amount2,
        uint200[] memory rewards
    ) public {
        amount1 = uint200(bound(amount1, 1, 10**55));
        amount2 = uint200(bound(amount2, 1, 10**55));

        system.mint(user1, amount1);
        system.mint(user2, amount2);

        if (rewards.length == 0) return;

        uint256 rewardsLen = bound(rewards.length, 1, 2000);

        uint96[] memory timePeriods = new uint96[](rewardsLen);
        for (uint256 i = 0; i < rewardsLen; i++) {
            timePeriods[i] = uint96(bound(rewards[i], 1 days, 10000 days));
        }

        uint256 totalRewards;

        for (uint256 i = 0; i < rewardsLen; i++) {
            uint256 periodReward = bound(rewards[i], 10, 10**45);
            totalRewards += periodReward;

            uint256 timePeriod = bound(timePeriods[i], 1 days, 10000 days);

            vm.warp(block.timestamp + timePeriod);

            IStakingModule.StakingAtData memory atData = system.getStakingAtData(system.clock());

            if (atData.totalVirtualRewards > 0) {
                rewardToken.mint(address(this), periodReward);
                rewardToken.approve(address(system), periodReward);
                system.depositRewards(periodReward);
            } else {
                totalRewards -= periodReward;
            }

            IStakingModule.UserStakingData memory user1Data = system.getUserStakingData(user1);
            IStakingModule.UserStakingData memory user2Data = system.getUserStakingData(user2);

            if (user1Data.stakedAmount == 0 && user2Data.stakedAmount == 0) {
                totalRewards -= periodReward;
            }

            assertApproxEqAbs(int256(user1Data.pendingRewards + user2Data.pendingRewards), int256(totalRewards), 10**6);

            if (i % 2 == 0) {
                uint200 transferAmount = uint200(bound(amount1, 1, amount1));

                if (user1Data.stakedAmount > transferAmount) {
                    vm.prank(user1);
                    system.unstake(transferAmount);
                } else if (system.balanceOf(user1) - user1Data.stakedAmount > 10) {
                    vm.prank(user1);
                    system.stake((system.balanceOf(user1) - user1Data.stakedAmount) / 2);
                }
            } else {
                uint200 transferAmount = uint200(bound(amount2, 1, amount2));

                if (user2Data.stakedAmount > transferAmount) {
                    vm.prank(user2);
                    system.unstake(transferAmount);
                } else if (system.balanceOf(user2) - user2Data.stakedAmount > 10) {
                    vm.prank(user2);
                    system.stake((system.balanceOf(user2) - user1Data.stakedAmount) / 2);
                }
            }

            user1Data = system.getUserStakingData(user1);
            user2Data = system.getUserStakingData(user2);
            assertApproxEqAbs(int256(user1Data.pendingRewards + user2Data.pendingRewards), int256(totalRewards), 10**6);
        }

        assertEqUint(rewardToken.balanceOf(address(system)), totalRewards);

        vm.prank(user1);
        system.claimRewards();

        vm.prank(user2);
        system.claimRewards();
    }
}

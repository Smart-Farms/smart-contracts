import { expect } from "chai";
import { ethers } from "hardhat";

import { getInterfaceID } from "@solarity/hardhat-habits";

import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

import { usdc, wei } from "@scripts";

import { Reverter } from "@test-helpers";

import { ERC20Mock, SfUSD, SfUSDMock } from "@ethers-v6";

import { IStakingModule } from "../generated-types/ethers/contracts/interfaces/IStakingModule";
import UserStakingDataStruct = IStakingModule.UserStakingDataStruct;
import StakingDataStruct = IStakingModule.StakingDataStruct;
import StakingAtDataStruct = IStakingModule.StakingAtDataStruct;

describe("SfUSD", () => {
  const reverter = new Reverter();

  let OWNER: SignerWithAddress;
  let ALICE: SignerWithAddress;
  let BOB: SignerWithAddress;
  let CHARLIE: SignerWithAddress;

  let rewardToken: ERC20Mock;
  let sfUSD: SfUSD;

  const DAY = 86400n;
  const MONTH = 30n * DAY;
  const YEAR = 365n * DAY;

  before(async () => {
    [OWNER, ALICE, BOB, CHARLIE] = await ethers.getSigners();

    rewardToken = await ethers.deployContract("ERC20Mock", ["Reward Token", "RWD", 6]);

    await rewardToken.mint(OWNER.address, wei(1000000));

    const implementation = await ethers.deployContract("sfUSD");

    const proxy = await ethers.deployContract("ERC1967Proxy", [await implementation.getAddress(), "0x"]);

    sfUSD = (await ethers.getContractAt("sfUSD", await proxy.getAddress())) as any;

    await sfUSD.__sfUSD_init("Staking Token", "STK", rewardToken.getAddress());

    await rewardToken.approve(sfUSD.getAddress(), wei(1000000));

    await reverter.snapshot();
  });

  afterEach(reverter.revert);

  describe("Initialization", () => {
    it("should set parameters correctly", async () => {
      expect(await sfUSD.name()).to.eq("Staking Token");
      expect(await sfUSD.symbol()).to.eq("STK");

      const stakingData: StakingDataStruct = await sfUSD.getStakingData();

      expect(stakingData.rewardToken).to.eq(await rewardToken.getAddress());
      expect(stakingData.totalStake).to.eq(0);
      expect(stakingData.lastUpdateTime).to.eq((await time.latest()) - 1);
      expect(stakingData.snapshotId).to.eq(1);
      expect(await sfUSD.CLOCK_MODE()).to.eq("mode=counter");
    });

    it("should revert if trying to initialize sfUSD with rewards token set to address(0)", async () => {
      const implementation = await ethers.deployContract("sfUSD");
      const proxy = await ethers.deployContract("ERC1967Proxy", [await implementation.getAddress(), "0x"]);

      const sfUSD = (await ethers.getContractAt("sfUSD", await proxy.getAddress())) as any;
      await expect(sfUSD.__sfUSD_init("Staking Token", "STK", ethers.ZeroAddress)).to.be.revertedWithCustomError(
        sfUSD,
        "InvalidRewardTokenAddress",
      );
    });

    it("should revert if trying to directly call __StakingModule_init", async () => {
      const sfUSD: SfUSDMock = (await ethers.deployContract("sfUSDMock")) as any;
      await expect(sfUSD.__StakingModule_direct_init()).to.be.revertedWithCustomError(sfUSD, "NotInitializing");
    });

    it("should revert if trying to initialize sfUSD twice", async () => {
      await expect(sfUSD.__sfUSD_init("Staking Token", "STK", rewardToken.getAddress())).to.be.revertedWithCustomError(
        sfUSD,
        "InvalidInitialization",
      );
    });

    it("should revert if trying to getStakingAtData with snapshotId > currentSnapshot", async () => {
      await expect(sfUSD.getStakingAtData(2))
        .to.be.revertedWithCustomError(sfUSD, "StakingModuleFutureLookup")
        .withArgs(2, 1);
    });
  });

  describe("Staking", () => {
    it("should mint and stake tokens automatically", async () => {
      const tx = sfUSD.mint(ALICE.address, wei(50));
      await expect(tx).to.changeTokenBalance(sfUSD, ALICE, wei(50));

      const stakingData: StakingDataStruct = await sfUSD.getStakingData();

      expect(stakingData.totalStake).to.eq(wei(50));

      const userStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(ALICE.address);

      expect(userStakingData.stakedAmount).to.eq(wei(50));
      expect(userStakingData.pendingRewards).to.eq(0);
    });

    it("should stake tokens for two users between timeframes and calculate weights correctly", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await time.increase(YEAR);

      await sfUSD.mint(BOB.address, wei(100));

      const stakingData: StakingDataStruct = await sfUSD.getStakingData();
      const aliceStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(ALICE.address);
      const bobStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(BOB.address);

      expect(stakingData.totalStake).to.eq(wei(150));
      expect(stakingData.lastUpdateTime).to.eq(await time.latest());

      expect(aliceStakingData.stakedAmount).to.eq(wei(50));
      expect(bobStakingData.stakedAmount).to.eq(wei(100));
    });

    it("should distribute rewards between users proportionally", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await time.increase(YEAR / 2n - 1n);
      await sfUSD.mint(BOB.address, wei(100));
      await time.increase(YEAR / 2n - 1n);

      await sfUSD.depositRewards(usdc(500));

      await sfUSD.connect(BOB).claimRewards();
      await sfUSD.connect(ALICE).claimRewards();

      expect(await rewardToken.balanceOf(BOB.address)).to.closeTo(usdc(250), 5);
      expect(await rewardToken.balanceOf(ALICE.address)).to.closeTo(usdc(250), 5);

      expect((await rewardToken.balanceOf(BOB.address)) + (await rewardToken.balanceOf(ALICE.address))).to.closeTo(
        usdc(500),
        5,
      );
    });

    it("should distribute rewards between users proportionally (part2)", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await sfUSD.mint(BOB.address, wei(100));

      await time.increase(YEAR / 2n - 1n);

      await sfUSD.depositRewards(usdc(500));

      expect(await sfUSD.getPendingRewards(BOB.address)).to.closeTo((usdc(500) * 2n) / 3n, 10);
      expect(await sfUSD.getPendingRewards(ALICE.address)).to.closeTo((usdc(500) * 1n) / 3n, 10);
    });

    it("should carry rewards through multiple snapshots", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await time.increase(YEAR / 2n - 1n);

      await sfUSD.depositRewards(usdc(500));

      expect(await sfUSD.getPendingRewards(ALICE.address)).to.be.closeTo(usdc(500), 1);

      await sfUSD.mint(BOB.address, wei(100));

      await time.increase(YEAR / 2n - 1n);

      await sfUSD.depositRewards(usdc(1000));

      const alicePendingRewards = await sfUSD.getPendingRewards(ALICE.address);
      const bobPendingRewards = await sfUSD.getPendingRewards(BOB.address);

      expect(alicePendingRewards).to.closeTo(usdc(500) + usdc(1000) / 3n, 20);
      expect(bobPendingRewards).to.closeTo((2n * usdc(1000)) / 3n, 20);

      await sfUSD.connect(ALICE).claimRewards();
      await sfUSD.connect(BOB).claimRewards();

      expect(await rewardToken.balanceOf(BOB.address)).to.eq(bobPendingRewards);
      expect(await rewardToken.balanceOf(ALICE.address)).to.eq(alicePendingRewards);
    });

    it("should correctly distribute rewards after a user transfers tokens", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await sfUSD.mint(BOB.address, wei(100));

      await time.increase(YEAR / 2n - 1n);

      await sfUSD.connect(ALICE).transfer(CHARLIE.address, wei(25));
      await sfUSD.connect(CHARLIE).stake(wei(25));

      const aliceStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(ALICE.address);
      const bobStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(BOB.address);
      const charlieStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(CHARLIE.address);

      expect(aliceStakingData.stakedAmount).to.eq(wei(25));
      expect(bobStakingData.stakedAmount).to.eq(wei(100));
      expect(charlieStakingData.stakedAmount).to.eq(wei(25));

      await time.increase(YEAR / 2n);

      await sfUSD.depositRewards(usdc(1000));

      await sfUSD.connect(ALICE).claimRewards();
      await sfUSD.connect(BOB).claimRewards();
      await sfUSD.connect(CHARLIE).claimRewards();

      const expectedAliceReward = (usdc(500) * 50n) / 150n + (usdc(500) * 25n) / 150n;
      const expectedBobReward = (usdc(1000) * 100n) / 150n;
      const expectedCharlieReward = (usdc(500) * 25n) / 150n;

      expect(await rewardToken.balanceOf(ALICE.address)).to.be.closeTo(expectedAliceReward, 10);
      expect(await rewardToken.balanceOf(BOB.address)).to.be.closeTo(expectedBobReward, 10);
      expect(await rewardToken.balanceOf(CHARLIE.address)).to.be.closeTo(expectedCharlieReward, 10);
    });

    it("should correctly distribute sequential rewards (part 3)", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await sfUSD.mint(BOB.address, wei(100));

      await time.increase(YEAR / 2n);
      await sfUSD.depositRewards(usdc(1000));

      await time.increase(YEAR / 2n);
      await sfUSD.depositRewards(usdc(1000));

      await time.increase(YEAR / 2n);
      await sfUSD.depositRewards(usdc(1000));

      await sfUSD.connect(ALICE).claimRewards();
      await sfUSD.connect(BOB).claimRewards();

      const expectedAliceReward = (usdc(1000) * 50n) / 150n + (usdc(1000) * 50n) / 150n + (usdc(1000) * 50n) / 150n;
      const expectedBobReward = (usdc(1000) * 100n) / 150n + (usdc(1000) * 100n) / 150n + (usdc(1000) * 100n) / 150n;

      expect(await rewardToken.balanceOf(ALICE.address)).to.be.closeTo(expectedAliceReward, 20);
      expect(await rewardToken.balanceOf(BOB.address)).to.be.closeTo(expectedBobReward, 20);
    });

    it("should revert if trying to stake/unstake/depositRewards with 0 tokens", async () => {
      await expect(sfUSD.connect(ALICE).stake(0n)).to.be.revertedWithCustomError(sfUSD, "ProvidedZeroAmount");

      await expect(sfUSD.connect(ALICE).unstake(0n)).to.be.revertedWithCustomError(sfUSD, "ProvidedZeroAmount");

      await expect(sfUSD.depositRewards(0n)).to.be.revertedWithCustomError(sfUSD, "ProvidedZeroAmount");
    });

    it("should return 0 by getPendingRewards if snapshotId = 0", async () => {
      await sfUSD.mint(ALICE.address, wei(50));

      await time.increase(YEAR);

      expect(await sfUSD.getPendingRewards(ALICE.address)).to.eq(0);
    });

    it("should correctly handle rewards distribution with empty rewards periods", async () => {
      await sfUSD.mint(ALICE.address, wei(100));
      await sfUSD.mint(BOB.address, wei(100));

      await time.increase(YEAR / 2n);
      await sfUSD.connect(ALICE).unstake(wei(100));
      await sfUSD.depositRewards(usdc(1000));

      expect(await sfUSD.getPendingRewards(ALICE.address)).to.eq(usdc(500));
      expect(await sfUSD.getPendingRewards(BOB.address)).to.eq(usdc(500));

      await time.increase(YEAR / 2n);
      await sfUSD.depositRewards(usdc(1000));

      expect(await sfUSD.getPendingRewards(ALICE.address)).to.eq(usdc(500));
      expect(await sfUSD.getPendingRewards(BOB.address)).to.eq(usdc(1500));

      await sfUSD.connect(ALICE).stake(wei(100));

      await time.increase(YEAR / 2n);
      await sfUSD.depositRewards(usdc(1000));

      await sfUSD.connect(ALICE).claimRewards();
      await sfUSD.connect(BOB).claimRewards();

      const expectedAliceReward = usdc(500) + usdc(0) + usdc(500);
      const expectedBobReward = usdc(500) + usdc(1000) + usdc(500);

      expect(await rewardToken.balanceOf(ALICE.address)).to.be.closeTo(expectedAliceReward, 20);
      expect(await rewardToken.balanceOf(BOB.address)).to.be.closeTo(expectedBobReward, 20);
    });
  });

  describe("Unstaking", () => {
    beforeEach(async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await sfUSD.mint(BOB.address, wei(100));

      await time.increase(YEAR);
    });

    it("should revert if trying to unstake more than the user has staked", async () => {
      await expect(sfUSD.connect(ALICE).unstake(wei(51)))
        .to.be.revertedWithCustomError(sfUSD, "InsufficientSharesAmount")
        .withArgs(ALICE.address, wei(50), wei(51));
    });
  });

  describe("Reward distribution", () => {
    beforeEach(async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await sfUSD.mint(BOB.address, wei(100));

      await time.increase(YEAR);
    });

    it("should call claimRewards multiple times without reverting", async () => {
      const expectedAliceRewards = await sfUSD.getPendingRewards(ALICE);
      const expectedBobRewards = await sfUSD.getPendingRewards(BOB);

      await sfUSD.connect(ALICE).claimRewards();
      await sfUSD.connect(BOB).claimRewards();

      expect(await rewardToken.balanceOf(ALICE.address)).to.be.closeTo(expectedAliceRewards, 10);
      expect(await rewardToken.balanceOf(BOB.address)).to.be.closeTo(expectedBobRewards, 10);

      await expect(sfUSD.connect(ALICE).claimRewards()).to.not.be.reverted;
      await expect(sfUSD.connect(BOB).claimRewards()).to.not.be.reverted;
    });

    it("should set distributedVirtualRewards to 0 after a rewards are deposited", async () => {
      let stakingAtData: StakingAtDataStruct = await sfUSD.getStakingAtData(0);

      expect(stakingAtData.totalVirtualRewards).to.be.gt(0);

      await sfUSD.depositRewards(usdc(1000));

      stakingAtData = await sfUSD.getStakingAtData(1);

      expect(stakingAtData.totalVirtualRewards).to.eq(0);
    });

    it("should revert on second rewards deposit due to no rewards to distribute", async () => {
      await sfUSD.connect(BOB).unstake(await sfUSD.balanceOf(BOB.address));
      await sfUSD.connect(ALICE).unstake(await sfUSD.balanceOf(ALICE.address));

      await sfUSD.depositRewards(usdc(1000));
      await expect(sfUSD.depositRewards(usdc(1000))).to.be.revertedWithCustomError(sfUSD, "NoRewardsToDistribute");
    });

    it("should revert if trying to deposit rewards by not owner", async () => {
      await expect(sfUSD.connect(ALICE).depositRewards(usdc(100)))
        .to.be.revertedWithCustomError(sfUSD, "OwnableUnauthorizedAccount")
        .withArgs(ALICE.address);
    });

    it("should consume quite a lot of gas for claiming after a long idle period", async () => {
      for (let i = 0; i < 100; i++) {
        await time.increase(YEAR);
        await sfUSD.depositRewards(usdc(1000));
      }

      const gasUsed = (await (await sfUSD.connect(ALICE).claimRewards()).wait())?.gasUsed;
      expect(gasUsed).to.be.greaterThan(1.01 * 10 ** 6);
      expect(gasUsed).to.be.lessThan(1.5 * 10 ** 6);
    });
  });

  describe("sfUSD as token functionality", () => {
    it("should revert if trying to mint/burn by not owner", async () => {
      await expect(sfUSD.connect(ALICE).mint(BOB.address, wei(100)))
        .to.be.revertedWithCustomError(sfUSD, "OwnableUnauthorizedAccount")
        .withArgs(ALICE.address);

      await expect(sfUSD.connect(ALICE).burn(BOB.address, wei(100)))
        .to.be.revertedWithCustomError(sfUSD, "OwnableUnauthorizedAccount")
        .withArgs(ALICE.address);
    });

    it("should revert if trying to mint/burn/transfer value that is bigger than 200 bits", async () => {
      await expect(sfUSD.connect(OWNER).mint(BOB.address, 2n ** 208n))
        .to.be.revertedWithCustomError(sfUSD, "ValueTooHigh")
        .withArgs(2n ** 208n, 2n ** 200n - 1n);

      await expect(sfUSD.connect(OWNER).burn(BOB.address, 2n ** 208n))
        .to.be.revertedWithCustomError(sfUSD, "ValueTooHigh")
        .withArgs(2n ** 208n, 2n ** 200n - 1n);

      await expect(sfUSD.connect(OWNER).transfer(BOB.address, 2n ** 208n))
        .to.be.revertedWithCustomError(sfUSD, "ValueTooHigh")
        .withArgs(2n ** 208n, 2n ** 200n - 1n);
    });

    it("should upgrade contract only by owner", async () => {
      const newImplementation = await ethers.deployContract("sfUSD");

      await expect(sfUSD.connect(ALICE).upgradeToAndCall(await newImplementation.getAddress(), "0x"))
        .to.be.revertedWithCustomError(sfUSD, "OwnableUnauthorizedAccount")
        .withArgs(ALICE.address);

      await sfUSD.connect(OWNER).upgradeToAndCall(await newImplementation.getAddress(), "0x");

      expect(await sfUSD.implementation()).to.eq(await newImplementation.getAddress());
    });

    it("should support IERC20/ISFUSD/IERC6372/IStakingModule", async () => {
      expect(await sfUSD.supportsInterface(await getInterfaceID("IERC165"))).to.be.true;
      expect(await sfUSD.supportsInterface(await getInterfaceID("IERC20"))).to.be.true;
      expect(await sfUSD.supportsInterface(await getInterfaceID("ISFUSD"))).to.be.true;
      expect(await sfUSD.supportsInterface(await getInterfaceID("IERC6372"))).to.be.true;
      expect(await sfUSD.supportsInterface(await getInterfaceID("IStakingModule"))).to.be.true;
    });

    it("should stake automatically when minting", async () => {
      await sfUSD.mint(ALICE.address, wei(50));

      const stakingData: StakingDataStruct = await sfUSD.getStakingData();

      expect(stakingData.totalStake).to.eq(wei(50));
      expect(await sfUSD.balanceOf(ALICE.address)).to.eq(wei(50));
    });

    it("should include staked amount in balanceOf", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await sfUSD.connect(ALICE).unstake(wei(25));

      const userStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(ALICE.address);

      expect(await sfUSD.balanceOf(ALICE.address)).to.eq(wei(50));
      expect(userStakingData.stakedAmount).to.eq(wei(25));
    });

    it("should unstake automatically when burning/transferring", async () => {
      await sfUSD.mint(ALICE.address, wei(50));

      let userStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(ALICE.address);

      expect(userStakingData.stakedAmount).to.eq(wei(50));

      await sfUSD.connect(ALICE).transfer(BOB.address, wei(25));

      userStakingData = await sfUSD.getUserStakingData(ALICE.address);

      expect(userStakingData.stakedAmount).to.eq(wei(25));

      await sfUSD.burn(ALICE.address, wei(25));

      userStakingData = await sfUSD.getUserStakingData(ALICE.address);

      expect(userStakingData.stakedAmount).to.eq(0);
    });

    it("should transfer without unstaking", async () => {
      await sfUSD.mint(ALICE.address, wei(50));
      await sfUSD.connect(ALICE).unstake(wei(25));

      let userStakingData: UserStakingDataStruct = await sfUSD.getUserStakingData(ALICE.address);

      expect(userStakingData.stakedAmount).to.eq(wei(25));

      await sfUSD.connect(ALICE).transfer(BOB.address, wei(25));

      userStakingData = await sfUSD.getUserStakingData(ALICE.address);

      expect(userStakingData.stakedAmount).to.eq(wei(25));
    });

    it("should revert if trying to transfer more than the user has", async () => {
      await expect(sfUSD.connect(ALICE).transfer(BOB.address, wei(51)))
        .to.be.revertedWithCustomError(sfUSD, "ERC20InsufficientBalance")
        .withArgs(ALICE.address, 0, wei(51));
    });
  });
});

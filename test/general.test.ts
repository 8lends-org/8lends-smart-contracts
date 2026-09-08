import { expect } from "chai";
import { ethers } from "hardhat";
import { deployContracts } from "./utils/helpers";
import {
  ManagerRegistry,
  Treasury,
  Fundraise,
  TestERC20,
  Token,
  RewardSystem,
  IUniswapV2Router02,
} from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { Stage } from "../scripts/utils/helpers";
import { formatEther, formatUnits, parseEther, parseUnits } from "ethers";

import { BalanceTable, BalanceEntry } from "./utils/balance-table";





describe("🚀 8lends Protocol - General Flow Tests", function () {
  // 🔧 Configuration
  // Flip to true for the step-by-step trace and the balance tables while debugging.
  const LOGGING_ADDITIONALS = false;
  const TRACE_BALANCES = false;

  // 📊 Balance tracking storage
  const balanceTable = new BalanceTable();
  // 👥 Actors
  let owner: HardhatEthersSigner;
  let manager: HardhatEthersSigner;
  let borrower: HardhatEthersSigner;
  let investor: HardhatEthersSigner;
  let backend: HardhatEthersSigner;
  let inviter: HardhatEthersSigner;

  // 📋 Contracts
  let rewardSystem: RewardSystem;
  let usdcToken: TestERC20;
  let token: Token;
  let managerRegistry: ManagerRegistry;
  let treasury: Treasury;
  let fundraise: Fundraise;
  let router: IUniswapV2Router02;
  let poolAddress: string;
  // Project used by the whole vesting/claim chain below. Set when it is created, rather than
  // hardcoded, so adding a test that creates a project does not shift it out from under them.
  let vestingProjectId: bigint;
  // Total token reward for that project, captured when it is activated rather than hardcoded:
  // the amount depends on the token price at investment time, so any test that moves the pool
  // changes it. The assertions below are about the unlock percentages, not this number.
  let vestingTotalTokens: bigint;

  // 📊 Test Data
  let projectData: any;
  let project: {
    hardCap: bigint;
    softCap: bigint;
    totalInvested: bigint;
    startAt: bigint;
    preFundDuration: bigint;
    investorInterestRate: bigint;
    openStageEndAt: bigint;
    innerStruct: {
      borrower: string;
      loanToken: string;
      platformInterestRate: bigint;
      totalRepaid: bigint;
      fundedTime: bigint;
      stage: bigint;
    };
  };

  // ⚙️ Constants
  const PLATFORM_PERCENT = parseUnits("3", 4); // 3%
  const INVESTOR_INTEREST_RATE = parseUnits("20", 4); // 20%

  // 🔧 Helper Functions
  /** Logs only when LOGGING_ADDITIONALS is on. Indents so the trace nests under mocha's test titles. */
  function log(message: string, ...args: any[]) {
    if (LOGGING_ADDITIONALS) {
      console.log(" ".repeat(19) + message, ...args);
    }
  }

  /**
   * Copies an on-chain project into a struct for setProject, with the given fields replaced.
   * projects() already returns bigints, so nothing needs converting; the fields are listed
   * explicitly because spreading the result would carry its numeric tuple indices along.
   */
  function cloneProject(
    current: Fundraise.ProjectStructOutput,
    overrides: Partial<Omit<Fundraise.ProjectStruct, "innerStruct">> & {
      innerStruct?: Partial<Fundraise.InnerProjectStructStruct>;
    } = {}
  ): Fundraise.ProjectStruct {
    const { innerStruct, ...top } = overrides;
    return {
      hardCap: current.hardCap,
      softCap: current.softCap,
      totalInvested: current.totalInvested,
      startAt: current.startAt,
      preFundDuration: current.preFundDuration,
      investorInterestRate: current.investorInterestRate,
      openStageEndAt: current.openStageEndAt,
      ...top,
      innerStruct: {
        platformInterestRate: current.innerStruct.platformInterestRate,
        totalRepaid: current.innerStruct.totalRepaid,
        borrower: current.innerStruct.borrower,
        fundedTime: current.innerStruct.fundedTime,
        loanToken: current.innerStruct.loanToken,
        stage: current.innerStruct.stage,
        ...innerStruct,
      },
    };
  }

  async function invest(projectId: bigint, amount: bigint){
    const currentNonce1 = await fundraise.userNonces(await investor.getAddress());
    const nonceForSignature1 = currentNonce1 + 1n;
    const messageHash1 = ethers.solidityPackedKeccak256(
      ["address", "uint256", "uint256", "uint256", "address"],
      [await investor.getAddress(), projectId, amount, nonceForSignature1, await inviter.getAddress()]
    );
    const signature1 = await backend.signMessage(ethers.getBytes(messageHash1));
    await usdcToken.connect(investor).approve(await fundraise.getAddress(), amount);

    await fundraise.connect(investor).investUpdateV2(projectId, amount, nonceForSignature1, signature1, inviter);
  }

  /**
   * Tracks and displays token balances for all key addresses after an operation
   * Only works when TRACE_BALANCES is true
   * @param operation - Description of the operation that was performed
   */
  async function trackBalances(operation: string) {
    if (!TRACE_BALANCES) return;
    
    const balances = {
      investor: {
        usdc: formatUnits(await usdcToken.balanceOf(await investor.getAddress()), 6),
        token: formatEther(await token.balanceOf(await investor.getAddress()))
      },
      borrower: {
        usdc: formatUnits(await usdcToken.balanceOf(await borrower.getAddress()), 6),
        token: formatEther(await token.balanceOf(await borrower.getAddress()))
      },
      inviter: {
        usdc: formatUnits(await usdcToken.balanceOf(await inviter.getAddress()), 6),
        token: formatEther(await token.balanceOf(await inviter.getAddress()))
      },
      treasury: {
        usdc: formatUnits(await usdcToken.balanceOf(await treasury.getAddress()), 6),
        token: formatEther(await token.balanceOf(await treasury.getAddress()))
      },
      fundraise: {
        usdc: formatUnits(await usdcToken.balanceOf(await fundraise.getAddress()), 6),
        token: formatEther(await token.balanceOf(await fundraise.getAddress()))
      },
      rewardSystem: {
        usdc: formatUnits(await usdcToken.balanceOf(await rewardSystem.getAddress()), 6),
        token: formatEther(await token.balanceOf(await rewardSystem.getAddress()))
      }
    };

    // Get pool balances (assuming there's a pool contract or we get it from token)
    const poolBalances = {
      usdc: formatUnits(await usdcToken.balanceOf(poolAddress), 6),
      token: formatEther(await token.balanceOf(poolAddress))
    };

    // Get token price (placeholder - will be calculated based on pool ratios)
    const tokenPrice = {
      tokenPrice: (Number(poolBalances.usdc) / Number(poolBalances.token)).toString()
    };

    // Get token supply
    const tokenSupply = formatEther(await token.totalSupply());

    // Create balance entry
    const balanceEntry: BalanceEntry = { 
      operation, 
      balances, 
      pool: poolBalances, 
      price: tokenPrice,
      tokenSupply
    };

    // Add to table and display
    balanceTable.addEntry(balanceEntry);
    balanceTable.displayTable();
  }

  /**
   * Clears the balance history (useful for starting fresh in each test)
   */
  function clearBalanceHistory() {
    balanceTable.clearHistory();
  }




  // 🏗️ Helper Functions
  async function createProject(amountMin: string="20000", amountMax: string="40000") {
    log("📋 CREATE PROJECT");
    projectData = {
      softCap: ethers.parseUnits(amountMin, 6),
      hardCap: ethers.parseUnits(amountMax, 6),
      totalInvested: 0,
      startAt: await time.latest() - 10, // 10 seconds ago
      preFundDuration: 7 * 24 * 3600, // 7 days
      investorInterestRate: INVESTOR_INTEREST_RATE,
      openStageEndAt: await time.latest() + 7 * 24 * 3600, // 7 days
      innerStruct: {
        borrower: await borrower.getAddress(),
        loanToken: await usdcToken.getAddress(),
        platformInterestRate: PLATFORM_PERCENT,
        totalRepaid: 0,
        fundedTime: 0,
        stage: 0 // ComingSoon
      }
    };

    const projectId = await fundraise.projectCount();
    await fundraise.connect(manager).createProject(projectData, 1);
    return fundraise.projects(projectId);
  }

 

  describe("💰 Investment Flow Tests", function () {

    // 📊 Test Variables
    let softCap: bigint;

    // Deploying and funding is setup, not a test. It used to sit in the first two `it` blocks,
    // which reported a broken environment as two failing tests and let the rest run regardless.
    before(async function () {
      clearBalanceHistory();

      const deployResult = await deployContracts();
      owner = deployResult.owner;
      manager = deployResult.manager;
      borrower = deployResult.borrower;
      investor = deployResult.investor;
      backend = deployResult.backend;
      usdcToken = deployResult.usdcToken;
      managerRegistry = deployResult.managerRegistry;
      treasury = deployResult.treasury;
      fundraise = deployResult.fundraise;
      token = deployResult.token;
      inviter = deployResult.inviter;
      rewardSystem = deployResult.rewardSystem;
      router = deployResult.router;
      poolAddress = deployResult.poolAddress;

      project = await createProject();
      await trackBalances("Created project");

      // Fund the investor up to softCap, which is what the first investment tests spend
      softCap = project.softCap;
      await usdcToken.mint(investor.address, softCap);
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), softCap);
      await trackBalances("Minted USDC");
    });

    it("Send USDC to reward system", async function () {
      const amount = 10000;
      await usdcToken.mint(await rewardSystem.getAddress(), amount * 1e6);
      const balanceOfRewardSystem = await usdcToken.balanceOf(await rewardSystem.getAddress());
      log("💵 BALANCE OF REWARD SYSTEM", formatUnits(balanceOfRewardSystem, 6));
      expect(balanceOfRewardSystem).to.equal(amount * 1e6);
      await trackBalances(`Sent ${amount} USDC to reward system`);
    });


    it("💱 Token price should be ~0.01 USDC", async function () {
      const usdcAmount = 100;
      const minimumTokenAmount = 9000;
      const maximumTokenAmount = 11000;
      const tokenPrice = await router.getAmountsOut(ethers.parseUnits(usdcAmount.toString(), 6), [await usdcToken.getAddress(), await token.getAddress()]);
      expect(Number(ethers.formatEther(tokenPrice[1]))).to.be.greaterThanOrEqual(minimumTokenAmount);
      expect(Number(ethers.formatEther(tokenPrice[1]))).to.be.lessThanOrEqual(maximumTokenAmount);
    });

    it("🚫 Token buying on DEX should be disabled", async () => {
      const path = [await usdcToken.getAddress(), await token.getAddress()];
      await usdcToken.connect(investor).approve(await router.getAddress(), 100);
      await expect(router.connect(investor).swapExactTokensForTokens(100, 0, path, await investor.getAddress(), await time.latest() + 1000))
      .to.be.revertedWith("UniswapV2: TRANSFER_FAILED");
    });

    it("💰 Investment in project should succeed", async function () {
        // Create signature for first investment
        const currentNonce1 = await fundraise.userNonces(await investor.getAddress());
        const nonceForSignature1 = currentNonce1 + 1n;
        const messageHash1 = ethers.solidityPackedKeccak256(
          ["address", "uint256", "uint256", "uint256", "address"],
          [await investor.getAddress(), 0, softCap/2n, nonceForSignature1, await inviter.getAddress()]
        );
        const signature1 = await backend.signMessage(ethers.getBytes(messageHash1));

        await fundraise.connect(investor).investUpdateV2(0, softCap/2n, nonceForSignature1, signature1, inviter);

        // Create signature for second investment
        const currentNonce2 = await fundraise.userNonces(await investor.getAddress());
        const nonceForSignature2 = currentNonce2 + 1n;
        const messageHash2 = ethers.solidityPackedKeccak256(
          ["address", "uint256", "uint256", "uint256", "address"],
          [await investor.getAddress(), 0, softCap/2n, nonceForSignature2, await inviter.getAddress()]
        );
        const signature2 = await backend.signMessage(ethers.getBytes(messageHash2));

        await fundraise.connect(investor).investUpdateV2(0, softCap/2n, nonceForSignature2, signature2, inviter);
        project = await fundraise.projects(0);
        expect(project.totalInvested).to.equal(softCap);
        expect(project.innerStruct.stage).to.equal(Stage.Open); // Open
        expect(project.innerStruct.totalRepaid).to.equal(0); // Amount repaid to borrower
        expect(project.innerStruct.fundedTime).to.equal(0); // When soft cap was reached
        await trackBalances(`Investment in project ${formatUnits(softCap, 6)} USDC`);
    });

    it("🔒 Rewards cannot be claimed before project activation", async function () {
      await expect(rewardSystem.connect(investor).claimUSDCForProject(0))
        .to.be.revertedWith("Project rewards not activated");
      await expect(rewardSystem.connect(investor).claimTokensForProject(0))
        .to.be.revertedWith("Project rewards not activated");
    });



    it("💸 Transfer funds to borrower (minus platform fee)", async function () {
        await fundraise.connect(manager).transferFundsToBorrower(0); // Transfer funds to borrower
        expect((await fundraise.projects(0)).innerStruct.stage).to.equal(Stage.Funded); // Funded
        const project = await fundraise.projects(0);
        const platformFee = (project.totalInvested * project.innerStruct.platformInterestRate) / await fundraise.BASIS_POINTS();
      log("💰 PLATFORM FEE", formatUnits(platformFee, 6));
      log("📊 SOFT CAP", formatUnits(softCap, 6));
      log("💵 TOTAL INVESTED", formatUnits(project.totalInvested, 6));
        const balanceOfBorrower = await usdcToken.balanceOf(await borrower.getAddress());
        expect(balanceOfBorrower).to.equal(softCap - platformFee);
        await trackBalances("Sent funds to borrower");
    });




    it("✅ Rewards should be activated after Stage.Funded", async function () {
      const projectRewards = await rewardSystem.getProjectRewards(await investor.getAddress(), 0);
      log("🎯 PROJECT REWARDS IS ACTIVATED", projectRewards.isActivated);
      log("💵 PROJECT REWARDS TOTAL USDC", formatUnits(projectRewards.totalUSDC, 6));
      log("🪙 PROJECT REWARDS TOTAL TOKENS", formatEther(projectRewards.totalTokens));
      expect(projectRewards.isActivated).to.be.true;
    });

    it(`🏦 Treasury balance should be ${formatUnits(PLATFORM_PERCENT, 4)}% of investment`, async function () {
      const balanceOfTreasury = await usdcToken.balanceOf(await treasury.getAddress());
      const burnedUSDC = (await rewardSystem.burnPercentage()) * project.totalInvested / await fundraise.BASIS_POINTS();
      log("💰 BALANCE OF TREASURY", formatUnits(balanceOfTreasury, 6));
      log("📊 PROJECT INVESTED", formatUnits(project.totalInvested, 6));
      log("📈 PLATFORM PERCENT", formatUnits(PLATFORM_PERCENT, 4));
      log("🔥 BURNED USDC", formatUnits(burnedUSDC, 6));
      log("💵 EXPECTED BALANCE OF TREASURY", formatUnits(project.totalInvested * PLATFORM_PERCENT / await fundraise.BASIS_POINTS(), 6));

      expect(balanceOfTreasury).to.equal(project.totalInvested * PLATFORM_PERCENT / await fundraise.BASIS_POINTS());
    });



    it("🎁 Claim USDC rewards by investor", async function () {
      const projectRewards = await rewardSystem.getProjectRewards(await investor.getAddress(), 0);
      const initialBalance = await usdcToken.balanceOf(await investor.getAddress());


      const balanceOfRewardSystem = await usdcToken.balanceOf(await rewardSystem.getAddress());
      log("💵 BALANCE OF REWARD SYSTEM", formatUnits(balanceOfRewardSystem, 6));

      log("💵 PROJECT REWARDS TOTAL USDC", formatUnits(projectRewards.totalUSDC, 6));
      log("🪙 PROJECT REWARDS TOTAL TOKENS", formatEther(projectRewards.totalTokens));

      // 30 USDC for new user bonus
      expect(projectRewards.totalUSDC).to.be.eq(30e6);
      expect(projectRewards.totalTokens).to.be.greaterThan(0);

      
      await rewardSystem.connect(investor).claimUSDCForProject(0);
      
      const finalBalance = await usdcToken.balanceOf(await investor.getAddress());
      expect(finalBalance - initialBalance).to.equal(projectRewards.totalUSDC);

      const balanceOfRewardSystemAfter = await usdcToken.balanceOf(await rewardSystem.getAddress());
      expect(balanceOfRewardSystemAfter).to.equal(balanceOfRewardSystem - projectRewards.totalUSDC);
      await trackBalances("Investor claimed USDC rewards");
    });

    it("🎁 Claim USDC rewards by inviter", async function () {
      // Refill Treasury for inviter
      const balanceOfRewardSystem = await usdcToken.balanceOf(await rewardSystem.getAddress());
      const projectRewards = await rewardSystem.getProjectRewards(await inviter.getAddress(), 0);

      // await usdcToken.mint(await treasury.getAddress(), addedUSDCToTreasury); // need more than treasury has, so we top up
      
      const initialBalance = await usdcToken.balanceOf(await inviter.getAddress());

      log("💵 PROJECT REWARDS TOTAL USDC", formatUnits(projectRewards.totalUSDC, 6));
      log("👤 INVITER BALANCE", formatUnits(initialBalance, 6));
      
      await rewardSystem.connect(inviter).claimUSDCForProject(0);
      
      const finalBalance = await usdcToken.balanceOf(await inviter.getAddress());
      log("👤 INVITER BALANCE AFTER", formatUnits(finalBalance, 6));

      expect(finalBalance - initialBalance).to.equal(projectRewards.totalUSDC);
      const balanceOfRewardSystemAfter = await usdcToken.balanceOf(await rewardSystem.getAddress());
      expect(balanceOfRewardSystemAfter).to.equal(balanceOfRewardSystem - projectRewards.totalUSDC);
      log("🏦 BALANCE OF TREASURY AFTER", formatUnits(balanceOfRewardSystemAfter, 6));
      await trackBalances("Inviter claimed USDC rewards");
    });


    it("✅ Inviter USDC rewards (already claimed)", async() => {
      const projectRewards = await rewardSystem.getProjectRewards(await inviter.getAddress(), 0);
      // Inviter already claimed their rewards, so totalUSDC = 0
      expect(projectRewards.totalUSDC).to.equal(0);
    });

    it("🪙 Investor token rewards (6% tokens)", async() => {
      const tokenPercentage = await rewardSystem.tokenPercentage();
      log("📊 TOKEN PERCENTAGE", tokenPercentage);
      const investorInfo = await fundraise.investorInfo(await investor.getAddress(), 0);
      const investorInvestedAmount = investorInfo.investedAmount;
      log("💵 INVESTOR INVESTED USDC", formatUnits(investorInvestedAmount, 6));
      // investor vesting total amount
      const investorVestingTotalAmount = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 0);
      log("🪙 INVESTOR VESTING TOKEN TOTAL AMOUNT", formatEther(investorVestingTotalAmount.totalAmount));
      log("✅ INVESTOR VESTING TOKEN CLAIMED AMOUNT", formatEther(investorVestingTotalAmount.claimedAmount));
      log("🎯 INVESTOR VESTING TOKEN CLAIMABLE AMOUNT", formatEther(investorVestingTotalAmount.claimableAmount));
      log("⏰ INVESTOR VESTING TOKEN START TIME", new Date(Number(investorVestingTotalAmount.startTime) * 1000).toLocaleString());
      log("🔥 INVESTOR VESTING TOKEN IS ACTIVE", investorVestingTotalAmount.isActive);
      expect(investorVestingTotalAmount.totalAmount).to.be.greaterThanOrEqual(investorInvestedAmount * tokenPercentage / 100n);
    });

    it("⏰ Skip 1 week and check claimable amount", async() => {
      const BASIS_POINTS = await rewardSystem.BASIS_POINTS();
      await time.increase(7 * 24 * 3600);
      const investorInfo = await fundraise.investorInfo(await investor.getAddress(), 0);
      const investorInvestedAmount = investorInfo.investedAmount;
      const tokenPercentage = await rewardSystem.tokenPercentage();

      const investorVestingTotalAmount = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 0);
      log("🪙 INVESTOR VESTING TOKEN TOTAL AMOUNT", formatEther(investorVestingTotalAmount.totalAmount));
      log("✅ INVESTOR VESTING TOKEN CLAIMED AMOUNT", formatEther(investorVestingTotalAmount.claimedAmount));
      log("🎯 INVESTOR VESTING TOKEN CLAIMABLE AMOUNT", formatEther(investorVestingTotalAmount.claimableAmount));

      // weekly correct amount
      const weeklyUnlock = await rewardSystem.weeklyUnlock(); //25
      log("📊 WEEKLY UNLOCK", formatUnits(weeklyUnlock,1));
      log("💵 INVESTOR INVESTED USDC", formatUnits(investorInvestedAmount, 6));
      log("📈 TOKEN PERCENTAGE", tokenPercentage/BASIS_POINTS * 100n);

      const _expectedClaimableAmount = investorVestingTotalAmount.totalAmount * weeklyUnlock * 2n / BASIS_POINTS;
      log("🎯 EXPECTED CLAIMABLE AMOUNT", formatEther(_expectedClaimableAmount));
      expect(investorVestingTotalAmount.claimableAmount).to.be.eq(_expectedClaimableAmount);
    });

    it("🎁 Claim tokens by investor (balance should equal claimableAmount)", async () => {
      const { claimableAmount } = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 0);
      await rewardSystem.connect(investor).claimTokensForProject(0);
      const balance = await token.balanceOf(await investor.getAddress());
      expect(balance).to.be.eq(claimableAmount);
      await trackBalances(`Investor claimed tokens (week 1 - %${Number(await rewardSystem.weeklyUnlock())/1e4})`);
    });

    it("✅ After claim, claimableAmount should be 0", async () => {
      const { claimableAmount } = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 0);
      const balance = await token.balanceOf(await investor.getAddress());
      log("🪙 INVESTOR TOKEN BALANCE", formatEther(balance));
      expect(claimableAmount).to.be.eq(0);
    });

    it("🚫 Try to claim tokens again (should fail)", async () => {
      await expect(rewardSystem.connect(investor).claimTokensForProject(0)).to.be.revertedWith("No tokens to claim");
    });

    it("💱 Sell claimed tokens on DEX", async () => {
      const tokensBefore = await token.balanceOf(await investor.getAddress());
      expect(tokensBefore).to.be.greaterThan(0);
      const usdcBefore = await usdcToken.balanceOf(await investor.getAddress());

      await token.connect(investor).approve(await router.getAddress(), tokensBefore);
      await router.connect(investor).swapExactTokensForTokens(
        tokensBefore,
        0,
        [await token.getAddress(), await usdcToken.getAddress()],
        await investor.getAddress(),
        await time.latest() + 1000
      );

      // The whole balance goes in, and the proceeds come back as USDC
      expect(await token.balanceOf(await investor.getAddress())).to.equal(0);
      const usdcGained = (await usdcToken.balanceOf(await investor.getAddress())) - usdcBefore;
      expect(usdcGained).to.be.greaterThan(0);

      log("🪙 TOKENS SOLD", formatEther(tokensBefore));
      log("📈 INVESTOR INCREMENTED USDC", formatUnits(usdcGained, 6));
      await trackBalances("Sold claimed tokens on DEX");
    });

    it("💱 Check token price on DEX", async () => {
      const path = [await usdcToken.getAddress(), await token.getAddress()];
      const forOne = await router.getAmountsOut(ethers.parseUnits("100", 6), path);
      const forTwo = await router.getAmountsOut(ethers.parseUnits("200", 6), path);

      // The pool quotes a real price, and more USDC in buys more tokens out. Below that, the
      // constant-product curve makes twice the input buy strictly less than twice the output.
      expect(forOne[1]).to.be.greaterThan(0);
      expect(forTwo[1]).to.be.greaterThan(forOne[1]);
      expect(forTwo[1]).to.be.lessThan(forOne[1] * 2n);

      log("💰 TOKEN PRICE", 100 / Number(formatEther(forOne[1])));
    });

    it("✅ Enable token buying", async () => {
      await token.connect(owner).enableBuying();
      const buyingEnabled = await token.buyingEnabled();
      expect(buyingEnabled).to.be.true;
      await trackBalances("Enabled token buying");
    });

    it("🛒 Inviter can buy tokens on DEX", async () => {

      const path = [await usdcToken.getAddress(), await token.getAddress()];
      const inviterBalanceUSDT = await usdcToken.balanceOf(await inviter.getAddress());

      await usdcToken.connect(inviter).approve(await router.getAddress(), inviterBalanceUSDT);
      await router.connect(inviter).swapExactTokensForTokens(inviterBalanceUSDT, 0, path, await inviter.getAddress(), await time.latest() + 1000);
      const inviterBalanceTokens = await token.balanceOf(await inviter.getAddress());
      const inviterBalanceUSDTAfterSwap = await usdcToken.balanceOf(await inviter.getAddress());
      log("🪙 INVITER TOKENS BALANCE", formatEther(inviterBalanceTokens));
      log("💵 INVITER USDC BALANCE AFTER SWAP", formatUnits(inviterBalanceUSDTAfterSwap, 6));
      await trackBalances("Inviter can buy tokens on DEX");
      expect(inviterBalanceTokens).to.be.greaterThan(0);
      expect(inviterBalanceUSDTAfterSwap).to.be.eq(0);
    });

    it("🚫 Disable token buying and verify inviter cannot buy", async () => {
      //mint usdc to inviter
      await usdcToken.mint(await inviter.getAddress(), 100);
      //approve usdc to router
      await usdcToken.connect(inviter).approve(await router.getAddress(), 100);
      const path = [await usdcToken.getAddress(), await token.getAddress()];
      await token.connect(owner).disableBuying();
      const buyingEnabled = await token.buyingEnabled();
      expect(buyingEnabled).to.be.false;
      await expect(router.connect(inviter).swapExactTokensForTokens(100, 0, path, await inviter.getAddress(), await time.latest() + 1000))
      .to.be.revertedWith("UniswapV2: TRANSFER_FAILED");
    });

    it("✅ But inviter can sell their tokens", async () => {
      const inviterBalanceTokens = await token.balanceOf(await inviter.getAddress());
      const inviterBalanceUSDT = await usdcToken.balanceOf(await inviter.getAddress());
      log("💵 INVITER USDC BALANCE", formatUnits(inviterBalanceUSDT, 6));
      log("🪙 INVITER TOKENS BALANCE", formatEther(inviterBalanceTokens));
     
      await token.connect(inviter).approve(await router.getAddress(), inviterBalanceTokens);
      await router.connect(inviter).swapExactTokensForTokens(inviterBalanceTokens, 0, [await token.getAddress(), await usdcToken.getAddress()], await inviter.getAddress(), await time.latest() + 1000);
     
      const inviterBalanceUSDTAfterSwap = await usdcToken.balanceOf(await inviter.getAddress());
      const inviterBalanceTokensAfterSwap = await token.balanceOf(await inviter.getAddress());

      log("💵 INVITER USDC BALANCE AFTER SWAP", formatUnits(inviterBalanceUSDTAfterSwap, 6));
      log("🪙 INVITER TOKENS BALANCE AFTER SWAP", formatEther(inviterBalanceTokensAfterSwap));
      expect(inviterBalanceUSDTAfterSwap).to.be.greaterThan(inviterBalanceUSDT);
      expect(inviterBalanceTokensAfterSwap).to.be.eq(0);
      await trackBalances("Inviter can sell their tokens");
    });

    it("❌ Test project cancellation - rewards remain pending", async function () {
      const projectId = await fundraise.projectCount();
      await createProject("1000", "2000");

      // Stay under softCap: the project has to still be cancellable from Open
      const investment = ethers.parseUnits("500", 6);
      await usdcToken.mint(investor.address, investment);
      await invest(projectId, investment);

      await fundraise.connect(manager).cancelProject(projectId);
      expect((await fundraise.projects(projectId)).innerStruct.stage).to.equal(Stage.Canceled);

      // Investing records the investor's token rewards; only reaching Funded activates them
      const projectRewards = await rewardSystem.getProjectRewards(await investor.getAddress(), projectId);
      log("🪙 PROJECT REWARDS TOKENS", formatEther(projectRewards.totalTokens));
      expect(projectRewards.totalTokens).to.be.greaterThan(0);
      expect(projectRewards.isActivated).to.be.false;

      // Cannot claim rewards from canceled project
      await expect(rewardSystem.connect(investor).claimUSDCForProject(projectId))
        .to.be.revertedWith("Project rewards not activated");
    });


    it("💸 Borrower repayment", async() => {
      const investorInterest = (project.totalInvested * project.investorInterestRate) / await fundraise.BASIS_POINTS();
      const totalRepaymentAmount = project.totalInvested + investorInterest;

      const borrowerBalance = await usdcToken.balanceOf(await borrower.getAddress());
      const needAddBalance = totalRepaymentAmount - borrowerBalance;
      
      //mint and approve usdc to borrower
      await usdcToken.mint(await borrower.getAddress(), needAddBalance);
      await usdcToken.connect(borrower).approve(await fundraise.getAddress(), totalRepaymentAmount);
      // make repayment
      await fundraise.connect(borrower).makeRepayment(0, totalRepaymentAmount);
      project = await fundraise.projects(0);
      log("📊 PROJECT STAGE" , project.innerStruct.stage);
      log("💵 PROJECT TOTAL REPAID" , formatUnits(project.innerStruct.totalRepaid, 6));
      log("⏰ PROJECT FUNDED TIME" , new Date(Number(project.innerStruct.fundedTime) * 1000).toLocaleString());
      log("💰 PROJECT TOTAL INVESTED" , formatUnits(project.totalInvested, 6));
      log("📈 PROJECT INVESTOR INTEREST" , formatUnits(investorInterest, 6));
      log("💸 PROJECT TOTAL REPAYMENT AMOUNT" , formatUnits(totalRepaymentAmount, 6));
    
      expect(project.innerStruct.stage).to.equal(Stage.Repaid, "Stage is not Repaid"); // Repaid
      expect(project.innerStruct.totalRepaid).to.equal(totalRepaymentAmount);
      await trackBalances("Borrower repaid loan");
    });

    it("Investor claim investment", async () => {
      const investorBalanceBefore = await usdcToken.balanceOf(await investor.getAddress());
      await fundraise.connect(investor).claim(0, await investor.getAddress());
      const balance = await usdcToken.balanceOf(await investor.getAddress());
      expect(balance).to.be.eq(investorBalanceBefore + project.totalInvested + project.totalInvested * project.investorInterestRate / await fundraise.BASIS_POINTS());
      await trackBalances("Investor claimed principal + profit");
    });

    it("⏰ Skip 40 weeks and claim all tokens", async () => {
      await time.increase(40 * 7 * 24 * 3600);
      await rewardSystem.connect(investor).claimTokensForProject(0);
      const balance = await token.balanceOf(await investor.getAddress());
      const { claimableAmount, totalAmount, claimedAmount } = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 0);
      log("🪙 INVESTOR TOKEN BALANCE", formatEther(balance));
      log("📊 INVESTOR TOKEN TOTAL AMOUNT", formatEther(totalAmount));
      log("✅ INVESTOR TOKEN CLAIMED AMOUNT", formatEther(claimedAmount));
      log("🎯 INVESTOR TOKEN CLAIMABLE AMOUNT", formatEther(claimableAmount));

      // subtract 2.5% from totalAmount that was already claimed earlier
      const totalAmountMinus25 = totalAmount - (totalAmount * 2n * 25n / 1000n);
      expect(balance).to.be.eq(totalAmountMinus25); 
      expect(claimedAmount).to.be.eq(totalAmount);
      expect(claimableAmount).to.be.eq(0);
      await trackBalances("after 40 weeks investor claimed all tokens");
    });

    it("Investor sold all tokens", async () => {
      const investorBalanceTokens = await token.balanceOf(await investor.getAddress());
      const investorBalanceUSDT = await usdcToken.balanceOf(await investor.getAddress());
      await token.connect(investor).approve(await router.getAddress(), investorBalanceTokens);
      await router.connect(investor).swapExactTokensForTokens(investorBalanceTokens, 0, [await token.getAddress(), await usdcToken.getAddress()], await investor.getAddress(), await time.latest() + 1000);
      const investorBalanceUSDTAfterSwap = await usdcToken.balanceOf(await investor.getAddress());
      const investorBalanceTokensAfterSwap = await token.balanceOf(await investor.getAddress());
      expect(investorBalanceUSDTAfterSwap).to.be.greaterThan(investorBalanceUSDT);
      expect(investorBalanceTokensAfterSwap).to.be.eq(0);
      await trackBalances("Investor sold all tokens");
    });

    // ========================================
    // 🔄 PROJECT MANAGEMENT TESTS
    // ========================================

    it("🔄 Move project from ComingSoon to Open stage", async () => {
      // Create new project in ComingSoon
      const newProjectData = {
        softCap: ethers.parseUnits("1000", 6),
        hardCap: ethers.parseUnits("2000", 6),
        totalInvested: 0,
        startAt: await time.latest() - 10,
        preFundDuration: 7 * 24 * 3600,
        investorInterestRate: INVESTOR_INTEREST_RATE,
        openStageEndAt: await time.latest() + 7 * 24 * 3600,
        innerStruct: {
          borrower: await borrower.getAddress(),
          loanToken: await usdcToken.getAddress(),
          platformInterestRate: PLATFORM_PERCENT,
          totalRepaid: 0,
          fundedTime: 0,
          stage: 0 // ComingSoon
        }
      };

      const projectId = await fundraise.projectCount();
      await fundraise.connect(manager).createProject(newProjectData, 1);
      
      let newProject = await fundraise.projects(projectId);
      expect(newProject.innerStruct.stage).to.equal(Stage.ComingSoon);
      
      // Move to Open
      await fundraise.connect(manager).moveProjectStage(projectId);
      newProject = await fundraise.projects(projectId);
      expect(newProject.innerStruct.stage).to.equal(Stage.Open);
    });

    it("📊 Update project parameters", async () => {
      const newProjectData = {
        softCap: ethers.parseUnits("1000", 6),
        hardCap: ethers.parseUnits("2000", 6),
        totalInvested: 0,
        startAt: await time.latest() - 10,
        preFundDuration: 7 * 24 * 3600,
        investorInterestRate: INVESTOR_INTEREST_RATE,
        openStageEndAt: await time.latest() + 7 * 24 * 3600,
        innerStruct: {
          borrower: await borrower.getAddress(),
          loanToken: await usdcToken.getAddress(),
          platformInterestRate: PLATFORM_PERCENT,
          totalRepaid: 0,
          fundedTime: 0,
          stage: 0 // ComingSoon
        }
      };
      await fundraise.connect(manager).createProject(newProjectData, 2);

      const projectId = await fundraise.projectCount() - 1n;
      let currentProject = await fundraise.projects(projectId);

      // Create new project object with updated parameters
      const updatedProject = {
        hardCap: ethers.parseUnits("2500", 6),
        softCap: ethers.parseUnits("1500", 6),
        totalInvested: currentProject.totalInvested,
        startAt: currentProject.startAt,
        preFundDuration: currentProject.preFundDuration,
        investorInterestRate: parseUnits("2", 4), // 2% instead of 1.5%
        openStageEndAt: currentProject.openStageEndAt + 86400n, // +1 day
        innerStruct: {
          platformInterestRate: parseUnits("4", 4), // 4% instead of 3%
          totalRepaid: currentProject.innerStruct.totalRepaid,
          borrower: currentProject.innerStruct.borrower,
          fundedTime: currentProject.innerStruct.fundedTime,
          loanToken: currentProject.innerStruct.loanToken,
          stage: currentProject.innerStruct.stage
        }
      };

      // Update project
      await fundraise.connect(manager).setProject(projectId, updatedProject);
      const updatedProjectData = await fundraise.projects(projectId);

      // Check that parameters were updated
      expect(updatedProjectData.hardCap).to.equal(ethers.parseUnits("2500", 6));
      expect(updatedProjectData.softCap).to.equal(ethers.parseUnits("1500", 6));
      expect(updatedProjectData.investorInterestRate).to.equal(parseUnits("2", 4));
      expect(updatedProjectData.openStageEndAt).to.equal(currentProject.openStageEndAt + 86400n);
      expect(updatedProjectData.innerStruct.platformInterestRate).to.equal(parseUnits("4", 4));
    });

    it("🚫 Non-manager cannot update project", async () => {
      const projectId = await fundraise.projectCount();
      const currentProject = await fundraise.projects(projectId);
      const updatedProject = cloneProject(currentProject, { hardCap: ethers.parseUnits("3000", 6) });

      await expect(fundraise.connect(investor).setProject(projectId, updatedProject))
        .to.be.revertedWithCustomError(fundraise, "NotAManager");
    });

    it("🚫 Cannot update funded project", async () => {
      const projectId = 0; // Use first project, which is already funded
      const currentProject = await fundraise.projects(projectId);
      
      log("🔍 Funded project stage:", currentProject.innerStruct.stage.toString());

      const updatedProject = cloneProject(currentProject, { hardCap: ethers.parseUnits("3000", 6) });

      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWithCustomError(fundraise, "CantUpdateFundedProject");
    });

    it("🚫 Cannot extend openStageEndAt more than 30 days", async () => {
      // Create a project and move it to Open stage with an investment
      const projectId = await fundraise.projectCount();
      await createProject();

      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await invest(projectId, investmentAmount);

      const currentProject = await fundraise.projects(projectId);
      log("🔍 Project stage:", currentProject.innerStruct.stage.toString());

      // Only openStageEndAt changes: 32 days past the current end, over the 30-day cap
      const updatedProject = cloneProject(currentProject, {
        openStageEndAt: currentProject.openStageEndAt + 32n * 86400n,
      });

      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWithCustomError(fundraise, "OpenStageExtensionTooLong");
    });

    it("🚫 Cannot decrease platform interest rate", async () => {
      // Create a project and move it to Open stage with an investment
      const projectId = await fundraise.projectCount();
      await createProject();

      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await invest(projectId, investmentAmount);

      const currentProject = await fundraise.projects(projectId);
      log("🔍 Project stage:", currentProject.innerStruct.stage.toString());

      // 2% instead of the project's 3%
      const updatedProject = cloneProject(currentProject, {
        innerStruct: { platformInterestRate: parseUnits("2", 4) },
      });

      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWithCustomError(fundraise, "WrongPercents");
    });

    it("🚫 Cannot decrease investor interest rate", async () => {
      // Create a project and move it to Open stage with an investment
      const projectId = await fundraise.projectCount();
      await createProject();

      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await invest(projectId, investmentAmount);

      const currentProject = await fundraise.projects(projectId);
      log("🔍 Project stage:", currentProject.innerStruct.stage.toString());

      // 1% instead of the project's 20%
      const updatedProject = cloneProject(currentProject, {
        investorInterestRate: parseUnits("1", 4),
      });

      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWithCustomError(fundraise, "WrongPercents");
    });


    // ========================================
    // 🔥 TOKEN BURNING TESTS
    // ========================================

    it("🔥 Buy-back and burn on project activation keeps totalSupply flat", async function () {
      const burnTestProjectId = await fundraise.projectCount();
      await createProject();

      const burnTestInvestmentAmount = ethers.parseUnits("20000", 6);
      await usdcToken.mint(investor.address, burnTestInvestmentAmount);
      await invest(burnTestProjectId, burnTestInvestmentAmount);

      // _mintRewards mints this many reward tokens, then buys the same number off the pool and
      // burns them. Read it before activation, since activation is what consumes it.
      const tokensForMint = await rewardSystem.rewardTokensAmount(burnTestProjectId);
      expect(tokensForMint).to.be.greaterThan(0);
      expect(await rewardSystem.burnPercentage()).to.be.greaterThan(0);

      const rewardSystemAddr = await rewardSystem.getAddress();
      const supplyBefore = await token.totalSupply();
      const poolTokensBefore = await token.balanceOf(poolAddress);
      const poolUsdcBefore = await usdcToken.balanceOf(poolAddress);
      const rsUsdcBefore = await usdcToken.balanceOf(rewardSystemAddr);
      const rsTokensBefore = await token.balanceOf(rewardSystemAddr);

      // Reaching Funded activates the project's rewards, which is what runs the buy-back
      await fundraise.connect(manager).transferFundsToBorrower(burnTestProjectId);

      // The mint and the burn are deliberately paired, so supply does not move at all
      expect(await token.totalSupply()).to.equal(supplyBefore);

      // The burnt tokens come out of the pool, paid for with the RewardSystem's own USDC
      const poolTokensAfter = await token.balanceOf(poolAddress);
      expect(poolTokensAfter).to.equal(poolTokensBefore - tokensForMint);

      const usdcSpent = rsUsdcBefore - (await usdcToken.balanceOf(rewardSystemAddr));
      expect(usdcSpent).to.be.greaterThan(0);
      expect(await usdcToken.balanceOf(poolAddress)).to.equal(poolUsdcBefore + usdcSpent);

      // What stays behind is the minted rewards; the bought-back tokens are the ones burnt
      expect(await token.balanceOf(rewardSystemAddr)).to.equal(rsTokensBefore + tokensForMint);

      log("🪙 TOKENS MINTED AND BOUGHT BACK", formatEther(tokensForMint));
      log("💵 USDC SPENT ON BUY-BACK", formatUnits(usdcSpent, 6));
      await trackBalances("Buy-back and burn on project activation");
    });

    it("Add the vesting project and invest 1000", async () => {
      vestingProjectId = await fundraise.projectCount();
      await createProject("1000", "1000");

      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await invest(vestingProjectId, investmentAmount);
      await fundraise.connect(manager).transferFundsToBorrower(vestingProjectId);

      vestingTotalTokens = (
        await rewardSystem.getVestingInfoForProject(await investor.getAddress(), vestingProjectId)
      ).totalAmount;
      expect(vestingTotalTokens).to.be.greaterThan(0);

      await trackBalances("Added project 1 and invested 1000");
    });


    // ========================================
    // 🎁 ADDITIONAL UNLOCK TESTS
    // ========================================

    it("available for claim 2.5%", async () => {
      const projectId = vestingProjectId;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(vestingTotalTokens * 250n / 10000n);
    });

    it("Check investor vesting project info", async () => {
      const projectId = vestingProjectId;
      const investorVestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      log("🎯 INVESTOR TOTAL TOKENS", formatEther(investorVestingInfo.totalAmount));
      log("✅ INVESTOR CLAIMED", formatEther(investorVestingInfo.claimedAmount));
      log("💰 INVESTOR CLAIMABLE", formatEther(investorVestingInfo.claimableAmount));
      log("📊 TOTAL AT ACTIVATION", formatEther(vestingTotalTokens));
      
      expect(investorVestingInfo.totalAmount).to.equal(vestingTotalTokens);
    });

    it("Inviter accrues referral USDC, not vesting tokens", async () => {
      const inviterAddr = await inviter.getAddress();
      const rewards = await rewardSystem.getProjectRewards(inviterAddr, vestingProjectId);
      const vesting = await rewardSystem.getVestingInfoForProject(inviterAddr, vestingProjectId);

      // recordInvestment credits totalRewardsUSDC to the inviter and totalRewardsTokens to the
      // investor, so the inviter's vesting total stays at zero however much they invite.
      expect(rewards.totalUSDC).to.be.greaterThan(0);
      expect(vesting.totalAmount).to.equal(0);

      log("💵 INVITER REFERRAL USDC", formatUnits(rewards.totalUSDC, 6));
    });

    it("RewardSystem holds enough tokens to cover the vesting project", async () => {
      const totalTokens = await token.balanceOf(await rewardSystem.getAddress());
      const vesting = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), vestingProjectId);
      const unclaimed = vesting.totalAmount - vesting.claimedAmount;

      log("💼 REWARD SYSTEM BALANCE", formatEther(totalTokens));
      log("🎯 VESTING PROJECT UNCLAIMED", formatEther(unclaimed));

      // A solvency check, not an equality: the balance also covers the other projects' rewards.
      // Equality only held while this was the only project with rewards outstanding.
      expect(unclaimed).to.be.greaterThan(0);
      expect(totalTokens).to.be.greaterThanOrEqual(unclaimed);
    });

    it("claim 2.5%", async () => {
      const projectId = vestingProjectId;
      const balanceBefore = await token.balanceOf(await investor.getAddress());
      await rewardSystem.connect(investor).claimTokensForProject(projectId);
      const balanceAfter = await token.balanceOf(await investor.getAddress());
      expect(balanceAfter).to.equal(balanceBefore + vestingTotalTokens * 250n / 10000n);
      await trackBalances("Claimed 2.5%");
    });

    it("available for claim 0% after claim", async () => {
      const projectId = vestingProjectId;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("🎁 Set additional unlock to 26%", async () => {
      const additionalUnlock = 260000; // 26% in BASIS_POINTS
      await rewardSystem.connect(manager).setAdditionalUnlock(additionalUnlock);
      const currentAdditionalUnlock = await rewardSystem.additionalUnlockPercentage();
      expect(currentAdditionalUnlock).to.equal(additionalUnlock);
      log("📊 ADDITIONAL UNLOCK SET TO", Number(currentAdditionalUnlock) / 10000, "%");
    });


    it("claim additional unlock 26% and sell", async () => {
      const projectId = vestingProjectId;
      const balanceBefore = await token.balanceOf(await investor.getAddress());
      const usdcBalanceBefore = await usdcToken.balanceOf(await investor.getAddress());

      const claimableAmount = vestingTotalTokens * 2600n / 10000n;
      
      const amountsOut = await router.getAmountsOut(claimableAmount, [await token.getAddress(), await usdcToken.getAddress()]);
      const minUsdcAmount = await rewardSystem.getClaimAndSellAmounts(await investor.getAddress(), [projectId]);
      await rewardSystem.connect(investor).claimAndSellTokensForProjectBatch([projectId], minUsdcAmount.minUsdcAmount);


      const balanceAfter = await token.balanceOf(await investor.getAddress());
      const usdcBalanceAfter = await usdcToken.balanceOf(await investor.getAddress());
      expect(usdcBalanceAfter).to.be.equals(usdcBalanceBefore + amountsOut[1]);
      expect(balanceAfter).to.be.equals(balanceBefore);
      await trackBalances("Claimed additional unlock 26% and sold");
    });

    it("available for claim 0% after claim and sell", async () => {
      const projectId = vestingProjectId;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("set additional unlock to 0%", async () => {
      await rewardSystem.connect(manager).setAdditionalUnlock(0);
      const currentAdditionalUnlock = await rewardSystem.additionalUnlockPercentage();
      expect(currentAdditionalUnlock).to.equal(0);
      log("📊 ADDITIONAL UNLOCK SET TO", Number(currentAdditionalUnlock) / 10000, "%");
    });

    it("available for claim 0% after set additional unlock to 0%", async () => {
      const projectId = vestingProjectId;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("skip 1 week and claim 2.5%", async () => {
      const projectId = vestingProjectId;
      await time.increase(7 * 24 * 3600);

      // Another week unlocks another 2.5%. Compared with a few wei of slack, because the contract
      // truncates per claim, so the running total drifts from one 250/10000 of the whole.
      const before = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(before.claimableAmount).to.be.closeTo(vestingTotalTokens * 250n / 10000n, 10n);

      // The transfer itself must match what the contract reported, to the wei
      const balanceBefore = await token.balanceOf(await investor.getAddress());
      await rewardSystem.connect(investor).claimTokensForProject(projectId);
      const balanceAfter = await token.balanceOf(await investor.getAddress());
      expect(balanceAfter).to.equal(balanceBefore + before.claimableAmount);
      await trackBalances("1w, claim 2.5%");
    });

    it("skip week, set additional unlock to 50% and claim 52.5%", async () => {
      await time.increase(7 * 24 * 3600);
      const projectId = vestingProjectId;
      await rewardSystem.connect(manager).setAdditionalUnlock(500000);
      const usdcBalanceBefore = await usdcToken.balanceOf(await investor.getAddress());
      await rewardSystem.connect(investor).claimTokensForProject(projectId);
      const balanceAfter = await token.balanceOf(await investor.getAddress());

      const claimedTotal= vestingTotalTokens * (250n + 250n + 250n) / 10000n;
      const usdcBalanceAfter = await usdcToken.balanceOf(await investor.getAddress());
      await trackBalances("1w, unlock to 50%, claim 5.5%");
      expect(usdcBalanceAfter).to.be.equals(usdcBalanceBefore);
      expect(balanceAfter).to.be.equals(claimedTotal);
    });

    it("skip 20 weeks, sell remaining with 50% bonus", async () => {
      const projectId = vestingProjectId;

      // Skip to week 22

      // Sell with additional unlock 50% (updates userMaxAdditionalUnlockUsed to 50%)
      // Available: 55% (vesting) + 50% (additional) = 105% → cap at 100%
      // Already claimed: 33.5%
      // Will sell: 100% - 33.5% = 66.5%
      const minUsdcAmount = await rewardSystem.getClaimAndSellAmounts(await investor.getAddress(), [projectId]);
      await rewardSystem.connect(investor).claimAndSellTokensForProjectBatch([projectId], minUsdcAmount.minUsdcAmount);

      await trackBalances("Sell remaining with 50% bonus");
      
      // Skip to end of vesting (week 42)
      await time.increase(20 * 7 * 24 * 3600);

      // Claim any remaining tokens (should be 0 if all was sold)
      await rewardSystem.connect(investor).claimTokensForProjectBatch([projectId]);

      await trackBalances("20w skip, claim remaining tokens");

      
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
      expect(vestingInfo.totalAmount).to.equal(vestingTotalTokens);
      expect(vestingInfo.claimedAmount).to.equal(vestingTotalTokens);

      const balance = await token.balanceOf(await investor.getAddress());
      
      // On balance: 2.5% + 2.5% + 2.5% = 7.5%
      // Sold: 26% + 66.5% = 92.5%
      // Total: 100%
      
      
      log("🪙 INVESTOR BALANCE", formatEther(balance));
      log("🎯 EXPECTED ~50%", formatEther(vestingInfo.totalAmount / 2n));
      
      
      expect(balance).to.be.equals(vestingInfo.totalAmount / 2n);
    });

    it("available for claim 0% after skip week, set additional unlock to 50% and claim 52.5%", async () => {
      const projectId = vestingProjectId;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("try claim - should fail", async () => {
      const projectId = vestingProjectId;
      await time.increase(20 * 7 * 24 * 3600);

      await expect(rewardSystem.connect(investor).claimTokensForProject(projectId)).to.be.revertedWith("No tokens to claim");

      const balanceUsdcBefore = await usdcToken.balanceOf(await investor.getAddress());
      const minUsdcAmount = await rewardSystem.getClaimAndSellAmounts(await investor.getAddress(), [projectId]);
      await rewardSystem.connect(investor).claimAndSellTokensForProjectBatch([projectId], minUsdcAmount.minUsdcAmount);
      const balanceUsdcAfter = await usdcToken.balanceOf(await investor.getAddress());
      expect(balanceUsdcAfter).to.be.equals(balanceUsdcBefore);

    });

    it("investor sell all tokens with uniswap router", async () => {
      const balanceBefore = await token.balanceOf(await investor.getAddress());
      await token.connect(investor).approve(await router.getAddress(), balanceBefore);
      await router.connect(investor).swapExactTokensForTokens(balanceBefore, 0, [await token.getAddress(), await usdcToken.getAddress()], await investor.getAddress(), await time.latest() + 1000);
      const balanceAfter = await token.balanceOf(await investor.getAddress());
      expect(balanceAfter).to.be.equals(0);
      await trackBalances("Investor sold all tokens (2)");
    });


    it("🔥 Buy-back holds at different investment sizes", async function () {
      // Runs the whole cycle twice at a 5x ratio, in one test, so the comparison does not depend
      // on what other tests left behind.
      const fundAndActivate = async (softCap: string, hardCap: string, amount: string) => {
        const projectId = await fundraise.projectCount();
        await createProject(softCap, hardCap);

        const investment = ethers.parseUnits(amount, 6);
        await usdcToken.mint(investor.address, investment);
        await invest(projectId, investment);

        // The buy-back is paid out of the RewardSystem's own USDC, so it has to be topped up or
        // activation reverts with "Not enough USDC to buy tokens". Same as the funding test above.
        await usdcToken.mint(await rewardSystem.getAddress(), investment);

        const tokensForMint = await rewardSystem.rewardTokensAmount(projectId);
        const supplyBefore = await token.totalSupply();
        const poolTokensBefore = await token.balanceOf(poolAddress);

        await fundraise.connect(manager).transferFundsToBorrower(projectId);

        const poolDrop = poolTokensBefore - (await token.balanceOf(poolAddress));
        return { tokensForMint, poolDrop, supplyBefore, supplyAfter: await token.totalSupply() };
      };

      const small = await fundAndActivate("20000", "40000", "20000");
      const large = await fundAndActivate("100000", "200000", "100000");

      for (const run of [small, large]) {
        // The invariant is size-independent: supply flat, and the buy-back takes exactly what
        // was minted out of the pool.
        expect(run.supplyAfter).to.equal(run.supplyBefore);
        expect(run.poolDrop).to.equal(run.tokensForMint);
        expect(run.tokensForMint).to.be.greaterThan(0);
      }

      // A bigger investment buys back more. Not asserted as exactly 5x: the reward is linear in
      // USDC, but converting it to tokens uses the price, and the first buy-back moved the pool.
      expect(large.tokensForMint).to.be.greaterThan(small.tokensForMint);

      log("🪙 SMALL RUN TOKENS", formatEther(small.tokensForMint));
      log("🪙 LARGE RUN TOKENS", formatEther(large.tokensForMint));
      await trackBalances("Buy-back at different investment sizes");
    });
  });
});

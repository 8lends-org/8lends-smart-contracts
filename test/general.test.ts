import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { deployContracts } from "./helpers";
import { 
  ManagerRegistry,
  Treasury,
  Fundraise,
  MockERC20,
  Token,
  RewardSystem,
  IUniswapV2Router02,
  IUniswapV2Pair,
} from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { Stage } from "../scripts/helpers";
import { formatEther, formatUnits, parseEther, parseUnits, Wallet } from "ethers";

import { BalanceTable, BalanceEntry } from "./balance-table";





describe("🚀 8lends Protocol - General Flow Tests", function () {
  // 🔧 Configuration
  const LOGGING_ADDITIONALS = true; // Set to true to enable detailed logging and balance tracking
  const TRACE_BALANCES = true; // Set to true to enable detailed logging and balance tracking

  // 📊 Balance tracking storage
  const balanceTable = new BalanceTable();
  // 👥 Actors
  let owner: HardhatEthersSigner;
  let superManager: HardhatEthersSigner;
  let manager: HardhatEthersSigner;
  let borrower: HardhatEthersSigner;
  let investor: HardhatEthersSigner;
  let backend: HardhatEthersSigner;
  let inviter: HardhatEthersSigner;

  // 📋 Contracts
  let rewardSystem: RewardSystem;
  let usdcToken: MockERC20;
  let token: Token;
  let managerRegistry: ManagerRegistry;
  let treasury: Treasury;
  let fundraise: Fundraise;
  let router: IUniswapV2Router02;
  let poolAddress: string;

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
  /**
   * Conditional logging function - only logs when LOGGING_ADDITIONALS is true
   * @param message - Log message
   * @param args - Additional arguments to log
   */
  function log(message: string, ...args: any[]) {
    if (LOGGING_ADDITIONALS) {
      console.log(message, ...args);
    }
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

    await fundraise.connect(investor).investUpdate(projectId, amount, nonceForSignature1, signature1, inviter);
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
    log("                   📋 CREATE PROJECT");
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

    it("🚀 Deploy contracts and setup", async function () {
      // Clear balance history for fresh start
      clearBalanceHistory();
      
      // Deploy base contracts
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

      // Mint USDC for testing
      // await usdcToken.mint(investor.address, ethers.parseUnits("10000", 6)); // 10k USDC    
      project = await createProject();
      await trackBalances("Created project");
    });

    // 📊 Test Variables
    let softCap: bigint;

    it("💵 Mint USDC for testing", async function () {
      softCap = project.softCap;
      await usdcToken.mint(investor.address, softCap); // 10k USDC    
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), softCap);
      await trackBalances("Minted USDC");
    });

    it("Send USDC to reward system", async function () {
      const amount = 10000;
      await usdcToken.mint(await rewardSystem.getAddress(), amount * 1e6);
      const balanceOfRewardSystem = await usdcToken.balanceOf(await rewardSystem.getAddress());
      log("                   💵 BALANCE OF REWARD SYSTEM", formatUnits(balanceOfRewardSystem, 6));
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

        await fundraise.connect(investor).investUpdate(0, softCap/2n, nonceForSignature1, signature1, inviter);

        // Create signature for second investment
        const currentNonce2 = await fundraise.userNonces(await investor.getAddress());
        const nonceForSignature2 = currentNonce2 + 1n;
        const messageHash2 = ethers.solidityPackedKeccak256(
          ["address", "uint256", "uint256", "uint256", "address"],
          [await investor.getAddress(), 0, softCap/2n, nonceForSignature2, await inviter.getAddress()]
        );
        const signature2 = await backend.signMessage(ethers.getBytes(messageHash2));

        await fundraise.connect(investor).investUpdate(0, softCap/2n, nonceForSignature2, signature2, inviter);
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
      log("                   💰 PLATFORM FEE", formatUnits(platformFee, 6));
      log("                   📊 SOFT CAP", formatUnits(softCap, 6));
      log("                   💵 TOTAL INVESTED", formatUnits(project.totalInvested, 6));
        const balanceOfBorrower = await usdcToken.balanceOf(await borrower.getAddress());
        expect(balanceOfBorrower).to.equal(softCap - platformFee);
        await trackBalances("Sent funds to borrower");
    });




    it("✅ Rewards should be activated after Stage.Funded", async function () {
      const projectRewards = await rewardSystem.getProjectRewards(await investor.getAddress(), 0);
      log("                   🎯 PROJECT REWARDS IS ACTIVATED", projectRewards.isActivated);
      log("                   💵 PROJECT REWARDS TOTAL USDC", formatUnits(projectRewards.totalUSDC, 6));
      log("                   🪙 PROJECT REWARDS TOTAL TOKENS", formatEther(projectRewards.totalTokens));
      expect(projectRewards.isActivated).to.be.true;
    });

    it(`🏦 Treasury balance should be ${formatUnits(PLATFORM_PERCENT, 4)}% of investment`, async function () {
      const balanceOfTreasury = await usdcToken.balanceOf(await treasury.getAddress());
      const burnedUSDC = (await rewardSystem.burnPercentage()) * project.totalInvested / await fundraise.BASIS_POINTS();
      log("                   💰 BALANCE OF TREASURY", formatUnits(balanceOfTreasury, 6));
      log("                   📊 PROJECT INVESTED", formatUnits(project.totalInvested, 6));
      log("                   📈 PLATFORM PERCENT", formatUnits(PLATFORM_PERCENT, 4));
      log("                   🔥 BURNED USDC", formatUnits(burnedUSDC, 6));
      log("                   💵 EXPECTED BALANCE OF TREASURY", formatUnits(project.totalInvested * PLATFORM_PERCENT / await fundraise.BASIS_POINTS(), 6));

      expect(balanceOfTreasury).to.equal(project.totalInvested * PLATFORM_PERCENT / await fundraise.BASIS_POINTS());
    });



    it("🎁 Claim USDC rewards by investor", async function () {
      const projectRewards = await rewardSystem.getProjectRewards(await investor.getAddress(), 0);
      const initialBalance = await usdcToken.balanceOf(await investor.getAddress());


      const balanceOfRewardSystem = await usdcToken.balanceOf(await rewardSystem.getAddress());
      log("                   💵 BALANCE OF REWARD SYSTEM", formatUnits(balanceOfRewardSystem, 6));

      log("                   💵 PROJECT REWARDS TOTAL USDC", formatUnits(projectRewards.totalUSDC, 6));
      log("                   🪙 PROJECT REWARDS TOTAL TOKENS", formatEther(projectRewards.totalTokens));

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

      log("                   💵 PROJECT REWARDS TOTAL USDC", formatUnits(projectRewards.totalUSDC, 6));
      log("                   👤 INVITER BALANCE", formatUnits(initialBalance, 6));
      
      await rewardSystem.connect(inviter).claimUSDCForProject(0);
      
      const finalBalance = await usdcToken.balanceOf(await inviter.getAddress());
      log("                   👤 INVITER BALANCE AFTER", formatUnits(finalBalance, 6));

      expect(finalBalance - initialBalance).to.equal(projectRewards.totalUSDC);
      const balanceOfRewardSystemAfter = await usdcToken.balanceOf(await rewardSystem.getAddress());
      expect(balanceOfRewardSystemAfter).to.equal(balanceOfRewardSystem - projectRewards.totalUSDC);
      log("                   🏦 BALANCE OF TREASURY AFTER", formatUnits(balanceOfRewardSystemAfter, 6));
      await trackBalances("Inviter claimed USDC rewards");
    });


    it("✅ Inviter USDC rewards (already claimed)", async() => {
      const projectRewards = await rewardSystem.getProjectRewards(await inviter.getAddress(), 0);
      // Inviter already claimed their rewards, so totalUSDC = 0
      expect(projectRewards.totalUSDC).to.equal(0);
    });

    it("🪙 Investor token rewards (6% tokens)", async() => {
      const tokenPercentage = await rewardSystem.tokenPercentage();
      log("                   📊 TOKEN PERCENTAGE", tokenPercentage);
      const investorInfo = await fundraise.investorInfo(await investor.getAddress(), 0);
      const investorInvestedAmount = investorInfo.investedAmount;
      log("                   💵 INVESTOR INVESTED USDC", formatUnits(investorInvestedAmount, 6));
      // investor vesting total amount
      const investorVestingTotalAmount = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 0);
      log("                   🪙 INVESTOR VESTING TOKEN TOTAL AMOUNT", formatEther(investorVestingTotalAmount.totalAmount));
      log("                   ✅ INVESTOR VESTING TOKEN CLAIMED AMOUNT", formatEther(investorVestingTotalAmount.claimedAmount));
      log("                   🎯 INVESTOR VESTING TOKEN CLAIMABLE AMOUNT", formatEther(investorVestingTotalAmount.claimableAmount));
      log("                   ⏰ INVESTOR VESTING TOKEN START TIME", new Date(Number(investorVestingTotalAmount.startTime) * 1000).toLocaleString());
      log("                   🔥 INVESTOR VESTING TOKEN IS ACTIVE", investorVestingTotalAmount.isActive);
      expect(investorVestingTotalAmount.totalAmount).to.be.greaterThanOrEqual(investorInvestedAmount * tokenPercentage / 100n);
    });

    it("⏰ Skip 1 week and check claimable amount", async() => {
      const BASIS_POINTS = await rewardSystem.BASIS_POINTS();
      await time.increase(7 * 24 * 3600);
      const investorInfo = await fundraise.investorInfo(await investor.getAddress(), 0);
      const investorInvestedAmount = investorInfo.investedAmount;
      const tokenPercentage = await rewardSystem.tokenPercentage();

      const investorVestingTotalAmount = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 0);
      log("                   🪙 INVESTOR VESTING TOKEN TOTAL AMOUNT", formatEther(investorVestingTotalAmount.totalAmount));
      log("                   ✅ INVESTOR VESTING TOKEN CLAIMED AMOUNT", formatEther(investorVestingTotalAmount.claimedAmount));
      log("                   🎯 INVESTOR VESTING TOKEN CLAIMABLE AMOUNT", formatEther(investorVestingTotalAmount.claimableAmount));

      // weekly correct amount
      const weeklyUnlock = await rewardSystem.weeklyUnlock(); //25
      log("                   📊 WEEKLY UNLOCK", formatUnits(weeklyUnlock,1));
      log("                   💵 INVESTOR INVESTED USDC", formatUnits(investorInvestedAmount, 6));
      log("                   📈 TOKEN PERCENTAGE", tokenPercentage/BASIS_POINTS * 100n);

      const _expectedClaimableAmount = investorVestingTotalAmount.totalAmount * weeklyUnlock * 2n / BASIS_POINTS;
      log("                   🎯 EXPECTED CLAIMABLE AMOUNT", formatEther(_expectedClaimableAmount));
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
      log("                   🪙 INVESTOR TOKEN BALANCE", formatEther(balance));
      expect(claimableAmount).to.be.eq(0);
    });

    it("🚫 Try to claim tokens again (should fail)", async () => {
      await expect(rewardSystem.connect(investor).claimTokensForProject(0)).to.be.revertedWith("No tokens to claim");
    });

    it("💱 Sell claimed tokens on DEX", async () => {
      let balanceTokens = await token.balanceOf(await investor.getAddress());
      await token.connect(investor).approve(await router.getAddress(), balanceTokens);
      let balanceUsdt = await usdcToken.balanceOf(await investor.getAddress());
      log("                   💵 INVESTOR USDC BALANCE", formatUnits(balanceUsdt, 6));

      log("                   🪙 INVESTOR TOKENS BALANCE", formatEther(balanceTokens));
      await router.connect(investor).swapExactTokensForTokens(balanceTokens, 0, [await token.getAddress(), await usdcToken.getAddress()], await investor.getAddress(), await time.latest() + 1000);

      const balanceUsdtAfterSwap = await usdcToken.balanceOf(await investor.getAddress());
      log("                   💵 INVESTOR USDC BALANCE AFTER SWAP", formatUnits(balanceUsdt, 6));
      log("                   📈 INVESTOR INCREMENTED USDC", formatUnits(balanceUsdtAfterSwap - balanceUsdt, 6));
      balanceTokens = await token.balanceOf(await investor.getAddress());
      log("                   🪙 INVESTOR TOKENS BALANCE AFTER SWAP", formatEther(balanceTokens));
      await trackBalances("Sold claimed tokens on DEX");
    });

    it("💱 Check token price on DEX", async () => {
      const usdcAmount = 100;
      const tokenPrice = await router.getAmountsOut(ethers.parseUnits(usdcAmount.toString(), 6), [await usdcToken.getAddress(), await token.getAddress()]);
      log("                   💰 TOKEN PRICE", usdcAmount/Number(formatEther(tokenPrice[1])));
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
      log("                   🪙 INVITER TOKENS BALANCE", formatEther(inviterBalanceTokens));
      log("                   💵 INVITER USDC BALANCE AFTER SWAP", formatUnits(inviterBalanceUSDTAfterSwap, 6));
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
      log("                   💵 INVITER USDC BALANCE", formatUnits(inviterBalanceUSDT, 6));
      log("                   🪙 INVITER TOKENS BALANCE", formatEther(inviterBalanceTokens));
     
      await token.connect(inviter).approve(await router.getAddress(), inviterBalanceTokens);
      await router.connect(inviter).swapExactTokensForTokens(inviterBalanceTokens, 0, [await token.getAddress(), await usdcToken.getAddress()], await inviter.getAddress(), await time.latest() + 1000);
     
      const inviterBalanceUSDTAfterSwap = await usdcToken.balanceOf(await inviter.getAddress());
      const inviterBalanceTokensAfterSwap = await token.balanceOf(await inviter.getAddress());

      log("                   💵 INVITER USDC BALANCE AFTER SWAP", formatUnits(inviterBalanceUSDTAfterSwap, 6));
      log("                   🪙 INVITER TOKENS BALANCE AFTER SWAP", formatEther(inviterBalanceTokensAfterSwap));
      expect(inviterBalanceUSDTAfterSwap).to.be.greaterThan(inviterBalanceUSDT);
      expect(inviterBalanceTokensAfterSwap).to.be.eq(0);
      await trackBalances("Inviter can sell their tokens");
    });

    it.skip("❌ Test project cancellation - rewards remain pending", async function () {
      // Create second project
      const projectData2 = {
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
          stage: 0
        }
      };

      const projectId2 = await fundraise.projectCount();
      await fundraise.connect(manager).createProject(projectData2, 2);

      // Invest in project
      await usdcToken.mint(investor.address, ethers.parseUnits("5000", 6));
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), ethers.parseUnits("5000", 6));

      // Create signature for investment
      const currentNonce2 = await fundraise.userNonces(await investor.getAddress());
      const nonceForSignature2 = currentNonce2 + 1n;
      const messageHash2 = ethers.solidityPackedKeccak256(
        ["address", "uint256", "uint256", "uint256", "address"],
        [await investor.getAddress(), projectId2, ethers.parseUnits("5000", 6), nonceForSignature2, await inviter.getAddress()]
      );
      const signature2 = await backend.signMessage(ethers.getBytes(messageHash2));

      await fundraise.connect(investor).investUpdate(projectId2, ethers.parseUnits("5000", 6), nonceForSignature2, signature2, inviter);
      
      // Cancel project
      await fundraise.connect(manager).cancelProject(projectId2);
      
      // Check that rewards exist but are not activated
      const projectRewards = await rewardSystem.getProjectRewards(await investor.getAddress(), projectId2);
      log("                   💵 PROJECT 2 REWARDS USDC", formatUnits(projectRewards.totalUSDC, 6));
      log("                   🪙 PROJECT 2 REWARDS TOKENS", formatEther(projectRewards.totalTokens));
      log("                   🎯 PROJECT 2 IS ACTIVATED", projectRewards.isActivated);
      // USDC rewards may be 0 if investor already claimed them, but token rewards should be present
      expect(projectRewards.totalTokens).to.be.greaterThan(0);
      expect(projectRewards.isActivated).to.be.false;
      
      // Cannot claim rewards from canceled project
      await expect(rewardSystem.connect(investor).claimUSDCForProject(projectId2))
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
      log("                   📊 PROJECT STAGE" , project.innerStruct.stage);
      log("                   💵 PROJECT TOTAL REPAID" , formatUnits(project.innerStruct.totalRepaid, 6));
      log("                   ⏰ PROJECT FUNDED TIME" , new Date(Number(project.innerStruct.fundedTime) * 1000).toLocaleString());
      log("                   💰 PROJECT TOTAL INVESTED" , formatUnits(project.totalInvested, 6));
      log("                   📈 PROJECT INVESTOR INTEREST" , formatUnits(investorInterest, 6));
      log("                   💸 PROJECT TOTAL REPAYMENT AMOUNT" , formatUnits(totalRepaymentAmount, 6));
    
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
      log("                   🪙 INVESTOR TOKEN BALANCE", formatEther(balance));
      log("                   📊 INVESTOR TOKEN TOTAL AMOUNT", formatEther(totalAmount));
      log("                   ✅ INVESTOR TOKEN CLAIMED AMOUNT", formatEther(claimedAmount));
      log("                   🎯 INVESTOR TOKEN CLAIMABLE AMOUNT", formatEther(claimableAmount));

      // subtract 2.5% from totalAmount that was already claimed earlier
      const totalAmountMinus25 = totalAmount - (totalAmount * 2n * 25n / 1000n);
      expect(balance).to.be.eq(totalAmountMinus25); 
      expect(claimedAmount).to.be.eq(totalAmount);
      expect(claimableAmount).to.be.eq(0);
      await trackBalances("after 40 weeks investor claimed all tokens");
    });

    it("Ivester sold all tokens", async () => {
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
      const projectId = await fundraise.projectCount();
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
      
      log("🔍 Current project data:", {
        hardCap: currentProject.hardCap.toString(),
        softCap: currentProject.softCap.toString(),
        totalInvested: currentProject.totalInvested.toString(),
        startAt: currentProject.startAt.toString(),
        preFundDuration: currentProject.preFundDuration.toString(),
        investorInterestRate: currentProject.investorInterestRate.toString(),
        openStageEndAt: currentProject.openStageEndAt.toString(),
        innerStruct: {
          platformInterestRate: currentProject.innerStruct.platformInterestRate.toString(),
          totalRepaid: currentProject.innerStruct.totalRepaid.toString(),
          borrower: currentProject.innerStruct.borrower,
          fundedTime: currentProject.innerStruct.fundedTime.toString(),
          loanToken: currentProject.innerStruct.loanToken,
          stage: currentProject.innerStruct.stage.toString()
        }
      });
      
      // Create deep copy of object
      const updatedProject = {
        hardCap: ethers.parseUnits("3000", 6),
        softCap: BigInt(currentProject.softCap.toString()),
        totalInvested: BigInt(currentProject.totalInvested.toString()),
        startAt: BigInt(currentProject.startAt.toString()),
        preFundDuration: BigInt(currentProject.preFundDuration.toString()),
        investorInterestRate: BigInt(currentProject.investorInterestRate.toString()),
        openStageEndAt: BigInt(currentProject.openStageEndAt.toString()),
        innerStruct: {
          platformInterestRate: BigInt(currentProject.innerStruct.platformInterestRate.toString()),
          totalRepaid: BigInt(currentProject.innerStruct.totalRepaid.toString()),
          borrower: currentProject.innerStruct.borrower,
          fundedTime: BigInt(currentProject.innerStruct.fundedTime.toString()),
          loanToken: currentProject.innerStruct.loanToken,
          stage: Number(currentProject.innerStruct.stage.toString())
        }
      };
      
      log("🔍 Updated project data:", updatedProject);
      
      await expect(fundraise.connect(investor).setProject(projectId, updatedProject))
        .to.be.revertedWith("Not a manager");
    });

    it.skip("🚫 Cannot update funded project", async () => {
      const projectId = 0; // Use first project, which is already funded
      const currentProject = await fundraise.projects(projectId);
      
      log("🔍 Funded project stage:", currentProject.innerStruct.stage.toString());
      
      const updatedProject = {
        hardCap: ethers.parseUnits("3000", 6),
        softCap: BigInt(currentProject.softCap.toString()),
        totalInvested: BigInt(currentProject.totalInvested.toString()),
        startAt: BigInt(currentProject.startAt.toString()),
        preFundDuration: BigInt(currentProject.preFundDuration.toString()),
        investorInterestRate: BigInt(currentProject.investorInterestRate.toString()),
        openStageEndAt: BigInt(currentProject.openStageEndAt.toString()),
        innerStruct: {
          platformInterestRate: BigInt(currentProject.innerStruct.platformInterestRate.toString()),
          totalRepaid: BigInt(currentProject.innerStruct.totalRepaid.toString()),
          borrower: currentProject.innerStruct.borrower,
          fundedTime: BigInt(currentProject.innerStruct.fundedTime.toString()),
          loanToken: currentProject.innerStruct.loanToken,
          stage: Number(currentProject.innerStruct.stage.toString())
        }
      };
      
      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWith("Can't update funded project");
    });

    it.skip("🚫 Cannot extend openStageEndAt more than 30 days", async () => {
      // Create new project and move it to Open stage
      const projectId = await fundraise.projectCount();
      await createProject();
      
      // Make investment to move project to Open stage
      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), investmentAmount);
      
      // Create signature for investment
      const currentNonce = await fundraise.userNonces(await investor.getAddress());
      const nonceForSignature = currentNonce + 1n;
      const messageHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "uint256", "uint256", "address"],
        [await investor.getAddress(), projectId, investmentAmount, nonceForSignature, inviter]
      );
      const signature = await backend.signMessage(ethers.getBytes(messageHash));

      await fundraise.connect(investor).investUpdate(projectId, investmentAmount, nonceForSignature, signature, inviter);
      
      const currentProject = await fundraise.projects(projectId);
      log("🔍 Project stage:", currentProject.innerStruct.stage.toString());
      
      log("🔍 Current openStageEndAt:", currentProject.openStageEndAt.toString());
      log("🔍 New openStageEndAt:", (BigInt(currentProject.openStageEndAt.toString()) + 32n * 86400n).toString());
      
      // Create object with same values but change only openStageEndAt
      const updatedProject = {
        hardCap: BigInt(currentProject.hardCap.toString()),
        softCap: BigInt(currentProject.softCap.toString()),
        totalInvested: BigInt(currentProject.totalInvested.toString()),
        startAt: BigInt(currentProject.startAt.toString()),
        preFundDuration: BigInt(currentProject.preFundDuration.toString()),
        investorInterestRate: BigInt(currentProject.investorInterestRate.toString()),
        openStageEndAt: BigInt(currentProject.openStageEndAt.toString()) + 32n * 86400n, // +32 days
        innerStruct: {
          platformInterestRate: BigInt(currentProject.innerStruct.platformInterestRate.toString()),
          totalRepaid: BigInt(currentProject.innerStruct.totalRepaid.toString()),
          borrower: currentProject.innerStruct.borrower,
          fundedTime: BigInt(currentProject.innerStruct.fundedTime.toString()),
          loanToken: currentProject.innerStruct.loanToken,
          stage: Number(currentProject.innerStruct.stage.toString())
        }
      };
      
      log("🔍 Difference in days:", ((BigInt(currentProject.openStageEndAt.toString()) + 32n * 86400n) - BigInt(currentProject.openStageEndAt.toString())) / 86400n);
      log("🔍 openStageEndAt changed:", updatedProject.openStageEndAt !== BigInt(currentProject.openStageEndAt.toString()));
      
      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWith("Too long");
    });

    it.skip("🚫 Cannot decrease platform interest rate", async () => {
      // Create new project and move it to Open stage
      const projectId = await fundraise.projectCount();
      await createProject();
      
      // Make investment to move project to Open stage
      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), investmentAmount);
      
      // Create signature for investment
      const currentNonce = await fundraise.userNonces(await investor.getAddress());
      const nonceForSignature = currentNonce + 1n;
      const messageHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "uint256", "uint256", "address"],
        [await investor.getAddress(), projectId, investmentAmount, nonceForSignature, inviter]
      );
      const signature = await backend.signMessage(ethers.getBytes(messageHash));

      await fundraise.connect(investor).investUpdate(projectId, investmentAmount, nonceForSignature, signature, inviter);
      
      const currentProject = await fundraise.projects(projectId);
      log("🔍 Project stage:", currentProject.innerStruct.stage.toString());
      
      log("🔍 Current platform interest rate:", currentProject.innerStruct.platformInterestRate.toString());
      log("🔍 New platform interest rate:", parseUnits("2", 4).toString());
      
      const updatedProject = {
        hardCap: BigInt(currentProject.hardCap.toString()),
        softCap: BigInt(currentProject.softCap.toString()),
        totalInvested: BigInt(currentProject.totalInvested.toString()),
        startAt: BigInt(currentProject.startAt.toString()),
        preFundDuration: BigInt(currentProject.preFundDuration.toString()),
        investorInterestRate: BigInt(currentProject.investorInterestRate.toString()),
        openStageEndAt: BigInt(currentProject.openStageEndAt.toString()),
        innerStruct: {
          platformInterestRate: parseUnits("2", 4), // 2% instead of 3%
          totalRepaid: BigInt(currentProject.innerStruct.totalRepaid.toString()),
          borrower: currentProject.innerStruct.borrower,
          fundedTime: BigInt(currentProject.innerStruct.fundedTime.toString()),
          loanToken: currentProject.innerStruct.loanToken,
          stage: Number(currentProject.innerStruct.stage.toString())
        }
      };
      
      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWith("Wrong percents");
    });

    it.skip("🚫 Cannot decrease investor interest rate", async () => {
      // Create new project and move it to Open stage
      const projectId = await fundraise.projectCount();
      await createProject();
      
      // Make investment to move project to Open stage
      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), investmentAmount);
      
      // Create signature for investment
      const currentNonce = await fundraise.userNonces(await investor.getAddress());
      const nonceForSignature = currentNonce + 1n;
      const messageHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "uint256", "uint256", "address"],
        [await investor.getAddress(), projectId, investmentAmount, nonceForSignature, inviter]
      );
      const signature = await backend.signMessage(ethers.getBytes(messageHash));

      await fundraise.connect(investor).investUpdate(projectId, investmentAmount, nonceForSignature, signature, inviter);
      
      const currentProject = await fundraise.projects(projectId);
      log("🔍 Project stage:", currentProject.innerStruct.stage.toString());
      
      log("🔍 Current investor interest rate:", currentProject.investorInterestRate.toString());
      log("🔍 New investor interest rate:", parseUnits("1", 4).toString());
      
      const updatedProject = {
        hardCap: BigInt(currentProject.hardCap.toString()),
        softCap: BigInt(currentProject.softCap.toString()),
        totalInvested: BigInt(currentProject.totalInvested.toString()),
        startAt: BigInt(currentProject.startAt.toString()),
        preFundDuration: BigInt(currentProject.preFundDuration.toString()),
          investorInterestRate: parseUnits("1", 4), // 1% instead of 1.5%
        openStageEndAt: BigInt(currentProject.openStageEndAt.toString()),
        innerStruct: {
          platformInterestRate: BigInt(currentProject.innerStruct.platformInterestRate.toString()),
          totalRepaid: BigInt(currentProject.innerStruct.totalRepaid.toString()),
          borrower: currentProject.innerStruct.borrower,
          fundedTime: BigInt(currentProject.innerStruct.fundedTime.toString()),
          loanToken: currentProject.innerStruct.loanToken,
          stage: Number(currentProject.innerStruct.stage.toString())
        }
      };
      
      await expect(fundraise.connect(manager).setProject(projectId, updatedProject))
        .to.be.revertedWith("Wrong percents");
    });


    // ========================================
    // 🔥 TOKEN BURNING TESTS
    // ========================================

    it.skip("🔥 Test token burning on project activation", async function () {
      // Create new project for burn test
      const burnTestProjectData = {
        softCap: ethers.parseUnits("20000", 6),
        hardCap: ethers.parseUnits("40000", 6),
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
          stage: 0
        }
      };

      const burnTestProjectId = await fundraise.projectCount();
      await fundraise.connect(manager).createProject(burnTestProjectData, 1);

      // Invest in project
      const burnTestInvestmentAmount = ethers.parseUnits("20000", 6);
      await usdcToken.mint(investor.address, burnTestInvestmentAmount);
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), burnTestInvestmentAmount);

      // Create signature for investment
      const burnTestCurrentNonce = await fundraise.userNonces(await investor.getAddress());
      const burnTestNonceForSignature = burnTestCurrentNonce + 1n;
      const burnTestMessageHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "uint256", "uint256", "address"],
        [await investor.getAddress(), burnTestProjectId, burnTestInvestmentAmount, burnTestNonceForSignature, inviter]
      );
      const burnTestSignature = await backend.signMessage(ethers.getBytes(burnTestMessageHash));

      await fundraise.connect(investor).investUpdate(burnTestProjectId, burnTestInvestmentAmount, burnTestNonceForSignature, burnTestSignature, inviter);
      
      // Get token balance before burning
      const totalSupplyBeforeBurn = await token.totalSupply();
      
      log("                   📊 TOTAL SUPPLY BEFORE BURN", formatEther(totalSupplyBeforeBurn));
      
      // Move project to Funded stage (this activates burning)
      await fundraise.connect(manager).transferFundsToBorrower(burnTestProjectId);
      
      // Get token balance after burning
      const totalSupplyAfterBurn = await token.totalSupply();
      
      log("                   📊 TOTAL SUPPLY AFTER BURN", formatEther(totalSupplyAfterBurn));
      
      // Check that tokens were burned
      const burnPercentage = await rewardSystem.burnPercentage();
      const expectedBurnAmount = (burnTestInvestmentAmount * burnPercentage) / await rewardSystem.BASIS_POINTS();
      
      // Get amount of tokens that should have been burned
      const path = [await usdcToken.getAddress(), await token.getAddress()];
      const amounts = await router.getAmountsOut(expectedBurnAmount, path);
      const expectedTokensBurned = amounts[1];
      
      log("                   💵 EXPECTED USDC TO BURN", formatUnits(expectedBurnAmount, 6));
      log("                   🪙 EXPECTED TOKENS TO BURN", formatEther(expectedTokensBurned));
      log("                   📉 ACTUAL SUPPLY REDUCTION", formatEther(totalSupplyBeforeBurn - totalSupplyAfterBurn));
      
      // Check that total supply decreased
      expect(totalSupplyAfterBurn).to.be.lessThan(totalSupplyBeforeBurn);
      await trackBalances("Test token burning on project activation");
    });

    it("Add project 1 and invest 1000", async () => {
      const projectId = 1;
      await createProject("1000", "1000");
      const investmentAmount = ethers.parseUnits("1000", 6);
      await usdcToken.mint(await investor.getAddress(), investmentAmount);
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), investmentAmount);

      
      const currentNonce = await fundraise.userNonces(await investor.getAddress());
      const nonceForSignature = currentNonce + 1n;
      const messageHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "uint256", "uint256", "address"],
        [await investor.getAddress(), projectId, investmentAmount, nonceForSignature, await inviter.getAddress()]
      );
      const signature = await backend.signMessage(ethers.getBytes(messageHash));

      await fundraise.connect(investor).investUpdate(projectId, investmentAmount, nonceForSignature, signature, await inviter.getAddress());
      await fundraise.connect(manager).transferFundsToBorrower(projectId);

      await trackBalances("Added project 1 and invested 1000");
    });


    // ========================================
    // 🎁 ADDITIONAL UNLOCK TESTS
    // ========================================

    // it("mint twap for reward system", async () => {
    //   const balanceBefore = await token.balanceOf(await rewardSystem.getAddress());
    //   const amount = parseEther("1000");
    //   await rewardSystem.connect(owner).mintRewardsTWAP(amount);
    //   const balanceAfter = await token.balanceOf(await rewardSystem.getAddress());
    //   expect(balanceAfter).to.equal(balanceBefore + amount);
    //   await trackBalances("Minted twap for reward system");
    // });


    // it("🔥 Test distributeVestingTokens", async () => {
    //   const projectId = 1;
    //   const users = [investor.address]
    //   const amounts = [parseEther("1000")];
    //   const projectIds = [projectId];
    //   const vestingInfoBefore = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
    //   await rewardSystem.connect(owner).distributeVestingTokens(users, amounts, projectIds);
    //   const vestingInfoAfter = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
    //   expect(vestingInfoAfter.totalAmount).to.equal(vestingInfoBefore.totalAmount + amounts[0]);
    //   await trackBalances("Distributed vesting tokens to investor");
    // });


    const MAGIC_TOTLAL_TOKENS = 5938984763627118734080n;


    it("available for claim 2.5%", async () => {
      const projectId = 1;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(MAGIC_TOTLAL_TOKENS * 250n / 10000n);
    });

    it("Check investor project 1 vesting info", async () => {
      const projectId = 1;
      const investorVestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      log("                   🎯 INVESTOR TOTAL TOKENS", formatEther(investorVestingInfo.totalAmount));
      log("                   ✅ INVESTOR CLAIMED", formatEther(investorVestingInfo.claimedAmount));
      log("                   💰 INVESTOR CLAIMABLE", formatEther(investorVestingInfo.claimableAmount));
      log("                   📊 MAGIC_TOTAL", formatEther(MAGIC_TOTLAL_TOKENS));
      
      expect(investorVestingInfo.totalAmount).to.equal(MAGIC_TOTLAL_TOKENS);
    });

    it("Check inviter project 0 and 1", async () => {
      const inviterVesting0 = await rewardSystem.getVestingInfoForProject(await inviter.getAddress(), 0);
      const inviterVesting1 = await rewardSystem.getVestingInfoForProject(await inviter.getAddress(), 1);
      
      log("                   🎯 INVITER PROJECT 0 TOTAL", formatEther(inviterVesting0.totalAmount));
      log("                   🎯 INVITER PROJECT 1 TOTAL", formatEther(inviterVesting1.totalAmount));
      log("                   ✅ INVITER PROJECT 0 CLAIMED", formatEther(inviterVesting0.claimedAmount));
      log("                   ✅ INVITER PROJECT 1 CLAIMED", formatEther(inviterVesting1.claimedAmount));
    });

    it("RewardSystem balance check", async () => {
      const totalTokens = await token.balanceOf(await rewardSystem.getAddress());
      const investorVesting1 = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), 1);
      const unclaimed = investorVesting1.totalAmount - investorVesting1.claimedAmount;
      
      log("                   💼 REWARD SYSTEM BALANCE", formatEther(totalTokens));
      log("                   🎯 INVESTOR PROJECT 1 UNCLAIMED", formatEther(unclaimed));
      
      // Balance should equal investor's unclaimed tokens for project 1
      expect(totalTokens).to.be.closeTo(unclaimed, parseEther("0.01"));
    });

    it("claim 2.5%", async () => {
      const projectId = 1;
      const balanceBefore = await token.balanceOf(await investor.getAddress());
      await rewardSystem.connect(investor).claimTokensForProject(projectId);
      const balanceAfter = await token.balanceOf(await investor.getAddress());
      expect(balanceAfter).to.equal(balanceBefore + MAGIC_TOTLAL_TOKENS * 250n / 10000n);
      await trackBalances("Claimed 2.5%");
    });

    it("available for claim 0% after claim", async () => {
      const projectId = 1;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("🎁 Set additional unlock to 26%", async () => {
      const additionalUnlock = 260000; // 26% in BASIS_POINTS
      await rewardSystem.connect(manager).setAdditionalUnlock(additionalUnlock);
      const currentAdditionalUnlock = await rewardSystem.additionalUnlockPercentage();
      expect(currentAdditionalUnlock).to.equal(additionalUnlock);
      log("                   📊 ADDITIONAL UNLOCK SET TO", Number(currentAdditionalUnlock) / 10000, "%");
    });


    it("claim additional unlock 26% and sell", async () => {
      const projectId = 1;
      const balanceBefore = await token.balanceOf(await investor.getAddress());
      const usdcBalanceBefore = await usdcToken.balanceOf(await investor.getAddress());

      const claimableAmount = MAGIC_TOTLAL_TOKENS * 2600n / 10000n;
      
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
      const projectId = 1;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("set additional unlock to 0%", async () => {
      await rewardSystem.connect(manager).setAdditionalUnlock(0);
      const currentAdditionalUnlock = await rewardSystem.additionalUnlockPercentage();
      expect(currentAdditionalUnlock).to.equal(0);
      log("                   📊 ADDITIONAL UNLOCK SET TO", Number(currentAdditionalUnlock) / 10000, "%");
    });

    it("available for claim 0% after set additional unlock to 0%", async () => {
      const projectId = 1;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("skip 1 week and claim 2.5%", async () => {
      const projectId = 1;
      await time.increase(7 * 24 * 3600);
      const balanceBefore = await token.balanceOf(await investor.getAddress());
      await rewardSystem.connect(investor).claimTokensForProject(projectId);
      const balanceAfter = await token.balanceOf(await investor.getAddress());
      expect(balanceAfter).to.equal(balanceBefore + MAGIC_TOTLAL_TOKENS * 250n / 10000n);
      await trackBalances("1w, claim 2.5%");
    });

    it("skip week, set additional unlock to 50% and claim 52.5%", async () => {
      await time.increase(7 * 24 * 3600);
      const projectId = 1;
      await rewardSystem.connect(manager).setAdditionalUnlock(500000);
      const usdcBalanceBefore = await usdcToken.balanceOf(await investor.getAddress());
      await rewardSystem.connect(investor).claimTokensForProject(projectId);
      const balanceAfter = await token.balanceOf(await investor.getAddress());

      const claimedTotal= MAGIC_TOTLAL_TOKENS * (250n + 250n + 250n) / 10000n;
      const usdcBalanceAfter = await usdcToken.balanceOf(await investor.getAddress());
      await trackBalances("1w, unlock to 50%, claim 5.5%");
      expect(usdcBalanceAfter).to.be.equals(usdcBalanceBefore);
      expect(balanceAfter).to.be.equals(claimedTotal);
    });

    it("skip 20 weeks, sell remaining with 50% bonus", async () => {
      const projectId = 1;

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
      expect(vestingInfo.totalAmount).to.equal(MAGIC_TOTLAL_TOKENS);
      expect(vestingInfo.claimedAmount).to.equal(MAGIC_TOTLAL_TOKENS);

      const balance = await token.balanceOf(await investor.getAddress());
      
      // On balance: 2.5% + 2.5% + 2.5% = 7.5%
      // Sold: 26% + 66.5% = 92.5%
      // Total: 100%
      
      
      log("                   🪙 INVESTOR BALANCE", formatEther(balance));
      log("                   🎯 EXPECTED ~50%", formatEther(vestingInfo.totalAmount / 2n));
      
      
      expect(balance).to.be.equals(vestingInfo.totalAmount / 2n);
    });

    it("available for claim 0% after skip week, set additional unlock to 50% and claim 52.5%", async () => {
      const projectId = 1;
      const vestingInfo = await rewardSystem.getVestingInfoForProject(await investor.getAddress(), projectId);
      expect(vestingInfo.claimableAmount).to.equal(0);
    });

    it("try claim - should fail", async () => {
      const projectId = 1;
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


    it.skip("🔥 Test burning with different investment amounts", async function () {
      // Create project with larger amount for more noticeable burning
      const largeBurnTestProjectData = {
        softCap: ethers.parseUnits("100000", 6),
        hardCap: ethers.parseUnits("200000", 6),
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
          stage: 0
        }
      };

      const largeBurnTestProjectId = await fundraise.projectCount();
      await fundraise.connect(manager).createProject(largeBurnTestProjectData, 1);

      // Invest large amount
      const largeInvestmentAmount = ethers.parseUnits("100000", 6);
      await usdcToken.mint(investor.address, largeInvestmentAmount);
      await usdcToken.connect(investor).approve(await fundraise.getAddress(), largeInvestmentAmount);

      // Create signature for investment
      const largeBurnTestCurrentNonce = await fundraise.userNonces(await investor.getAddress());
      const largeBurnTestNonceForSignature = largeBurnTestCurrentNonce + 1n;
      const largeBurnTestMessageHash = ethers.solidityPackedKeccak256(
        ["address", "uint256", "uint256", "uint256", "address"],
        [await investor.getAddress(), largeBurnTestProjectId, largeInvestmentAmount, largeBurnTestNonceForSignature, inviter]
      );
      const largeBurnTestSignature = await backend.signMessage(ethers.getBytes(largeBurnTestMessageHash));

      await fundraise.connect(investor).investUpdate(largeBurnTestProjectId, largeInvestmentAmount, largeBurnTestNonceForSignature, largeBurnTestSignature, inviter);
      
      const totalSupplyBeforeLargeBurn = await token.totalSupply();


            // Check that burning is proportional to investment
            const burnPercentage = await rewardSystem.burnPercentage();
            const expectedBurnAmountUSDC = (largeInvestmentAmount * burnPercentage) / await rewardSystem.BASIS_POINTS();

            // Get expected amount of tokens to burn
            const path = [await usdcToken.getAddress(), await token.getAddress()];
            const amounts = await router.getAmountsOut(expectedBurnAmountUSDC, path);
            const expectedTokensBurned = amounts[1];
      
      // Activate burning
      await fundraise.connect(manager).transferFundsToBorrower(largeBurnTestProjectId);
      
      const totalSupplyAfterLargeBurn = await token.totalSupply();
      const burnedAmount = totalSupplyBeforeLargeBurn - totalSupplyAfterLargeBurn;
      
      log("                   🔥 LARGE BURN TEST");
      log("                   💵 LARGE INVESTMENT AMOUNT", formatUnits(largeInvestmentAmount, 6));
      log("                   📊 TOTAL SUPPLY BEFORE LARGE BURN", formatEther(totalSupplyBeforeLargeBurn));
      log("                   📊 TOTAL SUPPLY AFTER LARGE BURN", formatEther(totalSupplyAfterLargeBurn));
      log("                   🔥 ACTUAL TOKENS BURNED", formatEther(burnedAmount));
      
      // Check that burning occurred
      expect(burnedAmount).to.be.greaterThan(0);
      expect(totalSupplyAfterLargeBurn).to.be.lessThan(totalSupplyBeforeLargeBurn);
      

          
      log("                   💵 EXPECTED USDC TO BURN", formatUnits(expectedBurnAmountUSDC, 6));
      log("                   🪙 EXPECTED TOKENS TO BURN", formatEther(expectedTokensBurned));
      
      // Check that approximately expected amount of tokens were burned (accounting for swap error)
      const tolerance = expectedTokensBurned / 10n; // 10% tolerance
      expect(burnedAmount).to.be.closeTo(expectedTokensBurned, tolerance);
      await trackBalances("Test burning with different investment amounts");
    });


  });
});

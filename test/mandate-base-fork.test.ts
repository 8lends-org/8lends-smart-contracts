import { expect } from "chai";
import { ethers } from "hardhat";
import { impersonateAccount, mine, setBalance } from "@nomicfoundation/hardhat-network-helpers";
import { Wallet } from "ethers";
import { IERC20, MandateEscrowV1 } from "../typechain-types";

/**
 * The two dependencies that cannot be faithfully stubbed: Circle's USDC and the live Lending8
 * market. Everything else has unit coverage; what is proven here is that the escrow's calls land on
 * the real implementations.
 *
 * The hardhat network forks Base unconditionally (see hardhat.config.ts), so nothing has to be set
 * up here — but that also means this file only makes sense on that network.
 */
describe("🔱 Mandate — Base fork", function () {
  const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
  const LENDING8 = "0x435782af7B8B12d71CB8FeCa159d65D96459f042";
  const FUNDRAISE = "0xf435A133D6cDCb81061F18a4763560f9931DB57D";
  const REGISTRY = "0xFa709E34598BA4f67C2074EBE427FcC700dBDEF4";

  /** The live USDC/BTC8L market, lltv 0.8. */
  const MARKET_ID = "0x6c4df3166bf6cf859656fca88e77febb7274fcdc154ad52e3e644e65447882b4";

  const KEEP = 0;
  const LEND = 2;

  /** @dev A holder large enough to fund the test, used instead of writing balance slots by hand. */
  const USDC_SOURCE = FUNDRAISE;

  let escrow: MandateEscrowV1;
  let owner: Wallet;

  /**
   * The implementation is initialised directly rather than cloned: the guard is `owner == 0`, not a
   * caller check, and clone derivation has its own suite. What is under test here is USDC and
   * Lending8, and a clone would answer both exactly the same.
   */
  async function deployEscrow(direction: number) {
    const [deployer] = await ethers.getSigners();
    const Escrow = await ethers.getContractFactory("MandateEscrowV1");
    const e = await Escrow.connect(deployer).deploy(USDC, FUNDRAISE, REGISTRY, deployer.address, LENDING8);
    await e.waitForDeployment();
    await e.initialize(owner.address, { interestDirection: direction, projectLimitBps: 10_000 });
    return e;
  }

  async function fundUsdc(to: string, amount: bigint) {
    await impersonateAccount(USDC_SOURCE);
    await setBalance(USDC_SOURCE, ethers.parseEther("1000"));
    const source = await ethers.getSigner(USDC_SOURCE);
    const usdc = (await ethers.getContractAt(
      "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", USDC
    )) as unknown as IERC20;
    await usdc.connect(source).transfer(to, amount);
  }

  beforeEach(async function () {
    // A read at the fork block itself asks hardhat to execute at a historical block, which it
    // refuses without a hardfork activation history. One block forward and "latest" is ours.
    await mine();

    owner = new Wallet(
      "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
      ethers.provider
    );
    await setBalance(owner.address, ethers.parseEther("1000"));
  });

  it("the live market lends USDC", async function () {
    const lending = await ethers.getContractAt("contracts/lending/interfaces/ILending8.sol:ILending8", LENDING8);
    const params = await lending.idToMarketParams(MARKET_ID);

    expect(params.loanToken).to.equal(USDC);
    expect(params.collateralToken).to.not.equal(ethers.ZeroAddress);
  });

  it("forwards interest into Lending8 on behalf of the owner", async function () {
    escrow = await deployEscrow(LEND);
    const interest = 250_000_000n; // 250 USDC
    await fundUsdc(await escrow.getAddress(), interest);

    const lending = await ethers.getContractAt("contracts/lending/interfaces/ILending8.sol:ILending8", LENDING8);
    const before = await lending.position(MARKET_ID, owner.address);

    // Fundraise is the only caller onPayout accepts. Budget equal to the payout says "all of this
    // is interest", so the whole amount goes to the direction the mandate chose.
    await impersonateAccount(FUNDRAISE);
    await setBalance(FUNDRAISE, ethers.parseEther("1000"));
    const asFundraise = await ethers.getSigner(FUNDRAISE);
    await escrow.connect(asFundraise).onPayout(1, interest, interest, interest, MARKET_ID);

    const after = await lending.position(MARKET_ID, owner.address);
    expect(after.supplyShares).to.be.greaterThan(before.supplyShares, "the owner's position grew");

    const escrowPos = await lending.position(MARKET_ID, await escrow.getAddress());
    expect(escrowPos.supplyShares).to.equal(0n, "and the escrow holds nothing itself");

    const usdc = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", USDC);
    expect(await usdc.balanceOf(await escrow.getAddress())).to.equal(0n, "the interest left");
    expect(await usdc.allowance(await escrow.getAddress(), LENDING8)).to.equal(0n, "no standing allowance");
  });

  it("takes a deposit signed against Circle's USDC", async function () {
    escrow = await deployEscrow(KEEP);
    const value = 500_000_000n; // 500 USDC
    await fundUsdc(owner.address, value);

    const escrowAddress = await escrow.getAddress();
    const nonce = ethers.keccak256(ethers.toUtf8Bytes("mandate-fork-deposit"));
    const validAfter = 0;
    const validBefore = (await time_latest()) + 3600;

    // signTypedData rather than hand-rolled hashing — the domain is Circle's own.
    const signature = await owner.signTypedData(
      { name: "USD Coin", version: "2", chainId: 8453, verifyingContract: USDC },
      {
        ReceiveWithAuthorization: [
          { name: "from", type: "address" },
          { name: "to", type: "address" },
          { name: "value", type: "uint256" },
          { name: "validAfter", type: "uint256" },
          { name: "validBefore", type: "uint256" },
          { name: "nonce", type: "bytes32" },
        ],
      },
      { from: owner.address, to: escrowAddress, value, validAfter, validBefore, nonce }
    );

    // Submitted by a stranger on purpose: from and to are pinned by the signature.
    const [, stranger] = await ethers.getSigners();
    await escrow.connect(stranger).depositWithAuthorization(value, validAfter, validBefore, nonce, signature);

    expect(await escrow.freeBalance()).to.equal(value, "the deposit landed");
    const usdc = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", USDC);
    expect(await usdc.balanceOf(owner.address)).to.equal(0n, "and left the owner");
  });

  async function time_latest(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block!.timestamp;
  }
});

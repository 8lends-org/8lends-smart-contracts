import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { upgrades } from "hardhat";
import { readJsonFile, writeJsonFile } from "../helpers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  console.log("\nDeploying Fundraise contract");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  const trustSignerPrivateKey = process.env.TRUSTED_SIGNER_PRIVATE_KEY;
  if (!trustSignerPrivateKey) {
    throw new Error("Trusted signer private key not found in env");
  }
  const trustedSigner = new ethers.Wallet(trustSignerPrivateKey, ethers.provider);

  const FundraiseFactory = await hre.ethers.getContractFactory("Fundraise");
  const Fundraise = await upgrades.deployProxy(
    FundraiseFactory,
    [config.Treasury, config.ManagerRegistry, trustedSigner.address, config.RewardSystem],
    {
      kind: "uups",
      initializer: "initialize",
    }
  );
  await Fundraise.waitForDeployment();
  console.log("Fundraise deployed to:", await Fundraise.getAddress());

  await new Promise(resolve => setTimeout(resolve, 12000));

  const Fundraise_impl_addr = await upgrades.erc1967.getImplementationAddress(
    await Fundraise.getAddress()
  );
  console.log("Fundraise implementation deployed to:", Fundraise_impl_addr);

  config.Fundraise = await Fundraise.getAddress();
  config.Fundraise_impl = Fundraise_impl_addr;
  config.trustedSigner = trustedSigner.address;

  await writeJsonFile(filePath, config);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});

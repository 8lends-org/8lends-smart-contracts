import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { upgrades } from "hardhat";
import { readJsonFile, writeJsonFile } from "../helpers";
import { ZeroAddress } from "ethers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  const whitelist = [
    ZeroAddress
  ];

  console.log("\nDeploying TEST USDT contract");

  const [signer] = await ethers.getSigners();
  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  const USDTFactory = await hre.ethers.getContractFactory("MockERC20");
  const USDT = await upgrades.deployProxy(USDTFactory, [signer.address, "Test usdt", "TUSDT"], {
    kind: "uups",
    initializer: "initialize",
  });
  console.log("USDT ", USDT);
  await USDT.waitForDeployment();
  console.log("TEST USDT token  deployed to:", await USDT.getAddress());

  const USDT_impl_addr = await upgrades.erc1967.getImplementationAddress(await USDT.getAddress());
  console.log("TEST USDT implementation deployed to:", USDT_impl_addr);

  config.usdc = await USDT.getAddress();
  config.usdc_impl = USDT_impl_addr;

  await writeJsonFile(filePath, config);

  console.log("Minting");
  for (let addr of whitelist) {
    let tx = await USDT.mint(addr, ethers.parseUnits("100000", 6));
    await tx.wait();
    console.log(`minted to: ${addr}`);
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});

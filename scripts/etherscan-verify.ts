import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "./helpers";
dotenv.config();

async function main() {
  const config = await readJsonFile(
    `./scripts/config/${(await ethers.provider.getNetwork()).chainId}-config.json`
  );
  console.log(`\n🔍 Verifying contracts on ${(await ethers.provider.getNetwork()).name}\n`);

  const verify = async (name: string, address: string, args: any[] = []) => {
    if (!address) return { name, status: "⚠️ Skipped" };
    // Check if contract is already verified
    try {
      const code = await ethers.provider.getCode(address);
      if (!code || code === "0x") {
        console.log(`⚠️ ${name} not deployed at ${address}, skipping`);
        return { name, status: "⚠️ Not deployed" };
      }
      const resp = await hre.run("verify:verify", { address, constructorArguments: args });
      console.log("resp", resp);
      console.log(`✅ ${name} verified`);
      return { name, status: "✅ Success" };
    } catch (error: any) {
      if (
        error.message &&
        (error.message.includes("Already Verified") ||
          error.message.includes("Contract source code already verified") ||
          error.message.includes("Reason: Already Verified"))
      ) {
        console.log(`ℹ️ ${name} already verified`);
        return { name, status: "ℹ️ Already verified" };
      }
      console.log(`❌ ${name} failed:`, error.message);
      return { name, status: "❌ Failed" };
    }
  };

  const onlyOne = process.env.CONTRACT;

  const results = [];
  const contractsToVerify = [
    { name: "Token", address: config.token, args: [] },
    ...Object.entries(config)
      .filter(([k, v]) => k.endsWith("_impl") && v)
      .map(([k, v]) => ({ name: k.replace("_impl", ""), address: v as string, args: [] })),
  ].filter(c => onlyOne ? c.name === onlyOne : true);

  for (const contract of contractsToVerify) {
    console.log(`\n\nVerifying ${contract.name} at ${contract.address}\n`);
    results.push(await verify(contract.name, contract.address, contract.args));
    await new Promise(res => setTimeout(res, 2000));
    console.log("\n\n");
  }

  console.log("\n" + "=".repeat(50));
  console.log("📊 VERIFICATION SUMMARY");
  console.log("=".repeat(50));
  results.forEach(r => console.log(`${r.status} ${r.name}`));
  console.log(
    `\n📈 Results: ${results.filter(r => r.status.includes("✅")).length}/${results.length} verified successfully`
  );
  console.log("=".repeat(50));
}

main().catch(console.error);

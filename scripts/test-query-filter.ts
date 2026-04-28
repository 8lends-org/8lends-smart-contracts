import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";

async function main() {

    const net = await ethers.provider.getNetwork();
    const config: {
      Fundraise: string;
      fundraiseDeployBlock: number;
    } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));
  
    const fromBlock = config.fundraiseDeployBlock;
    const fundraise = await ethers.getContractAt("Fundraise", config.Fundraise);
  
    console.log(`Scanning Invest events from block ${fromBlock}...`);
  
    const filter = fundraise.filters.Invest();
    const events = await fundraise.queryFilter(filter, fromBlock)
    
    for (const event of events) {
        console.log(event);
    }
    console.log(`Found ${events.length} Invest events`);

}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
  
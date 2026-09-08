import dotenv from "dotenv";
import { formatEther } from "ethers";
import hre, { ethers } from "hardhat";
dotenv.config();

async function main() {
  const FROM_PRIVATE_KEY = process.env.FROM_PRIVATE_KEY;
  const TO_ADDRESS = process.env.TO_ADDRESS;
  const AMOUNT = process.env.AMOUNT;

  if (!FROM_PRIVATE_KEY || !TO_ADDRESS || !AMOUNT) {
    console.log(
      "Usage: FROM_PRIVATE_KEY=0x123... TO_ADDRESS=0x123... AMOUNT=0.01 npx hardhat run scripts/tools/send_native.ts --network <network>"
    );
    console.log(
      "Example: FROM_PRIVATE_KEY=0x123... TO_ADDRESS=0x123... AMOUNT=0.01 npx hardhat run scripts/tools/send_native.ts --network sepolia"
    );
    process.exit(1);
  }

  const net = await ethers.provider.getNetwork();
  console.log(`\nNetwork name: ${net.name}\n`);

  let signer;
  if (FROM_PRIVATE_KEY.toLowerCase() === "signer") signer = (await ethers.getSigners())[0];
  else signer = new ethers.Wallet(FROM_PRIVATE_KEY, ethers.provider);
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Validate wallet address
  if (!ethers.isAddress(TO_ADDRESS)) {
    throw new Error("Invalid wallet address");
  }

  // Convert amount to wei
  let sendAmount;
  if (process.env.AMOUNT?.toUpperCase() === "MAX") {
    const { gasPrice } = await ethers.provider.getFeeData();
    if (!gasPrice) throw new Error("Gas price not found");

    const gasLimit = 21000n;
    const gasFee = BigInt(gasPrice) * gasLimit;

    console.log("Gas FEE:", formatEther(gasFee));
    sendAmount = await ethers.provider.getBalance(await signer.getAddress());
    sendAmount = sendAmount - gasFee * 2n;
  } else sendAmount = ethers.parseEther(AMOUNT);

  console.log("Sending ETH:", formatEther(sendAmount));

  // Check if signer has enough balance
  if (signerBalance < sendAmount) {
    throw new Error(
      `Insufficient balance. Need ${ethers.formatEther(sendAmount)}, have ${ethers.formatEther(signerBalance)}`
    );
  }

  console.log(`\nSending ${AMOUNT} native tokens to ${TO_ADDRESS}...`);

  // Send native tokens
  const tx = await signer.sendTransaction({
    to: TO_ADDRESS,
    value: sendAmount,
  });

  console.log("Transaction hash:", tx.hash);

  await tx.wait();
  console.log("✅ Native tokens sent successfully!");

  // Check new balances
  const newSignerBalance = await ethers.provider.getBalance(await signer.getAddress());
  const receiverBalance = await ethers.provider.getBalance(TO_ADDRESS);

  console.log(`\nNew balances:`);
  console.log(
    `Signer: ${ethers.formatEther(newSignerBalance)} ETH`
  );
  console.log(
    `Receiver: ${ethers.formatEther(receiverBalance)} ETH`
  );
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});

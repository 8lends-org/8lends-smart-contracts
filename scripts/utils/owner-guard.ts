import { ethers } from "hardhat";

/**
 * Throws before sending anything if the signer is not the contract's owner.
 * Takes an address rather than a contract because most scripts build their own narrow ABI
 * without `owner()`.
 */
export async function requireOwner(address: string, name: string): Promise<void> {
  const [signer] = await ethers.getSigners();
  const me = (await signer.getAddress()).toLowerCase();
  const contract = new ethers.Contract(address, ["function owner() view returns (address)"], signer);
  const owner = ((await contract.owner()) as string).toLowerCase();
  if (owner !== me) {
    throw new Error(`Not the owner of ${name}: owner ${owner}, signer ${me}`);
  }
}

import { ethers } from "hardhat";

/**
 * Throws before sending anything if the signer is not the contract's owner.
 * Takes an address rather than a contract because most scripts build their own narrow ABI
 * without `owner()`.
 *
 * `fallbackRole` is for contracts that have no owner at all — BTC8L and anything else gated by
 * AccessControl. It is opt-in per call site rather than automatic: holding a role is not the same
 * authority as owning the contract, and most callers here guard owner-only operations.
 */
export async function requireOwner(address: string, name: string, fallbackRole?: string): Promise<void> {
  const [signer] = await ethers.getSigners();
  const me = (await signer.getAddress()).toLowerCase();
  const contract = new ethers.Contract(
    address,
    [
      "function owner() view returns (address)",
      "function hasRole(bytes32, address) view returns (bool)",
    ],
    signer
  );

  let owner: string;
  try {
    owner = ((await contract.owner()) as string).toLowerCase();
  } catch {
    if (!fallbackRole) {
      throw new Error(`${name} has no owner(); pass the role that guards this action`);
    }
    if (await contract.hasRole(ethers.id(fallbackRole), me)) return;
    throw new Error(`Signer ${me} does not hold ${fallbackRole} on ${name}`);
  }

  if (owner !== me) {
    throw new Error(`Not the owner of ${name}: owner ${owner}, signer ${me}`);
  }
}

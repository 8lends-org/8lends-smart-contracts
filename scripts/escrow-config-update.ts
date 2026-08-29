import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readJsonFile } from "./utils/helpers";
import { requireOwner } from "./utils/owner-guard";
import { requireRealNetwork } from "./utils/network-guard";

dotenv.config();

/**
 * Idempotent reconciliation of EscrowFactory + Fundraise settings against
 * scripts/config/<chainId>-config.json.
 *
 * For every settable field the script reads on-chain state, compares to the
 * desired value from the config file, and only sends a transaction when they
 * differ. Safe to re-run on every deploy.
 *
 * Optional config keys (defaults are sensible):
 *   escrowSigner            address  — backend signer for AML approvals
 *                                       (falls back to trustedSigner)
 *   escrowMaxInvestAmount   uint     — max single invest (default already in factory: 500e6)
 *   escrowMinInvestAmount   uint     — min single invest (default: 1e6)
 *   escrowRefundTimeout     uint     — refund timeout in seconds (default: 30 days)
 *   maxPriceAge             uint     — Fundraise oracle staleness window (0 = disabled)
 *
 * Required: EscrowFactory, AmlEscrow, Fundraise, USDC.
 */

type Cfg = Record<string, string | undefined>;

async function sendIfChanged(
    label: string,
    current: string,
    desired: string,
    sender: () => Promise<{ hash: string; wait: () => Promise<unknown> }>
): Promise<boolean> {
    if (current.toLowerCase() === desired.toLowerCase()) {
        console.log(`   ✓ ${label}: ${current} (no change)`);
        return false;
    }
    console.log(`   ⏳ ${label}: ${current} → ${desired}`);
    const tx = await sender();
    console.log(`      tx: ${tx.hash}`);
    await tx.wait();
    console.log(`   ✅ ${label} updated`);
    return true;
}

async function main(): Promise<void> {
  await requireRealNetwork();
    const net = await ethers.provider.getNetwork();
    const filePath = `./scripts/config/${net.chainId}-config.json`;
    const config = (await readJsonFile(filePath)) as Cfg;

    console.log(`\nReconciling escrow config on chain ${net.chainId} (${net.name})\n`);

    if (!config.EscrowFactory) throw new Error("EscrowFactory missing in config — deploy it first");
    if (!config.Fundraise) throw new Error("Fundraise missing in config");
    if (!config.USDC) throw new Error("USDC missing in config");
    if (!config.AmlEscrow) throw new Error("AmlEscrow missing in config");

    const [signer] = await ethers.getSigners();
    const me = (await signer.getAddress()).toLowerCase();
    console.log(`Signer: ${me}`);

    // Both guards up front: the script writes to two contracts, and a late check would leave the
    // first one already updated if the signer owns it but not the second.
    await requireOwner(config.EscrowFactory as string, "EscrowFactory");
    await requireOwner(config.Fundraise as string, "Fundraise");

    // -----------------------------------------------------------------------
    // EscrowFactory
    // -----------------------------------------------------------------------
    console.log("\n=== EscrowFactory ===");
    const factory = await ethers.getContractAt("EscrowFactory", config.EscrowFactory);

    // implementation (clone target for new escrows; existing clones are pinned)
    await sendIfChanged(
        "implementation",
        await factory.implementation(),
        config.AmlEscrow,
        () => factory.setImplementation(config.AmlEscrow as string)
    );

    // fundraise
    await sendIfChanged(
        "fundraise",
        await factory.fundraise(),
        config.Fundraise,
        () => factory.setFundraise(config.Fundraise as string)
    );

    // usdc
    await sendIfChanged(
        "usdc",
        await factory.usdc(),
        config.USDC,
        () => factory.setUsdc(config.USDC as string)
    );

    // signer (backend AML approver).
    // NB: factory.signer collides with ethers v6 built-in `Contract.signer` —
    // typechain hides it from the typed surface, so we read it via getFunction().
    const desiredSigner = config.escrowSigner || config.trustedSigner;
    if (desiredSigner) {
        const readSigner = factory.getFunction("signer") as unknown as () => Promise<string>;
        const currentSigner = await readSigner();
        await sendIfChanged(
            "signer",
            currentSigner,
            desiredSigner,
            () => factory.setSigner(desiredSigner)
        );
    } else {
        console.log("   ⚠️  No escrowSigner/trustedSigner in config — skipping signer update");
    }

    // min/max invest amounts must satisfy: min <= max AT ALL TIMES.
    // To avoid intermediate-state reverts, order operations correctly:
    //   - if desiredMax >= currentMin, setMax first is safe;
    //   - otherwise (desiredMax < currentMin), setMin first is required.
    const currentMax = await factory.maxInvestAmount();
    const currentMin = await factory.minInvestAmount();
    const desiredMax = config.escrowMaxInvestAmount ? BigInt(config.escrowMaxInvestAmount) : currentMax;
    const desiredMin = config.escrowMinInvestAmount ? BigInt(config.escrowMinInvestAmount) : currentMin;

    if (desiredMin > desiredMax) {
        throw new Error(`escrowMinInvestAmount (${desiredMin}) > escrowMaxInvestAmount (${desiredMax})`);
    }

    const updateMax = async () => {
        if (desiredMax !== currentMax) {
            await sendIfChanged(
                "maxInvestAmount",
                currentMax.toString(),
                desiredMax.toString(),
                () => factory.setMaxInvestAmount(desiredMax)
            );
        } else {
            console.log(`   ✓ maxInvestAmount: ${currentMax} (no change)`);
        }
    };
    const updateMin = async () => {
        if (desiredMin !== currentMin) {
            await sendIfChanged(
                "minInvestAmount",
                currentMin.toString(),
                desiredMin.toString(),
                () => factory.setMinInvestAmount(desiredMin)
            );
        } else {
            console.log(`   ✓ minInvestAmount: ${currentMin} (no change)`);
        }
    };

    if (desiredMax >= currentMin) {
        await updateMax();
        await updateMin();
    } else {
        await updateMin();
        await updateMax();
    }

    // refundTimeout
    if (config.escrowRefundTimeout) {
        const desired = BigInt(config.escrowRefundTimeout);
        const current = await factory.refundTimeout();
        await sendIfChanged(
            "refundTimeout",
            current.toString(),
            desired.toString(),
            () => factory.setRefundTimeout(desired)
        );
    } else {
        console.log(`   ✓ refundTimeout: ${await factory.refundTimeout()} (no config value — keeping)`);
    }

    // -----------------------------------------------------------------------
    // Fundraise: amlGateway + maxPriceAge
    // -----------------------------------------------------------------------
    console.log("\n=== Fundraise ===");
    const fundraise = await ethers.getContractAt("Fundraise", config.Fundraise);

    await sendIfChanged(
        "amlGateway",
        await fundraise.amlGateway(),
        config.EscrowFactory,
        () => fundraise.setAmlGateway(config.EscrowFactory as string)
    );

    if (config.maxPriceAge !== undefined) {
        const desired = BigInt(config.maxPriceAge);
        const current = await fundraise.maxPriceAge();
        await sendIfChanged(
            "maxPriceAge",
            current.toString(),
            desired.toString(),
            () => fundraise.setMaxPriceAge(desired)
        );
    } else {
        console.log(`   ✓ maxPriceAge: ${await fundraise.maxPriceAge()} (no config value — keeping)`);
    }

    console.log("\n✅ Escrow config reconciled");
}

main().catch((error: unknown) => {
    console.error("\n❌ Error:", error);
    process.exitCode = 1;
    process.exit(1);
});

# Owner-only calls via Gnosis Safe

On Base the owner of every contract is a Safe, so nothing can be sent directly. Two scripts turn
an intended change into a JSON file you drag into the Safe Transaction Builder. Neither sends a
transaction; the upgrade script is the only one that deploys anything, and what it deploys is an
implementation nobody points at yet.

| Script | For |
|---|---|
| `prepare-upgrade-for-multisig.ts` | UUPS upgrade: deploys a new implementation, prepares `upgradeToAndCall` |
| `prepare-safe-tx.ts` | Any other owner-only call, one or several in a batch. Deploys nothing |

Both write a batch with the method and its arguments spelled out — `data: null` plus
`contractMethod` and `contractInputsValues` — so signers see `upgradeToAndCall` with the new
implementation address in a field, not an opaque calldata blob.

## Upgrading a contract

```bash
CONTRACT=Fundraise npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network base
```

`CONTRACT` is the config key of the proxy in `scripts/config/<chainId>-config.json`. The script
recompiles from a clean state first, so the deployed bytecode matches the working tree, then
prints the old and new implementation addresses and writes
`safe-upgrade-<Contract>-<chainId>.json`.

It also records the new address in the config as `<Contract>_impl_pending` — pending because the
proxy still points at the old one until the Safe executes.

The prepared call passes empty `data`, i.e. a plain upgrade with no reinitializer. If the new
version needs one, encode that call and put it in the batch by hand before submitting.

## Any other owner-only call

```bash
CONTRACT=ManagerRegistry METHOD=setOperatorStatus ARGS='["0x6E9d…C28", true]' \
  npx hardhat run scripts/prepare-safe-tx.ts --network base
```

`ARGS` is a JSON array, so types survive: `true` is a bool, `"0x…"` a string. An argument written
as `"@Key"` is looked up in the network config, which keeps addresses off the command line:

```bash
CONTRACT=Fundraise METHOD=setAmlGateway ARGS='["@EscrowFactory"]' \
  npx hardhat run scripts/prepare-safe-tx.ts --network base
```

Several calls in one batch:

```bash
CONTRACT=Token CALLS='[{"method":"mint","args":["0xf139…F25","75000000000000000000"]},
                       {"method":"mint","args":["0xCb16…7852","600000000000000000000"]}]' \
  ADDRESS=0x… npx hardhat run scripts/prepare-safe-tx.ts --network base
```

`ADDRESS` overrides the config lookup, for contracts whose config key differs from the artifact
name — the 8LNDS token is `token` in the config but `Token` as an artifact. `METHOD` takes a full
`name(type,...)` signature when the name is overloaded. The output is
`safe-tx-<Contract>-<method>-<chainId>.json`.

## Submitting

1. Open https://app.safe.global/ and select the Safe on the right network
2. **Apps** → **Transaction Builder**
3. Drag the JSON file in, or use **Load from file**
4. Check what the app shows: the target address, the method name, each argument
5. **Create batch** → the transaction appears in **Transactions** → **Queue**
6. Each signer opens it, checks the same fields, and confirms
7. Once the threshold is met, anyone can **Execute**

What to check before signing an upgrade: the target is the **proxy**, not the implementation; the
new implementation address matches what the script printed; `data` is `0x` unless a reinitializer
was added deliberately.

## Verifying

```bash
CONTRACT=Fundraise npx hardhat run scripts/verify-upgrade.ts --network base
```

Reads the ERC-1967 implementation slot on the proxy and compares it with what the config expects.

## Dry runs

Running either script without `--network` uses the in-process `hardhat` network, which forks Base
and reports chainId 8453 — a run looks exactly like a real one. The scripts detect that and mark
the output: the file is named `DRY-RUN-…json`, the config is left untouched, and the console says
the implementation exists on no real chain. A `DRY-RUN-` file must never be submitted.

Both filename patterns are gitignored: these files hold local run state, not something to share
through the repository.

## Notes

- Rehearse on Sepolia first. There the owner is the deploy key, so scripts send transactions
  directly and you find out immediately whether the call does what you meant.
- The Safe needs ETH for gas on execution.
- Long calldata is normal for an upgrade.
- "Not owner" on execution means the Safe is not the contract's owner — check with
  `scripts/tools/check_owner.ts`.
- If Transaction Builder will not load, **New transaction** → **Contract interaction** takes the
  proxy address, the method `upgradeToAndCall` and its two arguments by hand.

## Links

- Safe: https://app.safe.global/
- BaseScan: https://basescan.org

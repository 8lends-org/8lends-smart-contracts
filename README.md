[![CI](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/oleg8lend/c4e8201ab2aff9e57bda9ce7aace23d6/raw/coverage-badge.json)](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.23-363636?logo=solidity)](https://soliditylang.org)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.4-blue?logo=openzeppelin)](https://openzeppelin.com/contracts)
[![Network: Base](https://img.shields.io/badge/Network-Base-0052FF?logo=coinbase)](https://base.org)

# 8lends Smart Contracts

Crowdfunding protocol on Base: projects raise USDC from investors, investors earn platform-token
rewards on a vesting schedule, and positions can be resold on a secondary market. Alongside it sits
a lending market (a modified Morpho Blue fork) and a set of one-off bonus campaigns.

Contracts are UUPS-upgradeable and owned by a Gnosis Safe on production.

## Quick start

```bash
npm ci                # installs cleanly, no --legacy-peer-deps needed
npm test              # Hardhat: 66 tests
npm run forge:test    # Foundry: 661 tests
```

Both suites run without any secrets. `npm test` forks Base at `latest`, falling back to the public
endpoint when `BASE_RPC_URL` is unset — that works but takes minutes on a cold cache, so set the
variable for day-to-day work.

## Layout

```
contracts/
  core/         Fundraise, RewardSystem, Rewards2, ManagerRegistry,
                Treasury, TreasuryLending, LimitedSeller, market/Market
  bonus/        five independent bonus campaigns
  token/        Token (8LNDS), BTC8L
  escrow/       AML escrow and its factory
  oracle/       price oracle: Pyth → Chainlink → Uniswap V3 TWAP
  lending/      Lending8 and friends — a vendored Morpho fork, kept syncable
  interfaces/   protocol/ (ours) · external/ (third-party) · token/ (ERC-20)
  mocks/        test doubles, not deployed
  test-tokens/  USDC/WBTC/WETH stand-ins, deployed on Sepolia only
scripts/        deployment, migrations, Safe batch preparation
  utils/        shared helpers: owner guard, batch progress, Safe encoding
test/           Hardhat suites (need the Base fork)
  foundry/      unit · fuzz · invariant · upgrade
```

`contracts/interfaces/protocol/` must stay in step with the deployed ABI; `external/` mirrors
third-party ABIs and is not ours to change.

## Contracts

| Contract | Role |
|---|---|
| `Fundraise` | Projects, investments, repayments, KYC limits |
| `RewardSystem` | Token and referral rewards, 40-week vesting at 2.5%/week |
| `Rewards2` | Standalone vesting: the owner creates schedules, users claim from them |
| `ManagerRegistry` | Central access control: managers, operators, pools |
| `Treasury` / `TreasuryLending` | Fee custody, owner-only withdrawal; the second is an empty subclass, deployed separately for lending fees |
| `Market` | Secondary trading of whole investments — see `contracts/core/market/Market.md` |
| `LimitedSeller` | Buying 8LNDS off Uniswap V2, capped per user by what they invested |
| `Token` | 8LNDS platform token (not upgradeable) |
| `BTC8L` | Wrapped BTC: minted against a Bitcoin transaction, burned on withdrawal |
| `Oracle` | Price feed with source priority and deviation checks |
| `Lending8` | Lending market (Morpho Blue fork) |
| `FlashLiquidator` | Liquidations, flash-funded or from own balance |
| `AdaptiveCurveIrm` / `FixedRateIrm` | Interest rate models |
| `AmlEscrow` / `EscrowFactory` | Per-user escrow for AML-gated investments |
| `WelcomeBonus`, `MaclearBonus`, `LeagueBonus`, `CustomBonus`, `CryptoCourseBonus` | Campaign payouts |

## Testing

Two suites on purpose:

**Foundry** covers contract logic — fast (in-process EVM), and the only place with fuzzing (1024
runs) and invariants (256 runs, depth 64).

**Hardhat** covers what Foundry cannot: it forks Base to read the live Uniswap V2 router, Chainlink
and Pyth, and it runs the OpenZeppelin plugin's storage-layout validation on upgrades.

| Script | Scope |
|---|---|
| `npm test` | all Hardhat suites |
| `npm run test:general` | end-to-end investment → vesting → claim flow |
| `npm run test:oracle` | oracle against live Base feeds |
| `npm run test:lending` | Lending8 supply/borrow/repay |
| `npm run forge:test` | all Foundry tests |
| `npm run forge:test:unit` / `:fuzz` / `:invariant` / `:upgrade` | one Foundry group |
| `npm run forge:coverage` | coverage summary |
| `npm run slither` / `:high` / `:triage` | static analysis (needs slither installed) |

Contracts are compiled twice with different settings: Hardhat uses `runs: 50` with the Yul
optimizer on (RewardSystem does not fit under EIP-170 otherwise), Foundry uses `runs: 200`. Gas
figures from the two are not comparable, and deployments go through Hardhat.

## Environment

`.env-example` lists what the toolchain reads. Nothing is required to run the tests.

| Variable | Needed for |
|---|---|
| `BASE_RPC_URL` | fast Base fork; falls back to the public endpoint |
| `ETHEREUM_SEPOLIA_RPC_URL` | Sepolia; same fallback |
| `OWNER_MNEMONIC_PROD` / `_DEV` | signing on Base / Sepolia |
| `INITIAL_INDEX` | which mnemonic account to use |
| `ETHERSCAN_API_KEY` | verification (single key, Etherscan V2) |
| `TRUSTED_SIGNER_PRIVATE_KEY` | backend signature for `Fundraise` deploys |
| `CONTRACT`, `METHOD`, `ARGS`, `CALLS` | inputs for `prepare-safe-tx` |

Individual scripts take further inputs the same way; each file documents its own in a header
comment.

Deployed addresses live in `scripts/config/<chainId>-config.json` and are committed: this is the
record of what exists on each chain, and scripts resolve proxies through it. Deploy and upgrade
scripts rewrite the file, so expect it in diffs — that is the point. Nothing secret goes in;
`trustedSigner` is an address, its key stays in `.env`.

What is not committed is per-run state: `scripts/state/` (batch progress) and the `safe-*.json`
batches.

## Networks

| Name | Chain | Notes |
|---|---|---|
| `hardhat` | 8453 | default for tests, always forks Base at `latest` |
| `base` | 8453 | production; owner is a Gnosis Safe |
| `sepolia` | 11155111 | testnet; owner is the deploy key |

That difference in ownership is why the testnet scripts are worth keeping: on Sepolia they can send
transactions directly, on Base they can only prepare a batch for the Safe.

## Deploying and upgrading

```bash
CONTRACT=Fundraise npx hardhat run scripts/contract-deploy.ts --network sepolia
```

`scripts/contract-deploy.ts` knows 24 contracts, asks for confirmation, and writes the resulting
address into the chain config.

On Base the owner is a Safe, so nothing is sent directly. Two scripts prepare a JSON to drag into
the Safe Transaction Builder:

```bash
# arbitrary owner-only call
CONTRACT=ManagerRegistry METHOD=setOperatorStatus ARGS='["0x…", true]' \
  npx hardhat run scripts/prepare-safe-tx.ts --network base

# UUPS upgrade
CONTRACT=Fundraise npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network base
```

Both scripts, what to check before signing, and the dry-run mode are covered in
[SAFE_OPERATIONS.md](SAFE_OPERATIONS.md).

## CI

Four jobs on every pull request and on pushes to `main`, `master` and `develop`: Foundry tests,
coverage, Hardhat tests, Slither. All of them gate — a red job is a real failure.

Slither runs with `fail-on: none`, so findings are reported to the Security tab without blocking.
Three high-severity findings are outstanding; raising the gate to `high` before triaging them would
turn the build red immediately.

The coverage badge is written to a gist and only updates on pushes to `main`.

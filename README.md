[![Forge Tests](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml/badge.svg?branch=main&event=push&job=forge-test)](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml)
[![Hardhat Tests](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml/badge.svg?branch=main&event=push&job=hardhat-test)](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml)
[![Slither](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml/badge.svg?branch=main&event=push&job=slither)](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/oleg8lend/c4e8201ab2aff9e57bda9ce7aace23d6/raw/coverage-badge.json)](https://github.com/8lends-org/8lends-smart-contracts/actions/workflows/ci.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.23-363636?logo=solidity)](https://soliditylang.org)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.4-blue?logo=openzeppelin)](https://openzeppelin.com/contracts)
[![Hardhat](https://img.shields.io/badge/Built%20with-Hardhat-yellow?logo=hardhat)](https://hardhat.org)
[![Foundry](https://img.shields.io/badge/Tests-Foundry-red)](https://book.getfoundry.sh)
[![UUPS Proxy](https://img.shields.io/badge/Proxy-UUPS%20Upgradeable-orange)](https://docs.openzeppelin.com/contracts/5.x/api/proxy)
[![Network: Base](https://img.shields.io/badge/Network-Base-0052FF?logo=coinbase)](https://base.org)
[![Network: Ethereum](https://img.shields.io/badge/Network-Ethereum-3C3C3D?logo=ethereum)](https://ethereum.org)
[![Fuzz Testing](https://img.shields.io/badge/Fuzz%20Testing-1024%20runs-purple)](https://book.getfoundry.sh/reference/config/testing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

# 8lends Smart Contracts Overview

## System Architecture

The 8lends system consists of 5 main contracts working together to provide crowdfunding functionality with a reward system:

```
┌─────────────────┐
│ ManagerRegistry │ ◄─────── Central registry for access management
└────────┬────────┘
         │
    ┌────┴────┬──────────┬────────────┐
    │         │          │            │
┌───▼────┐ ┌─▼────────┐ ┌▼──────────┐ ┌▼─────┐
│Fundraise│ │RewardSys │ │  Treasury │ │Token │
└─────────┘ └──────────┘ └───────────┘ └──────┘
```

---

## 1. ManagerRegistry.sol

**Purpose:** Central registry for managing access rights to all system contracts.

### Main Functions:

#### Manager Management:
- `setManagerStatus(address _manager, bool _status)` - add/remove manager
- `setManagerStatusBatch(address[], bool[])` - batch manager addition
- `isManager(address)` - check if address is a manager

#### Uniswap Pool Management:
- `setPoolStatus(address _pool, bool _status)` - register pool
- `isPool(address)` - check if address is a pool

#### System Contract Address Management:
- `setContractAddresses(address _rewardSystem, address _fundraise, address _treasury)` - set addresses
- `isFundraise(address)` - check Fundraise contract
- `isTreasury(address)` - check Treasury contract
- `isRewardSystem(address)` - check RewardSystem contract

#### Investor Claim Address Management:
- `setInvestorClaimAddress(address _investor, address _claimAddress)` - set claim address for investor payouts (owner only)
- `getInvestorClaimAddress(address _investor)` - get claim address (returns original address if not set)

### Features:
- ✅ UUPS Upgradeable pattern
- ✅ Only owner can manage
- ✅ Used by all contracts for permission checks
- ✅ Managers can set other managers (with restrictions)

---

## 2. Fundraise.sol

**Purpose:** Main contract for creating and managing crowdfunding projects.

### Project Structure:

```solidity
struct Project {
    uint256 hardCap;              // Maximum fundraising amount
    uint256 softCap;              // Minimum amount for success
    uint256 totalInvested;        // Funds raised
    uint256 startAt;              // Start time
    uint256 preFundDuration;      // Time until activation
    uint256 investorInterestRate; // Investor interest rate
    uint256 openStageEndAt;       // Fundraising end time
    InnerProjectStruct innerStruct;
}

struct InnerProjectStruct {
    uint256 platformInterestRate; // Platform fee
    uint256 totalRepaid;          // Amount repaid by borrower
    address borrower;             // Borrower address
    uint256 fundedTime;           // Activation time
    IERC20 loanToken;            // Loan token (USDC)
    Stage stage;                  // Current status
}
```

### Project Lifecycle:

```
ComingSoon → Open → PreFunded → Funded → Repaid
              ↓
           Canceled
```

### Main Functions:

#### For Investors:
- `investUpdate(uint256 _pid, uint256 _amount, bytes32 _rootHash, uint256 _nonce, bytes memory _sig, address _inviter)` - invest with whitelist update
- `withdrawInvestment(uint256 _projectId, address _investor)` - refund if project is canceled
- `claim(uint256 _projectId, address _investor)` - claim project payouts
- `availableToClaim(uint256 _projectId, address _investor)` - view available funds to claim

#### For Borrowers:
- `transferFundsToBorrower(uint256 _projectId)` - receive raised funds (platform fee automatically deducted)
- `makeRepayment(uint256 _projectId, uint256 _amount)` - repay funds to investors

#### For Managers:
- `createProject(Project memory, bytes32 _whitelistRoot, uint256 _projectHash)` - create project
- `setProject(uint256 _projectId, Project memory)` - update project parameters
- `cancelProject(uint256 _projectId)` - cancel project
- `moveProjectStage(uint256 _projectId)` - force transition between stages
- `setWhitelist(bytes32 _whitelistRoot, uint256 _projectId)` - update whitelist

#### For Owner:
- `setManagerRegistry(address)` - change ManagerRegistry
- `setTreasury(address)` - change Treasury
- `setRewardSystem(address)` - change RewardSystem

### Features:
- ✅ Merkle proof for investor whitelist
- ✅ Integration with RewardSystem for rewards
- ✅ Automatic platform fee calculation
- ✅ Proportional payout distribution
- ✅ UUPS Upgradeable
- ✅ Trusted signer signature verification
- ✅ Nonce-based replay attack protection

### Constants:
- `BASIS_POINTS = 1_000_000` (1% = 10_000)

---

## 3. RewardSystem.sol

**Purpose:** Reward system for investors and referral program.

### Reward Mechanics:

#### During Investment:
1. **Referral Bonus (inviter):** 6% of investment amount in USDC
2. **Welcome Bonus (new investor):** 30 USDC on first investment ≥1000 USDC
3. **Tokens (investor):** 6% of investment amount in tokens (40 weeks vesting)

#### During Project Activation (Funded):
4. **Buyback & Burn:** 6% of total project amount used to buy back tokens from pool and burn them

### Data Structures:

```solidity
struct UserInfo {
    address inviter;    // Who invited
    bool isNewUser;     // Has received welcome bonus
}

struct ReferralData {
    uint256 totalRewardsUSDC;      // USDC rewards
    uint256 totalRewardsTokens;    // Tokens in vesting
    uint256 vestingClaimedAmount;  // Already claimed tokens
}
```

### Main Functions:

#### Called by Fundraise:
- `recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId)` - register investment
- `activateProjectRewards(uint256 _projectId, uint256 _totalInvested)` - activate rewards + buyback & burn

#### For Users:
- `claimUSDCForProject(uint256 _projectId)` - claim USDC rewards
- `claimTokensForProject(uint256 _projectId)` - claim unlocked tokens (vesting)
- `getProjectRewards(address _user, uint256 _projectId)` - view rewards
- `getVestingInfoForProject(address _user, uint256 _projectId)` - vesting information

#### For Managers:
- `sendUSDCForProjectToUser(address _user, uint256 _projectId)` - send USDC on behalf of user
- `sendTokensForProjectToUser(address _user, uint256 _projectId)` - send tokens on behalf of user
- `setParameters(...)` - change system parameters

#### For Owner:
- `updateContracts(address _managerRegistry, address _token, address _usdc)` - update addresses
- `updateUniswapRouterAddress(address)` - update Uniswap router
- `updateUSDCAddress(address)` - update USDC address
- `updateTokenAddress(address)` - update token address
- `withdraw(address _token, uint256 _amount, address _recepient)` - withdraw funds

### System Parameters (default):
- `referralPercentage = 6%` - inviter bonus
- `tokenPercentage = 6%` - token bonus for investor
- `burnPercentage = 6%` - percentage for buyback & burn
- `welcomeBonusAmount = 30 USDC` - welcome bonus
- `minInvestmentForBonus = 1000 USDC` - minimum for bonus
- `vestingWeeks = 40` - vesting period
- `weeklyUnlock = 2.5%` - weekly unlock

### Features:
- ✅ Integration with Uniswap for token price determination
- ✅ Automatic buyback & burn on project activation
- ✅ Linear vesting unlock
- ✅ Reentrancy protection
- ✅ UUPS Upgradeable
- ✅ Uses investor claim addresses from ManagerRegistry

---

## 4. Token.sol

**Purpose:** Platform ERC20 token with purchase control and minting mechanisms.

### Operating Modes:

#### Purchase Control:
- `buyingEnabled = false` (default) - purchasing disabled
- Transfers allowed only to pools and RewardSystem
- After `enableBuying()` - purchasing allowed for everyone
- `enableBuyingForever()` - enable forever (cannot be disabled)
- `canDisableBuying` - flag to prevent disabling after permanent enable

#### Minting Control:
- `mintingEnabled = true` (default)
- `disableMintingForever()` - disable forever

### Main Functions:

#### For RewardSystem:
- `mintReward(address to, uint256 amount)` - mint rewards (always available)

#### For Owner:
- `mint(address to, uint256 amount)` - regular mint (only if `mintingEnabled`)
- `enableBuying()` / `disableBuying()` - purchase management
- `enableBuyingForever()` - enable purchasing forever
- `disableMintingForever()` - disable minting forever
- `setManagerRegistry(address)` - update ManagerRegistry

#### For Everyone:
- `burn(uint256 amount)` - burn own tokens
- `transfer()` / `transferFrom()` - with `buyingEnabled` check
- `canBuy(address buyer)` - check if address can buy

### Access Modifiers:
- `onlyRewardSystem` - only RewardSystem can call
- `canTransfer(address to)` - check transfer permission

### Features:
- ✅ Protection against early purchases before enable
- ✅ Transfers to pools allowed even when purchasing is disabled
- ✅ Irreversible minting disable for tokenomics finalization
- ✅ NOT upgradeable (regular contract)

---

## 5. Treasury.sol

**Purpose:** Platform treasury for storing fees and other funds.

### Main Functions:

#### For Owner:
- `withdraw(address _token, uint256 _amount, address _recepient)` - withdraw tokens

### Features:
- ✅ Extremely simple contract
- ✅ Receives platform fees from Fundraise
- ✅ UUPS Upgradeable
- ✅ Only owner can withdraw funds

---

## Contract Interactions

### Investment Process:

```
1. Investor → Fundraise.investUpdate()
2. Fundraise → RewardSystem.recordInvestment()
3. RewardSystem registers:
   - Referral bonus to inviter
   - Welcome bonus (if new user)
   - Tokens in vesting for investor
```

### Project Activation Process:

```
1. Borrower/Manager → Fundraise.transferFundsToBorrower()
2. Fundraise:
   - Transfers funds to borrower (minus fee)
   - Transfers fee to Treasury
3. Fundraise → RewardSystem.activateProjectRewards()
4. RewardSystem:
   - Buys back tokens from Uniswap
   - Burns bought tokens
   - Activates vesting for all project investors
```

### Reward Claiming Process:

```
1. User → RewardSystem.claimUSDCForProject()
   RewardSystem → User (USDC) [via claim address]

2. User → RewardSystem.claimTokensForProject()
   RewardSystem → Token.mintReward()
   Token → User (new tokens) [via claim address]
```

---

## Access Rights

| Function | Owner | Manager | Fundraise | RewardSystem | User |
|---------|-------|---------|-----------|--------------|------|
| Create project | - | ✅ | - | - | - |
| Invest | - | - | - | - | ✅ |
| Claim rewards | - | - | - | - | ✅ |
| Withdraw from Treasury | ✅ | - | - | - | - |
| Mint tokens | ✅ | - | - | ✅ | - |
| Manage ManagerRegistry | ✅ | - | - | - | - |
| Upgrade contracts | ✅ | - | - | - | - |
| Set investor claim address | ✅ | - | - | - | - |

---

## Security

### Attack Protection:
- ✅ ReentrancyGuard in RewardSystem
- ✅ SafeERC20 for all token transfers
- ✅ Merkle proof for whitelist
- ✅ Trusted signer signature verification
- ✅ Nonce check for replay attack protection

### Access Control:
- ✅ All admin functions through ManagerRegistry
- ✅ Centralized permission management
- ✅ Role separation (owner, manager, system contracts)

### Upgradeability:
- ✅ UUPS pattern for all main contracts
- ✅ Storage layout compatibility on upgrade
- ✅ Initializers protected from re-invocation

---

## Constants and Magic Numbers

- `BASIS_POINTS = 1_000_000` (100% = 1_000_000, 1% = 10_000)
- Vesting: 40 weeks at 2.5% per week
- Welcome bonus: 30 USDC on investment ≥1000 USDC
- Fees: 6% (referral, tokens, burn) - configurable

---

## Deployment Sequence

```bash
1. Deploy ManagerRegistry
2. Deploy Treasury
3. Deploy Token(managerRegistry)
4. Deploy RewardSystem(managerRegistry, token, usdc, uniswapRouter)
5. Deploy Fundraise(treasury, managerRegistry, trustedSigner, rewardSystem)
6. ManagerRegistry.setContractAddresses(rewardSystem, fundraise, treasury)
7. ManagerRegistry.setManagerStatus(manager, true)
8. Create Uniswap pool (Token/USDC)
9. ManagerRegistry.setPoolStatus(pool, true)
```

---

## Contract Upgrades

### Fundraise Upgrade with New ManagerRegistry:
```bash
1. Deploy new ManagerRegistry
2. Deploy new RewardSystem
3. Fundraise.upgradeTo(newImplementation)
4. Fundraise.setManagerRegistry(newManagerRegistry)
5. Fundraise.setRewardSystem(newRewardSystem)
```

### Upgrade Compatibility:
- ✅ Fundraise: compatible (storage layout preserved)
- ✅ ManagerRegistry: fresh deploy recommended
- ✅ Treasury: compatible or fresh deploy
- ✅ RewardSystem: compatible
- ⚠️ Token: NOT upgradeable

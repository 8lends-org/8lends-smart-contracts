// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {Eip712Signing} from "./helpers/Eip712Signing.sol";

// Protocol contracts
import {Fundraise} from "../../contracts/core/Fundraise.sol";
import {Token} from "../../contracts/token/8lnds/Token.sol";
import {ManagerRegistry} from "../../contracts/core/ManagerRegistry.sol";
import {RewardSystem} from "../../contracts/core/RewardSystem.sol";
import {Rewards2} from "../../contracts/core/Rewards2.sol";
import {Rewards2Harness} from "./mocks/Rewards2Harness.sol";
import {RewardSystemHarness} from "./mocks/RewardSystemHarness.sol";
import {Treasury} from "../../contracts/core/Treasury.sol";

// OpenZeppelin proxy
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mocks
import "./mocks/MockUSDC.sol";
import "./mocks/MockUniswapV2Router.sol";
import {MockOracle} from "../../contracts/mocks/MockOracle.sol";

/// @notice Base test setup — deploys all protocol contracts and configures roles.
/// @dev Mirrors the Hardhat deployment from test/helpers.ts.
///      All test files inherit from this contract.
abstract contract Setup is Test, Eip712Signing {
    // ── Contracts ──
    Fundraise public fundraise;
    Token public token;
    ManagerRegistry public managerRegistry;
    RewardSystemHarness public rewardSystem;
    Rewards2Harness public rewards2;
    Treasury public treasury;
    MockUSDC public usdc;
    MockUniswapV2Router public mockRouter;
    MockOracle public mockOracle;

    // ── Actors ──
    address public owner;
    address public manager;
    address public borrower;
    address public investor;
    address public investor2;
    address public inviter;
    address public attacker;
    /// @dev Operator role only — deliberately NOT a manager, so tests can prove the
    ///      two roles are separate and a manager cannot call operator methods.
    address public operator;
    /// @dev Admin role only, and held by nobody else: parameters and the claim-for-user buttons
    ///      moved here from the manager and the owner, and a fixture that blurred the sets would
    ///      pass whichever of the three still had the right.
    address public admin;

    // backend = trusted signer (we need its private key for vm.sign)
    uint256 public backendPk;
    address public backend;

    // ── Constants ──
    uint256 public constant BASIS_POINTS = 1_000_000;
    uint256 public constant PLATFORM_FEE = 30_000; // 3%
    uint256 public constant INVESTOR_INTEREST = 200_000; // 20%

    function setUp() public virtual {
        // ── Create actors ──
        owner = makeAddr("owner");
        manager = makeAddr("manager");
        borrower = makeAddr("borrower");
        investor = makeAddr("investor");
        investor2 = makeAddr("investor2");
        inviter = makeAddr("inviter");
        attacker = makeAddr("attacker");
        operator = makeAddr("operator");
        admin = makeAddr("admin");
        (backend, backendPk) = makeAddrAndKey("backend");

        // Foundry starts at timestamp=1. Set a realistic timestamp.
        vm.warp(1_700_000_000);

        vm.startPrank(owner);

        // ── Deploy MockUSDC ──
        usdc = new MockUSDC();

        // ── Deploy Token (non-upgradeable) ──
        token = new Token();

        // ── Deploy ManagerRegistry (UUPS proxy) ──
        {
            ManagerRegistry impl = new ManagerRegistry();
            bytes memory initData = abi.encodeCall(ManagerRegistry.initialize, ());
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            managerRegistry = ManagerRegistry(address(proxy));
        }

        // ── Deploy Treasury (UUPS proxy) ──
        {
            Treasury impl = new Treasury();
            bytes memory initData = abi.encodeCall(Treasury.initialize, ());
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            treasury = Treasury(address(proxy));
        }

        // ── Connect Token to ManagerRegistry ──
        token.setManagerRegistry(address(managerRegistry));

        // ── Deploy MockUniswapV2Router ──
        mockRouter = new MockUniswapV2Router(address(token), address(usdc));

        // ── Deploy RewardSystem (UUPS proxy) ──
        {
            RewardSystemHarness impl = new RewardSystemHarness();
            bytes memory initData = abi.encodeCall(
                RewardSystem.initialize,
                (address(managerRegistry), address(token), address(usdc), address(mockRouter))
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            rewardSystem = RewardSystemHarness(address(proxy));
            // The cutover stays where initialize put it: this block. Projects the fixture funds land
            // on it, so they survive with their first week in the token era — the state the upgrade
            // actually leaves behind. A project funded later is cancelled, which is the point.
        }

        // ── Deploy MockOracle — still priced for Fundraise, no longer read by RewardSystem ──
        mockOracle = new MockOracle();
        // 1 token = 0.01 USD → price = 0.01 * 1e8 = 1_000_000 (8 decimals)
        mockOracle.setPrice(address(token), 1_000_000);
        // USDC = 1.00 USD → price = 1e8 (8 decimals)
        mockOracle.setPrice(address(usdc), 1e8);

        // ── Deploy Fundraise (UUPS proxy) ──
        {
            Fundraise impl = new Fundraise();
            bytes memory initData = abi.encodeCall(
                Fundraise.initialize,
                (address(treasury), address(managerRegistry), backend, address(rewardSystem))
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            fundraise = Fundraise(address(proxy));
        }

        // ── Deploy Rewards2 (UUPS proxy) ──
        {
            Rewards2Harness impl = new Rewards2Harness();
            bytes memory initData = abi.encodeCall(
                Rewards2.initialize,
                (address(managerRegistry), address(token), address(usdc), address(mockRouter))
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            rewards2 = Rewards2Harness(address(proxy));
            // Default to vesting granted after the cutover, paid entirely in USDC. The token era
            // before it is set up by the tests that are about it.
            rewards2.setCutover(1);
        }

        // ── Configure ManagerRegistry ──
        address[] memory managers = new address[](2);
        managers[0] = owner;
        managers[1] = manager;
        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;
        managerRegistry.setManagerStatusBatch(managers, statuses);

        // Operator role: routine automated actions (bonus payouts). Granted to `operator`
        // and to nobody else — not to `owner`, not to `manager`. The whole point of the role
        // is that a hot backend key cannot also create projects, so the test fixture must not
        // blur the two sets.
        managerRegistry.setOperatorStatus(operator, true);

        // Admin role: platform parameters and the support buttons that move a payout forward.
        managerRegistry.setAdminStatus(admin, true);

        managerRegistry.setContractAddresses(
            address(rewardSystem),
            address(fundraise),
            address(treasury)
        );
        managerRegistry.setRewards2Address(address(rewards2));

        // Register mock router as pool (so Token transfers to it are allowed)
        managerRegistry.setPoolStatus(address(mockRouter), true);

        // ── Seed MockRouter with liquidity (tokens + USDC) ──
        token.mint(address(mockRouter), 10_000_000e18); // 10M tokens
        usdc.mint(address(mockRouter), 1_000_000e6); // 1M USDC

        // ── Seed RewardSystem with USDC for rewards ──
        usdc.mint(address(rewardSystem), 500_000e6);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                         HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev A project hash is spent on release and never comes back, so every call needs its own.
    uint256 private _projectHashSeq;

    function _nextProjectHash() internal returns (uint256) {
        return ++_projectHashSeq;
    }

    /// @notice Create a project via manager. Returns projectId.
    function _createProject(uint256 softCap, uint256 hardCap) internal returns (uint256 projectId) {
        return _createProjectFor(softCap, hardCap, borrower);
    }

    function _createProjectFor(uint256 softCap, uint256 hardCap, address _borrower)
        internal
        returns (uint256 projectId)
    {
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: hardCap,
            softCap: softCap,
            totalInvested: 0,
            startAt: block.timestamp - 10, // already started
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + 7 days,
            innerStruct: Fundraise.InnerProjectStruct({
                platformInterestRate: PLATFORM_FEE,
                totalRepaid: 0,
                borrower: _borrower,
                fundedTime: 0,
                loanToken: IERC20(address(usdc)),
                stage: Fundraise.Stage.ComingSoon
            })
        });

        vm.prank(manager);
        projectId = fundraise.createProject(proj, _nextProjectHash());
    }

    /// @notice Build the EIP-191 signature for investUpdateV2
    function _signInvest(
        address _investor,
        uint256 _pid,
        uint256 _amount,
        uint256 _nonce,
        address _inviter
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(abi.encode(INVEST_TYPEHASH, _investor, _pid, _amount, _nonce, _inviter));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, _eip712(address(fundraise), structHash));
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice Full invest flow: mint USDC → approve → sign → investUpdateV2
    function _investAs(address _investor, uint256 _pid, uint256 _amount, address _inviter) internal {
        // Mint USDC to investor
        vm.prank(owner);
        usdc.mint(_investor, _amount);

        // Approve Fundraise to spend
        vm.prank(_investor);
        usdc.approve(address(fundraise), _amount);

        // Build signature
        uint256 currentNonce = fundraise.userNonces(_investor);
        uint256 nonceForSig = currentNonce + 1;
        bytes memory sig = _signInvest(_investor, _pid, _amount, nonceForSig, _inviter);

        // Invest
        vm.prank(_investor);
        fundraise.investUpdateV2(_pid, _amount, nonceForSig, sig, _inviter);
    }

    /// @notice Transfer funds to borrower (transitions project to Funded)
    function _fundProject(uint256 _pid) internal {
        vm.prank(manager);
        fundraise.transferFundsToBorrower(_pid);
    }

    /// @notice Full repayment: repay totalInvested + interest
    function _repayFull(uint256 _pid) internal {
        (
            ,
            ,
            uint256 totalInvested,
            ,
            ,
            uint256 investorInterestRate,
            ,
        ) = fundraise.projects(_pid);

        uint256 totalOwed = totalInvested + (totalInvested * investorInterestRate) / BASIS_POINTS;

        vm.prank(owner);
        usdc.mint(borrower, totalOwed);

        vm.prank(borrower);
        usdc.approve(address(fundraise), totalOwed);

        vm.prank(borrower);
        fundraise.makeRepayment(_pid, totalOwed);
    }

    /// @notice Partial repayment of a specific amount
    function _repay(uint256 _pid, uint256 _amount) internal {
        vm.prank(owner);
        usdc.mint(borrower, _amount);

        vm.prank(borrower);
        usdc.approve(address(fundraise), _amount);

        vm.prank(borrower);
        fundraise.makeRepayment(_pid, _amount);
    }

    /// @dev Investing no longer accrues token rewards, and nothing mints against them either, so
    ///      vesting that predates the switch has to be seeded the way it now exists on chain: the
    ///      obligation written by the owner, the tokens already sitting on the contract.
    function _seedVesting(address _user, uint256 _pid, uint256 _amount) internal {
        vm.prank(owner);
        token.mint(address(rewardSystem), _amount);

        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory pids = new uint256[](1);
        users[0] = _user;
        amounts[0] = _amount;
        pids[0] = _pid;

        vm.prank(owner);
        rewardSystem.seedVestings(users, amounts, pids);
    }

    /**
     * The current block time, snapshotted so that a later `vm.warp` cannot move it.
     *
     * `uint256 t0 = block.timestamp` does not survive one. Reading the clock twice in a call can
     * only give one answer on a real chain, so solc is entitled to drop the local and re-emit
     * TIMESTAMP where it is used — and under the IR pipeline it does. A cheatcode warp breaks that
     * premise: the value read back is the warped one, every arithmetic built on it silently moves,
     * and the test goes on measuring a window it never set up.
     *
     * A cheatcode call cannot be folded away, so what it returns stays put.
     */
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }
}

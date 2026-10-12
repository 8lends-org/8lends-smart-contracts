// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../interfaces/protocol/IManagerRegistry.sol";
import "../interfaces/protocol/IRewardSystem.sol";
import "../interfaces/protocol/ILimitedSeller.sol";
import "../interfaces/protocol/IOracle.sol";

import {IEscrowFactory} from "../interfaces/protocol/IEscrowFactory.sol";
import {IMandateRouter} from "../mandate/interfaces/IMandateRouter.sol";
import {IMandateFactory} from "../mandate/interfaces/IMandateFactory.sol";
import {IMandateEscrowV1} from "../mandate/interfaces/IMandateEscrowV1.sol";

/// @title Fundraise - 8lends RWA lending platform
/// @notice Only standard ERC20 tokens are supported as loanToken.
/// Fee-on-transfer, rebasing, and deflationary tokens are NOT supported
/// and will cause accounting errors.
/// @notice 8lends uses a Real World Asset (RWA) lending model.
/// Loans are unsecured on-chain by design. Borrower creditworthiness
/// is assessed off-chain through underwriting. Legal recourse for
/// non-repayment is handled through off-chain legal framework.
contract Fundraise is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    error IncorrectNonce();
    error NotTrustedSigner();
    error InviterCannotBeInvestor();
    error ProjectNotFound();
    error CannotInvestInOwnProject();
    error ProjectClosedYet();
    error ProjectNotStarted(uint256 projectId, uint256 startAt);
    error InvestmentExceedsHardCap();
    error NotAManager();
    error AccountFrozen(address user);
    error ProjectDoesNotExist();
    error ProjectNotCanceled();
    error NoInvestmentToWithdraw();
    error InvalidStageForCancellation();
    error NotAMarket();
    error AddressZeroFrom();
    error AddressZeroTo();
    error FromAndToSame();
    error PositionIndexOutOfBounds();
    error PositionHasZeroAmount();
    error InvalidStageForTransfer();
    error NotFundedEnough();
    error RepaymentWrongStage();
    error InvalidStageForClaiming();
    error NoInvestmentFound();
    error CantUpdateFundedProject();
    error ProjectHashAlreadyUsed();
    error OpenStageExtensionTooLong();
    error WrongPercents();
    error ZeroAddress();
    error TotalInvestedMustBeZero();
    error TotalRepaidMustBeZero();
    error SoftCapMustBePositive();
    error HardCapMustBePositive();
    error SoftCapExceedsHardCap();
    error PreFundDurationMustBePositive();
    error BorrowerMustBeSet();
    error LoanTokenMustBeSet();
    error OracleNotSet();
    error LoanTokenPriceZero();
    error KycLessLimitExceeded();
    error NotAmlGateway();
    error LoanTokenNotUsdc();
    error NotAllowed();
    error NoMandateFactory();
    error NotMandateOf(address investor, address caller);
    error ProjectIsRouted(uint256 projectId);
    error ProjectNotRouted(uint256 projectId);
    error StalePriceData();
    error ProjectPayoutExceedsRepaid();

    event ProjectCreated(uint256 indexed projectId, address borrower, uint256 projectHash);
    event Invest(uint256 indexed projectId, address investor, uint256 amount);
    event InterestRepayment(uint256 indexed projectId, uint256 amount);
    event PrincipalRepayment(uint256 indexed projectId, uint256 amount);
    // totalInvested include platformFee
    event ProjectFunded(uint256 indexed projectId, address borrower, uint256 totalInvested, uint256 platformFee);
    event Claimed(uint256 indexed projectId, address investor, uint256 claimed);
    event WithdrawInvestment(uint256 indexed projectId, address investor, uint256 amount);
    event ProjectStatusChanged(uint256 indexed projectId, uint8 status);
    event ProjectUpdated(uint256 indexed projectId);
    event InvestorClaimAddressSet(address indexed investor, address indexed claimAddress);
    event InvestmentTransferred(
        uint256 indexed projectId,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 id
    );
    event ManagerRegistryUpdated(address managerRegistry);
    event TreasuryUpdated(address treasury);
    event RewardSystemUpdated(address rewardSystem);
    event TrustedSignerUpdated(address signer);
    event LimitedSellerUpdated(address limitedSeller);
    event AmlGatewayUpdated(address indexed oldGateway, address indexed newGateway);
    event OracleUpdated(address oracle);
    event MandateRouterUpdated(address mandateRouter);

    /// @notice Principal returned somewhere other than the investor. Silent when they coincide.
    event InvestmentRefunded(
        uint256 indexed projectId, address indexed investor, address indexed recipient, uint256 amount
    );

    /// @dev EIP-712 with the smallest domain that still pins the deployment: no name or version,
    ///      because the backend signs these and nobody reads them in a wallet. The typehash is what
    ///      keeps this message apart from the ones the same key signs for Market and LimitedSeller.
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 private constant INVEST_TYPEHASH =
        keccak256("Invest(address investor,uint256 projectId,uint256 amount,uint256 nonce,address inviter)");

    /// @notice What this implementation promises its callers, not a release number. It moves only
    ///         when a change breaks them — a method removed, an argument added, a signature format
    ///         replaced. An ordinary upgrade leaves it where it is, so a client that reads it once
    ///         can trust the answer until it changes.
    /// @dev No version() at all means a deployment older than this field, which signs the way
    ///      things were signed before EIP-712.
    uint256 public constant version = 2;

    uint256 public constant BASIS_POINTS = 1000000; // 1% = 10000
    uint256 public constant MAX_KYC_LESS_INVEST_USD = 500 * BASIS_POINTS; // 500_000_000 = 500 USD

    enum Stage {
        ComingSoon,
        Open,
        Canceled,
        PreFunded,
        Funded,
        Repaid
    }

    struct Project {
        uint256 hardCap;
        uint256 softCap;
        uint256 totalInvested;
        uint256 startAt;
        uint256 preFundDuration;
        uint256 investorInterestRate;
        uint256 openStageEndAt;
        InnerProjectStruct innerStruct;
    }

    struct InnerProjectStruct {
        uint256 platformInterestRate;
        uint256 totalRepaid;
        address borrower;
        uint256 fundedTime;
        IERC20 loanToken;
        Stage stage;
    }

    struct InvestorInfo {
        uint256 investedAmount;
        uint256 totalClaimed;
    }

    /// @notice projects info map
    mapping(uint256 => Project) public projects;

    /// @notice investor info map by project id
    mapping(address => mapping(uint256 => InvestorInfo)) public investorInfo; // msg.sender => projId => InvestorInfo

    /// @dev Deprecated: merkle whitelist roots are no longer used on-chain. Slot preserved for upgrade safety.
    mapping(uint256 => bytes32) private __deprecated_whitelistRoots;

    uint256 public projectCount;

    address public treasury;
    address public managerRegistry;

    uint256 private __deprecated_nonce;

    address public trustedSigner;

    address public rewardSystem;

    /// @notice Per-user nonce for replay protection (used by investUpdateV2)
    mapping(address => uint256) public userNonces;

    /// @notice LimitedSeller contract for accruing token-buy limits on invest
    address public limitedSeller;

    /// @notice Individual investment positions per (investor, project).
    /// Each invest() call pushes a new entry. Index serves as position ID.
    mapping(address => mapping(uint256 => InvestorInfo[])) internal _investorPositions;

    /// @notice Authorized AML gateway (EscrowFactory) that can call investFromEscrow
    address public amlGateway;

    /// @notice Net invested USD by investor (incremented on invest, decremented on withdrawal).
    /// @dev Used to enforce MAX_KYC_LESS_INVEST_USD cap for escrow (KYC-less) investments.
    mapping(address => uint256) public allTimeInvestedUSD;

    address public oracle;

    /// @notice Maximum acceptable oracle price age in seconds (0 = staleness check disabled)
    uint256 public maxPriceAge;

    /// @notice Cumulative amount claimed by all investors per project.
    /// @dev Defense-in-depth solvency backstop: claim() enforces this never exceeds totalRepaid.
    ///      Appended at end of storage for upgrade safety; 0 for pre-upgrade projects (which is
    ///      sound because total-ever-claimed is already bounded by totalRepaid via per-investor watermarks).
    mapping(uint256 => uint256) public projectTotalClaimed;

    /// @notice Off-chain ids already spent by createProject, so one project cannot be released twice.
    /// @dev The slot this takes is the slot it has to keep: the mandate work appends its own field
    ///      after it, and moving this one would leave every id recorded so far unfindable while the
    ///      guard went on answering, just never again about a spent one.
    mapping(uint256 => bool) public projectHashUsed;

    /// @notice Router holding the payout routes of mandates.
    /// @dev While zero every project reads as unrouted, so this can be deployed ahead of the router.
    address public mandateRouter;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _treasury,
        address _managerRegistry,
        address _trustedSigner,
        address _rewardSystem
    ) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        treasury = _treasury;
        managerRegistry = _managerRegistry;
        trustedSigner = _trustedSigner;
        rewardSystem = _rewardSystem;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Invest, with the backend's approval of this exact investment.
    /// @param _pid Project Id
    /// @param _amount Amount of loan token for invest
    /// @param _nonce Per-user nonce for replay protection
    /// @param _sig Signature of a trusted signer
    /// @param _inviter Inviter address
    function investUpdateV2(
        uint256 _pid,
        uint256 _amount,
        uint256 _nonce,
        bytes memory _sig,
        address _inviter
    ) external {
        _requireNotFrozen(msg.sender);
        if (_nonce != userNonces[msg.sender] + 1) revert IncorrectNonce();

        bytes32 structHash = keccak256(abi.encode(INVEST_TYPEHASH, msg.sender, _pid, _amount, _nonce, _inviter));
        _verifySignature(MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash), _sig);
        _invest(msg.sender, _pid, _amount, _inviter);
        userNonces[msg.sender]++;
    }

    /// @dev Built per call rather than cached: a cold SLOAD costs more than hashing three words,
    ///      and there is no initialiser left to run on a proxy that is already live.
    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    /// @dev ECDSA.recover carries the length, malleability and zero-address checks, so the only
    ///      thing left to say here is whose signature it has to be.
    function _verifySignature(bytes32 digest, bytes memory _sig) internal view {
        if (ECDSA.recover(digest, _sig) != trustedSigner) revert NotTrustedSigner();
    }

    function _invest(address _investor, uint256 _pid, uint256 _amount, address _inviter) internal {
        if (_inviter == _investor) revert InviterCannotBeInvestor();
        Project storage project = projects[_pid];
        if (!(project.softCap > 0 || project.hardCap > 0)) revert ProjectNotFound();
        if (project.innerStruct.borrower == _investor) revert CannotInvestInOwnProject();

        if (project.innerStruct.stage == Stage.ComingSoon) {
            if (block.timestamp >= project.startAt) {
                project.innerStruct.stage = Stage.Open;
                emit ProjectStatusChanged(_pid, uint8(Stage.Open));
            } else {
                revert ProjectNotStarted(_pid, project.startAt);
            }
        }
        // Past the deadline the raise is over whatever the stage still says. Recording that is
        // moveProjectStage's and cancelProject's job, so this one only refuses.
        if (project.innerStruct.stage != Stage.Open || block.timestamp > project.openStageEndAt) {
            revert ProjectClosedYet();
        }

        if (project.totalInvested + _amount > project.hardCap) revert InvestmentExceedsHardCap();

        uint256 _usdValue = _tryToUSD(_amount, address(project.innerStruct.loanToken));
        if (_usdValue > 0) {
            allTimeInvestedUSD[_investor] += _usdValue;
        }

        project.innerStruct.loanToken.safeTransferFrom(msg.sender, address(this), _amount);

        if (rewardSystem != address(0)) {
            IRewardSystem(rewardSystem).recordInvestment(
                _investor,
                _amount,
                _inviter,
                _pid,
                address(project.innerStruct.loanToken)
            );
        }

        if (limitedSeller != address(0)) {
            ILimitedSeller(limitedSeller).addEarnedLimit(_investor, _amount);
        }

        project.totalInvested += _amount;
        investorInfo[_investor][_pid].investedAmount += _amount;
        _investorPositions[_investor][_pid].push(InvestorInfo(_amount, 0));
        if (project.totalInvested >= project.hardCap) {
            project.openStageEndAt = block.timestamp;
            project.innerStruct.stage = Stage.PreFunded;
            emit ProjectStatusChanged(_pid, uint8(Stage.PreFunded));
        }

        emit Invest(_pid, _investor, _amount);
    }

    /// @notice Invest on behalf of a KYC-less investor via escrow (AML-cleared, capped at $500 lifetime).
    /// @dev Only path for investing without KYC. On-chain enforcement of MAX_KYC_LESS_INVEST_USD.
    /// @param _investor The address that will be recorded as investor
    /// @param _pid Project ID
    /// @param _amount Amount of loan token to invest
    /// @param _inviter Inviter address
    function investFromEscrow(
        address _investor,
        uint256 _pid,
        uint256 _amount,
        address _inviter
    ) external {
        // Safe to stop only because the other exit is stopped too: cancelRequest refunds to the
        // user's own address, and EscrowFactory now refuses that callback for a frozen account.
        // Both have to be closed together, or the freeze leaves one way out open.
        _requireNotFrozen(_investor);
        address gateway = amlGateway;
        if (gateway == address(0) || IEscrowFactory(gateway).escrows(_investor) != msg.sender) {
            revert NotAmlGateway();
        }
        if (address(projects[_pid].innerStruct.loanToken) != IEscrowFactory(gateway).usdc()) {
            revert LoanTokenNotUsdc();
        }

        uint256 amountInUSD = _toUSD(_amount, address(projects[_pid].innerStruct.loanToken));
        if (allTimeInvestedUSD[_investor] + amountInUSD > MAX_KYC_LESS_INVEST_USD) {
            revert KycLessLimitExceeded();
        }

        _invest(_investor, _pid, _amount, _inviter);
    }

    /// @notice Place a mandate's funds into a project, recording its owner as the investor.
    /// @dev No signature and no KYC-less cap: access control is the KYC signature spent creating
    ///      the mandate, and the caller can only be the owner's own escrow.
    /// @param _investor Mandate owner, recorded as the investor
    /// @param _amount Amount of loan token, pulled from the calling escrow
    function investFromMandate(address _investor, uint256 _pid, uint256 _amount, address _inviter) external {
        _requireNotFrozen(_investor);
        address factory = IManagerRegistry(managerRegistry).mandateFactory();
        if (factory == address(0)) revert NoMandateFactory();
        if (!IMandateFactory(factory).isEscrowOf(_investor, msg.sender)) {
            revert NotMandateOf(_investor, msg.sender);
        }

        _invest(_investor, _pid, _amount, _inviter);
    }

    /// @notice In case if project got cancelled, user can withdraw his investment
    /// @param _projectId Project Id
    /// @param _investor Whose principal is returned; the recipient is decided here, not passed in
    function withdrawInvestment(uint256 _projectId, address _investor) external {
        address escrow = _routeOf(_investor, _projectId);
        (address target, bool compromised) = _payoutTarget(_investor, escrow);
        // On the target, not the address named: on a chain the named one is the wallet that was
        // taken, and freezing it must not hold money that is already routed somewhere else.
        _requireNotFrozen(target);

        // Clean address: nobody may call for it, the platform included. Flagged: anybody may, and
        // the money still goes where this contract decides. The operator branch is not a
        // convenience — without it the principal of a cancelled mandate project would sit here
        // until the owner pressed a button he has no way of knowing about.
        if (
            msg.sender != _investor && !compromised
            && (escrow == address(0) || !IManagerRegistry(managerRegistry).isOperator(msg.sender))
        ) revert NotAllowed();

        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (project.innerStruct.stage != Stage.Canceled) revert ProjectNotCanceled();
        uint256 amount = investorInfo[_investor][_projectId].investedAmount;
        if (amount == 0) revert NoInvestmentToWithdraw();

        investorInfo[_investor][_projectId].investedAmount = 0;
        project.totalInvested -= amount;

        // Restore KYC-less limit: subtract USD value of withdrawn investment
        uint256 usdValue = _tryToUSD(amount, address(project.innerStruct.loanToken));
        if (usdValue > 0) {
            if (allTimeInvestedUSD[_investor] >= usdValue) {
                allTimeInvestedUSD[_investor] -= usdValue;
            } else {
                allTimeInvestedUSD[_investor] = 0;
            }
        }

        // Zero out all individual positions
        InvestorInfo[] storage positions = _investorPositions[_investor][_projectId];
        for (uint256 i = 0; i < positions.length; i++) {
            positions[i].investedAmount = 0;
            positions[i].totalClaimed = 0;
        }

        project.innerStruct.loanToken.safeTransfer(target, amount);
        emit WithdrawInvestment(_projectId, _investor, amount);
        if (target != _investor) emit InvestmentRefunded(_projectId, _investor, target, amount);
    }

    /// @notice Cancel project
    /// @param _projectId Project info
    function cancelProject(uint256 _projectId) external {
        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (
            !(
                project.innerStruct.stage == Stage.Open ||
                project.innerStruct.stage == Stage.PreFunded ||
                project.innerStruct.stage == Stage.ComingSoon
            )
        ) {
            revert InvalidStageForCancellation();
        }
        // The raise ran out of time without its soft cap: settled by the clock and the amount
        // raised, so anyone may record it — including an investor who wants their principal back.
        if (
            project.innerStruct.stage == Stage.Open &&
            block.timestamp > project.openStageEndAt &&
            project.totalInvested < project.softCap
        ) {
            project.innerStruct.stage = Stage.Canceled;
            emit ProjectStatusChanged(_projectId, uint8(Stage.Canceled));
            return;
        }
        if (
            project.innerStruct.stage == Stage.PreFunded &&
            block.timestamp > project.openStageEndAt + project.preFundDuration
        ) {
            project.innerStruct.stage = Stage.Canceled;
            emit ProjectStatusChanged(_projectId, uint8(Stage.Canceled));
            return;
        } else {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        }
        project.innerStruct.stage = Stage.Canceled;
        emit ProjectStatusChanged(_projectId, uint8(Stage.Canceled));
    }

    /// @notice Transfer a single investment position by index (used by Market for per-position sales)
    /// @param _projectId Project ID
    /// @param _from Source address (seller or market cell)
    /// @param _to Destination address (market cell or buyer)
    /// @param _positionIndex Index of the position in _from's positions array
    /// @param _id Sale ID for event tracking
    function transferPosition(
        uint256 _projectId,
        address _from,
        address _to,
        uint256 _positionIndex,
        uint256 _id
    ) external {
        if (!IManagerRegistry(managerRegistry).isMarket(msg.sender)) revert NotAMarket();
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (_from == address(0)) revert AddressZeroFrom();
        if (_to == address(0)) revert AddressZeroTo();
        if (_from == _to) revert FromAndToSame();
        if (_positionIndex >= _investorPositions[_from][_projectId].length) revert PositionIndexOutOfBounds();

        InvestorInfo storage pos = _investorPositions[_from][_projectId][_positionIndex];
        uint256 posAmount = pos.investedAmount;
        if (posAmount == 0) revert PositionHasZeroAmount();

        InvestorInfo storage fromAgg = investorInfo[_from][_projectId];
        uint256 posClaimed = positionClaimed(_from, _projectId, posAmount);

        // Update aggregate mappings
        fromAgg.investedAmount -= posAmount;
        fromAgg.totalClaimed -= posClaimed;
        investorInfo[_to][_projectId].investedAmount += posAmount;
        investorInfo[_to][_projectId].totalClaimed += posClaimed;

        // Move position: push derived watermark to _to, zero out in _from
        _investorPositions[_to][_projectId].push(InvestorInfo(posAmount, posClaimed));
        pos.investedAmount = 0;
        pos.totalClaimed = 0;

        emit InvestmentTransferred(_projectId, _from, _to, posAmount, _id);
    }

    function transferFundsToBorrower(uint256 _projectId) external {
        _transferFundsToBorrower(_projectId, 0);
    }

    function transferFundsToBorrower(uint256 _projectId, uint256 _maxUSDForReward) external {
        _transferFundsToBorrower(_projectId, _maxUSDForReward);
    }

    /// @notice When project is funded, transfer money for a borrower with max USD for reward
    /// @param _maxUSDForReward Priced the token reward the funding used to mint; RewardSystem
    ///        ignores it now, and the argument is kept so the caller keeps the same signature.
    /// @param _projectId Project info
    function _transferFundsToBorrower(uint256 _projectId, uint256 _maxUSDForReward) internal {
        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (msg.sender != project.innerStruct.borrower) {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        }
        if (
            !(project.innerStruct.stage == Stage.Open || project.innerStruct.stage == Stage.PreFunded)
        ) {
            revert InvalidStageForTransfer();
        }

        if (project.innerStruct.stage == Stage.Open) {
            if (project.totalInvested < project.softCap) revert NotFundedEnough();
        }

        uint256 platformFee = (project.totalInvested * project.innerStruct.platformInterestRate) / BASIS_POINTS;
        project.innerStruct.loanToken.safeTransfer(project.innerStruct.borrower, project.totalInvested - platformFee);
        project.innerStruct.stage = Stage.Funded;
        project.innerStruct.fundedTime = block.timestamp;

        if (platformFee > 0) project.innerStruct.loanToken.safeTransfer(treasury, platformFee);

        if (rewardSystem != address(0)) {
            IRewardSystem(rewardSystem).activateProjectRewards(_projectId, project.totalInvested, _maxUSDForReward);
        }

        emit ProjectFunded(_projectId, project.innerStruct.borrower, project.totalInvested, platformFee);
        emit ProjectStatusChanged(_projectId, uint8(Stage.Funded));
    }

    /// @notice Borrower repays money for a user
    /// @dev Repayment is enforced through off-chain legal agreements,
    /// not on-chain collateral or liquidation mechanisms.
    /// @notice Only borrower or manager can make repayments.
    /// Third-party repayment is restricted due to legal/regulatory requirements.
    /// This is an intentional design decision, not a missing feature.
    /// @param _projectId Project info
    /// @param _amount Amount of usdt for repayment
    function makeRepayment(uint256 _projectId, uint256 _amount) external {
        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (project.innerStruct.stage != Stage.Funded) revert RepaymentWrongStage();
        if (msg.sender != project.innerStruct.borrower) {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        }

        project.innerStruct.loanToken.safeTransferFrom(msg.sender, address(this), _amount);
        project.innerStruct.totalRepaid += _amount;

        if (
            project.innerStruct.totalRepaid >=
            project.totalInvested + ((project.totalInvested * project.investorInterestRate) / BASIS_POINTS)
        ) {
            project.innerStruct.stage = Stage.Repaid;
            emit PrincipalRepayment(_projectId, _amount);
            emit ProjectStatusChanged(_projectId, uint8(Stage.Repaid));
        } else {
            emit InterestRepayment(_projectId, _amount);
        }
    }

    /// @notice User claims his investment
    /// @param _projectId Project info
    /// @param _investor Whose payout is claimed; only he may call, unless his address was flagged
    /// @dev An admin may press it for him. The money still goes to recipientOf(_investor), so the
    ///      button cannot redirect anything — the same shape the reward contracts have had for
    ///      their payouts all along.
    function claim(uint256 _projectId, address _investor) external {
        address escrow = _routeOf(_investor, _projectId);
        (address target, bool compromised) = _payoutTarget(_investor, escrow);
        _requireNotFrozen(target);

        if (
            msg.sender != _investor && !compromised
                && !IManagerRegistry(managerRegistry).isAdmin(msg.sender)
        ) revert NotAllowed();

        // Called here the payout would land on the escrow without onPayout and count as principal,
        // so under WALLET and LEND the interest would never go where the owner asked. A flagged
        // address is exempt: its route does not apply, and this is the support button.
        if (escrow != address(0) && !compromised) revert ProjectIsRouted(_projectId);

        _claimTo(_projectId, _investor, target);
    }

    /// @notice Claim on a project routed to a mandate, handing the payout to the escrow to split.
    /// @dev Open to an operator because the money can only reach the owner's own escrow — which is
    ///      why the ordinary claim, whose money reaches a wallet, is not.
    /// @param _marketId Lending8 pool for the LEND direction; ignored by the others
    function claimForMandate(uint256 _projectId, address _investor, bytes32 _marketId) external {
        address escrow = _routeOf(_investor, _projectId);
        if (escrow == address(0)) revert ProjectNotRouted(_projectId);

        (address target, bool compromised) = _payoutTarget(_investor, escrow);
        _requireNotFrozen(target);
        if (
            msg.sender != _investor && !compromised
                && !IManagerRegistry(managerRegistry).isOperator(msg.sender)
        ) revert NotAllowed();

        (uint256 claimable, uint256 invested, uint256 claimed) = _claimTo(_projectId, _investor, target);

        // Only when the money really went to the escrow by route: a call into the recovery EOA
        // would not revert, so that mistake would be silent. Zero skipped — LEND reverts on it.
        if (!compromised && claimable > 0) {
            _notifyMandate(escrow, _projectId, claimable, invested, claimed, _marketId);
        }
    }

    /// @dev Its own function only to keep claimForMandate off a too-deep stack.
    function _notifyMandate(
        address _escrow,
        uint256 _projectId,
        uint256 _claimable,
        uint256 _invested,
        uint256 _claimed,
        bytes32 _marketId
    ) internal {
        IMandateEscrowV1(_escrow).onPayout(
            _projectId,
            _claimable,
            _claimed,
            positionOwed(_projectId, _invested) - _invested, // the interest part of it
            _marketId
        );
    }

    /// @dev Claim accounting, shared by both entry points. `claimed` is the value after the
    ///      increment, which is what onPayout expects.
    function _claimTo(uint256 _projectId, address _investor, address _target)
        internal
        returns (uint256 claimable, uint256 invested, uint256 claimed)
    {
        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (!(project.innerStruct.stage == Stage.Funded || project.innerStruct.stage == Stage.Repaid)) {
            revert InvalidStageForClaiming();
        }

        InvestorInfo storage investor = investorInfo[_investor][_projectId];
        invested = investor.investedAmount;
        if (invested == 0) revert NoInvestmentFound();

        uint256 claimableShare = Math.mulDiv(project.innerStruct.totalRepaid, invested, project.totalInvested);
        claimable = claimableShare > investor.totalClaimed ? claimableShare - investor.totalClaimed : 0;

        claimed = investor.totalClaimed + claimable;
        investor.totalClaimed = claimed;

        // Defense-in-depth: cumulative payouts on a project can never exceed what was repaid.
        // Correct per-investor watermarks already guarantee this; the guard is a backstop that
        // trips if watermark accounting ever regresses into a double-claim.
        uint256 newProjectClaimed = projectTotalClaimed[_projectId] + claimable;
        if (newProjectClaimed > project.innerStruct.totalRepaid) revert ProjectPayoutExceedsRepaid();
        projectTotalClaimed[_projectId] = newProjectClaimed;

        project.innerStruct.loanToken.safeTransfer(_target, claimable);

        emit Claimed(_projectId, _investor, claimable);
    }

    /// @notice Create new project
    /// @dev Only standard ERC20 tokens are supported as loanToken.
    /// Fee-on-transfer, rebasing, and deflationary tokens will cause accounting errors.
    /// @param _project Project info
    /// @param _projectHash Off-chain id of the project. Emitted, and spent: a second release of the
    ///        same project reverts, whichever tab or admin sends it.
    function createProject(Project memory _project, uint256 _projectHash) external returns (uint256) {
        if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        _validateProject(_project);
        if (projectHashUsed[_projectHash]) revert ProjectHashAlreadyUsed();
        projectHashUsed[_projectHash] = true;

        uint256 projectId = projectCount++;
        projects[projectId] = _project;
        emit ProjectCreated(projectId, _project.innerStruct.borrower, _projectHash);

        return projectId;
    }

    /// @notice Update project stage
    /// @param _projectId Project id
    function moveProjectStage(uint256 _projectId) external {
        // Was implied by the manager gate. Without it an id past the end reads as a ComingSoon
        // whose startAt is zero, and anyone could emit a status for a project that does not exist.
        if (_projectId >= projectCount) revert ProjectDoesNotExist();

        Project storage project = projects[_projectId];

        // Open on time: the condition is the clock alone, so nobody has to be trusted with it.
        if (project.innerStruct.stage == Stage.ComingSoon && block.timestamp >= project.startAt) {
            project.innerStruct.stage = Stage.Open;
            emit ProjectStatusChanged(_projectId, uint8(Stage.Open));
            return;
        }
        if (project.innerStruct.stage == Stage.Open && project.totalInvested >= project.softCap) {
            // Past the deadline the outcome is settled and recording it is bookkeeping. Before it,
            // closing the raise forfeits the room left up to the hard cap — that is a decision.
            bool early = block.timestamp <= project.openStageEndAt;
            if (early && !IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();

            project.innerStruct.stage = Stage.PreFunded;
            // Only an early close ends the raise now; past the deadline it ended at the deadline,
            // and preFundDuration is counted from there.
            if (early) project.openStageEndAt = block.timestamp;
            emit ProjectStatusChanged(_projectId, uint8(Stage.PreFunded));
            return;
        }
    }

    /// @notice Update project info
    /// @dev Only standard ERC20 tokens are supported as loanToken when replacing project in ComingSoon stage.
    /// @param _projectId Project id
    /// @param _project new project info
    function setProject(uint256 _projectId, Project memory _project) external {
        if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        // A number that was never created reads as stage ComingSoon, so without this the write
        // below would mint a project with no event and no hash.
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (
            !(
                projects[_projectId].innerStruct.stage == Stage.ComingSoon ||
                projects[_projectId].innerStruct.stage == Stage.Open
            )
        ) {
            revert CantUpdateFundedProject();
        }
        if (
            projects[_projectId].innerStruct.stage == Stage.ComingSoon && _project.innerStruct.stage == Stage.ComingSoon
        ) {
            _validateProject(_project);
            projects[_projectId] = _project;
            emit ProjectUpdated(_projectId);
        } else if (projects[_projectId].innerStruct.stage == Stage.Open) {
            if (_project.openStageEndAt > projects[_projectId].openStageEndAt) {
                if (_project.openStageEndAt - projects[_projectId].openStageEndAt > 30 days) {
                    revert OpenStageExtensionTooLong();
                }
                projects[_projectId].openStageEndAt = _project.openStageEndAt;
            }
            if (_project.innerStruct.platformInterestRate != projects[_projectId].innerStruct.platformInterestRate) {
                if (
                    _project.innerStruct.platformInterestRate <=
                    projects[_projectId].innerStruct.platformInterestRate
                ) {
                    revert WrongPercents();
                }
                projects[_projectId].innerStruct.platformInterestRate = _project.innerStruct.platformInterestRate;
            }
            if (_project.investorInterestRate != projects[_projectId].investorInterestRate) {
                if (_project.investorInterestRate <= projects[_projectId].investorInterestRate) {
                    revert WrongPercents();
                }
                projects[_projectId].investorInterestRate = _project.investorInterestRate;
            }
            emit ProjectUpdated(_projectId);
        }
    }

    /// @notice Update address of trusted signer
    /// @param _signer New address
    /// @notice Appointing a signer is the owner's; zeroing it is also an admin's.
    /// @dev Zero is the revocation, so the zero-address guard is deliberately gone. It stops
    ///      investUpdateV2 and the whole secondary market, which reads this signer through
    ///      IFundraise — accepted, because a leaked key has to be killable in one call by one
    ///      person. Escrow and mandate investments carry no signature and keep working.
    function setTrustedSigner(address _signer) external {
        if (_signer == address(0)) {
            if (msg.sender != owner() && !IManagerRegistry(managerRegistry).isAdmin(msg.sender)) {
                revert NotAllowed();
            }
        } else if (msg.sender != owner()) {
            revert NotAllowed();
        }
        trustedSigner = _signer;
        emit TrustedSignerUpdated(_signer);
    }

    /// @dev Zero while no router is set, so every project then reads as unrouted.
    /// @dev Read on whoever's money moves, not on the caller: a claim, a withdrawal and a mandate
    ///      investment all name their investor, and the caller may be an operator or anyone at all
    ///      once the address is compromised.
    function _requireNotFrozen(address _user) internal view {
        if (IManagerRegistry(managerRegistry).isFrozen(_user)) revert AccountFrozen(_user);
    }

    function _routeOf(address _investor, uint256 _projectId) internal view returns (address) {
        address router = mandateRouter;
        return router == address(0) ? address(0) : IMandateRouter(router).routes(_investor, _projectId);
    }

    /// @dev Where the money goes, and whether the address was superseded — both from one read, so
    ///      they cannot disagree. The order is the rule: a route never outranks the flag.
    function _payoutTarget(address _investor, address _escrow)
        internal
        view
        returns (address target, bool compromised)
    {
        address recipient = IManagerRegistry(managerRegistry).recipientOf(_investor);
        compromised = recipient != _investor;
        target = compromised ? recipient : (_escrow == address(0) ? _investor : _escrow);
    }

    /// @notice Sets the mandate router. Zero switches every mandate path off: payouts fall back to
    ///         wallets and claimForMandate reverts.
    function setMandateRouter(address _mandateRouter) external onlyOwner {
        mandateRouter = _mandateRouter;
        emit MandateRouterUpdated(_mandateRouter);
    }

    /// @notice Update manager registry address
    /// @param _managerRegistry New manager registry address
    function setManagerRegistry(address _managerRegistry) external onlyOwner {
        if (_managerRegistry == address(0)) revert ZeroAddress();
        managerRegistry = _managerRegistry;
        emit ManagerRegistryUpdated(_managerRegistry);
    }

    /// @notice Update treasury address
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @notice Update reward system address
    /// @param _rewardSystem New reward system address
    /// @dev address(0) disables the reward system integration
    function setRewardSystem(address _rewardSystem) external onlyOwner {
        rewardSystem = _rewardSystem;
        emit RewardSystemUpdated(_rewardSystem);
    }

    /// @notice Update LimitedSeller address for token-buy limit accrual
    /// @param _limitedSeller New LimitedSeller address
    /// @dev address(0) disables the limit accrual integration
    function setLimitedSeller(address _limitedSeller) external onlyOwner {
        limitedSeller = _limitedSeller;
        emit LimitedSellerUpdated(_limitedSeller);
    }

    /// @notice Update AML gateway address (EscrowFactory) authorized to call investFromEscrow
    /// @param _amlGateway New AML gateway address
    /// @dev address(0) effectively disables escrow investing
    function setAmlGateway(address _amlGateway) external onlyOwner {
        address oldGateway = amlGateway;
        amlGateway = _amlGateway;
        emit AmlGatewayUpdated(oldGateway, _amlGateway);
    }

    /// @notice Set maximum acceptable oracle price age (0 = disabled)
    /// @param _maxPriceAge Max age in seconds
    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        maxPriceAge = _maxPriceAge;
    }

    /// @notice Validate project struct invariants
    function _validateProject(Project memory _project) internal pure {
        if (_project.totalInvested != 0) revert TotalInvestedMustBeZero();
        if (_project.innerStruct.totalRepaid != 0) revert TotalRepaidMustBeZero();
        if (_project.softCap == 0) revert SoftCapMustBePositive();
        if (_project.hardCap == 0) revert HardCapMustBePositive();
        if (_project.softCap > _project.hardCap) revert SoftCapExceedsHardCap();
        if (_project.preFundDuration == 0) revert PreFundDurationMustBePositive();
        if (_project.innerStruct.borrower == address(0)) revert BorrowerMustBeSet();
        if (address(_project.innerStruct.loanToken) == address(0)) revert LoanTokenMustBeSet();
    }

    /// @notice Get investors available amount for claim
    /// @param _projectId ProjectId
    /// @param _investor User address
    function availableToClaim(uint256 _projectId, address _investor) public view returns (uint256 claimable) {
        Project memory project = projects[_projectId];
        Stage stage = project.innerStruct.stage;
        if (stage != Stage.Funded && stage != Stage.Repaid) {
            return 0;
        }

        InvestorInfo memory investor = investorInfo[_investor][_projectId];
        if (investor.investedAmount == 0) {
            return 0;
        }

        uint256 claimableShare =
            Math.mulDiv(project.innerStruct.totalRepaid, investor.investedAmount, project.totalInvested);

        claimable = claimableShare > investor.totalClaimed ? claimableShare - investor.totalClaimed : 0;
    }

    /// @notice How much of this position's principal has not come back yet.
    /// @dev totalClaimed mixes principal and interest, so it is read through the interest-first
    ///      waterfall: a claim is interest until the budget is spent, principal after. The mandate
    ///      escrow splits payouts by the same rule in onPayout, and the two have to agree.
    function outstandingPrincipal(address _investor, uint256 _projectId) external view returns (uint256) {
        InvestorInfo storage investor = investorInfo[_investor][_projectId];
        uint256 invested = investor.investedAmount;
        if (invested == 0) return 0;

        uint256 owed = positionOwed(_projectId, invested);
        uint256 claimed = investor.totalClaimed;
        // The cap is the interest-first rule: what is owed beyond the principal is untaken interest.
        return owed > claimed ? Math.min(invested, owed - claimed) : 0;
    }

    /// @notice What a position of this size has effectively claimed: the holder's aggregate
    ///         watermark apportioned to it. Nowhere in storage — claim() never writes the
    ///         per-position field, so that one is stale.
    /// @dev Rounded up, in the pool's favour, so a drained position is never taken for untouched
    ///      on a transfer, nor priced as if it were on a listing.
    function positionClaimed(address _investor, uint256 _projectId, uint256 _invested)
        public
        view
        returns (uint256)
    {
        InvestorInfo storage investor = investorInfo[_investor][_projectId];
        if (investor.investedAmount == 0) return 0;
        return Math.mulDiv(investor.totalClaimed, _invested, investor.investedAmount, Math.Rounding.Ceil);
    }

    /// @notice Everything a position of this size can ever claim: its share of the project's debt,
    ///         floored exactly as a claim floors it. The one definition of that ceiling.
    /// @dev Not the rate applied to the position — that floors at another scale and lands a unit
    ///      off, which is enough to block clearIfEmpty for good.
    function positionOwed(uint256 _projectId, uint256 _invested) public view returns (uint256) {
        Project storage project = projects[_projectId];
        uint256 totalInvested = project.totalInvested;
        if (totalInvested == 0) return _invested;

        uint256 owed = totalInvested + (totalInvested * project.investorInterestRate) / BASIS_POINTS;
        return Math.mulDiv(owed, _invested, totalInvested);
    }

    /// @notice Get all individual investment positions for an investor in a project
    /// @param _investor Investor address
    /// @param _projectId Project ID
    function getInvestorPositions(address _investor, uint256 _projectId) external view returns (InvestorInfo[] memory) {
        return _investorPositions[_investor][_projectId];
    }

    /// @notice Get the number of individual positions for an investor in a project
    /// @param _investor Investor address
    /// @param _projectId Project ID
    function getPositionCount(address _investor, uint256 _projectId) external view returns (uint256) {
        return _investorPositions[_investor][_projectId].length;
    }

    /// @notice Pre-check for KYC-less escrow cap ($500). Call via `eth_call` before creating escrow request.
    /// @dev Returns `false` if the investment would exceed MAX_KYC_LESS_INVEST_USD. Invalid `_projectId` returns `false`.
    function kycLessInvestable(uint256 _projectId, address _investor, uint256 _investAmount) external view returns (bool) {
        if (_projectId >= projectCount) return false;
        uint256 amountInUSD = _toUSD(_investAmount, address(projects[_projectId].innerStruct.loanToken));
        if (allTimeInvestedUSD[_investor] + amountInUSD > MAX_KYC_LESS_INVEST_USD) {
            return false;
        }
        return true;
    }

    /// @notice Set oracle address for manipulation-resistant pricing
    /// @param _oracle Oracle contract address
    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = _oracle;
        emit OracleUpdated(_oracle);
    }

    /// @notice Best-effort USD conversion: returns 0 if token cannot be priced (no oracle, not USDC).
    /// @dev Used in _invest to track allTimeInvestedUSD without blocking non-USDC investments.
    ///      Safe because investFromEscrow enforces loanToken == USDC (always priceable).
    function _tryToUSD(uint256 _amount, address _loanToken) internal view returns (uint256) {
        if (oracle != address(0)) {
            return _toUSD(_amount, _loanToken);
        }
        if (rewardSystem != address(0) && _loanToken == IRewardSystem(rewardSystem).usdc()) {
            return _amount;
        }
        return 0;
    }

    /// @notice Convert token amount to USD in Fundraise scale (BASIS_POINTS = 1 USD = 1_000_000).
    /// @dev If oracle is not set, falls back to 1:1 for USDC (6 dec, same scale as BASIS_POINTS).
    ///      For any other token without oracle — reverts.
    function _toUSD(uint256 _amount, address _loanToken) internal view returns (uint256) {
        if (oracle == address(0)) {
            bool isUsdc = rewardSystem != address(0) &&
                _loanToken == IRewardSystem(rewardSystem).usdc();
            if (!isUsdc) revert OracleNotSet();
            return _amount;
        }
        IOracle.PriceResult memory loanPriceResult = IOracle(oracle).getPrice(_loanToken);
        if (loanPriceResult.price == 0) revert LoanTokenPriceZero();

        // Staleness guard (opt-in: maxPriceAge > 0)
        if (maxPriceAge > 0) {
            uint256 updatedAt;
            if (loanPriceResult.priceSource == IOracle.PriceSource.Pyth) {
                updatedAt = loanPriceResult.pythUpdatedAt;
            } else if (loanPriceResult.priceSource == IOracle.PriceSource.ChainLink) {
                updatedAt = loanPriceResult.chainLinkUpdatedAt;
            }
            // Uniswap is on-chain (always fresh); None has no timestamp to check
            if (
                loanPriceResult.priceSource == IOracle.PriceSource.Pyth ||
                loanPriceResult.priceSource == IOracle.PriceSource.ChainLink
            ) {
                if (block.timestamp - updatedAt > maxPriceAge) revert StalePriceData();
            }
        }

        uint8 priceDecimals = IOracle(oracle).priceDecimals();
        uint8 loanTokenDecimals = IERC20Metadata(_loanToken).decimals();
        return Math.mulDiv(
            _amount,
            uint256(loanPriceResult.price) * BASIS_POINTS,
            10 ** (uint256(priceDecimals) + uint256(loanTokenDecimals))
        );
    }

}

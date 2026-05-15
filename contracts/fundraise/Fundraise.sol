// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IManagerRegistry.sol";
import "./interfaces/IRewardSystem.sol";
import "./interfaces/ILimitedSeller.sol";
import "./interfaces/IOracle.sol";

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
    error InvalidSignatureSValue();
    error InvalidSignature();
    error NotTrustedSigner();
    error InviterCannotBeInvestor();
    error ProjectNotFound();
    error CannotInvestInOwnProject();
    error ProjectClosedYet();
    error InvestmentExceedsHardCap();
    error NotAManager();
    error ProjectDoesNotExist();
    error ProjectNotCanceled();
    error NoInvestmentToWithdraw();
    error InvalidStageForCancellation();
    error NotAMarket();
    error ProjectNotInFundedStage();
    error AddressZeroFrom();
    error AddressZeroTo();
    error FromAndToSame();
    error FromNotFoundInProject();
    error PositionIndexOutOfBounds();
    error PositionHasZeroAmount();
    error InvalidStageForTransfer();
    error NotFundedEnough();
    error RepaymentWrongStage();
    error InvalidStageForClaiming();
    error NoInvestmentFound();
    error CantUpdateFundedProject();
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
    error PositionsAlreadyExist();
    error InvestorHasClaimed();
    error AmountMustBePositive();
    error SumMismatchWithAggregate();
    error InvalidSignatureLength();
    error OracleNotSet();
    error LoanTokenPriceZero();
    error ArrayLengthMismatch();

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
    event OracleUpdated(address oracle);

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

    /// @dev Deprecated: global nonce replaced by per-user userNonces. Slot preserved for upgrade safety.
    /// TODO: remove after frontend migrates to investUpdateV2 (read userNonces instead of nonce).
    uint256 public nonce;

    address public trustedSigner;

    address public rewardSystem;

    /// @notice Per-user nonce for replay protection (used by investUpdateV2)
    mapping(address => uint256) public userNonces;

    /// @notice LimitedSeller contract for accruing token-buy limits on invest
    address public limitedSeller;

    /// @notice Individual investment positions per (investor, project).
    /// Each invest() call pushes a new entry. Index serves as position ID.
    mapping(address => mapping(uint256 => InvestorInfo[])) internal _investorPositions;

    /// @notice All time invested USD by investor 
    mapping(address => uint256) public allTimeInvestedUSD;

    address public oracle;

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

    /// @notice LEGACY — old frontend/backend use global nonce + rootHash in signature.
    /// @dev TODO: remove after frontend migrates to investUpdateV2.
    /// @param _pid Project Id
    /// @param _amount Amount of loan token for invest
    /// @param _rootHash Included in signature verification for backward compat
    /// @param _nonce Global nonce for replay protection (legacy)
    /// @param _sig Signature of a trusted signer
    /// @param _inviter Inviter address
    function investUpdate(
        uint256 _pid,
        uint256 _amount,
        bytes32 _rootHash,
        uint256 _nonce,
        bytes memory _sig,
        address _inviter
    ) external {
        if (_nonce != nonce + 1) revert IncorrectNonce();

        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(msg.sender, _pid, _amount, _rootHash, _nonce, _inviter))
            )
        );
        _verifySignature(ethSignedMessageHash, _sig);
        bool success = _invest(_pid, _amount, _inviter);
        if (success) {
            nonce++;
        }
    }

    /// @notice New invest with per-user nonce and no rootHash in signature.
    /// @dev Migrate frontend/backend to use this function after upgrade.
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
        if (_nonce != userNonces[msg.sender] + 1) revert IncorrectNonce();

        // New signature format without rootHash
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(msg.sender, _pid, _amount, _nonce, _inviter))
            )
        );
        _verifySignature(ethSignedMessageHash, _sig);
        bool success = _invest(_pid, _amount, _inviter);
        if (success) {
            userNonces[msg.sender]++;
        }
    }

    /// @dev Verify ECDSA signature against trustedSigner with malleability protection
    function _verifySignature(bytes32 ethSignedMessageHash, bytes memory _sig) internal view {
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_sig);
        // Prevent signature malleability (as in OpenZeppelin ECDSA)
        if (
            uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) {
            revert InvalidSignatureSValue();
        }
        address signer = ecrecover(ethSignedMessageHash, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        if (signer != trustedSigner) revert NotTrustedSigner();
    }

    function _invest(uint256 _pid, uint256 _amount, address _inviter) internal returns (bool) {
        if (_inviter == msg.sender) revert InviterCannotBeInvestor();
        Project storage project = projects[_pid];
        if (!(project.softCap > 0 || project.hardCap > 0)) revert ProjectNotFound();
        if (project.innerStruct.borrower == msg.sender) revert CannotInvestInOwnProject();

        if (project.innerStruct.stage == Stage.ComingSoon) {
            if (block.timestamp >= project.startAt) {
                project.innerStruct.stage = Stage.Open;
                emit ProjectStatusChanged(_pid, uint8(Stage.Open));
            } else {
                return false;
            }
        }
        if (project.innerStruct.stage != Stage.Open) revert ProjectClosedYet();
        if (block.timestamp > project.openStageEndAt) {
            if (project.totalInvested >= project.softCap) {
                project.innerStruct.stage = Stage.PreFunded;
                project.openStageEndAt = block.timestamp;
                emit ProjectStatusChanged(_pid, uint8(Stage.PreFunded));
                return false;
            } else {
                project.innerStruct.stage = Stage.Canceled;
                emit ProjectStatusChanged(_pid, uint8(Stage.Canceled));
                return false;
            }
        }

        if (project.totalInvested + _amount > project.hardCap) revert InvestmentExceedsHardCap();

        allTimeInvestedUSD[msg.sender] += _toUSD(_amount, address(project.innerStruct.loanToken));

        project.innerStruct.loanToken.safeTransferFrom(msg.sender, address(this), _amount);

        if (rewardSystem != address(0)) {
            IRewardSystem(rewardSystem).recordInvestment(
                msg.sender,
                _amount,
                _inviter,
                _pid,
                address(project.innerStruct.loanToken)
            );
        }

        if (limitedSeller != address(0)) {
            ILimitedSeller(limitedSeller).addEarnedLimit(msg.sender, _amount);
        }

        project.totalInvested += _amount;
        investorInfo[msg.sender][_pid].investedAmount += _amount;
        _investorPositions[msg.sender][_pid].push(InvestorInfo(_amount, 0));
        if (project.totalInvested >= project.hardCap) {
            project.openStageEndAt = block.timestamp;
            project.innerStruct.stage = Stage.PreFunded;
            emit ProjectStatusChanged(_pid, uint8(Stage.PreFunded));
        }

        emit Invest(_pid, msg.sender, _amount);
        return true;
    }

    /// @notice In case if project got cancelled, user can withdraw his investment
    /// @param _projectId Project Id
    /// @param _investor User address, in case if manager will withdraw money for user
    function withdrawInvestment(uint256 _projectId, address _investor) external {
        if (msg.sender != _investor) {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        }
        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (project.innerStruct.stage != Stage.Canceled) revert ProjectNotCanceled();
        uint256 amount = investorInfo[_investor][_projectId].investedAmount;
        if (amount == 0) revert NoInvestmentToWithdraw();

        investorInfo[_investor][_projectId].investedAmount = 0;
        project.totalInvested -= amount;

        // Zero out all individual positions
        InvestorInfo[] storage positions = _investorPositions[_investor][_projectId];
        for (uint256 i = 0; i < positions.length; i++) {
            positions[i].investedAmount = 0;
            positions[i].totalClaimed = 0;
        }

        // Use claim address if set, otherwise use original investor address
        address payoutAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_investor);

        project.innerStruct.loanToken.safeTransfer(payoutAddress, amount);
        emit WithdrawInvestment(_projectId, _investor, amount);
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

    function transferInvestment(uint256 _projectId, address _from, address _to, bool _isSell, uint256 _id) external {
        if (!IManagerRegistry(managerRegistry).isMarket(msg.sender)) revert NotAMarket();
        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (_isSell) {
            if (project.innerStruct.stage != Stage.Funded) revert ProjectNotInFundedStage();
        }
        if (_from == address(0)) revert AddressZeroFrom();
        if (_to == address(0)) revert AddressZeroTo();
        if (_from == _to) revert FromAndToSame();
        uint256 amountInvested = investorInfo[_from][_projectId].investedAmount;
        uint256 amountClaimed = investorInfo[_from][_projectId].totalClaimed;

        if (amountInvested == 0) revert FromNotFoundInProject();

        investorInfo[_to][_projectId].investedAmount += amountInvested;
        investorInfo[_to][_projectId].totalClaimed += amountClaimed;
        investorInfo[_from][_projectId].investedAmount = 0;
        investorInfo[_from][_projectId].totalClaimed = 0;
        emit InvestmentTransferred(_projectId, _from, _to, amountInvested, _id);
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
        uint256 posClaimed = pos.totalClaimed;
        if (posAmount == 0) revert PositionHasZeroAmount();

        // Update aggregate mappings
        investorInfo[_from][_projectId].investedAmount -= posAmount;
        investorInfo[_from][_projectId].totalClaimed -= posClaimed;
        investorInfo[_to][_projectId].investedAmount += posAmount;
        investorInfo[_to][_projectId].totalClaimed += posClaimed;

        // Move position: push to _to, zero out in _from
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
    /// @param _maxUSDForReward - how much USD is allowed to be used for reward, for frontrun protection
    /// @dev Calculation of _maxUSDForReward: Set to 6% of project.totalInvested, then add 1% of that 6% as a slippage buffer.
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
    /// @param _investor User address, in case if manager will withdraw money for user
    function claim(uint256 _projectId, address _investor) external {
        if (msg.sender != _investor) {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        }

        Project storage project = projects[_projectId];
        if (_projectId >= projectCount) revert ProjectDoesNotExist();
        if (!(project.innerStruct.stage == Stage.Funded || project.innerStruct.stage == Stage.Repaid)) {
            revert InvalidStageForClaiming();
        }

        InvestorInfo storage investor = investorInfo[_investor][_projectId];
        if (investor.investedAmount == 0) revert NoInvestmentFound();
        uint256 investorShare = (investor.investedAmount * BASIS_POINTS) / project.totalInvested; // Basis points
        uint256 claimableShare = (project.innerStruct.totalRepaid * investorShare) / BASIS_POINTS; // Numeric

        uint256 claimable = claimableShare > investor.totalClaimed ? claimableShare - investor.totalClaimed : 0; // Numeric

        investor.totalClaimed += claimable; // Numeric

        // Use claim address if set, otherwise use original investor address
        address payoutAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_investor);

        project.innerStruct.loanToken.safeTransfer(payoutAddress, claimable);

        emit Claimed(_projectId, _investor, claimable);
    }

    /// @notice Backward-compatible: create project with whitelistRoot (ignored).
    /// @dev TODO: remove after admin frontend stops passing whitelistRoot.
    function createProject(Project memory _project, bytes32, uint256 _projectHash) external returns (uint256) {
        return _createProjectInternal(_project, _projectHash);
    }

    /// @notice Create new project (clean version without whitelistRoot)
    /// @dev Only standard ERC20 tokens are supported as loanToken.
    /// Fee-on-transfer, rebasing, and deflationary tokens will cause accounting errors.
    /// @param _project Project info
    /// @param _projectHash project hash, for event
    function createProject(Project memory _project, uint256 _projectHash) external returns (uint256) {
        return _createProjectInternal(_project, _projectHash);
    }

    function _createProjectInternal(Project memory _project, uint256 _projectHash) internal returns (uint256) {
        if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        _validateProject(_project);

        uint256 projectId = projectCount++;
        projects[projectId] = _project;
        emit ProjectCreated(projectId, _project.innerStruct.borrower, _projectHash);

        return projectId;
    }

    /// @notice Update project stage
    /// @param _projectId Project id
    function moveProjectStage(uint256 _projectId) external {
        if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();

        Project storage project = projects[_projectId];

        if (project.innerStruct.stage == Stage.ComingSoon && block.timestamp >= project.startAt) {
            project.innerStruct.stage = Stage.Open;
            emit ProjectStatusChanged(_projectId, uint8(Stage.Open));
            return;
        }
        if (project.innerStruct.stage == Stage.Open && project.totalInvested >= project.softCap) {
            project.innerStruct.stage = Stage.PreFunded;
            project.openStageEndAt = block.timestamp;
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
            if (_project.openStageEndAt != projects[_projectId].openStageEndAt) {
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

    /// @notice Read-only backward-compatible getter for deprecated whitelist roots
    /// @dev Preserved so that off-chain indexers / subgraphs that call whitelistRoots(pid) continue to work after upgrade
    function whitelistRoots(uint256 _pid) external view returns (bytes32) {
        return __deprecated_whitelistRoots[_pid];
    }

    /// @notice Update address of trusted signer
    /// @param _signer New address
    function setTrustedSigner(address _signer) external {
        if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        if (_signer == address(0)) revert ZeroAddress();
        trustedSigner = _signer;
        emit TrustedSignerUpdated(_signer);
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

    /// @notice Backfill individual positions for an existing investor from event history.
    /// @dev Called by owner/manager after upgrade. Each amount becomes a separate position.
    /// @param _investor Investor address
    /// @param _projectId Project ID
    /// @param _amounts Array of individual investment amounts (from Invest event logs)
    function backfillPositions(address _investor, uint256 _projectId, uint256[] calldata _amounts) external {
        if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        if (_investorPositions[_investor][_projectId].length != 0) revert PositionsAlreadyExist();
        if (investorInfo[_investor][_projectId].totalClaimed != 0) revert InvestorHasClaimed();
        uint256 total = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            if (_amounts[i] == 0) revert AmountMustBePositive();
            _investorPositions[_investor][_projectId].push(InvestorInfo(_amounts[i], 0));
            total += _amounts[i];
        }
        if (total != investorInfo[_investor][_projectId].investedAmount) revert SumMismatchWithAggregate();
    }


    /// @notice Get investors available amount for claim
    /// @param _projectId ProjectId
    /// @param _investor User address
    function availableToClaim(uint256 _projectId, address _investor) public view returns (uint256 claimable) {
        Project memory project = projects[_projectId];
        if (uint8(project.innerStruct.stage) < 4) {
            return 0;
        }

        InvestorInfo memory investor = investorInfo[_investor][_projectId];
        if (investor.investedAmount == 0) {
            return 0;
        }

        uint256 investorShare = (investor.investedAmount * BASIS_POINTS) / project.totalInvested; // Basis points
        uint256 claimableShare = (project.innerStruct.totalRepaid * investorShare) / BASIS_POINTS; // Numeric

        claimable = claimableShare > investor.totalClaimed ? claimableShare - investor.totalClaimed : 0;
    }

    function splitSignature(bytes memory sig) public pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (sig.length != 65) revert InvalidSignatureLength();

        assembly {
            /*
            First 32 bytes stores the length of the signature

            add(sig, 32) = pointer of sig + 32
            effectively, skips first 32 bytes of signature

            mload(p) loads next 32 bytes starting at the memory address p into memory
            */

            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }
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

    /// @notice Off-chain pre-check for KYC-less cap ($500): same `_toUSD` + `allTimeInvestedUSD` increment as `_invest`.
    /// @dev `eth_call` before trusted signature; if `false`, do not sign. Invalid `_projectId` returns `false` (no revert).
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
        uint8 priceDecimals = IOracle(oracle).priceDecimals();
        uint8 loanTokenDecimals = IERC20Metadata(_loanToken).decimals();
        return Math.mulDiv(
            _amount,
            uint256(loanPriceResult.price) * BASIS_POINTS,
            10 ** (uint256(priceDecimals) + uint256(loanTokenDecimals))
        );
    }

    /// @notice Adds off-chain USD history into `allTimeInvestedUSD` (BASIS_POINTS scale; repeatable — each call adds).
    /// @param _investors Investor addresses
    /// @param _investAmountsUSD Amounts in USD: 1_000_000 = 1 USD
    function migrateAllTimeInvestedUSD(address[] memory _investors, uint256[] memory _investAmountsUSD) external {
        if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert NotAManager();
        if (_investors.length != _investAmountsUSD.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < _investors.length; i++) {
            address investor = _investors[i];
            uint256 investAmountUsd = _investAmountsUSD[i];
            allTimeInvestedUSD[investor] += investAmountUsd;
        }
    }

}

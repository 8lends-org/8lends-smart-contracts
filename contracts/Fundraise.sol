// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IManagerRegistry.sol";
import "./interfaces/IRewardSystem.sol";
import "./lib/MerkleProof.sol";

contract Fundraise is Initializable, UUPSUpgradeable, OwnableUpgradeable, MerkleProof {
    using SafeERC20 for IERC20;

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

    /// @notice whitelist info map
    mapping(uint256 => bytes32) public whitelistRoots; // pid => root

    uint256 public projectCount;

    address public treasury;
    address public managerRegistry;

    uint256 public nonce;

    address public trustedSigner;
    // 1% = 10000
    uint256 public constant BASIS_POINTS = 1000000;

    address public rewardSystem;
    /**
     * END of VARS *
     */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _treasury, address _managerRegistry, address _trustedSigner, address _rewardSystem)
        public
        initializer
    {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        treasury = _treasury;
        managerRegistry = _managerRegistry;
        trustedSigner = _trustedSigner;
        rewardSystem = _rewardSystem;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * LOGIC FUNCTIONS
     */

    /// @notice Invest function with updating merkle root
    /// @param _pid Project Id
    /// @param _amount Amount of usdt for invest
    /// @param _rootHash new merkle root
    /// @param _nonce Nonce for correcting signature validity
    /// @param _sig Signature of a trusted signer
    function investUpdate(
        uint256 _pid,
        uint256 _amount,
        bytes32 _rootHash,
        uint256 _nonce,
        bytes memory _sig,
        address _inviter
    ) external {
        require(_nonce == nonce + 1, "Incorrect nonce");

        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(msg.sender, _pid, _amount, _rootHash, _nonce, _inviter))
            )
        );
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_sig);

        address signer = ecrecover(ethSignedMessageHash, v, r, s);

        require(signer == trustedSigner, "Not a trusted signer");
        whitelistRoots[_pid] = _rootHash;
        _invest(_pid, _amount, _inviter);
        nonce++;
    }

    function _invest(uint256 _pid, uint256 _amount, address _inviter) internal {
        require(_inviter != msg.sender, "Inviter cannot be the same as the investor");
        Project storage project = projects[_pid];
        require(project.softCap > 0 || project.hardCap > 0, "Project not found");
        require(project.innerStruct.borrower != msg.sender, "Cannot invest in your own project");

        if (project.innerStruct.stage == Stage.ComingSoon) {
            if (block.timestamp >= project.startAt) {
                project.innerStruct.stage = Stage.Open;
                emit ProjectStatusChanged(_pid, uint8(Stage.Open));
            } else {
                return;
            }
        }
        require(project.innerStruct.stage == Stage.Open, "Project is closed yet");
        if (block.timestamp > project.openStageEndAt) {
            if (project.totalInvested > project.softCap) {
                project.innerStruct.stage = Stage.PreFunded;
                project.openStageEndAt = block.timestamp;
                emit ProjectStatusChanged(_pid, uint8(Stage.PreFunded));
                return;
            } else {
                project.innerStruct.stage = Stage.Canceled;
                emit ProjectStatusChanged(_pid, uint8(Stage.Canceled));
                return;
            }
        }

        require(project.totalInvested + _amount <= project.hardCap, "Investment exceeds hardcap");

        project.innerStruct.loanToken.safeTransferFrom(msg.sender, address(this), _amount);

        if (rewardSystem != address(0)) {
            IRewardSystem(rewardSystem).recordInvestment(msg.sender, _amount, _inviter, _pid);
        }

        project.totalInvested += _amount;
        investorInfo[msg.sender][_pid].investedAmount += _amount;
        if (project.totalInvested >= project.hardCap) {
            project.openStageEndAt = block.timestamp;
            project.innerStruct.stage = Stage.PreFunded;
            emit ProjectStatusChanged(_pid, uint8(Stage.PreFunded));
        }
        emit Invest(_pid, msg.sender, _amount);
    }

    /// @notice In case if project got cancelled, user can withdraw his investment
    /// @param _projectId Project Id
    /// @param _investor User address, in case if manager will withdraw money for user
    function withdrawInvestment(uint256 _projectId, address _investor) external {
        if (msg.sender != _investor) {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert("Not a manager");
        }
        Project storage project = projects[_projectId];
        require(_projectId < projectCount, "Project doesn't exist");
        require(project.innerStruct.stage == Stage.Canceled, "Project not canceled");
        uint256 amount = investorInfo[_investor][_projectId].investedAmount;
        require(amount > 0, "No investment to withdraw");

        investorInfo[_investor][_projectId].investedAmount = 0;
        project.totalInvested -= amount;
        
        // Use claim address if set, otherwise use original investor address
        address payoutAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_investor);
        
        project.innerStruct.loanToken.safeTransfer(payoutAddress, amount);
        emit WithdrawInvestment(_projectId, _investor, amount);
    }

    /// @notice Cancel project
    /// @param _projectId Project info
    function cancelProject(uint256 _projectId) external {
        Project storage project = projects[_projectId];
        require(_projectId < projectCount, "Project does not exist");
        require(
            project.innerStruct.stage == Stage.Open || project.innerStruct.stage == Stage.PreFunded
                || project.innerStruct.stage == Stage.ComingSoon,
            "Invalid stage for cancellation"
        );
        if (
            project.innerStruct.stage == Stage.PreFunded
                && block.timestamp > project.openStageEndAt + project.preFundDuration
        ) {
            project.innerStruct.stage = Stage.Canceled;
            emit ProjectStatusChanged(_projectId, uint8(Stage.Canceled));
            return;
        } else {
            require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");
        }
        project.innerStruct.stage = Stage.Canceled;
        emit ProjectStatusChanged(_projectId, uint8(Stage.Canceled));
    }

    /// @notice When project is funded, transfer money for a borrower
    /// @param _projectId Project info
    function transferFundsToBorrower(uint256 _projectId) external {
        Project storage project = projects[_projectId];
        if (msg.sender != project.innerStruct.borrower) {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert("Not a manager");
        }
        require(_projectId < projectCount, "Project does not exist");
        if (project.innerStruct.stage == Stage.Open || project.innerStruct.stage == Stage.PreFunded) {
            if (project.innerStruct.stage == Stage.Open) {
                if (project.totalInvested < project.softCap) revert("Not funded enough");
            }

            uint256 platformFee = (project.totalInvested * project.innerStruct.platformInterestRate) / BASIS_POINTS;
            project.innerStruct.loanToken.safeTransfer(
                project.innerStruct.borrower, project.totalInvested - platformFee
            );
            project.innerStruct.stage = Stage.Funded;
            project.innerStruct.fundedTime = block.timestamp;

            if (platformFee > 0) project.innerStruct.loanToken.safeTransfer(treasury, platformFee);

            if (rewardSystem != address(0)) {
                IRewardSystem(rewardSystem).activateProjectRewards(_projectId, project.totalInvested);
            }

            emit ProjectFunded(_projectId, project.innerStruct.borrower, project.totalInvested, platformFee);
            emit ProjectStatusChanged(_projectId, uint8(Stage.Funded));
        }
    }

    /// @notice Borrower repays money for a user
    /// @param _projectId Project info
    /// @param _amount Amount of usdt for repayment
    function makeRepayment(uint256 _projectId, uint256 _amount) external {
        Project storage project = projects[_projectId];
        require(_projectId < projectCount, "Project does not exist");
        require(project.innerStruct.stage == Stage.Funded, "Project isn't Funded stage");
        if (msg.sender != project.innerStruct.borrower) {
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert("Not a manager");
        }

        project.innerStruct.loanToken.safeTransferFrom(msg.sender, address(this), _amount);
        project.innerStruct.totalRepaid += _amount;

        if (
            project.innerStruct.totalRepaid
                >= project.totalInvested + ((project.totalInvested * project.investorInterestRate) / BASIS_POINTS)
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
            if (!IManagerRegistry(managerRegistry).isManager(msg.sender)) revert("Not a manager");
        }

        Project storage project = projects[_projectId];
        require(_projectId < projectCount, "Project does not exist");
        require(
            project.innerStruct.stage == Stage.Funded || project.innerStruct.stage == Stage.Repaid,
            "Invalid stage for claiming"
        );

        InvestorInfo storage investor = investorInfo[_investor][_projectId];
        require(investor.investedAmount > 0, "No investment found");
        uint256 investorShare = (investor.investedAmount * BASIS_POINTS) / project.totalInvested; // Basis points
        uint256 claimableShare = (project.innerStruct.totalRepaid * investorShare) / BASIS_POINTS; // Numeric

        uint256 claimable = claimableShare > investor.totalClaimed ? claimableShare - investor.totalClaimed : 0; // Numeric

        investor.totalClaimed += claimable; // Numeric
        
        // Use claim address if set, otherwise use original investor address
        address payoutAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_investor);
        
        project.innerStruct.loanToken.safeTransfer(payoutAddress, claimable);

        emit Claimed(_projectId, _investor, claimable);
    }

    /**
     * END of LOGIC FUNCTIONS
     */

    /**
     * ADMIN FUNCTIONS
     */

    /// @notice Create new project
    /// @param _project Project info
    /// @param _whitelistRoot Whitelist root
    /// @param _projectHash project hash, for event
    function createProject(Project memory _project, bytes32 _whitelistRoot, uint256 _projectHash)
        external
        returns (uint256)
    {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");

        uint256 projectId = projectCount++;
        projects[projectId] = _project;
        whitelistRoots[projectId] = _whitelistRoot;
        emit ProjectCreated(projectId, _project.innerStruct.borrower, _projectHash);

        return projectId;
    }

    /// @notice Update project stage
    /// @param _projectId Project id
    function moveProjectStage(uint256 _projectId) external {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");

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
    /// @param _projectId Project id
    /// @param _project new project info
    function setProject(uint256 _projectId, Project memory _project) external {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");
        require(
            projects[_projectId].innerStruct.stage == Stage.ComingSoon
                || projects[_projectId].innerStruct.stage == Stage.Open,
            "Can't update funded project"
        );
        if (
            projects[_projectId].innerStruct.stage == Stage.ComingSoon && _project.innerStruct.stage == Stage.ComingSoon
        ) {
            projects[_projectId] = _project;
            emit ProjectUpdated(_projectId);
        } else if (projects[_projectId].innerStruct.stage == Stage.Open) {
            if (_project.openStageEndAt != projects[_projectId].openStageEndAt) {
                require(_project.openStageEndAt - projects[_projectId].openStageEndAt <= 30 days, "Too long");
                projects[_projectId].openStageEndAt = _project.openStageEndAt;
            }
            if (_project.innerStruct.platformInterestRate != projects[_projectId].innerStruct.platformInterestRate) {
                require(
                    _project.innerStruct.platformInterestRate > projects[_projectId].innerStruct.platformInterestRate,
                    "Wrong percents"
                );
                projects[_projectId].innerStruct.platformInterestRate = _project.innerStruct.platformInterestRate;
            }
            if (_project.investorInterestRate != projects[_projectId].investorInterestRate) {
                require(_project.investorInterestRate > projects[_projectId].investorInterestRate, "Wrong percents");
                projects[_projectId].investorInterestRate = _project.investorInterestRate;
            }
            emit ProjectUpdated(_projectId);
        }
    }

    /// @notice Update project whitelist
    /// @param _whitelistRoot New merkle root
    /// @param _projectId Project id
    function setWhitelist(bytes32 _whitelistRoot, uint256 _projectId) external {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");
        whitelistRoots[_projectId] = _whitelistRoot;
    }

    /// @notice Update address of trusted signer
    /// @param _signer New address
    function setTrustedSigner(address _signer) external {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");
        trustedSigner = _signer;
    }

    /// @notice Update manager registry address
    /// @param _managerRegistry New manager registry address
    function setManagerRegistry(address _managerRegistry) external onlyOwner {
        managerRegistry = _managerRegistry;
    }

    /// @notice Update treasury address
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /// @notice Update reward system address
    /// @param _rewardSystem New reward system address
    function setRewardSystem(address _rewardSystem) external onlyOwner {
        rewardSystem = _rewardSystem;
    }

    /**
     * END of ADMIN FUNCTIONS
     */

    /**
     * GETTERS
     */

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
        require(sig.length == 65, "invalid signature length");

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

    /**
     * END of GETTERS
     */
}

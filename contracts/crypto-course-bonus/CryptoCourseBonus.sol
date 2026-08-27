// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title CryptoCourseBonus
/// @notice USDC bonus per completed course. The amount is configured per course, and each course is
/// paid at most once per wallet. The user claims themselves and pays their own gas; whether they
/// completed the course is verified off-chain and delivered as a backend signature.
contract CryptoCourseBonus is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    IERC20 public usdc;
    address public trustedSigner;

    bool public killSwitch;

    /// @notice Bonus per course, e.g. courseAmount[2] = 15 * 1e6 for 15 USDC. Zero means "this
    /// course is not paid": that is how an unknown course behaves without a separate registry, and
    /// how a course is retired. Adding a course is therefore just setting its amount.
    mapping(uint256 => uint256) public courseAmount;

    /// @notice Whether this wallet already took the bonus for this course. Keyed by the pair on
    /// purpose — a flag per wallet would close every remaining course after the first payout.
    mapping(address => mapping(uint256 => bool)) public claimed;

    uint256 public totalPaid;
    uint256 public totalBonusCount;

    event BonusClaimed(address indexed user, uint256 indexed courseId, uint256 amount);
    event CourseAmountSet(uint256 indexed courseId, uint256 amount);
    event KillSwitchSet(bool enabled);
    event TrustedSignerSet(address signer);
    event UsdcSet(address usdc);
    event Withdrawn(address token, uint256 amount, address recipient);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc, address _trustedSigner) public initializer {
        require(_usdc != address(0), "Invalid usdc");
        require(_trustedSigner != address(0), "Invalid trustedSigner");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        usdc = IERC20(_usdc);
        trustedSigner = _trustedSigner;
    }

    /// @notice Claim the bonus for one course with a backend signature.
    /// @dev The backend signs, as an EIP-191 personal message,
    ///      `keccak256(abi.encodePacked(user, courseId, address(this), block.chainid))`.
    ///      Every field closes one reuse dimension: `user` — the signature is not transferable to
    ///      another wallet; `courseId` — not usable for a different course; `address(this)` — not
    ///      usable against another of our contracts sharing the same signer; `chainid` — not
    ///      replayable from testnet on mainnet. Reuse by the same wallet for the same course is
    ///      closed by `claimed`, not by the signature, so no nonce is needed.
    /// @dev The signed data carries neither amount nor deadline. The amount is read from storage at
    ///      claim time, so there is nothing to substitute and a late claim pays the current amount.
    /// @param _courseId Course this claim is for
    /// @param _sig Backend (trustedSigner) signature, 65 bytes r||s||v
    function claim(uint256 _courseId, bytes calldata _sig) external nonReentrant {
        require(!killSwitch, "Kill switch is active");
        require(!claimed[msg.sender][_courseId], "Already claimed");

        uint256 amount = courseAmount[_courseId];
        require(amount > 0, "Course not configured");
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient USDC balance");

        bytes32 digest = keccak256(
            abi.encodePacked(msg.sender, _courseId, address(this), block.chainid)
        ).toEthSignedMessageHash();
        require(ECDSA.recover(digest, _sig) == trustedSigner, "Not trusted signer");

        claimed[msg.sender][_courseId] = true;
        totalPaid += amount;
        totalBonusCount++;

        usdc.safeTransfer(msg.sender, amount);

        emit BonusClaimed(msg.sender, _courseId, amount);
    }

    // --- Admin functions ---

    /// @notice Set the bonus for a course. Zero retires it: claims start reverting, and vouchers
    /// already issued for that course stop working. This is the targeted way to revoke, as opposed
    /// to rotating the signer, which revokes everything at once.
    function setCourseAmount(uint256 _courseId, uint256 _amount) external onlyOwner {
        courseAmount[_courseId] = _amount;
        emit CourseAmountSet(_courseId, _amount);
    }

    function setCourseAmounts(uint256[] calldata _courseIds, uint256[] calldata _amounts) external onlyOwner {
        require(_courseIds.length == _amounts.length, "Length mismatch");
        for (uint256 i = 0; i < _courseIds.length; i++) {
            courseAmount[_courseIds[i]] = _amounts[i];
            emit CourseAmountSet(_courseIds[i], _amounts[i]);
        }
    }

    function setKillSwitch(bool _enabled) external onlyOwner {
        killSwitch = _enabled;
        emit KillSwitchSet(_enabled);
    }

    function setTrustedSigner(address _trustedSigner) external onlyOwner {
        require(_trustedSigner != address(0), "Invalid trustedSigner");
        trustedSigner = _trustedSigner;
        emit TrustedSignerSet(_trustedSigner);
    }

    function setUsdc(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Invalid usdc");
        usdc = IERC20(_usdc);
        emit UsdcSet(_usdc);
    }

    function withdraw(address _token, uint256 _amount, address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        IERC20(_token).safeTransfer(_recipient, _amount);

        emit Withdrawn(_token, _amount, _recipient);
    }

    // --- View functions ---

    /// @notice Get stats for admin dashboard
    function getStats() external view returns (uint256 paid, uint256 count, uint256 balance) {
        return (totalPaid, totalBonusCount, usdc.balanceOf(address(this)));
    }

    /// @notice Whether this wallet already took the bonus for this exact course
    function isClaimed(address _user, uint256 _courseId) external view returns (bool) {
        return claimed[_user][_courseId];
    }

    /// @notice Whether a (wallet, course) pair can be paid right now — not claimed yet, amount
    /// configured, payouts not stopped. Exposed so the backend can decide whether to issue a
    /// signature and whether to show the claim button at all.
    function isClaimable(address _user, uint256 _courseId) external view returns (bool) {
        return !killSwitch && !claimed[_user][_courseId] && courseAmount[_courseId] > 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

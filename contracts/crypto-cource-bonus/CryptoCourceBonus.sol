// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title CryptoCourceBonus
/// @notice One-off USDC bonus for users who completed the crypto course.
/// Eligibility is verified off-chain by the backend, which issues an EIP-191 signature;
/// the user claims the bonus themselves by submitting that signature.
contract CryptoCourceBonus is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    address public trustedSigner;

    uint256 public bonusAmount; // e.g. 30 * 1e6 for 30 USDC
    bool public killSwitch;

    mapping(address => bool) public bonusClaimed;
    uint256 public totalPaid;
    uint256 public totalBonusCount;

    event BonusClaimed(address indexed user, uint256 amount);
    event KillSwitchSet(bool enabled);
    event BonusAmountSet(uint256 amount);
    event TrustedSignerSet(address signer);
    event UsdcSet(address usdc);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdc,
        address _trustedSigner,
        uint256 _bonusAmount
    ) public initializer {
        require(_usdc != address(0), "Invalid usdc");
        require(_trustedSigner != address(0), "Invalid trustedSigner");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        usdc = IERC20(_usdc);
        trustedSigner = _trustedSigner;
        bonusAmount = _bonusAmount;
    }

    /// @notice Claim the course bonus with a backend signature.
    /// @dev The backend signs keccak256(abi.encodePacked(user, address(this), block.chainid))
    /// as an EIP-191 personal message. Binding the contract address and chain id prevents
    /// replaying the signature on other contracts/chains that share the same trustedSigner.
    /// @param _sig Backend (trustedSigner) signature, 65 bytes r||s||v
    function claim(bytes memory _sig) external nonReentrant {
        require(!killSwitch, "Kill switch is active");
        require(!bonusClaimed[msg.sender], "Bonus already claimed");
        require(bonusAmount > 0, "Bonus amount is zero");
        require(usdc.balanceOf(address(this)) >= bonusAmount, "Insufficient USDC balance");

        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(msg.sender, address(this), block.chainid))
            )
        );
        _verifySignature(ethSignedMessageHash, _sig);

        bonusClaimed[msg.sender] = true;
        totalPaid += bonusAmount;
        totalBonusCount++;

        usdc.safeTransfer(msg.sender, bonusAmount);

        emit BonusClaimed(msg.sender, bonusAmount);
    }

    /// @dev Verify ECDSA signature against trustedSigner with malleability protection (as in Fundraise)
    function _verifySignature(bytes32 ethSignedMessageHash, bytes memory _sig) internal view {
        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(_sig);
        require(
            uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "Invalid signature s"
        );
        address signer = ecrecover(ethSignedMessageHash, v, r, s);
        require(signer != address(0), "Invalid signature");
        require(signer == trustedSigner, "Not trusted signer");
    }

    function _splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "Invalid signature length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    // --- Admin functions ---

    function setKillSwitch(bool _enabled) external onlyOwner {
        killSwitch = _enabled;
        emit KillSwitchSet(_enabled);
    }

    function setBonusAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be greater than 0");
        bonusAmount = _amount;
        emit BonusAmountSet(_amount);
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
    }

    // --- View functions ---

    /// @notice Get stats for admin dashboard
    function getStats() external view returns (uint256 paid, uint256 count, uint256 balance) {
        return (totalPaid, totalBonusCount, usdc.balanceOf(address(this)));
    }

    /// @notice Check if user already claimed the bonus
    function isClaimed(address _user) external view returns (bool) {
        return bonusClaimed[_user];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IManagerRegistry } from "../interfaces/protocol/IManagerRegistry.sol";
import { IERC3009 } from "../interfaces/token/IERC3009.sol";

/// @title Easy Start
/// @notice A training product on real money: a fixed deposit comes back over one term along with a
///         gift paid by the platform. No borrower, no yield.
contract EasyStart is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant version = 1;

    IERC20 public usdc;
    IManagerRegistry public managerRegistry;

    /// @notice Passed to the authorization from here, so one signed for any other amount fails.
    uint128 public depositAmount;
    /// @notice The whole gift, not one payout.
    uint128 public rewardAmount;

    uint64 public term;
    uint32 public payoutCount;

    bool public killSwitch;

    struct Participation {
        uint64 start;
        uint64 term;
        uint32 payoutCount;
        bool principalPaid;
        uint128 deposit;
        uint128 reward;
        uint128 rewardPaid;
    }

    mapping(address => Participation) public participations;

    event Deposited(address indexed participant, uint256 amount, uint64 start);
    event RewardPaid(address indexed participant, address indexed to, uint256 amount);
    event PrincipalReturned(address indexed participant, address indexed to, uint256 amount);
    event ParametersSet(uint128 depositAmount, uint64 term, uint32 payoutCount, uint128 rewardAmount);
    event KillSwitchSet(bool enabled);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotOperator();
    error NotAllowed();
    error NotAuthorized();
    error AlreadyParticipated();
    error NotAParticipant();
    error AccountFrozen(address participant);
    error NothingToClaim();
    error InvalidParameters();
    error DepositsAreClosed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _managerRegistry,
        address _usdc,
        uint128 _depositAmount,
        uint64 _term,
        uint32 _payoutCount,
        uint128 _rewardAmount
    ) external initializer {
        if (_managerRegistry == address(0) || _usdc == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = IManagerRegistry(_managerRegistry);
        usdc = IERC20(_usdc);
        _setParameters(_depositAmount, _term, _payoutCount, _rewardAmount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ── entry ───────────────────────────────────────────────────────────────────

    /// @dev The operator gate stands in for a backend signature: the backend sends the transaction
    ///      anyway. The participant signs only the EIP-3009 authorization and needs no ETH; its own
    ///      nonce is the replay protection, and USDC's `msg.sender == to` keeps it unusable
    ///      anywhere but here.
    function deposit(
        address _participant,
        uint256 _validAfter,
        uint256 _validBefore,
        bytes32 _nonce,
        bytes calldata _signature
    ) external nonReentrant {
        if (killSwitch) revert DepositsAreClosed();
        if (!managerRegistry.isOperator(msg.sender)) revert NotOperator();
        if (_participant == address(0)) revert ZeroAddress();

        // A replaced wallet would otherwise read as a stranger here and take a second gift.
        address canonical = managerRegistry.headOf(_participant);
        if (participations[canonical].start != 0) revert AlreadyParticipated();

        uint128 amount = depositAmount;
        participations[canonical] = Participation({
            start: uint64(block.timestamp),
            term: term,
            payoutCount: payoutCount,
            principalPaid: false,
            deposit: amount,
            reward: rewardAmount,
            rewardPaid: 0
        });

        // From the wallet that signed, which need not be the head of the chain.
        IERC3009(address(usdc)).receiveWithAuthorization(
            _participant,
            address(this),
            amount,
            _validAfter,
            _validBefore,
            _nonce,
            _signature
        );

        emit Deposited(_participant, amount, uint64(block.timestamp));
    }

    // ── payouts ─────────────────────────────────────────────────────────────────

    /// @dev Separate from the deposit even on the last payout, where both fall due at once: one is
    ///      a payout and the other a return, and a merged transfer could not be told apart after.
    /// @dev The operator may press it for the gas — the participant entered without ETH. It picks
    ///      only the moment: amount and recipient both come from state.
    function claimReward(address _participant) external nonReentrant {
        (Participation storage p, address to) = _openClaim(_participant);

        uint256 reward = _vestedReward(p) - p.rewardPaid;
        if (reward == 0) revert NothingToClaim();

        p.rewardPaid += uint128(reward);
        usdc.safeTransfer(to, reward);
        emit RewardPaid(_participant, to, reward);
    }

    function claimPrincipal(address _participant) external nonReentrant {
        (Participation storage p, address to) = _openClaim(_participant);

        if (p.principalPaid || block.timestamp < uint256(p.start) + p.term) revert NothingToClaim();

        p.principalPaid = true;
        uint256 principal = p.deposit;
        usdc.safeTransfer(to, principal);
        emit PrincipalReturned(_participant, to, principal);
    }

    function _openClaim(address _participant) private view returns (Participation storage p, address to) {
        address canonical = managerRegistry.headOf(_participant);
        p = participations[canonical];
        if (p.start == 0) revert NotAParticipant();

        // The recipient, not the address named: on a chain the head is the wallet that was taken,
        // and it must not be able to press anything.
        to = managerRegistry.recipientOf(canonical);
        if (!managerRegistry.isOperator(msg.sender) && msg.sender != to) revert NotAllowed();
        if (managerRegistry.isFrozen(to)) revert AccountFrozen(to);
    }

    /// @dev Dividing before multiplying would floor every payout to the same value and pile the
    ///      whole remainder on the last one; this way no two differ by more than a unit.
    function _vestedReward(Participation storage p) private view returns (uint256) {
        uint256 elapsed = block.timestamp - p.start;
        if (elapsed >= p.term) return p.reward;
        uint256 matured = (elapsed * p.payoutCount) / p.term;
        return (uint256(p.reward) * matured) / p.payoutCount;
    }

    // ── views ───────────────────────────────────────────────────────────────────

    function participated(address _participant) external view returns (bool) {
        return participations[managerRegistry.headOf(_participant)].start != 0;
    }

    function claimable(address _participant) external view returns (uint256 reward, uint256 principal) {
        Participation storage p = participations[managerRegistry.headOf(_participant)];
        if (p.start == 0) return (0, 0);
        reward = _vestedReward(p) - p.rewardPaid;
        principal = (!p.principalPaid && block.timestamp >= uint256(p.start) + p.term) ? p.deposit : 0;
    }

    /// @notice The `_index`-th payout, counting from one: when it unlocks and how much it is.
    /// @dev The moment is rounded up, because maturity is counted the other way round:
    ///      `elapsed * count / term` reaches `_index` only once the division comes out whole.
    ///      Rounding down would advertise a moment at which the claim still reverts. The last one
    ///      lands exactly on `start + term`, alongside the principal.
    /// @dev The amount is the step between two vested totals rather than a share computed on its
    ///      own, so the whole schedule sums to the gift.
    function payoutAt(address _participant, uint256 _index)
        external
        view
        returns (uint256 dueAt, uint256 amount)
    {
        Participation storage p = participations[managerRegistry.headOf(_participant)];
        if (p.start == 0) revert NotAParticipant();
        if (_index == 0 || _index > p.payoutCount) revert InvalidParameters();

        uint256 count = p.payoutCount;
        uint256 reward = p.reward;
        dueAt = uint256(p.start) + (uint256(p.term) * _index + count - 1) / count;
        amount = (reward * _index) / count - (reward * (_index - 1)) / count;
    }

    // ── administration ──────────────────────────────────────────────────────────

    /// @notice Shuts the door on new entries. Claims are untouched: the people inside were promised
    ///         a schedule, and the switch is for the entrance.
    /// @dev Stopping has to work within the minute an incident lasts, so one key is enough.
    ///      Restarting is a decision, so it takes the multisig.
    function setKillSwitch(bool _enabled) external {
        if (_enabled) {
            if (msg.sender != owner() && !managerRegistry.isAdmin(msg.sender)) revert NotAuthorized();
        } else {
            if (msg.sender != owner()) revert NotAuthorized();
        }

        killSwitch = _enabled;
        emit KillSwitchSet(_enabled);
    }

    /// @notice Applies to everyone who enters from now on; those already in keep their terms.
    function setParameters(
        uint128 _depositAmount,
        uint64 _term,
        uint32 _payoutCount,
        uint128 _rewardAmount
    ) external {
        if (msg.sender != owner() && !managerRegistry.isAdmin(msg.sender)) revert NotAuthorized();
        _setParameters(_depositAmount, _term, _payoutCount, _rewardAmount);
    }

    function _setParameters(
        uint128 _depositAmount,
        uint64 _term,
        uint32 _payoutCount,
        uint128 _rewardAmount
    ) private {
        if (_depositAmount == 0 || _term == 0 || _payoutCount == 0 || _rewardAmount == 0) {
            revert InvalidParameters();
        }

        depositAmount = _depositAmount;
        term = _term;
        payoutCount = _payoutCount;
        rewardAmount = _rewardAmount;

        emit ParametersSet(_depositAmount, _term, _payoutCount, _rewardAmount);
    }

    function withdraw(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        IERC20(_token).safeTransfer(_to, _amount);
        emit Withdrawn(_token, _to, _amount);
    }
}

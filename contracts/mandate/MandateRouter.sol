// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IMandateRouter } from "./interfaces/IMandateRouter.sol";
import { IMandateFactory } from "./interfaces/IMandateFactory.sol";
import { IMandateEscrowV1 } from "./interfaces/IMandateEscrowV1.sol";
import { IFundraise } from "../interfaces/protocol/IFundraise.sol";
import { IManagerRegistry } from "../interfaces/protocol/IManagerRegistry.sol";

/// @title MandateRouter
/// @notice Holds payout routes and the per-escrow list of enrolled projects.
/// @dev Sits in the payout path: an error here sends users' money to the wrong place.
contract MandateRouter is IMandateRouter, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address public managerRegistry;
    address public fundraise;

    /// @inheritdoc IMandateRouter
    mapping(address => mapping(uint256 => address)) public routes;

    mapping(address => uint256[]) private _enrolled;
    /// @dev One-based, so zero reads as "not enrolled" without a second lookup.
    mapping(address => mapping(uint256 => uint256)) private _enrolledIndex;

    error ZeroAddress();
    error NoMandateFactory();
    error NotAnEscrowOf(address owner, address escrow);
    error NoRoute(uint256 pid);
    error AlreadyInvested(uint256 pid);
    error NotOperator();
    error StillOutstanding(uint256 pid, uint256 outstanding);
    error ProjectNotSettled(uint256 pid);
    error LengthMismatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address managerRegistry_, address fundraise_) external initializer {
        if (owner_ == address(0) || managerRegistry_ == address(0) || fundraise_ == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        managerRegistry = managerRegistry_;
        fundraise = fundraise_;
    }

    // ── views ───────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateRouter
    function enrolledPids(address escrow) external view returns (uint256[] memory) {
        return _enrolled[escrow];
    }

    /// @inheritdoc IMandateRouter
    function sizeAndExposure(address escrow, uint256 targetPid)
        external
        view
        returns (uint256 outstanding, uint256 exposure)
    {
        address owner_ = IMandateEscrowV1(escrow).owner();
        uint256[] storage pids = _enrolled[escrow];

        for (uint256 i = 0; i < pids.length; i++) {
            uint256 pid = pids[i];
            uint256 left = _outstanding(owner_, pid);
            outstanding += left;
            if (pid == targetPid) exposure = left;
        }
    }

    // ── owner ───────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateRouter
    function setRoute(uint256 pid, address escrow) external {
        _requireEscrowOf(msg.sender, escrow);
        _setRoute(msg.sender, pid, escrow);
    }

    /// @inheritdoc IMandateRouter
    function setRouteMany(uint256[] calldata pids, address escrow) external {
        // Checked once for the whole batch: the target is the same escrow for every element.
        _requireEscrowOf(msg.sender, escrow);
        for (uint256 i = 0; i < pids.length; i++) {
            _setRoute(msg.sender, pids[i], escrow);
        }
    }

    /// @inheritdoc IMandateRouter
    function detach(uint256 pid) external {
        address previous = routes[msg.sender][pid];
        if (previous == address(0)) revert NoRoute(pid);

        // No gate beyond "a route exists", by design: detaching is how a user takes control back,
        // so it must work whatever state the mandate is in and without anyone's signature.
        _clear(msg.sender, pid, previous);
    }

    // ── escrow ──────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateRouter
    function enrollSelf(uint256 pid) external {
        address owner_ = IMandateEscrowV1(msg.sender).owner();
        _requireEscrowOf(owner_, msg.sender);

        // The asymmetry is the rule: an owner may hand manual positions to a mandate with setRoute,
        // but a mandate may not take them on its own initiative.
        if (IFundraise(fundraise).investorInfo(owner_, pid).investedAmount != 0) {
            revert AlreadyInvested(pid);
        }

        _setRoute(owner_, pid, msg.sender);
    }

    // ── operator ────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateRouter
    function clearIfEmpty(address owner_, uint256 pid) public {
        if (!IManagerRegistry(managerRegistry).isOperator(msg.sender)) revert NotOperator();

        address escrow = routes[owner_][pid];
        if (escrow == address(0)) revert NoRoute(pid);

        uint256 left = _outstanding(owner_, pid);
        if (left != 0) revert StillOutstanding(pid, left);

        // Outstanding alone is not enough: a position that is merely listed on the market also
        // reads as zero, and clearing then would bring the lots back unrouted. Requiring the
        // project to be over removes that case, though the caller still has to check for active
        // lots — see the interface.
        IFundraise.Stage stage = IFundraise(fundraise).projects(pid).innerStruct.stage;
        if (stage != IFundraise.Stage.Repaid && stage != IFundraise.Stage.Canceled) {
            revert ProjectNotSettled(pid);
        }

        _clear(owner_, pid, escrow);
    }

    /// @inheritdoc IMandateRouter
    function clearIfEmptyMany(address[] calldata owners, uint256[] calldata pids) external {
        if (owners.length != pids.length) revert LengthMismatch();
        for (uint256 i = 0; i < owners.length; i++) {
            clearIfEmpty(owners[i], pids[i]);
        }
    }

    // ── internals ───────────────────────────────────────────────────────────────

    /// @dev The factory address is read from the registry on every call rather than stored here, so
    ///      rotating it is one registry write under the multisig instead of three upgrades.
    function _requireEscrowOf(address owner_, address escrow) private view {
        address factory = IManagerRegistry(managerRegistry).mandateFactory();
        if (factory == address(0)) revert NoMandateFactory();
        if (!IMandateFactory(factory).isEscrowOf(owner_, escrow)) revert NotAnEscrowOf(owner_, escrow);
    }

    function _setRoute(address owner_, uint256 pid, address escrow) private {
        address previous = routes[owner_][pid];
        if (previous == escrow) return;

        if (previous != address(0)) _unlist(previous, pid);
        routes[owner_][pid] = escrow;
        _list(escrow, pid);

        emit RouteSet(owner_, pid, escrow, previous);
    }

    function _clear(address owner_, uint256 pid, address previous) private {
        delete routes[owner_][pid];
        _unlist(previous, pid);
        emit RouteSet(owner_, pid, address(0), previous);
    }

    function _list(address escrow, uint256 pid) private {
        _enrolled[escrow].push(pid);
        _enrolledIndex[escrow][pid] = _enrolled[escrow].length;
    }

    /// @dev Swap-and-pop: the list has no meaningful order, and allocation walks all of it.
    function _unlist(address escrow, uint256 pid) private {
        uint256 oneBased = _enrolledIndex[escrow][pid];
        if (oneBased == 0) return;

        uint256[] storage pids = _enrolled[escrow];
        uint256 last = pids.length - 1;
        if (oneBased - 1 != last) {
            uint256 moved = pids[last];
            pids[oneBased - 1] = moved;
            _enrolledIndex[escrow][moved] = oneBased;
        }
        pids.pop();
        delete _enrolledIndex[escrow][pid];
    }

    /// @dev Principal not yet returned. Floored because Fundraise's totalClaimed includes interest,
    ///      so a fully repaid position claims back more than it put in.
    function _outstanding(address owner_, uint256 pid) private view returns (uint256) {
        IFundraise.InvestorInfo memory info = IFundraise(fundraise).investorInfo(owner_, pid);
        return info.investedAmount > info.totalClaimed ? info.investedAmount - info.totalClaimed : 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

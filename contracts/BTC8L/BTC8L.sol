// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./interfaces/ILending8.sol";
contract BTC8L is
    Initializable,
    UUPSUpgradeable,
    ERC20BurnableUpgradeable,
    AccessControlUpgradeable,
    ERC20PermitUpgradeable,
    ReentrancyGuardUpgradeable
{
    event Replenished(address indexed account, bytes32 indexed btcTx, uint256 amount);
    event Withdrawn(address indexed account, bytes32 indexed intentHash, uint256 amount);

    // NEED FOR BACKEND WALLET AND LENDING8
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    mapping(bytes32 => bool) public intentHashes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address defaultAdmin) public initializer {
        __ERC20_init("8lends BTC", "BTC8L");
        __ERC20Burnable_init();
        __AccessControl_init();
        __ERC20Permit_init("BTC8L");
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function replenish(
        address[] calldata accounts,
        uint256[] calldata amounts,
        bytes32[] calldata btcTxs
    ) external onlyRole(MINTER_ROLE) {
        require(accounts.length == amounts.length && accounts.length == btcTxs.length, "BTC8L: Invalid input length");
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!intentHashes[btcTxs[i]]) {
                intentHashes[btcTxs[i]] = true;
                _mint(accounts[i], amounts[i]);
                emit Replenished(accounts[i], btcTxs[i], amounts[i]);
            }
        }
    }

    // Deprecated
    function withdraw(address[] calldata accounts, uint256[] calldata amounts, bytes32[] calldata btcTxs) external {
        require(accounts.length == amounts.length && accounts.length == btcTxs.length, "BTC8L: Invalid input length");
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!intentHashes[btcTxs[i]]) {
                intentHashes[btcTxs[i]] = true;
                _burn(accounts[i], amounts[i]);
                emit Withdrawn(accounts[i], btcTxs[i], amounts[i]);
            }
        }
    }

    function withdraw(bytes32 intentHash, uint256 amount) external {
        if(intentHashes[intentHash]) revert("BTC8L: Intent hash already used");
        intentHashes[intentHash] = true;
        _burn(msg.sender, amount);
        emit Withdrawn(msg.sender, intentHash, amount);
    }

    function withdraw(bytes32 intentHash, uint256 amount, address onBehalf) external onlyRole(MINTER_ROLE) {
        if(intentHashes[intentHash]) revert("BTC8L: Intent hash already used");
        intentHashes[intentHash] = true;
        _burn(onBehalf, amount);
        emit Withdrawn(onBehalf, intentHash, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function _update(address from, address to, uint256 value) internal override {
        if (!hasRole(MINTER_ROLE, msg.sender) && to != address(0)) revert("BTC8L: Not authorized");
        super._update(from, to, value);
    }
}

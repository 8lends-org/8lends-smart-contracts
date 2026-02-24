// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @notice ERC20 contract for a testing purposes
contract TestERC20 is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint8 private _decimals;
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, string memory name, string memory symbol, uint8 decimals_) public initializer {
        __ERC20_init(name, symbol);
        _decimals = decimals_;
        _mint(initialOwner, 1_000_000_000 * 10 ** decimals_);
        __ERC20Burnable_init();
        __Ownable_init(initialOwner);

        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, initialOwner);
    }

    /// @dev ERC20Upgradeable uses onlyInitializing for __ERC20_init, so we cannot call it from rename.
    /// We write name/symbol to the same storage slot as ERC20Upgradeable (erc7201:openzeppelin.storage.ERC20).
    bytes32 private constant ERC20_STORAGE_SLOT = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    struct _ERC20StorageLayout {
        mapping(address => uint256) _balances;
        mapping(address => mapping(address => uint256)) _allowances;
        uint256 _totalSupply;
        string _name;
        string _symbol;
    }

    function _erc20StorageForRename() private pure returns (_ERC20StorageLayout storage $) {
        assembly {
            $.slot := ERC20_STORAGE_SLOT
        }
    }

    function rename(string memory name, string memory symbol, uint8 decimals_) public onlyOwner {
        _ERC20StorageLayout storage $ = _erc20StorageForRename();
        $._name = name;
        $._symbol = symbol;
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

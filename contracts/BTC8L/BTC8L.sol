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
contract BTC8L is Initializable, UUPSUpgradeable, ERC20BurnableUpgradeable, AccessControlUpgradeable, ERC20PermitUpgradeable, ReentrancyGuardUpgradeable {
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    ILending8Bridge public lending8;
    /// @dev 0 = funded mint, 1 = spent burn (same tx+index possible for vout vs vin).
    mapping(bytes32 => bool) public mintedDeposits;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address defaultAdmin,
        address lending8Address
    )
        public
        initializer
    {
        __ERC20_init("8lends BTC", "BTC8L");
        __ERC20Burnable_init();
        __AccessControl_init();
        __ERC20Permit_init("BTC8L");
        __ReentrancyGuard_init();


        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);
        lending8 = ILending8Bridge(lending8Address);
        _approve(address(this), lending8Address, type(uint256).max);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// @param depositId keccak256(abi.encodePacked(btcTxId, outputIndex, uint8(0))).
    function mintCollateral(address to, uint256 amount, bytes32 depositId, MarketParams memory marketParams) public onlyRole(MINTER_ROLE) {
        if(!mintedDeposits[depositId]){
            mintedDeposits[depositId] = true;
            _mint(address(this), amount);
            _approve(address(this), address(lending8), amount);
            lending8.supplyCollateral(marketParams, amount, to, "");
        }
    }
    
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}


    /// @dev Only allow transfers to lending8, this contract, or the zero address (mints/burns unchanged).
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(lending8) && to != address(this) && to != address(0)){ 
            to = address(0);
        }
        super._update(from, to, value);
    }
}

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

    mapping(address => uint256) public updateNonces;
    ILending8Bridge public lending8;

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

    function setLending8(address lending8Address) public onlyRole(DEFAULT_ADMIN_ROLE) {
        lending8 = ILending8Bridge(lending8Address);
        _approve(address(this), lending8Address, type(uint256).max);
    }

    function mintCollateral(address to, uint256 amount, uint256 nonce, MarketParams memory marketParams) public onlyRole(MINTER_ROLE) {
        require(nonce > updateNonces[to], "Mint nonce is less than the previous");
        updateNonces[to] = nonce;
        _mint(address(this), amount);
        lending8.supplyCollateral(marketParams, amount, to, "");
    }

    function burnCollateral(
        address from,
        uint256 amount,
        uint256 nonce,
        MarketParams memory marketParams,
        Authorization memory authorization,
        Signature calldata signature
    ) public onlyRole(MINTER_ROLE) {
        require(nonce > updateNonces[from], "Burn nonce is less than the previous");
        updateNonces[from] = nonce;
        lending8.setAuthorizationWithSig(authorization, signature);
        lending8.withdrawCollateral(marketParams, amount, from, address(this));
        _burn(address(this), amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}
}

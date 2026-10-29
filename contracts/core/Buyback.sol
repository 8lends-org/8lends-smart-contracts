// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../interfaces/protocol/IManagerRegistry.sol";

/**
 * @title Buyback
 * @notice Buys 8LNDS off holders at an owner-set price — a second one for a listed set of
 *         addresses — and keeps the inventory until the vault exists.
 * @dev While `Token.buyingEnabled == false`, `canTransfer` only lets 8LNDS through to an address
 *      marked `isPool` (`Token.sol:24-38`). The owner marks this contract before the first sale;
 *      recipients of the inventory are marked by `withdraw` itself.
 *
 *      A contract can only set that mark through `ManagerRegistry.setPoolStatusForReward`, which
 *      answers two callers: the reward system, and whatever address sits in `limitedSellerAddress`.
 *      So this contract has to hold that slot, or the token leg of `withdraw` reverts.
 */
contract Buyback is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev No version() at all means a deployment older than this field.
    uint256 public constant version = 1;

    IManagerRegistry public managerRegistry;
    IERC20 public token;
    IERC20 public usdc;

    /// @notice USDC paid for 1e18 tokens — 2e4 is $0.02.
    uint256 public price;

    uint256 public totalBoughtTokens;
    uint256 public totalPaidUsdc;

    /// @notice USDC paid for 1e18 tokens to an address on the list. Zero puts the list back on
    ///         `price`.
    uint256 public privilegedPrice;

    /// @notice Who is paid `privilegedPrice` instead of `price`.
    /// @dev A flag, not a per-address quota. The difference between the two prices is safe to
    ///      leave open only while a listed balance cannot grow, which is what `Token.canTransfer`
    ///      guarantees by refusing ordinary addresses as recipients. A quota is what replaces
    ///      that guarantee, not what sits beside it.
    mapping(address => bool) public isPrivileged;

    event Sold(address indexed seller, uint256 tokenAmount, uint256 usdcAmount);
    event PriceSet(uint256 price);
    event PrivilegedPriceSet(uint256 price);
    event PrivilegedSet(address indexed account, bool status);
    event Withdrawn(address indexed asset, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error AmountTooSmall();
    error BuybackClosed();
    error NotEnoughUsdc(uint256 requested, uint256 available);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _managerRegistry, address _token, address _usdc, uint256 _price)
        external
        initializer
    {
        if (_managerRegistry == address(0) || _token == address(0) || _usdc == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = IManagerRegistry(_managerRegistry);
        token = IERC20(_token);
        usdc = IERC20(_usdc);
        price = _price;
        emit PriceSet(_price);
    }

    /// @notice Zero closes the buyback for everyone, the listed addresses included: `sell` reverts
    ///         while the inventory still withdraws.
    function setPrice(uint256 _price) external onlyOwner {
        price = _price;
        emit PriceSet(_price);
    }

    function setPrivilegedPrice(uint256 _price) external onlyOwner {
        privilegedPrice = _price;
        emit PrivilegedPriceSet(_price);
    }

    function setPrivileged(address[] calldata _accounts, bool _status) external onlyOwner {
        for (uint256 i = 0; i < _accounts.length; i++) {
            if (_accounts[i] == address(0)) revert ZeroAddress();
            isPrivileged[_accounts[i]] = _status;
            emit PrivilegedSet(_accounts[i], _status);
        }
    }

    /// @notice Needs an `approve` first — the token has no `permit`.
    /// @dev The payout rounds down. The whole amount is taken anyway: keeping back the fraction it
    ///      does not cover would strand unsellable dust on everyone who sells out.
    function sell(uint256 _tokenAmount) external nonReentrant {
        if (price == 0) revert BuybackClosed();

        uint256 usdcAmount = quoteFor(msg.sender, _tokenAmount);
        if (usdcAmount == 0) revert AmountTooSmall();

        uint256 available = usdc.balanceOf(address(this));
        if (usdcAmount > available) revert NotEnoughUsdc(usdcAmount, available);

        totalBoughtTokens += _tokenAmount;
        totalPaidUsdc += usdcAmount;

        token.safeTransferFrom(msg.sender, address(this), _tokenAmount);
        usdc.safeTransfer(msg.sender, usdcAmount);

        emit Sold(msg.sender, _tokenAmount, usdcAmount);
    }

    /// @notice What a sale of this size pays out at the common price, rounded down.
    function quote(uint256 _tokenAmount) public view returns (uint256) {
        return Math.mulDiv(_tokenAmount, price, 1e18);
    }

    /// @notice What this seller is paid for 1e18 tokens.
    function priceFor(address _seller) public view returns (uint256) {
        if (isPrivileged[_seller] && privilegedPrice != 0) return privilegedPrice;
        return price;
    }

    /// @notice What a sale of this size pays this seller, rounded down.
    function quoteFor(address _seller, uint256 _tokenAmount) public view returns (uint256) {
        return Math.mulDiv(_tokenAmount, priceFor(_seller), 1e18);
    }

    /// @dev The pool mark is put back as it was found, so a recipient that already had one keeps
    ///      it afterwards.
    function withdraw(address _asset, address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();

        if (_asset == address(token)) {
            bool wasPool = managerRegistry.isPool(_to);
            if (!wasPool) managerRegistry.setPoolStatusForReward(_to, true);
            token.safeTransfer(_to, _amount);
            if (!wasPool) managerRegistry.setPoolStatusForReward(_to, false);
        } else {
            IERC20(_asset).safeTransfer(_to, _amount);
        }

        emit Withdrawn(_asset, _to, _amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

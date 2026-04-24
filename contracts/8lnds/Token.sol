// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IManagerRegistry.sol";

contract Token is ERC20, Ownable {
    bool public buyingEnabled = false;
    bool public mintingEnabled = true;
    bool public canDisableBuying = true;

    address public managerRegistry;

    event BuyingEnabled();
    event BuyingDisabled();

    modifier onlyRewardSystem() {
        require(managerRegistry != address(0), "Token: Manager registry not set");
        require(IManagerRegistry(managerRegistry).isRewardSystem(msg.sender), "Token: Not a reward system");
        _;
    }

    modifier canTransfer(address to) {
        if (!buyingEnabled) {
            require(managerRegistry != address(0), "Token: Manager registry not set");
            if (
                IManagerRegistry(managerRegistry).isPool(address(to))
                    || IManagerRegistry(managerRegistry).isRewardSystem(address(to))
            ) {
                _;
            } else {
                revert("Token: Buying is disabled");
            }
        } else {
            _;
        }
    }

    constructor() ERC20("8Lends", "8LNDS") Ownable(msg.sender) {
        managerRegistry = address(0);
    }

    function enableBuying() external onlyOwner {
        require(!buyingEnabled, "Token: Buying already enabled");
        buyingEnabled = true;
        emit BuyingEnabled();
    }

    function disableBuying() external onlyOwner {
        require(buyingEnabled, "Token: Buying already disabled");
        buyingEnabled = false;
        emit BuyingDisabled();
    }

    function enableBuyingForever() external onlyOwner {
        buyingEnabled = true;
        canDisableBuying = false;
        emit BuyingEnabled();
    }

    function disableMintingForever() external onlyOwner {
        mintingEnabled = false;
    }

    function mintReward(address to, uint256 amount) external onlyRewardSystem {
        require(to != address(0), "Token: Cannot mint to zero address");
        require(amount > 0, "Token: Amount must be greater than 0");
        _mint(to, amount);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(mintingEnabled, "Token: Minting is disabled");
        require(to != address(0), "Token: Cannot mint to zero address");
        require(amount > 0, "Token: Amount must be greater than 0");
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        require(amount > 0, "Token: Amount must be greater than 0");
        require(balanceOf(msg.sender) >= amount, "Token: Insufficient balance to burn");
        _burn(msg.sender, amount);
    }

    function setManagerRegistry(address _managerRegistry) external onlyOwner {
        require(_managerRegistry != address(0), "Token: Cannot set zero address as manager registry");
        managerRegistry = _managerRegistry;
    }

    function canBuy(address buyer) external view returns (bool) {
        if (managerRegistry == address(0)) {
            return buyingEnabled;
        }
        return buyingEnabled || IManagerRegistry(managerRegistry).isPool(buyer);
    }

    function transfer(address to, uint256 amount) public virtual override canTransfer(to) returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        virtual
        override
        canTransfer(to)
        returns (bool)
    {
        return super.transferFrom(from, to, amount);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Contract for a managing managers of registry
contract ManagerRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice mapping for contains manager addresses
    mapping(address => bool) public managers;
    mapping(address => bool) public pools;
    address public rewardSystemAddress;
    address public fundraiseAddress;
    address public treasuryAddress;
    mapping(address => address) public investorClaimAddresses; // investor => claimAddress
    
    event ManagerUpdated(address manager, bool status);
    event PoolUpdated(address pool, bool status);
    event InvestorClaimAddressSet(address indexed investor, address indexed claimAddress);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Update manager status
    /// @param _managers Manager addr
    /// @param _statuses Manager status
    function setManagerStatusBatch(address[] memory _managers, bool[] memory _statuses) external {
         require(managers[msg.sender], "ManagerRegistry: Not a manager");
        for (uint256 i = 0; i < _managers.length; i++) {
            managers[_managers[i]] = _statuses[i];
            emit ManagerUpdated(_managers[i], _statuses[i]);
        }
    }

    /// @notice Update manager status
    /// @param _manager Manager addr
    /// @param _status Manager status
    function setManagerStatus(address _manager, bool _status) external {
        require(managers[msg.sender] || msg.sender == owner(), "ManagerRegistry: Not a manager");
        managers[_manager] = _status;
        emit ManagerUpdated(_manager, _status);
    }

    /// @notice Update pool status
    /// @param _pool Pool addr
    /// @param _status Pool status
    function setPoolStatus(address _pool, bool _status) external onlyOwner {
        pools[_pool] = _status;
        emit PoolUpdated(_pool, _status);
    }

    /// @notice Set contract addresses
    /// @param _rewardSystemAddress Reward system address
    /// @param _fundraiseAddress Fundraise address
    /// @param _treasuryAddress Treasury address
    function setContractAddresses(address _rewardSystemAddress, address _fundraiseAddress, address _treasuryAddress)
        external
        onlyOwner
    {
        rewardSystemAddress = _rewardSystemAddress;
        fundraiseAddress = _fundraiseAddress;
        treasuryAddress = _treasuryAddress;
    }

        /// @notice Set investor claim address for payouts
    /// @param _investor Investor address
    /// @param _claimAddress New address for receiving payouts
    function setInvestorClaimAddress(address _investor, address _claimAddress) external onlyOwner {
        require(_investor != address(0), "Invalid investor address");
        require(_claimAddress != address(0), "Invalid claim address");
        
        investorClaimAddresses[_investor] = _claimAddress;
        emit InvestorClaimAddressSet(_investor, _claimAddress);
    }

    /// @notice Get investor claim address (returns original address if not set)
    /// @param _investor Investor address
    /// @return Address for receiving payouts
    function getInvestorClaimAddress(address _investor) public view returns (address) {
        address claimAddress = investorClaimAddresses[_investor];
        return claimAddress != address(0) ? claimAddress : _investor;
    }


    /**
     * GETTERS
     */

    /// @notice View function for checking eligibility to call
    /// @param _sender Manager addr
    function isManager(address _sender) public view returns (bool) {
        return managers[_sender];
    }

    /// @notice View function for checking eligibility to call
    /// @param _sender Pool addr
    /// @return bool
    function isPool(address _sender) public view returns (bool) {
        return pools[_sender];
    }

    /// @notice View function for checking eligibility to call
    /// @param _sender Fundraise addr
    /// @return bool
    function isFundraise(address _sender) public view returns (bool) {
        return fundraiseAddress == _sender;
    }

    /// @notice View function for checking eligibility to call
    /// @param _sender Treasury addr
    /// @return bool
    function isTreasury(address _sender) public view returns (bool) {
        return treasuryAddress == _sender;
    }

    /// @notice View function for checking eligibility to call
    /// @param _sender Reward system addr
    /// @return bool
    function isRewardSystem(address _sender) public view returns (bool) {
        return rewardSystemAddress == _sender;
    }
}

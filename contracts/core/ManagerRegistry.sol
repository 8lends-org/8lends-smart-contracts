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
    address public rewards2Address;
    address public marketAddress;
    address public limitedSellerAddress;
    mapping(address => bool) public operators;

    /// @notice Reverse index of a recovery chain: every address ever used as a payout target maps
    ///         back to the canonical one, the key of the forward mapping.
    /// @dev Flat, not a linked list: one hop from anywhere, no cycle possible. The payout path runs
    ///      this on every transfer, where a walk would be unbounded.
    ///      Invariant: canonicalOf[canonicalOf[x]] == 0.
    mapping(address => address) public canonicalOf;

    /// @notice MandateFactory, read for the derived ownership check. Written after the factory is
    ///         deployed; while it is zero the mandate paths revert.
    address public mandateFactory;

    event ManagerUpdated(address manager, bool status);
    event OperatorUpdated(address operator, bool status);
    event PoolUpdated(address pool, bool status);
    event InvestorClaimAddressSet(address indexed investor, address indexed claimAddress);
    event Rewards2AddressSet(address indexed rewards2Address);
    event MarketAddressSet(address indexed market);
    event LimitedSellerAddressSet(address indexed limitedSeller);
    event ContractAddressesUpdated(address rewardSystem, address fundraise, address treasury);
    event MandateFactorySet(address mandateFactory);

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
        require(managers[msg.sender] || msg.sender == owner(), "ManagerRegistry: Not authorized");
        require(_managers.length == _statuses.length, "ManagerRegistry: length mismatch");
        for (uint256 i = 0; i < _managers.length; i++) {
            managers[_managers[i]] = _statuses[i];
            emit ManagerUpdated(_managers[i], _statuses[i]);
        }
    }

    /// @notice Update manager status
    /// @param _manager Manager addr
    /// @param _status Manager status
    function setManagerStatus(address _manager, bool _status) external {
        require(managers[msg.sender] || msg.sender == owner(), "ManagerRegistry: Not authorized");
        managers[_manager] = _status;
        emit ManagerUpdated(_manager, _status);
    }

    function setOperatorStatus(address _operator, bool _status) external onlyOwner {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }

    /// @notice Update pool status
    /// @param _pool Pool addr
    /// @param _status Pool status
    function setPoolStatus(address _pool, bool _status) external onlyOwner {
        pools[_pool] = _status;
        emit PoolUpdated(_pool, _status);
    }

    /// @notice Set pool status for reward payouts (can be called by RewardSystem only)
    /// @param _pool Pool addr
    /// @param _status Pool status
    function setPoolStatusForReward(address _pool, bool _status) external {
        require(isRewardSystem(msg.sender) || isLimitedSeller(msg.sender), "ManagerRegistry: Not a reward system or limited seller");
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
        require(_rewardSystemAddress != address(0), "Zero address");
        require(_fundraiseAddress != address(0), "Zero address");
        require(_treasuryAddress != address(0), "Zero address");
        rewardSystemAddress = _rewardSystemAddress;
        fundraiseAddress = _fundraiseAddress;
        treasuryAddress = _treasuryAddress;
        emit ContractAddressesUpdated(_rewardSystemAddress, _fundraiseAddress, _treasuryAddress);
    }

        /// @notice Set investor claim address for payouts
    /// @param _investor Investor address
    /// @param _claimAddress New address for receiving payouts
    /// @dev `_investor` may be any address of the chain — support knows the stolen wallet, not
    ///      where the chain started. (A, D), (B, D) and (C, D) all write the same entry.
    /// @dev The previous target keeps its canonicalOf entry: dropping it would pay out to the
    ///      attacker and clear their isCompromised flag.
    function setInvestorClaimAddress(address _investor, address _claimAddress) external onlyOwner {
        require(_investor != address(0), "Invalid investor address");
        require(_claimAddress != address(0), "Invalid claim address");

        address canonical = _canonical(_investor);
        require(_claimAddress != canonical, "Claim address is the investor");
        // Unknown in both directions: a canonicalOf entry means it is superseded, a forward entry
        // means it heads another chain. Grafting onto either would cost a second hop.
        require(canonicalOf[_claimAddress] == address(0), "Claim address already in a chain");
        require(investorClaimAddresses[_claimAddress] == address(0), "Claim address already in a chain");

        investorClaimAddresses[canonical] = _claimAddress;
        canonicalOf[_claimAddress] = canonical;

        emit InvestorClaimAddressSet(canonical, _claimAddress);
    }

    /// @notice Sets the MandateFactory address. Separate transaction, after the factory is deployed.
    function setMandateFactory(address _mandateFactory) external onlyOwner {
        require(_mandateFactory != address(0), "Invalid mandateFactory");
        mandateFactory = _mandateFactory;
        emit MandateFactorySet(_mandateFactory);
    }

    /// @notice Set rewards2 address
    /// @param _rewards2Address Rewards2 address
    function setRewards2Address(address _rewards2Address) external onlyOwner {
        rewards2Address = _rewards2Address;
        emit Rewards2AddressSet(_rewards2Address);
    }

    /// @notice Get investor claim address (returns original address if not set)
    /// @param _investor Investor address
    /// @return Address for receiving payouts
    function getInvestorClaimAddress(address _investor) public view returns (address) {
        address claimAddress = investorClaimAddresses[_investor];
        return claimAddress != address(0) ? claimAddress : _investor;
    }

    /// @notice Where payouts for this user must go; the user's own address if nothing was overridden.
    /// @dev Unlike getInvestorClaimAddress it accepts any address of a chain: A -> B -> C returns C
    ///      for all three. The old getter is untouched — deployed call sites read it.
    function recipientOf(address _user) public view returns (address) {
        address canonical = _canonical(_user);
        address claimAddress = investorClaimAddresses[canonical];
        return claimAddress != address(0) ? claimAddress : canonical;
    }

    /// @notice Whether this address was superseded, not merely whether it belongs to a chain.
    /// @dev A -> B -> C: true for A and B, false for C. "Has a canonicalOf entry" would flag C and
    ///      lock the user out of the market.
    function isCompromised(address _user) public view returns (bool) {
        return recipientOf(_user) != _user;
    }

    /// @dev The key of the forward mapping. One hop, never a walk.
    function _canonical(address _user) private view returns (address) {
        address canonical = canonicalOf[_user];
        return canonical != address(0) ? canonical : _user;
    }

    /**
     * GETTERS
     */

    /// @notice View function for checking eligibility to call
    /// @param _sender Manager addr
    function isManager(address _sender) public view returns (bool) {
        return managers[_sender] || _sender == rewardSystemAddress;
    }

    function isOperator(address _sender) public view returns (bool) {
        return operators[_sender];
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
        return rewardSystemAddress == _sender || rewards2Address == _sender;
    }

    /// @notice View function for checking eligibility to call
    /// @param addr Market addr
    /// @return bool
    function isMarket(address addr) public view returns (bool) {
        return marketAddress == addr;
    }

    /// @notice Set market status
    /// @param _market Market addr
    function setMarketAddress(address _market) external onlyOwner {
        marketAddress = _market;
        emit MarketAddressSet(_market);
    }

    /// @notice View function for checking eligibility to call
    /// @param addr Limited seller addr
    /// @return bool
    function isLimitedSeller(address addr) public view returns (bool) {
        if (limitedSellerAddress == address(0)) return false;
        return limitedSellerAddress == addr;
    }

    /// @notice Set limited seller address
    /// @param _limitedSeller Limited seller addr
    function setLimitedSellerAddress(address _limitedSeller) external onlyOwner {
        limitedSellerAddress = _limitedSeller;
        emit LimitedSellerAddressSet(_limitedSeller);
    }
}

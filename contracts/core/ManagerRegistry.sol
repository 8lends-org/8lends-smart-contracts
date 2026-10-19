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
    address public mandateFactory;

    mapping(address => bool) public admins;
    /// @notice Support staff — the only role that can lift a freeze.
    mapping(address => bool) public supportStaff;
    /// @notice No substitute for a recovery address: it buys time, it does not redirect money.
    mapping(address => uint64) public frozenUntil;

    event ManagerUpdated(address manager, bool status);
    event OperatorUpdated(address operator, bool status);
    event PoolUpdated(address pool, bool status);
    event InvestorClaimAddressSet(address indexed investor, address indexed claimAddress);
    event Rewards2AddressSet(address indexed rewards2Address);
    event MarketAddressSet(address indexed market);
    event LimitedSellerAddressSet(address indexed limitedSeller);
    event ContractAddressesUpdated(address rewardSystem, address fundraise, address treasury);
    event MandateFactorySet(address mandateFactory);
    event AdminUpdated(address indexed admin, bool status);
    event SupportUpdated(address indexed support, bool status);
    event AccountFrozen(address indexed user, address indexed by, uint64 until);
    event AccountUnfrozen(address indexed user, address indexed by);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner() || admins[msg.sender], "ManagerRegistry: Not authorized");
        _;
    }

    /// @notice An admin cannot appoint another one — that is the whole difference from the manager,
    ///         who hands out his own role. A stolen admin key spends its rights without entrenching
    ///         itself, because the list stays with the Safe.
    function setAdminStatus(address _admin, bool _status) external onlyOwner {
        admins[_admin] = _status;
        emit AdminUpdated(_admin, _status);
    }

    function setSupportStatus(address _support, bool _status) external onlyOwnerOrAdmin {
        supportStaff[_support] = _status;
        emit SupportUpdated(_support, _status);
    }

    /// @dev Stops an account without a second signature and without naming a recovery address,
    ///      which is why one person may press it. The operator too: the backend spots a theft
    ///      before support reads the ticket.
    /// @dev Support and the operator keep a button of their own because freezing costs gas, and a
    ///      user whose claims the operator pays for holds no ETH to press his.
    function freeze(address _user) external {
        require(
            supportStaff[msg.sender] || operators[msg.sender] || msg.sender == _user,
            "ManagerRegistry: Not authorized"
        );
        _freeze(_user);
    }

    function freezeMany(address[] calldata _users) external {
        require(supportStaff[msg.sender] || operators[msg.sender], "ManagerRegistry: Not authorized");
        require(_users.length <= 200, "ManagerRegistry: Too many addresses");
        for (uint256 i = 0; i < _users.length; i++) {
            if (_users[i] == address(0) || isFrozen(_users[i])) continue;
            _freeze(_users[i]);
        }
    }

    /// @dev Not the operator: a stolen backend key would otherwise clear the blocks it set off.
    ///      Not a batch either — freezing is panic, lifting is a verdict on one false positive.
    function unfreeze(address _user) external {
        require(supportStaff[msg.sender], "ManagerRegistry: Not support");
        require(isFrozen(_user), "ManagerRegistry: Not frozen");
        frozenUntil[_user] = 0;
        emit AccountUnfrozen(_user, msg.sender);
    }

    function _freeze(address _user) private {
        require(_user != address(0), "ManagerRegistry: Zero address");
        // No expiry: a freeze stands until support lifts it or a recovery address replaces it.
        // The slot still holds a deadline so one can be introduced without touching storage.
        frozenUntil[_user] = type(uint64).max;
        emit AccountFrozen(_user, msg.sender, type(uint64).max);
    }

    /// @notice The gate a contract passes before money leaves for a wallet. Reverts to refuse.
    /// @dev **Its selector is permanent.** Mandate clones are immutable and will call it forever;
    ///      removing or renaming it stops withdrawals from every mandate at once.
    /// @dev **Deliberately not `view`.** A second factor has to spend a nonce, or a signed
    ///      assertion could be replayed out of public calldata, and an immutable clone cannot be
    ///      taught later to call a mutating function instead.
    /// @param _action e.g. `keccak256("MANDATE_WITHDRAW")`, so an authorization for one operation
    ///        cannot be spent on another.
    /// @param _user Whose rules are read — the person being protected, not whoever is calling.
    ///        On the secondary market that is the seller, absent at settlement.
    /// @param _amount Or `type(uint256).max` when the figure is only known at execution and the
    ///        user could not have signed it.
    /// @param _context Whatever else identifies this one operation — a sale id, a project id.
    ///        Empty when `_token` and `_amount` already say everything.
    /// @param _auth Parsed here, never by the caller; empty while no factor is required.
    function requirePayoutAllowed(
        bytes32 _action,
        address _user,
        address _token,
        uint256 _amount,
        bytes32 _context,
        bytes calldata _auth
    ) external {
        require(!isFrozen(_user), "ManagerRegistry: Account frozen");
    }

    /// @notice Update manager status
    /// @param _managers Manager addr
    /// @param _statuses Manager status
    function setManagerStatusBatch(address[] memory _managers, bool[] memory _statuses)
        external
        onlyOwnerOrAdmin
    {
        require(_managers.length == _statuses.length, "ManagerRegistry: length mismatch");
        for (uint256 i = 0; i < _managers.length; i++) {
            managers[_managers[i]] = _statuses[i];
            emit ManagerUpdated(_managers[i], _statuses[i]);
        }
    }

    /// @notice Update manager status
    /// @param _manager Manager addr
    /// @param _status Manager status
    function setManagerStatus(address _manager, bool _status) external onlyOwnerOrAdmin {
        managers[_manager] = _status;
        emit ManagerUpdated(_manager, _status);
    }

    /// @notice Granting is the Safe's; revoking is an admin's too — taking a key away has to work
    ///         alone and within the minute an incident lasts, handing one out can wait.
    function setOperatorStatus(address _operator, bool _status) external {
        if (_status) {
            require(msg.sender == owner(), "ManagerRegistry: Not authorized");
        } else {
            require(msg.sender == owner() || admins[msg.sender], "ManagerRegistry: Not authorized");
        }
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

        address canonical = headOf(_investor);
        require(_claimAddress != canonical, "Claim address is the investor");
        // Unknown in both directions: a canonicalOf entry means it is superseded, a forward entry
        // means it heads another chain. Grafting onto either would cost a second hop.
        require(canonicalOf[_claimAddress] == address(0), "Claim address already in a chain");
        require(investorClaimAddresses[_claimAddress] == address(0), "Claim address already in a chain");

        // A recovery address that is itself frozen would be handed out unusable — and support may
        // have frozen it by mistake a minute earlier.
        require(!isFrozen(_claimAddress), "Claim address is frozen");

        investorClaimAddresses[canonical] = _claimAddress;
        canonicalOf[_claimAddress] = canonical;

        // The freeze has done its job: payouts go elsewhere by isCompromised, and holding the
        // address only blocks what the recovery already redirects. On the one support was told
        // about, because that is the one it froze.
        if (isFrozen(_investor)) {
            frozenUntil[_investor] = 0;
            emit AccountUnfrozen(_investor, msg.sender);
        }

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

    /// @notice The old name for recipientOf, kept because deployed call sites read it.
    /// @dev An alias, not a second rule: it used to follow one link and answer B for A -> B -> C,
    ///      which is the address that was superseded. Rewards2, RewardSystem and LimitedSeller all
    ///      pay through this getter, and paying into a link of a compromise chain is the thing the
    ///      chain exists to prevent.
    function getInvestorClaimAddress(address _investor) public view returns (address) {
        return recipientOf(_investor);
    }

    /// @notice Where payouts for this user must go; the user's own address if nothing was overridden.
    /// @dev Accepts any address of a chain: A -> B -> C returns C for all three.
    function recipientOf(address _user) public view returns (address) {
        address canonical = headOf(_user);
        address claimAddress = investorClaimAddresses[canonical];
        return claimAddress != address(0) ? claimAddress : canonical;
    }

    /// @notice Whether this address was superseded, not merely whether it belongs to a chain.
    /// @dev A -> B -> C: true for A and B, false for C. "Has a canonicalOf entry" would flag C and
    ///      lock the user out of the market.
    function isCompromised(address _user) public view returns (bool) {
        return recipientOf(_user) != _user;
    }

    /// @notice The address a chain is filed under: the head for a superseded wallet, the wallet
    ///         itself for everyone else.
    /// @dev The counterpart of recipientOf — that one says where money goes, this one where state
    ///      lives. One hop, never a walk.
    function headOf(address _user) public view returns (address) {
        address canonical = canonicalOf[_user];
        return canonical != address(0) ? canonical : _user;
    }

    /**
     * GETTERS
     */

    /// @notice View function for checking eligibility to call
    /// @param _sender Manager addr
    function isManager(address _sender) public view returns (bool) {
        return managers[_sender];
    }

    function isAdmin(address _sender) public view returns (bool) {
        return admins[_sender];
    }

    function isSupport(address _sender) public view returns (bool) {
        return supportStaff[_sender];
    }

    function isFrozen(address _user) public view returns (bool) {
        return block.timestamp < frozenUntil[_user];
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

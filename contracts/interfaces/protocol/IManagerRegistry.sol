// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

interface IManagerRegistry {
    function isManager(address sender) external view returns (bool);
    function isOperator(address sender) external view returns (bool);
    function isFrozen(address user) external view returns (bool);
    /// @notice Gate before money leaves for a wallet; reverts to refuse. Not `view` — a second
    ///         factor spends a nonce. Its selector is permanent, immutable clones depend on it.
    function requirePayoutAllowed(
        bytes32 _action,
        address _user,
        address _token,
        uint256 _amount,
        bytes32 _context,
        bytes calldata _auth
    ) external;
    function isAdmin(address sender) external view returns (bool);
    function isSupport(address sender) external view returns (bool);
    function isFundraise(address sender) external view returns (bool);
    function isTreasury(address sender) external view returns (bool);
    function isRewardSystem(address sender) external view returns (bool);
    function isPool(address sender) external view returns (bool);
    function isMarket(address sender) external view returns (bool);
    function setManagerStatus(address _manager, bool _status) external;
    function setManagerStatusBatch(address[] memory _managers, bool[] memory _statuses) external;
    function setContractAddresses(address _rewardSystemAddress, address _fundraiseAddress, address _treasuryAddress)
        external;
    function rewardSystemAddress() external view returns (address);
    function fundraiseAddress() external view returns (address);
    function treasuryAddress() external view returns (address);
    function setPoolStatus(address _pool, bool _status) external;
    function setPoolStatusForReward(address _pool, bool _status) external;
    function setInvestorClaimAddress(address _investor, address _claimAddress) external;
    /// @notice An alias for recipientOf, kept for deployed call sites.
    function getInvestorClaimAddress(address _investor) external view returns (address);

    function mandateFactory() external view returns (address);
    function setMandateFactory(address _mandateFactory) external;
    function recipientOf(address _user) external view returns (address);
    function isCompromised(address _user) external view returns (bool);
    /// @notice The head of a compromise chain for a superseded address, zero for everyone else.
    function canonicalOf(address _user) external view returns (address);
    /// @notice Where a user's records are filed: the head of the chain, or the address itself.
    function headOf(address _user) external view returns (address);
}

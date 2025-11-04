// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.23;

interface IManagerRegistry {
    function isManager(address sender) external view returns (bool);
    function isFundraise(address sender) external view returns (bool);
    function isTreasury(address sender) external view returns (bool);
    function isRewardSystem(address sender) external view returns (bool);
    function isPool(address sender) external view returns (bool);
    function setManagerStatus(address _manager, bool _status) external;
    function setManagerStatusBatch(address[] memory _managers, bool[] memory _statuses) external;
    function setContractAddresses(address _rewardSystemAddress, address _fundraiseAddress, address _treasuryAddress)
        external;
    function rewardSystemAddress() external view returns (address);
    function fundraiseAddress() external view returns (address);
    function treasuryAddress() external view returns (address);
    function setPoolStatus(address _pool, bool _status) external;
    function setInvestorClaimAddress(address _investor, address _claimAddress) external;
    function getInvestorClaimAddress(address _investor) external view returns (address);
}

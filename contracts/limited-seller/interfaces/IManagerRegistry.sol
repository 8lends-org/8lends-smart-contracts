// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.23;

interface IManagerRegistry {
    function setPoolStatusForReward(address _pool, bool _status) external;
    function getInvestorClaimAddress(address _investor) external view returns (address);
    function isPool(address _pool) external view returns (bool);
}

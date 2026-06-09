// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IManagerRegistry {
    function isManager(address sender) external view returns (bool);
}

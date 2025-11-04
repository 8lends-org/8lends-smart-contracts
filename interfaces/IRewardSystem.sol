// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IRewardSystem {
    function recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId) external;
    function activateProjectRewards(uint256 _projectId, uint256 _burnFee) external;
    function claimUSDCForProject(uint256 _projectId) external;
    function claimTokensForProject(uint256 _projectId) external;
    function sendUSDCForProjectToUser(address _user, uint256 _projectId) external;
    function sendTokensForProjectToUser(address _user, uint256 _projectId) external;

    function getUserInfo(address _user) external view returns (address inviter, bool isNewUser);

    function getVestingInfoForProject(address _user, uint256 _projectId)
        external
        view
        returns (uint256 totalAmount, uint256 claimedAmount, uint256 claimableAmount, uint256 startTime, bool isActive);

    function getProjectRewards(address _user, uint256 _projectId)
        external
        view
        returns (
            uint256 totalUSDC,
            uint256 totalTokens,
            uint256 claimedTokens,
            uint256 claimableTokens,
            bool isActivated
        );

    function getInviterStats(address _inviter) external view returns (uint256);

    function burnPercentage() external view returns (uint256);
}

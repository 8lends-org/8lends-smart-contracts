// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFundraise {
    enum Stage {
        ComingSoon,
        Open,
        Canceled,
        PreFunded,
        Funded,
        Repaid
    }

    struct Project {
        uint256 hardCap;
        uint256 softCap;
        uint256 totalInvested;
        uint256 startAt;
        uint256 preFundDuration;
        uint256 investorInterestRate;
        uint256 openStageEndAt;
        InnerProjectStruct innerStruct;
    }

    struct InnerProjectStruct {
        uint256 platformInterestRate;
        uint256 totalRepaid;
        address borrower;
        uint256 fundedTime;
        IERC20 loanToken;
        Stage stage;
    }

    struct InvestorInfo {
        uint256 investedAmount;
        uint256 totalClaimed;
    }

    function projectCount() external view returns (uint256);

    function projects(uint256 _projectId) external view returns (Project memory);

    function investorInfo(address _investor, uint256 _projectId) external view returns (InvestorInfo memory);

    /// @notice Principal of this position that has not come back yet, read through the same
    ///         interest-first waterfall the escrow's onPayout splits payouts by.
    function outstandingPrincipal(address _investor, uint256 _projectId) external view returns (uint256);

    /// @notice Everything a position of this size can ever claim. Taken from here rather than
    ///         computed from the rate: the two floor at different scales and disagree by a unit.
    function positionOwed(uint256 _projectId, uint256 _invested) external view returns (uint256);

    /// @notice What a position of this size has effectively claimed: the holder's aggregate
    ///         watermark apportioned to it, rounded up. The per-position field is stale.
    function positionClaimed(address _investor, uint256 _projectId, uint256 _invested)
        external
        view
        returns (uint256);

    /// @notice Places `amount` of the caller's USDC into `pid`, recording `owner` as the investor.
    /// @dev Callable only by an escrow of `owner`, which Fundraise checks against the factory in the
    ///      registry. The escrow approves exactly `amount` immediately before the call and resets
    ///      the allowance to zero after, so no standing allowance is left behind.
    function investFromMandate(address owner, uint256 pid, uint256 amount, address inviter) external;

    function transferPosition(uint256 _projectId, address _from, address _to, uint256 _positionIndex, uint256 _id) external;

    function getInvestorPositions(address _investor, uint256 _projectId) external view returns (InvestorInfo[] memory);

    function getPositionCount(address _investor, uint256 _projectId) external view returns (uint256);

    function BASIS_POINTS() external view returns (uint256);

    function trustedSigner() external view returns (address);
}

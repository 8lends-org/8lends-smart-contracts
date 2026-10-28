// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../interfaces/protocol/IFundraise.sol";
import "../interfaces/external/IUniswapV2Router02.sol";
import "../interfaces/protocol/IManagerRegistry.sol";
import "../interfaces/protocol/IMarket.sol";

/**
 * @title LimitedSeller
 * @notice Bought 8LNDS from Uniswap V2 against a quota earned by investing. Purchases are closed:
 *         `limitedBuy` refuses and the quota reports zero. What is left is the accrual, which keeps
 *         running, and the history, which still answers for itself.
 */
contract LimitedSeller is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 1e6; // 100% = 1_000_000 bp

    struct EstimateResult {
        uint256 fundedProjectsInvestedTotal;
        uint256 alreadyBoughtTokensInUSDC;
        uint256 availableBuyTokensInUSDC;
        uint256 percent;
    }

    IFundraise public fundraise;
    IUniswapV2Router02 public router;
    IERC20 public usdc;
    IERC20 public token;
    IManagerRegistry public managerRegistry;
    uint256 public percent;

    mapping(address => uint256) public boughtUsdcByUser;
    uint256 public totalBoughtInTokens;
    uint256 public totalBoughtInUSDC;
    mapping(address => uint256) public buyerNonce;
    IMarket public market;

    /// @notice Quota earned in USDC, per user, only ever growing. Accrues on each investment
    ///         through Fundraise and is spent by nothing: purchases are closed, so the number is a
    ///         record rather than a right.
    mapping(address => uint256) public earnedLimitUsdc;

    event Bought(
        address indexed buyer,
        address receiver,
        uint256 usdcAmount,
        uint256 tokensAmount,
        uint256 timestamp
    );
    event PercentSet(uint256 newPercent);
    event EarnedLimitIncreased(address indexed user, uint256 investedAmount, uint256 earnedDelta, uint256 newTotal);

    error ExceedsAvailableLimit();
    error EmptyProjectIds();
    error InsufficientTokensReceived();
    error InvalidPercent();
    error InvalidReceiver();
    error ManagerRegistryNotSet();
    error OnlyFundraise();
    error PurchasesClosed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (called once via proxy).
     * @param _fundraise Fundraise contract address.
     * @param _router Uniswap V2 router address.
     * @param _usdc USDC token address.
     * @param _token Token (8LND) address.
     * @param _percent Share of an investment that becomes quota, in BASIS_POINTS: 60000 is 6%.
     * @param _managerRegistry ManagerRegistry contract address (can be set later via setManagerRegistry).
     */
    function initialize(
        address _fundraise,
        address _router,
        address _usdc,
        address _token,
        uint256 _percent,
        address _managerRegistry
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        if (_percent > BASIS_POINTS) revert InvalidPercent();
        fundraise = IFundraise(_fundraise);
        router = IUniswapV2Router02(_router);
        usdc = IERC20(_usdc);
        token = IERC20(_token);
        percent = _percent;
        if (_managerRegistry != address(0)) {
            managerRegistry = IManagerRegistry(_managerRegistry);
        }
    }

    /**
     * @notice Set ManagerRegistry address (e.g. after upgrade). Owner only.
     */
    function setManagerRegistry(address _managerRegistry) external onlyOwner {
        managerRegistry = IManagerRegistry(_managerRegistry);
    }

    /**
     * @notice Set Market address for secondary investment tracking. Owner only.
     */
    function setMarket(address _market) external onlyOwner {
        market = IMarket(_market);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


    /**
     * @notice What the user invested and what they bought while buying was open.
     * @dev `availableBuyTokensInUSDC` is always zero — see the tail of the body for why the other
     *      two fields are still computed.
     * @param user User address.
     * @param projectIds Project IDs to consider (must be non-empty).
     */
    function estimateAvailableBuy(
        address user,
        uint256[] memory projectIds
    ) external view returns (EstimateResult memory result) {
        if (projectIds.length == 0) revert EmptyProjectIds();

        result.percent = percent;
        result.alreadyBoughtTokensInUSDC = boughtUsdcByUser[user];

        // Always compute fundedProjectsInvestedTotal for UI/subgraph consumers
        uint256 count = fundraise.projectCount();
        for (uint256 j; j < projectIds.length; ) {
            uint256 i = projectIds[j];
            if (i < count) {
                IFundraise.Project memory project = fundraise.projects(i);
                if (
                    project.innerStruct.stage == IFundraise.Stage.Funded
                        || project.innerStruct.stage == IFundraise.Stage.Repaid
                ) {
                    IFundraise.InvestorInfo memory info = fundraise.investorInfo(user, i);
                    uint256 primaryInvested = info.investedAmount;
                    if (address(market) != address(0)) {
                        uint256 secondary = market.secondaryInvestedAmount(user, i);
                        primaryInvested = primaryInvested > secondary ? primaryInvested - secondary : 0;
                    }
                    result.fundedProjectsInvestedTotal += primaryInvested;
                }
            }
            unchecked {
                ++j;
            }
        }

        // availableBuyTokensInUSDC stays zero: purchases are closed, so nothing is available
        // whatever the quota adds up to. The quota itself is left in storage, and the two fields
        // above are the user's history, which still answers for itself.
    }

    /// @notice Closed. The liquidity this bought from is gone, and there is no other path until the
    ///         new seller ships, so the call refuses before it touches a signature or any money.
    function limitedBuy(uint256, uint256, uint256[] memory, bytes memory) external pure {
        revert PurchasesClosed();
    }


    /**
     * @notice Called by Fundraise when a user invests. Accrues the token-buy limit.
     * @param user Investor address.
     * @param investedAmount USDC amount invested (6 decimals).
     */
    function addEarnedLimit(address user, uint256 investedAmount) external {
        if (msg.sender != address(fundraise)) revert OnlyFundraise();
        uint256 delta = (investedAmount * percent) / BASIS_POINTS;
        earnedLimitUsdc[user] += delta;
        emit EarnedLimitIncreased(user, investedAmount, delta, earnedLimitUsdc[user]);
    }

    /**
     * @notice One-time migration for pre-upgrade users. Sets earnedLimitUsdc
     *         from off-chain calculated historical data. Owner only.
     * @param users Array of user addresses.
     * @param limits Array of accumulated limit values in USDC (6 decimals).
     */
    function migrateEarnedLimits(address[] calldata users, uint256[] calldata limits) external onlyOwner {
        require(users.length == limits.length, "Length mismatch");
        for (uint256 i; i < users.length; ) {
            earnedLimitUsdc[users[i]] = limits[i];
            unchecked { ++i; }
        }
    }

    /// @notice In BASIS_POINTS: 60000 is 6%. Accrual keeps running while purchases are closed, so
    ///         this still decides what the quota grows by.
    function setPercent(uint256 _percent) external onlyOwner {
        if (_percent > BASIS_POINTS) revert InvalidPercent();
        percent = _percent;
        emit PercentSet(_percent);
    }
}

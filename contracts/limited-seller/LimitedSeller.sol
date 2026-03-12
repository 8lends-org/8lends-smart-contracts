// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IFundraise.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IManagerRegistry.sol";

/**
 * @title LimitedSeller
 * @notice Allows buying tokens from Uniswap V2 up to a limit: percent of user's
 *         total investment in Fundraise projects that are Funded or Repaid.
 *         Upgradeable via UUPS.
 */
contract LimitedSeller is Initializable, UUPSUpgradeable, OwnableUpgradeable {
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

    event Bought(
        address indexed buyer,
        address receiver,
        uint256 usdcAmount,
        uint256 tokensAmount,
        uint256 timestamp
    );
    event PercentSet(uint256 newPercent);

    error ExceedsAvailableLimit();
    error EmptyProjectIds();
    error InsufficientTokensReceived();
    error InvalidPercent();
    error InvalidReceiver();
    error ManagerRegistryNotSet();

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
     * @param _percent Limit in basis points (e.g. 600 for 6%).
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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


    /**
     * @notice Returns the buy limit for a user based on Fundraise investments.
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
                    result.fundedProjectsInvestedTotal += info.investedAmount;
                }
            }
            unchecked {
                ++j;
            }
        }

        uint256 limitUsdc = (result.fundedProjectsInvestedTotal * percent) / BASIS_POINTS;
        if (limitUsdc > result.alreadyBoughtTokensInUSDC) {
            result.availableBuyTokensInUSDC = limitUsdc - result.alreadyBoughtTokensInUSDC;
        }
    }


    /**
     * @notice Buy tokens with USDC within the user's limit. User must approve this contract for usdcAmount.
     * @param usdcAmount USDC amount to spend (6 decimals).
     * @param minTokensAmount Minimum tokens to receive (slippage protection).
     * @param projectIds Project IDs to consider for the limit (must be non-empty).
     */
    function _limitedBuy(
        uint256 usdcAmount,
        uint256 minTokensAmount,
        uint256[] memory projectIds
    ) internal {
        if (projectIds.length == 0) revert EmptyProjectIds();
        if (address(managerRegistry) == address(0)) revert ManagerRegistryNotSet();
        EstimateResult memory est = this.estimateAvailableBuy(msg.sender, projectIds);
        if (usdcAmount > est.availableBuyTokensInUSDC) revert ExceedsAvailableLimit();

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(token);

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        usdc.forceApprove(address(router), usdcAmount);

        address receiver = IManagerRegistry(managerRegistry).getInvestorClaimAddress(msg.sender);
        bool isPoolPrevStatus = IManagerRegistry(managerRegistry).isPool(receiver);
        uint256 balanceBefore = token.balanceOf(receiver);

        IManagerRegistry(managerRegistry).setPoolStatusForReward(receiver, true);
        router.swapExactTokensForTokens(
            usdcAmount,
            minTokensAmount,
            path,
            receiver,
            block.timestamp + 300
        );
        IManagerRegistry(managerRegistry).setPoolStatusForReward(receiver, isPoolPrevStatus);

        uint256 tokensReceived = token.balanceOf(receiver) - balanceBefore;
        if (tokensReceived < minTokensAmount) revert InsufficientTokensReceived();

        boughtUsdcByUser[msg.sender] += usdcAmount;
        totalBoughtInUSDC += usdcAmount;
        totalBoughtInTokens += tokensReceived;

        emit Bought(msg.sender, receiver, usdcAmount, tokensReceived, block.timestamp);
    }


    function limitedBuy(uint256 usdcAmount, uint256 minTokensAmount, uint256[] memory projectIds, bytes memory _sig) external {
        address trustedSignerAddr = fundraise.trustedSigner();
        require(trustedSignerAddr != address(0), "Trusted signer not set");
        uint256 nonce = buyerNonce[msg.sender];
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, nonce));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(_sig);
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "Invalid signature s");
        address signer = ecrecover(ethSignedMessageHash, v, r, s);
        require(signer != address(0), "Invalid signature");
        require(signer == trustedSignerAddr, "Not trusted signer");
        buyerNonce[msg.sender] = nonce + 1;
        _limitedBuy(usdcAmount, minTokensAmount, projectIds);
    }

    function _splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "Invalid signature length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }
    /**
     * @notice Set the limit in basis points (e.g. 600 for 6%). Owner only.
     */
    function setPercent(uint256 _percent) external onlyOwner {
        if (_percent > BASIS_POINTS) revert InvalidPercent();
        percent = _percent;
        emit PercentSet(_percent);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IManagerRegistry.sol";
import "./interfaces/IFundraise.sol";

contract Market is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    enum ListingStatus {
        Active,
        Cancelled,
        Sold
    }

    struct Listing {
        uint256 listingId;
        address seller;
        uint256 projectId;
        uint256 investedAmount;
        uint256 price;
        uint256 createdAt;
        ListingStatus status;
    }

    address public managerRegistry;
    address public fundraise;

    mapping(address => mapping(uint256 => uint256)) public activeListingIds;
    mapping(uint256 => Listing) public listings;
    uint256 public listingCount;

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        uint256 indexed projectId,
        uint256 investedAmount,
        uint256 price
    );

    event ListingBought(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 projectId,
        uint256 investedAmount,
        uint256 price
    );

    event ListingCancelled(
        uint256 indexed listingId,
        address indexed seller,
        uint256 indexed projectId
    );

    event ListingPriceUpdated(
        uint256 indexed listingId,
        uint256 oldPrice,
        uint256 newPrice
    );

    modifier onlyManager() {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");
        _;
    }

    modifier onlyFundraise() {
        require(IManagerRegistry(managerRegistry).isFundraise(msg.sender), "Not a fundraise");
        _;
    }

    /// @notice Authorize contract upgrade (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _managerRegistry, address _fundraise) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        managerRegistry = _managerRegistry;
        fundraise = _fundraise;
    }

    /// @notice Create listing for selling investment
    /// @param _projectId Project ID in Fundraise
    /// @param _price Price in loan tokens
    /// @return listingId Created listing ID
    function createListing(uint256 _projectId, uint256 _price) external returns (uint256 listingId) {
        address seller = msg.sender;
        require(activeListingIds[seller][_projectId] == 0, "Active listing exists");
        IFundraise.InvestorInfo memory investor = IFundraise(fundraise).investorInfo(seller, _projectId);
        require(investor.investedAmount > 0, "No investment found");
        IFundraise.Project memory project = IFundraise(fundraise).projects(_projectId);
        require(project.innerStruct.stage == IFundraise.Stage.Funded, "Project not funded");
        uint256 maxReturn = investor.investedAmount
            + (investor.investedAmount * project.investorInterestRate / IFundraise(fundraise).BASIS_POINTS());
        uint256 remainingForBuyer = maxReturn - investor.totalClaimed;
        require(_price <= remainingForBuyer, "Price exceeds buyer return");
        listingId = ++listingCount;
        listings[listingId] = Listing({
            listingId: listingId,
            seller: seller,
            projectId: _projectId,
            investedAmount: investor.investedAmount,
            price: _price,
            createdAt: block.timestamp,
            status: ListingStatus.Active
        });
        activeListingIds[seller][_projectId] = listingId;
        emit ListingCreated(listingId, seller, _projectId, investor.investedAmount, _price);
        return listingId;
    }

    /// @notice Buy listing
    /// @param _listingId Listing ID to buy
    function buyListing(uint256 _listingId) external nonReentrant {
        Listing storage listing = listings[_listingId];
        require(listing.status == ListingStatus.Active, "Listing not active");
        require(msg.sender != listing.seller, "Cannot buy own listing");
        IFundraise.InvestorInfo memory currentInvestor = IFundraise(fundraise).investorInfo(
            listing.seller,
            listing.projectId
        );
        require(
            currentInvestor.investedAmount == listing.investedAmount,
            "Investment amount changed"
        );
        IFundraise.Project memory project = IFundraise(fundraise).projects(listing.projectId);
        IERC20 loanToken = project.innerStruct.loanToken;
        loanToken.safeTransferFrom(msg.sender, listing.seller, listing.price);
        IFundraise(fundraise).transferInvestment(
            listing.projectId,
            listing.seller,
            msg.sender,
            listing.investedAmount
        );
        listing.status = ListingStatus.Sold;
        activeListingIds[listing.seller][listing.projectId] = 0;
        emit ListingBought(
            _listingId,
            msg.sender,
            listing.seller,
            listing.projectId,
            listing.investedAmount,
            listing.price
        );
    }

    /// @notice Cancel listing
    /// @param _listingId Listing ID to cancel
    function cancelListing(uint256 _listingId) external {
        Listing storage listing = listings[_listingId];
        require(msg.sender == listing.seller, "Not seller");
        require(listing.status == ListingStatus.Active, "Listing not active");
        listing.status = ListingStatus.Cancelled;
        activeListingIds[listing.seller][listing.projectId] = 0;
        emit ListingCancelled(_listingId, listing.seller, listing.projectId);
    }

    /// @notice Update listing price
    /// @param _listingId Listing ID
    /// @param _newPrice New price
    function updateListingPrice(uint256 _listingId, uint256 _newPrice) external {
        Listing storage listing = listings[_listingId];
        require(msg.sender == listing.seller, "Not seller");
        require(listing.status == ListingStatus.Active, "Listing not active");
        IFundraise.InvestorInfo memory investor = IFundraise(fundraise).investorInfo(
            listing.seller,
            listing.projectId
        );
        IFundraise.Project memory project = IFundraise(fundraise).projects(listing.projectId);
        uint256 maxReturn = listing.investedAmount
            + (listing.investedAmount * project.investorInterestRate / IFundraise(fundraise).BASIS_POINTS());
        uint256 remainingForBuyer = maxReturn - investor.totalClaimed;
        require(_newPrice <= remainingForBuyer, "Price exceeds buyer return");
        uint256 oldPrice = listing.price;
        listing.price = _newPrice;
        emit ListingPriceUpdated(_listingId, oldPrice, _newPrice);
    }

    /// @notice Check if listing can be created
    /// @param _projectId Project ID
    /// @param _seller Seller address
    /// @return bool True if listing can be created
    function canCreateListing(uint256 _projectId, address _seller) external view returns (bool) {
        if (activeListingIds[_seller][_projectId] != 0) {
            return false;
        }
        IFundraise.InvestorInfo memory investor = IFundraise(fundraise).investorInfo(_seller, _projectId);
        if (investor.investedAmount == 0) {
            return false;
        }
        IFundraise.Project memory project = IFundraise(fundraise).projects(_projectId);
        return project.innerStruct.stage == IFundraise.Stage.Funded;
    }

    /// @notice Get active listing for seller and project
    /// @param _seller Seller address
    /// @param _projectId Project ID
    /// @return listing Active listing
    function getActiveListing(address _seller, uint256 _projectId)
        external
        view
        returns (Listing memory listing)
    {
        uint256 listingId = activeListingIds[_seller][_projectId];
        require(listingId != 0, "No active listing");
        return listings[listingId];
    }

    /// @notice Get listing by ID
    /// @param _listingId Listing ID
    /// @return listing Listing data
    function getListing(uint256 _listingId) external view returns (Listing memory listing) {
        return listings[_listingId];
    }

    /// @notice Set fundraise address
    /// @param _fundraise New fundraise address
    function setFundraise(address _fundraise) external onlyOwner {
        fundraise = _fundraise;
    }
}
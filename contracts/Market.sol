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

    enum SaleStatus {
        Active,
        Sold,
        Cancelled
    }

    struct Sale {
        uint256 saleId;
        address seller;
        address buyer;
        uint256 projectId;
        address marketCell;
        uint256 price;
        uint256 fee;
        uint256 maxReturn;
        uint256 totalClaimed;
        uint256 createdAt;
        SaleStatus status;
    }


    address public managerRegistry;

    uint256 public saleCount;
    mapping(uint256 => Sale) public sales;
    mapping(address => mapping(uint256 => uint256)) public activeSaleIds;
    mapping(address => uint256[]) public soldSales;
    mapping(address => uint256[]) public boughtSales;

    // 1% = 10000, same as Fundraise.BASIS_POINTS
    uint256 public constant BASIS_POINTS = 1000000;
    uint256 public platformFee;
    mapping(address => uint256) public accumulatedFees;

    event SaleCreated(
        uint256 indexed saleId,
        address indexed seller,
        uint256 indexed projectId,
        address marketCell,
        uint256 price
    );

    event SaleBought(
        uint256 indexed saleId,
        address indexed buyer,
        address indexed seller,
        uint256 projectId
    );

    event SaleCancelled(uint256 indexed saleId, address indexed seller, uint256 indexed projectId);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeCollected(address indexed token, uint256 amount);

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

    function initialize(address _managerRegistry) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        managerRegistry = _managerRegistry;
        platformFee = 0;
    }

    /// @notice Get fundraise address from manager registry
    /// @return fundraiseAddress Address of fundraise contract
    function getFundraise() internal view returns (address fundraiseAddress) {
        return IManagerRegistry(managerRegistry).fundraiseAddress();
    }


    /// @notice Sell investment - creates market cell and transfers investment to it
    /// @param _projectId Project ID
    /// @param _price Price in loan tokens
    /// @return saleId Created sale ID
    function sell(uint256 _projectId, uint256 _price) external nonReentrant returns (uint256 saleId) {
        address fundraiseAddress = getFundraise();
        address seller = msg.sender;
        require(activeSaleIds[seller][_projectId] == 0, "Active sale exists");
        IFundraise.InvestorInfo memory investor = IFundraise(fundraiseAddress).investorInfo(seller, _projectId);
        require(investor.investedAmount > 0, "No investment found");
        require(_price > 0, "Price must be greater than zero");
        IFundraise.Project memory project = IFundraise(fundraiseAddress).projects(_projectId);
        require(project.innerStruct.stage == IFundraise.Stage.Funded, "Only funded projects can be sold");
        uint256 maxReturn = investor.investedAmount
            + (investor.investedAmount * project.investorInterestRate / BASIS_POINTS);
        require(maxReturn >= investor.totalClaimed, "Total claimed exceeds max return");
        uint256 remainingForBuyer = maxReturn - investor.totalClaimed;
        require(_price <= remainingForBuyer, "Price exceeds buyer return");
        saleId = ++saleCount;
        
        // Create address containing saleId: 0x{saleId}{zeros}{hash}
        // Format: first 4 bytes = saleId, next 4 bytes = zeros (separator), last 12 bytes = from hash
        // Address is 160 bits (20 bytes): [4 bytes saleId][4 bytes zeros][12 bytes hash]
        bytes32 hash = keccak256(abi.encodePacked(saleId, seller, _projectId, address(this), block.chainid));
        address marketCell = address(uint160(
            (uint256(saleId) << 128) | (uint256(hash) & 0xFFFFFFFFFFFFFFFFFFFFFFFF)
        ));
        require(marketCell != address(0), "Market cell address cannot be zero");
        IFundraise(fundraiseAddress).transferInvestment(_projectId, seller, marketCell, true, saleId);
        sales[saleId] = Sale({
            saleId: saleId,
            seller: seller,
            buyer: address(0),
            projectId: _projectId,
            marketCell: marketCell,
            price: _price,
            fee: platformFee,
            maxReturn: maxReturn,
            totalClaimed: investor.totalClaimed,
            createdAt: block.timestamp,
            status: SaleStatus.Active
        });
        activeSaleIds[seller][_projectId] = saleId;
        emit SaleCreated(saleId, seller, _projectId, marketCell, _price);
        return saleId;
    }

    /// @notice Buy investment - transfers investment from market cell to buyer and payment to seller
    /// @param _saleId Sale ID to buy
    function buy(uint256 _saleId) external nonReentrant {
        require(_saleId > 0 && _saleId <= saleCount, "Invalid sale ID");
        address fundraiseAddress = getFundraise();
        Sale storage sale = sales[_saleId];
        require(sale.status == SaleStatus.Active, "Sale not active");
        require(msg.sender != sale.seller, "Cannot buy own sale");
        IFundraise.InvestorInfo memory marketCellInfo = IFundraise(fundraiseAddress).investorInfo(sale.marketCell, sale.projectId);
        require(marketCellInfo.investedAmount > 0, "Market cell has no investment");
        IFundraise.Project memory project = IFundraise(fundraiseAddress).projects(sale.projectId);
        IERC20 loanToken = project.innerStruct.loanToken;
        uint256 feeAmount = (sale.price * sale.fee) / BASIS_POINTS;
        uint256 sellerAmount = sale.price - feeAmount;
        loanToken.safeTransferFrom(msg.sender, address(this), feeAmount);
        loanToken.safeTransferFrom(msg.sender, sale.seller, sellerAmount);
        accumulatedFees[address(loanToken)] += feeAmount;
        IFundraise(fundraiseAddress).transferInvestment(sale.projectId, sale.marketCell, msg.sender, false, _saleId);
        sale.buyer = msg.sender;
        sale.status = SaleStatus.Sold;
        activeSaleIds[sale.seller][sale.projectId] = 0;
        boughtSales[msg.sender].push(_saleId);
        soldSales[sale.seller].push(_saleId);
        emit SaleBought(_saleId, msg.sender, sale.seller, sale.projectId);
        if (feeAmount > 0) {
            emit FeeCollected(address(loanToken), feeAmount);
        }
    }

    /// @notice Cancel sale - returns investment from market cell back to seller
    /// @param _saleId Sale ID to cancel
    function cancel(uint256 _saleId) external nonReentrant {
        require(_saleId > 0 && _saleId <= saleCount, "Invalid sale ID");
        address fundraiseAddress = getFundraise();
        Sale storage sale = sales[_saleId];
        require(msg.sender == sale.seller, "Not seller");
        require(sale.status == SaleStatus.Active, "Sale not active");
        IFundraise(fundraiseAddress).transferInvestment(sale.projectId, sale.marketCell, sale.seller, false, _saleId);
        sale.status = SaleStatus.Cancelled;
        activeSaleIds[sale.seller][sale.projectId] = 0;
        emit SaleCancelled(_saleId, sale.seller, sale.projectId);
    }

    /// @notice Set platform fee (owner only)
    /// @param _fee Fee in basis points (1% = 10000)
    function setPlatformFee(uint256 _fee) external onlyOwner {
        require(_fee <= BASIS_POINTS, "Fee exceeds 100%");
        uint256 oldFee = platformFee;
        platformFee = _fee;
        emit PlatformFeeUpdated(oldFee, _fee);
    }

    /// @notice Withdraw accumulated fees (owner only)
    /// @param _token Token address to withdraw
    /// @param _to Address to send fees to
    function withdrawFees(address _token, address _to) external onlyOwner {
        require(_to != address(0), "Invalid recipient address");
        uint256 amount = accumulatedFees[_token];
        require(amount > 0, "No fees to withdraw");
        accumulatedFees[_token] = 0;
        IERC20(_token).safeTransfer(_to, amount);
    }
    
    /// @notice Get sold sales for a user
    /// @param _user User address
    /// @return saleIds Array of sale IDs sold by user
    function getSoldSales(address _user) external view returns (uint256[] memory) {
        return soldSales[_user];
    }

    /// @notice Get bought sales for a user
    /// @param _user User address
    /// @return saleIds Array of sale IDs bought by user
    function getBoughtSales(address _user) external view returns (uint256[] memory) {
        return boughtSales[_user];
    }

    function getSale(uint256 _saleId) external view returns (Sale memory) {
        return sales[_saleId];
    }
}
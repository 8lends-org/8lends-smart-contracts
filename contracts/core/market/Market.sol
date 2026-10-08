// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../interfaces/protocol/IManagerRegistry.sol";
import "../../interfaces/protocol/IFundraise.sol";
import { IMandateFactory } from "../../mandate/interfaces/IMandateFactory.sol";

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
        uint256 positionIndex;
        /// @dev Zero means the seller, which is what pre-upgrade records hold.
        address proceedsTo;
    }


    address public managerRegistry;

    uint256 public saleCount;
    mapping(uint256 => Sale) public sales;
    /// @dev Deprecated: old single-sale-per-project mapping. Preserved for upgrade safety.
    mapping(address => mapping(uint256 => uint256)) public activeSaleIds;
    mapping(address => uint256[]) public soldSales;
    mapping(address => uint256[]) public boughtSales;

    // 1% = 10000, same as Fundraise.BASIS_POINTS
    /// @dev EIP-712 with the smallest domain that still pins the deployment: no name or version,
    ///      because nobody reads these in a wallet — the backend signs them.
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 private constant SELL_TYPEHASH =
        keccak256("Sell(address seller,uint256 projectId,uint256 price,uint256 positionIndex,uint256 deadline)");
    bytes32 private constant SELL_FOR_TYPEHASH = keccak256(
        "SellFor(address recovery,address owner,uint256 projectId,uint256 price,uint256 positionIndex,uint256 deadline)"
    );
    bytes32 private constant BUY_TYPEHASH = keccak256("Buy(address buyer,uint256 saleId)");

    /// @notice What this implementation promises its callers, not a release number. It moves only
    ///         when a change breaks them — a method removed, an argument added, a signature format
    ///         replaced. An ordinary upgrade leaves it where it is, so a client that reads it once
    ///         can trust the answer until it changes.
    /// @dev No version() at all means a deployment older than this field, which signs the way
    ///      things were signed before EIP-712.
    uint256 public constant version = 1;

    uint256 public constant BASIS_POINTS = 1000000;
    uint256 public platformFee;
    mapping(address => uint256) public accumulatedFees;

    /// @notice Tracks total investment amounts acquired via secondary market per user per project
    mapping(address => mapping(uint256 => uint256)) public secondaryInvestedAmount;

    /// @notice Active sale tracking per position: seller => projectId => positionIndex => saleId
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public activePositionSaleIds;

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
    /// @notice Who was actually paid, resolved at the buy.
    /// @dev The indexer must read the recipient here, never cache it off SaleCreated: the seller
    ///      may move it while the lot is up, and a buy racing that setter decides.
    event SaleProceedsPaid(uint256 indexed saleId, address indexed recipient);
    /// @notice The seller repointed a lot that is already up.
    event SaleProceedsToSet(uint256 indexed saleId, address indexed recipient);
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

    /// @notice Sell a specific investment position on the secondary market
    /// @param _projectId Project ID
    /// @param _price Price in loan tokens
    /// @param _positionIndex Index of the position to sell in seller's positions array
    /// @return saleId Created sale ID
    function sell(uint256 _projectId, uint256 _price, uint256 _positionIndex, uint256 _deadline, bytes memory _sig)
        external
        nonReentrant
        returns (uint256 saleId)
    {
        _verifySellSignature(_projectId, _price, _positionIndex, _deadline, _sig);
        return _executeSell(msg.sender, _projectId, _price, _positionIndex, msg.sender);
    }

    /// @notice List a position held by an address that was compromised, called from its recovery address.
    /// @dev The position stays recorded under `_owner` in Fundraise, so the sale is booked there too
    ///      and nothing downstream has to know a recovery chain exists. No proceeds parameter: for a
    ///      compromised seller the buy path pays recipientOf regardless of what was recorded.
    function sellFor(
        address _owner,
        uint256 _projectId,
        uint256 _price,
        uint256 _positionIndex,
        uint256 _deadline,
        bytes memory _sig
    )
        external
        nonReentrant
        returns (uint256 saleId)
    {
        _verifySellForSignature(_owner, _projectId, _price, _positionIndex, _deadline, _sig);
        // Only the live end of _owner's chain. For an address that was never in one this is _owner
        // themselves, so the function reaches nothing `sell` does not already reach.
        require(
            IManagerRegistry(managerRegistry).recipientOf(_owner) == msg.sender, "Not the recovery address"
        );
        return _executeSell(_owner, _projectId, _price, _positionIndex, msg.sender);
    }

    /// @notice Sell a position and name where the proceeds go.
    /// @param _proceedsTo Seller's own address or an escrow of theirs; zero is refused
    function sell(
        uint256 _projectId,
        uint256 _price,
        uint256 _positionIndex,
        address _proceedsTo,
        uint256 _deadline,
        bytes memory _sig
    )
        external
        nonReentrant
        returns (uint256 saleId)
    {
        // The same approval the plain listing uses: _requireOwnPayee already confines the payee to
        // the seller's own escrow, so there is nothing left for the backend to approve about it.
        _verifySellSignature(_projectId, _price, _positionIndex, _deadline, _sig);
        _requireOwnPayee(_proceedsTo);
        return _executeSell(msg.sender, _projectId, _price, _positionIndex, _proceedsTo);
    }

    /// @notice The backend's approval of one listing.
    /// @dev No nonce: listing empties the position the signature names, and a cancelled lot comes
    ///      back under a new index, so the same approval cannot be spent twice.
    function _verifySellSignature(
        uint256 _projectId,
        uint256 _price,
        uint256 _positionIndex,
        uint256 _deadline,
        bytes memory _sig
    ) internal view {
        require(block.timestamp <= _deadline, "Signature expired");
        _requireTrustedSigner(
            getFundraise(),
            keccak256(abi.encode(SELL_TYPEHASH, msg.sender, _projectId, _price, _positionIndex, _deadline)),
            _sig
        );
    }

    /// @dev A recovery address can stand behind several compromised wallets; an approval naming one
    ///      must not list a position of another.
    function _verifySellForSignature(
        address _owner,
        uint256 _projectId,
        uint256 _price,
        uint256 _positionIndex,
        uint256 _deadline,
        bytes memory _sig
    ) internal view {
        require(block.timestamp <= _deadline, "Signature expired");
        _requireTrustedSigner(
            getFundraise(),
            keccak256(
                abi.encode(SELL_FOR_TYPEHASH, msg.sender, _owner, _projectId, _price, _positionIndex, _deadline)
            ),
            _sig
        );
    }

    /// @dev Built per call rather than cached. A cold SLOAD costs more than hashing three words,
    ///      there is no slot to initialise on a proxy that is already live, and a chain that forks
    ///      gets the right separator without anyone remembering to refresh it.
    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    /// @dev Shared by listing and buy, so the two cannot drift apart.
    /// @dev The typehash separates messages by name instead of by how many bytes they happen to
    ///      pack into, and \x19\x01 keeps the whole family apart from anything signed as a personal
    ///      message — which is what the other contracts on this key still do. ECDSA.recover carries
    ///      the length, malleability and zero-address checks, so none of them are rebuilt here.
    function _requireTrustedSigner(address _fundraise, bytes32 _structHash, bytes memory _sig) internal view {
        address trustedSignerAddr = IFundraise(_fundraise).trustedSigner();
        require(trustedSignerAddr != address(0), "Trusted signer not set");
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), _structHash);
        require(ECDSA.recover(digest, _sig) == trustedSignerAddr, "Not trusted signer");
    }

    /// @dev Ownership is derived from the address, not asked of it — a look-alike would answer
    ///      owner() with anything. Not rechecked at buy time: an escrow is a hookless clone, so it
    ///      cannot refuse an incoming transfer or be removed.
    function _requireOwnPayee(address _proceedsTo) internal view {
        if (_proceedsTo == msg.sender) return;
        require(_proceedsTo != address(0), "Proceeds address is zero");
        address factory = IManagerRegistry(managerRegistry).mandateFactory();
        require(factory != address(0), "Mandate factory not set");
        require(IMandateFactory(factory).isEscrowOf(msg.sender, _proceedsTo), "Not an escrow of the seller");
    }

    /// @param _owner The address the position is recorded under; `msg.sender` unless called via sellFor.
    function _executeSell(
        address _owner,
        uint256 _projectId,
        uint256 _price,
        uint256 _positionIndex,
        address _proceedsTo
    ) internal returns (uint256 saleId) {
        address fundraiseAddress = getFundraise();
        require(!IManagerRegistry(managerRegistry).isCompromised(msg.sender), "Seller is compromised");
        require(activePositionSaleIds[_owner][_projectId][_positionIndex] == 0, "Active sale exists for position");
        require(_price > 0, "Price must be greater than zero");

        IFundraise.InvestorInfo[] memory positions = IFundraise(fundraiseAddress).getInvestorPositions(_owner, _projectId);
        require(_positionIndex < positions.length, "Position index out of bounds");
        require(positions[_positionIndex].investedAmount > 0, "No investment in position");

        uint256 maxReturn;
        uint256 posClaimed;
        {
            IFundraise.Project memory project = IFundraise(fundraiseAddress).projects(_projectId);
            require(project.innerStruct.stage == IFundraise.Stage.Funded, "Only funded projects can be sold");
            uint256 posInvested = positions[_positionIndex].investedAmount;
            // Fundraise's ceiling, not the rate applied here: the two floor at different scales.
            maxReturn = IFundraise(fundraiseAddress).positionOwed(_projectId, posInvested);
            // The same watermark transferPosition will hand the buyer, so the two cannot disagree.
            posClaimed = IFundraise(fundraiseAddress).positionClaimed(_owner, _projectId, posInvested);
            // Clamped, not asserted: the watermark rounds up and the ceiling floors, so on a
            // claimed-out position the two can cross. That is a lot with nothing left to sell.
            uint256 room = maxReturn > posClaimed ? maxReturn - posClaimed : 0;
            require(_price <= room, "Price exceeds buyer return");
        }

        saleId = ++saleCount;

        address marketCell;
        {
            bytes32 hash = keccak256(abi.encodePacked(saleId, _owner, _projectId, address(this), block.chainid));
            marketCell = address(uint160(
                (uint256(saleId) << 128) | (uint256(hash) & 0xFFFFFFFFFFFFFFFFFFFFFFFF)
            ));
        }
        require(marketCell != address(0), "Market cell address cannot be zero");
        IFundraise(fundraiseAddress).transferPosition(_projectId, _owner, marketCell, _positionIndex, saleId);

        Sale storage sale = sales[saleId];
        sale.saleId = saleId;
        sale.seller = _owner;
        sale.projectId = _projectId;
        sale.marketCell = marketCell;
        sale.price = _price;
        sale.fee = platformFee;
        sale.maxReturn = maxReturn;
        sale.totalClaimed = posClaimed;
        sale.createdAt = block.timestamp;
        sale.positionIndex = _positionIndex;
        sale.proceedsTo = _proceedsTo;

        activePositionSaleIds[_owner][_projectId][_positionIndex] = saleId;
        emit SaleCreated(saleId, _owner, _projectId, marketCell, _price);
    }

    /// @notice Buy a listed position, with the backend's approval of the buyer.
    /// @param _saleId Sale ID to buy
    /// @param _sig Signature from backend (trustedSigner) over Buy(buyer, saleId)
    /// @dev No nonce and no deadline: a lot is bought once, which already spends the approval.
    function buy(uint256 _saleId, bytes memory _sig) external nonReentrant {
        require(_saleId > 0 && _saleId <= saleCount, "Invalid sale ID");
        address fundraiseAddress = getFundraise();
        _requireTrustedSigner(fundraiseAddress, keccak256(abi.encode(BUY_TYPEHASH, msg.sender, _saleId)), _sig);
        _executeBuy(_saleId, fundraiseAddress);
    }

    function _executeBuy(uint256 _saleId, address fundraiseAddress) internal {
        Sale storage sale = sales[_saleId];
        require(sale.status == SaleStatus.Active, "Sale not active");
        require(msg.sender != sale.seller, "Cannot buy own sale");
        IFundraise.InvestorInfo memory marketCellInfo = IFundraise(fundraiseAddress).investorInfo(sale.marketCell, sale.projectId);
        require(marketCellInfo.investedAmount > 0, "Market cell has no investment");
        IFundraise.Project memory project = IFundraise(fundraiseAddress).projects(sale.projectId);
        IERC20 loanToken = project.innerStruct.loanToken;
        uint256 feeAmount = (sale.price * sale.fee) / BASIS_POINTS;
        uint256 sellerAmount = sale.price - feeAmount;
        // The chain outranks the recorded payee, which a key that is no longer the owner's may have
        // chosen. Buys stay open so a lot listed before the theft still settles.
        address recipient = IManagerRegistry(managerRegistry).recipientOf(sale.seller);
        if (recipient == sale.seller && sale.proceedsTo != address(0)) recipient = sale.proceedsTo;
        loanToken.safeTransferFrom(msg.sender, address(this), feeAmount);
        loanToken.safeTransferFrom(msg.sender, recipient, sellerAmount);
        accumulatedFees[address(loanToken)] += feeAmount;
        // Market cell always has the position at index 0
        IFundraise(fundraiseAddress).transferPosition(sale.projectId, sale.marketCell, msg.sender, 0, _saleId);
        secondaryInvestedAmount[msg.sender][sale.projectId] += marketCellInfo.investedAmount;
        if (secondaryInvestedAmount[sale.seller][sale.projectId] >= marketCellInfo.investedAmount) {
            secondaryInvestedAmount[sale.seller][sale.projectId] -= marketCellInfo.investedAmount;
        } else {
            secondaryInvestedAmount[sale.seller][sale.projectId] = 0;
        }
        sale.buyer = msg.sender;
        sale.status = SaleStatus.Sold;
        activePositionSaleIds[sale.seller][sale.projectId][sale.positionIndex] = 0;
        boughtSales[msg.sender].push(_saleId);
        soldSales[sale.seller].push(_saleId);
        emit SaleBought(_saleId, msg.sender, sale.seller, sale.projectId);
        emit SaleProceedsPaid(_saleId, recipient);
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
        // Same gate as listing. The superseded address gets no proceeds either way, but left in it
        // could cancel every relisting for the price of gas and keep the position unsellable.
        require(msg.sender == IManagerRegistry(managerRegistry).recipientOf(sale.seller), "Not seller");
        require(sale.status == SaleStatus.Active, "Sale not active");
        // Market cell always has the position at index 0
        IFundraise(fundraiseAddress).transferPosition(sale.projectId, sale.marketCell, sale.seller, 0, _saleId);
        sale.status = SaleStatus.Cancelled;
        activePositionSaleIds[sale.seller][sale.projectId][sale.positionIndex] = 0;
        emit SaleCancelled(_saleId, sale.seller, sale.projectId);
    }

    /// @notice Point an already listed lot at another address of the seller's.
    /// @dev Saves cancelling and relisting when a mandate moves. Price, fee, saleId and the
    ///      position in the service cell all stay put.
    function setSaleProceedsTo(uint256 _saleId, address _proceedsTo) public {
        require(_saleId > 0 && _saleId <= saleCount, "Invalid sale ID");
        Sale storage sale = sales[_saleId];
        require(msg.sender == sale.seller, "Not seller");
        require(sale.status == SaleStatus.Active, "Sale not active");

        _requireOwnPayee(_proceedsTo);
        sale.proceedsTo = _proceedsTo;
        emit SaleProceedsToSet(_saleId, _proceedsTo);
    }

    /// @notice Same for many lots — one call beside setRouteMany when a portfolio moves.
    /// @dev Reverts as a whole if any element fails, so filter the list before sending.
    function setSaleProceedsToMany(uint256[] calldata _saleIds, address _proceedsTo) external {
        for (uint256 i = 0; i < _saleIds.length; i++) {
            setSaleProceedsTo(_saleIds[i], _proceedsTo);
        }
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
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookListingRegistry} from "./HookListingRegistry.sol";
import {StoreAdmin} from "./StoreAdmin.sol";
import {IStoreToken, ExactStoreToken} from "./ExactStoreToken.sol";

/// @title Optional, refundable Hooks Store advertising
/// @notice 0.1 IMD buys seven days of #ad placement, oldest purchase first. IMD has 18 decimals.
/// Balances belong to depositors; locked fees cannot be claimed until cancellation or expiry.
contract FeaturedPlacements is StoreAdmin {
    error Reentrancy();
    error TokenNotConfigured();
    error TokenAlreadyConfigured();
    error InvalidToken();
    error RecipientNotConfigured();
    error InvalidAmount();
    error InsufficientBalance();
    error NotListingOwner();
    error ListingInactive();
    error TermsChanged();
    error DeadlineExpired();
    error AlreadyFeatured();
    error UnknownPlacement();
    error NotPayer();
    error PlacementClosed();
    error PlacementExpired();
    error PlacementNotExpired();
    error InvalidPage();

    uint256 public constant PRICE = 100_000_000_000_000_000;
    uint256 public constant DURATION = 7 days;
    uint256 public constant MAX_SCAN = 100;
    bytes3 public constant AD_LABEL = "#ad";

    enum Status {
        None,
        Open,
        Cancelled,
        Settled
    }

    struct Placement {
        uint256 id;
        uint256 listingId;
        uint256 revision;
        address payer;
        address recipient;
        uint256 startsAt;
        uint256 endsAt;
        uint256 closedAt;
        uint256 refund;
        Status status;
        bytes3 label;
    }

    event TokenConfigured(address indexed token);
    event ProceedsRecipientSet(address indexed previousRecipient, address indexed recipient);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, address indexed to, uint256 amount);
    event PlacementPurchased(
        uint256 indexed id,
        uint256 indexed listingId,
        address indexed payer,
        uint256 revision,
        address recipient,
        uint256 startsAt,
        uint256 endsAt,
        uint256 price,
        bytes3 label
    );
    event PlacementCancelled(uint256 indexed id, uint256 refund, uint256 earned);
    event PlacementSettled(uint256 indexed id, address indexed recipient, uint256 earned);
    event ProceedsWithdrawn(address indexed recipient, address indexed to, uint256 amount);

    HookListingRegistry public immutable registry;
    address public imd;
    address public proceedsRecipient;
    uint256 public placementCount;
    mapping(uint256 => Placement) private _placements;
    mapping(uint256 => uint256) public latestPlacement;
    mapping(address => uint256) public available;
    mapping(address => uint256) public proceeds;
    uint256 public totalAvailable;
    uint256 public totalEscrowed;
    uint256 public totalProceeds;
    uint256 private _entered;

    /// @dev No external calls or external-code requirements at construction, including on an empty chain.
    constructor(address owner_, HookListingRegistry registry_) StoreAdmin(owner_) {
        if (address(registry_) == address(0) || address(registry_) == address(this)) revert InvalidAddress();
        registry = registry_;
    }

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    /// @notice One-time, owner-only choice of the reviewed IMD contract on this chain.
    /// Locked forever to prevent replacing the asset backing existing user balances.
    function configureToken(address token) external onlyOwner nonReentrant {
        if (imd != address(0)) revert TokenAlreadyConfigured();
        if (token == address(this) || token.code.length == 0) revert InvalidToken();
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IStoreToken.decimals, ()));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != 18) revert InvalidToken();
        // Check the balance ABI too; identity and non-rebasing behavior require operator review.
        ExactStoreToken.balance(token, address(this));
        imd = token;
        emit TokenConfigured(token);
    }

    /// @notice Applies only to future purchases. Each purchase pins its recipient.
    function setProceedsRecipient(address recipient) external onlyOwner {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        address previousRecipient = proceedsRecipient;
        proceedsRecipient = recipient;
        emit ProceedsRecipientSet(previousRecipient, recipient);
    }

    function deposit(uint256 amount) external nonReentrant {
        address token = _token();
        if (amount == 0) revert InvalidAmount();
        ExactStoreToken.pull(token, msg.sender, amount);
        // Credit only the exact amount successfully received. Guard covers token callbacks.
        available[msg.sender] += amount;
        totalAvailable += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount, address to) external nonReentrant {
        address token = _token();
        _validateWithdrawal(amount, to);
        if (amount > available[msg.sender]) revert InsufficientBalance();
        available[msg.sender] -= amount;
        totalAvailable -= amount;
        ExactStoreToken.push(token, to, amount);
        emit Withdrawn(msg.sender, to, amount);
    }

    /// @notice Buy from the caller's deposit; only the current listing owner may advertise it.
    /// expectedRevision/expectedRecipient/deadline protect the reviewable purchase terms.
    function purchase(uint256 listingId, uint256 expectedRevision, address expectedRecipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        _token();
        address recipient = proceedsRecipient;
        if (recipient == address(0)) revert RecipientNotConfigured();
        if (block.timestamp > deadline) revert DeadlineExpired();
        HookListingRegistry.Listing memory item = registry.getListing(listingId);
        if (msg.sender != item.owner) revert NotListingOwner();
        if (!item.active) revert ListingInactive();
        if (item.revision != expectedRevision || recipient != expectedRecipient) revert TermsChanged();
        Placement storage previous = _placements[latestPlacement[listingId]];
        if (previous.status == Status.Open && block.timestamp < previous.endsAt) revert AlreadyFeatured();
        if (available[msg.sender] < PRICE) revert InsufficientBalance();
        available[msg.sender] -= PRICE;
        totalAvailable -= PRICE;
        totalEscrowed += PRICE;
        id = ++placementCount;
        uint256 endsAt = block.timestamp + DURATION;
        _placements[id] = Placement(
            id, listingId, item.revision, msg.sender, recipient, block.timestamp, endsAt, 0, 0, Status.Open, AD_LABEL
        );
        latestPlacement[listingId] = id;
        emit PlacementPurchased(
            id, listingId, msg.sender, item.revision, recipient, block.timestamp, endsAt, PRICE, AD_LABEL
        );
    }

    /// @notice Payer or current listing owner cancels before expiry. Earned = floor(price * elapsed / duration).
    /// Refunds always credit the original payer, including when a new owner removes the seller's ad.
    function cancel(uint256 id) external nonReentrant returns (uint256 refund) {
        Placement storage placement = _openPlacement(id);
        if (msg.sender != placement.payer && msg.sender != registry.getListing(placement.listingId).owner) {
            revert NotPayer();
        }
        if (block.timestamp >= placement.endsAt) revert PlacementExpired();
        uint256 earned = PRICE * (block.timestamp - placement.startsAt) / DURATION;
        refund = PRICE - earned;
        placement.status = Status.Cancelled;
        placement.closedAt = block.timestamp;
        placement.refund = refund;
        totalEscrowed -= PRICE;
        available[placement.payer] += refund;
        totalAvailable += refund;
        proceeds[placement.recipient] += earned;
        totalProceeds += earned;
        emit PlacementCancelled(id, refund, earned);
    }

    /// @notice Anyone can finalize an expired placement. No external transfer or keeper is needed for expiry.
    function settle(uint256 id) external nonReentrant {
        Placement storage placement = _openPlacement(id);
        if (block.timestamp < placement.endsAt) revert PlacementNotExpired();
        placement.status = Status.Settled;
        placement.closedAt = block.timestamp;
        totalEscrowed -= PRICE;
        proceeds[placement.recipient] += PRICE;
        totalProceeds += PRICE;
        emit PlacementSettled(id, placement.recipient, PRICE);
    }

    /// @notice Only a recipient can withdraw their own already earned proceeds; no admin sweep exists.
    function withdrawProceeds(uint256 amount, address to) external nonReentrant {
        address token = _token();
        _validateWithdrawal(amount, to);
        if (amount > proceeds[msg.sender]) revert InsufficientBalance();
        proceeds[msg.sender] -= amount;
        totalProceeds -= amount;
        ExactStoreToken.push(token, to, amount);
        emit ProceedsWithdrawn(msg.sender, to, amount);
    }

    function getPlacement(uint256 id) external view returns (Placement memory) {
        if (_placements[id].status == Status.None) revert UnknownPlacement();
        return _placements[id];
    }

    function isActive(uint256 id) public view returns (bool) {
        Placement storage placement = _placements[id];
        return placement.status == Status.Open && block.timestamp < placement.endsAt;
    }

    /// @notice Stable ascending purchase-ID order. Bounded scanning, no bidding or manual ranking.
    /// Every returned entry carries #ad and a historical listing revision to render.
    function featured(uint256 cursor, uint256 scanLimit)
        external
        view
        returns (Placement[] memory ads, uint256 nextCursor)
    {
        if (cursor == 0 || cursor > placementCount + 1 || scanLimit == 0 || scanLimit > MAX_SCAN) {
            revert InvalidPage();
        }
        uint256 remaining = placementCount + 1 - cursor;
        nextCursor = cursor + (scanLimit < remaining ? scanLimit : remaining);
        ads = new Placement[](nextCursor - cursor);
        uint256 count;
        for (uint256 id = cursor; id < nextCursor; ++id) {
            if (isActive(id)) ads[count++] = _placements[id];
        }
        assembly ("memory-safe") {
            mstore(ads, count)
        }
    }

    function accountedBalance() external view returns (uint256) {
        return totalAvailable + totalEscrowed + totalProceeds;
    }

    function _openPlacement(uint256 id) internal view returns (Placement storage placement) {
        placement = _placements[id];
        if (placement.status == Status.None) revert UnknownPlacement();
        if (placement.status != Status.Open) revert PlacementClosed();
    }

    function _token() internal view returns (address) {
        if (imd == address(0)) revert TokenNotConfigured();
        return imd;
    }

    function _validateWithdrawal(uint256 amount, address to) internal view {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0) || to == address(this)) revert InvalidAddress();
    }
}

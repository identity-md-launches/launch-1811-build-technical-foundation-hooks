// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Free, permissionless Hooks Store listings
/// @notice A listing is its owner's claim, not proof of hook control, deployment or audit.
/// There is no registry administrator. Each metadata revision remains readable forever.
contract HookListingRegistry {
    error UnknownListing(uint256 listingId);
    error UnknownRevision();
    error NotListingOwner();
    error NotProposedOwner();
    error InvalidIdentity();
    error DuplicateListing(uint256 existingId);
    error InvalidMetadata();
    error InvalidLabels();
    error InvalidPage();

    uint256 public constant MAX_LABELS = 16;
    uint256 public constant MAX_LABEL_BYTES = 32;
    uint256 public constant MAX_REFERENCE_BYTES = 512;
    uint256 public constant MAX_DISCLOSURE_BYTES = 1024;
    uint256 public constant MAX_SCAN = 100;

    struct Metadata {
        string name;
        string sourceRef;
        string testRef;
        string reviewRef;
        string auditRef;
        uint160 callbackMask;
        string callbackDisclosure;
        string feeDisclosure;
        string adminDisclosure;
        string[] labels;
    }

    struct Listing {
        uint256 chainId;
        address hook;
        address owner;
        address proposedOwner;
        uint256 revision;
        bool active;
    }

    event ListingCreated(uint256 indexed listingId, uint256 indexed chainId, address indexed hook, address owner);
    event MetadataUpdated(uint256 indexed listingId, uint256 indexed revision, bytes32 metadataHash);
    event LabelSet(uint256 indexed listingId, bytes32 indexed labelHash, string label, bool present);
    event ListingVisibilitySet(uint256 indexed listingId, bool active);
    event ListingTransferProposed(uint256 indexed listingId, address indexed proposedOwner);
    event ListingTransferred(uint256 indexed listingId, address indexed previousOwner, address indexed newOwner);

    uint256 public listingCount;
    mapping(uint256 => Listing) private _listings;
    mapping(uint256 => mapping(uint256 => Metadata)) private _revisions;
    mapping(uint256 => mapping(bytes32 => bool)) public hasLabel;
    // One entry per (chain, hook, listing owner), not a globally squattable claim to the hook.
    mapping(bytes32 => uint256) public listingFor;

    function createListing(uint256 chainId, address hook, Metadata calldata data) external returns (uint256 id) {
        if (chainId == 0 || hook == address(0)) revert InvalidIdentity();
        bytes32 key = identityKey(chainId, hook, msg.sender);
        if (listingFor[key] != 0) revert DuplicateListing(listingFor[key]);
        _validate(data);
        id = ++listingCount;
        _listings[id] = Listing(chainId, hook, msg.sender, address(0), 0, true);
        listingFor[key] = id;
        emit ListingCreated(id, chainId, hook, msg.sender);
        _writeRevision(id, data);
    }

    function updateListing(uint256 id, Metadata calldata data) external {
        _requireOwner(id);
        _validate(data);
        _writeRevision(id, data);
    }

    /// @notice Affects organic search and future ad purchases, not already purchased ad snapshots.
    function setListingActive(uint256 id, bool active) external {
        _requireOwner(id).active = active;
        emit ListingVisibilitySet(id, active);
    }

    function proposeListingOwner(uint256 id, address proposedOwner) external {
        Listing storage item = _requireOwner(id);
        if (proposedOwner == address(0) || proposedOwner == address(this)) revert InvalidIdentity();
        item.proposedOwner = proposedOwner;
        emit ListingTransferProposed(id, proposedOwner);
    }

    function cancelListingTransfer(uint256 id) external {
        delete _requireOwner(id).proposedOwner;
        emit ListingTransferProposed(id, address(0));
    }

    function acceptListingOwnership(uint256 id) external {
        Listing storage item = _requireListing(id);
        if (msg.sender != item.proposedOwner) revert NotProposedOwner();
        bytes32 key = identityKey(item.chainId, item.hook, msg.sender);
        uint256 existing = listingFor[key];
        if (existing != 0 && existing != id) revert DuplicateListing(existing);
        address previousOwner = item.owner;
        delete listingFor[identityKey(item.chainId, item.hook, previousOwner)];
        listingFor[key] = id;
        item.owner = msg.sender;
        delete item.proposedOwner;
        emit ListingTransferred(id, previousOwner, msg.sender);
    }

    function getListing(uint256 id) external view returns (Listing memory) {
        return _requireListing(id);
    }

    function getMetadata(uint256 id, uint256 revision) external view returns (Metadata memory) {
        Listing storage item = _requireListing(id);
        if (revision == 0 || revision > item.revision) revert UnknownRevision();
        return _revisions[id][revision];
    }

    /// @notice No audit-verification authority is configured or implied in this release.
    /// URLs, labels, paid ads and an Intake job's review outcome cannot set this flag.
    function isAudited(uint256 id) external view returns (bool) {
        _requireListing(id);
        return false;
    }

    function identityKey(uint256 chainId, address hook, address listingOwner) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, hook, listingOwner));
    }

    /// @notice Exact-match search key. Labels use lowercase ASCII letters, digits and hyphens.
    function labelKey(string calldata label) external pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    /// @notice Scan up to `scanLimit` consecutive IDs, ascending. Start with cursor 1.
    /// Zero filters mean any chain/owner/label; only active listings are returned.
    /// A short/empty page can have more results later. Continue until nextCursor > listingCount.
    function search(uint256 cursor, uint256 scanLimit, uint256 chainId, address listingOwner, bytes32 labelHash)
        external
        view
        returns (uint256[] memory ids, uint256 nextCursor)
    {
        if (cursor == 0 || cursor > listingCount + 1 || scanLimit == 0 || scanLimit > MAX_SCAN) revert InvalidPage();
        uint256 remaining = listingCount + 1 - cursor;
        nextCursor = cursor + (scanLimit < remaining ? scanLimit : remaining);
        ids = new uint256[](nextCursor - cursor);
        uint256 count;
        for (uint256 id = cursor; id < nextCursor; ++id) {
            Listing storage item = _listings[id];
            if (
                item.active && (chainId == 0 || chainId == item.chainId)
                    && (listingOwner == address(0) || listingOwner == item.owner)
                    && (labelHash == bytes32(0) || hasLabel[id][labelHash])
            ) ids[count++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    function _requireListing(uint256 id) internal view returns (Listing storage item) {
        item = _listings[id];
        if (item.owner == address(0)) revert UnknownListing(id);
    }

    function _requireOwner(uint256 id) internal view returns (Listing storage item) {
        item = _requireListing(id);
        if (msg.sender != item.owner) revert NotListingOwner();
    }

    function _writeRevision(uint256 id, Metadata calldata data) internal {
        Listing storage item = _listings[id];
        string[] storage previous = _revisions[id][item.revision].labels;
        for (uint256 i; i < previous.length; ++i) {
            bytes32 labelHash = keccak256(bytes(previous[i]));
            delete hasLabel[id][labelHash];
            emit LabelSet(id, labelHash, previous[i], false);
        }
        uint256 revision = ++item.revision;
        _revisions[id][revision] = data;
        for (uint256 i; i < data.labels.length; ++i) {
            bytes32 labelHash = keccak256(bytes(data.labels[i]));
            hasLabel[id][labelHash] = true;
            emit LabelSet(id, labelHash, data.labels[i], true);
        }
        emit MetadataUpdated(id, revision, keccak256(abi.encode(data)));
    }

    function _validate(Metadata calldata data) internal pure {
        if (
            bytes(data.name).length == 0 || bytes(data.name).length > 96
                || bytes(data.sourceRef).length > MAX_REFERENCE_BYTES
                || bytes(data.testRef).length > MAX_REFERENCE_BYTES
                || bytes(data.reviewRef).length > MAX_REFERENCE_BYTES
                || bytes(data.auditRef).length > MAX_REFERENCE_BYTES || data.callbackMask > 0x3fff
                || !_disclosureValid(data.callbackDisclosure) || !_disclosureValid(data.feeDisclosure)
                || !_disclosureValid(data.adminDisclosure)
        ) revert InvalidMetadata();
        if (data.labels.length > MAX_LABELS) revert InvalidLabels();
        for (uint256 i; i < data.labels.length; ++i) {
            bytes calldata label = bytes(data.labels[i]);
            if (label.length == 0 || label.length > MAX_LABEL_BYTES) revert InvalidLabels();
            for (uint256 j; j < label.length; ++j) {
                bytes1 c = label[j];
                if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-")) revert InvalidLabels();
            }
            for (uint256 j; j < i; ++j) {
                if (keccak256(label) == keccak256(bytes(data.labels[j]))) revert InvalidLabels();
            }
        }
    }

    function _disclosureValid(string calldata disclosure) internal pure returns (bool) {
        return bytes(disclosure).length != 0 && bytes(disclosure).length <= MAX_DISCLOSURE_BYTES;
    }
}

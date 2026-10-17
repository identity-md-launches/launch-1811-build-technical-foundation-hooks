// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreAdmin} from "../store/StoreAdmin.sol";
import {ExactStoreToken} from "../store/ExactStoreToken.sol";
import {IIntake} from "./IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";

/// @title Hooks Store's no-backend bridge to IdentityMD jobs
/// @notice A creator's wallet approves IMD to this contract and calls `openJob`. The contract asks
/// the Intake (version 2) for a `job.open` that writes standalone-hook code for a HookSpec, with
/// explicit build, test and adversarial-review steps fixed by the owner's template, tracks the
/// Intake's request id, and accepts exactly one completion or failure for it, from the Intake only.
///
/// A completion is NOT a review verdict. The review status shown to anyone comes only from a
/// separate `oracle.request` (`requestReview`), whose answer the IdentityMD oracle signs as
/// EIP-712 typed data in this contract's domain and this contract verifies. Without that signed
/// answer, review status stays `None`, `Pending` or `Unanswered`; nothing here can mark "audited".
///
/// A static website reads `getJob(requestId)`, `jobIds` and the events through any JSON-RPC node of
/// the chain (`eth_call`, `eth_getLogs`); it needs no backend and no browser access to api.imd.fun.
contract HookJobRequester is OracleAttestationConsumer, StoreAdmin {
    enum JobStatus {
        None,
        Open,
        Delivered,
        Failed,
        Expired
    }

    enum ReviewStatus {
        None,
        Pending,
        Passed,
        NotPassed,
        Unanswered
    }

    struct Job {
        address requester;
        uint64 openedAt;
        uint64 deadline;
        JobStatus status;
        ReviewStatus review;
        uint8 failureStatus;
        uint16 reviewPanelSize;
        uint16 reviewAgreed;
        uint64 reviewDeadline;
        bytes32 specHash;
        bytes32 bodyHash;
        bytes32 resultHash;
        bytes32 failureReason;
        bytes32 reviewRequestId;
        bytes32 reviewPanelJobId;
    }

    /// @notice Immutable ask context and an owner-verified binding, explicitly resettable while pending.
    /// Intake IDs, oracle UUIDs and canonical question hashes are separate namespaces.
    struct ReviewAsk {
        bytes32 bodyHash;
        bytes32 oracleRequestId;
        bytes32 questionHash;
        uint256 questionChainId;
        uint64 askedAt;
        uint64 deadline;
        uint64 fromBlock;
        uint64 toBlock;
        uint16 minPanelSize;
        uint16 minAgreed;
    }

    /// @notice A signature-verified answer received before binding, NOT a review verdict.
    /// Freshness and signer authority are checked at receipt. The immutable fields below are
    /// sufficient to check the owner's subsequent binding and finalize without another callback.
    /// The read ABI is independent of the gas-optimized storage representation below.
    struct ReviewReceipt {
        bytes32 oracleRequestId;
        bytes32 questionHash;
        uint256 questionChainId;
        bytes32 panelJobId;
        uint64 fromBlock;
        uint64 toBlock;
        uint64 receivedAt;
        uint16 panelSize;
        uint16 agreed;
        bool passed;
    }

    /// @dev Four full-width context words and one packed word. The top bit of details is
    /// allocated at payment, moving one cold zero-to-nonzero SSTORE out of the one-shot callback.
    /// Bits 0..63: fromBlock, 64..127: toBlock, 128..191: receivedAt,
    /// 192..207: panelSize, 208..223: agreed, 224: passed, 225..254: signer epoch,
    /// 255: allocation marker. Epochs identify verification authority, not ask creation time.
    /// The marker is not an answer; only a nonzero oracleRequestId denotes a receipt.
    struct StoredReviewReceipt {
        bytes32 oracleRequestId;
        bytes32 questionHash;
        uint256 questionChainId;
        bytes32 panelJobId;
        uint256 details;
    }

    uint256 private constant RECEIPT_ALLOCATED = uint256(1) << 255;
    uint32 private constant MAX_SIGNER_EPOCH = (uint32(1) << 30) - 1;

    /// @dev Markers the job template must contain, so every job names the three steps.
    bytes internal constant STEP_BUILD = "forge build";
    bytes internal constant STEP_TEST = "forge test";
    bytes internal constant STEP_REVIEW = "adversarial review";
    uint256 public constant MAX_BRIEF_BYTES = 2000;
    uint256 public constant MAX_TEMPLATE_BYTES = 4096;
    uint256 public constant MAX_BODY_BYTES = 16384;
    uint64 public constant MIN_TIMEOUT = 1 hours;
    uint64 public constant MAX_TIMEOUT = 30 days;

    IIntake public intake;
    /// @notice The asset paid in: the chain's IMD.
    address public asset;
    /// @notice The most IMD one ask may cost. The Intake's current `priceOf` is pulled, never more
    /// than this, so a wallet's standing allowance cannot be drained by a price move.
    uint256 public maxPrice;
    /// @notice Whether asks name the failure function (`requestWithFailure`, Intake version 2
    /// only). Off, asks use `request` and a refused job can only be expired after its deadline.
    bool public failureHook = true;
    bytes32 public jobAction;
    bytes public jobBodyPrefix;
    bytes public jobBodyMiddle;
    bytes public jobBodySuffix;
    bytes32 public reviewAction;
    bytes public reviewBodyPrefix;
    bytes public reviewBodySuffix;
    uint16 public minPanelSize;
    uint16 public minAgreed;
    uint64 public jobTimeout = 7 days;
    uint64 public reviewTimeout = 1 days;
    /// @notice Each signer setting starts a new verification epoch. Ordinary rotation does not
    /// revoke old receipts; explicit incident revocation does, even before individual closure.
    uint32 public oracleSignerEpoch = 1;
    mapping(uint32 epoch => bytes32 incidentHash) public revokedSignerEpochs;
    mapping(bytes32 intakeRequestId => bool) public revokedReviewReceipts;

    mapping(bytes32 requestId => Job) internal jobs;
    /// @notice Intake request id of a pending review ask => the job's Intake request id.
    mapping(bytes32 intakeRequestId => bytes32 jobRequestId) public reviewOf;
    mapping(bytes32 intakeRequestId => ReviewAsk) private _reviewAsks;
    mapping(bytes32 intakeRequestId => StoredReviewReceipt) private _reviewReceipts;
    /// @notice Historical receipt was closed for owner-reported misdelivery or an onchain UUID conflict.
    mapping(bytes32 intakeRequestId => bool) public discardedReviewReceipts;
    /// @notice Requester asked for expiry; delivery and binding remain open until owner confirmation.
    /// Historical flags are never cleared and cannot authorize expiry of a later ask.
    mapping(bytes32 intakeRequestId => bool) public reviewExpiryRequested;
    /// @notice Never cleared, including on failure/expiry: an Intake ID cannot be recycled.
    mapping(bytes32 intakeRequestId => bool) public usedIntakeRequestIds;
    /// @notice Bound UUIDs stay reserved unless the owner releases an unused, terminal reservation.
    /// Consumed UUIDs can never be released or reused.
    mapping(bytes32 oracleRequestId => bytes32 intakeRequestId) public intakeReviewOfOracle;
    bytes32[] public jobIds;
    mapping(address requester => bytes32[]) internal _jobsOf;
    bool private _locked;

    error ZeroAddress();
    error NotConfigured(bytes32 what);
    error NotTheIntake();
    error NotRequester();
    error UnknownOrSettled(bytes32 requestId);
    error DuplicateRequestId(bytes32 requestId);
    error InvalidBrief(uint256 index);
    error BriefLength(uint256 length);
    error TemplateTooLong(uint256 length);
    error TemplateMissingStep(bytes step);
    error BodyTooLong(uint256 length);
    error ActionNotPriced(bytes32 action);
    error PriceAboveCeiling(uint256 price, uint256 maxPrice);
    error PriceAboveUserMaximum(uint256 price, uint256 userMaxPrice);
    error InexactIntakeSpend();
    error InvalidTimeout(uint64 timeout);
    error InvalidPanelMinimums(uint16 panelSize, uint16 agreed);
    error PanelTooWeak(uint16 panelSize, uint16 quorum, uint16 agreed);
    error NotReviewable(bytes32 jobRequestId);
    error DeadlineNotReached(uint64 deadline);
    error ReviewAlreadyReceived(bytes32 requestId);
    error ReviewNotReceived(bytes32 requestId);
    error ReviewReceiptMatches(bytes32 requestId);
    error ReviewReceiptMismatch(bytes32 expected, bytes32 supplied);
    error ReviewExpiryAlreadyRequested(bytes32 requestId);
    error ReservationNotReleasable(bytes32 oracleRequestId);
    error ReviewAlreadyBound(bytes32 requestId);
    error ReviewNotBound(bytes32 requestId);
    error InvalidSignerEpoch(uint32 epoch);
    error SignerEpochRevoked(uint32 epoch);
    error SignerEpochNotRevoked(uint32 epoch);
    error InvalidIncidentHash();
    error InvalidReviewBinding();
    error ReviewBodyMismatch(bytes32 expected, bytes32 supplied);
    error ReviewAttestationMismatch(bytes32 requestId);
    error AttestationPredatesAsk(uint64 issuedAt, uint64 askedAt);
    error TokenCallFailed();
    error Reentrancy();

    event IntakeSet(address indexed intake);
    event PaymentSet(address indexed asset, uint256 maxPrice);
    event FailureHookSet(bool on);
    event JobTemplateSet(bytes32 indexed action, bytes32 templateHash);
    event ReviewTemplateSet(bytes32 indexed action, bytes32 templateHash, uint16 minPanelSize, uint16 minAgreed);
    event TimeoutsSet(uint64 jobTimeout, uint64 reviewTimeout);
    event JobOpened(
        bytes32 indexed requestId, address indexed requester, bytes32 indexed specHash, uint256 price, bytes body
    );
    event JobDelivered(bytes32 indexed requestId, bytes32 resultHash);
    event JobResultURI(bytes32 indexed requestId, string uri);
    event JobFailed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event JobExpired(bytes32 indexed requestId);
    event ReviewRequested(bytes32 indexed jobRequestId, bytes32 indexed intakeRequestId, uint256 price, bytes body);
    event ReviewBound(
        bytes32 indexed jobRequestId,
        bytes32 indexed intakeRequestId,
        bytes32 indexed oracleRequestId,
        bytes32 bodyHash,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock
    );
    event ReviewReceived(
        bytes32 indexed jobRequestId,
        bytes32 indexed intakeRequestId,
        bytes32 indexed oracleRequestId,
        bytes32 attestationDigest
    );
    event ReviewAnswered(
        bytes32 indexed jobRequestId,
        bytes32 indexed intakeRequestId,
        bool passed,
        bytes32 questionHash,
        bytes32 panelJobId,
        uint16 panelSize,
        uint16 agreed
    );
    event ReviewUnanswered(bytes32 indexed jobRequestId, bytes32 indexed intakeRequestId, uint8 status, bytes32 reason);
    event ReviewExpiryRequested(bytes32 indexed jobRequestId, bytes32 indexed intakeRequestId);
    event ReviewReceiptDiscarded(
        bytes32 indexed jobRequestId,
        bytes32 indexed intakeRequestId,
        bytes32 indexed receivedOracleRequestId,
        bytes32 authenticatedOracleRequestId,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock
    );
    event ReviewReservationReleased(bytes32 indexed oracleRequestId, bytes32 indexed intakeRequestId);
    event ReviewBindingReset(
        bytes32 indexed jobRequestId, bytes32 indexed intakeRequestId, bytes32 indexed previousOracleRequestId
    );
    event OracleSignerEpochStarted(uint32 indexed epoch, address indexed signer);
    event OracleSignerEpochRevoked(uint32 indexed epoch, bytes32 indexed incidentHash);
    event ReviewReceiptRevoked(
        bytes32 indexed jobRequestId, bytes32 indexed intakeRequestId, uint32 indexed epoch, bytes32 incidentHash
    );

    /// @param owner_ The launch's owner; never the deploying factory.
    /// @param intake_ The chain's Intake version 2.
    /// @param asset_ The chain's IMD token.
    /// @param oracleSigner_ The IdentityMD oracle signer (a key or an ERC-1271 registry).
    /// @param maxPrice_ The most `asset_` one ask may cost (0.5 IMD = 5e17 at the published price).
    constructor(address owner_, address intake_, address asset_, address oracleSigner_, uint256 maxPrice_)
        OracleAttestationConsumer(oracleSigner_)
        StoreAdmin(owner_)
    {
        if (owner_ == address(0) || intake_ == address(0) || asset_ == address(0)) revert ZeroAddress();
        if (maxPrice_ == 0) revert PriceAboveCeiling(0, 0);
        intake = IIntake(intake_);
        asset = asset_;
        maxPrice = maxPrice_;
        emit IntakeSet(intake_);
        emit PaymentSet(asset_, maxPrice_);
        emit FailureHookSet(true);
        emit OracleSignerEpochStarted(1, oracleSigner_);
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyIntake() {
        if (msg.sender != address(intake)) revert NotTheIntake();
        _;
    }

    // ---------------------------------------------------------------- job.open

    /// @notice Opens one paid `job.open` for standalone-hook code. The caller's wallet must have
    /// approved this contract for at least `intake.priceOf(jobAction, asset)` IMD; exactly that is
    /// pulled and forwarded. The price is spent once asked: there is no refund.
    /// @param specHash `HookSpecLib.hash` of the HookSpec the code is for.
    /// @param brief The creator's request text: 1-2000 bytes of UTF-8, no `"` `\` `<` `>` or control
    /// characters, inserted between the template's quoting delimiters as untrusted text.
    /// @param userMaxPrice The caller's maximum payment in the configured asset's base units.
    function openJob(bytes32 specHash, bytes calldata brief, uint256 userMaxPrice)
        external
        nonReentrant
        returns (bytes32 requestId)
    {
        if (jobAction == bytes32(0)) revert NotConfigured("jobTemplate");
        _validateBrief(brief);
        bytes memory body = bytes.concat(jobBodyPrefix, _hex(specHash), jobBodyMiddle, brief, jobBodySuffix);
        if (body.length > MAX_BODY_BYTES) revert BodyTooLong(body.length);
        uint256 price = _pull(jobAction, userMaxPrice);
        requestId = _ask(jobAction, body, this.onJobResult.selector, this.onJobFailure.selector, price);
        _recordIntakeId(requestId);
        Job storage job = jobs[requestId];
        job.requester = msg.sender;
        job.openedAt = uint64(block.timestamp);
        job.deadline = uint64(block.timestamp) + jobTimeout;
        job.status = JobStatus.Open;
        job.specHash = specHash;
        job.bodyHash = keccak256(body);
        jobIds.push(requestId);
        _jobsOf[msg.sender].push(requestId);
        emit JobOpened(requestId, msg.sender, specHash, price, body);
    }

    /// @notice First completion notice for an open or locally expired job, from Intake only.
    /// Local expiry never suppresses a late result/failure or changes any review verdict.
    /// Unsigned: it says the Intake reported the job complete, never that its review passed.
    /// @dev Protocol tuple: the supplied hash commits to the exact control-plane completion
    /// snapshot (/jobs/:id/result at completion), not arbitrary worker JSON or the URI.
    /// The URI is emitted for offchain readers; no string is stored or fetched by this contract.
    function onJobResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external onlyIntake {
        Job storage job = jobs[requestId];
        if (job.status != JobStatus.Open && job.status != JobStatus.Expired) revert UnknownOrSettled(requestId);
        job.status = JobStatus.Delivered;
        job.resultHash = resultHash;
        emit JobDelivered(requestId, resultHash);
        emit JobResultURI(requestId, uri);
    }

    /// @notice Version 2 failure function: the ask was refused (status 1) or ended without a result
    /// (status 2). Unsigned values; recorded, never acted on beyond closing the job.
    function onJobFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16 agreed,
        uint16 answered,
        bytes calldata
    ) external onlyIntake {
        Job storage job = jobs[requestId];
        if (job.status != JobStatus.Open && job.status != JobStatus.Expired) revert UnknownOrSettled(requestId);
        job.status = JobStatus.Failed;
        job.failureStatus = status;
        job.failureReason = reason;
        emit JobFailed(requestId, status, reason, agreed, answered);
    }

    /// @notice Marks a local timeout. The first authenticated result/failure remains deliverable.
    function expireJob(bytes32 requestId) external {
        Job storage job = jobs[requestId];
        if (job.status != JobStatus.Open) revert UnknownOrSettled(requestId);
        if (msg.sender != job.requester) revert NotRequester();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= job.deadline) revert DeadlineNotReached(job.deadline);
        job.status = JobStatus.Expired;
        emit JobExpired(requestId);
    }

    // ---------------------------------------------------------------- review verdict (oracle.request)

    /// @notice Asks the IdentityMD oracle whether the job's adversarial-review step passed. The
    /// requester pays `intake.priceOf(reviewAction, asset)` up to userMaxPrice. Allowed after
    /// delivery, failure or local expiry, and again after an unanswered ask. Unsigned job status
    /// cannot determine a signed verdict or make review eligibility depend on expiry ordering.
    /// The owner must bind the returned Intake ID to the independently verified oracle context.
    /// A valid answer arriving first is retained without setting a verdict or consuming its UUID.
    function requestReview(bytes32 jobRequestId, uint256 userMaxPrice)
        external
        nonReentrant
        returns (bytes32 intakeRequestId)
    {
        if (reviewAction == bytes32(0)) revert NotConfigured("reviewTemplate");
        Job storage job = jobs[jobRequestId];
        if (msg.sender != job.requester) revert NotRequester();
        if (
            (job.status != JobStatus.Delivered && job.status != JobStatus.Failed && job.status != JobStatus.Expired)
                || (job.review != ReviewStatus.None && job.review != ReviewStatus.Unanswered)
        ) revert NotReviewable(jobRequestId);
        bytes memory body = bytes.concat(reviewBodyPrefix, _hex(jobRequestId), reviewBodySuffix);
        uint256 price = _pull(reviewAction, userMaxPrice);
        intakeRequestId = _ask(reviewAction, body, this.onReviewResult.selector, this.onReviewFailure.selector, price);
        _recordIntakeId(intakeRequestId);
        reviewOf[intakeRequestId] = jobRequestId;
        job.review = ReviewStatus.Pending;
        job.reviewRequestId = intakeRequestId;
        job.reviewDeadline = uint64(block.timestamp) + reviewTimeout;
        ReviewAsk storage ask = _reviewAsks[intakeRequestId];
        ask.bodyHash = keccak256(body);
        ask.askedAt = uint64(block.timestamp);
        ask.deadline = job.reviewDeadline;
        ask.minPanelSize = minPanelSize;
        ask.minAgreed = minAgreed;
        _reviewReceipts[intakeRequestId].details = RECEIPT_ALLOCATED;
        emit ReviewRequested(jobRequestId, intakeRequestId, price, body);
    }

    /// @notice Pins the exact oracle identity/question for an unbound pending ask. If an answer was
    /// already received, the binding must match it exactly and finalizes it in this transaction.
    /// @dev The owner must independently verify the protocol's Intake-to-oracle mapping and compute
    /// the canonical question hash from this ask's body and resolved window. Neither ID equality nor
    /// keccak256(body) == questionHash is assumed. A relay/caller cannot choose these expectations.
    /// An unbound receipt is never itself authority for this mapping. No deadline cutoff: the
    /// requester may request expiry after its deadline, but closure needs owner confirmation.
    /// Positive receipts older than 23h settle as historical answers plus Unanswered, so a fresh
    /// review can restore a usable deployment window. Negative receipts remain terminal.
    /// The contract checks consistency with owner-supplied context, not its offchain authenticity.
    function bindReview(
        bytes32 intakeRequestId,
        bytes32 expectedBodyHash,
        bytes32 oracleRequestId,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock
    ) external onlyOwner {
        bytes32 jobRequestId = reviewOf[intakeRequestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(intakeRequestId);
        ReviewAsk storage ask = _reviewAsks[intakeRequestId];
        if (ask.oracleRequestId != bytes32(0)) revert ReviewAlreadyBound(intakeRequestId);
        _validateReviewBinding(
            ask, expectedBodyHash, oracleRequestId, questionHash, questionChainId, fromBlock, toBlock
        );
        if (intakeReviewOfOracle[oracleRequestId] != bytes32(0) || consumed[oracleRequestId]) {
            revert DuplicateRequestId(oracleRequestId);
        }
        ReviewReceipt memory receipt = getReviewReceipt(intakeRequestId);
        if (receipt.oracleRequestId != bytes32(0)) {
            uint32 epoch = reviewReceiptSignerEpoch(intakeRequestId);
            if (revokedSignerEpochs[epoch] != bytes32(0)) revert SignerEpochRevoked(epoch);
        }
        if (
            receipt.oracleRequestId != bytes32(0)
                && !_receiptMatches(receipt, oracleRequestId, questionHash, questionChainId, fromBlock, toBlock)
        ) revert ReviewAttestationMismatch(intakeRequestId);
        ask.oracleRequestId = oracleRequestId;
        ask.questionHash = questionHash;
        ask.questionChainId = questionChainId;
        ask.fromBlock = fromBlock;
        ask.toBlock = toBlock;
        intakeReviewOfOracle[oracleRequestId] = intakeRequestId;
        emit ReviewBound(
            jobRequestId,
            intakeRequestId,
            oracleRequestId,
            expectedBodyHash,
            questionHash,
            questionChainId,
            fromBlock,
            toBlock
        );
        if (receipt.oracleRequestId != bytes32(0)) {
            _consume(oracleRequestId);
            _answerReview(
                jobRequestId,
                intakeRequestId,
                receipt.passed,
                questionHash,
                receipt.panelJobId,
                receipt.panelSize,
                receipt.agreed
            );
        }
    }

    /// @notice Removes a pending pre-binding without deleting its receipt or settling the ask.
    /// @dev Authenticate the correction independently, then bind again. Historical ReviewBound
    /// and ReviewBindingReset events preserve the old context. Finalized verdicts cannot reset.
    function resetReviewBinding(bytes32 intakeRequestId, bytes32 expectedBodyHash) external onlyOwner {
        bytes32 jobRequestId = reviewOf[intakeRequestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(intakeRequestId);
        ReviewAsk storage ask = _reviewAsks[intakeRequestId];
        if (expectedBodyHash != ask.bodyHash) revert ReviewBodyMismatch(ask.bodyHash, expectedBodyHash);
        bytes32 previous = ask.oracleRequestId;
        if (previous == bytes32(0)) revert ReviewNotBound(intakeRequestId);
        if (consumed[previous] || intakeReviewOfOracle[previous] != intakeRequestId) {
            revert ReservationNotReleasable(previous);
        }
        delete intakeReviewOfOracle[previous];
        delete ask.oracleRequestId;
        delete ask.questionHash;
        delete ask.questionChainId;
        delete ask.fromBlock;
        delete ask.toBlock;
        emit ReviewBindingReset(jobRequestId, intakeRequestId, previous);
        emit ReviewReservationReleased(previous, intakeRequestId);
    }

    /// @notice Incident response: revoke verification from an old signer epoch permanently.
    /// @dev First rotate to a safe signer (or repair an ERC-1271 registry and start a new epoch).
    /// All retained receipts from this epoch immediately become unconfirmable. Finalized verdicts
    /// and consumed UUIDs stay historical; GatedHookDeployer rejects their use after revocation
    /// in either callback order. incidentHash commits to the operator's evidence.
    function revokeSignerEpoch(uint32 epoch, bytes32 incidentHash) external onlyOwner {
        if (epoch == 0 || epoch >= oracleSignerEpoch) revert InvalidSignerEpoch(epoch);
        if (incidentHash == bytes32(0)) revert InvalidIncidentHash();
        if (revokedSignerEpochs[epoch] != bytes32(0)) revert SignerEpochRevoked(epoch);
        revokedSignerEpochs[epoch] = incidentHash;
        emit OracleSignerEpochRevoked(epoch, incidentHash);
    }

    /// @notice Closes a pending receipt from an explicitly revoked epoch without erasing it.
    /// No verdict, UUID consumption change, payment or automatic reservation release occurs.
    function closeRevokedReviewReceipt(bytes32 intakeRequestId) external onlyOwner {
        bytes32 jobRequestId = reviewOf[intakeRequestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(intakeRequestId);
        if (_reviewReceipts[intakeRequestId].oracleRequestId == bytes32(0)) {
            revert ReviewNotReceived(intakeRequestId);
        }
        _closeRevokedReview(jobRequestId, intakeRequestId);
    }

    /// @notice Incident-only recovery of a finalized verdict, in either callback order.
    /// History, consumed UUIDs and deployment replay guards are never cleared.
    function closeRevokedVerdict(bytes32 jobRequestId) external onlyOwner {
        Job storage job = jobs[jobRequestId];
        if (job.review != ReviewStatus.Passed && job.review != ReviewStatus.NotPassed) {
            revert NotReviewable(jobRequestId);
        }
        _closeRevokedReview(jobRequestId, job.reviewRequestId);
    }

    function _closeRevokedReview(bytes32 jobRequestId, bytes32 intakeRequestId) private {
        uint32 epoch = reviewReceiptSignerEpoch(intakeRequestId);
        bytes32 incidentHash = revokedSignerEpochs[epoch];
        if (incidentHash == bytes32(0)) revert SignerEpochNotRevoked(epoch);
        revokedReviewReceipts[intakeRequestId] = true;
        delete reviewOf[intakeRequestId];
        jobs[jobRequestId].review = ReviewStatus.Unanswered;
        emit ReviewReceiptRevoked(jobRequestId, intakeRequestId, epoch, incidentHash);
        emit ReviewUnanswered(jobRequestId, intakeRequestId, 0, "signer epoch revoked");
    }

    /// @notice Closes an unconfirmed misdelivery or conflicting UUID as Unanswered, retaining history.
    /// @dev Supply the ask's true context, independently checked OFFCHAIN by the trusted owner.
    /// Misdelivery requires a different, available UUID. A same-UUID context must match every
    /// field and have an onchain conflict (consumed or reserved by another ask). A field typo,
    /// negative value or elapsed time alone cannot justify discard. No mapping proof is verified.
    /// This does not retry Intake, refund its fee, reserve a UUID, or change any consumed marker.
    function discardReviewReceipt(
        bytes32 intakeRequestId,
        bytes32 expectedBodyHash,
        bytes32 oracleRequestId,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock
    ) external onlyOwner {
        bytes32 jobRequestId = reviewOf[intakeRequestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(intakeRequestId);
        ReviewAsk storage ask = _reviewAsks[intakeRequestId];
        if (ask.oracleRequestId != bytes32(0)) revert ReviewAlreadyBound(intakeRequestId);
        _validateReviewBinding(
            ask, expectedBodyHash, oracleRequestId, questionHash, questionChainId, fromBlock, toBlock
        );
        ReviewReceipt memory receipt = getReviewReceipt(intakeRequestId);
        if (receipt.oracleRequestId == bytes32(0)) revert ReviewNotReceived(intakeRequestId);
        bytes32 reason;
        bytes32 holder = intakeReviewOfOracle[oracleRequestId];
        if (oracleRequestId == receipt.oracleRequestId) {
            if (!_receiptMatches(receipt, oracleRequestId, questionHash, questionChainId, fromBlock, toBlock)) {
                revert ReviewAttestationMismatch(intakeRequestId);
            }
            if (!consumed[oracleRequestId] && (holder == bytes32(0) || holder == intakeRequestId)) {
                revert ReviewReceiptMatches(intakeRequestId);
            }
            reason = "receipt UUID conflict";
        } else {
            if (consumed[oracleRequestId] || holder != bytes32(0)) revert DuplicateRequestId(oracleRequestId);
            reason = "misdelivered receipt";
        }
        _discardReceipt(
            jobRequestId,
            intakeRequestId,
            receipt.oracleRequestId,
            oracleRequestId,
            questionHash,
            questionChainId,
            fromBlock,
            toBlock,
            reason
        );
    }

    /// @notice Closes a receipt whose UUID is this ask's own but whose signed question, chain or
    /// window is not the ask's, as Unanswered, retaining the receipt and its verdict in history.
    /// @dev The signed context is the oracle's; the supplied context is what the owner independently
    /// established for this ask (bindReview's procedure). At least one of question/chain/window must
    /// differ, so a receipt that matches the ask's true context (a genuine Passed or NotPassed) can
    /// only be bound, never set aside here; a same-UUID typo in bindReview still reverts there.
    /// `receiptHash` must equal `reviewReceiptHash(intakeRequestId)`: the owner acknowledges the
    /// exact receipt, including its verdict, that this call sets aside. The UUID is neither reserved
    /// nor consumed: a retry must still be bound and signature-verified normally. Only the owner can
    /// call this; a requester cannot close any receipt. No fee is refunded or retried.
    function discardMismatchedReviewReceipt(
        bytes32 intakeRequestId,
        bytes32 expectedBodyHash,
        bytes32 receiptHash,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock
    ) external onlyOwner {
        bytes32 jobRequestId = reviewOf[intakeRequestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(intakeRequestId);
        ReviewAsk storage ask = _reviewAsks[intakeRequestId];
        if (ask.oracleRequestId != bytes32(0)) revert ReviewAlreadyBound(intakeRequestId);
        ReviewReceipt memory receipt = getReviewReceipt(intakeRequestId);
        bytes32 oracleRequestId = receipt.oracleRequestId;
        if (oracleRequestId == bytes32(0)) revert ReviewNotReceived(intakeRequestId);
        _validateReviewBinding(
            ask, expectedBodyHash, oracleRequestId, questionHash, questionChainId, fromBlock, toBlock
        );
        bytes32 expectedReceiptHash = keccak256(abi.encode(receipt));
        if (receiptHash != expectedReceiptHash) revert ReviewReceiptMismatch(expectedReceiptHash, receiptHash);
        if (_receiptMatches(receipt, oracleRequestId, questionHash, questionChainId, fromBlock, toBlock)) {
            revert ReviewReceiptMatches(intakeRequestId);
        }
        _discardReceipt(
            jobRequestId,
            intakeRequestId,
            oracleRequestId,
            oracleRequestId,
            questionHash,
            questionChainId,
            fromBlock,
            toBlock,
            "receipt context mismatch"
        );
    }

    function _discardReceipt(
        bytes32 jobRequestId,
        bytes32 intakeRequestId,
        bytes32 receivedOracleRequestId,
        bytes32 oracleRequestId,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock,
        bytes32 reason
    ) private {
        discardedReviewReceipts[intakeRequestId] = true;
        delete reviewOf[intakeRequestId];
        jobs[jobRequestId].review = ReviewStatus.Unanswered;
        emit ReviewReceiptDiscarded(
            jobRequestId,
            intakeRequestId,
            receivedOracleRequestId,
            oracleRequestId,
            questionHash,
            questionChainId,
            fromBlock,
            toBlock
        );
        emit ReviewUnanswered(jobRequestId, intakeRequestId, 0, reason);
    }

    /// @notice Releases an unused UUID after closure without a receipt, or explicit receipt revocation.
    /// @dev Does not reopen the old Intake ID or clear consumption. Authenticate the protocol's
    /// retry mapping before release; the retry must still be bound and signature-verified normally.
    function releaseReservation(bytes32 oracleRequestId) external onlyOwner {
        bytes32 holder = intakeReviewOfOracle[oracleRequestId];
        if (
            holder == bytes32(0) || consumed[oracleRequestId] || reviewOf[holder] != bytes32(0)
                || (_reviewReceipts[holder].oracleRequestId != bytes32(0) && !revokedReviewReceipts[holder])
        ) revert ReservationNotReleasable(oracleRequestId);
        delete intakeReviewOfOracle[oracleRequestId];
        emit ReviewReservationReleased(oracleRequestId, holder);
    }

    function _validateReviewBinding(
        ReviewAsk storage ask,
        bytes32 expectedBodyHash,
        bytes32 oracleRequestId,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock
    ) private view {
        if (expectedBodyHash != ask.bodyHash) revert ReviewBodyMismatch(ask.bodyHash, expectedBodyHash);
        if (oracleRequestId == bytes32(0) || questionHash == bytes32(0) || questionChainId == 0 || fromBlock > toBlock)
        {
            revert InvalidReviewBinding();
        }
    }

    function _receiptMatches(
        ReviewReceipt memory receipt,
        bytes32 oracleRequestId,
        bytes32 questionHash,
        uint256 questionChainId,
        uint64 fromBlock,
        uint64 toBlock
    ) private pure returns (bool) {
        return receipt.oracleRequestId == oracleRequestId && receipt.questionHash == questionHash
            && receipt.questionChainId == questionChainId && receipt.fromBlock == fromBlock
            && receipt.toBlock == toBlock;
    }

    /// @notice The `oracle.request` callback: verifies the current Intake/signer, freshness and
    /// snapshotted panel minimums. An exact pre-binding match settles; otherwise retain the
    /// verified answer, including a pre-binding mismatch, for owner correction/confirmation.
    function onReviewResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        onlyIntake
    {
        bytes32 jobRequestId = reviewOf[requestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(requestId);
        ReviewAsk storage ask = _reviewAsks[requestId];
        if (_reviewReceipts[requestId].oracleRequestId != bytes32(0)) revert ReviewAlreadyReceived(requestId);
        bool matches = ask.oracleRequestId != bytes32(0) && a.requestId == ask.oracleRequestId
            && a.questionHash == ask.questionHash && a.chainId == ask.questionChainId && a.fromBlock == ask.fromBlock
            && a.toBlock == ask.toBlock;
        if (a.requestId == bytes32(0) || a.questionHash == bytes32(0) || a.chainId == 0 || a.fromBlock > a.toBlock) {
            revert InvalidReviewBinding();
        }
        // Widen before adding so even hostile uint64 timestamps cannot overflow this check.
        if (uint256(a.issuedAt) + ISSUED_AT_TOLERANCE < ask.askedAt) {
            revert AttestationPredatesAsk(a.issuedAt, ask.askedAt);
        }
        // Panel strength is the signed panel size and actual agreement against the minimums
        // snapshotted at payment. The signed quorum is the oracle's own threshold, which the
        // agreement must also meet; it is not compared with minAgreed, so a body quorum below
        // the configured minimum cannot burn an answer whose agreement reaches that minimum.
        if (a.panelSize < ask.minPanelSize || a.agreed < ask.minAgreed || a.agreed < a.quorum || a.agreed > a.panelSize)
        {
            revert PanelTooWeak(a.panelSize, a.quorum, a.agreed);
        }
        bytes32 digest = _verifyAttestation(a, signature);
        bool passed = decodeBool(a);
        if (consumed[a.requestId]) revert AlreadyConsumed(a.requestId);
        if (!matches) {
            // Do not reserve a UUID on unconfirmed delivery: a swapped answer must not prevent
            // its actual ask from binding. Nor may another ask's reservation burn this one-shot
            // delivery. Binding still requires an available UUID; only the owner can release a
            // terminal reservation or close a conflicting receipt. Consumed UUIDs stay rejected.
            _reviewReceipts[requestId] = StoredReviewReceipt({
                oracleRequestId: a.requestId,
                questionHash: a.questionHash,
                questionChainId: a.chainId,
                panelJobId: a.panelJobId,
                details: RECEIPT_ALLOCATED | uint256(a.fromBlock) | (uint256(a.toBlock) << 64)
                    | (uint256(uint64(block.timestamp)) << 128) | (uint256(a.panelSize) << 192)
                    | (uint256(a.agreed) << 208) | (uint256(passed ? 1 : 0) << 224)
                    | (uint256(oracleSignerEpoch) << 225)
            });
            emit ReviewReceived(jobRequestId, requestId, a.requestId, digest);
            return;
        }
        // Keep verification authority even when pre-binding settles immediately. This writes
        // the already allocated metadata word, without materializing four cold context slots.
        _reviewReceipts[requestId].details =
            RECEIPT_ALLOCATED | (uint256(oracleSignerEpoch) << 225) | (uint256(uint64(block.timestamp)) << 128);
        _consume(a.requestId);
        _answerReview(jobRequestId, requestId, passed, a.questionHash, a.panelJobId, a.panelSize, a.agreed);
    }

    function _answerReview(
        bytes32 jobRequestId,
        bytes32 requestId,
        bool passed,
        bytes32 questionHash,
        bytes32 panelJobId,
        uint16 panelSize,
        uint16 agreed
    ) internal {
        delete reviewOf[requestId];
        Job storage job = jobs[jobRequestId];
        job.review = passed ? ReviewStatus.Passed : ReviewStatus.NotPassed;
        job.reviewPanelSize = panelSize;
        job.reviewAgreed = agreed;
        job.reviewPanelJobId = panelJobId;
        emit ReviewAnswered(jobRequestId, requestId, passed, questionHash, panelJobId, panelSize, agreed);
        // A fresh finalized approval must leave at least one hour under the deployer's minimum
        // one-day age policy. Old positive receipts remain historical and consumed, but need a
        // fresh paid review. Negative answers are NEVER made retryable by elapsed time.
        if (passed && block.timestamp > uint256(reviewVerifiedAt(requestId)) + 23 hours) {
            job.review = ReviewStatus.Unanswered;
            emit ReviewUnanswered(jobRequestId, requestId, 0, "positive receipt aged");
        }
    }

    /// @notice The review ask was refused or the panel did not agree: no verdict. Unsigned; only clears.
    function onReviewFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        onlyIntake
    {
        bytes32 jobRequestId = reviewOf[requestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(requestId);
        if (_reviewReceipts[requestId].oracleRequestId != bytes32(0)) revert ReviewAlreadyReceived(requestId);
        delete reviewOf[requestId];
        jobs[jobRequestId].review = ReviewStatus.Unanswered;
        emit ReviewUnanswered(jobRequestId, requestId, status, reason);
    }

    /// @notice Requests owner-assisted expiry after the deadline, only without a retained answer.
    /// The ask stays Pending and accepts delivery/binding. A requester cannot front-run a visible
    /// NotPassed callback by expiring or buying a retry. See confirmReviewExpiry for actual closure.
    function expireReview(bytes32 jobRequestId) external {
        Job storage job = jobs[jobRequestId];
        if (job.review != ReviewStatus.Pending) revert UnknownOrSettled(jobRequestId);
        if (msg.sender != job.requester) revert NotRequester();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= job.reviewDeadline) revert DeadlineNotReached(job.reviewDeadline);
        bytes32 intakeRequestId = job.reviewRequestId;
        if (_reviewReceipts[intakeRequestId].oracleRequestId != bytes32(0)) {
            revert ReviewAlreadyReceived(intakeRequestId);
        }
        if (reviewExpiryRequested[intakeRequestId]) revert ReviewExpiryAlreadyRequested(intakeRequestId);
        reviewExpiryRequested[intakeRequestId] = true;
        emit ReviewExpiryRequested(jobRequestId, intakeRequestId);
    }

    /// @notice Closes an overdue ask with no receipt, even if its requester has abandoned it.
    /// @dev The owner must independently check that Intake will not deliver a valid answer.
    /// That absence is NOT proven onchain. Never confirm based only on the deadline or requester
    /// assertion. A mistaken/hostile confirmation can still burn a later callback. Use the exact
    /// Intake ID so an approval for an old ask cannot close its retry. Receipts always block closure.
    function confirmReviewExpiry(bytes32 intakeRequestId) external onlyOwner {
        bytes32 jobRequestId = reviewOf[intakeRequestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(intakeRequestId);
        uint64 deadline = _reviewAsks[intakeRequestId].deadline;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= deadline) revert DeadlineNotReached(deadline);
        if (_reviewReceipts[intakeRequestId].oracleRequestId != bytes32(0)) {
            revert ReviewAlreadyReceived(intakeRequestId);
        }
        delete reviewOf[intakeRequestId];
        jobs[jobRequestId].review = ReviewStatus.Unanswered;
        emit ReviewUnanswered(jobRequestId, intakeRequestId, 0, "owner confirmed expiry");
    }

    // ---------------------------------------------------------------- reads for a static site

    /// @notice Everything a status page shows for one job, in one eth_call.
    function getJob(bytes32 requestId) external view returns (Job memory) {
        return jobs[requestId];
    }

    function getReviewAsk(bytes32 intakeRequestId) external view returns (ReviewAsk memory) {
        return _reviewAsks[intakeRequestId];
    }

    /// @notice Verification epoch for either callback order; zero before authenticated delivery.
    /// A bind-first verdict has provenance here but no early receipt. Check revokedSignerEpochs
    /// for finalized approvals too; revocation never rewrites the historical verdict.
    function reviewReceiptSignerEpoch(bytes32 intakeRequestId) public view returns (uint32) {
        return uint32((_reviewReceipts[intakeRequestId].details >> 225) & MAX_SIGNER_EPOCH);
    }

    /// @notice An early verified receipt (zero oracleRequestId if none). It is NOT a verdict and
    /// remains readable after finalization or owner discard; consult getJob for current status.
    function getReviewReceipt(bytes32 intakeRequestId) public view returns (ReviewReceipt memory) {
        StoredReviewReceipt storage receipt = _reviewReceipts[intakeRequestId];
        uint256 details = receipt.details;
        // Each cast selects its documented field; allocation bit 255 is never exposed as data.
        return ReviewReceipt({
            oracleRequestId: receipt.oracleRequestId,
            questionHash: receipt.questionHash,
            questionChainId: receipt.questionChainId,
            panelJobId: receipt.panelJobId,
            fromBlock: uint64(details),
            toBlock: uint64(details >> 64),
            receivedAt: uint64(details >> 128),
            panelSize: uint16(details >> 192),
            agreed: uint16(details >> 208),
            passed: (details & (uint256(1) << 224)) != 0
        });
    }

    /// @notice Time the signed verdict was verified, in either callback order.
    /// Late owner binding does not make an old answer fresh again.
    function reviewVerifiedAt(bytes32 intakeRequestId) public view returns (uint64) {
        return uint64(_reviewReceipts[intakeRequestId].details >> 128);
    }

    /// @notice Acknowledgment value for `discardMismatchedReviewReceipt`: the hash of the exact
    /// receipt tuple `getReviewReceipt` returns, verdict included. Read it, inspect the receipt, then
    /// pass it, so the call names the specific signed answer being set aside.
    function reviewReceiptHash(bytes32 intakeRequestId) external view returns (bytes32) {
        return keccak256(abi.encode(getReviewReceipt(intakeRequestId)));
    }

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    function jobsOf(address requester) external view returns (bytes32[] memory) {
        return _jobsOf[requester];
    }

    // ---------------------------------------------------------------- owner settings

    /// @dev Operational recommendation: rotate with no pending work. This is NOT enforced;
    /// the current Intake and signer authorize callbacks even for previously opened asks.
    function setIntake(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        intake = IIntake(to);
        emit IntakeSet(to);
    }

    /// @notice The asset and the price ceiling move together: a ceiling means nothing in another asset.
    function setPayment(address asset_, uint256 maxPrice_) external onlyOwner nonReentrant {
        if (asset_ == address(0)) revert ZeroAddress();
        if (maxPrice_ == 0) revert PriceAboveCeiling(0, 0);
        asset = asset_;
        maxPrice = maxPrice_;
        emit PaymentSet(asset_, maxPrice_);
    }

    /// @notice On only against an Intake version 2; a version 1 intake has no `requestWithFailure`.
    function setFailureHook(bool on) external onlyOwner {
        failureHook = on;
        emit FailureHookSet(on);
    }

    function setOracleSigner(address to) external onlyOwner {
        if (oracleSignerEpoch == MAX_SIGNER_EPOCH) revert InvalidSignerEpoch(oracleSignerEpoch);
        _setOracleSigner(to);
        ++oracleSignerEpoch;
        emit OracleSignerEpochStarted(oracleSignerEpoch, to);
    }

    /// @notice The `job.open` action id and body template. Body = prefix ++ "0x<specHash>" ++
    /// middle ++ brief ++ suffix. The template must name "forge build", "forge test" and
    /// "adversarial review", and quote the brief as untrusted text.
    /// @dev Each marker must sit whole inside one fragment. The assembled body inserts the spec
    /// hash and the untrusted brief between fragments, so a marker spanning a fragment boundary
    /// would be absent from every real body; one inside the brief is the creator's, not the
    /// template's. A marker whole inside a fragment is in every assembled body, so this check is
    /// exactly "every body this template can assemble names all three steps".
    function setJobTemplate(bytes32 action, bytes calldata prefix, bytes calldata middle, bytes calldata suffix)
        external
        onlyOwner
    {
        if (action == bytes32(0)) revert NotConfigured("jobAction");
        uint256 length = prefix.length + middle.length + suffix.length;
        if (length > MAX_TEMPLATE_BYTES) revert TemplateTooLong(length);
        bytes[3] memory fragments = [prefix, middle, suffix];
        _requireStep(fragments, STEP_BUILD);
        _requireStep(fragments, STEP_TEST);
        _requireStep(fragments, STEP_REVIEW);
        jobAction = action;
        jobBodyPrefix = prefix;
        jobBodyMiddle = middle;
        jobBodySuffix = suffix;
        emit JobTemplateSet(action, keccak256(abi.encode(prefix, middle, suffix)));
    }

    /// @notice The `oracle.request` action id, review question template (body = prefix ++
    /// "0x<job request id>" ++ suffix) and the smallest panel and agreement a verdict must carry.
    function setReviewTemplate(
        bytes32 action,
        bytes calldata prefix,
        bytes calldata suffix,
        uint16 minPanelSize_,
        uint16 minAgreed_
    ) external onlyOwner {
        if (action == bytes32(0)) revert NotConfigured("reviewAction");
        if (prefix.length + suffix.length > MAX_TEMPLATE_BYTES) revert TemplateTooLong(prefix.length + suffix.length);
        if (minPanelSize_ < 2 || minAgreed_ == 0 || minAgreed_ > minPanelSize_) {
            revert InvalidPanelMinimums(minPanelSize_, minAgreed_);
        }
        reviewAction = action;
        reviewBodyPrefix = prefix;
        reviewBodySuffix = suffix;
        minPanelSize = minPanelSize_;
        minAgreed = minAgreed_;
        emit ReviewTemplateSet(action, keccak256(abi.encode(prefix, suffix)), minPanelSize_, minAgreed_);
    }

    function setTimeouts(uint64 jobTimeout_, uint64 reviewTimeout_) external onlyOwner {
        if (jobTimeout_ < MIN_TIMEOUT || jobTimeout_ > MAX_TIMEOUT) revert InvalidTimeout(jobTimeout_);
        if (reviewTimeout_ < MIN_TIMEOUT || reviewTimeout_ > MAX_TIMEOUT) revert InvalidTimeout(reviewTimeout_);
        jobTimeout = jobTimeout_;
        reviewTimeout = reviewTimeout_;
        emit TimeoutsSet(jobTimeout_, reviewTimeout_);
    }

    /// @notice Recovers tokens sent here by mistake. The contract holds nothing between calls.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    // ---------------------------------------------------------------- internals

    function _recordIntakeId(bytes32 requestId) internal {
        if (requestId == bytes32(0) || usedIntakeRequestIds[requestId]) revert DuplicateRequestId(requestId);
        usedIntakeRequestIds[requestId] = true;
    }

    function _pull(bytes32 action, uint256 userMaxPrice) internal returns (uint256 price) {
        price = intake.priceOf(action, asset);
        if (price == 0) revert ActionNotPriced(action);
        if (price > maxPrice) revert PriceAboveCeiling(price, maxPrice);
        if (price > userMaxPrice) revert PriceAboveUserMaximum(price, userMaxPrice);
        ExactStoreToken.pull(asset, msg.sender, price);
        _approve(address(intake), price);
    }

    /// @dev One ask, with the failure function when the hook is on, and no standing allowance after.
    function _ask(bytes32 action, bytes memory body, bytes4 onResult, bytes4 onFailure, uint256 price)
        internal
        returns (bytes32 requestId)
    {
        uint256 beforeBalance = ExactStoreToken.balance(asset, address(this));
        IIntake.Callback memory callback = IIntake.Callback(address(this), onResult);
        if (failureHook) {
            requestId = intake.requestWithFailure(action, body, callback, onFailure, asset, price);
        } else {
            requestId = intake.request(action, body, callback, asset, price);
        }
        _approve(address(intake), 0);
        if (ExactStoreToken.balance(asset, address(this)) != beforeBalance - price) revert InexactIntakeSpend();
    }

    function _approve(address spender, uint256 amount) internal {
        _call(asset, abi.encodeWithSelector(0x095ea7b3, spender, amount));
    }

    /// @dev ERC-20 call accepting `true` or no return data, as SafeERC20 does.
    function _call(address token, bytes memory data) internal {
        if (token.code.length == 0) revert TokenCallFailed();
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && (ret.length != 32 || !abi.decode(ret, (bool))))) revert TokenCallFailed();
    }

    /// @dev Strict UTF-8 (no overlongs, surrogates or > U+10FFFF) without JSON-significant ASCII
    /// (`"` `\`), the quoting delimiters (`<` `>`), control characters or DEL.
    function _validateBrief(bytes calldata b) internal pure {
        uint256 n = b.length;
        if (n == 0 || n > MAX_BRIEF_BYTES) revert BriefLength(n);
        uint256 i;
        while (i < n) {
            uint8 c = uint8(b[i]);
            if (c < 0x80) {
                if (c < 0x20 || c == 0x7f || c == 0x22 || c == 0x5c || c == 0x3c || c == 0x3e) revert InvalidBrief(i);
                ++i;
                continue;
            }
            uint256 len;
            uint256 cp;
            if (c >= 0xc2 && c <= 0xdf) {
                len = 2;
                cp = c & 0x1f;
            } else if (c >= 0xe0 && c <= 0xef) {
                len = 3;
                cp = c & 0x0f;
            } else if (c >= 0xf0 && c <= 0xf4) {
                len = 4;
                cp = c & 0x07;
            } else {
                revert InvalidBrief(i);
            }
            if (i + len > n) revert InvalidBrief(i);
            for (uint256 j = 1; j < len; ++j) {
                uint8 d = uint8(b[i + j]);
                if (d & 0xc0 != 0x80) revert InvalidBrief(i + j);
                cp = (cp << 6) | (d & 0x3f);
            }
            if (len == 3 && (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff))) revert InvalidBrief(i);
            if (len == 4 && (cp < 0x10000 || cp > 0x10ffff)) revert InvalidBrief(i);
            i += len;
        }
    }

    /// @dev The step marker must lie whole inside one template fragment (see setJobTemplate).
    function _requireStep(bytes[3] memory fragments, bytes memory step) internal pure {
        for (uint256 i; i < 3; ++i) {
            if (_contains(fragments[i], step)) return;
        }
        revert TemplateMissingStep(step);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        uint256 m = needle.length;
        if (m > haystack.length) return false;
        bytes32 target = keccak256(needle);
        for (uint256 i; i + m <= haystack.length; ++i) {
            bytes32 h;
            assembly ("memory-safe") {
                h := keccak256(add(add(haystack, 0x20), i), m)
            }
            if (h == target) return true;
        }
        return false;
    }

    function _hex(bytes32 value) internal pure returns (bytes memory out) {
        bytes16 digits = "0123456789abcdef";
        out = new bytes(66);
        out[0] = "0";
        out[1] = "x";
        // i < 32 bounds both offset expressions below 66; neither can overflow.
        unchecked {
            for (uint256 i; i < 32; ++i) {
                out[2 + 2 * i] = digits[uint8(value[i]) >> 4];
                out[3 + 2 * i] = digits[uint8(value[i]) & 0x0f];
            }
        }
    }
}

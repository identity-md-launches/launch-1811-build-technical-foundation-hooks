// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";
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
contract HookJobRequester is OracleAttestationConsumer, Owned {
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

    mapping(bytes32 requestId => Job) internal jobs;
    /// @notice Oracle request id of a pending review ask => the job's Intake request id.
    mapping(bytes32 oracleRequestId => bytes32 jobRequestId) public reviewOf;
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
    error InvalidTimeout(uint64 timeout);
    error InvalidPanelMinimums(uint16 panelSize, uint16 agreed);
    error PanelTooWeak(uint16 panelSize, uint16 quorum, uint16 agreed);
    error NotReviewable(bytes32 jobRequestId);
    error DeadlineNotReached(uint64 deadline);
    error TokenCallFailed();
    error Reentrancy();

    event IntakeSet(address indexed intake);
    event AssetSet(address indexed asset);
    event JobTemplateSet(bytes32 indexed action, bytes32 templateHash);
    event ReviewTemplateSet(bytes32 indexed action, bytes32 templateHash, uint16 minPanelSize, uint16 minAgreed);
    event TimeoutsSet(uint64 jobTimeout, uint64 reviewTimeout);
    event JobOpened(
        bytes32 indexed requestId, address indexed requester, bytes32 indexed specHash, uint256 price, bytes body
    );
    event JobDelivered(bytes32 indexed requestId, bytes32 resultHash);
    event JobFailed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event JobExpired(bytes32 indexed requestId);
    event ReviewRequested(bytes32 indexed jobRequestId, bytes32 indexed oracleRequestId, uint256 price, bytes body);
    event ReviewAnswered(
        bytes32 indexed jobRequestId,
        bytes32 indexed oracleRequestId,
        bool passed,
        bytes32 questionHash,
        bytes32 panelJobId,
        uint16 panelSize,
        uint16 agreed
    );
    event ReviewUnanswered(bytes32 indexed jobRequestId, bytes32 indexed oracleRequestId, uint8 status, bytes32 reason);

    /// @param owner_ The launch's owner; never the deploying factory.
    /// @param intake_ The chain's Intake version 2.
    /// @param asset_ The chain's IMD token.
    /// @param oracleSigner_ The IdentityMD oracle signer (a key or an ERC-1271 registry).
    constructor(address owner_, address intake_, address asset_, address oracleSigner_)
        OracleAttestationConsumer(oracleSigner_)
        Owned(owner_)
    {
        if (owner_ == address(0) || intake_ == address(0) || asset_ == address(0)) revert ZeroAddress();
        intake = IIntake(intake_);
        asset = asset_;
        emit IntakeSet(intake_);
        emit AssetSet(asset_);
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
    function openJob(bytes32 specHash, bytes calldata brief) external nonReentrant returns (bytes32 requestId) {
        if (jobAction == bytes32(0)) revert NotConfigured("jobTemplate");
        _validateBrief(brief);
        bytes memory body = bytes.concat(jobBodyPrefix, _hex(specHash), jobBodyMiddle, brief, jobBodySuffix);
        if (body.length > MAX_BODY_BYTES) revert BodyTooLong(body.length);
        uint256 price = _pull(jobAction);
        requestId = intake.requestWithFailure(
            jobAction,
            body,
            IIntake.Callback(address(this), this.onJobResult.selector),
            this.onJobFailure.selector,
            asset,
            price
        );
        _approve(address(intake), 0);
        if (requestId == bytes32(0) || jobs[requestId].status != JobStatus.None) revert DuplicateRequestId(requestId);
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

    /// @notice Completion notice for an open job, from the Intake only, once. Unsigned: it says
    /// the Intake reported the job complete, never that its review passed.
    /// @dev The `job.open` callback ABI was not part of this task's protocol references; this
    /// `(bytes32, bytes)` shape must be confirmed in a live pilot. If the Intake calls with another
    /// shape, this reverts inside the Intake's try, the job stays Open, and its requester can
    /// expire it after the deadline. Nothing of value moves either way.
    function onJobResult(bytes32 requestId, bytes calldata result) external onlyIntake {
        Job storage job = jobs[requestId];
        if (job.status != JobStatus.Open) revert UnknownOrSettled(requestId);
        job.status = JobStatus.Delivered;
        bytes32 resultHash = keccak256(result);
        job.resultHash = resultHash;
        emit JobDelivered(requestId, resultHash);
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
        if (job.status != JobStatus.Open) revert UnknownOrSettled(requestId);
        job.status = JobStatus.Failed;
        job.failureStatus = status;
        job.failureReason = reason;
        emit JobFailed(requestId, status, reason, agreed, answered);
    }

    /// @notice A job whose result or failure never came can be closed by its requester after the deadline.
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
    /// requester pays `intake.priceOf(reviewAction, asset)`. Allowed once the job was delivered or
    /// expired (a lost completion notice does not block a verdict), and again after an unanswered ask.
    function requestReview(bytes32 jobRequestId) external nonReentrant returns (bytes32 oracleRequestId) {
        if (reviewAction == bytes32(0)) revert NotConfigured("reviewTemplate");
        Job storage job = jobs[jobRequestId];
        if (msg.sender != job.requester) revert NotRequester();
        if (
            (job.status != JobStatus.Delivered && job.status != JobStatus.Expired)
                || (job.review != ReviewStatus.None && job.review != ReviewStatus.Unanswered)
        ) revert NotReviewable(jobRequestId);
        bytes memory body = bytes.concat(reviewBodyPrefix, _hex(jobRequestId), reviewBodySuffix);
        uint256 price = _pull(reviewAction);
        oracleRequestId = intake.requestWithFailure(
            reviewAction,
            body,
            IIntake.Callback(address(this), this.onReviewResult.selector),
            this.onReviewFailure.selector,
            asset,
            price
        );
        _approve(address(intake), 0);
        if (
            oracleRequestId == bytes32(0) || reviewOf[oracleRequestId] != bytes32(0)
                || jobs[oracleRequestId].status != JobStatus.None
        ) {
            revert DuplicateRequestId(oracleRequestId);
        }
        reviewOf[oracleRequestId] = jobRequestId;
        job.review = ReviewStatus.Pending;
        job.reviewRequestId = oracleRequestId;
        job.reviewDeadline = uint64(block.timestamp) + reviewTimeout;
        emit ReviewRequested(jobRequestId, oracleRequestId, price, body);
    }

    /// @notice The `oracle.request` callback: Intake only, a pending review ask of this contract
    /// only, a panel at least the owner's minimums, a valid signature for this contract, once.
    function onReviewResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        onlyIntake
    {
        bytes32 jobRequestId = reviewOf[requestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(requestId);
        if (a.panelSize < minPanelSize || a.agreed < minAgreed || a.agreed < a.quorum) {
            revert PanelTooWeak(a.panelSize, a.quorum, a.agreed);
        }
        _verifyAttestation(a, signature);
        _consume(a.requestId);
        bool passed = decodeBool(a);
        delete reviewOf[requestId];
        Job storage job = jobs[jobRequestId];
        job.review = passed ? ReviewStatus.Passed : ReviewStatus.NotPassed;
        job.reviewPanelSize = a.panelSize;
        job.reviewAgreed = a.agreed;
        job.reviewPanelJobId = a.panelJobId;
        emit ReviewAnswered(jobRequestId, requestId, passed, a.questionHash, a.panelJobId, a.panelSize, a.agreed);
    }

    /// @notice The review ask was refused or the panel did not agree: no verdict. Unsigned; only clears.
    function onReviewFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        onlyIntake
    {
        bytes32 jobRequestId = reviewOf[requestId];
        if (jobRequestId == bytes32(0)) revert UnknownOrSettled(requestId);
        delete reviewOf[requestId];
        jobs[jobRequestId].review = ReviewStatus.Unanswered;
        emit ReviewUnanswered(jobRequestId, requestId, status, reason);
    }

    /// @notice A review ask with no answer by its deadline can be cleared by the job's requester.
    function expireReview(bytes32 jobRequestId) external {
        Job storage job = jobs[jobRequestId];
        if (job.review != ReviewStatus.Pending) revert UnknownOrSettled(jobRequestId);
        if (msg.sender != job.requester) revert NotRequester();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= job.reviewDeadline) revert DeadlineNotReached(job.reviewDeadline);
        bytes32 oracleRequestId = job.reviewRequestId;
        delete reviewOf[oracleRequestId];
        job.review = ReviewStatus.Unanswered;
        emit ReviewUnanswered(jobRequestId, oracleRequestId, 0, "expired");
    }

    // ---------------------------------------------------------------- reads for a static site

    /// @notice Everything a status page shows for one job, in one eth_call.
    function getJob(bytes32 requestId) external view returns (Job memory) {
        return jobs[requestId];
    }

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    function jobsOf(address requester) external view returns (bytes32[] memory) {
        return _jobsOf[requester];
    }

    // ---------------------------------------------------------------- owner settings

    /// @dev Change only with no job or review pending: callbacks are accepted from the current intake.
    function setIntake(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        intake = IIntake(to);
        emit IntakeSet(to);
    }

    function setAsset(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        asset = to;
        emit AssetSet(to);
    }

    function setOracleSigner(address to) external onlyOwner {
        _setOracleSigner(to);
    }

    /// @notice The `job.open` action id and body template. Body = prefix ++ "0x<specHash>" ++
    /// middle ++ brief ++ suffix. The template must name "forge build", "forge test" and
    /// "adversarial review", and quote the brief as untrusted text.
    function setJobTemplate(bytes32 action, bytes calldata prefix, bytes calldata middle, bytes calldata suffix)
        external
        onlyOwner
    {
        if (action == bytes32(0)) revert NotConfigured("jobAction");
        bytes memory all = bytes.concat(prefix, middle, suffix);
        if (all.length > MAX_TEMPLATE_BYTES) revert TemplateTooLong(all.length);
        if (!_contains(all, STEP_BUILD)) revert TemplateMissingStep(STEP_BUILD);
        if (!_contains(all, STEP_TEST)) revert TemplateMissingStep(STEP_TEST);
        if (!_contains(all, STEP_REVIEW)) revert TemplateMissingStep(STEP_REVIEW);
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
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    // ---------------------------------------------------------------- internals

    function _pull(bytes32 action) internal returns (uint256 price) {
        price = intake.priceOf(action, asset);
        if (price == 0) revert ActionNotPriced(action);
        _call(asset, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), price));
        _approve(address(intake), price);
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
        for (uint256 i; i < 32; ++i) {
            out[2 + 2 * i] = digits[uint8(value[i]) >> 4];
            out[3 + 2 * i] = digits[uint8(value[i]) & 0x0f];
        }
    }
}

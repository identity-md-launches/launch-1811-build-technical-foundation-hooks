// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreAdmin} from "../../store/StoreAdmin.sol";
import {ExactStoreToken} from "../../store/ExactStoreToken.sol";
import {IIntake} from "../IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../OracleAttestation.sol";
import {HookJobRequester} from "../HookJobRequester.sol";
import {HookSpec} from "../../HookSpec.sol";
import {GatedHookDeployer} from "../../deployment/GatedHookDeployer.sol";
import {HookRequestCodec} from "./HookRequestCodec.sol";
import {ECDSA} from "../../vendor/openzeppelin/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "../../vendor/openzeppelin/utils/cryptography/SignatureChecker.sol";

/// @notice Automatic successor to the legacy owner-bound requester. No per-job owner binding.
/// The job requester commits one candidate, then anyone can spend its prepaid verdict reserve.
/// A signed, reconstructed question authorizes exactly that candidate; publication never does.
contract AutoHookJobRequester is OracleAttestationConsumer, StoreAdmin {
    struct Payment {
        address intake;
        address asset;
        bytes32 verdictAction;
        uint256 reserve;
        uint64 windowStartBlock;
        uint64 reserveDeadline;
        uint16 panelSize;
        uint16 quorum;
        bool cancelled;
    }

    struct Candidate {
        GatedHookDeployer.Artifact artifact;
        bytes20 reviewedCommit;
    }

    struct Ask {
        bytes32 jobId;
        bytes32 intakeId;
        address pin;
        uint64 askedAt;
        uint64 deadline;
        uint64 fromBlock;
        uint64 toBlock;
        // Snapshotted at trigger: bits 96..255 signer, 64..95 epoch; 0..63 verifiedAt on receipt.
        uint256 verification;
        bytes32 oracleUUID;
    }

    HookRequestCodec public immutable codec;
    IIntake public intake;
    address public asset;
    uint256 public maxPrice;
    bytes32 public jobAction = bytes32("job.open@job-1");
    bytes32 public reviewAction = bytes32("oracle.request@oracle-1");
    uint16 public minPanelSize = 7;
    uint16 public minAgreed = 5;
    uint64 private constant JOB_TIMEOUT = 7 days;
    uint64 private constant REVIEW_TIMEOUT = 1 days;
    uint64 public constant WINDOW_DEPTH = 8;
    // Native block-count policy, initialized to the codec's chain-specific cadence assumption.
    uint64 public maxWindowAgeBlocks;
    uint32 public oracleSignerEpoch = 1;
    mapping(uint32 => bytes32) public revokedSignerEpochs;
    mapping(bytes32 => bool) public revokedReviewReceipts;
    mapping(bytes32 => HookJobRequester.Job) private jobs;
    mapping(bytes32 => HookSpec) private specs;
    mapping(bytes32 => address) public deployerOf;
    mapping(bytes32 => Payment) private payments;
    mapping(bytes32 => Candidate) private candidates;
    mapping(bytes32 => bytes32) public candidateDigest;
    mapping(bytes32 => bytes32) public jobAsk;
    mapping(bytes32 => Ask) private asks;
    mapping(bytes32 => bytes32) public reviewOf;
    mapping(bytes32 => bool) public usedIntakeRequestIds;
    mapping(address => uint256) public reserved;
    mapping(address => mapping(address => uint256)) public refunds;
    mapping(bytes32 => uint64) private windowAge;
    mapping(address => bytes32[]) private creatorJobs;
    uint256 private nonce;
    uint256 private locked = 1;

    error InvalidConfig();
    error NotConfigured();
    error NotRequester();
    error NotIntake();
    error NotReady();
    error AlreadyCommitted();
    error UnknownOrSettled();
    error DuplicateId();
    error PriceExceeded(uint256 price, uint256 cap);
    error InexactSpend();
    error InvalidArtifact();
    error WrongQuestion();
    error InvalidWindow();
    error WeakPanel();
    error Revoked();
    error DeadlineNotReached();
    error Reentrancy();
    error EscrowProtected();

    event JobOpened(
        bytes32 indexed requestId, address indexed requester, bytes32 indexed specHash, uint256 price, bytes body
    );
    event JobDelivered(bytes32 indexed requestId, bytes32 resultHash);
    event JobResultURI(bytes32 indexed requestId, string uri);
    event JobResultURIOmitted(bytes32 indexed requestId, uint256 uriBytes);
    event JobFailed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event JobExpired(bytes32 indexed requestId);
    event CandidateCommitted(bytes32 indexed jobId, bytes32 indexed askId, bytes32 digest, bytes20 reviewedCommit);
    event VerdictRequested(bytes32 indexed askId, bytes32 indexed intakeId, address pin, uint256 price, bytes body);
    event VerdictAnswered(bytes32 indexed askId, bytes32 indexed oracleUUID, bool passed, bytes32 digest);
    event VerdictUnanswered(bytes32 indexed askId, bytes32 reason);
    event ReserveRefunded(bytes32 indexed jobId, address asset, address requester, uint256 amount);
    event VerdictRenewed(bytes32 indexed jobId, bytes32 indexed askId, uint64 windowStartBlock, uint64 reserveDeadline);
    event ReserveToppedUp(bytes32 indexed jobId, uint256 amount, uint256 reserve);
    event RefundWithdrawn(address indexed asset, address indexed requester, uint256 amount);
    event ProtocolSet(address intake, address asset, uint256 maxPrice, bytes32 jobAction, bytes32 reviewAction);
    event PanelSet(uint16 panelSize, uint16 quorum, uint64 maxWindowAgeBlocks);
    event OracleSignerEpochStarted(uint32 indexed epoch, address indexed signer);
    event OracleSignerEpochRevoked(uint32 indexed epoch, bytes32 incidentHash);
    event ReviewReceiptRevoked(bytes32 indexed jobId, bytes32 indexed intakeId, uint32 epoch, bytes32 incidentHash);

    constructor(address owner_, address intake_, address asset_, address signer_, uint256 cap_, HookRequestCodec codec_)
        OracleAttestationConsumer(signer_)
        StoreAdmin(owner_)
    {
        if (intake_ == address(0) || asset_ == address(0) || address(codec_) == address(0) || cap_ == 0) {
            revert InvalidConfig();
        }
        intake = IIntake(intake_);
        asset = asset_;
        maxPrice = cap_;
        codec = codec_;
        maxWindowAgeBlocks = codec_.minimumWindowAgeBlocks();
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    function automaticBindingSupported() external pure returns (bool) {
        return true;
    }

    /// @notice The same native chain clock used by every lifecycle transition.
    function head() public view returns (uint64) {
        return codec.paymentHead(maxWindowAgeBlocks);
    }

    /// @notice Prepay build and a caller-capped verdict reserve. No later token approval is needed
    /// for the permissionless trigger. Build cost is spent; unused reserve is pull-refunded.
    function openJob(
        HookSpec calldata spec,
        address deployer,
        bytes calldata brief,
        uint256 maxBuildFee,
        uint256 verdictReserve
    ) external nonReentrant returns (bytes32 jobId, bytes32 askId) {
        if (address(codec).codehash != 0xfb28d0432fba1c6ee9e6ec8d3ae5896d1a36c708c7ee6eccc701eb07dc6611ea) revert NotConfigured();
        uint64 currentBlock = head();
        if (verdictReserve > maxPrice) revert PriceExceeded(verdictReserve, maxPrice);
        uint256 price = _quote(address(intake), jobAction, asset, maxBuildFee < maxPrice ? maxBuildFee : maxPrice);
        _quote(address(intake), reviewAction, asset, verdictReserve);
        askId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        (bytes32 specHash, bytes memory body) = codec.prepareJob(spec, askId, address(intake), deployer, brief);
        ExactStoreToken.pull(asset, msg.sender, price + verdictReserve);
        reserved[asset] += verdictReserve;
        jobId = _request(
            address(intake), asset, jobAction, body, this.onJobResult.selector, this.onJobFailure.selector, price
        );
        _recordId(jobId);
        HookJobRequester.Job storage j = jobs[jobId];
        j.requester = msg.sender;
        j.openedAt = uint64(block.timestamp);
        j.deadline = uint64(block.timestamp) + JOB_TIMEOUT;
        j.status = HookJobRequester.JobStatus.Open;
        j.specHash = specHash;
        j.bodyHash = keccak256(body);
        specs[jobId] = spec;
        deployerOf[jobId] = deployer;
        payments[jobId] = Payment(
            address(intake),
            asset,
            reviewAction,
            verdictReserve,
            currentBlock,
            uint64(block.timestamp) + JOB_TIMEOUT,
            minPanelSize,
            minAgreed,
            false
        );
        jobAsk[jobId] = askId;
        asks[askId].jobId = jobId;
        creatorJobs[msg.sender].push(jobId);
        emit JobOpened(jobId, msg.sender, j.specHash, price, body);
    }

    /// @notice One immutable candidate per job, selected explicitly by its requester. This call
    /// requires delivery first. The panel must prove it is the accepted reviewed build.
    function commitArtifact(bytes32 jobId, GatedHookDeployer.Artifact calldata a, bytes20 reviewedCommit) external {
        HookJobRequester.Job storage j = _requesterJob(jobId);
        if (candidateDigest[jobId] != bytes32(0)) revert AlreadyCommitted();
        if (j.status != HookJobRequester.JobStatus.Delivered || payments[jobId].cancelled) revert NotReady();
        bytes32 digest = codec.validateCandidate(a, specs[jobId], jobId, deployerOf[jobId], reviewedCommit);
        _refreshReserveWindow(payments[jobId]);
        candidates[jobId] = Candidate(a, reviewedCommit);
        candidateDigest[jobId] = digest;
        emit CandidateCommitted(jobId, jobAsk[jobId], digest, reviewedCommit);
    }

    function onJobResult(bytes32 jobId, bytes32 resultHash, string calldata uri) external {
        _jobCallback(jobId);
        if (resultHash == bytes32(0)) revert InvalidArtifact();
        HookJobRequester.Job storage j = jobs[jobId];
        j.status = HookJobRequester.JobStatus.Delivered;
        j.resultHash = resultHash;
        _refreshReserveWindow(payments[jobId]);
        emit JobDelivered(jobId, resultHash);
        if (bytes(uri).length <= 1024) emit JobResultURI(jobId, uri);
        else emit JobResultURIOmitted(jobId, bytes(uri).length);
    }

    function onJobFailure(bytes32 jobId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered, bytes calldata)
        external
    {
        _jobCallback(jobId);
        HookJobRequester.Job storage j = jobs[jobId];
        j.status = HookJobRequester.JobStatus.Failed;
        j.failureStatus = status;
        j.failureReason = reason;
        emit JobFailed(jobId, status, reason, agreed, answered);
    }

    function _jobCallback(bytes32 id) private view {
        if (msg.sender != payments[id].intake) revert NotIntake();
        HookJobRequester.JobStatus s = jobs[id].status;
        if (s != HookJobRequester.JobStatus.Open && s != HookJobRequester.JobStatus.Expired) revert UnknownOrSettled();
    }

    /// @notice Anyone may trigger this transaction once ready, paying only transaction gas.
    /// No caller-selected question, prefix, artifact, recipient or fee is accepted here.
    function requestVerdict(bytes32 askId) external nonReentrant returns (bytes32 intakeId) {
        (bool ready,, uint64 fromBlock, uint64 toBlock) = verdictReadiness(askId);
        if (!ready) revert NotReady();
        Ask storage a = asks[askId];
        bytes32 jobId = a.jobId;
        HookJobRequester.Job storage j = jobs[jobId];
        Payment storage p = payments[jobId];
        uint256 price = _quote(p.intake, p.verdictAction, p.asset, p.reserve);
        a.askedAt = uint64(block.timestamp);
        a.deadline = uint64(block.timestamp) + REVIEW_TIMEOUT;
        a.fromBlock = fromBlock;
        a.toBlock = toBlock;
        a.verification = (uint256(uint160(oracleSigner)) << 96) | (uint256(oracleSignerEpoch) << 64);
        windowAge[askId] = maxWindowAgeBlocks;
        bytes memory body;
        (a.pin, body) = codec.prepareOracle(
            HookRequestCodec.VerdictRequest({
                intake: p.intake,
                jobId: jobId,
                askId: askId,
                specHash: j.specHash,
                resultHash: j.resultHash,
                reviewedCommit: candidates[jobId].reviewedCommit,
                artifactDigest: candidateDigest[jobId],
                fromBlock: fromBlock,
                toBlock: toBlock,
                panelSize: p.panelSize,
                quorum: p.quorum
            })
        );
        // Mark/spend before external interactions. Reverts restore reserve on refusal or bad spend.
        j.review = HookJobRequester.ReviewStatus.Pending;
        j.reviewDeadline = a.deadline;
        reserved[p.asset] -= price;
        p.reserve -= price;
        intakeId = _request(
            p.intake, p.asset, p.verdictAction, body, this.onReviewResult.selector, this.onReviewFailure.selector, price
        );
        _recordId(intakeId);
        a.intakeId = intakeId;
        j.reviewRequestId = intakeId;
        reviewOf[intakeId] = askId;
        historicalAsk[intakeId] = askId;
        _refund(jobId);
        emit VerdictRequested(askId, intakeId, a.pin, price, body);
    }

    /// @notice Snapshot readiness for SDK/UI. The same checks gate reserve spending.
    /// toBlock is zero before head reaches WINDOW_DEPTH; ready is always false then.
    /// Fee changes may still prevent a ready ask. Unsupported clocks revert without a fallback.
    function verdictReadiness(bytes32 askId)
        public
        view
        returns (bool ready, uint64 currentBlock, uint64 fromBlock, uint64 toBlock)
    {
        currentBlock = head();
        Ask storage a = asks[askId];
        bytes32 jobId = a.jobId;
        Payment storage p = payments[jobId];
        HookJobRequester.Job storage j = jobs[jobId];
        fromBlock = p.windowStartBlock;
        if (currentBlock < WINDOW_DEPTH) return (false, currentBlock, fromBlock, 0);
        unchecked {
            toBlock = currentBlock - WINDOW_DEPTH; // guarded above
        }
        if (
            jobId == bytes32(0) || a.intakeId != bytes32(0) || p.cancelled || p.reserve == 0
                || block.timestamp > p.reserveDeadline || j.status != HookJobRequester.JobStatus.Delivered
                || j.review != HookJobRequester.ReviewStatus.None || candidateDigest[jobId] == bytes32(0)
                || fromBlock > toBlock
        ) return (false, currentBlock, fromBlock, toBlock);
        ready = true;
    }

    function questionPrefix(bytes32 askId) public view returns (bytes memory out) {
        address pin = asks[askId].pin;
        if (pin == address(0)) revert NotReady();
        return codec.readPrefix(pin);
    }

    /// @notice Live quote in the job's original Intake/action/asset context. May revert if the
    /// quote is unavailable. Consumers must require a positive quote within reserve AND readiness.
    function verdictFunding(bytes32 askId) external view returns (uint256 price, uint256 reserve, address token) {
        bytes32 jobId = asks[askId].jobId;
        if (jobId == bytes32(0)) revert NotReady();
        Payment storage p = payments[jobId];
        return (IIntake(p.intake).priceOf(p.verdictAction, p.asset), p.reserve, p.asset);
    }

    function expectedQuestionHash(bytes32 askId, uint64 fromBlock, uint64 toBlock) public view returns (bytes32) {
        address pin = asks[askId].pin;
        if (pin == address(0)) revert NotReady();
        return codec.hashQuestion(pin, fromBlock, toBlock);
    }

    function onReviewResult(bytes32 intakeId, OracleAttestation.Attestation calldata att, bytes calldata signature)
        external
    {
        bytes32 askId = reviewOf[intakeId];
        Ask storage a = asks[askId];
        bytes32 jobId = a.jobId;
        Payment storage p = payments[jobId];
        if (msg.sender != p.intake) revert NotIntake();
        if (askId == bytes32(0) || a.oracleUUID != bytes32(0)) revert UnknownOrSettled();
        bool passed = codec.validateReview(
            att,
            HookRequestCodec.ReviewContext({
                pin: a.pin,
                fromBlock: a.fromBlock,
                toBlock: a.toBlock,
                askedAt: a.askedAt,
                deadline: a.deadline,
                maxWindowAgeBlocks: windowAge[askId],
                panelSize: p.panelSize,
                quorum: p.quorum
            })
        );
        bytes32 digest = _verifyRecordedAttestation(a.verification, att, signature);
        _consume(att.requestId);
        a.oracleUUID = att.requestId;
        a.verification |= uint64(att.issuedAt < block.timestamp ? att.issuedAt : block.timestamp);
        delete reviewOf[intakeId];
        HookJobRequester.Job storage j = jobs[jobId];
        j.review = passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed;
        j.reviewPanelSize = att.panelSize;
        j.reviewAgreed = att.agreed;
        j.reviewPanelJobId = att.panelJobId;
        emit VerdictAnswered(askId, att.requestId, passed, digest);
    }

    /// @dev Verify in the consumer's domain and ERC-1271 caller context, against the trigger's
    /// signer. ECDSA first also preserves an EOA key with EIP-7702 delegated code.
    function _verifyRecordedAttestation(
        uint256 verification,
        OracleAttestation.Attestation calldata att,
        bytes calldata signature
    ) private view returns (bytes32 digest) {
        if (revokedSignerEpochs[uint32(verification >> 64)] != bytes32(0)) {
            revert Revoked();
        }
        address signer = address(uint160(verification >> 96));
        digest = attestationDigest(att);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return digest;
        if (!SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature)) revert BadSignature();
    }

    function onReviewFailure(bytes32 intakeId, uint8, bytes32 reason, uint16, uint16, bytes calldata) external {
        bytes32 askId = reviewOf[intakeId];
        Ask storage a = asks[askId];
        if (msg.sender != payments[a.jobId].intake) revert NotIntake();
        if (askId == bytes32(0) || a.oracleUUID != bytes32(0)) revert UnknownOrSettled();
        delete reviewOf[intakeId];
        jobs[a.jobId].review = HookJobRequester.ReviewStatus.Unanswered;
        emit VerdictUnanswered(askId, reason);
    }

    /// @notice Requester can recover unused reserve after build failure or deadline. Cancelling
    /// permanently disables the ask even if the build's late callback subsequently arrives.
    function cancelReserve(bytes32 jobId) external nonReentrant {
        HookJobRequester.Job storage j = _requesterJob(jobId);
        if (j.status != HookJobRequester.JobStatus.Failed && block.timestamp <= payments[jobId].reserveDeadline) {
            revert DeadlineNotReached();
        }
        if (asks[jobAsk[jobId]].intakeId != bytes32(0)) revert UnknownOrSettled();
        payments[jobId].cancelled = true;
        _refund(jobId);
    }

    function expireJob(bytes32 jobId) external {
        HookJobRequester.Job storage j = _requesterJob(jobId);
        if (j.status != HookJobRequester.JobStatus.Open) revert UnknownOrSettled();
        if (block.timestamp <= j.deadline) revert DeadlineNotReached();
        j.status = HookJobRequester.JobStatus.Expired;
        emit JobExpired(jobId);
    }

    function _refreshReserveWindow(Payment storage p) private {
        p.windowStartBlock = head();
        uint64 deadline = uint64(block.timestamp) + REVIEW_TIMEOUT;
        if (deadline > p.reserveDeadline) p.reserveDeadline = deadline;
    }

    /// @notice Refresh an expired, unspent ask without paying again or changing its identity.
    /// The refreshed native window must mature for eight blocks before a verdict can be triggered.
    function renewVerdict(bytes32 jobId) external {
        (Payment storage p, bytes32 askId) = _unspentReserve(jobId);
        if (p.reserve == 0) revert NotReady();
        if (block.timestamp <= p.reserveDeadline) revert DeadlineNotReached();
        _refreshReserveWindow(p);
        emit VerdictRenewed(jobId, askId, p.windowStartBlock, p.reserveDeadline);
    }

    /// @notice Add to an unspent committed verdict's original-asset reserve without repaying
    /// the build or replacing the ask/candidate. Refreshing restarts the eight-block wait.
    function topUpReserve(bytes32 jobId, uint256 amount) external nonReentrant {
        (Payment storage p,) = _unspentReserve(jobId);
        if (candidateDigest[jobId] == bytes32(0)) revert NotReady();
        uint256 total = p.reserve + amount;
        if (amount == 0 || total > maxPrice) revert InvalidConfig();
        _refreshReserveWindow(p);
        p.reserve = total;
        reserved[p.asset] += amount;
        ExactStoreToken.pull(p.asset, msg.sender, amount);
        emit ReserveToppedUp(jobId, amount, total);
    }

    function _requesterJob(bytes32 jobId) private view returns (HookJobRequester.Job storage j) {
        j = jobs[jobId];
        if (msg.sender != j.requester) revert NotRequester();
    }

    function _unspentReserve(bytes32 jobId) private view returns (Payment storage p, bytes32 askId) {
        HookJobRequester.Job storage j = _requesterJob(jobId);
        p = payments[jobId];
        askId = jobAsk[jobId];
        if (
            j.status != HookJobRequester.JobStatus.Delivered || j.review != HookJobRequester.ReviewStatus.None
                || p.cancelled || asks[askId].intakeId != bytes32(0)
        ) revert NotReady();
    }

    function _refund(bytes32 jobId) private {
        Payment storage p = payments[jobId];
        uint256 amount = p.reserve;
        if (amount == 0) return;
        p.reserve = 0;
        // Reserved includes both unspent job reserves and withdrawable credits.
        refunds[p.asset][jobs[jobId].requester] += amount;
        emit ReserveRefunded(jobId, p.asset, jobs[jobId].requester, amount);
    }

    function withdrawRefund(address token) external nonReentrant {
        uint256 amount = refunds[token][msg.sender];
        refunds[token][msg.sender] = 0;
        reserved[token] -= amount;
        ExactStoreToken.push(token, msg.sender, amount);
        emit RefundWithdrawn(token, msg.sender, amount);
    }

    /// @notice Retry only an unanswered attempt, keeping the same immutable candidate. A fresh
    /// ask identity prevents replay from a previous attempt. A genuine NotPassed cannot retry.
    function retryVerdict(bytes32 jobId, uint256 reserve) external nonReentrant returns (bytes32 askId) {
        HookJobRequester.Job storage j = _requesterJob(jobId);
        if (j.review != HookJobRequester.ReviewStatus.Unanswered) revert NotReady();
        Payment storage p = payments[jobId];
        if (p.cancelled || reserve == 0 || reserve > maxPrice) revert InvalidConfig();
        uint64 currentBlock = head();
        _quote(p.intake, p.verdictAction, p.asset, reserve);
        ExactStoreToken.pull(p.asset, msg.sender, reserve);
        p.reserve = reserve;
        reserved[p.asset] += reserve;
        p.windowStartBlock = currentBlock;
        p.reserveDeadline = uint64(block.timestamp) + REVIEW_TIMEOUT;
        askId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        jobAsk[jobId] = askId;
        asks[askId].jobId = jobId;
        j.review = HookJobRequester.ReviewStatus.None;
        emit CandidateCommitted(jobId, askId, candidateDigest[jobId], candidates[jobId].reviewedCommit);
    }

    function reserveOf(bytes32 jobId) external view returns (address token, uint256 amount, bool cancelled) {
        Payment storage p = payments[jobId];
        return (p.asset, p.reserve, p.cancelled);
    }

    function reserveDeadline(bytes32 jobId) external view returns (uint64) {
        return payments[jobId].reserveDeadline;
    }

    function getJob(bytes32 jobId) external view returns (HookJobRequester.Job memory) {
        return jobs[jobId];
    }

    function getSpec(bytes32 jobId) external view returns (HookSpec memory) {
        return specs[jobId];
    }

    function getCandidate(bytes32 jobId) external view returns (Candidate memory) {
        return candidates[jobId];
    }

    function getAsk(bytes32 askId) external view returns (Ask memory) {
        return asks[askId];
    }

    function getOrigin(bytes32 askId) external view returns (bytes32 jobId, address intake_, uint256 chainId) {
        jobId = asks[askId].jobId;
        return (jobId, payments[jobId].intake, block.chainid);
    }

    function jobsOf(address creator) external view returns (bytes32[] memory) {
        return creatorJobs[creator];
    }

    function reviewVerifiedAt(bytes32 intakeId) public view returns (uint64) {
        return uint64(_askForIntake(intakeId).verification);
    }

    function reviewReceiptSignerEpoch(bytes32 intakeId) public view returns (uint32) {
        Ask storage a = _askForIntake(intakeId);
        return a.oracleUUID == bytes32(0) ? 0 : uint32(a.verification >> 64);
    }
    // An immutable historic mapping is needed after reviewOf is cleared.
    mapping(bytes32 => bytes32) private historicalAsk;

    function _askForIntake(bytes32 intakeId) private view returns (Ask storage) {
        return asks[historicalAsk[intakeId]];
    }

    function approvedArtifact(bytes32 jobId) external view returns (bytes32) {
        HookJobRequester.Job storage j = jobs[jobId];
        uint32 epoch = reviewReceiptSignerEpoch(j.reviewRequestId);
        if (
            j.review != HookJobRequester.ReviewStatus.Passed || epoch == 0 || revokedSignerEpochs[epoch] != bytes32(0)
                || revokedReviewReceipts[j.reviewRequestId]
        ) return bytes32(0);
        return candidateDigest[jobId];
    }

    // Protocol and panel settings are snapshotted per job. Window age is snapshotted at trigger.
    // Signer and epoch are snapshotted at trigger; current maxPrice caps new prepayments.
    function setProtocol(address intake_, address asset_, uint256 cap_, bytes32 jobAction_, bytes32 reviewAction_)
        external
        onlyOwner
        nonReentrant
    {
        if (
            intake_ == address(0) || asset_ == address(0) || cap_ == 0 || jobAction_ == bytes32(0)
                || reviewAction_ == bytes32(0)
        ) revert InvalidConfig();
        intake = IIntake(intake_);
        asset = asset_;
        maxPrice = cap_;
        jobAction = jobAction_;
        reviewAction = reviewAction_;
        emit ProtocolSet(intake_, asset_, cap_, jobAction_, reviewAction_);
    }

    function setPanel(uint16 panel, uint16 quorum, uint64 ageBlocks) external onlyOwner nonReentrant {
        if (panel < 2 || panel > 100 || quorum == 0 || quorum > panel || ageBlocks < codec.minimumWindowAgeBlocks()) {
            revert InvalidConfig();
        }
        minPanelSize = panel;
        minAgreed = quorum;
        maxWindowAgeBlocks = ageBlocks;
        emit PanelSet(panel, quorum, ageBlocks);
    }

    function setOracleSigner(address signer) external onlyOwner nonReentrant {
        _setOracleSigner(signer);
        ++oracleSignerEpoch;
        emit OracleSignerEpochStarted(oracleSignerEpoch, signer);
    }

    function revokeSignerEpoch(uint32 epoch, bytes32 incidentHash) external onlyOwner {
        if (
            epoch == 0 || epoch >= oracleSignerEpoch || incidentHash == bytes32(0)
                || revokedSignerEpochs[epoch] != bytes32(0)
        ) revert InvalidConfig();
        revokedSignerEpochs[epoch] = incidentHash;
        emit OracleSignerEpochRevoked(epoch, incidentHash);
    }

    function closeRevokedVerdict(bytes32 jobId) external onlyOwner {
        HookJobRequester.Job storage j = jobs[jobId];
        uint32 epoch = reviewReceiptSignerEpoch(j.reviewRequestId);
        bytes32 incident = revokedSignerEpochs[epoch];
        if (
            incident == bytes32(0)
                || (j.review != HookJobRequester.ReviewStatus.Passed
                    && j.review != HookJobRequester.ReviewStatus.NotPassed)
        ) revert Revoked();
        revokedReviewReceipts[j.reviewRequestId] = true;
        j.review = HookJobRequester.ReviewStatus.Unanswered;
        emit ReviewReceiptRevoked(jobId, j.reviewRequestId, epoch, incident);
    }

    /// @notice Exceptional owner recovery only. Cannot erase any verified true or false answer.
    function confirmReviewExpiry(bytes32 intakeId) external onlyOwner {
        bytes32 askId = reviewOf[intakeId];
        Ask storage a = asks[askId];
        if (askId == bytes32(0) || a.oracleUUID != bytes32(0)) revert UnknownOrSettled();
        if (block.timestamp <= uint256(a.deadline) + ISSUED_AT_TOLERANCE + REVIEW_TIMEOUT) revert DeadlineNotReached();
        delete reviewOf[intakeId];
        jobs[a.jobId].review = HookJobRequester.ReviewStatus.Unanswered;
        emit VerdictUnanswered(askId, "owner confirmed expiry");
    }

    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || amount > ExactStoreToken.balance(token, address(this)) - reserved[token]) {
            revert EscrowProtected();
        }
        ExactStoreToken.push(token, to, amount);
    }

    function _quote(address at, bytes32 action, address token, uint256 cap) private view returns (uint256 price) {
        // New prepayments/retries clamp cap to maxPrice at the caller. A previously funded
        // verdict keeps its reserved cap even if the owner subsequently lowers maxPrice.
        price = IIntake(at).priceOf(action, token);
        if (price == 0) revert NotConfigured();
        if (price > cap) revert PriceExceeded(price, cap);
    }

    function _recordId(bytes32 id) private {
        if (id == bytes32(0) || usedIntakeRequestIds[id]) revert DuplicateId();
        usedIntakeRequestIds[id] = true;
    }

    function _request(
        address at,
        address token,
        bytes32 action,
        bytes memory body,
        bytes4 success,
        bytes4 failure,
        uint256 price
    ) private returns (bytes32 id) {
        if (body.length > 16384) revert InvalidConfig();
        uint256 beforeBalance = ExactStoreToken.balance(token, address(this));
        ExactStoreToken.call(token, abi.encodeWithSelector(0x095ea7b3, at, 0));
        ExactStoreToken.call(token, abi.encodeWithSelector(0x095ea7b3, at, price));
        id = IIntake(at)
            .requestWithFailure(action, body, IIntake.Callback(address(this), success), failure, token, price);
        ExactStoreToken.call(token, abi.encodeWithSelector(0x095ea7b3, at, 0));
        if (ExactStoreToken.balance(token, address(this)) != beforeBalance - price) revert InexactSpend();
    }
}

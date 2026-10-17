// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreAdmin} from "../store/StoreAdmin.sol";
import {HookJobRequester} from "../imd/HookJobRequester.sol";
import {HookMiner} from "./HookMiner.sol";
import {AcceptedArtifact} from "./AcceptedArtifact.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Readback surface every generated hook must expose (BoundedSwapHook already does).
interface IGeneratedHook {
    function poolManager() external view returns (address);
    function getHookPermissions() external view returns (Hooks.Permissions memory);
}

/// @title Oracle-gated CREATE2 deployer for generated Uniswap v4 hooks
/// @notice Deploys an arbitrary generated hook only when ALL of these hold onchain, in this call:
/// 1. the `HookJobRequester` job is `Delivered` and its review is `Passed` by the oracle-signed
///    verdict the requester verified (an Intake completion, a URL or an owner allowlist is not);
/// 2. the caller supplies the control-plane completion snapshot: its keccak256 equals the
///    stored `resultHash`; its accepted source bundle and unique accepted approval file commit
///    to this exact artifact (SHA-256 file hashes, never substring matching);
/// 3. the artifact digest commits to the job (whose result hash commits to the document naming it), source and build identity, the creation code,
///    constructor arguments, expected runtime code hash, chain, this deployer, the PoolManager and
///    its code hash, and the callback permission mask;
/// 4. the chain/PoolManager pair is enabled here; on production chains only the first-party pinned
///    manager address and code hash can ever be enabled;
/// 5. the CREATE2 address carries exactly the permission bits, and readback after deployment
///    matches runtime code hash, `poolManager()` and `getHookPermissions()`.
/// Each job deploys at most once and each artifact digest at most once.
/// @dev The requester is immutable: the owner of this contract cannot point it at another verdict
/// source. The requester's own owner still binds review asks and sets the oracle signer (see
/// docs/GATED_DEPLOYMENT.md). This contract never creates tokens, pools or managers.
contract GatedHookDeployer is StoreAdmin {
    struct Artifact {
        bytes32 jobRequestId;
        bytes32 sourceHash;
        bytes32 sourceSubmissionHash;
        bytes32 reviewSubmissionHash;
        bytes32 evidenceHash;
        bytes32 buildHash;
        bytes32 creationCodeHash;
        bytes32 constructorArgsHash;
        bytes32 runtimeCodeHash;
        uint256 chainId;
        address deployer;
        address poolManager;
        bytes32 poolManagerCodeHash;
        uint160 permissions;
    }

    struct Manager {
        bool enabled;
        bytes32 codeHash;
    }

    bytes32 public constant ARTIFACT_TYPEHASH = keccak256(
        "HookArtifactV2(bytes32 jobRequestId,bytes32 sourceHash,bytes32 sourceSubmissionHash,bytes32 reviewSubmissionHash,bytes32 evidenceHash,bytes32 buildHash,bytes32 creationCodeHash,bytes32 constructorArgsHash,bytes32 runtimeCodeHash,uint256 chainId,address deployer,address poolManager,bytes32 poolManagerCodeHash,uint160 permissions)"
    );
    bytes public constant ARTIFACT_MARKER = '"hooksStoreArtifact":"0x';
    uint256 public constant MAX_RESULT_DOCUMENT_BYTES = 12288;
    uint64 public constant MIN_JOB_AGE = 1 days;
    uint64 public constant MAX_JOB_AGE = 180 days;
    uint256 internal constant READBACK_GAS = 100_000;

    // First-party pins: docs.uniswap.org/contracts/v4/deployments (address) and eth_getCode
    // readback on 2026-10-17 (code hash), recorded in docs/checks/gated-deployment/managers.json.
    address internal constant ETH_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant ETH_MANAGER_HASH = 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    address internal constant BASE_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    bytes32 internal constant BASE_MANAGER_HASH = 0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6;
    address internal constant RH_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 internal constant RH_MANAGER_HASH = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    address internal constant SEPOLIA_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    bytes32 internal constant SEPOLIA_MANAGER_HASH = 0x09930125a49f5b95caf8052991cc14d1240dca8b43f42b899115b86867e4bce1;

    HookJobRequester public immutable requester;
    uint64 public maxJobAge = 30 days;
    mapping(address manager => Manager) public managers;
    mapping(bytes32 jobRequestId => address hook) public deployedHookOf;
    mapping(bytes32 artifactDigest => bool) public usedArtifact;
    mapping(address hook => bytes32 artifactDigest) public artifactOf;
    uint256 private _lock = 1;

    error Reentrancy();
    error InvalidRequester();
    error UnsupportedChain(uint256 chainId);
    error ManagerNotPinned(address manager, bytes32 codeHash);
    error ManagerNotEnabled(address manager);
    error ManagerCodeHashMismatch(bytes32 expected, bytes32 actual);
    error InvalidJobAge(uint64 age);
    error NotJobRequester();
    error JobNotDelivered(bytes32 jobRequestId);
    error ReviewNotPassed(bytes32 jobRequestId);
    error ReviewRevoked(bytes32 intakeRequestId);
    error ApprovalStale(uint64 verifiedAt, uint64 maxJobAge);
    error ResultHashMismatch();
    error ResultDocumentTooLong(uint256 length);
    error ArtifactNotInResult(bytes32 digest);
    error WrongChain(uint256 expected, uint256 actual);
    error WrongDeployer(address expected);
    error CreationCodeMismatch();
    error ConstructorArgsMismatch();
    error InvalidPermissions(uint160 permissions);
    error PermissionBitsMismatch(address hook, uint160 expected);
    error PredictionMismatch(address predicted, address expected);
    error AddressOccupied(address hook);
    error AlreadyDeployed(bytes32 jobRequestId, address hook);
    error ArtifactReplayed(bytes32 digest);
    error CreateFailed();
    error RuntimeCodeMismatch(bytes32 expected, bytes32 actual);
    error ReadbackFailed(bytes4 what);

    event ManagerSet(uint256 indexed chainId, address indexed manager, bytes32 codeHash, bool enabled);
    event MaxJobAgeSet(uint64 maxJobAge);
    event GatedHookDeployed(
        bytes32 indexed jobRequestId,
        address indexed hook,
        bytes32 indexed artifactDigest,
        address poolManager,
        uint160 permissions,
        bytes32 salt
    );

    /// @dev No external call: launch checks run constructors on an empty chain.
    constructor(address owner_, HookJobRequester requester_) StoreAdmin(owner_) {
        if (address(requester_) == address(0)) revert InvalidRequester();
        requester = requester_;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ---------------------------------------------------------------- policy

    /// @notice The pinned production manager for a chain, or zero where any reviewed manager may be
    /// owner-enabled (local 31337 and the named testnets), or reverts for an unsupported chain.
    function pinnedManager(uint256 id) public pure returns (address manager, bytes32 codeHash, bool pinned) {
        if (id == 1) return (ETH_MANAGER, ETH_MANAGER_HASH, true);
        if (id == 8453) return (BASE_MANAGER, BASE_MANAGER_HASH, true);
        if (id == 4663) return (RH_MANAGER, RH_MANAGER_HASH, true);
        if (id == 11155111) return (SEPOLIA_MANAGER, SEPOLIA_MANAGER_HASH, true);
        if (id == 31337 || id == 84532 || id == 46630) return (address(0), bytes32(0), false);
        revert UnsupportedChain(id);
    }

    /// @notice Enables or disables a manager on this chain. On a pinned chain only the pinned pair
    /// can be enabled. Enabling also requires the live code hash to match now.
    function setManager(address manager, bytes32 codeHash, bool enabled) external onlyOwner {
        (address pin, bytes32 pinHash, bool pinned) = pinnedManager(block.chainid);
        if (enabled) {
            if (pinned && (manager != pin || codeHash != pinHash)) revert ManagerNotPinned(manager, codeHash);
            if (manager.code.length == 0 || manager.codehash != codeHash) {
                revert ManagerCodeHashMismatch(codeHash, manager.codehash);
            }
        }
        managers[manager] = Manager(enabled, enabled ? codeHash : bytes32(0));
        emit ManagerSet(block.chainid, manager, codeHash, enabled);
    }

    function setMaxJobAge(uint64 age) external onlyOwner {
        if (age < MIN_JOB_AGE || age > MAX_JOB_AGE) revert InvalidJobAge(age);
        maxJobAge = age;
        emit MaxJobAgeSet(age);
    }

    // ---------------------------------------------------------------- artifact identity

    function artifactDigest(Artifact memory a) public pure returns (bytes32) {
        return keccak256(abi.encode(ARTIFACT_TYPEHASH, a));
    }

    /// @notice Legacy display helper only. A marker is never deployment evidence.
    function artifactMarker(Artifact memory a) public pure returns (bytes memory) {
        return bytes.concat(ARTIFACT_MARKER, _hex(artifactDigest(a)), '"');
    }

    /// @notice Exact bytes the publication step emits after accepted independent review.
    /// No trailing newline. The snapshot must commit its SHA-256 under files, plus the source bundle.
    function approvalDocument(Artifact memory a) public pure returns (bytes memory) {
        return AcceptedArtifact.approvalDocument(artifactDigest(a));
    }

    /// @notice Canonical worker publication describing the exact reviewed build and review.
    /// evidenceHash is omitted from its own preimage to avoid circular hashing. Publication is
    /// not oracle approval; the signed, bound review must independently validate these claims.
    function evidenceDocument(Artifact memory a) public pure returns (bytes memory) {
        bytes32 saved = a.evidenceHash;
        a.evidenceHash = bytes32(0);
        bytes32 build = artifactDigest(a);
        a.evidenceHash = saved;
        return AcceptedArtifact.evidenceDocument(build, a.sourceSubmissionHash, a.reviewSubmissionHash);
    }

    /// @notice Automatic Intake-to-oracle binding is unavailable in the documented protocol.
    /// This deployment tool cannot make owner binding permissionless or authenticate HTTP metadata.
    function automaticBindingSupported() external pure returns (bool) {
        return false;
    }

    function permissionsToFlags(Hooks.Permissions memory p) public pure returns (uint160 f) {
        if (p.beforeInitialize) f |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) f |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) f |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) f |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) f |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) f |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) f |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) f |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) f |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) f |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) f |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) f |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) f |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) f |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }

    /// @notice A mask is deployable when nonzero, within the 14 hook bits, and every return-delta bit
    /// has its base callback (the PoolManager's own `isValidHookAddress` rule).
    function validPermissions(uint160 flags) public pure returns (bool) {
        if (flags == 0 || flags & ~Hooks.ALL_HOOK_MASK != 0) return false;
        return Hooks.isValidHookAddress(IHooks(address(flags)), 3000);
    }

    function predict(bytes32 initCodeHash, bytes32 salt) public view returns (address) {
        return HookMiner.predict(address(this), salt, initCodeHash);
    }

    /// @notice Paginated salt search for this deployer; run as eth_call, never as a transaction.
    function mine(bytes32 initCodeHash, uint160 flags, uint256 startNonce, uint256 attempts)
        external
        view
        returns (HookMiner.Result memory)
    {
        if (!validPermissions(flags)) revert InvalidPermissions(flags);
        return HookMiner.mine(address(this), initCodeHash, flags, startNonce, attempts);
    }

    // ---------------------------------------------------------------- gate

    /// @notice Every check `deploy` makes before CREATE2, as a view. Returns the predicted address.
    function check(
        Artifact calldata a,
        bytes calldata resultDocument,
        bytes calldata creationCode,
        bytes calldata constructorArgs,
        bytes32 salt,
        address caller
    ) public view returns (address hook, bytes32 digest) {
        _checkContext(a, creationCode, constructorArgs);
        digest = _checkApproval(a, resultDocument, caller);
        hook = predict(keccak256(bytes.concat(creationCode, constructorArgs)), salt);
        if (uint160(hook) & Hooks.ALL_HOOK_MASK != a.permissions) revert PermissionBitsMismatch(hook, a.permissions);
        if (hook.code.length != 0) revert AddressOccupied(hook);
    }

    function _checkContext(Artifact calldata a, bytes calldata creationCode, bytes calldata constructorArgs)
        internal
        view
    {
        if (a.chainId != block.chainid) revert WrongChain(a.chainId, block.chainid);
        pinnedManager(block.chainid);
        if (a.deployer != address(this)) revert WrongDeployer(address(this));
        Manager memory m = managers[a.poolManager];
        if (!m.enabled) revert ManagerNotEnabled(a.poolManager);
        if (m.codeHash != a.poolManagerCodeHash || a.poolManager.codehash != a.poolManagerCodeHash) {
            revert ManagerCodeHashMismatch(a.poolManagerCodeHash, a.poolManager.codehash);
        }
        if (!validPermissions(a.permissions)) revert InvalidPermissions(a.permissions);
        if (keccak256(creationCode) != a.creationCodeHash) revert CreationCodeMismatch();
        if (keccak256(constructorArgs) != a.constructorArgsHash) revert ConstructorArgsMismatch();
    }

    function _checkApproval(Artifact calldata a, bytes calldata resultDocument, address caller)
        internal
        view
        returns (bytes32 digest)
    {
        HookJobRequester.Job memory job = requester.getJob(a.jobRequestId);
        if (caller != job.requester) revert NotJobRequester();
        if (job.status != HookJobRequester.JobStatus.Delivered) revert JobNotDelivered(a.jobRequestId);
        if (job.review != HookJobRequester.ReviewStatus.Passed) revert ReviewNotPassed(a.jobRequestId);
        if (requester.revokedReviewReceipts(job.reviewRequestId)) revert ReviewRevoked(job.reviewRequestId);
        uint32 epoch = requester.reviewReceiptSignerEpoch(job.reviewRequestId);
        if (epoch == 0 || requester.revokedSignerEpochs(epoch) != bytes32(0)) {
            revert ReviewRevoked(job.reviewRequestId);
        }
        uint64 verifiedAt = requester.reviewVerifiedAt(job.reviewRequestId);
        // Freshness is anchored at authenticated receipt, never job opening or delayed owner binding.
        if (verifiedAt == 0 || block.timestamp > uint256(verifiedAt) + maxJobAge) {
            revert ApprovalStale(verifiedAt, maxJobAge);
        }
        if (keccak256(resultDocument) != job.resultHash) revert ResultHashMismatch();
        if (resultDocument.length > MAX_RESULT_DOCUMENT_BYTES) revert ResultDocumentTooLong(resultDocument.length);

        digest = artifactDigest(a);
        bytes memory evidence = evidenceDocument(a);
        if (
            a.buildHash == bytes32(0) || a.reviewSubmissionHash == bytes32(0) || a.sourceSubmissionHash == bytes32(0)
                || a.reviewSubmissionHash == a.sourceSubmissionHash || a.evidenceHash != sha256(evidence)
                || !AcceptedArtifact.verify(
                    resultDocument,
                    digest,
                    AcceptedArtifact.Binding(a.sourceHash, a.sourceSubmissionHash, a.evidenceHash, evidence.length)
                )
        ) {
            revert ArtifactNotInResult(digest);
        }
        if (deployedHookOf[a.jobRequestId] != address(0)) {
            revert AlreadyDeployed(a.jobRequestId, deployedHookOf[a.jobRequestId]);
        }
        if (usedArtifact[digest]) revert ArtifactReplayed(digest);
    }

    /// @notice The only gated entry point. Callable by the job's requester; the approval is
    /// consumed before CREATE2 so a constructor cannot reuse it, and every failure reverts all.
    function deploy(
        Artifact calldata a,
        bytes calldata resultDocument,
        bytes calldata creationCode,
        bytes calldata constructorArgs,
        bytes32 salt,
        address expectedHook
    ) external nonReentrant returns (address hook) {
        bytes32 digest;
        (hook, digest) = check(a, resultDocument, creationCode, constructorArgs, salt, msg.sender);
        if (hook != expectedHook) revert PredictionMismatch(hook, expectedHook);
        deployedHookOf[a.jobRequestId] = hook;
        usedArtifact[digest] = true;
        artifactOf[hook] = digest;
        _create2(bytes.concat(creationCode, constructorArgs), salt, hook);
        verifyDeployment(hook, a);
        _emitDeployed(a, hook, digest, salt);
    }

    function _create2(bytes memory init, bytes32 salt, address expected) internal {
        address created;
        assembly ("memory-safe") {
            created := create2(0, add(init, 0x20), mload(init), salt)
        }
        if (created == address(0)) revert CreateFailed();
        if (created != expected) revert PredictionMismatch(created, expected);
    }

    function _emitDeployed(Artifact calldata a, address hook, bytes32 digest, bytes32 salt) internal {
        emit GatedHookDeployed(a.jobRequestId, hook, digest, a.poolManager, a.permissions, salt);
    }

    /// @notice Code and configuration readback, usable by anyone after deployment.
    function verifyDeployment(address hook, Artifact calldata a) public view {
        if (artifactOf[hook] != artifactDigest(a)) revert ArtifactReplayed(artifactOf[hook]);
        if (uint160(hook) & Hooks.ALL_HOOK_MASK != a.permissions) revert PermissionBitsMismatch(hook, a.permissions);
        if (hook.codehash != a.runtimeCodeHash) revert RuntimeCodeMismatch(a.runtimeCodeHash, hook.codehash);
        (bool ok, bytes memory ret) = hook.staticcall{gas: READBACK_GAS}(abi.encodeCall(IGeneratedHook.poolManager, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != a.poolManager) {
            revert ReadbackFailed(IGeneratedHook.poolManager.selector);
        }
        (ok, ret) = hook.staticcall{gas: READBACK_GAS}(abi.encodeCall(IGeneratedHook.getHookPermissions, ()));
        if (!ok || ret.length != 14 * 32 || permissionsToFlags(abi.decode(ret, (Hooks.Permissions))) != a.permissions) {
            revert ReadbackFailed(IGeneratedHook.getHookPermissions.selector);
        }
    }

    // ---------------------------------------------------------------- internals

    function _hex(bytes32 value) internal pure returns (bytes memory out) {
        return AcceptedArtifact.hexHash(value);
    }
}

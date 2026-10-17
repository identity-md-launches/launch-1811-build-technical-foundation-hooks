// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {GatedHookDeployer} from "../src/deployment/GatedHookDeployer.sol";
import {AcceptedArtifact} from "../src/deployment/AcceptedArtifact.sol";
import {HookMiner} from "../src/deployment/HookMiner.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {BoundedSwapHook} from "../src/BoundedSwapHook.sol";
import {HookSpec, HookSpecLib} from "../src/HookSpec.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {
    GeneratedHook,
    LyingManagerHook,
    LyingPermissionsHook,
    ReenteringHook,
    EmptyRuntimeHook,
    RevertingHook,
    EnvironmentDependentHook
} from "./helpers/GeneratedHooks.sol";

contract GatedHookDeployerTest is HookJobRequesterFixture {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant FLAGS = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_DONATE_FLAG;

    PoolManager internal manager;
    GatedHookDeployer internal deployer;

    struct Case {
        bytes32 jobId;
        GatedHookDeployer.Artifact a;
        bytes doc;
        bytes code;
        bytes args;
        bytes32 salt;
        address hook;
    }

    function setUp() public override {
        super.setUp();
        manager = new PoolManager(owner);
        deployer = new GatedHookDeployer(owner, requester);
        vm.prank(owner);
        deployer.setManager(address(manager), address(manager).codehash, true);
    }

    // ---------------------------------------------------------------- helpers

    function _artifact(bytes32 jobId, bytes memory code, bytes memory args, bytes32 runtimeHash, uint160 flags)
        internal
        view
        returns (GatedHookDeployer.Artifact memory a)
    {
        a = GatedHookDeployer.Artifact({
            jobRequestId: jobId,
            sourceHash: sha256("generated source bundle"),
            sourceSubmissionHash: sha256("accepted source submission"),
            reviewSubmissionHash: sha256("accepted independent review submission"),
            evidenceHash: bytes32(0),
            buildHash: keccak256("solc 0.8.26 cancun optimizer 200"),
            creationCodeHash: keccak256(code),
            constructorArgsHash: keccak256(args),
            runtimeCodeHash: runtimeHash,
            chainId: block.chainid,
            deployer: address(deployer),
            poolManager: address(manager),
            poolManagerCodeHash: address(manager).codehash,
            permissions: flags
        });
        a.evidenceHash = sha256(deployer.evidenceDocument(a));
    }

    function _doc(GatedHookDeployer.Artifact memory a) internal view returns (bytes memory) {
        bytes memory approval = deployer.approvalDocument(a);
        return bytes.concat(
            '{"jobId":"d8ec4ec9-b939-4ff8-8ce1-fad7a6a69bd9","state":"completed","complete":true,',
            '"source":[{"hash":"',
            AcceptedArtifact.hexHash(a.sourceHash),
            '","submissionHash":"',
            AcceptedArtifact.hexHash(a.sourceSubmissionHash),
            '"}],',
            '"files":[{"name":"hooksStoreApproval","path":"artifacts/hooks-store-approval.json",',
            '"mediaType":"application/json","hash":"',
            AcceptedArtifact.hexHash(sha256(approval)),
            '","bytes":',
            bytes(vm.toString(approval.length)),
            ',"submissionHash":"',
            AcceptedArtifact.hexHash(sha256("accepted publication submission")),
            '"},{"name":"hooksStoreEvidence","path":"artifacts/hooks-store-evidence.json",',
            '"mediaType":"application/json","hash":"',
            AcceptedArtifact.hexHash(a.evidenceHash),
            '","bytes":',
            bytes(vm.toString(deployer.evidenceDocument(a).length)),
            ',"submissionHash":"',
            AcceptedArtifact.hexHash(sha256("accepted publication submission")),
            '"}]}'
        );
    }

    function _mine(bytes memory init, uint160 flags) internal view returns (bytes32 salt, address hook) {
        uint256 start;
        for (uint256 page; page < 16; ++page) {
            HookMiner.Result memory r = deployer.mine(keccak256(init), flags, start, 131072);
            if (r.found) return (r.salt, r.hook);
            start = r.nextNonce;
        }
        revert("exhausted");
    }

    /// Opens a job, delivers a result naming the artifact; no review yet.
    function _case(bytes memory code, bytes memory args, bytes32 runtimeHash, uint160 flags)
        internal
        returns (Case memory c)
    {
        c.jobId = _open();
        c.code = code;
        c.args = args;
        c.a = _artifact(c.jobId, code, args, runtimeHash, flags);
        c.doc = _doc(c.a);
        assertTrue(intake.complete(c.jobId, abi.encode(c.jobId, keccak256(c.doc), "ipfs://result")));
        (c.salt, c.hook) = _mine(bytes.concat(code, args), flags);
    }

    function _generic(uint160 flags) internal returns (Case memory) {
        return _case(
            type(GeneratedHook).creationCode,
            abi.encode(address(manager), flags),
            keccak256(type(GeneratedHook).runtimeCode),
            flags
        );
    }

    /// Bind first, then the one-shot signed callback.
    function _pass(bytes32 jobId, bool passed) internal returns (bytes32 intakeId) {
        intakeId = _requestReview(jobId);
        OracleAttestation.Attestation memory att = _attestation(intakeId, passed);
        assertTrue(intake.complete(intakeId, abi.encode(intakeId, att, _sign(att, signerKey))));
    }

    /// Signed callback first (retained receipt), then the owner's binding finalizes it.
    function _passReceiptFirst(bytes32 jobId) internal returns (bytes32 intakeId) {
        vm.prank(creator);
        intakeId = requester.requestReview(jobId, 0.5 ether);
        OracleAttestation.Attestation memory att = _attestation(intakeId, true);
        assertTrue(intake.complete(intakeId, abi.encode(intakeId, att, _sign(att, signerKey))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        _bind(intakeId);
    }

    function _deploy(Case memory c) internal returns (address) {
        vm.prank(creator);
        return deployer.deploy(c.a, c.doc, c.code, c.args, c.salt, c.hook);
    }

    function _expectDeployRevert(Case memory c, bytes memory err) internal {
        vm.prank(creator);
        vm.expectRevert(err);
        deployer.deploy(c.a, c.doc, c.code, c.args, c.salt, c.hook);
    }

    // ---------------------------------------------------------------- success

    function testGeneratedHookDeploysAfterBindThenCallback() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        address hook = _deploy(c);
        assertEq(hook, c.hook);
        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertEq(GeneratedHook(hook).poolManager(), address(manager));
        assertEq(deployer.deployedHookOf(c.jobId), hook);
        assertEq(deployer.artifactOf(hook), deployer.artifactDigest(c.a));
        deployer.verifyDeployment(hook, c.a);
    }

    function testGeneratedHookDeploysAfterCallbackThenBind() public {
        Case memory c = _generic(FLAGS);
        _passReceiptFirst(c.jobId);
        assertEq(uint8(_review(c.jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertEq(_deploy(c), c.hook);
    }

    function testFuzzAnyValidMaskDeploys(uint16 raw) public {
        uint160 flags = uint160(raw) & Hooks.ALL_HOOK_MASK;
        vm.assume(deployer.validPermissions(flags));
        Case memory c = _generic(flags);
        _pass(c.jobId, true);
        address hook = _deploy(c);
        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, flags);
    }

    function testBoundedSwapHookDeploysThroughGateAndInitializesPool() public {
        HookSpec memory spec = HookSpec({
            schemaVersion: 1,
            templateId: HookSpecLib.TEMPLATE_ID,
            chainId: block.chainid,
            poolManager: address(manager),
            poolManagerCodeHash: address(manager).codehash,
            permissions: HookSpecLib.PERMISSIONS,
            maxSpecifiedAmount: 1_000_000
        });
        Case memory c = _case(
            type(BoundedSwapHook).creationCode,
            abi.encode(spec),
            keccak256(type(BoundedSwapHook).runtimeCode),
            HookSpecLib.PERMISSIONS
        );
        _pass(c.jobId, true);
        address hook = _deploy(c);
        TestToken t0 = new TestToken("A", 18);
        TestToken t1 = new TestToken("B", 18);
        (address lo, address hi) = address(t0) < address(t1) ? (address(t0), address(t1)) : (address(t1), address(t0));
        PoolKey memory key = PoolKey(Currency.wrap(lo), Currency.wrap(hi), 3000, 60, IHooks(hook));
        manager.initialize(key, 79228162514264337593543950336);
        assertTrue(BoundedSwapHook(hook).initialized(_id(key)));
    }

    function _id(PoolKey memory key) internal pure returns (PoolId) {
        return key.toId();
    }

    function testCheckViewMatchesDeploy() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        (address predicted, bytes32 digest) = deployer.check(c.a, c.doc, c.code, c.args, c.salt, creator);
        assertEq(predicted, c.hook);
        assertEq(digest, deployer.artifactDigest(c.a));
    }

    // ---------------------------------------------------------------- missing / failed reviews

    function testNoReviewRefused() public {
        Case memory c = _generic(FLAGS);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
    }

    function testPendingReviewRefused() public {
        Case memory c = _generic(FLAGS);
        _requestReview(c.jobId);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
    }

    function testRetainedUnboundReceiptIsNotApproval() public {
        Case memory c = _generic(FLAGS);
        vm.prank(creator);
        bytes32 intakeId = requester.requestReview(c.jobId, 0.5 ether);
        OracleAttestation.Attestation memory att = _attestation(intakeId, true);
        assertTrue(intake.complete(intakeId, abi.encode(intakeId, att, _sign(att, signerKey))));
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
    }

    function testNotPassedRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, false);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
    }

    function testUnansweredReviewRefused() public {
        Case memory c = _generic(FLAGS);
        bytes32 intakeId = _requestReview(c.jobId);
        assertTrue(intake.fail(intakeId, 2, "disagreed", 3, 7));
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
    }

    function testForgedSignatureNeverApproves() public {
        Case memory c = _generic(FLAGS);
        bytes32 intakeId = _requestReview(c.jobId);
        OracleAttestation.Attestation memory att = _attestation(intakeId, true);
        // one-shot callback with a wrong key is swallowed by the Intake's try and records nothing
        intake.complete(intakeId, abi.encode(intakeId, att, _sign(att, uint256(keccak256("forger")))));
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
    }

    function testUndeliveredJobRefused() public {
        bytes32 jobId = _open();
        GatedHookDeployer.Artifact memory a =
            _artifact(jobId, type(GeneratedHook).creationCode, abi.encode(address(manager), FLAGS), bytes32(0), FLAGS);
        bytes memory doc = _doc(a);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.JobNotDelivered.selector, jobId));
        deployer.deploy(a, doc, type(GeneratedHook).creationCode, abi.encode(address(manager), FLAGS), 0, address(0));
    }

    function testRevokedSignerEpochBlocksRetainedVerdict() public {
        Case memory c = _generic(FLAGS);
        _passReceiptFirst(c.jobId);
        vm.startPrank(owner);
        requester.setOracleSigner(makeAddr("rotated signer"));
        requester.revokeSignerEpoch(1, keccak256("incident"));
        vm.stopPrank();
        bytes32 intakeId = requester.getJob(c.jobId).reviewRequestId;
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewRevoked.selector, intakeId));
    }

    // ---------------------------------------------------------------- substitution

    function testSubstitutedCreationCodeRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        c.code = type(LyingManagerHook).creationCode;
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.CreationCodeMismatch.selector));
    }

    function testSubstitutedConstructorArgsRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        c.args = abi.encode(address(manager), FLAGS | Hooks.BEFORE_SWAP_FLAG);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ConstructorArgsMismatch.selector));
    }

    function testArtifactFieldEditNotInReviewedResult() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        c.a.sourceHash = keccak256("other source");
        _expectDeployRevert(
            c, abi.encodeWithSelector(GatedHookDeployer.ArtifactNotInResult.selector, deployer.artifactDigest(c.a))
        );
        c.a.sourceHash = sha256("generated source bundle");
        c.a.buildHash = keccak256("other build");
        _expectDeployRevert(
            c, abi.encodeWithSelector(GatedHookDeployer.ArtifactNotInResult.selector, deployer.artifactDigest(c.a))
        );
    }

    function testForgedResultDocumentRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        c.doc = bytes.concat(c.doc, " ");
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ResultHashMismatch.selector));
    }

    function testOtherJobsApprovalCannotBeBorrowed() public {
        Case memory approved = _generic(FLAGS);
        _pass(approved.jobId, true);
        Case memory unapproved = _generic(FLAGS | Hooks.AFTER_SWAP_FLAG);
        // the unapproved job's artifact presented with the approved job id: its result names a different digest
        unapproved.a.jobRequestId = approved.jobId;
        unapproved.doc = approved.doc;
        _expectDeployRevert(
            unapproved,
            abi.encodeWithSelector(
                GatedHookDeployer.ArtifactNotInResult.selector, deployer.artifactDigest(unapproved.a)
            )
        );
    }

    function testOnlyJobRequesterMayDeploy() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        vm.prank(stranger);
        vm.expectRevert(GatedHookDeployer.NotJobRequester.selector);
        deployer.deploy(c.a, c.doc, c.code, c.args, c.salt, c.hook);
    }

    // ---------------------------------------------------------------- wrong context

    function testWrongChainRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        vm.chainId(84532);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.WrongChain.selector, 31337, 84532));
    }

    function testUnsupportedChainRefused() public {
        vm.chainId(10);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.UnsupportedChain.selector, 10));
        deployer.setManager(address(manager), address(manager).codehash, true);
    }

    function testWrongDeployerRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        GatedHookDeployer other = new GatedHookDeployer(owner, requester);
        vm.prank(owner);
        other.setManager(address(manager), address(manager).codehash, true);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.WrongDeployer.selector, address(other)));
        other.deploy(c.a, c.doc, c.code, c.args, c.salt, c.hook);
    }

    function testWrongManagerRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        PoolManager rogue = new PoolManager(stranger);
        c.a.poolManager = address(rogue);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ManagerNotEnabled.selector, address(rogue)));
    }

    function testDisabledManagerRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        vm.prank(owner);
        deployer.setManager(address(manager), bytes32(0), false);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ManagerNotEnabled.selector, address(manager)));
    }

    function testManagerCodeHashMismatchRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        c.a.poolManagerCodeHash = keccak256("other");
        _expectDeployRevert(
            c,
            abi.encodeWithSelector(
                GatedHookDeployer.ManagerCodeHashMismatch.selector, c.a.poolManagerCodeHash, address(manager).codehash
            )
        );
    }

    function testWrongMaskRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        // the salt mined for FLAGS does not give a FLAGS|BEFORE_SWAP address and the digest differs
        c.a.permissions = FLAGS | Hooks.BEFORE_SWAP_FLAG;
        _expectDeployRevert(
            c, abi.encodeWithSelector(GatedHookDeployer.ArtifactNotInResult.selector, deployer.artifactDigest(c.a))
        );
    }

    function testUnminedSaltRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        bytes32 salt = bytes32(uint256(c.salt) + 1);
        address predicted = deployer.predict(keccak256(bytes.concat(c.code, c.args)), salt);
        vm.assume(uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS);
        c.salt = salt;
        _expectDeployRevert(
            c, abi.encodeWithSelector(GatedHookDeployer.PermissionBitsMismatch.selector, predicted, FLAGS)
        );
    }

    function testInvalidMasksRefused() public {
        assertFalse(deployer.validPermissions(0));
        assertFalse(deployer.validPermissions(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        assertFalse(deployer.validPermissions(uint160(1) << 14));
        assertTrue(deployer.validPermissions(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.InvalidPermissions.selector, uint160(0)));
        deployer.mine(bytes32(0), 0, 0, 1);
    }

    function testExpectedHookMismatchRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        address wanted = c.hook;
        c.hook = address(1);
        _expectDeployRevert(
            c, abi.encodeWithSelector(GatedHookDeployer.PredictionMismatch.selector, wanted, address(1))
        );
    }

    // ---------------------------------------------------------------- collisions / replay / staleness

    function testOccupiedAddressRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        vm.etch(c.hook, hex"00");
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.AddressOccupied.selector, c.hook));
    }

    function testJobReplayRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        address hook = _deploy(c);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.AlreadyDeployed.selector, c.jobId, hook));
        // a fresh salt for the same job is still one job, one deployment
        (bytes32 salt2, address hook2) = _mine2(c);
        c.salt = salt2;
        c.hook = hook2;
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.AlreadyDeployed.selector, c.jobId, hook));
    }

    function _mine2(Case memory c) internal view returns (bytes32, address) {
        HookMiner.Result memory r =
            deployer.mine(keccak256(bytes.concat(c.code, c.args)), c.a.permissions, uint256(c.salt) + 1, 131072);
        if (!r.found) {
            r = deployer.mine(keccak256(bytes.concat(c.code, c.args)), c.a.permissions, r.nextNonce, 131072);
        }
        return (r.salt, r.hook);
    }

    function testStaleApprovalRefused() public {
        Case memory c = _generic(FLAGS);
        _pass(c.jobId, true);
        uint64 openedAt = requester.getJob(c.jobId).openedAt;
        vm.warp(uint256(openedAt) + 30 days + 1);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ApprovalStale.selector, openedAt, 30 days));
    }

    function testMaxJobAgeBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.InvalidJobAge.selector, uint64(1 hours)));
        deployer.setMaxJobAge(1 hours);
        deployer.setMaxJobAge(90 days);
        vm.stopPrank();
        assertEq(deployer.maxJobAge(), 90 days);
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("NotOwner()")));
        deployer.setMaxJobAge(10 days);
    }

    // ---------------------------------------------------------------- malicious constructors

    function testLyingManagerReadbackRefused() public {
        Case memory c = _case(
            type(LyingManagerHook).creationCode,
            abi.encode(address(manager), FLAGS),
            keccak256(type(LyingManagerHook).runtimeCode),
            FLAGS
        );
        _pass(c.jobId, true);
        _expectDeployRevert(
            c, abi.encodeWithSelector(GatedHookDeployer.ReadbackFailed.selector, bytes4(keccak256("poolManager()")))
        );
        assertEq(deployer.deployedHookOf(c.jobId), address(0));
    }

    function testLyingPermissionsReadbackRefused() public {
        Case memory c = _case(
            type(LyingPermissionsHook).creationCode,
            abi.encode(address(manager), FLAGS),
            keccak256(type(LyingPermissionsHook).runtimeCode),
            FLAGS
        );
        _pass(c.jobId, true);
        _expectDeployRevert(
            c,
            abi.encodeWithSelector(GatedHookDeployer.ReadbackFailed.selector, bytes4(keccak256("getHookPermissions()")))
        );
    }

    function testReenteringConstructorCannotReuseApproval() public {
        Case memory c = _case(
            type(ReenteringHook).creationCode,
            abi.encode(address(manager), FLAGS, address(deployer)),
            keccak256(type(ReenteringHook).runtimeCode),
            FLAGS
        );
        _pass(c.jobId, true);
        address hook = _deploy(c);
        assertFalse(ReenteringHook(hook).reentered());
    }

    function testEmptyRuntimeRefused() public {
        Case memory c =
            _case(type(EmptyRuntimeHook).creationCode, abi.encode(address(manager), FLAGS), keccak256(""), FLAGS);
        _pass(c.jobId, true);
        _expectDeployRevert(
            c, abi.encodeWithSelector(GatedHookDeployer.ReadbackFailed.selector, bytes4(keccak256("poolManager()")))
        );
    }

    function testRevertingConstructorLeavesApprovalUnused() public {
        Case memory c =
            _case(type(RevertingHook).creationCode, abi.encode(address(manager), FLAGS), keccak256("x"), FLAGS);
        _pass(c.jobId, true);
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.CreateFailed.selector));
        assertFalse(deployer.usedArtifact(deployer.artifactDigest(c.a)));
    }

    function testEnvironmentDependentRuntimeRefused() public {
        bytes32 placeholder = keccak256("runtime the reviewer built at another block");
        Case memory c =
            _case(type(EnvironmentDependentHook).creationCode, abi.encode(address(manager), FLAGS), placeholder, FLAGS);
        _pass(c.jobId, true);
        vm.prank(creator);
        vm.expectPartialRevert(GatedHookDeployer.RuntimeCodeMismatch.selector);
        deployer.deploy(c.a, c.doc, c.code, c.args, c.salt, c.hook);
    }

    // ---------------------------------------------------------------- manager policy

    function testProductionChainsAcceptOnlyPinnedManager() public {
        uint256[4] memory ids = [uint256(1), 8453, 4663, 11155111];
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            (address pin, bytes32 pinHash, bool pinned) = deployer.pinnedManager(ids[i]);
            assertTrue(pinned);
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(
                    GatedHookDeployer.ManagerNotPinned.selector, address(manager), address(manager).codehash
                )
            );
            deployer.setManager(address(manager), address(manager).codehash, true);
            // the pinned address with no code here (no fork) is refused: enable needs live code hash
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(GatedHookDeployer.ManagerCodeHashMismatch.selector, pinHash, bytes32(0))
            );
            deployer.setManager(pin, pinHash, true);
        }
    }

    function testPinnedManagerRefusedWhenLiveCodeDiffers() public {
        vm.chainId(1);
        (address pin, bytes32 pinHash,) = deployer.pinnedManager(1);
        vm.etch(pin, address(manager).code);
        // local bytecode is not mainnet's: its hash differs from the pinned first-party hash
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(GatedHookDeployer.ManagerCodeHashMismatch.selector, pinHash, pin.codehash)
        );
        deployer.setManager(pin, pinHash, true);
    }

    function testOnlyOwnerSetsManager() public {
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("NotOwner()")));
        deployer.setManager(address(manager), address(manager).codehash, true);
    }

    function testConstructorRejectsZeroRequesterAndOwner() public {
        vm.expectRevert(GatedHookDeployer.InvalidRequester.selector);
        new GatedHookDeployer(owner, HookJobRequester(address(0)));
        vm.expectRevert(bytes4(keccak256("InvalidAddress()")));
        new GatedHookDeployer(address(0), requester);
    }

    function testMarkerFormat() public view {
        GatedHookDeployer.Artifact memory a;
        bytes memory m = deployer.artifactMarker(a);
        assertEq(m.length, 24 + 64 + 1);
    }
}

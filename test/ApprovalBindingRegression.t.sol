// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GatedHookDeployerTest} from "./GatedHookDeployer.t.sol";
import {GatedHookDeployer} from "../src/deployment/GatedHookDeployer.sol";
import {AcceptedArtifact} from "../src/deployment/AcceptedArtifact.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {GeneratedHook} from "./helpers/GeneratedHooks.sol";

contract ApprovalBindingRegressionTest is GatedHookDeployerTest {
    function testRegressionRejectedNestedArtifactCannotDeploy() public {
        Case memory c;
        c.jobId = _open();
        c.code = type(GeneratedHook).creationCode;
        c.args = abi.encode(address(manager), FLAGS);
        c.a = _artifact(c.jobId, c.code, c.args, keccak256(type(GeneratedHook).runtimeCode), FLAGS);
        GatedHookDeployer.Artifact memory approved =
            _artifact(c.jobId, c.code, c.args, keccak256(type(GeneratedHook).runtimeCode), FLAGS);
        approved.buildHash = keccak256("approved build A");
        c.doc =
            bytes.concat("{", deployer.artifactMarker(approved), ',"rejected":{', deployer.artifactMarker(c.a), "}}");
        assertTrue(intake.complete(c.jobId, abi.encode(c.jobId, keccak256(c.doc), "ipfs://regression")));
        _pass(c.jobId, true);
        (c.salt, c.hook) = _mine(bytes.concat(c.code, c.args), FLAGS);
        vm.prank(creator);
        vm.expectRevert();
        deployer.deploy(c.a, c.doc, c.code, c.args, c.salt, c.hook);
    }

    function testRegressionBindFirstRevokedEpochCannotDeploy() public {
        Case memory c = _generic(FLAGS);
        bytes32 ask = _pass(c.jobId, true);
        uint32 epoch = requester.oracleSignerEpoch();
        vm.startPrank(owner);
        requester.setOracleSigner(makeAddr("replacement oracle"));
        requester.revokeSignerEpoch(epoch, keccak256("incident evidence"));
        vm.stopPrank();
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewRevoked.selector, ask));
        assertEq(uint8(_review(c.jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertTrue(requester.consumed(requester.getReviewAsk(ask).oracleRequestId));
    }

    function testApprovedADeploysFromSnapshotThatAlsoMentionsRejectedB() public {
        Case memory c;
        c.jobId = _open();
        c.code = type(GeneratedHook).creationCode;
        c.args = abi.encode(address(manager), FLAGS);
        c.a = _artifact(c.jobId, c.code, c.args, keccak256(type(GeneratedHook).runtimeCode), FLAGS);
        bytes memory snapshot = _doc(c.a);
        bytes memory prefix = new bytes(snapshot.length - 1);
        for (uint256 i; i < prefix.length; ++i) {
            prefix[i] = snapshot[i];
        }
        GatedHookDeployer.Artifact memory rejected = _artifact(c.jobId, c.code, c.args, c.a.runtimeCodeHash, FLAGS);
        rejected.buildHash = keccak256("rejected build B");
        c.doc = bytes.concat(
            prefix, ",", deployer.artifactMarker(c.a), ',"rejected":{', deployer.artifactMarker(rejected), "}}"
        );
        assertTrue(intake.complete(c.jobId, abi.encode(c.jobId, keccak256(c.doc), "ipfs://snapshot")));
        _pass(c.jobId, true);
        (c.salt, c.hook) = _mine(bytes.concat(c.code, c.args), FLAGS);
        bytes32 rejectedDigest = deployer.artifactDigest(rejected);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.ArtifactNotInResult.selector, rejectedDigest));
        deployer.deploy(rejected, c.doc, c.code, c.args, c.salt, c.hook);
        assertEq(_deploy(c), c.hook);
    }

    function testMissingSignerProvenanceFailsClosed() public {
        Case memory c = _generic(FLAGS);
        bytes32 ask = _pass(c.jobId, true);
        vm.mockCall(
            address(requester), abi.encodeCall(requester.reviewReceiptSignerEpoch, (ask)), abi.encode(uint32(0))
        );
        _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewRevoked.selector, ask));
    }

    function testFuzzBothOrdersKeepEpochAcrossOrdinaryRotation(bool receiptFirst, bool passed) public {
        Case memory c = _generic(FLAGS);
        bytes32 ask;
        if (receiptFirst) {
            vm.prank(creator);
            ask = requester.requestReview(c.jobId, 0.5 ether);
            OracleAttestation.Attestation memory a = _attestation(ask, passed);
            assertTrue(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey))));
            vm.prank(owner);
            requester.setOracleSigner(makeAddr("next oracle"));
            _bind(ask);
        } else {
            ask = _pass(c.jobId, passed);
            vm.prank(owner);
            requester.setOracleSigner(makeAddr("next oracle"));
        }
        assertEq(requester.reviewReceiptSignerEpoch(ask), 1);
        assertEq(requester.oracleSignerEpoch(), 2);
        if (passed) assertEq(_deploy(c), c.hook);
        else _expectDeployRevert(c, abi.encodeWithSelector(GatedHookDeployer.ReviewNotPassed.selector, c.jobId));
    }

    function testEpochIsVerificationTimeNotAskTime() public {
        Case memory c = _generic(FLAGS);
        bytes32 ask = _requestReview(c.jobId);
        vm.prank(owner);
        requester.setOracleSigner(signer);
        OracleAttestation.Attestation memory a = _attestation(ask, true);
        assertTrue(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey))));
        assertEq(requester.reviewReceiptSignerEpoch(ask), 2);
        vm.prank(owner);
        requester.revokeSignerEpoch(1, keccak256("old incident"));
        assertEq(_deploy(c), c.hook);
    }

    function testRejectedSignatureLeavesNoProvenance() public {
        Case memory c = _generic(FLAGS);
        bytes32 ask = _requestReview(c.jobId);
        OracleAttestation.Attestation memory a = _attestation(ask, true);
        assertFalse(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey + 1))));
        assertEq(requester.reviewReceiptSignerEpoch(ask), 0);
        assertFalse(requester.consumed(a.requestId));
        assertEq(uint8(_review(c.jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testAutomaticBindingRemainsDisabled() public view {
        assertFalse(deployer.automaticBindingSupported());
    }
}

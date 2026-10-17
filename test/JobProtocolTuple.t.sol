// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {Vm} from "forge-std/Vm.sol";

contract JobProtocolTupleTest is HookJobRequesterFixture {
    function testProtocolTuple() public {
        bytes32 id = _open();
        bytes32 h = keccak256("result document");
        assertTrue(intake.complete(id, abi.encode(id, h, "ipfs://fixture")));
        assertEq(requester.getJob(id).resultHash, h);
    }

    function testRegisteredSelectorAndResultEventsMatchProtocol() public {
        bytes32 id = _open();
        (,,, address target, bytes4 selector,,) = intake.reqs(id);
        assertEq(target, address(requester));
        assertEq(selector, bytes4(keccak256("onJobResult(bytes32,bytes32,string)")));
        assertEq(selector, bytes4(0x325a77b4));
        assertTrue(RESULT_HASH != keccak256("ipfs://fixture"), "document hash differs from URI hash");
        bytes memory beforeJob = abi.encode(requester.getJob(id));
        vm.recordLogs();
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://fixture")));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3, "two requester events and Intake completion");
        assertEq(logs[0].emitter, address(requester));
        assertEq(logs[0].topics.length, 2);
        assertEq(logs[0].topics[0], HookJobRequester.JobDelivered.selector);
        assertEq(logs[0].topics[1], id);
        assertEq(abi.decode(logs[0].data, (bytes32)), RESULT_HASH);
        assertEq(logs[1].emitter, address(requester));
        assertEq(logs[1].topics.length, 2);
        assertEq(logs[1].topics[0], keccak256("JobResultURI(bytes32,string)"));
        assertEq(logs[1].topics[1], id);
        assertEq(abi.decode(logs[1].data, (string)), "ipfs://fixture");
        HookJobRequester.Job memory afterJob = requester.getJob(id);
        assertEq(afterJob.resultHash, RESULT_HASH);
        assertEq(uint8(afterJob.status), uint8(HookJobRequester.JobStatus.Delivered));
        assertEq(uint8(afterJob.review), uint8(HookJobRequester.ReviewStatus.None));
        // No URI storage: the existing static Job ABI and all other fields stay unchanged.
        assertEq(abi.encode(afterJob).length, 15 * 32);
        afterJob.status = HookJobRequester.JobStatus.Open;
        afterJob.resultHash = bytes32(0);
        assertEq(abi.encode(afterJob), beforeJob);
    }

    function testFuzzSuppliedHashAndURIBytesArePreserved(bytes32 hash, uint16 length) public {
        bytes32 id = _open();
        bytes memory raw = new bytes(bound(length, 0, 1024));
        for (uint256 i; i < raw.length; ++i) {
            raw[i] = hash[i % 32];
        }
        // Solidity strings can contain arbitrary bytes. Readers must treat them as untrusted.
        vm.expectEmit(true, false, false, true, address(requester));
        emit HookJobRequester.JobDelivered(id, hash);
        vm.expectEmit(true, false, false, true, address(requester));
        emit HookJobRequester.JobResultURI(id, string(raw));
        assertTrue(intake.complete(id, abi.encode(id, hash, string(raw))));
        assertEq(requester.getJob(id).resultHash, hash);
        assertEq(uint8(_review(id)), uint8(HookJobRequester.ReviewStatus.None));
    }

    function testEmptyURICanBeReportedWithoutReviewApproval() public {
        bytes32 id = _open();
        vm.expectEmit(true, false, false, true, address(requester));
        emit HookJobRequester.JobResultURI(id, "");
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "")));
        assertEq(requester.getJob(id).resultHash, RESULT_HASH);
        assertEq(uint8(_review(id)), uint8(HookJobRequester.ReviewStatus.None));
    }

    function testUnauthorizedTupleLeavesJobAndLogsUntouched() public {
        bytes32 id = _open();
        bytes memory beforeJob = abi.encode(requester.getJob(id));
        address[3] memory unauthorized = [creator, owner, stranger];
        vm.recordLogs();
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert(HookJobRequester.NotTheIntake.selector);
            requester.onJobResult(id, RESULT_HASH, "javascript:untrusted");
        }
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(abi.encode(requester.getJob(id)), beforeJob);
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://fixture")));
    }

    function testDuplicateCannotReplaceHashOrURI() public {
        bytes32 id = _delivered();
        bytes memory beforeJob = abi.encode(requester.getJob(id));
        vm.recordLogs();
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobResult(id, keccak256("replacement document"), "ipfs://replacement");
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(abi.encode(requester.getJob(id)), beforeJob);
        bytes memory payload = abi.encode(id, RESULT_HASH, "ipfs://result");
        vm.expectRevert("not pending");
        intake.complete(id, payload);
    }

    function testObsoleteSelectorIsNotAnAlias() public {
        bytes32 id = _open();
        vm.prank(address(intake));
        (bool ok,) = address(requester).call(abi.encodeWithSignature("onJobResult(bytes32,bytes)", id, bytes("old")));
        assertFalse(ok);
        assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Open));
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://fixture")));
    }

    function testMalformedTuplesLoseOnlyTheSingleIntakeAttempt() public {
        for (uint256 fault; fault < 6; ++fault) {
            bytes32 id = _open();
            bytes memory payload;
            if (fault == 0) payload = abi.encode(id, bytes("ipfs://legacy"));
            if (fault == 1) payload = abi.encode(id, RESULT_HASH); // Missing string offset.
            if (fault == 2) payload = abi.encode(id, RESULT_HASH, type(uint256).max); // Offset outside data.
            if (fault == 3) payload = abi.encode(id, RESULT_HASH, uint256(96), type(uint256).max); // Length overflow.
            if (fault == 4) payload = abi.encode(id, RESULT_HASH, uint256(96), uint256(1)); // Missing string byte.
            if (fault == 5) payload = hex"deadbeef";
            bytes memory beforeJob = abi.encode(requester.getJob(id));
            vm.recordLogs();
            assertFalse(intake.complete(id, payload));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1, "failed callback emits no result events");
            assertEq(logs[0].emitter, address(intake));
            assertFalse(abi.decode(logs[0].data, (bool)));
            assertEq(abi.encode(requester.getJob(id)), beforeJob);
            (,,,,,, bool settled) = intake.reqs(id);
            assertTrue(settled, "Intake consumes even an unsuccessful attempt");
            bytes memory corrected = abi.encode(id, RESULT_HASH, "ipfs://fixture");
            vm.expectRevert("not pending");
            intake.complete(id, corrected);
            vm.warp(requester.getJob(id).deadline + 1);
            vm.prank(creator);
            requester.expireJob(id);
            assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Expired));
        }
        assertEq(imd.balanceOf(address(intake)), 6 * PRICE, "failed callbacks do not refund payment");
    }

    function testUnknownTupleCannotDeliverAnotherRequest() public {
        bytes32 id = _open();
        bytes memory beforeJob = abi.encode(requester.getJob(id));
        bytes32 unknown = keccak256("unregistered request");
        assertFalse(intake.complete(id, abi.encode(unknown, RESULT_HASH, "ipfs://fixture")));
        assertEq(abi.encode(requester.getJob(id)), beforeJob);
        assertEq(uint8(_status(unknown)), uint8(HookJobRequester.JobStatus.None));
    }

    function testFuzzLateTupleWorksBeforeOrAfterLocalExpiry(bool expireFirst) public {
        bytes32 id = _open();
        vm.warp(requester.getJob(id).deadline + 1);
        if (expireFirst) {
            vm.prank(creator);
            requester.expireJob(id);
        }
        vm.expectEmit(true, false, false, true, address(requester));
        emit HookJobRequester.JobResultURI(id, "ipfs://late");
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://late")));
        assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Delivered));
        assertEq(requester.getJob(id).resultHash, RESULT_HASH);
        assertEq(uint8(_review(id)), uint8(HookJobRequester.ReviewStatus.None));
    }

    function testLateTuplePreservesFinalizedNegativeReview() public {
        bytes32 id = _open();
        vm.warp(requester.getJob(id).deadline + 1);
        vm.prank(creator);
        requester.expireJob(id);
        bytes32 ask = _requestReview(id);
        OracleAttestation.Attestation memory a = _attestation(ask, false);
        assertTrue(intake.complete(ask, abi.encode(ask, a, _sign(a, signerKey))));
        bytes memory receipt = abi.encode(requester.getReviewReceipt(ask));
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://late")));
        assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Delivered));
        assertEq(requester.getJob(id).resultHash, RESULT_HASH);
        assertEq(uint8(_review(id)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertTrue(requester.consumed(a.requestId));
        assertEq(abi.encode(requester.getReviewReceipt(ask)), receipt);
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
    }
}

contract JobProtocolGasTest is HookJobRequesterFixture {
    bytes32 private id;

    function setUp() public override {
        super.setUp();
        // Allocate the Open job in an earlier transaction so the status slot is clean.
        id = _open();
    }

    function testColdTupleWithLongURIFits200kAndRuntimeLimit() public {
        string memory uri = string(new bytes(4096));
        bytes memory payload = abi.encodeCall(requester.onJobResult, (id, RESULT_HASH, uri));
        uint256 low = 0;
        uint256 high = 200_000;
        while (low < high) {
            uint256 cap = (low + high) / 2;
            uint256 snapshot = vm.snapshotState();
            vm.cool(address(requester));
            vm.prank(address(intake));
            (bool success,) = address(requester).call{gas: cap}(payload);
            assertTrue(vm.revertToStateAndDelete(snapshot));
            if (success) high = cap;
            else low = cap + 1;
        }
        emit log_named_uint("Cold job tuple with 4096-byte URI minimum forwarded gas", high);
        assertLt(high, 100_000, "at least 100k headroom for tested URI length");
        assertEq(intake.STIPEND(), 200_000);
        vm.cool(address(requester));
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, uri)));
        assertEq(requester.getJob(id).resultHash, RESULT_HASH);
        emit log_named_uint("Requester deployed runtime bytes", address(requester).code.length);
        assertLt(address(requester).code.length, 24_576);
    }
}

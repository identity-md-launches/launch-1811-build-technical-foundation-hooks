// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";

/// @dev A reproducible pilot measurement, not a universal URI limit. No production code changed.
contract UriPilotGasTest is HookJobRequesterFixture {
    bytes32 private id;

    function setUp() public override {
        super.setUp();
        id = _open();
    }

    function testColdMeasuredUriBoundaryAndOneAttemptFeeLoss() public {
        uint256 snapshot = vm.snapshotState();
        vm.cool(address(requester));
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, string(new bytes(20_224)))));
        assertEq(uint8(requester.getJob(id).status), uint8(HookJobRequester.JobStatus.Delivered));
        emit log_named_uint("Local cold URI bytes delivered under exact 200k", 20_224);
        assertTrue(vm.revertToStateAndDelete(snapshot));

        vm.cool(address(requester));
        assertFalse(intake.complete(id, abi.encode(id, RESULT_HASH, string(new bytes(20_256)))));
        assertEq(uint8(requester.getJob(id).status), uint8(HookJobRequester.JobStatus.Open));
        (,,,,,, bool settled) = intake.reqs(id);
        assertTrue(settled, "failed one-shot callback still consumes the attempt");
        assertEq(imd.balanceOf(address(intake)), PRICE, "fee is retained");
        emit log_named_uint("Local cold URI bytes exceeding exact 200k", 20_256);
        vm.expectRevert("not pending");
        intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://short-retry"));
    }
}

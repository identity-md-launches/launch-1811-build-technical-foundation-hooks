// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {MockIntake} from "./helpers/MockIntake.sol";
import {ImdTemplates} from "./helpers/ImdTemplates.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";

/// @dev The oracle-consumer reference's conformance test, adapted to HookJobRequester: deployed at
/// the protocol's vector address on the vector's chain, it must reproduce the protocol's digest.
contract OracleConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    string constant CALLBACK =
        "onReviewResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
    string constant FAILURE = "onReviewFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)";

    bytes32 constant JOB_ACTION = "job.open@test";
    bytes32 constant ORACLE_ACTION = "oracle.request@oracle-1";

    MockIntake intake;
    TestToken imd;
    HookJobRequester consumer;
    address creator = makeAddr("creator");

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        intake = new MockIntake();
        imd = new TestToken("IMD", 18);
        intake.setPrice(JOB_ACTION, address(imd), 0.5 ether);
        intake.setPrice(ORACLE_ACTION, address(imd), 0.5 ether);
        deployCodeTo(
            "HookJobRequester.sol:HookJobRequester",
            abi.encode(address(this), address(intake), address(imd), SIGNER, 0.5 ether),
            VECTOR_CONSUMER
        );
        consumer = HookJobRequester(VECTOR_CONSUMER);
        consumer.setJobTemplate(JOB_ACTION, ImdTemplates.JOB_PREFIX, ImdTemplates.JOB_MIDDLE, ImdTemplates.JOB_SUFFIX);
        consumer.setReviewTemplate(ORACLE_ACTION, ImdTemplates.REVIEW_PREFIX, ImdTemplates.REVIEW_SUFFIX, 5, 4);
        imd.mint(creator, 1 ether);
        vm.prank(creator);
        imd.approve(VECTOR_CONSUMER, 1 ether);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST, "struct, type string or domain differs");
    }

    function test_callbackSelectorsAreCanonical() public pure {
        assertEq(HookJobRequester.onReviewResult.selector, bytes4(keccak256(bytes(CALLBACK))));
        assertEq(HookJobRequester.onReviewFailure.selector, bytes4(keccak256(bytes(FAILURE))));
    }

    /// @dev The vector's answer is a bytes32[]; a review verdict is a bool, so this signs a bool
    /// answer with the vector key, as the reference prescribes for consumers refusing its type.
    function test_acceptsAFreshSignatureFromTheVectorKeyAsDelivered() public {
        vm.prank(creator);
        bytes32 jobId = consumer.openJob(keccak256("spec"), "brief");
        assertTrue(intake.complete(jobId, abi.encode(jobId, bytes("result"))));
        vm.prank(creator);
        bytes32 oracleId = consumer.requestReview(jobId);
        OracleAttestation.Attestation memory a = vector();
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, abi.encodePacked(r, s, v))), "200k stipend");
        assertTrue(consumer.consumed(a.requestId));
        assertEq(uint8(consumer.getJob(jobId).review), uint8(HookJobRequester.ReviewStatus.Passed));
    }
}

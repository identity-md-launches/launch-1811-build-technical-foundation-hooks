// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookJobRequester} from "src/imd/HookJobRequester.sol";
import {IIntake} from "src/imd/IIntake.sol";
import {OracleAttestation} from "src/imd/OracleAttestation.sol";

/// @dev Minimal ERC-20 for the proof: returns true, no callbacks.
contract ProofToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal Intake v2 stand-in: pulls the price, calls back once under the 200k stipend.
contract ProofIntake is IIntake {
    struct Req {
        address target;
        bytes4 selector;
        bool settled;
    }

    uint256 public price;
    uint256 internal nonce;
    mapping(bytes32 => Req) public reqs;

    constructor(uint256 price_) {
        price = price_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 id)
    {
        return _request(callback, asset, amount);
    }

    function requestWithFailure(
        bytes32,
        bytes calldata,
        Callback calldata callback,
        bytes4,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        return _request(callback, asset, amount);
    }

    function _request(Callback calldata callback, address asset, uint256 amount) internal returns (bytes32 id) {
        require(amount == price, "wrong amount");
        require(ProofToken(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        id = keccak256(abi.encode(address(this), ++nonce));
        reqs[id] = Req(callback.target, callback.selector, false);
    }

    function complete(bytes32 id, bytes calldata args) external returns (bool called) {
        Req storage r = reqs[id];
        require(r.target != address(0) && !r.settled, "not pending");
        r.settled = true;
        (called,) = r.target.call{gas: 200_000}(bytes.concat(r.selector, args));
    }
}

/// @notice Fails on the current code: an unbound receipt whose true context matches but whose UUID
/// was consumed through another ask has no recovery path. Passes once the owner can close it.
contract StuckReceiptProofTest is Test {
    bytes32 internal constant JOB_ACTION = "job.open@test";
    bytes32 internal constant ORACLE_ACTION = "oracle.request@oracle-1";
    uint256 internal constant PRICE = 0.5 ether;

    ProofToken internal imd;
    ProofIntake internal intake;
    HookJobRequester internal requester;
    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    uint256 internal signerKey = uint256(keccak256("proof oracle key"));

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1_800_000_000);
        imd = new ProofToken();
        intake = new ProofIntake(PRICE);
        requester = new HookJobRequester(owner, address(intake), address(imd), vm.addr(signerKey), PRICE);
        vm.startPrank(owner);
        requester.setJobTemplate(
            JOB_ACTION,
            '{"steps":["forge build","forge test","adversarial review"],"specHash":"',
            '","request":"<brief>',
            '</brief>"}'
        );
        requester.setReviewTemplate(ORACLE_ACTION, '{"question":"', '"}', 5, 4);
        vm.stopPrank();
        imd.mint(creator, 10 ether);
        vm.prank(creator);
        imd.approve(address(requester), type(uint256).max);
    }

    function _unboundAsk() internal returns (bytes32 jobId, bytes32 askId) {
        vm.prank(creator);
        jobId = requester.openJob(keccak256("spec"), "A swap cap hook");
        assertTrue(intake.complete(jobId, abi.encode(jobId, bytes("ipfs://result"))));
        vm.prank(creator);
        askId = requester.requestReview(jobId);
    }

    function _attestation(bytes32 askId, bytes32 uuid, bool passed)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: uuid,
            chainId: 31337,
            questionHash: keccak256(abi.encode("question", askId)),
            answerType: OracleAttestation.ANSWER_BOOL,
            answer: abi.encode(passed),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(uint256(3)),
            panelJobId: keccak256("panel job"),
            panelSize: 7,
            quorum: 5,
            agreed: 6,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _deliver(bytes32 askId, OracleAttestation.Attestation memory a) internal returns (bool) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, requester.attestationDigest(a));
        return intake.complete(askId, abi.encode(askId, a, abi.encodePacked(r, s, v)));
    }

    function testOwnerCanCloseReceiptWhoseUuidWasConsumedElsewhere() public {
        (, bytes32 askA) = _unboundAsk();
        (bytes32 jobB, bytes32 askB) = _unboundAsk();
        bytes32 uuid = bytes32(bytes16(keccak256("shared protocol UUID")));
        OracleAttestation.Attestation memory a = _attestation(askA, uuid, true);
        OracleAttestation.Attestation memory b = _attestation(askB, uuid, false);
        assertTrue(_deliver(askA, a), "receipt A retained");
        assertTrue(_deliver(askB, b), "receipt B retained");

        // Owner authenticates A's context and finalizes it, consuming the shared UUID.
        bytes32 bodyA = requester.getReviewAsk(askA).bodyHash;
        vm.prank(owner);
        requester.bindReview(askA, bodyA, uuid, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        assertTrue(requester.consumed(uuid));

        // B's receipt matches B's true context but its UUID is gone: bind is impossible by design.
        bytes32 bodyB = requester.getReviewAsk(askB).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, uuid));
        requester.bindReview(askB, bodyB, uuid, b.questionHash, b.chainId, b.fromBlock, b.toBlock);

        // The requester has no path either.
        vm.warp(requester.getReviewAsk(askB).deadline + 1);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askB));
        requester.expireReview(jobB);

        // Expected: the owner can close the dead receipt so the requester may retry.
        // Actual on current code: ReviewReceiptMatches, and jobB is Pending forever.
        vm.prank(owner);
        requester.discardReviewReceipt(askB, bodyB, uuid, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        assertEq(uint8(requester.getJob(jobB).review), uint8(HookJobRequester.ReviewStatus.Unanswered));
        vm.prank(creator);
        requester.requestReview(jobB);
    }
}

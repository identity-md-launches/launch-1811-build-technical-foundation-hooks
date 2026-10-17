// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookJobRequester} from "src/imd/HookJobRequester.sol";
import {IIntake} from "src/imd/IIntake.sol";
import {OracleAttestation} from "src/imd/OracleAttestation.sol";

contract PocToken {
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

/// @dev One-shot Intake stand-in: 200k gas callback, settled even when the callback reverts.
contract PocIntake is IIntake {
    struct Req {
        address target;
        bytes4 selector;
        bool settled;
        bytes body;
    }

    mapping(bytes32 => Req) public reqs;
    uint256 internal nonce;
    uint256 public price = 0.5 ether;

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata cb, address asset, uint256 amount)
        external
        payable
        returns (bytes32 id)
    {
        return _req(body, cb, asset, amount);
    }

    function requestWithFailure(
        bytes32,
        bytes calldata body,
        Callback calldata cb,
        bytes4,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        return _req(body, cb, asset, amount);
    }

    function _req(bytes calldata body, Callback calldata cb, address asset, uint256 amount)
        internal
        returns (bytes32 id)
    {
        PocToken(asset).transferFrom(msg.sender, address(this), amount);
        id = keccak256(abi.encode(address(this), ++nonce));
        reqs[id] = Req(cb.target, cb.selector, false, body);
    }

    function bodyOf(bytes32 id) external view returns (bytes memory) {
        return reqs[id].body;
    }

    function complete(bytes32 id, bytes calldata args) external returns (bool called) {
        Req storage r = reqs[id];
        require(r.target != address(0) && !r.settled, "not pending");
        r.settled = true;
        (called,) = r.target.call{gas: 200_000}(bytes.concat(r.selector, args));
    }
}

/// @notice Audit finding: a requester who sees a late NotPassed answer coming (Intake completion in
/// the mempool, or the public panel result) front-runs it with `expireReview`, so the one-shot
/// callback reverts, the negative verdict is never recorded, and the requester re-asks.
contract ExpiryFrontRunShoppingTest is Test {
    PocToken internal imd;
    PocIntake internal intake;
    HookJobRequester internal requester;
    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    uint256 internal signerKey = uint256(keccak256("poc oracle key"));

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new PocToken();
        intake = new PocIntake();
        requester = new HookJobRequester(owner, address(intake), address(imd), vm.addr(signerKey), 0.5 ether);
        vm.startPrank(owner);
        requester.setJobTemplate(
            "job", '{"steps":"forge build, forge test, adversarial review","spec":"', '","b":"', '"}'
        );
        requester.setReviewTemplate("review", '{"q":"did job ', ' pass?"}', 5, 4);
        vm.stopPrank();
        imd.mint(creator, 10 ether);
        vm.prank(creator);
        imd.approve(address(requester), type(uint256).max);
    }

    function _attestation(bytes32 askId, bool passed) internal view returns (OracleAttestation.Attestation memory) {
        return OracleAttestation.Attestation({
            requestId: bytes32(bytes16(keccak256(abi.encode("uuid", askId)))),
            chainId: 31337,
            questionHash: keccak256(intake.bodyOf(askId)),
            answerType: 0,
            answer: abi.encode(passed),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(uint256(3)),
            panelJobId: keccak256("panel"),
            panelSize: 7,
            quorum: 5,
            agreed: 6,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _signed(bytes32 askId, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, requester.attestationDigest(a));
        return abi.encode(askId, a, abi.encodePacked(r, s, v));
    }

    function testRequesterFrontRunsLateNotPassedWithExpiryAndReasks() public {
        vm.prank(creator);
        bytes32 jobId = requester.openJob(keccak256("spec"), "hook brief", 0.5 ether);
        assertTrue(intake.complete(jobId, abi.encode(jobId, keccak256("result document"), "ipfs://result")));
        vm.prank(creator);
        bytes32 askId = requester.requestReview(jobId, 0.5 ether);

        // The oracle's answer is produced after the 1-day local deadline. It is a valid, fresh,
        // correctly signed NotPassed for this exact ask; the Intake's completion tx is pending.
        vm.warp(block.timestamp + 1 days + 1);
        bytes memory pendingDelivery = _signed(askId, _attestation(askId, false));

        // Requester sees `answer = false` in the pending calldata and front-runs with expiry.
        vm.prank(creator);
        (bool expired,) = address(requester).call(abi.encodeCall(HookJobRequester.expireReview, (jobId)));
        expired; // ignored: a fix may refuse this

        // The Intake's one attempt: the genuine negative answer must be retained or recorded.
        bool delivered = intake.complete(askId, pendingDelivery);
        assertTrue(delivered, "genuine NotPassed was discarded by requester-chosen expiry");
        HookJobRequester.ReviewStatus status = requester.getJob(jobId).review;
        assertTrue(status != HookJobRequester.ReviewStatus.Unanswered, "requester may re-ask after seeing NotPassed");
    }
}

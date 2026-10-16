// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {ECDSA} from "../src/vendor/openzeppelin/utils/cryptography/ECDSA.sol";

/// @dev Ordinary ERC-1271 registry with revocation, rejection and broken-response modes.
contract OracleRegistryMock {
    address public key;
    uint8 public mode;

    constructor(address key_) {
        key = key_;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (mode == 1) return bytes4(0xffffffff);
        if (mode == 2) revert("registry unavailable");
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 0x1626ba7e)
                return(28, 4)
            }
        }
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, signature);
        return err == ECDSA.RecoverError.NoError && recovered == key ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract OracleSignerTest is HookJobRequesterFixture {
    function testEip7702DesignatorDoesNotDisableTheSignersEcdsaKey() public {
        (, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes memory sig = _sign(a, signerKey);
        // Cancun cannot execute EIP-7702 delegation. Etching its real 23-byte layout reproduces
        // the code.length regression; success must not depend on executing the delegated code.
        address delegate = makeAddr("no ERC1271 delegate");
        vm.etch(signer, abi.encodePacked(hex"ef0100", delegate));
        assertEq(signer.code.length, 23);
        vm.cool(signer);
        vm.cool(address(requester));
        assertTrue(intake.complete(askId, abi.encode(askId, a, sig)), "ECDSA still fits the 200k stipend");
        assertTrue(requester.consumed(a.requestId));
    }

    function testEcdsaKeyRemainsValidEvenIfItsCodeRejectsErc1271() public {
        (, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes memory sig = _sign(a, signerKey);
        vm.etch(signer, hex"60006000fd"); // Always reverts if called.
        assertTrue(intake.complete(askId, abi.encode(askId, a, sig)));
    }

    function testDelegatedSignerStillRejectsWrongKeyTamperingAndMalformedEcdsa() public {
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes memory sig = _sign(a, signerKey);
        vm.etch(signer, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        _reject(askId, a, _sign(a, signerKey + 1));
        a.answer = abi.encode(false);
        _reject(askId, a, sig);
        a.answer = abi.encode(true);
        _reject(askId, a, hex"01");
        _reject(askId, a, new bytes(65));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, requester.attestationDigest(a));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        _reject(askId, a, abi.encodePacked(r, bytes32(curveOrder - uint256(s)), uint8(v == 27 ? 28 : 27)));
        assertFalse(requester.consumed(a.requestId));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testContractSignerUsesErc1271FallbackUnderTheStipend() public {
        (, bytes32 askId) = _reviewPending();
        OracleRegistryMock registry = new OracleRegistryMock(signer);
        vm.prank(owner);
        requester.setOracleSigner(address(registry));
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        bytes memory sig = _sign(a, signerKey);
        assertNotEq(signer, address(registry), "ECDSA cannot directly match the contract signer");
        vm.cool(address(registry));
        vm.cool(address(requester));
        assertTrue(intake.complete(askId, abi.encode(askId, a, sig)), "ERC1271 fits the 200k stipend");
        assertTrue(requester.consumed(a.requestId));
    }

    function testErc1271RevocationRevertAndShortReturnFailClosedAndDoNotConsume() public {
        (, bytes32 askId) = _reviewPending();
        OracleRegistryMock registry = new OracleRegistryMock(signer);
        vm.prank(owner);
        requester.setOracleSigner(address(registry));
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes memory sig = _sign(a, signerKey);
        _reject(askId, a, _sign(a, signerKey + 1));
        for (uint8 mode = 1; mode <= 3; ++mode) {
            registry.setMode(mode);
            _reject(askId, a, sig);
            assertFalse(requester.consumed(a.requestId));
        }
        registry.setMode(0);
        assertTrue(intake.complete(askId, abi.encode(askId, a, sig)));
    }

    function testFutureAttestationIsRefusedWithoutConsumingIt() public {
        (, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.issuedAt = uint64(block.timestamp + requester.ISSUED_AT_TOLERANCE() + 1);
        bytes memory sig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        requester.onReviewResult(askId, a, sig);
        assertFalse(requester.consumed(a.requestId));
    }

    function _reject(bytes32 askId, OracleAttestation.Attestation memory a, bytes memory sig) internal {
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(askId, a, sig);
    }
}

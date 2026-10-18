// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutomaticVectors} from "./helpers/AutomaticVectors.sol";
import {HookRequestCodec, HookQuestionPin} from "../src/imd/automatic/HookRequestCodec.sol";
import {AutoHookJobRequester} from "../src/imd/automatic/AutoHookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {ECDSA} from "../src/vendor/openzeppelin/utils/cryptography/ECDSA.sol";

/// @notice Independent captured public signatures, not test-key/self-consistent mock signatures.
contract AutomaticQuestionVectorsTest is Test {
    HookRequestCodec private codec;
    address private constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function setUp() public {
        codec = new HookRequestCodec();
    }

    function hash(OracleAttestation.Attestation calldata a) external pure returns (bytes32) {
        return OracleAttestation.hashStruct(a);
    }

    function _check(
        bytes memory prefix,
        OracleAttestation.Attestation memory a,
        bytes memory signature,
        address consumer
    ) private {
        assertEq(keccak256(codec.document(prefix, a.fromBlock, a.toBlock)), a.questionHash);
        address pin = address(new HookQuestionPin(prefix));
        assertEq(codec.hashQuestion(pin, a.fromBlock, a.toBlock), a.questionHash);
        assertEq(codec.readPrefix(pin), prefix);
        assertNotEq(codec.hashQuestion(pin, a.fromBlock, a.toBlock + 1), a.questionHash);
        // Exercise the successor's actual inherited EIP-712 implementation at the public domain.
        vm.chainId(1);
        deployCodeTo(
            "AutoHookJobRequester.sol:AutoHookJobRequester",
            abi.encode(address(this), address(codec), address(codec), SIGNER, 1, codec),
            consumer
        );
        bytes32 digest = AutoHookJobRequester(consumer).attestationDigest(a);
        assertEq(ECDSA.recover(digest, signature), SIGNER);
        assertEq(
            AutoHookJobRequester.onReviewResult.selector,
            bytes4(
                keccak256(
                    "onReviewResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                )
            )
        );
    }

    function testLive76587543PricePreimageAndSignature() public {
        _check(
            AutomaticVectors.prefix0(),
            AutomaticVectors.vector0(),
            AutomaticVectors.signature0(),
            AutomaticVectors.consumer0()
        );
    }

    function testLivePanelBoolBitcoinPreimageAndSignature() public {
        _check(
            AutomaticVectors.prefix1(),
            AutomaticVectors.vector1(),
            AutomaticVectors.signature1(),
            AutomaticVectors.consumer1()
        );
    }

    function testLivePanelBoolArgentinaPreimageAndSignature() public {
        _check(
            AutomaticVectors.prefix2(),
            AutomaticVectors.vector2(),
            AutomaticVectors.signature2(),
            AutomaticVectors.consumer2()
        );
    }

    function testLivePanelUintWithDefinitionsPreimageAndSignature() public {
        _check(
            AutomaticVectors.prefix3(),
            AutomaticVectors.vector3(),
            AutomaticVectors.signature3(),
            AutomaticVectors.consumer3()
        );
    }
}

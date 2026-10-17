// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";

/// @dev Captured public signature, verified offline, never signed here. This is a different
/// consumer's uint256 answer, NOT a Hooks Store review or proof of the HTTP Intake mapping.
/// Source: docs/checks/consolidated/sources/oracle-attestation.json (2026-10-17).
contract LiveOracleVectorTest is Test {
    function hash(OracleAttestation.Attestation calldata a) external pure returns (bytes32) {
        return OracleAttestation.hashStruct(a);
    }

    function testCapturedLiveV2SignatureAndDifferentIdNamespaces() public view {
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            agreed: 68,
            answer: hex"00000000000000000000000000000000000000000000000000081255fd31152f",
            figure: 2271960343057711,
            quorum: 67,
            chainId: 1,
            toBlock: 26212933,
            issuedAt: 1792248175,
            blockHash: 0xd437cd95383cc240abc4c40505c8a3491f4dbd2c1d5c529496dd9559cdc49969,
            expiresAt: 1792334575,
            fromBlock: 26212634,
            panelSize: 100,
            requestId: 0x76587543d7e6471ea01f63e9e0dfc6e700000000000000000000000000000000,
            answerType: 3,
            panelJobId: 0x8ff12a685cbb4fd2ab94e678c20fdfcd00000000000000000000000000000000,
            questionHash: 0xf4df38bb41d635b3de83f4215612d83e25696f6a40fc040f9de053baba7029df
        });
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                uint256(1),
                address(0x77E1684402869Bf2B7c70B8bf21E1C7Ca7104951)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, this.hash(a)));
        assertEq(
            ecrecover(
                digest,
                27,
                0xb21b01f33d14deea91d22434066ec23b3c0c5fd821bd222ba194708fd69003ce,
                0x6b8899be087cca8ecc86650047bc4e9e65672850b4dcd6f2dd59523cafd54a6f
            ),
            address(0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982)
        );
        assertTrue(a.requestId != 0x2a2a72a13996058695e187dfd43bcee41682f8a6592b04b23bae308fca2784e1);
    }
}

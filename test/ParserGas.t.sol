// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ResultJson} from "../src/deployment/ResultJson.sol";
import {GatedHookDeployerTest} from "./GatedHookDeployer.t.sol";
import {GeneratedHook} from "./helpers/GeneratedHooks.sol";

contract ParserGasHarness {
    function parse(bytes memory raw) external pure returns (uint256) {
        return ResultJson.parse(raw).count;
    }
}

library ParserGasCorpus {
    function repeat(bytes1 c, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = c;
        }
    }

    function wide() internal pure returns (bytes memory out) {
        // Six objects at the 32-member cap, 6*(1+64) tokens plus wrapper tokens.
        out = "[";
        for (uint256 n; n < 6; ++n) {
            if (n != 0) out = bytes.concat(out, ",");
            out = bytes.concat(out, "{");
            for (uint256 i; i < 32; ++i) {
                if (i != 0) out = bytes.concat(out, ",");
                out = bytes.concat(out, '"', abi.encodePacked(bytes1(uint8(i < 26 ? 65 + i : 97 + i - 26))), '":0');
            }
            out = bytes.concat(out, "}");
        }
        out = bytes.concat(out, "]");
    }

    function escapedPad(bytes memory base, bytes memory extra) internal pure returns (bytes memory out) {
        out = pad(base, extra, "a");
        // Replace only the trailing pad string, leaving all structural and evidence bytes intact.
        uint256 length = 12288 - base.length - extra.length - 17;
        bytes memory pattern = "\\uD83D\\uDE80";
        uint256 start = out.length - 2 - length;
        for (uint256 i; i + 12 <= length; i += 12) {
            for (uint256 j; j < 12; ++j) {
                out[start + i + j] = pattern[j];
            }
        }
    }

    function pad(bytes memory base, bytes memory extra, bytes1 filler) internal pure returns (bytes memory) {
        bytes memory prefix = new bytes(base.length - 1);
        for (uint256 i; i < prefix.length; ++i) {
            prefix[i] = base[i];
        }
        prefix = bytes.concat(prefix, ',"load":', extra, ',"pad":"');
        return bytes.concat(prefix, repeat(filler, 12288 - prefix.length - 2), '"}');
    }
}

contract ParserWorstCaseTest is Test {
    ParserGasHarness internal harness = new ParserGasHarness();

    function _measure(bytes memory raw, string memory label) private {
        assertEq(raw.length, 12288);
        uint256 start = gasleft();
        uint256 tokens = harness.parse(raw);
        uint256 spent = start - gasleft();
        emit log_named_uint(label, spent);
        emit log_named_uint("tokens", tokens);
        assertLe(tokens, 512);
        assertLt(spent, 9_000_000, "bounded parser must fit the conservative 9M budget");
    }

    function testWorstWidthPlusMaximumBytes() public {
        _measure(ParserGasCorpus.pad('{"base":0}', ParserGasCorpus.wide(), "a"), "max width+bytes parser gas");
    }

    function testMaximumTokensAndBytes() public {
        bytes memory numbers = "[0";
        for (uint256 i; i < 126; ++i) {
            numbers = bytes.concat(numbers, ",0");
        }
        numbers = bytes.concat(numbers, "]");
        // Including pad/base wrapper fields, these arrays use exactly 512 tokens.
        bytes memory shortArray = "[0";
        for (uint256 i; i < 119; ++i) {
            shortArray = bytes.concat(shortArray, ",0");
        }
        shortArray = bytes.concat(shortArray, "]");
        bytes memory values = bytes.concat("[", numbers, ",", numbers, ",", numbers, ",", shortArray, "]");
        _measure(ParserGasCorpus.pad('{"base":0}', values, "a"), "max tokens+bytes parser gas");
    }

    function testMaximumNumberAndWhitespace() public {
        _measure(bytes.concat('{"x":', ParserGasCorpus.repeat("1", 12282), "}"), "max number parser gas");
        _measure(bytes.concat("{", ParserGasCorpus.repeat(" ", 12286), "}"), "max whitespace parser gas");
    }

    function testMaximumEscapedDocument() public {
        bytes memory escaped;
        for (uint256 i; i < 1023; ++i) {
            escaped = bytes.concat(escaped, "\\uD83D\\uDE80");
        }
        escaped = bytes.concat('{"x":"', escaped, '"}');
        escaped = bytes.concat(escaped, ParserGasCorpus.repeat(" ", 12288 - escaped.length));
        _measure(escaped, "max surrogate escapes parser gas");
    }

    function testLimitsRejectBeforeUnboundedWork() public {
        vm.expectRevert(ResultJson.ResultDocumentLimit.selector);
        harness.parse(new bytes(12289));
        bytes memory broad = "{";
        for (uint256 i; i < 33; ++i) {
            if (i != 0) broad = bytes.concat(broad, ",");
            broad = bytes.concat(broad, '"', bytes(vm.toString(i)), '":0');
        }
        vm.expectRevert(ResultJson.ResultContainerLimit.selector);
        harness.parse(bytes.concat(broad, "}"));
        bytes memory zeros = "[0";
        for (uint256 i; i < 127; ++i) {
            zeros = bytes.concat(zeros, ",0");
        }
        zeros = bytes.concat(zeros, "]");
        vm.expectRevert(ResultJson.ResultTokenLimit.selector);
        harness.parse(bytes.concat('{"x":[', zeros, ",", zeros, ",", zeros, ",", zeros, "]}"));
    }
}

/// A deliberately maximal EIP-170 runtime with the normal readback surface and inert padding.
contract MaxRuntimeHook is GeneratedHook {
    constructor(address m, uint160 flags_) GeneratedHook(m, flags_) {
        bytes memory code =
            bytes.concat(type(GeneratedHook).runtimeCode, new bytes(24576 - type(GeneratedHook).runtimeCode.length));
        assembly ("memory-safe") { return(add(code, 32), mload(code)) }
    }
}

contract ParserDeploymentGasTest is GatedHookDeployerTest {
    function testMaximumDocumentAndRuntimeFitTransactionBudget() public {
        _maximum(false);
    }

    function testMaximumSourceEntriesAndRuntimeFitTransactionBudget() public {
        _maximum(true);
    }

    function _maximum(bool sourceEntries) private {
        Case memory c;
        c.jobId = _open();
        c.code = type(MaxRuntimeHook).creationCode;
        c.args = abi.encode(address(manager), FLAGS);
        bytes32 runtime = keccak256(
            bytes.concat(type(GeneratedHook).runtimeCode, new bytes(24576 - type(GeneratedHook).runtimeCode.length))
        );
        c.a = _artifact(c.jobId, c.code, c.args, runtime, FLAGS);
        bytes memory base = _doc(c.a);
        if (sourceEntries) {
            bytes memory entries;
            for (uint256 i; i < 127; ++i) {
                entries = bytes.concat(
                    entries, ',{"hash":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}'
                );
            }
            base = bytes(vm.replace(string(base), '}],"files"', string(bytes.concat("}", entries, '],"files"'))));
            c.doc = ParserGasCorpus.escapedPad(base, "null");
        } else {
            ParserGasHarness parser = new ParserGasHarness();
            bytes memory prefix = bytes.concat('{"wide":', ParserGasCorpus.wide(), ',"tail":[');
            bytes memory extra = bytes.concat(prefix, "]}");
            uint256 count = parser.parse(ParserGasCorpus.pad(base, extra, "a"));
            for (uint256 i; i < 512 - count; ++i) {
                if (i != 0) prefix = bytes.concat(prefix, ",");
                prefix = bytes.concat(prefix, "0");
            }
            extra = bytes.concat(prefix, "]}");
            c.doc = ParserGasCorpus.escapedPad(base, extra);
            assertEq(parser.parse(c.doc), 512);
        }
        assertTrue(intake.complete(c.jobId, abi.encode(c.jobId, keccak256(c.doc), "ipfs://max")));
        _pass(c.jobId, true);
        (c.salt, c.hook) = _mine(bytes.concat(c.code, c.args), FLAGS);
        vm.cool(address(requester));
        uint256 start = gasleft();
        deployer.check(c.a, c.doc, c.code, c.args, c.salt, creator);
        uint256 checkGas = start - gasleft();
        emit log_named_uint("max document check gas", checkGas);
        assertLt(checkGas, 10_000_000, "must fit the SDK's explicit eth_call gas budget");
        vm.cool(address(requester));
        vm.cool(address(deployer));
        start = gasleft();
        _deploy(c);
        uint256 spent = start - gasleft();
        emit log_named_uint("max document + 24576 runtime deploy execution gas", spent);
        // Includes ample room for intrinsic calldata cost below a 16,777,216 transaction cap.
        assertLt(spent, 15_500_000);
        assertEq(c.hook.code.length, 24576);
    }
}

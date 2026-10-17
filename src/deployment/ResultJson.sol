// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Strict UTF-8 JSON. Escapes are decoded in a private memory copy, AFTER the caller checks
/// the original resultHash. Keys are unique by decoded bytes at every depth, including aliases.
/// Bounds: 12 KiB, 512 tokens, 32 object members, 128 array items, depth 16.
/// No caller-supplied offsets or substring proofs. Limits are mirrored in sdk/result_snapshot.py.
library ResultJson {
    error InvalidResultJSON();
    error ResultDocumentLimit();
    error ResultTokenLimit();
    error ResultContainerLimit();
    uint256 internal constant MAX_BYTES = 12288;
    uint256 internal constant MAX_TOKENS = 512;

    struct Token {
        uint256 start;
        uint256 end;
        uint256 next;
        uint256 size;
        bytes1 kind;
    }

    struct Document {
        bytes data;
        Token[] tokens;
        uint256 count;
        uint256 pos;
    }

    function parse(bytes memory data) internal pure returns (Document memory d) {
        if (data.length == 0 || data.length > MAX_BYTES) revert ResultDocumentLimit();
        // Do not mutate the caller's byte string: its exact encoding is authenticated evidence.
        d.data = bytes.concat(data);
        d.tokens = new Token[](data.length / 2 + 1 < MAX_TOKENS ? data.length / 2 + 1 : MAX_TOKENS);
        _value(d, 0);
        _space(d);
        if (d.pos != data.length || d.tokens[0].kind != "{") revert InvalidResultJSON();
    }

    function member(Document memory d, uint256 object, bytes memory key) internal pure returns (uint256) {
        uint256 token = tryMember(d, object, key);
        if (token == 0) revert InvalidResultJSON();
        return token;
    }

    /// @dev Zero is an unambiguous missing token: the root is never a member value.
    function tryMember(Document memory d, uint256 object, bytes memory key) internal pure returns (uint256) {
        if (d.tokens[object].kind != "{") return 0;
        uint256 cursor = object + 1;
        for (uint256 i; i < d.tokens[object].size; ++i) {
            if (eq(d, cursor, key)) return cursor + 1;
            cursor = d.tokens[cursor + 1].next;
        }
        return 0;
    }

    function eq(Document memory d, uint256 token, bytes memory expected) internal pure returns (bool) {
        return
            d.tokens[token].end - d.tokens[token].start == expected.length
                && _tokenHash(d, token) == keccak256(expected);
    }

    function stringEq(Document memory d, uint256 token, bytes memory expected) internal pure returns (bool) {
        return d.tokens[token].kind == '"' && eq(d, token, expected);
    }

    function hashValue(Document memory d, uint256 token) internal pure returns (bytes32 result) {
        Token memory t = d.tokens[token];
        if (t.kind != '"' || t.end - t.start != 64) revert InvalidResultJSON();
        uint256 value;
        for (uint256 i = t.start; i < t.end; ++i) {
            uint8 c = uint8(d.data[i]);
            if (c >= 48 && c <= 57) c -= 48;
            else if (c >= 97 && c <= 102) c -= 87;
            else revert InvalidResultJSON();
            value = (value << 4) | c;
        }
        return bytes32(value);
    }

    /// @dev Select a 64-character hash without decoding every irrelevant entry. OR 0x20 folds
    /// ASCII hex A-F to a-f and leaves digits unchanged. Reject control bytes before folding:
    /// decoded U+0010..U+0019 would otherwise alias digits. Matched entries still pass strict
    /// lowercase hashValue; case aliases cannot hide a duplicate.
    function hashEq(Document memory d, uint256 token, bytes32 expectedTextHash) internal pure returns (bool) {
        Token memory t = d.tokens[token];
        if (t.kind != '"' || t.end - t.start != 64) return false;
        bytes memory data = d.data;
        uint256 start = t.start;
        bytes32 h;
        assembly ("memory-safe") {
            let mask := 0x2020202020202020202020202020202020202020202020202020202020202020
            let p := add(add(data, 32), start)
            let a := mload(p)
            let b := mload(add(p, 32))
            // Standard word-parallel byte < 32 predicate; any cross-byte borrow still
            // requires an earlier byte < 32, so the aggregate test has no false positive.
            let high := 0x8080808080808080808080808080808080808080808080808080808080808080
            let low := or(and(and(sub(a, mask), not(a)), high), and(and(sub(b, mask), not(b)), high))
            if iszero(low) {
                mstore(0, or(a, mask))
                mstore(32, or(b, mask))
                h := keccak256(0, 64)
            }
        }
        return h == expectedTextHash;
    }

    function uintValue(Document memory d, uint256 token) internal pure returns (uint256 value) {
        Token memory t = d.tokens[token];
        if (t.kind != "0" || t.end - t.start > 20) revert InvalidResultJSON();
        for (uint256 i = t.start; i < t.end; ++i) {
            uint8 c = uint8(d.data[i]);
            if (c < 48 || c > 57) revert InvalidResultJSON();
            value = value * 10 + c - 48;
        }
    }

    function _value(Document memory d, uint256 depth) private pure returns (uint256 index) {
        _space(d);
        if (depth > 16 || d.pos == d.data.length) revert InvalidResultJSON();
        if (d.count == d.tokens.length) revert ResultTokenLimit();
        index = d.count++;
        bytes1 c = d.data[d.pos];
        d.tokens[index].kind = c;
        d.tokens[index].start = d.pos;
        if (c == "{" || c == "[") {
            _container(d, index, depth, c == "{");
        } else if (c == '"') {
            _string(d, index);
        } else if (c == "t") {
            _literal(d, "true");
        } else if (c == "f") {
            _literal(d, "false");
        } else if (c == "n") {
            _literal(d, "null");
        } else {
            d.tokens[index].kind = "0";
            _number(d);
        }
        if (c != '"') d.tokens[index].end = d.pos;
        d.tokens[index].next = d.count;
    }

    function _container(Document memory d, uint256 index, uint256 depth, bool object) private pure {
        ++d.pos;
        _space(d);
        bytes1 close = object ? bytes1("}") : bytes1("]");
        if (_peek(d) == close) {
            ++d.pos;
            return;
        }
        bytes32[32] memory keys;
        while (true) {
            uint256 size = ++d.tokens[index].size;
            if (size > (object ? 32 : 128)) revert ResultContainerLimit();
            if (object) {
                if (_peek(d) != '"') revert InvalidResultJSON();
                uint256 key = _value(d, depth + 1);
                bytes32 h = _tokenHash(d, key);
                for (uint256 i; i + 1 < size; ++i) {
                    if (keys[i] == h) revert InvalidResultJSON();
                }
                keys[size - 1] = h;
                _space(d);
                if (_peek(d) != ":") revert InvalidResultJSON();
                ++d.pos;
            }
            _value(d, depth + 1);
            _space(d);
            bytes1 c = _peek(d);
            ++d.pos;
            if (c == close) return;
            if (c != ",") revert InvalidResultJSON();
            _space(d);
        }
    }

    function _tokenHash(Document memory d, uint256 token) private pure returns (bytes32 h) {
        bytes memory data = d.data;
        uint256 start = d.tokens[token].start;
        uint256 length = d.tokens[token].end - start;
        assembly ("memory-safe") { h := keccak256(add(add(data, 32), start), length) }
    }

    function _string(Document memory d, uint256 index) private pure {
        bytes memory data = d.data;
        uint256 p = d.pos + 1;
        uint256 w = p;
        d.tokens[index].start = p;
        while (p < data.length) {
            uint8 c = uint8(data[p++]);
            if (c == 34) {
                d.tokens[index].end = w;
                d.pos = p;
                return;
            }
            if (c < 32) revert InvalidResultJSON();
            if (c == 92) {
                if (p == data.length) revert InvalidResultJSON();
                c = uint8(data[p++]);
                if (c == 117) {
                    uint256 cp = _hex4(data, p);
                    p += 4;
                    if (cp >= 0xd800 && cp <= 0xdbff) {
                        if (p + 6 > data.length || data[p] != "\\" || data[p + 1] != "u") {
                            revert InvalidResultJSON();
                        }
                        uint256 low = _hex4(data, p + 2);
                        if (low < 0xdc00 || low > 0xdfff) revert InvalidResultJSON();
                        cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
                        p += 6;
                    } else if (cp >= 0xdc00 && cp <= 0xdfff) {
                        revert InvalidResultJSON();
                    }
                    w = _utf8Write(data, w, cp);
                    continue;
                }
                if (c == 98) c = 8;
                else if (c == 102) c = 12;
                else if (c == 110) c = 10;
                else if (c == 114) c = 13;
                else if (c == 116) c = 9;
                else if (c != 34 && c != 92 && c != 47) revert InvalidResultJSON();
                data[w++] = bytes1(c);
            } else if (c < 128) {
                data[w++] = bytes1(c);
            } else {
                uint256 n = c >= 0xc2 && c <= 0xdf ? 1 : c >= 0xe0 && c <= 0xef ? 2 : c >= 0xf0 && c <= 0xf4 ? 3 : 0;
                if (n == 0 || p + n > data.length) revert InvalidResultJSON();
                uint8 first = uint8(data[p]);
                if (
                    (c == 0xe0 && first < 0xa0) || (c == 0xed && first >= 0xa0) || (c == 0xf0 && first < 0x90)
                        || (c == 0xf4 && first >= 0x90)
                ) revert InvalidResultJSON();
                data[w++] = bytes1(c);
                for (uint256 i; i < n; ++i) {
                    c = uint8(data[p++]);
                    if (c < 0x80 || c > 0xbf) revert InvalidResultJSON();
                    data[w++] = bytes1(c);
                }
            }
        }
        revert InvalidResultJSON();
    }

    function _hex4(bytes memory data, uint256 p) private pure returns (uint256 value) {
        if (p + 4 > data.length) revert InvalidResultJSON();
        for (uint256 i; i < 4; ++i) {
            uint8 c = uint8(data[p + i]);
            if (c >= 48 && c <= 57) c -= 48;
            else if (c >= 97 && c <= 102) c -= 87;
            else if (c >= 65 && c <= 70) c -= 55;
            else revert InvalidResultJSON();
            value = (value << 4) | c;
        }
    }

    function _utf8Write(bytes memory data, uint256 w, uint256 cp) private pure returns (uint256) {
        if (cp < 0x80) {
            data[w++] = bytes1(uint8(cp));
        } else {
            if (cp >= 0x10000) {
                data[w++] = bytes1(uint8(0xf0 | (cp >> 18)));
                data[w++] = bytes1(uint8(0x80 | ((cp >> 12) & 63)));
            } else if (cp >= 0x800) {
                data[w++] = bytes1(uint8(0xe0 | (cp >> 12)));
            } else {
                data[w++] = bytes1(uint8(0xc0 | (cp >> 6)));
            }
            if (cp >= 0x800) data[w++] = bytes1(uint8(0x80 | ((cp >> 6) & 63)));
            data[w++] = bytes1(uint8(0x80 | (cp & 63)));
        }
        return w;
    }

    function _number(Document memory d) private pure {
        if (_peek(d) == "-") ++d.pos;
        bytes1 c = _peek(d);
        if (c == "0") {
            ++d.pos;
        } else {
            if (c < "1" || c > "9") revert InvalidResultJSON();
            _digits(d);
        }
        if (_peek(d) == ".") {
            ++d.pos;
            _digits(d);
        }
        c = _peek(d);
        if (c == "e" || c == "E") {
            ++d.pos;
            c = _peek(d);
            if (c == "+" || c == "-") ++d.pos;
            _digits(d);
        }
    }

    function _digits(Document memory d) private pure {
        uint256 start = d.pos;
        while (_peek(d) >= "0" && _peek(d) <= "9") ++d.pos;
        if (start == d.pos) revert InvalidResultJSON();
    }

    function _literal(Document memory d, bytes memory literal) private pure {
        for (uint256 i; i < literal.length; ++i) {
            if (_peek(d) != literal[i]) revert InvalidResultJSON();
            ++d.pos;
        }
    }

    function _peek(Document memory d) private pure returns (bytes1) {
        return d.pos < d.data.length ? d.data[d.pos] : bytes1(0);
    }

    function _space(Document memory d) private pure {
        while (d.pos < d.data.length) {
            bytes1 c = d.data[d.pos];
            if (c != " " && c != "\n" && c != "\r" && c != "\t") return;
            ++d.pos;
        }
    }
}

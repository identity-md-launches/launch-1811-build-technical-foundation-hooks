// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Bounded, strict JSON reader for authenticated IMD snapshots. Only printable ASCII strings are supported. No key/string escapes are
/// accepted: alternate spellings fail closed instead of requiring JSON Unicode normalization.
/// Object keys must be unique at EVERY depth. Arrays/objects have at most 128 items, depth 16,
/// and the document at most 2048 tokens. No caller-supplied offsets or substring proofs.
library ResultJson {
    error InvalidResultJSON();

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
        d.data = data;
        d.tokens = new Token[](data.length / 2 + 1 < 2048 ? data.length / 2 + 1 : 2048);
        _value(d, 0);
        _space(d);
        if (d.pos != data.length || d.tokens[0].kind != "{") revert InvalidResultJSON();
    }

    function member(Document memory d, uint256 object, bytes memory key) internal pure returns (uint256) {
        if (d.tokens[object].kind != "{") revert InvalidResultJSON();
        uint256 cursor = object + 1;
        for (uint256 i; i < d.tokens[object].size; ++i) {
            if (eq(d, cursor, key)) return cursor + 1;
            cursor = d.tokens[cursor + 1].next;
        }
        revert InvalidResultJSON();
    }

    function eq(Document memory d, uint256 token, bytes memory expected) internal pure returns (bool) {
        Token memory t = d.tokens[token];
        if (t.end - t.start != expected.length) return false;
        for (uint256 i; i < expected.length; ++i) {
            if (d.data[t.start + i] != expected[i]) return false;
        }
        return true;
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
        if (depth > 16 || d.pos == d.data.length || d.count == d.tokens.length) revert InvalidResultJSON();
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
        while (true) {
            if (++d.tokens[index].size > 128) revert InvalidResultJSON();
            if (object) {
                if (_peek(d) != '"') revert InvalidResultJSON();
                uint256 key = _value(d, depth + 1);
                _uniqueKey(d, index, key);
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

    function _uniqueKey(Document memory d, uint256 object, uint256 key) private pure {
        uint256 previous = object + 1;
        bytes32 h = _tokenHash(d, key);
        while (previous < key) {
            if (_tokenHash(d, previous) == h) revert InvalidResultJSON();
            previous = d.tokens[previous + 1].next;
        }
    }

    function _tokenHash(Document memory d, uint256 token) private pure returns (bytes32 h) {
        bytes memory data = d.data;
        uint256 start = d.tokens[token].start;
        uint256 length = d.tokens[token].end - start;
        assembly ("memory-safe") { h := keccak256(add(add(data, 32), start), length) }
    }

    function _string(Document memory d, uint256 index) private pure {
        d.tokens[index].start = ++d.pos;
        while (d.pos < d.data.length) {
            bytes1 c = d.data[d.pos++];
            if (c == '"') {
                d.tokens[index].end = d.pos - 1;
                return;
            }
            if (uint8(c) < 32 || uint8(c) > 126 || c == "\\") revert InvalidResultJSON();
        }
        revert InvalidResultJSON();
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

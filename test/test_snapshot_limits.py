"""The Python and Solidity readers must agree on UTF-8, aliases and all resource bounds."""
import json
import unittest

from sdk.hooks_store import ROOT, Rpc, StoreError
from sdk.result_snapshot import parse_snapshot, MAX_BYTES, MAX_TOKENS, MAX_OBJECT_MEMBERS, MAX_ARRAY_ITEMS
from test.helpers.local_rpc import LocalChain


class SnapshotLimitsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local = LocalChain().__enter__()
        cls.addClassCleanup(cls.local.__exit__, None, None, None)
        built = json.loads((ROOT / 'out/ParserGas.t.sol/ParserGasHarness.json').read_text())
        cls.harness = cls.local.send({'data':built['bytecode']['object']})['contractAddress']

    def check(self, raw, accepted):
        try:
            parse_snapshot(raw)
            sdk = True
        except StoreError:
            sdk = False
        try:
            Rpc(self.local.url).call(self.harness, 'parse(bytes)', '0x' + raw.hex())
            solidity = True
        except StoreError:
            solidity = False
        self.assertEqual((sdk, solidity), (accepted, accepted), repr(raw[:90]))

    def test_encoding_and_ignored_values(self):
        good = [b'{"note":"\\\" \\/ \\\\ \\b \\f \\n \\r \\t \\u0000"}',
                b'{"x":"\\uD83D\\uDE80"}', '{"café":"😀"}'.encode(),
                b'{"fi\\u006ces":[]}', b'{"empty":null,"number":-0.12e+42}',
                b'{"x":' + b'1' * (MAX_BYTES-6) + b'}']
        bad = [b'{"x":"\\uD800"}', b'{"x":"\\uDC00"}', b'{"x":"\\uD800\\u0041"}',
               b'{"x":"\xc0\x80"}', b'{"x":"\xed\xa0\x80"}', b'{"x":"\xf4\x90\x80\x80"}',
               b'{"x":"\\x41"}', b'{"x":"line\nbreak"}', b'{"x":NaN}', b'{"x":01}',
               '{"x":1}'.encode('utf-16'), b'{"files":[],"fi\\u006ces":[]}',
               '{"é":1,"\\u00e9":2}'.encode(), b'{"n":{"x":1,"\\u0078":2}}']
        for raw in good: self.check(raw, True)
        for raw in bad: self.check(raw, False)

    def test_decoded_unicode_aliases_match_at_utf8_boundaries(self):
        for cp in [0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff]:
            raw_key = json.dumps(chr(cp), ensure_ascii=False).encode()
            escaped_key = json.dumps(chr(cp), ensure_ascii=True).encode()
            self.check(b'{' + raw_key + b':0,' + escaped_key + b':1}', False)
        # Canonical Unicode normalization is deliberately not part of JSON string equality.
        self.check('{"e\u0301":0,"é":1}'.encode(), True)

    def test_exact_limits(self):
        self.check(b'{' + b' ' * (MAX_BYTES-2) + b'}', True)
        self.check(b'{' + b' ' * (MAX_BYTES-1) + b'}', False)
        for n in (MAX_OBJECT_MEMBERS, MAX_OBJECT_MEMBERS+1):
            self.check(json.dumps({str(i): 0 for i in range(n)}).encode(), n == MAX_OBJECT_MEMBERS)
        for n in (MAX_ARRAY_ITEMS, MAX_ARRAY_ITEMS+1):
            self.check(json.dumps({'x':[0]*n}).encode(), n == MAX_ARRAY_ITEMS)
        # root(1), key(1), array(1), 3 arrays(3)+384 numbers, final array(1)+121 numbers = 512.
        self.check(json.dumps({'x':[[0]*128]*3+[[0]*121]}).encode(), True)
        self.check(json.dumps({'x':[[0]*128]*3+[[0]*122]}).encode(), False)
        for n in (15, 16):
            raw = b'{"x":'+b'['*n+b'0'+b']'*n+b'}'
            self.check(raw, n == 15)
        self.assertEqual(MAX_TOKENS, 512)

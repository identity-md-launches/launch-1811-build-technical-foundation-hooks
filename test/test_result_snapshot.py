"""Offline snapshot/evidence attack corpus; all values here are explicitly local fixtures."""
import copy
import hashlib
import json
import unittest

from sdk.hooks_store import ROOT, StoreError, keccak_hex
from sdk.result_snapshot import approval_document, parse_snapshot, verify_snapshot as verify_bound_snapshot

DIGEST = keccak_hex('local artifact A')
SOURCE = hashlib.sha256(b'local accepted source bundle').hexdigest()
SUBMISSION = hashlib.sha256(b'local accepted submission').hexdigest()


EVIDENCE = b'canonical test evidence'

def verify_snapshot(*args, **kwargs):
    kwargs.setdefault('source_submission', '0x' + SUBMISSION)
    kwargs.setdefault('evidence', EVIDENCE)
    return verify_bound_snapshot(*args, **kwargs)


def snapshot():
    approval = approval_document(DIGEST)
    return {'jobId': 'd8ec4ec9-b939-4ff8-8ce1-fad7a6a69bd9', 'state': 'completed', 'complete': True,
            'launch': {'requested': False}, 'delivery': {'requested': False},
            'source': [{'hash': SOURCE, 'submissionHash': SUBMISSION}],
            'files': [{'name': 'hooksStoreApproval', 'path': 'artifacts/hooks-store-approval.json',
                       'mediaType': 'application/json', 'hash': hashlib.sha256(approval).hexdigest(),
                       'bytes': len(approval), 'submissionHash': SUBMISSION},
                      {'name': 'hooksStoreEvidence', 'path': 'artifacts/hooks-store-evidence.json',
                       'mediaType': 'application/json', 'hash': hashlib.sha256(EVIDENCE).hexdigest(),
                       'bytes': len(EVIDENCE), 'submissionHash': SUBMISSION}]}


def encoded(v):
    return json.dumps(v, separators=(',', ':')).encode()


class SnapshotTest(unittest.TestCase):
    def test_irrelevant_escaped_controls_cannot_alias_hex_digits(self):
        s = snapshot()
        s['source'][0]['hash'] = '1' * 64
        s['source'].append({'hash': '\x11' * 64})
        proof = verify_snapshot(encoded(s), DIGEST, '0x' + '1' * 64)
        self.assertEqual(proof['source'], s['source'][0])

    def test_accepted_file_reconstructs_canonical_evidence(self):
        raw = encoded(snapshot())
        proof = verify_snapshot(raw, DIGEST, '0x' + SOURCE, approval=approval_document(DIGEST))
        self.assertEqual(proof['approvalDocument'].encode(), approval_document(DIGEST))
        with self.assertRaisesRegex(StoreError, 'canonical'):
            verify_snapshot(raw, DIGEST, '0x' + SOURCE, approval=approval_document(DIGEST) + b'\n')

    def test_rejected_alternative_cannot_become_approved(self):
        s = snapshot()
        rejected = keccak_hex('local artifact B')
        s['hooksStoreArtifact'] = DIGEST
        s['rejected'] = {'hooksStoreArtifact': rejected, 'files': copy.deepcopy(s['files'])}
        s['rejected']['files'][0]['hash'] = hashlib.sha256(approval_document(rejected)).hexdigest()
        verify_snapshot(encoded(s), DIGEST, '0x' + SOURCE)
        with self.assertRaisesRegex(StoreError, 'another artifact'):
            verify_snapshot(encoded(s), rejected, '0x' + SOURCE)
        s['files'] = []
        with self.assertRaisesRegex(StoreError, 'exactly one'):
            verify_snapshot(encoded(s), rejected, '0x' + SOURCE)

    def test_duplicate_keys_rejected_at_every_depth(self):
        raw = encoded(snapshot())
        for field in [b'"complete":true', b'"name":"hooksStoreApproval"', b'"hash":"' + SOURCE.encode() + b'"']:
            bad = raw.replace(field, field + b',' + field)
            with self.assertRaisesRegex(StoreError, 'duplicate'):
                verify_snapshot(bad, DIGEST, '0x' + SOURCE)

    def test_metadata_mismatch_duplicate_source_or_file_cannot_authorize(self):
        cases = []
        for key, value in [('hash', '0' * 64), ('submissionHash', '0' * 64), ('bytes', 158.0),
                           ('bytes', 157), ('mediaType', 'text/plain'), ('name', 'rejected'),
                           ('path', 'artifacts/rejected.json')]:
            s = snapshot(); s['files'][0][key] = value; cases.append(s)
        for where in ['source', 'files']:
            s = snapshot(); s[where] += copy.deepcopy(s[where]); cases.append(s)
        for field, value in [('complete', 'true'), ('complete', False), ('state', 'pending'), ('jobId', DIGEST)]:
            s = snapshot(); s[field] = value; cases.append(s)
        for s in cases:
            with self.subTest(s=s), self.assertRaises(StoreError):
                verify_snapshot(encoded(s), DIGEST, '0x' + SOURCE)

    def test_real_retained_control_plane_result_has_no_approval(self):
        raw = (ROOT / 'docs/checks/approval-binding/sources/previous-job-result.json').read_bytes()
        actual = parse_snapshot(raw)
        self.assertEqual(actual['jobId'], 'd8ec4ec9-b939-4ff8-8ce1-fad7a6a69bd9')
        self.assertEqual(actual['files'], [])
        with self.assertRaisesRegex(StoreError, 'submission mismatch'):
            verify_snapshot(raw, DIGEST, '0x' + actual['source'][0]['hash'])

    def test_retained_offline_fixture_hash_chain(self):
        root = ROOT / 'docs/checks/approval-binding/fixtures'
        meta = json.loads((root / 'provenance.json').read_text())
        raw = (root / 'completion.json').read_bytes()
        self.assertEqual(keccak_hex('0x' + raw.hex()), meta['resultHash'])
        self.assertEqual(hashlib.sha256((root / 'source.bundle').read_bytes()).hexdigest(), meta['sourceSha256'])
        self.assertEqual(keccak_hex('0x' + (root / 'build-identity.json').read_bytes().hex()), meta['buildKeccak256'])
        # Historical v1 publication remains readable, but cannot authorize the v2 gate.
        with self.assertRaises(StoreError):
            verify_snapshot(raw, meta['artifactDigest'], '0x' + meta['sourceSha256'],
                            approval=(root / 'approval.json').read_bytes())

    def test_parser_bounds_escapes_and_non_json_fail_closed(self):
        deep = b'{"x":' + b'[' * 17 + b'0' + b']' * 17 + b'}'
        for raw in [b'{"x":NaN}', b'{"x":Infinity}', b'{"x":01}', b'{"x":1,}', b'{}{}',
                    b'{"x":"\\uD800"}', b'{"x":"\xff"}', b'[]', deep,
                    b'{"x":[' + b','.join([b'0'] * 129) + b']}', b' ' * 12289]:
            with self.subTest(raw=raw[:80]), self.assertRaises(StoreError):
                parse_snapshot(raw)

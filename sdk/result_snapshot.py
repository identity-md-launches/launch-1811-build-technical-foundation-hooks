"""Offline, bounded verification of the exact IMD completion snapshot and worker publication.

Callers must check keccak256(raw) against Intake resultHash BEFORE parsing. Publication proves
which evidence a worker supplied, not that the oracle approved it or a reviewer accepted it.
"""
import hashlib
import json
import re

from sdk.hooks_store import StoreError, _hex

NAME = 'hooksStoreApproval'
PATH = 'artifacts/hooks-store-approval.json'
MAX_BYTES = 12288
MAX_TOKENS = 512
MAX_OBJECT_MEMBERS = 32
MAX_ARRAY_ITEMS = 128
MAX_DEPTH = 16


def approval_document(digest):
    digest = _hex(digest, 32, 'artifact digest')
    return ('{"schema":"hooks-store-approval-v2","hooksStoreArtifact":"' + digest +
            '","publication":"review-evidence"}').encode('ascii')


def evidence_document(reviewed_build, source_submission, review_submission):
    return ('{"schema":"hooks-store-evidence-v1","reviewedBuild":"' +
            _hex(reviewed_build, 32, 'reviewed build digest') + '","sourceSubmission":"' +
            _hex(source_submission, 32, 'source submission') + '","reviewSubmission":"' +
            _hex(review_submission, 32, 'review submission') + '"}').encode('ascii')


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise StoreError('duplicate JSON key in completion snapshot (including escaped aliases)')
        result[key] = value
    return result


def parse_snapshot(raw):
    if not isinstance(raw, bytes) or not 0 < len(raw) <= MAX_BYTES:
        raise StoreError(f'completion snapshot must be 1..{MAX_BYTES} bytes')
    try:
        # Decode strictly: json.loads(bytes) alone also accepts UTF-16/32, which Solidity does not.
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError('non-JSON number')),
                           parse_int=lambda text: int(text) if len(text) <= 20 else text_to_number(text))
    except StoreError:
        raise
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise StoreError('invalid completion snapshot JSON') from exc
    count = 0

    def walk(v, depth=0):
        nonlocal count
        count += 1
        if depth > MAX_DEPTH or count > MAX_TOKENS:
            raise StoreError('completion snapshot exceeds JSON token/depth bounds')
        if isinstance(v, str):
            # Reject isolated surrogates; valid escaped pairs have already combined into a scalar.
            try:
                v.encode('utf-8')
            except UnicodeError as exc:
                raise StoreError('invalid Unicode scalar in completion snapshot') from exc
        if isinstance(v, (dict, list)):
            if len(v) > (MAX_OBJECT_MEMBERS if isinstance(v, dict) else MAX_ARRAY_ITEMS):
                raise StoreError('completion snapshot exceeds container bounds')
            for item in v:
                if isinstance(v, dict):
                    walk(item, depth + 1)
                    walk(v[item], depth + 1)
                else:
                    walk(item, depth + 1)
    walk(value)
    if not isinstance(value, dict):
        raise StoreError('completion snapshot must be an object')
    return value


class JsonNumber:
    """Ignored long numbers remain valid JSON without Python's integer digit limit."""
    def __init__(self, text):
        self.text = text


def text_to_number(text):
    return JsonNumber(text)


def _hash(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        raise StoreError('accepted evidence hash must be 64 lowercase hex characters')
    return value


def verify_snapshot(raw, digest, source_hash, *, source_submission, evidence, approval=None):
    value = parse_snapshot(raw)
    if (not isinstance(value.get('jobId'), str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value['jobId']) or
            value.get('complete') is not True or value.get('state') != 'completed'):
        raise StoreError('snapshot is not a completed IMD job')
    source_hash = _hex(source_hash, 32, 'source hash')[2:]
    source_submission = _hex(source_submission, 32, 'source submission')[2:]
    doc = approval_document(digest)
    if approval is not None and approval != doc:
        raise StoreError('approval file must equal the exact canonical approved-artifact document')
    if not isinstance(evidence, bytes) or not evidence:
        raise StoreError('canonical reviewed-build evidence bytes required')
    try:
        sources, files = value['source'], value['files']
        if not isinstance(sources, list) or not isinstance(files, list):
            raise StoreError('source/files must be arrays')
        matched_sources = [s for s in sources if isinstance(s, dict) and isinstance(s.get('hash'), str) and s['hash'].lower() == source_hash]
        if len(matched_sources) != 1 or int(source_hash, 16) == 0:
            raise StoreError('snapshot does not name exactly one accepted artifact source')
        _hash(matched_sources[0]['hash'])
        if int(source_submission, 16) == 0 or _hash(matched_sources[0]['submissionHash']) != source_submission:
            raise StoreError('accepted source submission mismatch')

        def selected(name, path, content):
            matches = []
            for f in files:
                if not isinstance(f, dict):
                    continue
                n, p = f.get('name'), f.get('path')
                if n == name or p == path:
                    if n != name or p != path:
                        raise StoreError('ambiguous approved-artifact file name/path')
                    matches.append(f)
            if len(matches) != 1:
                raise StoreError('snapshot must name exactly one accepted approval/evidence file')
            f = matches[0]
            if (f['mediaType'] != 'application/json' or type(f['bytes']) is not int or f['bytes'] != len(content) or
                    int(_hash(f['submissionHash']), 16) == 0):
                raise StoreError('invalid accepted approval/evidence file metadata')
            if _hash(f['hash']) != hashlib.sha256(content).hexdigest():
                raise StoreError('accepted approval/evidence file names another artifact')
            return f

        f = selected(NAME, PATH, doc)
        e = selected('hooksStoreEvidence', 'artifacts/hooks-store-evidence.json', evidence)
        if f['submissionHash'] != e['submissionHash']:
            raise StoreError('approval and evidence must have the same accepted publication submission')
    except (KeyError, TypeError) as exc:
        raise StoreError('missing or invalid accepted source/file metadata') from exc
    return {'snapshotJobId': value['jobId'], 'source': matched_sources[0], 'approval': f, 'evidence': e,
            'approvalDocument': doc.decode('ascii'), 'approvalSha256': hashlib.sha256(doc).hexdigest(),
            'path': 'resultHash -> exact completion snapshot -> accepted publication -> artifact digest',
            'workerPublicationOnly': True}

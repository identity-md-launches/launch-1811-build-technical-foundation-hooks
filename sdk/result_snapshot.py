"""Strict offline verification of IMD completion snapshot -> accepted source/approval.

The snapshot's exact bytes must separately match the Intake resultHash. This module mirrors
AcceptedArtifact/ResultJson's deliberately bounded JSON subset, and never fetches a URL.
SHA-256 is IMD's accepted file/bundle hash; keccak256 is the completion snapshot hash.
"""
import hashlib
import json
import re

from sdk.hooks_store import StoreError, _hex

NAME = 'hooksStoreApproval'
PATH = 'artifacts/hooks-store-approval.json'


def approval_document(digest):
    digest = _hex(digest, 32, 'artifact digest')
    return ('{"schema":"hooks-store-approval-v1","hooksStoreArtifact":"' + digest +
            '","review":"passed"}').encode('ascii')


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise StoreError('duplicate JSON key in completion snapshot')
        result[key] = value
    return result


def parse_snapshot(raw):
    if not isinstance(raw, bytes) or not 0 < len(raw) <= 65536:
        raise StoreError('completion snapshot must be 1..65536 bytes')
    # Match the contract: escaped strings, non-ASCII and alternate encodings fail closed.
    if b'\\' in raw or any(c > 126 for c in raw):
        raise StoreError('unsupported escaped/non-ASCII completion snapshot')
    try:
        value = json.loads(raw, object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError('non-JSON number')))
    except StoreError:
        raise
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise StoreError('invalid completion snapshot JSON') from exc
    count = 0

    def walk(v, depth=0):
        nonlocal count
        count += 1
        if depth > 16 or count > 2048:
            raise StoreError('completion snapshot exceeds JSON bounds')
        if isinstance(v, (dict, list)):
            if len(v) > 128:
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


def _hash(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        raise StoreError('accepted evidence hash must be 64 lowercase hex characters')
    return value


def verify_snapshot(raw, digest, source_hash, *, approval=None):
    value = parse_snapshot(raw)
    if (not isinstance(value.get('jobId'), str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value['jobId']) or
            value.get('complete') is not True or value.get('state') != 'completed'):
        raise StoreError('snapshot is not a completed IMD job')
    source_hash = _hex(source_hash, 32, 'source hash')[2:]
    doc = approval_document(digest)
    if approval is not None and approval != doc:
        raise StoreError('approval file must equal the exact canonical approved-artifact document')
    try:
        sources, files = value['source'], value['files']
        if not isinstance(sources, list) or not isinstance(files, list):
            raise StoreError('source/files must be arrays')
        matched_sources = []
        for source in sources:
            if _hash(source['hash']) == source_hash:
                if int(_hash(source['submissionHash']), 16) == 0:
                    raise StoreError('missing accepted source submission')
                matched_sources.append(source)
        if len(matched_sources) != 1 or int(source_hash, 16) == 0:
            raise StoreError('snapshot does not name exactly one accepted artifact source')
        matches = []
        for f in files:
            name, path = f['name'], f['path']
            if name == NAME or path == PATH:
                if name != NAME or path != PATH:
                    raise StoreError('ambiguous approved-artifact file name/path')
                matches.append(f)
        if len(matches) != 1:
            raise StoreError('snapshot must name exactly one accepted approval file')
        f = matches[0]
        if (f['mediaType'] != 'application/json' or type(f['bytes']) is not int or f['bytes'] != len(doc) or
                int(_hash(f['submissionHash']), 16) == 0):
            raise StoreError('invalid accepted approval file metadata')
        expected_hash = hashlib.sha256(doc).hexdigest()
        if _hash(f['hash']) != expected_hash:
            raise StoreError('accepted approval file names another artifact')
    except (KeyError, TypeError) as exc:
        raise StoreError('missing or invalid accepted source/file metadata') from exc
    return {'snapshotJobId': value['jobId'], 'source': matched_sources[0], 'approval': f,
            'approvalDocument': doc.decode('ascii'), 'approvalSha256': expected_hash,
            'path': 'resultHash -> exact completion snapshot -> files[hooksStoreApproval] -> artifact digest'}

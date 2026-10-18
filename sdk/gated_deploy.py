"""Exact signed ArtifactV2 -> oracle-verdict checks -> mined salt -> UNSIGNED deployment calldata.

Read-only: uses eth_chainId, eth_getCode and eth_call only, never signs or sends. Every gate the
contract enforces is also re-run here through `check(...)` as an eth_call, so a transaction this
tool prints is one the contract would accept at the read block (it can still go stale before it is
mined, for example if the address becomes occupied, the manager is disabled or the job ages out).

Usage:
  python3 -m sdk.gated_deploy --rpc URL --deployer 0x.. --job 0x.. \
      --creation-code code.hex --constructor-args args.hex

Automatic mode reads the immutable candidate from the requester; no caller-supplied artifact
metadata or result JSON is needed. This tool only prints an unsigned transaction.
Legacy owner-confirmed mode additionally requires the exact completion snapshot and accepted files.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

from sdk.hooks_store import Rpc, StoreError, _cast, _hex, keccak_hex
from sdk.result_snapshot import verify_snapshot, evidence_document

ARTIFACT = "(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,uint256,address,address,bytes32,uint160)"
JOB_STATUS = ["None", "Open", "Delivered", "Failed", "Expired"]
REVIEW_STATUS = ["None", "Pending", "Passed", "NotPassed", "Unanswered"]
PAGE = 4096
CHECK_GAS = 10_000_000  # bounded full pre-CREATE2 check; see ParserGas.t.sol and consolidated evidence


def _word(ret, i):
    body = ret[2:]
    return "0x" + body[64 * i: 64 * (i + 1)]


def _addr(word):
    return "0x" + word[-40:]


def artifact_tuple(a):
    return "(" + ",".join([a["jobRequestId"], a["sourceHash"], a["sourceSubmissionHash"], a["reviewSubmissionHash"], a["evidenceHash"], a["buildHash"], a["creationCodeHash"],
                           a["constructorArgsHash"], a["runtimeCodeHash"], str(a["chainId"]), a["deployer"],
                           a["poolManager"], a["poolManagerCodeHash"], str(a["permissions"])]) + ")"


def prepare(rpc, *, deployer, job, result_document=b"", creation_code, constructor_args, source_hash, build_hash,
            runtime_hash, pool_manager, permissions, source_submission, review_submission, max_pages=64, binding_mode="automatic", approval_document=None):
    if binding_mode not in ("automatic", "owner-confirmed"):
        raise StoreError("unsupported binding mode")
    deployer = _hex(deployer, 20, "deployer")
    supports_automatic = int(rpc.call(deployer, "automaticBindingSupported()(bool)"), 16) == 1
    if binding_mode == "automatic" and not supports_automatic:
        raise StoreError("automatic binding disabled for this legacy deployer/requester")
    if binding_mode == "owner-confirmed" and supports_automatic:
        raise StoreError("owner-confirmed mode requires a legacy requester; select automatic")
    job = _hex(job, 32, "job")
    pool_manager = _hex(pool_manager, 20, "pool manager")
    creation_code = _hex(creation_code, (len(creation_code) - 2) // 2, "creation code")
    constructor_args = _hex(constructor_args, (len(constructor_args) - 2) // 2, "constructor args")
    if not isinstance(result_document, (bytes, bytearray)):
        raise StoreError("result document must be bytes")
    evidence = []
    chain_id = int(rpc.request("eth_chainId", []), 16)
    manager_code = rpc.code(pool_manager)
    if manager_code in ("0x", ""):
        raise StoreError("pool manager has no code at the read block")
    if rpc.code(deployer) in ("0x", ""):
        raise StoreError("deployer has no code at the read block")
    a = {
        "jobRequestId": job, "sourceHash": _hex(source_hash, 32, "source hash"),
        "sourceSubmissionHash": _hex(source_submission, 32, "source submission"),
        "reviewSubmissionHash": _hex(review_submission, 32, "review submission"),
        "evidenceHash": "0x" + "00" * 32,  # excluded from its own preimage, not a deployment parameter
        "buildHash": _hex(build_hash, 32, "build hash"), "creationCodeHash": keccak_hex(creation_code),
        "constructorArgsHash": keccak_hex(constructor_args), "runtimeCodeHash": _hex(runtime_hash, 32, "runtime"),
        "chainId": chain_id, "deployer": deployer, "poolManager": pool_manager,
        "poolManagerCodeHash": keccak_hex(manager_code), "permissions": int(permissions, 0),
    }
    if int(a["sourceSubmissionHash"], 16) == 0 or int(a["reviewSubmissionHash"], 16) == 0 or a["sourceSubmissionHash"] == a["reviewSubmissionHash"]:
        raise StoreError("distinct nonzero accepted source and review submissions required")
    core_digest = _word(rpc.call(deployer, f"artifactDigest({ARTIFACT})", artifact_tuple(a)), 0)
    evidence_doc = evidence_document(core_digest, a["sourceSubmissionHash"], a["reviewSubmissionHash"])
    a["evidenceHash"] = "0x" + hashlib.sha256(evidence_doc).hexdigest()
    tup = artifact_tuple(a)

    requester = _addr(rpc.call(deployer, "requester()(address)"))
    ret = rpc.call(requester, "getJob(bytes32)", job)
    # Job is a static tuple: requester, openedAt, deadline, status, review, ..., resultHash at index 11.
    job_requester = _addr(_word(ret, 0))
    status, review = int(_word(ret, 3), 16), int(_word(ret, 4), 16)
    result_hash = _word(ret, 11)
    review_request_id = _word(ret, 13)
    evidence.append({"check": "job status", "value": JOB_STATUS[status], "ok": status == 2})
    evidence.append({"check": "oracle-signed review verdict", "value": REVIEW_STATUS[review], "ok": review == 2})
    if binding_mode == "owner-confirmed":
        doc_hash = keccak_hex("0x" + bytes(result_document).hex())
        evidence.append({"check": "result document hash == job resultHash", "value": doc_hash,
                         "ok": doc_hash == result_hash.lower()})
    digest = _word(rpc.call(deployer, f"artifactDigest({ARTIFACT})", tup), 0)

    failed = [e["check"] for e in evidence if not e["ok"]]
    if failed:
        raise StoreError("refused before mining: " + "; ".join(failed))

    if binding_mode == "automatic":
        approved = rpc.call(requester, "approvedArtifact(bytes32)(bytes32)", job).lower()
        if approved != digest.lower():
            raise StoreError("signed oracle question authorizes another artifact or no artifact")
        evidence.append({"check": "exact ArtifactV2 authorized by reconstructed signed question", "value": digest, "ok": True})
        # The exact result was part of the signed question; parser bytes are not deployment authority.
        result_document = b""
    else:
        proof = verify_snapshot(bytes(result_document), digest, a["sourceHash"], source_submission=a["sourceSubmissionHash"], evidence=evidence_doc, approval=approval_document)
        evidence.append({"check": "accepted source and canonical approved-artifact file", "value": proof, "ok": True})
    ask = review_request_id
    epoch = int(rpc.call(requester, "reviewReceiptSignerEpoch(bytes32)", ask), 16)
    if epoch == 0 or int(rpc.call(requester, "revokedSignerEpochs(uint32)", str(epoch)), 16) != 0:
        raise StoreError("approval signer epoch missing or revoked")
    evidence.append({"check": "authenticated signer epoch", "value": epoch, "ok": True})

    init_hash = keccak_hex(creation_code + constructor_args[2:])
    start, salt, hook = 0, None, None
    for _ in range(max_pages):
        ret = rpc.call(deployer, "mine(bytes32,uint160,uint256,uint256)", init_hash, str(a["permissions"]),
                       str(start), str(PAGE))
        if int(_word(ret, 0), 16):
            salt, hook = _word(ret, 1), _addr(_word(ret, 2))
            break
        start = int(_word(ret, 3), 16)
    if salt is None:
        raise StoreError(f"no salt found; resume mining at nonce {start}")
    doc_hex = "0x" + bytes(result_document).hex()
    # The contract's own complete pre-CREATE2 gate, as the job requester.
    check_data = _cast("calldata", f"check({ARTIFACT},bytes,bytes,bytes,bytes32,address)", tup, doc_hex,
                       creation_code, constructor_args, salt, job_requester)
    ret = rpc.request("eth_call", [{"to": deployer, "data": check_data, "gas": hex(CHECK_GAS)}, rpc.block])
    if _addr(_word(ret, 0)) != hook.lower() or _word(ret, 1) != digest:
        raise StoreError("contract check disagrees with mined plan")
    evidence.append({"check": "GatedHookDeployer.check (eth_call)", "value": hook, "ok": True})
    data = _cast("calldata", f"deploy({ARTIFACT},bytes,bytes,bytes,bytes32,address)", tup, doc_hex, creation_code,
                 constructor_args, salt, hook)
    return {
        "unsigned": True,
        "bindingMode": binding_mode,
        "automaticBindingSupported": binding_mode == "automatic",
        "trust": ("The existing v2 oracle signer and panel attested the exact onchain question and ArtifactV2. No per-job owner binding."
                  if binding_mode == "automatic" else
                  "Owner asserted the Intake-to-oracle binding (no protocol proof); oracle signer authenticated the answer. Worker publication alone is not approval."),
        "readBlock": rpc.block,
        "artifact": a,
        "artifactDigest": digest,
        "evidenceDocument": evidence_doc.decode(),
        "salt": salt,
        "hook": hook,
        "evidence": evidence,
        "transaction": {"chainId": chain_id, "from": job_requester, "to": deployer, "value": "0x0", "data": data},
    }


def read_candidate(rpc, requester, job):
    raw = rpc.call(requester, "getCandidate(bytes32)", _hex(job, 32, "job"))
    _hex(raw, 15 * 32, "candidate ABI response")
    fields = ["jobRequestId", "sourceHash", "sourceSubmissionHash", "reviewSubmissionHash", "evidenceHash",
              "buildHash", "creationCodeHash", "constructorArgsHash", "runtimeCodeHash", "chainId", "deployer",
              "poolManager", "poolManagerCodeHash", "permissions"]
    a = {name: _word(raw, i) for i, name in enumerate(fields)}
    for name in ("chainId", "permissions"):
        a[name] = int(a[name], 16)
    for name in ("deployer", "poolManager"):
        a[name] = _addr(a[name])
    commit_word = _word(raw, 14)
    if commit_word[42:] != "0" * 24 or int(commit_word[:42], 16) == 0 or a["jobRequestId"].lower() != job.lower():
        raise StoreError("no committed candidate for this job or malformed reviewed commit")
    return a, commit_word[:42]


def prepare_automatic(rpc, *, deployer, job, creation_code, constructor_args, max_pages=64):
    deployer = _hex(deployer, 20, "deployer")
    if int(rpc.call(deployer, "automaticBindingSupported()(bool)"), 16) != 1:
        raise StoreError("automatic binding disabled for this legacy deployer/requester")
    requester = _addr(rpc.call(deployer, "requester()(address)"))
    a, commit = read_candidate(rpc, requester, job)
    if a["deployer"].lower() != deployer:
        raise StoreError("candidate names another deployer")
    out = prepare(rpc, deployer=deployer, job=job, creation_code=creation_code, constructor_args=constructor_args,
                  source_hash=a["sourceHash"], build_hash=a["buildHash"], runtime_hash=a["runtimeCodeHash"],
                  pool_manager=a["poolManager"], permissions=hex(a["permissions"]), source_submission=a["sourceSubmissionHash"],
                  review_submission=a["reviewSubmissionHash"], max_pages=max_pages)
    out["reviewedCommit"] = commit
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for name in ("rpc", "deployer", "job", "creation-code", "constructor-args"):
        p.add_argument("--" + name, required=True)
    manual_fields = ("source-hash", "build-hash", "runtime-hash", "pool-manager", "permissions", "source-submission", "review-submission")
    for name in manual_fields:
        p.add_argument("--" + name, help="legacy owner-confirmed mode only")
    p.add_argument("--result-document", help="required only for legacy owner-confirmed mode")
    p.add_argument("--binding-mode", choices=["automatic", "owner-confirmed"], default="automatic")
    p.add_argument("--approval-document", help="accepted approval file; must match the canonical bytes exactly")
    args = p.parse_args(argv)
    try:
        if args.binding_mode == "automatic":
            if any(getattr(args, name.replace("-", "_")) is not None for name in manual_fields):
                raise StoreError("automatic mode reads the committed candidate; omit manual artifact fields")
            out = prepare_automatic(Rpc(args.rpc), deployer=args.deployer, job=args.job,
                                    creation_code=Path(args.creation_code).read_text().strip(),
                                    constructor_args=Path(args.constructor_args).read_text().strip())
        else:
            if not args.result_document or any(getattr(args, name.replace("-", "_")) is None for name in manual_fields):
                raise StoreError("legacy mode requires the exact result document and all artifact metadata")
            out = prepare(
                Rpc(args.rpc), deployer=args.deployer, job=args.job,
                result_document=Path(args.result_document).read_bytes() if args.result_document else b"",
                creation_code=Path(args.creation_code).read_text().strip(),
                constructor_args=Path(args.constructor_args).read_text().strip(),
                source_hash=args.source_hash, build_hash=args.build_hash, runtime_hash=args.runtime_hash,
                source_submission=args.source_submission, review_submission=args.review_submission,
                pool_manager=args.pool_manager, permissions=args.permissions, binding_mode=args.binding_mode,
                approval_document=Path(args.approval_document).read_bytes() if args.approval_document else None,
            )
    except StoreError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 2
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

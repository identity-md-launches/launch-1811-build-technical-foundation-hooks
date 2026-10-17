"""IMD completion snapshot -> accepted evidence -> oracle-verdict checks -> mined salt -> UNSIGNED GatedHookDeployer.deploy calldata.

Read-only: uses eth_chainId, eth_getCode and eth_call only, never signs or sends. Every gate the
contract enforces is also re-run here through `check(...)` as an eth_call, so a transaction this
tool prints is one the contract would accept at the read block (it can still go stale before it is
mined, for example if the address becomes occupied, the manager is disabled or the job ages out).

Usage:
  python3 -m sdk.gated_deploy --rpc URL --deployer 0x.. --job 0x.. --result-document result.json \
      --creation-code code.hex --constructor-args args.hex --source-hash 0x.. --build-hash 0x.. \
      --runtime-hash 0x.. --pool-manager 0x.. --permissions 0x.. --binding-mode owner-confirmed
"""
import argparse
import json
import sys
from pathlib import Path

from sdk.hooks_store import Rpc, StoreError, _cast, _hex, keccak_hex
from sdk.result_snapshot import verify_snapshot

ARTIFACT = "(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,uint256,address,address,bytes32,uint160)"
JOB_STATUS = ["None", "Open", "Delivered", "Failed", "Expired"]
REVIEW_STATUS = ["None", "Pending", "Passed", "NotPassed", "Unanswered"]
PAGE = 4096


def _word(ret, i):
    body = ret[2:]
    return "0x" + body[64 * i: 64 * (i + 1)]


def _addr(word):
    return "0x" + word[-40:]


def artifact_tuple(a):
    return "(" + ",".join([a["jobRequestId"], a["sourceHash"], a["buildHash"], a["creationCodeHash"],
                           a["constructorArgsHash"], a["runtimeCodeHash"], str(a["chainId"]), a["deployer"],
                           a["poolManager"], a["poolManagerCodeHash"], str(a["permissions"])]) + ")"


def prepare(rpc, *, deployer, job, result_document, creation_code, constructor_args, source_hash, build_hash,
            runtime_hash, pool_manager, permissions, max_pages=64, binding_mode="automatic", approval_document=None):
    if binding_mode != "owner-confirmed":
        raise StoreError("automatic binding disabled: official protocol supplies no authenticated Intake/body -> "
                         "oracle UUID/canonical question proof; only explicit owner-confirmed local/manual use is supported")
    deployer = _hex(deployer, 20, "deployer")
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
        "buildHash": _hex(build_hash, 32, "build hash"), "creationCodeHash": keccak_hex(creation_code),
        "constructorArgsHash": keccak_hex(constructor_args), "runtimeCodeHash": _hex(runtime_hash, 32, "runtime"),
        "chainId": chain_id, "deployer": deployer, "poolManager": pool_manager,
        "poolManagerCodeHash": keccak_hex(manager_code), "permissions": int(permissions, 0),
    }
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
    doc_hash = keccak_hex("0x" + bytes(result_document).hex())
    evidence.append({"check": "result document hash == job resultHash", "value": doc_hash,
                     "ok": doc_hash == result_hash.lower()})
    digest = _word(rpc.call(deployer, f"artifactDigest({ARTIFACT})", tup), 0)

    failed = [e["check"] for e in evidence if not e["ok"]]
    if failed:
        raise StoreError("refused before mining: " + "; ".join(failed))

    proof = verify_snapshot(bytes(result_document), digest, a["sourceHash"], approval=approval_document)
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
    ret = rpc.call(deployer, f"check({ARTIFACT},bytes,bytes,bytes,bytes32,address)", tup, doc_hex, creation_code,
                   constructor_args, salt, job_requester)
    if _addr(_word(ret, 0)) != hook.lower() or _word(ret, 1) != digest:
        raise StoreError("contract check disagrees with mined plan")
    evidence.append({"check": "GatedHookDeployer.check (eth_call)", "value": hook, "ok": True})
    data = _cast("calldata", f"deploy({ARTIFACT},bytes,bytes,bytes,bytes32,address)", tup, doc_hex, creation_code,
                 constructor_args, salt, hook)
    return {
        "unsigned": True,
        "bindingMode": "owner-confirmed",
        "automaticBindingSupported": False,
        "trust": "Owner authenticated the Intake-to-oracle binding; oracle signer authenticated the verdict.",
        "readBlock": rpc.block,
        "artifact": a,
        "artifactDigest": digest,
        "salt": salt,
        "hook": hook,
        "evidence": evidence,
        "transaction": {"chainId": chain_id, "from": job_requester, "to": deployer, "value": "0x0", "data": data},
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for name in ("rpc", "deployer", "job", "result-document", "creation-code", "constructor-args", "source-hash",
                 "build-hash", "runtime-hash", "pool-manager", "permissions"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--binding-mode", choices=["automatic", "owner-confirmed"], default="automatic")
    p.add_argument("--approval-document", help="accepted approval file; must match the canonical bytes exactly")
    args = p.parse_args(argv)
    try:
        out = prepare(
            Rpc(args.rpc), deployer=args.deployer, job=args.job,
            result_document=Path(args.result_document).read_bytes(),
            creation_code=Path(args.creation_code).read_text().strip(),
            constructor_args=Path(args.constructor_args).read_text().strip(),
            source_hash=args.source_hash, build_hash=args.build_hash, runtime_hash=args.runtime_hash,
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

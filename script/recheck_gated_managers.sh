#!/usr/bin/env bash
# Read-only: compares each pinned PoolManager's live code hash with GatedHookDeployer's pins.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, subprocess, sys
m = json.load(open("docs/checks/gated-deployment/managers.json"))
bad = 0
for e in m["managers"]:
    chain = subprocess.run(["cast", "chain-id", "-r", e["rpc"]], capture_output=True, text=True).stdout.strip()
    code = subprocess.run(["cast", "code", e["poolManager"], "-r", e["rpc"]], capture_output=True, text=True).stdout.strip()
    h = subprocess.run(["cast", "keccak", code], capture_output=True, text=True).stdout.strip() if code not in ("", "0x") else "none"
    ok = chain == str(e["chainId"]) and h == e["codeHash"]
    bad += not ok
    print(("OK  " if ok else "BAD ") + f'{e["name"]} chain={chain} hash={h}')
src = open("src/deployment/GatedHookDeployer.sol").read()
for e in m["managers"]:
    if e["poolManager"] not in src or e["codeHash"] not in src:
        bad += 1; print("BAD source pin missing for", e["name"])
sys.exit(1 if bad else 0)
PY

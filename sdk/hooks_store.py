"""Dependency-free Store adapter: Python stdlib + Foundry `cast` + locally built artifacts.

Both creators supply HookSpec dictionaries. This module validates, mines using eth_call,
builds unsigned calldata, and verifies deployments. It never signs or submits transactions.
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

TEMPLATE = "hooks-store/bounded-swap/v1"
PERMISSIONS = ["afterInitialize", "beforeSwap", "afterSwap"]
MASK = 0x10C0
TYPE = "(uint32,bytes32,uint256,address,bytes32,uint160,uint128)"
TYPE_TEXT = (
    "HookSpec(uint32 schemaVersion,bytes32 templateId,uint256 chainId,address poolManager,"
    "bytes32 poolManagerCodeHash,uint160 permissions,uint128 maxSpecifiedAmount)"
)
FIELDS = {
    "schemaVersion", "templateId", "chainId", "poolManager", "poolManagerCodeHash",
    "permissions", "maxSpecifiedAmount",
}
TEST_CHAINS = {31337, 11155111, 84532, 46630}
EMPTY_CODE_HASH = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
ROOT = Path(__file__).resolve().parents[1]


class StoreError(ValueError):
    pass


def _cast(*args):
    result = subprocess.run(["cast", *args], text=True, capture_output=True, check=False, timeout=30)
    if result.returncode:
        # Do not include command arguments (which may contain caller-supplied data) in diagnostics.
        raise StoreError("cast failed; check the installed Foundry version and input encoding")
    return result.stdout.strip()


def keccak_hex(value):
    return _cast("keccak", value).lower()


def _hex(value, size, field):
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{%d}" % (size * 2), value):
        raise StoreError(f"{field} must be a {size}-byte hex string")
    return value.lower()


def _decimal(value, bits, field):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]*", value):
        raise StoreError(f"{field} must be a positive decimal string without leading zeroes")
    if len(value) > 78 or int(value) >= 1 << bits:
        raise StoreError(f"{field} exceeds uint{bits}")
    return value


def normalize_spec(value):
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise StoreError("HookSpec must contain exactly the v1 schema fields")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise StoreError("unsupported schemaVersion")
    if value["templateId"] != TEMPLATE:
        raise StoreError("unsupported templateId")
    if value["permissions"] != PERMISSIONS:
        raise StoreError("v1 requires exactly afterInitialize, beforeSwap, afterSwap in that order")
    result = dict(value)
    result["permissions"] = list(PERMISSIONS)
    result["chainId"] = _decimal(value["chainId"], 256, "chainId")
    result["maxSpecifiedAmount"] = _decimal(value["maxSpecifiedAmount"], 128, "maxSpecifiedAmount")
    result["poolManager"] = _hex(value["poolManager"], 20, "poolManager")
    result["poolManagerCodeHash"] = _hex(value["poolManagerCodeHash"], 32, "poolManagerCodeHash")
    if int(result["poolManager"], 16) == 0:
        raise StoreError("poolManager must be supplied and nonzero")
    if int(result["poolManagerCodeHash"], 16) == 0 or result["poolManagerCodeHash"] == EMPTY_CODE_HASH:
        raise StoreError("poolManagerCodeHash must identify nonempty reviewed code")
    return result


def build_spec(*, chain_id, pool_manager, pool_manager_code_hash, max_specified_amount):
    """Common entry for chat structured output and visual fields. No inferred chain/address defaults."""
    return normalize_spec({
        "schemaVersion": 1, "templateId": TEMPLATE, "chainId": chain_id,
        "poolManager": pool_manager, "poolManagerCodeHash": pool_manager_code_hash,
        "permissions": list(PERMISSIONS), "maxSpecifiedAmount": max_specified_amount,
    })


def abi_tuple(spec):
    spec = normalize_spec(spec)
    template_id = keccak_hex("0x" + TEMPLATE.encode().hex())
    return "(" + ",".join([
        "1", template_id, spec["chainId"], spec["poolManager"], spec["poolManagerCodeHash"],
        str(MASK), spec["maxSpecifiedAmount"],
    ]) + ")"


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise StoreError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=_unique_object)


def _artifact(name, root):
    value = load_json(Path(root) / "out" / (name + ".sol") / (name + ".json"))
    creation = value["bytecode"]["object"]
    runtime = value["deployedBytecode"]["object"]
    for code in (creation, runtime):
        if not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", code):
            raise StoreError("artifact contains missing bytecode or unresolved library references")
    if value["deployedBytecode"].get("immutableReferences"):
        raise StoreError("v1 runtime hashing requires artifacts without immutable substitutions")
    return creation.lower(), runtime.lower()


class Rpc:
    """Read-only RPC client. Every state read in an operation uses one explicit block number."""

    def __init__(self, url):
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            raise StoreError("RPC must be an HTTP(S) URL")
        self.url = url
        # Explicit transport settings: no machine-level proxy discovery or credential configuration.
        self.transport = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.counter = 0
        self.block = self.request("eth_blockNumber", [])

    def request(self, method, params):
        if method not in {"eth_chainId", "eth_blockNumber", "eth_getCode", "eth_call"}:
            raise StoreError("only read-only RPC methods are permitted")
        self.counter += 1
        payload = json.dumps({"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, payload, {"Content-Type": "application/json"})
        try:
            with self.transport.open(request, timeout=30) as response:
                data = json.load(response)
        except Exception as exc:
            # Endpoints can contain API credentials; never echo the URL or transport exception.
            raise StoreError("RPC transport failed") from exc
        if "error" in data:
            raise StoreError(f"{method} failed; inspect the RPC response privately for revert details")
        if data.get("id") != self.counter or "result" not in data:
            raise StoreError("invalid JSON-RPC response")
        return data["result"]

    def code(self, address):
        return self.request("eth_getCode", [address, self.block]).lower()

    def call(self, address, signature, *args):
        data = _cast("calldata", signature, *args)
        return self.request("eth_call", [{"to": address, "data": data}, self.block])


def _words(value, count):
    value = _hex(value, count * 32, "ABI response")
    return [value[2 + 64 * i:2 + 64 * (i + 1)] for i in range(count)]


def _plan_words(plan):
    values = [
        int(plan["spec"]["chainId"]), int(plan["factory"], 16), int(plan["predictedAddress"], 16),
        int(plan["salt"], 16), int(plan["specHash"], 16), int(plan["initCodeHash"], 16),
        int(plan["runtimeCodeHash"], 16), MASK,
    ]
    return [f"{value:064x}" for value in values]


class StoreClient:
    def __init__(self, rpc, factory, artifact_root=ROOT):
        self.rpc = rpc
        self.factory = _hex(factory, 20, "factory")
        self.hook_creation, self.hook_runtime = _artifact("BoundedSwapHook", artifact_root)
        _, self.factory_runtime = _artifact("HooksStoreFactory", artifact_root)

    def _preflight(self, spec):
        spec = normalize_spec(spec)
        chain = int(spec["chainId"])
        if chain not in TEST_CHAINS:
            raise StoreError("this release permits only local chain 31337 and named testnets; mainnets are disabled")
        if int(self.rpc.request("eth_chainId", []), 16) != chain:
            raise StoreError("RPC chain does not match HookSpec")
        if self.rpc.code(self.factory) != self.factory_runtime:
            raise StoreError("factory code differs from the local build")
        code = self.rpc.code(spec["poolManager"])
        if code == "0x" or keccak_hex(code) != spec["poolManagerCodeHash"]:
            raise StoreError("PoolManager code is missing or differs from HookSpec")
        return spec

    def _plan(self, spec, salt):
        salt = _hex(salt, 32, "salt")
        encoded_tuple = abi_tuple(spec)
        args = _cast("abi-encode", "f(" + TYPE + ")", encoded_tuple).lower()
        init_hash = keccak_hex(self.hook_creation + args[2:])
        type_hash = keccak_hex("0x" + TYPE_TEXT.encode().hex())
        spec_hash = keccak_hex(type_hash + args[2:])
        prediction_hash = keccak_hex("0xff" + self.factory[2:] + salt[2:] + init_hash[2:])
        predicted = "0x" + prediction_hash[-40:]
        if int(predicted, 16) & 0x3FFF != MASK:
            raise StoreError("salt does not produce the exact callback mask")
        calldata = _cast("calldata", f"deploy({TYPE},bytes32,address,bytes32)", encoded_tuple, salt, predicted, init_hash)
        return {
            "planVersion": 1, "spec": spec, "factory": self.factory, "salt": salt,
            "predictedAddress": predicted, "specHash": spec_hash, "initCodeHash": init_hash,
            "runtimeCodeHash": keccak_hex(self.hook_runtime), "factoryCodeHash": keccak_hex(self.factory_runtime),
            "permissionBits": MASK, "constructorArgs": args,
            "transaction": {"chainId": hex(int(spec["chainId"])), "to": self.factory, "data": calldata, "value": "0x0"},
        }

    def plan(self, spec, *, start_nonce=0, page_size=4096, max_pages=32):
        spec = self._preflight(spec)
        if type(start_nonce) is not int or start_nonce < 0 or type(page_size) is not int or not 1 <= page_size <= 131072:
            raise StoreError("invalid mining range")
        if type(max_pages) is not int or not 1 <= max_pages <= 1024:
            raise StoreError("max_pages must be between 1 and 1024")
        encoded_tuple = abi_tuple(spec)
        start = start_nonce
        for _ in range(max_pages):
            if start + page_size >= 1 << 256:
                raise StoreError("mining range exceeds uint256")
            result = _words(self.rpc.call(self.factory, f"mine({TYPE},uint256,uint256)", encoded_tuple, str(start), str(page_size)), 4)
            found, salt_int, address_int, next_nonce = [int(word, 16) for word in result]
            if found == 1:
                if not start <= salt_int < start + page_size or next_nonce != salt_int + 1 or address_int >= 1 << 160:
                    raise StoreError("invalid miner response")
                plan = self._plan(spec, "0x" + result[1])
                if int(plan["predictedAddress"], 16) != address_int:
                    raise StoreError("miner and local CREATE2 prediction disagree")
                onchain = self.rpc.call(self.factory, f"preview({TYPE},bytes32)", encoded_tuple, plan["salt"])
                if _words(onchain, 8) != _plan_words(plan):
                    raise StoreError("factory and local build plans disagree")
                if self.rpc.code(plan["predictedAddress"]) != "0x":
                    raise StoreError("predicted address is already occupied")
                return plan
            # A page cut short by the RPC's eth_call gas cap reports the first unchecked nonce.
            if found != 0 or not start < next_nonce <= start + page_size:
                raise StoreError("invalid exhausted-page response")
            start = next_nonce
        raise StoreError(f"search exhausted; resume with start_nonce={start}")

    def verify(self, plan):
        if not isinstance(plan, dict) or "spec" not in plan or "salt" not in plan:
            raise StoreError("invalid deployment plan")
        spec = self._preflight(plan["spec"])
        expected = self._plan(spec, plan["salt"])
        if plan != expected:
            raise StoreError("plan fields or unsigned transaction were changed")
        hook = expected["predictedAddress"]
        if self.rpc.code(hook) != self.hook_runtime:
            raise StoreError("deployed hook bytecode differs from the local build, or no deployment exists")
        response = self.rpc.call(self.factory, f"verify({TYPE},bytes32,address)", abi_tuple(spec), plan["salt"], hook)
        if _words(response, 8) != _plan_words(expected):
            raise StoreError("onchain verification disagrees with the committed plan")
        return {
            "status": "verified-on-chain", "chainId": spec["chainId"], "blockNumber": self.rpc.block,
            "hook": hook, "specHash": expected["specHash"], "runtimeCodeHash": expected["runtimeCodeHash"],
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("spec")
    plan = commands.add_parser("plan")
    plan.add_argument("spec")
    plan.add_argument("--rpc", required=True)
    plan.add_argument("--factory", required=True)
    plan.add_argument("--start-nonce", type=int, default=0)
    plan.add_argument("--page-size", type=int, default=4096)
    plan.add_argument("--max-pages", type=int, default=32)
    plan.add_argument("--artifact-root", type=Path, default=ROOT)
    verify = commands.add_parser("verify")
    verify.add_argument("plan")
    verify.add_argument("--rpc", required=True)
    verify.add_argument("--artifact-root", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        if args.command == "validate":
            result = normalize_spec(load_json(args.spec))
        elif args.command == "plan":
            client = StoreClient(Rpc(args.rpc), args.factory, args.artifact_root)
            result = client.plan(load_json(args.spec), start_nonce=args.start_nonce, page_size=args.page_size, max_pages=args.max_pages)
        else:
            deployment_plan = load_json(args.plan)
            client = StoreClient(Rpc(args.rpc), deployment_plan["factory"], args.artifact_root)
            result = client.verify(deployment_plan)
        print(json.dumps(result, indent=2, sort_keys=True))
    except (StoreError, OSError, KeyError, ValueError, subprocess.SubprocessError) as exc:
        print(f"hooks-store: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Run with: python3 -m unittest discover -s test -p 'test_*.py' -v.

Integration tests create a private local Anvil process. No remote chain or private key is used.
forge build must run first; all Python dependencies are from the standard library.
"""

import copy
import json
import socket
import subprocess
import time
import unittest
import urllib.request

from sdk.hooks_store import (
    FIELDS, MASK, PERMISSIONS, ROOT, Rpc, StoreClient, StoreError,
    _artifact, _cast, _unique_object, abi_tuple, build_spec, keccak_hex, normalize_spec,
)


class StoreSdkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        cls.url = f"http://127.0.0.1:{cls.port}"
        cls.anvil = subprocess.Popen(
            ["anvil", "--host", "127.0.0.1", "--port", str(cls.port), "--chain-id", "31337", "--silent"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        cls.addClassCleanup(cls.stop_anvil)
        for _ in range(100):
            try:
                cls.account = cls.rpc("eth_accounts", [])[0]
                break
            except OSError:
                if cls.anvil.poll() is not None:
                    raise RuntimeError("local Anvil exited")
                time.sleep(0.03)
        else:
            raise RuntimeError("local Anvil did not start")
        # Owner comes from this disposable Anvil instance, not a hard-coded production address.
        manager_code = json.loads((ROOT / "out/PoolManager.sol/PoolManager.json").read_text())["bytecode"]["object"]
        constructor_args = _cast("abi-encode", "f(address)", cls.account)
        cls.manager = cls.send({"data": manager_code + constructor_args[2:]})["contractAddress"]
        factory_code, _ = _artifact("HooksStoreFactory", ROOT)
        cls.factory = cls.send({"data": factory_code})["contractAddress"]
        cls.manager_hash = keccak_hex(cls.rpc("eth_getCode", [cls.manager, "latest"]))

    @classmethod
    def stop_anvil(cls):
        cls.anvil.terminate()
        try:
            cls.anvil.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.anvil.kill()
            cls.anvil.wait(timeout=5)

    @classmethod
    def rpc(cls, method, params):
        data = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        request = urllib.request.Request(cls.url, data, {"Content-Type": "application/json"})
        transport = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with transport.open(request, timeout=5) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["result"]

    @classmethod
    def send(cls, transaction):
        transaction = dict(transaction)
        transaction.update({"from": cls.account, "gas": hex(15_000_000)})
        transaction.pop("chainId", None)
        tx_hash = cls.rpc("eth_sendTransaction", [transaction])
        receipt = cls.rpc("eth_getTransactionReceipt", [tx_hash])
        if not receipt or receipt["status"] != "0x1":
            raise AssertionError("local transaction failed")
        return receipt

    def setUp(self):
        self.spec = build_spec(
            chain_id="31337", pool_manager=self.manager, pool_manager_code_hash=self.manager_hash,
            max_specified_amount="1000000",
        )

    def client(self):
        return StoreClient(Rpc(self.url), self.factory)

    def test_chat_and_visual_use_identical_canonical_spec(self):
        # These are structured outputs, not a claim to implement an NLP service or visual UI.
        chat_output = json.loads(json.dumps(self.spec))
        visual_output = build_spec(
            chain_id=self.spec["chainId"], pool_manager=self.spec["poolManager"],
            pool_manager_code_hash=self.spec["poolManagerCodeHash"], max_specified_amount="1000000",
        )
        self.assertEqual(normalize_spec(chat_output), visual_output)
        self.assertEqual(abi_tuple(chat_output), abi_tuple(visual_output))

    def test_plan_deploy_and_verify_real_create2_locally(self):
        # Unique spec for this test; no reliance on unittest execution order.
        self.spec["maxSpecifiedAmount"] = "2000001"
        plan = self.client().plan(self.spec)
        self.assertEqual(int(plan["predictedAddress"], 16) & 0x3FFF, MASK)
        self.assertEqual(self.rpc("eth_getCode", [plan["predictedAddress"], "latest"]), "0x")
        with self.assertRaises(StoreError):
            self.client().verify(plan)
        receipt = self.send(plan["transaction"])
        self.assertEqual(len(receipt["logs"]), 1)  # Only HookDeployed, no token or pool creation event.
        evidence = self.client().verify(plan)
        self.assertEqual(evidence["status"], "verified-on-chain")
        self.assertEqual(evidence["hook"], plan["predictedAddress"])
        self.assertEqual(evidence["specHash"], plan["specHash"])
        client = self.client()
        manager_word = client.rpc.call(plan["predictedAddress"], "poolManager()")
        limit_word = client.rpc.call(plan["predictedAddress"], "maxSpecifiedAmount()")
        self.assertEqual(int(manager_word, 16), int(self.manager, 16))
        self.assertEqual(int(limit_word, 16), 2000001)
        tampered = copy.deepcopy(plan)
        tampered["transaction"]["to"] = self.manager
        with self.assertRaisesRegex(StoreError, "changed"):
            self.client().verify(tampered)
        tampered = copy.deepcopy(plan)
        tampered["spec"]["maxSpecifiedAmount"] = "2"
        with self.assertRaises(StoreError):
            self.client().verify(tampered)

    def test_manager_code_and_factory_must_match(self):
        self.spec["poolManagerCodeHash"] = keccak_hex("0x1234")
        with self.assertRaisesRegex(StoreError, "PoolManager code"):
            self.client().plan(self.spec)
        with self.assertRaisesRegex(StoreError, "factory code"):
            StoreClient(Rpc(self.url), self.manager).plan(self.spec)

    def test_chain_mismatch_and_mainnets_rejected(self):
        for chain in ("1", "8453", "4663", "42"):
            self.spec["chainId"] = chain
            with self.assertRaisesRegex(StoreError, "mainnets are disabled"):
                self.client().plan(self.spec)
        self.spec["chainId"] = "11155111"
        with self.assertRaisesRegex(StoreError, "RPC chain"):
            self.client().plan(self.spec)

    def test_read_only_client_refuses_transaction_submission(self):
        with self.assertRaisesRegex(StoreError, "read-only"):
            Rpc(self.url).request("eth_sendTransaction", [])

    def test_unknown_fields_and_duplicate_json_keys_rejected(self):
        self.spec["owner"] = self.account
        with self.assertRaises(StoreError):
            normalize_spec(self.spec)
        with self.assertRaisesRegex(StoreError, "duplicate"):
            json.loads('{"schemaVersion":1,"schemaVersion":2}', object_pairs_hook=_unique_object)

    def test_every_required_field_is_required(self):
        for field in FIELDS:
            value = dict(self.spec)
            value.pop(field)
            with self.assertRaises(StoreError):
                normalize_spec(value)

    def test_versions_templates_and_permissions_fail_closed(self):
        for field, invalid in (
            ("schemaVersion", 2), ("schemaVersion", True), ("schemaVersion", "1"),
            ("templateId", "user-supplied-solidity"), ("permissions", PERMISSIONS[::-1]),
            ("permissions", PERMISSIONS + ["beforeSwapReturnDelta"]),
        ):
            value = dict(self.spec)
            value[field] = invalid
            with self.assertRaises(StoreError):
                normalize_spec(value)

    def test_numeric_boundaries_and_no_float_coercion(self):
        for field, bits in (("chainId", 256), ("maxSpecifiedAmount", 128)):
            for invalid in ("0", "-1", "01", "1e6", "1.0", 1, 1.5, True, str(1 << bits)):
                value = dict(self.spec)
                value[field] = invalid
                with self.assertRaises(StoreError):
                    normalize_spec(value)
            value = dict(self.spec)
            value[field] = str((1 << bits) - 1)
            self.assertEqual(normalize_spec(value)[field], value[field])

    def test_schema_document_matches_shared_constants(self):
        schema = json.loads((ROOT / "schemas/hook-spec.v1.schema.json").read_text())
        self.assertEqual(set(schema["required"]), FIELDS)
        self.assertEqual(schema["properties"]["permissions"]["const"], PERMISSIONS)
        self.assertFalse(schema["additionalProperties"])


if __name__ == "__main__":
    unittest.main()

"""Job result -> verdict checks -> unsigned GatedHookDeployer calldata, on disposable local Anvil.

The verdict source here is MockVerdictRequester (LOCAL only); the oracle signature path is
covered by the Foundry suite against the real HookJobRequester (test/GatedHookDeployer.t.sol).
"""
import json
import hashlib
from unittest.mock import Mock
import unittest

from sdk.gated_deploy import prepare
from sdk.result_snapshot import approval_document
from sdk.hooks_store import ROOT, Rpc, StoreError, _cast, keccak_hex
from test.helpers.local_rpc import LocalChain

FLAGS = (1 << 11) | (1 << 4)  # beforeAddLiquidity | afterDonate
JOB = "0x" + "11" * 32


def _built(path, name):
    return json.loads((ROOT / f"out/{path}/{name}.json").read_text())


class GatedDeployToolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local = LocalChain().__enter__()
        cls.addClassCleanup(cls.local.__exit__, None, None, None)
        cls.owner, cls.creator = cls.local.accounts[1:3]
        cls.manager = cls.local.deploy("PoolManager", "f(address)", cls.owner)
        cls.requester = cls.local.deploy("MockVerdictRequester")
        cls.deployer = cls.local.deploy("GatedHookDeployer", "f(address,address)", cls.owner, cls.requester)
        code_hash = keccak_hex(Rpc(cls.local.url).code(cls.manager))
        cls.local.call_transaction(cls.deployer, "setManager(address,bytes32,bool)", cls.manager, code_hash, "true",
                                   sender=cls.owner)
        hook = _built("GeneratedHooks.sol", "GeneratedHook")
        cls.code = hook["bytecode"]["object"]
        cls.runtime = keccak_hex(hook["deployedBytecode"]["object"])
        cls.args = _cast("abi-encode", "f(address,uint160)", cls.manager, str(FLAGS))

    def setUp(self):
        self.snapshot = self.local.request("evm_snapshot", [])

    def tearDown(self):
        self.assertTrue(self.local.request("evm_revert", [self.snapshot]))

    def _params(self, doc):
        return dict(deployer=self.deployer, job=JOB, result_document=doc, creation_code=self.code,
                    constructor_args=self.args, source_hash="0x" + "22" * 32, build_hash="0x" + "33" * 32,
                    runtime_hash=self.runtime, pool_manager=self.manager, permissions=hex(FLAGS), binding_mode="owner-confirmed")

    def _digest(self):
        # Ask the contract for the canonical digest of the artifact this tool will build.
        chain = 31337
        tup = "(" + ",".join([JOB, "0x" + "22" * 32, "0x" + "33" * 32, keccak_hex(self.code), keccak_hex(self.args),
                              self.runtime, str(chain), self.deployer, self.manager,
                              keccak_hex(Rpc(self.local.url).code(self.manager)), str(FLAGS)]) + ")"
        return Rpc(self.local.url).call(self.deployer, "artifactDigest((bytes32,bytes32,bytes32,bytes32,bytes32,"
                                        "bytes32,uint256,address,address,bytes32,uint160))", tup)

    def _job(self, doc, status=2, review=2):
        self.local.call_transaction(self.requester, "setJob(bytes32,address,uint8,uint8,bytes32)", JOB, self.creator,
                                    str(status), str(review), keccak_hex("0x" + doc.hex()))

    def _doc(self):
        approval = approval_document(self._digest())
        snapshot = {"jobId": "d8ec4ec9-b939-4ff8-8ce1-fad7a6a69bd9", "complete": True, "state": "completed",
                    "launch": {"requested": False}, "delivery": {"requested": False},
                    "source": [{"hash": "22" * 32, "submissionHash": hashlib.sha256(b"local source submission").hexdigest()}],
                    "files": [{"name": "hooksStoreApproval", "path": "artifacts/hooks-store-approval.json",
                               "mediaType": "application/json", "bytes": len(approval),
                               "hash": hashlib.sha256(approval).hexdigest(),
                               "submissionHash": hashlib.sha256(b"local review submission").hexdigest()}]}
        return json.dumps(snapshot, separators=(",", ":")).encode()

    def test_success_produces_unsigned_calldata_the_contract_accepts(self):
        doc = self._doc()
        self._job(doc)
        out = prepare(Rpc(self.local.url), **self._params(doc))
        self.assertTrue(out["unsigned"])
        self.assertEqual(out["transaction"]["from"].lower(), self.creator.lower())
        self.assertEqual(int(out["hook"], 16) & 0x3FFF, FLAGS)
        receipt = self.local.send({k: v for k, v in out["transaction"].items() if k != "chainId"})
        self.assertEqual(receipt["status"], "0x1")
        rpc = Rpc(self.local.url)
        self.assertEqual(keccak_hex(rpc.code(out["hook"])), self.runtime)
        self.assertEqual(rpc.call(self.deployer, "deployedHookOf(bytes32)", JOB)[-40:], out["hook"][-40:].lower())

    def test_not_passed_review_refused(self):
        doc = self._doc()
        self._job(doc, review=3)
        with self.assertRaisesRegex(StoreError, "oracle-signed review verdict"):
            prepare(Rpc(self.local.url), **self._params(doc))

    def test_undelivered_job_refused(self):
        doc = self._doc()
        self._job(doc, status=1)
        with self.assertRaisesRegex(StoreError, "job status"):
            prepare(Rpc(self.local.url), **self._params(doc))

    def test_substituted_document_refused(self):
        doc = self._doc()
        self._job(doc)
        with self.assertRaisesRegex(StoreError, "resultHash"):
            prepare(Rpc(self.local.url), **self._params(doc + b" "))

    def test_substituted_constructor_args_refused(self):
        doc = self._doc()
        self._job(doc)
        params = self._params(doc)
        params["constructor_args"] = _cast("abi-encode", "f(address,uint160)", self.manager, str(FLAGS | 1))
        with self.assertRaisesRegex(StoreError, "another artifact"):
            prepare(Rpc(self.local.url), **params)

    def test_automatic_route_is_disabled_before_any_rpc(self):
        params = self._params(b"{}")
        params.pop("binding_mode")
        rpc = Mock()
        with self.assertRaisesRegex(StoreError, "automatic binding disabled"):
            prepare(rpc, **params)
        self.assertEqual(rpc.mock_calls, [])

    def test_nested_rejected_alternative_does_not_approve_substitution(self):
        doc = json.loads(self._doc())
        doc["rejected"] = {"hooksStoreArtifact": "0x" + "aa" * 32}
        raw = json.dumps(doc, separators=(",", ":")).encode()
        self._job(raw)
        out = prepare(Rpc(self.local.url), **self._params(raw))
        self.assertFalse(out["automaticBindingSupported"])
        self.assertEqual(out["bindingMode"], "owner-confirmed")
        self.assertTrue(all(e["ok"] for e in out["evidence"]))

    def test_duplicate_approval_and_changed_file_hash_are_refused(self):
        for duplicate in (True, False):
            doc = json.loads(self._doc())
            if duplicate:
                doc["files"].append(dict(doc["files"][0]))
            else:
                doc["files"][0]["hash"] = hashlib.sha256(b"rejected alternative").hexdigest()
            raw = json.dumps(doc).encode()
            self._job(raw)
            with self.assertRaisesRegex(StoreError, "exactly one|another artifact"):
                prepare(Rpc(self.local.url), **self._params(raw))


if __name__ == "__main__":
    unittest.main()

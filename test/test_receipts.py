"""Deterministic deadline tests; delayed mining is also exercised against disposable Anvil."""
import unittest
from unittest.mock import patch

from sdk.hooks_store import ReceiptReverted, ReceiptTimeout, StoreError, wait_for_receipt

TX = "0x" + "ab" * 32  # local receipt vector, not an operational transaction
GOOD = {"transactionHash": TX, "status": "0x1", "blockHash": "0x" + "cd" * 32}


class ReceiptTest(unittest.TestCase):
    def test_pending_then_mined_succeeds(self):
        values = iter([None, None, GOOD])
        with patch("sdk.hooks_store.time.sleep") as sleep:
            self.assertEqual(wait_for_receipt(lambda *a, **k: next(values), TX), GOOD)
        self.assertEqual(sleep.call_count, 2)

    def test_timeout_is_bounded_including_rpc_time(self):
        now = [0.0]
        calls = []
        def request(*args, timeout):
            calls.append(timeout)
            now[0] += 0.2
            return None
        def sleep(seconds):
            now[0] += seconds
        with patch("sdk.hooks_store.time.monotonic", side_effect=lambda: now[0]), \
                patch("sdk.hooks_store.time.sleep", side_effect=sleep):
            with self.assertRaisesRegex(ReceiptTimeout, "pending"):
                wait_for_receipt(request, TX, timeout=0.5, poll_interval=0.1)
        self.assertEqual(len(calls), 2)
        self.assertLessEqual(now[0], 0.5)
        self.assertAlmostEqual(calls[1], 0.2)

    def test_reverted_receipt_is_not_pending_and_never_retried(self):
        with patch("sdk.hooks_store.time.sleep") as sleep:
            with self.assertRaisesRegex(ReceiptReverted, "reverted"):
                wait_for_receipt(lambda *a, **k: {**GOOD, "status": "0x0"}, TX)
        sleep.assert_not_called()

    def test_bad_receipts_and_bad_bounds_fail_closed(self):
        for receipt in ({}, {**GOOD, "status": "0x2"}, {**GOOD, "transactionHash": "0x" + "ef" * 32}):
            with self.subTest(receipt=receipt), self.assertRaises(StoreError):
                wait_for_receipt(lambda *a, **k: receipt, TX)
        for value in (0, -1, float("nan"), float("inf"), True, 601):
            with self.subTest(value=value), self.assertRaises(StoreError):
                wait_for_receipt(lambda *a, **k: GOOD, TX, timeout=value)

    def test_rpc_error_is_not_misreported_as_transaction_revert(self):
        def request(*args, **kwargs):
            raise StoreError("RPC transport failed")
        with self.assertRaisesRegex(StoreError, "transport"):
            wait_for_receipt(request, TX)

    def test_transport_expiring_at_overall_deadline_is_a_receipt_timeout(self):
        now = [0.0]
        def request(*args, timeout):
            now[0] += timeout
            raise TimeoutError("transport expired")
        with patch("sdk.hooks_store.time.monotonic", side_effect=lambda: now[0]):
            with self.assertRaisesRegex(ReceiptTimeout, "deadline"):
                wait_for_receipt(request, TX, timeout=0.5)

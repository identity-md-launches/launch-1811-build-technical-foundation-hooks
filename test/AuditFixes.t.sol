// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {HookSpec, HookSpecLib} from "../src/HookSpec.sol";
import {BoundedSwapHook} from "../src/BoundedSwapHook.sol";
import {HooksStoreFactory} from "../src/HooksStoreFactory.sol";
import {IHooksStore} from "../src/interfaces/IHooksStore.sol";
import {HookMiner} from "../src/deployment/HookMiner.sol";
import {DeploymentPolicy} from "../src/deployment/DeploymentPolicy.sol";
import {DeployHook} from "../script/DeployHook.s.sol";
import {DeployStore} from "../script/DeployStore.s.sol";

/// @dev Follow-up tests for audit job 0baee611 against foundation commit 42119ec.
contract AuditFixesTest is Fixture {
    /// @dev Typical provider caps on eth_call gas are 25M-50M; 10M is a conservative budget.
    uint256 internal constant CALL_GAS_BUDGET = 10_000_000;

    // ---- chain rejection, on every release path ----

    function _assertEveryReleasePathRejects(uint256 id) internal {
        bytes memory policy = abi.encodeWithSelector(DeploymentPolicy.UnsupportedDeploymentChain.selector, id);
        // Plan prepared on the local chain, so only the chain differs at deploy time.
        IHooksStore.Plan memory plan = _plan(spec);
        DeployHook script = new DeployHook();
        DeployStore bootstrap = new DeployStore();
        address broadcaster = makeAddr("broadcaster");

        vm.chainId(id);
        HookSpec memory onChain = spec;
        onChain.chainId = id;

        vm.expectRevert(policy);
        new HooksStoreFactory();
        // The real plan, with the spec's chain matching the chain: only the policy can refuse it.
        vm.expectRevert(policy);
        factory.deploy(onChain, plan.salt, plan.hook, plan.initCodeHash);
        vm.expectRevert(policy);
        factory.deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
        vm.expectRevert(policy);
        bootstrap.run(broadcaster);
        vm.expectRevert(policy);
        script.prepare(address(factory), onChain, 0, 1);
        vm.expectRevert(policy);
        script.execute(address(factory), onChain, plan);
        vm.expectRevert(policy);
        script.run(broadcaster, address(factory), onChain, 0, 1);
        assertEq(plan.hook.code.length, 0, "nothing deployed");
        assertEq(factory.deployedSpecHash(plan.hook), bytes32(0));
    }

    function testEthereumMainnetRejectedOnEveryReleasePath() public {
        _assertEveryReleasePathRejects(1);
    }

    function testBaseMainnetRejectedOnEveryReleasePath() public {
        _assertEveryReleasePathRejects(8453);
    }

    function testRobinhoodMainnetRejectedOnEveryReleasePath() public {
        _assertEveryReleasePathRejects(4663);
    }

    function testFuzzUnknownChainsRejectedOnEveryReleasePath(uint64 id) public {
        vm.assume(!DeploymentPolicy.isAllowed(id) && id != 0);
        _assertEveryReleasePathRejects(id);
    }

    function testAllowedTestnetsDeployAndVerifyEndToEnd() public {
        // Local policy simulation only: not evidence of live testnet compatibility.
        uint256[3] memory ids = [uint256(11155111), uint256(84532), uint256(46630)];
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            HooksStoreFactory f = new HooksStoreFactory();
            HookSpec memory s = spec;
            s.chainId = ids[i];
            HookMiner.Result memory r = f.mine(s, 0, HookMiner.MAX_ATTEMPTS);
            while (!r.found) {
                r = f.mine(s, r.nextNonce, HookMiner.MAX_ATTEMPTS);
            }
            IHooksStore.Plan memory p = f.preview(s, r.salt);
            f.deploy(s, p.salt, p.hook, p.initCodeHash);
            assertEq(f.verify(s, p.salt, p.hook).chainId, ids[i]);
            assertEq(BoundedSwapHook(p.hook).deploymentChainId(), ids[i]);
        }
    }

    // ---- the mainnet restriction is the factory's release policy, not the hook template's ----

    function testHookTemplateStaysChainAgnosticForFutureMainnetRelease() public {
        vm.chainId(1);
        HookSpec memory s = spec;
        s.chainId = 1;
        bytes32 initHash = keccak256(bytes.concat(type(BoundedSwapHook).creationCode, abi.encode(s)));
        HookMiner.Result memory r = HookMiner.mine(address(this), initHash, HookSpecLib.PERMISSIONS, 0, 131072);
        while (!r.found) {
            r = HookMiner.mine(address(this), initHash, HookSpecLib.PERMISSIONS, r.nextNonce, 131072);
        }
        // The public template deploys on chain 1 outside the Store: the spec is unchanged and valid there.
        BoundedSwapHook direct = new BoundedSwapHook{salt: r.salt}(s);
        assertEq(address(direct), r.hook);
        assertEq(direct.deploymentChainId(), 1);
        assertEq(address(direct).codehash, keccak256(type(BoundedSwapHook).runtimeCode));
        // ...but it is not a Store deployment: this release's factory refuses to deploy there, and
        // its registry does not know a hook deployed around it.
        vm.expectRevert(abi.encodeWithSelector(DeploymentPolicy.UnsupportedDeploymentChain.selector, 1));
        new HooksStoreFactory();
        assertEq(factory.deployedSpecHash(address(direct)), bytes32(0));
    }

    function testHookConstructorStillBindsSpecToActualChain() public {
        vm.chainId(1);
        // A testnet spec cannot be deployed onto chain 1 and vice versa.
        vm.expectRevert(abi.encodeWithSelector(HookSpecLib.WrongChain.selector, spec.chainId, 1));
        new BoundedSwapHook{salt: bytes32(0)}(spec);
    }

    // ---- salt mining under eth_call gas caps ----

    function testFullPageCompletesOrResumesUnderTypicalCallGasCap() public view {
        IHooksStore.Plan memory expected = _plan(spec);
        // Walk the whole search exactly as a client would, each call capped at the budget.
        uint256 start;
        uint256 calls;
        HookMiner.Result memory r;
        while (true) {
            r = this.capped(spec, start, HookMiner.MAX_ATTEMPTS, CALL_GAS_BUDGET);
            ++calls;
            if (r.found) break;
            assertGt(r.nextNonce, start, "every capped page makes progress");
            assertLe(r.nextNonce, start + HookMiner.MAX_ATTEMPTS);
            start = r.nextNonce;
        }
        // The capped walk finds the same first salt as an uncapped search: nothing was skipped.
        assertEq(r.salt, expected.salt);
        assertEq(r.hook, expected.hook);
        assertGe(calls, 1);
    }

    function testTruncatedPageReportsFirstUncheckedNonce() public view {
        // With a small budget, a max-size page cannot finish: it must stop early and say where.
        HookMiner.Result memory r = this.capped(spec, 0, HookMiner.MAX_ATTEMPTS, 1_000_000);
        if (!r.found) {
            assertGt(r.nextNonce, 0);
            assertLt(r.nextNonce, HookMiner.MAX_ATTEMPTS);
            // The skipped-over range [0, nextNonce) really held no match.
            HookMiner.Result memory again = factory.mine(spec, 0, r.nextNonce);
            assertFalse(again.found);
            assertEq(again.nextNonce, r.nextNonce);
        } else {
            assertLt(uint256(r.salt), HookMiner.MAX_ATTEMPTS);
        }
    }

    function testTooLittleGasForOneCandidateRevertsClearly() public {
        // Sweep small budgets: each call either makes progress or reverts; the miner's own floor
        // reports InsufficientGas rather than an empty "no match" page.
        bool sawFloor;
        for (uint256 g = 40_000; g < 400_000; g += 4_000) {
            (bool ok, bytes memory data) =
                address(factory).call{gas: g}(abi.encodeCall(HooksStoreFactory.mine, (spec, 0, HookMiner.MAX_ATTEMPTS)));
            if (ok) {
                HookMiner.Result memory r = abi.decode(data, (HookMiner.Result));
                assertTrue(r.found || r.nextNonce > 0, "no silent zero-progress page");
            } else if (keccak256(data) == keccak256(abi.encodeWithSelector(HookMiner.InsufficientGas.selector))) {
                sawFloor = true;
            }
        }
        assertTrue(sawFloor);
    }

    function testMaxPageGasWithinBudgetWhenUncapped() public view {
        // Measure the worst case: a page of the miner's maximum with no early match cut-off.
        uint256 before = gasleft();
        HookMiner.Result memory r = factory.mine(spec, 0, 16384);
        uint256 used = before - gasleft();
        uint256 checked = r.found ? uint256(r.salt) + 1 : 16384;
        // ~350 gas per candidate: a full 131,072-candidate page needs ~46M gas, above common
        // eth_call caps. That is why a page stops early on low gas instead of failing.
        assertLt(used / checked, 400, "per-candidate gas");
        assertGt(HookMiner.MAX_ATTEMPTS * (used / checked), 30_000_000);
    }

    /// @dev External so the test can cap gas exactly as an RPC eth_call cap would.
    function capped(HookSpec memory s, uint256 start, uint256 attempts, uint256 gasCap)
        external
        view
        returns (HookMiner.Result memory)
    {
        return factory.mine{gas: gasCap}(s, start, attempts);
    }
}

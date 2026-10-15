// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {HookSpec, HookSpecLib} from "../src/HookSpec.sol";
import {BoundedSwapHook} from "../src/BoundedSwapHook.sol";
import {HooksStoreFactory} from "../src/HooksStoreFactory.sol";
import {IHooksStore} from "../src/interfaces/IHooksStore.sol";
import {HookMiner} from "../src/deployment/HookMiner.sol";
import {HookDeployment} from "../src/deployment/HookDeployment.sol";
import {DeploymentPolicy} from "../src/deployment/DeploymentPolicy.sol";
import {DeployHook} from "../script/DeployHook.s.sol";
import {DeployStore} from "../script/DeployStore.s.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

contract DeploymentTest is Fixture {
    function testPredictionDeploymentPermissionsSettingsAndBytecodeAgree() public {
        IHooksStore.Plan memory plan = _plan(spec);
        bytes memory constructorArgs = abi.encode(spec);
        bytes memory init = bytes.concat(type(BoundedSwapHook).creationCode, constructorArgs);
        address independentPrediction = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), plan.salt, keccak256(init)))))
        );
        assertEq(factory.initCode(spec), init);
        assertEq(plan.initCodeHash, keccak256(init));
        assertEq(plan.hook, independentPrediction);
        assertEq(plan.hook.code.length, 0);
        assertEq(uint160(plan.hook) & 0x3fff, 0x10c0);
        assertEq(plan.permissions, 0x10c0);
        vm.recordLogs();
        IHooksStore.Plan memory receipt = factory.deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // The hook constructor and factory do not initialize a pool or deploy a token.
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(factory));
        assertEq(logs[0].topics[0], keccak256("HookDeployed(address,bytes32,bytes32,bytes32,bytes32)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), plan.hook);
        assertEq(logs[0].topics[2], plan.specHash);
        assertEq(logs[0].data, abi.encode(plan.salt, plan.initCodeHash, plan.runtimeCodeHash));
        assertEq(abi.encode(receipt), abi.encode(plan));
        assertEq(plan.hook.code, type(BoundedSwapHook).runtimeCode);
        assertEq(plan.hook.codehash, plan.runtimeCodeHash);
        BoundedSwapHook hook = BoundedSwapHook(plan.hook);
        assertEq(address(hook.poolManager()), spec.poolManager);
        assertEq(hook.maxSpecifiedAmount(), spec.maxSpecifiedAmount);
        assertEq(hook.poolManagerCodeHash(), spec.poolManagerCodeHash);
        assertEq(hook.deploymentChainId(), spec.chainId);
        assertEq(hook.specHash(), HookSpecLib.hash(spec));
        assertEq(factory.deployedSpecHash(plan.hook), plan.specHash);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap && p.afterSwap);
        assertFalse(p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(
            p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(abi.encode(factory.verify(spec, plan.salt, plan.hook)), abi.encode(plan));
    }

    function testScriptUsesSamePlanAndDeploymentAsStore() public {
        DeployHook script = new DeployHook();
        IHooksStore.Plan memory expected = _plan(spec);
        IHooksStore.Plan memory plan = script.prepare(address(factory), spec, uint256(expected.salt), 1);
        assertEq(abi.encode(plan), abi.encode(expected));
        IHooksStore.Plan memory result = script.execute(address(factory), spec, plan);
        assertEq(abi.encode(result), abi.encode(plan));
        assertEq(plan.hook.code, type(BoundedSwapHook).runtimeCode);
    }

    function testDuplicateDeploymentRejectedAndMinerSkipsOccupiedAddress() public {
        IHooksStore.Plan memory plan = _deploy(spec);
        vm.expectRevert(abi.encodeWithSelector(HooksStoreFactory.AddressOccupied.selector, plan.hook));
        factory.deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
        HookMiner.Result memory result = factory.mine(spec, uint256(plan.salt), 1);
        assertFalse(result.found);
        assertEq(result.nextNonce, uint256(plan.salt) + 1);
        assertEq(factory.verify(spec, plan.salt, plan.hook).specHash, plan.specHash);
    }

    function testAnyoneMayDeployIdenticalPlanWithoutTakingOwnership() public {
        IHooksStore.Plan memory plan = _plan(spec);
        address anotherCaller = makeAddr("anotherCaller");
        vm.prank(anotherCaller);
        factory.deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
        assertEq(factory.verify(spec, plan.salt, plan.hook).specHash, plan.specHash);
        // No owner, creator payout, mutable manager or settings exist to steal by copying the transaction.
        assertEq(BoundedSwapHook(plan.hook).maxSpecifiedAmount(), spec.maxSpecifiedAmount);
    }

    function testPrefundedPredictedAddressStillDeploys() public {
        IHooksStore.Plan memory plan = _plan(spec);
        vm.deal(plan.hook, 1);
        factory.deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
        assertEq(factory.verify(spec, plan.salt, plan.hook).hook, plan.hook);
        assertEq(plan.hook.balance, 1); // Unsolicited funds cannot change constructor behavior.
    }

    function testWrongExpectedAddressAndHashRejected() public {
        IHooksStore.Plan memory plan = _plan(spec);
        vm.expectRevert(HooksStoreFactory.PredictionMismatch.selector);
        factory.deploy(spec, plan.salt, address(this), plan.initCodeHash);
        vm.expectRevert(HooksStoreFactory.InitCodeHashMismatch.selector);
        factory.deploy(spec, plan.salt, plan.hook, keccak256("wrong bytecode"));
        assertEq(plan.hook.code.length, 0);
    }

    function testChangedConstructorSettingsInvalidateCachedPlan() public {
        IHooksStore.Plan memory plan = _plan(spec);
        spec.maxSpecifiedAmount += 1;
        IHooksStore.Plan memory changed = factory.preview(spec, plan.salt);
        assertNotEq(changed.specHash, plan.specHash);
        assertNotEq(changed.initCodeHash, plan.initCodeHash);
        assertNotEq(changed.hook, plan.hook);
        vm.expectRevert(HooksStoreFactory.PredictionMismatch.selector);
        factory.deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
    }

    function testChangingManagerChangesCommitments() public {
        IHooksStore.Plan memory before_ = factory.preview(spec, bytes32(0));
        PoolManager other = new PoolManager(address(this));
        spec.poolManager = address(other);
        spec.poolManagerCodeHash = address(other).codehash;
        IHooksStore.Plan memory after_ = factory.preview(spec, bytes32(0));
        assertNotEq(before_.specHash, after_.specHash);
        assertNotEq(before_.initCodeHash, after_.initCodeHash);
        assertNotEq(before_.hook, after_.hook);
    }

    function testWrongSaltRejectedByFactoryAndConstructor() public {
        bytes32 salt;
        IHooksStore.Plan memory plan = factory.preview(spec, salt);
        while (uint160(plan.hook) & 0x3fff == spec.permissions) {
            salt = bytes32(uint256(salt) + 1);
            plan = factory.preview(spec, salt);
        }
        vm.expectRevert(abi.encodeWithSelector(HooksStoreFactory.PermissionBitsMismatch.selector, plan.hook));
        factory.deploy(spec, salt, plan.hook, plan.initCodeHash);

        address direct = HookMiner.predict(address(this), salt, plan.initCodeHash);
        while (uint160(direct) & 0x3fff == spec.permissions) {
            salt = bytes32(uint256(salt) + 1);
            direct = HookMiner.predict(address(this), salt, plan.initCodeHash);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, direct));
        new BoundedSwapHook{salt: salt}(spec);
    }

    function testVerifyUndeployedOrWrongAddressRejected() public {
        IHooksStore.Plan memory plan = _plan(spec);
        vm.expectRevert(HooksStoreFactory.UnknownDeployment.selector);
        factory.verify(spec, plan.salt, plan.hook);
        vm.expectRevert(HooksStoreFactory.PredictionMismatch.selector);
        factory.verify(spec, plan.salt, address(this));
    }

    function testVerificationDetectsCorruptedRuntime() public {
        IHooksStore.Plan memory plan = _deploy(spec);
        // Fault injection only, never used to manufacture a successful hook deployment.
        vm.etch(plan.hook, hex"60006000f3");
        vm.expectRevert(HooksStoreFactory.RuntimeCodeMismatch.selector);
        factory.verify(spec, plan.salt, plan.hook);
    }

    function testVerificationDetectsCorruptedConstructorStorage() public {
        IHooksStore.Plan memory plan = _deploy(spec);
        // Slot 1 contains maxSpecifiedAmount. Deliberately break the write-once setting.
        vm.store(plan.hook, bytes32(uint256(1)), bytes32(uint256(spec.maxSpecifiedAmount) + 1));
        vm.expectRevert(HooksStoreFactory.ConstructorSettingsMismatch.selector);
        factory.verify(spec, plan.salt, plan.hook);
    }

    function testManagerCodeChangeFailsClosed() public {
        IHooksStore.Plan memory plan = _plan(spec);
        vm.etch(address(manager), hex"60006000f3");
        vm.expectRevert(
            abi.encodeWithSelector(
                HooksStoreFactory.ManagerCodeHashMismatch.selector, spec.poolManagerCodeHash, address(manager).codehash
            )
        );
        factory.deploy(spec, plan.salt, plan.hook, plan.initCodeHash);
    }

    function testManagerMustHaveExpectedCode() public {
        spec.poolManager = makeAddr("no-code-manager");
        vm.expectRevert(HooksStoreFactory.ManagerHasNoCode.selector);
        factory.preview(spec, bytes32(0));
        spec.poolManager = address(manager);
        spec.poolManagerCodeHash = keccak256("unapproved manager code");
        vm.expectRevert(
            abi.encodeWithSelector(
                HooksStoreFactory.ManagerCodeHashMismatch.selector, spec.poolManagerCodeHash, address(manager).codehash
            )
        );
        factory.preview(spec, bytes32(0));
    }

    function testInvalidSpecFieldsRejected() public {
        HookSpec memory input = spec;
        input.schemaVersion = 2;
        vm.expectRevert(abi.encodeWithSelector(HookSpecLib.UnsupportedVersion.selector, uint32(2)));
        factory.preview(input, bytes32(0));
        input = spec;
        input.templateId = keccak256("unknown template");
        vm.expectRevert(abi.encodeWithSelector(HookSpecLib.UnsupportedTemplate.selector, input.templateId));
        factory.preview(input, bytes32(0));
        input = spec;
        input.chainId = 0;
        vm.expectRevert(HookSpecLib.InvalidChainId.selector);
        factory.preview(input, bytes32(0));
        input = spec;
        input.poolManager = address(0);
        vm.expectRevert(HookSpecLib.InvalidManager.selector);
        factory.preview(input, bytes32(0));
        input = spec;
        input.poolManagerCodeHash = bytes32(0);
        vm.expectRevert(HookSpecLib.InvalidManagerCodeHash.selector);
        factory.preview(input, bytes32(0));
        input.poolManagerCodeHash = keccak256("");
        vm.expectRevert(HookSpecLib.InvalidManagerCodeHash.selector);
        factory.preview(input, bytes32(0));
        input = spec;
        input.maxSpecifiedAmount = 0;
        vm.expectRevert(HookSpecLib.InvalidLimit.selector);
        factory.preview(input, bytes32(0));
    }

    function testFuzzOnlyExactPermissionMaskAccepted(uint160 bits) public {
        vm.assume(bits != spec.permissions);
        spec.permissions = bits;
        vm.expectRevert(abi.encodeWithSelector(HookSpecLib.InvalidPermissions.selector, bits));
        factory.preview(spec, bytes32(0));
    }

    function testWrongChainRejected() public {
        spec.chainId = 11155111;
        vm.expectRevert(abi.encodeWithSelector(HookSpecLib.WrongChain.selector, spec.chainId, block.chainid));
        factory.preview(spec, bytes32(0));
    }

    function testAllNamedMainnetsAndUnknownChainsRejected() public {
        uint256[4] memory ids = [uint256(1), uint256(8453), uint256(4663), uint256(42)];
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            vm.expectRevert(abi.encodeWithSelector(DeploymentPolicy.UnsupportedDeploymentChain.selector, ids[i]));
            new HooksStoreFactory();
            vm.expectRevert(abi.encodeWithSelector(DeploymentPolicy.UnsupportedDeploymentChain.selector, ids[i]));
            factory.deploy(spec, bytes32(0), address(this), bytes32(0));
        }
    }

    function testTestnetPolicyIdsOnlyLocalSimulation() public {
        // This is policy testing in a local EVM, not a fork or evidence of live testnet compatibility.
        uint256[3] memory ids = [uint256(11155111), uint256(84532), uint256(46630)];
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            HooksStoreFactory f = new HooksStoreFactory();
            assertGt(address(f).code.length, 0);
        }
    }

    function testStaleOrForgedScriptPlansRejected() public {
        DeployHook script = new DeployHook();
        IHooksStore.Plan memory plan = _plan(spec);
        plan.runtimeCodeHash = keccak256("different build");
        vm.expectRevert(HookDeployment.StalePlan.selector);
        script.execute(address(factory), spec, plan);
        vm.expectRevert(HookDeployment.UntrustedFactory.selector);
        script.prepare(address(manager), spec, 0, 1);
        vm.expectRevert(HookDeployment.UntrustedFactory.selector);
        script.prepare(makeAddr("absent factory"), spec, 0, 1);
    }

    function testScriptsRejectMissingBroadcaster() public {
        DeployHook script = new DeployHook();
        DeployStore bootstrap = new DeployStore();
        vm.expectRevert(DeployHook.InvalidBroadcaster.selector);
        script.run(address(0), address(factory), spec, 0, 1);
        vm.expectRevert(DeployStore.InvalidBroadcaster.selector);
        bootstrap.run(address(0));
    }

    function testSearchExhaustionAndResume() public {
        IHooksStore.Plan memory known = _plan(spec);
        uint256 start = uint256(known.salt);
        // A one-candidate page at the known match succeeds; a known nonmatch fails explicitly.
        HookMiner.Result memory found = factory.mine(spec, start, 1);
        assertTrue(found.found);
        assertEq(found.nextNonce, start + 1);
        assertEq(found.hook, known.hook);
        uint256 wrong = start + 1;
        while (uint160(factory.preview(spec, bytes32(wrong)).hook) & 0x3fff == spec.permissions) ++wrong;
        HookMiner.Result memory empty = factory.mine(spec, wrong, 1);
        assertFalse(empty.found);
        assertEq(empty.nextNonce, wrong + 1);
        DeployHook script = new DeployHook();
        vm.expectRevert(abi.encodeWithSelector(HookDeployment.SearchExhausted.selector, wrong + 1));
        script.prepare(address(factory), spec, wrong, 1);
    }

    function testInvalidSearchRanges() public {
        vm.expectRevert(HookMiner.InvalidSearchRange.selector);
        factory.mine(spec, 0, 0);
        vm.expectRevert(HookMiner.InvalidSearchRange.selector);
        factory.mine(spec, 0, 131073);
        vm.expectRevert(HookMiner.InvalidSearchRange.selector);
        factory.mine(spec, type(uint256).max, 1);
    }

    function testFuzzPredictionMatchesIndependentCreate2Formula(address deployer, bytes32 salt, bytes32 initHash)
        public
        pure
    {
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
        assertEq(HookMiner.predict(deployer, salt, initHash), expected);
    }

    function testFuzzSpecLimitCommitsToExactConstructor(uint128 limit, bytes32 salt) public view {
        vm.assume(limit > 0);
        HookSpec memory input = spec;
        input.maxSpecifiedAmount = limit;
        IHooksStore.Plan memory plan = factory.preview(input, salt);
        assertEq(plan.specHash, HookSpecLib.hash(input));
        assertEq(plan.initCodeHash, keccak256(bytes.concat(type(BoundedSwapHook).creationCode, abi.encode(input))));
    }
}

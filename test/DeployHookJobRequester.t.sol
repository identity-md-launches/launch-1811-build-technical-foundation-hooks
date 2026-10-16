// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {MockIntake} from "./helpers/MockIntake.sol";
import {ImdTemplates} from "./helpers/ImdTemplates.sol";
import {DeployHookJobRequester} from "../script/DeployHookJobRequester.s.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";

/// @dev Drives the script's units directly with explicit arguments: no environment, no broadcast key.
contract DeployHookJobRequesterTest is Test {
    bytes32 internal constant JOB_ACTION = "job.open@test";
    bytes32 internal constant ORACLE_ACTION = "oracle.request@oracle-1";
    uint256 internal constant PRICE = 0.5 ether;

    DeployHookJobRequester internal script;
    MockIntake internal intake;
    TestToken internal imd;
    address internal owner = makeAddr("owner");
    address internal signer = makeAddr("signer");
    address internal creator = makeAddr("creator");

    function setUp() public {
        script = new DeployHookJobRequester();
        intake = new MockIntake();
        imd = new TestToken("IMD", 18);
        intake.setPrice(JOB_ACTION, address(imd), PRICE);
        intake.setPrice(ORACLE_ACTION, address(imd), PRICE);
    }

    function _config() internal view returns (DeployHookJobRequester.Config memory) {
        return DeployHookJobRequester.Config(owner, address(intake), address(imd), signer, PRICE);
    }

    function _templates() internal pure returns (DeployHookJobRequester.Templates memory) {
        return DeployHookJobRequester.Templates(
            JOB_ACTION,
            ImdTemplates.JOB_PREFIX,
            ImdTemplates.JOB_MIDDLE,
            ImdTemplates.JOB_SUFFIX,
            ORACLE_ACTION,
            ImdTemplates.REVIEW_PREFIX,
            ImdTemplates.REVIEW_SUFFIX,
            5,
            4
        );
    }

    function testDeployThenConfigureGivesAWorkingRequesterOwnedByTheNamedOwner() public {
        address broadcaster = makeAddr("broadcaster");
        HookJobRequester requester = script.run(broadcaster, _config());
        assertEq(requester.owner(), owner, "owner is the argument, not the script or the broadcaster");
        assertEq(address(requester.intake()), address(intake));
        assertEq(requester.asset(), address(imd));
        assertEq(requester.oracleSigner(), signer);
        assertEq(requester.maxPrice(), PRICE);
        assertTrue(requester.failureHook());
        // Unconfigured until the owner applies the templates; anyone else (here the script itself) fails.
        vm.expectRevert("UNAUTHORIZED");
        script.configure(requester, _templates());
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotConfigured.selector, bytes32("jobTemplate")));
        requester.openJob(keccak256("spec"), "a hook");
        script.runConfigure(owner, requester, _templates());
        assertEq(requester.jobAction(), JOB_ACTION);
        assertEq(requester.reviewAction(), ORACLE_ACTION);
        assertEq(requester.minPanelSize(), 5);
        imd.mint(creator, PRICE);
        vm.startPrank(creator);
        imd.approve(address(requester), PRICE);
        bytes32 id = requester.openJob(keccak256("spec"), "a hook");
        vm.stopPrank();
        assertEq(uint8(requester.getJob(id).status), uint8(HookJobRequester.JobStatus.Open));
    }

    function testCheckRefusesAddressesWithoutCodeAndUnsoldActions() public {
        DeployHookJobRequester.Config memory c = _config();
        c.intake = makeAddr("no intake here");
        vm.expectRevert(abi.encodeWithSelector(DeployHookJobRequester.NoCode.selector, c.intake));
        script.deploy(c);
        c = _config();
        c.imd = makeAddr("no token here");
        vm.expectRevert(abi.encodeWithSelector(DeployHookJobRequester.NoCode.selector, c.imd));
        script.deploy(c);
        c = _config();
        vm.expectRevert(
            abi.encodeWithSelector(DeployHookJobRequester.ActionNotSold.selector, bytes32("job.open@other"))
        );
        script.check(c, "job.open@other", ORACLE_ACTION);
        c.maxPrice = PRICE - 1;
        vm.expectRevert(abi.encodeWithSelector(DeployHookJobRequester.ActionNotSold.selector, JOB_ACTION));
        script.check(c, JOB_ACTION, ORACLE_ACTION);
        c = _config();
        script.check(c, JOB_ACTION, ORACLE_ACTION);
    }

    function testRunRefusesZeroBroadcaster() public {
        vm.expectRevert(DeployHookJobRequester.InvalidBroadcaster.selector);
        script.run(address(0), _config());
        vm.expectRevert(DeployHookJobRequester.InvalidBroadcaster.selector);
        script.runConfigure(address(0), HookJobRequester(address(1)), _templates());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {IIntake} from "../src/imd/IIntake.sol";

/// @notice Deploys and configures `HookJobRequester` from explicit arguments. No key handling, no
/// environment reads, no tokens, no paid request. `deploy` and `configure` are the units the tests
/// call directly; `run` only wraps `deploy` in a broadcast.
///
/// The constructor itself never calls another contract (a launch checks it on an empty chain), so
/// the checks that the Intake and the IMD token exist on the target chain live here, before the
/// broadcast, where an operator deploys by hand.
contract DeployHookJobRequester is Script {
    struct Config {
        /// @dev The launch's owner: a wallet the operator controls, never the deployer.
        address owner;
        /// @dev The chain's Intake version 2 (or version 1 with `failureHook` turned off after).
        address intake;
        /// @dev The chain's IMD token.
        address imd;
        /// @dev The IdentityMD oracle signer.
        address oracleSigner;
        /// @dev The most IMD one ask may cost; 5e17 at the published 0.5 IMD price.
        uint256 maxPrice;
    }

    struct Templates {
        bytes32 jobAction;
        bytes jobPrefix;
        bytes jobMiddle;
        bytes jobSuffix;
        bytes32 reviewAction;
        bytes reviewPrefix;
        bytes reviewSuffix;
        uint16 minPanelSize;
        uint16 minAgreed;
    }

    error InvalidBroadcaster();
    error NoCode(address at);
    error ActionNotSold(bytes32 action);

    /// @notice Refuses a configuration that cannot work on this chain: an address without code,
    /// or an action the Intake does not sell in the IMD given (price zero or above the ceiling).
    function check(Config memory c, bytes32 jobAction, bytes32 reviewAction) public view {
        if (c.intake.code.length == 0) revert NoCode(c.intake);
        if (c.imd.code.length == 0) revert NoCode(c.imd);
        if (jobAction != bytes32(0)) _checkSold(c, jobAction);
        if (reviewAction != bytes32(0)) _checkSold(c, reviewAction);
    }

    /// @notice Deploys one requester. The caller (test or `run`) chooses whether to broadcast.
    function deploy(Config memory c) public returns (HookJobRequester requester) {
        check(c, bytes32(0), bytes32(0));
        requester = new HookJobRequester(c.owner, c.intake, c.imd, c.oracleSigner, c.maxPrice);
    }

    /// @notice Applies the owner's templates. Must be called by (broadcast from) the owner.
    function configure(HookJobRequester requester, Templates memory t) public {
        requester.setJobTemplate(t.jobAction, t.jobPrefix, t.jobMiddle, t.jobSuffix);
        requester.setReviewTemplate(t.reviewAction, t.reviewPrefix, t.reviewSuffix, t.minPanelSize, t.minAgreed);
    }

    /// @notice `forge script ... --sig "run(address,(address,address,address,address,uint256))"`.
    function run(address broadcaster, Config memory c) external returns (HookJobRequester requester) {
        if (broadcaster == address(0)) revert InvalidBroadcaster();
        vm.startBroadcast(broadcaster);
        requester = deploy(c);
        vm.stopBroadcast();
    }

    /// @notice Same, for the templates, broadcast from the owner.
    function runConfigure(address owner, HookJobRequester requester, Templates memory t) external {
        if (owner == address(0)) revert InvalidBroadcaster();
        vm.startBroadcast(owner);
        configure(requester, t);
        vm.stopBroadcast();
    }

    function _checkSold(Config memory c, bytes32 action) internal view {
        uint256 price = IIntake(c.intake).priceOf(action, c.imd);
        if (price == 0 || price > c.maxPrice) revert ActionNotSold(action);
    }
}

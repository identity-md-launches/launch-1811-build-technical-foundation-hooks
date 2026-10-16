// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookListingRegistry} from "../../src/store/HookListingRegistry.sol";
import {FeaturedPlacements} from "../../src/store/FeaturedPlacements.sol";
import {TestToken} from "./TestToken.sol";

abstract contract StoreFixture is Test {
    HookListingRegistry internal registry;
    FeaturedPlacements internal ads;
    TestToken internal token;
    address internal alice;
    address internal bob;
    address internal treasury;
    address internal nextTreasury;
    address internal hook;
    uint256 internal constant PRICE = 0.1 ether;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant START = 1_800_000_000;

    function setUp() public virtual {
        vm.warp(START);
        alice = makeAddr("listing owner Alice");
        bob = makeAddr("listing owner Bob");
        treasury = makeAddr("test treasury");
        nextTreasury = makeAddr("next test treasury");
        hook = makeAddr("cross-chain hook claim");
        registry = new HookListingRegistry();
        ads = new FeaturedPlacements(address(this), registry);
        token = new TestToken("Mock IMD", 18);
        ads.configureToken(address(token));
        ads.setProceedsRecipient(treasury);
    }

    function _metadata() internal pure returns (HookListingRegistry.Metadata memory data) {
        data.name = "Bounded swap hook";
        data.sourceRef = "ipfs://source-commit";
        data.testRef = "ipfs://test-results";
        data.reviewRef = "ipfs://independent-review";
        data.auditRef = "https://example.invalid/user-claimed-audit";
        data.callbackMask = 0x10c0;
        data.callbackDisclosure = "beforeInitialize, beforeSwap, afterSwap; declared, not verified";
        data.feeDisclosure = "No hook fee; pool fee is separate";
        data.adminDisclosure = "No hook admin; immutable configuration";
        data.labels = new string[](2);
        data.labels[0] = "swap-limit";
        data.labels[1] = "static-fee";
    }

    function _create(address actor) internal returns (uint256) {
        vm.prank(actor);
        return registry.createListing(1, hook, _metadata());
    }

    function _deposit(address actor, uint256 amount) internal {
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(ads), amount);
        ads.deposit(amount);
        vm.stopPrank();
    }

    function _purchase(address actor, uint256 listingId) internal returns (uint256) {
        uint256 revision = registry.getListing(listingId).revision;
        address recipient = ads.proceedsRecipient();
        vm.prank(actor);
        return ads.purchase(listingId, revision, recipient, vm.getBlockTimestamp());
    }

    function _fundedAd() internal returns (uint256 id, uint256 listingId) {
        listingId = _create(alice);
        _deposit(alice, PRICE);
        id = _purchase(alice, listingId);
    }

    function _assertSolvent() internal view {
        assertEq(token.balanceOf(address(ads)), ads.totalAvailable() + ads.totalEscrowed() + ads.totalProceeds());
        assertEq(ads.accountedBalance(), token.balanceOf(address(ads)));
    }
}

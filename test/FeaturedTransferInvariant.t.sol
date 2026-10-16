// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeaturedHandler, FeaturedInvariantTest} from "./FeaturedInvariant.t.sol";
import {StoreFixture, FeaturedPlacements, HookListingRegistry, TestToken} from "./helpers/StoreFixture.sol";

contract FeaturedTransferHandler is FeaturedHandler {
    constructor(FeaturedPlacements ads_, TestToken token_, address[2] memory actors_, address[2] memory recipients_)
        FeaturedHandler(ads_, token_, actors_, recipients_)
    {}

    function transferListing(uint256 listingSeed) external {
        uint256 listingId = listings[listingSeed % 2];
        address current = registry.getListing(listingId).owner;
        address next = current == actors[0] ? actors[1] : actors[0];
        vm.prank(current);
        registry.proposeListingOwner(listingId, next);
        vm.prank(next);
        registry.acceptListingOwnership(listingId);
    }

    function purchaseAsCurrentOwner(uint256 listingSeed) external {
        if (ads.placementCount() >= 30) return;
        uint256 listingId = listings[listingSeed % 2];
        HookListingRegistry.Listing memory listing = registry.getListing(listingId);
        if (!listing.active || ads.available(listing.owner) < PRICE || ads.isActive(ads.latestPlacement(listingId))) {
            return;
        }
        address recipient = ads.proceedsRecipient();
        vm.prank(listing.owner);
        ads.purchase(listingId, listing.revision, recipient, vm.getBlockTimestamp());
    }

    function cancelAsCurrentOwner(uint256 idSeed) external {
        uint256 count = ads.placementCount();
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        if (!ads.isActive(id)) return;
        address current = registry.getListing(ads.getPlacement(id).listingId).owner;
        vm.prank(current);
        ads.cancel(id);
    }

    function toggleCurrentListing(uint256 listingSeed, bool active) external {
        uint256 listingId = listings[listingSeed % 2];
        address current = registry.getListing(listingId).owner;
        vm.prank(current);
        registry.setListingActive(listingId, active);
    }
}

/// @dev Reuses the original conservation assertions and full wind-down unchanged, with ownership
/// transitions and buyer cancellations added to the generated sequences. Original suite still runs.
contract FeaturedTransferInvariantTest is FeaturedInvariantTest {
    function setUp() public override {
        StoreFixture.setUp();
        _create(alice);
        // Distinct identities let either actor own either listing without duplicate-claim conflicts.
        vm.prank(bob);
        registry.createListing(4663, hook, _metadata());
        handler = new FeaturedTransferHandler(ads, token, [alice, bob], [treasury, nextTreasury]);
        ads.transferOwnership(address(handler));
        vm.prank(address(handler));
        ads.acceptOwnership();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = FeaturedHandler.deposit.selector;
        selectors[1] = FeaturedHandler.withdraw.selector;
        selectors[2] = FeaturedTransferHandler.purchaseAsCurrentOwner.selector;
        selectors[3] = FeaturedHandler.cancel.selector;
        selectors[4] = FeaturedHandler.settle.selector;
        selectors[5] = FeaturedHandler.advanceTime.selector;
        selectors[6] = FeaturedHandler.rotateRecipient.selector;
        selectors[7] = FeaturedHandler.claim.selector;
        selectors[8] = FeaturedTransferHandler.toggleCurrentListing.selector;
        selectors[9] = FeaturedTransferHandler.transferListing.selector;
        selectors[10] = FeaturedTransferHandler.cancelAsCurrentOwner.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }
}

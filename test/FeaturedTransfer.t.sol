// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, HookListingRegistry, FeaturedPlacements} from "./helpers/StoreFixture.sol";

contract FeaturedTransferTest is StoreFixture {
    function _transfer(uint256 listingId, address from, address to) internal {
        vm.prank(from);
        registry.proposeListingOwner(listingId, to);
        vm.prank(to);
        registry.acceptListingOwnership(listingId);
    }

    function testBuyerCanClearSellersAdAndBuyItsOwnWhileOnlySellerGetsRefund() public {
        (uint256 oldAd, uint256 listingId) = _fundedAd();
        _transfer(listingId, alice, bob);
        _deposit(bob, PRICE);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacements.AlreadyFeatured.selector);
        ads.purchase(listingId, 1, treasury, START);
        vm.warp(START + 1 days);
        ads.setProceedsRecipient(nextTreasury);
        vm.prank(bob);
        uint256 refund = ads.cancel(oldAd);
        assertEq(refund, PRICE - PRICE * 1 days / DURATION);
        assertEq(ads.available(alice), refund);
        assertEq(ads.available(bob), PRICE, "buyer receives none of seller's refund");
        assertEq(ads.proceeds(treasury), PRICE - refund);
        assertEq(ads.proceeds(nextTreasury), 0);
        HookListingRegistry.Metadata memory updated = _metadata();
        updated.name = "Buyer's version";
        vm.prank(bob);
        registry.updateListing(listingId, updated);
        uint256 newAd = _purchase(bob, listingId);
        assertEq(ads.getPlacement(newAd).payer, bob);
        assertEq(ads.getPlacement(newAd).revision, 2);
        assertEq(ads.getPlacement(newAd).recipient, nextTreasury);
        assertFalse(ads.isActive(oldAd));
        assertTrue(ads.isActive(newAd));
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacements.NotPayer.selector);
        ads.cancel(newAd);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacements.InsufficientBalance.selector);
        ads.withdraw(refund, bob);
        vm.prank(alice);
        ads.withdraw(refund, alice);
        assertEq(token.balanceOf(alice), refund);
        _assertSolvent();
    }

    function testProposedOwnerCannotCancelUntilAcceptingAndAdminCannotCancel() public {
        (uint256 adId, uint256 listingId) = _fundedAd();
        vm.prank(alice);
        registry.proposeListingOwner(listingId, bob);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacements.NotPayer.selector);
        ads.cancel(adId);
        vm.expectRevert(FeaturedPlacements.NotPayer.selector);
        ads.cancel(adId);
        vm.prank(bob);
        registry.acceptListingOwnership(listingId);
        vm.prank(bob);
        assertEq(ads.cancel(adId), PRICE);
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.available(bob), 0);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacements.PlacementClosed.selector);
        ads.cancel(adId);
        _assertSolvent();
    }

    function testIntermediateOwnerLosesCancellationPowerButOriginalPayerKeepsIt() public {
        (uint256 adId, uint256 listingId) = _fundedAd();
        address carol = makeAddr("third listing owner");
        _transfer(listingId, alice, bob);
        _transfer(listingId, bob, carol);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacements.NotPayer.selector);
        ads.cancel(adId);
        vm.prank(carol);
        registry.setListingActive(listingId, false);
        vm.warp(START + DURATION / 2);
        vm.prank(alice);
        assertEq(ads.cancel(adId), PRICE / 2);
        assertEq(ads.available(alice), PRICE / 2);
        assertEq(ads.available(carol), 0);
        _assertSolvent();
    }

    function testNewOwnerCannotCancelAtExpiryAndCanRenewBeforeOldSettlement() public {
        (uint256 adId, uint256 listingId) = _fundedAd();
        _transfer(listingId, alice, bob);
        vm.warp(START + DURATION);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacements.PlacementExpired.selector);
        ads.cancel(adId);
        _deposit(bob, PRICE);
        uint256 nextAd = _purchase(bob, listingId);
        ads.settle(adId);
        assertEq(ads.proceeds(treasury), PRICE);
        assertEq(ads.available(alice), 0);
        assertTrue(ads.isActive(nextAd));
        _assertSolvent();
    }

    function testFuzzNewOwnerCancellationConservesAllCredits(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, DURATION - 1);
        (uint256 adId, uint256 listingId) = _fundedAd();
        _transfer(listingId, alice, bob);
        vm.warp(START + elapsed);
        vm.prank(bob);
        uint256 refund = ads.cancel(adId);
        assertEq(refund + ads.proceeds(treasury), PRICE);
        assertEq(ads.available(alice), refund);
        assertEq(ads.available(bob), 0);
        assertEq(ads.totalEscrowed(), 0);
        _assertSolvent();
    }
}

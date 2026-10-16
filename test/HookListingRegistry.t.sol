// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, HookListingRegistry} from "./helpers/StoreFixture.sol";

contract HookListingRegistryTest is StoreFixture {
    function testFreeCreateAndEditPersistAllFieldsAndHistory() public {
        uint256 id = _create(alice);
        HookListingRegistry.Listing memory item = registry.getListing(id);
        assertEq(id, 1);
        assertEq(item.chainId, 1);
        assertEq(item.hook, hook);
        assertEq(item.owner, alice);
        assertEq(item.revision, 1);
        assertTrue(item.active);
        assertEq(abi.encode(registry.getMetadata(id, 1)), abi.encode(_metadata()));
        HookListingRegistry.Metadata memory edited = _metadata();
        edited.feeDisclosure = "New disclosure; historical ads retain the old text";
        edited.labels[0] = "updated";
        vm.prank(alice);
        registry.updateListing(id, edited);
        assertEq(registry.getListing(id).revision, 2);
        assertEq(abi.encode(registry.getMetadata(id, 2)), abi.encode(edited));
        assertEq(abi.encode(registry.getMetadata(id, 1)), abi.encode(_metadata()));
        assertFalse(registry.hasLabel(id, keccak256("swap-limit")));
        assertTrue(registry.hasLabel(id, keccak256("updated")));
        assertEq(registry.labelKey("updated"), keccak256("updated"));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function testAuditUrlAndAuditLabelNeverConferVerification() public {
        HookListingRegistry.Metadata memory data = _metadata();
        data.labels[0] = "audited";
        vm.prank(alice);
        uint256 id = registry.createListing(1, hook, data);
        assertFalse(registry.isAudited(id));
        data.auditRef = "https://another.invalid/new-claim";
        vm.prank(alice);
        registry.updateListing(id, data);
        assertFalse(registry.isAudited(id));
        _deposit(alice, PRICE);
        _purchase(alice, id);
        assertFalse(registry.isAudited(id));
    }

    function testSameHookCanHaveIndependentOwnersButNoOwnerDuplicates() public {
        uint256 id = _create(alice);
        uint256 other = _create(bob);
        assertEq(registry.getListing(other).owner, bob);
        vm.expectRevert(abi.encodeWithSelector(HookListingRegistry.DuplicateListing.selector, id));
        _create(alice);
        vm.prank(alice);
        registry.setListingActive(id, false);
        vm.expectRevert(abi.encodeWithSelector(HookListingRegistry.DuplicateListing.selector, id));
        _create(alice);
        vm.prank(alice);
        uint256 onAnotherChain = registry.createListing(8453, hook, _metadata());
        assertEq(registry.getListing(onAnotherChain).chainId, 8453);
    }

    function testTwoStepListingTransferAndDuplicateProtection() public {
        uint256 id = _create(alice);
        vm.prank(alice);
        registry.proposeListingOwner(id, bob);
        assertEq(registry.getListing(id).owner, alice);
        vm.prank(treasury);
        vm.expectRevert(HookListingRegistry.NotProposedOwner.selector);
        registry.acceptListingOwnership(id);
        vm.prank(bob);
        registry.acceptListingOwnership(id);
        assertEq(registry.getListing(id).owner, bob);
        assertEq(registry.getListing(id).proposedOwner, address(0));
        assertEq(registry.listingFor(registry.identityKey(1, hook, alice)), 0);
        assertEq(registry.listingFor(registry.identityKey(1, hook, bob)), id);
        vm.prank(alice);
        vm.expectRevert(HookListingRegistry.NotListingOwner.selector);
        registry.updateListing(id, _metadata());
        uint256 second = _create(alice);
        vm.prank(alice);
        registry.proposeListingOwner(second, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HookListingRegistry.DuplicateListing.selector, id));
        registry.acceptListingOwnership(second);
        assertEq(registry.getListing(second).owner, alice);
    }

    function testTransferCanBeCancelledOrReplaced() public {
        uint256 id = _create(alice);
        vm.startPrank(alice);
        registry.proposeListingOwner(id, bob);
        registry.cancelListingTransfer(id);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(HookListingRegistry.NotProposedOwner.selector);
        registry.acceptListingOwnership(id);
        vm.startPrank(alice);
        registry.proposeListingOwner(id, bob);
        registry.proposeListingOwner(id, treasury);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(HookListingRegistry.NotProposedOwner.selector);
        registry.acceptListingOwnership(id);
        vm.prank(treasury);
        registry.acceptListingOwnership(id);
        assertEq(registry.getListing(id).owner, treasury);
    }

    function testFuzzUnauthorizedCallerCannotModifyListing(address attacker) public {
        vm.assume(attacker != alice);
        uint256 id = _create(alice);
        vm.startPrank(attacker);
        vm.expectRevert(HookListingRegistry.NotListingOwner.selector);
        registry.updateListing(id, _metadata());
        vm.expectRevert(HookListingRegistry.NotListingOwner.selector);
        registry.setListingActive(id, false);
        vm.expectRevert(HookListingRegistry.NotListingOwner.selector);
        registry.proposeListingOwner(id, attacker);
        vm.expectRevert(HookListingRegistry.NotListingOwner.selector);
        registry.cancelListingTransfer(id);
        vm.stopPrank();
    }

    function testSearchByLabelChainOwnerAndVisibilityUsesBoundedAscendingCursor() public {
        uint256 first = _create(alice);
        uint256 second = _create(bob);
        vm.prank(alice);
        uint256 third = registry.createListing(8453, hook, _metadata());
        (uint256[] memory ids, uint256 next) = registry.search(1, 1, 0, address(0), bytes32(0));
        assertEq(ids.length, 1);
        assertEq(ids[0], first);
        assertEq(next, second);
        (ids, next) = registry.search(next, 1, 8453, address(0), bytes32(0));
        assertEq(ids.length, 0);
        assertEq(next, third);
        (ids, next) = registry.search(next, 100, 8453, alice, keccak256("swap-limit"));
        assertEq(ids.length, 1);
        assertEq(ids[0], third);
        assertEq(next, 4);
        (ids, next) = registry.search(next, 100, 0, address(0), bytes32(0));
        assertEq(ids.length, 0);
        assertEq(next, 4);
        vm.prank(alice);
        registry.setListingActive(first, false);
        (ids,) = registry.search(1, 100, 1, address(0), keccak256("static-fee"));
        assertEq(ids.length, 1);
        assertEq(ids[0], second);
        vm.prank(alice);
        registry.setListingActive(first, true);
        (ids,) = registry.search(1, 100, 1, address(0), bytes32(0));
        assertEq(ids.length, 2);
        assertEq(ids[0], first);
        assertEq(ids[1], second);
    }

    function testInvalidIdentityUnknownRecordsAndPagesRevert() public {
        vm.expectRevert(HookListingRegistry.InvalidIdentity.selector);
        registry.createListing(0, hook, _metadata());
        vm.expectRevert(HookListingRegistry.InvalidIdentity.selector);
        registry.createListing(1, address(0), _metadata());
        vm.expectRevert(abi.encodeWithSelector(HookListingRegistry.UnknownListing.selector, 1));
        registry.getListing(1);
        uint256 id = _create(alice);
        vm.expectRevert(HookListingRegistry.UnknownRevision.selector);
        registry.getMetadata(id, 0);
        vm.expectRevert(HookListingRegistry.UnknownRevision.selector);
        registry.getMetadata(id, 2);
        vm.prank(alice);
        vm.expectRevert(HookListingRegistry.InvalidIdentity.selector);
        registry.proposeListingOwner(id, address(0));
        vm.expectRevert(HookListingRegistry.InvalidPage.selector);
        registry.search(0, 1, 0, address(0), bytes32(0));
        vm.expectRevert(HookListingRegistry.InvalidPage.selector);
        registry.search(1, 101, 0, address(0), bytes32(0));
        vm.expectRevert(HookListingRegistry.InvalidPage.selector);
        registry.search(1, 0, 0, address(0), bytes32(0));
        vm.expectRevert(HookListingRegistry.InvalidPage.selector);
        registry.search(type(uint256).max, 1, 0, address(0), bytes32(0));
    }

    function testInvalidMetadataIsAtomicAndReferencesMayBeAbsent() public {
        HookListingRegistry.Metadata memory data = _metadata();
        data.name = "";
        _badMetadata(data);
        data = _metadata();
        data.name = new string(97);
        _badMetadata(data);
        data = _metadata();
        data.sourceRef = new string(513);
        _badMetadata(data);
        data = _metadata();
        data.testRef = new string(513);
        _badMetadata(data);
        data = _metadata();
        data.reviewRef = new string(513);
        _badMetadata(data);
        data = _metadata();
        data.auditRef = new string(513);
        _badMetadata(data);
        data = _metadata();
        data.callbackMask = 0x4000;
        _badMetadata(data);
        data = _metadata();
        data.callbackDisclosure = "";
        _badMetadata(data);
        data = _metadata();
        data.feeDisclosure = "";
        _badMetadata(data);
        data = _metadata();
        data.adminDisclosure = new string(1025);
        _badMetadata(data);
        assertEq(registry.listingCount(), 0);
        data = _metadata();
        data.sourceRef = "";
        data.testRef = "";
        data.reviewRef = "";
        data.auditRef = "";
        uint256 id = registry.createListing(1, hook, data);
        assertFalse(registry.isAudited(id));
        data.adminDisclosure = "";
        vm.expectRevert(HookListingRegistry.InvalidMetadata.selector);
        registry.updateListing(id, data);
        assertEq(registry.getListing(id).revision, 1);
    }

    function testLabelValidationBoundsAndDuplicates() public {
        HookListingRegistry.Metadata memory data = _metadata();
        data.labels[0] = "UPPER";
        _badLabels(data);
        data.labels[0] = "has space";
        _badLabels(data);
        data.labels[0] = "#ad";
        _badLabels(data);
        data.labels[0] = "";
        _badLabels(data);
        data.labels[0] = "static-fee";
        _badLabels(data);
        data.labels[0] = "12345678901234567890123456789012345";
        _badLabels(data);
        data.labels = new string[](17);
        _badLabels(data);
        data.labels = new string[](0);
        uint256 id = registry.createListing(1, hook, data);
        assertEq(registry.getMetadata(id, 1).labels.length, 0);
    }

    function testFuzzValidLabelsRemainSearchable(uint128 value) public {
        HookListingRegistry.Metadata memory data = _metadata();
        data.labels[0] = string.concat("label-", vm.toString(uint256(value) % 1e20));
        uint256 id = registry.createListing(1, hook, data);
        (uint256[] memory ids,) = registry.search(1, 100, 1, address(this), keccak256(bytes(data.labels[0])));
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
    }

    function _badMetadata(HookListingRegistry.Metadata memory data) internal {
        vm.expectRevert(HookListingRegistry.InvalidMetadata.selector);
        registry.createListing(1, hook, data);
    }

    function _badLabels(HookListingRegistry.Metadata memory data) internal {
        vm.expectRevert(HookListingRegistry.InvalidLabels.selector);
        registry.createListing(1, hook, data);
    }
}

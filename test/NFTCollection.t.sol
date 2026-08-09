// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Merkle} from "murky/Merkle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {NFTCollection} from "../src/NFTCollection.sol";
import {AllowlistRoot} from "../script/AllowlistRoot.s.sol";
import {GoodReceiver, ReentrantReceiver, RejectingTreasury} from "./mocks/Receivers.sol";

contract NFTCollectionTest is Test {
    NFTCollection internal nft;
    Merkle internal merkle;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave"); // deliberately not on the allowlist

    uint256 internal constant MAX_SUPPLY = 100;
    uint256 internal constant RESERVE_SUPPLY = 10;
    uint256 internal constant PRICE = 0.05 ether;
    uint256 internal constant MAX_PER_WALLET = 3;
    uint96 internal constant ROYALTY_BPS = 500; // 5%

    string internal constant HIDDEN_URI = "ipfs://hidden/placeholder.json";
    string internal constant BASE_URI = "ipfs://revealed/";
    bytes32 internal constant PROVENANCE = keccak256("provenance");

    /// @dev Allowlist entries, mirrored into the Merkle tree in `setUp`.
    address[3] internal allowlistAddrs = [address(0), address(0), address(0)];
    uint256[3] internal allowlistAllowances = [uint256(3), 1, 5];
    bytes32[] internal leaves;
    bytes32 internal root;

    /// @dev Proofs are precomputed in `setUp` rather than generated on demand. Calling the
    ///      Merkle helper inline would put an external call between `vm.prank` / `vm.expectRevert`
    ///      and the call under test -- and those cheatcodes apply to the *next* call, so the
    ///      helper would silently consume them.
    bytes32[][] internal proofs;

    function setUp() public {
        allowlistAddrs[0] = alice;
        allowlistAddrs[1] = bob;
        allowlistAddrs[2] = carol;

        merkle = new Merkle();
        leaves = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            leaves[i] = _leaf(allowlistAddrs[i], allowlistAllowances[i]);
        }
        root = merkle.getRoot(leaves);

        for (uint256 i = 0; i < 3; i++) {
            proofs.push();
            proofs[i] = merkle.getProof(leaves, i);
        }

        vm.prank(owner);
        nft = new NFTCollection(
            "Test Collection",
            "TEST",
            MAX_SUPPLY,
            RESERVE_SUPPLY,
            PRICE,
            MAX_PER_WALLET,
            HIDDEN_URI,
            PROVENANCE,
            treasury,
            ROYALTY_BPS,
            owner
        );

        vm.prank(owner);
        nft.setAllowlistRoot(root);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
    }

    /// @dev Must match the leaf construction inside the contract exactly, double hash included.
    function _leaf(address account, uint256 allowance) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, allowance))));
    }

    function _proofFor(uint256 index) internal view returns (bytes32[] memory) {
        return proofs[index];
    }

    function _openAllowlist() internal {
        vm.prank(owner);
        nft.setPhase(NFTCollection.Phase.Allowlist);
    }

    function _openPublic() internal {
        vm.prank(owner);
        nft.setPhase(NFTCollection.Phase.Public);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsConfiguration() public view {
        assertEq(nft.name(), "Test Collection");
        assertEq(nft.symbol(), "TEST");
        assertEq(nft.maxSupply(), MAX_SUPPLY);
        assertEq(nft.reserveSupply(), RESERVE_SUPPLY);
        assertEq(nft.price(), PRICE);
        assertEq(nft.maxPerWallet(), MAX_PER_WALLET);
        assertEq(nft.provenanceHash(), PROVENANCE);
        assertEq(nft.treasury(), treasury);
        assertEq(nft.owner(), owner);
        assertEq(uint256(nft.phase()), uint256(NFTCollection.Phase.Closed));
        assertFalse(nft.revealed());
    }

    function test_ConstructorRejectsBadParameters() public {
        vm.expectRevert(NFTCollection.ZeroQuantity.selector);
        _deployWith(0, RESERVE_SUPPLY, MAX_PER_WALLET, treasury, ROYALTY_BPS);

        vm.expectRevert(NFTCollection.ZeroQuantity.selector);
        _deployWith(MAX_SUPPLY, RESERVE_SUPPLY, 0, treasury, ROYALTY_BPS);

        vm.expectRevert(NFTCollection.ReserveExceeded.selector);
        _deployWith(10, 11, MAX_PER_WALLET, treasury, ROYALTY_BPS);

        vm.expectRevert(NFTCollection.ZeroAddress.selector);
        _deployWith(MAX_SUPPLY, RESERVE_SUPPLY, MAX_PER_WALLET, address(0), ROYALTY_BPS);

        vm.expectRevert(NFTCollection.RoyaltyTooHigh.selector);
        _deployWith(MAX_SUPPLY, RESERVE_SUPPLY, MAX_PER_WALLET, treasury, 1001);
    }

    function _deployWith(
        uint256 maxSupply_,
        uint256 reserve_,
        uint256 perWallet_,
        address treasury_,
        uint96 royalty_
    ) internal {
        new NFTCollection(
            "N",
            "N",
            maxSupply_,
            reserve_,
            PRICE,
            perWallet_,
            HIDDEN_URI,
            PROVENANCE,
            treasury_,
            royalty_,
            owner
        );
    }

    /*//////////////////////////////////////////////////////////////
                            PHASE GATING
    //////////////////////////////////////////////////////////////*/

    function test_MintsClosedByDefault() public {
        vm.prank(alice);
        vm.expectRevert(NFTCollection.WrongPhase.selector);
        nft.mintPublic{value: PRICE}(1);

        vm.prank(alice);
        vm.expectRevert(NFTCollection.WrongPhase.selector);
        nft.mintAllowlist{value: PRICE}(1, 3, _proofFor(0));
    }

    function test_AllowlistMintRejectedDuringPublicPhase() public {
        _openPublic();

        vm.prank(alice);
        vm.expectRevert(NFTCollection.WrongPhase.selector);
        nft.mintAllowlist{value: PRICE}(1, 3, _proofFor(0));
    }

    function test_PublicMintRejectedDuringAllowlistPhase() public {
        _openAllowlist();

        vm.prank(alice);
        vm.expectRevert(NFTCollection.WrongPhase.selector);
        nft.mintPublic{value: PRICE}(1);
    }

    /*//////////////////////////////////////////////////////////////
                            ALLOWLIST MINT
    //////////////////////////////////////////////////////////////*/

    function test_AllowlistMintWithValidProof() public {
        _openAllowlist();

        vm.prank(alice);
        nft.mintAllowlist{value: PRICE * 3}(3, 3, _proofFor(0));

        assertEq(nft.balanceOf(alice), 3);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(3), alice);
        assertEq(nft.totalMinted(), 3);
        assertEq(nft.allowlistMinted(alice), 3);
    }

    function test_AllowlistMintRejectsNonMember() public {
        _openAllowlist();

        // Dave has no leaf, so no proof exists. Borrowing Alice's proof fails because the
        // leaf is rebuilt from `msg.sender`.
        vm.prank(dave);
        vm.expectRevert(NFTCollection.InvalidProof.selector);
        nft.mintAllowlist{value: PRICE}(1, 3, _proofFor(0));
    }

    function test_AllowlistMintRejectsInflatedAllowance() public {
        _openAllowlist();

        // Bob is in the tree with allowance 1. Claiming 10 changes the leaf, so his own
        // proof no longer verifies -- this is why the allowance belongs inside the leaf.
        vm.prank(bob);
        vm.expectRevert(NFTCollection.InvalidProof.selector);
        nft.mintAllowlist{value: PRICE * 10}(10, 10, _proofFor(1));
    }

    function test_AllowlistMintEnforcesAllowanceAcrossCalls() public {
        _openAllowlist();

        vm.startPrank(alice);
        nft.mintAllowlist{value: PRICE * 2}(2, 3, _proofFor(0));
        nft.mintAllowlist{value: PRICE}(1, 3, _proofFor(0));

        vm.expectRevert(NFTCollection.AllowanceExceeded.selector);
        nft.mintAllowlist{value: PRICE}(1, 3, _proofFor(0));
        vm.stopPrank();

        assertEq(nft.balanceOf(alice), 3);
    }

    function test_AllowlistMintRejectsWrongPayment() public {
        _openAllowlist();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NFTCollection.IncorrectPayment.selector, PRICE * 2, PRICE));
        nft.mintAllowlist{value: PRICE}(2, 3, _proofFor(0));
    }

    function test_AllowlistMintRejectsZeroQuantity() public {
        _openAllowlist();

        vm.prank(alice);
        vm.expectRevert(NFTCollection.ZeroQuantity.selector);
        nft.mintAllowlist{value: 0}(0, 3, _proofFor(0));
    }

    function test_AllowlistMintRevertsWithoutRoot() public {
        vm.startPrank(owner);
        nft.setAllowlistRoot(bytes32(0));
        nft.setPhase(NFTCollection.Phase.Allowlist);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(NFTCollection.AllowlistRootNotSet.selector);
        nft.mintAllowlist{value: PRICE}(1, 3, _proofFor(0));
    }

    function test_IsAllowlistedMatchesMintBehaviour() public view {
        assertTrue(nft.isAllowlisted(alice, 3, _proofFor(0)));
        assertTrue(nft.isAllowlisted(carol, 5, _proofFor(2)));
        assertFalse(nft.isAllowlisted(alice, 4, _proofFor(0)));
        assertFalse(nft.isAllowlisted(dave, 3, _proofFor(0)));
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLIC MINT
    //////////////////////////////////////////////////////////////*/

    function test_PublicMintRespectsWalletLimit() public {
        _openPublic();

        vm.startPrank(alice);
        nft.mintPublic{value: PRICE * MAX_PER_WALLET}(MAX_PER_WALLET);

        vm.expectRevert(NFTCollection.WalletLimitExceeded.selector);
        nft.mintPublic{value: PRICE}(1);
        vm.stopPrank();

        assertEq(nft.balanceOf(alice), MAX_PER_WALLET);
    }

    function test_PublicMintAccumulatesEth() public {
        _openPublic();

        vm.prank(alice);
        nft.mintPublic{value: PRICE * 2}(2);
        vm.prank(bob);
        nft.mintPublic{value: PRICE}(1);

        assertEq(address(nft).balance, PRICE * 3);
    }

    function test_AllowlistAndPublicLimitsAreIndependent() public {
        _openAllowlist();
        vm.prank(alice);
        nft.mintAllowlist{value: PRICE * 3}(3, 3, _proofFor(0));

        _openPublic();
        vm.prank(alice);
        nft.mintPublic{value: PRICE * MAX_PER_WALLET}(MAX_PER_WALLET);

        assertEq(nft.balanceOf(alice), 3 + MAX_PER_WALLET);
    }

    function test_PublicMintRejectsZeroQuantity() public {
        _openPublic();

        vm.prank(alice);
        vm.expectRevert(NFTCollection.ZeroQuantity.selector);
        nft.mintPublic{value: 0}(0);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER CONFIG
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanRetuneSaleParameters() public {
        vm.startPrank(owner);

        vm.expectEmit(false, false, false, true, address(nft));
        emit NFTCollection.PriceUpdated(0.1 ether);
        nft.setPrice(0.1 ether);

        vm.expectEmit(false, false, false, true, address(nft));
        emit NFTCollection.MaxPerWalletUpdated(10);
        nft.setMaxPerWallet(10);

        vm.expectEmit(true, false, false, true, address(nft));
        emit NFTCollection.PhaseChanged(NFTCollection.Phase.Public);
        nft.setPhase(NFTCollection.Phase.Public);
        vm.stopPrank();

        assertEq(nft.price(), 0.1 ether);
        assertEq(nft.maxPerWallet(), 10);

        vm.prank(alice);
        nft.mintPublic{value: 0.1 ether * 10}(10);
        assertEq(nft.balanceOf(alice), 10);
    }

    function test_SetMaxPerWalletRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(NFTCollection.ZeroQuantity.selector);
        nft.setMaxPerWallet(0);
    }

    function test_ConfigSettersAreOwnerOnly() public {
        bytes memory expected = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);

        vm.startPrank(alice);
        vm.expectRevert(expected);
        nft.setPhase(NFTCollection.Phase.Public);

        vm.expectRevert(expected);
        nft.setPrice(1);

        vm.expectRevert(expected);
        nft.setMaxPerWallet(1);

        vm.expectRevert(expected);
        nft.setAllowlistRoot(bytes32("x"));

        vm.expectRevert(expected);
        nft.setTreasury(alice);

        vm.expectRevert(expected);
        nft.setDefaultRoyalty(alice, 100);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             RESERVE MINT
    //////////////////////////////////////////////////////////////*/

    function test_ReserveMintIsFreeAndCapped() public {
        vm.startPrank(owner);
        nft.mintReserve(carol, RESERVE_SUPPLY);

        vm.expectRevert(NFTCollection.ReserveExceeded.selector);
        nft.mintReserve(carol, 1);
        vm.stopPrank();

        assertEq(nft.balanceOf(carol), RESERVE_SUPPLY);
        assertEq(nft.reserveMinted(), RESERVE_SUPPLY);
    }

    function test_ReserveMintOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.mintReserve(alice, 1);
    }

    function test_ReserveMintRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(NFTCollection.ZeroAddress.selector);
        nft.mintReserve(address(0), 1);
    }

    /*//////////////////////////////////////////////////////////////
                             SUPPLY CAP
    //////////////////////////////////////////////////////////////*/

    function test_MaxSupplyIsEnforced() public {
        vm.prank(owner);
        nft.setMaxPerWallet(MAX_SUPPLY);
        _openPublic();

        vm.prank(alice);
        nft.mintPublic{value: PRICE * MAX_SUPPLY}(MAX_SUPPLY);
        assertEq(nft.totalMinted(), MAX_SUPPLY);
        assertEq(nft.remainingSupply(), 0);

        vm.prank(bob);
        vm.expectRevert(NFTCollection.MaxSupplyExceeded.selector);
        nft.mintPublic{value: PRICE}(1);
    }

    function test_ReserveCountsAgainstMaxSupply() public {
        vm.startPrank(owner);
        nft.setMaxPerWallet(MAX_SUPPLY);
        nft.mintReserve(owner, RESERVE_SUPPLY);
        vm.stopPrank();
        _openPublic();

        assertEq(nft.remainingSupply(), MAX_SUPPLY - RESERVE_SUPPLY);

        vm.prank(alice);
        vm.expectRevert(NFTCollection.MaxSupplyExceeded.selector);
        nft.mintPublic{value: PRICE * (MAX_SUPPLY - RESERVE_SUPPLY + 1)}(MAX_SUPPLY - RESERVE_SUPPLY + 1);
    }

    /*//////////////////////////////////////////////////////////////
                               METADATA
    //////////////////////////////////////////////////////////////*/

    function test_TokenUriHiddenBeforeReveal() public {
        _openPublic();
        vm.prank(alice);
        nft.mintPublic{value: PRICE * 2}(2);

        // Both tokens look identical, so rarity cannot be inferred while minting is open.
        assertEq(nft.tokenURI(1), HIDDEN_URI);
        assertEq(nft.tokenURI(2), HIDDEN_URI);
    }

    function test_TokenUriAfterReveal() public {
        _openPublic();
        vm.prank(alice);
        nft.mintPublic{value: PRICE}(1);

        vm.prank(owner);
        nft.reveal(BASE_URI);

        assertTrue(nft.revealed());
        assertEq(nft.tokenURI(1), "ipfs://revealed/1.json");
    }

    function test_TokenUriRevertsForNonexistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        nft.tokenURI(999);
    }

    function test_RevealIsOneWay() public {
        vm.startPrank(owner);
        nft.reveal(BASE_URI);

        vm.expectRevert(NFTCollection.AlreadyRevealed.selector);
        nft.reveal("ipfs://other/");
        vm.stopPrank();
    }

    function test_BaseUriUpdatableUntilFrozen() public {
        _openPublic();
        vm.prank(alice);
        nft.mintPublic{value: PRICE}(1);

        vm.startPrank(owner);
        nft.reveal(BASE_URI);
        nft.setBaseURI("ipfs://moved/");
        assertEq(nft.tokenURI(1), "ipfs://moved/1.json");

        nft.freezeMetadata();
        assertTrue(nft.metadataFrozen());

        vm.expectRevert(NFTCollection.MetadataFrozen.selector);
        nft.setBaseURI("ipfs://rug/");
        vm.stopPrank();

        assertEq(nft.tokenURI(1), "ipfs://moved/1.json");
    }

    function test_MetadataFunctionsAreOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.reveal(BASE_URI);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setBaseURI(BASE_URI);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.freezeMetadata();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               ROYALTIES
    //////////////////////////////////////////////////////////////*/

    function test_RoyaltyInfoFollowsConfiguration() public {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 10 ether);
        assertEq(receiver, treasury);
        assertEq(amount, (10 ether * ROYALTY_BPS) / 10_000);

        vm.prank(owner);
        nft.setDefaultRoyalty(alice, 250);

        (receiver, amount) = nft.royaltyInfo(1, 10 ether);
        assertEq(receiver, alice);
        assertEq(amount, 0.25 ether);
    }

    function test_RoyaltyCappedAtTenPercent() public {
        vm.prank(owner);
        vm.expectRevert(NFTCollection.RoyaltyTooHigh.selector);
        nft.setDefaultRoyalty(alice, 1001);
    }

    function test_SupportsExpectedInterfaces() public view {
        assertTrue(nft.supportsInterface(type(IERC165).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId), "marketplaces need 2981");
        assertFalse(nft.supportsInterface(0xdeadbeef));
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawSendsEverythingToTreasury() public {
        _openPublic();
        vm.prank(alice);
        nft.mintPublic{value: PRICE * 3}(3);

        // Anyone may trigger it; the destination is fixed.
        vm.prank(dave);
        nft.withdraw();

        assertEq(treasury.balance, PRICE * 3);
        assertEq(address(nft).balance, 0);
    }

    function test_WithdrawRevertsWhenEmpty() public {
        vm.expectRevert(NFTCollection.NothingToWithdraw.selector);
        nft.withdraw();
    }

    function test_WithdrawRevertsWhenTreasuryRejectsEth() public {
        RejectingTreasury rejecting = new RejectingTreasury();
        vm.prank(owner);
        nft.setTreasury(address(rejecting));

        _openPublic();
        vm.prank(alice);
        nft.mintPublic{value: PRICE}(1);

        // Funds stay in the contract rather than being silently lost.
        vm.expectRevert();
        nft.withdraw();
        assertEq(address(nft).balance, PRICE);
    }

    function test_SetTreasuryRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(NFTCollection.ZeroAddress.selector);
        nft.setTreasury(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          CONTRACT RECEIVERS
    //////////////////////////////////////////////////////////////*/

    function test_SafeMintReachesCompliantContract() public {
        GoodReceiver receiver = new GoodReceiver();
        vm.prank(owner);
        nft.mintReserve(address(receiver), 2);

        assertEq(nft.balanceOf(address(receiver)), 2);
    }

    function test_SafeMintRejectsNonReceiverContract() public {
        // RejectingTreasury has no `onERC721Received`, so ERC-721 refuses to mint into it.
        RejectingTreasury notAReceiver = new RejectingTreasury();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(notAReceiver))
        );
        nft.mintReserve(address(notAReceiver), 1);
    }

    function test_ReentrantMintIsBlocked() public {
        _openPublic();
        ReentrantReceiver attacker = new ReentrantReceiver(nft);
        vm.deal(address(attacker), 10 ether);

        attacker.attack{value: PRICE}(1);

        assertTrue(attacker.attempted(), "callback should have fired");
        assertEq(
            bytes4(attacker.reentryRevertData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "re-entry must be rejected by the guard"
        );
        // The honest mint still went through, and only that one.
        assertEq(nft.balanceOf(address(attacker)), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          SCRIPT / CONTRACT PARITY
    //////////////////////////////////////////////////////////////*/

    /// @dev The off-chain generator and the contract must build leaves identically. If they
    ///      ever drift, every proof in production stops verifying -- so pin it with a test.
    function test_ScriptLeafFormatMatchesContract() public {
        AllowlistRoot generator = new AllowlistRoot();

        assertEq(generator.leafFor(alice, 3), _leaf(alice, 3));
        assertEq(generator.leafFor(carol, 5), _leaf(carol, 5));

        // And the leaf the generator produces really is the one the contract accepts.
        assertTrue(nft.isAllowlisted(alice, 3, _proofFor(0)));
        assertEq(merkle.getRoot(leaves), nft.allowlistRoot());
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PublicMintChargesExactly(uint256 quantity) public {
        quantity = bound(quantity, 1, MAX_PER_WALLET);
        _openPublic();

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        nft.mintPublic{value: PRICE * quantity}(quantity);

        assertEq(balanceBefore - alice.balance, PRICE * quantity);
        assertEq(nft.balanceOf(alice), quantity);
        assertEq(address(nft).balance, PRICE * quantity);
    }

    function testFuzz_WrongPaymentAlwaysReverts(uint256 quantity, uint256 sent) public {
        quantity = bound(quantity, 1, MAX_PER_WALLET);
        uint256 expected = PRICE * quantity;
        sent = bound(sent, 0, 10 ether);
        vm.assume(sent != expected);

        _openPublic();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NFTCollection.IncorrectPayment.selector, expected, sent));
        nft.mintPublic{value: sent}(quantity);
    }

    function testFuzz_AllowlistProofOnlyWorksForItsOwner(address caller) public {
        vm.assume(caller != alice && caller != address(0));
        vm.assume(caller.code.length == 0);

        _openAllowlist();
        vm.deal(caller, 10 ether);

        vm.prank(caller);
        vm.expectRevert(NFTCollection.InvalidProof.selector);
        nft.mintAllowlist{value: PRICE}(1, 3, _proofFor(0));
    }

    function testFuzz_TokenIdsAreSequentialAndUnique(uint256 q1, uint256 q2) public {
        q1 = bound(q1, 1, MAX_PER_WALLET);
        q2 = bound(q2, 1, MAX_PER_WALLET);
        _openPublic();

        vm.prank(alice);
        nft.mintPublic{value: PRICE * q1}(q1);
        vm.prank(bob);
        nft.mintPublic{value: PRICE * q2}(q2);

        for (uint256 id = 1; id <= q1; id++) {
            assertEq(nft.ownerOf(id), alice);
        }
        for (uint256 id = q1 + 1; id <= q1 + q2; id++) {
            assertEq(nft.ownerOf(id), bob);
        }
        assertEq(nft.totalMinted(), q1 + q2);
    }
}

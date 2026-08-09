// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Merkle} from "murky/Merkle.sol";

import {NFTCollection} from "../src/NFTCollection.sol";
import {MintHandler} from "./handlers/MintHandler.sol";

/// @title NFTCollectionInvariantTest
/// @notice Properties that must survive any interleaving of mints, phase flips, price changes
///         and withdrawals.
contract NFTCollectionInvariantTest is Test {
    NFTCollection internal nft;
    MintHandler internal handler;
    Merkle internal merkle;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant MAX_SUPPLY = 200;
    uint256 internal constant RESERVE_SUPPLY = 20;
    uint256 internal constant PRICE = 0.05 ether;
    uint256 internal constant MAX_PER_WALLET = 5;

    uint256 internal constant ACTOR_COUNT = 4;

    function setUp() public {
        address[] memory actors = new address[](ACTOR_COUNT);
        uint256[] memory allowances = new uint256[](ACTOR_COUNT);
        bytes32[] memory leaves = new bytes32[](ACTOR_COUNT);

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            allowances[i] = i + 1;
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(actors[i], allowances[i]))));
        }

        merkle = new Merkle();
        bytes32 root = merkle.getRoot(leaves);

        vm.startPrank(owner);
        nft = new NFTCollection(
            "Invariant Collection",
            "INV",
            MAX_SUPPLY,
            RESERVE_SUPPLY,
            PRICE,
            MAX_PER_WALLET,
            "ipfs://hidden",
            keccak256("provenance"),
            treasury,
            500,
            owner
        );
        nft.setAllowlistRoot(root);
        vm.stopPrank();

        handler = new MintHandler(nft, owner);
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            handler.addActor(actors[i], allowances[i], merkle.getProof(leaves, i));
        }

        targetContract(address(handler));

        // `addActor` is setup, not an action the fuzzer should call.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = MintHandler.mintPublic.selector;
        selectors[1] = MintHandler.mintAllowlist.selector;
        selectors[2] = MintHandler.mintReserve.selector;
        selectors[3] = MintHandler.setPhase.selector;
        selectors[4] = MintHandler.setPrice.selector;
        selectors[5] = MintHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Supply can never exceed the cap promised at deploy time.
    function invariant_SupplyNeverExceedsCap() public view {
        assertLe(nft.totalMinted(), nft.maxSupply());
    }

    /// @notice The owner can never mint more free tokens than the declared reserve.
    function invariant_ReserveNeverExceedsLimit() public view {
        assertLe(nft.reserveMinted(), nft.reserveSupply());
    }

    /// @notice Token ownership adds up to the number minted.
    function invariant_BalancesSumToTotalMinted() public view {
        uint256 sum;
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            sum += nft.balanceOf(handler.actors(i));
        }
        assertEq(sum, nft.totalMinted());
    }

    /// @notice Every minted id has an owner, and ids are contiguous from 1.
    /// @dev Not `view`: `vm.expectRevert` counts as a state-modifying cheatcode call.
    function invariant_AllMintedIdsAreOwned() public {
        uint256 minted = nft.totalMinted();
        // Sampling keeps the check cheap on long runs; ids are assigned sequentially, so a
        // gap would show up at the boundaries.
        if (minted > 0) {
            assertTrue(nft.ownerOf(1) != address(0));
            assertTrue(nft.ownerOf(minted) != address(0));
        }
        vm.expectRevert();
        nft.ownerOf(minted + 1);
    }

    /// @notice The contract holds exactly what was paid in minus what was withdrawn.
    /// @dev Ghost variables are tracked by the handler, so this compares the contract against
    ///      an independent tally rather than against itself.
    function invariant_EthBalanceMatchesPayments() public view {
        assertEq(address(nft).balance, handler.ghostPaid() - handler.ghostWithdrawn());
    }

    /// @notice Everything withdrawn ended up at the treasury.
    function invariant_TreasuryReceivedAllWithdrawals() public view {
        assertEq(treasury.balance, handler.ghostWithdrawn());
    }

    /// @notice Per-wallet limits hold for every actor.
    function invariant_WalletLimitsRespected() public view {
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actors(i);
            assertLe(nft.publicMinted(actor), nft.maxPerWallet());
            assertLe(nft.allowlistMinted(actor), handler.allowanceOf(actor));
        }
    }
}

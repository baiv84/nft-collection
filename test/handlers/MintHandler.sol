// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {NFTCollection} from "../../src/NFTCollection.sol";

/// @title MintHandler
/// @notice Bounded action surface for the invariant fuzzer.
/// @dev Tracks ETH in and out as ghost variables so the invariant suite can check the
///      contract's balance against what was actually paid, independently of the contract's
///      own accounting.
contract MintHandler is Test {
    NFTCollection public immutable nft;
    address public immutable owner;

    address[] public actors;
    mapping(address actor => uint256 allowance) public allowanceOf;
    mapping(address actor => bytes32[] proof) internal _proofOf;

    /// @notice Total wei paid into the collection by mints.
    uint256 public ghostPaid;

    /// @notice Total wei pulled out through `withdraw`.
    uint256 public ghostWithdrawn;

    constructor(NFTCollection nft_, address owner_) {
        nft = nft_;
        owner = owner_;
    }

    /// @dev Called once from the test's `setUp`, before fuzzing starts.
    function addActor(address actor, uint256 allowance, bytes32[] memory proof) external {
        actors.push(actor);
        allowanceOf[actor] = allowance;
        _proofOf[actor] = proof;
        vm.deal(actor, 1000 ether);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function proofOf(address actor) external view returns (bytes32[] memory) {
        return _proofOf[actor];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function mintPublic(uint256 actorSeed, uint256 quantity) external {
        if (nft.phase() != NFTCollection.Phase.Public) return;

        address actor = _actor(actorSeed);
        uint256 headroom = nft.maxPerWallet() - nft.publicMinted(actor);
        uint256 remaining = nft.remainingSupply();
        if (headroom == 0 || remaining == 0) return;

        quantity = bound(quantity, 1, headroom < remaining ? headroom : remaining);
        uint256 cost = nft.price() * quantity;

        vm.prank(actor);
        nft.mintPublic{value: cost}(quantity);
        ghostPaid += cost;
    }

    function mintAllowlist(uint256 actorSeed, uint256 quantity) external {
        if (nft.phase() != NFTCollection.Phase.Allowlist) return;

        address actor = _actor(actorSeed);
        uint256 allowance = allowanceOf[actor];
        uint256 headroom = allowance - nft.allowlistMinted(actor);
        uint256 remaining = nft.remainingSupply();
        if (headroom == 0 || remaining == 0) return;

        quantity = bound(quantity, 1, headroom < remaining ? headroom : remaining);
        uint256 cost = nft.price() * quantity;

        vm.prank(actor);
        nft.mintAllowlist{value: cost}(quantity, allowance, _proofOf[actor]);
        ghostPaid += cost;
    }

    function mintReserve(uint256 actorSeed, uint256 quantity) external {
        uint256 headroom = nft.reserveSupply() - nft.reserveMinted();
        uint256 remaining = nft.remainingSupply();
        if (headroom == 0 || remaining == 0) return;

        quantity = bound(quantity, 1, headroom < remaining ? headroom : remaining);

        vm.prank(owner);
        nft.mintReserve(_actor(actorSeed), quantity);
    }

    function setPhase(uint256 phaseSeed) external {
        NFTCollection.Phase newPhase = NFTCollection.Phase(bound(phaseSeed, 0, 2));
        vm.prank(owner);
        nft.setPhase(newPhase);
    }

    function setPrice(uint256 newPrice) external {
        vm.prank(owner);
        nft.setPrice(bound(newPrice, 0, 1 ether));
    }

    function withdraw() external {
        uint256 balance = address(nft).balance;
        if (balance == 0) return;

        nft.withdraw();
        ghostWithdrawn += balance;
    }
}

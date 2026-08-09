// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {NFTCollection} from "../src/NFTCollection.sol";

/// @title Deploy
/// @notice Deploys the collection with the parameters below.
/// @dev Run against a local anvil node:
///        forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
///
///      `ALLOWLIST_ROOT` is optional: leave it unset to deploy with the mint closed and set
///      the root later, which is the usual order since the allowlist is finalised last.
contract Deploy is Script {
    string public constant NAME = "Foundry Apes";
    string public constant SYMBOL = "FAPE";
    uint256 public constant MAX_SUPPLY = 5000;
    uint256 public constant RESERVE_SUPPLY = 100;
    uint256 public constant PRICE = 0.05 ether;
    uint256 public constant MAX_PER_WALLET = 3;
    uint96 public constant ROYALTY_BPS = 500; // 5%
    string public constant HIDDEN_URI = "ipfs://bafyPlaceholder/hidden.json";

    function run() external returns (NFTCollection collection) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envOr("TREASURY", deployer);

        // Commitment to the artwork and its order. Replace with the real hash of the
        // concatenated image hashes before a live deployment.
        bytes32 provenance = vm.envOr("PROVENANCE_HASH", keccak256("REPLACE_ME"));
        bytes32 allowlistRoot = vm.envOr("ALLOWLIST_ROOT", bytes32(0));

        vm.startBroadcast(deployerKey);

        collection = new NFTCollection(
            NAME,
            SYMBOL,
            MAX_SUPPLY,
            RESERVE_SUPPLY,
            PRICE,
            MAX_PER_WALLET,
            HIDDEN_URI,
            provenance,
            treasury,
            ROYALTY_BPS,
            deployer
        );

        if (allowlistRoot != bytes32(0)) {
            collection.setAllowlistRoot(allowlistRoot);
        }

        vm.stopBroadcast();

        console.log("NFTCollection :", address(collection));
        console.log("owner         :", deployer);
        console.log("treasury      :", treasury);
        console.log("maxSupply     :", MAX_SUPPLY);
        console.log("price (wei)   :", PRICE);
        console.log("phase         : Closed (open it with setPhase)");
    }
}

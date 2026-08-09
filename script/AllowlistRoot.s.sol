// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Merkle} from "murky/Merkle.sol";

/// @title AllowlistRoot
/// @notice Builds the allowlist Merkle root and every member's proof from a JSON file.
/// @dev This is the off-chain half of the allowlist. The contract only ever stores the root;
///      each minter supplies their own proof, which the front end reads from the generated
///      `allowlist-proofs.json`.
///
///      Run with:
///        forge script script/AllowlistRoot.s.sol:AllowlistRoot
///        ALLOWLIST_FILE=./allowlist.example.json forge script script/AllowlistRoot.s.sol:AllowlistRoot
contract AllowlistRoot is Script {
    /// @dev Field order must be alphabetical -- `vm.parseJson` decodes JSON keys in
    ///      alphabetical order, not in the order they appear in the file.
    struct Entry {
        address account;
        uint256 allowance;
    }

    function run() external {
        string memory path = vm.envOr("ALLOWLIST_FILE", string("./allowlist.json"));
        string memory json = vm.readFile(path);

        Entry[] memory entries = abi.decode(vm.parseJson(json, ".entries"), (Entry[]));
        require(entries.length > 1, "allowlist needs at least 2 entries");

        bytes32[] memory leaves = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            leaves[i] = leafFor(entries[i].account, entries[i].allowance);
        }

        Merkle merkle = new Merkle();
        bytes32 root = merkle.getRoot(leaves);

        console.log("Entries    :", entries.length);
        console.log("Merkle root:");
        console.logBytes32(root);

        string memory out = string.concat('{\n  "root": "', vm.toString(root), '",\n  "proofs": {\n');
        for (uint256 i = 0; i < entries.length; i++) {
            bytes32[] memory proof = merkle.getProof(leaves, i);

            string memory elements = "";
            for (uint256 j = 0; j < proof.length; j++) {
                elements = string.concat(elements, '"', vm.toString(proof[j]), '"');
                if (j + 1 < proof.length) elements = string.concat(elements, ", ");
            }

            out = string.concat(
                out,
                '    "',
                vm.toString(entries[i].account),
                '": {"allowance": ',
                vm.toString(entries[i].allowance),
                ', "proof": [',
                elements,
                "]}"
            );
            out = string.concat(out, i + 1 < entries.length ? ",\n" : "\n");
        }
        out = string.concat(out, "  }\n}\n");

        vm.writeFile("./allowlist-proofs.json", out);
        console.log("Proofs written to ./allowlist-proofs.json");
    }

    /// @notice Leaf format, kept identical to `NFTCollection`.
    /// @dev Double hashed so an internal tree node can never be replayed as a leaf.
    function leafFor(address account, uint256 allowance) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, allowance))));
    }
}

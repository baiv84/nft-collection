// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {NFTCollection} from "../../src/NFTCollection.sol";

/// @notice Well-behaved ERC-721 receiver, used to prove `_safeMint` works towards contracts.
contract GoodReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Receiver that tries to mint again from inside the `_safeMint` callback.
/// @dev This is the attack `nonReentrant` exists to stop: without the guard the callback would
///      re-enter before `publicMinted` is committed and mint past the per-wallet limit.
contract ReentrantReceiver is IERC721Receiver {
    NFTCollection public immutable collection;

    /// @notice Revert data returned by the re-entrant call, for the test to inspect.
    bytes public reentryRevertData;

    /// @notice True once a re-entry was attempted.
    bool public attempted;

    constructor(NFTCollection collection_) {
        collection = collection_;
    }

    function attack(uint256 quantity) external payable {
        collection.mintPublic{value: msg.value}(quantity);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!attempted) {
            attempted = true;
            uint256 price = collection.price();
            try collection.mintPublic{value: price}(1) {
            // Reaching here would mean the guard failed.
            }
            catch (bytes memory reason) {
                reentryRevertData = reason;
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice Contract that rejects plain ETH transfers, used to test withdraw failure handling.
contract RejectingTreasury {
    error Nope();

    receive() external payable {
        revert Nope();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title NFTCollection
/// @notice Fixed-supply ERC-721 collection with a phased mint: an allowlist round gated by a
///         Merkle proof, then a public round, plus delayed metadata reveal and EIP-2981
///         royalties.
/// @dev Three ideas carry this contract:
///
///      1. The allowlist lives off-chain as a Merkle tree; only its 32-byte root is stored.
///         Ten thousand addresses cost the same storage as one.
///      2. Metadata stays hidden until the whole collection is minted, so nobody can snipe
///         the rare tokens. A provenance hash fixed at deploy time proves the art order was
///         decided beforehand rather than rearranged afterwards.
///      3. Metadata can be frozen permanently, which is the strongest promise a collection
///         can make to its holders.
contract NFTCollection is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error WrongPhase();
    error ZeroQuantity();
    error ZeroAddress();
    error MaxSupplyExceeded();
    error ReserveExceeded();
    error WalletLimitExceeded();
    error AllowanceExceeded();
    error InvalidProof();
    error IncorrectPayment(uint256 expected, uint256 sent);
    error AllowlistRootNotSet();
    error AlreadyRevealed();
    error MetadataFrozen();
    error NothingToWithdraw();
    error RoyaltyTooHigh();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PhaseChanged(Phase indexed phase);
    event AllowlistRootUpdated(bytes32 root);
    event PriceUpdated(uint256 price);
    event MaxPerWalletUpdated(uint256 maxPerWallet);
    event TreasuryUpdated(address indexed treasury);
    event Minted(address indexed to, uint256 indexed startTokenId, uint256 quantity);
    event Revealed(string baseURI);
    event BaseURIUpdated(string baseURI);
    event MetadataFrozenForever();
    event Withdrawn(address indexed treasury, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint phases. Only one is open at a time; the owner advances them manually.
    enum Phase {
        Closed,
        Allowlist,
        Public
    }

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard cap on tokens that will ever exist.
    uint256 public immutable maxSupply;

    /// @notice Portion of `maxSupply` the owner may mint without paying, for the team and
    ///         giveaways. Counted inside `maxSupply`, not on top of it.
    uint256 public immutable reserveSupply;

    /// @notice Hash committing to the artwork and its order, published before minting opens.
    /// @dev Immutable on purpose. Holders can recompute it from the revealed images and
    ///      check the collection was not reshuffled to hide the rares from the allowlist.
    bytes32 public immutable provenanceHash;

    /// @dev Royalties above 10% get collections delisted on most marketplaces, so the
    ///      contract refuses to set them at all.
    uint96 public constant MAX_ROYALTY_BPS = 1000;

    /*//////////////////////////////////////////////////////////////
                              MINT SETTINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current mint phase.
    Phase public phase;

    /// @notice Price per token in wei. Applies to both the allowlist and public rounds.
    uint256 public price;

    /// @notice Tokens one wallet may mint in the public round.
    uint256 public maxPerWallet;

    /// @notice Merkle root of `(address, allowance)` pairs eligible for the allowlist round.
    bytes32 public allowlistRoot;

    /// @notice Address that receives mint proceeds.
    address public treasury;

    /*//////////////////////////////////////////////////////////////
                                 SUPPLY
    //////////////////////////////////////////////////////////////*/

    /// @notice Tokens minted so far. Token ids run from 1 to `maxSupply`.
    uint256 public totalMinted;

    /// @notice Tokens minted from the reserve.
    uint256 public reserveMinted;

    /// @notice Tokens minted per wallet in the public round.
    mapping(address wallet => uint256 count) public publicMinted;

    /// @notice Tokens minted per wallet in the allowlist round.
    mapping(address wallet => uint256 count) public allowlistMinted;

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice True once the real metadata has been published.
    bool public revealed;

    /// @notice True once the base URI can never change again.
    bool public metadataFrozen;

    string private _hiddenURI;
    string private _baseTokenURI;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param name_ Collection name.
    /// @param symbol_ Collection symbol.
    /// @param maxSupply_ Hard supply cap.
    /// @param reserveSupply_ Team reserve, must not exceed `maxSupply_`.
    /// @param price_ Mint price per token in wei.
    /// @param maxPerWallet_ Public round per-wallet cap.
    /// @param hiddenURI_ Placeholder metadata URI served before reveal.
    /// @param provenanceHash_ Commitment to the artwork order.
    /// @param treasury_ Recipient of mint proceeds and default royalties.
    /// @param royaltyBps_ Default royalty in basis points, capped at `MAX_ROYALTY_BPS`.
    /// @param initialOwner Contract owner.
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        uint256 reserveSupply_,
        uint256 price_,
        uint256 maxPerWallet_,
        string memory hiddenURI_,
        bytes32 provenanceHash_,
        address treasury_,
        uint96 royaltyBps_,
        address initialOwner
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        if (maxSupply_ == 0 || maxPerWallet_ == 0) revert ZeroQuantity();
        if (reserveSupply_ > maxSupply_) revert ReserveExceeded();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (royaltyBps_ > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();

        maxSupply = maxSupply_;
        reserveSupply = reserveSupply_;
        provenanceHash = provenanceHash_;
        price = price_;
        maxPerWallet = maxPerWallet_;
        _hiddenURI = hiddenURI_;
        treasury = treasury_;

        _setDefaultRoyalty(treasury_, royaltyBps_);
    }

    /*//////////////////////////////////////////////////////////////
                                MINTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints during the allowlist round.
    /// @param quantity Tokens to mint now.
    /// @param allowance Total tokens this wallet is allowed across the whole round.
    /// @param proof Merkle proof that `(msg.sender, allowance)` is in the allowlist.
    /// @dev `allowance` is part of the leaf, so it cannot be inflated: changing it produces a
    ///      different leaf and the proof stops verifying. That is what lets one root encode
    ///      per-wallet limits instead of a flat yes/no list.
    function mintAllowlist(uint256 quantity, uint256 allowance, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        if (phase != Phase.Allowlist) revert WrongPhase();
        if (allowlistRoot == bytes32(0)) revert AllowlistRootNotSet();
        if (quantity == 0) revert ZeroQuantity();

        // Double hashing the leaf makes it impossible to pass off an internal node of the
        // tree as a leaf: internal nodes are hashes of 64 bytes, leaves of 32.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, allowance))));
        if (!MerkleProof.verifyCalldata(proof, allowlistRoot, leaf)) revert InvalidProof();

        uint256 minted = allowlistMinted[msg.sender] + quantity;
        if (minted > allowance) revert AllowanceExceeded();
        allowlistMinted[msg.sender] = minted;

        _collectPayment(quantity);
        _mintSequential(msg.sender, quantity);
    }

    /// @notice Mints during the public round.
    function mintPublic(uint256 quantity) external payable nonReentrant {
        if (phase != Phase.Public) revert WrongPhase();
        if (quantity == 0) revert ZeroQuantity();

        uint256 minted = publicMinted[msg.sender] + quantity;
        if (minted > maxPerWallet) revert WalletLimitExceeded();
        publicMinted[msg.sender] = minted;

        _collectPayment(quantity);
        _mintSequential(msg.sender, quantity);
    }

    /// @notice Mints from the team reserve without payment.
    /// @dev Bounded by `reserveSupply` so the owner cannot quietly take the whole collection.
    function mintReserve(address to, uint256 quantity) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (quantity == 0) revert ZeroQuantity();

        uint256 minted = reserveMinted + quantity;
        if (minted > reserveSupply) revert ReserveExceeded();
        reserveMinted = minted;

        _mintSequential(to, quantity);
    }

    /// @dev Requires exact payment. Refunding change would mean sending ETH back mid-mint,
    ///      which is an extra external call for no benefit -- the front end knows the price.
    function _collectPayment(uint256 quantity) private {
        uint256 expected = price * quantity;
        if (msg.value != expected) revert IncorrectPayment(expected, msg.value);
    }

    /// @dev Mints `quantity` sequential ids. `_safeMint` calls back into `to` if it is a
    ///      contract, which is why every public mint path carries `nonReentrant`: without it
    ///      a malicious receiver could re-enter and mint past its wallet limit.
    function _mintSequential(address to, uint256 quantity) private {
        uint256 startTokenId = totalMinted + 1;
        if (totalMinted + quantity > maxSupply) revert MaxSupplyExceeded();

        totalMinted += quantity;
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(to, startTokenId + i);
        }

        emit Minted(to, startTokenId, quantity);
    }

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice Metadata URI for `tokenId`.
    /// @dev Before reveal every token returns the same placeholder, so no one can tell which
    ///      ids are rare while minting is still open.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        if (!revealed) return _hiddenURI;
        return string.concat(_baseTokenURI, tokenId.toString(), ".json");
    }

    /// @notice Publishes the real metadata. One-way.
    function reveal(string calldata baseURI) external onlyOwner {
        if (revealed) revert AlreadyRevealed();

        revealed = true;
        _baseTokenURI = baseURI;

        emit Revealed(baseURI);
    }

    /// @notice Updates the base URI, e.g. to move pinned files to another gateway.
    function setBaseURI(string calldata baseURI) external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();

        _baseTokenURI = baseURI;
        emit BaseURIUpdated(baseURI);
    }

    /// @notice Gives up the ability to change metadata, forever.
    /// @dev Irreversible by design. A collection that cannot do this is one whose owner can
    ///      still swap every image after the sale.
    function freezeMetadata() external onlyOwner {
        metadataFrozen = true;
        emit MetadataFrozenForever();
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER CONFIG
    //////////////////////////////////////////////////////////////*/

    function setPhase(Phase newPhase) external onlyOwner {
        phase = newPhase;
        emit PhaseChanged(newPhase);
    }

    function setAllowlistRoot(bytes32 root) external onlyOwner {
        allowlistRoot = root;
        emit AllowlistRootUpdated(root);
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
        emit PriceUpdated(newPrice);
    }

    function setMaxPerWallet(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert ZeroQuantity();

        maxPerWallet = newMax;
        emit MaxPerWalletUpdated(newMax);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();

        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Updates the marketplace royalty.
    function setDefaultRoyalty(address receiver, uint96 feeBps) external onlyOwner {
        if (feeBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();

        _setDefaultRoyalty(receiver, feeBps);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends the full balance to the treasury.
    /// @dev Callable by anyone: the destination is fixed, so there is nothing to gain by
    ///      calling it, and it means proceeds are not stuck if the owner key is lost.
    function withdraw() external nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();

        // `sendValue` forwards all gas and reverts on failure, unlike `transfer`, whose
        // 2300 gas stipend breaks payouts to multisigs.
        Address.sendValue(payable(treasury), balance);

        emit Withdrawn(treasury, balance);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tokens still mintable.
    function remainingSupply() external view returns (uint256) {
        return maxSupply - totalMinted;
    }

    /// @notice Checks an allowlist entry without spending gas on a failed mint.
    function isAllowlisted(address account, uint256 allowance, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, allowance))));
        return MerkleProof.verifyCalldata(proof, allowlistRoot, leaf);
    }

    /// @dev Both parents declare this; the override merges ERC-721 and ERC-2981 support so
    ///      marketplaces can discover the royalty interface.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

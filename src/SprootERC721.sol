// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// /////////////////////////////////////////////////////
//    _____                        __              __ 
//   / ___/____  _________  ____  / /_ ____ ______/ /_
//   \__ \/ __ \/ ___/ __ \/ __ \/ __// __ `/ ___/ __/
//  ___/ / /_/ / /  / /_/ / /_/ / /__/ /_/ / /  / /_  
// /____/ .___/_/   \____/\____/\__(_)__,_/_/   \__/  
//     /_/                                            
// /////////////////////////////////////////////////////

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {SprootCollectionBase} from "./SprootCollectionBase.sol";
import {CollectionConfig, MintConfig, MintPhase, SprootErrors} from "./SprootTypes.sol";

/// @title SprootERC721
/// @notice A classic NFT collection: N sequentially-minted tokens, each with
///         its own metadata and traits. The PFP or generative-drop shape, not a
///         shared-artwork edition.
///
/// @dev Metadata comes from a directory CID. The creator pins the whole drop,
///      assets plus one metadata JSON per token, as a single IPFS directory, so
///      `tokenURI(7)` resolves to `ipfs://<dirCID>/7.json`. Per-token URIs are
///      never stored on-chain: for a 10,000-piece collection that would cost
///      more than the drop earns.
///
///      One contract is one collection. Another deploy costs around 253k gas,
///      so there is no reason to pack several drops into one contract and then
///      explain which id ranges belong to which.
///
/// @dev `baseURI` is mutable until `freezeMetadata()` is called, so a drop can
///      mint against a placeholder and reveal afterwards. Freezing is permanent
///      and is the creator's proof that the art can no longer change, including
///      by us. Frontends should surface the frozen flag prominently.
///
/// @dev A reveal moves every token's metadata at once, so `setBaseURI` emits
///      ERC-4906 `BatchMetadataUpdate` over the whole id range and the contract
///      advertises `0x49064906`. Without that signal marketplaces and wallets
///      keep serving the cached placeholder document forever: the chain says
///      the art has changed, but nothing tells them to re-read it.
///
/// For 1-of-1s and editions, use SprootERC1155: a single-piece drop needs no
/// sequential ids or directory, and 1155 lets one contract hold many
/// independent pieces.
contract SprootERC721 is ERC721Upgradeable, SprootCollectionBase {
    using Strings for uint256;

    /// @dev A classic collection is a single drop, so all the per-token mint
    ///      accounting in the base contract is keyed on this one id.
    uint256 internal constant DROP_ID = 1;

    /// @notice Directory URI holding one metadata document per token.
    ///         Must end with `/`; `tokenURI` appends `<id>.json`.
    string public baseURI;

    /// @notice Once true, `baseURI` can never change again.
    bool public metadataFrozen;

    /// @notice Next token id to issue. Ids are sequential from 1.
    uint256 public nextTokenId;

    uint256[46] private __gap;

    /// @dev ERC-4906's id, which is `IERC721MetadataUpdate` XOR `IERC165` and
    ///      so is not derivable from a Solidity interface type.
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    event DropConfigured(string baseURI, uint256 maxSupply);
    event BaseURIUpdated(string baseURI);
    event MetadataFrozen();

    /// @dev ERC-4906. Declared here rather than inherited: `IERC4906` extends
    ///      `IERC721`, which would clash with `ERC721Upgradeable`.
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        CollectionConfig calldata cfg,
        address feeSink_,
        uint256 platformFeeWei_
    ) external initializer {
        __ERC721_init(cfg.name, cfg.symbol);
        __SprootCollection_init(owner_, cfg, feeSink_, platformFeeWei_);
        nextTokenId = 1;
    }

    // ---------------------------------------------------------------------
    // Drop setup
    // ---------------------------------------------------------------------

    /// @notice Define the collection: its metadata directory and its size.
    /// @param baseURI_ `ipfs://<dirCID>/`, must end with `/`.
    /// @param maxSupply_ total collection size. 0 = open-ended.
    /// @dev Callable once. The collection's size is part of what a collector is
    ///      buying into, so it is not revisable after minting starts.
    function setupDrop(string calldata baseURI_, uint256 maxSupply_) external onlyOwner {
        if (tokenExists(DROP_ID)) revert SprootErrors.DropAlreadyConfigured();
        if (bytes(baseURI_).length == 0) revert SprootErrors.EmptyTokenURI();

        baseURI = baseURI_;
        _registerToken(baseURI_, maxSupply_);

        emit DropConfigured(baseURI_, maxSupply_);
    }

    /// @notice Update the metadata directory, which is the reveal.
    function setBaseURI(string calldata baseURI_) external onlyOwner {
        if (metadataFrozen) revert SprootErrors.MetadataIsFrozen();
        if (bytes(baseURI_).length == 0) revert SprootErrors.EmptyTokenURI();

        baseURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
        // Every token's document moved, including ids not yet minted, so the
        // range is open-ended: a collector who mints after the reveal must not
        // inherit a cache entry built from the placeholder.
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    /// @notice Permanently lock the metadata directory.
    /// @dev One-way. The creator's credible commitment that the art is final,
    ///      worth doing after a reveal and worth showing collectors.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert SprootErrors.MetadataIsFrozen();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    // ---------------------------------------------------------------------
    // Mint terms, collection-wide, because a collection is one drop
    // ---------------------------------------------------------------------

    function setMintConfig(MintConfig calldata cfg) external onlyOwner {
        _setMintConfig(DROP_ID, cfg);
    }

    function setPaused(bool paused_) external onlyOwner {
        _setPaused(DROP_ID, paused_);
    }

    function mintConfig() external view returns (MintConfig memory) {
        return _mintConfigs[DROP_ID];
    }

    /// @notice Set the drop's phase schedule. An empty array clears it.
    function setPhases(MintPhase[] calldata phases_) external onlyOwner {
        _setPhases(DROP_ID, phases_);
    }

    function phases() external view returns (MintPhase[] memory) {
        return _phases[DROP_ID];
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    /// @notice Mint `quantity` sequential tokens to the caller.
    /// @dev Cost is linear in quantity: each token is its own `_safeMint` plus
    ///      storage, around 118k gas for 1 and 526k for 10. ERC-721A would
    ///      amortise this and is a roadmap item.
    function mint(uint256 quantity) external payable nonReentrant {
        _processMint(DROP_ID, quantity);
    }

    /// @notice Mint within a phase, proving allowlist membership if it is gated.
    /// @param proof Merkle proof for the caller; empty for an open phase.
    function mintPhase(uint256 phaseIndex, uint256 quantity, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        _processPhaseMint(DROP_ID, phaseIndex, quantity, proof);
    }

    /// @inheritdoc SprootCollectionBase
    function _deliver(address to, uint256, uint256 quantity)
        internal
        override
        returns (uint256 firstTokenId)
    {
        firstTokenId = nextTokenId;
        uint256 tokenId = firstTokenId;
        for (uint256 i; i < quantity;) {
            _safeMint(to, tokenId);
            unchecked {
                ++i;
                ++tokenId;
            }
        }
        nextTokenId = tokenId;
    }

    // ---------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------

    /// @notice `ipfs://<dirCID>/<tokenId>.json`, that token's own traits.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(baseURI, tokenId.toString(), ".json");
    }

    /// @notice Number of tokens minted so far.
    function totalSupply() external view returns (uint256) {
        return nextTokenId - 1;
    }

    /// @notice Declared collection size. 0 = open-ended.
    function collectionSize() external view returns (uint256) {
        return tokenMaxSupply[DROP_ID];
    }

    /// @notice Tokens minted from this drop. Equals `totalSupply()`; both exist
    ///         because marketplaces expect the latter and the mint page reads
    ///         the former.
    function totalMinted() external view returns (uint256) {
        return mintedCount[DROP_ID];
    }

    /// @notice Tokens still mintable, or `type(uint256).max` if uncapped.
    function remaining() external view returns (uint256) {
        return remainingSupply(DROP_ID);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, SprootCollectionBase)
        returns (bool)
    {
        return interfaceId == ERC4906_INTERFACE_ID
            || ERC721Upgradeable.supportsInterface(interfaceId)
            || ERC2981Upgradeable.supportsInterface(interfaceId);
    }
}

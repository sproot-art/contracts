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

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";

import {SprootCollectionBase} from "./SprootCollectionBase.sol";
import {CollectionConfig, MintConfig, MintPhase} from "./SprootTypes.sol";

/// @title SprootERC1155
/// @notice ERC-1155 edition collection, cloned per creator by SprootFactory.
///         The clone's owner is the creator, permanently.
///
/// @dev Unlike the ERC-721 series model, a token id here is the edition:
///      `mint(tokenId, 5)` issues 5 copies of that id to the caller. This is
///      the one-artwork-many-collectors case.
contract SprootERC1155 is ERC1155Upgradeable, SprootCollectionBase {
    string public name;
    string public symbol;

    uint256[48] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        CollectionConfig calldata cfg,
        address feeSink_,
        uint256 platformFeeWei_
    ) external initializer {
        __ERC1155_init("");
        __SprootCollection_init(owner_, cfg, feeSink_, platformFeeWei_);
        name = cfg.name;
        symbol = cfg.symbol;
    }

    /// @notice Create a new edition.
    /// @param tokenURI_ `ipfs://...` metadata URI.
    /// @param maxSupply_ hard ceiling; 0 = open edition.
    function createToken(string calldata tokenURI_, uint256 maxSupply_)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        tokenId = _registerToken(tokenURI_, maxSupply_);
    }

    // -----------------------------------------------------------------
    // Mint terms, per token, because one contract holds many pieces
    // -----------------------------------------------------------------

    function setMintConfig(uint256 tokenId, MintConfig calldata cfg) external onlyOwner {
        _setMintConfig(tokenId, cfg);
    }

    function setPaused(uint256 tokenId, bool paused_) external onlyOwner {
        _setPaused(tokenId, paused_);
    }

    /// @notice Mint `quantity` copies of `tokenId` to the caller.
    function mint(uint256 tokenId, uint256 quantity) external payable nonReentrant {
        _processMint(tokenId, quantity);
    }

    /// @notice Set a token's phase schedule. An empty array clears it.
    /// @dev Per token, unlike ERC-721: a 1155 contract holds independent
    ///      pieces, and each runs its own drop on its own schedule.
    function setPhases(uint256 tokenId, MintPhase[] calldata phases_) external onlyOwner {
        _setPhases(tokenId, phases_);
    }

    /// @notice Mint within a phase, proving allowlist membership if it is gated.
    /// @param proof Merkle proof for the caller; empty for an open phase.
    function mintPhase(uint256 tokenId, uint256 phaseIndex, uint256 quantity, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        _processPhaseMint(tokenId, phaseIndex, quantity, proof);
    }

    /// @inheritdoc SprootCollectionBase
    function _deliver(address to, uint256 tokenId, uint256 quantity)
        internal
        override
        returns (uint256 reportedId)
    {
        _mint(to, tokenId, quantity, "");
        return tokenId;
    }

    /// @notice Per-token metadata URI.
    /// @dev ERC-1155's `uri()` is one template for all ids by default. SPROOT
    ///      pins a distinct metadata document per token, so this returns the
    ///      stored per-id URI instead.
    function uri(uint256 tokenId) public view override returns (string memory) {
        _requireTokenExists(tokenId);
        return _tokenURIs[tokenId];
    }

    function totalSupply(uint256 tokenId) external view returns (uint256) {
        return mintedCount[tokenId];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, SprootCollectionBase)
        returns (bool)
    {
        return ERC1155Upgradeable.supportsInterface(interfaceId)
            || ERC2981Upgradeable.supportsInterface(interfaceId);
    }
}

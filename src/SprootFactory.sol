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

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {SprootERC721} from "./SprootERC721.sol";
import {SprootERC1155} from "./SprootERC1155.sol";
import {ISprootFeeSink} from "./ISprootFeeSink.sol";
import {CollectionConfig, SprootStandard, SprootErrors} from "./SprootTypes.sol";

/// @title SprootFactory
/// @notice Deploys creator-owned NFT collections as EIP-1167 minimal proxies.
///
/// @dev The caller becomes the owner. The factory sets `msg.sender` as the
///      clone's owner and keeps nothing: no admin role, no fee hook, no pause
///      authority, no upgrade path. A creator's collection keeps working even
///      if SPROOT disappears.
///
/// @dev The factory itself is owned, and holds the platform fee configuration
///      and the fees collections pay at mint time. That is the only thing
///      SPROOT owns in the system, and it confers no authority over any
///      creator's collection. One factory per chain.
///
/// @dev The fee cannot be applied retroactively. `platformFeeWei` is read once,
///      at deploy, and written into the new collection permanently. Raising it
///      here affects future deploys only. `MAX_PLATFORM_FEE_WEI` bounds even
///      that, in bytecode.
///
/// @dev Portable by construction: no chain-conditional logic, no chain-specific
///      precompiles, no assumption about the gas token. The same bytecode
///      deploys on every supported chain.
contract SprootFactory is Ownable2Step, ReentrancyGuard, ISprootFeeSink {
    using Clones for address;

    /// @notice Fixed implementations that every clone delegates to.
    address public immutable erc721Implementation;
    address public immutable erc1155Implementation;

    /// @notice Hard ceiling on the per-NFT platform fee, in wei.
    /// @dev In bytecode, not storage, so the owner cannot raise it and a
    ///      creator can read the worst case rather than trust it. Sized as
    ///      headroom over the intended fee, not as a target.
    uint256 public constant MAX_PLATFORM_FEE_WEI = 0.002 ether;

    /// @notice Per-NFT platform fee applied to collections deployed from now
    ///         on, in wei. Starts at 0.
    /// @dev Denominated in the chain's gas token, so its fiat value drifts and
    ///      is retuned by hand. Only new deploys pick up a change.
    uint256 public platformFeeWei;

    event PlatformFeeUpdated(uint256 previousFeeWei, uint256 newFeeWei);
    event Withdrawn(address indexed to, uint256 amount);
    /// @dev `collection` is whoever paid. Anyone may call `collectFee`, so this
    ///      is attribution, not proof that a SPROOT collection minted.
    event FeeCollected(address indexed collection, address indexed payer, uint256 amount);

    event CollectionCreated(
        address indexed collection,
        address indexed owner,
        uint8 standard,
        string name,
        string symbol,
        bytes32 salt
    );

    /// @dev The deployer becomes the owner: the fee dial and the withdrawal key.
    constructor() Ownable(msg.sender) {
        erc721Implementation = address(new SprootERC721());
        erc1155Implementation = address(new SprootERC1155());
    }

    // ---------------------------------------------------------------------
    // Platform fee
    // ---------------------------------------------------------------------

    /// @notice Set the per-NFT fee that future collections will carry.
    /// @dev No effect on existing collections, which hold their own snapshot
    ///      and expose no setter.
    function setPlatformFee(uint256 feeWei) external onlyOwner {
        if (feeWei > MAX_PLATFORM_FEE_WEI) {
            revert SprootErrors.FeeAboveCap(feeWei, MAX_PLATFORM_FEE_WEI);
        }

        emit PlatformFeeUpdated(platformFeeWei, feeWei);
        platformFeeWei = feeWei;
    }

    /// @inheritdoc ISprootFeeSink
    /// @dev Ungated on purpose. Gating it would mean keeping a registry of
    ///      every collection ever deployed and reading it on every mint, just
    ///      to stop someone sending us money. Accept and log.
    function collectFee(address payer) external payable {
        emit FeeCollected(msg.sender, payer, msg.value);
    }

    /// @notice Withdraw accumulated platform fees.
    /// @dev Same shape as a collection's `withdraw`: pull, whole balance, and
    ///      `call` rather than `transfer` so a contract wallet can receive it.
    function withdraw(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert SprootErrors.ZeroAddress();

        uint256 amount = address(this).balance;
        if (amount == 0) revert SprootErrors.NothingToWithdraw();

        emit Withdrawn(to, amount);

        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert SprootErrors.WithdrawFailed(to, amount);
    }

    /// @notice Deploy an ERC-721 collection owned by the caller.
    /// @param salt caller-chosen salt; combined with `msg.sender` internally.
    /// @param maxFeeWei the highest per-NFT platform fee the caller accepts.
    function createERC721Collection(CollectionConfig calldata cfg, bytes32 salt, uint256 maxFeeWei)
        external
        returns (address collection)
    {
        uint256 feeWei = _acceptedFee(maxFeeWei);

        collection = erc721Implementation.cloneDeterministic(_deploySalt(msg.sender, salt));
        SprootERC721(collection).initialize(msg.sender, cfg, address(this), feeWei);

        emit CollectionCreated(collection, msg.sender, SprootStandard.ERC721, cfg.name, cfg.symbol, salt);
    }

    /// @notice Deploy an ERC-1155 collection owned by the caller.
    /// @param maxFeeWei the highest per-NFT platform fee the caller accepts.
    function createERC1155Collection(CollectionConfig calldata cfg, bytes32 salt, uint256 maxFeeWei)
        external
        returns (address collection)
    {
        uint256 feeWei = _acceptedFee(maxFeeWei);

        collection = erc1155Implementation.cloneDeterministic(_deploySalt(msg.sender, salt));
        SprootERC1155(collection).initialize(msg.sender, cfg, address(this), feeWei);

        emit CollectionCreated(collection, msg.sender, SprootStandard.ERC1155, cfg.name, cfg.symbol, salt);
    }

    /// @dev The fee this deploy will carry, refused if it exceeds what the
    ///      caller agreed to.
    ///
    ///      A collection's fee is permanent, which is why the value must be
    ///      pinned at signature time rather than read at execution time.
    ///      Without this bound, a `setPlatformFee` landing earlier in the same
    ///      block would stamp a fee the creator never saw onto their drop.
    ///
    ///      Read once into memory so the value checked is the value written.
    function _acceptedFee(uint256 maxFeeWei) private view returns (uint256 feeWei) {
        feeWei = platformFeeWei;
        if (feeWei > maxFeeWei) revert SprootErrors.FeeAboveExpected(feeWei, maxFeeWei);
    }

    /// @notice Predict a collection's address before deploying.
    /// @dev Lets the review step show the creator their actual contract address
    ///      before they sign.
    function predictAddress(uint8 standard, bytes32 salt, address deployer) external view returns (address) {
        address impl = standard == SprootStandard.ERC721 ? erc721Implementation : erc1155Implementation;
        return impl.predictDeterministicAddress(_deploySalt(deployer, salt), address(this));
    }

    /// @dev Binds the salt to the deployer, so one creator cannot occupy an
    ///      address another creator is about to use. Without this, salts are a
    ///      global namespace and predicted addresses can be front-run.
    function _deploySalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }
}

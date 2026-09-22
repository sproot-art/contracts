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

/// @notice Collection-level configuration, fixed at deploy time.
/// @dev `name` and `symbol` cannot change after deploy.
struct CollectionConfig {
    string name;
    string symbol;
    string contractURI;
    address royaltyRecipient;
    uint96 royaltyBps;
}

/// @notice Per-token mint terms, stored on-chain.
/// @dev `merkleRoot` is reserved for allowlists and must be zero. Reserving the
///      slot now keeps the storage layout stable when allowlists ship. A
///      non-zero value reverts instead of being ignored, so a future allowlist
///      can never appear to work while enforcing nothing.
struct MintConfig {
    uint256 price;
    uint256 maxSupply;
    uint32 perWallet;
    uint64 startTime;
    uint64 endTime;
    bool paused;
    bytes32 merkleRoot;
}

/// @notice One timed segment of a drop, such as a pre-sale or a public sale.
/// @dev Phases supersede `MintConfig` for any token that has them. Terms live
///      on-chain because a schedule enforced only by the page is not enforced.
///
///      A zero `merkleRoot` means the phase is open to everyone. A non-zero
///      root restricts it to addresses that can prove membership.
///
///      Phase names are deliberately absent: they are presentation, they cost
///      gas to store, and they belong in the off-chain mint page row.
struct MintPhase {
    uint256 price;
    /// @dev Allocation for this phase. 0 = share the token's own cap.
    uint256 maxSupply;
    uint32 perWallet;
    uint64 startTime;
    uint64 endTime;
    bytes32 merkleRoot;
}

/// @notice Token standard discriminator, as emitted in `CollectionCreated`.
library SprootStandard {
    uint8 internal constant ERC721 = 0;
    uint8 internal constant ERC1155 = 1;
}

/// @notice Errors shared by the factory and both collection implementations.
/// @dev Custom errors rather than revert strings: cheaper, and each maps to a
///      specific message in the UI. "Sold out" and "not started" are different
///      failures and a collector needs to be told which one happened.
library SprootErrors {
    error EmptyName();
    error EmptySymbol();
    error RoyaltyTooHigh(uint96 bps, uint96 max);
    error ZeroAddress();

    error TokenDoesNotExist(uint256 tokenId);
    error EmptyTokenURI();

    error MintNotConfigured(uint256 tokenId);
    error MintPaused(uint256 tokenId);
    error MintNotStarted(uint256 tokenId, uint64 startTime);
    error MintEnded(uint256 tokenId, uint64 endTime);
    error InvalidQuantity();
    error ExceedsMaxSupply(uint256 requested, uint256 remaining);
    error ExceedsWalletLimit(uint256 requested, uint256 remaining);
    error IncorrectPayment(uint256 sent, uint256 required);

    error InvalidTimeWindow(uint64 startTime, uint64 endTime);
    error SupplyBelowMinted(uint256 requested, uint256 alreadyMinted);
    error ExceedsTokenSupply(uint256 requested, uint256 tokenMaxSupply);
    error AllowlistNotSupported();

    // Phases.
    error NoPhases(uint256 tokenId);
    error PhaseDoesNotExist(uint256 tokenId, uint256 phaseIndex);
    error PhaseNotStarted(uint256 tokenId, uint256 phaseIndex, uint64 startTime);
    error PhaseEnded(uint256 tokenId, uint256 phaseIndex, uint64 endTime);
    error PhasesOverlap(uint256 first, uint256 second);
    error PhaseUnbounded(uint256 phaseIndex);
    error StartedPhaseImmutable(uint256 phaseIndex);
    error PhaseCountChanged();
    error TooManyPhases(uint256 requested, uint256 max);
    error NotOnAllowlist(uint256 phaseIndex, address account);
    error ProofNotRequired(uint256 phaseIndex);
    error ExceedsPhaseSupply(uint256 requested, uint256 remaining);
    error UsePhasedMint(uint256 tokenId);

    error NothingToWithdraw();
    error WithdrawFailed(address to, uint256 amount);

    // Platform fee.
    error FeeAboveCap(uint256 requested, uint256 max);
    /// @dev The factory's live fee exceeded the ceiling the creator signed for.
    ///      Distinct from `FeeAboveCap`, which guards the bytecode constant.
    ///      The two can fail independently.
    error FeeAboveExpected(uint256 actual, uint256 maxAccepted);

    error DropAlreadyConfigured();
    error DropNotConfigured();
    error MetadataIsFrozen();
}

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


import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {CollectionConfig, MintConfig, MintPhase, SprootErrors} from "./SprootTypes.sol";
import {ISprootFeeSink} from "./ISprootFeeSink.sol";

/// @title SprootCollectionBase
/// @notice Shared mint accounting, terms, proceeds, and royalties for both
///         SPROOT collection standards.
///
/// @dev Ownership: the factory passes the caller's address to `initialize`, and
///      this contract transfers ownership there immediately. SPROOT holds no
///      admin role, no pause authority, and no upgrade path on any deployed
///      collection. That is the product's central promise and must not be
///      weakened.
///
/// @dev Not upgradeable. Clones point at a fixed implementation; there is no
///      proxy admin and no `upgradeTo`. New features ship as a new
///      implementation used by future deploys only.
abstract contract SprootCollectionBase is
    Initializable,
    Ownable2StepUpgradeable,
    ERC2981Upgradeable,
    ReentrancyGuardUpgradeable
{
    /// @notice Hard ceiling on creator royalties.
    uint96 public constant MAX_ROYALTY_BPS = 1000; // 10%

    /// @notice Collection-level metadata URI (`ipfs://...`).
    string public contractURI;

    /// @notice Highest token id created so far. Token ids start at 1, never 0,
    ///         which is too easily confused with "unset".
    uint256 public totalTokens;

    mapping(uint256 tokenId => bool) internal _tokenExists;
    mapping(uint256 tokenId => string) internal _tokenURIs;

    /// @notice Hard supply ceiling declared when the token was created.
    ///         0 = open edition. ERC-721 series are always 0 here; their cap
    ///         comes from the mint config.
    mapping(uint256 tokenId => uint256) public tokenMaxSupply;

    mapping(uint256 tokenId => MintConfig) internal _mintConfigs;

    /// @notice Whether mint terms have been set. A token with no config cannot
    ///         be minted: a zero-valued MintConfig would read as free,
    ///         unlimited, and live, so absence must be an explicit refusal
    ///         rather than a permissive default. Shows as "Draft" in the UI.
    mapping(uint256 tokenId => bool) public mintConfigured;

    mapping(uint256 tokenId => uint256) public mintedCount;
    mapping(uint256 tokenId => mapping(address wallet => uint256)) public walletMinted;

    /// @notice Hard ceiling on phases per token. Bounded because `setPhases`
    ///         compares every pair to reject overlaps, which is quadratic.
    uint256 public constant MAX_PHASES = 8;

    /// @notice Timed segments of a drop. Empty means the single-window
    ///         `MintConfig` above governs.
    mapping(uint256 tokenId => MintPhase[]) internal _phases;

    /// @notice Minted per phase, so a phase allocation is enforceable and a
    ///         pre-sale cannot quietly consume the public phase's supply.
    mapping(uint256 tokenId => mapping(uint256 phaseIndex => uint256)) public phaseMinted;

    /// @notice Per-wallet, per-phase. Deliberately not shared with
    ///         `walletMinted`: an allowlist allocation of 2 and a public
    ///         allocation of 5 are separate entitlements, and folding them
    ///         together would let one phase eat the other's limit.
    mapping(uint256 tokenId => mapping(uint256 phaseIndex => mapping(address wallet => uint256))) public
        phaseWalletMinted;

    /// @notice Platform fee charged per NFT minted, on top of the creator's
    ///         price, in wei. 0 = no fee.
    ///
    /// @dev Snapshotted from the factory at initialization and never writable
    ///      again, not even by the owner. A collection's fee is whatever it was
    ///      when the creator deployed, so SPROOT can never raise the take on a
    ///      drop that already exists.
    uint256 public platformFeeWei;

    /// @notice Where the platform fee is sent: the factory that deployed this
    ///         collection. Zero when `platformFeeWei` is 0.
    /// @dev Also fixed at initialization, for the same reason.
    address public feeSink;

    /// @dev Storage gap. The implementation is fixed per deploy, but a future
    ///      implementation used by later collections should be able to add
    ///      state without disturbing the layout inherited by subclasses.
    ///      Decremented as state is added above, so the total stays constant.
    uint256[35] private __gap;

    event TokenCreated(uint256 indexed tokenId, string tokenURI, uint256 maxSupply);
    event MintConfigUpdated(
        uint256 indexed tokenId,
        uint256 price,
        uint256 maxSupply,
        uint32 perWallet,
        uint64 startTime,
        uint64 endTime,
        bool paused
    );
    event Minted(uint256 indexed tokenId, address indexed to, uint256 quantity, uint256 pricePaid);
    /// @dev One event per phase, plus a count, so an indexer can rebuild the
    ///      whole schedule from logs without an archive-node state read.
    event PhasesUpdated(uint256 indexed tokenId, uint256 phaseCount);
    event PhaseSet(
        uint256 indexed tokenId,
        uint256 indexed phaseIndex,
        uint256 price,
        uint256 maxSupply,
        uint32 perWallet,
        uint64 startTime,
        uint64 endTime,
        bytes32 merkleRoot
    );
    /// @dev Carries the phase so proceeds and allowlist take-up are attributable.
    event PhaseMinted(
        uint256 indexed tokenId, uint256 indexed phaseIndex, address indexed to, uint256 quantity
    );
    event Withdrawn(address indexed to, uint256 amount);
    /// @dev Emitted alongside `Minted` whenever a platform fee was taken, so the
    ///      split is reconstructable from this collection's own logs and not
    ///      only from the factory's.
    event PlatformFeePaid(address indexed sink, address indexed payer, uint256 amount);
    event ContractURIUpdated(string contractURI);

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function __SprootCollection_init(
        address owner_,
        CollectionConfig calldata cfg,
        address feeSink_,
        uint256 platformFeeWei_
    ) internal onlyInitializing {
        if (owner_ == address(0)) revert SprootErrors.ZeroAddress();
        if (platformFeeWei_ != 0 && feeSink_ == address(0)) revert SprootErrors.ZeroAddress();
        validateCollectionConfig(cfg);

        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ERC2981_init();
        __ReentrancyGuard_init();

        contractURI = cfg.contractURI;
        _setDefaultRoyalty(cfg.royaltyRecipient, cfg.royaltyBps);

        // Written once, here, and never again. See the field docs above.
        platformFeeWei = platformFeeWei_;
        feeSink = feeSink_;
    }

    /// @notice Validates collection config. Public so the factory enforces the
    ///         same rules before it spends gas on a clone, and so tests and the
    ///         frontend can dry-run the exact on-chain rules.
    /// @dev Client-side validation is UX; this is the truth.
    function validateCollectionConfig(CollectionConfig calldata cfg) public pure {
        if (bytes(cfg.name).length == 0) revert SprootErrors.EmptyName();
        if (bytes(cfg.symbol).length == 0) revert SprootErrors.EmptySymbol();
        if (cfg.royaltyBps > MAX_ROYALTY_BPS) {
            revert SprootErrors.RoyaltyTooHigh(cfg.royaltyBps, MAX_ROYALTY_BPS);
        }
        if (cfg.royaltyRecipient == address(0)) revert SprootErrors.ZeroAddress();
    }

    // ---------------------------------------------------------------------
    // Owner actions
    // ---------------------------------------------------------------------

    function _setMintConfig(uint256 tokenId, MintConfig calldata cfg) internal {
        _requireTokenExists(tokenId);

        // Allowlists are not implemented on this path. Reject rather than
        // ignore. See the note on MintConfig in SprootTypes.sol.
        if (cfg.merkleRoot != bytes32(0)) revert SprootErrors.AllowlistNotSupported();

        if (cfg.startTime != 0 && cfg.endTime != 0 && cfg.endTime <= cfg.startTime) {
            revert SprootErrors.InvalidTimeWindow(cfg.startTime, cfg.endTime);
        }

        // A cap below what is already minted would strand the counter above the
        // ceiling and make "sold out" unreachable coherently.
        uint256 minted = mintedCount[tokenId];
        if (cfg.maxSupply != 0 && cfg.maxSupply < minted) {
            revert SprootErrors.SupplyBelowMinted(cfg.maxSupply, minted);
        }

        // The mint allocation may not exceed the token's declared hard cap. A
        // zero allocation means no limit beyond the token's own cap, so against
        // a capped token it normalizes to that cap rather than being rejected:
        // a creator who declared 10,000 pieces and left the allocation blank
        // means all 10,000.
        uint256 hardCap = tokenMaxSupply[tokenId];
        uint256 effectiveSupply = cfg.maxSupply;
        if (hardCap != 0) {
            if (effectiveSupply == 0) {
                effectiveSupply = hardCap;
            } else if (effectiveSupply > hardCap) {
                revert SprootErrors.ExceedsTokenSupply(effectiveSupply, hardCap);
            }
        }

        _mintConfigs[tokenId] = cfg;
        // Store the effective cap, so every reader (indexer, mint page,
        // `remainingSupply`) sees one number and not a rule to re-derive.
        _mintConfigs[tokenId].maxSupply = effectiveSupply;
        mintConfigured[tokenId] = true;

        emit MintConfigUpdated(
            tokenId, cfg.price, effectiveSupply, cfg.perWallet, cfg.startTime, cfg.endTime, cfg.paused
        );
    }

    /// @dev Replace a token's phase schedule.
    ///
    ///      Two rules make this safe to call on a live drop:
    ///
    ///      1. A phase that has already started is immutable. Collectors minted
    ///         on those terms, so re-pricing it or swapping its allowlist would
    ///         rewrite what they agreed to. Existing started phases must be
    ///         resubmitted byte-identically, and the array may only grow.
    ///      2. Phases may not overlap in time. Two live phases means two
    ///         simultaneous prices for the same token, and which one applies
    ///         becomes an argument the caller picks and the collector does not
    ///         control.
    ///
    ///      An empty array clears the schedule and returns the token to its
    ///      single-window `MintConfig`, which is only permitted while nothing
    ///      has started.
    function _setPhases(uint256 tokenId, MintPhase[] calldata newPhases) internal {
        _requireTokenExists(tokenId);
        if (newPhases.length > MAX_PHASES) revert SprootErrors.TooManyPhases(newPhases.length, MAX_PHASES);

        MintPhase[] storage existing = _phases[tokenId];
        uint256 existingLength = existing.length;

        // Rule 1: started phases are frozen, and cannot be dropped by shortening.
        for (uint256 i = 0; i < existingLength; i++) {
            if (!_phaseStarted(existing[i])) continue;
            if (newPhases.length <= i) revert SprootErrors.PhaseCountChanged();
            if (keccak256(abi.encode(existing[i])) != keccak256(abi.encode(newPhases[i]))) {
                revert SprootErrors.StartedPhaseImmutable(i);
            }
        }

        for (uint256 i = 0; i < newPhases.length; i++) {
            MintPhase calldata p = newPhases[i];
            if (p.startTime != 0 && p.endTime != 0 && p.endTime <= p.startTime) {
                revert SprootErrors.InvalidTimeWindow(p.startTime, p.endTime);
            }
            // An unbounded phase cannot be followed by anything: with no end,
            // every later phase overlaps it. Only the last may run forever.
            if (p.endTime == 0 && i + 1 < newPhases.length) revert SprootErrors.PhaseUnbounded(i);

            // Rule 2. Quadratic, but bounded by MAX_PHASES.
            for (uint256 j = 0; j < i; j++) {
                if (_overlaps(newPhases[j], p)) revert SprootErrors.PhasesOverlap(j, i);
            }
        }

        delete _phases[tokenId];
        for (uint256 i = 0; i < newPhases.length; i++) {
            _phases[tokenId].push(newPhases[i]);
            emit PhaseSet(
                tokenId,
                i,
                newPhases[i].price,
                newPhases[i].maxSupply,
                newPhases[i].perWallet,
                newPhases[i].startTime,
                newPhases[i].endTime,
                newPhases[i].merkleRoot
            );
        }

        emit PhasesUpdated(tokenId, newPhases.length);
    }

    /// @dev Half-open intervals: a phase ending exactly when the next begins is
    ///      a clean handover, not an overlap. `startTime == 0` means already
    ///      open, `endTime == 0` means never closes.
    function _overlaps(MintPhase calldata a, MintPhase calldata b) private pure returns (bool) {
        uint64 aEnd = a.endTime == 0 ? type(uint64).max : a.endTime;
        uint64 bEnd = b.endTime == 0 ? type(uint64).max : b.endTime;
        return a.startTime < bEnd && b.startTime < aEnd;
    }

    function _phaseStarted(MintPhase storage p) private view returns (bool) {
        return block.timestamp >= p.startTime;
    }

    /// @dev Pause or resume a mint. On-chain state, so it needs the owner's
    ///      signature: the platform cannot pause a creator's mint.
    function _setPaused(uint256 tokenId, bool paused_) internal {
        _requireTokenExists(tokenId);
        if (!mintConfigured[tokenId]) revert SprootErrors.MintNotConfigured(tokenId);

        MintConfig storage cfg = _mintConfigs[tokenId];
        cfg.paused = paused_;

        emit MintConfigUpdated(
            tokenId, cfg.price, cfg.maxSupply, cfg.perWallet, cfg.startTime, cfg.endTime, paused_
        );
    }

    function setContractURI(string calldata contractURI_) external onlyOwner {
        contractURI = contractURI_;
        emit ContractURIUpdated(contractURI_);
    }

    /// @notice Update the ERC-2981 royalty.
    function setDefaultRoyalty(address recipient, uint96 bps) external onlyOwner {
        if (recipient == address(0)) revert SprootErrors.ZeroAddress();
        if (bps > MAX_ROYALTY_BPS) revert SprootErrors.RoyaltyTooHigh(bps, MAX_ROYALTY_BPS);
        _setDefaultRoyalty(recipient, bps);
    }

    /// @notice Withdraw accumulated mint proceeds.
    /// @dev Pull, not push. Forwarding on every mint would put an arbitrary
    ///      external call in the mint path, so one hostile or gas-hungry
    ///      recipient could brick every mint. Uses `call` rather than
    ///      `transfer`: the 2300-gas stipend breaks contract wallets, which
    ///      this audience uses.
    function withdraw(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert SprootErrors.ZeroAddress();

        uint256 amount = address(this).balance;
        if (amount == 0) revert SprootErrors.NothingToWithdraw();

        emit Withdrawn(to, amount);

        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert SprootErrors.WithdrawFailed(to, amount);
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    /// @notice Mint `quantity` of `tokenId` to the caller.
    /// @dev Checks-Effects-Interactions, plus a reentrancy guard. `_deliver`
    ///      lands in ERC-721 `_safeMint` or ERC-1155 `_mint`, both of which
    ///      call into the receiver, so this is a live surface.
    ///
    ///      Every limit is enforced here and only here. The indexed count in
    ///      Postgres is a display cache; two collectors racing for the last
    ///      piece are resolved by the supply check below, and the loser reverts.
    function _processMint(uint256 tokenId, uint256 quantity) internal {
        _requireTokenExists(tokenId);
        if (quantity == 0) revert SprootErrors.InvalidQuantity();

        // A phased token must be minted through `mintPhase`. Letting the
        // single-window path stand would be a hole straight through every
        // allowlist: mint the same token here, prove nothing, pay the old
        // price. Refused explicitly rather than silently ignored.
        if (_phases[tokenId].length != 0) revert SprootErrors.UsePhasedMint(tokenId);

        if (!mintConfigured[tokenId]) revert SprootErrors.MintNotConfigured(tokenId);

        MintConfig storage cfg = _mintConfigs[tokenId];

        if (cfg.paused) revert SprootErrors.MintPaused(tokenId);
        if (cfg.startTime != 0 && block.timestamp < cfg.startTime) {
            revert SprootErrors.MintNotStarted(tokenId, cfg.startTime);
        }
        if (cfg.endTime != 0 && block.timestamp > cfg.endTime) {
            revert SprootErrors.MintEnded(tokenId, cfg.endTime);
        }

        uint256 alreadyMinted = mintedCount[tokenId];
        if (cfg.maxSupply != 0) {
            uint256 remaining = cfg.maxSupply - alreadyMinted;
            if (quantity > remaining) revert SprootErrors.ExceedsMaxSupply(quantity, remaining);
        }

        if (cfg.perWallet != 0) {
            uint256 walletSoFar = walletMinted[tokenId][msg.sender];
            uint256 walletRemaining = walletSoFar >= cfg.perWallet ? 0 : cfg.perWallet - walletSoFar;
            if (quantity > walletRemaining) {
                revert SprootErrors.ExceedsWalletLimit(quantity, walletRemaining);
            }
        }

        // Exact payment, not `>=`. Accepting overpayment means either keeping
        // the excess or refunding it: the first is theft-adjacent, the second
        // adds another external call to the mint path. Reverting is honest, and
        // the UI computes the exact total.
        //
        // The platform fee rides on top of the creator's price, per NFT, and is
        // itemized in the checkout dialog before the collector reaches their
        // wallet. A fee discovered at the signature prompt would be a trick.
        uint256 fee = platformFeeWei * quantity;
        uint256 required = cfg.price * quantity + fee;
        if (msg.value != required) revert SprootErrors.IncorrectPayment(msg.value, required);

        // Effects before interactions.
        mintedCount[tokenId] = alreadyMinted + quantity;
        walletMinted[tokenId][msg.sender] += quantity;

        // Interactions last. `_deliver` reports the id to attribute the mint
        // to: the token id for an ERC-1155 edition, or the first NFT id for an
        // ERC-721 collection, from which the indexer derives the range.
        uint256 reportedId = _deliver(msg.sender, tokenId, quantity);

        _payPlatformFee(fee);

        // `pricePaid` is the creator's share, never the gross. Every consumer
        // (indexer, leaderboard, stats) already reads it as revenue.
        emit Minted(reportedId, msg.sender, quantity, msg.value - fee);
    }

    /// @notice Mint within a specific phase, proving allowlist membership when
    ///         that phase requires it.
    ///
    /// @dev Same Checks-Effects-Interactions discipline as `_processMint`, and
    ///      the same reentrancy guard on the external entry points. The phase
    ///      supplies price, window, and limits; the token's own hard cap and
    ///      the collection-wide counter still apply on top, so a phase
    ///      allocation can never over-issue the collection.
    function _processPhaseMint(
        uint256 tokenId,
        uint256 phaseIndex,
        uint256 quantity,
        bytes32[] calldata proof
    ) internal {
        _requireTokenExists(tokenId);
        if (quantity == 0) revert SprootErrors.InvalidQuantity();

        MintPhase[] storage list = _phases[tokenId];
        if (list.length == 0) revert SprootErrors.NoPhases(tokenId);
        if (phaseIndex >= list.length) {
            revert SprootErrors.PhaseDoesNotExist(tokenId, phaseIndex);
        }

        MintPhase storage phase = list[phaseIndex];

        // Phases refine the token's terms; they never stand in for them. A
        // token with no `MintConfig` is a draft, and a draft is unmintable by
        // every path, the same refusal `_processMint` makes.
        //
        // This is load-bearing beyond the draft rule. Both the pause flag and
        // the supply ceiling below live in `MintConfig`, and `_setPaused`
        // refuses to write to a config that was never created. Without this
        // check, a `setupDrop` plus `setPhases` sequence, which the contract
        // otherwise accepts, produces a live, uncapped mint whose owner's
        // emergency stop reverts every time they call it, and whose started
        // phases can no longer be edited or cleared. Nobody can undo that
        // state, including us.
        if (!mintConfigured[tokenId]) revert SprootErrors.MintNotConfigured(tokenId);

        // A paused token is paused in every phase: pause is the creator's
        // emergency stop, and a phase-shaped hole in it is not one.
        if (_mintConfigs[tokenId].paused) revert SprootErrors.MintPaused(tokenId);

        if (phase.startTime != 0 && block.timestamp < phase.startTime) {
            revert SprootErrors.PhaseNotStarted(tokenId, phaseIndex, phase.startTime);
        }
        if (phase.endTime != 0 && block.timestamp > phase.endTime) {
            revert SprootErrors.PhaseEnded(tokenId, phaseIndex, phase.endTime);
        }

        // Allowlist. The leaf is double-hashed so no leaf can be mistaken for
        // an internal node, the standard second-preimage defence.
        if (phase.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
            if (!MerkleProof.verifyCalldata(proof, phase.merkleRoot, leaf)) {
                revert SprootErrors.NotOnAllowlist(phaseIndex, msg.sender);
            }
        } else if (proof.length != 0) {
            // A proof sent to an open phase means the caller believes this is
            // gated when it is not. Say so rather than accept it silently.
            revert SprootErrors.ProofNotRequired(phaseIndex);
        }

        // Phase allocation.
        uint256 phaseSoFar = phaseMinted[tokenId][phaseIndex];
        if (phase.maxSupply != 0) {
            uint256 phaseRemaining = phaseSoFar >= phase.maxSupply ? 0 : phase.maxSupply - phaseSoFar;
            if (quantity > phaseRemaining) {
                revert SprootErrors.ExceedsPhaseSupply(quantity, phaseRemaining);
            }
        }

        if (phase.perWallet != 0) {
            uint256 walletSoFar = phaseWalletMinted[tokenId][phaseIndex][msg.sender];
            uint256 walletRemaining = walletSoFar >= phase.perWallet ? 0 : phase.perWallet - walletSoFar;
            if (quantity > walletRemaining) {
                revert SprootErrors.ExceedsWalletLimit(quantity, walletRemaining);
            }
        }

        // The collection's own ceiling still binds. Phase allocations divide
        // supply; they never exceed it.
        uint256 alreadyMinted = mintedCount[tokenId];
        uint256 cap = tokenMaxSupply[tokenId] != 0 ? tokenMaxSupply[tokenId] : _mintConfigs[tokenId].maxSupply;
        if (cap != 0) {
            uint256 remaining = alreadyMinted >= cap ? 0 : cap - alreadyMinted;
            if (quantity > remaining) revert SprootErrors.ExceedsMaxSupply(quantity, remaining);
        }

        uint256 fee = platformFeeWei * quantity;
        uint256 required = phase.price * quantity + fee;
        if (msg.value != required) revert SprootErrors.IncorrectPayment(msg.value, required);

        // Effects before interactions.
        mintedCount[tokenId] = alreadyMinted + quantity;
        walletMinted[tokenId][msg.sender] += quantity;
        phaseMinted[tokenId][phaseIndex] = phaseSoFar + quantity;
        phaseWalletMinted[tokenId][phaseIndex][msg.sender] += quantity;

        uint256 reportedId = _deliver(msg.sender, tokenId, quantity);

        _payPlatformFee(fee);

        // Both events: `Minted` keeps every existing consumer working, and
        // `PhaseMinted` adds the attribution the schedule needs.
        emit Minted(reportedId, msg.sender, quantity, msg.value - fee);
        emit PhaseMinted(tokenId, phaseIndex, msg.sender, quantity);
    }

    /// @dev Forwards the platform fee to the sink, leaving the creator's share
    ///      in this contract for their own `withdraw`.
    ///
    ///      Push, not pull, unlike creator proceeds. The argument against
    ///      pushing proceeds is that a hostile recipient could brick every
    ///      mint; here the recipient is the factory, fixed at deploy, whose
    ///      `collectFee` does nothing but accept and log. Pushing keeps the two
    ///      pots from mixing, so a creator's `withdraw` can never sweep fees
    ///      and a fee withdrawal can never touch a creator's earnings.
    ///
    ///      Called after `_deliver`, inside the entry point's `nonReentrant`
    ///      guard. A reverting sink reverts the mint, which is the honest
    ///      outcome: the collector paid a fee that could not be delivered.
    function _payPlatformFee(uint256 fee) private {
        if (fee == 0) return;

        address sink = feeSink;
        ISprootFeeSink(sink).collectFee{value: fee}(msg.sender);

        emit PlatformFeePaid(sink, msg.sender, fee);
    }

    /// @dev Standard-specific delivery. Returns the id to report in `Minted`.
    function _deliver(address to, uint256 tokenId, uint256 quantity)
        internal
        virtual
        returns (uint256 reportedId);

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function mintConfig(uint256 tokenId) external view returns (MintConfig memory) {
        return _mintConfigs[tokenId];
    }

    function tokenExists(uint256 tokenId) public view returns (bool) {
        return _tokenExists[tokenId];
    }

    /// @notice The whole schedule, for a page that must show every phase and
    ///         not merely the live one.
    function phases(uint256 tokenId) external view returns (MintPhase[] memory) {
        return _phases[tokenId];
    }

    function phaseCount(uint256 tokenId) external view returns (uint256) {
        return _phases[tokenId].length;
    }

    /// @notice Index of the phase live right now, and whether there is one.
    /// @dev Returned rather than derived on the client so the page and the
    ///      contract cannot disagree about which terms are in force.
    function activePhase(uint256 tokenId) external view returns (bool active, uint256 phaseIndex) {
        MintPhase[] storage list = _phases[tokenId];
        for (uint256 i = 0; i < list.length; i++) {
            bool started = list[i].startTime == 0 || block.timestamp >= list[i].startTime;
            bool ended = list[i].endTime != 0 && block.timestamp > list[i].endTime;
            if (started && !ended) return (true, i);
        }
        return (false, 0);
    }

    /// @notice Whether `account` may mint in `phaseIndex` with `proof`.
    /// @dev The page asks this before enabling its button, so a collector who
    ///      is not on the list is told, rather than shown a control that
    ///      reverts.
    function isAllowed(uint256 tokenId, uint256 phaseIndex, address account, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        MintPhase[] storage list = _phases[tokenId];
        if (phaseIndex >= list.length) return false;
        bytes32 root = list[phaseIndex].merkleRoot;
        if (root == bytes32(0)) return true;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account))));
        return MerkleProof.verifyCalldata(proof, root, leaf);
    }

    /// @notice Remaining mintable supply, or `type(uint256).max` if uncapped.
    function remainingSupply(uint256 tokenId) public view returns (uint256) {
        if (!mintConfigured[tokenId]) return 0;
        uint256 cap = _mintConfigs[tokenId].maxSupply;
        if (cap == 0) return type(uint256).max;
        uint256 minted = mintedCount[tokenId];
        return minted >= cap ? 0 : cap - minted;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _requireTokenExists(uint256 tokenId) internal view {
        if (!_tokenExists[tokenId]) revert SprootErrors.TokenDoesNotExist(tokenId);
    }

    /// @dev Registers a new token id and its metadata URI. Ids start at 1.
    function _registerToken(string calldata tokenURI_, uint256 maxSupply_)
        internal
        returns (uint256 tokenId)
    {
        if (bytes(tokenURI_).length == 0) revert SprootErrors.EmptyTokenURI();

        unchecked {
            tokenId = ++totalTokens;
        }
        _tokenExists[tokenId] = true;
        _tokenURIs[tokenId] = tokenURI_;
        tokenMaxSupply[tokenId] = maxSupply_;

        emit TokenCreated(tokenId, tokenURI_, maxSupply_);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISprootFeeSink
/// @notice Minimal surface a collection needs to hand off the platform fee.
///
/// @dev Lets SprootCollectionBase pay the factory without importing it. The
///      factory already imports both implementations to deploy them, so a
///      direct import back would be circular.
///
/// @dev A collection stores the sink address once, at initialization, and has
///      no setter. The fee destination is fixed for the collection's lifetime.
interface ISprootFeeSink {
    /// @notice Accept a platform fee collected during a mint.
    /// @param payer the collector whose mint produced the fee. Attribution
    ///        only; the sink must not treat it as authorization.
    function collectFee(address payer) external payable;
}

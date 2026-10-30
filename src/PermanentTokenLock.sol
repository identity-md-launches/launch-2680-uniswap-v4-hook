// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Irrecoverable custody for launch tokens that reject zero-address transfers.
/// @dev No owner, approvals, calls, withdrawal, delegatecall or upgrade mechanism.
/// Locking reduces circulating supply; it does not change the token's totalSupply.
contract PermanentTokenLock {}

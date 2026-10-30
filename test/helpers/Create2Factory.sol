// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal CREATE2 deployer for tests. Its code is etched at the brief's deployer address so a
/// test can prove where the real deployer's CREATE2 lands. A failed creation bubbles the revert data.
contract Create2Factory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address target) {
        assembly ("memory-safe") {
            target := create2(0, add(initCode, 32), mload(initCode), salt)
            if iszero(target) {
                let size := returndatasize()
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }
}

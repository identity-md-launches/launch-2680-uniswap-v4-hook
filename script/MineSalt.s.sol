// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SigmaHook} from "../src/SigmaHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Local, bounded CREATE2 salt search. Never broadcasts or reads configuration.
contract MineSalt {
    error SearchExhausted();

    /// @dev deployer is the actual CREATE2 factory, not the calling EOA or this script contract.
    /// Pass the exact final constructor arguments. Retry with the next start if a batch exhausts.
    function run(
        address deployer,
        IPoolManager manager,
        address owner,
        address token,
        address factory,
        uint256 start,
        uint256 attempts
    ) external pure returns (bytes32 salt, address predicted) {
        bytes32 hash = keccak256(bytes.concat(type(SigmaHook).creationCode, abi.encode(manager, owner, token, factory)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.SIGMA)) return (salt, predicted);
        }
        revert SearchExhausted();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICreatePoolManager} from "../../src/DeployFactory.sol";

/// @notice Test-only adapter for the requested createPool ABI over the real vendored manager.
/// @dev The 1:1 price is a fixture value, NOT a claim about the target chain's initial-price policy.
contract CreatePoolManagerHarness is PoolManager, ICreatePoolManager {
    error ManagerFailure();

    enum Behavior {
        Initialize,
        Revert,
        NoOp
    }

    Behavior public behavior;
    address public lastSender;
    uint256 public calls;

    constructor() PoolManager(msg.sender) {}

    function setBehavior(Behavior value) external {
        behavior = value;
    }

    function createPool(PoolKey calldata key) external {
        lastSender = msg.sender;
        ++calls;
        if (behavior == Behavior.Revert) revert ManagerFailure();
        if (behavior == Behavior.NoOp) return;
        // Self-delegatecall preserves the factory sender in the actual upstream initialize callback.
        // Never deployed as production code; no external/caller-chosen delegatecall target.
        (bool ok, bytes memory result) =
            address(this).delegatecall(abi.encodeCall(IPoolManager.initialize, (key, uint160(1 << 96))));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

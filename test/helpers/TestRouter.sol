// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Funded test-only router. Its funds belong to the test; no production routing or payer API.
contract TestRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    address public immutable controller;
    bool public hookDeltasWereZero;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount, uint160 limit) external returns (BalanceDelta) {
        require(msg.sender == controller);
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), key, abi.encode(SwapParams(zeroForOne, amount, limit)))), (BalanceDelta)
        );
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 change) external returns (BalanceDelta) {
        require(msg.sender == controller);
        return abi.decode(
            manager.unlock(
                abi.encode(uint8(1), key, abi.encode(ModifyLiquidityParams(lower, upper, change, bytes32(0))))
            ),
            (BalanceDelta)
        );
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        require(msg.sender == controller);
        manager.unlock(abi.encode(uint8(2), key, abi.encode(amount0, amount1)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, PoolKey memory key, bytes memory args) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        } else if (action == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        } else {
            (uint256 amount0, uint256 amount1) = abi.decode(args, (uint256, uint256));
            delta = manager.donate(key, amount0, amount1, "");
        }
        // Check before paying the swap input: the hook must have settled its own account already.
        hookDeltasWereZero = manager.currencyDelta(address(key.hooks), key.currency0) == 0
            && manager.currencyDelta(address(key.hooks), key.currency1) == 0;
        require(hookDeltasWereZero, "hook debt leaked into router settlement");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                currency.transfer(address(manager), amount);
                manager.settle();
            }
        }
    }

    receive() external payable {}
}

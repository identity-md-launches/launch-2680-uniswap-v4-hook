// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BandMath} from "./libraries/BandMath.sol";
import {VaultMath} from "./libraries/VaultMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface ISigmaPosition {
    function poolManager() external view returns (IPoolManager);
    function poolId() external view returns (PoolId);
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);
    function liquidity() external view returns (uint128);
}

/// @notice Immutable, stateless arithmetic and position-view module deployed by each SigmaHook.
/// @dev Read-only calculations: no token custody, mutable storage, owner or upgrade path.
/// Keeping calculation bytecode here keeps the hook below the EIP-170 deployment limit.
contract SigmaMath {
    using StateLibrary for IPoolManager;

    function positionAssets(address basket, bool roundUp)
        external
        view
        returns (uint256 principal0, uint256 principal1, uint256 fee0, uint256 fee1)
    {
        ISigmaPosition hook = ISigmaPosition(basket);
        uint128 liquidity = hook.liquidity();
        if (liquidity == 0) return (0, 0, 0, 0);
        IPoolManager manager = hook.poolManager();
        PoolId id = hook.poolId();
        int24 lower = hook.tickLower();
        int24 upper = hook.tickUpper();
        (uint160 price,,,) = manager.getSlot0(id);
        (principal0, principal1) = VaultMath.amounts(
            price, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity, roundUp
        );
        (, uint256 last0, uint256 last1) =
            manager.getPositionInfo(id, basket, lower, upper, keccak256("SigmaHook.vault"));
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthInside(id, lower, upper);
        // v4 fee growth counters wrap modulo 2^256.
        unchecked {
            growth0 -= last0;
            growth1 -= last1;
        }
        fee0 = FullMath.mulDiv(growth0, liquidity, 1 << 128);
        fee1 = FullMath.mulDiv(growth1, liquidity, 1 << 128);
    }

    function moments(int24[8] calldata ticks) external pure returns (int256 sum, uint256 sigma8) {
        return BandMath.moments(ticks);
    }

    function statistics(int24[8] calldata ticks) external pure returns (int24 mean, uint256 sigma) {
        return BandMath.statistics(ticks);
    }

    function bands(int256 sum, uint256 sigma8, int24 spacing, uint256 rangeSigma)
        external
        pure
        returns (int24 lower, int24 upper)
    {
        return BandMath.bands(sum, sigma8, spacing, rangeSigma);
    }

    function priceAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function liquidityForAmounts(uint160 price, int24 lower, int24 upper, uint256 amount0, uint256 amount1, uint128 cap)
        external
        pure
        returns (uint128)
    {
        return VaultMath.liquidityForAmounts(
            price, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1, cap
        );
    }

    function amounts(uint160 price, int24 lower, int24 upper, uint128 liquidity, bool roundUp)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return VaultMath.amounts(
            price, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity, roundUp
        );
    }

    function rebalanceTrade(uint160 price, int24 lower, int24 upper, uint256 have0, uint256 have1, uint256 deadband)
        external
        pure
        returns (bool zeroForOne, uint256 amountIn)
    {
        return VaultMath.rebalanceTrade(
            price, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), have0, have1, deadband
        );
    }
}

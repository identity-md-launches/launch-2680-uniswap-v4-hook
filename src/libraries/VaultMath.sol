// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

library VaultMath {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant BPS = 10_000;

    /// @dev Value of `amount0` in currency1 units at sqrt price `price`.
    function valueInCurrency1(uint256 amount0, uint160 price) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, price, Q96), price, Q96);
    }

    /// @dev Currency0 worth `value1` currency1 units at sqrt price `price`.
    function amount0ForValue(uint256 value1, uint160 price) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(value1, Q96, price), Q96, price);
    }

    /// @dev Currency1 holdings, out of `total` value in currency1 units, that the band [lower, upper]
    /// needs at `price`. Per unit of liquidity the band holds (p − lower) of currency1 and
    /// (upper − p) · p / upper of currency0 value, both in sqrt-price units; the share follows from
    /// those weights, with the price clamped to the band so a one-sided range gets a one-sided target.
    function targetAmount1(uint160 price, uint160 lower, uint160 upper, uint256 total) internal pure returns (uint256) {
        uint160 inside = price < lower ? lower : (price > upper ? upper : price);
        uint256 weight1 = FullMath.mulDiv(inside - lower, upper, inside);
        uint256 weight0 = upper - inside;
        return FullMath.mulDiv(total, weight1, weight1 + weight0);
    }

    /// @dev Exact-input trade that moves (have0, have1) towards the band's ratio at `price`, or
    /// amountIn 0 when the imbalance is under `deadbandBps` of value. The ratio is evaluated at the
    /// pre-trade price; fees and price impact leave a remainder the next cycle sees.
    function rebalanceTrade(
        uint160 price,
        uint160 lower,
        uint160 upper,
        uint256 have0,
        uint256 have1,
        uint256 deadbandBps
    ) internal pure returns (bool zeroForOne, uint256 amountIn) {
        uint256 total = have1 + valueInCurrency1(have0, price);
        if (total == 0) return (false, 0);
        uint256 target1 = targetAmount1(price, lower, upper, total);
        if (have1 > target1) {
            uint256 surplus = have1 - target1;
            if (surplus * BPS < total * deadbandBps) return (false, 0);
            return (false, surplus);
        }
        uint256 missing = target1 - have1;
        if (missing * BPS < total * deadbandBps) return (false, 0);
        amountIn = amount0ForValue(missing, price);
        if (amountIn > have0) amountIn = have0;
        return (true, amountIn);
    }

    /// @dev Price limit for a balancing trade: the band edge it moves towards, no further than
    /// `maxTicks` from the current tick, inside v4's open price interval.
    function tradeLimit(bool zeroForOne, int24 tick, int24 lowerTick, int24 upperTick, int24 maxTicks)
        internal
        pure
        returns (uint160 limit)
    {
        int24 bound;
        if (zeroForOne) {
            bound = tick - maxTicks;
            if (bound < lowerTick) bound = lowerTick;
        } else {
            bound = tick + maxTicks;
            if (bound > upperTick) bound = upperTick;
        }
        if (bound < TickMath.MIN_TICK) bound = TickMath.MIN_TICK;
        if (bound > TickMath.MAX_TICK) bound = TickMath.MAX_TICK;
        limit = TickMath.getSqrtPriceAtTick(bound);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
    }

    function amounts(uint160 price, uint160 lower, uint160 upper, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (price < upper) {
            amount0 = SqrtPriceMath.getAmount0Delta(price > lower ? price : lower, upper, liquidity, roundUp);
        }
        if (price > lower) {
            amount1 = SqrtPriceMath.getAmount1Delta(lower, price < upper ? price : upper, liquidity, roundUp);
        }
    }

    /// @dev Largest liquidity whose rounded-up costs fit both budgets, at most `cap`.
    /// Only a budget below the cap's own cost is sized, which bounds amount0 * a below
    /// 2^256 * (upper - a) and keeps the first product from overflowing even one sqrt-price
    /// unit away from a boundary.
    function liquidityForAmounts(
        uint160 price,
        uint160 lower,
        uint160 upper,
        uint256 amount0,
        uint256 amount1,
        uint128 cap
    ) internal pure returns (uint128) {
        if (cap == 0) return 0;
        (uint256 need0, uint256 need1) = amounts(price, lower, upper, cap, true);
        uint256 result = cap;
        if (amount0 < need0) {
            uint160 a = price > lower ? price : lower;
            // amount0 * a * upper / ((upper - a) * Q96), dividing by the small term first so that
            // no intermediate is floored to a handful of units at very low prices.
            uint256 l0 = FullMath.mulDiv(FullMath.mulDiv(amount0, a, uint256(upper) - a), upper, Q96);
            if (l0 < result) result = l0;
        }
        if (amount1 < need1) {
            uint256 l1 = FullMath.mulDiv(amount1, Q96, uint256(price < upper ? price : upper) - lower);
            if (l1 < result) result = l1;
        }
        return uint128(result);
    }
}

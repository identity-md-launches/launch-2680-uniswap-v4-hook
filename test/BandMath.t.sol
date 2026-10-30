// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BandMath} from "../src/libraries/BandMath.sol";
import {VaultMath} from "../src/libraries/VaultMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract BandMathTest is Test {
    function test_knownPopulationStatistics() public pure {
        int24[8] memory samples = [int24(-4), -3, -2, -1, 1, 2, 3, 4];
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        assertEq(sum, 0);
        assertEq(sigma8, 21); // floor(sqrt(64 * 60 / 8))
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        assertEq(mean, 0);
        assertEq(sigma, 2);
        samples = [int24(0), 0, 0, 0, 0, 0, 0, 800];
        (sum, sigma8) = BandMath.moments(samples);
        assertEq(sum, 800);
        assertEq(sigma8, 2116); // floor(sqrt(35_840_000 / 8)) = floor(8 * 264.575)
        (mean, sigma) = BandMath.statistics(samples);
        assertEq(mean, 100);
        assertEq(sigma, 264);
        (int24 lower, int24 upper) = BandMath.bands(sum, sigma8, 60, 30);
        assertEq(lower, -720); // floor((800 - 6348) / 8) = -694 -> -720
        assertEq(upper, 900); // ceil((800 + 6348) / 8) = 894 -> 900
    }

    function test_meanRoundsToNearestAndNegativeGridFloors() public pure {
        int24[8] memory samples = [int24(-1), -1, -1, -1, -1, -1, -1, 0];
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        assertEq(sum, -7);
        assertEq(sigma8, 2); // floor(sqrt(56 / 8))
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        assertEq(mean, -1); // -0.875 rounds to -1
        assertEq(sigma, 0);
        (int24 lower, int24 upper) = BandMath.bands(-61 * 8, 0, 60, 30);
        assertEq(lower, -120);
        assertEq(upper, -60);
    }

    /// Seven samples at one tick and one a tick nearer zero: the resting tick must not trigger and
    /// the outlier must, which a truncated mean with a floored sigma got backwards.
    function test_restingTickDoesNotDeviateButOutlierDoes() public pure {
        int24[8] memory samples = [int24(6), 6, 6, 6, 6, 6, 6, 5];
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        assertEq(sum, 47);
        assertEq(sigma8, 2); // floor(8 * 0.331)
        assertFalse(BandMath.deviates(6, sum, sigma8, 15)); // 0.125 < 0.496
        assertTrue(BandMath.deviates(5, sum, sigma8, 15)); // 0.875 > 0.496
        (int24 lower, int24 upper) = BandMath.bands(sum, sigma8, 60, 30);
        assertEq(lower, 0);
        assertEq(upper, 60);
        samples = [int24(-6), -6, -6, -6, -6, -6, -6, -5];
        (sum, sigma8) = BandMath.moments(samples);
        assertEq(sum, -47);
        assertFalse(BandMath.deviates(-6, sum, sigma8, 15));
        assertTrue(BandMath.deviates(-5, sum, sigma8, 15));
        (lower, upper) = BandMath.bands(sum, sigma8, 60, 30);
        assertEq(lower, -60);
        assertEq(upper, 0);
    }

    function test_strictTriggerAndHalfIntegerThreshold() public pure {
        // sigma8 = 16 is two whole ticks: the threshold is three ticks, exclusive.
        assertFalse(BandMath.deviates(3, 0, 16, 15));
        assertTrue(BandMath.deviates(4, 0, 16, 15));
        assertFalse(BandMath.deviates(-3, 0, 16, 15));
        assertTrue(BandMath.deviates(-4, 0, 16, 15));
        // sigma8 = 24 is three ticks: the threshold is four and a half ticks.
        assertFalse(BandMath.deviates(4, 0, 24, 15));
        assertTrue(BandMath.deviates(5, 0, 24, 15));
        assertFalse(BandMath.deviates(-4, 0, 24, 15));
        assertTrue(BandMath.deviates(-5, 0, 24, 15));
        assertFalse(BandMath.deviates(0, 0, 0, 15));
        assertTrue(BandMath.deviates(1, 0, 0, 15));
        // An eighth of a tick of sigma: half a tick's distance is 4 eighths, 1.5 sigma is 1.5 eighths.
        assertTrue(BandMath.deviates(1, 4, 1, 15));
        assertFalse(BandMath.deviates(0, 1, 1, 15));
    }

    function test_extremeTicksStayWithinUsableGrid() public pure {
        (int24 lower, int24 upper) = BandMath.bands(int256(TickMath.MIN_TICK) * 8, 0, 60, 30);
        assertEq(lower, -887220);
        assertEq(upper, -887160);
        (lower, upper) = BandMath.bands(int256(TickMath.MAX_TICK) * 8, 0, 60, 30);
        assertEq(lower, 887160);
        assertEq(upper, 887220);
        int24[8] memory samples = [int24(-887272), 887272, -887272, 887272, -887272, 887272, -887272, 887272];
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        assertEq(sum, 0);
        assertEq(sigma8, 8 * 887272);
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        assertEq(mean, 0);
        assertEq(sigma, 887272);
        (lower, upper) = BandMath.bands(sum, sigma8, 60, 30);
        assertEq(lower, -887220);
        assertEq(upper, 887220);
    }

    function testFuzz_statisticsMatchIndependentIntegerReference(int24[8] memory samples, uint16 spacingSeed)
        public
        pure
    {
        int256 sum;
        for (uint256 i; i < 8; ++i) {
            samples[i] = int24(bound(samples[i], TickMath.MIN_TICK, TickMath.MAX_TICK));
            sum += samples[i];
        }
        uint256 variance8;
        for (uint256 i; i < 8; ++i) {
            int256 residual = int256(samples[i]) * 8 - sum;
            variance8 += uint256(residual * residual);
        }
        variance8 /= 8;
        (int256 actualSum, uint256 sigma8) = BandMath.moments(samples);
        assertEq(actualSum, sum);
        assertLe(sigma8 * sigma8, variance8);
        assertGt((sigma8 + 1) * (sigma8 + 1), variance8);
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        // Nearest whole tick, half up: 8 * mean is within 4 eighths of the sum.
        assertLe(int256(mean) * 8 - sum, 4);
        assertLt(sum - int256(mean) * 8, 4);
        assertEq(sigma, sigma8 / 8);
        int24 spacing = int24(int256(bound(spacingSeed, 1, 32767)));
        (int24 lower, int24 upper) = BandMath.bands(sum, sigma8, spacing, 30);
        assertLt(lower, upper);
        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertGe(lower, TickMath.minUsableTick(spacing));
        assertLe(upper, TickMath.maxUsableTick(spacing));
        // The latest sample is one of the eight, so the band built from them brackets it, except
        // where the usable grid clips the band at the extremes.
        for (uint256 i; i < 8; ++i) {
            if (samples[i] >= TickMath.minUsableTick(spacing) && samples[i] <= TickMath.maxUsableTick(spacing)) {
                assertLe(lower, samples[i]);
                assertGe(upper, samples[i]);
            }
        }
    }

    function testFuzz_liquiditySizingNeverOverspends(
        int24 lowerSeed,
        int24 upperSeed,
        int24 currentSeed,
        uint128 budget0,
        uint128 budget1,
        uint128 cap
    ) public pure {
        int24 lower = int24(bound(lowerSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        int24 upper = int24(bound(upperSeed, lower + 1, TickMath.MAX_TICK));
        int24 current = int24(bound(currentSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        uint160 price = TickMath.getSqrtPriceAtTick(current);
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        uint128 l = VaultMath.liquidityForAmounts(price, lo, hi, budget0, budget1, cap);
        (uint256 need0, uint256 need1) = VaultMath.amounts(price, lo, hi, l, true);
        assertLe(l, cap);
        assertLe(need0, budget0);
        assertLe(need1, budget1);
    }

    function test_sizingOneSqrtUnitFromUpperAndVeryLowTicks() public pure {
        uint160 lo = TickMath.getSqrtPriceAtTick(887100);
        uint160 hi = TickMath.getSqrtPriceAtTick(887220);
        uint128 l = VaultMath.liquidityForAmounts(hi - 1, lo, hi, type(uint128).max, 1e27, 1e30);
        (uint256 a0, uint256 a1) = VaultMath.amounts(hi - 1, lo, hi, l, true);
        assertLe(a0, type(uint128).max);
        assertLe(a1, 1e27);
        lo = TickMath.getSqrtPriceAtTick(-887220);
        hi = TickMath.getSqrtPriceAtTick(-887100);
        l = VaultMath.liquidityForAmounts(lo, lo, hi, 1e27, 0, 1e30);
        assertGt(l, 0);
        (a0, a1) = VaultMath.amounts(lo, lo, hi, l, true);
        assertLe(a0, 1e27);
        assertEq(a1, 0);
    }

    /// At very low prices the old a*upper/Q96 intermediate was a handful of units, so sizing lost up
    /// to half the currency0 budget. The division-first form keeps at least 90% of the optimum.
    function test_lowPriceSizingKeepsPrecision() public pure {
        uint160 price = TickMath.getSqrtPriceAtTick(-658620);
        uint160 lo = TickMath.getSqrtPriceAtTick(-658680);
        uint160 hi = TickMath.getSqrtPriceAtTick(-658560);
        uint128 l = VaultMath.liquidityForAmounts(price, lo, hi, 1000e18, 1, type(uint128).max);
        assertGe(l, 1502303472);
        (uint256 a0, uint256 a1) = VaultMath.amounts(price, lo, hi, l, true);
        assertLe(a0, 1000e18);
        assertLe(a1, 1);
        // Nearly all of the budget is used: the idle remainder is below a tenth of a percent.
        assertGt(a0, 999e18);
    }

    function test_rebalanceTradeTargetsBandRatioAndRespectsDeadband() public pure {
        uint160 price = TickMath.getSqrtPriceAtTick(0);
        uint160 lo = TickMath.getSqrtPriceAtTick(-600);
        uint160 hi = TickMath.getSqrtPriceAtTick(600);
        // A symmetric band at its centre wants equal value on both sides.
        (bool zeroForOne, uint256 amountIn) = VaultMath.rebalanceTrade(price, lo, hi, 0, 100e18, 100);
        assertFalse(zeroForOne);
        assertApproxEqRel(amountIn, 50e18, 1e15);
        (zeroForOne, amountIn) = VaultMath.rebalanceTrade(price, lo, hi, 100e18, 0, 100);
        assertTrue(zeroForOne);
        assertApproxEqRel(amountIn, 50e18, 1e15);
        // Balanced inventory, or an imbalance under the deadband, trades nothing.
        (, amountIn) = VaultMath.rebalanceTrade(price, lo, hi, 100e18, 100e18, 100);
        assertEq(amountIn, 0);
        (, amountIn) = VaultMath.rebalanceTrade(price, lo, hi, 100e18, 101e18, 100);
        assertEq(amountIn, 0);
        (, amountIn) = VaultMath.rebalanceTrade(price, lo, hi, 100e18, 101e18, 0);
        assertGt(amountIn, 0);
        // Price at or beyond an edge wants a single currency.
        (zeroForOne, amountIn) = VaultMath.rebalanceTrade(hi, lo, hi, 100e18, 100e18, 100);
        assertTrue(zeroForOne);
        assertApproxEqAbs(amountIn, 100e18, 10);
        (zeroForOne, amountIn) = VaultMath.rebalanceTrade(lo, lo, hi, 100e18, 100e18, 100);
        assertFalse(zeroForOne);
        assertApproxEqAbs(amountIn, 100e18, 10);
        (, amountIn) = VaultMath.rebalanceTrade(price, lo, hi, 0, 0, 100);
        assertEq(amountIn, 0);
    }

    function test_tradeLimitStopsAtBandEdgeOrCap() public pure {
        assertEq(VaultMath.tradeLimit(true, 2000, -1740, 2280, 300), TickMath.getSqrtPriceAtTick(1700));
        assertEq(VaultMath.tradeLimit(false, 2000, -1740, 2280, 300), TickMath.getSqrtPriceAtTick(2280));
        assertEq(VaultMath.tradeLimit(true, 20, -60, 60, 300), TickMath.getSqrtPriceAtTick(-60));
        assertEq(VaultMath.tradeLimit(false, 20, -60, 60, 300), TickMath.getSqrtPriceAtTick(60));
        assertEq(VaultMath.tradeLimit(true, -887100, -887220, -887160, 300), TickMath.getSqrtPriceAtTick(-887220));
        assertEq(VaultMath.tradeLimit(true, -887100, TickMath.MIN_TICK, -887160, 300), TickMath.MIN_SQRT_PRICE + 1);
        assertEq(VaultMath.tradeLimit(false, 887271, 887160, 887220, 300), TickMath.getSqrtPriceAtTick(887220));
        assertEq(VaultMath.tradeLimit(false, 887271, 887160, TickMath.MAX_TICK, 300), TickMath.MAX_SQRT_PRICE - 1);
    }
}

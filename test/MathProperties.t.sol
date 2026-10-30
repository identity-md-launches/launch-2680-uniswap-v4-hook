// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BandMath} from "src/libraries/BandMath.sol";
import {VaultMath} from "src/libraries/VaultMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract MathPropertiesTest is Test {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_momentsIgnoreOrderAndReflectAboutZero(int24[8] memory samples, uint8 rotation) public pure {
        int24[8] memory permuted;
        int24[8] memory reflected;
        for (uint256 i; i < 8; ++i) {
            samples[i] = int24(bound(samples[i], TickMath.MIN_TICK, TickMath.MAX_TICK));
        }
        int256 expectedSum;
        for (uint256 i; i < 8; ++i) {
            permuted[i] = samples[(i + uint256(rotation)) % 8];
            reflected[i] = -samples[i];
            expectedSum += samples[i];
        }
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        (int256 permutedSum, uint256 permutedSigma8) = BandMath.moments(permuted);
        (int256 reflectedSum, uint256 reflectedSigma8) = BandMath.moments(reflected);
        assertEq(sum, expectedSum);
        assertEq(permutedSum, sum);
        assertEq(permutedSigma8, sigma8);
        assertEq(reflectedSum, -sum);
        assertEq(reflectedSigma8, sigma8);
        // The whole-tick view is the rounded moments, so it is also order independent.
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        (int24 permutedMean, uint256 permutedSigma) = BandMath.statistics(permuted);
        assertEq(permutedMean, mean);
        assertEq(permutedSigma, sigma);
        assertEq(sigma, sigma8 / 8);
        // Nearest whole tick, halves up: |8 * mean - sum| <= 4 and a tie resolves upwards.
        int256 error = int256(mean) * 8 - sum;
        assertLe(error, 4);
        assertGt(error, -4);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_symmetricTwoPointDistributionHasKnownPopulationSigma(int24 centerSeed, uint24 widthSeed)
        public
        pure
    {
        int24 center = int24(bound(centerSeed, -400_000, 400_000));
        int24 width = int24(int256(bound(widthSeed, 0, 400_000)));
        int24[8] memory samples;
        for (uint256 i; i < 8; ++i) {
            samples[i] = i % 2 == 0 ? center - width : center + width;
        }
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        assertEq(sum, int256(center) * 8);
        assertEq(sigma8, uint256(uint24(width)) * 8, "population sigma of equal +/-d samples is d");
        (int24 mean, uint256 sigma) = BandMath.statistics(samples);
        assertEq(mean, center);
        assertEq(sigma, uint24(width));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_bandsEncloseThreeSigmaOnTheSmallestUsableGrid(int256 sumSeed, uint256 sigmaSeed) public pure {
        int24 spacing = 60;
        int256 minTick = TickMath.minUsableTick(spacing);
        int256 maxTick = TickMath.maxUsableTick(spacing);
        int256 sum = bound(sumSeed, (minTick + spacing) * 8, (maxTick - spacing) * 8);
        uint256 sigma8 = bound(sigmaSeed, 0, 887272 * 8);
        (int24 lower, int24 upper) = BandMath.bands(sum, sigma8, spacing, 30);
        // Exact band edges in eighths of a tick: 8 * (mean -/+ 3 sigma).
        int256 rawLower8 = sum - int256(3 * sigma8);
        int256 rawUpper8 = sum + int256(3 * sigma8);
        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertLt(lower, upper);
        assertLe(int256(lower) * 8, sum);
        assertGe(int256(upper) * 8, sum);
        if (sigma8 == 0 && sum % (8 * spacing) == 0) {
            assertEq(int256(lower) * 8, sum - 8 * spacing);
            assertEq(int256(upper) * 8, sum + 8 * spacing);
        } else {
            if (rawLower8 < minTick * 8) {
                assertEq(lower, minTick);
            } else {
                assertLe(int256(lower) * 8, rawLower8);
                assertGt((int256(lower) + spacing) * 8, rawLower8, "lower band unnecessarily wide");
            }
            if (rawUpper8 > maxTick * 8) {
                assertEq(upper, maxTick);
            } else {
                assertGe(int256(upper) * 8, rawUpper8);
                assertLt((int256(upper) - spacing) * 8, rawUpper8, "upper band unnecessarily wide");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_triggerIsStrictAtBothSidesOfOneAndAHalfSigma(uint24 sigmaSeed, int24 meanSeed) public pure {
        // A whole-tick mean and sigma: sum = 8 * mean, sigma8 = 8 * sigma.
        uint256 sigma = bound(sigmaSeed, 0, 200_000);
        int24 mean = int24(bound(meanSeed, -400_000, 400_000));
        int256 sum = int256(mean) * 8;
        uint256 sigma8 = sigma * 8;
        int24 atOrBelow = int24(int256(3 * sigma / 2));
        int24 above = atOrBelow + 1;
        assertFalse(BandMath.deviates(mean + atOrBelow, sum, sigma8, 15));
        assertFalse(BandMath.deviates(mean - atOrBelow, sum, sigma8, 15));
        assertTrue(BandMath.deviates(mean + above, sum, sigma8, 15));
        assertTrue(BandMath.deviates(mean - above, sum, sigma8, 15));
    }

    function test_triggerUsesTheUnroundedMean() public pure {
        // Samples 0,0,0,0,0,0,0,3: mean 0.375, sigma8 = floor(sqrt(Σ(8t - 3)^2 / 8)) = floor(sqrt(63)) = 7.
        int24[8] memory samples;
        samples[7] = 3;
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        assertEq(sum, 3);
        assertEq(sigma8, 7);
        // |8 * 2 - 3| = 13, 2 * 13 = 26 > 21: tick 2 deviates; |8 * (-1) - 3| = 11, 22 > 21 deviates;
        // tick 1: |8 - 3| = 5, 10 <= 21 does not; tick 0: 3, 6 <= 21 does not.
        assertTrue(BandMath.deviates(2, sum, sigma8, 15));
        assertTrue(BandMath.deviates(-1, sum, sigma8, 15));
        assertFalse(BandMath.deviates(1, sum, sigma8, 15));
        assertFalse(BandMath.deviates(0, sum, sigma8, 15));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_principalRoundingAndPriceMonotonicity(
        int24 lowerSeed,
        int24 upperSeed,
        int24 priceSeed,
        int24 laterSeed,
        uint128 liquidity
    ) public pure {
        int24 lowerTick = int24(bound(lowerSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        int24 upperTick = int24(bound(upperSeed, lowerTick + 1, TickMath.MAX_TICK));
        int24 priceTick = int24(bound(priceSeed, TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 laterTick = int24(bound(laterSeed, priceTick, TickMath.MAX_TICK));
        uint160 lower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 upper = TickMath.getSqrtPriceAtTick(upperTick);
        uint160 price = TickMath.getSqrtPriceAtTick(priceTick);
        (uint256 down0, uint256 down1) = VaultMath.amounts(price, lower, upper, liquidity, false);
        (uint256 up0, uint256 up1) = VaultMath.amounts(price, lower, upper, liquidity, true);
        assertLe(down0, up0);
        assertLe(down1, up1);
        assertLe(up0 - down0, 1, "principal0 rounding exceeded one base unit");
        assertLe(up1 - down1, 1, "principal1 rounding exceeded one base unit");
        (uint256 later0, uint256 later1) =
            VaultMath.amounts(TickMath.getSqrtPriceAtTick(laterTick), lower, upper, liquidity, false);
        assertLe(later0, down0, "higher price increased token0 principal");
        assertGe(later1, down1, "higher price reduced token1 principal");
        if (priceTick <= lowerTick) assertEq(up1, 0);
        if (priceTick >= upperTick) assertEq(up0, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_largerBudgetsNeverReduceLiquidity(
        int24 lowerSeed,
        int24 upperSeed,
        int24 priceSeed,
        uint128 budget0,
        uint128 budget1,
        uint128 cap
    ) public pure {
        int24 lowerTick = int24(bound(lowerSeed, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        int24 upperTick = int24(bound(upperSeed, lowerTick + 1, TickMath.MAX_TICK));
        int24 priceTick = int24(bound(priceSeed, TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint160 lower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 upper = TickMath.getSqrtPriceAtTick(upperTick);
        uint160 price = TickMath.getSqrtPriceAtTick(priceTick);
        uint128 original = VaultMath.liquidityForAmounts(price, lower, upper, budget0, budget1, cap);
        uint128 increased =
            VaultMath.liquidityForAmounts(price, lower, upper, uint256(budget0) * 2 + 1, uint256(budget1) * 2 + 1, cap);
        assertGe(increased, original);
        assertLe(increased, cap);
    }

    function test_zeroLiquidityZeroBudgetsAndZeroCapacity() public pure {
        uint160 lower = TickMath.getSqrtPriceAtTick(-60);
        uint160 upper = TickMath.getSqrtPriceAtTick(60);
        (uint256 amount0, uint256 amount1) = VaultMath.amounts(1 << 96, lower, upper, 0, true);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(VaultMath.liquidityForAmounts(1 << 96, lower, upper, 0, 0, type(uint128).max), 0);
        assertEq(VaultMath.liquidityForAmounts(1 << 96, lower, upper, 1 ether, 1 ether, 0), 0);
    }

    function test_oneWeiFundsOnlyAffordableLiquidityAtExactBandBoundaries() public pure {
        uint160 lower = TickMath.getSqrtPriceAtTick(-60);
        uint160 upper = TickMath.getSqrtPriceAtTick(60);
        uint128 atLower = VaultMath.liquidityForAmounts(lower, lower, upper, 1, 0, type(uint128).max);
        uint128 atUpper = VaultMath.liquidityForAmounts(upper, lower, upper, 0, 1, type(uint128).max);
        assertGt(atLower, 0);
        assertGt(atUpper, 0);
        (uint256 a0, uint256 a1) = VaultMath.amounts(lower, lower, upper, atLower, true);
        assertEq(a0, 1);
        assertEq(a1, 0);
        (a0, a1) = VaultMath.amounts(upper, lower, upper, atUpper, true);
        assertEq(a0, 0);
        assertEq(a1, 1);
    }
}

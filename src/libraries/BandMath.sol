// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Population statistics over eight execution ticks, kept in eighths of a tick so that no
/// rounding of the mean leaks into the trigger or the band.
/// @dev `sum` is exactly 8 × mean. `sigma8` is floor(sqrt(Σ(8·tick − sum)² / 8)) = floor(8 × sigma).
library BandMath {
    int256 internal constant SAMPLES = 8;

    function moments(int24[8] memory ticks) internal pure returns (int256 sum, uint256 sigma8) {
        for (uint256 i; i < 8; ++i) {
            sum += ticks[i];
        }
        uint256 squared = 0;
        for (uint256 i; i < 8; ++i) {
            int256 residual = int256(ticks[i]) * SAMPLES - sum;
            squared += uint256(residual * residual);
        }
        sigma8 = Math.sqrt(squared / 8);
    }

    /// @notice Whole-tick view of the moments: mean rounded to nearest (half up), sigma floored.
    function rounded(int256 sum, uint256 sigma8) internal pure returns (int24 mean, uint256 sigma) {
        mean = int24(floorDiv(sum + SAMPLES / 2, SAMPLES));
        sigma = sigma8 / 8;
    }

    function statistics(int24[8] memory ticks) internal pure returns (int24 mean, uint256 sigma) {
        (int256 sum, uint256 sigma8) = moments(ticks);
        return rounded(sum, sigma8);
    }

    /// @dev |tick − mean| > (triggerSigma / 10) sigma, evaluated as 10·|8·tick − sum| > triggerSigma·sigma8
    /// without rounding the mean. `triggerSigma` is in tenths of a sigma (15 = 1.5σ).
    function deviates(int24 tick, int256 sum, uint256 sigma8, uint256 triggerSigma) internal pure returns (bool) {
        int256 distance = int256(tick) * SAMPLES - sum;
        uint256 absolute = uint256(distance < 0 ? -distance : distance);
        return 10 * absolute > triggerSigma * sigma8;
    }

    /// @dev lower = floor_to_spacing(mean − r sigma), upper = ceil_to_spacing(mean + r sigma), where
    /// r = rangeSigma / 10 (30 = 3.0σ). The width is floored to whole eighths of a tick.
    function bands(int256 sum, uint256 sigma8, int24 spacing, uint256 rangeSigma)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        int256 width = int256(int256(rangeSigma * sigma8 / 10));
        int256 lo = floor(floorDiv(sum - width, SAMPLES), spacing);
        int256 hi = -floor(floorDiv(-(sum + width), SAMPLES), spacing);
        // A zero-volatility feed still needs a non-empty position.
        if (lo == hi) {
            lo -= spacing;
            hi += spacing;
        }
        int256 minTick = TickMath.minUsableTick(spacing);
        int256 maxTick = TickMath.maxUsableTick(spacing);
        if (lo < minTick) lo = minTick;
        if (hi > maxTick) hi = maxTick;
        if (lo >= hi) {
            if (lo >= maxTick) lo = maxTick - spacing;
            else hi = minTick + spacing;
        }
        lower = int24(lo);
        upper = int24(hi);
    }

    /// @dev Round down to a multiple of `spacing`, towards negative infinity.
    function floor(int256 tick, int24 spacing) internal pure returns (int256 result) {
        result = floorDiv(tick, spacing) * spacing;
    }

    /// @dev Signed division rounding towards negative infinity; `divisor` must be positive.
    function floorDiv(int256 value, int256 divisor) internal pure returns (int256 result) {
        result = value / divisor;
        if (value < 0 && value % divisor != 0) --result;
    }
}

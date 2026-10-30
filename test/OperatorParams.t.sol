// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {SigmaHook} from "src/SigmaHook.sol";
import {BandMath} from "src/libraries/BandMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Owner-set rebalance parameters: defaults, presets, bounds, access control and their effect
/// on the keeper gates and on the band the hook deploys into.
contract OperatorParamsTest is Fixture {
    using StateLibrary for IPoolManager;

    uint8 constant SLEEP = 0;
    uint8 constant STANDARD = 1;
    uint8 constant AGGRESSIVE = 2;
    uint8 constant MAX = 3;
    uint8 constant DEFENSIVE = 4;
    uint8 constant PAUSED = 5;

    event ModeChanged(uint8 mode);

    function setUp() public {
        _setup(false);
    }

    // ---------------------------------------------------------------- defaults and presets

    function test_defaultsMatchTheSprintOneBehaviour() public view {
        assertEq(hook.triggerSigma(), 15);
        assertEq(hook.rangeSigma(), 30);
        assertEq(hook.cooldown(), 1800);
        // The launch band is built with the default range sigma over a zero-sigma feed.
        assertEq(hook.tickLower(), -60);
        assertEq(hook.tickUpper(), 60);
    }

    function test_presetTableIsExactlyAsOrdered() public view {
        _assertPreset(SLEEP, 30, 30, 3600);
        _assertPreset(STANDARD, 15, 20, 1800);
        _assertPreset(AGGRESSIVE, 10, 15, 900);
        _assertPreset(MAX, 5, 10, 300);
        _assertPreset(DEFENSIVE, 30, 40, 7200);
        _assertPreset(PAUSED, 255, 255, type(uint32).max);
    }

    function test_setModeLoadsEveryPresetAndEmits() public {
        for (uint8 m; m < 6; ++m) {
            (uint8 trigger, uint8 range, uint32 cool) = hook.presets(m);
            vm.expectEmit(true, true, true, true, address(hook));
            emit ModeChanged(m);
            vm.prank(owner);
            hook.setMode(m);
            assertEq(hook.triggerSigma(), trigger);
            assertEq(hook.rangeSigma(), range);
            assertEq(hook.cooldown(), cool);
        }
    }

    function test_setModeRejectsUnknownModeAndNonOwner() public {
        vm.prank(owner);
        vm.expectRevert(bytes("invalid mode"));
        hook.setMode(6);
        vm.prank(owner);
        vm.expectRevert(bytes("invalid mode"));
        hook.setMode(255);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setMode(STANDARD);
        // The deploying factory (this test contract) is not the owner either.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setMode(STANDARD);
        assertEq(hook.triggerSigma(), 15);
        assertEq(hook.rangeSigma(), 30);
        assertEq(hook.cooldown(), 1800);
    }

    // ---------------------------------------------------------------- individual setters

    function test_setTriggerSigmaBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("bounds"));
        hook.setTriggerSigma(4);
        vm.expectRevert(bytes("bounds"));
        hook.setTriggerSigma(51);
        vm.expectRevert(bytes("bounds"));
        hook.setTriggerSigma(0);
        vm.expectRevert(bytes("bounds"));
        hook.setTriggerSigma(255);
        hook.setTriggerSigma(5);
        assertEq(hook.triggerSigma(), 5);
        hook.setTriggerSigma(50);
        assertEq(hook.triggerSigma(), 50);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        hook.setTriggerSigma(20);
        assertEq(hook.triggerSigma(), 50);
    }

    function test_setRangeSigmaBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("bounds"));
        hook.setRangeSigma(9);
        vm.expectRevert(bytes("bounds"));
        hook.setRangeSigma(51);
        vm.expectRevert(bytes("bounds"));
        hook.setRangeSigma(0);
        hook.setRangeSigma(10);
        assertEq(hook.rangeSigma(), 10);
        hook.setRangeSigma(50);
        assertEq(hook.rangeSigma(), 50);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        hook.setRangeSigma(20);
        assertEq(hook.rangeSigma(), 50);
    }

    function test_setCooldownBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("bounds"));
        hook.setCooldown(299);
        vm.expectRevert(bytes("bounds"));
        hook.setCooldown(86401);
        vm.expectRevert(bytes("bounds"));
        hook.setCooldown(0);
        vm.expectRevert(bytes("bounds"));
        hook.setCooldown(type(uint32).max);
        hook.setCooldown(300);
        assertEq(hook.cooldown(), 300);
        hook.setCooldown(86400);
        assertEq(hook.cooldown(), 86400);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        hook.setCooldown(1800);
        assertEq(hook.cooldown(), 86400);
    }

    function test_pauseAndResumeTouchOnlyTheTrigger() public {
        vm.startPrank(owner);
        hook.setMode(MAX); // trigger 5, range 10, cooldown 300
        hook.pause();
        assertEq(hook.triggerSigma(), 255);
        assertEq(hook.rangeSigma(), 10);
        assertEq(hook.cooldown(), 300);
        hook.resume();
        assertEq(hook.triggerSigma(), 15, "resume restores the STANDARD trigger");
        assertEq(hook.rangeSigma(), 10, "resume leaves the range alone");
        assertEq(hook.cooldown(), 300, "resume leaves the cooldown alone");
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.resume();
    }

    // ---------------------------------------------------------------- effect on the keeper gates

    function test_cooldownGateUsesTheLiveSetting() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.prank(owner);
        hook.setCooldown(300);
        uint256 start = hook.lastRebalance();
        _moveTo(2000);
        vm.warp(start + 299);
        vm.expectRevert(SigmaHook.RebalanceTooSoon.selector);
        hook.flashRebalance(key);
        vm.warp(start + 300);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), start + 300);
        _assertPositionMatches();
        // Lengthening the cooldown afterwards applies to the next cycle from the last rebalance.
        vm.prank(owner);
        hook.setCooldown(86400);
        _moveTo(-2000);
        vm.warp(start + 300 + 1800);
        vm.expectRevert(SigmaHook.RebalanceTooSoon.selector);
        hook.flashRebalance(key);
        vm.warp(start + 300 + 86400);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
    }

    function test_pausedPresetCooldownNeverElapses() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.prank(owner);
        hook.setMode(PAUSED);
        _moveTo(2000);
        // type(uint32).max seconds is about 136 years; a century later the gate still holds.
        // Absolute warps: the IR optimizer may merge two identical block.timestamp reads.
        uint256 start = hook.lastRebalance();
        vm.warp(start + 100 * 365 days);
        vm.expectRevert(SigmaHook.RebalanceTooSoon.selector);
        hook.flashRebalance(key);
        // And even past that horizon the paused trigger (25.5 sigma) refuses the rebalance.
        vm.warp(start + 200 * 365 days);
        assertGt(block.timestamp, start + type(uint32).max);
        vm.expectRevert(SigmaHook.WithinThreshold.selector);
        hook.flashRebalance(key);
    }

    /// One swap after a flat feed is a 2.65-sigma outlier: STANDARD (1.5σ) fires, SLEEP (3.0σ) and
    /// the paused trigger (25.5σ) do not, and resume() makes it fire again.
    function test_triggerGateUsesTheLiveSettingAndPauseResume() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.warp(hook.lastRebalance() + 1 hours);
        _moveTo(2000);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        (int256 sum, uint256 sigma8) = hook.moments();
        assertTrue(BandMath.deviates(tick, sum, sigma8, 15));
        assertFalse(BandMath.deviates(tick, sum, sigma8, 30));

        vm.prank(owner);
        hook.setMode(SLEEP);
        vm.expectRevert(SigmaHook.WithinThreshold.selector);
        hook.flashRebalance(key);

        vm.prank(owner);
        hook.pause();
        vm.expectRevert(SigmaHook.WithinThreshold.selector);
        hook.flashRebalance(key);

        vm.prank(owner);
        hook.resume();
        uint256 when = block.timestamp;
        vm.prank(bob);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), when);
        _assertPositionMatches();
    }

    /// Three samples at the new tick and five at the old one put the tick 1.29 sigma from the mean:
    /// STANDARD (1.5σ) refuses, AGGRESSIVE (1.0σ) fires. Four and four is exactly 1.0 sigma, which
    /// the strict comparison refuses for AGGRESSIVE and accepts for MAX (0.5σ).
    function test_tighterTriggerFiresWhereStandardDoesNot() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.warp(hook.lastRebalance() + 1 hours);
        _moveTo(2000);
        _resample();
        _resample();
        assertEq(hook.nextSample(), 3);
        vm.expectRevert(SigmaHook.WithinThreshold.selector);
        hook.flashRebalance(key);

        vm.prank(owner);
        hook.setTriggerSigma(10);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        (int256 sum, uint256 sigma8) = hook.moments();
        assertTrue(BandMath.deviates(tick, sum, sigma8, 10));
        assertFalse(BandMath.deviates(tick, sum, sigma8, 15));

        _resample();
        (sum, sigma8) = hook.moments();
        assertFalse(BandMath.deviates(tick, sum, sigma8, 10), "exactly one sigma is not strictly beyond it");
        vm.expectRevert(SigmaHook.WithinThreshold.selector);
        hook.flashRebalance(key);

        vm.prank(owner);
        hook.setMode(MAX);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
        _assertPositionMatches();
    }

    // ---------------------------------------------------------------- effect on the band

    function test_rangeSigmaShapesProposedAndDeployedBands() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.warp(hook.lastRebalance() + 1 hours);
        _moveTo(2000);
        (int256 sum, uint256 sigma8) = hook.moments();
        assertGt(sigma8, 0);

        (int24 lower30, int24 upper30) = hook.proposedBands();
        (int24 expectedLower, int24 expectedUpper) = BandMath.bands(sum, sigma8, 60, 30);
        assertEq(lower30, expectedLower);
        assertEq(upper30, expectedUpper);

        vm.prank(owner);
        hook.setRangeSigma(10);
        (int24 lower10, int24 upper10) = hook.proposedBands();
        (expectedLower, expectedUpper) = BandMath.bands(sum, sigma8, 60, 10);
        assertEq(lower10, expectedLower);
        assertEq(upper10, expectedUpper);
        assertGt(lower10, lower30, "a smaller range sigma narrows the band from below");
        assertLt(upper10, upper30, "a smaller range sigma narrows the band from above");

        hook.flashRebalance(key);
        assertEq(hook.tickLower(), lower10);
        assertEq(hook.tickUpper(), upper10);
        _assertPositionMatches();

        vm.prank(owner);
        hook.setRangeSigma(50);
        (int24 lower50, int24 upper50) = hook.proposedBands();
        (sum, sigma8) = hook.moments();
        (expectedLower, expectedUpper) = BandMath.bands(sum, sigma8, 60, 50);
        assertEq(lower50, expectedLower);
        assertEq(upper50, expectedUpper);
        assertLt(lower50, lower10);
        assertGt(upper50, upper10);
    }

    function test_firstDepositUsesTheLiveRangeSigma() public {
        _seedBackground();
        // Build a feed with volatility before anyone has deposited, then widen the range.
        _moveTo(600);
        _moveTo(-600);
        vm.prank(owner);
        hook.setMode(DEFENSIVE); // range 4.0σ
        (int256 sum, uint256 sigma8) = hook.moments();
        (int24 expectedLower, int24 expectedUpper) = BandMath.bands(sum, sigma8, 60, 40);
        _deposit(alice, 10 ether, 10 ether);
        assertEq(hook.tickLower(), expectedLower);
        assertEq(hook.tickUpper(), expectedUpper);
        (int24 narrowLower, int24 narrowUpper) = BandMath.bands(sum, sigma8, 60, 30);
        assertTrue(expectedLower < narrowLower || expectedUpper > narrowUpper, "4.0 sigma is wider than 3.0");
        _assertPositionMatches();
    }

    // ---------------------------------------------------------------- library properties

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_triggerIsStrictAtBothSidesForAnyTenthsSetting(uint24 sigmaSeed, int24 meanSeed, uint8 triggerSeed)
        public
        pure
    {
        uint256 sigma = bound(sigmaSeed, 0, 90_000);
        int24 mean = int24(bound(meanSeed, -400_000, 400_000));
        uint256 trigger = bound(triggerSeed, 5, 50);
        int256 sum = int256(mean) * 8;
        uint256 sigma8 = sigma * 8;
        int24 atOrBelow = int24(int256(trigger * sigma / 10));
        int24 above = atOrBelow + 1;
        assertFalse(BandMath.deviates(mean + atOrBelow, sum, sigma8, trigger));
        assertFalse(BandMath.deviates(mean - atOrBelow, sum, sigma8, trigger));
        assertTrue(BandMath.deviates(mean + above, sum, sigma8, trigger));
        assertTrue(BandMath.deviates(mean - above, sum, sigma8, trigger));
    }

    function test_pausedTriggerIsBeyondAnyEightSampleDeviation() public pure {
        // The most extreme eight-sample feed: seven at one tick, one at another, the current tick
        // being the outlier. Its distance is sqrt(7) ~ 2.65 sigma, far below 25.5 sigma.
        int24[8] memory samples = [int24(0), 0, 0, 0, 0, 0, 0, 500_000];
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        assertFalse(BandMath.deviates(500_000, sum, sigma8, 255));
        assertTrue(BandMath.deviates(500_000, sum, sigma8, 15));
        samples = [int24(0), 0, 0, 0, 0, 0, 0, -500_000];
        (sum, sigma8) = BandMath.moments(samples);
        assertFalse(BandMath.deviates(-500_000, sum, sigma8, 255));
        // Only a zero-sigma feed with the tick off every sample would pass a 25.5 sigma trigger,
        // which the sampling callback cannot produce: every swap records the tick it leaves behind.
        assertTrue(BandMath.deviates(1, 0, 0, 255));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_bandsEncloseRangeSigmaOnTheSmallestUsableGrid(int256 sumSeed, uint256 sigmaSeed, uint8 rangeSeed)
        public
        pure
    {
        int24 spacing = 60;
        int256 minTick = TickMath.minUsableTick(spacing);
        int256 maxTick = TickMath.maxUsableTick(spacing);
        int256 sum = bound(sumSeed, (minTick + spacing) * 8, (maxTick - spacing) * 8);
        uint256 sigma8 = bound(sigmaSeed, 0, 887272 * 8);
        uint256 range = bound(rangeSeed, 10, 50);
        (int24 lower, int24 upper) = BandMath.bands(sum, sigma8, spacing, range);
        int256 width8 = int256(range * sigma8 / 10);
        int256 rawLower8 = sum - width8;
        int256 rawUpper8 = sum + width8;
        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertLt(lower, upper);
        assertLe(int256(lower) * 8, sum);
        assertGe(int256(upper) * 8, sum);
        if (width8 == 0 && sum % (8 * spacing) == 0) {
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

    function test_bandsWidenMonotonicallyWithRangeSigma() public pure {
        int24[8] memory samples = [int24(0), 0, 0, 0, 0, 0, 0, 800];
        (int256 sum, uint256 sigma8) = BandMath.moments(samples);
        int24 previousLower = type(int24).max;
        int24 previousUpper = type(int24).min;
        for (uint256 range = 10; range <= 50; range += 5) {
            (int24 lower, int24 upper) = BandMath.bands(sum, sigma8, 60, range);
            assertLe(lower, previousLower);
            assertGe(upper, previousUpper);
            previousLower = lower;
            previousUpper = upper;
        }
        // 3.0 sigma reproduces the Sprint 1 band exactly.
        (int24 lower30, int24 upper30) = BandMath.bands(sum, sigma8, 60, 30);
        assertEq(lower30, -720);
        assertEq(upper30, 900);
        // 1.0 sigma: floor((800 - 2116) / 8) = -165 -> -180; ceil((800 + 2116) / 8) = 365 -> 420.
        (int24 lower10, int24 upper10) = BandMath.bands(sum, sigma8, 60, 10);
        assertEq(lower10, -180);
        assertEq(upper10, 420);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Records the current tick again: a one-wei exact-input swap is consumed entirely by the
    /// LP fee and leaves slot0 where it is, so the callback samples the same tick once more.
    function _resample() internal {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        router.swap(key, false, -1, TickMath.getSqrtPriceAtTick(tick + 1));
        (, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertEq(tickAfter, tick, "resample moved the tick");
    }

    function _assertPreset(uint8 mode, uint8 trigger, uint8 range, uint32 cool) internal view {
        (uint8 t, uint8 r, uint32 c) = hook.presets(mode);
        assertEq(t, trigger);
        assertEq(r, range);
        assertEq(c, cool);
    }
}

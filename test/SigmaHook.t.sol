// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {SigmaHook} from "../src/SigmaHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {VaultMath} from "../src/libraries/VaultMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SigmaHookTest is Fixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function setUp() public {
        _setup(false);
    }

    function test_minedPermissionsInitializationAndExplicitOwner() public view {
        assertEq(HookFlags.flagsOf(address(hook)), 0x1040);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.afterSwap);
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(hook.owner(), owner);
        assertTrue(hook.owner() != address(this));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.launchToken(), address(token));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        for (uint256 i; i < 8; ++i) {
            assertEq(hook.ticks(i), 0);
        }
        assertEq(hook.nextSample(), 0);
        (int24 mean, uint256 sigma) = hook.statistics();
        assertEq(mean, 0);
        assertEq(sigma, 0);
        assertEq(hook.tickLower(), -60);
        assertEq(hook.tickUpper(), 60);
        assertEq(hook.totalSupply(), 0);
        assertLe(address(hook).code.length, 24_576);
    }

    function test_callbacksAndUnlockRefuseUnauthorizedCalls() public {
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.afterInitialize(address(this), key, 1 << 96, 0);
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.afterSwap(address(this), key, SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.unlockCallback(abi.encode(uint8(3), 0, 0));
        vm.prank(address(manager));
        vm.expectRevert(SigmaHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(uint8(3), 0, 0));
    }

    function test_rejectsSecondPoolAndWrongCallbackPool() public {
        PoolKey memory another = key;
        another.fee = 3_000;
        vm.expectRevert();
        manager.initialize(another, 1 << 96);
        vm.prank(address(manager));
        vm.expectRevert(SigmaHook.InvalidPool.selector);
        hook.afterSwap(address(this), another, SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
        assertEq(hook.nextSample(), 0);
    }

    function test_uninitializedFunctionsAndFactoryGate() public {
        SigmaHook unbound = _deployHook(address(token));
        vm.expectRevert(SigmaHook.NotInitialized.selector);
        unbound.deposit(1, 1, 1, alice, block.timestamp);
        vm.expectRevert(SigmaHook.NotInitialized.selector);
        unbound.totalAssets();
        PoolKey memory newKey = key;
        newKey.hooks = IHooks(address(unbound));
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(newKey, 1 << 96);
        assertFalse(unbound.initialized());
        newKey.fee = 3_000;
        vm.expectRevert();
        manager.initialize(newKey, 1 << 96);
        newKey.fee = 12_500;
        manager.initialize(newKey, TickMath.getSqrtPriceAtTick(-123));
        for (uint256 i; i < 8; ++i) {
            assertEq(unbound.ticks(i), -123);
        }
        assertEq(unbound.tickLower(), -180);
        assertEq(unbound.tickUpper(), -120);
    }

    function test_firstDepositAndProportionalSecondDeposit() public {
        uint256 first = _deposit(alice, 10 ether, 10 ether);
        assertEq(hook.balanceOf(alice), first);
        assertEq(hook.balanceOf(address(hook)), 1_000);
        assertEq(hook.totalSupply(), first + 1_000);
        assertGt(hook.liquidity(), 0);
        _assertPositionMatches();
        (uint256 a0, uint256 a1) = hook.totalAssets();
        assertApproxEqAbs(a0, 10 ether, 1);
        assertApproxEqAbs(a1, 10 ether, 1);

        (uint256 quote, uint256 used0, uint256 used1) = hook.previewDeposit(20 ether, 5 ether);
        uint256 b0 = _balance(key.currency0, bob);
        uint256 b1 = _balance(key.currency1, bob);
        uint256 second = _deposit(bob, 20 ether, 5 ether);
        assertEq(second, quote);
        assertEq(b0 - _balance(key.currency0, bob), used0);
        assertEq(b1 - _balance(key.currency1, bob), used1);
        assertLe(used0, 5 ether + 1);
        assertLe(used1, 5 ether);
        assertApproxEqAbs(second * 2, first, 2_000);
        _assertPositionMatches();
    }

    function test_depositAndWithdrawalSlippageDeadlineAndZeroChecks() public {
        vm.startPrank(alice);
        vm.expectRevert(SigmaHook.InvalidAmount.selector);
        hook.deposit(1 ether, 1 ether, 0, alice, block.timestamp);
        vm.expectRevert(SigmaHook.Slippage.selector);
        hook.deposit(0, 0, 1, alice, block.timestamp);
        vm.expectRevert(SigmaHook.InvalidAddress.selector);
        hook.deposit(1 ether, 1 ether, 1, address(0), block.timestamp);
        vm.expectRevert(SigmaHook.UnexpectedNativeValue.selector);
        hook.deposit{value: 1}(1 ether, 1 ether, 1, alice, block.timestamp);
        vm.expectRevert(SigmaHook.Expired.selector);
        hook.deposit(1 ether, 1 ether, 1, alice, block.timestamp - 1);
        vm.expectRevert(SigmaHook.Slippage.selector);
        hook.deposit(1 ether, 1 ether, type(uint256).max, alice, block.timestamp);
        vm.stopPrank();
        assertEq(hook.totalSupply(), 0);
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(SigmaHook.Slippage.selector);
        hook.withdraw(shares, 11 ether, 0, alice, block.timestamp);
        assertEq(hook.balanceOf(alice), shares);
        vm.expectRevert(SigmaHook.Expired.selector);
        hook.withdraw(shares, 0, 0, alice, block.timestamp - 1);
        vm.expectRevert(SigmaHook.InvalidAmount.selector);
        hook.withdraw(0, 0, 0, alice, block.timestamp);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert();
        hook.withdraw(shares, 0, 0, bob, block.timestamp);
    }

    function test_feeOwnershipCannotBeDilutedByNewDepositor() public {
        uint256 sharesA = _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 2 ether, 2 ether);
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        assertApproxEqAbs(assets0, 11.58 ether, 2);
        assertApproxEqAbs(assets1, 11.58 ether, 2);
        uint256 sharesB = _deposit(bob, 10 ether, 10 ether);
        assertLt(sharesB, sharesA);
        assertApproxEqRel(sharesB * 1158, (sharesA + 1_000) * 1000, 1e12);
        vm.prank(bob);
        (uint256 received0, uint256 received1) = hook.withdraw(sharesB, 0, 0, bob, block.timestamp);
        assertLe(received0, 10 ether);
        assertLe(received1, 10 ether);
        vm.prank(alice);
        (received0, received1) = hook.withdraw(sharesA, 0, 0, alice, block.timestamp);
        assertApproxEqAbs(received0, 11.58 ether, 20);
        assertApproxEqAbs(received1, 11.58 ether, 20);
    }

    function test_circularFeedUsesPostExecutionSlot0AndWraps() public {
        _seedBackground();
        int24[8] memory expected;
        for (uint256 i; i < 10; ++i) {
            _moveTo(int24(int256((i + 1) * 7)));
            (, int24 actual,,) = manager.getSlot0(key.toId());
            expected[i % 8] = actual;
            assertEq(hook.ticks(i % 8), actual);
        }
        for (uint256 i; i < 8; ++i) {
            assertEq(hook.ticks(i), expected[i]);
        }
        assertEq(hook.nextSample(), 2);
    }

    function test_cooldownRequiresFullThirtyMinutesAndDeviation() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        uint256 initialTime = hook.lastRebalance();
        vm.warp(initialTime + 30 minutes - 1);
        _moveTo(300);
        assertEq(hook.lastRebalance(), initialTime);
        vm.warp(initialTime + 30 minutes);
        _moveTo(600);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
        uint256 nowTime = block.timestamp;
        _moveTo(900);
        assertEq(hook.lastRebalance(), nowTime);
        _assertPositionMatches();
    }

    function test_noDeviationDoesNotRebalanceAfterCooldown() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        // A swap with no active liquidity movement is unnecessary: use 1 wei exact input,
        // consumed entirely as a fee, leaving slot0 at the seeded tick.
        uint256 initialTime = hook.lastRebalance();
        vm.warp(initialTime + 30 minutes);
        router.swap(key, false, -1, TickMath.getSqrtPriceAtTick(1));
        (, int24 active,,) = manager.getSlot0(key.toId());
        assertEq(active, 0);
        assertEq(hook.lastRebalance(), initialTime);
    }

    function test_rebalanceBurnsEntireOldPositionAndKeepsAllCapital() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.warp(hook.lastRebalance() + 30 minutes);
        _moveTo(300);
        hook.flashRebalance(key);
        (uint128 oldPosition,,) = manager.getPositionInfo(key.toId(), address(hook), -60, 60, hook.POSITION_SALT());
        assertEq(oldPosition, 0);
        (int24 proposedLower, int24 proposedUpper) = hook.proposedBands();
        assertEq(hook.tickLower(), proposedLower);
        assertEq(hook.tickUpper(), proposedUpper);
        assertEq(hook.tickLower() % 60, 0);
        assertEq(hook.tickUpper() % 60, 0);
        _assertPositionMatches();
        (uint256 a0, uint256 a1) = hook.totalAssets();
        assertGt(a0 + a1, 19 ether);
        assertGt(hook.liquidity(), 0);
        assertTrue(router.hookDeltasWereZero());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    /// A trend carries the price out of the band, so the burn returns a single currency. The cycle
    /// sells the surplus to the band's ratio and redeploys; later cycles keep doing so.
    function test_trendRebalanceSellsSurplusAndRedeploys() public {
        _seedBackground();
        _deposit(alice, 1_000 ether, 1_000 ether);
        uint256 t = block.timestamp + 31 minutes;
        vm.warp(t);
        _moveTo(2000);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), t);
        assertGt(hook.liquidity(), 0, "capital redeployed on the trend cycle");
        assertTrue(router.hookDeltasWereZero());
        _assertPositionMatches();
        assertLe(hook.tickLower(), 2000);
        assertGe(hook.tickUpper(), 2000);
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 8; ++j) {
                router.swap(key, true, -1000, TickMath.MIN_SQRT_PRICE + 1);
            }
            t += 31 minutes;
            vm.warp(t);
            _moveTo(i % 2 == 0 ? int24(-1500) : int24(1500));
            hook.flashRebalance(key);
            assertEq(hook.lastRebalance(), t);
            assertGt(hook.liquidity(), 0, "capital redeployed on a later cycle");
            assertTrue(router.hookDeltasWereZero());
            _assertPositionMatches();
        }
    }

    /// In a pool deep enough for the balancing trade to fill inside the range, a trend cycle
    /// leaves only a small idle remainder: the rest of the vault's value is in the new band.
    function test_deepPoolTrendRebalanceDeploysMostCapital() public {
        router.modify(key, -887220, 887220, 20_000 ether);
        _deposit(alice, 1_000 ether, 1_000 ether);
        vm.warp(block.timestamp + 31 minutes);
        _moveTo(2000);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
        assertGt(hook.liquidity(), 0);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        assertGe(tick, 2000);
        assertLe(tick, hook.tickUpper());
        (uint256 a0, uint256 a1) = hook.totalAssets();
        uint256 idle0 = _balance(key.currency0, address(hook)) + manager.balanceOf(address(hook), key.currency0.toId());
        uint256 idle1 = _balance(key.currency1, address(hook)) + manager.balanceOf(address(hook), key.currency1.toId());
        uint256 idleValue = VaultMath.valueInCurrency1(idle0, price) + idle1;
        uint256 totalValue = VaultMath.valueInCurrency1(a0, price) + a1;
        assertLe(idleValue * 10, totalValue, "at most a tenth of the vault's value idle");
        assertGt(totalValue, 1_900 ether, "value kept through the trade");
        assertTrue(router.hookDeltasWereZero());
        _assertPositionMatches();
    }

    /// The balancing trade is an ordinary swap by the hook: it pays the LP fee and stops at the band
    /// edge, never beyond, and the vault keeps all its value in both currencies.
    function test_balancingTradeStaysInsideBand() public {
        _seedBackground();
        _deposit(alice, 1_000 ether, 1_000 ether);
        vm.warp(block.timestamp + 31 minutes);
        _moveTo(2000);
        hook.flashRebalance(key);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertLe(tick, hook.tickUpper());
        assertGe(tick, hook.tickLower());
        (uint256 a0, uint256 a1) = hook.totalAssets();
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    /// Without other liquidity a swap would only displace the price, so the cycle invests as is.
    function test_noBalancingTradeInAnEmptyPool() public {
        _deposit(alice, 10 ether, 10 ether);
        vm.warp(block.timestamp + 30 minutes);
        _moveTo(20);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, 20);
        assertGt(hook.liquidity(), 0);
    }

    function test_firstDepositPullsOnlyWhatTheBandNeeds() public {
        (uint256 quote, uint256 need0, uint256 need1) = hook.previewDeposit(1 ether, 10);
        assertGt(quote, 0);
        assertLe(need0, 20);
        assertEq(need1, 10);
        uint256 before0 = _balance(key.currency0, alice);
        uint256 before1 = _balance(key.currency1, alice);
        vm.prank(alice);
        (uint256 shares, uint256 used0, uint256 used1) = hook.deposit(1 ether, 10, 1, alice, block.timestamp);
        assertEq(shares, quote);
        assertEq(used0, need0);
        assertEq(used1, need1);
        assertEq(before0 - _balance(key.currency0, alice), used0);
        assertEq(before1 - _balance(key.currency1, alice), used1);
        vm.prank(alice);
        hook.withdraw(shares, 0, 0, alice, block.timestamp);
        assertLe(before0 - _balance(key.currency0, alice), 20);
        assertLe(before1 - _balance(key.currency1, alice), 20);
    }

    /// Launch pools trade before anyone deposits: the first deposit must invest around the current
    /// price, not the launch tick's band.
    function test_firstDepositAfterPriceMoveUsesFreshBand() public {
        _seedBackground();
        _moveTo(3000);
        assertEq(hook.tickLower(), -60);
        assertEq(hook.tickUpper(), 60);
        (int24 proposedLower, int24 proposedUpper) = hook.proposedBands();
        (uint256 quote, uint256 need0, uint256 need1) = hook.previewDeposit(10 ether, 10 ether);
        vm.prank(alice);
        (uint256 shares, uint256 used0, uint256 used1) = hook.deposit(10 ether, 10 ether, 1, alice, block.timestamp);
        assertEq(hook.tickLower(), proposedLower);
        assertEq(hook.tickUpper(), proposedUpper);
        assertLe(proposedLower, 3000);
        assertGe(proposedUpper, 3000);
        assertGt(used0, 0);
        assertGt(used1, 0);
        assertGt(hook.liquidity(), 0);
        _assertPositionMatches();
        // The quote uses the same fresh band and rounded costs as execution.
        assertEq(shares, quote);
        assertEq(used0, need0);
        assertEq(used1, need1);
        // Idle inventory is only the unused side's remainder.
        (uint256 a0, uint256 a1) = hook.totalAssets();
        assertLe(_balance(key.currency0, address(hook)) * 100, a0 + 100);
        assertLe(_balance(key.currency1, address(hook)) * 100, a1 + 100);
    }

    function test_emptiedVaultDoesNotRebalanceUntilSomeoneDepositsAgain() public {
        _seedBackground();
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        vm.prank(alice);
        hook.withdraw(shares, 0, 0, alice, block.timestamp);
        assertEq(hook.totalSupply(), hook.MINIMUM_SHARES());
        uint256 initialTime = hook.lastRebalance();
        vm.warp(initialTime + 30 minutes);
        _moveTo(600);
        assertEq(hook.lastRebalance(), initialTime);
        _deposit(bob, 10 ether, 10 ether);
        vm.warp(block.timestamp + 30 minutes);
        _moveTo(1200);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
    }

    function test_strayEthIsRefusedOnAnErc20Pair() public {
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
        vm.deal(address(manager), 1 ether);
        vm.prank(address(manager));
        (ok,) = address(hook).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(hook).balance, 1 ether);
        vm.prank(owner);
        hook.rescueStrayETH();
        assertEq(address(hook).balance, 0);
    }

    function test_rebalanceCompoundsNetAccruedFeesAndDust() public {
        _deposit(alice, 10 ether, 10 ether);
        uint128 beforeL = hook.liquidity();
        router.donate(key, 1 ether, 1 ether);
        // External raw dust also belongs to holders and must be deployed on the cycle.
        vm.prank(alice);
        IERC20(Currency.unwrap(key.currency0)).transfer(address(hook), 0.1 ether);
        vm.prank(alice);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(hook), 0.1 ether);
        vm.warp(hook.lastRebalance() + 30 minutes);
        _moveTo(20);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
        assertGt(hook.liquidity(), beforeL);
        _assertPositionMatches();
        (, uint256 last0, uint256 last1) =
            manager.getPositionInfo(key.toId(), address(hook), hook.tickLower(), hook.tickUpper(), hook.POSITION_SALT());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthInside(key.toId(), hook.tickLower(), hook.tickUpper());
        assertEq(growth0, last0);
        assertEq(growth1, last1);
        assertTrue(router.hookDeltasWereZero());
    }

    function test_otherLpCanCollectZeroDeltaFeesEvenInEmergency() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        _moveTo(30);
        BalanceDelta first = router.modify(key, -887220, 887220, 0);
        assertGt(uint256(uint128(first.amount0())) + uint256(uint128(first.amount1())), 0);
        vm.prank(owner);
        hook.activateEmergencyMode();
        _moveTo(-30);
        BalanceDelta second = router.modify(key, -887220, 887220, 0);
        assertGt(uint256(uint128(second.amount0())) + uint256(uint128(second.amount1())), 0);
    }

    function test_emergencyRemovesAllLiquidityAndWithdrawsProRata() public {
        uint256 sharesA = _deposit(alice, 10 ether, 10 ether);
        uint256 sharesB = _deposit(bob, 20 ether, 20 ether);
        router.donate(key, 3 ether, 6 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        hook.activateEmergencyMode();
        vm.expectRevert(SigmaHook.EmergencyInactive.selector);
        hook.emergencyWithdraw();
        uint256 owner0 = _balance(key.currency0, owner);
        vm.prank(owner);
        hook.activateEmergencyMode();
        assertEq(_balance(key.currency0, owner), owner0);
        assertTrue(hook.emergencyMode());
        assertEq(hook.liquidity(), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        _assertPositionMatches();
        uint256 raw0 = _balance(key.currency0, address(hook));
        uint256 raw1 = _balance(key.currency1, address(hook));
        uint256 supply = hook.totalSupply();
        vm.prank(alice);
        (uint256 paid0, uint256 paid1) = hook.emergencyWithdraw();
        assertEq(paid0, FullMath.mulDiv(raw0, sharesA, supply));
        assertEq(paid1, FullMath.mulDiv(raw1, sharesA, supply));
        assertEq(hook.balanceOf(alice), 0);
        vm.prank(bob);
        (paid0, paid1) = hook.emergencyWithdraw(sharesB, bob);
        assertGt(paid0, 21 ether);
        assertGt(paid1, 23 ether);
        assertEq(hook.totalSupply(), hook.MINIMUM_SHARES());
        vm.prank(owner);
        vm.expectRevert(SigmaHook.EmergencyActive.selector);
        hook.activateEmergencyMode();
        vm.prank(alice);
        vm.expectRevert(SigmaHook.InvalidAmount.selector);
        hook.emergencyWithdraw();
        vm.expectRevert(SigmaHook.EmergencyActive.selector);
        hook.deposit(1, 1, 1, bob, block.timestamp);
    }

    function test_emergencyFreezesInvestmentButNotSwapsOrShareTransfers() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.prank(owner);
        hook.activateEmergencyMode();
        uint256 beforeTime = hook.lastRebalance();
        vm.warp(beforeTime + 1 days);
        _moveTo(300);
        assertEq(hook.liquidity(), 0);
        assertEq(hook.lastRebalance(), beforeTime);
        uint256 shares = hook.balanceOf(alice);
        vm.prank(alice);
        hook.transfer(bob, shares);
        vm.prank(bob);
        hook.emergencyWithdraw();
        assertEq(hook.balanceOf(bob), 0);
    }

    function test_ownerTransferRequiresAcceptanceAndCannotRenounce() public {
        vm.prank(owner);
        hook.transferOwnership(bob);
        assertEq(hook.owner(), owner);
        vm.prank(alice);
        vm.expectRevert();
        hook.acceptOwnership();
        vm.prank(bob);
        hook.acceptOwnership();
        assertEq(hook.owner(), bob);
        vm.prank(bob);
        vm.expectRevert(SigmaHook.OwnershipRequired.selector);
        hook.renounceOwnership();
    }

    function testFuzz_roundTripNeverCreatesAssets(uint96 amount0, uint96 amount1) public {
        amount0 = uint96(bound(amount0, 1e6, 100 ether));
        amount1 = uint96(bound(amount1, 1e6, 100 ether));
        vm.prank(alice);
        (uint256 shares, uint256 used0, uint256 used1) = hook.deposit(amount0, amount1, 1, alice, block.timestamp);
        assertLe(used0, amount0);
        assertLe(used1, amount1);
        vm.prank(alice);
        (uint256 paid0, uint256 paid1) = hook.withdraw(shares, 0, 0, alice, block.timestamp);
        assertLe(paid0, used0);
        assertLe(paid1, used1);
        (uint256 remaining0, uint256 remaining1) = hook.totalAssets();
        assertApproxEqAbs(paid0 + remaining0, used0, 2);
        assertApproxEqAbs(paid1 + remaining1, used1, 2);
        _assertPositionMatches();
    }

    function testFuzz_donationsDoNotAllowZeroShareDeposit(uint80 donation) public {
        donation = uint80(bound(donation, 1, 100 ether));
        _deposit(alice, 1e6, 1e6);
        vm.prank(alice);
        IERC20(Currency.unwrap(key.currency0)).transfer(address(hook), donation);
        vm.prank(alice);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(hook), donation);
        (uint256 quote,,) = hook.previewDeposit(1, 1);
        if (quote == 0) {
            vm.prank(bob);
            vm.expectRevert(SigmaHook.Slippage.selector);
            hook.deposit(1, 1, 1, bob, block.timestamp);
        } else {
            uint256 before0 = _balance(key.currency0, bob);
            uint256 before1 = _balance(key.currency1, bob);
            uint256 shares = _deposit(bob, 1, 1);
            vm.prank(bob);
            hook.withdraw(shares, 0, 0, bob, block.timestamp);
            assertLe(_balance(key.currency0, bob), before0);
            assertLe(_balance(key.currency1, bob), before1);
        }
    }
}

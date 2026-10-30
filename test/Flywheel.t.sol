// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SigmaHook} from "src/SigmaHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Only a test token: the live SHK token is never changed to add this behavior.
contract AcceptZeroToken is MockERC20 {
    constructor() MockERC20("Zero-accepting test token", "ZERO") {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == address(0)) {
            _burn(msg.sender, amount);
            return true;
        }
        return super.transfer(to, amount);
    }
}

contract FlywheelTest is Fixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function setUp() public {
        _setup(false);
    }

    function test_afterSwapOnlySamplesEvenWhenKeeperIsDue() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        uint128 initialL = hook.liquidity();
        uint256 timestamp = hook.lastRebalance();
        vm.warp(timestamp + 30 minutes);
        _moveTo(2000);
        assertEq(hook.lastRebalance(), timestamp);
        assertEq(hook.liquidity(), initialL);
        assertEq(hook.tickLower(), -60);
        assertEq(hook.tickUpper(), 60);
        assertEq(hook.nextSample(), 1);
        assertEq(hook.ticks(0), 2000);
        assertEq(token.balanceOf(hook.burnSink()), 0);
        assertEq(hook.burnReserve0() + hook.burnReserve1(), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_keeperGatesWrongPoolCooldownDeviationAndReplay() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        PoolKey memory wrong = key;
        wrong.fee++;
        vm.expectRevert(SigmaHook.InvalidPool.selector);
        hook.flashRebalance(wrong);
        vm.expectRevert(SigmaHook.RebalanceTooSoon.selector);
        hook.flashRebalance(key);
        uint256 ready = hook.lastRebalance() + 30 minutes;
        vm.warp(ready);
        vm.expectRevert(SigmaHook.WithinThreshold.selector);
        hook.flashRebalance(key);
        _moveTo(2000);
        vm.prank(bob);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalanceTimestamp(), ready);
        vm.expectRevert(SigmaHook.RebalanceTooSoon.selector);
        hook.flashRebalance(key);
        _assertPositionMatches();
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_emptyAndEmergencyVaultCannotPayBounty() public {
        _seedBackground();
        vm.warp(hook.lastRebalance() + 30 minutes);
        _moveTo(2000);
        vm.expectRevert(SigmaHook.NoExternalShares.selector);
        hook.flashRebalance(key);
        vm.prank(owner);
        hook.activateEmergencyMode();
        vm.expectRevert(SigmaHook.EmergencyActive.selector);
        hook.flashRebalance(key);
        vm.expectRevert(SigmaHook.EmergencyActive.selector);
        hook.retryInvestment(key);
    }

    function test_triSplitUsesFeesOnlyAndPaysActualKeeperBeforeReinvestment() public {
        router.modify(key, -887220, 887220, 100_000 ether);
        _deposit(alice, 1_000 ether, 1_000 ether);
        router.donate(key, 10 ether, 20 ether);
        _moveTo(500);
        vm.warp(hook.lastRebalance() + 30 minutes);
        uint256 before0 = key.currency0.balanceOf(bob);
        uint256 before1 = key.currency1.balanceOf(bob);
        uint256 tokenSupply = token.totalSupply();
        vm.recordLogs();
        vm.prank(bob);
        hook.flashRebalance(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fee0;
        uint256 fee1;
        uint256 buyback;
        uint256 compounded0;
        uint256 compounded1;
        uint256 paidIndex;
        uint256 rebalancedIndex;
        bool splitSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == keccak256("FeesSplit(uint256,uint256,uint256,uint256,uint256,uint256)")) {
                (uint256 f0, uint256 f1, uint256 b0, uint256 b1, uint256 k0, uint256 k1) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                assertEq(b0, f0 * 20 / 100);
                assertEq(b1, f1 * 20 / 100);
                assertEq(k0, f0 / 100);
                assertEq(k1, f1 / 100);
                fee0 += f0;
                fee1 += f1;
                compounded0 += f0 - b0 - k0;
                compounded1 += f1 - b1 - k1;
                splitSeen = true;
            } else if (sig == keccak256("BuybackExecuted(uint256,uint256)")) {
                (, uint256 bought) = abi.decode(logs[i].data, (uint256, uint256));
                buyback += bought;
            } else if (sig == keccak256("KeeperPaid(address,uint256,uint256)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), bob);
                paidIndex = i;
            } else if (sig == keccak256("Rebalanced(int24,int24,uint128,uint128)")) {
                rebalancedIndex = i;
            }
        }
        assertTrue(splitSeen);
        assertLt(paidIndex, rebalancedIndex);
        assertGt(fee0 + fee1, 0);
        assertGt(buyback, 0);
        assertEq(key.currency0.balanceOf(bob) - before0, fee0 / 100);
        assertEq(key.currency1.balanceOf(bob) - before1, fee1 / 100);
        uint256 launchFee = Currency.unwrap(key.currency0) == address(token) ? fee0 : fee1;
        assertEq(token.balanceOf(hook.burnSink()), launchFee * 20 / 100 + buyback);
        assertEq(token.totalSupply(), tokenSupply, "the existing token is locked, not re-minted or supply-burned");
        assertEq(compounded0, fee0 - fee0 / 5 - fee0 / 100);
        assertEq(compounded1, fee1 - fee1 / 5 - fee1 / 100);
        assertEq(hook.keeperReserve0() + hook.keeperReserve1(), 0);
        assertGt(hook.liquidity(), 0);
        _assertPositionMatches();
    }

    function test_harvestByNewDepositCannotEvadeFeeReservesOrDiluteOldHolder() public {
        _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 1 ether, 2 ether);
        (uint256 before0, uint256 before1) = hook.totalAssets();
        (uint256 quote,,) = hook.previewDeposit(1 ether, 1 ether);
        uint256 second = _deposit(bob, 1 ether, 1 ether);
        assertEq(second, quote);
        assertApproxEqAbs(hook.burnReserve0(), 0.2 ether, 1);
        assertApproxEqAbs(hook.keeperReserve1(), 0.02 ether, 1);
        (uint256 after0, uint256 after1) = hook.totalAssets();
        assertGe(after0, before0);
        assertGe(after1, before1);
        vm.prank(bob);
        (uint256 paid0, uint256 paid1) = hook.withdraw(second, 0, 0, bob, block.timestamp);
        assertLe(paid0, 1 ether);
        assertLe(paid1, 1 ether);
        assertGt(hook.burnReserve0(), 0);
    }

    function test_noExternalLiquidityDefersAndPermissionlessRetryRecovers() public {
        _deposit(alice, 100 ether, 100 ether);
        _moveTo(2000);
        vm.warp(hook.lastRebalance() + 30 minutes);
        vm.prank(bob);
        hook.flashRebalance(key);
        assertEq(hook.liquidity(), 0);
        assertTrue(hook.investmentPending());
        assertGt(hook.burnReserve0() + hook.burnReserve1(), 0);
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        assertGt(assets0 + assets1, 190 ether);
        uint256 timestamp = hook.lastRebalance();
        int24 lower = hook.tickLower();
        int24 upper = hook.tickUpper();
        router.modify(key, -887220, 887220, 100_000 ether);
        vm.prank(alice);
        hook.retryInvestment(key);
        assertGt(hook.liquidity(), 0);
        assertFalse(hook.investmentPending());
        assertEq(hook.lastRebalance(), timestamp);
        assertEq(hook.tickLower(), lower);
        assertEq(hook.tickUpper(), upper);
        vm.expectRevert(SigmaHook.NoPendingInvestment.selector);
        hook.retryInvestment(key);
    }

    function test_deferredAssetsRemainWithdrawable() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        _moveTo(2000);
        vm.warp(hook.lastRebalance() + 30 minutes);
        hook.flashRebalance(key);
        assertTrue(hook.investmentPending());
        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(shares, 0, 0, alice, block.timestamp);
        assertGt(out0 + out1, 19 ether);
        assertEq(hook.balanceOf(alice), 0);
    }

    function test_depositCannotRefreshDeferredRangeToBypassKeeperCooldown() public {
        _deposit(alice, 100 ether, 100 ether);
        _moveTo(2000);
        vm.warp(hook.lastRebalance() + 30 minutes);
        hook.flashRebalance(key);
        assertTrue(hook.investmentPending());
        int24 lower = hook.tickLower();
        int24 upper = hook.tickUpper();
        uint256 time = hook.lastRebalance();
        _moveTo(2100);
        _deposit(bob, 1 ether, 1 ether);
        assertEq(hook.tickLower(), lower);
        assertEq(hook.tickUpper(), upper);
        assertEq(hook.lastRebalance(), time);
    }

    function test_deferredBuybackIsSpentOnlyOnceOnNextEligibleCycle() public {
        _deposit(alice, 100 ether, 100 ether);
        router.donate(key, 2 ether, 3 ether);
        _moveTo(2000);
        vm.warp(hook.lastRebalance() + 30 minutes);
        hook.flashRebalance(key);
        uint256 pending = hook.burnReserve0() + hook.burnReserve1();
        assertGt(pending, 0);
        uint256 locked = token.balanceOf(hook.burnSink());
        router.modify(key, -887220, 887220, 100_000 ether);
        // Refresh the sample window, then supply an outlier on the opposite side.
        for (uint256 i; i < 8; ++i) {
            _moveTo(i % 2 == 0 ? int24(1900) : int24(1901));
        }
        _moveTo(-2000);
        vm.warp(hook.lastRebalance() + 30 minutes);
        hook.flashRebalance(key);
        assertEq(hook.burnReserve0() + hook.burnReserve1(), 0);
        assertGt(token.balanceOf(hook.burnSink()), locked);
        locked = token.balanceOf(hook.burnSink());
        vm.expectRevert(SigmaHook.RebalanceTooSoon.selector);
        hook.flashRebalance(key);
        assertEq(token.balanceOf(hook.burnSink()), locked);
        (bool ok,) = hook.burnSink().call(abi.encodeWithSignature("withdraw(address,uint256)", alice, locked));
        assertFalse(ok);
        assertEq(token.balanceOf(hook.burnSink()), locked);
    }

    function test_zeroAddressCompatibleTokenUsesRequestedDisposalPath() public {
        AcceptZeroToken burnable = new AcceptZeroToken();
        hook = _deployHook(address(burnable));
        (address a, address b) =
            address(burnable) < address(weth) ? (address(burnable), address(weth)) : (address(weth), address(burnable));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, 1 << 96);
        burnable.mint(alice, 1_000 ether);
        burnable.mint(address(router), 1_000_000 ether);
        vm.startPrank(alice);
        burnable.approve(address(hook), 1_000 ether);
        weth.approve(address(hook), 1_000 ether);
        vm.stopPrank();
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 1 ether, 1 ether);
        _moveTo(300);
        vm.warp(hook.lastRebalance() + 30 minutes);
        uint256 supply = burnable.totalSupply();
        hook.flashRebalance(key);
        assertLt(burnable.totalSupply(), supply);
        assertEq(burnable.balanceOf(hook.burnSink()), 0);
        assertGt(hook.liquidity(), 0);
    }

    function testFuzz_dislocatedPriceStillMintsOrExplicitlyDefers(int24 target, uint64 background) public {
        target = int24(bound(target, -12_000, 12_000));
        if (target > -100 && target < 100) target = 2000;
        uint256 depth = bound(background, 1e12, 1_000 ether);
        router.modify(key, -887220, 887220, int256(depth));
        _deposit(alice, 100 ether, 100 ether);
        _moveTo(target);
        vm.warp(hook.lastRebalance() + 30 minutes);
        hook.flashRebalance(key);
        assertTrue(hook.liquidity() > 0 || hook.investmentPending());
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        assertGt(assets0 + assets1, 0);
        _assertPositionMatches();
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }
}

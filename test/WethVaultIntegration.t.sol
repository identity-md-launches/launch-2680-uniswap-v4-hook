// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {SigmaToken} from "src/SigmaToken.sol";
import {SigmaHook} from "src/SigmaHook.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Uses actual ETH-backed WETH and the vendored PoolManager; no RPC or token storage edits.
contract WethVaultIntegrationTest is Fixture {
    using StateLibrary for IPoolManager;

    WETH private wrapped;

    function setUp() public {
        alice = makeAddr("weth-alice");
        bob = makeAddr("weth-bob");
        owner = makeAddr("weth-owner");
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(owner)));
        token = new SigmaToken();
        wrapped = new WETH();
        hook = _deployHook(address(token));
        (address a, address b) =
            address(token) < address(wrapped) ? (address(token), address(wrapped)) : (address(wrapped), address(token));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, 1 << 96);
        router = new TestRouter(manager);
        token.transfer(address(router), 1_000_000 ether);
        vm.deal(address(this), 1_000_000 ether);
        wrapped.deposit{value: 1_000_000 ether}();
        wrapped.transfer(address(router), 900_000 ether);
        for (uint256 i; i < 2; ++i) {
            address actor = i == 0 ? alice : bob;
            token.transfer(actor, 10_000 ether);
            wrapped.transfer(actor, 10_000 ether);
            vm.startPrank(actor);
            token.approve(address(hook), type(uint256).max);
            wrapped.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_priceAboveLaunchSoleVaultReserveExactInputRebalance() public {
        _soleVaultSwap(true, false);
    }

    function test_priceAboveLaunchSoleVaultReserveExactOutputRebalance() public {
        _soleVaultSwap(true, true);
    }

    function test_priceBelowLaunchSoleVaultReserveExactInputRebalance() public {
        _soleVaultSwap(false, false);
    }

    function test_priceBelowLaunchSoleVaultReserveExactOutputRebalance() public {
        _soleVaultSwap(false, true);
    }

    /// @dev Each sample lies within sqrt(7) sigma of the mean, so a band refreshed from the feed always
    /// contains the moved price: the first deposit after an empty-pool move must bring both tokens.
    function test_firstDepositAfterEmptyPoolMoveRecentresBandOnFeed() public {
        _moveTo(60);
        (int24 lower, int24 upper) = hook.proposedBands();
        assertLt(lower, 60);
        assertGt(upper, 60);
        // Preview and execution both use the refreshed band; one-sided entry cannot fund it.
        vm.prank(alice);
        vm.expectRevert(SigmaHook.Slippage.selector);
        hook.deposit(0, 10 ether, 1, alice, block.timestamp);
        assertEq(hook.tickLower(), -60, "failed deposit must not keep the refreshed band");
        assertEq(hook.tickUpper(), 60);
        uint256 before0 = key.currency0.balanceOf(alice);
        uint256 before1 = key.currency1.balanceOf(alice);
        vm.prank(alice);
        (uint256 shares, uint256 paid0, uint256 paid1) = hook.deposit(10 ether, 10 ether, 1, alice, block.timestamp);
        assertGt(shares, 0);
        assertEq(hook.tickLower(), lower);
        assertEq(hook.tickUpper(), upper);
        assertGt(paid0, 0);
        assertGt(paid1, 0);
        // Only what the minted liquidity costs leaves the depositor; the unused budget stays.
        assertEq(before0 - key.currency0.balanceOf(alice), paid0);
        assertEq(before1 - key.currency1.balanceOf(alice), paid1);
        assertTrue(paid0 < 10 ether || paid1 < 10 ether);
        assertEq(key.currency0.balanceOf(address(manager)), paid0);
        assertEq(key.currency1.balanceOf(address(manager)), paid1);
        _assertPositionMatches();
    }

    function _soleVaultSwap(bool fromAbove, bool exactOutput) private {
        // An empty pool can move to the limit without moving tokens, so every token the manager
        // holds afterwards is the vault's own deposit, refreshed around the moved price.
        _moveTo(fromAbove ? int24(60) : int24(-60));
        vm.prank(alice);
        (uint256 shares, uint256 paid0, uint256 paid1) = hook.deposit(10 ether, 10 ether, 1, alice, block.timestamp);
        assertEq(key.currency0.balanceOf(address(manager)), paid0);
        assertEq(key.currency1.balanceOf(address(manager)), paid1);
        vm.warp(hook.lastRebalance() + 30 minutes);
        BalanceDelta delta = router.swap(
            key,
            fromAbove,
            // Asking for the whole output reserve stops the swap at its limit, inside the band.
            exactOutput ? int256(fromAbove ? paid1 : paid0) : -int256(100 ether),
            TickMath.getSqrtPriceAtTick(fromAbove ? int24(-50) : int24(50))
        );
        assertLt(hook.lastRebalance(), block.timestamp, "swaps must only sample ticks");
        assertTrue(router.hookDeltasWereZero(), "hook must settle before router input arrives");
        assertEq(hook.totalSupply(), shares + hook.MINIMUM_SHARES(), "swap changed share ownership");
        _assertPositionMatches();
        assertEq(key.currency0.balanceOf(address(manager)), uint256(int256(paid0) - int256(delta.amount0())));
        assertEq(key.currency1.balanceOf(address(manager)), uint256(int256(paid1) - int256(delta.amount1())));
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        (uint256 fee0, uint256 fee1) = hook.feeLiabilities();
        assets0 += fee0;
        assets1 += fee1;
        assertApproxEqAbs(assets0, uint256(int256(paid0) - int256(delta.amount0())), 4);
        assertApproxEqAbs(assets1, uint256(int256(paid1) - int256(delta.amount1())), 4);
        assertEq(wrapped.totalSupply(), address(wrapped).balance, "WETH backing changed");
        vm.prank(owner);
        hook.activateEmergencyMode();
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        vm.prank(alice);
        hook.emergencyWithdraw();
        assertEq(hook.balanceOf(alice), 0);
    }

    function test_emergencyReturnsWrappedEtherToChosenReceiverWithoutUnwrapping() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 2 ether, 3 ether);
        vm.prank(owner);
        hook.activateEmergencyMode();
        uint256 beforeWrapped = wrapped.balanceOf(bob);
        uint256 beforeLaunch = token.balanceOf(bob);
        uint256 beforeEth = bob.balance;
        uint256 beforeBacking = address(wrapped).balance;
        uint256 beforeSupply = wrapped.totalSupply();
        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = hook.emergencyWithdraw(shares, bob);
        uint256 expectedWeth = Currency.unwrap(key.currency0) == address(wrapped) ? amount0 : amount1;
        uint256 expectedToken = Currency.unwrap(key.currency0) == address(token) ? amount0 : amount1;
        assertGt(expectedWeth, 10 ether);
        assertEq(wrapped.balanceOf(bob) - beforeWrapped, expectedWeth);
        assertEq(token.balanceOf(bob) - beforeLaunch, expectedToken);
        assertEq(bob.balance, beforeEth);
        assertEq(address(wrapped).balance, beforeBacking);
        assertEq(wrapped.totalSupply(), beforeSupply);
        assertEq(hook.balanceOf(alice), 0);
    }

    function _coldManagerSwap(bool token1Only, bool exactOutput) private {
        // An empty pool can move to the limit without moving tokens. The first LP then seeds
        // just the output asset, leaving the next swap's input currency completely unfunded.
        _moveTo(token1Only ? int24(60) : int24(-60));
        uint256 seed0 = token1Only ? 0 : 10 ether;
        uint256 seed1 = token1Only ? 10 ether : 0;
        uint256 shares = _deposit(alice, seed0, seed1);
        Currency input = token1Only ? key.currency0 : key.currency1;
        assertEq(input.balanceOf(address(manager)), 0);
        assertEq(input.balanceOf(address(hook)), 0);
        vm.warp(hook.lastRebalance() + 30 minutes);
        BalanceDelta delta = router.swap(
            key,
            token1Only,
            exactOutput ? int256(9 ether) : -int256(100 ether),
            TickMath.getSqrtPriceAtTick(token1Only ? int24(-50) : int24(50))
        );
        assertLt(hook.lastRebalance(), block.timestamp, "swaps must only sample ticks");
        assertTrue(router.hookDeltasWereZero(), "hook must settle before router input arrives");
        assertGt(input.balanceOf(address(manager)), 0);
        assertEq(hook.totalSupply(), shares + hook.MINIMUM_SHARES(), "swap changed share ownership");
        (uint128 oldLiquidity,,) = manager.getPositionInfo(key.toId(), address(hook), -60, 60, hook.POSITION_SALT());
        // If the new bands happen to equal the old bands, the position can have been redeployed there.
        if (hook.tickLower() != -60 || hook.tickUpper() != 60) assertEq(oldLiquidity, 0);
        _assertPositionMatches();
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        (uint256 fee0, uint256 fee1) = hook.feeLiabilities();
        assets0 += fee0;
        assets1 += fee1;
        assertApproxEqAbs(assets0, uint256(int256(seed0) - int256(delta.amount0())), 4);
        assertApproxEqAbs(assets1, uint256(int256(seed1) - int256(delta.amount1())), 4);
        assertEq(wrapped.totalSupply(), address(wrapped).balance, "WETH backing changed");
        vm.prank(owner);
        hook.activateEmergencyMode();
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        vm.prank(alice);
        hook.emergencyWithdraw();
        assertEq(hook.balanceOf(alice), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {SigmaHook} from "src/SigmaHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract KeeperReceiver {
    SigmaHook immutable hook;
    bool immutable reject;
    bool public attempted;
    bytes4 public refusal;

    constructor(SigmaHook hook_, bool reject_) {
        hook = hook_;
        reject = reject_;
    }

    function rebalance(PoolKey calldata key) external {
        hook.flashRebalance(key);
    }

    receive() external payable {
        require(!reject, "reject bounty");
        attempted = true;
        (bool success, bytes memory result) = address(hook).call(abi.encodeCall(hook.flashRebalance, (hook.poolKey())));
        require(!success, "reentered keeper");
        refusal = bytes4(result);
    }
}

contract NativeSafetyTest is Fixture {
    function setUp() public {
        _setup(true);
    }

    function testFuzz_initialDepositRefundsNativeBudgetAndMatchesFreshPreview(
        uint64 max0Seed,
        uint64 max1Seed,
        int24 tick
    ) public {
        uint256 max0 = bound(max0Seed, 0.1 ether, 10 ether);
        uint256 max1 = bound(max1Seed, 0.1 ether, 10 ether);
        tick = int24(bound(tick, -10_000, 10_000));
        _seedBackground();
        if (tick != 0) _moveTo(tick);
        (uint256 quote, uint256 need0, uint256 need1) = hook.previewDeposit(max0, max1);
        uint256 beforeNative = alice.balance;
        uint256 beforeToken = token.balanceOf(alice);
        vm.prank(alice);
        (uint256 shares, uint256 paid0, uint256 paid1) =
            hook.deposit{value: max0}(max0, max1, quote, alice, block.timestamp);
        assertEq(shares, quote);
        assertEq(paid0, need0);
        assertEq(paid1, need1);
        assertEq(beforeNative - alice.balance, paid0);
        assertEq(beforeToken - token.balanceOf(alice), paid1);
        assertEq(address(hook).balance, 0, "unused native budget locked with genesis shares");
        assertEq(hook.accountedNative(), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertGt(hook.liquidity(), 0);
        _assertPositionMatches();
    }

    function test_ownerRescuesOnlyForcedSurplusAndCannotSweepLPCapital() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        vm.prank(owner);
        hook.activateEmergencyMode();
        uint256 owed = hook.accountedNative();
        assertGt(owed, 0);
        vm.deal(address(hook), address(hook).balance + 0.3 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.rescueStrayETH();
        uint256 before = owner.balance;
        vm.prank(owner);
        hook.rescueStrayETH();
        assertEq(owner.balance - before, 0.3 ether);
        assertEq(address(hook).balance, owed);
        assertEq(hook.accountedNative(), owed);
        vm.prank(owner);
        hook.rescueStrayETH();
        assertEq(address(hook).balance, owed);
        vm.prank(alice);
        hook.emergencyWithdraw(shares, alice);
        assertLe(hook.accountedNative(), 10);
    }

    function test_receiveAllowsOnlyManagerOrOnceConfiguredWETH() public {
        vm.prank(alice);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setWETH(address(weth));
        vm.prank(owner);
        vm.expectRevert(SigmaHook.InvalidAddress.selector);
        hook.setWETH(address(0));
        vm.prank(owner);
        hook.setWETH(address(weth));
        vm.prank(owner);
        vm.expectRevert(SigmaHook.AlreadyConfigured.selector);
        hook.setWETH(address(weth));
        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (ok,) = address(hook).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(hook.accountedNative(), 0);
        vm.prank(owner);
        hook.rescueStrayETH();
        assertEq(address(hook).balance, 0);
    }

    function test_keeperCallbackCannotReenterAndRejectedBountyRollsBack() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 1 ether, 1 ether);
        _moveTo(300);
        uint256 beforeTime = hook.lastRebalance();
        uint128 beforeL = hook.liquidity();
        vm.warp(beforeTime + 30 minutes);
        KeeperReceiver rejecting = new KeeperReceiver(hook, true);
        vm.expectRevert();
        rejecting.rebalance(key);
        assertEq(hook.lastRebalance(), beforeTime);
        assertEq(hook.liquidity(), beforeL);
        assertEq(token.balanceOf(hook.burnSink()), 0);
        KeeperReceiver accepting = new KeeperReceiver(hook, false);
        accepting.rebalance(key);
        assertTrue(accepting.attempted());
        assertEq(accepting.refusal(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertGt(address(accepting).balance, 0);
        assertEq(hook.lastRebalance(), block.timestamp);
        assertEq(address(hook).balance, hook.accountedNative());
    }
}

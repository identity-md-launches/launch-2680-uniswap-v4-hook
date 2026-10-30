// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {SigmaHook} from "src/SigmaHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IAccountingDriver {
    function executeTrade(int24 target, bool exactOutput) external returns (BalanceDelta);
    function giveFees(uint256 amount0, uint256 amount1) external;
}

/// @dev Sole-LP market: every manager token belongs to this vault, except integer rounding dust.
/// The book is updated from external wallet flows, never from totalAssets() or VaultMath.
contract AccountingHandler is Test {
    using StateLibrary for IPoolManager;

    SigmaHook public immutable vault;
    IPoolManager public immutable manager;
    IAccountingDriver private immutable driver;
    address private immutable owner;
    PoolKey private key;
    address[3] public actors;
    mapping(address => uint256) public expectedShares;
    uint256 public expectedSupply;
    int256 public book0 = 170 ether;
    int256 public book1 = 170 ether;
    uint256 public roundingBudget = 12;
    bool public emergencySeen;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public trades;
    uint256 public roundTrips;
    uint256 public sampleCount;
    mapping(uint256 => int24) public executionTick;

    constructor(SigmaHook vault_, address[3] memory actors_, address owner_) {
        vault = vault_;
        manager = vault_.poolManager();
        driver = IAccountingDriver(msg.sender);
        owner = owner_;
        key = vault_.poolKey();
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            expectedShares[actors[i]] = vault.balanceOf(actors[i]);
            expectedSupply += expectedShares[actors[i]];
        }
        expectedSupply += vault.MINIMUM_SHARES();
    }

    function deposit(uint256 seed0, uint256 seed1, uint8 payerSeed, uint8 receiverSeed) external {
        if (emergencySeen) return;
        _deposit(actors[payerSeed % 3], actors[receiverSeed % 3], seed0, seed1);
    }

    function withdraw(uint256 seed, uint8 actorSeed, uint8 receiverSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 held = expectedShares[actor];
        if (held == 0) return;
        uint256 shares = seed == type(uint256).max ? held : bound(seed, 1, held);
        _withdraw(actor, actors[receiverSeed % 3], shares);
    }

    function transferShares(uint256 seed, uint8 fromSeed, uint8 toSeed, bool delegated) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 shares = bound(seed, 0, expectedShares[from]);
        if (delegated) {
            address spender = actors[(uint256(fromSeed) + 1) % 3];
            vm.prank(from);
            vault.approve(spender, shares);
            vm.prank(spender);
            assertTrue(vault.transferFrom(from, to, shares));
            assertEq(vault.allowance(from, spender), 0);
        } else {
            vm.prank(from);
            assertTrue(vault.transfer(to, shares));
        }
        expectedShares[from] -= shares;
        expectedShares[to] += shares;
    }

    function donateRaw(uint64 seed0, uint64 seed1, uint8 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount0 = bound(seed0, 0, 1 ether);
        uint256 amount1 = bound(seed1, 0, 1 ether);
        vm.startPrank(actor);
        assertTrue(IERC20(Currency.unwrap(key.currency0)).transfer(address(vault), amount0));
        assertTrue(IERC20(Currency.unwrap(key.currency1)).transfer(address(vault), amount1));
        vm.stopPrank();
        book0 += int256(amount0);
        book1 += int256(amount1);
    }

    function donateFees(uint64 seed0, uint64 seed1) external {
        if (emergencySeen || manager.getLiquidity(key.toId()) == 0) return;
        uint256 amount0 = bound(seed0, 0, 1 ether);
        uint256 amount1 = bound(seed1, 0, 1 ether);
        driver.giveFees(amount0, amount1);
        book0 += int256(amount0);
        book1 += int256(amount1);
        roundingBudget += 4;
    }

    function trade(int24 seed, uint32 elapsed, bool exactOutput) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 1 hours));
        int24 target = int24(bound(seed, -600, 600));
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        uint256 previousRebalance = vault.lastRebalance();
        BalanceDelta paid = driver.executeTrade(target, exactOutput);
        // Positive router delta is paid out of the pool; negative delta is an input to it.
        book0 -= int256(paid.amount0());
        book1 -= int256(paid.amount1());
        roundingBudget += 4;
        ++trades;
        if (beforePrice != TickMath.getSqrtPriceAtTick(target)) {
            (, int24 actualTick,,) = manager.getSlot0(key.toId());
            executionTick[sampleCount++] = actualTick;
            assertEq(vault.lastRebalance(), previousRebalance, "swap performed keeper work");
        } else {
            assertEq(vault.lastRebalance(), previousRebalance);
        }
    }

    function roundTrip(uint256 seed0, uint256 seed1, uint8 actorSeed) external {
        if (emergencySeen) return;
        address actor = actors[actorSeed % 3];
        uint256 before0 = key.currency0.balanceOf(actor);
        uint256 before1 = key.currency1.balanceOf(actor);
        uint256 shares = _deposit(actor, actor, seed0, seed1);
        if (shares == 0) return;
        _withdraw(actor, actor, shares);
        assertLe(key.currency0.balanceOf(actor), before0, "round trip extracted currency0");
        assertLe(key.currency1.balanceOf(actor), before1, "round trip extracted currency1");
        ++roundTrips;
    }

    function emergency(uint8 seed) external {
        if (seed % 32 != 0 || emergencySeen) return;
        uint256 before0 = key.currency0.balanceOf(owner);
        uint256 before1 = key.currency1.balanceOf(owner);
        vm.prank(owner);
        vault.activateEmergencyMode();
        emergencySeen = true;
        roundingBudget += 4;
        assertEq(key.currency0.balanceOf(owner), before0, "owner received LP assets");
        assertEq(key.currency1.balanceOf(owner), before1, "owner received LP assets");
    }

    function _deposit(address payer, address receiver, uint256 seed0, uint256 seed1) private returns (uint256 shares) {
        uint256 max0 = bound(seed0, 0, 5 ether);
        uint256 max1 = bound(seed1, 0, 5 ether);
        (uint256 quote, uint256 used0, uint256 used1) = vault.previewDeposit(max0, max1);
        if (quote == 0) {
            vm.prank(payer);
            vm.expectRevert(SigmaHook.Slippage.selector);
            vault.deposit(max0, max1, 1, receiver, block.timestamp);
            return 0;
        }
        uint256 before0 = key.currency0.balanceOf(payer);
        uint256 before1 = key.currency1.balanceOf(payer);
        uint256 paid0;
        uint256 paid1;
        vm.prank(payer);
        (shares, paid0, paid1) = vault.deposit(max0, max1, quote, receiver, block.timestamp);
        assertEq(shares, quote, "preview disagrees at unchanged spot state");
        assertEq(paid0, used0);
        assertEq(paid1, used1);
        assertLe(paid0, max0);
        assertLe(paid1, max1);
        assertEq(before0 - key.currency0.balanceOf(payer), paid0);
        assertEq(before1 - key.currency1.balanceOf(payer), paid1);
        book0 += int256(before0 - key.currency0.balanceOf(payer));
        book1 += int256(before1 - key.currency1.balanceOf(payer));
        expectedShares[receiver] += shares;
        expectedSupply += shares;
        roundingBudget += 4;
        ++deposits;
    }

    function _withdraw(address actor, address receiver, uint256 shares) private {
        uint256 before0 = key.currency0.balanceOf(receiver);
        uint256 before1 = key.currency1.balanceOf(receiver);
        uint256 paid0;
        uint256 paid1;
        if (emergencySeen) {
            uint256 raw0 = key.currency0.balanceOf(address(vault));
            uint256 raw1 = key.currency1.balanceOf(address(vault));
            vm.prank(actor);
            (paid0, paid1) = vault.emergencyWithdraw(shares, receiver);
            assertEq(paid0, raw0 * shares / expectedSupply, "emergency pro-rata currency0");
            assertEq(paid1, raw1 * shares / expectedSupply, "emergency pro-rata currency1");
        } else {
            vm.prank(actor);
            (paid0, paid1) = vault.withdraw(shares, 0, 0, receiver, block.timestamp);
        }
        assertEq(key.currency0.balanceOf(receiver) - before0, paid0);
        assertEq(key.currency1.balanceOf(receiver) - before1, paid1);
        book0 -= int256(key.currency0.balanceOf(receiver) - before0);
        book1 -= int256(key.currency1.balanceOf(receiver) - before1);
        expectedShares[actor] -= shares;
        expectedSupply -= shares;
        roundingBudget += 4;
        ++withdrawals;
    }
}

contract VaultAccountingInvariantTest is Fixture, IAccountingDriver {
    using StateLibrary for IPoolManager;

    AccountingHandler private handler;
    address private carol;

    function setUp() public {
        _setup(false);
        carol = makeAddr("accounting-carol");
        _fundAndApprove(carol);
        _deposit(alice, 100 ether, 100 ether);
        _deposit(bob, 50 ether, 50 ether);
        _deposit(carol, 20 ether, 20 ether);
        handler = new AccountingHandler(hook, [alice, bob, carol], owner);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = AccountingHandler.deposit.selector;
        selectors[1] = AccountingHandler.withdraw.selector;
        selectors[2] = AccountingHandler.transferShares.selector;
        selectors[3] = AccountingHandler.donateRaw.selector;
        selectors[4] = AccountingHandler.donateFees.selector;
        selectors[5] = AccountingHandler.trade.selector;
        selectors[6] = AccountingHandler.roundTrip.selector;
        selectors[7] = AccountingHandler.emergency.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function executeTrade(int24 target, bool exactOutput) external returns (BalanceDelta) {
        require(msg.sender == address(handler));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        if (price == limit) return BalanceDelta.wrap(0);
        return router.swap(key, limit < price, exactOutput ? int256(1 ether) : -int256(5 ether), limit);
    }

    function giveFees(uint256 amount0, uint256 amount1) external {
        require(msg.sender == address(handler));
        router.donate(key, amount0, amount1);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_assetsBackedByExternalCashFlows() public view {
        assertGe(handler.book0(), 0);
        assertGe(handler.book1(), 0);
        uint256 backing0 = key.currency0.balanceOf(address(manager)) + key.currency0.balanceOf(address(hook));
        uint256 backing1 = key.currency1.balanceOf(address(manager)) + key.currency1.balanceOf(address(hook));
        assertEq(backing0, uint256(handler.book0()), "currency0 cash-flow ledger");
        assertEq(backing1, uint256(handler.book1()), "currency1 cash-flow ledger");
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        (uint256 fee0, uint256 fee1) = hook.feeLiabilities();
        assets0 += fee0;
        assets1 += fee1;
        assertLe(assets0, backing0, "unbacked reported currency0 assets");
        assertLe(assets1, backing1, "unbacked reported currency1 assets");
        // Each liquidity/fee operation loses at most a few integer base units at these ticks.
        // This is an absolute, operation-count bound, not a percentage that conceals value loss.
        assertLe(backing0 - assets0, handler.roundingBudget(), "currency0 stranded in manager");
        assertLe(backing1 - assets1, handler.roundingBudget(), "currency1 stranded in manager");
        assertEq(hook.totalSupply(), handler.expectedSupply());
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(hook.balanceOf(actor), handler.expectedShares(actor), "wrong share recipient or burn");
        }
        assertEq(hook.balanceOf(address(hook)), hook.MINIMUM_SHARES());
        assertEq(hook.emergencyMode(), handler.emergencySeen(), "emergency state reopened");
        // The oracle history is append-only. Compare its last eight actual executions with
        // the production ring, including zero-volume swaps and sampling after emergency.
        uint256 count = handler.sampleCount();
        assertEq(hook.nextSample(), count % 8);
        for (uint256 i; i < 8; ++i) {
            if (i >= count) {
                assertEq(hook.ticks(i), 0);
            } else {
                uint256 latest = i + ((count - 1 - i) / 8) * 8;
                assertEq(hook.ticks(i), handler.executionTick(latest), "feed lost or reordered an execution tick");
            }
        }
        _assertPositionMatches();
        if (handler.emergencySeen()) {
            assertEq(hook.liquidity(), 0);
            assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
            assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
            assertEq(assets0, key.currency0.balanceOf(address(hook)));
            assertEq(assets1, key.currency1.balanceOf(address(hook)));
        }
    }

    function afterInvariant() public {
        handler.emergency(0);
        for (uint8 i; i < 3; ++i) {
            handler.withdraw(type(uint256).max, i, i);
        }
        assertEq(hook.totalSupply(), hook.MINIMUM_SHARES(), "all holders must be able to exit");
        invariant_assetsBackedByExternalCashFlows();
    }

    /// @dev Pins reachable branches in addition to the random campaign and its call metrics.
    function test_accountingHandlerExercisesEveryActionAndFullExit() public {
        handler.deposit(3 ether, 2 ether, 0, 2);
        handler.donateFees(1 ether, 0.5 ether);
        handler.donateRaw(0.1 ether, 0.2 ether, 1);
        handler.transferShares(type(uint128).max, 2, 1, true);
        handler.trade(20, 30 minutes, false);
        handler.roundTrip(1 ether, 1 ether, 0);
        handler.withdraw(1, 1, 2);
        invariant_assetsBackedByExternalCashFlows();
        assertGt(handler.deposits(), 0);
        assertGt(handler.withdrawals(), 0);
        assertGt(handler.trades(), 0);
        assertGt(handler.sampleCount(), 0);
        assertGt(handler.roundTrips(), 0);
        afterInvariant();
    }
}

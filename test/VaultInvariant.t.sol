// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {SigmaHook} from "../src/SigmaHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BandMath} from "src/libraries/BandMath.sol";

interface ITradeDriver {
    function trade(int24 target) external;
    function rebalance() external;
}

contract VaultHandler is Test {
    SigmaHook public immutable hook;
    ITradeDriver private immutable driver;
    address private immutable alice;
    address private immutable bob;
    address private immutable owner;
    PoolKey private key;

    constructor(SigmaHook hook_, address alice_, address bob_, address owner_) {
        hook = hook_;
        driver = ITradeDriver(msg.sender);
        alice = alice_;
        bob = bob_;
        owner = owner_;
        key = hook_.poolKey();
    }

    function deposit(uint64 a0, uint64 a1, bool asBob) external {
        if (hook.emergencyMode()) return;
        uint256 max0 = bound(a0, 1e6, 1 ether);
        uint256 max1 = bound(a1, 1e6, 1 ether);
        (uint256 quote,,) = hook.previewDeposit(max0, max1);
        if (quote == 0) return;
        address actor = asBob ? bob : alice;
        vm.prank(actor);
        hook.deposit(max0, max1, quote, actor, block.timestamp);
    }

    function withdraw(uint256 seed, bool asBob) external {
        address actor = asBob ? bob : alice;
        uint256 balance = hook.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = bound(seed, 1, balance);
        bool inEmergency = hook.emergencyMode();
        vm.prank(actor);
        if (inEmergency) hook.emergencyWithdraw(shares, actor);
        else hook.withdraw(shares, 0, 0, actor, block.timestamp);
    }

    function trade(int24 seed) external {
        driver.trade(int24(bound(seed, -500, 500)));
    }

    function rebalance() external {
        driver.rebalance();
    }

    function donate(uint64 a0, uint64 a1) external {
        vm.startPrank(alice);
        IERC20(Currency.unwrap(key.currency0)).transfer(address(hook), bound(a0, 0, 0.1 ether));
        IERC20(Currency.unwrap(key.currency1)).transfer(address(hook), bound(a1, 0, 0.1 ether));
        vm.stopPrank();
    }

    function transferShares(uint256 seed, bool fromBob) external {
        address from = fromBob ? bob : alice;
        uint256 balance = hook.balanceOf(from);
        if (balance == 0) return;
        uint256 shares = bound(seed, 0, balance);
        vm.prank(from);
        hook.transfer(fromBob ? alice : bob, shares);
    }

    function advanceTime(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 hours));
    }

    function emergency(uint8 seed) external {
        if (seed % 16 != 0 || hook.emergencyMode()) return;
        vm.prank(owner);
        hook.activateEmergencyMode();
    }
}

contract VaultInvariantTest is Fixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    VaultHandler private handler;

    function setUp() public {
        _setup(false);
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        handler = new VaultHandler(hook, alice, bob, owner);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.trade.selector;
        selectors[3] = VaultHandler.donate.selector;
        selectors[4] = VaultHandler.transferShares.selector;
        selectors[5] = VaultHandler.advanceTime.selector;
        selectors[6] = VaultHandler.emergency.selector;
        selectors[7] = VaultHandler.rebalance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function trade(int24 target) external {
        require(msg.sender == address(handler));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        if (price != limit) router.swap(key, limit < price, -int256(10_000 ether), limit);
    }

    function rebalance() external {
        require(msg.sender == address(handler));
        if (hook.emergencyMode() || hook.totalSupply() <= hook.MINIMUM_SHARES()) return;
        if (block.timestamp < hook.lastRebalance() + hook.cooldown()) return;
        (, int24 tick,,) = manager.getSlot0(key.toId());
        (int256 sum, uint256 sigma8) = hook.moments();
        if (!BandMath.deviates(tick, sum, sigma8, hook.triggerSigma())) return;
        hook.flashRebalance(key);
    }

    function invariant_currencyAndShareConservation() public view {
        _assertConservation(IERC20(address(token)));
        _assertConservation(IERC20(address(weth)));
        assertEq(hook.balanceOf(alice) + hook.balanceOf(bob) + hook.balanceOf(address(hook)), hook.totalSupply());
        assertEq(hook.balanceOf(address(hook)), hook.MINIMUM_SHARES());
    }

    function invariant_positionAndFlashAccounting() public view {
        _assertPositionMatches();
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertLt(hook.tickLower(), hook.tickUpper());
        assertEq(hook.tickLower() % 60, 0);
        assertEq(hook.tickUpper() % 60, 0);
        assertLt(hook.nextSample(), 8);
        if (hook.emergencyMode()) {
            assertEq(hook.liquidity(), 0);
            assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
            assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        }
    }

    /// @dev Every randomized sequence must still permit full emergency exits for both holders.
    function afterInvariant() public {
        if (!hook.emergencyMode()) {
            vm.prank(owner);
            hook.activateEmergencyMode();
        }
        if (hook.balanceOf(alice) != 0) {
            vm.prank(alice);
            hook.emergencyWithdraw();
        }
        if (hook.balanceOf(bob) != 0) {
            vm.prank(bob);
            hook.emergencyWithdraw();
        }
        assertEq(hook.totalSupply(), hook.MINIMUM_SHARES());
        assertEq(hook.liquidity(), 0);
        invariant_currencyAndShareConservation();
        invariant_positionAndFlashAccounting();
    }

    function _assertConservation(IERC20 asset) private view {
        uint256 balances = asset.balanceOf(address(this)) + asset.balanceOf(alice) + asset.balanceOf(bob)
            + asset.balanceOf(address(manager)) + asset.balanceOf(address(hook)) + asset.balanceOf(address(router))
            + asset.balanceOf(hook.burnSink());
        assertEq(balances, asset.totalSupply());
    }
}

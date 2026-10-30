// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {SigmaHook} from "src/SigmaHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract VaultFailurePathsTest is Fixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setup(false);
    }

    function test_secondTokenPullFailureRestoresHarvestMintAndFirstTokenPull() public {
        _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 1 ether, 2 ether);
        IERC20 second = IERC20(Currency.unwrap(key.currency1));
        vm.prank(bob);
        second.approve(address(hook), 0);
        (,, uint256 needed1) = hook.previewDeposit(3 ether, 3 ether);
        bytes32 beforeState = _state();
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, needed1)
        );
        hook.deposit(3 ether, 3 ether, 1, bob, block.timestamp);
        assertEq(_state(), beforeState, "failed pull left fees, shares, allowance, or balances changed");
        // The same vault remains usable, including its unlock/reentrancy guards.
        vm.prank(bob);
        second.approve(address(hook), 3 ether);
        assertGt(_deposit(bob, 3 ether, 3 ether), 0);
    }

    function test_minSharesFailureAfterHarvestRestoresUncollectedFees() public {
        _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 2 ether, 1 ether);
        (uint256 quote,,) = hook.previewDeposit(1 ether, 1 ether);
        bytes32 beforeState = _state();
        vm.prank(bob);
        vm.expectRevert(SigmaHook.Slippage.selector);
        hook.deposit(1 ether, 1 ether, quote + 1, bob, block.timestamp);
        assertEq(_state(), beforeState, "slippage failure committed the fee harvest");
        assertEq(_deposit(bob, 1 ether, 1 ether), quote);
    }

    function test_secondCurrencyWithdrawalMinimumRollsBackBurnAndPosition() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 2 ether, 3 ether);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(SigmaHook.Slippage.selector);
        hook.withdraw(shares, 0, 14 ether, bob, block.timestamp);
        assertEq(_state(), beforeState, "withdrawal slippage did not restore the position and shares");
        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = hook.withdraw(shares, 11 ether, 12 ether, bob, block.timestamp);
        assertGt(amount0, 11 ether);
        assertGt(amount1, 12 ether);
        assertEq(hook.balanceOf(alice), 0);
    }

    function test_budgetAboveInt128LimitCannotHarvestFeesOrPullTokens() public {
        _deposit(alice, 10 ether, 10 ether);
        router.donate(key, 1 ether, 1 ether);
        uint256 tooMuch = uint256(uint128(type(int128).max)) + 1;
        bytes32 beforeState = _state();
        for (uint256 side; side < 2; ++side) {
            uint256 max0 = side == 0 ? tooMuch : 1 ether;
            uint256 max1 = side == 1 ? tooMuch : 1 ether;
            vm.expectRevert(SigmaHook.InvalidAmount.selector);
            hook.previewDeposit(max0, max1);
            vm.prank(bob);
            vm.expectRevert(SigmaHook.InvalidAmount.selector);
            hook.deposit(max0, max1, 1, bob, block.timestamp);
            assertEq(_state(), beforeState);
        }
    }

    function test_invalidReceiversAreAtomicInLiveAndEmergencyModes() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        address[2] memory receivers = [address(0), address(hook)];
        bytes32 beforeState = _state();
        for (uint256 i; i < receivers.length; ++i) {
            vm.startPrank(alice);
            vm.expectRevert(SigmaHook.InvalidAddress.selector);
            hook.deposit(1 ether, 1 ether, 1, receivers[i], block.timestamp);
            vm.expectRevert(SigmaHook.InvalidAddress.selector);
            hook.withdraw(shares, 0, 0, receivers[i], block.timestamp);
            vm.stopPrank();
            assertEq(_state(), beforeState);
        }
        vm.prank(owner);
        hook.activateEmergencyMode();
        beforeState = _state();
        for (uint256 i; i < receivers.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(SigmaHook.InvalidAddress.selector);
            hook.emergencyWithdraw(shares, receivers[i]);
            assertEq(_state(), beforeState);
        }
    }

    function test_emergencyCannotBeUsedBeforeActivationAndLiveEntrypointsCloseAfterward() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        bytes32 beforeState = _state();
        vm.startPrank(alice);
        vm.expectRevert(SigmaHook.EmergencyInactive.selector);
        hook.emergencyWithdraw(shares, bob);
        vm.expectRevert(SigmaHook.EmergencyInactive.selector);
        hook.emergencyWithdraw();
        vm.stopPrank();
        assertEq(_state(), beforeState);
        vm.prank(owner);
        hook.activateEmergencyMode();
        beforeState = _state();
        vm.startPrank(alice);
        vm.expectRevert(SigmaHook.EmergencyActive.selector);
        hook.withdraw(shares, 0, 0, alice, block.timestamp);
        vm.expectRevert(SigmaHook.EmergencyActive.selector);
        hook.deposit(1 ether, 1 ether, 1, alice, block.timestamp);
        vm.expectRevert(SigmaHook.EmergencyActive.selector);
        hook.previewDeposit(1 ether, 1 ether);
        vm.expectRevert(SigmaHook.InvalidAmount.selector);
        hook.emergencyWithdraw(0, alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, shares, shares + 1)
        );
        hook.emergencyWithdraw(shares + 1, alice);
        vm.stopPrank();
        assertEq(_state(), beforeState);
    }

    function test_pendingAndFormerOwnerCannotActivateEmergency() public {
        _deposit(alice, 10 ether, 10 ether);
        vm.prank(owner);
        hook.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        hook.activateEmergencyMode();
        assertFalse(hook.emergencyMode());
        vm.prank(bob);
        hook.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.activateEmergencyMode();
        vm.prank(bob);
        hook.activateEmergencyMode();
        assertTrue(hook.emergencyMode());
        assertEq(hook.liquidity(), 0);
    }

    function test_invalidPoolAttemptsDoNotPoisonLaterValidInitialization() public {
        SigmaHook unbound = _deployHook(address(token));
        PoolKey memory candidate = key;
        candidate.hooks = IHooks(address(unbound));
        candidate.tickSpacing = 1;
        _rejectInitialization(unbound, candidate, SigmaHook.InvalidPool.selector);
        candidate.tickSpacing = 60;
        candidate.fee = 3_000;
        _rejectInitialization(unbound, candidate, SigmaHook.InvalidPool.selector);
        candidate.fee = 12_500;

        MockERC20 other = new MockERC20("Other", "OTHER");
        (address a, address b) =
            address(other) < address(weth) ? (address(other), address(weth)) : (address(weth), address(other));
        PoolKey memory wrongPair = PoolKey(Currency.wrap(a), Currency.wrap(b), 12_500, 60, IHooks(address(unbound)));
        _rejectInitialization(unbound, wrongPair, SigmaHook.InvalidPool.selector);

        address noCode = makeAddr("not-an-erc20");
        (a, b) = address(token) < noCode ? (address(token), noCode) : (noCode, address(token));
        wrongPair = PoolKey(Currency.wrap(a), Currency.wrap(b), 12_500, 60, IHooks(address(unbound)));
        _rejectInitialization(unbound, wrongPair, SigmaHook.UnsupportedToken.selector);

        manager.initialize(candidate, TickMath.getSqrtPriceAtTick(127));
        assertTrue(unbound.initialized());
        for (uint256 i; i < 8; ++i) {
            assertEq(unbound.ticks(i), 127);
        }
        assertEq(unbound.tickLower(), 120);
        assertEq(unbound.tickUpper(), 180);
    }

    function test_allUninitializedVaultEntrypointsRefuseBeforeTokenTransfers() public {
        SigmaHook unbound = _deployHook(address(token));
        vm.expectRevert(SigmaHook.NotInitialized.selector);
        unbound.previewDeposit(1 ether, 1 ether);
        vm.expectRevert(SigmaHook.NotInitialized.selector);
        unbound.proposedBands();
        vm.prank(alice);
        vm.expectRevert(SigmaHook.NotInitialized.selector);
        unbound.withdraw(1, 0, 0, alice, block.timestamp);
        vm.prank(owner);
        vm.expectRevert(SigmaHook.NotInitialized.selector);
        unbound.activateEmergencyMode();
        vm.expectRevert(SigmaHook.EmergencyInactive.selector);
        unbound.emergencyWithdraw();
        assertFalse(unbound.initialized());
        assertFalse(unbound.emergencyMode());
        assertEq(unbound.totalSupply(), 0);
    }

    function _rejectInitialization(SigmaHook unbound, PoolKey memory candidate, bytes4 innerError) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(unbound),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(innerError),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(candidate, 1 << 96);
        assertFalse(unbound.initialized());
        assertEq(unbound.lastRebalance(), 0);
        (uint160 price,,,) = manager.getSlot0(candidate.toId());
        assertEq(price, 0, "failed initialization persisted pool state");
    }

    function _state() private view returns (bytes32) {
        (uint128 position, uint256 last0, uint256 last1) =
            manager.getPositionInfo(key.toId(), address(hook), hook.tickLower(), hook.tickUpper(), hook.POSITION_SALT());
        (uint256 assets0, uint256 assets1) = hook.totalAssets();
        return keccak256(
            abi.encode(
                hook.totalSupply(),
                hook.balanceOf(alice),
                hook.balanceOf(bob),
                hook.balanceOf(address(hook)),
                hook.liquidity(),
                position,
                last0,
                last1,
                assets0,
                assets1,
                hook.emergencyMode(),
                _currencyState(key.currency0),
                _currencyState(key.currency1)
            )
        );
    }

    function _currencyState(Currency currency) private view returns (bytes32) {
        IERC20 asset = IERC20(Currency.unwrap(currency));
        return keccak256(
            abi.encode(
                asset.balanceOf(alice),
                asset.balanceOf(bob),
                asset.balanceOf(address(hook)),
                asset.balanceOf(address(manager)),
                asset.allowance(alice, address(hook)),
                asset.allowance(bob, address(hook)),
                manager.balanceOf(address(hook), currency.toId())
            )
        );
    }
}

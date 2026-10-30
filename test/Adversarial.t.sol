// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {TaxToken, MockERC20} from "./helpers/MockERC20.sol";
import {SigmaHook} from "../src/SigmaHook.sol";
import {MineSalt} from "../script/MineSalt.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CallbackToken is MockERC20 {
    SigmaHook public target;
    bool public attempted;
    bool public succeeded;
    bytes4 public refusal;

    constructor() MockERC20("Callback", "CALL") {}

    function setTarget(SigmaHook hook) external {
        target = hook;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        attempted = true;
        (bool ok, bytes memory reason) =
            address(target).call(abi.encodeCall(target.deposit, (1, 1, 1, address(this), block.timestamp)));
        succeeded = ok;
        refusal = bytes4(reason);
        return super.transferFrom(from, to, value);
    }
}

/// @dev A router that pays its input before the swap: sync, transfer, swap, settle. Valid in v4, and
/// broken by any hook that syncs a currency of its own inside afterSwap.
contract PrepayRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) external {
        manager.unlock(abi.encode(key, zeroForOne, amountIn, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        manager.sync(input);
        input.transfer(address(manager), amountIn);
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        uint256 paid = manager.settle();
        require(paid == amountIn, "prepayment lost");
        int128 owed = zeroForOne ? delta.amount0() : delta.amount1();
        if (uint256(uint128(-owed)) < amountIn) manager.take(input, address(this), amountIn - uint256(uint128(-owed)));
        int128 received = zeroForOne ? delta.amount1() : delta.amount0();
        if (received > 0) manager.take(output, address(this), uint128(received));
        return "";
    }
}

contract AdversarialTest is Fixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function setUp() public {
        _setup(false);
    }

    function _bindPair(address a, address b, int24 tick) internal returns (SigmaHook other, PoolKey memory otherKey) {
        other = _deployHook(a);
        if (a > b) (a, b) = (b, a);
        otherKey = PoolKey(Currency.wrap(a), Currency.wrap(b), 12_500, 60, IHooks(address(other)));
        manager.initialize(otherKey, TickMath.getSqrtPriceAtTick(tick));
    }

    function test_feeOnTransferDepositIsRejectedAtomically() public {
        TaxToken tax = new TaxToken();
        (SigmaHook other,) = _bindPair(address(tax), address(weth), 0);
        tax.mint(alice, 10 ether);
        vm.startPrank(alice);
        tax.approve(address(other), 10 ether);
        weth.approve(address(other), 10 ether);
        vm.expectRevert(SigmaHook.UnsupportedToken.selector);
        other.deposit(10 ether, 10 ether, 1, alice, block.timestamp);
        vm.stopPrank();
        assertEq(tax.balanceOf(alice), 10 ether);
        assertEq(tax.balanceOf(address(other)), 0);
        assertEq(weth.balanceOf(address(other)), 0);
        assertEq(other.totalSupply(), 0);
        assertEq(other.liquidity(), 0);
    }

    function test_tokenCallbackCannotReenterDeposit() public {
        CallbackToken callbackToken = new CallbackToken();
        (SigmaHook other,) = _bindPair(address(callbackToken), address(weth), 0);
        callbackToken.setTarget(other);
        callbackToken.mint(alice, 10 ether);
        vm.startPrank(alice);
        callbackToken.approve(address(other), 10 ether);
        weth.approve(address(other), 10 ether);
        other.deposit(10 ether, 10 ether, 1, alice, block.timestamp);
        vm.stopPrank();
        assertTrue(callbackToken.attempted());
        assertFalse(callbackToken.succeeded());
        assertEq(callbackToken.refusal(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertGt(other.balanceOf(alice), 0);
        assertEq(other.balanceOf(address(callbackToken)), 0);
    }

    function test_liquidityCapacityCannotBlockSwapRebalance() public {
        _deposit(alice, 10 ether, 10 ether);
        uint128 ownLiquidity = hook.liquidity();
        uint128 maxPerTick = Pool.tickSpacingToMaxLiquidityPerTick(60);
        deal(Currency.unwrap(key.currency0), address(router), 1e35);
        deal(Currency.unwrap(key.currency1), address(router), 1e35);
        router.modify(key, -60, 60, int256(uint256(maxPerTick - ownLiquidity)));
        _deposit(bob, 10 ether, 10 ether);
        assertEq(hook.liquidity(), ownLiquidity);
        assertGt(_balance(key.currency0, address(hook)), 0);
        vm.warp(hook.lastRebalance() + 30 minutes);
        router.swap(key, false, -int256(1e35), TickMath.getSqrtPriceAtTick(20));
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
        assertLe(hook.liquidity(), ownLiquidity);
        assertTrue(router.hookDeltasWereZero());
        _assertPositionMatches();
    }

    function test_initializationAtPriceExtremesAndSingleSidedDeposits() public {
        for (uint256 i; i < 2; ++i) {
            int24 initialTick = i == 0 ? TickMath.MIN_TICK : TickMath.MAX_TICK - 1;
            (SigmaHook other, PoolKey memory otherKey) = _bindPair(address(token), address(weth), initialTick);
            uint256 amount0 = i == 0 ? 1_000 ether : 0;
            uint256 amount1 = i == 0 ? 0 : 1_000 ether;
            vm.startPrank(alice);
            token.approve(address(other), 1_000 ether);
            weth.approve(address(other), 1_000 ether);
            (uint256 shares,,) = other.deposit(amount0, amount1, 1, alice, block.timestamp);
            vm.stopPrank();
            assertGt(shares, 0);
            assertGt(other.liquidity(), 0);
            assertEq(other.tickLower() % 60, 0);
            assertEq(other.tickUpper() % 60, 0);
            vm.prank(owner);
            other.activateEmergencyMode();
            vm.prank(alice);
            (uint256 received0, uint256 received1) = other.emergencyWithdraw();
            assertLe(received0, amount0);
            assertLe(received1, amount1);
            assertEq(manager.currencyDelta(address(other), otherKey.currency0), 0);
            assertEq(manager.currencyDelta(address(other), otherKey.currency1), 0);
        }
    }

    /// A rebalance inside a prepaying router's unlock must not sync: it pays from claims only and
    /// leaves raw dust for a cycle opened by a router that pays afterwards.
    function test_prepayRouterSwapSurvivesARebalance() public {
        _seedBackground();
        _deposit(alice, 10 ether, 10 ether);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(key.currency0)).transfer(address(hook), 1 ether);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(hook), 1 ether);
        vm.stopPrank();
        PrepayRouter prepay = new PrepayRouter(manager);
        token.transfer(address(prepay), 100 ether);
        weth.mint(address(prepay), 100 ether);
        vm.warp(hook.lastRebalance() + 30 minutes);
        prepay.swapExactIn(key, true, 5 ether, TickMath.getSqrtPriceAtTick(-600));
        assertLt(hook.lastRebalance(), block.timestamp);
        assertGt(hook.liquidity(), 0);
        assertEq(_balance(key.currency0, address(hook)), 1 ether, "raw dust untouched by a claims-only cycle");
        assertEq(_balance(key.currency1, address(hook)), 1 ether);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        // The next cycle, opened by a router that pays after the swap, deploys the dust too.
        vm.warp(hook.lastRebalance() + 30 minutes);
        _moveTo(600);
        hook.flashRebalance(key);
        assertEq(hook.lastRebalance(), block.timestamp);
        assertLt(_balance(key.currency0, address(hook)) + _balance(key.currency1, address(hook)), 2 ether);
        assertTrue(router.hookDeltasWereZero());
    }

    function test_emptyVaultCanEnterEmergency() public {
        vm.prank(owner);
        hook.activateEmergencyMode();
        assertTrue(hook.emergencyMode());
        vm.prank(alice);
        vm.expectRevert(SigmaHook.InvalidAmount.selector);
        hook.emergencyWithdraw();
    }

    function test_emergencyCannotBurnOtherHoldersShares() public {
        uint256 shares = _deposit(alice, 10 ether, 10 ether);
        vm.prank(owner);
        hook.activateEmergencyMode();
        vm.prank(bob);
        vm.expectRevert();
        hook.emergencyWithdraw(shares, bob);
        assertEq(hook.balanceOf(alice), shares);
        assertEq(hook.balanceOf(address(hook)), hook.MINIMUM_SHARES());
        vm.prank(owner);
        vm.expectRevert();
        hook.emergencyWithdraw(shares, owner);
    }

    function test_saltToolUsesExactFactoryAndConstructorArguments() public {
        MineSalt miner = MineSalt(deployCode("MineSalt.s.sol:MineSalt"));
        address newOwner = makeAddr("newOwner");
        (bytes32 salt, address predicted) =
            miner.run(address(this), manager, newOwner, address(token), address(this), 0, 200_000);
        SigmaHook deployed = _createHook(
            bytes.concat(
                vm.getCode("SigmaHook.sol:SigmaHook"), abi.encode(manager, newOwner, address(token), address(this))
            ),
            salt
        );
        assertEq(address(deployed), predicted);
        assertEq(deployed.owner(), newOwner);
        vm.expectRevert(MineSalt.SearchExhausted.selector);
        miner.run(address(this), manager, newOwner, address(token), address(this), 0, 0);
    }
}

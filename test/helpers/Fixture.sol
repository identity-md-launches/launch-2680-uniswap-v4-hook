// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SigmaHook} from "../../src/SigmaHook.sol";
import {SigmaToken} from "../../src/SigmaToken.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "./MockERC20.sol";
import {TestRouter} from "./TestRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract Fixture is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    SigmaHook internal hook;
    SigmaToken internal token;
    MockERC20 internal weth;
    TestRouter internal router;
    PoolKey internal key;
    address internal alice;
    address internal bob;
    address internal owner;

    function _setup(bool nativePair) internal {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        owner = makeAddr("owner");
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(owner)));
        token = new SigmaToken();
        weth = new MockERC20("Wrapped Ether", "WETH");
        hook = _deployHook(address(token));
        address paired = nativePair ? address(0) : address(weth);
        (address a, address b) = address(token) < paired ? (address(token), paired) : (paired, address(token));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, 1 << 96);
        router = new TestRouter(manager);
        token.transfer(address(router), 1_000_000 ether);
        weth.mint(address(router), 1_000_000 ether);
        vm.deal(address(router), 1_000_000 ether);
        _fundAndApprove(alice);
        _fundAndApprove(bob);
        vm.deal(address(this), 1_000_000 ether);
    }

    function _deployHook(address launchToken) internal returns (SigmaHook deployed) {
        bytes memory initCode =
            bytes.concat(vm.getCode("SigmaHook.sol:SigmaHook"), abi.encode(manager, owner, launchToken, address(this)));
        bytes32 hash = keccak256(initCode);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (!HookFlags.matches(predicted, HookFlags.SIGMA) || predicted.code.length != 0) continue;
            deployed = _createHook(initCode, salt);
            assertEq(address(deployed), predicted);
            return deployed;
        }
        revert("salt search exhausted");
    }

    function _createHook(bytes memory initCode, bytes32 salt) internal returns (SigmaHook deployed) {
        address target;
        assembly ("memory-safe") {
            target := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(target != address(0), "hook deployment failed");
        return SigmaHook(payable(target));
    }

    function _fundAndApprove(address who) internal {
        token.transfer(who, 100_000 ether);
        weth.mint(who, 100_000 ether);
        vm.deal(who, 100_000 ether);
        vm.startPrank(who);
        token.approve(address(hook), 100_000 ether);
        weth.approve(address(hook), 100_000 ether);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount0, uint256 amount1) internal returns (uint256 shares) {
        vm.prank(who);
        (shares,,) =
            hook.deposit{value: key.currency0.isAddressZero() ? amount0 : 0}(amount0, amount1, 1, who, block.timestamp);
    }

    function _seedBackground() internal {
        router.modify(key, -887220, 887220, 1_000 ether);
    }

    function _moveTo(int24 target) internal returns (BalanceDelta delta) {
        (uint160 current,,,) = manager.getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        require(limit != current, "target already reached");
        delta = router.swap(key, limit < current, -int256(10_000 ether), limit);
    }

    function _assertPositionMatches() internal view {
        (uint128 actual,,) =
            manager.getPositionInfo(key.toId(), address(hook), hook.tickLower(), hook.tickUpper(), hook.POSITION_SALT());
        assertEq(actual, hook.liquidity());
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        return currency.balanceOf(account);
    }

    receive() external payable {}
}

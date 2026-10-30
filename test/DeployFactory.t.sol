// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SSTORE2} from "solmate/src/utils/SSTORE2.sol";
import {DeployFactory, ICreatePoolManager} from "../src/DeployFactory.sol";
import {SigmaHook} from "../src/SigmaHook.sol";
import {MineSalt} from "../script/MineSalt.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CreatePoolManagerHarness} from "./helpers/CreatePoolManagerHarness.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract DeployFactoryTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant EOA = 0xdbeab8243F318F1bBF815d85a8A869def1510b61;
    address internal constant FACTORY = 0x44aa80c4F3807C0b5A2c880158E0141A9553e199;
    address internal constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant TOKEN = 0x4fE865Ad3b3eF64B2af9C38c78aBf5C6e68C1164;
    bytes32 internal constant SALT = bytes32(uint256(0x1762c));
    address internal constant HOOK = 0xB259cb6965FD49df82a415920Ac61DF370cB1040;
    bytes32 internal constant INIT_HASH = 0xd09c16e2448f647d24add8afafe9f5e94196ab26a56d0592ff129a016827aa3c;

    DeployFactory internal factory;
    MineSalt internal miner;

    function setUp() public {
        miner = MineSalt(deployCode("MineSalt.s.sol:MineSalt"));
        bytes memory code = vm.getCode("DeployFactory.sol:DeployFactory");
        vm.setNonce(EOA, 2);
        vm.prank(EOA);
        // Real CREATE with the EOA's nonce; the factory and its immutable stores are never etched.
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "factory CREATE failed");
        factory = DeployFactory(deployed);
    }

    function test_nonceTwoCreateMatchesRlpAndAssignsExplicitOwner() public view {
        bytes memory rlp = abi.encodePacked(hex"d694", EOA, hex"02");
        assertEq(rlp.length, 23);
        assertEq(address(uint160(uint256(keccak256(rlp)))), FACTORY);
        assertEq(vm.computeCreateAddress(EOA, 2), FACTORY);
        assertEq(address(factory), FACTORY);
        assertEq(factory.owner(), EOA);
        assertEq(vm.getNonce(EOA), 3);
        assertEq(miner.factoryAddress(), FACTORY);
    }

    function test_ownerIsExplicitEvenWhenSomeoneElseCreatesFactory() public {
        DeployFactory other = DeployFactory(deployCode("DeployFactory.sol:DeployFactory"));
        assertEq(other.owner(), EOA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        other.deployHook(SALT, MANAGER, EOA, TOKEN);
    }

    function test_factoryAndCodeStoresFitDeploymentLimitsAndPreserveExactInitCode() public view {
        bytes memory creation = vm.getCode("SigmaHook.sol:SigmaHook");
        bytes memory stored = bytes.concat(SSTORE2.read(factory.codePart0()), SSTORE2.read(factory.codePart1()));
        assertEq(stored, creation, "full byte-for-byte reconstruction");
        assertGt(creation.length, 24_576, "direct embedding would exceed EIP-170");
        assertLe(address(factory).code.length, 24_576);
        assertLe(vm.getCode("DeployFactory.sol:DeployFactory").length, 49_152);
        assertLe(creation.length + 128, 49_152);
        assertLe(factory.codePart0().code.length, 24_576);
        assertLe(factory.codePart1().code.length, 24_576);
        assertEq(uint8(factory.codePart0().code[0]), 0);
        assertEq(uint8(factory.codePart1().code[0]), 0);
        assertEq(keccak256(bytes.concat(stored, abi.encode(MANAGER, EOA, TOKEN, FACTORY))), INIT_HASH);
    }

    function test_recordedSaltDeploysRealHookFromRealFactory() public {
        vm.expectEmit(true, true, true, true, FACTORY);
        emit DeployFactory.HookDeployed(HOOK, SALT, EOA, MANAGER, TOKEN);
        SigmaHook hook = _recordedHook();
        assertEq(address(hook), HOOK);
        assertEq(vm.computeCreate2Address(SALT, INIT_HASH, FACTORY), HOOK);
        assertEq(uint160(address(hook)) & 0xFFFF, 0x1040);
        assertEq(hook.owner(), EOA);
        assertEq(hook.factory(), FACTORY);
        assertEq(address(hook.poolManager()), MANAGER);
        assertEq(hook.launchToken(), TOKEN);
        assertFalse(hook.initialized());
        assertTrue(factory.isHook(HOOK));
        assertLe(HOOK.code.length, 24_576);
        assertGt(address(hook.math()).code.length, 0);
        assertGt(hook.burnSink().code.length, 0);
        Hooks.validateHookPermissions(IHooks(HOOK), hook.getHookPermissions());
    }

    function test_duplicateSaltRevertsWithoutChangingExistingHook() public {
        SigmaHook hook = _recordedHook();
        bytes32 codeHash = HOOK.codehash;
        vm.expectRevert(DeployFactory.HookDeploymentFailed.selector);
        vm.prank(EOA);
        factory.deployHook{gas: 12_000_000}(SALT, MANAGER, EOA, TOKEN);
        assertEq(HOOK.codehash, codeHash);
        assertEq(hook.owner(), EOA);
        assertTrue(factory.isHook(HOOK));
    }

    function test_unminedSaltBubblesHookPermissionFailureAndCanRetry() public {
        bytes32 invalidSalt;
        address predicted = miner.predict(FACTORY, invalidSalt, INIT_HASH);
        assertTrue((uint160(predicted) & Hooks.ALL_HOOK_MASK) != 0x1040);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        vm.prank(EOA);
        factory.deployHook(invalidSalt, MANAGER, EOA, TOKEN);
        assertEq(predicted.code.length, 0);
        assertFalse(factory.isHook(predicted));
        assertEq(address(_recordedHook()), HOOK);
    }

    function test_zeroConstructorArgumentsRevertEvenWithMinedSalts() public {
        _invalidArguments(address(0), EOA, TOKEN, abi.encodeWithSelector(SigmaHook.InvalidAddress.selector));
        _invalidArguments(MANAGER, EOA, address(0), abi.encodeWithSelector(SigmaHook.InvalidAddress.selector));
        _invalidArguments(
            MANAGER, address(0), TOKEN, abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0))
        );
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_onlyOwnerCanDeployOrCreatePool(address caller) public {
        vm.assume(caller != EOA);
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.expectRevert(unauthorized);
        vm.prank(caller);
        factory.deployHook(SALT, MANAGER, EOA, TOKEN);
        vm.expectRevert(unauthorized);
        vm.prank(caller);
        factory.createPool(HOOK, address(0), TOKEN);
        assertEq(HOOK.code.length, 0);
    }

    function test_onlyFactoryOwnerCanTransferOwnershipAndZeroNewOwnerRejected() public {
        address nextOwner = makeAddr("factoryOwner");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.transferOwnership(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        vm.prank(EOA);
        factory.transferOwnership(address(0));
        vm.prank(EOA);
        factory.transferOwnership(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, EOA));
        vm.prank(EOA);
        factory.deployHook(SALT, MANAGER, EOA, TOKEN);
        vm.prank(nextOwner);
        address deployed = factory.deployHook(SALT, MANAGER, EOA, TOKEN);
        assertEq(deployed, HOOK);
        assertEq(SigmaHook(payable(deployed)).owner(), EOA, "factory and hook ownership are independent");
    }

    function test_createPoolForwardsExactKeyAndFactorySenderToHooksManager() public {
        (SigmaHook hook, CreatePoolManagerHarness manager, MockERC20 token) = _localHook();
        PoolKey memory expected = _key(hook, address(token));
        vm.expectCall(address(manager), abi.encodeCall(ICreatePoolManager.createPool, (expected)));
        vm.expectEmit(true, false, false, true, FACTORY);
        emit DeployFactory.PoolCreated(address(hook), address(0), address(token));
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        assertTrue(hook.initialized());
        assertEq(abi.encode(hook.poolKey()), abi.encode(expected));
        assertEq(manager.lastSender(), FACTORY);
        assertEq(manager.calls(), 1);
        (uint160 price,,, uint24 fee) = IPoolManager(address(manager)).getSlot0(expected.toId());
        assertEq(price, 1 << 96);
        assertEq(fee, 12_500);
    }

    function test_fullSequenceFirstNativeDepositStandardModeAndExit() public {
        (SigmaHook hook,, MockERC20 token) = _localHook();
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        token.mint(EOA, 2 ether);
        vm.deal(EOA, 2 ether);
        (uint256 quoted,,) = hook.previewDeposit(1 ether, 1 ether);
        assertGt(quoted, 0);
        vm.startPrank(EOA);
        token.approve(address(hook), 1 ether);
        (uint256 shares, uint256 used0, uint256 used1) =
            hook.deposit{value: 1 ether}(1 ether, 1 ether, quoted, EOA, block.timestamp + 60);
        assertEq(hook.balanceOf(EOA), shares);
        assertEq(shares, quoted);
        assertGt(hook.liquidity(), 0);
        assertEq(EOA.balance, 2 ether - used0);
        assertEq(token.balanceOf(EOA), 2 ether - used1);
        hook.setMode(1);
        assertEq(hook.triggerSigma(), 15);
        assertEq(hook.rangeSigma(), 20);
        assertEq(hook.cooldown(), 1800);
        hook.withdraw(shares, 1, 1, EOA, block.timestamp + 60);
        vm.stopPrank();
        assertEq(hook.balanceOf(EOA), 0);
        assertEq(address(factory).balance, 0);
        assertEq(token.balanceOf(FACTORY), 0);
    }

    function test_createPoolRejectsUnknownHooks() public {
        vm.expectRevert(DeployFactory.UnknownHook.selector);
        vm.prank(EOA);
        factory.createPool(HOOK, address(0), TOKEN);
    }

    function test_createPoolRejectsInvalidCurrencyOrderEqualCurrenciesAndMissingToken() public {
        (SigmaHook hook, CreatePoolManagerHarness manager, MockERC20 token) = _localHook();
        vm.startPrank(EOA);
        vm.expectRevert(DeployFactory.InvalidCurrencies.selector);
        factory.createPool(address(hook), address(token), address(0));
        vm.expectRevert(DeployFactory.InvalidCurrencies.selector);
        factory.createPool(address(hook), address(token), address(token));
        vm.expectRevert(DeployFactory.InvalidCurrencies.selector);
        factory.createPool(address(hook), address(0), TOKEN);
        vm.stopPrank();
        assertEq(manager.calls(), 0);
        assertFalse(hook.initialized());
    }

    function test_createPoolCannotRebindInitializedHook() public {
        (SigmaHook hook, CreatePoolManagerHarness manager, MockERC20 token) = _localHook();
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        bytes32 pool = keccak256(abi.encode(hook.poolKey()));
        vm.expectRevert(SigmaHook.AlreadyInitialized.selector);
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        assertEq(manager.calls(), 1);
        assertEq(keccak256(abi.encode(hook.poolKey())), pool);
    }

    function test_managerFailureBubblesAndInitializationCanBeRetried() public {
        (SigmaHook hook, CreatePoolManagerHarness manager, MockERC20 token) = _localHook();
        manager.setBehavior(CreatePoolManagerHarness.Behavior.Revert);
        vm.expectRevert(CreatePoolManagerHarness.ManagerFailure.selector);
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        assertFalse(hook.initialized());
        assertEq(manager.calls(), 0, "manager state rolls back");
        manager.setBehavior(CreatePoolManagerHarness.Behavior.Initialize);
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        assertTrue(hook.initialized());
    }

    function test_noOpManagerCannotReportSuccessfulPoolCreation() public {
        (SigmaHook hook, CreatePoolManagerHarness manager, MockERC20 token) = _localHook();
        manager.setBehavior(CreatePoolManagerHarness.Behavior.NoOp);
        vm.expectRevert(DeployFactory.PoolNotInitialized.selector);
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        assertFalse(hook.initialized());
        assertEq(manager.calls(), 0);
    }

    function test_directManagerInitializationCannotBypassFactory() public {
        (SigmaHook hook, CreatePoolManagerHarness manager, MockERC20 token) = _localHook();
        PoolKey memory key = _key(hook, address(token));
        // Upstream Hooks wraps callback reverts. Failure must leave the hook and pool unbound.
        vm.expectRevert();
        vm.prank(EOA);
        manager.initialize(key, 1 << 96);
        assertFalse(hook.initialized());
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), address(token));
        assertTrue(hook.initialized());
    }

    function test_upstreamManagerWithoutCreatePoolRevertsRatherThanGuessingPrice() public {
        address manager = deployCode("PoolManager.sol:PoolManager", abi.encode(EOA));
        (bytes32 salt,) = _mine(manager, EOA, TOKEN);
        vm.prank(EOA);
        SigmaHook hook = SigmaHook(payable(factory.deployHook(salt, manager, EOA, TOKEN)));
        vm.expectRevert();
        vm.prank(EOA);
        factory.createPool(address(hook), address(0), TOKEN);
        assertFalse(hook.initialized());
    }

    function _recordedHook() internal returns (SigmaHook) {
        vm.prank(EOA);
        return SigmaHook(payable(factory.deployHook(SALT, MANAGER, EOA, TOKEN)));
    }

    function _mine(address manager, address owner_, address token) internal view returns (bytes32, address) {
        return miner.mine(FACTORY, miner.initCodeHash(IPoolManager(manager), owner_, token, FACTORY), 0, 1 << 22);
    }

    function _localHook() internal returns (SigmaHook hook, CreatePoolManagerHarness manager, MockERC20 token) {
        manager = CreatePoolManagerHarness(deployCode("CreatePoolManagerHarness.sol:CreatePoolManagerHarness"));
        token = new MockERC20("Local fixture token", "TEST");
        (bytes32 salt, address predicted) = _mine(address(manager), EOA, address(token));
        vm.prank(EOA);
        hook = SigmaHook(payable(factory.deployHook(salt, address(manager), EOA, address(token))));
        assertEq(address(hook), predicted);
    }

    function _invalidArguments(address manager, address owner_, address token, bytes memory reason) internal {
        (bytes32 salt, address predicted) = _mine(manager, owner_, token);
        vm.expectRevert(reason);
        vm.prank(EOA);
        factory.deployHook(salt, manager, owner_, token);
        assertEq(predicted.code.length, 0);
        assertFalse(factory.isHook(predicted));
    }

    function _key(SigmaHook hook, address token) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 12_500, 60, IHooks(address(hook)));
    }
}

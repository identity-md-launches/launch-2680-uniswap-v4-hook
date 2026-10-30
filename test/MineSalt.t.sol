// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {MineSalt} from "../script/MineSalt.s.sol";
import {SigmaHook} from "../src/SigmaHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Create2Factory} from "./helpers/Create2Factory.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice The salt tool is judged against the real artifact and a real CREATE2 from the brief's deployer.
contract MineSaltTest is Test {
    address internal constant BRIEF_DEPLOYER = 0x735121A546092F31050A867FD7E3A750C7B0EFF9;
    address internal constant BRIEF_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant BRIEF_TOKEN = 0x4fE865Ad3b3eF64B2af9C38c78aBf5C6e68C1164;
    /// @dev Hook owner the requester gave for the recorded search, and the three values it produced.
    address internal constant BRIEF_OWNER = 0xdbeab8243F318F1bBF815d85a8A869def1510b61;
    bytes32 internal constant BRIEF_SALT = bytes32(uint256(0x75db));
    address internal constant BRIEF_ADDRESS = 0x0E19960828C6f198713e97C0039D589a5b0f1040;
    bytes32 internal constant BRIEF_INIT_CODE_HASH = 0xad1d60e3f24ffe14b9ec5816c251dcdd918e6f52b5c441024b1b1f58ca49cb96;
    uint256 internal constant ATTEMPTS = 1 << 22;

    MineSalt internal miner;
    Create2Factory internal factoryAtDeployer;
    address internal owner;

    function setUp() public {
        miner = MineSalt(deployCode("MineSalt.s.sol:MineSalt"));
        owner = makeAddr("hookOwner");
        // Give the brief's deployer address real CREATE2 code so its deployments can be executed locally.
        vm.etch(BRIEF_DEPLOYER, address(new Create2Factory()).code);
        factoryAtDeployer = Create2Factory(BRIEF_DEPLOYER);
    }

    function _artifactInitCode(address manager, address owner_, address token, address factory)
        internal
        view
        returns (bytes memory)
    {
        return bytes.concat(vm.getCode("SigmaHook.sol:SigmaHook"), abi.encode(manager, owner_, token, factory));
    }

    function _suffix(address a) internal pure returns (uint160) {
        return uint160(a) & 0xFFFF;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    function test_constantsMatchBriefAndHookPermissions() public view {
        assertEq(miner.DEPLOYER(), BRIEF_DEPLOYER);
        assertEq(miner.OWNER(), BRIEF_OWNER);
        assertEq(miner.RECORDED_SALT(), BRIEF_SALT);
        assertEq(miner.RECORDED_ADDRESS(), BRIEF_ADDRESS);
        assertEq(miner.RECORDED_INIT_CODE_HASH(), BRIEF_INIT_CODE_HASH);
        assertEq(address(miner.POOL_MANAGER()), BRIEF_MANAGER);
        assertEq(miner.LAUNCH_TOKEN(), BRIEF_TOKEN);
        assertEq(miner.CHAIN_ID(), 4663);
        assertEq(miner.REQUIRED_SUFFIX(), 0x1040);
        assertEq(miner.REQUIRED_SUFFIX(), HookFlags.SIGMA);
        assertEq(HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP, 0x1040);
        assertEq(miner.SUFFIX_MASK(), 0xFFFF);
        assertEq(miner.DEFAULT_ATTEMPTS(), ATTEMPTS);
    }

    function test_suffixPredicateIsStricterThanV4Flags() public view {
        // Ends in 1040: accepted.
        assertTrue(miner.hasSuffix(address(uint160(0xAAAA0000) | 0x1040)));
        // Same 14 v4 flag bits but bit 14 set: v4 accepts, the brief's "ends in 0x1040" does not.
        address bit14 = address(uint160(0x5040));
        assertTrue(HookFlags.matches(bit14, HookFlags.SIGMA));
        assertFalse(miner.hasSuffix(bit14));
        assertFalse(miner.hasSuffix(address(uint160(0x9040))));
        // Wrong flags: rejected.
        assertFalse(miner.hasSuffix(address(uint160(0x1041))));
        assertFalse(miner.hasSuffix(address(uint160(0x1000))));
        assertFalse(miner.hasSuffix(address(uint160(0x0040))));
        assertFalse(miner.hasSuffix(address(0)));
    }

    // ---------------------------------------------------------------------------------------------
    // The recorded result for the requester's owner
    // ---------------------------------------------------------------------------------------------

    function test_runMinesRecordedSaltForRequesterOwner() public view {
        (bytes32 salt, address predicted) = miner.run();
        assertEq(salt, BRIEF_SALT, "SALT");
        assertEq(predicted, BRIEF_ADDRESS, "ADDRESS");
        assertEq(_suffix(predicted), 0x1040);
        (bytes32 salt2, address predicted2) = miner.mineFor(BRIEF_OWNER);
        assertEq(salt2, salt, "run() is mineFor(OWNER)");
        assertEq(predicted2, predicted);
    }

    function test_recordedInitCodeHashMatchesThisBuild() public view {
        bytes32 fromScript = miner.initCodeHash(IPoolManager(BRIEF_MANAGER), BRIEF_OWNER, BRIEF_TOKEN, BRIEF_DEPLOYER);
        bytes32 fromArtifact = keccak256(_artifactInitCode(BRIEF_MANAGER, BRIEF_OWNER, BRIEF_TOKEN, BRIEF_DEPLOYER));
        assertEq(fromScript, BRIEF_INIT_CODE_HASH, "INIT_CODE_HASH recorded for this build");
        assertEq(fromArtifact, BRIEF_INIT_CODE_HASH, "artifact agrees");
        assertEq(vm.computeCreate2Address(BRIEF_SALT, BRIEF_INIT_CODE_HASH, BRIEF_DEPLOYER), BRIEF_ADDRESS);
    }

    function test_verifyRecordedPassesForThisBuild() public view {
        assertEq(miner.verifyRecorded(), BRIEF_ADDRESS);
    }

    function test_recordedSaltIsTheLowestForRequesterOwner() public {
        vm.expectRevert(MineSalt.SearchExhausted.selector);
        miner.mine(BRIEF_DEPLOYER, BRIEF_INIT_CODE_HASH, 0, uint256(BRIEF_SALT));
        (bytes32 exact, address at) = miner.mine(BRIEF_DEPLOYER, BRIEF_INIT_CODE_HASH, uint256(BRIEF_SALT), 1);
        assertEq(exact, BRIEF_SALT);
        assertEq(at, BRIEF_ADDRESS);
    }

    function test_recordedSaltDeploysHookOwnedByRequester() public {
        assertEq(BRIEF_ADDRESS.code.length, 0, "fresh address");
        address deployed = factoryAtDeployer.deploy(
            miner.initCode(IPoolManager(BRIEF_MANAGER), BRIEF_OWNER, BRIEF_TOKEN, BRIEF_DEPLOYER), BRIEF_SALT
        );
        assertEq(
            deployed, BRIEF_ADDRESS, "CREATE2 from 0x7351...EFF9 with the recorded salt lands on the recorded address"
        );
        SigmaHook hook = SigmaHook(payable(deployed));
        assertEq(hook.owner(), BRIEF_OWNER);
        assertEq(hook.factory(), BRIEF_DEPLOYER);
        assertEq(hook.launchToken(), BRIEF_TOKEN);
        assertEq(address(hook.poolManager()), BRIEF_MANAGER);
        Hooks.validateHookPermissions(IHooks(deployed), hook.getHookPermissions());
        assertTrue(Hooks.hasPermission(IHooks(deployed), Hooks.AFTER_INITIALIZE_FLAG));
        assertTrue(Hooks.hasPermission(IHooks(deployed), Hooks.AFTER_SWAP_FLAG));
    }

    function test_recordedSaltDoesNotServeAnotherOwnerOrDeployer() public {
        bytes32 otherOwnerHash =
            miner.initCodeHash(IPoolManager(BRIEF_MANAGER), makeAddr("someoneElse"), BRIEF_TOKEN, BRIEF_DEPLOYER);
        assertTrue(otherOwnerHash != BRIEF_INIT_CODE_HASH);
        address moved = miner.predict(BRIEF_DEPLOYER, BRIEF_SALT, otherOwnerHash);
        assertTrue(moved != BRIEF_ADDRESS);
        assertFalse(miner.hasSuffix(moved), "the recorded salt is bound to the requester's owner");
        address elsewhere = miner.predict(makeAddr("otherDeployer"), BRIEF_SALT, BRIEF_INIT_CODE_HASH);
        assertTrue(elsewhere != BRIEF_ADDRESS);
        assertFalse(miner.hasSuffix(elsewhere), "and to the deployer");
    }

    function test_checkRejectsStaleInitCode() public {
        bytes32 changed = keccak256(bytes.concat(bytes32(BRIEF_INIT_CODE_HASH), hex"01"));
        vm.expectRevert(abi.encodeWithSelector(MineSalt.ResultStale.selector, BRIEF_INIT_CODE_HASH, changed));
        miner.check(BRIEF_DEPLOYER, changed, BRIEF_INIT_CODE_HASH, BRIEF_SALT, BRIEF_ADDRESS);
    }

    function test_checkRejectsWrongSaltOrAddress() public {
        bytes32 wrongSalt = bytes32(uint256(BRIEF_SALT) + 1);
        address actual = miner.predict(BRIEF_DEPLOYER, wrongSalt, BRIEF_INIT_CODE_HASH);
        vm.expectRevert(abi.encodeWithSelector(MineSalt.AddressMismatch.selector, BRIEF_ADDRESS, actual));
        miner.check(BRIEF_DEPLOYER, BRIEF_INIT_CODE_HASH, BRIEF_INIT_CODE_HASH, wrongSalt, BRIEF_ADDRESS);

        address wrongExpected = address(uint160(BRIEF_ADDRESS) ^ (1 << 100));
        vm.expectRevert(abi.encodeWithSelector(MineSalt.AddressMismatch.selector, wrongExpected, BRIEF_ADDRESS));
        miner.check(BRIEF_DEPLOYER, BRIEF_INIT_CODE_HASH, BRIEF_INIT_CODE_HASH, BRIEF_SALT, wrongExpected);

        // A consistent (salt, address) pair whose address lacks the suffix is refused even when it matches.
        address noSuffix = miner.predict(BRIEF_DEPLOYER, wrongSalt, BRIEF_INIT_CODE_HASH);
        if (!miner.hasSuffix(noSuffix)) {
            vm.expectRevert(abi.encodeWithSelector(MineSalt.AddressMismatch.selector, noSuffix, noSuffix));
            miner.check(BRIEF_DEPLOYER, BRIEF_INIT_CODE_HASH, BRIEF_INIT_CODE_HASH, wrongSalt, noSuffix);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Success paths
    // ---------------------------------------------------------------------------------------------

    function test_runWithOwnerMinesAddressEndingIn1040ForBriefDeployer() public view {
        (bytes32 salt, address predicted) = miner.mineFor(owner);
        assertEq(_suffix(predicted), 0x1040, "address must end in 0x1040");
        assertEq(HookFlags.flagsOf(predicted), 0x1040, "v4 flags afterInitialize|afterSwap");
        bytes32 hash = miner.initCodeHash(IPoolManager(BRIEF_MANAGER), owner, BRIEF_TOKEN, BRIEF_DEPLOYER);
        assertEq(predicted, vm.computeCreate2Address(salt, hash, BRIEF_DEPLOYER), "forge-std CREATE2 formula");
        assertEq(predicted, miner.predict(BRIEF_DEPLOYER, salt, hash));
    }

    function test_initCodeMatchesCompiledArtifact() public view {
        bytes memory expected = _artifactInitCode(BRIEF_MANAGER, owner, BRIEF_TOKEN, BRIEF_DEPLOYER);
        bytes memory actual = miner.initCode(IPoolManager(BRIEF_MANAGER), owner, BRIEF_TOKEN, BRIEF_DEPLOYER);
        assertEq(keccak256(actual), keccak256(expected));
        assertEq(
            miner.initCodeHash(IPoolManager(BRIEF_MANAGER), owner, BRIEF_TOKEN, BRIEF_DEPLOYER), keccak256(expected)
        );
    }

    function test_briefDeployerCreate2LandsOnPredictedAddress() public {
        (bytes32 salt, address predicted) = miner.mineFor(owner);
        assertEq(predicted.code.length, 0, "fresh address");

        address deployed = factoryAtDeployer.deploy(
            miner.initCode(IPoolManager(BRIEF_MANAGER), owner, BRIEF_TOKEN, BRIEF_DEPLOYER), salt
        );
        assertEq(deployed, predicted, "CREATE2 from the brief's deployer lands on the prediction");
        assertGt(deployed.code.length, 0);

        SigmaHook hook = SigmaHook(payable(deployed));
        assertEq(hook.owner(), owner);
        assertEq(hook.factory(), BRIEF_DEPLOYER);
        assertEq(hook.launchToken(), BRIEF_TOKEN);
        assertEq(address(hook.poolManager()), BRIEF_MANAGER);
        assertEq(_suffix(deployed), 0x1040);
        // The constructor already ran validateHookAddress; re-check against the permission table explicitly.
        Hooks.validateHookPermissions(IHooks(deployed), hook.getHookPermissions());
        assertTrue(Hooks.hasPermission(IHooks(deployed), Hooks.AFTER_INITIALIZE_FLAG));
        assertTrue(Hooks.hasPermission(IHooks(deployed), Hooks.AFTER_SWAP_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(deployed), Hooks.BEFORE_SWAP_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(deployed), Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
    }

    function test_mineIsDeterministicAndReturnsLowestSalt() public {
        (bytes32 salt1, address addr1) = miner.mineFor(owner);
        (bytes32 salt2, address addr2) = miner.mineFor(owner);
        assertEq(salt1, salt2);
        assertEq(addr1, addr2);

        bytes32 hash = miner.initCodeHash(IPoolManager(BRIEF_MANAGER), owner, BRIEF_TOKEN, BRIEF_DEPLOYER);
        // No earlier salt qualifies: the window [0, salt1) exhausts, and the assembly loop agrees with the
        // plain Solidity formula at the hit and at its neighbours.
        vm.expectRevert(MineSalt.SearchExhausted.selector);
        miner.mine(BRIEF_DEPLOYER, hash, 0, uint256(salt1));
        assertTrue(miner.hasSuffix(miner.predict(BRIEF_DEPLOYER, salt1, hash)));
        if (uint256(salt1) > 0) {
            assertFalse(miner.hasSuffix(miner.predict(BRIEF_DEPLOYER, bytes32(uint256(salt1) - 1), hash)));
        }
        (bytes32 exact,) = miner.mine(BRIEF_DEPLOYER, hash, uint256(salt1), 1);
        assertEq(exact, salt1, "a one-salt window at the hit finds exactly it");
    }

    function test_mineRefusesWindowThatWraps() public {
        bytes32 hash = keccak256("anything");
        vm.expectRevert(stdError.arithmeticError);
        miner.mine(BRIEF_DEPLOYER, hash, type(uint256).max, 2);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_assemblyPredictionMatchesSolidityFormula(address deployer, bytes32 hash, bytes32 salt)
        public
        view
    {
        address viaFormula = miner.predict(deployer, salt, hash);
        assertEq(viaFormula, vm.computeCreate2Address(salt, hash, deployer));
        // A one-salt window either returns the formula's address or exhausts, never something else.
        try miner.mine(deployer, hash, uint256(salt), 1) returns (bytes32 s, address a) {
            assertEq(s, salt);
            assertEq(a, viaFormula);
            assertEq(_suffix(a), 0x1040);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), MineSalt.SearchExhausted.selector);
            assertTrue(_suffix(viaFormula) != 0x1040);
        }
    }

    function test_searchResumesFromStart() public view {
        (bytes32 first,) = miner.mineFor(owner);
        (bytes32 next, address predicted) = miner.mineWith(
            BRIEF_DEPLOYER,
            IPoolManager(BRIEF_MANAGER),
            owner,
            BRIEF_TOKEN,
            BRIEF_DEPLOYER,
            uint256(first) + 1,
            ATTEMPTS
        );
        assertGt(uint256(next), uint256(first));
        assertEq(_suffix(predicted), 0x1040);
    }

    function test_fullFormMatchesLocalDeployer() public {
        Create2Factory local = new Create2Factory();
        IPoolManager manager = IPoolManager(makeAddr("manager"));
        address token = makeAddr("token");
        (bytes32 salt, address predicted) =
            miner.mineWith(address(local), manager, owner, token, address(local), 0, ATTEMPTS);
        address deployed = local.deploy(miner.initCode(manager, owner, token, address(local)), salt);
        assertEq(deployed, predicted);
        assertEq(SigmaHook(payable(deployed)).factory(), address(local));
        assertEq(_suffix(deployed), 0x1040);
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths
    // ---------------------------------------------------------------------------------------------

    function test_zeroOwnerReverts() public {
        vm.expectRevert(MineSalt.ZeroAddress.selector);
        miner.mineFor(address(0));
    }

    function test_zeroArgumentsRevert() public {
        IPoolManager manager = IPoolManager(BRIEF_MANAGER);
        vm.expectRevert(MineSalt.ZeroAddress.selector);
        miner.mineWith(address(0), manager, owner, BRIEF_TOKEN, BRIEF_DEPLOYER, 0, 1);
        vm.expectRevert(MineSalt.ZeroAddress.selector);
        miner.mineWith(BRIEF_DEPLOYER, IPoolManager(address(0)), owner, BRIEF_TOKEN, BRIEF_DEPLOYER, 0, 1);
        vm.expectRevert(MineSalt.ZeroAddress.selector);
        miner.mineWith(BRIEF_DEPLOYER, manager, owner, address(0), BRIEF_DEPLOYER, 0, 1);
        vm.expectRevert(MineSalt.ZeroAddress.selector);
        miner.mineWith(BRIEF_DEPLOYER, manager, owner, BRIEF_TOKEN, address(0), 0, 1);
    }

    function test_searchExhaustedBeforeFirstHit() public {
        (bytes32 first,) = miner.mineFor(owner);
        IPoolManager manager = IPoolManager(BRIEF_MANAGER);
        // Every salt below the first hit fails, so a window that stops just short of it exhausts.
        vm.expectRevert(MineSalt.SearchExhausted.selector);
        miner.mineWith(BRIEF_DEPLOYER, manager, owner, BRIEF_TOKEN, BRIEF_DEPLOYER, 0, uint256(first));
        vm.expectRevert(MineSalt.SearchExhausted.selector);
        miner.mineWith(BRIEF_DEPLOYER, manager, owner, BRIEF_TOKEN, BRIEF_DEPLOYER, 0, 0);
    }

    function test_saltIsBoundToOwner() public {
        address otherOwner = makeAddr("otherOwner");
        (bytes32 salt, address predicted) = miner.mineFor(owner);
        bytes32 otherHash = miner.initCodeHash(IPoolManager(BRIEF_MANAGER), otherOwner, BRIEF_TOKEN, BRIEF_DEPLOYER);
        address relocated = miner.predict(BRIEF_DEPLOYER, salt, otherHash);
        assertTrue(relocated != predicted, "a different owner moves the address");
        assertFalse(miner.hasSuffix(relocated), "the salt mined for one owner does not serve another");
    }

    function test_saltIsBoundToDeployer() public {
        (bytes32 salt, address predicted) = miner.mineFor(owner);
        bytes32 hash = miner.initCodeHash(IPoolManager(BRIEF_MANAGER), owner, BRIEF_TOKEN, BRIEF_DEPLOYER);
        address elsewhere = miner.predict(makeAddr("anotherFactory"), salt, hash);
        assertTrue(elsewhere != predicted);
        assertFalse(miner.hasSuffix(elsewhere));
    }

    function test_hookConstructorRejectsUnminedSalt() public {
        bytes memory code = miner.initCode(IPoolManager(BRIEF_MANAGER), owner, BRIEF_TOKEN, BRIEF_DEPLOYER);
        bytes32 hash = keccak256(code);
        // Find a salt whose address carries the wrong flags, then show CREATE2 with it fails inside the hook.
        bytes32 bad;
        for (uint256 s;; ++s) {
            if (!HookFlags.matches(miner.predict(BRIEF_DEPLOYER, bytes32(s), hash), HookFlags.SIGMA)) {
                bad = bytes32(s);
                break;
            }
        }
        address wrong = miner.predict(BRIEF_DEPLOYER, bad, hash);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        factoryAtDeployer.deploy(code, bad);
    }

    function test_hookConstructorRejectsZeroOwnerEvenAtMinedAddress() public {
        // A salt can be mined for owner zero only through the raw helper; the hook refuses it at deploy.
        bytes memory code = miner.initCode(IPoolManager(BRIEF_MANAGER), address(0), BRIEF_TOKEN, BRIEF_DEPLOYER);
        (bytes32 salt,) = miner.mine(BRIEF_DEPLOYER, keccak256(code), 0, ATTEMPTS);
        vm.expectRevert();
        factoryAtDeployer.deploy(code, salt);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_minedAddressAlwaysEndsIn1040(address deployer, bytes32 hash, uint64 start) public view {
        (bytes32 salt, address predicted) = miner.mine(deployer, hash, start, ATTEMPTS);
        assertGe(uint256(salt), start);
        assertLt(uint256(salt) - start, ATTEMPTS);
        assertEq(_suffix(predicted), 0x1040);
        assertEq(HookFlags.flagsOf(predicted), 0x1040);
        assertEq(predicted, vm.computeCreate2Address(salt, hash, deployer));
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_anyOwnerDeploysAtPrediction(address owner_) public {
        vm.assume(owner_ != address(0));
        (bytes32 salt, address predicted) = miner.mineFor(owner_);
        address deployed = factoryAtDeployer.deploy(
            miner.initCode(IPoolManager(BRIEF_MANAGER), owner_, BRIEF_TOKEN, BRIEF_DEPLOYER), salt
        );
        assertEq(deployed, predicted);
        assertEq(SigmaHook(payable(deployed)).owner(), owner_);
        assertEq(_suffix(deployed), 0x1040);
    }
}

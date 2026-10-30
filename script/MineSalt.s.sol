// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SigmaHook} from "../src/SigmaHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 salt search for `SigmaHook`. Never broadcasts, never reads the environment,
/// never touches an RPC: every input is a constant below or a function argument.
///
/// The CREATE2 address is `keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:]`, where
/// `initCode` is the compiled `SigmaHook` creation code followed by its ABI-encoded constructor
/// arguments `(manager, owner, launchToken, factory)`. Every one of those values changes the address,
/// so the salt is only valid for the exact build in this repository (solc 0.8.26, via-IR, 200 runs,
/// Cancun, no metadata hash) and the exact argument set passed here.
///
/// Usage, with the requester's owner address as the one argument:
///
///   forge script script/MineSalt.s.sol --sig "mineFor(address)" <owner>
///
/// The requester fixed the owner as `OWNER`, so the bare `run()` mines for it and `RECORDED_*` hold the
/// result of that search for the build in this repository. `verifyRecorded()` recomputes the result from
/// the current creation code and reverts `ResultStale` when any change has moved the address: run it
/// before the deployment transaction. The full form `mineWith(deployer, manager, owner, token, factory,
/// start, attempts)` overrides every constant, for another deployer, another chain or a resumed search.
contract MineSalt is Script {
    /// @dev No salt in `[start, start + attempts)` yields an address ending in `REQUIRED_SUFFIX`.
    error SearchExhausted();
    /// @dev Every address input must be non-zero, as the hook constructor itself requires.
    error ZeroAddress();
    /// @dev The creation code or the arguments changed since the recorded search: the recorded salt is void.
    error ResultStale(bytes32 recordedInitCodeHash, bytes32 currentInitCodeHash);
    /// @dev The salt does not put the given init code at the expected address for this deployer.
    error AddressMismatch(address expected, address actual);

    /// @notice DeployFactory, created by OWNER at nonce 2. It executes CREATE2 and is also the
    /// hook's `factory_` constructor argument (the only caller allowed to bind the pool).
    address public constant DEPLOYER = 0x44aa80c4F3807C0b5A2c880158E0141A9553e199;
    /// @notice Hook owner given by the requester for this search (`owner_` constructor argument).
    address public constant OWNER = 0xdbeab8243F318F1bBF815d85a8A869def1510b61;
    uint256 public constant FACTORY_NONCE = 2;
    /// @notice Uniswap v4 PoolManager on Robinhood Chain (chain id 4663), from the pinned project inputs.
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    /// @notice Existing SHK launch token on Robinhood Chain, from the pinned project inputs. Never redeployed.
    address public constant LAUNCH_TOKEN = 0x4fE865Ad3b3eF64B2af9C38c78aBf5C6e68C1164;
    /// @notice Chain the constants above belong to. Context only: CREATE2 addresses do not depend on it.
    uint256 public constant CHAIN_ID = 4663;

    /// @notice The address must end in these two bytes: the v4 flag bits `afterInitialize | afterSwap`
    /// (0x1040 within the low 14 bits) and clear bits 14 and 15, so the printed address literally ends
    /// in `1040`. Any address accepted here also passes `Hooks.validateHookPermissions`.
    uint160 public constant REQUIRED_SUFFIX = 0x1040;
    uint160 public constant SUFFIX_MASK = 0xFFFF;
    /// @notice One in 65,536 salts matches, so 2^22 attempts fail with probability e^-64.
    uint256 public constant DEFAULT_ATTEMPTS = 1 << 22;

    /// @notice Result of `mineFor(OWNER)` for the creation code built from this repository with the pinned
    /// settings (solc 0.8.26, via-IR, 200 runs, Cancun, no metadata hash) and the constants above. Any
    /// change to the hook source, its imports, the compiler settings or the arguments voids all three.
    bytes32 public constant RECORDED_SALT = 0x000000000000000000000000000000000000000000000000000000000001762c;
    address public constant RECORDED_ADDRESS = 0xB259cb6965FD49df82a415920Ac61DF370cB1040;
    bytes32 public constant RECORDED_INIT_CODE_HASH =
        0xd09c16e2448f647d24add8afafe9f5e94196ab26a56d0592ff129a016827aa3c;

    /// @notice RLP([OWNER, 2]) = 0xd6 ++ 0x94 ++ OWNER ++ 0x02 (23 bytes total).
    /// @dev This encoding is deliberately specific to the brief's nonce, not a general RLP encoder.
    function factoryAddress() public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", OWNER, uint8(FACTORY_NONCE))))));
    }

    /// @notice The bare invocation: mine for the requester's owner with every other input from the constants.
    function run() external pure returns (bytes32 salt, address predicted) {
        return mineFor(OWNER);
    }

    /// @notice Mine for the brief's deployer, PoolManager and token with the given hook owner.
    function mineFor(address owner) public pure returns (bytes32 salt, address predicted) {
        return mineWith(DEPLOYER, POOL_MANAGER, owner, LAUNCH_TOKEN, DEPLOYER, 0, DEFAULT_ATTEMPTS);
    }

    /// @notice Pre-deployment check: the recorded salt still places the current build at the recorded address.
    /// Reverts `ResultStale` when the creation code or arguments changed and `AddressMismatch` when the salt
    /// no longer maps to the address; returns the address when everything agrees.
    function verifyRecorded() external pure returns (address) {
        address factory = factoryAddress();
        if (factory != DEPLOYER) revert AddressMismatch(DEPLOYER, factory);
        bytes32 hash = initCodeHash(POOL_MANAGER, OWNER, LAUNCH_TOKEN, DEPLOYER);
        address predicted = check(DEPLOYER, hash, RECORDED_INIT_CODE_HASH, RECORDED_SALT, RECORDED_ADDRESS);
        console.log("VERIFIED FACTORY_ADDRESS:", vm.toString(factory));
        console.log("VERIFIED SALT:", vm.toString(RECORDED_SALT));
        console.log("VERIFIED ADDRESS:", vm.toString(predicted));
        console.log("VERIFIED INIT_CODE_HASH:", vm.toString(hash));
        return predicted;
    }

    /// @notice Generic form of `verifyRecorded`: `currentHash` must equal `recordedHash`, and `salt` must map
    /// `currentHash` to `expected` for `deployer` with the required suffix.
    function check(address deployer, bytes32 currentHash, bytes32 recordedHash, bytes32 salt, address expected)
        public
        pure
        returns (address predicted)
    {
        if (currentHash != recordedHash) revert ResultStale(recordedHash, currentHash);
        predicted = predict(deployer, salt, currentHash);
        if (predicted != expected || !hasSuffix(predicted)) revert AddressMismatch(expected, predicted);
    }

    /// @notice Fully parameterised search. `deployer` is the account that executes CREATE2, not the EOA
    /// that signs the transaction and not this script contract. Retry with a later `start` if a batch
    /// exhausts or if the first result is already occupied on chain.
    function mineWith(
        address deployer,
        IPoolManager manager,
        address owner,
        address token,
        address factory,
        uint256 start,
        uint256 attempts
    ) public pure returns (bytes32 salt, address predicted) {
        if (
            deployer == address(0) || address(manager) == address(0) || owner == address(0) || token == address(0)
                || factory == address(0)
        ) revert ZeroAddress();
        bytes32 hash = initCodeHash(manager, owner, token, factory);
        (salt, predicted) = mine(deployer, hash, start, attempts);
        console.log("SALT:", vm.toString(salt));
        console.log("ADDRESS:", vm.toString(predicted));
        console.log("INIT_CODE_HASH:", vm.toString(hash));
        console.log("DEPLOYER:", vm.toString(deployer));
        console.log("CONSTRUCTOR manager:", vm.toString(address(manager)));
        console.log("CONSTRUCTOR owner:", vm.toString(owner));
        console.log("CONSTRUCTOR launchToken:", vm.toString(token));
        console.log("CONSTRUCTOR factory:", vm.toString(factory));
    }

    /// @notice Creation code plus ABI-encoded constructor arguments, exactly what the deployer must pass to CREATE2.
    function initCode(IPoolManager manager, address owner, address token, address factory)
        public
        pure
        returns (bytes memory)
    {
        return bytes.concat(type(SigmaHook).creationCode, abi.encode(manager, owner, token, factory));
    }

    function initCodeHash(IPoolManager manager, address owner, address token, address factory)
        public
        pure
        returns (bytes32)
    {
        return keccak256(initCode(manager, owner, token, factory));
    }

    /// @notice Lowest salt in `[start, start + attempts)` whose CREATE2 address ends in `REQUIRED_SUFFIX`.
    /// @dev The loop hashes in a fixed scratch area: a Solidity `abi.encodePacked` per attempt would grow
    /// memory without bound and make a 100k-attempt search run out of gas on memory expansion alone.
    function mine(address deployer, bytes32 hash, uint256 start, uint256 attempts)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        uint256 end = start + attempts; // checked: refuses a window that wraps past 2^256
        uint160 mask = SUFFIX_MASK;
        uint160 want = REQUIRED_SUFFIX;
        bool found;
        assembly ("memory-safe") {
            // 85-byte preimage 0xff ++ deployer ++ salt ++ hash, laid out from ptr+0x0b with the deployer
            // right-aligned in the first word. Scratch beyond the free pointer is not kept afterwards.
            let ptr := mload(0x40)
            mstore(ptr, deployer)
            mstore8(add(ptr, 0x0b), 0xff)
            mstore(add(ptr, 0x40), hash)
            for { let s := start } lt(s, end) { s := add(s, 1) } {
                mstore(add(ptr, 0x20), s)
                let a := and(keccak256(add(ptr, 0x0b), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
                if eq(and(a, mask), want) {
                    salt := s
                    predicted := a
                    found := 1
                    break
                }
            }
        }
        if (!found) revert SearchExhausted();
    }

    function predict(address deployer, bytes32 salt, bytes32 hash) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
    }

    /// @notice True when the address ends in `1040`, which implies the v4 flags `afterInitialize | afterSwap`.
    function hasSuffix(address hook) public pure returns (bool) {
        return (uint160(hook) & SUFFIX_MASK) == REQUIRED_SUFFIX && HookFlags.matches(hook, HookFlags.SIGMA);
    }
}

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
/// The default entrypoint `run()` deliberately reverts `OwnerRequired`, because no salt exists until
/// the owner is fixed. The full form `mineWith(deployer, manager, owner, token, factory, start,
/// attempts)` overrides every constant, for another deployer, another chain or a resumed search.
contract MineSalt is Script {
    /// @dev No salt in `[start, start + attempts)` yields an address ending in `REQUIRED_SUFFIX`.
    error SearchExhausted();
    /// @dev `run()` was called without the owner; the hint says which entrypoint to call instead.
    error OwnerRequired(string hint);
    /// @dev Every address input must be non-zero, as the hook constructor itself requires.
    error ZeroAddress();

    /// @notice CREATE2 deployer from the brief. It is the contract that executes CREATE2, so it is also
    /// the hook's `factory_` constructor argument (the only caller allowed to bind the pool).
    address public constant DEPLOYER = 0x735121A546092F31050A867FD7E3A750C7B0EFF9;
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

    /// @notice The brief's bare invocation. There is no answer without the owner, so say so.
    function run() external pure {
        revert OwnerRequired("the CREATE2 address depends on the hook owner; run: forge script script/MineSalt.s.sol --sig \"mineFor(address)\" <owner>");
    }

    /// @notice Mine for the brief's deployer, PoolManager and token with the given hook owner.
    function mineFor(address owner) external pure returns (bytes32 salt, address predicted) {
        return mineWith(DEPLOYER, POOL_MANAGER, owner, LAUNCH_TOKEN, DEPLOYER, 0, DEFAULT_ATTEMPTS);
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

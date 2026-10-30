// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SSTORE2} from "solmate/src/utils/SSTORE2.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SigmaHook} from "./SigmaHook.sol";

/// @notice The launch manager's createPool extension, which is absent from upstream IPoolManager.
/// @dev The manager chooses the initial price and must forward this factory as the initialization sender.
interface ICreatePoolManager {
    function createPool(PoolKey calldata key) external;
}

/// @notice Owner-operated CREATE2 deployment and pool creation for SigmaHook. No constructor arguments.
contract DeployFactory is Ownable {
    error CreationCodeTooLarge();
    error HookDeploymentFailed();
    error UnknownHook();
    error InvalidCurrencies();
    error PoolNotInitialized();

    // STOP-prefixed, immutable code stores keep the factory runtime below EIP-170. Embedding
    // `new SigmaHook` in deployHook would put the entire hook init code in the factory runtime.
    address public immutable codePart0;
    address public immutable codePart1;
    mapping(address hook => bool) public isHook;

    event HookDeployed(
        address indexed hook, bytes32 indexed salt, address indexed hookOwner, address manager, address token
    );
    event PoolCreated(address indexed hook, address currency0, address currency1);

    constructor() Ownable(0xdbeab8243F318F1bBF815d85a8A869def1510b61) {
        bytes memory code = type(SigmaHook).creationCode;
        // Each code store needs one byte for STOP, in addition to its payload.
        if (code.length > 2 * (24_576 - 1)) revert CreationCodeTooLarge();
        uint256 split = code.length / 2;
        codePart0 = SSTORE2.write(_slice(code, 0, split));
        codePart1 = SSTORE2.write(_slice(code, split, code.length - split));
    }

    /// @notice Only the factory owner may deploy, preventing someone else from consuming the launch salt.
    /// @dev Executes CREATE2 here, with exactly (manager, owner, token, address(this)) as hook arguments.
    function deployHook(bytes32 salt, address manager, address owner_, address token)
        external
        onlyOwner
        returns (address hook)
    {
        bytes memory initCode = bytes.concat(
            SSTORE2.read(codePart0), SSTORE2.read(codePart1), abi.encode(manager, owner_, token, address(this))
        );
        assembly ("memory-safe") {
            hook := create2(0, add(initCode, 32), mload(initCode), salt)
            // Preserve constructor errors, including invalid hook permissions and invalid addresses.
            if iszero(hook) {
                if returndatasize() {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }
        }
        if (hook == address(0)) revert HookDeploymentFailed();
        isHook[hook] = true;
        emit HookDeployed(hook, salt, owner_, manager, token);
    }

    /// @notice Bind a deployed hook to its manager's 1.25% fee / 60 tick-spacing pool.
    /// @dev Native ETH is address(0), ordered before SHK. No initial price is guessed here.
    function createPool(address hook, address currency0, address currency1) external onlyOwner {
        if (!isHook[hook]) revert UnknownHook();
        SigmaHook sigma = SigmaHook(payable(hook));
        if (sigma.initialized()) revert SigmaHook.AlreadyInitialized();
        if (currency0 >= currency1 || (currency0 != sigma.launchToken() && currency1 != sigma.launchToken())) {
            revert InvalidCurrencies();
        }
        PoolKey memory key = PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), 12_500, 60, IHooks(hook));
        ICreatePoolManager(address(sigma.poolManager())).createPool(key);
        if (!sigma.initialized()) revert PoolNotInitialized();
        emit PoolCreated(hook, currency0, currency1);
    }

    /// @dev Constructor-only copy; never accepts caller-supplied offsets. Cancun MCOPY is pinned by the project.
    function _slice(bytes memory data, uint256 start, uint256 length) private pure returns (bytes memory part) {
        part = new bytes(length);
        assembly ("memory-safe") {
            mcopy(add(part, 32), add(add(data, 32), start), length)
        }
    }
}

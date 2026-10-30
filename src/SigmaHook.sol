// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BandMath} from "./libraries/BandMath.sol";
import {SigmaMath} from "./SigmaMath.sol";
import {PermanentTokenLock} from "./PermanentTokenLock.sol";

/// @notice Single-pool basket with ERC-20 receipts, permissionless keeper compounding and owner-set
/// rebalance parameters (trigger sigma, range sigma, cooldown) selectable through presets.
/// @dev Shares represent only this hook's position and idle assets, never other LP positions.
contract SigmaHook is BaseHook, ERC20, Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error NotInitialized();
    error AlreadyInitialized();
    error InvalidPool();
    error NotFactory();
    error EmergencyActive();
    error EmergencyInactive();
    error InvalidAmount();
    error Slippage();
    error Expired();
    error UnexpectedNativeValue();
    error UnsupportedToken();
    error UnexpectedUnlock();
    error OwnershipRequired();
    error RebalanceTooSoon();
    error WithinThreshold();
    error NoExternalShares();
    error NoPendingInvestment();
    error AlreadyConfigured();

    /// @notice Rebalance trigger distance from the SMA, in tenths of a sigma (15 = 1.5σ; 255 = paused).
    uint8 public triggerSigma = 15;
    /// @notice Half-width of the redeployed range around the SMA, in tenths of a sigma (30 = 3.0σ).
    uint8 public rangeSigma = 30;
    /// @notice Minimum seconds between keeper rebalances.
    uint32 public cooldown = 1800;

    struct Preset {
        uint8 trigger;
        uint8 range;
        uint32 cooldown;
    }

    /// @notice Operator presets: 0 SLEEP, 1 STANDARD, 2 AGGRESSIVE, 3 MAX, 4 DEFENSIVE, 5 PAUSED.
    Preset[6] public presets;

    uint256 public constant MINIMUM_SHARES = 1_000;
    /// @notice A rebalance sells surplus inventory only when it exceeds this share of vault value.
    uint256 public constant REBALANCE_SWAP_DEADBAND_BPS = 100;
    uint256 public constant BURN_BPS = 2_000;
    uint256 public constant KEEPER_BPS = 100;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    bytes32 public constant POSITION_SALT = keccak256("SigmaHook.vault");

    address public immutable launchToken;
    address public immutable factory;
    address public immutable burnSink;
    SigmaMath public immutable math;
    address public WETH;
    uint256 public accountedNative;
    uint256 public burnReserve0;
    uint256 public burnReserve1;
    uint256 public keeperReserve0;
    uint256 public keeperReserve1;
    bool public investmentPending;
    PoolKey private _key;
    PoolId public poolId;
    bool public initialized;
    bool public emergencyMode;
    int24[8] public ticks;
    uint8 public nextSample;
    uint256 public lastRebalance;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    bool private _expectUnlock;

    enum Action {
        Harvest,
        Invest,
        Withdraw,
        Emergency,
        InitialDeposit,
        Rebalance,
        Retry
    }

    event PoolBound(PoolId indexed id, address currency0, address currency1, int24 launchTick);
    event SampleRecorded(uint8 indexed index, int24 tick);
    event Rebalanced(int24 lower, int24 upper, uint128 oldLiquidity, uint128 newLiquidity);
    event BandRefreshed(int24 lower, int24 upper);
    event InventoryBalanced(bool zeroForOne, uint256 amountIn, int128 delta0, int128 delta1);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event Deposited(address indexed caller, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed caller, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event EmergencyActivated(uint256 amount0, uint256 amount1);
    event FeesSplit(uint256 fee0, uint256 fee1, uint256 burn0, uint256 burn1, uint256 keeper0, uint256 keeper1);
    event KeeperPaid(address indexed keeper, uint256 amount0, uint256 amount1);
    event LaunchDisposed(uint256 amount, bool zeroAddressTransfer);
    event BuybackDeferred(uint256 amount0, uint256 amount1);
    event BuybackExecuted(uint256 pairedSpent, uint256 launchBought);
    event InvestmentDeferred(uint256 amount0, uint256 amount1);
    event WETHConfigured(address indexed weth);
    event StrayETHRescued(address indexed receiver, uint256 amount);
    event ModeChanged(uint8 mode);

    constructor(IPoolManager manager_, address owner_, address launchToken_, address factory_)
        BaseHook(manager_)
        ERC20("SigmaHook Basket Receipt", "sSHK")
        Ownable(owner_)
    {
        if (address(manager_) == address(0) || launchToken_ == address(0) || factory_ == address(0)) {
            revert InvalidAddress();
        }
        launchToken = launchToken_;
        factory = factory_;
        burnSink = address(new PermanentTokenLock());
        math = new SigmaMath();
        presets[0] = Preset(30, 30, 3600); // SLEEP
        presets[1] = Preset(15, 20, 1800); // STANDARD
        presets[2] = Preset(10, 15, 900); // AGGRESSIVE
        presets[3] = Preset(5, 10, 300); // MAX
        presets[4] = Preset(30, 40, 7200); // DEFENSIVE
        presets[5] = Preset(255, 255, type(uint32).max); // PAUSED
    }

    /// @notice Load one preset into the three live parameters.
    function setMode(uint8 m) external onlyOwner {
        require(m < 6, "invalid mode");
        Preset memory p = presets[m];
        triggerSigma = p.trigger;
        rangeSigma = p.range;
        cooldown = p.cooldown;
        emit ModeChanged(m);
    }

    function setTriggerSigma(uint8 v) external onlyOwner {
        require(v >= 5 && v <= 50, "bounds");
        triggerSigma = v;
    }

    function setRangeSigma(uint8 v) external onlyOwner {
        require(v >= 10 && v <= 50, "bounds");
        rangeSigma = v;
    }

    function setCooldown(uint32 v) external onlyOwner {
        require(v >= 300 && v <= 86400, "bounds");
        cooldown = v;
    }

    /// @notice Stop keeper rebalances by raising the trigger beyond any reachable deviation.
    function pause() external onlyOwner {
        triggerSigma = 255;
    }

    /// @notice Restore the STANDARD trigger; range and cooldown keep their current values.
    function resume() external onlyOwner {
        triggerSigma = presets[1].trigger;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.afterSwap = true;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    /// @notice Whole-tick view of the feed: mean rounded to nearest, sigma floored.
    function statistics() public view returns (int24 mean, uint256 sigma) {
        return math.statistics(ticks);
    }

    /// @notice The exact feed moments in eighths of a tick: sum = 8 × mean, sigma8 = floor(8 × sigma).
    function moments() public view returns (int256 sum, uint256 sigma8) {
        return math.moments(ticks);
    }

    function proposedBands() external view returns (int24 lower, int24 upper) {
        _requireInitialized();
        (int256 sum, uint256 sigma8) = moments();
        return math.bands(sum, sigma8, _key.tickSpacing, rangeSigma);
    }

    /// @notice Principal, uncollected fees, raw dust, and ERC-6909 claims in pool currency order.
    /// @dev Principal rounds down here; deposit pricing rounds it up to protect existing holders.
    function totalAssets() external view returns (uint256 amount0, uint256 amount1) {
        _requireInitialized();
        return _assets(false);
    }

    /// @notice Quote maximum shares for the supplied budgets, including uncollected fees.
    /// @dev This is a spot-state quote. Set minShares and a deadline when submitting a deposit.
    function previewDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        _requireLive();
        return _quoteDeposit(amount0Max, amount1Max, 0);
    }

    /// @notice Deposit a proportional basket. Unused ERC-20 budgets are never pulled, on the first
    /// deposit included: only what the minted liquidity costs leaves the caller.
    /// @dev For native currency0 send exactly amount0Max; unused ETH is refunded to the caller.
    /// The first deposit refreshes the band from the feed before quoting. Later deposits cannot
    /// change a pending range or bypass the keeper cooldown.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        _requireLive();
        _checkReceiver(receiver);
        if (block.timestamp > deadline) revert Expired();
        if (minShares == 0) revert InvalidAmount();
        if (msg.value != (_key.currency0.isAddressZero() ? amount0Max : 0)) revert UnexpectedNativeValue();

        accountedNative += msg.value;

        // Existing holders own all net fees earned before the deposit.
        if (liquidity != 0) {
            _unlock(Action.Harvest, 0, 0);
        } else if (totalSupply() == 0) {
            (int256 sum, uint256 sigma8) = moments();
            (tickLower, tickUpper) = math.bands(sum, sigma8, _key.tickSpacing, rangeSigma);
            emit BandRefreshed(tickLower, tickUpper);
        }
        (shares, amount0, amount1) = _quoteDeposit(amount0Max, amount1Max, msg.value);
        if (shares == 0 || shares < minShares) revert Slippage();
        _pull(_key.currency0, amount0);
        _pull(_key.currency1, amount1);
        if (totalSupply() == 0) {
            // The callback sizes against only this depositor's budgets. Preexisting donations
            // cannot increase the amount invested on their behalf or contaminate the refund.
            (shares, amount0, amount1) =
                abi.decode(_unlock(Action.InitialDeposit, shares + MINIMUM_SHARES, 0), (uint256, uint256, uint256));
            if (shares < minShares) revert Slippage();
            _mint(address(this), MINIMUM_SHARES);
        } else {
            if (_key.currency0.isAddressZero() && msg.value > amount0) {
                _transferCurrency(_key.currency0, msg.sender, msg.value - amount0);
            }
            _unlock(Action.Invest, 0, 0);
        }
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Burn the caller's shares for principal, fees, and idle assets at any time while live.
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address receiver, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _requireLive();
        _checkReceiver(receiver);
        if (block.timestamp > deadline) revert Expired();
        if (shares == 0) revert InvalidAmount();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        (amount0, amount1) = abi.decode(_unlock(Action.Withdraw, shares, supply), (uint256, uint256));
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();
        _pay(receiver, amount0, amount1);
        emit Withdrawn(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Irreversibly exit the vault's position and redeem every claim into raw assets.
    /// @dev Other LP positions and swaps remain usable. The owner receives no assets.
    function activateEmergencyMode() external onlyOwner nonReentrant {
        _requireLive();
        emergencyMode = true;
        _unlock(Action.Emergency, 0, 0);
        emit EmergencyActivated(_key.currency0.balanceOfSelf(), _key.currency1.balanceOfSelf());
    }

    /// @notice Immediately redeem all caller-owned shares, without calling the PoolManager.
    function emergencyWithdraw() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        return _emergencyWithdraw(balanceOf(msg.sender), msg.sender);
    }

    /// @notice Partial redemption or an alternative receiving wallet, including for contracts rejecting ETH.
    function emergencyWithdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        return _emergencyWithdraw(shares, receiver);
    }

    /// @dev Keep an accountable emergency owner; transfers use Ownable2Step.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        nonReentrant
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        if (
            address(key.hooks) != address(this) || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING
                || (Currency.unwrap(key.currency0) != launchToken && Currency.unwrap(key.currency1) != launchToken)
        ) revert InvalidPool();
        _checkCurrency(key.currency0);
        _checkCurrency(key.currency1);
        _key = key;
        poolId = key.toId();
        initialized = true;
        for (uint256 i; i < 8; ++i) {
            ticks[i] = tick;
        }
        (tickLower, tickUpper) = math.bands(int256(tick) * BandMath.SAMPLES, 0, key.tickSpacing, rangeSigma);
        lastRebalance = block.timestamp;
        emit PoolBound(poolId, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), tick);
        return IHooks.afterInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        nonReentrant
        returns (bytes4, int128)
    {
        _requireInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint8 index = nextSample;
        ticks[index] = tick;
        nextSample = (index + 1) % 8;
        emit SampleRecorded(index, tick);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Move capital only when both the owner-set cooldown and strict trigger-sigma hold.
    function flashRebalance(PoolKey calldata key) external nonReentrant {
        _requireLive();
        _checkKey(key);
        if (block.timestamp < lastRebalance + cooldown) revert RebalanceTooSoon();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        (int256 sum, uint256 sigma8) = moments();
        if (!BandMath.deviates(tick, sum, sigma8, triggerSigma)) revert WithinThreshold();
        if (totalSupply() <= MINIMUM_SHARES) revert NoExternalShares();
        lastRebalance = block.timestamp;
        _unlock(Action.Rebalance, 0, 0);
    }

    function lastRebalanceTimestamp() external view returns (uint256) {
        return lastRebalance;
    }

    /// @notice Retry idle inventory in the already selected range, without a bounty or range change.
    function retryInvestment(PoolKey calldata key) external nonReentrant {
        _requireLive();
        _checkKey(key);
        if (!investmentPending) revert NoPendingInvestment();
        _unlock(Action.Retry, 0, 0);
    }

    /// @notice Optional, one-time source authorization for wrapped ETH. Native pools do not need it.
    function setWETH(address weth) external onlyOwner {
        if (WETH != address(0)) revert AlreadyConfigured();
        if (weth == address(0) || weth.code.length == 0) revert InvalidAddress();
        WETH = weth;
        emit WETHConfigured(weth);
    }

    /// @notice Recover only ETH outside the native pool's accounted balance, including forced ETH.
    function rescueStrayETH() external onlyOwner nonReentrant {
        uint256 amount = address(this).balance - accountedNative;
        address receiver = owner();
        Currency.wrap(address(0)).transfer(receiver, amount);
        emit StrayETHRescued(receiver, amount);
    }

    function _checkKey(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory result) {
        if (!_expectUnlock) revert UnexpectedUnlock();
        _expectUnlock = false;
        (Action action, uint256 shares, uint256 supply, address caller, uint256 nativeBudget) =
            abi.decode(data, (Action, uint256, uint256, address, uint256));
        if (action == Action.Harvest) {
            _harvest();
        } else if (action == Action.InitialDeposit) {
            result = _initialDeposit(uint128(shares), caller, nativeBudget);
        } else if (action == Action.Invest) {
            _invest();
        } else if (action == Action.Rebalance) {
            _rebalance(caller);
        } else if (action == Action.Retry) {
            if (_capacity() != 0) _balanceInventory();
            _invest();
        } else if (action == Action.Withdraw) {
            _harvest();
            uint256 amount0 = FullMath.mulDiv(_available(_key.currency0), shares, supply);
            uint256 amount1 = FullMath.mulDiv(_available(_key.currency1), shares, supply);
            uint128 removed = uint128(FullMath.mulDiv(liquidity, shares, supply));
            if (removed != 0) {
                BalanceDelta delta = _changeLiquidity(-int256(uint256(removed)));
                amount0 += uint128(delta.amount0());
                amount1 += uint128(delta.amount1());
            }
            _makeRaw(_key.currency0, amount0);
            _makeRaw(_key.currency1, amount1);
            result = abi.encode(amount0, amount1);
        } else {
            if (liquidity != 0) _changeLiquidity(-int256(uint256(liquidity)));
            _makeRaw(_key.currency0, _idle(_key.currency0));
            _makeRaw(_key.currency1, _idle(_key.currency1));
            // Terminal mode cancels unexecuted fee allocations back to LPs. No keeper job remains.
            burnReserve0 = 0;
            burnReserve1 = 0;
            keeperReserve0 = 0;
            keeperReserve1 = 0;
            investmentPending = false;
        }
    }

    function _unlock(Action action, uint256 shares, uint256 supply) private returns (bytes memory) {
        _expectUnlock = true;
        return poolManager.unlock(abi.encode(action, shares, supply, msg.sender, msg.value));
    }

    function _initialDeposit(uint128 added, address caller, uint256 nativeBudget) private returns (bytes memory) {
        (uint160 price,,,) = poolManager.getSlot0(poolId);
        (uint256 budget0, uint256 budget1) = math.amounts(price, tickLower, tickUpper, added, true);
        if (added <= MINIMUM_SHARES) revert Slippage();
        BalanceDelta delta = _changeLiquidity(int256(uint256(added)));
        uint256 amount0Consumed = uint256(-int256(delta.amount0()));
        uint256 amount1Consumed = uint256(-int256(delta.amount1()));
        // Price shares from the manager's actual rounded debits, never the user's maximum budget.
        uint256 paidLiquidity =
            math.liquidityForAmounts(price, tickLower, tickUpper, amount0Consumed, amount1Consumed, added);
        if (paidLiquidity <= MINIMUM_SHARES) revert Slippage();
        uint256 refund0 = (_key.currency0.isAddressZero() ? nativeBudget : budget0) - amount0Consumed;
        uint256 refund1 = budget1 - amount1Consumed;
        // Refund in this same unlock; no unused first-deposit budget can back genesis shares.
        if (refund0 != 0) _transferCurrency(_key.currency0, caller, refund0);
        if (refund1 != 0) _transferCurrency(_key.currency1, caller, refund1);
        return abi.encode(paidLiquidity - MINIMUM_SHARES, amount0Consumed, amount1Consumed);
    }

    function _rebalance(address keeper) private {
        uint128 oldLiquidity = liquidity;
        if (oldLiquidity != 0) _changeLiquidity(-int256(uint256(oldLiquidity)));
        (int256 sum, uint256 sigma8) = moments();
        (tickLower, tickUpper) = math.bands(sum, sigma8, _key.tickSpacing, rangeSigma);
        _distributeFees(keeper);
        if (_capacity() != 0) _balanceInventory();
        _invest();
        emit Rebalanced(tickLower, tickUpper, oldLiquidity, liquidity);
    }

    function _harvest() private {
        if (liquidity != 0) _changeLiquidity(0);
    }

    function _changeLiquidity(int256 change) private returns (BalanceDelta delta) {
        if (change < 0) liquidity -= uint128(uint256(-change));
        else liquidity += uint128(uint256(change));
        BalanceDelta fees;
        (delta, fees) =
            poolManager.modifyLiquidity(_key, ModifyLiquidityParams(tickLower, tickUpper, change, POSITION_SALT), "");
        // callerDelta ALREADY includes fees; never add feesAccrued a second time.
        _settle(_key.currency0, delta.amount0());
        _settle(_key.currency1, delta.amount1());
        if (fees.amount0() != 0 || fees.amount1() != 0) {
            uint256 fee0 = uint128(fees.amount0());
            uint256 fee1 = uint128(fees.amount1());
            uint256 burn0 = fee0 * BURN_BPS / 10_000;
            uint256 burn1 = fee1 * BURN_BPS / 10_000;
            uint256 keeper0 = fee0 * KEEPER_BPS / 10_000;
            uint256 keeper1 = fee1 * KEEPER_BPS / 10_000;
            burnReserve0 += burn0;
            burnReserve1 += burn1;
            keeperReserve0 += keeper0;
            keeperReserve1 += keeper1;
            emit FeesCollected(fee0, fee1);
            emit FeesSplit(fee0, fee1, burn0, burn1, keeper0, keeper1);
        }
    }

    function _invest() private {
        uint128 added;
        uint128 capacity = _capacity();
        // A bounded number of ratio corrections adapts to price impact; there is no 300-tick cap.
        for (uint256 attempt; attempt < 3 && capacity != 0; ++attempt) {
            (uint160 price,,,) = poolManager.getSlot0(poolId);
            added = math.liquidityForAmounts(
                price, tickLower, tickUpper, _budget(_key.currency0), _budget(_key.currency1), capacity
            );
            if (added != 0) {
                _changeLiquidity(int256(uint256(added)));
                investmentPending = false;
                return;
            }
            if (!_balanceInventory()) break;
        }
        // Persistent claims/raw balances remain redeemable. Transient storage cannot hold funds
        // across transactions. Retrying never pays another bounty or bypasses the range gates.
        investmentPending = liquidity == 0 && (_available(_key.currency0) != 0 || _available(_key.currency1) != 0);
        if (investmentPending) emit InvestmentDeferred(_available(_key.currency0), _available(_key.currency1));
    }

    /// @dev Trade as deeply as the selected statistical range permits, stopping one tick inside
    /// its edge. If no other LP can fill it, retain inventory for permissionless retry/withdrawal.
    function _balanceInventory() private returns (bool traded) {
        if (poolManager.getLiquidity(poolId) == 0) return false;
        (uint160 price,,,) = poolManager.getSlot0(poolId);
        (bool zeroForOne, uint256 amountIn) = math.rebalanceTrade(
            price, tickLower, tickUpper, _budget(_key.currency0), _budget(_key.currency1), REBALANCE_SWAP_DEADBAND_BPS
        );
        if (amountIn == 0) return false;
        uint160 limit = _routeLimit(zeroForOne);
        if (zeroForOne ? limit >= price : limit <= price) return false;
        BalanceDelta delta = poolManager.swap(_key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        _settle(_key.currency0, delta.amount0());
        _settle(_key.currency1, delta.amount1());
        emit InventoryBalanced(zeroForOne, amountIn, delta.amount0(), delta.amount1());
        return delta.amount0() != 0 || delta.amount1() != 0;
    }

    function _routeLimit(bool zeroForOne) private view returns (uint160) {
        return math.priceAtTick(zeroForOne ? tickLower + 1 : tickUpper - 1);
    }

    function _distributeFees(address keeper) private {
        bool launchIs0 = Currency.unwrap(_key.currency0) == launchToken;
        uint256 input = launchIs0 ? burnReserve1 : burnReserve0;
        if (input != 0) {
            bool zeroForOne = !launchIs0;
            (uint160 price,,,) = poolManager.getSlot0(poolId);
            uint160 limit = _routeLimit(zeroForOne);
            if (poolManager.getLiquidity(poolId) != 0 && (zeroForOne ? limit < price : limit > price)) {
                uint256 amountIn = Math.min(input, uint256(uint128(type(int128).max)));
                BalanceDelta delta = poolManager.swap(_key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
                _settle(_key.currency0, delta.amount0());
                _settle(_key.currency1, delta.amount1());
                if (launchIs0) {
                    burnReserve1 -= uint256(-int256(delta.amount1()));
                    burnReserve0 += uint128(delta.amount0());
                    emit BuybackExecuted(uint256(-int256(delta.amount1())), uint128(delta.amount0()));
                } else {
                    burnReserve0 -= uint256(-int256(delta.amount0()));
                    burnReserve1 += uint128(delta.amount1());
                    emit BuybackExecuted(uint256(-int256(delta.amount0())), uint128(delta.amount1()));
                }
            }
        }
        uint256 launchAmount = launchIs0 ? burnReserve0 : burnReserve1;
        if (launchAmount != 0) {
            if (launchIs0) burnReserve0 = 0;
            else burnReserve1 = 0;
            _makeRaw(Currency.wrap(launchToken), launchAmount);
            _disposeLaunch(launchAmount);
        }
        if (burnReserve0 != 0 || burnReserve1 != 0) emit BuybackDeferred(burnReserve0, burnReserve1);
        uint256 keeper0 = keeperReserve0;
        uint256 keeper1 = keeperReserve1;
        keeperReserve0 = 0;
        keeperReserve1 = 0;
        _makeRaw(_key.currency0, keeper0);
        _makeRaw(_key.currency1, keeper1);
        _pay(keeper, keeper0, keeper1);
        emit KeeperPaid(keeper, keeper0, keeper1);
    }

    function _disposeLaunch(uint256 amount) private {
        IERC20 token = IERC20(launchToken);
        uint256 beforeBalance = token.balanceOf(address(this));
        (bool success, bytes memory result) = launchToken.call(abi.encodeCall(IERC20.transfer, (address(0), amount)));
        bool sentToZero = success && (result.length == 0 || (result.length == 32 && abi.decode(result, (bool))));
        if (!sentToZero) token.safeTransfer(burnSink, amount);
        if (beforeBalance - token.balanceOf(address(this)) != amount) revert UnsupportedToken();
        emit LaunchDisposed(amount, sentToZero);
    }

    /// @dev Spendable inventory excludes fee liabilities and is bounded to int128.
    function _budget(Currency currency) private view returns (uint256 amount) {
        amount = poolManager.balanceOf(address(this), currency.toId());
        amount += _rawBalance(currency);
        uint256 reserved = _reserved(currency);
        return Math.min(amount > reserved ? amount - reserved : 0, uint256(uint128(type(int128).max)));
    }

    /// @dev Match v4's per-tick cap, including other LPs sharing either boundary.
    function _capacity() private view returns (uint128) {
        return _capacityFor(tickLower, tickUpper);
    }

    function _capacityFor(int24 lower, int24 upper) private view returns (uint128) {
        int256 minIndex = BandMath.floor(TickMath.MIN_TICK, _key.tickSpacing) / _key.tickSpacing;
        int256 maxIndex = int256(TickMath.MAX_TICK) / _key.tickSpacing;
        uint128 maxPerTick = uint128(type(uint128).max / uint256(maxIndex - minIndex + 1));
        (uint128 grossLower,) = poolManager.getTickLiquidity(poolId, lower);
        (uint128 grossUpper,) = poolManager.getTickLiquidity(poolId, upper);
        uint128 gross = grossLower > grossUpper ? grossLower : grossUpper;
        return gross >= maxPerTick ? 0 : maxPerTick - gross;
    }

    /// @dev All deltas settle in this hook's own unlock. Credits become claims; debts consume
    /// those claims before any raw balance. Router swaps only record observations.
    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) {
            poolManager.mint(address(this), currency.toId(), uint128(delta));
        } else if (delta < 0) {
            uint256 debt = uint256(-int256(delta));
            uint256 claims = Math.min(debt, poolManager.balanceOf(address(this), currency.toId()));
            if (claims != 0) poolManager.burn(address(this), currency.toId(), claims);
            debt -= claims;
            if (debt != 0) {
                poolManager.sync(currency);
                uint256 paid;
                if (currency.isAddressZero()) {
                    accountedNative -= debt;
                    paid = poolManager.settle{value: debt}();
                } else {
                    currency.transfer(address(poolManager), debt);
                    paid = poolManager.settle();
                }
                if (paid != debt) revert UnsupportedToken();
            }
        }
    }

    function _makeRaw(Currency currency, uint256 amount) private {
        uint256 raw = _rawBalance(currency);
        if (amount > raw) {
            uint256 redeem = amount - raw;
            poolManager.burn(address(this), currency.toId(), redeem);
            poolManager.take(currency, address(this), redeem);
        }
    }

    function _idle(Currency currency) private view returns (uint256) {
        return _rawBalance(currency) + poolManager.balanceOf(address(this), currency.toId());
    }

    function _rawBalance(Currency currency) private view returns (uint256) {
        return currency.isAddressZero() ? accountedNative : currency.balanceOfSelf();
    }

    function _reserved(Currency currency) private view returns (uint256) {
        return currency == _key.currency0 ? burnReserve0 + keeperReserve0 : burnReserve1 + keeperReserve1;
    }

    function _available(Currency currency) private view returns (uint256) {
        return _idle(currency) - _reserved(currency);
    }

    function _netFee(uint256 fee) private pure returns (uint256) {
        return fee - fee * BURN_BPS / 10_000 - fee * KEEPER_BPS / 10_000;
    }

    /// @notice Amounts excluded from LP NAV for the next buyback and keeper payment.
    function feeLiabilities() external view returns (uint256 amount0, uint256 amount1) {
        (,, uint256 fee0, uint256 fee1) = math.positionAssets(address(this), false);
        amount0 = burnReserve0 + keeperReserve0 + fee0 - _netFee(fee0);
        amount1 = burnReserve1 + keeperReserve1 + fee1 - _netFee(fee1);
    }

    function _assets(bool roundUp) private view returns (uint256 amount0, uint256 amount1) {
        if (emergencyMode) return (_rawBalance(_key.currency0), _rawBalance(_key.currency1));
        amount0 = _available(_key.currency0);
        amount1 = _available(_key.currency1);
        (uint256 principal0, uint256 principal1, uint256 fee0, uint256 fee1) =
            math.positionAssets(address(this), roundUp);
        amount0 += principal0 + _netFee(fee0);
        amount1 += principal1 + _netFee(fee1);
    }

    function _quoteDeposit(uint256 max0, uint256 max1, uint256 incomingNative)
        private
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        // Bound input budgets, while allowing donations to remain in the asset accounting.
        if (max0 > uint128(type(int128).max) || max1 > uint128(type(int128).max)) revert InvalidAmount();
        uint256 supply = totalSupply();
        if (supply == 0) {
            (int256 sum, uint256 sigma8) = moments();
            (int24 lower, int24 upper) = math.bands(sum, sigma8, _key.tickSpacing, rangeSigma);
            (uint160 price,,,) = poolManager.getSlot0(poolId);
            uint128 initial = math.liquidityForAmounts(price, lower, upper, max0, max1, _capacityFor(lower, upper));
            if (initial <= MINIMUM_SHARES) return (0, 0, 0);
            // Pull only what the minted liquidity costs, never the unused side of the budget.
            (amount0, amount1) = math.amounts(price, lower, upper, initial, true);
            return (initial - MINIMUM_SHARES, amount0, amount1);
        }
        (uint256 assets0, uint256 assets1) = _assets(true);
        assets0 -= incomingNative;
        if (assets0 == 0 && assets1 == 0) revert InvalidAmount();
        uint256 shares0 = assets0 == 0 ? type(uint256).max : FullMath.mulDiv(max0, supply, assets0);
        uint256 shares1 = assets1 == 0 ? type(uint256).max : FullMath.mulDiv(max1, supply, assets1);
        shares = Math.min(shares0, shares1);
        amount0 = Math.mulDiv(shares, assets0, supply, Math.Rounding.Ceil);
        amount1 = Math.mulDiv(shares, assets1, supply, Math.Rounding.Ceil);
    }

    function _pull(Currency currency, uint256 amount) private {
        if (amount == 0 || currency.isAddressZero()) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
    }

    function _emergencyWithdraw(uint256 shares, address receiver) private returns (uint256 amount0, uint256 amount1) {
        if (!emergencyMode) revert EmergencyInactive();
        _checkReceiver(receiver);
        if (shares == 0) revert InvalidAmount();
        uint256 supply = totalSupply();
        amount0 = FullMath.mulDiv(_rawBalance(_key.currency0), shares, supply);
        amount1 = FullMath.mulDiv(_rawBalance(_key.currency1), shares, supply);
        _burn(msg.sender, shares);
        _pay(receiver, amount0, amount1);
        emit Withdrawn(msg.sender, receiver, shares, amount0, amount1);
    }

    function _pay(address receiver, uint256 amount0, uint256 amount1) private {
        if (amount0 != 0) _transferCurrency(_key.currency0, receiver, amount0);
        if (amount1 != 0) _transferCurrency(_key.currency1, receiver, amount1);
    }

    function _transferCurrency(Currency currency, address receiver, uint256 amount) private {
        if (currency.isAddressZero()) accountedNative -= amount;
        currency.transfer(receiver, amount);
    }

    function _checkCurrency(Currency currency) private view {
        if (!currency.isAddressZero() && Currency.unwrap(currency).code.length == 0) revert UnsupportedToken();
    }

    function _checkReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
    }

    function _requireInitialized() private view {
        if (!initialized) revert NotInitialized();
    }

    function _requireLive() private view {
        _requireInitialized();
        if (emergencyMode) revert EmergencyActive();
    }

    /// @dev Only trusted settlement/unwrap sources may send ETH. Forced ETH stays outside NAV.
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != WETH) revert UnexpectedNativeValue();
        if (msg.sender == address(poolManager) && initialized && _key.currency0.isAddressZero()) {
            accountedNative += msg.value;
        }
    }
}

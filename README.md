# SigmaHook v2 — keeper flywheel with operator parameters

Solidity 0.8.26 / Cancun Foundry project. `SigmaHook` manages one Uniswap v4 position and a basket of its two currencies, issuing transferable ERC-20 basket receipts (**sSHK**) directly. The separate tokenized-vault wrapper of v1 has been removed: the hook is the only share ledger. The rebalance trigger, the width of the redeployed range and the keeper cooldown are owner-set parameters with six presets, replacing the fixed 1.5σ / 3σ / 30-minute constants. Existing SHK token source and supply are unchanged.

## Build and verify

```sh
forge build
FOUNDRY_FUZZ_SEED=0x8e51b61561d782ae6da4336bbfca7a992dab30632683eb25cb82218c4f97b39f forge test
forge fmt --check
```

Dependencies are vendored in `lib/`; the build configuration, `remappings.txt` and `dependencies.lock.json` are unchanged. Tests use the real vendored PoolManager, actual CREATE2 deployment with the required hook bits, and local tokens. No RPC, keys, environment reads, network installation, FFI, or additional filesystem permissions are required by the tests. The seed above is supplied to Forge, not read by contracts or test cheatcodes.

## What changed in v2

| Area | v1 | v2 |
| --- | --- | --- |
| Share token | `SigmaHook` receipts (sSHK) wrapped by a separate tokenized-vault contract with its own share token | `SigmaHook` receipts (sSHK) only; the wrapper contract, the hook's getter for it and the wrapper's test file are deleted |
| Rebalance trigger | constant 1.5σ | `triggerSigma` (tenths of σ), default 15 |
| Redeployed range | constant SMA ± 3σ | `rangeSigma` (tenths of σ), default 30 |
| Keeper cooldown | constant `REBALANCE_INTERVAL = 30 minutes` | `cooldown` (seconds), default 1800 |
| `BandMath.deviates` | `(tick, sum, sigma8)` | `(tick, sum, sigma8, triggerSigma)` → `10·|8·tick − sum| > triggerSigma·sigma8` |
| `BandMath.bands` / `SigmaMath.bands` | `(sum, sigma8, spacing)` | `(sum, sigma8, spacing, rangeSigma)` → width `rangeSigma·sigma8 / 10` |

With the defaults every formula reduces exactly to v1: `10·d > 15·s ⇔ 2·d > 3·s` and `30·s/10 = 3·s`. The constructor signature, hook flags (`0x1040`: `afterInitialize` + `afterSwap`), storage of the feed, fee split, buyback and emergency paths are unchanged.

## Architecture and units

| Contract | Responsibility | Units |
| --- | --- | --- |
| `SigmaToken` | Existing fixed-supply SHK launch token | SHK base units |
| `SigmaHook` | Pool position, idle balances/claims, basket entry/exit, statistics, keeper fee pipeline, operator parameters | `sSHK` basket receipts; two-currency `totalAssets()` |
| `SigmaMath` (`hook.math()`) | Stateless calculation/view helper, immutable and without custody | Band, price, position and liquidity calculations |
| `PermanentTokenLock` (`hook.burnSink()`) | Irrecoverable buyback custody if the token rejects zero-address transfers | Launch tokens held forever |

Each receipt owns its fraction of pool principal, net uncollected fees, idle ERC-20/native balances, and ERC-6909 claims. Yield increases the underlying value of a receipt. The 1,000 genesis receipt units stay permanently locked in the hook.

Typical entry: read `poolKey()` and `previewDeposit(max0,max1)`, approve the exact ERC-20 requirements (for a native pair send `max0` ETH), then call `deposit(max0,max1,minReceipts,receiver,deadline)`. Typical exit: `withdraw(receipts,min0,min1,receiver,deadline)`. During emergency mode call `emergencyWithdraw`, including its partial/alternative-recipient overload. Receipts transfer like any ERC-20.

## Operator parameters

Three live parameters drive the keeper flywheel. All three have a public getter; all setters are `onlyOwner` (`Ownable2Step`, ownership cannot be renounced).

| Parameter | Type | Unit | Default | Direct setter | Bounds |
| --- | --- | --- | --- | --- | --- |
| `triggerSigma` | `uint8` | tenths of a sigma | 15 (1.5σ) | `setTriggerSigma(v)` | 5 ≤ v ≤ 50, revert `"bounds"` |
| `rangeSigma` | `uint8` | tenths of a sigma | 30 (3.0σ) | `setRangeSigma(v)` | 10 ≤ v ≤ 50, revert `"bounds"` |
| `cooldown` | `uint32` | seconds | 1800 | `setCooldown(v)` | 300 ≤ v ≤ 86400, revert `"bounds"` |

Presets (`presets(i)` returns `(trigger, range, cooldown)`), loaded as a set by `setMode(i)`, which emits `ModeChanged(i)` and reverts `"invalid mode"` for `i ≥ 6`:

| Mode | Name | trigger | range | cooldown |
| --- | --- | --- | --- | --- |
| 0 | SLEEP | 30 (3.0σ) | 30 (3.0σ) | 3600 s |
| 1 | STANDARD | 15 (1.5σ) | 20 (2.0σ) | 1800 s |
| 2 | AGGRESSIVE | 10 (1.0σ) | 15 (1.5σ) | 900 s |
| 3 | MAX | 5 (0.5σ) | 10 (1.0σ) | 300 s |
| 4 | DEFENSIVE | 30 (3.0σ) | 40 (4.0σ) | 7200 s |
| 5 | PAUSED | 255 | 255 | `type(uint32).max` |

`pause()` sets only `triggerSigma = 255`; `resume()` sets only `triggerSigma = presets[1].trigger` (15) and leaves `rangeSigma` and `cooldown` as they were. `setMode(5)` additionally sets the cooldown to about 136 years, so `flashRebalance` reverts `RebalanceTooSoon` until the owner loads another mode. Note that the fresh-deployment defaults (15 / 30 / 1800) are not identical to the STANDARD preset (15 / 20 / 1800): the default range is v1's 3σ, STANDARD's is 2σ.

Where the parameters act:

- `flashRebalance(key)`: reverts `RebalanceTooSoon` while `block.timestamp < lastRebalance + cooldown`, then `WithinThreshold` unless `BandMath.deviates(tick, sum, sigma8, triggerSigma)`. Equality never qualifies. Lowering the cooldown applies at once; raising it applies from the last rebalance timestamp.
- Band selection: `_afterInitialize` (launch band, zero sigma), the first deposit's band refresh and quote, `_rebalance` and `proposedBands()` all pass `rangeSigma` to `SigmaMath.bands`. A change takes effect at the next of these events; the position already deployed is not moved until a rebalance fires.
- `afterSwap` only samples the execution tick. No parameter is read there, so parameter changes never affect swap gas or success.

Properties the operator should know:

- The current tick is normally the newest of the eight samples, so its distance from the SMA cannot exceed √7 ≈ 2.65σ, and a single outlier swap after a flat feed is exactly that. A trigger at or above 27 (2.7σ), which includes SLEEP and DEFENSIVE at 3.0σ, therefore fires only on small moves where the floored `sigma8` tips the integer comparison, or when the hook's own internal balancing swap (which does not sample) left the tick off the feed. Treat those two presets as "nearly never rebalance", not as a 3σ oracle. `pause()` at 25.5σ cannot be reached from any eight-sample feed.
- `rangeSigma = 255` (PAUSED) widens the proposed band to 25.5σ. It matters only if a first deposit or a rebalance happens while paused; the cooldown of `setMode(5)` prevents the latter, and the owner should load a real mode before inviting the first deposit.
- Sigma is the population standard deviation of eight execution ticks, in eighths of a tick, floored; it is not a TWAP and can be moved by eight swaps in one block. Tighter triggers (AGGRESSIVE, MAX) rebalance more often and expose the position to more adverse-selection and keeper-payout cost; the owner chooses that trade-off.

## Keeper execution and fee accounting

`afterSwap` validates the bound pool, reads the execution tick, writes one circular-buffer slot and emits `SampleRecorded(index,tick)`. It performs no statistics, swaps, liquidity changes, fee payouts or rebalance. The buffer has eight execution samples, initially seeded with the launch tick. Own internal swaps do not reenter the hook under v4 dispatch rules.

Anyone may call **`flashRebalance(PoolKey key)`**. It reverts unless the basket is live, the key matches, external receipts exist, at least `cooldown` seconds have passed since `lastRebalance()`, and the current tick lies strictly beyond `triggerSigma/10` sigma from the running SMA. The new range is SMA ± `rangeSigma/10` sigma, rounded outward to the tick-spacing grid; a zero-width band still gets one spacing on each side.

One hook-initiated unlock removes the old position, allocates harvested fees, processes buybacks, pays the caller, balances inventory and redeploys principal plus net yield. Only the manager's separate `feesAccrued` result is treated as fees; `callerDelta` already contains those fees and is never counted twice. For each currency and harvest with fee amount `F`: buyback reserve `floor(F·2000/10000)` (20%), keeper reserve `floor(F·100/10000)` (1%), LP yield the remainder. Reserves are recognised on every harvest, including deposits and withdrawals; `feeLiabilities()` reports the uncollected allocations. Raw token donations are LP assets and incur no split.

The launch-token allocation is disposed directly. The paired-currency allocation is swapped in the bound pool into the launch token, using actual swap debits/credits and the statistical range price limit. The keeper reserve is paid in its original pool currencies to the `flashRebalance` caller before reinvestment. A failed receiver or token transfer reverts the entire operation. If the paired buyback cannot be fully filled, its unspent amount stays in `burnReserve0/1`, excluded from LP assets, and `BuybackDeferred` reports it; a later eligible rebalance retries it. If no nonzero position can be funded, `InvestmentDeferred` and `investmentPending` make that explicit and `retryInvestment(key)` retries the selected range without a bounty or a cooldown reset.

## Burn policy

The live SHK contract inherits OpenZeppelin ERC-20, rejects `transfer(address(0),amount)`, and exposes no public burn. The hook attempts the zero-address transfer; if the token refuses it, the exact amount goes to the newly created **`PermanentTokenLock`**, which has no owner, functions, approval path, withdrawal, self-destruct, delegatecall or upgrade mechanism. `LaunchDisposed(amount,zeroAddressTransfer)` distinguishes the paths. For SHK the lock path reduces circulating supply but not `totalSupply()`.

## Native ETH

`receive()` accepts only the PoolManager or the once-configured `WETH` source. `accountedNative` tracks native deposits, manager receipts, payments and refunds. `rescueStrayETH()` is owner-only and sends only `address(this).balance - accountedNative` to the current owner; the owner cannot rescue native pool principal, claims, fee reserves or emergency withdrawal assets.

## Deployment parameters

Constructor: `(IPoolManager manager_, address owner_, address launchToken_, address factory_)`, all nonzero; the manifest fills them as `$poolManager`, `$owner`, `$token`, `$factory`. Ownership is assigned to `owner_`, never the deploying factory. The constructor also deploys `SigmaMath` and `PermanentTokenLock` and fills the preset table; it makes no external calls. CREATE2 hook bits are `0x1040`; re-mine the salt for the final creation code with `script/MineSalt.s.sol`, since any code change changes the CREATE2 hash. The runtime is within 200 bytes of the EIP-170 limit (24,376 of 24,576 bytes with the pinned compiler settings); any further addition to the hook needs a corresponding removal or a move into `SigmaMath`.

Factory-only initialization binds one pool permanently. Required pool fee is 12,500 pips (1.25%), spacing is 60, one currency must be the immutable launch token, and the other may be native ETH or a standard ERC-20. There is no pool reassignment or upgrade.

Pinned project inputs identify Robinhood Chain, chain ID **4663**, with the existing SHK token `0x4fe865ad3b3ef64b2af9c38c78abf5c6e68c1164`, the immutable Sprint 1 hook `0xcc0551d738d964a2d68ac3674e7fe4a2e69f1040` and PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`. These are input records, not newly verified on-chain addresses. No transactions, deployment, migration, or token mint were performed by this assignment. Updating source cannot patch an immutable live hook: a new hook and pool must be deployed and reviewed, and existing LPs migrate voluntarily. Holders of v1 wrapper shares redeem them on the v1 wrapper for v1 receipts and exit the v1 hook; v2 has no wrapper to migrate into.

The network input marks `extendedSwapParams: true`, while the vendored core uses upstream three-field `SwapParams`. Local tests establish correctness against the vendored ABI only; the operator must verify the target manager's swap/callback ABI before deploying.

## After launch

- **Mode:** the hook starts at the v1 defaults (15 / 30 / 1800). The owner calls `setMode(m)` with the preset that matches the intended risk posture, or the individual setters within their bounds. `pause()` stops keeper rebalances without touching the range or cooldown; `resume()` restores the 1.5σ trigger. No value here is secret or external: the owner picks it.
- **Optional WETH source:** owner calls `setWETH(verifiedWrappedEtherAddress)` once, only if WETH-source ETH reception is needed. The supplied network inputs contain no WETH address, so none is invented. Until configured, only the PoolManager may send ETH through `receive()`.
- **Operator:** verify constructor arguments, hook flags, `poolKey()`, `math()` and `burnSink()`; verify Cancun and manager ABI compatibility, factory initialization, fee/spacing and currency order. Publish the new hook address separately from the historical deployment. Never redeploy or re-mint SHK.
- **Keepers:** read `triggerSigma()`, `rangeSigma()`, `cooldown()` and `lastRebalance()` rather than assuming constants; simulate `flashRebalance(key)` and submit when eligible. Gas is the keeper's expense; the 1% bounty does not guarantee profit. Monitor `ModeChanged`, `InvestmentDeferred` and `BuybackDeferred`.
- **Owner:** operate the two-step ownership transfer, the parameter setters and the irreversible emergency exit, and rescue only stray ETH. Emergency activation collects all pool assets, cancels unexecuted fee allocations back to LPs, and pays the owner nothing; thereafter holders redeem raw assets without the manager.
- **Release reviewer:** perform an independent adversarial review and actual-chain integration rehearsal before public capital. See [security review](docs/SECURITY.md) and [test coverage](test/README.md).

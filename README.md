# SigmaHook v2 — keeper flywheel with operator parameters

Solidity 0.8.26 / Cancun Foundry project. `SigmaHook` manages one Uniswap v4 position and a basket of its two currencies, issuing transferable ERC-20 basket receipts (**sSHK**) directly. The separate tokenized-vault wrapper of v1 has been removed: the hook is the only share ledger. The rebalance trigger, the width of the redeployed range and the keeper cooldown are owner-set parameters with six presets, replacing the fixed 1.5σ / 3σ / 30-minute constants. Existing SHK token source and supply are unchanged.

## Build and verify

```sh
forge build
FOUNDRY_FUZZ_SEED=0xc84cd5248922f87e15fc9a5277917df94609ac4718540c324edc66cc0c98531b forge test
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
| `DeployFactory` | Owner-operated CREATE2 deployment and pool creation; no constructor arguments | Fixed initial owner, immutable hook creation code |
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

## Factory deployment and CREATE2 parameters

[`src/DeployFactory.sol`](src/DeployFactory.sol) takes **no constructor arguments**. Its initial OpenZeppelin `Ownable` owner is explicitly `0xdbeab8243F318F1bBF815d85a8A869def1510b61`, regardless of who deploys it. Both `deployHook` and `createPool` are owner-only. Restricting deployment prevents another caller from consuming the recorded salt first. The factory records its own successful hook deployments and refuses pool creation for unknown hooks.

`deployHook(bytes32 salt,address manager,address owner,address token)` executes CREATE2 **in the factory** and returns the new hook address. It supplies exactly `(manager, owner, token, address(this))` to the unchanged `SigmaHook` constructor. The hook owner is independent of the factory owner. Constructor errors bubble up; a duplicate salt/init-code combination reverts without affecting the existing hook. `HookDeployed` records the hook, salt, owner, manager and token.

The hook's creation code is 32,956 bytes, so embedding `new SigmaHook` in the factory's runtime would exceed EIP-170's 24,576-byte limit. The factory constructor instead stores that exact code in two immutable, STOP-prefixed code stores using the already-vendored SSTORE2 library. They are created internally during Tx 1, require no separate transactions, and have no callable mutation or destruction path. At deployment the factory reads both pieces, appends the constructor arguments and executes CREATE2 itself. There is no proxy, delegatecall or external bytecode supplier. The deployed factory runtime is **2,227 bytes**, its creation code is **35,823 bytes** (below EIP-3860's 49,152 bytes), and each code store is **16,479 bytes**. The hook runtime remains **24,376 bytes**, leaving 200 bytes of EIP-170 headroom.

The factory address is determined by regular CREATE from the supplied EOA at nonce **2**, independent of factory bytecode:

```text
RLP: 0xd694dbeab8243f318f1bbf815d85a8a869def1510b6102
FACTORY_ADDRESS = keccak256(RLP)[12:]
```

This was computed offline with `cast compute-address 0xdbeab8243F318F1bBF815d85a8A869def1510b61 --nonce 2`, reproduced by `MineSalt.factoryAddress()`, and tested against an actual local CREATE from that EOA at nonce 2. Internal code-store deployments use the factory's nonce and do not consume additional EOA nonces.

| Parameter | Value | Source |
| --- | --- | --- |
| EOA creating factory / initial factory owner | `0xdbeab8243F318F1bBF815d85a8A869def1510b61` | This brief |
| EOA nonce for factory CREATE | `2` | This brief; not a live nonce check |
| CREATE2 deployer / hook `factory_` | `0x44aa80c4F3807C0b5A2c880158E0141A9553e199` | Derived from EOA and nonce |
| Hook `manager_` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | This brief |
| Hook `owner_` | `0xdbeab8243F318F1bBF815d85a8A869def1510b61` | This brief |
| Hook `launchToken_` / existing SHK | `0x4fE865Ad3b3eF64B2af9C38c78aBf5C6e68C1164` | This brief |
| Chain | Robinhood, `4663` | Context only; no RPC queried |
| Build | Solidity 0.8.26, Cancun, via-IR, optimizer 200 runs, no bytecode metadata hash | Unchanged `foundry.toml` |

## CREATE2 salt mining

`script/MineSalt.s.sol` runs locally with constants or function arguments. It needs no key, RPC, environment reads, FFI or broadcast. The CREATE2 address is `keccak256(0xff ‖ deployer ‖ salt ‖ keccak256(initCode))[12:]`; `initCode` is the hook creation code followed by `abi.encode(manager, owner, token, factory)`.

The search requires the low **16 bits** to equal `0x1040`. This is stricter than v4's low-14-bit permission check, and yields exactly `afterInitialize | afterSwap`. It returns the lowest salt in the requested window or reverts `SearchExhausted`. The window below is `[0, 4194304)`.

Reproduce the requested full-argument search:

```sh
forge build
forge script script/MineSalt.s.sol \
  --sig "mineWith(address,address,address,address,address,uint256,uint256)" \
  0x44aa80c4F3807C0b5A2c880158E0141A9553e199 \
  0x8366a39CC670B4001A1121B8F6A443A643e40951 \
  0xdbeab8243F318F1bBF815d85a8A869def1510b61 \
  0x4fE865Ad3b3eF64B2af9C38c78aBf5C6e68C1164 \
  0x44aa80c4F3807C0b5A2c880158E0141A9553e199 0 4194304
forge script script/MineSalt.s.sol --sig "verifyRecorded()"
```

### Recorded result

```text
FACTORY_ADDRESS: 0x44aa80c4F3807C0b5A2c880158E0141A9553e199
HOOK_SALT: 0x000000000000000000000000000000000000000000000000000000000001762c
HOOK_ADDRESS: 0xB259cb6965FD49df82a415920Ac61DF370cB1040
INIT_CODE_HASH: 0xd09c16e2448f647d24add8afafe9f5e94196ab26a56d0592ff129a016827aa3c
```

[`docs/create2-salt.json`](docs/create2-salt.json) records the same result, parameters, derivation, commands and sequence. This record **supersedes the previous salt mined for `0x735121A546092F31050A867FD7E3A750C7B0EFF9`**. The new salt is decimal 95,788; the search checks 95,789 candidates including zero. Tests prove every lower salt fails and that the production factory really deploys the hook at the recorded address.

`verifyRecorded()` recomputes the factory address, hook init-code hash and CREATE2 prediction. It reverts `ResultStale` or `AddressMismatch` when they disagree with the record. It checks local bytecode, not live chain state. A change to the EOA nonce, hook creation code, compiler settings or any hook constructor argument requires re-mining and refreshing the script's `RECORDED_*` constants, tests and recorded documentation together. The bare `run()` and `mineFor(OWNER)` now use this nonce-2 factory; `mineFor(otherOwner)` changes only the hook owner. The factory's initial owner stays fixed.

## DEPLOY_SEQUENCE

All five main operations are signed by `0xdbeab8243F318F1bBF815d85a8A869def1510b61`. Nothing was broadcast by this assignment.

1. **Tx 1 — EOA nonce 2:** deploy `src/DeployFactory.sol:DeployFactory` with regular CREATE and no constructor arguments. Expect factory `0x44aa80c4F3807C0b5A2c880158E0141A9553e199`. Using a CREATE2 deployment service instead would give a different factory address and invalidate this record.
2. **Tx 2 — to factory:** `deployHook(0x000000000000000000000000000000000000000000000000000000000001762c, 0x8366a39CC670B4001A1121B8F6A443A643e40951, 0xdbeab8243F318F1bBF815d85a8A869def1510b61, 0x4fE865Ad3b3eF64B2af9C38c78aBf5C6e68C1164)`. Check `HookDeployed` and the returned hook `0xB259cb6965FD49df82a415920Ac61DF370cB1040`.
3. **Tx 3 — to factory:** `createPool(0xB259cb6965FD49df82a415920Ac61DF370cB1040, 0x0000000000000000000000000000000000000000, 0x4fE865Ad3b3eF64B2af9C38c78aBf5C6e68C1164)`. Zero here is the defined **native ETH currency sentinel**. The factory calls the hook's manager with `PoolKey(ETH, SHK, 12500, 60, hook)`. It rejects invalid ordering, a missing launch token, an already-bound hook and a manager that returns without initializing the hook.
4. **Tx 4 — to hook:** first LP calls `deposit(ethBudget, shkBudget, minShares, receiver, deadline)` with **`msg.value = ethBudget`**. Read `poolKey()`, the initialized price and a fresh `previewDeposit` quote first. The operator chooses funded budgets, the intended receipt receiver, a positive slippage minimum and a deadline. Unused native budget is refunded; only consumed SHK is pulled.
5. **Tx 5 — to hook:** `setMode(1)` selects **STANDARD** (`triggerSigma=15`, `rangeSigma=20`, `cooldown=1800`). This changes live parameters; it does not immediately move the existing position.

**SHK approval prerequisite:** the EOA must already have enough SHK allowance to the predicted hook before step 4. If it does not, send an additional `SHK.approve(hook, shkBudget)` transaction between steps 3 and 4. The list above describes the five requested main operations, not a guarantee of only five transactions. Without a prior allowance the actual EOA nonces are factory 2, hook deployment 3, pool creation 4, approval 5, deposit 6, mode 7. **Do not use nonce 2 for the approval.** The factory cannot approve tokens held by the EOA, and the existing token is never redeployed or re-minted.

Pool creation is owner-gated, but deposits become permissionless as soon as the pool is initialized. The sequence does not reserve the first LP slot for the EOA; the operator should quote the actual current state before depositing.

## Manager compatibility and operational responsibilities

The brief explicitly requires `poolManager.createPool(PoolKey)`. The protected vendored upstream `IPoolManager` instead exposes `initialize(PoolKey,uint160)`. `ICreatePoolManager` declares the requested extension without changing any dependency. The factory invokes **only `createPool((address,address,uint24,int24,address))`** on the manager read from the hook. It supplies no guessed price and has no fallback to upstream `initialize`.

The deployment operator must confirm that the supplied manager implements that extension, chooses an acceptable initial price, forwards the factory as the `afterInitialize` sender, and supports the hook's remaining swap/callback ABI. An upstream-only manager makes this factory's `createPool` revert. The local test adapter adds `createPool` over the real upstream manager using a fixture-only 1:1 price; it proves the factory call, caller identity, pool binding, deposit and exit flow, **not live-chain ABI or price compatibility**. No such adapter is deployed in production.

The operator must also confirm the EOA still has nonce 2, the predicted factory and hook addresses are unused, the manager and existing SHK addresses match the intended chain, and Cancun opcodes and transaction gas limits are supported. These are supplied assumptions, not checks completed offline. Verify source and constructor arguments before inviting liquidity. Re-run `verifyRecorded()` on the exact build to be deployed.

The factory owner may deploy more hooks, choose each hook's manager/owner/token, create a valid pool once per hook, transfer factory ownership with standard one-step `transferOwnership`, or renounce it. Renunciation permanently disables both factory operations, so must not happen before pool creation. Factory ownership grants no hook parameter, withdrawal or upgrade authority; hook ownership uses the existing separate `Ownable2Step` flow. The factory does not hold LP funds or provide a generic arbitrary-call interface. The code stores and hook factory binding cannot be changed.

Pinned project inputs identify the immutable Sprint 1 hook `0xcc0551d738d964a2d68ac3674e7fe4a2e69f1040`. It and the existing token remain unchanged on chain. A new hook and pool need review, and existing LPs migrate voluntarily. The project's prior network notes mention an extended swap ABI, while the vendored core uses upstream three-field `SwapParams`; actual-chain compatibility remains the operator's responsibility. Independent adversarial review is still required before public capital.

## After launch

- **Mode:** the hook starts at the v1 defaults (15 / 30 / 1800). The owner calls `setMode(m)` with the preset that matches the intended risk posture, or the individual setters within their bounds. `pause()` stops keeper rebalances without touching the range or cooldown; `resume()` restores the 1.5σ trigger. No value here is secret or external: the owner picks it.
- **Optional WETH source:** owner calls `setWETH(verifiedWrappedEtherAddress)` once, only if WETH-source ETH reception is needed. The supplied network inputs contain no WETH address, so none is invented. Until configured, only the PoolManager may send ETH through `receive()`.
- **Salt:** use the nonce-2 factory and the exact [recorded result](#recorded-result). Run `forge script script/MineSalt.s.sol --sig "verifyRecorded()"` on the deployment build. Re-mine after any change to factory address, hook creation code, compiler settings or hook arguments.
- **Operator:** verify constructor arguments, hook flags, `poolKey()`, `math()` and `burnSink()`; verify Cancun and manager ABI compatibility, factory initialization, fee/spacing and currency order. Publish the new hook address separately from the historical deployment. Never redeploy or re-mint SHK.
- **Keepers:** read `triggerSigma()`, `rangeSigma()`, `cooldown()` and `lastRebalance()` rather than assuming constants; simulate `flashRebalance(key)` and submit when eligible. Gas is the keeper's expense; the 1% bounty does not guarantee profit. Monitor `ModeChanged`, `InvestmentDeferred` and `BuybackDeferred`.
- **Owner:** operate the two-step ownership transfer, the parameter setters and the irreversible emergency exit, and rescue only stray ETH. Emergency activation collects all pool assets, cancels unexecuted fee allocations back to LPs, and pays the owner nothing; thereafter holders redeem raw assets without the manager.
- **Release reviewer:** perform an independent adversarial review and actual-chain integration rehearsal before public capital. See [security review](docs/SECURITY.md) and [test coverage](test/README.md).

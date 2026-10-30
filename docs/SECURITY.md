# Security review record — Sprint 2 / v2

Implementation self-review against the pinned security, address and L2 inputs. This is not an independent audit, fork test, on-chain verification, or a claim that production deployment is authorized. The existing token and immutable deployed hook are unchanged on chain.

## v2 delta: vault removal and operator parameters

- The v1 tokenized-vault wrapper is gone. The hook's own ERC-20 receipt is the only share ledger; nothing else holds receipts on holders' behalf, so the wrapper's allowance and rounding surface no longer exists.
- Three new owner powers: `setMode`, `setTriggerSigma` / `setRangeSigma` / `setCooldown`, and `pause` / `resume`. They change only when and how wide the keeper redeploys; they cannot move funds, change the fee split, the pool, the position salt or the emergency path, and they never run inside a PoolManager callback. Bounds are enforced in the setters (trigger 5–50, range 10–50, cooldown 300–86400 s); the presets bypass those bounds by design (PAUSED uses 255 / 255 / `uint32` max), so an owner-chosen preset is the only way to leave the bounded space.
- The owner can stall the flywheel (`pause`, PAUSED, SLEEP/DEFENSIVE at 3.0σ, or an 86,400 s cooldown) but cannot stall LP exits: `withdraw`, `emergencyWithdraw` and the factory's fee collect do not read any parameter. A stalled flywheel leaves the position where it is and keeps collecting fees there.
- Parameter changes are not front-runnable into a loss for LPs: `flashRebalance` reads the live values at call time, and the band a rebalance deploys is computed from the same feed and `rangeSigma` that `proposedBands()` shows. A keeper that simulated under old parameters simply reverts with `WithinThreshold` or `RebalanceTooSoon`.
- `rangeSigma * sigma8` and `triggerSigma * sigma8` are `uint256` products of a `uint8` and a value at most `8 * 887272`; no overflow is possible. `lastRebalance + cooldown` is a `uint256` sum with a `uint32` addend.
- The hook runtime sits 200 bytes under EIP-170; the size test in `SigmaHook.t.sol` and the protected floor both assert the limit.

## Salt mining tool

- `script/MineSalt.s.sol` is a simulation-only contract: it embeds the hook creation code as a constant, which puts it above the EIP-170 size limit, and it must never be deployed on chain. It holds no key, reads no environment and sends no transaction; `forge script` executes it locally and prints the result.
- The search predicate is the low 16 bits of the address equal to `0x1040`, stricter than v4's 14-bit `validateHookPermissions`. Any accepted salt passes the hook constructor's own check; any unmined salt makes the constructor revert `HookAddressNotValid`, so a wrong salt cannot produce a live hook with wrong flags. A failed window reverts `SearchExhausted` rather than returning a guess.
- The salt is a function of the deployer, the bytecode and the four constructor values. The owner `0xdbeab8243F318F1bBF815d85a8A869def1510b61` and its nonce 2 come from the brief. The CREATE2 deployer is the derived factory `0x44aa80c4F3807C0b5A2c880158E0141A9553e199`, which also fills `factory_`. `verifyRecorded()` checks the CREATE derivation as well as the hook prediction. No live nonce or chain state was queried.
- The recorded result (salt `0x1762c`, address `0xB259cb6965FD49df82a415920Ac61DF370cB1040`, init code hash `0xd09c…aa3c`) is pinned as `RECORDED_*` constants, recorded in `docs/create2-salt.json` and asserted by `test/MineSalt.t.sol` against the compiled artifact, so any source or settings change that moves the address fails the suite instead of silently invalidating the salt. `verifyRecorded()` gives the deployer the same check from the command line; it reverts `ResultStale` or `AddressMismatch` rather than printing a stale value. The recorded address was not checked for existing code on chain.
- The tool cannot see the chain. The deployer must confirm the predicted address is empty and that the pinned PoolManager and token addresses still match the live chain before sending the deployment. `test/helpers/Create2Factory.sol` remains a generic mining-test helper. The production path is now `src/DeployFactory.sol`; its tests execute a real CREATE from the EOA at nonce 2 and then the real factory's CREATE2, without etching the factory or its code stores.

## Factory implementation self-review

- **Ownership:** the no-argument constructor assigns the exact requested EOA, never `msg.sender` or `tx.origin`. Both deployment and pool creation require the current factory owner. The deployment gate prevents unauthorized consumption of the known salt. Standard Ownable transfer/renunciation is separate from the hook's Ownable2Step ownership; renouncing too early prevents pool creation permanently. Only the hook owner controls modes, pause and emergency exit.
- **Executable size:** the unchanged SigmaHook creation code is 32,956 bytes. Putting it in the factory runtime would exceed EIP-170. The factory constructor writes two immutable STOP-prefixed SSTORE2 stores (16,479 bytes each). The factory runtime is 2,227 bytes and init code is 35,823 bytes. The test suite compares reconstructed bytes to the compiled hook artifact, checks EIP-170/EIP-3860 limits and deploys the actual factory. Code stores cannot execute the payload or be rewritten. There is no arbitrary-code input, proxy, upgrade path or production delegatecall.
- **CREATE2:** only this factory executes the opcode; the code stores never deploy the hook. Constructor arguments are appended in the required order, including this factory's address. Failed constructors bubble their errors, collisions revert `HookDeploymentFailed`, and only success updates `isHook` and emits `HookDeployed`. Tests prove exact recorded address, owner, manager, launch token, factory binding, hook flags, and retry/rollback after failures.
- **Pool binding:** `createPool` accepts only a hook this factory deployed, requires sorted distinct currencies including that hook's launch token, fixes fee 12,500 and spacing 60, and selects the manager from the hook. It refuses a previously initialized hook and requires initialization to have completed before reporting success. The hook retains its own factory-sender check and permanent one-pool binding. A reverting/no-op manager cannot leave a successful factory initialization record.
- **External interactions:** the factory has no LP fund custody or token allowances. Fixed hook creation makes no calls to supplied manager/token contracts. `createPool` calls the chosen manager; during launch that manager cannot reenter either owner-gated factory function as the EOA. The owner explicitly chooses each hook's immutable manager, so manager trust and later transfers of factory ownership to contracts remain operator responsibilities.
- **ABI assumption:** the required manager extension is `createPool(PoolKey)`, absent from protected upstream dependencies. A local interface declares it. No initial price is invented and there is no fallback to `initialize`. Tests demonstrate that upstream-only and no-op managers fail. The test-only extension uses the actual upstream pool accounting and a fixture price; it does not establish the supplied live manager's extension, initial-price policy or swap ABI.
- **Operations:** the five requested main actions are documented. A separate EOA-to-hook SHK approval is necessary before deposit unless already present; it must not consume nonce 2 ahead of factory deployment. Pool deposits are permissionless after initialization, so the EOA's first-LP position is an operational intention, not an exclusive on-chain reservation.

This is implementation self-review against the pinned security reference. The offline assignment does not establish target-chain compatibility or replace the independent review described below.

## Fund boundaries

- The immutable manager and bound pool are the only strategy venue. Callback identity and the outstanding-unlock latch are checked. Own hook swaps skip callbacks under the vendored v4 dispatch rules. All operations finish with zero manager currency deltas.
- The actual manager liquidity delta determines first-deposit spending and shares. Only caller-owned tokens are pulled. Preview and execution use the same refreshed range. Refunds happen inside the initial unlock. Donations cannot be silently included in a depositor's invested budget.
- LP assets exclude reserved buyback and keeper proceeds, including uncollected fee allocations. `feesAccrued` is separated from principal; `callerDelta` includes fees already. Reserve debits use actual buyback inputs and outputs. Fees harvested by deposits cannot be paid to those depositors or reinvested twice.
- Native balances have a separate accounting ledger. Only pool settlement native receipts enter that ledger. The owner's rescue is bounded by surplus over the ledger. Forced ETH cannot inflate LP quotes or make an LP withdrawal available to the owner.
- Buyback proceeds enter a zero-address transfer or an immutable lock with no callable withdrawal logic. The current token requires the lock. Locking is not total-supply burning. No recipient supplied by a keeper or owner can redirect it.

## Adversarial paths checked

| Path | Expected result |
| --- | --- |
| Wrong pool / wrong manager / unexpected unlock | Revert before funds move |
| Keeper too early / at or inside deviation threshold / no external shares / emergency | Revert with explicit gating error, against the live `cooldown` and `triggerSigma` |
| Non-owner or factory calls a parameter setter / owner passes an out-of-bounds value or mode | Revert; parameters unchanged |
| Owner pauses or loads PAUSED while LPs hold receipts | Keeper calls revert; deposits, withdrawals, emergency exits and the factory's fee collect are unaffected |
| Price jump, shallow or empty active liquidity | Nonzero investment or explicit persistent, redeemable pending inventory |
| Failed keeper payout or reentry | Whole rebalance rolls back; reentry is blocked |
| Zero-address-rejecting launch token | Buyback proceeds reach the permanent lock; rebalance remains live |
| Fees collected before keeper call | 20% and 1% remain reserved, excluded from LP pricing and investment |
| First deposit after price moves, asymmetric budgets, native refunds | Preview matches actual costs; only consumed assets leave depositor |
| Taxed/callback pair token | Exact-pull validation and reentrancy protection reject unsafe behavior |
| Forced ETH with funded native position or emergency vault | Rescue transfers only unaccounted surplus |
| Emergency after keeper cycles | LP assets become raw; remaining fee reservations are released; holder exits do not need manager |

Meaningful unit, fuzz and stateful accounting tests use the actual vendored manager and the assignment's specified seed. State-machine tests check custody conservation, receipt conservation, fee liabilities, position accounting, sample history, no outstanding flash debts and full emergency exits. Tests are independent of network, environment values and order. See the accompanying test README for coverage.

## Limits and release responsibilities

1. The eight execution ticks can be manipulated in one block. The requested timestamp/deviation gates and band price limits are not a trusted price oracle. Deeper routes remove starvation at the expense of larger permitted price movement. No unverified router/TWAP is configured implicitly.
2. The basket supports ordinary fixed-balance, untaxed native/ERC-20 assets. Token censorship, rebasing, upgrades or dishonest transfer returns can break liveness/accounting; exact pulls do not make a malicious token trustworthy.
3. If there is no counterparty liquidity or per-tick capacity, capital can remain idle. Pending investment can be retried without paying another keeper bounty. Unfilled buyback inputs remain liabilities until a later eligible rebalance; the owner cannot take them via ETH rescue. Emergency cancels remaining reservations back to shareholders.
4. A rejecting keeper only fails its own transaction. External swaps perform no fee distribution or investment work. Manager/token failure can still prevent emergency activation; successful activation removes that manager dependency for exits.
5. The initial 1,000 locked basket units are a permanent rounding/inflation defense, not a substitute for user slippage checks. Tiny donations/rounding may remain after the last external holder exits.
6. The old hook is immutable. This source release requires a separately reviewed deployment and voluntary liquidity migration using the existing token. The pinned chain advertises an extended swap ABI; the protected local dependency is upstream v4. Its compatibility must be established before deploying. This is not proven by local unit tests.
7. The owner's parameter powers are a trust assumption the brief asks for: a careless or hostile owner can keep the position in a stale range (never worse than v1's fixed 3σ band left alone) or rebalance as often as every 300 s at 0.5σ, which pays the 1% keeper bounty and incurs swap fees more often. The owner cannot extract LP funds through them. Governance of the owner key (multisig, timelock) is the operator's responsibility.

No Slither, Mythril, formal proof, independent review, or actual-chain deployment rehearsal is represented as completed here. An independent reviewer and the deployment operator must resolve the economic and manager-ABI risks before accepting public funds.

# SpongeBot (SPONGEBOT) — Uniswap v4 launch hook

A Foundry project for the SpongeBot launch on Ethereum mainnet: a fixed-supply ERC-20, a Uniswap v4
hook for its IMD pool that charges a decaying anti-snipe fee and a 1% staking fee, and a staking
vault that pays those rewards to SPONGEBOT stakers.

| Contract         | File                     | Role                                                                 |
| ---------------- | ------------------------ | -------------------------------------------------------------------- |
| `SPONGEBOT`      | `src/SPONGEBOT.sol`      | Launch token. Name "SpongeBot", symbol "SPONGEBOT", 18 decimals, 1e27 units minted to the deployer. |
| `SpongeBotHook`  | `src/SpongeBotHook.sol`  | Hook of the SPONGEBOT/IMD pool. Collects both fees, holds them, `sweep()` pays them out. |
| `SpongeBotVault` | `src/SpongeBotVault.sol` | Staking vault, created by the hook's constructor. Stake SPONGEBOT, earn IMD. |
| `HookFlags`      | `src/HookFlags.sol`      | Internal library: hook permission bits and address helpers.          |

No contract has an owner, a setter, a proxy, `delegatecall` or `selfdestruct`. Every library
function is `internal`, so the bytecode has no link placeholders.

## Build

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with
`optimizer_runs = 44444444` and `via_ir = true` (the settings v4-core itself uses so the
`PoolManager` tests deploy fits EIP-170), and `bytecode_hash = "none"` / `cbor_metadata = false` so
the build is reproducible. `ffi` is off and there are no `fs_permissions`.

Dependencies are vendored as ordinary files under `lib/` (no submodules):

- `lib/v4-core` — Uniswap v4-core `src/` at commit `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`,
  plus `test/utils/CurrencySettler.sol` needed by its test routers. Two test helpers that import
  OpenZeppelin (`ProxyPoolManager.sol`, `MockContract.sol`) were dropped; nothing here uses them.
- `lib/solmate` — `Owned.sol`, `ERC20.sol` and the mock v4-core imports.
- `lib/forge-std` — forge-std 1.17.0 `src/`.

## Fee mechanics

Both fees are taken in IMD (the paired currency) on top of the pool's static 1.25% LP fee
(tier 12500, never dynamic, never overridden). They are collected through `beforeSwap` /
`afterSwap` return deltas and held as IMD ERC-6909 claims on the PoolManager until swept. Nothing is
swapped, burned or donated inside a swap callback.

**Rate.** `feeBps() = antiSnipeBps() + 100`.

- Anti-snipe: `3000 * (10 - elapsed) / 10` basis points where `elapsed = block.number - poolOpenBlock`,
  i.e. 30% in the opening block, 27% one block later, ... 3% in block 9, 0% from block 10 on.
- Staking: 100 bps (1%) forever.

**Base.** The fee is always `rate × the IMD amount that actually moved through the pool` (what the
pool received on a buy, what it delivered on a sell). This makes the fee proportional to the fill
in every case:

| Swap                   | IMD side    | How the fee is taken                                                                 |
| ---------------------- | ----------- | ------------------------------------------------------------------------------------ |
| Exact-input sell       | unspecified | `afterSwap` returns `+fee` on the pool's real IMD output (`afterSwapReturnDelta`).  |
| Exact-output buy       | unspecified | `afterSwap` returns `+fee` on the pool's real IMD input.                             |
| Exact-input buy        | specified   | `beforeSwap` reserves `ceil(in × rate / (10000 + rate))` from the input; `afterSwap` recomputes the fee from the real fill and refunds the excess to the swapper as an IMD ERC-6909 claim. |
| Exact-output sell      | specified   | `beforeSwap` asks the pool for `ceil(out × rate / (10000 − rate))` extra; `afterSwap` reconciles the same way. |

In `afterSwap` the hook mints its fee to itself as an ERC-6909 claim and books it in
`pendingAntiSnipe` / `pendingStaking` (the staking share is `amount × 100 / 10000`, the rest is
anti-snipe). The hook's delta is therefore zero at the end of every swap. `pending()` returns the
sum.

**Sweep.** `sweep()` is callable by anyone, in its own transaction. It unlocks the PoolManager,
burns the claims, `take`s the anti-snipe share to the SIMD Hackathon vault
`0x3dd5f73dd1a4e62630fad3909673f130ad429985` and the staking share to `SpongeBotVault`, then calls
`vault.notifyReward(amount)`. Both recipients are fixed at construction. The claims are always backed
by IMD the pool holds, so a sweep cannot fail for lack of balance; the recipients are plain ERC-20
holders, so nothing can reject the transfer.

**Accepted swap domain.** The hook never reverts a real swap. The only reverts are
`UnrepresentableFee` for specified amounts so large that the reservation would overflow `int256` or
`int128` (for example `type(int256).max` exact-output or `type(int256).min` exact-input), which the
pool could not fill anyway.

**Known edge (first 10 blocks only in practice).** An exact-output sell with a price limit whose fill
is smaller than the reservation (fill < `rate / (10000 − rate)` of the requested output; under 45% of
the request at the 31% opening rate, under 1% afterwards) leaves the swapper's IMD delta in the
PoolManager slightly negative and an IMD claim larger than that; the net is still fill minus fee. A
router that settles every negative delta (as the v4 test router does) completes the swap; a router
that insists on a positive output delta (Universal Router `TAKE_ALL`, `V4Router._getFullCredit`)
reverts with `DeltaNotPositive`. The hook cannot change the swapper's specified-side delta after the
fill, so this is inherent to the reserve-and-refund design the brief mandates.
`test_sellExactOutputTinyFillNetsToFillMinusFee` pins this behaviour down. **Integrators:** during
the anti-snipe window use exact-input sells, or price limits that allow a full fill.

**Refund recipient.** The refund claim is minted to the `sender` the PoolManager reports, i.e. the
router that called `swap`; it is the only identity a hook can see. Routers that pass `takeClaims` /
claim-aware settlement receive it directly (the v4 test router used in the tests holds it and can
burn it in the same settlement); routers that never burn or transfer ERC-6909 claims (Universal Router,
`V4Router`) strand it on the router contract. On full fills the refund is at most 2 wei of rounding
dust; it only matters on a price-limited or liquidity-exhausted exact-input buy or exact-output sell
(about 23.7% of the unfilled input in the opening block, 1% after block 10). **Integrators:** route
such swaps through a claim-aware contract, or use limits that fill in full.

**Sweep coupling.** One `sweep()` pays both recipients in one unlock. IMD is a plain ERC-20 that
cannot reject a transfer, so neither leg can fail; if IMD ever gained a blocklist or pause that
refused the hackathon vault, the staking leg would be blocked with it until the transfer succeeds.

## Staking vault

`SpongeBotVault` uses a time-weighted reward-per-token accumulator: rewards are pro rata to
**stake × blocks held**, not to stake alone. `stake(amount)`, `unstake(amount)`, `claim()` and
`exit()` are available at any time; only the staker can move the staker's tokens.
`notifyReward(amount)` is callable only by the hook, after the hook has transferred `amount` IMD in.

**Epochs.** The time between two distributions is an epoch. Every staker accrues *stake-blocks*
(stake × blocks) inside the open epoch; `notifyReward` closes it and splits the reward (plus anything
queued) over the stake-blocks accrued since the previous distribution, then opens the next epoch. A
stake that exists for zero blocks around a distribution earns nothing from it, so the moment at
which the anyone-callable `sweep()` triggers the distribution cannot be used to capture rewards with
a flash stake: staking, sweeping and exiting in one block yields exactly zero. Stake held for one
block out of a thousand earns one thousandth, and so on. Rewards that arrive while no stake-blocks
have accrued (nothing staked, or everything staked in that very block) are kept in `queuedRewards`
and folded into the next distribution that has some.

Each epoch stores its start block, its reward rate per stake-block and the cumulative rate at its
start, so a staker who never touches the vault across many distributions is settled lazily in O(1)
on the next action. `earned(address)` returns what is claimable now, i.e. everything from closed
epochs; the open epoch's share is known only when it closes. Views: `earned(address)`,
`totalStaked()`, `stakedBalance(address)`, `points(address)` (stake-blocks in the open epoch),
`currentTotalPoints()`, `currentEpoch()`, `epochs(uint256)`, `queuedRewards()`.

**Rounding.** The rate floors, so under `stake-blocks / 1e18` wei of each distribution cannot be
represented by it; that part is re-queued for the next distribution rather than lost. What stays
unclaimable in the vault is under one wei per distribution plus one wei per staker per settlement.
The booked amount is the ceiling of the exact distribution, so the queued remainder can never also
be owed to a staker and claims never exceed the vault's balance.

## Deployment parameters

- Chain: Ethereum mainnet (chain id 1).
- Uniswap v4 PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`, passed as the first
  constructor argument (`$poolManager` in the manifest). Never hardcoded.
- Launch token: the second constructor argument (`$token`); the factory deploys `SPONGEBOT` just
  before the hook.
- Paired currency: IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals), a constant in the
  hook (`PAIRED_CURRENCY`). `beforeInitialize` accepts exactly one pool: `{SPONGEBOT, IMD}` with a
  static fee (any listed tier; the launch uses 12500) and any tick spacing (the launch uses 60), and
  refuses a second initialization, any other currency pair and the dynamic-fee flag.
- Hackathon vault: constant `HACKATHON_VAULT = 0x3dd5f73dd1a4e62630fad3909673f130ad429985`.
- Hook address: CREATE2-mined so the low 14 bits equal `0x20CC` =
  `beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta`
  (8192 + 128 + 64 + 8 + 4 = 8396). The constructor does not validate its own address; the deployer
  mines it, and `test_permissionBitsMatchAddress` plus the protected floor check it.
- The hook's constructor deploys `SpongeBotVault(token, IMD, hook)`; it calls no existing contract
  and requires no address to have code. Hook initcode is about 11.6 KB (EIP-3860 limit 49,152),
  runtime about 7 KB.
- The constructor only rejects zero addresses; `$poolManager` and `$token` are the only two
  arguments.

Manifest values for the launch.json step (not written here; the manifest step writes it):

```
kind: "univ4_hook"
token: { contract: "SPONGEBOT", name: "SpongeBot", symbol: "SPONGEBOT", decimals: 18 }
hook:  { contract: "SpongeBotHook",
         constructorArgs: ["$poolManager", "$token"],
         permissions: ["beforeInitialize", "beforeSwap", "afterSwap",
                       "beforeSwapReturnDelta", "afterSwapReturnDelta"] }
pool:  { pairedCurrency: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", fee: 12500, tickSpacing: 60,
         initialPrice: "79228162514264337593543950336" }
notes: "constructorArgs are the chain's Uniswap v4 PoolManager and the launch token; the hook's
        address must carry permission bits 0x20CC (beforeInitialize, beforeSwap, afterSwap,
        beforeSwapReturnDelta, afterSwapReturnDelta); fees in IMD on top of the 1.25% LP fee: an
        anti-snipe fee of 30% decaying linearly to 0 over the first 10 blocks, swept to the SIMD
        Hackathon vault 0x3dd5f73dd1a4e62630fad3909673f130ad429985, and 1% on every swap swept to
        the staking vault the hook deployed."
```

Hook configuration record (the v4 hook generator's canonical shape, implemented by hand on the
v4-core interfaces; no OpenZeppelin uniswap-hooks base is vendored):

```json
{
  "hook": "BaseHook", "name": "SpongeBotHook", "pausable": false,
  "currencySettler": false, "safeCast": false, "transientStorage": true,
  "shares": { "options": false },
  "permissions": { "beforeInitialize": true, "afterInitialize": false,
    "beforeAddLiquidity": false, "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true, "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false },
  "access": "none (immutable, no owner)", "info": { "license": "MIT" }
}
```

## Assumptions

- The launch factory mints the supply, seeds the pool (tokens only is fine: fees are claims and need
  no IMD in the manager), distributes the swarm's 10% and calls `PoolManager.initialize`. No contract
  here is allocated any supply; the vault only holds what users stake after launch.
- IMD is a standard 18-decimal ERC-20 without transfer fees or callbacks. The vault tolerates tokens
  that return no boolean.
- The anti-snipe clock starts at the block `beforeInitialize` runs, which is the factory's launch
  transaction.
- "30% on the paired currency side" is implemented as 30% of the IMD amount that passes through the
  pool. On an exact-input buy that is 30% of what the pool receives (23.1% of the gross input); on
  every other kind it is 30% of the pool-side IMD amount. The staking 1% follows the same base.
- The brief's wording "the launch pool's hook ... implements two immutable fees" is read as M1 + M2
  of the mechanics specification, which are authoritative where the wording differs.
- The token is the standard launch token: no fee, limit, mint, burn or admin function. The brief
  asks nothing of the token beyond name and symbol.

## Operational responsibilities (after launch)

There is nothing to configure: no owner, no setter. What someone has to do:

- Call `SpongeBotHook.sweep()` periodically (anyone, any wallet, no arguments). Until it is called,
  fees sit as claims in the PoolManager, the hackathon vault receives nothing and stakers earn
  nothing. A keeper or a cron on any funded wallet is enough; a sweep reverts with `NothingToSweep`
  when there is nothing to move.
- Stakers approve the vault for SPONGEBOT and call `stake`, then `claim` / `unstake` / `exit`.
- Nobody can rescue tokens sent to the hook or the vault by mistake.

## Tests

`forge test` runs 62 local tests plus a fork suite that skips without an RPC:

- `test/SPONGEBOT.t.sol` — supply, decimals, transfer, allowance, no admin or mint path.
- `test/SpongeBotVault.t.sol` — stake/unstake/claim/exit, pro rata by stake, by time and by both, a
  flash stake around a distribution earning zero (fixed and fuzzed), one-block stakes earning their
  one-block share, lazy settlement across many epochs, queued rewards, remainder re-queuing and
  solvency, access control, a conservation fuzz.
- `test/SpongeBotHook.t.sol` — permission bits vs. address, callbacks refuse non-manager callers,
  one-pool / wrong-pair / dynamic-fee refusals, factory initialization, anti-snipe decay per block,
  the four swap kinds (exact-in/out, buy/sell) through a real `PoolManager`, partial fills with a
  price limit on both specified-side kinds, the tiny-fill edge, the overflow guard, sweep to both
  vaults, rewards reaching stakers, a fuzz over amount / kind / block / limit asserting
  `fee == rate × pool IMD amount` and conservation, and a launch-like manager seeded with tokens only.
- `test/SpongeBotHookFork.t.sol` — mainnet fork with the real PoolManager and real IMD. Run with
  `MAINNET_RPC_URL=https://... forge test --match-contract Fork`. It passed against
  `https://ethereum-rpc.publicnode.com` at block 26152895 (7 tests: the four swap kinds, partial
  fills, sweep paying real IMD).

Tests read no environment except the fork test's optional `MAINNET_RPC_URL`, use inline
`forge-config` for fuzz runs, and pass in any order.

## Security notes

- Every callback checks `msg.sender == poolManager`; `unlockCallback` additionally requires the
  transient "sweeping" flag set by `sweep()`.
- `beforeSwapReturnDelta` is used only to reserve the IMD fee on the specified side; the hook never
  returns a delta on the launch token and never no-ops a swap.
- Reentrancy: `sweep()` zeroes the pending amounts before unlocking; the vault updates state before
  transfers; no ETH is handled anywhere.
- Tests passing is not an audit. The hook and vault hold user funds (claims and stakes) and should
  get an independent adversarial review before launch.

# Daffy ($DAFF) — Degenerate Assistance Fund Fund

A HyperEVM meme token backed by a USDC-launched treasury that goes 75% HYPE, buys big dips and only
sells HYPE after a rally. Unofficial parody of Hyperliquid's Assistance Fund — not affiliated with
Hyperliquid.

> **UNAUDITED.** These contracts have a thorough test suite but no external audit. Do not deploy with
> real funds until they have been audited.

## How it works

**Deposits.** USDC deposits mint DAFF 1:1, so NAV starts at $1. The window is 7 days. Daffy
launches after it if at least $100,000 is in, or as soon as deposits reach $10M (anyone can call
`finalizeLaunch()`). Until launch anyone can `withdrawDeposit` for their USDC back 1:1; if the
window ends under $100,000 it never launches and withdrawals stay open for good. `launchStatus()`
returns everything a deposit page needs.

At launch the treasury is split:

| Part | Share | Where |
| --- | --- | --- |
| HYPE held | 55% | HYPE spot on HyperCore |
| HYPE bid | 20% | WHYPE bid in the DAFF/WHYPE pool, 0.6–0.8× NAV |
| Dip fund | 20% | USDC supplied to HyperCore lending |
| USDC bid | 5% | USDC bid in the DAFF/USDC pool, 0.6–0.8× NAV |

Most exit money sits in the HYPE bid on purpose. Measured in HYPE, NAV rises when HYPE falls, so
in a crash the HYPE bid ends up further under NAV and can't overpay sellers. The USDC bid can, until
the next re-placement, so it's kept small: with nobody calling upkeep through a 70% HYPE crash it
could overpay by at most about 1.4% of the treasury.

- **Exits.** There is no redeem function. Holders sell DAFF into either pool. The treasury's bids sit
  at 0.6–0.8× NAV and never above the pool price, and the DAFF they buy is burned at the next
  re-placement, so every exit raises NAV for those who stay. Nothing defends NAV.
- **Premium.** The treasury's only DAFF asks sit at 2–10× NAV in both pools (10% of circulating DAFF
  each), so new DAFF is only ever minted at a premium.
- **Dip buys.** HYPE 25% / 40% / 55% below its highest upkeep price → a third of the dip fund comes
  out of lending and buys HYPE (the last tranche takes the rest). The levels reset at a new high.
  After bigger runs the dips must be deeper: every tranche moves 5 points deeper for each 50% the
  high is above the launch price, at most 15 points (launch $78: a $120 high buys at about −30% /
  −45% / −60%; from $195 up, −40% / −55% / −70%). `dipLevels()` returns today's three prices.
- **Rally trims.** HYPE over 85% of the treasury and within 10% of its high → sell back to 75%. The
  USDC goes to the dip fund. HYPE is never sold otherwise.
- **HYPE bid refills.** HYPE held on HyperCore tops up the DAFF/WHYPE bid, at most 5% of the
  treasury's HYPE per week after the first fill.
- **Incoming USDC** (premium sales, USDC fees): kept for the USDC bid up to its 5% target, then
  75% buys HYPE and 25% goes to the dip fund.
- **Borrow tranche (on from launch by default).** With `BORROW_AT_LAUNCH=true` (the deploy
  default) the first upkeep after the launch USDC lands switches the HyperCore account to portfolio
  margin (action 16, code 3; needs over $10k of account value). With it off, the migrator can turn
  it on later with `setBorrowing(true)`. After all three dip tranches have spent the dip fund, and
  with HYPE still 55% under its high, the treasury borrows up to 20% of its HYPE's value once and
  buys HYPE (only while the lending read works, so the debt is always visible). Rally trims and
  incoming USDC repay it. While a loan is open there are no HYPE bid refills and no new loans. If
  the debt passes 50% of the HYPE's value (liquidation: 0.95 margin ratio at HYPE's 0.65 LTV, so
  debt near 62%), it sells just enough HYPE to get back to 40%: the one case where HYPE is sold in
  a dump. If HyperCore ignores the switch, the borrow buy simply fails there and nothing else
  changes. Every other order is capped at the balance it spends, so portfolio margin never borrows
  by accident.
- **Upkeep.** `poke()` (anyone): collects fees daily, re-places a pool's positions when NAV moves
  5% in that pool's units or weekly, runs one HyperCore step, routes new USDC. It pays 1 USDC from a
  reserve of at most 20 rewards (filled from spare USDC) when it did real work, at most every 10
  minutes. The migrator can change the reward (up to 5 USDC) and interval (at least 10 minutes)
  with `setRewards` until the role is renounced.
- **Lending.** HyperCore's lending read (0x811) errors until an account first supplies, and an
  erroring read precompile burns all the gas it's given. The core gives each read 50k gas, seeds
  lending once with $10 when the read fails, and keeps the dip fund as spot USDC if it never works.

## HyperCore facts to verify (use test mode first)

| Fact | Used for |
| --- | --- |
| CoreWriter action 15 `(op, token, wei)` supplies (0) / withdraws (1) USDC; `wei` 0 = max | Dip fund |
| Precompile 0x811 returns `(borrow basis, borrow value, supply basis, supply value)` | Dip fund value. On mainnet it reverted for a fresh contract account; the core then skips lending and keeps the dip fund as spot USDC |
| `CoreDepositWallet.deposit(amount, 4294967295)` credits spot USDC next block | USDC in |
| `sendAsset` to `0x2000…0000`, token 0, moves USDC to the EVM (confirmed on mainnet) | Migration, test withdrawals |
| `sendAsset` to `0x2222…2222`, token 150, arrives as native HYPE (confirmed on mainnet) | HYPE bid refills |
| Under portfolio margin (action 16, code 3) a spot buy beyond the USDC balance borrows against HYPE, and 0x811's borrow value reports it | Borrow tranche |
| HyperSwap V3 pools call `hyperswapV3MintCallback` (confirmed on mainnet) | Pool positions |

Confirmed on mainnet so far: the USDC bridge in, the oracle, lending (after a first supply), the
HyperSwap callback name, HYPE spot buys, and USDC and HYPE sends from HyperCore back to the EVM.
Still to see live: portfolio margin from a contract (the first upkeep after launch switches it on).

Pools use the 0.3% fee tier by default (`POOL_FEE=3000`; set `POOL_FEE=10000` for 1%).

A quick test-mode check of lending, after launch (5 USDC = 500000000 in HyperCore's 8 decimals):

```bash
cast send $CORE "setManual(bool)" true --rpc-url $RPC --private-key $PRIVATE_KEY
cast send $CORE "testCoreAction(uint24,bytes)" 15 $(cast abi-encode "f(uint8,uint64,uint64)" 0 0 500000000) --rpc-url $RPC --private-key $PRIVATE_KEY
cast call $CORE "coreSnapshot()((uint256,uint256,uint256,uint256,bool))" --rpc-url $RPC   # 4th = supplied, 5th = lending readable
```

## Deploy

```bash
# .env: RPC, PRIVATE_KEY, MIGRATOR, TEST_MODE=true, LAUNCH_MINUTES=1440 (all other values default to mainnet)
# real launch: TEST_MODE=false and no LAUNCH_MINUTES (7 days, $100k minimum, $10M early)
# a small test launch can lower the bars: MIN_LAUNCH_USDC=10 EARLY_LAUNCH_USDC=1000
source .env
forge script script/DeployUSD.s.sol --rpc-url $RPC                       # dry run
forge script script/DeployUSD.s.sol --rpc-url $RPC --broadcast --slow    # ~14M gas: big blocks on
```

Then send the DaffyUSD address a few USDC on HyperCore (it activates the account), deposit with
`approve` + `deposit(amount)` on the USDC contract and DaffyUSD, and call `finalizeLaunch()`; in
test mode the migrator can launch before the window ends. Call `poke()` a few times (one block
apart) to let it buy HYPE, fill the HYPE bid and supply the dip fund.

Test mode: `testWithdraw(to, usdc, hype)`, `testCoreAction(kind, params)`, `testPullPools()`,
`setManual(bool)`, `endTestMode()`, and the early launch. `renounceMigrator()` ends test mode too.

## Deposit page

`frontend/index.html` is a single file: connect a wallet (it switches to HyperEVM), deposit USDC
(approve, then deposit), withdraw before launch (approve DAFF, then withdraw), with the deposit
total, the progress to $100,000 and $10M, and the countdown up top. It reads the chain through
`https://rpc.hyperliquid.xyz/evm`, so the total shows without a wallet.

- Set the contract: edit `DEFAULT_CORE` at the top of the script, or open the page with
  `?core=0xYourDaffyUSD`.
- Preview without a contract: `?demo=1`.
- Host it anywhere static: GitHub Pages, Vercel, Netlify, IPFS. Opening the file locally works too.

## Trading without a DEX website

`src/DaffySwap.sol` is a small router (no owner, holds nothing between calls) that trades straight
against Daffy's two pools: `buyWithUsdc`, `buyWithHype` (native HYPE in), `sellForUsdc`,
`sellForHype` (native HYPE out), each with a minimum out and a deadline, and `quote` (call it with
eth_call). A swap never runs past the edge of the treasury's own ask (buys) or bid (sells): a bigger
order fills what it can there and the rest stays with the trader. Deploy it any time after DaffyUSD:

```bash
CORE=0xYourDaffyUSD forge script script/DeploySwap.s.sol --rpc-url $RPC --broadcast
```

Then set `DEFAULT_SWAP` in `frontend/index.html` (or open the page with `&swap=0x…`). After launch
the page shows a Trade panel: buy or sell, against USDC or HYPE, with a live quote, the price in
× NAV, and the 1% minimum. `?demo=trade` previews it.

## Hardening (from the exploit review)

- **Orders are delayed on HyperCore.** Hyperliquid runs orders sent from the EVM "a few seconds"
  late, so for a few blocks the balances the contract reads don't show them. Acting on those reads
  repeated rally trims (HYPE sold down to ~34% instead of 75% in a test), and at launch swept the
  USDC into lending before the buy ran, so no HYPE was bought. Now, after any order or HYPE send,
  the strategy waits `ORDER_SETTLE_SECS` (default 20) before its next HyperCore step. Pool upkeep
  is not affected. Launch buying is one `MAX_TRADE_USD` chunk per wait.
- **Empty-pool prices are free to move.** With no liquidity around it, anyone can move a pool's
  price at no cost (before launch: anywhere). That made `finalizeLaunch` revert, or put the bids at
  a silly price. Now placement first tries to move the price back to the bid top / ask bottom the
  same free way (the treasury's swap callback refuses to pay anything, so it only works when it
  costs nothing), and the maths is clamped so no price can make launch or upkeep revert. A side
  effect: with no other liquidity in the way, each re-placement puts the bid back at 0.6-0.8x NAV
  instead of capping it at the last traded price.
- The mint callback now only pays while the contract itself is placing positions.

## Tests

`test/`: 147 tests: behaviour tests (both token orders in both pools) and a fuzzer, with and without
the borrow tranche, checking seven invariants: no USDC debt unless borrowing is on, never
liquidatable, every HyperCore action valid, bids placed under 0.8× NAV, upkeep never loses value,
accounting matches an independent count, and HYPE never sold more than 10% under its high (bar a
deleverage while a loan is open). The HyperCore mock is written from Hyperliquid's docs, not their code, and has no order book
or slippage.

## Layout

```
src/DaffyUSD.sol                     core: deposits, launch, pools, upkeep, migration, test mode
src/DaffyToken.sol                   the DAFF ERC-20 (core can be handed to a successor)
src/libraries/DaffyUSDHyperCore.sol  HyperCore: HYPE buys, dip tranches, trims, refills, lending
src/libraries/DaffyUSDPools.sol      one-sided bids and asks in a DAFF/quote pool
src/libraries/DaffyMath.sol          price, tick and liquidity maths
script/DeployUSD.s.sol               deploy script (mainnet defaults)
script/lookup_indices.py             print HyperCore indices for mainnet or testnet
frontend/index.html                  deposit / withdraw page
test/                                behaviour tests, fuzzer, HyperCore mock
```

## Build and test

```bash
git init
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install Uniswap/v3-core@6562c52e8f75f0c10f9deaf44861847585fc8129 Uniswap/v3-periphery@b325bb0905d922ae61fcc7df85ee802e8df5e96c
forge build && forge test
```


# TinyCLOB — External Interface Reference

This document describes the externally observable behavior of
`tiny_clob::tiny_clob`: every public function and struct a caller can use,
its parameter contract, its return values, its abort conditions, the events
it emits, and all documented border cases. It covers the module's public
API surface only — parameter contracts, return values, abort conditions, and
events an integrator observes — not internal data structures, algorithms, or
the reasoning behind any design choice.

## 1. Object model

- `OrderBook<Base, Quote>` has `store` only, no `key`. It cannot become a
  standalone Sui object or be shared via `sui::transfer::share_object`; it is
  meant to be embedded as a field inside an integrator's own object.
- `ClobAdminCap` has `store` only, no `key`. Like `OrderBook`, it cannot
  become a standalone Sui object or be independently transferred; it must be
  embedded as a field inside some other object with `key` to persist. It is
  minted once per book, at construction, and is the capability required by
  every function whose name begins with `clob_admin_`.
- `OrderTicket` has `store` only, no `key`. It is a plain value returned to a
  caller when a limit order rests on the book, and is required to cancel
  that order, reassign its owner, or claim its proceeds later. It is bound
  at minting time to the specific book's own object id, side, price, and
  order id.

## 2. Constructing a book

```
public fun new<Base, Quote>(
    min_size: u64,
    base_decimals: u8,
    quote_decimals: u8,
    precision: u8,
    exponent: u8,
    initial_last_price: u64,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap)
```

```
public fun new_with_event_id_override<Base, Quote>(
    min_size: u64,
    base_decimals: u8,
    quote_decimals: u8,
    precision: u8,
    exponent: u8,
    initial_last_price: u64,
    event_id_override: &UID,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap)
```

Both are callable by any address; no capability is required to construct a
book, and construction does not register or share the book anywhere. Both
mint and return a fresh `ClobAdminCap` alongside the book.

`new_with_event_id_override` additionally stamps every event this book ever
emits with `object::uid_to_inner(event_id_override)` instead of the book's
own object id (`new`'s default). This is fixed permanently at construction
and cannot be changed afterward. `event_id` is used solely for event
stamping and is never used for authentication anywhere in this module.

### `min_size`

Bounds order-placement size only — checked once, at the moment an order or
swap is submitted. It is never re-checked against the size of a resulting
fill or a partial-fill remainder, so a partial fill can leave a resting
order's remaining size below `min_size`. Such a remainder persists on the
book until it is cancelled by its ticket holder, fully consumed by a later
fill, or removed by `clob_admin_cancel_order`/`clob_admin_drain_step`.

### `base_decimals` / `quote_decimals` / `precision` / `exponent` /
### `initial_last_price`

See §3 (price representation).

### Construction-time abort conditions

| Condition | Abort code |
|---|---|
| `min_size == 0` | `EZeroMinSize` (1) |
| `min_size > 1_000_000_000_000_000` | `EMinSizeTooLarge` (3) |
| any of `base_decimals`, `quote_decimals`, `precision`, `exponent` `> 38` | `EDecimalsTooLarge` (28) |
| no valid `price_scale` exists for the declared inputs (§3) | `EPriceRangeInfeasible` (20) |
| `initial_last_price == 0` | `EZeroPrice` (14) |
| `initial_last_price` outside the book's declared representable range (§3) | `EPriceBelowDeclaredMin` (21) / `EPriceAboveDeclaredMax` (22) |

## 3. Price representation and validation

Every `price: u64` value used anywhere in this module is a raw, book-relative
integer, not a human-readable decimal. For a given book, the relationship
between a raw `price` and the corresponding true price (quote units per base
unit, in ordinary decimal terms) is:

```
true_price = (price / price_scale) * 10^(base_decimals - quote_decimals)
```

`price_scale` is a `u64` fixed for the lifetime of the book, readable via
`price_scale<Base, Quote>(book): u64`. It is derived at construction from
`base_decimals`/`quote_decimals`/`precision`/`exponent` as follows:

```
pow_base  = 10^base_decimals
pow_quote = 10^quote_decimals
pow_prec  = 10^precision
pow_exp   = 10^exponent

scale_lo = ceil(pow_base * pow_prec / pow_quote)
scale_hi = floor(u64::MAX * pow_base / (pow_quote * pow_exp))

price_scale = min(scale_hi, u64::MAX)
```

Construction aborts with `EPriceRangeInfeasible` (20) if `scale_lo >
scale_hi`, or if `scale_lo` itself does not fit in a `u64`.

`precision` and `exponent` jointly declare the range of true price the book
guarantees to represent: at least `10^-precision` and at most `10^exponent`.
A raw `price` decodes to a representable true price only if:

```
price_scale * pow_quote <= price * pow_base * pow_prec     (else EPriceBelowDeclaredMin, 21)
price * pow_base <= pow_exp * price_scale * pow_quote       (else EPriceAboveDeclaredMax, 22)
```

This check is applied to:

| Call site | Value checked |
|---|---|
| `new` / `new_with_event_id_override` | `initial_last_price` |
| `set_last_price` | `new_last_price` |
| `place_limit_order_bid` | `price` |
| `place_limit_order_ask` | `price` |
| `swap_bid` | `limit_price`, only when `Some` |
| `swap_ask` | `limit_price`, only when `Some` |

It is **not** applied to `place_market_order_bid`, `place_market_order_ask`,
or to `swap_bid`/`swap_ask` when `limit_price` is `None` — none of these
take a price parameter to validate in that case.

### `bid_escrow_amount`

```
public fun bid_escrow_amount<Base, Quote>(book: &OrderBook<Base, Quote>, price: u64, size: u64): u64
```

Returns `ceil(price * size / price_scale)` — the `Quote`-atom amount a
resting bid at `(price, size)` requires. Calling this with `price == 0`
returns `0` without aborting.

## 4. Price-band safeguard

```
public fun clob_admin_set_price_band_factor<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    factor: Option<u64>,
)
```

Requires `cap` to be the book's own `ClobAdminCap` (else `EWrongClobAdminCap`,
4). Sets (or, via `option::none()`, clears) the book's `price_band_factor`.
When `factor` is `Some(f)`, `f` must be `>= 1` (else `EZeroPriceBandFactor`,
25). `option::none()` is the constructor's default and disables the check
entirely.

When `price_band_factor` is `Some(factor)`, a checked price must satisfy:

```
price * factor >= last_price     (else EPriceBelowBand, 23)
price <= last_price * factor      (else EPriceAboveBand, 24)
```

This check is applied only to `place_limit_order_bid` and
`place_limit_order_ask` (both on their `price` parameter). It is **not**
applied to `place_market_order_bid`, `place_market_order_ask`, `swap_bid`,
or `swap_ask` — including `swap_bid`/`swap_ask` when `limit_price` is
`Some` (that value is still subject to the declared-range check in §3, but
never to the price band).

Every call to `clob_admin_set_price_band_factor` emits `PriceBandFactorSet {
order_book_id, factor }`, including a call that sets the same value the
book already has — there is no no-op skip on this event.

## 5. `last_price`

`last_price` is a per-book reference point with no public getter of its own
(other than a test-only accessor); it is observable only through its effect
on `price_band_factor` (§4). It is seeded to `initial_last_price` at
construction and can subsequently change in two ways:

**Automatically, on a real fill.** Whenever a match against a resting order
produces a nonzero fill, `last_price` is set to that resting order's price.
For a single order/swap that sweeps multiple resting price levels in one
call, `last_price` ends at the price of the *last* level that received a
nonzero fill, not the first, and not an average. An order or swap that
matches nothing leaves `last_price` unchanged.

**Explicitly, via:**

```
public fun set_last_price<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    new_last_price: u64,
    ctx: &TxContext,
)
```

Callable by any address — no capability parameter exists on this function.

Abort conditions:

| Condition | Abort code |
|---|---|
| `new_last_price == 0` | `EZeroPrice` (14) |
| `new_last_price` outside the book's declared range (§3) | `EPriceBelowDeclaredMin` (21) / `EPriceAboveDeclaredMax` (22) |
| a best bid exists and `new_last_price < best_bid` | `EResetPriceBelowBestBid` (26) |
| a best ask exists and `new_last_price > best_ask` | `EResetPriceAboveBestAsk` (27) |

If neither a best bid nor a best ask currently exists on the book, no bound
beyond the declared range applies — any value within the declared range is
accepted.

If `new_last_price` differs from the book's current `last_price`, the value
is updated and `LastPriceSet { order_book_id, last_price, setter }` is
emitted, where `setter` is the calling transaction's sender address. If
`new_last_price` equals the current `last_price`, the call succeeds as a
no-op: no state is written and no event is emitted.

`set_last_price` performs no pause or retiring check: it succeeds regardless
of whether the book is paused or retiring, and calling it does not interact
with, block, or otherwise affect the deletion sequence in §9.

### Documented limitation

When a book has neither a best bid nor a best ask, `set_last_price` accepts
any value in the declared range, and — because the function requires no
capability — any address can call it. On such a book, `last_price` (and
therefore the acceptance window of an active `price_band_factor`) can be
relocated to any declared-range value in a single transaction, by any
caller, at no cost beyond gas. This can cause subsequent
`place_limit_order_bid`/`_ask` calls at the actual market price to abort
with `EPriceBelowBand`/`EPriceAboveBand` until `last_price` is corrected
again. Correcting it is equally permissionless, equally low-cost, and can
be combined with a caller's own order-placement call in a single
transaction. `set_last_price` never reads or writes any escrow, fee, or
proceeds state, so this has no effect on funds already resting on the book
or already claimable.

## 6. Order placement

### `place_limit_order_bid`

```
public fun place_limit_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    price: u64,
    size: u64,
    payment: Coin<Quote>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool)
```

Aborts if the book is paused (`EBookPaused`, 15), if `price == 0`
(`EZeroPrice`, 14), if `price` fails the declared-range check (§3), if
`price` fails the price-band check when set (§4), or if `size < min_size`
(`ESizeBelowMinSize`, 12). All of these checks run before any of `payment`
is escrowed.

`max_fills` bounds how many resting orders this call will cross before
stopping the crossing sweep early (whether or not the book had more
crossable liquidity available). The fourth return value,
`stopped_on_max_fills_while_crossing`, is `true` when the sweep was cut
short this way.

Returns: `Option<OrderTicket>` — `option::some` if any size ends up resting,
`option::none()` otherwise (this includes both a fully-crossed order and a
remainder that rounds down to a restable size of zero, per below);
`Coin<Base>` — base received from crossing; `Coin<Quote>` — unused/leftover
payment; `bool` — the max-fills-stopped flag above.

Any unmatched remainder that ends up resting may be **smaller** than the
originally requested unmatched size, if the payment left over after any
crossing fills is insufficient to fully back the ceiling-rounded escrow
requirement (`bid_escrow_amount`, §3) for the full remainder at the
requested price.

### `place_limit_order_ask`

```
public fun place_limit_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    price: u64,
    size: u64,
    payment: Coin<Base>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool)
```

Same abort conditions as `place_limit_order_bid`, mirrored for the ask side.
Unlike the bid side, an ask's unmatched remainder always rests at its full
size — `Base`-denominated escrow requires no price-scale conversion or
rounding, so there is no analogous shortfall case.

### `place_market_order_bid`

```
public fun place_market_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    budget: u64,
    payment: Coin<Quote>,
    max_fills: u64,
    max_quote_in: Option<u64>,
    min_base_out: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool)
```

No price parameter; no declared-range check and no price-band check apply
at all — this fills at whatever prices the book's resting orders currently
offer. Aborts if the book is paused, or if `size < min_size`. `budget` is
the amount of `payment` escrowed for this buy; any part of `payment` beyond
`budget`, together with any unspent portion of `budget` itself left over
from matching, is merged into and returned as a single `Coin<Quote>`. Never
rests an order — anything unfilled is simply returned.

Optional slippage guards, checked after matching completes: `max_quote_in`
aborts with `ESlippageExceeded` (17) if the quote actually spent exceeds it;
`min_base_out` aborts with the same code if the base actually received is
below it.

`budget` and `max_quote_in` serve different purposes and are not redundant:
`budget` is escrowed up front and must cover the worst case the caller is
willing to fund; `max_quote_in` is a post-hoc, atomic assertion on the
actual amount spent, which can be tighter than `budget` without requiring
the caller to compute a precisely-sized `budget` coin in advance. A caller
may pass a generously large `budget` and rely on `max_quote_in` to bound
real spend — the unspent difference is always returned automatically as
part of the merged leftover `Coin<Quote>` — rather than needing to
pre-split `payment` down to an exact amount themselves.

### `place_market_order_ask`

```
public fun place_market_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    payment: Coin<Base>,
    max_fills: u64,
    min_quote_out: Option<u64>,
    max_base_in: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool)
```

Mirrors `place_market_order_bid` for the ask side: no price parameter, no
declared-range or price-band checks. `size` determines exactly how much
`Base` is escrowed from `payment` for this sell. Optional slippage guards
`min_quote_out`/`max_base_in`, same abort code.

### `swap_bid`

```
public fun swap_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    budget: u64,
    payment: Coin<Quote>,
    max_fills: u64,
    limit_price: Option<u64>,
    max_quote_in: Option<u64>,
    min_base_out: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool)
```

Behaves like `place_market_order_bid`, with one addition: an optional
`limit_price` caps how far the sweep is willing to walk the book (it never
fills at a price worse, for the caller, than `limit_price`). When `Some`,
`limit_price` is validated only for declared-range representability (§3) —
never against the price band (§4) — so it can be set tighter or looser than
the currently active band without being rejected for either reason. It
never itself becomes a resting price.

### `swap_ask`

```
public fun swap_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    payment: Coin<Base>,
    max_fills: u64,
    limit_price: Option<u64>,
    min_quote_out: Option<u64>,
    max_base_in: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool)
```

Mirrors `swap_bid` for the ask side, with the same `limit_price` contract.

### Order-placement summary

| Function | Price parameter | Declared-range check | Price-band check | Can rest an order |
|---|---|---|---|---|
| `place_limit_order_bid` | `price: u64` (mandatory) | Yes | Yes | Yes |
| `place_limit_order_ask` | `price: u64` (mandatory) | Yes | Yes | Yes |
| `place_market_order_bid` | none | — | — | No |
| `place_market_order_ask` | none | — | — | No |
| `swap_bid` | `limit_price: Option<u64>` | Yes, only if `Some` | No, never | No |
| `swap_ask` | `limit_price: Option<u64>` | Yes, only if `Some` | No, never | No |

All four of `place_market_order_bid`/`place_market_order_ask`/`swap_bid`/
`swap_ask` return three values: a matched-side coin, a single merged
leftover coin, and the `stopped_on_max_fills_while_crossing` flag — but the
order differs by side. `place_market_order_bid`/`swap_bid` return
`(Coin<Base>, Coin<Quote>, bool)`: matched base first, merged leftover quote
second. `place_market_order_ask`/`swap_ask` return
`(Coin<Base>, Coin<Quote>, bool)` too, but the first position is the
leftover (unmatched) base returned to the caller and the second is the
matched quote received — see each function's own signature for which is
which. On the bid side, `budget`'s own unspent remainder from matching and
the portion of `payment` never earmarked as `budget` are joined into that
one leftover `Coin<Quote>` before it is returned, mirroring how
`place_limit_order_bid`/`place_limit_order_ask` already merge their own
internal escrow/payment
splits into a single returned coin.

## 7. Order lifecycle: tickets, cancellation, ownership

### `OrderTicket`

Returned by a limit-order placement whose remainder rests. Required to
cancel that order, reassign its owner, or claim its proceeds. Read-only
accessors: `ticket_order_id`, `ticket_order_book_id`, `ticket_side`,
`ticket_price`.

### `cancel_order`

```
public fun cancel_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: OrderTicket,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>)
```

Aborts with `EWrongBook` (16) if `ticket` was not minted by `book`. Not
gated by pause. If the order is still resting, its remaining escrow is
returned along with any already-pooled, unclaimed proceeds for that order
id, combined into the two returned coins. If the order is no longer resting
(already fully filled and removed, or never found), only the pooled
proceeds (if any) are returned; calling this on an already-fully-consumed
or nonexistent order is not an error. Emits `OrderCancelled { order_id,
order_book_id, trader }` only if a still-resting order was actually found
and removed; emits `ProceedsClaimed { claimant, order_book_id, base_amount,
quote_amount }` only if nonzero pooled proceeds were paid out alongside.

### `update_resting_order`

```
public fun update_resting_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: &OrderTicket,
    new_owner: address,
): bool
```

Reassigns the resting order's payout destination to `new_owner`. Takes
`ticket` by reference, so the caller retains it. Returns `true` if the order
was found and updated, `false` if not (a no-op; not an abort). Authority
follows ticket possession, exactly like `cancel_order`. Immediately syncs
the payout address of the order's currently-pooled unclaimed proceeds (if
any), not just future fills — this affects both proceeds already credited
before the call and any credited afterward. Aborts with `EWrongBook` if
`ticket` was not minted by `book`.

Emits `OrderOwnerUpdated { order_id, order_book_id, old_owner, new_owner }`
whenever the order is found and reassigned — including when `new_owner`
equals the order's current owner (the reassignment and its proceeds-owner
sync still run in that case). Never emitted when the function returns
`false`.

### `claim_proceeds`

```
public fun claim_proceeds<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: OrderTicket,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, Option<OrderTicket>)
```

Pays out any accumulated proceeds for `ticket`'s order id to the caller
(`ctx.sender()`), regardless of the `owner` address currently recorded for
that order — authority follows ticket possession. Aborts with `EWrongBook`
if `ticket` was not minted by `book`. If the order is still resting, the
ticket is handed back (`option::some`) for future claims or eventual
cancellation. If the order is no longer resting, the ticket is destroyed
and `option::none()` is returned instead — nothing more can ever be claimed
through it. Emits `ProceedsClaimed` only if a nonzero amount was actually
paid out.

### `destroy_orphaned_ticket`

```
public fun destroy_orphaned_ticket<Base, Quote>(book: &OrderBook<Base, Quote>, ticket: OrderTicket)
```

Disposes of a ticket. Aborts with `EWrongBook` if not minted by `book`, or
with `EProceedsNotEmpty` (19) if the ticket's order id still has pooled,
unclaimed proceeds (destroying it in that case would permanently strand
those funds). Does not check whether the order is still resting — destroying
a ticket for a still-resting order with zero pooled proceeds is a valid
choice (e.g. abandoning a dust order).

## 8. Proceeds — admin rescue path

```
public fun push_proceeds<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    order_id: u64,
    ctx: &mut TxContext,
)
```

Pays out a specific order's accumulated proceeds. The destination is never
caller-supplied — always the `owner` address currently recorded for that
order id, so even the admin cannot redirect funds elsewhere. A no-op (no
event, no transfer) if there is nothing to pay out. Emits `ProceedsClaimed
{ claimant: owner, order_book_id, base_amount, quote_amount }` when nonzero.

## 9. Admin controls

### Pause / unpause

```
public fun clob_admin_pause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>)
public fun clob_admin_unpause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>)
```

Pausing blocks all six order-placement/market/swap entry points
(`EBookPaused`). It does **not** block `cancel_order`, `claim_proceeds`,
`update_resting_order`, `set_last_price`, or `clob_admin_cancel_order` — a
trader can always recover funds already at rest, and the admin can always
force-cancel or reset the reference price, whether or not the book is
paused. `clob_admin_unpause_book` aborts with `EBookRetiring` (18) if the
book is retiring — a retiring book can never be unpaused again (§10).
Emits `Paused { order_book_id }` / `Unpaused { order_book_id }`.

### Fees

```
public fun clob_admin_set_taker_fee<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>, rate_bps: u64)
public fun clob_admin_set_maker_fee<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>, rate_bps: u64)
```

`rate_bps` must be `<= 10` for the taker fee (else `ETakerFeeRateTooHigh`, 8)
and `<= 5` for the maker fee (else `EMakerFeeRateTooHigh`, 9). Both default
to `0` at construction. A change takes effect for fills from that point
forward; a resting order snapshots the maker-fee rate in effect at the
moment it was placed, so later maker-fee changes never retroactively affect
an already-resting order. Fee amounts are computed as `ceil(receive_amount *
rate_bps / 10_000)` — any nonzero receive amount at a nonzero rate pays at
least 1 unit of fee. Emits `TakerFeeSet { order_book_id, rate_bps }` /
`MakerFeeSet { order_book_id, rate_bps }` unconditionally, including a
same-value call.

```
public fun clob_admin_claim_fees<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>, ctx: &mut TxContext): (Coin<Base>, Coin<Quote>)
```

Withdraws the entire accumulated fee balance (both legs) to the caller.
Emits `FeesClaimed { claimant, order_book_id, base_amount, quote_amount }`
only if a nonzero amount was actually claimed. Readable without withdrawing
via `fee_accumulator_balances<Base, Quote>(book): (u64, u64)`; current rates
readable via `fee_config<Base, Quote>(book): (u64, u64)` (taker, maker).

### Force-cancel

```
public fun clob_admin_cancel_order<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order_id: u64,
    ctx: &mut TxContext,
)
```

Removes a specific resting order by side/price/order id and refunds its
escrow to its owner. A no-op (no abort, no event) if no such order exists.
Not gated by pause. Emits `OrderCancelled { order_id, order_book_id,
trader }` only when an order was actually found and removed. Does not touch
or pay out that order's already-pooled proceeds (if any) — those remain
claimable separately via the order's `OrderTicket`, if the caller who placed
it still holds one, or payable via `push_proceeds`.

### Price band and last-price reset

See §4 and §5.

## 10. Deletion lifecycle

```
public fun clob_admin_retire<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>)
```

Sets `paused = true` and `retiring = true`. `retiring` is sticky: no
function ever clears it back to `false` once set. Emits `OrderBookRetired {
order_book_id }`.

```
public fun clob_admin_drain_step<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    max_items: u64,
    ctx: &mut TxContext,
)
```

Aborts with `ENotRetiring` (6) unless the book is retiring. Force-cancels
resting orders (best-priced first on each side) and pays out pooled
proceeds entries, up to `max_items` total items across both, refunding
escrow/proceeds to their respective owners as it goes. Callable repeatedly
across multiple transactions to drain a large book incrementally; each call
processes at most `max_items` items and simply does less if fewer remain.

Emits `OrderCancelled` for every resting order it force-cancels and
`ProceedsClaimed` for every nonzero pooled-proceeds entry it pays out (a
zero-valued entry is skipped, matching `claim_proceeds`/`push_proceeds`'s
own skip-on-zero convention) — i.e. up to one event per processed item,
where previously this function emitted none. Sui enforces a hard cap of
1024 events emitted per transaction, so an admin's `max_items` choice should
stay comfortably under that limit (e.g. a few hundred), especially if
multiple `clob_admin_drain_step` calls are batched into a single PTB, where
the cap applies across the whole transaction, not per call.

```
public fun clob_admin_finalize<Base, Quote>(cap: ClobAdminCap, book: OrderBook<Base, Quote>): ID
```

Consumes the `ClobAdminCap` and the `OrderBook` by value, permanently
deleting both. Aborts with `ENotRetiring` unless the book is retiring, and
with `ENotFullyDrained` (7) unless the book has zero resting bids, zero
resting asks, zero pooled proceeds entries, and a zero fee-accumulator
balance on both legs — i.e. `clob_admin_drain_step` and
`clob_admin_claim_fees` must have fully emptied the book first. Emits
`OrderBookDeleted { order_book_id, base: TypeName, quote: TypeName }` (using
the book's `Base`/`Quote` type names) and `ClobAdminCapDiscarded { cap_id,
for_book }`. Returns the book's true, unforgeable object id.

## 11. Version guard

```
public fun assert_book_version<Base, Quote>(book: &mut OrderBook<Base, Quote>)
```

Public so an integrator wrapping the book can version-guard its own call
sites the same way this module's own functions do (every function in this
module that mutates the book calls this first). A book whose stored version
lags behind the currently-published package's version is transparently
upgraded in place with no separate migration call required — this emits
`BookVersionUpgraded { book_id, from, to }`. A book whose stored version is
*ahead* of the currently-published package still aborts with
`ENewVersionMismatch` (5), since that direction cannot be auto-resolved.

## 12. View functions

| Function | Returns |
|---|---|
| `bid(): bool` / `ask(): bool` | the `side` convention's `true`/`false` constants, purely for self-documenting call sites |
| `book_id<Base, Quote>(book): ID` | the book's true, unforgeable object id |
| `price_scale<Base, Quote>(book): u64` | the book's fixed `price_scale` (§3) |
| `fee_config<Base, Quote>(book): (u64, u64)` | `(taker_fee_bps, maker_fee_bps)` |
| `fee_accumulator_balances<Base, Quote>(book): (u64, u64)` | `(base, quote)` accumulated, unclaimed fee balances |
| `is_book_paused<Base, Quote>(book): bool` | current pause state |
| `is_book_retiring<Base, Quote>(book): bool` | current retiring state (sticky once `true`) |
| `best_bid<Base, Quote>(book): Option<u64>` | highest resting bid price, or `None` |
| `best_ask<Base, Quote>(book): Option<u64>` | lowest resting ask price, or `None` |
| `depth_at_price<Base, Quote>(book, side: bool, price: u64): u64` | total resting size at that exact raw price on that side; `0` if no such level exists, for any `price` value including `0` — never aborts |
| `bid_escrow_amount<Base, Quote>(book, price, size): u64` | escrow required for a bid at `(price, size)` (§3) |
| `ticket_order_id`/`ticket_order_book_id`/`ticket_side`/`ticket_price` | the corresponding field of an `OrderTicket` |
| `last_price<Base, Quote>(book): u64` | the book's current `last_price` (§5) |
| `price_band_factor<Base, Quote>(book): Option<u64>` | the book's current price-band factor, or `None` (§4) |
| `book_version<Base, Quote>(book): u64` | the book's current `version` (§11) |
| `min_size<Base, Quote>(book): u64` | the book's `min_size` floor (§2) |
| `bid_quote_escrow_at_price<Base, Quote>(book, price): u64` | the exact, maintained total of live `Quote` escrow held by every resting bid order at `price`; `0` if no bid level exists there. Bid-only (no `side` parameter) — an ask level's escrow is `Base`, already exactly equal to `depth_at_price(book, ask(), price)`, so there is no analogous "quote value" for it. |
| `resting_order_escrow<Base, Quote>(book, side, price, order_id): Option<RestingOrderEscrow>` | the live state of one resting order, or `None` if that price level doesn't exist or holds no such order (fully filled, cancelled, or never placed). Never aborts, for any input. |
| `resting_order_escrow_by_ticket<Base, Quote>(book, ticket): Option<RestingOrderEscrow>` | `resting_order_escrow` for the order `ticket` was minted for. Aborts with `EWrongBook` (16) if `ticket` was not minted by `book`. |
| `resting_order_escrow_fields(e: &RestingOrderEscrow): (u64, u64)` | `(escrow, remaining_size)` — `escrow` is Quote for a bid, Base for an ask (the currency that side actually escrows); `remaining_size` is always the order's Base-denominated remaining size regardless of side. `escrow` is the order's remaining escrowed *principal* only — `cancel_order` may additionally pay out pooled proceeds in the opposite currency, which this value does not include. `(0, r)` with `r > 0` is a real, reachable state (escrow fully charged, order still resting with real remaining size) — distinct from `None` (not resting at all). |

## 13. Events reference

Within one call to a matching entry point, events are emitted in a fixed
order: zero-or-more `OrderFilled`, then an optional `OrderPlaced`, then
exactly one `OrderExecuted` as a trailer. Correlating fills to their
triggering call relies on this within-transaction ordering (Sui's event
ordering within a transaction's effects is deterministic).

| Event | Fields |
|---|---|
| `BookVersionUpgraded` | `book_id: ID`, `from: u64`, `to: u64` |
| `Paused` | `order_book_id: ID` |
| `Unpaused` | `order_book_id: ID` |
| `TakerFeeSet` | `order_book_id: ID`, `rate_bps: u64` |
| `MakerFeeSet` | `order_book_id: ID`, `rate_bps: u64` |
| `FeesClaimed` | `claimant: address`, `order_book_id: ID`, `base_amount: u64`, `quote_amount: u64` |
| `PriceBandFactorSet` | `order_book_id: ID`, `factor: Option<u64>` |
| `LastPriceSet` | `order_book_id: ID`, `last_price: u64`, `setter: address` |
| `OrderCancelled` | `order_id: u64`, `order_book_id: ID`, `trader: address` |
| `OrderBookRetired` | `order_book_id: ID` |
| `OrderBookDeleted` | `order_book_id: ID`, `base: TypeName`, `quote: TypeName` |
| `ClobAdminCapDiscarded` | `cap_id: ID`, `for_book: ID` |
| `OrderPlaced` | `order_id: u64`, `order_book_id: ID`, `side: bool`, `price: u64`, `size: u64`, `trader: address`, `maker_fee_bps: u64` |
| `OrderFilled` | `maker_order_id: u64`, `order_book_id: ID`, `price: u64`, `size: u64`, `maker: address`, `taker: address`, `maker_side: bool`, `quote_amount: u64`, `taker_fee_amount: u64`, `maker_fee_amount: u64` |
| `OrderExecuted` | `order_book_id: ID`, `taker: address`, `taker_side: bool`, `entry_point: u8`, `limit_price: Option<u64>`, `requested_size: u64`, `unmatched_size: u64`, `rested_size: u64`, `rested_order_id: Option<u64>`, `stopped_on_max_fills_while_crossing: bool` |
| `ProceedsClaimed` | `claimant: address`, `order_book_id: ID`, `base_amount: u64`, `quote_amount: u64` |
| `OrderOwnerUpdated` | `order_id: u64`, `order_book_id: ID`, `old_owner: address`, `new_owner: address` |

`OrderPlaced.maker_fee_bps` is the maker-fee rate snapshotted into the
resting order at placement time — permanent for the order's lifetime; later
`MakerFeeSet` changes never retroactively affect it.

`OrderFilled`'s new fields follow a currency truth table: each party's fee
is denominated in the asset that party receives. When `maker_side == false`
(the resting maker order was an ask): the taker receives Base
(`taker_fee_amount` in Base) and the maker receives Quote (`maker_fee_amount`
in Quote). When `maker_side == true` (the resting maker order was a bid):
the taker receives Quote (`taker_fee_amount` in Quote) and the maker
receives Base (`maker_fee_amount` in Base). `size` and `price` are the
exception to the flip: `size` is always denominated in `Base` atomic units
and `price` is always the raw, book-relative price of the resting maker
order (§3), regardless of `maker_side`. `quote_amount`,
`taker_fee_amount`, and `maker_fee_amount` are all gross amounts — each fee
is deducted FROM its respective gross leg, not added on top. On the
maker-bid side (`maker_side == true`), `quote_amount` is derived from a
proportional slice of the maker's original escrow reservation (not a direct
`price * size` recomputation) and may differ by rounding from
`ceil(price * size / price_scale)` — this is expected.

Although any single `quote_amount` may deviate by rounding on the maker-bid
side, the sum is exact: for a given `maker_order_id`, the total of
`quote_amount` across every `OrderFilled` event with `maker_side == true`
emitted over that order's entire lifetime equals exactly the amount debited
from that order's quote escrow — and equals exactly the full escrow
originally reserved for it if the order is filled to completion, with zero
residual dust, no matter how many separate fills or transactions it was
drained across. If the order is only partially filled, the sum is strictly
less than the original reservation, and the exact difference is what
`cancel_order` (or `clob_admin_cancel_order` / `clob_admin_drain_step`)
refunds.

`OrderExecuted` is emitted exactly once, unconditionally, as the last event
of every call to `place_limit_order_bid` / `place_limit_order_ask` /
`place_market_order_bid` / `place_market_order_ask` / `swap_bid` /
`swap_ask` — after any slippage-guard asserts in the market/swap functions,
so an abort emits nothing. `entry_point` identifies which of the six
functions produced the event:

| `entry_point` | Function |
|---|---|
| 0 | `place_limit_order_bid` |
| 1 | `place_limit_order_ask` |
| 2 | `place_market_order_bid` |
| 3 | `place_market_order_ask` |
| 4 | `swap_bid` |
| 5 | `swap_ask` |

`limit_price` is `None` for market orders; for `place_limit_order_*`, the
resting/placement price; for `swap_*`, the taker's protective slippage cap
(exempt from the price band). `unmatched_size` is the remaining size after
matching, gross of taker fee — it does not directly equal the base returned
to the taker when `taker_fee_bps > 0`. `rested_size` is `0` if nothing rests;
on the bid limit path it can be less than `unmatched_size` even when
something rests, because `place_limit_order_bid` clamps the resting size to
what leftover escrow can actually back. `rested_order_id` is `Some(id)` iff
something rested this call, else `None`.

## 14. Error code reference

| Code | Constant |
|---|---|
| 1 | `EZeroMinSize` |
| 3 | `EMinSizeTooLarge` |
| 4 | `EWrongClobAdminCap` |
| 5 | `ENewVersionMismatch` |
| 6 | `ENotRetiring` |
| 7 | `ENotFullyDrained` |
| 8 | `ETakerFeeRateTooHigh` |
| 9 | `EMakerFeeRateTooHigh` |
| 12 | `ESizeBelowMinSize` |
| 14 | `EZeroPrice` |
| 15 | `EBookPaused` |
| 16 | `EWrongBook` |
| 17 | `ESlippageExceeded` |
| 18 | `EBookRetiring` |
| 19 | `EProceedsNotEmpty` |
| 20 | `EPriceRangeInfeasible` |
| 21 | `EPriceBelowDeclaredMin` |
| 22 | `EPriceAboveDeclaredMax` |
| 23 | `EPriceBelowBand` |
| 24 | `EPriceAboveBand` |
| 25 | `EZeroPriceBandFactor` |
| 26 | `EResetPriceBelowBestBid` |
| 27 | `EResetPriceAboveBestAsk` |
| 28 | `EDecimalsTooLarge` |

(Codes 2, 10, 11, 13 are not currently in use.)

## 15. Border cases — consolidated list

- `price == 0` is rejected everywhere it is checked (`EZeroPrice`): at
  construction (`initial_last_price`), `set_last_price`, and
  `place_limit_order_bid`/`_ask`. A zero `limit_price` passed to
  `swap_bid`/`_ask` is instead rejected by the declared-range check, since
  no book's declared range can ever include `0`.
- `price_band_factor` can only ever be `None` or `Some(f)` with `f >= 1`;
  `Some(0)` is always rejected.
- A construction request whose `base_decimals`/`quote_decimals`/
  `precision`/`exponent` cannot simultaneously satisfy `scale_lo <= scale_hi`
  and `scale_lo <= u64::MAX` aborts entirely — no book is created, and no
  capability is minted.
- `base_decimals`, `quote_decimals`, `precision`, and `exponent` are each
  independently capped at `38`, checked before and independently of the
  feasibility condition above.
- The declared-range check and the price-band check are independent: a
  value can fail one, both, or neither.
- The price-band check is only ever applied to a price that can rest on the
  book. It never constrains what price a taker actually executes against
  via `place_market_order_bid`/`_ask` or `swap_bid`/`_ask` — those fill at
  whatever price the book's existing resting orders offer, regardless of
  the current `price_band_factor` or `last_price`.
- `set_last_price`, on a book with neither a best bid nor a best ask,
  accepts any declared-range value from any caller, at no cost beyond gas
  (§5).
- `set_last_price` ignores `paused`/`retiring` state entirely and does not
  affect the retire/drain/finalize sequence.
- `set_last_price` emits no event and writes no state when the supplied
  value equals the book's current `last_price`.
- `last_price`'s automatic update reflects the price of the *last* resting
  level to receive a nonzero fill within a single match, not the first
  level touched and not an aggregate/average across levels touched.
- `bid_escrow_amount(book, 0, size)` returns `0` and does not abort.
- `resting_order_escrow` can return `Some((0, r))` with `r > 0` — a resting
  bid whose escrow is fully charged but which still has real remaining
  size and stays on the book. This is distinct from `None` (not resting at
  all) and is a real, reachable state, not an error condition.
- `bid_quote_escrow_at_price` is an exact, maintained aggregate, not a
  re-derivation — unlike computing `bid_escrow_amount(book, price,
  depth_at_price(book, bid(), price))`, which can over- or under-count the
  true live escrow by up to roughly one `Quote` atom per resting order at
  that price, in either direction, depending on each order's own fill
  history.
- A `place_limit_order_bid` call's unmatched remainder may rest at a
  smaller size than requested if leftover escrow cannot fully back it at
  the ceiling-rounded rate; the returned ticket is `option::none()` when
  nothing ends up resting. `place_limit_order_ask` has no analogous
  shortfall case.
- `min_size` is checked only at placement time, never against a post-fill
  remainder; a resting order can end up smaller than `min_size` ("dust")
  and will persist until cancelled, fully filled, or admin-removed.
- Pausing blocks all order-placement/market/swap entry points but never
  `cancel_order`, `claim_proceeds`, `update_resting_order`, `set_last_price`,
  or `clob_admin_cancel_order`.
- `clob_admin_unpause_book` always aborts on a retiring book; once
  `clob_admin_retire` has been called, the book can never be unpaused again.
- `clob_admin_cancel_order` and `clob_admin_finalize`'s emptiness checks are
  independent of any pooled proceeds for the removed/remaining orders —
  proceeds are refunded/paid separately from escrow.
- `push_proceeds`'s payout destination is always the recorded `owner` for
  that order id, never caller-suppliable, even by the admin.
- `destroy_orphaned_ticket` refuses to discard a ticket that still has
  pooled, unclaimed proceeds attached to its order id.
- `clob_admin_finalize` requires zero resting orders on both sides, zero
  pooled proceeds entries, and a zero fee-accumulator balance on both legs
  simultaneously before it will succeed.
- Fee rate changes apply to fills from that point forward only; an
  already-resting order keeps the maker-fee rate that was in effect when it
  was placed.
- Every fee computation rounds up: any nonzero receive amount at a nonzero
  fee rate always pays at least 1 atomic unit of fee.

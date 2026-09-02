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
    enclosing_object_id: &UID,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap)
```

Callable by any address; no capability is required to construct a book, and
construction does not register or share the book anywhere. Mints and returns
a fresh `ClobAdminCap` alongside the book.

`enclosing_object_id` is a MANDATORY `&UID` parameter, not optional: both
`OrderBook` and `ClobAdminCap` are `store`-only, never `key` (§1), so a book
can never exist as a top-level object in its own right — it is always
embedded inside some enclosing object. Requiring that enclosing object's live
`&UID` at construction time reflects how this type is actually used, not an
artificial restriction. `enclosing_object_id` is stamped on every event this
book ever emits (as `enclosing_object_id` — see §13), fixed permanently at
construction and never changeable afterward. It is a borrowed `&UID` rather
than a bare `ID` specifically so a caller cannot forge it to an arbitrary id
merely copied off a public event or explorer; it is used solely for event
stamping and is never used for authentication anywhere in this module (see
§13's note on `book_id` vs `enclosing_object_id`).

A caller with no real wrapper object handy may mint a throwaway `UID` via
`object::new(ctx)`, pass a borrow of it here, and delete it immediately
afterward — this is a supported pattern, not a workaround: what matters for
the event/indexer use case this parameter exists for is the id's uniqueness,
not whether the referenced object is still live when an event is later read.
In the same spirit, deliberately reusing the same (now-dead) enclosing id
across a delete-and-reconstruct transition (an old enclosing object deleted,
a new `OrderBook` created in its place) is a legitimate way to preserve
indexer continuity across that transition, not a misuse.

### `min_size`

Bounds order-placement size only — checked once, at the moment an order is
submitted. It is never re-checked against the size of a resulting
fill or a partial-fill remainder, so a partial fill can leave a resting
order's remaining size below `min_size`. Such a remainder persists on the
book until it is cancelled by its ticket holder, fully consumed by a later
fill, or removed by `clob_admin_cancel_order`/`clob_admin_drain_step`.

Integrators/deployers should ensure `min_size * price / price_scale` (the
Quote value of the smallest permitted fill) stays well above 1 atom of the
escrowed currency. A leg worth exactly 1 atom is the one case where a
nonzero fee rate necessarily either consumes the entire leg or collects no
fee at all — this is an accepted, unavoidable tradeoff of integer fee math,
not a bug (see §9, Fees). This guidance only bounds *initial placement*
size, however — it does nothing to bound a post-fill dust remainder, which
can still end up arbitrarily small regardless of `min_size`, per the
dust-remainder behavior described above.

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
| `enclosing_object_id` refers to the book's own `UID` (structurally unreachable — defensive-only, see the `EEnclosingIsSelf` constant doc comment) | `EEnclosingIsSelf` (32) |

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

price_scale = scale_lo
```

`price_scale` is chosen as `scale_lo`, the *smallest* value that guarantees
resolution at least as fine as the book's declared `10^-precision` — not the
largest value that fits in a `u64`. `scale_hi` is retained only as a
feasibility bound: it guarantees `10^exponent` (the book's declared maximum
true price) still decodes to a raw price that fits in a `u64` at the chosen
`price_scale`. Construction aborts with `EPriceRangeInfeasible` (20) if
`scale_lo > scale_hi`, or if `scale_lo` itself does not fit in a `u64`.

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
| `new` | `initial_last_price` |
| `set_last_price` | `new_last_price` |
| `place_limit_order_bid` | `price` (derived internally from `payment`/`expected_base_output`) |
| `place_limit_order_ask` | `price` (derived internally from `expected_quote_output`/`payment.value()`) |

It is **not** applied to `place_market_order_bid` or `place_market_order_ask`
— neither takes a price parameter to validate.

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
`place_limit_order_ask` (both on their internally-derived `price`). It is **not**
applied to `place_market_order_bid` or `place_market_order_ask`.

Every call to `clob_admin_set_price_band_factor` emits `PriceBandFactorSet {
book_id, enclosing_object_id, factor }`, including a call that sets the same value the
book already has — there is no no-op skip on this event.

## 5. `last_price`

`last_price` is a per-book reference point, readable directly via the
public getter `last_price<Base, Quote>(book): u64` (§12); it is also
observable indirectly through its effect on `price_band_factor` (§4). It is
seeded to `initial_last_price` at
construction and can subsequently change in two ways:

**Automatically, on a real fill.** Whenever a match against a resting order
produces a nonzero fill, `last_price` is set to that resting order's price.
For a single order that sweeps multiple resting price levels in one
call, `last_price` ends at the price of the *last* level that received a
nonzero fill, not the first, and not an average. An order that
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
is updated and `LastPriceSet { book_id, enclosing_object_id, last_price, setter }` is
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
    payment: Coin<Quote>,
    expected_base_output: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool)
```

This is the only entry point for placing a resting limit bid. There is no
caller-supplied `price` parameter: raw `price` is an internal,
`price_scale`-denominated unit that is easy to misinterpret (e.g. mistaking
`price = 2` for "2 tokens per token"), so it is always derived internally
from real quantities instead. The whole `payment` coin's value is derived,
up front, into the implied limit `price` for a resting bid targeting exactly
`expected_base_output` Base: `price = floor(payment.value() * price_scale /
expected_base_output)` — the maximum price `payment`'s entire value can
afford for `expected_base_output` Base — computed once and used both to
cross the book and, unchanged, as the price any unfilled remainder rests at.
This guarantees `bid_escrow_amount(book, price, expected_base_output) <=
payment.value()`, so this function can never itself abort for lack of funds
on account of this derivation; any leftover (rounding slack from the
`floor`, plus whatever isn't matched/rested) is returned merged into the
leftover `Coin<Quote>`.

Aborts if the book is paused (`EBookPaused`, 15), if `expected_base_output <
min_size` (`ESizeBelowMinSize`, 12), if the derived `price` rounds down to
`0` (`EZeroPrice`, 14), if the derivation would overflow `u64`
(`EPriceOverflow`, 29), if `price` fails the declared-range check (§3), or if
`price` fails the price-band check when set (§4). All of these checks run
before any of `payment` is escrowed.

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
requirement (`bid_escrow_amount`, §3) for the full remainder at the derived
price.

**Precision note**: `price_scale` is chosen (see §3) as the smallest value
guaranteeing resolution at least as fine as the book's declared
`10^-precision`, not a near-`u64::MAX` value — so this derived price snaps
down to the nearest whole declared tick rather than tracking `payment`'s
implied ratio near-exactly. Still fund-safe: `floor` rounding still
guarantees the escrow bound above holds.

**Worst-case resting price**: because the derived price is a maximum, any
unmatched remainder rests at the *worst* price this payment could imply —
potentially far above what a hand-computed limit price would use. This is
deliberate (it is what makes the fund-safety guarantee above hold), not a
bug — it is the tradeoff inherent in there being no way to pass an explicit
resting price.

### `place_limit_order_ask`

```
public fun place_limit_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    payment: Coin<Base>,
    expected_quote_output: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool)
```

The only entry point for placing a resting limit ask, mirroring
`place_limit_order_bid`: no caller-supplied `price` parameter. The whole
`payment` coin's value (`payment.value()`) is the resting ask's `size` — the
whole coin is escrowed. The implied limit `price` is derived from
`expected_quote_output` via `price = ceil(expected_quote_output *
price_scale / size)` — the lowest price at which fully filling this ask
would yield at least `expected_quote_output` Quote. Unlike the bid side,
there is no rounding-slack leftover to return here: an ask's escrow is
exactly `size` Base with no price-scale conversion involved, and an ask's
unmatched remainder always rests at its full size.

Aborts if the book is paused (`EBookPaused`, 15), if `size < min_size`
(`ESizeBelowMinSize`, 12), if `expected_quote_output == 0` (the derived
price would round down to `0`, `EZeroPrice`, 14), if the derivation would
overflow `u64` (`EPriceOverflow`, 29), if `price` fails the declared-range
check (§3), or if `price` fails the price-band check when set (§4).

**Precision note**: as with the bid-side mirror, `price_scale` is the
smallest value guaranteeing resolution at least as fine as the book's
declared `10^-precision`, not a near-`u64::MAX` value — so this derived
price snaps up to the nearest whole declared tick rather than tracking
`expected_quote_output`'s implied ratio near-exactly. Still fund-safe:
`ceil` rounding still guarantees the yield bound above holds.

**Worst-case resting price**: the derived price is the *lowest* price
satisfying the constraint above, so any unmatched remainder rests at the
worst price for the ask's own maker (least Quote received per unit sold).
Deliberate, for the same fund-safety reason as the bid-side mirror — not a
bug, but the tradeoff inherent in there being no way to pass an explicit
resting price.

### `place_market_order_bid`

```
public fun place_market_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    payment: Coin<Quote>,
    max_fills: u64,
    min_base_out: u64,
    max_base_out: u64,
    max_quote_in: u64,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool)
```

No price parameter; no declared-range check and no price-band check apply
at all — this fills at whatever prices the book's resting orders currently
offer. Aborts if the book is paused. Never rests an order — anything
unfilled is simply returned. There is no `size`/`budget` split like the
older interface: `payment`'s whole value is the taker's available Quote,
and `max_base_out`/`max_quote_in` cap how much of it actually gets used.

- `max_base_out` caps how much Base this call will ever try to buy. `0` is
  a real, literal zero cap — the call immediately no-ops with nothing
  matched and `payment` returned untouched, it does **not** mean
  "unbounded". `u64::MAX` means unbounded.
- `max_quote_in` caps how much Quote this call will ever spend, using the
  same `0`-is-real / `u64::MAX`-is-unbounded convention. At most
  `min(payment.value(), max_quote_in)` is ever escrowed into the match —
  the cap is enforced up front, by construction, not asserted after the
  fact — and anything beyond it is returned untouched as part of the merged
  leftover `Coin<Quote>`.
- `min_base_out` is the slippage floor: aborts with `ESlippageExceeded`
  (17) if the base actually received is below it. `0` means "not
  applicable" (no floor).
- Aborts with `EMinExceedsMaxBaseOut` (30) if `min_base_out >
  max_base_out` — both are Base-denominated, so this combination can never
  be satisfied by any match outcome, and is rejected up front rather than
  left to surface later as a confusing `ESlippageExceeded`. `max_base_out ==
  u64::MAX` always satisfies this check.

This interface replaces an older `(size: u64, budget: u64, payment,
max_fills, max_quote_in: Option<u64>, min_base_out: Option<u64>)` signature.
It is a redesign, not a positional drop-in: every parameter's meaning
and/or type changed, so do not mechanically migrate a caller by renaming
old arguments onto the new positions.

### `place_market_order_ask`

```
public fun place_market_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    payment: Coin<Base>,
    max_fills: u64,
    min_quote_out: u64,
    max_base_in: u64,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool)
```

Mirrors `place_market_order_bid` for the ask side: no price parameter, no
declared-range or price-band checks.

- `max_base_in` caps how much Base this call sells: `size =
  min(payment.value(), max_base_in)`. `0` is a real, literal zero cap — the
  call immediately no-ops with nothing matched and `payment` returned
  untouched. `u64::MAX` means unbounded (`size` is then simply
  `payment.value()`). Any of `payment` beyond the resulting `size` is
  returned unspent. Like `place_market_order_bid`, there is deliberately no
  `min_size` check against the resulting `size` here (`ESizeBelowMinSize`
  is never raised by this function): a market order never rests, so it can
  never leave a sub-`min_size` dust order on the book — the check only
  matters for an order that might rest.
- `min_quote_out` is the slippage floor: aborts with `ESlippageExceeded`
  (17) if the quote actually received is below it. `0` means "not
  applicable".

Unlike `place_market_order_bid`, there is no `min_quote_out`-vs-`max_base_in`
ordering constraint to enforce — the two are denominated in different
currencies (Quote and Base respectively), so no combination of values is
inherently unsatisfiable the way `min_base_out > max_base_out` is on the bid
side.

This interface replaces an older `(size: u64, payment, max_fills,
min_quote_out: Option<u64>, max_base_in: Option<u64>)` signature — likewise
a redesign, not a positional drop-in.

### Order-placement summary

| Function | Price parameter | Declared-range check | Price-band check | Can rest an order |
|---|---|---|---|---|
| `place_limit_order_bid` | none (derived internally) | Yes | Yes | Yes |
| `place_limit_order_ask` | none (derived internally) | Yes | Yes | Yes |
| `place_market_order_bid` | none | — | — | No |
| `place_market_order_ask` | none | — | — | No |

Both of `place_market_order_bid`/`place_market_order_ask` return the same
tuple shape, `(Coin<Base>, Coin<Quote>, bool)` — a `Coin<Base>`, a
`Coin<Quote>`, and the `stopped_on_max_fills_while_crossing` flag, in that
position order for both functions. What differs by side is not the tuple
shape but which currency plays the "matched" role and which plays the
"leftover" role: `place_market_order_bid` returns matched Base first and
merged leftover Quote second, while `place_market_order_ask` returns merged
leftover Base first and matched Quote second — distinguished by which coin
is which currency, not by position, since both functions place `Coin<Base>`
first and `Coin<Quote>` second regardless of which one is "matched". See
each function's own signature for which is which. On the bid side, whatever
internally-escrowed Quote goes unspent by
matching, together with the portion of `payment` never escrowed for
matching in the first place (e.g. capped out by `max_quote_in` on
`place_market_order_bid`), are joined into that one leftover `Coin<Quote>`
before it is returned, mirroring how `place_limit_order_bid`/
`place_limit_order_ask` already merge their own internal escrow/payment
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
id, combined into the two returned coins — this escrow leg also includes
that order's maker-fee true-up (§9's Fees section): the CORRECT aggregate
fee is computed and moved into the book's fee accumulator, and any
superadditive slack left in the order's reserve is folded into the returned
escrow. If the order is no longer resting (already fully filled and
removed, or never found), only the pooled proceeds (if any) are returned;
calling this on an already-fully-consumed or nonexistent order is not an
error. Emits `OrderCancelled { book_id, enclosing_object_id, order_id, trader }` and
`MakerFeeSettled` (§13) only if a still-resting order was actually found and
removed; emits `ProceedsClaimed { book_id, enclosing_object_id, claimant, base_amount,
quote_amount }` only if nonzero pooled proceeds were paid out alongside.

### `update_resting_order`

```
public fun update_resting_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: &mut OrderTicket,
    new_owner: address,
): bool
```

Reassigns the resting order's payout destination to `new_owner`. Takes
`ticket` by mutable reference, so the caller retains it. Returns `true` if
the order was found *still resting* and updated, `false` if not (a no-op on
the resting-order half; not an abort). Authority follows ticket possession,
exactly like `cancel_order`. Aborts with `EWrongBook` if `ticket` was not
minted by `book`, or with `EInvalidOwner` (33) if `new_owner == @0x0` —
both `resting_order_owner`-style escrow refunds and pooled-proceeds sweeps
route through this recorded address, so a zero address would otherwise
silently burn funds.

Independently of that `bool`, this ALWAYS immediately syncs the payout
address of the order's currently-pooled unclaimed proceeds (if any) to
`new_owner` — this affects both proceeds already credited before the call
and any credited afterward, and runs whether or not the order is found
still resting: even if the order has already concluded by the time this is
called (fully filled and drained, `cancel_order`ed, force-cancelled via
`clob_admin_cancel_order`, or removed by `clob_admin_drain_step`), any
pooled, unclaimed proceeds entry for its order id is still resynced to
`new_owner`. The pooled amount is then payable either via `claim_proceeds`
through the order's own `OrderTicket` (paying the ticket holder/caller
regardless of the recorded owner — see `claim_proceeds` above), or via the
admin-gated `push_proceeds` (live book or retiring, unconditionally) or the
internal `drain_proceeds` reached through `clob_admin_drain_step` (retiring
only) (paying whichever owner was last synced, by either this function or
the original placement) — whichever happens first. Because `push_proceeds`
is unconditional on a live book, the admin can call it at any time to pay
out an order's pooled proceeds to the recorded owner, including pre-empting
a ticket holder who has not yet gotten around to calling `claim_proceeds`
themselves — it is not limited to the retirement/drain sequence.

Emits `OrderOwnerUpdated { book_id, enclosing_object_id, order_id, old_owner, new_owner }`
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

Disposes of a ticket. Aborts with `EWrongBook` if not minted by `book`, with
`EProceedsNotEmpty` (19) if the ticket's order id still has pooled,
unclaimed proceeds (destroying it in that case would permanently strand
those funds), or with `EOrderStillResting` (31) if the order is still
resting on `book`. While the order and the book both still exist, this
ticket remains the only self-service path back to that order's escrow;
callers who want to give up on a still-resting order should call
`cancel_order` instead, not discard the ticket out from under it.

### `destroy_ticket_unconditionally`

```
public fun destroy_ticket_unconditionally(ticket: OrderTicket)
```

Disposes of a ticket with no check of any kind and no `OrderBook` parameter
at all — the only ticket-disposal function that doesn't take one. Always
succeeds. This is the only disposal path available once the ticket's book
has already been deleted via `clob_admin_finalize`, since nothing can ever
prove a deleted book's non-existence to `destroy_orphaned_ticket`'s
liveness check again. On a still-live book, it is safe for both the
escrow and the pooled proceeds of the ticket's order, because a ticket has
never been the *only* path back to either: escrow on a still-resting order
is reachable via `clob_admin_cancel_order` by `(side, price, order_id)`
alone, no ticket required, and pooled proceeds are reachable the same
admin-gated way via `push_proceeds`, which (unlike `clob_admin_drain_step`,
which still requires `book.retiring`) is unconditional on a live book,
gated only on the `ClobAdminCap`. Discarding a ticket for an order with
real pooled proceeds still attached, while the book is still live, no
longer strands anything — the admin can recover them immediately via
`push_proceeds`, with no need to retire the book first. Calling this
function only ever gives up the ticket holder's own convenient self-service
disposal path, never the underlying funds.

## 8. Proceeds — admin payout path

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
{ book_id, enclosing_object_id, claimant: owner, base_amount, quote_amount }` when nonzero.

Unconditional — gated only on the book's version and `cap`, exactly like
`clob_admin_cancel_order`, with no `book.retiring` requirement of its own
(unlike the private `drain_proceeds` helper `clob_admin_drain_step` uses
internally, which is still only reachable once the book is retiring). This
is a live-book rescue path, deliberately parallel to
`clob_admin_cancel_order`'s unconditional escrow rescue: it exists because
a ticket can be destroyed with no checks at all via
`destroy_ticket_unconditionally` (which takes no `OrderBook` at all) while
real proceeds are still pooled against that order's `order_id` — without
this, those proceeds would be stranded on a live book until the admin ran
the one-way, book-destroying retirement sequence just to reach them. An
integrator that needs to confirm ahead of time where this payout will
go can check `proceeds_owner`/`proceeds_owner_by_ticket` (§12).

## 9. Admin controls

### Pause / unpause

```
public fun clob_admin_pause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>)
public fun clob_admin_unpause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>)
```

Pausing blocks all four order-placement/market entry points
(`EBookPaused`). It does **not** block `cancel_order`, `claim_proceeds`,
`update_resting_order`, `set_last_price`, or `clob_admin_cancel_order` — a
trader can always recover funds already at rest, and the admin can always
force-cancel or reset the reference price, whether or not the book is
paused. `clob_admin_unpause_book` aborts with `EBookRetiring` (18) if the
book is retiring — a retiring book can never be unpaused again (§10).
Emits `Paused { book_id, enclosing_object_id }` / `Unpaused { book_id, enclosing_object_id }`.

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
an already-resting order. Every individual fee amount is computed as
`ceil(receive_amount * rate_bps / 10_000)` — any nonzero receive amount at a
nonzero rate pays at least 1 unit of fee. A receive amount of exactly 1 atom
is the one case where this necessarily either consumes the entire leg (fee
== the full 1 atom) or collects nothing (fee rounds down to 0 only if
`rate_bps == 0`) — an accepted tradeoff of integer math at today's fee caps,
not a bug (see §2's `min_size` guidance). Emits `TakerFeeSet { book_id,
enclosing_object_id, rate_bps }` / `MakerFeeSet { book_id, enclosing_object_id,
rate_bps }` unconditionally,
including a same-value call.

**Taker fee — computed once per call, in aggregate.** Each of the four
order-placement/market entry points computes its own taker fee exactly
once, after its entire matching sweep completes (across every price level it
touched), from the aggregate raw (pre-fee) quantity the taker filled that
call — never per individual fill. This aggregate fee is deducted from the
taker's matched proceeds *before* the post-match slippage floor is checked
(`min_base_out` on the bid side, `min_quote_out` on the ask side) and before
the coin(s) returned to the taker, and is reported via
`OrderExecuted.taker_fee_amount` (§13). (`max_quote_in`/`max_base_in` are a
different mechanism — an up-front spend/escrow clamp applied *before*
matching even starts, via `std::u64::min(payment.value(), cap)`, not a
post-match assert — so the fee deduction does not interact with them the
way it does with the slippage floors.) Because ceiling division is
superadditive, this once-per-call aggregate is always less than or equal to
what summing each individual fill's own independently-ceiling-rounded fee
would have charged — it can never make a slippage-floor check that would
have passed under the old per-fill model fail, only the reverse.

**Maker fee — set aside per-fill, collected once at conclusion.** Each fill
still computes its own ceiling-rounded maker fee and immediately splits it
out of the maker's proceeds for that fill, but instead of crediting the
book's fee accumulator immediately, that per-fill amount is set aside in a
reserve private to the resting order itself. Only when the order
*concludes* — fully filled (drained by a fill), cancelled by its own ticket
holder (`cancel_order`), force-cancelled (`clob_admin_cancel_order`), or
swept up by `clob_admin_drain_step` — is the CORRECT aggregate fee actually
computed (from the order's own running total of fill basis across its
entire lifetime) and transferred into the book's fee accumulator; any
superadditive slack left over in the reserve is refunded back to the maker
through whatever mechanism that conclusion event already uses to pay the
maker (pooled proceeds for a fill-drain, the escrow/coin(s) returned for a
cancellation or force-drain). This transfer is reported via a new event,
`MakerFeeSettled { book_id, enclosing_object_id, order_id, maker, amount }` (§13), emitted
exactly once per concluded order, alongside whatever event that conclusion
already emits (e.g. `OrderCancelled`).

Accepted tradeoff: an order that rests indefinitely without ever concluding
defers both its maker-fee collection and its `MakerFeeSettled` event
indefinitely along with it. The fee isn't lost — it's already been set
aside, fill by fill, in the order's own reserve — it's simply not yet
finalized into the book's fee accumulator, exactly the same way the order's
own unspent escrow and pooled fill proceeds aren't paid out until that same
conclusion.

```
public fun clob_admin_claim_fees<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>, ctx: &mut TxContext): (Coin<Base>, Coin<Quote>)
```

Withdraws the entire accumulated fee balance (both legs) to the caller.
Emits `FeesClaimed { book_id, enclosing_object_id, claimant, base_amount, quote_amount }`
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
Not gated by pause. Emits `OrderCancelled { book_id, enclosing_object_id,
order_id, trader }` and `MakerFeeSettled` (§9's Fees section, §13) only when an order
was actually found and removed — the latter is this order's conclusion,
which trues up its maker-fee reserve and folds any superadditive slack into
the escrow refunded here. Does not touch or pay out that order's
already-pooled proceeds (if any) — those remain claimable separately via
the order's `OrderTicket`, if the caller who placed it still holds one, or
payable at any time, live book or retiring, via the admin-gated
`push_proceeds` (§8), which is unconditional in the same way this function
is.

### Price band and last-price reset

See §4 and §5.

## 10. Deletion lifecycle

```
public fun clob_admin_retire<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>)
```

Sets `paused = true` and `retiring = true`. `retiring` is sticky: no
function ever clears it back to `false` once set. Emits `OrderBookRetired {
book_id, enclosing_object_id }`.

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

Emits `OrderCancelled` **and** `MakerFeeSettled` (§13) for every resting
order it force-cancels — the latter from the same centralized maker-fee
true-up that runs at every order conclusion — and `ProceedsClaimed` for
every nonzero pooled-proceeds entry it pays out (a zero-valued entry is
skipped, matching `claim_proceeds`/`push_proceeds`'s own skip-on-zero
convention). That is up to **two** events per drained resting order, plus
one per nonzero proceeds entry. Sui enforces a hard cap of 1024 events
emitted per transaction, so an admin's `max_items` choice should stay
comfortably under that limit (e.g. a few hundred), especially if multiple
`clob_admin_drain_step` calls are batched into a single PTB, where the cap
applies across the whole transaction, not per call. The `MakerFeeSettled`
addition roughly halves this function's previous safe per-call margin
against that cap (up to 2 events per drained order now, versus 1 before) —
an admin relying on a previously-safe `max_items` value should reassess it
accordingly.

Force-cancelling a partially-filled resting order routes its maker-fee
reserve into `book.fee_accumulator` through the same conclusion path
(`MakerFeeSettled`) every other order conclusion uses — this function does
not skip it. As a result, a `clob_admin_claim_fees` call made before every
`clob_admin_drain_step` call has finished may need to be repeated
afterward, since a later drain step can re-credit the accumulator with a
nonzero amount. See below for the recommended ordering.

```
public fun clob_admin_finalize<Base, Quote>(
    cap: ClobAdminCap,
    book: OrderBook<Base, Quote>,
    ctx: &mut TxContext,
): (ID, Coin<Base>, Coin<Quote>)
```

Consumes the `ClobAdminCap` and the `OrderBook` by value, permanently
deleting both. Aborts with `ENotRetiring` unless the book is retiring, and
with `ENotFullyDrained` (7) unless `bids.size() == 0 && asks.size() == 0 &&
proceeds.is_empty()` — i.e. `clob_admin_drain_step` must have fully drained
every resting order and pooled-proceeds entry first. The fee accumulator is
**not** part of this precondition: whatever remains in it at call time
(from either leg) is swept automatically and returned to the caller as the
second and third elements of the return tuple (`Coin<Base>`, `Coin<Quote>`,
either possibly zero-valued) — it does not need to be pre-emptied by
`clob_admin_claim_fees` first. Emits `OrderBookDeleted { book_id,
enclosing_object_id, base: TypeName, quote: TypeName }` (using the book's
`Base`/`Quote` type names) and `ClobAdminCapDiscarded { book_id,
enclosing_object_id, cap_id }` unconditionally, plus `FeesClaimed { book_id,
enclosing_object_id, claimant, base_amount, quote_amount }` whenever the
swept fee amount is nonzero on either leg. Returns the book's true,
unforgeable object id as the first tuple element — the same value both of
the unconditional events' `book_id` field carries.

**Recommended ordering.** To guarantee this function succeeds on the first
attempt: `clob_admin_retire` -> all `clob_admin_drain_step` calls (drain
every resting order and pooled-proceeds entry) -> `clob_admin_finalize`.
Calling `clob_admin_claim_fees` at any point before, during, or after that
sequence — or not at all — is purely optional cashflow timing, never a
correctness requirement: `clob_admin_finalize` sweeps whatever fee balance
remains and returns it as coins rather than requiring it to already be
zero.

## 11. Version guard

```
public fun assert_book_version<Base, Quote>(book: &mut OrderBook<Base, Quote>)
```

Public so an integrator wrapping the book can version-guard its own call
sites the same way this module's own functions do (every function in this
module that mutates the book calls this first). A book whose stored version
lags behind the currently-published package's version is transparently
upgraded in place with no separate migration call required — this emits
`BookVersionUpgraded { book_id, enclosing_object_id, from, to }`. A book whose stored version is
*ahead* of the currently-published package still aborts with
`ENewVersionMismatch` (5), since that direction cannot be auto-resolved.

The package's `CURRENT_VERSION` was bumped from 1 to 2 for the
`event_id` -> `enclosing_object_id` rename plus the addition of the new
`book_id` field to every emitted event (§13) — a wire-format change to
every event this module emits, even though no `OrderBook` on-chain data
actually needed converting (both stamped ids are derived fresh at emit
time from fields that already existed on the book). This bump is a marker
only; the self-healing auto-upgrade described above still applies
unchanged, with no explicit migration step required.

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
| `ask_base_escrow_at_price<Base, Quote>(book, price: u64): u64` | total resting Base size at that exact raw ask price; `0` if no such level exists, for any `price` value including `0` — never aborts. Ask-only (no `side` parameter): the bid-side equivalent is `bid_quote_escrow_at_price`, which is Quote-denominated, not Base — a single `side`-switched function returning the same `u64` type for two different denominations was removed as an integration hazard. |
| `bid_escrow_amount<Base, Quote>(book, price, size): u64` | escrow required for a bid at `(price, size)` (§3) |
| `ticket_order_id`/`ticket_order_book_id`/`ticket_side`/`ticket_price` | the corresponding field of an `OrderTicket` |
| `last_price<Base, Quote>(book): u64` | the book's current `last_price` (§5) |
| `price_band_factor<Base, Quote>(book): Option<u64>` | the book's current price-band factor, or `None` (§4) |
| `book_version<Base, Quote>(book): u64` | the book's current `version` (§11) |
| `min_size<Base, Quote>(book): u64` | the book's `min_size` floor (§2) |
| `bid_quote_escrow_at_price<Base, Quote>(book, price): u64` | the exact, maintained total of live `Quote` escrow held by every resting bid order at `price`; `0` if no bid level exists there. Bid-only (no `side` parameter) — an ask level's escrow is `Base`, already exactly equal to `ask_base_escrow_at_price(book, price)`, so there is no analogous "quote value" for it. |
| `resting_order_escrow<Base, Quote>(book, side, price, order_id): Option<RestingOrderEscrow>` | the live state of one resting order, or `None` if that price level doesn't exist or holds no such order (fully filled, cancelled, or never placed). Never aborts, for any input. |
| `resting_order_escrow_by_ticket<Base, Quote>(book, ticket): Option<RestingOrderEscrow>` | `resting_order_escrow` for the order `ticket` was minted for. Aborts with `EWrongBook` (16) if `ticket` was not minted by `book`. |
| `resting_order_escrow_fields(e: &RestingOrderEscrow): (u64, u64)` | `(escrow, remaining_size)` — `escrow` is Quote for a bid, Base for an ask (the currency that side actually escrows). `remaining_size` is ALSO denominated in Quote for a bid, Base for an ask — NOT always Base regardless of side. For a bid, `escrow` and `remaining_size` are therefore always equal (both are just the live Quote escrow value); for an ask they were already equal. `escrow` is the order's remaining escrowed *principal* only — `cancel_order` may additionally pay out pooled proceeds in the opposite currency, which this value does not include. For an ask, `escrow`/`remaining_size` can never reach `0` while still resting (draining to `0` is the same fill that stops it from resting). For a bid, under the telescoping proportional-ceiling escrow-charging scheme, `(escrow: 0, remaining_size: 0)` for a live, still-resting, still-fillable order IS a real, reachable state whenever the order's resting price is below `price_scale` — the Quote escrow can hit exactly `0` strictly before the order's Base side is exhausted. `None` (not resting at all) remains the only other state for either side. |
| `resting_order_owner<Base, Quote>(book, side: bool, price: u64, order_id: u64): Option<address>` | the recorded `owner` address of the resting order at `(side, price, order_id)` — i.e. the address `clob_admin_cancel_order`/`clob_admin_drain_step` will pay if it is force-cancelled/drained. `None` if the order is not resting. Lets an integrator confirm ahead of time where an admin bulk-payout path will route before relying on it. |
| `resting_order_owner_by_ticket<Base, Quote>(book, ticket: &OrderTicket): Option<address>` | `resting_order_owner` for the order `ticket` was minted for. Aborts with `EWrongBook` if `ticket` was not minted by `book`. |
| `proceeds_owner<Base, Quote>(book, order_id: u64): Option<address>` | the recorded `owner` address of the pooled proceeds entry for `order_id`, if one exists — i.e. the address `push_proceeds`/the internal `drain_proceeds` (reached via `clob_admin_drain_step`) will pay out to. `None` if no pooled entry exists. Lets an integrator confirm ahead of time where `push_proceeds`/`drain_side`/`drain_proceeds` will route before relying on that admin path to pay the right address. |
| `proceeds_owner_by_ticket<Base, Quote>(book, ticket: &OrderTicket): Option<address>` | `proceeds_owner` for the order `ticket` was minted for. Aborts with `EWrongBook` if `ticket` was not minted by `book`. |

## 13. Events reference

Within one call to a matching entry point, events are emitted in a fixed
order: zero-or-more `OrderFilled`, then an optional `OrderPlaced`, then
exactly one `OrderExecuted` as a trailer. Correlating fills to their
triggering call relies on this within-transaction ordering (Sui's event
ordering within a transaction's effects is deterministic).

**Two-field id prefix.** Every event below leads with the same two fields,
in the same order:

- `book_id: ID` — the book's own true, unforgeable object id
  (`object::uid_to_inner(&book.id)`, the same value `book_id<Base, Quote>`
  returns). Not caller-controllable; always the book's real identity.
- `enclosing_object_id: ID` — the id supplied to `new`'s mandatory
  `enclosing_object_id: &UID` parameter at construction (§2). Fixed for the
  book's lifetime, but caller-supplied and therefore potentially unrelated
  to the book's true identity — never use it for authentication or as
  proof of which book emitted the event; use `book_id` for that instead.

An off-chain consumer that wants to index by the book's real identity
should read `book_id`; one that wants whatever identity the integrator's
wrapping object chose to be indexed by should read `enclosing_object_id`.
Reading both together lets a consumer cross-check the caller-supplied value
against the book's unforgeable one, closing the spoofing gap a
`enclosing_object_id`-only event stream would otherwise leave open.

| Event | Fields |
|---|---|
| `BookVersionUpgraded` | `book_id: ID`, `enclosing_object_id: ID`, `from: u64`, `to: u64` |
| `Paused` | `book_id: ID`, `enclosing_object_id: ID` |
| `Unpaused` | `book_id: ID`, `enclosing_object_id: ID` |
| `TakerFeeSet` | `book_id: ID`, `enclosing_object_id: ID`, `rate_bps: u64` |
| `MakerFeeSet` | `book_id: ID`, `enclosing_object_id: ID`, `rate_bps: u64` |
| `FeesClaimed` | `book_id: ID`, `enclosing_object_id: ID`, `claimant: address`, `base_amount: u64`, `quote_amount: u64` |
| `PriceBandFactorSet` | `book_id: ID`, `enclosing_object_id: ID`, `factor: Option<u64>` |
| `LastPriceSet` | `book_id: ID`, `enclosing_object_id: ID`, `last_price: u64`, `setter: address` |
| `OrderCancelled` | `book_id: ID`, `enclosing_object_id: ID`, `order_id: u64`, `trader: address` |
| `OrderBookRetired` | `book_id: ID`, `enclosing_object_id: ID` |
| `OrderBookDeleted` | `book_id: ID`, `enclosing_object_id: ID`, `base: TypeName`, `quote: TypeName` |
| `ClobAdminCapDiscarded` | `book_id: ID`, `enclosing_object_id: ID`, `cap_id: ID` |
| `OrderPlaced` | `book_id: ID`, `enclosing_object_id: ID`, `order_id: u64`, `side: bool`, `price: u64`, `size: u64`, `trader: address`, `maker_fee_bps: u64` |
| `OrderFilled` | `book_id: ID`, `enclosing_object_id: ID`, `maker_order_id: u64`, `price: u64`, `size: u64`, `maker: address`, `taker: address`, `maker_side: bool`, `quote_amount: u64` |
| `OrderExecuted` | `book_id: ID`, `enclosing_object_id: ID`, `taker: address`, `taker_side: bool`, `entry_point: u8`, `limit_price: Option<u64>`, `requested_size: u64`, `unmatched_size: u64`, `rested_size: u64`, `rested_order_id: Option<u64>`, `stopped_on_max_fills_while_crossing: bool`, `taker_fee_amount: u64` |
| `MakerFeeSettled` | `book_id: ID`, `enclosing_object_id: ID`, `order_id: u64`, `maker: address`, `amount: u64` |
| `ProceedsClaimed` | `book_id: ID`, `enclosing_object_id: ID`, `claimant: address`, `base_amount: u64`, `quote_amount: u64` |
| `OrderOwnerUpdated` | `book_id: ID`, `enclosing_object_id: ID`, `order_id: u64`, `old_owner: address`, `new_owner: address` |

`OrderPlaced.maker_fee_bps` is the maker-fee rate snapshotted into the
resting order at placement time — permanent for the order's lifetime; later
`MakerFeeSet` changes never retroactively affect it.

`OrderFilled` carries no fee information — it is a pure per-fill
notification. Taker fees are now computed once per call, in aggregate, and
reported on `OrderExecuted.taker_fee_amount` below; maker fees are set
aside per-fill into a reserve private to the resting order and only
actually collected — and reported via `MakerFeeSettled` — when that order
concludes. See §9's Fees section for the full model.

`quote_amount`'s rounding direction on a given fill depends on whether that
fill fully drains the resting maker order (leaving `remaining_size == 0`) or
leaves it still resting, and differs by side:

- A fill that **fully drains** the maker order: on the maker-ask side
  (`maker_side == false`), `quote_amount = max(floor(price * size /
  price_scale), 1)` — at least 1 atom, but may be *less* than
  `ceil(price * size / price_scale)`. On the maker-bid side
  (`maker_side == true`), `quote_amount` is exactly whatever Quote remains of
  that order's original escrow reservation, which may also differ from
  `ceil(price * size / price_scale)`.
- A fill that leaves the order **still resting**: on the maker-ask side,
  `quote_amount = ceil(price * size / price_scale)` exactly, unchanged. On
  the maker-bid side, `quote_amount` is never more than what remains in that
  order's Quote escrow, but — unlike the ask side — it CAN be exactly `0`
  even while the order's remaining Quote escrow is still nonzero (i.e. a
  fill with `fill_qty > 0` that charges no additional Quote this round);
  this is a legitimate, non-error outcome of the escrow-charging scheme and
  is not itself evidence of the `(escrow: 0, remaining_size: 0)` state
  described under `resting_order_escrow_fields` (§12).

This rounding is deliberately asymmetric: a fill that exhausts a resting
order's own liquidity (not the taker's choice) never costs the taker more
than a single consolidated fill of the same total size would have, while a
fill the taker chooses to stop short of draining the maker keeps the
maker-protective ceiling. Although any single `quote_amount` may deviate by
rounding, the sum is exact: for a given `maker_order_id`, the total of
`quote_amount` across every `OrderFilled` event with the same `maker_side`
emitted over that order's entire lifetime equals exactly the amount debited
from that order's escrow — and equals exactly the full escrow originally
reserved for it if the order is filled to completion, with zero residual
dust, no matter how many separate fills or transactions it was drained
across. If the order is only partially filled, the sum is strictly less than
the original reservation, and the exact difference is what `cancel_order`
(or `clob_admin_cancel_order` / `clob_admin_drain_step`) refunds.

`OrderExecuted` is emitted exactly once, unconditionally, as the last event
of every call to `place_limit_order_bid` / `place_limit_order_ask` /
`place_market_order_bid` / `place_market_order_ask` — after any
slippage-guard asserts in the market functions, so an abort emits nothing.
`entry_point` identifies which of the four functions produced the event:

| `entry_point` | Function |
|---|---|
| 0 | `place_limit_order_bid` |
| 1 | `place_limit_order_ask` |
| 2 | `place_market_order_bid` |
| 3 | `place_market_order_ask` |

(Entry point values 4 and 5, formerly `swap_bid`/`swap_ask`, are no longer
produced now that those functions have been removed; they are not reused
for anything else.)

`limit_price` is `None` for market orders; for `place_limit_order_*`, the
resting/placement price. `unmatched_size` is the remaining size after
matching. For `entry_point` 0 (limit bid), the taker fee is charged in Base
(the side received), and this is gross of that fee — `requested_size -
unmatched_size` does not equal the base returned to the taker when
`taker_fee_bps > 0`. For `entry_point` 1 (limit ask) and 3 (market ask), the
taker fee is instead charged in Quote, never Base, so this caveat does not
apply: `requested_size - unmatched_size` always equals the base actually
sold. For `entry_point` 2 (`place_market_order_bid`) specifically,
`unmatched_size` is the NET shortfall against the caller's own NET
`max_base_out` request, so for that entry point too `requested_size -
unmatched_size` equals the base actually delivered to the taker.
`rested_size` is `0` if nothing rests;
on the bid limit path it can be less than `unmatched_size` even when
something rests, because `place_limit_order_bid` clamps the resting size to
what leftover escrow can actually back. `rested_order_id` is `Some(id)` iff
something rested this call, else `None`. `taker_fee_amount` is this call's
own taker fee, computed once in aggregate after matching completes and
already deducted from the matched proceeds returned to the taker — see §9's
Fees section. It is denominated in Base for a bid-side taker
(`taker_side == true`) and Quote for an ask-side taker (`taker_side ==
false`).

`MakerFeeSettled` is emitted exactly once for every order that concludes —
see §9's Fees section for the full model and the four ways an order can
conclude. `amount` is the CORRECT aggregate maker fee actually collected
across that order's entire fill history (not the sum of each fill's own
independently-ceiling-rounded fee), denominated in Base for a bid-side
order and Quote for an ask-side order (whichever currency that order's
maker fee is actually paid in).

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
| 29 | `EPriceOverflow` |
| 30 | `EMinExceedsMaxBaseOut` |
| 31 | `EOrderStillResting` |
| 32 | `EEnclosingIsSelf` |
| 33 | `EInvalidOwner` |

(Codes 2, 10, 11, 13 are not currently in use.)

## 15. Border cases — consolidated list

- `price == 0` is rejected everywhere it is checked (`EZeroPrice`): at
  construction (`initial_last_price`), `set_last_price`, and
  `place_limit_order_bid`/`_ask`.
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
  via `place_market_order_bid`/`_ask` — those fill at whatever price the
  book's existing resting orders offer, regardless of the current
  `price_band_factor` or `last_price`.
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
- For an ask, `resting_order_escrow`'s `escrow`/`remaining_size` can never
  both reach `0` while the order still rests (they are equal, and draining
  to `0` is the same fill that stops it from resting). For a bid, this is
  no longer true: `remaining_size` is Quote-denominated for a bid (equal to
  `escrow`), and under the telescoping proportional-ceiling escrow-charging
  scheme, `Some((escrow: 0, remaining_size: 0))` for a live, still-resting,
  still-fillable bid IS a real, reachable state whenever the order's
  resting price is below `price_scale` — the Quote escrow can hit exactly
  `0` strictly before the order's Base side is exhausted. This is distinct
  from `None` (not resting at all) and is not an error condition.
- `bid_quote_escrow_at_price` is an exact, maintained aggregate, not a
  re-derivation — unlike computing `bid_escrow_amount(book, price, size)`
  with a `size` from some other source, which can over- or under-count the
  true live escrow by up to roughly one `Quote` atom per resting order at
  that price, in either direction, depending on each order's own fill
  history. (Feeding `bid_quote_escrow_at_price`'s own return value into
  `bid_escrow_amount` as a `size` is a category error, not just rounding
  dust — that value is already Quote-denominated, so `bid_escrow_amount`
  would multiply by `price` a second time.)
- A `place_limit_order_bid` call's unmatched remainder may rest at a
  smaller size than requested if leftover escrow cannot fully back it at
  the ceiling-rounded rate; the returned ticket is `option::none()` when
  nothing ends up resting. `place_limit_order_ask` has no analogous
  shortfall case.
- `min_size` is checked only at placement time, never against a post-fill
  remainder; a resting order can end up smaller than `min_size` ("dust")
  and will persist until cancelled, fully filled, or admin-removed.
- A fill whose entire credited proceeds round to zero in both `Base` and
  `Quote` (e.g. a fee ceiling consuming the whole leg on a dust-sized fill)
  never creates a pooled proceeds entry for that order id in the first
  place — it is not created and later skipped, there is simply nothing to
  find. This is what lets `destroy_orphaned_ticket` dispose of such a
  ticket without hitting `EProceedsNotEmpty`.
- Pausing blocks all order-placement/market entry points but never
  `cancel_order`, `claim_proceeds`, `update_resting_order`, `set_last_price`,
  or `clob_admin_cancel_order`.
- `clob_admin_unpause_book` always aborts on a retiring book; once
  `clob_admin_retire` has been called, the book can never be unpaused again.
- `clob_admin_cancel_order` and `clob_admin_finalize`'s emptiness checks are
  independent of any pooled proceeds for the removed/remaining orders —
  proceeds are refunded/paid separately from escrow.
- `update_resting_order`'s pooled-proceeds owner sync runs unconditionally,
  regardless of whether it finds the order still resting — even if the
  order has already concluded (fill-drained, `cancel_order`ed,
  `clob_admin_cancel_order`ed, or `clob_admin_drain_step`-removed), a
  pooled, unclaimed proceeds entry for it is still resynced to `new_owner`;
  the `bool` return reflects only whether the resting order itself was
  found and reassigned. Relatedly, `cancel_order` sweeps and pays out
  any pooled proceeds as part of the same call — to the caller
  (`ctx.sender()`), same as `claim_proceeds`, not the recorded `owner` —
  while `clob_admin_cancel_order` deliberately does not — it refunds only the
  escrow principal, leaving pooled proceeds recoverable afterward via
  `claim_proceeds` (through the order's `OrderTicket`), the admin-gated
  `push_proceeds` (live book or retiring, unconditionally), or, once the
  book is retiring, the internal `drain_proceeds` reached through
  `clob_admin_drain_step`. `push_proceeds` IS a live-book path — unlike
  `clob_admin_drain_step`, it carries no `book.retiring` requirement of its
  own, gated only on the book's version and the `ClobAdminCap`, exactly
  like `clob_admin_cancel_order`.
- `push_proceeds`'s payout destination is always the recorded `owner` for
  that order id, never caller-suppliable, even by the admin.
- `destroy_orphaned_ticket` refuses to discard a ticket that still has
  pooled, unclaimed proceeds attached to its order id, or whose order is
  still resting on the book.
  `destroy_ticket_unconditionally` has no such restriction and takes no
  `OrderBook` parameter — it is the only disposal path left once a
  ticket's book has already been deleted.
- `clob_admin_finalize` requires zero resting orders on both sides and zero
  pooled proceeds entries before it will succeed — the fee-accumulator
  balance is not part of this precondition. Whatever remains in it (on
  either leg) is swept automatically and returned to the caller as coins.
- Fee rate changes apply to fills from that point forward only; an
  already-resting order keeps the maker-fee rate that was in effect when it
  was placed.
- Every fee computation rounds up: any nonzero receive amount at a nonzero
  fee rate always pays at least 1 atomic unit of fee.
- Calling `clob_admin_claim_fees` before, during, or after
  `clob_admin_drain_step`/`clob_admin_finalize` — or not at all — is purely
  optional cashflow timing, never a correctness requirement: a later drain
  step can re-credit the fee accumulator (force-cancelling a
  partially-filled resting order settles its maker-fee reserve the same as
  any other order conclusion), but `clob_admin_finalize` simply sweeps
  whatever is left rather than requiring it to already be zero.

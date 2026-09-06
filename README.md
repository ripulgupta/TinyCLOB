# TinyCLOB

A generic, permissionless, on-chain central limit order book (CLOB) for Sui
Move, implemented as an embeddable package rather than a standalone
application.

`tiny_clob::tiny_clob` provides price-time-priority limit and market order
matching for any `Coin<Base>` / `Coin<Quote>` pair, backed by a crit-bit price
tree (`price_tree.move`) and a FIFO order queue per price level
(`order.move`). Prices use fixed-point integer scaling with
per-book-configurable decimals, precision, and exponent, so a single generic
module can host markets across wildly different token decimal ranges and
price magnitudes. Orders are represented as bearer `OrderTicket` objects, and
book governance (pause, retire, fee rates, price-band safeguard) is gated
behind a capability object minted once per book.

## What this is

- **Generic** — parameterized over `<Base, Quote>` coin types; any book is a
  fresh instantiation for one coin pair.
- **Permissionless to construct** — `new<Base, Quote>` can be called by any
  address; no admin or registry approval is required to spin up a book.
- **Fixed-point pricing** — a book declares `base_decimals`, `quote_decimals`,
  `precision`, and `exponent` at construction, from which a `price_scale` is
  derived once and fixed for the book's lifetime. This lets the same code
  correctly price both very cheap, high-decimal tokens and very expensive,
  low-decimal ones.
- **Bearer order tickets** — placing a limit order that rests returns an
  `OrderTicket` value object. Whoever holds that ticket can cancel the order,
  reassign its payout owner, or claim proceeds against it — authority follows
  possession of the ticket, not an address recorded in book state.
- **Maker/taker fees** — independently configurable taker and maker fee
  rates (in bps, capped low), with maker fees settled once per order at
  conclusion rather than per fill.
- **Admin-capability-gated governance** — a `ClobAdminCap`, minted alongside
  the book at construction, gates pausing, fee-rate changes, the optional
  price-band safeguard, force-cancellation/proceeds-rescue, and the
  retire → drain → finalize deletion lifecycle.

See `docs/FEATURES.md` for the full, precise contract: every public
function's parameters, abort conditions, events, and documented edge cases.

## Where and how this can be used

TinyCLOB is a **Move package/library**, not a hosted or deployed service, and
it does not register itself anywhere on-chain by default. Both `OrderBook`
and `ClobAdminCap` are declared `has store` only — never `key` — so neither
can become a standalone Sui object or be shared via
`sui::transfer::share_object`. They are meant to be **embedded as fields
inside an integrator's own object**, which the integrator gives whatever
storage/access model it needs (a shared object, an owned object, a dynamic
field, etc.).

Concretely, this shape supports use cases such as:

- **A settlement layer for a custom trading application** — an integrator
  wraps `OrderBook<Base, Quote>` inside their own shared object and exposes
  their own entry functions on top, adding whatever access control, UI, or
  indexing integration they need.
- **A building block for a DEX front-end or aggregator** — since order
  placement returns real `Coin<Base>`/`Coin<Quote>` values and `OrderTicket`
  objects directly to the caller (no intermediate custody by the module
  itself beyond escrowed balances), a front-end or aggregator contract can
  compose order placement and matching into a larger transaction (a PTB)
  alongside other DeFi primitives.
- **Programmatic market-making** — because resting orders are represented as
  transferable `OrderTicket` bearer objects, a market-making bot or strategy
  contract can hold, transfer, or manage many tickets across many resting
  orders, cancelling or updating ownership as needed without the book itself
  needing to track a caller identity beyond ticket possession.

Because construction is permissionless and unregistered, discovering "which
books exist" is entirely the integrator's responsibility (e.g. via emitted
events and their own registry) — TinyCLOB itself keeps no global index of
books.

## Key design characteristics for integrators

- **Dual-ID event scheme.** Every event a book emits carries both the book's
  own object id (`book_id`) and a separate `enclosing_object_id` — the id of
  whatever object the integrator embedded the book inside, supplied once at
  construction and stamped on every subsequent event. This lets an indexer
  correlate a book's activity back to the integrator's own wrapping object
  without the module needing to know anything about that object's shape.
- **`OrderTicket` bearer-object custody.** An `OrderTicket` is the sole
  self-service path back to a resting order's escrow and proceeds while both
  the order and the book are live. Whoever holds the ticket controls the
  order — there is no address-based ACL for cancellation or ownership
  reassignment. Destroying a ticket carelessly (via
  `destroy_ticket_unconditionally`) does not burn the underlying funds — the
  admin can still recover them via `admin_redeem_ticket` — but it does give
  up the holder's own convenient recovery path, so ticket custody should be
  handled with the same care as any other bearer-object asset.
- **Scope of the admin capability.** `ClobAdminCap` gates pausing/unpausing,
  taker/maker fee-rate changes, the optional price-band factor, fee
  withdrawal, force-cancellation and proceeds-rescue (`admin_redeem_ticket`),
  and the one-way retire → drain → finalize deletion sequence. It does
  *not* gate everyday trading, cancellation, proceeds claims, or ownership
  reassignment — those remain available to any ticket holder regardless of
  pause state — and `set_last_price` requires no capability at all (see
  `docs/FEATURES.md` §5 for a documented griefing/escape-hatch limitation
  around that). Pausing blocks new order placement only; a trader can always
  recover funds already at rest.
- **Book-creation-time configurability.** Fee rates (bounded caps, both
  default to zero), the optional price-band safeguard, and the
  decimals/precision/exponent that determine the book's price resolution and
  representable range are all book-level parameters, either set at
  construction or adjustable afterward only through the admin capability —
  giving each book independent economic and precision parameters without
  needing a separate module per market.

## Repository structure

- `sources/` — the Move package: `tiny_clob.move` (the order book module and
  its public API), `order.move` (the resting-order type and its FIFO-queue
  invariants), `price_tree.move` (the generic crit-bit price-level tree).
- `tests/` — the Move test suite, organized by concern (construction/admin,
  price representation and decimals, order placement and validation,
  matching/FIFO behavior, cancellation and proceeds, escrow edge cases, fee
  behavior, price-band/last-price behavior, events, and more). Test file
  names are a good map of what's covered.
- `docs/FEATURES.md` — the detailed external interface reference: every
  public function's contract, abort conditions, events, and documented edge
  cases. Start there for anything beyond this overview.

## Building and testing

This is a standard Sui Move package (`Move.toml` declares `tiny_clob`,
edition `2024`, with no local `[addresses]` section — the modern package
system auto-assigns the address and resolves the Sui framework implicitly).
With the Sui CLI installed:

```
sui move build
sui move test
```

Run a single test file/module or filter by name with `sui move test <filter>`
as usual.

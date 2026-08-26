/// `EmbeddedOrderBook<Base, Quote>` — an additive order-book variant an
/// integrator embeds as a field of their own object instead of registering
/// it as a shared, globally-deduplicated `OrderBook<Base, Quote>`. See
/// `docs/spec/embedded_market.md` for the full design.
///
/// This module owns every `EmbeddedPoolAdminCap`-gated function (local
/// pause/unpause, fee setters/claim, force-cancel, retire/drain/finalize,
/// migration) — mirroring `market.move`'s own struct-colocation convention.
/// The placement/cancel/claim functions that must construct `OrderTicket`/
/// emit `order.move`'s own event structs live in `sources/order.move`
/// instead, per Move's module-privacy rule on struct-literal construction
/// (`docs/spec/embedded_market.md` §Module placement).
module tiny_clob::embedded_market;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::linked_table::{Self, LinkedTable};
use std::type_name::{Self, TypeName};
use tiny_clob::pending_transfer;
use tiny_clob::price_tree::{Self, PriceTree};

// === Error constants (module-local; no error constant shared with
// market.move/order.move/admin.move) ===

const EZeroLotSize: u64 = 0;
const EZeroMinSize: u64 = 1;
const EMinSizeNotMultipleOfLotSize: u64 = 2;
const ELotOrMinSizeTooLarge: u64 = 3;
const EWrongPoolAdminCap: u64 = 4;
const ENewVersionMismatch: u64 = 5;
const ENotRetiring: u64 = 6;
const ENotFullyDrained: u64 = 7;
const ETakerFeeRateTooHigh: u64 = 8;
const EMakerFeeRateTooHigh: u64 = 9;
const EStaleObjectVersion: u64 = 10;
/// `size` is not a multiple of the market's `lot_size` (M14 Chunk 1;
/// mirrors `order.move`'s `ESizeNotMultipleOfLotSize`, duplicated per this
/// package's module-private-constant convention — see `MAX_LOT_OR_MIN_SIZE`
/// above for the precedent).
const ESizeNotMultipleOfLotSize: u64 = 11;
/// `size` is below the market's `min_size` (M14 Chunk 1; mirrors
/// `order.move`'s `ESizeBelowMinSize`).
const ESizeBelowMinSize: u64 = 12;
/// A `price * size`-style multiplication's `u128` intermediate exceeds
/// `u64::MAX` (M14 Chunk 1; mirrors `order.move`'s `EEscrowOverflow`).
const EEscrowOverflow: u64 = 13;
/// `place_limit_order_*` called with `price == 0` (M14 Chunk 2; mirrors
/// `order.move`'s `EZeroPrice`).
const EZeroPrice: u64 = 14;
/// A placement function was called against a soft-paused/retiring market
/// (M14 Chunk 2; mirrors `order.move`'s `EMarketPaused` — this module's
/// merged `paused` field covers both cases at once, see the struct comment
/// above).
const EMarketPaused: u64 = 15;
/// `cancel_order`'s `ticket.order_book_id != id(book)` (M14 Chunk 2;
/// mirrors `order.move`'s `EWrongMarket`).
const EWrongMarket: u64 = 16;
/// A market order's supplied slippage bound was violated by the realized
/// matched amount (M14 Chunk 2; mirrors `order.move`'s `ESlippageExceeded`).
const ESlippageExceeded: u64 = 17;

const MAX_TAKER_FEE_BPS: u64 = 10;
const MAX_MAKER_FEE_BPS: u64 = 5;
/// Duplicated from `market.move`'s own constant of the same name/value
/// (Move constants are always module-private; no cross-module sharing
/// mechanism exists) — see `market.md` §`create_market`'s sanity ceiling for
/// this value's own derivation. `new` below is this package's single source
/// of truth for lot_size/min_size validation (`market::create_market` keeps
/// its own redundant copy of the same four checks only because existing
/// tests assert on its own specific abort codes — see the cross-reference
/// comment at `market.move`'s `create_market` call site). If this value or
/// the four checks in `new` are ever edited, keep `market.move`'s copy in
/// sync.
const MAX_LOT_OR_MIN_SIZE: u64 = 1_000_000_000_000_000;
/// Duplicated from `order.move`'s own constant of the same name/value
/// (M14 Chunk 1; same module-private-constant convention as above).
const U64_MAX: u128 = 0xFFFFFFFFFFFFFFFF;

// === M14 Chunk 3 (unplanned, load-bearing fix — see final report): the
// order-domain struct shells (`Order`, `PriceLevel`, `MakerBalance`,
// `FeeAccumulator`) and their field-touching accessor functions relocate
// here from `sources/market.move`, unchanged in body except dropping the
// `market::` self-qualification (now local calls) and the `book.`/`fees.`
// receiver renaming where a function used to take a whole `&(mut)
// OrderBook`/`&(mut) FeeAccumulator` and now takes the already-decomposed
// piece directly (mirroring the pattern `bids_mut_proceeds_mut_and_fees_
// mut` already established).
//
// **Why this was necessary, discovered empirically during Chunk 3**:
// `docs/spec/architecture.md`'s own "five-module dependency map" mandates
// `embedded_market.move` never `use tiny_clob::market` (REQ-ARCH-002) and
// `market.move` gain a new `use tiny_clob::embedded_market` (for the new
// `core: EmbeddedOrderBook<Base, Quote>` field the composing `OrderBook`
// struct needs, REQ-ARCH-006). But at the start of Chunk 3,
// `embedded_market.move` still carried its pre-existing (tenth-cycle)
// `use tiny_clob::market::{Self, Order, PriceLevel, MakerBalance,
// FeeAccumulator};` — adding `market.move`'s own new `use tiny_clob::
// embedded_market` on top of that un-relocated dependency produces a
// genuine Move `E02004` cyclic-module-dependency compile error (confirmed
// directly by attempting the build), which no chunk of `docs/plan-m14.md`'s
// own task list anticipates or resolves. The only structurally possible fix
// is breaking `embedded_market.move`'s existing dependency on `market.
// move` by relocating the four struct definitions (and the functions that
// construct/destructure their fields, which Move restricts to a struct's
// own defining module regardless of function visibility) into this module
// — which also happens to be the architecturally *correct* end state per
// `architecture.md`'s own stated dependency graph, just not called out as
// its own task anywhere in the plan. This unavoidably requires updating a
// handful of call sites in `sources/order.move`/`sources/admin.move` (a
// mechanical `market::foo(...)` -> `embedded_market::foo(...)` prefix
// rename at each now-relocated function's call site, zero behavior change)
// — a narrow, disclosed deviation from Chunk 3's own "order.move/admin.move
// completely untouched" promise, unavoidable given Move's real compilation
// rules. See this cycle's final report for the full accounting.

/// The resting price-tree entry. Relocated unchanged from `sources/
/// market.move`'s own `Order` (`order.md` §Order; REQ-ORDER-004).
public struct Order<phantom Base, phantom Quote> has store {
    order_id: u64,
    owner: address,
    remaining_quantity: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
}

/// One price level's FIFO queue of resting orders. Relocated unchanged from
/// `sources/market.move`'s own `PriceLevel` (`order.md` §PriceLevel).
public struct PriceLevel<phantom Base, phantom Quote> has store {
    orders: LinkedTable<u64, Order<Base, Quote>>,
}

/// A maker's claimable-but-unclaimed proceeds ledger entry. Relocated
/// unchanged from `sources/market.move`'s own `MakerBalance` (`order.md`
/// §MakerBalance).
public struct MakerBalance<phantom Base, phantom Quote> has store {
    base: Balance<Base>,
    quote: Balance<Quote>,
}

/// Per-book accumulator of collected taker/maker fees. Relocated unchanged
/// from `sources/market.move`'s own `FeeAccumulator` (`docs/spec/fee.md`
/// §`FeeAccumulator<Base, Quote>`).
public struct FeeAccumulator<phantom Base, phantom Quote> has store {
    base: Balance<Base>,
    quote: Balance<Quote>,
}

public(package) fun new_order<Base, Quote>(
    order_id: u64,
    owner: address,
    remaining_quantity: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
): Order<Base, Quote> {
    Order { order_id, owner, remaining_quantity, escrow_base, escrow_quote, maker_fee_bps }
}

public(package) fun order_maker_fee_bps<Base, Quote>(o: &Order<Base, Quote>): u64 {
    o.maker_fee_bps
}

public(package) fun order_id<Base, Quote>(o: &Order<Base, Quote>): u64 {
    o.order_id
}

public(package) fun order_owner<Base, Quote>(o: &Order<Base, Quote>): address {
    o.owner
}

public(package) fun order_remaining_quantity<Base, Quote>(o: &Order<Base, Quote>): u64 {
    o.remaining_quantity
}

public(package) fun order_decrease_remaining<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64) {
    o.remaining_quantity = o.remaining_quantity - amount;
}

/// `order.move`'s `redeem_transfer_ticket` mutator (REQ-ORDER-043). Fully
/// private (encapsulation-leak fix, Problem 1): the only external use case
/// this served is now covered by the narrow `update_resting_order_owner`
/// action function below, which calls this internally.
fun order_set_owner<Base, Quote>(o: &mut Order<Base, Quote>, new_owner: address) {
    o.owner = new_owner;
}

public(package) fun order_split_escrow_base<Base, Quote>(
    o: &mut Order<Base, Quote>,
    amount: u64,
): Balance<Base> {
    balance::split(o.escrow_base.borrow_mut(), amount)
}

public(package) fun order_split_escrow_quote<Base, Quote>(
    o: &mut Order<Base, Quote>,
    amount: u64,
): Balance<Quote> {
    balance::split(o.escrow_quote.borrow_mut(), amount)
}

public(package) fun destroy_order<Base, Quote>(
    o: Order<Base, Quote>,
): (Option<Balance<Base>>, Option<Balance<Quote>>) {
    let Order { order_id: _, owner: _, remaining_quantity: _, escrow_base, escrow_quote, maker_fee_bps: _ } = o;
    (escrow_base, escrow_quote)
}

public(package) fun new_price_level<Base, Quote>(ctx: &mut TxContext): PriceLevel<Base, Quote> {
    PriceLevel { orders: linked_table::new(ctx) }
}

/// Fully private (encapsulation-leak fix, Problem 1): no external caller may
/// hold a raw `&mut LinkedTable` into a price level's order queue — every
/// external mutation goes through this module's own action functions
/// instead. Still used internally throughout this module.
fun price_level_orders_mut<Base, Quote>(
    level: &mut PriceLevel<Base, Quote>,
): &mut LinkedTable<u64, Order<Base, Quote>> {
    &mut level.orders
}

public(package) fun price_level_is_empty<Base, Quote>(level: &PriceLevel<Base, Quote>): bool {
    level.orders.is_empty()
}

public(package) fun destroy_empty_price_level<Base, Quote>(level: PriceLevel<Base, Quote>) {
    let PriceLevel { orders } = level;
    linked_table::destroy_empty(orders);
}

/// Support for `market.move`'s own `depth_at_price` (REQ-MARKET view
/// function, unchanged signature) — relocated from `market.move`'s private
/// `sum_price_level`, widened to `public(package)` since `market.move` must
/// now call across the module boundary to reach it.
public(package) fun sum_price_level<Base, Quote>(level: &PriceLevel<Base, Quote>): u64 {
    let mut total = 0;
    if (level.orders.is_empty()) {
        return total
    };
    let mut cursor = *level.orders.front();
    while (cursor.is_some()) {
        let order_id = *cursor.borrow();
        let order = level.orders.borrow(order_id);
        total = total + order.remaining_quantity;
        cursor = *level.orders.next(order_id);
    };
    total
}

public(package) fun credit_maker_table<Base, Quote>(
    proceeds: &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    addr: address,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    if (!linked_table::contains(proceeds, addr)) {
        linked_table::push_back(proceeds, addr, MakerBalance { base: balance::zero(), quote: balance::zero() });
    };
    let mb = linked_table::borrow_mut(proceeds, addr);
    mb.base.join(base);
    mb.quote.join(quote);
}

public(package) fun destroy_maker_balance<Base, Quote>(
    mb: MakerBalance<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    let MakerBalance { base, quote } = mb;
    (base, quote)
}

public(package) fun new_fee_accumulator<Base, Quote>(): FeeAccumulator<Base, Quote> {
    FeeAccumulator { base: balance::zero(), quote: balance::zero() }
}

public(package) fun withdraw_fee_accumulator_raw<Base, Quote>(
    fees: FeeAccumulator<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    let FeeAccumulator { base, quote } = fees;
    (base, quote)
}

public(package) fun fee_accumulator_balances_raw<Base, Quote>(fees: &FeeAccumulator<Base, Quote>): (u64, u64) {
    (balance::value(&fees.base), balance::value(&fees.quote))
}

public(package) fun withdraw_fee_accumulator_in_place<Base, Quote>(
    fees: &mut FeeAccumulator<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    (fees.base.withdraw_all(), fees.quote.withdraw_all())
}

public(package) fun credit_fee_accumulator<Base, Quote>(
    fees: &mut FeeAccumulator<Base, Quote>,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    fees.base.join(base);
    fees.quote.join(quote);
}

// === EmbeddedOrderBook<Base, Quote> (REQ-EMBED-002) ===

/// Field order mirrors `OrderBook<Base, Quote>`'s own field order exactly,
/// with one deliberate structural difference: there is no separate
/// `retiring: bool` field — `paused` serves both purposes (the local
/// soft-pause flag and the deletion-lifecycle "has `retire` been called"
/// gate). See `docs/spec/embedded_market.md`'s "Consequence of the merged
/// `paused` field" note for the accepted interaction this causes with
/// `pool_admin_unpause_market`.
///
/// **`has store` only — deliberately no `key`.** This is a design
/// correction from this struct's original `key, store` ability set: the
/// operator wants it structurally IMPOSSIBLE for `EmbeddedOrderBook` to
/// ever become a Sui shared object via `sui::transfer::share_object`, which
/// requires `key`. There is no way to keep `key` while blocking just that
/// one operation, so dropping `key` entirely is the only enforced
/// mechanism — this is a compile-time guarantee, not something a runtime
/// test can exercise, hence this comment in place of a test. `id: UID` is
/// retained purely as a genuine, globally-unique `UID` value this struct
/// can hold as a plain `store`-only field (legal Move: a struct needs
/// `key` to be a *top-level* object, but any struct — `key` or not — may
/// hold a `UID` field and use it to anchor its own dynamic fields via
/// `sui::dynamic_field`, since dynamic-field storage is keyed off the
/// `UID`'s address regardless of the containing struct's own abilities);
/// it is never used to make this struct independently object-like.
#[allow(lint(missing_key))]
public struct EmbeddedOrderBook<phantom Base, phantom Quote> has store {
    id: UID,
    lot_size: u64,
    min_size: u64,
    bids: PriceTree<PriceLevel<Base, Quote>>,
    asks: PriceTree<PriceLevel<Base, Quote>>,
    proceeds: LinkedTable<address, MakerBalance<Base, Quote>>,
    paused: bool,
    next_order_id: u64,
    pool_admin_cap_id: ID,
    version: u64,
    taker_fee_bps: u64,
    maker_fee_bps: u64,
    fee_accumulator: FeeAccumulator<Base, Quote>,
    /// The id every event this module emits (and every `EmbeddedOrderTicket`
    /// it mints) stamps as `order_book_id`. Write-once: fixed at
    /// construction time by `new`'s `event_id_override` parameter (defaults
    /// to the book's own internal id (`id(book)`) when `option::none()` is
    /// passed) and never mutable afterward — see I-1's fix in the M14 final
    /// report for why a post-construction setter was removed. A wrapping
    /// module (e.g. `market.move`'s `OrderBook`) whose own outer object id
    /// is what external callers/indexers actually query by passes it via
    /// `option::some(book_id)` to `new` directly — see `market.move`'s
    /// `create_market`.
    event_id: ID,
}

// === EmbeddedPoolAdminCap (REQ-EMBED-003, REQ-EMBED-004) ===

public struct EmbeddedPoolAdminCap has key, store {
    id: UID,
    for_book: ID,
}

public struct EmbeddedPoolAdminCapDiscarded has copy, drop {
    cap_id: ID,
    for_book: ID,
}

/// Unconditional voluntary disposal — no liveness check of any kind,
/// mirrors `discard_pool_admin_cap`'s shape exactly (REQ-EMBED-003,
/// REQ-EMBED-004). Not required by any single REQ-EMBED-NNN item, but added
/// for completeness — `EmbeddedPoolAdminCap` has `key` (not droppable) and
/// no other destructor exists anywhere in the package.
public fun discard_embedded_pool_admin_cap(cap: EmbeddedPoolAdminCap) {
    let EmbeddedPoolAdminCap { id, for_book } = cap;
    let cap_id = object::uid_to_inner(&id);
    object::delete(id);
    event::emit(EmbeddedPoolAdminCapDiscarded { cap_id, for_book });
}

// === Constructor (REQ-EMBED-007) ===

/// No capability parameter of any kind (REQ-EMBED-007) — callable by any
/// address. No registry interaction of any kind (REQ-EMBED-016). Validation
/// mirrors `create_market`'s size-sanity checks only.
public fun new<Base, Quote>(
    lot_size: u64,
    min_size: u64,
    event_id_override: Option<ID>,
    ctx: &mut TxContext,
): (EmbeddedOrderBook<Base, Quote>, EmbeddedPoolAdminCap) {
    assert!(lot_size != 0, EZeroLotSize);
    assert!(min_size != 0, EZeroMinSize);
    assert!(min_size % lot_size == 0, EMinSizeNotMultipleOfLotSize);
    assert!(lot_size <= MAX_LOT_OR_MIN_SIZE && min_size <= MAX_LOT_OR_MIN_SIZE, ELotOrMinSizeTooLarge);

    let book_uid = object::new(ctx);
    let book_id = object::uid_to_inner(&book_uid);
    let cap = EmbeddedPoolAdminCap { id: object::new(ctx), for_book: book_id };
    let cap_id = object::id(&cap);
    // I-1 fix (blind-audit finding): `event_id` is now write-once, decided
    // here at construction and never mutable afterward — there is no
    // longer any function that can change it once a ticket/order exists,
    // which is what made the old post-construction `set_event_id` setter a
    // footgun (stale-ticket `EWrongMarket` false-abort on `cancel_order`
    // for any order already resting when it was called). A wrapping module
    // (e.g. `market.move`'s `create_market`) that needs its own outer
    // object id to be what every event/ticket stamps passes it here via
    // `option::some`, computed before this call, so it is correct from the
    // moment the core exists. `option::none()` keeps the prior default
    // (the book's own internal id).
    let event_id = if (event_id_override.is_some()) {
        event_id_override.destroy_some()
    } else {
        event_id_override.destroy_none();
        book_id
    };

    let book = EmbeddedOrderBook<Base, Quote> {
        id: book_uid,
        lot_size,
        min_size,
        bids: price_tree::new(ctx),
        asks: price_tree::new(ctx),
        proceeds: linked_table::new(ctx),
        paused: false,
        next_order_id: 0,
        pool_admin_cap_id: cap_id,
        version: pending_transfer::current_version(),
        taker_fee_bps: 0,
        maker_fee_bps: 0,
        fee_accumulator: new_fee_accumulator(),
        event_id,
    };
    (book, cap)
}

// === Package-private field accessors (mirroring market.move's identically-
// named counterparts exactly, receiver type substituted) ===

public(package) fun lot_size<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): u64 {
    book.lot_size
}

public(package) fun min_size<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): u64 {
    book.min_size
}

/// Fully private (encapsulation-leak fix, Problem 1): no external caller may
/// hold a raw `&mut PriceTree` into this book's own bid side. Still used
/// internally throughout this module.
fun bids_mut<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
): &mut PriceTree<PriceLevel<Base, Quote>> {
    &mut book.bids
}

/// Fully private — see `bids_mut` above; symmetric ask-side counterpart.
fun asks_mut<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
): &mut PriceTree<PriceLevel<Base, Quote>> {
    &mut book.asks
}

/// Fully private (encapsulation-leak fix, Problem 1). Still used internally
/// by the placement/swap functions below.
fun bids_mut_proceeds_mut_and_fees_mut<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
): (
    &mut PriceTree<PriceLevel<Base, Quote>>,
    &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    &mut FeeAccumulator<Base, Quote>,
) {
    (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator)
}

/// Fully private — see `bids_mut_proceeds_mut_and_fees_mut` above;
/// symmetric ask-side counterpart.
fun asks_mut_proceeds_mut_and_fees_mut<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
): (
    &mut PriceTree<PriceLevel<Base, Quote>>,
    &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    &mut FeeAccumulator<Base, Quote>,
) {
    (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator)
}

public(package) fun taker_fee_bps<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): u64 {
    book.taker_fee_bps
}

public(package) fun maker_fee_bps<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): u64 {
    book.maker_fee_bps
}

public(package) fun set_taker_fee_bps<Base, Quote>(book: &mut EmbeddedOrderBook<Base, Quote>, rate_bps: u64) {
    book.taker_fee_bps = rate_bps;
}

public(package) fun set_maker_fee_bps<Base, Quote>(book: &mut EmbeddedOrderBook<Base, Quote>, rate_bps: u64) {
    book.maker_fee_bps = rate_bps;
}

/// Mirrors `market::withdraw_fee_accumulator`'s exact withdraw-all-in-place
/// shape, expressed via `withdraw_fee_accumulator_in_place`
/// (`FeeAccumulator`'s fields cannot be dot-accessed outside `market.move`
/// — see Q-IMPL-015 in `docs/spec/embedded_market.md`).
public(package) fun withdraw_fee_accumulator<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    withdraw_fee_accumulator_in_place(&mut book.fee_accumulator)
}

public(package) fun is_paused<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): bool {
    book.paused
}

public(package) fun set_paused<Base, Quote>(book: &mut EmbeddedOrderBook<Base, Quote>, paused: bool) {
    book.paused = paused;
}

public(package) fun pool_admin_cap_id<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): ID {
    book.pool_admin_cap_id
}

/// The book's own object id, derived from its `id: UID` field directly
/// (`object::id`/`object::id(&book)` require `key`, which this struct
/// deliberately no longer has — see the struct's own doc comment above).
/// `public(package)` so `order.move`'s embedded call sites can obtain the
/// book id without needing `key`-based `object::id`.
public(package) fun id<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): ID {
    object::uid_to_inner(&book.id)
}

/// The id currently stamped as `order_book_id` on every event this module
/// emits and on every `EmbeddedOrderTicket` it mints — fixed at
/// construction (see `event_id`'s field doc comment above; write-once,
/// no setter exists). `public(package)` for `market.move`'s own call
/// sites, mirroring `id`'s visibility exactly.
public(package) fun event_id<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): ID {
    book.event_id
}

/// Fetch-and-increment: returns the next unique `order_id` for a newly
/// placed order — mirrors `market::next_order_id` exactly.
public(package) fun next_order_id<Base, Quote>(book: &mut EmbeddedOrderBook<Base, Quote>): u64 {
    let id = book.next_order_id;
    book.next_order_id = id + 1;
    id
}

/// Mirrors `market::claim_maker_balance`'s exact withdraw-all-and-remove-
/// if-both-zero logic (REQ-MARKET-035's fix, carried over unchanged).
/// `market::claim_maker_balance`'s own body always ends up removing the
/// entry (`Balance::withdraw_all` always leaves both legs at exactly `0`,
/// so its own `if (mb.base.value() == 0 && mb.quote.value() == 0)` check is
/// unconditionally true) — this is expressed here directly as an
/// unconditional `linked_table::remove` + `destroy_maker_balance`,
/// which is behaviorally identical without requiring `MakerBalance`'s
/// `base`/`quote` fields (private to `market.move`) to be dot-accessed from
/// this module.
public(package) fun claim_maker_balance<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    addr: address,
): (Balance<Base>, Balance<Quote>) {
    if (!linked_table::contains(&book.proceeds, addr)) {
        return (balance::zero(), balance::zero())
    };
    let mb = linked_table::remove(&mut book.proceeds, addr);
    destroy_maker_balance(mb)
}

public(package) fun bids_size<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): u64 {
    price_tree::size(&book.bids)
}

public(package) fun asks_size<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): u64 {
    price_tree::size(&book.asks)
}

public(package) fun proceeds_is_empty<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): bool {
    linked_table::is_empty(&book.proceeds)
}

/// Promoted to genuinely `public` (fake-public-API fix, Problem 2): part of
/// this module's real external API surface — an integrator wrapping this
/// book needs to be able to version-guard its own call sites the same way
/// this module's own functions do.
public fun assert_book_version<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>) {
    assert!(book.version == pending_transfer::current_version(), EStaleObjectVersion);
}

/// Promoted to genuinely `public` (fake-public-API fix, Problem 2) — see
/// `assert_book_version` above.
public fun set_book_version<Base, Quote>(book: &mut EmbeddedOrderBook<Base, Quote>, new_version: u64) {
    book.version = new_version;
}

// === Migration (REQ-EMBED-015) ===

public fun migrate_embedded_order_book_version<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: &mut EmbeddedOrderBook<Base, Quote>,
    new_version: u64,
) {
    assert_embedded_pool_admin(cap, book);
    assert!(new_version == pending_transfer::current_version(), ENewVersionMismatch);
    book.version = new_version;
}

// === New public view functions (no version-guard assertion) ===

public fun fee_config<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): (u64, u64) {
    (book.taker_fee_bps, book.maker_fee_bps)
}

public fun fee_accumulator_balances<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): (u64, u64) {
    fee_accumulator_balances_raw(&book.fee_accumulator)
}
// See Q-IMPL-016 in `docs/spec/embedded_market.md`: `market::
// fee_accumulator_balances_raw` is a small, additive, pure-read
// `public(package)` helper this view function needs (a third addition to
// `market.move`'s surface beyond Chunk 2's two constructor/disposal
// helpers) since `FeeAccumulator`'s `base`/`quote` fields cannot be
// dot-accessed from `embedded_market.move` directly.

public fun is_book_paused<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): bool {
    book.paused
}

public fun best_bid<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): Option<u64> {
    let ptr = price_tree::max_leaf(&book.bids);
    if (ptr.is_none()) {
        option::none()
    } else {
        let leaf_ptr = *ptr.borrow();
        option::some(price_tree::key(&book.bids, leaf_ptr))
    }
}

public fun best_ask<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): Option<u64> {
    let ptr = price_tree::min_leaf(&book.asks);
    if (ptr.is_none()) {
        option::none()
    } else {
        let leaf_ptr = *ptr.borrow();
        option::some(price_tree::key(&book.asks, leaf_ptr))
    }
}

/// M14 Chunk 4 (unplanned, load-bearing fix — see final report): new,
/// small, additive `public` view function — support for `market.move`'s
/// own `depth_at_price`, which can no longer reach `book.core`'s `bids`/
/// `asks` `PriceTree`s directly (REQ-ARCH-012's direct-field-reach ban).
/// Body is exactly `market.move`'s own pre-cycle `depth_at_price`, one
/// layer down. REQ-MARKET-015 (should-priority).
public fun depth_at_price<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>, side: bool, price: u64): u64 {
    let tree = if (side) &book.bids else &book.asks;
    let found = price_tree::find(tree, price);
    if (found.is_none()) {
        return 0
    };
    let leaf_ptr = found.destroy_some();
    let level = price_tree::borrow(tree, leaf_ptr);
    sum_price_level(level)
}

// === EmbeddedPoolAdminCap gate (REQ-EMBED-005/-006) ===

fun assert_embedded_pool_admin<Base, Quote>(cap: &EmbeddedPoolAdminCap, book: &EmbeddedOrderBook<Base, Quote>) {
    assert!(object::id(cap) == book.pool_admin_cap_id, EWrongPoolAdminCap);
}

// === Local pause/unpause (REQ-EMBED-006) ===

public struct Paused has copy, drop {
    order_book_id: ID,
}

public struct Unpaused has copy, drop {
    order_book_id: ID,
}

public fun pool_admin_pause_market<Base, Quote>(cap: &EmbeddedPoolAdminCap, book: &mut EmbeddedOrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    let id = book.event_id;
    book.paused = true;
    event::emit(Paused { order_book_id: id });
}

public fun pool_admin_unpause_market<Base, Quote>(cap: &EmbeddedPoolAdminCap, book: &mut EmbeddedOrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    let id = book.event_id;
    book.paused = false;
    event::emit(Unpaused { order_book_id: id });
}

// === Fee setters and claim_fees (REQ-EMBED-013) ===

public struct TakerFeeSet has copy, drop {
    order_book_id: ID,
    rate_bps: u64,
}

public struct MakerFeeSet has copy, drop {
    order_book_id: ID,
    rate_bps: u64,
}

public struct FeesClaimed has copy, drop {
    claimant: address,
    order_book_id: ID,
    base_amount: u64,
    quote_amount: u64,
}

public fun pool_admin_set_taker_fee<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: &mut EmbeddedOrderBook<Base, Quote>,
    rate_bps: u64,
) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    assert!(rate_bps <= MAX_TAKER_FEE_BPS, ETakerFeeRateTooHigh);
    let id = book.event_id;
    book.taker_fee_bps = rate_bps;
    event::emit(TakerFeeSet { order_book_id: id, rate_bps });
}

public fun pool_admin_set_maker_fee<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: &mut EmbeddedOrderBook<Base, Quote>,
    rate_bps: u64,
) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    assert!(rate_bps <= MAX_MAKER_FEE_BPS, EMakerFeeRateTooHigh);
    let id = book.event_id;
    book.maker_fee_bps = rate_bps;
    event::emit(MakerFeeSet { order_book_id: id, rate_bps });
}

public fun pool_admin_claim_fees<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: &mut EmbeddedOrderBook<Base, Quote>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    let book_id = book.event_id;
    let claimant = ctx.sender();
    // Mirrors `admin::pool_admin_claim_fees`'s exact shape (withdraw both
    // legs in place via the package-private accessor above, leaving a
    // live, zero-valued accumulator behind) — see Q-IMPL-015 in
    // `docs/spec/embedded_market.md` for why this departs from the spec's
    // original `std::mem::swap`-based code listing (that stdlib intrinsic
    // is unavailable in this project's vendored `move-stdlib`).
    let (base, quote) = withdraw_fee_accumulator(book);
    let base_amount = balance::value(&base);
    let quote_amount = balance::value(&quote);

    let base_coin = if (base_amount == 0) { balance::destroy_zero(base); coin::zero(ctx) }
        else { coin::from_balance(base, ctx) };
    let quote_coin = if (quote_amount == 0) { balance::destroy_zero(quote); coin::zero(ctx) }
        else { coin::from_balance(quote, ctx) };

    if (base_amount != 0 || quote_amount != 0) {
        event::emit(FeesClaimed { claimant, order_book_id: book_id, base_amount, quote_amount });
    };
    (base_coin, quote_coin)
}

// === Force-cancel (REQ-EMBED-014) ===

public struct OrderCancelled has copy, drop {
    order_id: u64,
    order_book_id: ID,
    trader: address,
}

public fun pool_admin_cancel_order<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: &mut EmbeddedOrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order_id: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    let book_id = book.event_id;
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let leaf_opt = price_tree::find(tree, price);
    if (leaf_opt.is_none()) { return };
    let leaf_ptr = leaf_opt.destroy_some();

    let (found, owner, escrow_base, escrow_quote, level_now_empty) = {
        let level = price_tree::borrow_mut(tree, leaf_ptr);
        let orders = price_level_orders_mut(level);
        if (orders.contains(order_id)) {
            let live_order = orders.remove(order_id);
            let owner = order_owner(&live_order);
            let (eb, eq) = destroy_order(live_order);
            (true, owner, eb, eq, orders.is_empty())
        } else {
            (false, @0x0, option::none(), option::none(), orders.is_empty())
        }
    };
    if (!found) { escrow_base.destroy_none(); escrow_quote.destroy_none(); return };
    if (level_now_empty) {
        let removed = price_tree::remove(tree, leaf_ptr);
        destroy_empty_price_level(removed);
    };
    refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
    event::emit(OrderCancelled { order_id, order_book_id: book_id, trader: owner });
}

// === Deletion lifecycle: retire/drain_step/finalize (REQ-EMBED-008) ===

public struct MarketRetired has copy, drop {
    order_book_id: ID,
}

/// M14 Chunk 2 (REQ-ARCH-009): widened from `{ order_book_id: ID }` to
/// carry `base`/`quote` too — the canonical, post-consolidation shape.
/// See `docs/spec/architecture.md` §Event ownership table, `MarketDeleted`.
public struct MarketDeleted has copy, drop {
    order_book_id: ID,
    base: TypeName,
    quote: TypeName,
}

public fun retire<Base, Quote>(cap: &EmbeddedPoolAdminCap, book: &mut EmbeddedOrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    let id = book.event_id;
    book.paused = true;
    event::emit(MarketRetired { order_book_id: id });
}

public fun drain_step<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: &mut EmbeddedOrderBook<Base, Quote>,
    max_items: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    assert!(book.paused, ENotRetiring);
    let mut remaining = max_items;
    drain_side(&mut book.bids, &mut remaining, /* want_max */ true, ctx);
    drain_side(&mut book.asks, &mut remaining, /* want_max */ false, ctx);
    drain_proceeds(&mut book.proceeds, &mut remaining, ctx);
}

/// Deliberately duplicated (not shared) from `admin.move`'s identically-
/// named private `fun` — Move gives no mechanism to call another module's
/// private functions. Identical body.
fun drain_side<Base, Quote>(
    tree: &mut PriceTree<PriceLevel<Base, Quote>>,
    remaining: &mut u64,
    want_max: bool,
    ctx: &mut TxContext,
) {
    while (*remaining > 0) {
        let best_opt = if (want_max) price_tree::max_leaf(tree) else price_tree::min_leaf(tree);
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let mut is_empty_now;
        {
            let level = price_tree::borrow_mut(tree, leaf_ptr);
            let orders = price_level_orders_mut(level);
            loop {
                if (*remaining == 0) break;
                if (orders.is_empty()) break;
                let (_, order) = orders.pop_front();
                let owner = order_owner(&order);
                let (escrow_base, escrow_quote) = destroy_order(order);
                refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
                *remaining = *remaining - 1;
            };
            is_empty_now = price_level_is_empty(level);
        };
        if (is_empty_now) {
            let removed = price_tree::remove(tree, leaf_ptr);
            destroy_empty_price_level(removed);
        };
    };
}

/// Deliberately duplicated (not shared) from `admin.move`'s identically-
/// named private `fun`, including its REQ-ADMIN-038 zero-value guard.
fun refund_order_escrow<Base, Quote>(
    owner: address,
    mut escrow_base: Option<Balance<Base>>,
    mut escrow_quote: Option<Balance<Quote>>,
    ctx: &mut TxContext,
) {
    if (escrow_base.is_some()) {
        let base = escrow_base.extract();
        if (balance::value(&base) == 0) {
            balance::destroy_zero(base);
        } else {
            transfer::public_transfer(coin::from_balance(base, ctx), owner);
        };
    };
    escrow_base.destroy_none();
    if (escrow_quote.is_some()) {
        let quote = escrow_quote.extract();
        if (balance::value(&quote) == 0) {
            balance::destroy_zero(quote);
        } else {
            transfer::public_transfer(coin::from_balance(quote, ctx), owner);
        };
    };
    escrow_quote.destroy_none();
}

/// Deliberately duplicated (not shared) from `admin.move`'s identically-
/// named private `fun`, including its REQ-ADMIN-021 zero-value guard.
fun drain_proceeds<Base, Quote>(
    proceeds: &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    remaining: &mut u64,
    ctx: &mut TxContext,
) {
    while (*remaining > 0 && !linked_table::is_empty(proceeds)) {
        let (addr, mb) = linked_table::pop_front(proceeds);
        let (base, quote) = destroy_maker_balance(mb);
        let base_amount = balance::value(&base);
        let quote_amount = balance::value(&quote);
        if (base_amount == 0) {
            balance::destroy_zero(base);
        } else {
            transfer::public_transfer(coin::from_balance(base, ctx), addr);
        };
        if (quote_amount == 0) {
            balance::destroy_zero(quote);
        } else {
            transfer::public_transfer(coin::from_balance(quote, ctx), addr);
        };
        *remaining = *remaining - 1;
    };
}

public fun finalize<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: EmbeddedOrderBook<Base, Quote>,
): ID {
    assert_book_version(&book);
    assert_embedded_pool_admin(cap, &book);
    assert!(book.paused, ENotRetiring);
    assert!(
        price_tree::size(&book.bids) == 0 && price_tree::size(&book.asks) == 0 && book.proceeds.is_empty(),
        ENotFullyDrained,
    );

    let EmbeddedOrderBook {
        id, lot_size: _, min_size: _, bids, asks, proceeds,
        paused: _, next_order_id: _, pool_admin_cap_id: _, version: _,
        taker_fee_bps: _, maker_fee_bps: _, fee_accumulator, event_id,
    } = book;
    let book_id = event_id;
    price_tree::destroy_empty(bids);
    price_tree::destroy_empty(asks);
    linked_table::destroy_empty(proceeds);
    let (base, quote) = withdraw_fee_accumulator_raw(fee_accumulator);
    balance::destroy_zero(base);
    balance::destroy_zero(quote);
    object::delete(id);

    event::emit(MarketDeleted {
        order_book_id: book_id,
        base: type_name::with_defining_ids<Base>(),
        quote: type_name::with_defining_ids<Quote>(),
    });
    book_id
}

// === M14 Chunk 1: matching engine, supporting math, EmbeddedOrderTicket
// (REQ-ARCH-004, REQ-ARCH-005, REQ-ARCH-011, REQ-ARCH-013, REQ-ARCH-014) ===
//
// Fully additive relocation from `sources/order.move` — every function body
// below is byte-for-byte identical to its `order.move` original (only
// cross-module-qualifying prefixes that referred to this same module, e.g.
// `embedded_market::bids_mut`, are dropped to their bare, module-local form
// now that the code lives inside this module itself — a purely mechanical
// consequence of the relocation, not a logic change). `order.move`'s own
// copies of all of these remain completely untouched and continue to serve
// every pre-existing test unchanged.
//
// **Flagged deviation from the plan's own chunk boundary**: `fill_level_
// bid`/`fill_level_ask` below each emit an `OrderFilled` event as part of
// their unchanged bodies (`sources/order.move:345-352,528-535`). The plan's
// own Chunk-by-chunk migration mapping assigns `OrderFilled` (along with
// `OrderPlaced`/`OrderCancelled`/`ProceedsClaimed`) to Chunk 2 ("now-
// canonical events"). Since Move requires a struct to be defined before any
// function in the same module can construct a value of it, `fill_level_
// bid`/`fill_level_ask` cannot compile in this module without `OrderFilled`
// already existing here — this is an unavoidable compile-order consequence
// of the plan's own instruction to copy these two functions' bodies
// unchanged in Chunk 1. Resolution adopted here: add only the `OrderFilled`
// struct itself now (not `OrderPlaced`/`OrderCancelled`/`ProceedsClaimed`,
// which no Chunk 1 function needs), field-shape-identical to `order.move`'s
// own `OrderFilled` (`sources/order.move:92-99`) and to what Chunk 2 would
// otherwise add — so Chunk 2's own task list needs no change beyond
// skipping the now-redundant re-declaration.

public struct OrderFilled has copy, drop {
    maker_order_id: u64,
    order_book_id: ID,
    price: u64,
    quantity: u64,
    maker: address,
    taker: address,
}

// --- Escrow amount computation (mirrors order.move:125-136) ---

/// `price * size`, u128-widened and abort-checked before narrowing back to
/// `u64` — never wraps. `size` is always `Base`-atomic-units; a bid's
/// escrow is this amount of `Quote`.
public fun bid_escrow_amount(price: u64, size: u64): u64 {
    checked_mul_u64(price, size)
}

fun checked_mul_u64(a: u64, b: u64): u64 {
    let product = (a as u128) * (b as u128);
    assert!(product <= U64_MAX, EEscrowOverflow);
    product as u64
}

// --- Fee-amount computation helper (mirrors order.move:138-149) ---

/// `receive_amount * rate_bps / 10_000`, `u128`-widened before multiplying.
/// No explicit overflow-abort check is needed here: `rate_bps` is
/// bounds-checked to at most `MAX_TAKER_FEE_BPS`/`MAX_MAKER_FEE_BPS` before
/// it can ever reach this function, so the maximum possible product is far
/// below `u128::MAX`. Floor division (Move's native `/`).
fun fee_amount(receive_amount: u64, rate_bps: u64): u64 {
    (((receive_amount as u128) * (rate_bps as u128)) / 10_000) as u64
}

// --- Validation helpers (mirrors order.move's validate_size_embedded,
// collapsed to a single, already-EmbeddedOrderBook-typed pair) ---

fun validate_size_raw(lot_size: u64, min_size: u64, size: u64) {
    assert!(size % lot_size == 0, ESizeNotMultipleOfLotSize);
    assert!(size >= min_size, ESizeBelowMinSize);
}

fun validate_size<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>, size: u64) {
    validate_size_raw(lot_size(book), min_size(book), size);
}

// --- Resting-order escrow destruction helpers (mirrors order.move:171-192) ---
//
// Once a maker's `Order` is fully consumed by matching, its escrow
// `Option`s hold either a spent (zero-value) `Balance` or `None`,
// side-exhaustively. These consume both halves of `destroy_order`'s
// return value so no `Option`/`Balance` is ever silently dropped.

fun destroy_drained_ask_escrow<Base, Quote>(
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
) {
    balance::destroy_zero(escrow_base.destroy_some());
    escrow_quote.destroy_none();
}

fun destroy_drained_bid_escrow<Base, Quote>(
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
) {
    escrow_base.destroy_none();
    balance::destroy_zero(escrow_quote.destroy_some());
}

// --- Resting-order insertion (mirrors order.move's insert_resting_order_
// embedded, collapsed to a single, already-EmbeddedOrderBook-typed fn) ---

fun insert_resting_order<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order: Order<Base, Quote>,
    ctx: &mut TxContext,
) {
    let order_id = order_id(&order);
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) bids_mut(book) else asks_mut(book);
    let existing = price_tree::find(tree, price);
    if (existing.is_some()) {
        let leaf_ptr = existing.destroy_some();
        let level = price_tree::borrow_mut(tree, leaf_ptr);
        price_level_orders_mut(level).push_back(order_id, order);
    } else {
        existing.destroy_none();
        let mut level = new_price_level<Base, Quote>(ctx);
        price_level_orders_mut(&mut level).push_back(order_id, order);
        price_tree::insert(tree, price, level);
    };
}

// --- Matching algorithm (mirrors order.move:246-619 unchanged) ---

fun fill_level_bid<Base, Quote>(
    asks: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    budget: &mut Balance<Quote>,
    matched_base: &mut Balance<Base>,
    taker: address,
    book_id: ID,
    fills_consumed: &mut u64,
    max_fills: u64,
    taker_fee_bps: u64,
): (bool, bool) {
    let mut budget_exhausted = false;
    let mut hit_max_fills = false;
    let is_empty_now;
    {
        let level = price_tree::borrow_mut(asks, leaf_ptr);
        loop {
            if (*remaining_size == 0) break;
            if (*fills_consumed == max_fills) {
                budget_exhausted = true;
                hit_max_fills = true;
                break
            };
            let orders: &mut LinkedTable<u64, Order<Base, Quote>> =
                price_level_orders_mut(level);
            if (orders.is_empty()) break;
            let head_key = *orders.front().borrow();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = order_remaining_quantity(orders.borrow(head_key));
            let natural_fill_qty = std::u64::min(*remaining_size, maker_remaining);
            let affordable_qty = balance::value(budget) / best_price;
            let fill_qty = std::u64::min(natural_fill_qty, affordable_qty);
            if (fill_qty == 0) {
                budget_exhausted = true;
                break
            };
            let quote_cost = checked_mul_u64(best_price, fill_qty);

            let maker_order_mut = orders.borrow_mut(head_key);
            order_decrease_remaining(maker_order_mut, fill_qty);
            let mut base_out = order_split_escrow_base(maker_order_mut, fill_qty);
            let maker_fee_bps = order_maker_fee_bps(maker_order_mut);
            let maker_addr = order_owner(maker_order_mut);
            let maker_order_id = order_id(maker_order_mut);
            let maker_remaining_after = order_remaining_quantity(maker_order_mut);

            let taker_fee_base = fee_amount(fill_qty, taker_fee_bps);
            let taker_fee_balance = balance::split(&mut base_out, taker_fee_base);
            matched_base.join(base_out); // remainder, net of taker fee

            let mut quote_payment = balance::split(budget, quote_cost);
            let maker_fee_quote = fee_amount(quote_cost, maker_fee_bps);
            let maker_fee_balance = balance::split(&mut quote_payment, maker_fee_quote);
            credit_fee_accumulator(fees, taker_fee_balance, maker_fee_balance);
            credit_maker_table(proceeds, maker_addr, balance::zero<Base>(), quote_payment);

            event::emit(OrderFilled {
                maker_order_id,
                order_book_id: book_id,
                price: best_price,
                quantity: fill_qty,
                maker: maker_addr,
                taker,
            });

            *remaining_size = *remaining_size - fill_qty;

            if (maker_remaining_after == 0) {
                let (_, drained) = orders.pop_front();
                let (eb, eq) = destroy_order(drained);
                destroy_drained_ask_escrow(eb, eq);
            };

            if (fill_qty < natural_fill_qty) {
                budget_exhausted = true;
                break
            };
        };
        is_empty_now = price_level_is_empty(level);
    };
    if (is_empty_now) {
        let removed = price_tree::remove(asks, leaf_ptr);
        destroy_empty_price_level(removed);
    };
    (budget_exhausted, hit_max_fills)
}

fun match_bid<Base, Quote>(
    asks: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    taker_fee_bps: u64,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    budget_in: Balance<Quote>,
    taker: address,
    book_id: ID,
    max_fills: u64,
): (Balance<Base>, Balance<Quote>, u64, bool) {
    let mut remaining_size = remaining_size_in;
    let mut budget = budget_in;
    let mut matched_base = balance::zero<Base>();
    let mut fills_consumed: u64 = 0;
    let mut stopped_on_max_fills_while_crossing = false;

    loop {
        if (remaining_size == 0) break;
        let best_opt = price_tree::min_leaf(asks);
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let best_price = price_tree::key(asks, leaf_ptr);
        if (limit_price.is_some() && best_price > *limit_price.borrow()) break;

        if (fills_consumed == max_fills) {
            stopped_on_max_fills_while_crossing = true;
            break
        };

        let (stop, hit_max_fills) = fill_level_bid(
            asks,
            proceeds,
            fees,
            leaf_ptr,
            best_price,
            &mut remaining_size,
            &mut budget,
            &mut matched_base,
            taker,
            book_id,
            &mut fills_consumed,
            max_fills,
            taker_fee_bps,
        );
        if (hit_max_fills) stopped_on_max_fills_while_crossing = true;
        if (stop) break;
    };

    (matched_base, budget, remaining_size, stopped_on_max_fills_while_crossing)
}

fun fill_level_ask<Base, Quote>(
    bids: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    own_wallet: &mut Balance<Base>,
    matched_quote: &mut Balance<Quote>,
    taker: address,
    book_id: ID,
    fills_consumed: &mut u64,
    max_fills: u64,
    taker_fee_bps: u64,
): (bool, bool) {
    let mut stop = false;
    let mut hit_max_fills = false;
    let is_empty_now;
    {
        let level = price_tree::borrow_mut(bids, leaf_ptr);
        loop {
            if (*remaining_size == 0) break;
            if (*fills_consumed == max_fills) {
                stop = true;
                hit_max_fills = true;
                break
            };
            let orders: &mut LinkedTable<u64, Order<Base, Quote>> =
                price_level_orders_mut(level);
            if (orders.is_empty()) break;
            let head_key = *orders.front().borrow();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = order_remaining_quantity(orders.borrow(head_key));
            let fill_qty = std::u64::min(*remaining_size, maker_remaining);
            let quote_amt = checked_mul_u64(best_price, fill_qty);

            let maker_order_mut = orders.borrow_mut(head_key);
            order_decrease_remaining(maker_order_mut, fill_qty);
            let mut quote_out = order_split_escrow_quote(maker_order_mut, quote_amt);
            let maker_fee_bps = order_maker_fee_bps(maker_order_mut);
            let maker_addr = order_owner(maker_order_mut);
            let maker_order_id = order_id(maker_order_mut);
            let maker_remaining_after = order_remaining_quantity(maker_order_mut);

            let taker_fee_quote = fee_amount(quote_amt, taker_fee_bps);
            let taker_fee_balance = balance::split(&mut quote_out, taker_fee_quote);
            matched_quote.join(quote_out); // remainder, net of taker fee

            let mut base_payment = balance::split(own_wallet, fill_qty);
            let maker_fee_base = fee_amount(fill_qty, maker_fee_bps);
            let maker_fee_balance = balance::split(&mut base_payment, maker_fee_base);
            credit_fee_accumulator(fees, maker_fee_balance, taker_fee_balance);
            credit_maker_table(proceeds, maker_addr, base_payment, balance::zero<Quote>());

            event::emit(OrderFilled {
                maker_order_id,
                order_book_id: book_id,
                price: best_price,
                quantity: fill_qty,
                maker: maker_addr,
                taker,
            });

            *remaining_size = *remaining_size - fill_qty;

            if (maker_remaining_after == 0) {
                let (_, drained) = orders.pop_front();
                let (eb, eq) = destroy_order(drained);
                destroy_drained_bid_escrow(eb, eq);
            };
        };
        is_empty_now = price_level_is_empty(level);
    };
    if (is_empty_now) {
        let removed = price_tree::remove(bids, leaf_ptr);
        destroy_empty_price_level(removed);
    };
    (stop, hit_max_fills)
}

fun match_ask<Base, Quote>(
    bids: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<address, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    taker_fee_bps: u64,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    own_wallet_in: Balance<Base>,
    taker: address,
    book_id: ID,
    max_fills: u64,
): (Balance<Quote>, Balance<Base>, u64, bool) {
    let mut remaining_size = remaining_size_in;
    let mut own_wallet = own_wallet_in;
    let mut matched_quote = balance::zero<Quote>();
    let mut fills_consumed: u64 = 0;
    let mut stopped_on_max_fills_while_crossing = false;

    loop {
        if (remaining_size == 0) break;
        let best_opt = price_tree::max_leaf(bids);
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let best_price = price_tree::key(bids, leaf_ptr);
        if (limit_price.is_some() && best_price < *limit_price.borrow()) break;

        if (fills_consumed == max_fills) {
            stopped_on_max_fills_while_crossing = true;
            break
        };

        let (stop, hit_max_fills) = fill_level_ask(
            bids,
            proceeds,
            fees,
            leaf_ptr,
            best_price,
            &mut remaining_size,
            &mut own_wallet,
            &mut matched_quote,
            taker,
            book_id,
            &mut fills_consumed,
            max_fills,
            taker_fee_bps,
        );
        if (hit_max_fills) stopped_on_max_fills_while_crossing = true;
        if (stop) break;
    };

    (matched_quote, own_wallet, remaining_size, stopped_on_max_fills_while_crossing)
}

// === EmbeddedOrderTicket (REQ-ARCH-005, REQ-ARCH-011, REQ-ARCH-013,
// REQ-ARCH-014) — new type ===
//
// `store` only, deliberately no `key` (REQ-ARCH-013): a plain, immutable,
// non-object value — never independently shareable via
// `transfer::share_object`. Field list/order mirrors `order.move`'s own
// `OrderTicket` minus its `id: UID` field. See `docs/spec/architecture.md`
// §`EmbeddedOrderTicket` — new type for the full rationale.
public struct EmbeddedOrderTicket has store {
    order_id: u64,
    order_book_id: ID,
    side: bool,
    price: u64,
}

/// Read-only accessor (REQ-ARCH-007/-011 support) — see `docs/spec/
/// architecture.md` §`EmbeddedOrderTicket` accessors. Promoted to genuinely
/// `public` (fake-public-API fix, Problem 2): a pure read accessor on a
/// value type an external integrator already holds — no encapsulation
/// concern in exposing it beyond this now-standalone package.
public fun embedded_ticket_order_id(t: &EmbeddedOrderTicket): u64 {
    t.order_id
}

/// Promoted to genuinely `public` (fake-public-API fix, Problem 2) — see
/// `embedded_ticket_order_id` above.
public fun embedded_ticket_order_book_id(t: &EmbeddedOrderTicket): ID {
    t.order_book_id
}

/// Promoted to genuinely `public` (fake-public-API fix, Problem 2) — see
/// `embedded_ticket_order_id` above.
public fun embedded_ticket_side(t: &EmbeddedOrderTicket): bool {
    t.side
}

/// Promoted to genuinely `public` (fake-public-API fix, Problem 2) — see
/// `embedded_ticket_order_id` above.
public fun embedded_ticket_price(t: &EmbeddedOrderTicket): u64 {
    t.price
}

/// Unconditional disposal, no liveness check of its own (REQ-ARCH-011) —
/// mirrors `discard_embedded_pool_admin_cap`'s shape. `market.move`'s own
/// `destroy_orphaned_ticket` calls this only after its own liveness check
/// has already passed. See `docs/spec/embedded_market.md` §`EmbeddedOrderTicket`
/// disposal. Promoted to genuinely `public` (fake-public-API fix, Problem 2):
/// a self-contained mutation (destruction) of a value the caller already
/// owns outright — no encapsulation concern.
public fun destroy_orphaned_embedded_ticket(ticket: EmbeddedOrderTicket) {
    let EmbeddedOrderTicket { order_id: _, order_book_id: _, side: _, price: _ } = ticket;
}

// === M14 Chunk 2: canonical (un-suffixed) placement/cancel/claim functions,
// remaining now-canonical events, pool_admin_push_proceeds (REQ-ARCH-003,
// REQ-ARCH-008, REQ-ARCH-009, REQ-ARCH-012) ===
//
// Bodies are byte-for-byte unchanged from `order.move`'s own `_embedded`-
// suffixed originals (`sources/order.move:1006-1358`) except: the suffix is
// dropped, cross-module `embedded_market::`-prefixed calls become bare
// (module-local) calls, and every ticket construction/destructure now uses
// `EmbeddedOrderTicket` (no `id`/`object::new(ctx)`/`id.delete()` step,
// since `EmbeddedOrderTicket` has no `UID`) in place of the shared-book
// `OrderTicket`. `order.move`'s own `_embedded`-suffixed originals remain
// completely untouched and continue to serve every pre-existing test.

public struct OrderPlaced has copy, drop {
    order_id: u64,
    order_book_id: ID,
    side: bool,
    price: u64,
    size: u64,
    trader: address,
}

public struct ProceedsClaimed has copy, drop {
    claimant: address,
    order_book_id: ID,
    base_amount: u64,
    quote_amount: u64,
}

public fun place_limit_order_bid<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    price: u64,
    size: u64,
    mut payment: Coin<Quote>,
    max_fills: u64,
    ctx: &mut TxContext,
): (EmbeddedOrderTicket, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EMarketPaused);
    assert!(price != 0, EZeroPrice);
    validate_size(book, size);

    let escrow_amount = bid_escrow_amount(price, size);
    let mut escrow = coin::into_balance(coin::split(&mut payment, escrow_amount, ctx));

    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = asks_mut_proceeds_mut_and_fees_mut(book);
    let (matched_base, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, option::some(price), size, escrow, taker, book_id, max_fills);
    escrow = remaining_escrow;

    let order_id = next_order_id(book);
    let should_rest = remaining_size > 0 && !stopped_on_max_fills_while_crossing;
    if (should_rest) {
        let resting_escrow_amount = bid_escrow_amount(price, remaining_size);
        let resting_escrow = balance::split(&mut escrow, resting_escrow_amount);
        coin::join(&mut payment, coin::from_balance(escrow, ctx));
        // REQ-FEE-007: snapshot the book's *current* maker-fee rate at the
        // exact moment this resting order is constructed.
        let maker_fee_bps_snapshot = maker_fee_bps(book);
        let resting = new_order(
            order_id,
            taker,
            remaining_size,
            option::none(),
            option::some(resting_escrow),
            maker_fee_bps_snapshot,
        );
        insert_resting_order(book, true, price, resting, ctx);
        event::emit(OrderPlaced {
            order_id,
            order_book_id: book_id,
            side: true,
            price,
            size: remaining_size,
            trader: taker,
        });
    } else {
        coin::join(&mut payment, coin::from_balance(escrow, ctx));
    };

    let ticket = EmbeddedOrderTicket {
        order_id,
        order_book_id: book_id,
        side: true,
        price,
    };
    (ticket, coin::from_balance(matched_base, ctx), payment, stopped_on_max_fills_while_crossing)
}

public fun place_limit_order_ask<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    price: u64,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    ctx: &mut TxContext,
): (EmbeddedOrderTicket, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EMarketPaused);
    assert!(price != 0, EZeroPrice);
    validate_size(book, size);

    let own_wallet = coin::into_balance(coin::split(&mut payment, size, ctx));

    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = bids_mut_proceeds_mut_and_fees_mut(book);
    let (matched_quote, remaining_wallet, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, option::some(price), size, own_wallet, taker, book_id, max_fills);

    let order_id = next_order_id(book);
    let should_rest = remaining_size > 0 && !stopped_on_max_fills_while_crossing;
    if (should_rest) {
        // REQ-FEE-007: snapshot the book's *current* maker-fee rate at the
        // exact moment this resting order is constructed.
        let maker_fee_bps_snapshot = maker_fee_bps(book);
        let resting = new_order(
            order_id,
            taker,
            remaining_size,
            option::some(remaining_wallet),
            option::none(),
            maker_fee_bps_snapshot,
        );
        insert_resting_order(book, false, price, resting, ctx);
        event::emit(OrderPlaced {
            order_id,
            order_book_id: book_id,
            side: false,
            price,
            size: remaining_size,
            trader: taker,
        });
    } else {
        coin::join(&mut payment, coin::from_balance(remaining_wallet, ctx));
    };

    let ticket = EmbeddedOrderTicket {
        order_id,
        order_book_id: book_id,
        side: false,
        price,
    };
    (ticket, payment, coin::from_balance(matched_quote, ctx), stopped_on_max_fills_while_crossing)
}

public fun place_market_order_bid<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    size: u64,
    budget: u64,
    mut payment: Coin<Quote>,
    max_fills: u64,
    max_quote_in: Option<u64>,
    min_base_out: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, Coin<Quote>) {
    assert_book_version(book);
    assert!(!is_paused(book), EMarketPaused);
    validate_size(book, size);

    let budget_balance = coin::into_balance(coin::split(&mut payment, budget, ctx));
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = asks_mut_proceeds_mut_and_fees_mut(book);
    let (matched_base, remaining_budget, _remaining_size, _stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, option::none(), size, budget_balance, taker, book_id, max_fills);

    if (max_quote_in.is_some()) {
        let quote_spent = budget - balance::value(&remaining_budget);
        assert!(quote_spent <= *max_quote_in.borrow(), ESlippageExceeded);
    };
    if (min_base_out.is_some()) {
        assert!(balance::value(&matched_base) >= *min_base_out.borrow(), ESlippageExceeded);
    };

    (coin::from_balance(matched_base, ctx), coin::from_balance(remaining_budget, ctx), payment)
}

public fun place_market_order_ask<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    min_quote_out: Option<u64>,
    max_base_in: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    assert!(!is_paused(book), EMarketPaused);
    validate_size(book, size);

    let own_wallet = coin::into_balance(coin::split(&mut payment, size, ctx));
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = bids_mut_proceeds_mut_and_fees_mut(book);
    let (matched_quote, remaining_wallet, _remaining_size, _stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, option::none(), size, own_wallet, taker, book_id, max_fills);

    if (max_base_in.is_some()) {
        let base_spent = size - balance::value(&remaining_wallet);
        assert!(base_spent <= *max_base_in.borrow(), ESlippageExceeded);
    };
    if (min_quote_out.is_some()) {
        assert!(balance::value(&matched_quote) >= *min_quote_out.borrow(), ESlippageExceeded);
    };

    coin::join(&mut payment, coin::from_balance(remaining_wallet, ctx));
    (payment, coin::from_balance(matched_quote, ctx))
}

public fun swap_bid<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    size: u64,
    budget: u64,
    mut payment: Coin<Quote>,
    max_fills: u64,
    limit_price: Option<u64>,
    max_quote_in: Option<u64>,
    min_base_out: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EMarketPaused);
    validate_size(book, size);

    let budget_balance = coin::into_balance(coin::split(&mut payment, budget, ctx));
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = asks_mut_proceeds_mut_and_fees_mut(book);
    let (matched_base, remaining_budget, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, limit_price, size, budget_balance, taker, book_id, max_fills);

    if (max_quote_in.is_some()) {
        let quote_spent = budget - balance::value(&remaining_budget);
        assert!(quote_spent <= *max_quote_in.borrow(), ESlippageExceeded);
    };
    if (min_base_out.is_some()) {
        assert!(balance::value(&matched_base) >= *min_base_out.borrow(), ESlippageExceeded);
    };

    (
        coin::from_balance(matched_base, ctx),
        coin::from_balance(remaining_budget, ctx),
        payment,
        stopped_on_max_fills_while_crossing,
    )
}

public fun swap_ask<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    limit_price: Option<u64>,
    min_quote_out: Option<u64>,
    max_base_in: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EMarketPaused);
    validate_size(book, size);

    let own_wallet = coin::into_balance(coin::split(&mut payment, size, ctx));
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = bids_mut_proceeds_mut_and_fees_mut(book);
    let (matched_quote, remaining_wallet, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, limit_price, size, own_wallet, taker, book_id, max_fills);

    if (max_base_in.is_some()) {
        let base_spent = size - balance::value(&remaining_wallet);
        assert!(base_spent <= *max_base_in.borrow(), ESlippageExceeded);
    };
    if (min_quote_out.is_some()) {
        assert!(balance::value(&matched_quote) >= *min_quote_out.borrow(), ESlippageExceeded);
    };

    coin::join(&mut payment, coin::from_balance(remaining_wallet, ctx));
    (payment, coin::from_balance(matched_quote, ctx), stopped_on_max_fills_while_crossing)
}

/// Neither `cancel_order` nor `claim_proceeds` checks `is_paused(book)` at
/// all (mirrors `order.move`'s own `cancel_order_embedded`/`claim_proceeds_
/// embedded` — soft pause and the deletion lifecycle's retiring state never
/// block cancel/claim, since both are the same merged field here).
public fun cancel_order<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    ticket: EmbeddedOrderTicket,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    let book_id = book.event_id;
    assert!(ticket.order_book_id == book_id, EWrongMarket);
    let EmbeddedOrderTicket { order_id, order_book_id: _, side, price } = ticket;

    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) bids_mut(book) else asks_mut(book);
    let leaf_opt = price_tree::find(tree, price);

    if (leaf_opt.is_none()) {
        return (coin::zero(ctx), coin::zero(ctx))
    };
    let leaf_ptr = leaf_opt.destroy_some();

    let (found_live, trader, escrow_base, escrow_quote, level_now_empty) = {
        let level = price_tree::borrow_mut(tree, leaf_ptr);
        let orders = price_level_orders_mut(level);
        if (orders.contains(order_id)) {
            let live_order = orders.remove(order_id);
            let owner = order_owner(&live_order);
            let (eb, eq) = destroy_order(live_order);
            (true, owner, eb, eq, orders.is_empty())
        } else {
            (false, @0x0, option::none(), option::none(), orders.is_empty())
        }
    };

    if (found_live && level_now_empty) {
        let removed = price_tree::remove(tree, leaf_ptr);
        destroy_empty_price_level(removed);
    };

    if (found_live) {
        event::emit(OrderCancelled { order_id, order_book_id: book_id, trader });
    };

    let base_coin = if (escrow_base.is_some()) {
        coin::from_balance(escrow_base.destroy_some(), ctx)
    } else {
        escrow_base.destroy_none();
        coin::zero(ctx)
    };
    let quote_coin = if (escrow_quote.is_some()) {
        coin::from_balance(escrow_quote.destroy_some(), ctx)
    } else {
        escrow_quote.destroy_none();
        coin::zero(ctx)
    };
    (base_coin, quote_coin)
}

/// Narrow, safe replacement (encapsulation-leak fix, Problem 1) for the one
/// external use case that used to require handing out a raw `&mut
/// PriceTree`/`&mut LinkedTable` (order.move's `redeem_transfer_ticket`,
/// which lives in the separate wrapper package and is out of this task's
/// scope): finds the resting order at `(side, price, order_id)` — mirroring
/// `cancel_order`'s own side/price/order_id lookup shape immediately above —
/// and overwrites its `owner` field in place via the (now-private)
/// `order_set_owner`. Returns `true` if an order was found and updated,
/// `false` if the price level or the order itself doesn't exist (a
/// no-op, mirroring `cancel_order`'s own not-found-is-a-no-op handling).
///
/// Deliberately does NOT call `assert_book_version` internally: the call
/// site this replaces already performs its own version check before calling
/// in, and that call site is being architecturally simplified elsewhere
/// (out of this task's scope) — so this function stays a pure lookup+mutate
/// primitive. Flagged for a human to double-check separately whether the
/// simplified call site still version-checks correctly.
public fun update_resting_order_owner<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order_id: u64,
    new_owner: address,
): bool {
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) bids_mut(book) else asks_mut(book);
    let leaf_opt = price_tree::find(tree, price);
    if (leaf_opt.is_none()) {
        return false
    };
    let leaf_ptr = leaf_opt.destroy_some();
    let level = price_tree::borrow_mut(tree, leaf_ptr);
    let orders = price_level_orders_mut(level);
    if (!orders.contains(order_id)) {
        return false
    };
    let order = orders.borrow_mut(order_id);
    order_set_owner(order, new_owner);
    true
}

#[allow(lint(self_transfer))]
public fun claim_proceeds<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    let claimant = ctx.sender();
    let book_id = book.event_id;
    let (base, quote) = claim_maker_balance(book, claimant);
    let base_amount = balance::value(&base);
    let quote_amount = balance::value(&quote);

    if (base_amount == 0 && quote_amount == 0) {
        balance::destroy_zero(base);
        balance::destroy_zero(quote);
        return
    };

    if (base_amount == 0) {
        balance::destroy_zero(base);
    } else {
        transfer::public_transfer(coin::from_balance(base, ctx), claimant);
    };
    if (quote_amount == 0) {
        balance::destroy_zero(quote);
    } else {
        transfer::public_transfer(coin::from_balance(quote, ctx), claimant);
    };
    event::emit(ProceedsClaimed { claimant, order_book_id: book_id, base_amount, quote_amount });
}

/// New this cycle (REQ-ARCH-012) — no core-level equivalent of "force-push a
/// specific maker's accumulated proceeds to them" existed before. Mirrors
/// `claim_proceeds`'s exact zero-value-guard shape, `EmbeddedPoolAdminCap`-
/// gated instead of ungated, taking an explicit `addr` instead of
/// `ctx.sender()`, reusing this module's own `ProceedsClaimed` (no new event
/// struct — the event's meaning is identical regardless of who triggered the
/// withdrawal).
public fun pool_admin_push_proceeds<Base, Quote>(
    cap: &EmbeddedPoolAdminCap,
    book: &mut EmbeddedOrderBook<Base, Quote>,
    addr: address,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_embedded_pool_admin(cap, book);
    let book_id = book.event_id;
    let (base, quote) = claim_maker_balance(book, addr);
    let base_amount = balance::value(&base);
    let quote_amount = balance::value(&quote);
    if (base_amount == 0 && quote_amount == 0) {
        balance::destroy_zero(base);
        balance::destroy_zero(quote);
        return
    };
    if (base_amount == 0) { balance::destroy_zero(base) }
    else { transfer::public_transfer(coin::from_balance(base, ctx), addr) };
    if (quote_amount == 0) { balance::destroy_zero(quote) }
    else { transfer::public_transfer(coin::from_balance(quote, ctx), addr) };
    event::emit(ProceedsClaimed { claimant: addr, order_book_id: book_id, base_amount, quote_amount });
}

// === test-only accessors ===

/// M14 Chunk 4: relocated unchanged from the now-deleted `order.move`'s
/// own `bid_for_testing`/`ask_for_testing` (the `BID`/`ASK` side-convention
/// accessors) — this module's own canonical placement functions use the
/// bare `true`/`false` literals directly (§Canonical placement/cancel/
/// claim functions, Chunk 2), so no local `BID`/`ASK` constant exists here
/// to expose; these two accessors simply return the literal values
/// directly, for test fixture parity with `order.move`'s own established
/// side-convention (`true` = bid, `false` = ask).
#[test_only]
public fun bid_for_testing(): bool { true }

#[test_only]
public fun ask_for_testing(): bool { false }

#[test_only]
public fun pool_admin_cap_id_for_testing<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): ID {
    book.pool_admin_cap_id
}

/// Test-only raw resting-order seeding helper (encapsulation-leak fix,
/// Problem 1): `bids_mut`/`asks_mut`/`price_level_orders_mut` are now fully
/// private, so a test module can no longer construct a price level and
/// splice it into the book's own tree directly. This exposes the module's
/// own existing internal insertion logic (`insert_resting_order` — the same
/// path every real placement function uses to rest an order) directly, so a
/// test can seed an arbitrary resting `Order` at a given `side`/`price`
/// without going through a full `place_limit_order_*` call.
#[test_only]
public fun insert_resting_order_for_testing<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order: Order<Base, Quote>,
    ctx: &mut TxContext,
) {
    insert_resting_order(book, side, price, order, ctx);
}

/// Test-only fee-accumulator seeding helper (encapsulation-leak fix,
/// Problem 1): `asks_mut_proceeds_mut_and_fees_mut` is now fully private, so
/// a test module can no longer reach into the book directly to seed a fee
/// balance for `pool_admin_claim_fees` coverage. This does the equivalent
/// internally (both calls are legal here since this function is defined in
/// the same module as the now-private accessor).
#[test_only]
public fun credit_fee_accumulator_for_testing<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    let (_, _, fees) = asks_mut_proceeds_mut_and_fees_mut(book);
    credit_fee_accumulator(fees, base, quote);
}

#[test_only]
public fun for_book_for_testing(cap: &EmbeddedPoolAdminCap): ID {
    cap.for_book
}

#[test_only]
public fun book_version_is_for_testing<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>, expected: u64): bool {
    book.version == expected
}

#[test_only]
public fun proceeds_contains_for_testing<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>, addr: address): bool {
    linked_table::contains(&book.proceeds, addr)
}

#[test_only]
public fun embedded_pool_admin_cap_discarded_fields_for_testing(e: &EmbeddedPoolAdminCapDiscarded): (ID, ID) {
    (e.cap_id, e.for_book)
}

#[test_only]
public fun paused_fields_for_testing(e: &Paused): ID { e.order_book_id }

#[test_only]
public fun unpaused_fields_for_testing(e: &Unpaused): ID { e.order_book_id }

#[test_only]
public fun taker_fee_set_fields_for_testing(e: &TakerFeeSet): (ID, u64) { (e.order_book_id, e.rate_bps) }

#[test_only]
public fun maker_fee_set_fields_for_testing(e: &MakerFeeSet): (ID, u64) { (e.order_book_id, e.rate_bps) }

#[test_only]
public fun event_id_for_testing<Base, Quote>(book: &EmbeddedOrderBook<Base, Quote>): ID { book.event_id }

#[test_only]
public fun fees_claimed_fields_for_testing(e: &FeesClaimed): (address, ID, u64, u64) {
    (e.claimant, e.order_book_id, e.base_amount, e.quote_amount)
}

#[test_only]
public fun order_cancelled_fields_for_testing(e: &OrderCancelled): (u64, ID, address) {
    (e.order_id, e.order_book_id, e.trader)
}

/// M14 Chunk 2 — mirrors `order.move`'s `order_placed_fields_for_testing`.
#[test_only]
public fun order_placed_fields_for_testing(e: &OrderPlaced): (u64, ID, bool, u64, u64, address) {
    (e.order_id, e.order_book_id, e.side, e.price, e.size, e.trader)
}

/// M14 Chunk 2 — mirrors `order.move`'s `proceeds_claimed_fields_for_testing`.
#[test_only]
public fun proceeds_claimed_fields_for_testing(e: &ProceedsClaimed): (address, ID, u64, u64) {
    (e.claimant, e.order_book_id, e.base_amount, e.quote_amount)
}

#[test_only]
public fun market_retired_fields_for_testing(e: &MarketRetired): ID { e.order_book_id }

/// M14 Chunk 2: widened return arity from bare `ID` to a 3-tuple, matching
/// `MarketDeleted`'s own widened shape (§Test-assertion-vs-call-site-rename
/// judgment call, `docs/plan-m14.md`).
#[test_only]
public fun market_deleted_fields_for_testing(e: &MarketDeleted): (ID, TypeName, TypeName) {
    (e.order_book_id, e.base, e.quote)
}

// === M14 Chunk 1: test-only accessors for the relocated matching engine /
// EmbeddedOrderTicket ===

/// Test-only constructor — `EmbeddedOrderTicket`'s literal is otherwise only
/// constructible by this module's own (Chunk-2-landing) canonical placement
/// functions, which do not exist yet; this lets Chunk 1's own tests
/// construct a value directly for disposal-path testing.
///
/// NOTE (test-only, does not reflect the production invariant): the caller
/// supplies `order_book_id` directly here, which lets a test construct a
/// ticket carrying *any* id, including one that was never a real book's own
/// `event_id`. In production, every `EmbeddedOrderTicket`'s `order_book_id`
/// is always exactly whatever `book.core`'s `event_id` was fixed to at
/// construction — which `market.move`'s `create_market` passes as `new`'s
/// `event_id_override` (the real outer `OrderBook` id) before the book is
/// ever shared (see `market.move`'s `create_market`/`redeem_transfer_
/// ticket` comments). Do not read this constructor's freedom to pass an
/// arbitrary id as evidence that production tickets can carry one too.
#[test_only]
public fun new_embedded_ticket_for_testing(
    order_id: u64,
    order_book_id: ID,
    side: bool,
    price: u64,
): EmbeddedOrderTicket {
    EmbeddedOrderTicket { order_id, order_book_id, side, price }
}

#[test_only]
public fun embedded_ticket_fields_for_testing(t: &EmbeddedOrderTicket): (u64, ID, bool, u64) {
    (t.order_id, t.order_book_id, t.side, t.price)
}

#[test_only]
public fun order_filled_fields_for_testing(e: &OrderFilled): (u64, ID, u64, u64, address, address) {
    (e.maker_order_id, e.order_book_id, e.price, e.quantity, e.maker, e.taker)
}

/// Direct `match_bid` exposure, mirroring `order.move`'s own `match_bid_
/// for_testing` established pattern exactly (`sources/order.move:1483-
/// 1517`), receiver type substituted to `EmbeddedOrderBook`. Used by this
/// chunk's own behavioral-equivalence test to drive the newly-relocated
/// `match_bid`/`fill_level_bid` directly, with an arbitrary (not
/// escrow-derived) `payment`.
#[test_only]
public fun match_bid_for_testing<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    payment: Coin<Quote>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, u64, bool) {
    let taker = ctx.sender();
    let book_id = book.event_id;
    let budget = coin::into_balance(payment);
    let taker_fee_bps = book.taker_fee_bps;
    let (asks, proceeds, fees) = asks_mut_proceeds_mut_and_fees_mut(book);
    let (matched_base, remaining_budget, remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, limit_price, remaining_size_in, budget, taker, book_id, max_fills);
    (
        coin::from_balance(matched_base, ctx),
        coin::from_balance(remaining_budget, ctx),
        remaining_size,
        stopped_on_max_fills_while_crossing,
    )
}

/// Direct `match_ask` exposure — symmetric counterpart to `match_bid_for_
/// testing` above, no `order.move`-side precedent exists for this side
/// (`order.move` only ever added a bid-side testing accessor), added here
/// since this chunk's own behavioral-equivalence test needs a direct,
/// isolated way to drive the newly-relocated `match_ask`/`fill_level_ask`.
#[test_only]
public fun match_ask_for_testing<Base, Quote>(
    book: &mut EmbeddedOrderBook<Base, Quote>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    payment: Coin<Base>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Coin<Quote>, Coin<Base>, u64, bool) {
    let taker = ctx.sender();
    let book_id = book.event_id;
    let own_wallet = coin::into_balance(payment);
    let taker_fee_bps = book.taker_fee_bps;
    let (bids, proceeds, fees) = bids_mut_proceeds_mut_and_fees_mut(book);
    let (matched_quote, remaining_wallet, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, limit_price, remaining_size_in, own_wallet, taker, book_id, max_fills);
    (
        coin::from_balance(matched_quote, ctx),
        coin::from_balance(remaining_wallet, ctx),
        remaining_size,
        stopped_on_max_fills_while_crossing,
    )
}

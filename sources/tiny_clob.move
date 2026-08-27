/// `OrderBook<Base, Quote>` — a price-time-priority limit order book meant
/// to be embedded as a field inside an integrator's own object, rather than
/// registered as a shared, standalone object. Provides limit and market
/// order placement, cancellation, matching, maker-fee proceeds tracking,
/// clob-admin-gated fee/pause controls, and a clob_admin_retire/drain/clob_admin_finalize
/// deletion lifecycle.
///
/// `price` throughout this module is quote-atoms per base-atom, not a
/// human-readable decimal ratio; see `place_limit_order_bid`'s doc comment
/// for the resulting granularity constraint on pairs where
/// `quote_decimals < base_decimals`.
module tiny_clob::tiny_clob;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::linked_table::{Self, LinkedTable};
use std::type_name::{Self, TypeName};
use tiny_clob::order::{Self, Order};
use tiny_clob::price_tree::{Self, PriceTree, PriceLevel};

// === Error constants ===

const EZeroMinSize: u64 = 1;
const EMinSizeTooLarge: u64 = 3;
const EWrongClobAdminCap: u64 = 4;
const ENewVersionMismatch: u64 = 5;
const ENotRetiring: u64 = 6;
const ENotFullyDrained: u64 = 7;
const ETakerFeeRateTooHigh: u64 = 8;
const EMakerFeeRateTooHigh: u64 = 9;
const ESizeBelowMinSize: u64 = 12;
/// A `price * size`-style multiplication's `u128` intermediate exceeded
/// `u64::MAX`.
const EPriceSizeOverflow: u64 = 13;
const EZeroPrice: u64 = 14;
const EBookPaused: u64 = 15;
const EWrongBook: u64 = 16;
const ESlippageExceeded: u64 = 17;
const EBookRetiring: u64 = 18;
const EProceedsNotEmpty: u64 = 19;

const MAX_TAKER_FEE_BPS: u64 = 10;
const MAX_MAKER_FEE_BPS: u64 = 5;
const MAX_MIN_SIZE: u64 = 1_000_000_000_000_000;
const U64_MAX: u128 = 0xFFFFFFFFFFFFFFFF;

/// Bumped whenever a published version of this package introduces a
/// breaking change to `OrderBook`'s on-chain layout or semantics. Existing
/// books need no explicit migration step — `assert_book_version` transparently
/// upgrades any book whose stored `version` lags behind `CURRENT_VERSION` the
/// next time it is touched by any version-guarded call. If a book's `version`
/// is instead AHEAD of this constant, it means this package build doesn't
/// yet understand a `version` the book already carries (see
/// `assert_book_version`).
const CURRENT_VERSION: u64 = 1;

// === Side convention ===

/// `side == true` means the bid side, `side == false` means the ask side.
/// Every `side: bool` parameter and struct field in this module (e.g.
/// `depth_at_price`'s `side`, `OrderTicket.side`, `OrderPlaced.side`)
/// follows this convention. `bid`/`ask` below are purely additive — they let
/// an external integrator write a self-documenting `tiny_clob::bid()` /
/// `tiny_clob::ask()` call site instead of a bare `true`/`false` if they
/// choose to; no function signature in this module is changed to require
/// them, and passing the literal `true`/`false` directly remains equally
/// valid.
public fun bid(): bool { true }

/// See `bid` above.
public fun ask(): bool { false }

// === Order-book internal structs ===
//
// `Order<Base, Quote>` and `PriceLevel<Base, Quote>` live in
// `tiny_clob::price_tree` now, along with every function that can touch
// `PriceLevel.orders` or `Order.remaining_size` — see that module's
// `level_*`/`order_*` functions. This module has no direct field access to
// either type; every interaction goes through that package-private API,
// which keeps `PriceLevel.total_size` always in sync by construction.

/// A maker's claimable-but-unclaimed proceeds ledger entry.
public struct MakerBalance<phantom Base, phantom Quote> has store {
    owner: address,
    base: Balance<Base>,
    quote: Balance<Quote>,
}

/// Per-book accumulator of collected taker/maker fees.
public struct FeeAccumulator<phantom Base, phantom Quote> has store {
    base: Balance<Base>,
    quote: Balance<Quote>,
}

fun credit_maker_table<Base, Quote>(
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    order_id: u64,
    owner: address,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    if (!linked_table::contains(proceeds, order_id)) {
        linked_table::push_back(proceeds, order_id, MakerBalance { owner, base: balance::zero(), quote: balance::zero() });
    };
    let mb = linked_table::borrow_mut(proceeds, order_id);
    mb.owner = owner;
    mb.base.join(base);
    mb.quote.join(quote);
}

/// If `proceeds` already holds a pooled `MakerBalance` entry for `order_id`,
/// re-stamps its payout `owner` in place. A no-op when no such entry exists
/// yet — a later `credit_maker_table` call will stamp the correct owner at
/// credit time in that case. Used by `update_resting_order` to keep an
/// already-pooled proceeds balance's payout destination in sync with a
/// reassigned order owner.
fun sync_maker_balance_owner<Base, Quote>(
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    order_id: u64,
    new_owner: address,
) {
    if (linked_table::contains(proceeds, order_id)) {
        linked_table::borrow_mut(proceeds, order_id).owner = new_owner;
    };
}

fun destroy_maker_balance<Base, Quote>(
    mb: MakerBalance<Base, Quote>,
): (address, Balance<Base>, Balance<Quote>) {
    let MakerBalance { owner, base, quote } = mb;
    (owner, base, quote)
}

fun new_fee_accumulator<Base, Quote>(): FeeAccumulator<Base, Quote> {
    FeeAccumulator { base: balance::zero(), quote: balance::zero() }
}

fun destroy_fee_accumulator<Base, Quote>(
    fees: FeeAccumulator<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    let FeeAccumulator { base, quote } = fees;
    (base, quote)
}

fun credit_fee_accumulator<Base, Quote>(
    fees: &mut FeeAccumulator<Base, Quote>,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    fees.base.join(base);
    fees.quote.join(quote);
}

// === OrderBook<Base, Quote> ===

/// `retiring` is a genuinely separate, sticky flag from `paused`. It is set
/// to `true` only by `clob_admin_retire`, and there is no function anywhere
/// in this module that ever clears it back to `false` — once a book starts
/// retiring, it is retiring forever. `clob_admin_drain_step` and
/// `clob_admin_finalize` both gate on `retiring` (not `paused`), so a plain
/// `clob_admin_pause_book` call is no longer sufficient to unlock the
/// destructive drain/finalize path. `paused` still independently gates new
/// order placement and can be freely toggled via `clob_admin_pause_book` /
/// `clob_admin_unpause_book` — but only until retirement begins:
/// `clob_admin_unpause_book` refuses to run on a retiring book (there is no
/// way to reverse retirement once started), so once `retiring` is set,
/// `paused` can never be cleared again either.
///
/// `has store` only — deliberately no `key`. This makes it structurally
/// impossible for `OrderBook` to ever become a Sui shared object via
/// `sui::transfer::share_object`, which requires `key`. There is no way to
/// keep `key` while blocking just that one operation, so dropping `key`
/// entirely is the only enforced mechanism — a compile-time guarantee, not
/// something a runtime test can exercise. `id: UID` is retained purely as a
/// genuine, globally-unique `UID` value this struct can hold as a plain
/// `store`-only field: a struct needs `key` to be a top-level object, but
/// any struct — `key` or not — may hold a `UID` field and anchor dynamic
/// fields off it via `sui::dynamic_field`, since dynamic-field storage is
/// keyed off the `UID`'s address regardless of the containing struct's own
/// abilities. It is never used to make this struct independently
/// object-like.
#[allow(lint(missing_key))]
public struct OrderBook<phantom Base, phantom Quote> has store {
    id: UID,
    /// Bounds order-placement size only, not post-fill remainder size — see
    /// `validate_size_raw`'s doc comment for the full caveat about resulting
    /// dust and `max_fills` griefing.
    min_size: u64,
    bids: PriceTree<PriceLevel<Base, Quote>>,
    asks: PriceTree<PriceLevel<Base, Quote>>,
    proceeds: LinkedTable<u64, MakerBalance<Base, Quote>>,
    paused: bool,
    /// Sticky: set to `true` only by `clob_admin_retire`, never cleared back
    /// to `false` by any function. See the struct doc comment above.
    retiring: bool,
    next_order_id: u64,
    clob_admin_cap_id: ID,
    version: u64,
    taker_fee_bps: u64,
    maker_fee_bps: u64,
    fee_accumulator: FeeAccumulator<Base, Quote>,
    /// The id every event this module emits stamps as `order_book_id`.
    /// Write-once: fixed at construction time (defaults to the book's own
    /// internal id via plain `new`, or to a caller-supplied override via
    /// `new_with_event_id_override`) and never mutable afterward. A
    /// wrapping object whose own outer id is what external
    /// callers/indexers actually query by should use
    /// `new_with_event_id_override`, passing a borrow of that object's own
    /// `UID`, instead of plain `new`.
    ///
    /// This field exists SOLELY to be stamped on emitted events. Because
    /// `new_with_event_id_override` requires a live `&UID` reference rather
    /// than a bare `ID` value, a caller can no longer forge this to an
    /// arbitrary id merely copied off a public event or explorer — that no
    /// longer compiles. This does NOT, however, guarantee the caller
    /// controls the referenced object: any object that is genuinely shared
    /// and whose module exposes a public `&UID` accessor (e.g.
    /// `sui::kiosk::uid(&Kiosk)`, `sui::transfer_policy::uid(&TransferPolicy)`)
    /// can have its `&UID` borrowed by any address, not just its owner, so
    /// `event_id` can in principle still be pointed at an id the caller
    /// doesn't own when such an accessor exists. This narrows the attack
    /// surface; it does not eliminate it. Regardless, `event_id` is NEVER
    /// used for authentication anywhere in this module and must never be
    /// relied on for any authentication/identity check — the residual risk
    /// above is scoped strictly to event/indexer spoofing (an off-chain
    /// consumer trusting `order_book_id` without independently verifying its
    /// true origin), never fund safety or access control. The book's own
    /// object id (`id: UID` above, via `object::uid_to_inner(&book.id)`) is
    /// what's unforgeable and must be used for authentication instead (see
    /// `OrderTicket.order_book_id`).
    event_id: ID,
}

// === ClobAdminCap ===

public struct ClobAdminCap has key, store {
    id: UID,
    for_book: ID,
}

public struct ClobAdminCapDiscarded has copy, drop {
    cap_id: ID,
    for_book: ID,
}

// === Constructor ===

/// Callable by any address — no capability is required to create a book,
/// and it is never registered anywhere by this call.
///
/// The book's `event_id` (stamped on every emitted event) defaults to the
/// book's own object id. Use `new_with_event_id_override` instead of this
/// function if a wrapping object's own id should be stamped there instead.
///
/// `min_size` bounds order-placement size only, not post-fill remainder
/// size — see `validate_size_raw`'s doc comment for the full caveat about
/// resulting dust and `max_fills` griefing.
public fun new<Base, Quote>(
    min_size: u64,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    new_impl(min_size, option::none(), ctx)
}

/// Same as `new`, except the book's `event_id` (stamped on every emitted
/// event) is set to `object::uid_to_inner(event_id_override)` instead of
/// defaulting to the book's own id — for a wrapping object whose own outer
/// id is what external callers/indexers actually query by.
///
/// `event_id_override` is a borrowed `&UID` rather than a bare `ID`
/// specifically to rule out the naive attack of pointing `event_id` at an
/// arbitrary id (e.g. copied off a public event for an unrelated book) that
/// the caller merely knows but doesn't hold a live reference to — passing a
/// bare `ID` copied that way no longer compiles. This does NOT fully
/// guarantee the caller controls the referenced object: any object that is
/// genuinely shared and whose module exposes a public `&UID` accessor (e.g.
/// `sui::kiosk::uid(&Kiosk)`, `sui::transfer_policy::uid(&TransferPolicy)`)
/// can have its `&UID` borrowed by any address, not just its owner — so a
/// caller can still legitimately obtain and pass in a live `&UID` for an
/// object they don't own if such an accessor exists for it. This narrows
/// the attack surface; it does not eliminate id spoofing outright. As
/// documented on `OrderBook.event_id`, this is never a fund-safety or
/// authentication concern — `event_id` is never used for authentication
/// anywhere in this module — only an event/indexer spoofing concern. Note:
/// `Option<&UID>` is not a legal Move type (generic type parameters,
/// including `Option`'s, cannot be references), which is why this is a
/// separate function rather than an `Option<&UID>` parameter on `new`
/// itself.
///
/// `min_size` carries the same order-placement-size-only caveat documented
/// on `new` (see `validate_size_raw`'s doc comment).
public fun new_with_event_id_override<Base, Quote>(
    min_size: u64,
    event_id_override: &UID,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    new_impl(min_size, option::some(object::uid_to_inner(event_id_override)), ctx)
}

fun new_impl<Base, Quote>(
    min_size: u64,
    event_id_override: Option<ID>,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    assert!(min_size != 0, EZeroMinSize);
    assert!(min_size <= MAX_MIN_SIZE, EMinSizeTooLarge);

    let book_uid = object::new(ctx);
    let book_id = object::uid_to_inner(&book_uid);
    let cap = ClobAdminCap { id: object::new(ctx), for_book: book_id };
    let cap_id = object::id(&cap);
    let event_id = if (event_id_override.is_some()) {
        event_id_override.destroy_some()
    } else {
        event_id_override.destroy_none();
        book_id
    };

    let book = OrderBook<Base, Quote> {
        id: book_uid,
        min_size,
        bids: price_tree::new(ctx),
        asks: price_tree::new(ctx),
        proceeds: linked_table::new(ctx),
        paused: false,
        retiring: false,
        next_order_id: 0,
        clob_admin_cap_id: cap_id,
        version: CURRENT_VERSION,
        taker_fee_bps: 0,
        maker_fee_bps: 0,
        fee_accumulator: new_fee_accumulator(),
        event_id,
    };
    (book, cap)
}

// === Package-private field accessors ===

public(package) fun min_size<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.min_size
}

fun taker_fee_bps<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.taker_fee_bps
}

fun maker_fee_bps<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.maker_fee_bps
}

fun withdraw_fee_accumulator<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    let fees = &mut book.fee_accumulator;
    (fees.base.withdraw_all(), fees.quote.withdraw_all())
}

public(package) fun is_paused<Base, Quote>(book: &OrderBook<Base, Quote>): bool {
    book.paused
}

/// Fetch-and-increment: returns the next unique `order_id` for a newly
/// placed order.
public(package) fun next_order_id<Base, Quote>(book: &mut OrderBook<Base, Quote>): u64 {
    let id = book.next_order_id;
    book.next_order_id = id + 1;
    id
}

fun claim_maker_balance<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    order_id: u64,
): (address, Balance<Base>, Balance<Quote>) {
    if (!linked_table::contains(&book.proceeds, order_id)) {
        return (@0x0, balance::zero(), balance::zero())
    };
    let mb = linked_table::remove(&mut book.proceeds, order_id);
    destroy_maker_balance(mb)
}

public struct BookVersionUpgraded has copy, drop {
    book_id: ID,
    from: u64,
    to: u64,
}

/// Public so an integrator wrapping this book can version-guard its own
/// call sites the same way this module's own functions do.
///
/// Self-healing, not just a check: a book whose `version` lags behind the
/// currently-published package's `CURRENT_VERSION` is transparently upgraded
/// in place — no admin migration call is required for callers to keep
/// working across a version bump. Only a book whose `version` is AHEAD of
/// this package's `CURRENT_VERSION` (i.e. this package build doesn't yet
/// understand a `version` the book already carries — this call is running
/// against an older, not-yet-upgraded package build) still aborts, since
/// that direction can never be safely auto-resolved by older code.
///
/// IMPORTANT — this silent, no-migration self-healing is a placeholder
/// policy, valid only because no version bump to date has ever required
/// actual per-book data migration (`CURRENT_VERSION` has only ever moved
/// from 0 to 1, a bookkeeping-only change). The day `CURRENT_VERSION` is
/// bumped for a change that DOES require converting a book's existing
/// on-chain data, this silent auto-bump behavior must be replaced — before
/// that version ships, not after — with an explicit, cap-gated migration
/// function and a strict version-equality assert here, so an un-migrated
/// book can no longer silently self-heal into a version whose data layout it
/// doesn't actually have yet.
public fun assert_book_version<Base, Quote>(book: &mut OrderBook<Base, Quote>) {
    assert!(book.version <= CURRENT_VERSION, ENewVersionMismatch);
    if (book.version < CURRENT_VERSION) {
        let from = book.version;
        book.version = CURRENT_VERSION;
        event::emit(BookVersionUpgraded {
            book_id: object::uid_to_inner(&book.id),
            from,
            to: CURRENT_VERSION,
        });
    };
}

// === Public view functions (no version-guard assertion) ===

/// The book's own immutable object id — what `OrderTicket.order_book_id` is
/// bound to (see `OrderTicket`'s doc comment). NOT the same as `event_id`,
/// which is caller-overridable at construction and used only for event
/// stamping; this is the actual, unforgeable identity `cancel_order` and
/// `update_resting_order` authenticate tickets against.
public fun book_id<Base, Quote>(book: &OrderBook<Base, Quote>): ID {
    object::uid_to_inner(&book.id)
}

public fun fee_config<Base, Quote>(book: &OrderBook<Base, Quote>): (u64, u64) {
    (book.taker_fee_bps, book.maker_fee_bps)
}

public fun fee_accumulator_balances<Base, Quote>(book: &OrderBook<Base, Quote>): (u64, u64) {
    (balance::value(&book.fee_accumulator.base), balance::value(&book.fee_accumulator.quote))
}

public fun is_book_paused<Base, Quote>(book: &OrderBook<Base, Quote>): bool {
    book.paused
}

/// Sticky: once `true`, stays `true` forever (see `OrderBook`'s doc comment).
public fun is_book_retiring<Base, Quote>(book: &OrderBook<Base, Quote>): bool {
    book.retiring
}

public fun best_bid<Base, Quote>(book: &OrderBook<Base, Quote>): Option<u64> {
    let ptr = price_tree::max_leaf(&book.bids);
    if (ptr.is_none()) {
        option::none()
    } else {
        let leaf_ptr = *ptr.borrow();
        option::some(price_tree::key(&book.bids, leaf_ptr))
    }
}

public fun best_ask<Base, Quote>(book: &OrderBook<Base, Quote>): Option<u64> {
    let ptr = price_tree::min_leaf(&book.asks);
    if (ptr.is_none()) {
        option::none()
    } else {
        let leaf_ptr = *ptr.borrow();
        option::some(price_tree::key(&book.asks, leaf_ptr))
    }
}

public fun depth_at_price<Base, Quote>(book: &OrderBook<Base, Quote>, side: bool, price: u64): u64 {
    let tree = if (side) &book.bids else &book.asks;
    let found = price_tree::find(tree, price);
    if (found.is_none()) {
        return 0
    };
    let leaf_ptr = found.destroy_some();
    let level = price_tree::borrow(tree, leaf_ptr);
    price_tree::level_total_size(level)
}

// === ClobAdminCap gate ===

fun assert_clob_admin<Base, Quote>(cap: &ClobAdminCap, book: &OrderBook<Base, Quote>) {
    assert!(object::id(cap) == book.clob_admin_cap_id, EWrongClobAdminCap);
}

// === Local pause/unpause ===

public struct Paused has copy, drop {
    order_book_id: ID,
}

public struct Unpaused has copy, drop {
    order_book_id: ID,
}

public fun clob_admin_pause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let event_book_id = book.event_id;
    book.paused = true;
    event::emit(Paused { order_book_id: event_book_id });
}

public fun clob_admin_unpause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(!book.retiring, EBookRetiring);
    let event_book_id = book.event_id;
    book.paused = false;
    event::emit(Unpaused { order_book_id: event_book_id });
}

// === Fee setters and claim_fees ===

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

public fun clob_admin_set_taker_fee<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    rate_bps: u64,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(rate_bps <= MAX_TAKER_FEE_BPS, ETakerFeeRateTooHigh);
    let event_book_id = book.event_id;
    book.taker_fee_bps = rate_bps;
    event::emit(TakerFeeSet { order_book_id: event_book_id, rate_bps });
}

public fun clob_admin_set_maker_fee<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    rate_bps: u64,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(rate_bps <= MAX_MAKER_FEE_BPS, EMakerFeeRateTooHigh);
    let event_book_id = book.event_id;
    book.maker_fee_bps = rate_bps;
    event::emit(MakerFeeSet { order_book_id: event_book_id, rate_bps });
}

public fun clob_admin_claim_fees<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let event_book_id = book.event_id;
    let claimant = ctx.sender();
    let (base, quote) = withdraw_fee_accumulator(book);
    let base_amount = balance::value(&base);
    let quote_amount = balance::value(&quote);

    let base_coin = coin_or_zero(base, ctx);
    let quote_coin = coin_or_zero(quote, ctx);

    if (base_amount != 0 || quote_amount != 0) {
        event::emit(FeesClaimed { claimant, order_book_id: event_book_id, base_amount, quote_amount });
    };
    (base_coin, quote_coin)
}

// === Force-cancel ===

public struct OrderCancelled has copy, drop {
    order_id: u64,
    order_book_id: ID,
    trader: address,
}

public fun clob_admin_cancel_order<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order_id: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let event_book_id = book.event_id;
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let order_opt = price_tree::find_and_remove_order(tree, price, order_id);
    if (order_opt.is_none()) { order_opt.destroy_none(); return };
    let live_order = order_opt.destroy_some();
    let owner = order::owner(&live_order);
    let (escrow_base, escrow_quote) = order::destroy(live_order);
    refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
    event::emit(OrderCancelled { order_id, order_book_id: event_book_id, trader: owner });
}

// === Deletion lifecycle: clob_admin_retire/clob_admin_drain_step/clob_admin_finalize ===

public struct OrderBookRetired has copy, drop {
    order_book_id: ID,
}

public struct OrderBookDeleted has copy, drop {
    order_book_id: ID,
    base: TypeName,
    quote: TypeName,
}

public fun clob_admin_retire<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let event_book_id = book.event_id;
    book.paused = true;
    book.retiring = true;
    event::emit(OrderBookRetired { order_book_id: event_book_id });
}

public fun clob_admin_drain_step<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    max_items: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(book.retiring, ENotRetiring);
    let mut remaining = max_items;
    drain_side(&mut book.bids, &mut remaining, /* want_max */ true, ctx);
    drain_side(&mut book.asks, &mut remaining, /* want_max */ false, ctx);
    drain_proceeds(&mut book.proceeds, &mut remaining, ctx);
}

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
            loop {
                if (*remaining == 0) break;
                if (price_tree::level_is_empty(level)) break;
                let (_, order) = price_tree::level_pop_front_order(level);
                let owner = order::owner(&order);
                let (escrow_base, escrow_quote) = order::destroy(order);
                refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
                *remaining = *remaining - 1;
            };
            is_empty_now = price_tree::level_is_empty(level);
        };
        if (is_empty_now) {
            let removed = price_tree::remove(tree, leaf_ptr);
            price_tree::destroy_empty_price_level(removed);
        };
    };
}

/// Converts `b` to a `Coin`, avoiding `coin::from_balance` on a zero-valued
/// `Balance` (which lacks `drop` and cannot simply be discarded) by
/// destroying it and minting an empty coin instead.
fun coin_or_zero<T>(b: Balance<T>, ctx: &mut TxContext): Coin<T> {
    if (balance::value(&b) == 0) {
        balance::destroy_zero(b);
        coin::zero(ctx)
    } else {
        coin::from_balance(b, ctx)
    }
}

/// Transfers `b` to `owner` as a `Coin`, or destroys it in place if it's
/// zero-valued (avoiding a zero-value transfer).
fun transfer_or_destroy_zero<T>(b: Balance<T>, owner: address, ctx: &mut TxContext) {
    if (balance::value(&b) == 0) {
        balance::destroy_zero(b);
    } else {
        transfer::public_transfer(coin::from_balance(b, ctx), owner);
    };
}

/// Both escrow legs may legitimately be zero-valued (e.g. a fully-filled
/// order still holds a spent `Balance`), so `balance::destroy_zero` is used
/// in place of transferring a zero coin.
fun refund_order_escrow<Base, Quote>(
    owner: address,
    mut escrow_base: Option<Balance<Base>>,
    mut escrow_quote: Option<Balance<Quote>>,
    ctx: &mut TxContext,
) {
    if (escrow_base.is_some()) {
        let base = escrow_base.extract();
        transfer_or_destroy_zero(base, owner, ctx);
    };
    escrow_base.destroy_none();
    if (escrow_quote.is_some()) {
        let quote = escrow_quote.extract();
        transfer_or_destroy_zero(quote, owner, ctx);
    };
    escrow_quote.destroy_none();
}

fun drain_proceeds<Base, Quote>(
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    remaining: &mut u64,
    ctx: &mut TxContext,
) {
    while (*remaining > 0 && !linked_table::is_empty(proceeds)) {
        let (_order_id, mb) = linked_table::pop_front(proceeds);
        let (owner, base, quote) = destroy_maker_balance(mb);
        transfer_or_destroy_zero(base, owner, ctx);
        transfer_or_destroy_zero(quote, owner, ctx);
        *remaining = *remaining - 1;
    };
}

/// Returns the book's true, unforgeable object id
/// (`object::uid_to_inner(&book.id)`) — NOT `book.event_id`. This is
/// distinct from the emitted `OrderBookDeleted` event's `order_book_id`
/// field, which stamps `event_id` and may differ if the book was
/// constructed with an `event_id_override`. A caller that relies on this
/// return value for indexing/bookkeeping gets the book's authoritative
/// identity, unlike `event_id`, which is caller-controllable at
/// construction time and must never be trusted for that purpose.
public fun clob_admin_finalize<Base, Quote>(
    cap: ClobAdminCap,
    mut book: OrderBook<Base, Quote>,
): ID {
    assert_book_version(&mut book);
    assert_clob_admin(&cap, &book);
    assert!(book.retiring, ENotRetiring);
    let (fee_base, fee_quote) = fee_accumulator_balances(&book);
    assert!(
        price_tree::size(&book.bids) == 0 && price_tree::size(&book.asks) == 0 && book.proceeds.is_empty()
            && fee_base == 0 && fee_quote == 0,
        ENotFullyDrained,
    );

    let OrderBook {
        id, min_size: _, bids, asks, proceeds,
        paused: _, retiring: _, next_order_id: _, clob_admin_cap_id: _, version: _,
        taker_fee_bps: _, maker_fee_bps: _, fee_accumulator, event_id,
    } = book;
    let event_book_id = event_id;
    let true_book_id = object::uid_to_inner(&id);
    price_tree::destroy_empty(bids);
    price_tree::destroy_empty(asks);
    linked_table::destroy_empty(proceeds);
    let (base, quote) = destroy_fee_accumulator(fee_accumulator);
    balance::destroy_zero(base);
    balance::destroy_zero(quote);
    object::delete(id);

    event::emit(OrderBookDeleted {
        order_book_id: event_book_id,
        base: type_name::with_defining_ids<Base>(),
        quote: type_name::with_defining_ids<Quote>(),
    });

    let ClobAdminCap { id: cap_id_uid, for_book: _ } = cap;
    let cap_id = object::uid_to_inner(&cap_id_uid);
    object::delete(cap_id_uid);
    event::emit(ClobAdminCapDiscarded { cap_id, for_book: true_book_id });

    true_book_id
}

// === Matching engine, escrow/fee math, OrderTicket ===

public struct OrderFilled has copy, drop {
    maker_order_id: u64,
    order_book_id: ID,
    price: u64,
    size: u64,
    maker: address,
    taker: address,
}

/// `price * size`, computed via a `u128` intermediate and abort-checked
/// before narrowing back to `u64` — never silently wraps. `size` is always
/// `Base`-atomic-units; a bid's escrow is this amount of `Quote`. Like every
/// `price` in this module, `price` here is quote-atoms per base-atom, not a
/// human-readable quote-per-base decimal ratio; see `place_limit_order_bid`'s
/// doc comment for the granularity caveat when `quote_decimals < base_decimals`.
public fun bid_escrow_amount(price: u64, size: u64): u64 {
    checked_mul_u64(price, size)
}

fun checked_mul_u64(a: u64, b: u64): u64 {
    let product = (a as u128) * (b as u128);
    assert!(product <= U64_MAX, EPriceSizeOverflow);
    product as u64
}

/// `ceil(receive_amount * rate_bps / 10_000)`, computed via a `u128`
/// intermediate. No explicit overflow check is needed: `rate_bps` is
/// bounds-checked to at most `MAX_TAKER_FEE_BPS`/`MAX_MAKER_FEE_BPS` before
/// it can ever reach this function, so the maximum possible product is far
/// below `u128::MAX`. Ceiling division: any nonzero `receive_amount` at a
/// nonzero `rate_bps` now pays at least 1 unit of fee, closing a dust-sized
/// exploit where floor division let many small fills each collect zero fee.
fun fee_amount(receive_amount: u64, rate_bps: u64): u64 {
    (((receive_amount as u128) * (rate_bps as u128) + 9_999) / 10_000) as u64
}

/// `min_size` bounds order-placement size only — it is enforced here, once,
/// at the moment an order is submitted. It is never re-checked against the
/// size of a resulting fill or a partial-fill remainder. A partial fill can
/// leave a resting order's `remaining_size` below `min_size` ("dust"); that
/// dust persists on the book — untouched by any automatic mechanism — until
/// it is cancelled by its ticket holder, fully consumed by a later fill, or
/// removed by an admin via `clob_admin_cancel_order` / `clob_admin_drain_step`.
/// Each resting order, dust-sized or not, consumes exactly one `max_fills`
/// slot when a taker's sweep reaches it (see `fills_consumed` in
/// `fill_level_bid`/`fill_level_ask`, incremented unconditionally per
/// touched order before any size check
/// runs). In an adversarial or permissionless deployment, this means dust
/// accumulation can cheapen a `max_fills`-based griefing strategy against a
/// specific taker — most plausible where delaying one specific transaction
/// has real payoff (e.g. a liquidation venue), not typical ordinary trading.
/// The available mitigation: every placement/market entry point returns a
/// `stopped_on_max_fills_while_crossing` bool — integrators should treat a
/// `true` result as a signal to retry with a larger `max_fills`, not assume
/// a single sweep reflects true available liquidity. This tradeoff is
/// deliberate: a fill-time fix (force-cancelling a maker's dust remainder
/// instead of resting it) was considered and rejected, since it would
/// force-cancel a maker's resting order below their own chosen `min_size`
/// without their consent — a real behavior change this project has chosen
/// not to make, consistent with the earlier removal of `lot_size` to keep
/// size-policy decisions out of the core matching engine.
fun validate_size_raw(min_size: u64, size: u64) {
    assert!(size >= min_size, ESizeBelowMinSize);
}

fun validate_size<Base, Quote>(book: &OrderBook<Base, Quote>, size: u64) {
    validate_size_raw(min_size(book), size);
}

// Once a maker's `Order` is fully consumed by matching, its escrow `Option`s
// hold either a spent (zero-value) `Balance` or `None`, side-exhaustively.
// These consume both halves of `destroy_order`'s return value so neither an
// `Option` nor a `Balance` is ever silently dropped.

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

fun insert_resting_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order: Order<Base, Quote>,
    ctx: &mut TxContext,
) {
    let order_id = order::id(&order);
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    price_tree::insert_or_append_order(tree, price, order_id, order, ctx);
}

fun fill_level_bid<Base, Quote>(
    asks: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    budget: &mut Balance<Quote>,
    matched_base: &mut Balance<Base>,
    taker: address,
    event_book_id: ID,
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
            if (price_tree::level_is_empty(level)) break;
            let head_key = price_tree::level_front_order_id(level).destroy_some();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = order::remaining_size(price_tree::level_borrow_order(level, head_key));
            let natural_fill_qty = std::u64::min(*remaining_size, maker_remaining);
            let affordable_qty = balance::value(budget) / best_price;
            let fill_qty = std::u64::min(natural_fill_qty, affordable_qty);
            if (fill_qty == 0) {
                budget_exhausted = true;
                break
            };
            let quote_cost = checked_mul_u64(best_price, fill_qty);

            let mut maker_order = price_tree::level_remove_order(level, head_key);
            order::decrease_remaining_size(&mut maker_order, fill_qty);
            let mut base_out = order::split_escrow_base(&mut maker_order, fill_qty);
            let maker_fee_bps = order::maker_fee_bps(&maker_order);
            let maker_addr = order::owner(&maker_order);
            let maker_order_id = order::id(&maker_order);
            let maker_remaining_after = order::remaining_size(&maker_order);

            let taker_fee_base = fee_amount(fill_qty, taker_fee_bps);
            let taker_fee_balance = balance::split(&mut base_out, taker_fee_base);
            matched_base.join(base_out); // remainder, net of taker fee

            let mut quote_payment = balance::split(budget, quote_cost);
            let maker_fee_quote = fee_amount(quote_cost, maker_fee_bps);
            let maker_fee_balance = balance::split(&mut quote_payment, maker_fee_quote);
            credit_fee_accumulator(fees, taker_fee_balance, maker_fee_balance);
            credit_maker_table(proceeds, maker_order_id, maker_addr, balance::zero<Base>(), quote_payment);

            event::emit(OrderFilled {
                maker_order_id,
                order_book_id: event_book_id,
                price: best_price,
                size: fill_qty,
                maker: maker_addr,
                taker,
            });

            *remaining_size = *remaining_size - fill_qty;

            if (maker_remaining_after == 0) {
                let (eb, eq) = order::destroy(maker_order);
                destroy_drained_ask_escrow(eb, eq);
            } else {
                price_tree::level_insert_order_front(level, head_key, maker_order);
            };

            if (fill_qty < natural_fill_qty) {
                budget_exhausted = true;
                break
            };
        };
        is_empty_now = price_tree::level_is_empty(level);
    };
    if (is_empty_now) {
        let removed = price_tree::remove(asks, leaf_ptr);
        price_tree::destroy_empty_price_level(removed);
    };
    (budget_exhausted, hit_max_fills)
}

fun match_bid<Base, Quote>(
    asks: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    taker_fee_bps: u64,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    budget_in: Balance<Quote>,
    taker: address,
    event_book_id: ID,
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
            event_book_id,
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
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    escrow_base: &mut Balance<Base>,
    matched_quote: &mut Balance<Quote>,
    taker: address,
    event_book_id: ID,
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
            if (price_tree::level_is_empty(level)) break;
            let head_key = price_tree::level_front_order_id(level).destroy_some();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = order::remaining_size(price_tree::level_borrow_order(level, head_key));
            let fill_qty = std::u64::min(*remaining_size, maker_remaining);
            let quote_cost = checked_mul_u64(best_price, fill_qty);

            let mut maker_order = price_tree::level_remove_order(level, head_key);
            order::decrease_remaining_size(&mut maker_order, fill_qty);
            let mut quote_out = order::split_escrow_quote(&mut maker_order, quote_cost);
            let maker_fee_bps = order::maker_fee_bps(&maker_order);
            let maker_addr = order::owner(&maker_order);
            let maker_order_id = order::id(&maker_order);
            let maker_remaining_after = order::remaining_size(&maker_order);

            let taker_fee_quote = fee_amount(quote_cost, taker_fee_bps);
            let taker_fee_balance = balance::split(&mut quote_out, taker_fee_quote);
            matched_quote.join(quote_out); // remainder, net of taker fee

            let mut base_payment = balance::split(escrow_base, fill_qty);
            let maker_fee_base = fee_amount(fill_qty, maker_fee_bps);
            let maker_fee_balance = balance::split(&mut base_payment, maker_fee_base);
            credit_fee_accumulator(fees, maker_fee_balance, taker_fee_balance);
            credit_maker_table(proceeds, maker_order_id, maker_addr, base_payment, balance::zero<Quote>());

            event::emit(OrderFilled {
                maker_order_id,
                order_book_id: event_book_id,
                price: best_price,
                size: fill_qty,
                maker: maker_addr,
                taker,
            });

            *remaining_size = *remaining_size - fill_qty;

            if (maker_remaining_after == 0) {
                let (eb, eq) = order::destroy(maker_order);
                destroy_drained_bid_escrow(eb, eq);
            } else {
                price_tree::level_insert_order_front(level, head_key, maker_order);
            };
        };
        is_empty_now = price_tree::level_is_empty(level);
    };
    if (is_empty_now) {
        let removed = price_tree::remove(bids, leaf_ptr);
        price_tree::destroy_empty_price_level(removed);
    };
    (stop, hit_max_fills)
}

fun match_ask<Base, Quote>(
    bids: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    fees: &mut FeeAccumulator<Base, Quote>,
    taker_fee_bps: u64,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    escrow_base_in: Balance<Base>,
    taker: address,
    event_book_id: ID,
    max_fills: u64,
): (Balance<Quote>, Balance<Base>, u64, bool) {
    let mut remaining_size = remaining_size_in;
    let mut escrow_base = escrow_base_in;
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
            &mut escrow_base,
            &mut matched_quote,
            taker,
            event_book_id,
            &mut fills_consumed,
            max_fills,
            taker_fee_bps,
        );
        if (hit_max_fills) stopped_on_max_fills_while_crossing = true;
        if (stop) break;
    };

    (matched_quote, escrow_base, remaining_size, stopped_on_max_fills_while_crossing)
}

// === OrderTicket ===

/// `store` only, deliberately no `key`: a plain, immutable, non-object
/// value — never independently shareable via `transfer::share_object`.
public struct OrderTicket has store {
    order_id: u64,
    /// Bound at minting time to the book's own immutable object id
    /// (`object::uid_to_inner(&book.id)`), NOT to `book.event_id`. This
    /// makes it unforgeable regardless of what `event_id_override` a book
    /// was constructed with — `event_id` is caller-controllable and must
    /// never be used to authenticate a ticket. `cancel_order` and
    /// `update_resting_order` check this field against
    /// `object::uid_to_inner(&book.id)` to reject a ticket minted by a
    /// different book.
    order_book_id: ID,
    side: bool,
    price: u64,
}

public fun ticket_order_id(t: &OrderTicket): u64 {
    t.order_id
}

public fun ticket_order_book_id(t: &OrderTicket): ID {
    t.order_book_id
}

public fun ticket_side(t: &OrderTicket): bool {
    t.side
}

public fun ticket_price(t: &OrderTicket): u64 {
    t.price
}

/// Unconditional disposal — no liveness check of its own. Package-private:
/// safe only because its sole caller, `claim_proceeds`, guarantees by
/// construction that `book.proceeds` holds no entry for this ticket's
/// `order_id` before calling this (it has just drained that entry via
/// `claim_maker_balance`). Any other caller must use the guarded public
/// `destroy_orphaned_ticket` below instead.
public(package) fun destroy_orphaned_ticket_unchecked(ticket: OrderTicket) {
    let OrderTicket { order_id: _, order_book_id: _, side: _, price: _ } = ticket;
}

/// Guarded disposal: aborts with `EWrongBook` if `ticket` wasn't minted by
/// `book`, and with `EProceedsNotEmpty` if `book.proceeds` still holds an
/// entry for this ticket's `order_id` — destroying the ticket in that case
/// would permanently strand those pooled funds, since nothing else can ever
/// reference that `order_id` again. Deliberately does NOT check whether the
/// order is still resting: destroying a ticket for a still-resting order
/// with zero pooled proceeds is a legitimate caller choice (e.g. abandoning
/// a dust order); the only actual safety invariant is "would this strand
/// funds."
public fun destroy_orphaned_ticket<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    ticket: OrderTicket,
) {
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    assert!(!linked_table::contains(&book.proceeds, ticket.order_id), EProceedsNotEmpty);
    destroy_orphaned_ticket_unchecked(ticket);
}

// === Order placement, cancellation, and proceeds claiming ===

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

/// `price` is quote-atoms per base-atom (e.g. atomic USDC per atomic SUI),
/// never a human-readable quote-per-base decimal ratio. When
/// `quote_decimals < base_decimals`, the smallest expressible `price` is
/// `10^(base_decimals - quote_decimals)` quote-atoms per base-atom; if that
/// granularity is coarser than the pair's economically meaningful price
/// resolution, this book cannot usefully quote it. Integrators should either
/// reject such pairs at wrapper-construction time or pre-scale `price`/`size`
/// themselves before calling in. See the `OrderBook` struct doc comment.
public fun place_limit_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    price: u64,
    size: u64,
    mut payment: Coin<Quote>,
    max_fills: u64,
    ctx: &mut TxContext,
): (OrderTicket, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    assert!(price != 0, EZeroPrice);
    validate_size(book, size);

    let escrow_amount = bid_escrow_amount(price, size);
    let mut escrow = coin::into_balance(coin::split(&mut payment, escrow_amount, ctx));

    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_base, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, option::some(price), size, escrow, taker, event_book_id, max_fills);
    escrow = remaining_escrow;

    let order_id = next_order_id(book);
    let should_rest = remaining_size > 0 && !stopped_on_max_fills_while_crossing;
    if (should_rest) {
        let resting_escrow_amount = bid_escrow_amount(price, remaining_size);
        let resting_escrow = balance::split(&mut escrow, resting_escrow_amount);
        coin::join(&mut payment, coin::from_balance(escrow, ctx));
        // Snapshot the book's *current* maker-fee rate at the exact moment
        // this resting order is constructed; later fee-rate changes never
        // retroactively affect an already-resting order.
        let maker_fee_bps_snapshot = maker_fee_bps(book);
        let resting = order::new(
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
            order_book_id: event_book_id,
            side: true,
            price,
            size: remaining_size,
            trader: taker,
        });
    } else {
        coin::join(&mut payment, coin::from_balance(escrow, ctx));
    };

    let ticket = OrderTicket {
        order_id,
        order_book_id: object::uid_to_inner(&book.id),
        side: true,
        price,
    };
    (ticket, coin::from_balance(matched_base, ctx), payment, stopped_on_max_fills_while_crossing)
}

/// `price` is quote-atoms per base-atom, not a human-readable quote-per-base
/// decimal ratio; see `place_limit_order_bid`'s doc comment for the full
/// note on price granularity when `quote_decimals < base_decimals`.
public fun place_limit_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    price: u64,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    ctx: &mut TxContext,
): (OrderTicket, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    assert!(price != 0, EZeroPrice);
    validate_size(book, size);

    let escrow_base = coin::into_balance(coin::split(&mut payment, size, ctx));

    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, option::some(price), size, escrow_base, taker, event_book_id, max_fills);

    let order_id = next_order_id(book);
    let should_rest = remaining_size > 0 && !stopped_on_max_fills_while_crossing;
    if (should_rest) {
        // Snapshot the book's *current* maker-fee rate at the exact moment
        // this resting order is constructed; later fee-rate changes never
        // retroactively affect an already-resting order.
        let maker_fee_bps_snapshot = maker_fee_bps(book);
        let resting = order::new(
            order_id,
            taker,
            remaining_size,
            option::some(remaining_escrow),
            option::none(),
            maker_fee_bps_snapshot,
        );
        insert_resting_order(book, false, price, resting, ctx);
        event::emit(OrderPlaced {
            order_id,
            order_book_id: event_book_id,
            side: false,
            price,
            size: remaining_size,
            trader: taker,
        });
    } else {
        coin::join(&mut payment, coin::from_balance(remaining_escrow, ctx));
    };

    let ticket = OrderTicket {
        order_id,
        order_book_id: object::uid_to_inner(&book.id),
        side: false,
        price,
    };
    (ticket, payment, coin::from_balance(matched_quote, ctx), stopped_on_max_fills_while_crossing)
}

public fun place_market_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    budget: u64,
    mut payment: Coin<Quote>,
    max_fills: u64,
    max_quote_in: Option<u64>,
    min_base_out: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, size);

    let budget_balance = coin::into_balance(coin::split(&mut payment, budget, ctx));
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_base, remaining_budget, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, option::none(), size, budget_balance, taker, event_book_id, max_fills);

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

public fun place_market_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    min_quote_out: Option<u64>,
    max_base_in: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, size);

    let escrow_base = coin::into_balance(coin::split(&mut payment, size, ctx));
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, option::none(), size, escrow_base, taker, event_book_id, max_fills);

    if (max_base_in.is_some()) {
        let base_spent = size - balance::value(&remaining_escrow);
        assert!(base_spent <= *max_base_in.borrow(), ESlippageExceeded);
    };
    if (min_quote_out.is_some()) {
        assert!(balance::value(&matched_quote) >= *min_quote_out.borrow(), ESlippageExceeded);
    };

    coin::join(&mut payment, coin::from_balance(remaining_escrow, ctx));
    (payment, coin::from_balance(matched_quote, ctx), stopped_on_max_fills_while_crossing)
}

public fun swap_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
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
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, size);

    let budget_balance = coin::into_balance(coin::split(&mut payment, budget, ctx));
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_base, remaining_budget, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, limit_price, size, budget_balance, taker, event_book_id, max_fills);

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
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    limit_price: Option<u64>,
    min_quote_out: Option<u64>,
    max_base_in: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, size);

    let escrow_base = coin::into_balance(coin::split(&mut payment, size, ctx));
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, limit_price, size, escrow_base, taker, event_book_id, max_fills);

    if (max_base_in.is_some()) {
        let base_spent = size - balance::value(&remaining_escrow);
        assert!(base_spent <= *max_base_in.borrow(), ESlippageExceeded);
    };
    if (min_quote_out.is_some()) {
        assert!(balance::value(&matched_quote) >= *min_quote_out.borrow(), ESlippageExceeded);
    };

    coin::join(&mut payment, coin::from_balance(remaining_escrow, ctx));
    (payment, coin::from_balance(matched_quote, ctx), stopped_on_max_fills_while_crossing)
}

/// Neither `cancel_order` nor `claim_proceeds` checks whether the book is
/// paused: pausing only blocks new order placement, it never blocks a
/// trader from recovering funds already at rest.
public fun cancel_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: OrderTicket,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    let event_book_id = book.event_id;
    let OrderTicket { order_id, order_book_id: _, side, price } = ticket;

    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let order_opt = price_tree::find_and_remove_order(tree, price, order_id);

    let (mut escrow_base, mut escrow_quote) = if (order_opt.is_none()) {
        order_opt.destroy_none();
        (option::none(), option::none())
    } else {
        let live_order = order_opt.destroy_some();
        let trader = order::owner(&live_order);
        let (eb, eq) = order::destroy(live_order);
        event::emit(OrderCancelled { order_id, order_book_id: event_book_id, trader });
        (eb, eq)
    };

    let (_owner, proceeds_base, proceeds_quote) = claim_maker_balance(book, order_id);
    let proceeds_base_amount = balance::value(&proceeds_base);
    let proceeds_quote_amount = balance::value(&proceeds_quote);

    let mut base_balance = if (escrow_base.is_some()) {
        let b = escrow_base.extract();
        escrow_base.destroy_none();
        b
    } else {
        escrow_base.destroy_none();
        balance::zero<Base>()
    };
    base_balance.join(proceeds_base);

    let mut quote_balance = if (escrow_quote.is_some()) {
        let q = escrow_quote.extract();
        escrow_quote.destroy_none();
        q
    } else {
        escrow_quote.destroy_none();
        balance::zero<Quote>()
    };
    quote_balance.join(proceeds_quote);

    if (proceeds_base_amount != 0 || proceeds_quote_amount != 0) {
        event::emit(ProceedsClaimed {
            claimant: ctx.sender(),
            order_book_id: event_book_id,
            base_amount: proceeds_base_amount,
            quote_amount: proceeds_quote_amount,
        });
    };

    let base_coin = coin_or_zero(base_balance, ctx);
    let quote_coin = coin_or_zero(quote_balance, ctx);
    (base_coin, quote_coin)
}

/// Finds the resting order identified by `ticket` and overwrites its
/// `owner` field in place. Returns `true` if an order was found and
/// updated, `false` if the price level or the order itself doesn't exist (a
/// no-op, mirroring `cancel_order`'s own not-found-is-a-no-op handling).
///
/// Permissionless, but not unauthenticated: authority to redirect an order's
/// proceeds destination follows `OrderTicket` possession, exactly
/// like cancellation authority does via `cancel_order` (`ticket` is taken by
/// reference here, so the caller keeps it and can still cancel afterward).
/// Both authorities now live in the same place — whoever holds the ticket —
/// so there is no split-authority footgun between "who can cancel" and "who
/// can redirect proceeds." `owner` is also the refund destination
/// `clob_admin_cancel_order` and the `clob_admin_drain_step` retirement
/// drain send the order's *escrow principal* to (not merely future fill
/// proceeds via `credit_maker_table`), so reassigning it is a real
/// redirection of that order's funds, not just a bookkeeping label — treat
/// it with the same care as `push_proceeds`. Proceeds are pooled per
/// `order_id` in a single maker-table ledger entry, and `credit_maker_table`
/// re-stamps that entry's payout `owner` on every credit, not just the
/// first. This function also immediately and unconditionally syncs the
/// `owner` of any already-pooled `MakerBalance` entry for this `order_id`
/// (via `sync_maker_balance_owner`) at the moment of reassignment — not
/// merely on a future fill. That means this function's reassignment reaches
/// the order's *entire* currently-pooled unclaimed proceeds balance for that
/// `order_id` — both proceeds already credited before the reassignment and
/// any credited afterward — immediately, whether or not the order is ever
/// filled again: `push_proceeds` / `drain_proceeds` always pay whoever is
/// currently stamped as owner, which this function keeps current. This is
/// intentional, since it remains the ticket holder's own choice about their
/// own order's funds.
///
/// Note: a bare `transfer::public_transfer` of the `OrderTicket` object
/// itself (bypassing this function) cannot be observed or synced by any
/// on-chain code — `OrderTicket` has no `key` ability and is never an owned
/// object in the usual sense, but if a wrapping integrator type does make
/// ticket custody transferable outside of calling this function, this
/// module has no way to know. `push_proceeds`/`drain_proceeds` therefore
/// remain a best-effort payout to the last address recorded via
/// `update_resting_order`, not a guarantee of payment to the ticket's true
/// current holder if custody changed by other means.
public fun update_resting_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: &OrderTicket,
    new_owner: address,
): bool {
    assert_book_version(book);
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    let side = ticket.side;
    let price = ticket.price;
    let order_id = ticket.order_id;
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let leaf_opt = price_tree::find(tree, price);
    if (leaf_opt.is_none()) {
        return false
    };
    let leaf_ptr = leaf_opt.destroy_some();
    let found = {
        let level = price_tree::borrow_mut(tree, leaf_ptr);
        if (!price_tree::level_contains_order(level, order_id)) {
            false
        } else {
            price_tree::level_set_order_owner(level, order_id, new_owner);
            true
        }
    };
    if (found) {
        sync_maker_balance_owner(&mut book.proceeds, order_id, new_owner);
    };
    found
}

/// Ticket-gated: any accumulated proceeds for `ticket`'s `order_id` are paid
/// out to the caller (`ctx.sender()`), regardless of the `owner` address
/// recorded in the ledger entry (mirroring `cancel_order`'s existing
/// pay-the-caller convention, not the stored owner) — authority to claim
/// follows `OrderTicket` possession, exactly like cancellation authority.
///
/// If the order identified by `ticket` is still resting on the book, the
/// ticket is handed back (`option::some`) so it can be used for future
/// claims or eventual cancellation. If the order is no longer resting
/// (fully filled and removed, or never found), nothing more can ever be
/// claimed through this ticket, so it is destroyed and `option::none()` is
/// returned instead.
public fun claim_proceeds<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: OrderTicket,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, Option<OrderTicket>) {
    assert_book_version(book);
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    let order_id = ticket.order_id;
    let side = ticket.side;
    let price = ticket.price;

    let claimant = ctx.sender();
    let event_book_id = book.event_id;
    let (_owner, base, quote) = claim_maker_balance(book, order_id);
    let base_amount = balance::value(&base);
    let quote_amount = balance::value(&quote);

    let base_coin = coin_or_zero(base, ctx);
    let quote_coin = coin_or_zero(quote, ctx);

    if (base_amount != 0 || quote_amount != 0) {
        event::emit(ProceedsClaimed { claimant, order_book_id: event_book_id, base_amount, quote_amount });
    };

    let tree: &PriceTree<PriceLevel<Base, Quote>> = if (side) &book.bids else &book.asks;
    let leaf_opt = price_tree::find(tree, price);
    let still_resting = if (leaf_opt.is_none()) {
        false
    } else {
        let leaf_ptr = leaf_opt.destroy_some();
        let level = price_tree::borrow(tree, leaf_ptr);
        price_tree::level_contains_order(level, order_id)
    };

    if (still_resting) {
        (base_coin, quote_coin, option::some(ticket))
    } else {
        destroy_orphaned_ticket_unchecked(ticket);
        (base_coin, quote_coin, option::none())
    }
}

/// Admin-gated convenience/rescue function: pays out a specific order's
/// accumulated proceeds. Requires the book's `ClobAdminCap`. As
/// defense-in-depth, the destination address is never caller-supplied — it
/// is always whatever `owner` was recorded against `order_id` in the
/// proceeds ledger at credit time (see `credit_maker_table`), so even the
/// admin can only trigger payout to the legitimately recorded owner and can
/// never redirect funds elsewhere.
public fun push_proceeds<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    order_id: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let event_book_id = book.event_id;
    let (owner, base, quote) = claim_maker_balance(book, order_id);
    let base_amount = balance::value(&base);
    let quote_amount = balance::value(&quote);
    if (base_amount == 0 && quote_amount == 0) {
        balance::destroy_zero(base);
        balance::destroy_zero(quote);
        return
    };
    transfer_or_destroy_zero(base, owner, ctx);
    transfer_or_destroy_zero(quote, owner, ctx);
    event::emit(ProceedsClaimed { claimant: owner, order_book_id: event_book_id, base_amount, quote_amount });
}

// === Test-only accessors ===

#[test_only]
public fun bid_for_testing(): bool { true }

#[test_only]
public fun ask_for_testing(): bool { false }

#[test_only]
public fun clob_admin_cap_id_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): ID {
    book.clob_admin_cap_id
}

#[test_only]
public fun bids_size_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    price_tree::size(&book.bids)
}

/// The book's own object id, derived from its `id: UID` field directly
/// (`object::id` requires `key`, which this struct deliberately does not
/// have — see the struct's own doc comment above).
#[test_only]
public fun id_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): ID {
    object::uid_to_inner(&book.id)
}

/// Exposes this module's own internal insertion path (`insert_resting_order`
/// — the same path every real placement function uses to rest an order) so
/// a test can seed an arbitrary resting `Order` at a given `side`/`price`
/// without going through a full `place_limit_order_*` call.
#[test_only]
public fun insert_resting_order_for_testing<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order: Order<Base, Quote>,
    ctx: &mut TxContext,
) {
    insert_resting_order(book, side, price, order, ctx);
}

#[test_only]
public fun credit_fee_accumulator_for_testing<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    let fees = &mut book.fee_accumulator;
    credit_fee_accumulator(fees, base, quote);
}

#[test_only]
public fun for_book_for_testing(cap: &ClobAdminCap): ID {
    cap.for_book
}

#[test_only]
public fun book_version_is_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>, expected: u64): bool {
    book.version == expected
}

/// Test-only escape hatch to force a book's `version` field directly, so
/// tests can simulate a lagging (`< CURRENT_VERSION`) or future-package
/// (`> CURRENT_VERSION`) book without any production-reachable way to do so
/// — real callers only ever observe `version` moving via `assert_book_version`'s
/// own auto-upgrade.
#[test_only]
public fun set_book_version_for_testing<Base, Quote>(book: &mut OrderBook<Base, Quote>, new_version: u64) {
    book.version = new_version;
}

#[test_only]
public fun proceeds_contains_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>, order_id: u64): bool {
    linked_table::contains(&book.proceeds, order_id)
}

#[test_only]
public fun clob_admin_cap_discarded_fields_for_testing(e: &ClobAdminCapDiscarded): (ID, ID) {
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
public fun event_id_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): ID { book.event_id }

#[test_only]
public fun book_version_upgraded_fields_for_testing(e: &BookVersionUpgraded): (ID, u64, u64) {
    (e.book_id, e.from, e.to)
}

#[test_only]
public fun fees_claimed_fields_for_testing(e: &FeesClaimed): (address, ID, u64, u64) {
    (e.claimant, e.order_book_id, e.base_amount, e.quote_amount)
}

#[test_only]
public fun order_cancelled_fields_for_testing(e: &OrderCancelled): (u64, ID, address) {
    (e.order_id, e.order_book_id, e.trader)
}

#[test_only]
public fun order_placed_fields_for_testing(e: &OrderPlaced): (u64, ID, bool, u64, u64, address) {
    (e.order_id, e.order_book_id, e.side, e.price, e.size, e.trader)
}

#[test_only]
public fun proceeds_claimed_fields_for_testing(e: &ProceedsClaimed): (address, ID, u64, u64) {
    (e.claimant, e.order_book_id, e.base_amount, e.quote_amount)
}

#[test_only]
public fun order_book_retired_fields_for_testing(e: &OrderBookRetired): ID { e.order_book_id }

#[test_only]
public fun order_book_deleted_fields_for_testing(e: &OrderBookDeleted): (ID, TypeName, TypeName) {
    (e.order_book_id, e.base, e.quote)
}

/// Test-only constructor: lets a test build an `OrderTicket` directly for
/// disposal-path testing, bypassing the placement functions that are the
/// only real way to obtain one.
///
/// NOTE (test-only, does not reflect the production invariant): the caller
/// supplies `order_book_id` directly here, which lets a test construct a
/// ticket carrying *any* id, including one that was never a real book's own
/// id. In production, every `OrderTicket`'s `order_book_id` is always
/// exactly the book's own object id (`object::uid_to_inner(&book.id)`),
/// fixed forever at the moment the ticket is minted — independent of
/// `event_id`/`event_id_override`, which is caller-controllable and used
/// solely for event stamping. Do not read this constructor's freedom to
/// pass an arbitrary id as evidence that production tickets can carry one
/// too.
#[test_only]
public fun new_ticket_for_testing(
    order_id: u64,
    order_book_id: ID,
    side: bool,
    price: u64,
): OrderTicket {
    OrderTicket { order_id, order_book_id, side, price }
}

#[test_only]
public fun ticket_fields_for_testing(t: &OrderTicket): (u64, ID, bool, u64) {
    (t.order_id, t.order_book_id, t.side, t.price)
}

#[test_only]
public fun order_filled_fields_for_testing(e: &OrderFilled): (u64, ID, u64, u64, address, address) {
    (e.maker_order_id, e.order_book_id, e.price, e.size, e.maker, e.taker)
}

/// Direct `match_bid` exposure, used by behavioral-equivalence tests that
/// need to drive the matching engine directly with an arbitrary (not
/// escrow-derived) `payment`.
#[test_only]
public fun match_bid_for_testing<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    payment: Coin<Quote>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, u64, bool) {
    let taker = ctx.sender();
    let event_book_id = book.event_id;
    let budget = coin::into_balance(payment);
    let taker_fee_bps = book.taker_fee_bps;
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_base, remaining_budget, remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, limit_price, remaining_size_in, budget, taker, event_book_id, max_fills);
    (
        coin::from_balance(matched_base, ctx),
        coin::from_balance(remaining_budget, ctx),
        remaining_size,
        stopped_on_max_fills_while_crossing,
    )
}

/// Direct `match_ask` exposure — symmetric counterpart to
/// `match_bid_for_testing` above.
#[test_only]
public fun match_ask_for_testing<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    payment: Coin<Base>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Coin<Quote>, Coin<Base>, u64, bool) {
    let taker = ctx.sender();
    let event_book_id = book.event_id;
    let escrow_base = coin::into_balance(payment);
    let taker_fee_bps = book.taker_fee_bps;
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, limit_price, remaining_size_in, escrow_base, taker, event_book_id, max_fills);
    (
        coin::from_balance(matched_quote, ctx),
        coin::from_balance(remaining_escrow, ctx),
        remaining_size,
        stopped_on_max_fills_while_crossing,
    )
}

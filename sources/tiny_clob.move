/// `OrderBook<Base, Quote>` — a price-time-priority limit order book meant
/// to be embedded as a field inside an integrator's own object, rather than
/// registered as a shared, standalone object. Provides limit and market
/// order placement, cancellation, matching, maker-fee proceeds tracking,
/// clob-admin-gated fee/pause controls, and a clob_admin_retire/drain/clob_admin_finalize
/// deletion lifecycle.
module tiny_clob::tiny_clob;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::linked_table::{Self, LinkedTable};
use std::type_name::{Self, TypeName};
use tiny_clob::price_tree::{Self, PriceTree};

// === Error constants ===

const EZeroLotSize: u64 = 0;
const EZeroMinSize: u64 = 1;
const EMinSizeNotMultipleOfLotSize: u64 = 2;
const ELotOrMinSizeTooLarge: u64 = 3;
const EWrongClobAdminCap: u64 = 4;
const ENewVersionMismatch: u64 = 5;
const ENotRetiring: u64 = 6;
const ENotFullyDrained: u64 = 7;
const ETakerFeeRateTooHigh: u64 = 8;
const EMakerFeeRateTooHigh: u64 = 9;
const EStaleObjectVersion: u64 = 10;
const ESizeNotMultipleOfLotSize: u64 = 11;
const ESizeBelowMinSize: u64 = 12;
/// A `price * size`-style multiplication's `u128` intermediate exceeded
/// `u64::MAX`.
const EPriceSizeOverflow: u64 = 13;
const EZeroPrice: u64 = 14;
const EBookPaused: u64 = 15;
const EWrongBook: u64 = 16;
const ESlippageExceeded: u64 = 17;

const MAX_TAKER_FEE_BPS: u64 = 10;
const MAX_MAKER_FEE_BPS: u64 = 5;
const MAX_LOT_OR_MIN_SIZE: u64 = 1_000_000_000_000_000;
const U64_MAX: u128 = 0xFFFFFFFFFFFFFFFF;

/// Bumped whenever a published version of this package introduces a
/// breaking change to `OrderBook`'s on-chain layout or semantics; existing
/// books must be migrated via `clob_admin_migrate_book_version` before they can
/// be used again.
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

/// A resting order held in a price level's FIFO queue.
public struct Order<phantom Base, phantom Quote> has store {
    order_id: u64,
    owner: address,
    remaining_size: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
}

/// One price level's FIFO queue of resting orders.
public struct PriceLevel<phantom Base, phantom Quote> has store {
    orders: LinkedTable<u64, Order<Base, Quote>>,
}

/// A maker's claimable-but-unclaimed proceeds ledger entry.
public struct MakerBalance<phantom Base, phantom Quote> has store {
    base: Balance<Base>,
    quote: Balance<Quote>,
}

/// Per-book accumulator of collected taker/maker fees.
public struct FeeAccumulator<phantom Base, phantom Quote> has store {
    base: Balance<Base>,
    quote: Balance<Quote>,
}

public(package) fun new_order<Base, Quote>(
    order_id: u64,
    owner: address,
    remaining_size: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
): Order<Base, Quote> {
    Order { order_id, owner, remaining_size, escrow_base, escrow_quote, maker_fee_bps }
}

public(package) fun order_decrease_remaining_size<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64) {
    o.remaining_size = o.remaining_size - amount;
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
    let Order { order_id: _, owner: _, remaining_size: _, escrow_base, escrow_quote, maker_fee_bps: _ } = o;
    (escrow_base, escrow_quote)
}

public(package) fun new_price_level<Base, Quote>(ctx: &mut TxContext): PriceLevel<Base, Quote> {
    PriceLevel { orders: linked_table::new(ctx) }
}

public(package) fun destroy_empty_price_level<Base, Quote>(level: PriceLevel<Base, Quote>) {
    let PriceLevel { orders } = level;
    linked_table::destroy_empty(orders);
}

public(package) fun sum_price_level<Base, Quote>(level: &PriceLevel<Base, Quote>): u64 {
    let mut total = 0;
    if (level.orders.is_empty()) {
        return total
    };
    let mut cursor = *level.orders.front();
    while (cursor.is_some()) {
        let order_id = *cursor.borrow();
        let order = level.orders.borrow(order_id);
        total = total + order.remaining_size;
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

public(package) fun destroy_fee_accumulator<Base, Quote>(
    fees: FeeAccumulator<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    let FeeAccumulator { base, quote } = fees;
    (base, quote)
}

public(package) fun credit_fee_accumulator<Base, Quote>(
    fees: &mut FeeAccumulator<Base, Quote>,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    fees.base.join(base);
    fees.quote.join(quote);
}

// === OrderBook<Base, Quote> ===

/// The only deliberate structural quirk relative to a naive book layout: there
/// is no separate `retiring: bool` field — `paused` serves both the local
/// soft-pause flag and the deletion-lifecycle "has `clob_admin_retire` been called"
/// gate. This means `clob_admin_unpause_book` also un-retires a book that
/// was mid-retirement; a caller that relies on `clob_admin_retire` being irreversible
/// must track that separately.
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
    lot_size: u64,
    min_size: u64,
    bids: PriceTree<PriceLevel<Base, Quote>>,
    asks: PriceTree<PriceLevel<Base, Quote>>,
    proceeds: LinkedTable<address, MakerBalance<Base, Quote>>,
    paused: bool,
    next_order_id: u64,
    clob_admin_cap_id: ID,
    version: u64,
    taker_fee_bps: u64,
    maker_fee_bps: u64,
    fee_accumulator: FeeAccumulator<Base, Quote>,
    /// The id every event this module emits (and every `OrderTicket` it
    /// mints) stamps as `order_book_id`. Write-once: fixed at construction
    /// time by `new`'s `event_id_override` parameter (defaults to the
    /// book's own internal id when `option::none()` is passed) and never
    /// mutable afterward. A wrapping object whose own outer id is what
    /// external callers/indexers actually query by should pass that id in
    /// via `option::some(id)` at construction time instead.
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

/// No liveness check: the book keeps functioning normally after its cap is
/// discarded — this only gives up the ability to administer it.
public fun discard_clob_admin_cap(cap: ClobAdminCap) {
    let ClobAdminCap { id, for_book } = cap;
    let cap_id = object::uid_to_inner(&id);
    object::delete(id);
    event::emit(ClobAdminCapDiscarded { cap_id, for_book });
}

// === Constructor ===

/// Callable by any address — no capability is required to create a book,
/// and it is never registered anywhere by this call.
public fun new<Base, Quote>(
    lot_size: u64,
    min_size: u64,
    event_id_override: Option<ID>,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    assert!(lot_size != 0, EZeroLotSize);
    assert!(min_size != 0, EZeroMinSize);
    assert!(min_size % lot_size == 0, EMinSizeNotMultipleOfLotSize);
    assert!(lot_size <= MAX_LOT_OR_MIN_SIZE && min_size <= MAX_LOT_OR_MIN_SIZE, ELotOrMinSizeTooLarge);

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
        lot_size,
        min_size,
        bids: price_tree::new(ctx),
        asks: price_tree::new(ctx),
        proceeds: linked_table::new(ctx),
        paused: false,
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

public(package) fun lot_size<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.lot_size
}

public(package) fun min_size<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.min_size
}

public(package) fun taker_fee_bps<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.taker_fee_bps
}

public(package) fun maker_fee_bps<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.maker_fee_bps
}

public(package) fun withdraw_fee_accumulator<Base, Quote>(
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

public(package) fun claim_maker_balance<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    addr: address,
): (Balance<Base>, Balance<Quote>) {
    if (!linked_table::contains(&book.proceeds, addr)) {
        return (balance::zero(), balance::zero())
    };
    let mb = linked_table::remove(&mut book.proceeds, addr);
    destroy_maker_balance(mb)
}

/// Public so an integrator wrapping this book can version-guard its own
/// call sites the same way this module's own functions do.
public fun assert_book_version<Base, Quote>(book: &OrderBook<Base, Quote>) {
    assert!(book.version == CURRENT_VERSION, EStaleObjectVersion);
}

/// Public — see `assert_book_version` above.
public fun set_book_version<Base, Quote>(book: &mut OrderBook<Base, Quote>, new_version: u64) {
    book.version = new_version;
}

// === Migration ===

public fun clob_admin_migrate_book_version<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    new_version: u64,
) {
    assert_clob_admin(cap, book);
    assert!(new_version == CURRENT_VERSION, ENewVersionMismatch);
    book.version = new_version;
}

// === Public view functions (no version-guard assertion) ===

public fun fee_config<Base, Quote>(book: &OrderBook<Base, Quote>): (u64, u64) {
    (book.taker_fee_bps, book.maker_fee_bps)
}

public fun fee_accumulator_balances<Base, Quote>(book: &OrderBook<Base, Quote>): (u64, u64) {
    (balance::value(&book.fee_accumulator.base), balance::value(&book.fee_accumulator.quote))
}

public fun is_book_paused<Base, Quote>(book: &OrderBook<Base, Quote>): bool {
    book.paused
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
    sum_price_level(level)
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
    let id = book.event_id;
    book.paused = true;
    event::emit(Paused { order_book_id: id });
}

public fun clob_admin_unpause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let id = book.event_id;
    book.paused = false;
    event::emit(Unpaused { order_book_id: id });
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
    let id = book.event_id;
    book.taker_fee_bps = rate_bps;
    event::emit(TakerFeeSet { order_book_id: id, rate_bps });
}

public fun clob_admin_set_maker_fee<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    rate_bps: u64,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(rate_bps <= MAX_MAKER_FEE_BPS, EMakerFeeRateTooHigh);
    let id = book.event_id;
    book.maker_fee_bps = rate_bps;
    event::emit(MakerFeeSet { order_book_id: id, rate_bps });
}

public fun clob_admin_claim_fees<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let book_id = book.event_id;
    let claimant = ctx.sender();
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
    let book_id = book.event_id;
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let leaf_opt = price_tree::find(tree, price);
    if (leaf_opt.is_none()) { return };
    let leaf_ptr = leaf_opt.destroy_some();

    let (found, owner, escrow_base, escrow_quote, level_now_empty) = {
        let level = price_tree::borrow_mut(tree, leaf_ptr);
        let orders = &mut level.orders;
        if (orders.contains(order_id)) {
            let live_order = orders.remove(order_id);
            let owner = live_order.owner;
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
    let id = book.event_id;
    book.paused = true;
    event::emit(OrderBookRetired { order_book_id: id });
}

public fun clob_admin_drain_step<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    max_items: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(book.paused, ENotRetiring);
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
            let orders = &mut level.orders;
            loop {
                if (*remaining == 0) break;
                if (orders.is_empty()) break;
                let (_, order) = orders.pop_front();
                let owner = order.owner;
                let (escrow_base, escrow_quote) = destroy_order(order);
                refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
                *remaining = *remaining - 1;
            };
            is_empty_now = level.orders.is_empty();
        };
        if (is_empty_now) {
            let removed = price_tree::remove(tree, leaf_ptr);
            destroy_empty_price_level(removed);
        };
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

public fun clob_admin_finalize<Base, Quote>(
    cap: &ClobAdminCap,
    book: OrderBook<Base, Quote>,
): ID {
    assert_book_version(&book);
    assert_clob_admin(cap, &book);
    assert!(book.paused, ENotRetiring);
    assert!(
        price_tree::size(&book.bids) == 0 && price_tree::size(&book.asks) == 0 && book.proceeds.is_empty(),
        ENotFullyDrained,
    );

    let OrderBook {
        id, lot_size: _, min_size: _, bids, asks, proceeds,
        paused: _, next_order_id: _, clob_admin_cap_id: _, version: _,
        taker_fee_bps: _, maker_fee_bps: _, fee_accumulator, event_id,
    } = book;
    let book_id = event_id;
    price_tree::destroy_empty(bids);
    price_tree::destroy_empty(asks);
    linked_table::destroy_empty(proceeds);
    let (base, quote) = destroy_fee_accumulator(fee_accumulator);
    balance::destroy_zero(base);
    balance::destroy_zero(quote);
    object::delete(id);

    event::emit(OrderBookDeleted {
        order_book_id: book_id,
        base: type_name::with_defining_ids<Base>(),
        quote: type_name::with_defining_ids<Quote>(),
    });
    book_id
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
/// `Base`-atomic-units; a bid's escrow is this amount of `Quote`.
public fun bid_escrow_amount(price: u64, size: u64): u64 {
    checked_mul_u64(price, size)
}

fun checked_mul_u64(a: u64, b: u64): u64 {
    let product = (a as u128) * (b as u128);
    assert!(product <= U64_MAX, EPriceSizeOverflow);
    product as u64
}

/// `receive_amount * rate_bps / 10_000`, computed via a `u128` intermediate.
/// No explicit overflow check is needed: `rate_bps` is bounds-checked to at
/// most `MAX_TAKER_FEE_BPS`/`MAX_MAKER_FEE_BPS` before it can ever reach this
/// function, so the maximum possible product is far below `u128::MAX`. Floor
/// division.
fun fee_amount(receive_amount: u64, rate_bps: u64): u64 {
    (((receive_amount as u128) * (rate_bps as u128)) / 10_000) as u64
}

fun validate_size_raw(lot_size: u64, min_size: u64, size: u64) {
    assert!(size % lot_size == 0, ESizeNotMultipleOfLotSize);
    assert!(size >= min_size, ESizeBelowMinSize);
}

fun validate_size<Base, Quote>(book: &OrderBook<Base, Quote>, size: u64) {
    validate_size_raw(lot_size(book), min_size(book), size);
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
    let order_id = order.order_id;
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let existing = price_tree::find(tree, price);
    if (existing.is_some()) {
        let leaf_ptr = existing.destroy_some();
        let level = price_tree::borrow_mut(tree, leaf_ptr);
        (&mut level.orders).push_back(order_id, order);
    } else {
        existing.destroy_none();
        let mut level = new_price_level<Base, Quote>(ctx);
        (&mut level.orders).push_back(order_id, order);
        price_tree::insert(tree, price, level);
    };
}

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
                &mut level.orders;
            if (orders.is_empty()) break;
            let head_key = *orders.front().borrow();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = orders.borrow(head_key).remaining_size;
            let natural_fill_qty = std::u64::min(*remaining_size, maker_remaining);
            let affordable_qty = balance::value(budget) / best_price;
            let fill_qty = std::u64::min(natural_fill_qty, affordable_qty);
            if (fill_qty == 0) {
                budget_exhausted = true;
                break
            };
            let quote_cost = checked_mul_u64(best_price, fill_qty);

            let maker_order_mut = orders.borrow_mut(head_key);
            order_decrease_remaining_size(maker_order_mut, fill_qty);
            let mut base_out = order_split_escrow_base(maker_order_mut, fill_qty);
            let maker_fee_bps = maker_order_mut.maker_fee_bps;
            let maker_addr = maker_order_mut.owner;
            let maker_order_id = maker_order_mut.order_id;
            let maker_remaining_after = maker_order_mut.remaining_size;

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
                size: fill_qty,
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
        is_empty_now = level.orders.is_empty();
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
    escrow_base: &mut Balance<Base>,
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
                &mut level.orders;
            if (orders.is_empty()) break;
            let head_key = *orders.front().borrow();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = orders.borrow(head_key).remaining_size;
            let fill_qty = std::u64::min(*remaining_size, maker_remaining);
            let quote_cost = checked_mul_u64(best_price, fill_qty);

            let maker_order_mut = orders.borrow_mut(head_key);
            order_decrease_remaining_size(maker_order_mut, fill_qty);
            let mut quote_out = order_split_escrow_quote(maker_order_mut, quote_cost);
            let maker_fee_bps = maker_order_mut.maker_fee_bps;
            let maker_addr = maker_order_mut.owner;
            let maker_order_id = maker_order_mut.order_id;
            let maker_remaining_after = maker_order_mut.remaining_size;

            let taker_fee_quote = fee_amount(quote_cost, taker_fee_bps);
            let taker_fee_balance = balance::split(&mut quote_out, taker_fee_quote);
            matched_quote.join(quote_out); // remainder, net of taker fee

            let mut base_payment = balance::split(escrow_base, fill_qty);
            let maker_fee_base = fee_amount(fill_qty, maker_fee_bps);
            let maker_fee_balance = balance::split(&mut base_payment, maker_fee_base);
            credit_fee_accumulator(fees, maker_fee_balance, taker_fee_balance);
            credit_maker_table(proceeds, maker_addr, base_payment, balance::zero<Quote>());

            event::emit(OrderFilled {
                maker_order_id,
                order_book_id: book_id,
                price: best_price,
                size: fill_qty,
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
        is_empty_now = level.orders.is_empty();
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
    escrow_base_in: Balance<Base>,
    taker: address,
    book_id: ID,
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
            book_id,
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

/// Unconditional disposal — no liveness check of its own; callers that need
/// to validate a ticket before dropping it must do so before calling this.
public fun destroy_orphaned_ticket(ticket: OrderTicket) {
    let OrderTicket { order_id: _, order_book_id: _, side: _, price: _ } = ticket;
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

    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_base, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, option::some(price), size, escrow, taker, book_id, max_fills);
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

    let ticket = OrderTicket {
        order_id,
        order_book_id: book_id,
        side: true,
        price,
    };
    (ticket, coin::from_balance(matched_base, ctx), payment, stopped_on_max_fills_while_crossing)
}

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

    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, option::some(price), size, escrow_base, taker, book_id, max_fills);

    let order_id = next_order_id(book);
    let should_rest = remaining_size > 0 && !stopped_on_max_fills_while_crossing;
    if (should_rest) {
        // Snapshot the book's *current* maker-fee rate at the exact moment
        // this resting order is constructed; later fee-rate changes never
        // retroactively affect an already-resting order.
        let maker_fee_bps_snapshot = maker_fee_bps(book);
        let resting = new_order(
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
            order_book_id: book_id,
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
        order_book_id: book_id,
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
): (Coin<Base>, Coin<Quote>, Coin<Quote>) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, size);

    let budget_balance = coin::into_balance(coin::split(&mut payment, budget, ctx));
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
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
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    min_quote_out: Option<u64>,
    max_base_in: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, size);

    let escrow_base = coin::into_balance(coin::split(&mut payment, size, ctx));
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, _remaining_size, _stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, option::none(), size, escrow_base, taker, book_id, max_fills);

    if (max_base_in.is_some()) {
        let base_spent = size - balance::value(&remaining_escrow);
        assert!(base_spent <= *max_base_in.borrow(), ESlippageExceeded);
    };
    if (min_quote_out.is_some()) {
        assert!(balance::value(&matched_quote) >= *min_quote_out.borrow(), ESlippageExceeded);
    };

    coin::join(&mut payment, coin::from_balance(remaining_escrow, ctx));
    (payment, coin::from_balance(matched_quote, ctx))
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
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
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
    let book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, limit_price, size, escrow_base, taker, book_id, max_fills);

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
    let book_id = book.event_id;
    assert!(ticket.order_book_id == book_id, EWrongBook);
    let OrderTicket { order_id, order_book_id: _, side, price } = ticket;

    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let leaf_opt = price_tree::find(tree, price);

    if (leaf_opt.is_none()) {
        return (coin::zero(ctx), coin::zero(ctx))
    };
    let leaf_ptr = leaf_opt.destroy_some();

    let (found_live, trader, escrow_base, escrow_quote, level_now_empty) = {
        let level = price_tree::borrow_mut(tree, leaf_ptr);
        let orders = &mut level.orders;
        if (orders.contains(order_id)) {
            let live_order = orders.remove(order_id);
            let owner = live_order.owner;
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

/// Finds the resting order at `(side, price, order_id)` and overwrites its
/// `owner` field in place. Returns `true` if an order was found and
/// updated, `false` if the price level or the order itself doesn't exist (a
/// no-op, mirroring `cancel_order`'s own not-found-is-a-no-op handling).
///
/// Deliberately does not call `assert_book_version` itself — a caller that
/// needs the version guard must perform it before calling in.
public fun update_resting_order_owner<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order_id: u64,
    new_owner: address,
): bool {
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let leaf_opt = price_tree::find(tree, price);
    if (leaf_opt.is_none()) {
        return false
    };
    let leaf_ptr = leaf_opt.destroy_some();
    let level = price_tree::borrow_mut(tree, leaf_ptr);
    let orders = &mut level.orders;
    if (!orders.contains(order_id)) {
        return false
    };
    let order = orders.borrow_mut(order_id);
    order.owner = new_owner;
    true
}

#[allow(lint(self_transfer))]
public fun claim_proceeds<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
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

/// Clob-admin-gated counterpart to `claim_proceeds`: force-pushes a
/// specific maker's accumulated proceeds to them instead of requiring the
/// maker to claim it themselves.
public fun clob_admin_push_proceeds<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    addr: address,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
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

#[test_only]
public fun proceeds_contains_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>, addr: address): bool {
    linked_table::contains(&book.proceeds, addr)
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
/// `event_id`. In production, every `OrderTicket`'s `order_book_id` is
/// always exactly whatever the book's `event_id` was fixed to at
/// construction. Do not read this constructor's freedom to pass an
/// arbitrary id as evidence that production tickets can carry one too.
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
    let book_id = book.event_id;
    let budget = coin::into_balance(payment);
    let taker_fee_bps = book.taker_fee_bps;
    let (asks, proceeds, fees) = (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_base, remaining_budget, remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(asks, proceeds, fees, taker_fee_bps, limit_price, remaining_size_in, budget, taker, book_id, max_fills);
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
    let book_id = book.event_id;
    let escrow_base = coin::into_balance(payment);
    let taker_fee_bps = book.taker_fee_bps;
    let (bids, proceeds, fees) = (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator);
    let (matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(bids, proceeds, fees, taker_fee_bps, limit_price, remaining_size_in, escrow_base, taker, book_id, max_fills);
    (
        coin::from_balance(matched_quote, ctx),
        coin::from_balance(remaining_escrow, ctx),
        remaining_size,
        stopped_on_max_fills_while_crossing,
    )
}

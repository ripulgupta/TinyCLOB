/// `OrderBook<Base, Quote>` — a price-time-priority limit order book meant
/// to be embedded as a field inside an integrator's own object, rather than
/// registered as a shared, standalone object. Provides limit and market
/// order placement, cancellation, matching, maker-fee proceeds tracking,
/// clob-admin-gated fee/pause controls, and a clob_admin_retire/drain/clob_admin_finalize
/// deletion lifecycle.
///
/// `price` throughout this module is a raw, book-relative unit, not a
/// human-readable decimal ratio: the true price is
/// `price / price_scale * 10^(base_decimals - quote_decimals)`, where
/// `price_scale` is derived at construction time from the book's declared
/// `base_decimals`/`quote_decimals`/`precision`/`exponent` (see `new`'s doc
/// comment and `price_scale`'s accessor). `precision`/`exponent` are the
/// book's declared guarantee on representable true-price resolution/range;
/// an optional `price_band_factor` (see `clob_admin_set_price_band_factor`)
/// is a further, independent safeguard bounding every placed order's `price`
/// to a factor of the book's `last_price`. `set_last_price` resets that
/// reference point and, unlike most controls in this module, requires no
/// capability at all.
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
const EZeroPrice: u64 = 14;
const EBookPaused: u64 = 15;
const EWrongBook: u64 = 16;
const ESlippageExceeded: u64 = 17;
const EBookRetiring: u64 = 18;
const EProceedsNotEmpty: u64 = 19;
/// A book's declared `base_decimals`/`quote_decimals`/`precision`/`exponent`
/// admit no valid `price_scale` at all (`scale_lo > scale_hi`), or the
/// tightest valid `price_scale` (`scale_lo`) itself cannot fit in a `u64` —
/// see `new`.
const EPriceRangeInfeasible: u64 = 20;
/// A `price` fell below the book's declared minimum representable true
/// price.
const EPriceBelowDeclaredMin: u64 = 21;
/// A `price` exceeded the book's declared maximum representable true price.
const EPriceAboveDeclaredMax: u64 = 22;
/// A `price` fell below `last_price / price_band_factor`.
const EPriceBelowBand: u64 = 23;
/// A `price` exceeded `last_price * price_band_factor`.
const EPriceAboveBand: u64 = 24;
/// `clob_admin_set_price_band_factor` was called with `Some(0)` — a
/// zero-valued factor can never bound any price and is always a caller
/// mistake.
const EZeroPriceBandFactor: u64 = 25;
/// `set_last_price` was called with a value below the book's
/// current best bid.
const EResetPriceBelowBestBid: u64 = 26;
/// `set_last_price` was called with a value above the book's
/// current best ask.
const EResetPriceAboveBestAsk: u64 = 27;
/// A decimals/precision/exponent argument to `new` exceeded `MAX_DECIMALS`.
const EDecimalsTooLarge: u64 = 28;
/// A `price` derived from `payment.value()`/`expected_base_output` (in
/// `place_limit_order_bid`) or from `expected_quote_output`/`size` (in
/// `place_limit_order_ask`) overflowed `u64` before it could be narrowed
/// down to `price: u64` -- a named, explicit failure instead of a bare
/// arithmetic-error abort on the narrowing cast.
const EPriceOverflow: u64 = 29;
/// `place_market_order_bid` was called with `min_base_out > max_base_out` --
/// both are Base-denominated, so this is an unsatisfiable request
/// regardless of the specific values (the slippage floor can never be met
/// without also exceeding the call's own declared cap), and is rejected
/// unconditionally up front rather than left to abort later, confusingly,
/// as a spurious `ESlippageExceeded`.
const EMinExceedsMaxBaseOut: u64 = 30;
/// `destroy_orphaned_ticket` was called for a ticket whose order is still
/// resting on the book -- destroying it would give up the ticket holder's
/// only self-service path back to that order's escrow while the order and
/// the book both still exist to reach it through. `destroy_ticket_unconditionally`
/// remains available once the book itself is gone (see its own doc comment).
const EOrderStillResting: u64 = 31;
/// Defensive-only: `new`'s `enclosing_object_id: &UID` parameter must
/// reference an object that already exists at call time, so it is provably
/// distinct from the book's own `UID`, which `new` mints fresh internally
/// (`object::new(ctx)`) after that parameter is bound — this can never
/// actually fire given how `new` is called. It exists purely to pin the
/// invariant defensively in case that structural guarantee is ever weakened
/// by a future refactor.
const EEnclosingIsSelf: u64 = 32;

/// `update_resting_order` routes funds through recorded-address payout paths
/// (escrow refunds, pooled proceeds sweeps) that would otherwise silently
/// burn to the zero address.
const EInvalidOwner: u64 = 33;

/// These caps must stay low enough that `ceil(x * bps / 10_000) < x` for
/// every `x > 1` — i.e. a leg worth more than 1 atom must never be fully
/// consumed by its own fee (see `fee_amount`'s doc comment, and the project's
/// audit notes, finding L-01). At today's values this is mathematically
/// impossible to violate for any `x > 1` (it would require `bps` close to
/// `10_000`), so no explicit clamp is implemented in `fee_amount` — this is
/// pure defense-in-depth. If either cap is ever raised meaningfully, revisit
/// `fee_amount` for an explicit clamp before shipping the change.
const MAX_TAKER_FEE_BPS: u64 = 10;
const MAX_MAKER_FEE_BPS: u64 = 5;
/// Basis-point denominator used by `fee_amount` (1 bps = 1 / 10_000).
const BPS_DENOM: u64 = 10_000;
const MAX_MIN_SIZE: u64 = 1_000_000_000_000_000;
const U64_MAX: u128 = 0xFFFFFFFFFFFFFFFF;

/// Upper bound on `base_decimals`/`quote_decimals`/`precision`/`exponent`.
/// Empirically verified: 10^38 squared fits comfortably inside `u256` (with
/// ~6.3x headroom given the true worst-case product
/// `price * pow_base * pow_prec` at `u64::MAX * 10^38 * 10^19`); 10^39
/// squared does not. IMPORTANT: this bound is safe ONLY in combination with
/// `assert_price_in_declared_range`'s independent enforcement (via the
/// `scale_lo`/`scale_hi` feasibility check in `new`) that
/// `precision + exponent` is effectively bounded well below `MAX_DECIMALS`
/// for any book that can actually be constructed — `MAX_DECIMALS = 38` alone,
/// without that coupling, would NOT be a safe bound against `u256` overflow
/// in `assert_price_in_declared_range`'s intermediate products.
const MAX_DECIMALS: u8 = 38;

/// Bumped whenever a published version of this package introduces a
/// breaking change to `OrderBook`'s on-chain layout or semantics. Existing
/// books need no explicit migration step — `assert_book_version` transparently
/// upgrades any book whose stored `version` lags behind `CURRENT_VERSION` the
/// next time it is touched by any version-guarded call. If a book's `version`
/// is instead AHEAD of this constant, it means this package build doesn't
/// yet understand a `version` the book already carries (see
/// `assert_book_version`).
///
/// Bumped from 1 to 2 for the `event_id` -> `enclosing_object_id` rename plus
/// the addition of a `book_id` field to every emitted event: a wire-format
/// change to every event this module emits (a field renamed and a field
/// added simultaneously), even though no `OrderBook` on-chain data actually
/// needed converting -- both stamped ids are derived fresh at emit time from
/// fields that already existed on `OrderBook` (the renamed field itself, and
/// the book's own `id`), so this bump is a marker only, and
/// `assert_book_version`'s existing no-migration self-heal still applies
/// unchanged.
const CURRENT_VERSION: u64 = 2;

// === Side convention ===

/// `side == true` means the bid side, `side == false` means the ask side.
/// Every `side: bool` parameter and struct field in this module (e.g.
/// `resting_order_escrow`'s `side`, `OrderTicket.side`, `OrderPlaced.side`)
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
    let already_exists = proceeds.contains(order_id);
    if (!already_exists && base.value() == 0 && quote.value() == 0) {
        // A zero-valued credit that would otherwise create a fresh ledger
        // entry holding nothing -- e.g. a fee-ceiling-consumes-everything
        // fill (see `fee_amount`) -- is skipped entirely rather than
        // creating a real entry with nothing pooled in it. Such an entry
        // would block `destroy_orphaned_ticket`'s presence check even
        // though it protects no real funds. If a LATER fill on this same
        // order credits a genuinely nonzero amount, the `push_back` below
        // still runs then, at that point.
        base.destroy_zero();
        quote.destroy_zero();
        return
    };
    if (!already_exists) {
        proceeds.push_back(order_id, MakerBalance { owner, base: balance::zero(), quote: balance::zero() });
    };
    let mb = proceeds.borrow_mut(order_id);
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
    if (proceeds.contains(order_id)) {
        proceeds.borrow_mut(order_id).owner = new_owner;
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
    /// Derived at construction (see `new`) from the book's declared
    /// `base_decimals`/`quote_decimals`/`precision`/`exponent`: the true
    /// price is `price / price_scale * 10^(base_decimals - quote_decimals)`.
    /// Chosen as the smallest value that guarantees resolution at least as
    /// fine as the book's declared `10^-precision`, i.e.
    /// `ceil(10^base_decimals * 10^precision / 10^quote_decimals)` — not the
    /// largest value that fits in a `u64`. Used by
    /// `bid_escrow_amount`/`scaled_ceil_mul_div` to convert a raw `price` and
    /// `size` into `Quote`-atom escrow.
    price_scale: u64,
    /// Declared minimum number of significant decimal digits of true-price
    /// resolution this book guarantees to support; see
    /// `assert_price_in_declared_range`.
    precision: u8,
    /// Declared upper bound (as a power of ten) on the true price this book
    /// guarantees to support; see `assert_price_in_declared_range`.
    exponent: u8,
    base_decimals: u8,
    quote_decimals: u8,
    /// The price (in the book's raw, `price_scale`-relative units) of the
    /// most recent real fill, or the constructor-supplied
    /// `initial_last_price` if no fill has ever occurred. Seeds and anchors
    /// `price_band_factor`'s optional band. See `set_last_price`.
    last_price: u64,
    /// Optional additional safeguard, independent of `precision`/`exponent`:
    /// when set, every placed order's `price` must fall within
    /// `[last_price / price_band_factor, last_price * price_band_factor]`.
    /// `None` (the default) disables this check entirely. See
    /// `clob_admin_set_price_band_factor`. This band is only as trustworthy
    /// as `last_price` itself — see `set_last_price`'s doc comment for a
    /// known, accepted limitation (permissionless, capital-free griefing of
    /// this band's position on an empty book).
    price_band_factor: Option<u64>,
    /// The id every event this module emits stamps as `enclosing_object_id`.
    /// Write-once: fixed at construction time — always caller-supplied via
    /// `new`'s mandatory `enclosing_object_id: &UID` parameter — and never
    /// mutable afterward. A wrapping object whose own outer id is what
    /// external callers/indexers actually query by should pass a borrow of
    /// that object's own `UID` to `new`.
    ///
    /// This field exists SOLELY to be stamped on emitted events. Because
    /// `new` takes a live `&UID` reference rather than a bare `ID` value, a
    /// caller can no longer forge this to an arbitrary id merely copied off
    /// a public event or explorer — that no longer compiles. This does NOT,
    /// however, guarantee the caller controls the referenced object: any
    /// object that is genuinely shared and whose module exposes a public
    /// `&UID` accessor (e.g. `sui::kiosk::uid(&Kiosk)`,
    /// `sui::transfer_policy::uid(&TransferPolicy)`) can have its `&UID`
    /// borrowed by any address, not just its owner, so
    /// `enclosing_object_id` can in principle still be pointed at an id the
    /// caller doesn't own when such an accessor exists. This narrows the
    /// attack surface; it does not eliminate it. Regardless,
    /// `enclosing_object_id` is always caller-supplied, and therefore always
    /// potentially unrelated to the book's true identity — it is NEVER used
    /// for authentication anywhere in this module and must never be relied
    /// on for any authentication/identity check — the residual risk above is
    /// scoped strictly to event/indexer spoofing (an off-chain consumer
    /// trusting `enclosing_object_id` without independently verifying its
    /// true origin), never fund safety or access control. The book's own
    /// object id (`id: UID` above, via `object::uid_to_inner(&book.id)`) is
    /// what's unforgeable and must be used for authentication instead (see
    /// `OrderTicket.order_book_id`) — and is also stamped directly on every
    /// emitted event as `book_id`, so an off-chain consumer can independently
    /// cross-check the two rather than trusting `enclosing_object_id` alone.
    enclosing_object_id: ID,
}

// === ClobAdminCap ===

/// `has store` only — deliberately no `key`. Just like `OrderBook` above,
/// this makes it structurally impossible for `ClobAdminCap` to ever become a
/// Sui shared/owned top-level object on its own; it can only be moved around
/// as a plain value, or embedded as a field inside some other object that
/// does have `key` (e.g. `CapHolder` in the tests). `id: UID` is retained
/// purely as a globally-unique identity value this struct can hold as a
/// plain `store`-only field — see `OrderBook`'s doc comment for the general
/// rationale.
#[allow(lint(missing_key))]
public struct ClobAdminCap has store {
    id: UID,
}

public struct ClobAdminCapDiscarded has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    cap_id: ID,
}

/// Small helper struct bundling both ids stamped on every event
/// (`book_id`, the book's true, unforgeable id, and `enclosing_object_id`,
/// the caller-supplied id — see `OrderBook.enclosing_object_id`'s doc
/// comment). Used to thread both ids into the handful of helper functions
/// (`conclude_order_fee`, `fold_maker_fee_slack`, `drain_side`,
/// `drain_proceeds`) that don't have `&OrderBook` in scope: passing a
/// single `BookIds` value instead of two bare, same-typed `ID` parameters
/// side by side avoids a silent-argument-swap hazard at every call site.
public struct BookIds has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
}

/// Single source of truth for deriving a book's two event-stamped ids.
/// Every call site should go through this accessor rather than
/// re-deriving `book_id` / `enclosing_object_id` inline, so a typo
/// swapping the two can't silently slip into just one event.
fun book_ids<Base, Quote>(book: &OrderBook<Base, Quote>): BookIds {
    BookIds { book_id: object::uid_to_inner(&book.id), enclosing_object_id: book.enclosing_object_id }
}

// === Price scaling helpers ===

/// `10^exp`, computed as a `u256`.
fun pow10_u256(exp: u8): u256 {
    let mut result: u256 = 1;
    let mut i: u8 = 0;
    while (i < exp) {
        result = result * 10;
        i = i + 1;
    };
    result
}

fun u64_max_as_u256(): u256 { U64_MAX as u256 }

/// Asserts `price` (in the book's raw, `price_scale`-relative units) decodes
/// to a true price within the range the book's declared
/// `precision`/`exponent` guarantee is representable: true price must be at
/// least `10^-precision` and at most `10^exponent`. Raw scalars only —
/// deliberately NOT `&OrderBook` — reused unmodified across 4 call sites in
/// 3 categories: construction (`new`), `set_last_price`, and
/// order placement (`place_limit_order_bid`/`_ask`), the
/// first of which has no live book reference to borrow yet.
fun assert_price_in_declared_range(
    price: u64,
    price_scale: u64,
    base_decimals: u8,
    quote_decimals: u8,
    precision: u8,
    exponent: u8,
) {
    let pow_base = pow10_u256(base_decimals);
    let pow_quote = pow10_u256(quote_decimals);
    let pow_prec = pow10_u256(precision);
    let pow_exp = pow10_u256(exponent);
    let price_u256 = price as u256;
    let scale_u256 = price_scale as u256;
    assert!(scale_u256 * pow_quote <= price_u256 * pow_base * pow_prec, EPriceBelowDeclaredMin);
    assert!(price_u256 * pow_base <= pow_exp * scale_u256 * pow_quote, EPriceAboveDeclaredMax);
}

// === Constructor ===

/// Callable by any address — no capability is required to create a book,
/// and it is never registered anywhere by this call.
///
/// `enclosing_object_id` is a MANDATORY `&UID` parameter, not an optional
/// one, because `OrderBook`/`ClobAdminCap` are both `store`-only, never
/// `key` (see their own doc comments) — this book can never exist as a
/// top-level object in its own right, only ever embedded as a field inside
/// some enclosing object. Requiring that enclosing object's live `&UID` at
/// construction time is therefore not an artificial burden; it reflects how
/// this type is actually used. The book's own `enclosing_object_id` field
/// (stamped on every emitted event, alongside the book's true id as
/// `book_id` — see `OrderBook.enclosing_object_id`'s doc comment) is set to
/// `object::uid_to_inner(enclosing_object_id)`.
///
/// `enclosing_object_id` is a borrowed `&UID` rather than a bare `ID`
/// specifically to rule out the naive attack of pointing
/// `enclosing_object_id` at an arbitrary id (e.g. copied off a public event
/// for an unrelated book) that the caller merely knows but doesn't hold a
/// live reference to — passing a bare `ID` copied that way does not
/// compile. This does NOT fully guarantee the caller controls the
/// referenced object: any object that is genuinely shared and whose module
/// exposes a public `&UID` accessor (e.g. `sui::kiosk::uid(&Kiosk)`,
/// `sui::transfer_policy::uid(&TransferPolicy)`) can have its `&UID`
/// borrowed by any address, not just its owner — so a caller can still
/// legitimately obtain and pass in a live `&UID` for an object they don't
/// own if such an accessor exists for it. This narrows the attack surface;
/// it does not eliminate id spoofing outright. As documented on
/// `OrderBook.enclosing_object_id`, this is never a fund-safety or
/// authentication concern — `enclosing_object_id` is never used for
/// authentication anywhere in this module — only an event/indexer spoofing
/// concern, and one an off-chain consumer can now independently detect by
/// cross-checking the event's own `book_id` field.
///
/// A caller with no real wrapper object handy may legitimately mint a
/// throwaway `UID` via `object::new(ctx)`, pass a borrow of it here, and
/// delete it immediately afterward (`that_uid.delete()`) — this is a
/// supported pattern, not a workaround: what actually matters for the
/// indexer-cross-check use case this field exists for is the id's
/// uniqueness, not whether the referenced object is still live at read
/// time. In the same spirit, if an enclosing object is later deleted and a
/// new `OrderBook` constructed to replace it, deliberately reusing that same
/// (now-dead) enclosing id across the transition is a useful capability for
/// indexer continuity, not a misuse of this parameter.
///
/// `min_size` bounds order-placement size only, not post-fill remainder
/// size — see `validate_size_raw`'s doc comment for the full caveat about
/// resulting dust and `max_fills` griefing.
///
/// `base_decimals`/`quote_decimals` are the on-chain atomic-unit decimals of
/// `Base`/`Quote` respectively. `precision`/`exponent` jointly declare the
/// range of true price this book guarantees to be able to represent: at
/// least `10^-precision` and at most `10^exponent`. From these four values, a
/// `price_scale` is derived (see `price_scale`'s accessor) as the smallest
/// value that guarantees resolution at least as fine as `10^-precision`;
/// `10^exponent` must still fit within a `u64` raw price at that
/// `price_scale` (a feasibility bound, `scale_hi`), and construction
/// aborts with `EPriceRangeInfeasible` if no valid `price_scale` exists for
/// the declared inputs. `initial_last_price` seeds the book's `last_price`
/// (see `set_last_price`), the reference point an optional
/// `price_band_factor` bounds every placed order's `price` against; it must
/// be nonzero and must itself decode to a true price within the declared
/// `precision`/`exponent` range.
public fun new<Base, Quote>(
    min_size: u64,
    base_decimals: u8,
    quote_decimals: u8,
    precision: u8,
    exponent: u8,
    initial_last_price: u64,
    enclosing_object_id: &UID,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    assert!(min_size != 0, EZeroMinSize);
    assert!(min_size <= MAX_MIN_SIZE, EMinSizeTooLarge);
    assert!(
        base_decimals <= MAX_DECIMALS && quote_decimals <= MAX_DECIMALS
            && precision <= MAX_DECIMALS && exponent <= MAX_DECIMALS,
        EDecimalsTooLarge,
    );

    let pow_base = pow10_u256(base_decimals);
    let pow_quote = pow10_u256(quote_decimals);
    let pow_prec = pow10_u256(precision);
    let pow_exp = pow10_u256(exponent);
    let u64_max = u64_max_as_u256();

    // scale_lo = ceil(pow_base * pow_prec / pow_quote)
    let numerator = pow_base * pow_prec;
    let scale_lo = (numerator + pow_quote - 1) / pow_quote;
    // scale_hi = floor(u64::MAX * pow_base / (pow_quote * pow_exp))
    let scale_hi = (u64_max * pow_base) / (pow_quote * pow_exp);
    assert!(scale_lo <= scale_hi && scale_lo <= u64_max, EPriceRangeInfeasible);
    let price_scale = scale_lo as u64;

    assert!(initial_last_price != 0, EZeroPrice);
    assert_price_in_declared_range(initial_last_price, price_scale, base_decimals, quote_decimals, precision, exponent);

    let book_uid = object::new(ctx);
    let cap = ClobAdminCap { id: object::new(ctx) };
    let cap_id = object::uid_to_inner(&cap.id);
    let enclosing_object_id = object::uid_to_inner(enclosing_object_id);
    assert!(enclosing_object_id != object::uid_to_inner(&book_uid), EEnclosingIsSelf);

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
        price_scale,
        precision,
        exponent,
        base_decimals,
        quote_decimals,
        last_price: initial_last_price,
        price_band_factor: option::none(),
        enclosing_object_id,
    };
    (book, cap)
}

// === Field accessors ===
// `min_size` is public (integrators need it to pre-validate order size before
// calling); the rest below are package-private.

public fun min_size<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
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
    if (!book.proceeds.contains(order_id)) {
        return (@0x0, balance::zero(), balance::zero())
    };
    let mb = book.proceeds.remove(order_id);
    destroy_maker_balance(mb)
}

public struct BookVersionUpgraded has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
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
/// from 0 to 1 and then from 1 to 2, each a bookkeeping-only change). The
/// day `CURRENT_VERSION` is bumped for a change that DOES require
/// converting a book's existing on-chain data, this silent auto-bump
/// behavior must be replaced — before that version ships, not after —
/// with an explicit, cap-gated migration
/// function and a strict version-equality assert here, so an un-migrated
/// book can no longer silently self-heal into a version whose data layout it
/// doesn't actually have yet.
public fun assert_book_version<Base, Quote>(book: &mut OrderBook<Base, Quote>) {
    assert!(book.version <= CURRENT_VERSION, ENewVersionMismatch);
    if (book.version < CURRENT_VERSION) {
        let from = book.version;
        let ids = book.book_ids();
        book.version = CURRENT_VERSION;
        event::emit(BookVersionUpgraded {
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            from,
            to: CURRENT_VERSION,
        });
    };
}

// === Public view functions (no version-guard assertion) ===

/// The book's own immutable object id — what `OrderTicket.order_book_id` is
/// bound to (see `OrderTicket`'s doc comment). NOT the same as
/// `enclosing_object_id`, which is caller-supplied at construction and used
/// only for event stamping; this is the actual, unforgeable identity
/// `cancel_order` and `update_resting_order` authenticate tickets against.
/// This is also the value stamped as `book_id` on every emitted event,
/// alongside the event's own `enclosing_object_id`.
public fun book_id<Base, Quote>(book: &OrderBook<Base, Quote>): ID {
    object::uid_to_inner(&book.id)
}

public fun fee_config<Base, Quote>(book: &OrderBook<Base, Quote>): (u64, u64) {
    (book.taker_fee_bps, book.maker_fee_bps)
}

/// See the `OrderBook.price_scale` field doc comment and the module doc
/// comment for what this value means for decoding `price`.
public fun price_scale<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.price_scale
}

public fun fee_accumulator_balances<Base, Quote>(book: &OrderBook<Base, Quote>): (u64, u64) {
    (book.fee_accumulator.base.value(), book.fee_accumulator.quote.value())
}

public fun is_book_paused<Base, Quote>(book: &OrderBook<Base, Quote>): bool {
    book.paused
}

/// Sticky: once `true`, stays `true` forever (see `OrderBook`'s doc comment).
public fun is_book_retiring<Base, Quote>(book: &OrderBook<Base, Quote>): bool {
    book.retiring
}

public fun best_bid<Base, Quote>(book: &OrderBook<Base, Quote>): Option<u64> {
    let ptr = book.bids.max_leaf();
    if (ptr.is_none()) {
        option::none()
    } else {
        let leaf_ptr = *ptr.borrow();
        option::some(book.bids.key(leaf_ptr))
    }
}

public fun best_ask<Base, Quote>(book: &OrderBook<Base, Quote>): Option<u64> {
    let ptr = book.asks.min_leaf();
    if (ptr.is_none()) {
        option::none()
    } else {
        let leaf_ptr = *ptr.borrow();
        option::some(book.asks.key(leaf_ptr))
    }
}

/// The exact, maintained total Base quantity resting across every ASK order
/// at `price` -- `0` if no ask level exists there. This function is
/// deliberately ask-only, not `side`-parameterized: a bid level's own
/// natural aggregate is Quote-denominated (its resting orders escrow Quote,
/// not Base -- see `order::Order.remaining_size`'s doc comment), so a single
/// `u64`-returning function silently switching denomination based on a
/// boolean `side` argument was a real integration hazard (a caller reading
/// only the type signature had no way to know the units differed by side,
/// and the two units are the same numeric type). Callers wanting a bid
/// level's aggregate should call `bid_quote_escrow_at_price` instead, which
/// is honest about being Quote-denominated in its own name.
public fun ask_base_escrow_at_price<Base, Quote>(book: &OrderBook<Base, Quote>, price: u64): u64 {
    let found = book.asks.find(price);
    if (found.is_none()) {
        return 0
    };
    let leaf_ptr = found.destroy_some();
    let level = book.asks.borrow(leaf_ptr);
    level.level_total_size()
}

/// The exact, maintained total of live Quote escrow currently held by every
/// resting BID order at `price` -- equivalently, the exact gross Quote
/// (before any taker fee) that would be paid out if every resting bid at
/// this price were fully drained via direct escrow refund. `0` if no bid
/// level exists at `price`.
///
/// This is an O(1) running aggregate maintained at the same mutation points
/// as `ask_base_escrow_at_price`'s underlying total (the bid-side twin of
/// the same per-level bookkeeping), so it always equals the true sum of
/// live per-order escrow -- unlike a re-derivation via
/// `bid_escrow_amount(book, price, size)` fed a size from some OTHER
/// source, which can be off in EITHER direction: a re-derivation over- or
/// under-counts by up to roughly one Quote atom per resting order at that
/// price, in either direction, depending on each order's own fill history.
/// (Feeding this function's own OWN return value into `bid_escrow_amount`
/// as a "size" is additionally a straightforward category error, not just a
/// rounding-dust discrepancy -- this value is already Quote-denominated, so
/// `bid_escrow_amount` would multiply by `price` a second time.)
///
/// Ask levels hold no Quote escrow at all (an ask escrows Base, exactly
/// equal to `ask_base_escrow_at_price(book, price)`), which is why this
/// function is deliberately bid-only rather than taking a `side` parameter.
public fun bid_quote_escrow_at_price<Base, Quote>(book: &OrderBook<Base, Quote>, price: u64): u64 {
    let found = book.bids.find(price);
    if (found.is_none()) {
        return 0
    };
    let leaf_ptr = found.destroy_some();
    let level = book.bids.borrow(leaf_ptr);
    level.level_total_quote_escrow()
}

/// The book's own `last_price` field, snapshotted the last time a fill
/// occurred (see the `OrderBook` doc comment for full semantics).
public fun last_price<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.last_price
}

/// The book's own optional price-band factor — see
/// `clob_admin_set_price_band_factor`'s doc comment for what this value
/// gates.
public fun price_band_factor<Base, Quote>(book: &OrderBook<Base, Quote>): Option<u64> {
    book.price_band_factor
}

/// The book's own `version` field. See `assert_book_version`'s doc comment
/// for how/when this can change.
public fun book_version<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.version
}

/// Returns `Some((escrow, remaining_size))` for the resting order identified
/// by `(side, price, order_id)`, or `None` if that price level doesn't exist
/// or holds no such order (fully filled, cancelled, or never placed). Never
/// aborts, for any input.
///
/// `escrow` is denominated in Quote for a bid (`side == true`), Base for an
/// ask (`side == false`) -- the currency that side actually escrows. This is
/// the order's remaining escrowed PRINCIPAL only: `cancel_order` may
/// additionally pay out pooled proceeds in the OPPOSITE currency, which this
/// value does not include. `remaining_size` is ALSO denominated in Quote for
/// a bid, Base for an ask (see `order::Order.remaining_size`'s doc comment)
/// -- for a bid, `escrow` and `remaining_size` are therefore always equal
/// (both are just `escrow_quote_value`), mirroring how they were already
/// equal for an ask.
///
/// For an ASK-side order, `escrow`/`remaining_size` can never reach `0`
/// while it's still resting: `fill_level_bid` never charges more Base than
/// an ask has left, and draining it to exactly `0` is the same fill that
/// stops it from resting. For a BID-side order, this is no longer true
/// under the telescoping proportional-ceiling escrow-charging scheme (see
/// `order::Order.original_size`'s doc comment and `fill_level_ask`): whenever
/// the order's resting price is below `book.price_scale` (the normal case),
/// the cumulative-ceiling formula reaches the order's full `total_reserved`
/// Quote escrow strictly before its Base side (`original_size -
/// fee_basis_accumulated`) is exhausted -- so `Some(RestingOrderEscrow {
/// escrow: 0, remaining_size: 0 })` (both fields are the same
/// `escrow_quote_value`, per above) for a live, still-resting, still-fillable
/// bid is a real, reachable state, not an error condition. `None` (not
/// resting at all) remains the only other state for either side.
///
/// Returns a small `RestingOrderEscrow` struct rather than a `(u64, u64)`
/// tuple: Move does not support a bare tuple as a type argument (e.g.
/// `Option<(u64, u64)>` does not compile), so a plain-data `copy, drop`
/// struct is used instead — unwrap it with `resting_order_escrow_fields`.
public fun resting_order_escrow<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order_id: u64,
): Option<RestingOrderEscrow> {
    let tree: &PriceTree<PriceLevel<Base, Quote>> = if (side) &book.bids else &book.asks;
    let found = tree.find(price);
    if (found.is_none()) {
        return option::none()
    };
    let leaf_ptr = found.destroy_some();
    let level = tree.borrow(leaf_ptr);
    if (!level.level_contains_order(order_id)) {
        return option::none()
    };
    let order = level.level_borrow_order(order_id);
    let escrow = if (side) order.escrow_quote_value() else order.remaining_size();
    option::some(RestingOrderEscrow { escrow, remaining_size: order.remaining_size() })
}

/// `resting_order_escrow` for the order this ticket was minted for.
/// Aborts with `EWrongBook` if `ticket` was not minted by `book`.
public fun resting_order_escrow_by_ticket<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    ticket: &OrderTicket,
): Option<RestingOrderEscrow> {
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    resting_order_escrow(book, ticket.side, ticket.price, ticket.order_id)
}

/// Plain-data result of `resting_order_escrow`/`resting_order_escrow_by_ticket`
/// -- see those functions' doc comments for what `escrow`/`remaining_size`
/// mean. Exists only because Move does not support a bare tuple as a type
/// argument.
public struct RestingOrderEscrow has copy, drop {
    escrow: u64,
    remaining_size: u64,
}

public fun resting_order_escrow_fields(e: &RestingOrderEscrow): (u64, u64) {
    (e.escrow, e.remaining_size)
}

/// The recorded `owner` address of the resting order at `(side, price, order_id)`
/// — i.e. the address `clob_admin_cancel_order`/`drain_side` will pay if this
/// order is force-cancelled/drained, and (once pooled) the address
/// `drain_proceeds`/`push_proceeds` will pay for its proceeds. This is NOT
/// necessarily the current `OrderTicket` holder: it is whoever `ctx.sender()`
/// was at placement time, only updated afterward by an explicit
/// `update_resting_order` call. An integrator whose ticket custody can change
/// hands (e.g. a wrapper holding tickets internally while a keeper address
/// places orders) should call `update_resting_order` on every custody change,
/// and can use this getter beforehand to verify the recorded address is
/// actually in sync with the intended current beneficiary. `None` if the
/// order is not resting (mirrors `resting_order_escrow`'s not-found handling).
public fun resting_order_owner<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order_id: u64,
): Option<address> {
    let tree: &PriceTree<PriceLevel<Base, Quote>> = if (side) &book.bids else &book.asks;
    let found = tree.find(price);
    if (found.is_none()) {
        return option::none()
    };
    let leaf_ptr = found.destroy_some();
    let level = tree.borrow(leaf_ptr);
    if (!level.level_contains_order(order_id)) {
        return option::none()
    };
    let order = level.level_borrow_order(order_id);
    option::some(order.owner())
}

/// `resting_order_owner` for the order this ticket was minted for. Aborts
/// with `EWrongBook` if `ticket` was not minted by `book`.
public fun resting_order_owner_by_ticket<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    ticket: &OrderTicket,
): Option<address> {
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    resting_order_owner(book, ticket.side, ticket.price, ticket.order_id)
}

/// The recorded `owner` address of the pooled proceeds entry for `order_id`,
/// if one exists — i.e. the address `drain_proceeds`/`push_proceeds` will pay
/// out to. Same staleness caveat as `resting_order_owner`: this is whoever was
/// last stamped via `credit_maker_table`/`update_resting_order`'s
/// `sync_maker_balance_owner` call, not necessarily the current `OrderTicket`
/// holder. `None` if no pooled entry exists for `order_id` (nothing to claim,
/// or already claimed/drained).
public fun proceeds_owner<Base, Quote>(book: &OrderBook<Base, Quote>, order_id: u64): Option<address> {
    if (book.proceeds.contains(order_id)) {
        option::some(book.proceeds.borrow(order_id).owner)
    } else {
        option::none()
    }
}

/// `proceeds_owner` for the order this ticket was minted for. Aborts with
/// `EWrongBook` if `ticket` was not minted by `book` — proceeds are pooled
/// per `order_id` within a single book, and `order_id` values are not unique
/// across books, so without this check a ticket minted by a different book
/// could collide with an unrelated pooled entry in this one.
public fun proceeds_owner_by_ticket<Base, Quote>(book: &OrderBook<Base, Quote>, ticket: &OrderTicket): Option<address> {
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    proceeds_owner(book, ticket.order_id)
}

// === ClobAdminCap gate ===

fun assert_clob_admin<Base, Quote>(cap: &ClobAdminCap, book: &OrderBook<Base, Quote>) {
    assert!(object::uid_to_inner(&cap.id) == book.clob_admin_cap_id, EWrongClobAdminCap);
}

// === Local pause/unpause ===

public struct Paused has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
}

public struct Unpaused has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
}

public fun clob_admin_pause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let ids = book.book_ids();
    book.paused = true;
    event::emit(Paused { book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id });
}

public fun clob_admin_unpause_book<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(!book.retiring, EBookRetiring);
    let ids = book.book_ids();
    book.paused = false;
    event::emit(Unpaused { book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id });
}

// === Fee setters and claim_fees ===

public struct TakerFeeSet has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    rate_bps: u64,
}

public struct MakerFeeSet has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    rate_bps: u64,
}

public struct FeesClaimed has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    claimant: address,
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
    let ids = book.book_ids();
    book.taker_fee_bps = rate_bps;
    event::emit(TakerFeeSet { book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id, rate_bps });
}

public fun clob_admin_set_maker_fee<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    rate_bps: u64,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(rate_bps <= MAX_MAKER_FEE_BPS, EMakerFeeRateTooHigh);
    let ids = book.book_ids();
    book.maker_fee_bps = rate_bps;
    event::emit(MakerFeeSet { book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id, rate_bps });
}

public struct PriceBandFactorSet has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    factor: Option<u64>,
}

/// Sets (or clears, via `option::none()`) the book's optional price-band
/// safeguard: when set, every placed order's `price` must fall within
/// `[last_price / factor, last_price * factor]`. `factor` must be at least
/// `1` when `Some` — a factor of `0` could never bound anything and is
/// always a caller mistake.
public fun clob_admin_set_price_band_factor<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    factor: Option<u64>,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    if (factor.is_some()) {
        assert!(*factor.borrow() >= 1, EZeroPriceBandFactor);
    };
    let ids = book.book_ids();
    book.price_band_factor = factor;
    event::emit(PriceBandFactorSet { book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id, factor });
}

public struct LastPriceSet has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    last_price: u64,
    setter: address,
}

/// Permissionless reset of the book's `last_price` reference point (see
/// `OrderBook.last_price`'s doc comment). `new_last_price` must be nonzero,
/// must decode to a true price within the book's declared
/// `precision`/`exponent` range, and — if a best bid/ask currently exists —
/// must not cross it (a set `last_price` inside the live spread can
/// never itself be an executable price, so this rules out setting a
/// nonsensical reference point).
///
/// Deliberately not capability-gated. The spread-bound check above already
/// makes this a no-op safety-wise whenever real resting liquidity exists —
/// it can only move `last_price` to somewhere at least as constrained as
/// the live spread already permits. When the book is empty near the
/// reference price, the check is unconstrained (no best bid/ask means no
/// bound applies), and gating this setter behind `ClobAdminCap` blocked no
/// meaningful attack downward — a resting-order self-cross can walk
/// `last_price` down cheaply regardless — while adding pure friction: a
/// genuine caller recovering from a stale or walked-away `last_price` had
/// to run multiple self-crossing rounds, or wait on the admin, just to
/// unblock their own order placement. Now they can call this directly —
/// optionally bundled with their order-placement call in the same PTB for
/// atomicity — the moment the book is unconstrained at that price.
///
/// Known limitation, accepted as documented rather than fixed (see the
/// project's audit notes, finding M-01): walking `last_price` UP via a
/// self-cross is not actually cheap — each round requires escrowing real
/// quote proportional to the new, higher price — but this permissionless
/// setter has no such cost in either direction. On an empty book, anyone
/// can jump `last_price` to any declared-range value in a single, capital-
/// free call, which can push `price_band_factor`'s band far enough from the
/// true price that every legitimate `place_limit_order_bid`/`_ask` at the
/// true price starts aborting on `EPriceBelowBand`/`EPriceAboveBand`. This
/// is pure griefing, not a fund-loss vector — `last_price` is never read by
/// any escrow, fee, or proceeds computation, and `cancel_order`/
/// `clob_admin_cancel_order` are never gated by it — and recovery is just
/// as cheap and permissionless as the griefing call: any caller can bundle
/// their own corrective `set_last_price` with their order placement in one
/// atomic PTB and always succeed. Integrators relying on `price_band_factor`
/// as protection against a determined, motivated griefer (rather than
/// purely a fat-finger guard) should account for this.
///
/// Since this is permissionless, the emitted `LastPriceSet` event carries
/// `setter: ctx.sender()` so off-chain indexers can distinguish an
/// admin-initiated reset from an anonymous caller's. No event is emitted
/// when `new_last_price` equals the book's current `last_price` — a no-op
/// reset is not an error, but it is not worth spamming the event stream
/// either, since anyone can call this for free repeatedly.
public fun set_last_price<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    new_last_price: u64,
    ctx: &TxContext,
) {
    assert_book_version(book);
    assert!(new_last_price != 0, EZeroPrice);
    assert_price_in_declared_range(
        new_last_price, book.price_scale, book.base_decimals, book.quote_decimals, book.precision, book.exponent,
    );
    let bid_opt = best_bid(book);
    if (bid_opt.is_some()) {
        assert!(new_last_price >= *bid_opt.borrow(), EResetPriceBelowBestBid);
    };
    let ask_opt = best_ask(book);
    if (ask_opt.is_some()) {
        assert!(new_last_price <= *ask_opt.borrow(), EResetPriceAboveBestAsk);
    };
    if (new_last_price != book.last_price) {
        let ids = book.book_ids();
        book.last_price = new_last_price;
        event::emit(LastPriceSet {
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            last_price: new_last_price,
            setter: ctx.sender(),
        });
    };
}

public fun clob_admin_claim_fees<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let ids = book.book_ids();
    let claimant = ctx.sender();
    let (base, quote) = withdraw_fee_accumulator(book);
    let base_amount = base.value();
    let quote_amount = quote.value();

    let base_coin = coin_or_zero(base, ctx);
    let quote_coin = coin_or_zero(quote, ctx);

    if (base_amount != 0 || quote_amount != 0) {
        event::emit(FeesClaimed {
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            claimant,
            base_amount,
            quote_amount,
        });
    };
    (base_coin, quote_coin)
}

// === Force-cancel ===

public struct OrderCancelled has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    order_id: u64,
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
    let ids = book.book_ids();
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let order_opt = tree.find_and_remove_order(price, order_id);
    if (order_opt.is_none()) { order_opt.destroy_none(); return };
    let live_order = order_opt.destroy_some();
    let owner = live_order.owner();
    let fee_basis = live_order.fee_basis_accumulated();
    let mfee_bps = live_order.maker_fee_bps();
    let (escrow_base, escrow_quote, frb, frq) = live_order.destroy();
    let (escrow_base, escrow_quote) = fold_maker_fee_slack(
        escrow_base, escrow_quote, frb, frq, fee_basis, mfee_bps, order_id, ids, owner,
        &mut book.fee_accumulator,
    );
    refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
    event::emit(OrderCancelled {
        book_id: ids.book_id,
        enclosing_object_id: ids.enclosing_object_id,
        order_id,
        trader: owner,
    });
}

// === Deletion lifecycle: clob_admin_retire/clob_admin_drain_step/clob_admin_finalize ===

public struct OrderBookRetired has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
}

public struct OrderBookDeleted has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    base: TypeName,
    quote: TypeName,
}

/// First step of the deletion lifecycle. The operational sequence is:
/// `clob_admin_retire` -> all `clob_admin_drain_step` calls (draining every
/// resting order and pooled-proceeds entry) -> `clob_admin_finalize`, which
/// also sweeps whatever remains in the fee accumulator and returns it to
/// the caller as coins. `clob_admin_claim_fees` may be called at any point
/// in that sequence (including never) purely for cashflow timing — there is
/// no required ordering between it and `clob_admin_drain_step`/
/// `clob_admin_finalize` — see `clob_admin_finalize`'s doc comment.
public fun clob_admin_retire<Base, Quote>(cap: &ClobAdminCap, book: &mut OrderBook<Base, Quote>) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    let ids = book.book_ids();
    book.paused = true;
    book.retiring = true;
    event::emit(OrderBookRetired { book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id });
}

/// Note: this function emits up to TWO events per drained resting order (one
/// `OrderCancelled`, plus one `MakerFeeSettled` from the centralized
/// maker-fee true-up — see `conclude_order_fee` — that now runs at every
/// order conclusion, drain included) and one `ProceedsClaimed` per nonzero
/// pooled-proceeds entry drained. Sui enforces a hard cap of 1024 events
/// emitted per transaction, so `max_items` should stay comfortably under
/// that limit (e.g. a few hundred) — especially if drain calls are batched
/// into a single PTB, where the cap applies across the whole transaction,
/// not per call. The added `MakerFeeSettled` roughly halves this function's
/// previous safe per-call margin against that cap (up to 2 events per
/// drained order now, versus 1 before), so an admin relying on a
/// previously-safe `max_items` value should reassess it accordingly.
///
/// Force-cancelling a partially-filled resting order routes that order's
/// maker-fee reserve into `book.fee_accumulator` through the very same
/// `conclude_order_fee` conclusion path every other order conclusion uses
/// (fill-drain, `cancel_order`, `clob_admin_cancel_order`) — this function
/// is not special-cased to skip it. Consequently, if `clob_admin_claim_fees`
/// is called before every `clob_admin_drain_step` call has finished, a
/// later drain step on a still-resting, previously-partially-filled order
/// can re-credit a nonzero amount into the accumulator after that claim
/// already emptied it. This is not a fund-loss bug and not a trap either:
/// `clob_admin_claim_fees` has no `retiring` gate, so calling it again any
/// time resolves it, and `clob_admin_finalize` itself now sweeps whatever
/// is left in the accumulator automatically, so no re-claim is required
/// before finalizing. See `clob_admin_finalize`'s doc comment.
///
/// This drains each remaining resting order's escrow to, and each pooled
/// proceeds entry's balance to, its recorded `owner` address (not necessarily
/// the current `OrderTicket` holder — see `update_resting_order`'s doc
/// comment). An integrator that needs to confirm ahead of time where a given
/// order's drain will pay out can check `resting_order_owner`/
/// `resting_order_owner_by_ticket` and `proceeds_owner`/
/// `proceeds_owner_by_ticket` beforehand.
public fun clob_admin_drain_step<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    max_items: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(book.retiring, ENotRetiring);
    let ids = book.book_ids();
    let mut remaining = max_items;
    let fees = &mut book.fee_accumulator;
    drain_side(&mut book.bids, &mut remaining, /* want_max */ true, ids, fees, ctx);
    drain_side(&mut book.asks, &mut remaining, /* want_max */ false, ids, fees, ctx);
    drain_proceeds(&mut book.proceeds, &mut remaining, ids, ctx);
}

fun drain_side<Base, Quote>(
    tree: &mut PriceTree<PriceLevel<Base, Quote>>,
    remaining: &mut u64,
    want_max: bool,
    ids: BookIds,
    fees: &mut FeeAccumulator<Base, Quote>,
    ctx: &mut TxContext,
) {
    while (*remaining > 0) {
        let best_opt = if (want_max) tree.max_leaf() else tree.min_leaf();
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let mut is_empty_now;
        {
            let level = tree.borrow_mut(leaf_ptr);
            loop {
                if (*remaining == 0) break;
                if (level.level_is_empty()) break;
                let (order_id, order) = level.level_pop_front_order();
                let owner = order.owner();
                let fee_basis = order.fee_basis_accumulated();
                let mfee_bps = order.maker_fee_bps();
                let (escrow_base, escrow_quote, frb, frq) = order.destroy();
                let (escrow_base, escrow_quote) = fold_maker_fee_slack(
                    escrow_base, escrow_quote, frb, frq, fee_basis, mfee_bps, order_id, ids, owner, fees,
                );
                refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
                event::emit(OrderCancelled {
                    book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id, order_id, trader: owner,
                });
                *remaining = *remaining - 1;
            };
            is_empty_now = level.level_is_empty();
        };
        if (is_empty_now) {
            let removed = tree.remove(leaf_ptr);
            removed.destroy_empty_price_level();
        };
    };
}

/// Converts `b` to a `Coin`, avoiding `coin::from_balance` on a zero-valued
/// `Balance` (which lacks `drop` and cannot simply be discarded) by
/// destroying it and minting an empty coin instead.
fun coin_or_zero<T>(b: Balance<T>, ctx: &mut TxContext): Coin<T> {
    if (b.value() == 0) {
        b.destroy_zero();
        coin::zero(ctx)
    } else {
        b.into_coin(ctx)
    }
}

/// Transfers `b` to `owner` as a `Coin`, or destroys it in place if it's
/// zero-valued (avoiding a zero-value transfer).
fun transfer_or_destroy_zero<T>(b: Balance<T>, owner: address, ctx: &mut TxContext) {
    if (b.value() == 0) {
        b.destroy_zero();
    } else {
        transfer::public_transfer(b.into_coin(ctx), owner);
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
    ids: BookIds,
    ctx: &mut TxContext,
) {
    while (*remaining > 0 && !proceeds.is_empty()) {
        let (_order_id, mb) = proceeds.pop_front();
        let (owner, base, quote) = destroy_maker_balance(mb);
        let base_amount = base.value();
        let quote_amount = quote.value();
        transfer_or_destroy_zero(base, owner, ctx);
        transfer_or_destroy_zero(quote, owner, ctx);
        if (base_amount != 0 || quote_amount != 0) {
            event::emit(ProceedsClaimed {
                book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id,
                claimant: owner, base_amount, quote_amount,
            });
        };
        *remaining = *remaining - 1;
    };
}

/// Returns the book's true, unforgeable object id
/// (`object::uid_to_inner(&book.id)`) — NOT `book.enclosing_object_id`. This
/// is distinct from the emitted `OrderBookDeleted` event's
/// `enclosing_object_id` field, which stamps the book's caller-supplied
/// `enclosing_object_id` and may differ from the book's true identity (that
/// same event's own `book_id` field carries the true id, for comparison). A
/// caller that relies on this return value for indexing/bookkeeping gets the
/// book's authoritative identity, unlike `enclosing_object_id`, which is
/// caller-controllable at construction time and must never be trusted for
/// that purpose.
///
/// The emptiness check below covers only resting orders and pooled
/// proceeds (`book.bids`, `book.asks`, `book.proceeds`) — NOT the fee
/// accumulator. Whatever remains in `book.fee_accumulator` at call time is
/// swept automatically and returned to the caller as the second and third
/// tuple elements (`Coin<Base>`, `Coin<Quote>`, either possibly zero-valued),
/// with a `FeesClaimed` event emitted alongside `OrderBookDeleted` and
/// `ClobAdminCapDiscarded` when the swept amount is nonzero. This means
/// there is no required ordering between `clob_admin_claim_fees` and
/// `clob_admin_drain_step`/this function anymore: a later
/// `clob_admin_drain_step` can still re-credit the accumulator
/// (force-cancelling a partially-filled resting order settles its
/// maker-fee reserve into `book.fee_accumulator`, same as any other order
/// conclusion — see that function's doc comment), but this function simply
/// sweeps whatever is left rather than requiring it to already be zero.
/// Calling `clob_admin_claim_fees` before this function is now purely
/// optional, for cashflow timing — never a correctness requirement.
public fun clob_admin_finalize<Base, Quote>(
    cap: ClobAdminCap,
    mut book: OrderBook<Base, Quote>,
    ctx: &mut TxContext,
): (ID, Coin<Base>, Coin<Quote>) {
    assert_book_version(&mut book);
    assert_clob_admin(&cap, &book);
    assert!(book.retiring, ENotRetiring);
    assert!(
        book.bids.size() == 0 && book.asks.size() == 0 && book.proceeds.is_empty(),
        ENotFullyDrained,
    );

    let OrderBook {
        id, min_size: _, bids, asks, proceeds,
        paused: _, retiring: _, next_order_id: _, clob_admin_cap_id: _, version: _,
        taker_fee_bps: _, maker_fee_bps: _, fee_accumulator,
        price_scale: _, precision: _, exponent: _, base_decimals: _, quote_decimals: _,
        last_price: _, price_band_factor: _, enclosing_object_id,
    } = book;
    let true_book_id = object::uid_to_inner(&id);
    bids.destroy_empty();
    asks.destroy_empty();
    proceeds.destroy_empty();
    let claimant = ctx.sender();
    let (fee_base, fee_quote) = destroy_fee_accumulator(fee_accumulator);
    let fee_base_amount = fee_base.value();
    let fee_quote_amount = fee_quote.value();
    let fee_base_coin = coin_or_zero(fee_base, ctx);
    let fee_quote_coin = coin_or_zero(fee_quote, ctx);
    object::delete(id);

    event::emit(OrderBookDeleted {
        book_id: true_book_id,
        enclosing_object_id,
        base: type_name::with_defining_ids<Base>(),
        quote: type_name::with_defining_ids<Quote>(),
    });

    if (fee_base_amount != 0 || fee_quote_amount != 0) {
        event::emit(FeesClaimed {
            book_id: true_book_id,
            enclosing_object_id,
            claimant,
            base_amount: fee_base_amount,
            quote_amount: fee_quote_amount,
        });
    };

    let ClobAdminCap { id: cap_id_uid } = cap;
    let cap_id = object::uid_to_inner(&cap_id_uid);
    object::delete(cap_id_uid);
    event::emit(ClobAdminCapDiscarded { book_id: true_book_id, enclosing_object_id, cap_id });

    (true_book_id, fee_base_coin, fee_quote_coin)
}

// === Matching engine, escrow/fee math, OrderTicket ===

/// Per-fill notification only — carries no fee information. Taker fees are
/// now computed once per call, in aggregate, after matching completes (see
/// `OrderExecuted.taker_fee_amount`); maker fees are set aside per-fill into
/// a per-order reserve and only actually settled — with any superadditive
/// slack refunded — when the order concludes (see `MakerFeeSettled`). Both
/// changes replace the old, exploitable per-fill-ceiling-rounded model (see
/// the project's audit notes, findings L-01/F-6). On the maker-bid side
/// (`maker_side == true`), `quote_amount` is derived from a proportional
/// slice of the maker's original escrow reservation (not a direct `price *
/// size` recomputation) and may differ by rounding from `ceil(price * size /
/// price_scale)` — this is expected.
public struct OrderFilled has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    maker_order_id: u64,
    price: u64,
    size: u64,
    maker: address,
    taker: address,
    maker_side: bool,
    quote_amount: u64,
}

/// Emitted exactly once for every order that concludes — fully filled
/// (drained by a fill), cancelled by its own ticket holder
/// (`cancel_order`), force-cancelled (`clob_admin_cancel_order`), or drained
/// (`clob_admin_drain_step`) — alongside whatever conclusion event that
/// site already emits (e.g. `OrderCancelled`). `amount` is the CORRECT
/// aggregate maker fee actually owed across the order's entire fill
/// history, `fee_amount(fee_basis_accumulated, maker_fee_bps)` — computed
/// once, at conclusion, from the order's own running fee-basis total, not
/// summed from each fill's independently ceiling-rounded per-fill fee
/// (which can over-collect — see the project's audit notes, finding F-6).
/// `amount` is denominated in Base for a bid-side order, Quote for an
/// ask-side order (whichever currency that order's maker fee is actually
/// paid in). An order that rests indefinitely without ever concluding
/// defers this event (and the fee's actual transfer into the book's fee
/// accumulator) indefinitely along with it — the fee isn't lost, just not
/// yet finalized, exactly like the order's own escrow/proceeds.
public struct MakerFeeSettled has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    order_id: u64,
    maker: address,
    amount: u64,
}

/// `ceil(price * size / book.price_scale)`. `size` is always
/// `Base`-atomic-units; a bid's escrow is this amount of `Quote`. `price` is
/// the book's raw, `price_scale`-relative unit — see the module doc comment.
public fun bid_escrow_amount<Base, Quote>(book: &OrderBook<Base, Quote>, price: u64, size: u64): u64 {
    scaled_ceil_mul_div(price, size, book.price_scale)
}

/// `ceil(price * size / price_scale)`, computed via a `u128` intermediate.
/// Style-mirrors `fee_amount`'s ceiling pattern. No separate overflow assert
/// on the intermediate product is needed: `price` and `size` are both `u64`,
/// so their raw product always fits in `u128` regardless of magnitude; only
/// the post-division narrowing back to `u64` can abort, which is the correct
/// safety net (a `price_scale` too coarse to represent the true cost in a
/// `u64` is a genuine "this amount cannot be escrowed" condition, not
/// silently-wrapped arithmetic).
fun scaled_ceil_mul_div(price: u64, size: u64, price_scale: u64): u64 {
    (((price as u128) * (size as u128) + (price_scale as u128) - 1) / (price_scale as u128)) as u64
}

/// `ceil(receive_amount * rate_bps / 10_000)`, computed via a `u128`
/// intermediate. No explicit overflow check is needed: `rate_bps` is
/// bounds-checked to at most `MAX_TAKER_FEE_BPS`/`MAX_MAKER_FEE_BPS` before
/// it can ever reach this function, so the maximum possible product is far
/// below `u128::MAX`. Ceiling division: any nonzero `receive_amount` at a
/// nonzero `rate_bps` now pays at least 1 unit of fee, closing a dust-sized
/// exploit where floor division let many small fills each collect zero fee.
fun fee_amount(receive_amount: u64, rate_bps: u64): u64 {
    (((receive_amount as u128) * (rate_bps as u128) + (BPS_DENOM as u128) - 1) / (BPS_DENOM as u128)) as u64
}

/// Inverse of `fee_amount`: the smallest gross size `G` such that, if fully
/// matched, `G - fee_amount(G, rate_bps) >= net_cap` -- i.e. the GROSS
/// matching bound to feed `match_bid` so that the resulting NET (post-fee)
/// delivered amount never exceeds `net_cap`. This exists because
/// `match_bid` only ever sees the gross size it is matching against --
/// `taker_fee_amount` is computed and deducted only after matching
/// completes -- so a NET-denominated cap like `max_base_out` must be
/// converted to an equivalent GROSS bound up front.
///
/// `rate_bps == 0` returns `net_cap` unchanged (no fee, gross == net).
/// Otherwise this is `ceil(net_cap * BPS_DENOM / (BPS_DENOM - rate_bps))`,
/// computed via a `u128` intermediate; `rate_bps` is bounds-checked to at
/// most `MAX_TAKER_FEE_BPS` before it can ever reach this function, so
/// `BPS_DENOM - rate_bps` is never zero.
///
/// `net_cap == u64::MAX` (the "unbounded" sentinel -- see
/// `place_market_order_bid`'s doc comment) is handled by clamping: the
/// inflated value would itself overflow `u64`, but an unbounded net cap
/// needs no inflation to remain unbounded, so any overflow just clamps back
/// to `u64::MAX`.
fun gross_size_bound_for_net_cap(net_cap: u64, rate_bps: u64): u64 {
    if (rate_bps == 0) { return net_cap };
    let denom = (BPS_DENOM - rate_bps) as u128;
    let gross = ((net_cap as u128) * (BPS_DENOM as u128) + denom - 1) / denom;
    if (gross > U64_MAX) { U64_MAX as u64 } else { gross as u64 }
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
    escrow_base.destroy_some().destroy_zero();
    escrow_quote.destroy_none();
}

fun destroy_drained_bid_escrow<Base, Quote>(
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
) {
    escrow_base.destroy_none();
    escrow_quote.destroy_some().destroy_zero();
}

// === Maker-fee reserve conclusion (Part C) ===
//
// Every one of `order::destroy`'s 5 call sites must run its concluding
// order's maker-fee reserve through `conclude_order_fee` below exactly
// once, rather than reimplementing the true-up computation itself. The two
// `extract_drained_*_fee_reserve` helpers unwrap `order::destroy`'s
// `(fee_reserve_base, fee_reserve_quote)` pair for the two fill-drain call
// sites, which already know their order's side unconditionally (mirroring
// `destroy_drained_ask_escrow`/`destroy_drained_bid_escrow` above);
// `fold_maker_fee_slack` is the side-generic version used by the other 3
// call sites, which handle a resting order of either side.

/// Centralized maker-fee true-up — the one place `correct_total_fee` is
/// ever computed. Computes the CORRECT aggregate fee owed across the
/// order's entire fill history, `fee_amount(fee_basis_accumulated,
/// maker_fee_bps)`, transfers exactly that amount out of `reserve` into
/// `fee_leg` (the book's fee-accumulator leg for this reserve's currency),
/// emits `MakerFeeSettled`, and returns whatever's left in `reserve` — the
/// superadditive slack — for the caller to fold into whatever refund
/// mechanism it already uses.
///
/// `reserve` is guaranteed to hold at least `correct_total_fee`: it is the
/// sum of independently ceiling-rounded per-fill fees taken over the same
/// running `fee_basis_accumulated` total, and ceiling division is
/// superadditive (the sum of ceilings is never less than the ceiling of the
/// sum), so the `balance::split` below can never abort.
fun conclude_order_fee<T>(
    mut reserve: Balance<T>,
    fee_basis_accumulated: u64,
    maker_fee_bps: u64,
    order_id: u64,
    ids: BookIds,
    owner: address,
): (Balance<T>, Balance<T>) {
    let correct_total_fee = fee_amount(fee_basis_accumulated, maker_fee_bps);
    let to_accumulator = reserve.split(correct_total_fee);
    event::emit(MakerFeeSettled {
        book_id: ids.book_id, enclosing_object_id: ids.enclosing_object_id,
        order_id, maker: owner, amount: correct_total_fee,
    });
    (reserve, to_accumulator)
}

/// Unwraps a fully-drained ASK-side maker order's `(fee_reserve_base,
/// fee_reserve_quote)` pair from `order::destroy`: asserts away the
/// always-`None` `fee_reserve_base` half (ask-side orders never populate
/// it — see `order::new`) and returns the always-`Some` `fee_reserve_quote`
/// balance.
fun extract_drained_ask_fee_reserve<Base, Quote>(
    fee_reserve_base: Option<Balance<Base>>,
    fee_reserve_quote: Option<Balance<Quote>>,
): Balance<Quote> {
    fee_reserve_base.destroy_none();
    fee_reserve_quote.destroy_some()
}

/// The BID-side mirror of `extract_drained_ask_fee_reserve` above.
fun extract_drained_bid_fee_reserve<Base, Quote>(
    fee_reserve_base: Option<Balance<Base>>,
    fee_reserve_quote: Option<Balance<Quote>>,
): Balance<Base> {
    fee_reserve_quote.destroy_none();
    fee_reserve_base.destroy_some()
}

/// The side-generic version of `extract_drained_*_fee_reserve` above, used
/// by the 3 conclusion call sites (`cancel_order`, `clob_admin_cancel_order`,
/// `drain_side`) that handle a resting order of either side: runs
/// `conclude_order_fee` against whichever one of `fee_reserve_base`/
/// `fee_reserve_quote` this order actually populated (exactly one, per
/// `order::new`'s bid/ask-exclusive construction), and folds the resulting
/// slack into the correspondingly-sided leg of `(escrow_base, escrow_quote)`
/// — creating that leg fresh via `option::some` if the order's own escrow
/// never held that currency to begin with (e.g. a bid order's `Base`-side
/// fee slack, since a bid order's `escrow_base` is always `None`).
fun fold_maker_fee_slack<Base, Quote>(
    mut escrow_base: Option<Balance<Base>>,
    mut escrow_quote: Option<Balance<Quote>>,
    fee_reserve_base: Option<Balance<Base>>,
    fee_reserve_quote: Option<Balance<Quote>>,
    fee_basis_accumulated: u64,
    maker_fee_bps: u64,
    order_id: u64,
    ids: BookIds,
    owner: address,
    fees: &mut FeeAccumulator<Base, Quote>,
): (Option<Balance<Base>>, Option<Balance<Quote>>) {
    if (fee_reserve_base.is_some()) {
        fee_reserve_quote.destroy_none();
        let reserve = fee_reserve_base.destroy_some();
        let (slack, fee_collected) = conclude_order_fee(reserve, fee_basis_accumulated, maker_fee_bps, order_id, ids, owner);
        fees.base.join(fee_collected);
        if (escrow_base.is_some()) {
            escrow_base.borrow_mut().join(slack);
        } else {
            escrow_base.destroy_none();
            escrow_base = option::some(slack);
        };
    } else {
        fee_reserve_base.destroy_none();
        let reserve = fee_reserve_quote.destroy_some();
        let (slack, fee_collected) = conclude_order_fee(reserve, fee_basis_accumulated, maker_fee_bps, order_id, ids, owner);
        fees.quote.join(fee_collected);
        if (escrow_quote.is_some()) {
            escrow_quote.borrow_mut().join(slack);
        } else {
            escrow_quote.destroy_none();
            escrow_quote = option::some(slack);
        };
    };
    (escrow_base, escrow_quote)
}

fun insert_resting_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    side: bool,
    price: u64,
    order: Order<Base, Quote>,
    ctx: &mut TxContext,
) {
    let order_id = order.id();
    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    tree.insert_or_append_order(price, order_id, order, ctx);
}

fun fill_level_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    budget: &mut Balance<Quote>,
    matched_base: &mut Balance<Base>,
    taker: address,
    fills_consumed: &mut u64,
    max_fills: u64,
): (bool, bool) {
    let ids = book.book_ids();
    let price_scale = book.price_scale;
    let mut budget_exhausted = false;
    let mut hit_max_fills = false;
    let is_empty_now;
    {
        let level = book.asks.borrow_mut(leaf_ptr);
        loop {
            if (*remaining_size == 0) break;
            if (level.level_is_empty()) break;
            if (*fills_consumed == max_fills) {
                budget_exhausted = true;
                hit_max_fills = true;
                break
            };
            let head_key = level.level_front_order_id().destroy_some();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = level.level_borrow_order(head_key).remaining_size();
            let natural_fill_qty = std::u64::min(*remaining_size, maker_remaining);
            // Taker-side scaling: no accumulator needed, since `affordable_qty`
            // is freshly recomputed every loop iteration from the taker's
            // live, already-decremented `budget`. Narrowing to `u64` happens
            // AFTER the min-clamp against `natural_fill_qty`, avoiding a
            // DoS-via-abort class where a live budget's `u128` intermediate
            // exceeds `u64::MAX` before clamping.
            let affordable_qty_u128 = ((budget.value() as u128) * (price_scale as u128)) / (best_price as u128);
            let natural_fill_qty_u128 = natural_fill_qty as u128;
            let fill_qty =
                (if (natural_fill_qty_u128 < affordable_qty_u128) { natural_fill_qty_u128 } else { affordable_qty_u128 }) as u64;
            if (fill_qty == 0) {
                budget_exhausted = true;
                break
            };
            // Rounding direction depends on which side this fill is limited
            // by (see the project's audit notes, findings L-A/L-B):
            //
            // - Maker-limited (`fill_qty == maker_remaining`, this fill fully
            //   drains the resting ask): floor, not ceiling. Ceiling here was
            //   the source of both findings -- independently ceiling-rounding
            //   every full-drain fill is superadditive across fragmented
            //   resting liquidity, so a taker sweeping N separate 1-unit asks
            //   paid strictly more Quote than sweeping one consolidated
            //   N-unit ask for the identical Base delivered (L-A), and a bid
            //   escrowed with the textbook-exact `bid_escrow_amount` could
            //   underfill against a sufficiently fragmented ask book (L-B).
            //   `max(floor, 1)` still guarantees a genuinely nonzero fill
            //   charges at least 1 quote atom, closing the same dust exploit
            //   the old ceiling guarded against.
            // - Taker-limited (maker order still has size left after this
            //   fill): unchanged, ceiling -- this fill's own boundary is
            //   already set by the taker's own budget/remaining_size, not by
            //   fully draining a maker, so there is no cross-maker
            //   superadditivity to worry about here.
            let quote_cost = if (fill_qty == maker_remaining) {
                let floor_u128 = ((best_price as u128) * (fill_qty as u128)) / (price_scale as u128);
                (if (floor_u128 < 1) { 1 } else { floor_u128 }) as u64
            } else {
                scaled_ceil_mul_div(best_price, fill_qty, price_scale)
            };

            let mut maker_order = level.level_remove_order(head_key);
            maker_order.decrease_remaining_size(fill_qty);
            let base_out = maker_order.split_escrow_base(fill_qty);
            // Taker fee (Base) is no longer deducted per-fill: the full,
            // gross `base_out` is joined as-is, and this fill's raw
            // pre-fee quantity is accumulated for a single aggregate
            // deduction once the whole matching loop (across every price
            // level) concludes -- see `match_bid` -- avoiding the
            // superadditive over-collection an independent per-fill
            // ceiling would otherwise cause (finding F-6).
            matched_base.join(base_out);

            let mut quote_payment = budget.split(quote_cost);
            // Maker fee (Quote, this is an ask-side maker) is likewise no
            // longer credited to the book's fee accumulator per-fill:
            // this fill's own ceiling-rounded contribution is set aside in
            // the maker order's own `fee_reserve_quote`, and only the
            // CORRECT aggregate fee is ever actually collected, at order
            // conclusion -- see `conclude_order_fee`.
            let maker_fee_bps = maker_order.maker_fee_bps();
            let maker_fee_quote_this_fill = fee_amount(quote_cost, maker_fee_bps);
            let quote_fee_balance = quote_payment.split(maker_fee_quote_this_fill);
            maker_order.join_fee_reserve_quote(quote_fee_balance);
            maker_order.increase_fee_basis_accumulated(quote_cost);

            let maker_addr = maker_order.owner();
            let maker_order_id = maker_order.id();
            let maker_remaining_after = maker_order.remaining_size();

            event::emit(OrderFilled {
                book_id: ids.book_id,
                enclosing_object_id: ids.enclosing_object_id,
                maker_order_id,
                price: best_price,
                size: fill_qty,
                maker: maker_addr,
                taker,
                maker_side: false,
                quote_amount: quote_cost,
            });

            *remaining_size = *remaining_size - fill_qty;
            book.last_price = best_price;

            if (maker_remaining_after == 0) {
                let fee_basis = maker_order.fee_basis_accumulated();
                let mfee_bps = maker_order.maker_fee_bps();
                let (eb, eq, frb, frq) = maker_order.destroy();
                destroy_drained_ask_escrow(eb, eq);
                let reserve_quote = extract_drained_ask_fee_reserve(frb, frq);
                let (slack_quote, fee_quote_collected) = conclude_order_fee(
                    reserve_quote, fee_basis, mfee_bps, maker_order_id, ids, maker_addr,
                );
                quote_payment.join(slack_quote);
                book.fee_accumulator.quote.join(fee_quote_collected);
                credit_maker_table(&mut book.proceeds, maker_order_id, maker_addr, balance::zero<Base>(), quote_payment);
            } else {
                credit_maker_table(&mut book.proceeds, maker_order_id, maker_addr, balance::zero<Base>(), quote_payment);
                level.level_insert_order_front(head_key, maker_order);
            };

            if (fill_qty < natural_fill_qty) {
                budget_exhausted = true;
                break
            };
        };
        is_empty_now = level.level_is_empty();
    };
    if (is_empty_now) {
        let removed = book.asks.remove(leaf_ptr);
        removed.destroy_empty_price_level();
    };
    (budget_exhausted, hit_max_fills)
}

fun match_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    budget_in: Balance<Quote>,
    taker: address,
    max_fills: u64,
): (Balance<Base>, Balance<Quote>, u64, bool) {
    let mut remaining_size = remaining_size_in;
    let mut budget = budget_in;
    let mut matched_base = balance::zero<Base>();
    let mut fills_consumed: u64 = 0;
    let mut stopped_on_max_fills_while_crossing = false;

    loop {
        if (remaining_size == 0) break;
        let best_opt = book.asks.min_leaf();
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let best_price = book.asks.key(leaf_ptr);
        if (limit_price.is_some() && best_price > *limit_price.borrow()) break;

        if (fills_consumed == max_fills) {
            stopped_on_max_fills_while_crossing = true;
            break
        };

        let (stop, hit_max_fills) = fill_level_bid(
            book,
            leaf_ptr,
            best_price,
            &mut remaining_size,
            &mut budget,
            &mut matched_base,
            taker,
            &mut fills_consumed,
            max_fills,
        );
        if (hit_max_fills) stopped_on_max_fills_while_crossing = true;
        if (stop) break;
    };

    (matched_base, budget, remaining_size, stopped_on_max_fills_while_crossing)
}

fun fill_level_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    escrow_base: &mut Balance<Base>,
    matched_quote: &mut Balance<Quote>,
    taker: address,
    fills_consumed: &mut u64,
    max_fills: u64,
): (bool, bool) {
    let ids = book.book_ids();
    // Note: unlike `fill_level_bid`, this function no longer reads
    // `book.price_scale` at all -- a resting bid's own `total_reserved`/
    // `original_size` ratio already fixes its price (every fill against a
    // single resting order happens at that order's own resting price, by
    // construction of price-level matching), so the cumulative-proportional
    // charging scheme in the loop below needs no separate `price`/
    // `price_scale` input.
    let mut stop = false;
    let mut hit_max_fills = false;
    let is_empty_now;
    {
        let level = book.bids.borrow_mut(leaf_ptr);
        loop {
            if (*remaining_size == 0) break;
            if (level.level_is_empty()) break;
            if (*fills_consumed == max_fills) {
                stop = true;
                hit_max_fills = true;
                break
            };
            let head_key = level.level_front_order_id().destroy_some();
            *fills_consumed = *fills_consumed + 1;
            // `maker_remaining` here is the resting bid's remaining BASE
            // capacity -- derived, NOT read directly off `remaining_size`
            // (which is Quote-denominated for a bid-side order; see
            // `order::Order.remaining_size`'s doc comment). `fee_basis_accumulated`
            // doubles as the running cumulative-Base-filled counter for a
            // bid-side order (see its own doc comment) -- reading it here,
            // BEFORE this fill's own increment below, is exactly the
            // "already filled" quantity needed to derive what's left.
            let original_size = level.level_borrow_order(head_key).original_size();
            let cumulative_before = level.level_borrow_order(head_key).fee_basis_accumulated();
            let maker_remaining = original_size - cumulative_before;
            let fill_qty = std::u64::min(*remaining_size, maker_remaining);

            let mut maker_order = level.level_remove_order(head_key);
            // Maker-side (bid-resting-order) charge: a delta-of-cumulative-
            // proportional-ceiling scheme, not an independent per-fill
            // ceiling/floor. See `original_size`'s doc comment in
            // `order.move` for the full derivation. In short:
            //
            //   target_charge  = ceil(total_reserved * cumulative_after / original_size)
            //   quote_cost     = target_charge - already_charged
            //
            // where `cumulative_after = cumulative_before + fill_qty` and
            // `already_charged = total_reserved - escrow_quote_value` (every
            // fill decrements the live escrow by exactly what it charges, so
            // this is always exactly right, with no separately-tracked
            // running total needed).
            //
            // This ONE formula covers both the taker-limited and the
            // maker-limited (fully-draining) case uniformly, with no special
            // branch: when `cumulative_after == original_size` (this fill
            // fully drains the order), `ceil(total_reserved * original_size /
            // original_size) == total_reserved` exactly, so `quote_cost`
            // collapses to `total_reserved - already_charged`, i.e. exactly
            // whatever remains in escrow -- a full drain to zero is
            // mathematically forced regardless of formula (money
            // conservation leaves no other choice), so this is not a special
            // case at all, just what the general formula already produces.
            //
            // Why this formula, and not the simpler "independently
            // ceiling-round every fill's own `price * fill_qty /
            // price_scale`" (which might look like the more obvious
            // "fairness fix" for the maker-limited case): that simpler
            // approach is exactly what three prior, separate experiments on
            // this project already tried (applying a ceil/upper-bound
            // conversion uniformly to every fill) and found broken --
            // independent per-fill ceiling is superadditive across a
            // fragmented sequence of fills, so it can exhaust a resting
            // bid's *actual* Quote escrow before its full Base size is
            // delivered, under-filling the order (e.g. delivering only 95 of
            // an intended 100 Base). The cumulative scheme above cannot do
            // this: Base delivery is governed purely by exact Base
            // arithmetic (`original_size - fee_basis_accumulated`, no
            // rounding anywhere in that derivation), and the Quote charged
            // telescopes to exactly `total_reserved` by construction, so
            // full Base delivery and exact Quote conservation both hold
            // simultaneously, always -- while still charging the earlier,
            // taker-limited fills closer to their own fair (isolated-ceil)
            // value than the old floor-based formula did, which is what
            // actually reduces (though, being an apportionment problem, does
            // not perfectly eliminate) how much rounding slack the final
            // fill absorbs relative to a hypothetical isolated trade.
            let total_reserved = maker_order.total_reserved();
            let cumulative_after = cumulative_before + fill_qty;
            let target_charge = scaled_ceil_mul_div(total_reserved, cumulative_after, original_size);
            let already_charged = total_reserved - maker_order.escrow_quote_value();
            let quote_cost = target_charge - already_charged;
            maker_order.decrease_remaining_size(quote_cost);

            let quote_out = maker_order.split_escrow_quote(quote_cost);
            // Taker fee (Quote) is no longer deducted per-fill -- see the
            // matching comment in `fill_level_bid`.
            matched_quote.join(quote_out);

            let mut base_payment = escrow_base.split(fill_qty);
            // Maker fee (Base, this is a bid-side maker) is set aside in
            // the maker order's own `fee_reserve_base` -- see the matching
            // comment in `fill_level_bid`.
            let maker_fee_bps = maker_order.maker_fee_bps();
            let maker_fee_base_this_fill = fee_amount(fill_qty, maker_fee_bps);
            let base_fee_balance = base_payment.split(maker_fee_base_this_fill);
            maker_order.join_fee_reserve_base(base_fee_balance);
            maker_order.increase_fee_basis_accumulated(fill_qty);

            let maker_addr = maker_order.owner();
            let maker_order_id = maker_order.id();
            // `original_size - cumulative_after` -- exact Base arithmetic,
            // matches `maker_remaining` above (`fee_basis_accumulated` was
            // just incremented by `fill_qty` above, so this order's own
            // accessor already reflects `cumulative_after`). NOT
            // `maker_order.remaining_size()`, which is Quote-denominated for
            // a bid-side order and would answer a different question (how
            // much Quote capacity is left, not whether Base capacity hit 0 --
            // though by construction both reach their respective zero at
            // exactly the same fill; see the formula derivation above).
            let maker_remaining_after = original_size - maker_order.fee_basis_accumulated();

            event::emit(OrderFilled {
                book_id: ids.book_id,
                enclosing_object_id: ids.enclosing_object_id,
                maker_order_id,
                price: best_price,
                size: fill_qty,
                maker: maker_addr,
                taker,
                maker_side: true,
                quote_amount: quote_cost,
            });

            *remaining_size = *remaining_size - fill_qty;
            book.last_price = best_price;

            if (maker_remaining_after == 0) {
                let fee_basis = maker_order.fee_basis_accumulated();
                let mfee_bps = maker_order.maker_fee_bps();
                let (eb, eq, frb, frq) = maker_order.destroy();
                destroy_drained_bid_escrow(eb, eq);
                let reserve_base = extract_drained_bid_fee_reserve(frb, frq);
                let (slack_base, fee_base_collected) = conclude_order_fee(
                    reserve_base, fee_basis, mfee_bps, maker_order_id, ids, maker_addr,
                );
                base_payment.join(slack_base);
                book.fee_accumulator.base.join(fee_base_collected);
                credit_maker_table(&mut book.proceeds, maker_order_id, maker_addr, base_payment, balance::zero<Quote>());
            } else {
                credit_maker_table(&mut book.proceeds, maker_order_id, maker_addr, base_payment, balance::zero<Quote>());
                level.level_insert_order_front(head_key, maker_order);
            };
        };
        is_empty_now = level.level_is_empty();
    };
    if (is_empty_now) {
        let removed = book.bids.remove(leaf_ptr);
        removed.destroy_empty_price_level();
    };
    (stop, hit_max_fills)
}

fun match_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    escrow_base_in: Balance<Base>,
    taker: address,
    max_fills: u64,
): (Balance<Quote>, Balance<Base>, u64, bool) {
    let mut remaining_size = remaining_size_in;
    let mut escrow_base = escrow_base_in;
    let mut matched_quote = balance::zero<Quote>();
    let mut fills_consumed: u64 = 0;
    let mut stopped_on_max_fills_while_crossing = false;

    loop {
        if (remaining_size == 0) break;
        let best_opt = book.bids.max_leaf();
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let best_price = book.bids.key(leaf_ptr);
        if (limit_price.is_some() && best_price < *limit_price.borrow()) break;

        if (fills_consumed == max_fills) {
            stopped_on_max_fills_while_crossing = true;
            break
        };

        let (stop, hit_max_fills) = fill_level_ask(
            book,
            leaf_ptr,
            best_price,
            &mut remaining_size,
            &mut escrow_base,
            &mut matched_quote,
            taker,
            &mut fills_consumed,
            max_fills,
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
    /// (`object::uid_to_inner(&book.id)`), NOT to `book.enclosing_object_id`.
    /// This makes it unforgeable regardless of what `enclosing_object_id` a
    /// book was constructed with — `enclosing_object_id` is caller-supplied
    /// and must never be used to authenticate a ticket. `cancel_order` and
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
/// used by two callers, each safe for a different reason. `claim_proceeds`
/// calls it having just guaranteed by construction that `book.proceeds`
/// holds no entry for this ticket's `order_id` (it has just drained that
/// entry via `claim_maker_balance`). `destroy_ticket_unconditionally`
/// (below) calls it with no such guarantee at all, by design — see that
/// function's own doc comment for why that is still safe. Any other caller
/// must use the guarded public `destroy_orphaned_ticket` below instead.
public(package) fun destroy_orphaned_ticket_unchecked(ticket: OrderTicket) {
    let OrderTicket { order_id: _, order_book_id: _, side: _, price: _ } = ticket;
}

/// Guarded disposal: aborts with `EWrongBook` if `ticket` wasn't minted by
/// `book`, with `EProceedsNotEmpty` if `book.proceeds` still holds an entry
/// for this ticket's `order_id` — destroying the ticket in that case would
/// permanently strand those pooled funds, since nothing else can ever
/// reference that `order_id` again — and with `EOrderStillResting` if the
/// order is still resting on `book`. While the order and the book both
/// still exist, this ticket remains the only self-service path back to
/// that order's escrow (`cancel_order` requires it by value); destroying it
/// here would give that up for no reason a caller couldn't achieve just as
/// well by calling `cancel_order` instead. Use `destroy_ticket_unconditionally`
/// once the book itself is gone — see that function's own doc comment for
/// why a live-book check has no answer at that point.
public fun destroy_orphaned_ticket<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    ticket: OrderTicket,
) {
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    assert!(!book.proceeds.contains(ticket.order_id), EProceedsNotEmpty);
    assert!(
        resting_order_escrow(book, ticket.side, ticket.price, ticket.order_id).is_none(),
        EOrderStillResting,
    );
    destroy_orphaned_ticket_unchecked(ticket);
}

/// Unconditionally destroys `ticket` with no liveness or safety check of
/// any kind, and — unlike every other ticket function — no `OrderBook`
/// parameter at all. This is intentional, not an oversight: `OrderBook`
/// has `store` only, and once `clob_admin_finalize` consumes and deletes
/// one, nothing in Move can ever again prove whether a given book still
/// exists. Requiring a live book reference (as `destroy_orphaned_ticket`
/// does) therefore has no answer once the book is genuinely gone — this
/// function exists specifically to dispose of a ticket in that situation.
///
/// It is safe to call even while the referenced book is still alive,
/// including when its order might still hold real escrow or pooled
/// proceeds: a ticket has never been the *only* path back to either.
/// `clob_admin_cancel_order` force-cancels a still-resting order using
/// just `(side, price, order_id)` — all public via `OrderPlaced` — with no
/// ticket needed, and `push_proceeds`/`clob_admin_drain_step` reach pooled
/// proceeds by `order_id` alone. Calling this function only ever gives up
/// the ticket holder's own convenient self-service path
/// (`cancel_order`/`claim_proceeds`/`destroy_orphaned_ticket`); it never
/// strands anything the book's admin-gated recovery paths can't still
/// reach. And if the book has already been finalized, `clob_admin_finalize`'s
/// own precondition (zero resting orders, zero pooled proceeds, zero fee
/// balances) guarantees nothing of value was ever left attached to any
/// ticket for it in the first place.
public fun destroy_ticket_unconditionally(ticket: OrderTicket) {
    destroy_orphaned_ticket_unchecked(ticket);
}

// === Order placement, cancellation, and proceeds claiming ===

public struct OrderPlaced has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    order_id: u64,
    side: bool,
    price: u64,
    size: u64,
    trader: address,
    maker_fee_bps: u64,
}

public struct ProceedsClaimed has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    claimant: address,
    base_amount: u64,
    quote_amount: u64,
}

/// Emitted exactly once, unconditionally, as the final event of every call to
/// `place_limit_order_bid`/`place_limit_order_ask`/`place_market_order_bid`/
/// `place_market_order_ask` (identified by
/// `entry_point`, see below) — after any slippage-guard asserts in the
/// market functions, so an abort emits nothing.
///
/// Event-ordering contract: within one call, the sequence is zero-or-more
/// `OrderFilled`, then an optional `OrderPlaced`, then exactly one
/// `OrderExecuted` as a trailer — correlating fills to their triggering call
/// relies on this within-transaction ordering (Sui's event ordering within a
/// transaction's effects is deterministic).
public struct OrderExecuted has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    taker: address,
    taker_side: bool,
    /// 0 = place_limit_order_bid, 1 = place_limit_order_ask,
    /// 2 = place_market_order_bid, 3 = place_market_order_ask.
    /// (Entry point values 4 and 5, formerly `swap_bid`/`swap_ask`, are no
    /// longer produced now that those functions have been removed; they are
    /// not reused for anything else.)
    entry_point: u8,
    /// `None` for market orders; for `place_limit_order_*`, the
    /// resting/placement price.
    limit_price: Option<u64>,
    /// The order's Base-denominated size: for `place_limit_order_bid`, the
    /// caller's `expected_base_output`; for `place_limit_order_ask`, the
    /// caller's `payment.value()`; for `place_market_order_bid`, `max_base_out`;
    /// for `place_market_order_ask`, `min(payment.value(), max_base_in)`.
    requested_size: u64,
    /// Remaining size after matching. For `entry_point` 0 (limit bid), the
    /// taker fee is charged in BASE (the side being received), and this
    /// field is GROSS -- NOT reduced by that fee -- so `requested_size -
    /// unmatched_size` does not equal the base actually returned to the
    /// taker when `taker_fee_bps > 0`. For `entry_point` 1 (limit ask) and 3
    /// (market ask), the taker fee is instead charged in QUOTE (the side
    /// being received on those paths), never in Base, so this caveat does
    /// not apply at all: `requested_size - unmatched_size` always equals the
    /// Base actually sold, fee or no fee. For `entry_point` 2
    /// (`place_market_order_bid`) specifically, this is the NET shortfall
    /// against the caller's own NET `max_base_out` request (`max_base_out -
    /// matched_base.value()`, where `matched_base` is already post-fee) --
    /// so for that one entry point too, `requested_size - unmatched_size`
    /// equals the base actually delivered to the taker.
    unmatched_size: u64,
    /// 0 if nothing ends up resting. On the bid limit path this can be LESS
    /// than `unmatched_size` even when something rests, because
    /// `place_limit_order_bid` clamps the resting size to what leftover
    /// escrow can actually back (ceiling-division superadditivity) — this is
    /// expected, not a bug.
    rested_size: u64,
    /// `Some(id)` iff something rested this call, else `None`.
    rested_order_id: Option<u64>,
    stopped_on_max_fills_while_crossing: bool,
    /// The taker's own fee for this call, computed once, in aggregate,
    /// after matching completes — `fee_amount(taker_fee_basis,
    /// taker_fee_bps)` — and already deducted from `matched_base`/
    /// `matched_quote` (whichever the taker receives) before the slippage
    /// checks in `place_market_order_*` and before the coin(s)
    /// returned to the taker. Denominated in Base for a bid-side taker
    /// (`taker_side == true`), Quote for an ask-side taker
    /// (`taker_side == false`). Replaces the old per-fill
    /// `OrderFilled.taker_fee_amount` field, which could over-collect across
    /// many small fills (finding F-6).
    taker_fee_amount: u64,
}

/// `payment`'s ENTIRE value is derived, up front, into the implied limit
/// `price` for a resting bid targeting exactly `expected_base_output` Base
/// (`price = floor(payment.value() * price_scale / expected_base_output)`).
/// This choice of rounding direction guarantees `bid_escrow_amount(book,
/// price, expected_base_output) <= payment.value()` always (the identity
/// `ceil(a/b) <= c <=> a <= c*b` applied to `price * expected_base_output <=
/// payment.value() * price_scale`, which holds by construction of `price`
/// via `floor`) -- so this function can never itself abort for lack of funds
/// on account of this derivation, and any of `payment` left over after
/// `bid_escrow_amount` is taken (rounding slack from the `floor`, at most
/// `price_scale - 1` raw price-scale units' worth of Quote, plus whatever
/// isn't matched/rested) is returned to the caller.
///
/// `price` is a raw, book-relative unit -- see the module doc comment for
/// how it decodes to a true price via `price_scale`/`precision`/`exponent`,
/// and `clob_admin_set_price_band_factor` for the optional additional band
/// safeguard. Both checks are enforced here immediately after the derived
/// price is computed and its zero-price check, before any escrow is taken.
/// Deriving `price` from real quantities like this -- rather than accepting
/// it as a caller-supplied argument -- is deliberate: raw `price` is an
/// internal, `price_scale`-denominated unit that is easy to misinterpret
/// (e.g. mistaking `price = 2` for "2 tokens per token"), so this is the
/// only way to place a resting limit bid.
///
/// PRECISION NOTE: `price_scale` is chosen (see `price_scale`'s doc comment)
/// as the smallest value guaranteeing resolution at least as fine as the
/// book's declared `10^-precision` -- not the near-`u64::MAX` value a book
/// might otherwise have used. As a result, this derived `price` snaps down
/// to the nearest whole declared tick (a multiple of the book's minimum
/// representable price increment) rather than tracking `payment`'s implied
/// ratio near-exactly; the rounding-slack bound below (`price_scale - 1`
/// raw units) is correspondingly smaller in absolute terms, but expressed as
/// a fraction of true price it is still bounded by the book's declared
/// `precision`. This remains fund-safe either way -- the `floor` rounding
/// direction still guarantees `bid_escrow_amount(...) <= payment.value()`.
///
/// WORST-CASE RESTING PRICE WARNING: this derived `price` is the MAXIMUM
/// price `payment`'s whole value implies for `expected_base_output` -- it is
/// used both to cross the book AND, unchanged, as the price any unfilled
/// remainder RESTS at. That resting price is the worst case from a "paying
/// too much" perspective (it is the highest price this payment could imply),
/// so a caller whose order does not fully fill can end up with a resting bid
/// parked indefinitely at a price considerably above what a tighter,
/// hand-computed limit price would have used. This is a deliberate tradeoff,
/// not a bug: it is exactly what guarantees the fund-safety property above
/// (this function can never abort for lack of funds).
///
/// Aborts with `EZeroPrice` if the derived `price` rounds down to `0` (e.g.
/// `payment` too small relative to `expected_base_output`). Aborts with
/// `EPriceOverflow` if the derived price would overflow `u64`.
public fun place_limit_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    mut payment: Coin<Quote>,
    expected_base_output: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, expected_base_output);
    let price_scale = book.price_scale;
    let price_u128 = ((payment.value() as u128) * (price_scale as u128)) / (expected_base_output as u128);
    assert!(price_u128 <= U64_MAX, EPriceOverflow);
    let price = price_u128 as u64;
    assert!(price != 0, EZeroPrice);
    assert_price_in_declared_range(
        price, price_scale, book.base_decimals, book.quote_decimals, book.precision, book.exponent,
    );
    if (book.price_band_factor.is_some()) {
        let factor = *book.price_band_factor.borrow();
        assert!((price as u128) * (factor as u128) >= (book.last_price as u128), EPriceBelowBand);
        assert!((price as u128) <= (book.last_price as u128) * (factor as u128), EPriceAboveBand);
    };
    let size = expected_base_output;

    let escrow_amount = bid_escrow_amount(book, price, size);
    let mut escrow = payment.split(escrow_amount, ctx).into_balance();

    let ids = book.book_ids();
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (mut matched_base, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(book, option::some(price), size, escrow, taker, max_fills);
    let taker_fee_amount = fee_amount(matched_base.value(), taker_fee_bps);
    let taker_fee_balance = matched_base.split(taker_fee_amount);
    book.fee_accumulator.base.join(taker_fee_balance);
    escrow = remaining_escrow;

    let order_id = next_order_id(book);
    // Derive the resting remainder's size from what the taker's leftover
    // escrow can actually back, rather than resting the full unmatched
    // `remaining_size` and possibly under-funding it: a fresh
    // `bid_escrow_amount(book, price, remaining_size)` recomputation can, by
    // ceiling-division superadditivity, demand strictly more than what's
    // actually left over after the crossing sweep. Narrowing to `u64`
    // happens AFTER the min-clamp, matching `fill_level_bid`'s
    // affordable-quantity pattern. This mathematically guarantees
    // `resting_escrow_amount <= escrow.value()` always (the
    // identity `ceil(a/b) <= c <=> a <= c*b`), so the `balance::split` below
    // can never abort.
    let max_size_available_can_back_u128 =
        ((escrow.value() as u128) * (price_scale as u128)) / (price as u128);
    let remaining_size_u128 = remaining_size as u128;
    let actual_resting_size =
        (if (remaining_size_u128 < max_size_available_can_back_u128) { remaining_size_u128 }
        else { max_size_available_can_back_u128 }) as u64;
    // Gates on `actual_resting_size`, NOT raw `remaining_size` — a resting
    // bid with real displayed size but zero/insufficient escrow must never
    // be created.
    let should_rest = actual_resting_size > 0 && !stopped_on_max_fills_while_crossing;
    let ticket_opt = if (should_rest) {
        let resting_escrow_amount = bid_escrow_amount(book, price, actual_resting_size);
        let resting_escrow = escrow.split(resting_escrow_amount);
        payment.join(escrow.into_coin(ctx));
        // Snapshot the book's *current* maker-fee rate at the exact moment
        // this resting order is constructed; later fee-rate changes never
        // retroactively affect an already-resting order.
        let maker_fee_bps_snapshot = maker_fee_bps(book);
        let resting = order::new(
            order_id,
            taker,
            actual_resting_size,
            option::none(),
            option::some(resting_escrow),
            maker_fee_bps_snapshot,
        );
        insert_resting_order(book, true, price, resting, ctx);
        event::emit(OrderPlaced {
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            order_id,
            side: true,
            price,
            size: actual_resting_size,
            trader: taker,
            maker_fee_bps: maker_fee_bps_snapshot,
        });
        option::some(OrderTicket {
            order_id,
            order_book_id: object::uid_to_inner(&book.id),
            side: true,
            price,
        })
    } else {
        payment.join(escrow.into_coin(ctx));
        option::none()
    };

    let rested_size = if (should_rest) actual_resting_size else 0;
    let rested_order_id = if (should_rest) option::some(order_id) else option::none();
    event::emit(OrderExecuted {
        book_id: ids.book_id,
        enclosing_object_id: ids.enclosing_object_id,
        taker,
        taker_side: true,
        entry_point: 0,
        limit_price: option::some(price),
        requested_size: size,
        unmatched_size: remaining_size,
        rested_size,
        rested_order_id,
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
    });

    (ticket_opt, matched_base.into_coin(ctx), payment, stopped_on_max_fills_while_crossing)
}

/// `payment`'s entire value (`payment.value()`) is the resting ask's `size`
/// -- the whole coin is escrowed. The implied limit `price` is derived from
/// `expected_quote_output` via `price = ceil(expected_quote_output *
/// price_scale / size)`, i.e. the lowest price at which fully filling this
/// ask would yield AT LEAST `expected_quote_output` Quote -- matching a "sell
/// this whole coin for at least this much" intent. There is no rounding-slack
/// leftover to return here: an ask's escrow is exactly `size` Base with no
/// price-scale conversion involved.
///
/// `price` is a raw, book-relative unit -- see `place_limit_order_bid`'s doc
/// comment for the full note on price-range/band checks, and for why `price`
/// is derived from real quantities rather than accepted as a caller-supplied
/// argument: raw `price` is an internal, `price_scale`-denominated unit that
/// is easy to misinterpret, so this is the only way to place a resting limit
/// ask.
///
/// PRECISION NOTE: as with `place_limit_order_bid`, `price_scale` is the
/// smallest value guaranteeing resolution at least as fine as the book's
/// declared `10^-precision` (see `price_scale`'s doc comment), not a
/// near-`u64::MAX` value -- so this derived `price` snaps up to the nearest
/// whole declared tick rather than tracking `expected_quote_output`'s
/// implied ratio near-exactly. This remains fund-safe: the `ceil` rounding
/// direction still guarantees fully filling `size` at the derived price
/// yields at least `expected_quote_output`.
///
/// WORST-CASE RESTING PRICE WARNING (mirrors `place_limit_order_bid`, same
/// direction of concern for an ask maker): this derived `price` is the
/// LOWEST price satisfying "fully filling `size` yields at least
/// `expected_quote_output`" -- it is used both to cross the book AND,
/// unchanged, as the price any unfilled remainder RESTS at. A lower price is
/// worse for an ask's maker (less Quote received per unit sold), so a
/// caller whose order does not fully fill can end up with a resting ask
/// parked indefinitely at a price lower than a tighter, hand-computed limit
/// price would have used. This is deliberate, not a bug -- it is what
/// guarantees this function's escrow is never starved of Base for the
/// implied price/size pair.
///
/// Aborts with `EZeroPrice` if `expected_quote_output == 0` (the derived
/// price would round down to `0`). Aborts with `EPriceOverflow` if the
/// derived price would overflow `u64`.
public fun place_limit_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    mut payment: Coin<Base>,
    expected_quote_output: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    let size = payment.value();
    validate_size(book, size);
    let price_scale = book.price_scale;
    let price_u128 = ((expected_quote_output as u128) * (price_scale as u128) + (size as u128) - 1) / (size as u128);
    assert!(price_u128 <= U64_MAX, EPriceOverflow);
    let price = price_u128 as u64;
    assert!(price != 0, EZeroPrice);
    assert_price_in_declared_range(
        price, price_scale, book.base_decimals, book.quote_decimals, book.precision, book.exponent,
    );
    if (book.price_band_factor.is_some()) {
        let factor = *book.price_band_factor.borrow();
        assert!((price as u128) * (factor as u128) >= (book.last_price as u128), EPriceBelowBand);
        assert!((price as u128) <= (book.last_price as u128) * (factor as u128), EPriceAboveBand);
    };

    let escrow_base = payment.split(size, ctx).into_balance();

    let ids = book.book_ids();
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (mut matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(book, option::some(price), size, escrow_base, taker, max_fills);
    let taker_fee_amount = fee_amount(matched_quote.value(), taker_fee_bps);
    let taker_fee_balance = matched_quote.split(taker_fee_amount);
    book.fee_accumulator.quote.join(taker_fee_balance);

    let order_id = next_order_id(book);
    let should_rest = remaining_size > 0 && !stopped_on_max_fills_while_crossing;
    let ticket_opt = if (should_rest) {
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
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            order_id,
            side: false,
            price,
            size: remaining_size,
            trader: taker,
            maker_fee_bps: maker_fee_bps_snapshot,
        });
        option::some(OrderTicket {
            order_id,
            order_book_id: object::uid_to_inner(&book.id),
            side: false,
            price,
        })
    } else {
        payment.join(remaining_escrow.into_coin(ctx));
        option::none()
    };

    let rested_size = if (should_rest) remaining_size else 0;
    let rested_order_id = if (should_rest) option::some(order_id) else option::none();
    event::emit(OrderExecuted {
        book_id: ids.book_id,
        enclosing_object_id: ids.enclosing_object_id,
        taker,
        taker_side: false,
        entry_point: 1,
        limit_price: option::some(price),
        requested_size: size,
        unmatched_size: remaining_size,
        rested_size,
        rested_order_id,
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
    });

    (ticket_opt, payment, matched_quote.into_coin(ctx), stopped_on_max_fills_while_crossing)
}

/// `payment`'s value, optionally capped by `max_quote_in`, is the taker's
/// Quote budget -- there is no separate `budget` parameter (unlike the old
/// `size`/`budget`/`Option`-wrapped-slippage-guard interface this replaces).
/// This is a REDESIGNED interface, not a drop-in replacement for the old
/// `(size, budget, payment, max_fills, max_quote_in: Option<u64>,
/// min_base_out: Option<u64>)` signature -- do not mechanically migrate a
/// caller by positionally renaming old arguments onto the new ones; every
/// parameter's meaning and type changed:
///
/// - `max_base_out` (`u64`, `0` = a real zero cap that immediately no-ops
///   with nothing matched; `u64::MAX` = unbounded) replaces the old,
///   mandatory `size` parameter -- it caps how much Base this call will ever
///   deliver. Like `min_base_out`, this is a NET (post-fee) cap: it bounds
///   the Base the taker actually receives, after the taker fee is deducted,
///   not the gross amount matched against the book. Internally, the GROSS
///   bound fed to matching is inflated from `max_base_out` (via
///   `gross_size_bound_for_net_cap`) so that the post-fee net delivered
///   amount never exceeds it -- so `min_base_out == max_base_out` is always
///   satisfiable when fully filled, regardless of `taker_fee_bps`.
/// - `max_quote_in` (`u64`, same `0`-is-real / `u64::MAX`-is-unbounded
///   convention) replaces the old `budget` parameter AND the old
///   `max_quote_in: Option<u64>` slippage guard in one: unlike the old
///   interface, where `budget` (escrowed up front) and `max_quote_in`
///   (asserted after the fact) were two independent knobs, this cap is now
///   enforced up front, by construction -- at most `min(payment.value(),
///   max_quote_in)` is ever escrowed/spent, so there is nothing left to
///   assert post-hoc and no way for matching itself to spend past it.
/// - `min_base_out` (`u64`, `0` = not applicable) is the slippage floor,
///   replacing the old `Option<u64>` guard of the same name -- unchanged in
///   spirit, just unwrapped from `Option`.
///
/// Any of `payment` not spent (beyond `max_quote_in`, or left over after
/// matching) is returned to the caller as the second output coin.
///
/// Unlike `place_market_order_ask`, there is deliberately no `validate_size`
/// call against `max_base_out`/`min_size` here: a market bid never rests an
/// order (any unmatched remainder is simply returned), so it can never
/// create a sub-`min_size` dust order on the book -- `validate_size`'s
/// entire purpose (see its own doc comment) is bounding what can rest, which
/// does not apply to a call that never rests anything.
///
/// Aborts with `EMinExceedsMaxBaseOut` if `min_base_out > max_base_out` --
/// both are Base-denominated, so this combination can never be satisfied
/// regardless of matching, and is rejected up front.
public fun place_market_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    mut payment: Coin<Quote>,
    max_fills: u64,
    min_base_out: u64,
    max_base_out: u64,
    max_quote_in: u64,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    // Both are Base-denominated, so this ordering constraint is
    // unconditional (not just a special case of `max_base_out == 0`):
    // `min_base_out > max_base_out` can never be satisfied no matter what
    // matches, and the `u64::MAX` "unbounded" sentinel for `max_base_out`
    // (see this function's doc comment) trivially satisfies this assert on
    // its own, so no separate unbounded-case logic is needed here.
    assert!(min_base_out <= max_base_out, EMinExceedsMaxBaseOut);

    let budget = std::u64::min(payment.value(), max_quote_in);
    let budget_balance = payment.split(budget, ctx).into_balance();
    let ids = book.book_ids();
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    // `max_base_out` is a NET (post-fee) cap -- see this function's doc
    // comment -- but `match_bid` matches against a GROSS bound and the fee
    // is only known/deducted afterward, so it is inflated here to the
    // equivalent gross bound via `gross_size_bound_for_net_cap`.
    let size_bound = gross_size_bound_for_net_cap(max_base_out, taker_fee_bps);
    let (mut matched_base, remaining_budget, _remaining_size, stopped_on_max_fills_while_crossing) =
        match_bid(book, option::none(), size_bound, budget_balance, taker, max_fills);
    let taker_fee_amount = fee_amount(matched_base.value(), taker_fee_bps);
    let taker_fee_balance = matched_base.split(taker_fee_amount);
    book.fee_accumulator.base.join(taker_fee_balance);

    if (min_base_out != 0) {
        assert!(matched_base.value() >= min_base_out, ESlippageExceeded);
    };

    payment.join(remaining_budget.into_coin(ctx));

    // `remaining_size` from `match_bid` is GROSS, relative to the inflated
    // `size_bound`, not to `max_base_out` -- so it is not reported directly.
    // Instead, the NET shortfall against the caller's actual (NET) request
    // is `max_base_out - matched_base.value()`, which never underflows:
    // `matched_base.value() <= max_base_out` always holds, since `size_bound`
    // was chosen (via `gross_size_bound_for_net_cap`) so that fully matching
    // it nets out to exactly `max_base_out`, and net is monotonic
    // non-decreasing in the gross amount matched.
    let base_unmatched = max_base_out - matched_base.value();

    event::emit(OrderExecuted {
        book_id: ids.book_id,
        enclosing_object_id: ids.enclosing_object_id,
        taker,
        taker_side: true,
        entry_point: 2,
        limit_price: option::none(),
        requested_size: max_base_out,
        unmatched_size: base_unmatched,
        rested_size: 0,
        rested_order_id: option::none(),
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
    });

    (matched_base.into_coin(ctx), payment, stopped_on_max_fills_while_crossing)
}

/// `payment`'s value, optionally capped by `max_base_in` (`u64`, `0` = a
/// real zero cap that immediately no-ops with nothing matched and `payment`
/// returned untouched; `u64::MAX` = unbounded -- replacing the old explicit
/// `size` parameter), is how much Base this call sells; any of `payment`
/// beyond that cap is returned unspent. `min_quote_out` (`0` = not
/// applicable) is the slippage floor, replacing the old `Option<u64>`
/// guard. There is no `budget`-equivalent parameter here (an ask was never
/// budget-gated) and no replacement for the old `max_base_in` spend-guard
/// beyond the cap itself, which is now enforced up front by construction
/// (via the `min(payment.value(), max_base_in)` clamp below) rather than
/// checked after the fact.
///
/// Like `place_market_order_bid`, there is deliberately no `validate_size`
/// call against `max_base_in`/`min_size` here: a market ask never rests an
/// order (any unmatched remainder is simply returned), so it can never
/// create a sub-`min_size` dust order on the book.
public fun place_market_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    mut payment: Coin<Base>,
    max_fills: u64,
    min_quote_out: u64,
    max_base_in: u64,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);

    let size = std::u64::min(payment.value(), max_base_in);
    let escrow_base = payment.split(size, ctx).into_balance();
    let ids = book.book_ids();
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (mut matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing) =
        match_ask(book, option::none(), size, escrow_base, taker, max_fills);
    let taker_fee_amount = fee_amount(matched_quote.value(), taker_fee_bps);
    let taker_fee_balance = matched_quote.split(taker_fee_amount);
    book.fee_accumulator.quote.join(taker_fee_balance);

    if (min_quote_out != 0) {
        assert!(matched_quote.value() >= min_quote_out, ESlippageExceeded);
    };

    payment.join(remaining_escrow.into_coin(ctx));

    event::emit(OrderExecuted {
        book_id: ids.book_id,
        enclosing_object_id: ids.enclosing_object_id,
        taker,
        taker_side: false,
        entry_point: 3,
        limit_price: option::none(),
        requested_size: size,
        unmatched_size: remaining_size,
        rested_size: 0,
        rested_order_id: option::none(),
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
    });

    (payment, matched_quote.into_coin(ctx), stopped_on_max_fills_while_crossing)
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
    let ids = book.book_ids();
    let OrderTicket { order_id, order_book_id: _, side, price } = ticket;

    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let order_opt = tree.find_and_remove_order(price, order_id);

    let (mut escrow_base, mut escrow_quote) = if (order_opt.is_none()) {
        order_opt.destroy_none();
        (option::none(), option::none())
    } else {
        let live_order = order_opt.destroy_some();
        let trader = live_order.owner();
        let fee_basis = live_order.fee_basis_accumulated();
        let mfee_bps = live_order.maker_fee_bps();
        let (eb, eq, frb, frq) = live_order.destroy();
        let (eb, eq) = fold_maker_fee_slack(
            eb, eq, frb, frq, fee_basis, mfee_bps, order_id, ids, trader, &mut book.fee_accumulator,
        );
        event::emit(OrderCancelled {
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            order_id,
            trader,
        });
        (eb, eq)
    };

    let (_owner, proceeds_base, proceeds_quote) = claim_maker_balance(book, order_id);
    let proceeds_base_amount = proceeds_base.value();
    let proceeds_quote_amount = proceeds_quote.value();

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
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            claimant: ctx.sender(),
            base_amount: proceeds_base_amount,
            quote_amount: proceeds_quote_amount,
        });
    };

    let base_coin = coin_or_zero(base_balance, ctx);
    let quote_coin = coin_or_zero(quote_balance, ctx);
    (base_coin, quote_coin)
}

public struct OrderOwnerUpdated has copy, drop {
    book_id: ID,
    enclosing_object_id: ID,
    order_id: u64,
    old_owner: address,
    new_owner: address,
}

/// Finds the resting order identified by `ticket` and overwrites its
/// `owner` field in place. Returns `true` if an order was found and
/// updated, `false` if the price level or the order itself doesn't exist (a
/// no-op, mirroring `cancel_order`'s own not-found-is-a-no-op handling).
/// Rejects `new_owner == @0x0` outright, since `owner` is the destination
/// every recorded-address payout path (escrow refunds, pooled proceeds
/// sweeps) later pays to, and a zero address there would silently burn
/// those funds.
///
/// Emits `OrderOwnerUpdated { book_id, enclosing_object_id, order_id, old_owner, new_owner }`
/// whenever an order is actually found and reassigned — including when
/// `new_owner` equals the order's current owner, since the reassignment
/// (and its unconditional proceeds-owner sync, see below) still runs in
/// that case. Never emitted on either not-found path.
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
/// first. This function ALWAYS immediately and unconditionally syncs the
/// `owner` of any already-pooled `MakerBalance` entry for this `order_id`
/// (via `sync_maker_balance_owner`, a safe no-op if no such entry exists)
/// at the moment of reassignment — not merely on a future fill, and
/// regardless of whether the order itself is found still resting (the
/// `bool` this function returns reflects only whether the RESTING order
/// was found and reassigned; the pooled-proceeds sync is unconditional on
/// that outcome). That means this function's reassignment reaches the
/// order's *entire* currently-pooled unclaimed proceeds balance for that
/// `order_id` — both proceeds already credited before the reassignment and
/// any credited afterward — immediately, whether or not the order is ever
/// filled again, and whether or not the order has already concluded by the
/// time this is called (fully filled and drained, `cancel_order`ed,
/// force-cancelled via `clob_admin_cancel_order`, or removed by
/// `clob_admin_drain_step`): `push_proceeds` / `drain_proceeds` always pay
/// whoever is currently stamped as owner, which this function keeps
/// current either way. This is intentional, since it remains the ticket
/// holder's own choice about their own order's funds. There is also a
/// secondary asymmetry worth noting here: `cancel_order` sweeps and pays
/// out any pooled proceeds as part of the same call — to the caller
/// (`ctx.sender()`), same as `claim_proceeds`, not the recorded `owner` —
/// while `clob_admin_cancel_order` deliberately does not — it refunds only the
/// order's escrow principal and leaves any pooled proceeds entry untouched
/// (so that an admin force-cancel can never redirect a maker's proceeds),
/// recoverable afterward only via `push_proceeds`/`drain_proceeds`/
/// `claim_proceeds`.
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
///
/// This function is the MANDATORY hand-off primitive whenever `OrderTicket`
/// custody changes hands outside of a bare object transfer this module can't
/// see — e.g. a wrapper/vault that places orders via a keeper address while
/// holding the ticket internally, and later moves that ticket (and the
/// beneficial ownership it represents) to a new custodian. Skipping this call
/// on such a change leaves the ledger's recorded `owner` stale: a later
/// `clob_admin_cancel_order`/`drain_side` (escrow principal) or
/// `drain_proceeds`/`push_proceeds` (pooled proceeds) will pay the OLD,
/// stale address instead of the current beneficiary, and this module has no
/// way to detect or flag that drift on its own — see the note above about a
/// bare ticket transfer being invisible to on-chain code. Use
/// `resting_order_owner`/`resting_order_owner_by_ticket` and
/// `proceeds_owner`/`proceeds_owner_by_ticket` beforehand to verify the
/// recorded address is actually in sync with the intended current
/// beneficiary before relying on any of those bulk/admin paths to route
/// correctly.
public fun update_resting_order<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    ticket: &mut OrderTicket,
    new_owner: address,
): bool {
    assert!(new_owner != @0x0, EInvalidOwner);
    assert_book_version(book);
    assert!(ticket.order_book_id == object::uid_to_inner(&book.id), EWrongBook);
    let ids = book.book_ids();
    let side = ticket.side;
    let price = ticket.price;
    let order_id = ticket.order_id;

    // Resync any already-pooled proceeds for this order_id to the new
    // owner unconditionally -- regardless of whether the order itself is
    // still resting. A pooled balance for a concluded order is exactly as
    // claimable as one for a still-resting order, and must not be left
    // silently pointed at the previous owner just because the order is
    // gone; `sync_maker_balance_owner` is already a safe no-op when no
    // pooled entry exists.
    sync_maker_balance_owner(&mut book.proceeds, order_id, new_owner);

    let tree: &mut PriceTree<PriceLevel<Base, Quote>> =
        if (side) &mut book.bids else &mut book.asks;
    let leaf_opt = tree.find(price);
    if (leaf_opt.is_none()) {
        return false
    };
    let leaf_ptr = leaf_opt.destroy_some();
    let old_owner_opt = {
        let level = tree.borrow_mut(leaf_ptr);
        if (!level.level_contains_order(order_id)) {
            option::none()
        } else {
            let old_owner = level.level_borrow_order(order_id).owner();
            level.level_set_order_owner(order_id, new_owner);
            option::some(old_owner)
        }
    };
    if (old_owner_opt.is_some()) {
        let old_owner = old_owner_opt.destroy_some();
        event::emit(OrderOwnerUpdated {
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            order_id,
            old_owner,
            new_owner,
        });
        true
    } else {
        old_owner_opt.destroy_none();
        false
    }
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
    let ids = book.book_ids();
    let (_owner, base, quote) = claim_maker_balance(book, order_id);
    let base_amount = base.value();
    let quote_amount = quote.value();

    let base_coin = coin_or_zero(base, ctx);
    let quote_coin = coin_or_zero(quote, ctx);

    if (base_amount != 0 || quote_amount != 0) {
        event::emit(ProceedsClaimed {
            book_id: ids.book_id,
            enclosing_object_id: ids.enclosing_object_id,
            claimant,
            base_amount,
            quote_amount,
        });
    };

    let tree: &PriceTree<PriceLevel<Base, Quote>> = if (side) &book.bids else &book.asks;
    let leaf_opt = tree.find(price);
    let still_resting = if (leaf_opt.is_none()) {
        false
    } else {
        let leaf_ptr = leaf_opt.destroy_some();
        let level = tree.borrow(leaf_ptr);
        level.level_contains_order(order_id)
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
/// never redirect funds elsewhere. Only usable as part of the retirement/
/// drain sequence, same as `drain_proceeds` — requires `book.retiring`, so a
/// live book's makers can only reach their pooled proceeds through
/// `claim_proceeds` themselves. An integrator that needs to confirm ahead of
/// time where this payout will go can check `proceeds_owner`/
/// `proceeds_owner_by_ticket`.
public fun push_proceeds<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    order_id: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(book.retiring, ENotRetiring);
    let ids = book.book_ids();
    let (owner, base, quote) = claim_maker_balance(book, order_id);
    let base_amount = base.value();
    let quote_amount = quote.value();
    if (base_amount == 0 && quote_amount == 0) {
        base.destroy_zero();
        quote.destroy_zero();
        return
    };
    transfer_or_destroy_zero(base, owner, ctx);
    transfer_or_destroy_zero(quote, owner, ctx);
    event::emit(ProceedsClaimed {
        book_id: ids.book_id,
        enclosing_object_id: ids.enclosing_object_id,
        claimant: owner,
        base_amount,
        quote_amount,
    });
}

// === Test-only accessors ===

#[test_only]
public fun clob_admin_cap_id_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): ID {
    book.clob_admin_cap_id
}

#[test_only]
public fun bids_size_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): u64 {
    book.bids.size()
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
public fun cap_id_for_testing(cap: &ClobAdminCap): ID {
    object::uid_to_inner(&cap.id)
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
    book.proceeds.contains(order_id)
}

#[test_only]
public fun clob_admin_cap_discarded_fields_for_testing(e: &ClobAdminCapDiscarded): (ID, ID, ID) {
    (e.book_id, e.enclosing_object_id, e.cap_id)
}

#[test_only]
public fun paused_fields_for_testing(e: &Paused): (ID, ID) { (e.book_id, e.enclosing_object_id) }

#[test_only]
public fun unpaused_fields_for_testing(e: &Unpaused): (ID, ID) { (e.book_id, e.enclosing_object_id) }

#[test_only]
public fun taker_fee_set_fields_for_testing(e: &TakerFeeSet): (ID, ID, u64) {
    (e.book_id, e.enclosing_object_id, e.rate_bps)
}

#[test_only]
public fun maker_fee_set_fields_for_testing(e: &MakerFeeSet): (ID, ID, u64) {
    (e.book_id, e.enclosing_object_id, e.rate_bps)
}

#[test_only]
public fun price_band_factor_set_fields_for_testing(e: &PriceBandFactorSet): (ID, ID, Option<u64>) {
    (e.book_id, e.enclosing_object_id, e.factor)
}

#[test_only]
public fun last_price_set_fields_for_testing(e: &LastPriceSet): (ID, ID, u64, address) {
    (e.book_id, e.enclosing_object_id, e.last_price, e.setter)
}

#[test_only]
public fun enclosing_object_id_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): ID {
    book.enclosing_object_id
}

#[test_only]
public fun book_version_upgraded_fields_for_testing(e: &BookVersionUpgraded): (ID, ID, u64, u64) {
    (e.book_id, e.enclosing_object_id, e.from, e.to)
}

#[test_only]
public fun fees_claimed_fields_for_testing(e: &FeesClaimed): (ID, ID, address, u64, u64) {
    (e.book_id, e.enclosing_object_id, e.claimant, e.base_amount, e.quote_amount)
}

#[test_only]
public fun order_cancelled_fields_for_testing(e: &OrderCancelled): (ID, ID, u64, address) {
    (e.book_id, e.enclosing_object_id, e.order_id, e.trader)
}

#[test_only]
public fun order_owner_updated_fields_for_testing(e: &OrderOwnerUpdated): (ID, ID, u64, address, address) {
    (e.book_id, e.enclosing_object_id, e.order_id, e.old_owner, e.new_owner)
}

#[test_only]
public fun order_placed_fields_for_testing(e: &OrderPlaced): (ID, ID, u64, bool, u64, u64, address, u64) {
    (e.book_id, e.enclosing_object_id, e.order_id, e.side, e.price, e.size, e.trader, e.maker_fee_bps)
}

#[test_only]
public fun proceeds_claimed_fields_for_testing(e: &ProceedsClaimed): (ID, ID, address, u64, u64) {
    (e.book_id, e.enclosing_object_id, e.claimant, e.base_amount, e.quote_amount)
}

#[test_only]
public fun order_book_retired_fields_for_testing(e: &OrderBookRetired): (ID, ID) {
    (e.book_id, e.enclosing_object_id)
}

#[test_only]
public fun order_book_deleted_fields_for_testing(e: &OrderBookDeleted): (ID, ID, TypeName, TypeName) {
    (e.book_id, e.enclosing_object_id, e.base, e.quote)
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
/// `enclosing_object_id`, which is caller-supplied and used solely for
/// event stamping. Do not read this constructor's freedom to pass an
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
public fun order_filled_fields_for_testing(e: &OrderFilled): (ID, ID, u64, u64, u64, address, address) {
    (e.book_id, e.enclosing_object_id, e.maker_order_id, e.price, e.size, e.maker, e.taker)
}

#[test_only]
public fun order_filled_side_and_quote_fields_for_testing(e: &OrderFilled): (bool, u64) {
    (e.maker_side, e.quote_amount)
}

#[test_only]
public fun order_executed_fields_for_testing(e: &OrderExecuted): (ID, ID, address, bool, u8, Option<u64>, u64, u64, u64, Option<u64>, bool, u64) {
    (e.book_id, e.enclosing_object_id, e.taker, e.taker_side, e.entry_point, e.limit_price, e.requested_size, e.unmatched_size, e.rested_size, e.rested_order_id, e.stopped_on_max_fills_while_crossing, e.taker_fee_amount)
}

#[test_only]
public fun maker_fee_settled_fields_for_testing(e: &MakerFeeSettled): (ID, ID, u64, address, u64) {
    (e.book_id, e.enclosing_object_id, e.order_id, e.maker, e.amount)
}


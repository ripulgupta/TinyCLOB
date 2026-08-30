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
/// see `new_impl`.
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
/// A decimals/precision/exponent argument to `new`/`new_with_event_id_override`
/// exceeded `MAX_DECIMALS`.
const EDecimalsTooLarge: u64 = 28;

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
/// `scale_lo`/`scale_hi` feasibility check in `new_impl`) that
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

#[test_only]
fun credit_fee_accumulator<Base, Quote>(
    fees: &mut FeeAccumulator<Base, Quote>,
    base: Balance<Base>,
    quote: Balance<Quote>,
) {
    fees.base.join(base);
    fees.quote.join(quote);
}

/// Pure-typing wrapper around a `Balance<T>` of accumulated maker fees,
/// produced by `match_bid`/`match_ask` as the aggregate maker-fee proceeds
/// collected mid-sweep (via `conclude_order_fee`/`fill_level_bid`/
/// `fill_level_ask`) across every resting order fully drained by one taker
/// sweep. Exists solely to make this value a DISTINCT TYPE from the
/// `Balance<Quote>`/`Balance<Base>` values already present in
/// `match_bid`/`match_ask`'s return tuples, so a positional destructuring
/// swap at any call site is a compile error instead of a silent
/// fund-misdirection bug. Carries no invariant of its own beyond that;
/// `wrap_maker_fee_collected`/`unwrap_maker_fee_collected` below are its only
/// constructor/destructor.
public struct MakerFeeCollected<phantom T> {
    balance: Balance<T>,
}

fun wrap_maker_fee_collected<T>(balance: Balance<T>): MakerFeeCollected<T> {
    MakerFeeCollected { balance }
}

fun unwrap_maker_fee_collected<T>(w: MakerFeeCollected<T>): Balance<T> {
    let MakerFeeCollected { balance } = w;
    balance
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
    /// Derived at construction (see `new_impl`) from the book's declared
    /// `base_decimals`/`quote_decimals`/`precision`/`exponent`: the true
    /// price is `price / price_scale * 10^(base_decimals - quote_decimals)`.
    /// Chosen to maximize precision subject to fitting in a `u64`. Used by
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
    cap_id: ID,
    for_book: ID,
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
/// deliberately NOT `&OrderBook` — reused unmodified across 6 call sites in
/// 3 categories: construction (`new_impl`), `set_last_price`, and
/// order placement (`place_limit_order_bid`/`_ask`, `swap_bid`/`_ask`), the
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
/// The book's `event_id` (stamped on every emitted event) defaults to the
/// book's own object id. Use `new_with_event_id_override` instead of this
/// function if a wrapping object's own id should be stamped there instead.
///
/// `min_size` bounds order-placement size only, not post-fill remainder
/// size — see `validate_size_raw`'s doc comment for the full caveat about
/// resulting dust and `max_fills` griefing.
///
/// `base_decimals`/`quote_decimals` are the on-chain atomic-unit decimals of
/// `Base`/`Quote` respectively. `precision`/`exponent` jointly declare the
/// range of true price this book guarantees to be able to represent: at
/// least `10^-precision` and at most `10^exponent`. From these four values, a
/// `price_scale` is derived (see `price_scale`'s accessor) that maximizes
/// representable precision subject to fitting in a `u64`; construction
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
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    new_impl(min_size, base_decimals, quote_decimals, precision, exponent, initial_last_price, option::none(), ctx)
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
///
/// `base_decimals`/`quote_decimals`/`precision`/`exponent`/`initial_last_price`
/// carry the same meaning documented on `new`.
public fun new_with_event_id_override<Base, Quote>(
    min_size: u64,
    base_decimals: u8,
    quote_decimals: u8,
    precision: u8,
    exponent: u8,
    initial_last_price: u64,
    event_id_override: &UID,
    ctx: &mut TxContext,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    new_impl(
        min_size, base_decimals, quote_decimals, precision, exponent, initial_last_price,
        option::some(object::uid_to_inner(event_id_override)), ctx,
    )
}

fun new_impl<Base, Quote>(
    min_size: u64,
    base_decimals: u8,
    quote_decimals: u8,
    precision: u8,
    exponent: u8,
    initial_last_price: u64,
    event_id_override: Option<ID>,
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
    let price_scale = (if (scale_hi > u64_max) { u64_max } else { scale_hi }) as u64;

    assert!(initial_last_price != 0, EZeroPrice);
    assert_price_in_declared_range(initial_last_price, price_scale, base_decimals, quote_decimals, precision, exponent);

    let book_uid = object::new(ctx);
    let book_id = object::uid_to_inner(&book_uid);
    let cap = ClobAdminCap { id: object::new(ctx) };
    let cap_id = object::uid_to_inner(&cap.id);
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
        price_scale,
        precision,
        exponent,
        base_decimals,
        quote_decimals,
        last_price: initial_last_price,
        price_band_factor: option::none(),
        event_id,
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
    order_book_id: ID,
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
            order_book_id: book.event_id,
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

public fun depth_at_price<Base, Quote>(book: &OrderBook<Base, Quote>, side: bool, price: u64): u64 {
    let tree = if (side) &book.bids else &book.asks;
    let found = tree.find(price);
    if (found.is_none()) {
        return 0
    };
    let leaf_ptr = found.destroy_some();
    let level = tree.borrow(leaf_ptr);
    level.level_total_size()
}

/// The exact, maintained total of live Quote escrow currently held by every
/// resting BID order at `price` -- equivalently, the exact gross Quote
/// (before any taker fee) that would be paid out if every resting bid at
/// this price were fully drained via direct escrow refund. `0` if no bid
/// level exists at `price`.
///
/// This is an O(1) running aggregate maintained at the same mutation points
/// as `depth_at_price`'s underlying total, so it always equals the true sum
/// of live per-order escrow -- unlike a re-derivation via
/// `bid_escrow_amount(book, price, depth_at_price(book, bid(), price))`,
/// which can be off in EITHER direction: a re-derivation over- or
/// under-counts by up to roughly one Quote atom per resting order at that
/// price, in either direction, depending on each order's own fill history.
///
/// Ask levels hold no Quote escrow at all (an ask escrows Base, exactly
/// equal to `depth_at_price(book, ask(), price)`), which is why this
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
/// value does not include. `Some({escrow: 0, remaining_size: r})` with `r >
/// 0` is a real, reachable state (the order's escrow is fully charged but it
/// is still resting with real remaining size) -- distinct from `None` (not
/// resting at all).
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

// === ClobAdminCap gate ===

fun assert_clob_admin<Base, Quote>(cap: &ClobAdminCap, book: &OrderBook<Base, Quote>) {
    assert!(object::uid_to_inner(&cap.id) == book.clob_admin_cap_id, EWrongClobAdminCap);
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

public struct PriceBandFactorSet has copy, drop {
    order_book_id: ID,
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
    let event_book_id = book.event_id;
    book.price_band_factor = factor;
    event::emit(PriceBandFactorSet { order_book_id: event_book_id, factor });
}

public struct LastPriceSet has copy, drop {
    order_book_id: ID,
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
        let event_book_id = book.event_id;
        book.last_price = new_last_price;
        event::emit(LastPriceSet { order_book_id: event_book_id, last_price: new_last_price, setter: ctx.sender() });
    };
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
    let base_amount = base.value();
    let quote_amount = quote.value();

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
    let order_opt = tree.find_and_remove_order(price, order_id);
    if (order_opt.is_none()) { order_opt.destroy_none(); return };
    let live_order = order_opt.destroy_some();
    let owner = live_order.owner();
    let fee_basis = live_order.fee_basis_accumulated();
    let mfee_bps = live_order.maker_fee_bps();
    let (escrow_base, escrow_quote, frb, frq) = live_order.destroy();
    let (escrow_base, escrow_quote) = fold_maker_fee_slack(
        escrow_base, escrow_quote, frb, frq, fee_basis, mfee_bps, order_id, event_book_id, owner,
        &mut book.fee_accumulator,
    );
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
public fun clob_admin_drain_step<Base, Quote>(
    cap: &ClobAdminCap,
    book: &mut OrderBook<Base, Quote>,
    max_items: u64,
    ctx: &mut TxContext,
) {
    assert_book_version(book);
    assert_clob_admin(cap, book);
    assert!(book.retiring, ENotRetiring);
    let event_book_id = book.event_id;
    let mut remaining = max_items;
    let fees = &mut book.fee_accumulator;
    drain_side(&mut book.bids, &mut remaining, /* want_max */ true, event_book_id, fees, ctx);
    drain_side(&mut book.asks, &mut remaining, /* want_max */ false, event_book_id, fees, ctx);
    drain_proceeds(&mut book.proceeds, &mut remaining, event_book_id, ctx);
}

fun drain_side<Base, Quote>(
    tree: &mut PriceTree<PriceLevel<Base, Quote>>,
    remaining: &mut u64,
    want_max: bool,
    event_book_id: ID,
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
                    escrow_base, escrow_quote, frb, frq, fee_basis, mfee_bps, order_id, event_book_id, owner, fees,
                );
                refund_order_escrow(owner, escrow_base, escrow_quote, ctx);
                event::emit(OrderCancelled { order_id, order_book_id: event_book_id, trader: owner });
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
    event_book_id: ID,
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
            event::emit(ProceedsClaimed { claimant: owner, order_book_id: event_book_id, base_amount, quote_amount });
        };
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
        book.bids.size() == 0 && book.asks.size() == 0 && book.proceeds.is_empty()
            && fee_base == 0 && fee_quote == 0,
        ENotFullyDrained,
    );

    let OrderBook {
        id, min_size: _, bids, asks, proceeds,
        paused: _, retiring: _, next_order_id: _, clob_admin_cap_id: _, version: _,
        taker_fee_bps: _, maker_fee_bps: _, fee_accumulator,
        price_scale: _, precision: _, exponent: _, base_decimals: _, quote_decimals: _,
        last_price: _, price_band_factor: _, event_id,
    } = book;
    let event_book_id = event_id;
    let true_book_id = object::uid_to_inner(&id);
    bids.destroy_empty();
    asks.destroy_empty();
    proceeds.destroy_empty();
    let (base, quote) = destroy_fee_accumulator(fee_accumulator);
    base.destroy_zero();
    quote.destroy_zero();
    object::delete(id);

    event::emit(OrderBookDeleted {
        order_book_id: event_book_id,
        base: type_name::with_defining_ids<Base>(),
        quote: type_name::with_defining_ids<Quote>(),
    });

    let ClobAdminCap { id: cap_id_uid } = cap;
    let cap_id = object::uid_to_inner(&cap_id_uid);
    object::delete(cap_id_uid);
    event::emit(ClobAdminCapDiscarded { cap_id, for_book: event_book_id });

    true_book_id
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
    maker_order_id: u64,
    order_book_id: ID,
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
    order_id: u64,
    order_book_id: ID,
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
    event_book_id: ID,
    owner: address,
): (Balance<T>, Balance<T>) {
    let correct_total_fee = fee_amount(fee_basis_accumulated, maker_fee_bps);
    let to_accumulator = reserve.split(correct_total_fee);
    event::emit(MakerFeeSettled { order_id, order_book_id: event_book_id, maker: owner, amount: correct_total_fee });
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
    event_book_id: ID,
    owner: address,
    fees: &mut FeeAccumulator<Base, Quote>,
): (Option<Balance<Base>>, Option<Balance<Quote>>) {
    if (fee_reserve_base.is_some()) {
        fee_reserve_quote.destroy_none();
        let reserve = fee_reserve_base.destroy_some();
        let (slack, fee_collected) = conclude_order_fee(reserve, fee_basis_accumulated, maker_fee_bps, order_id, event_book_id, owner);
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
        let (slack, fee_collected) = conclude_order_fee(reserve, fee_basis_accumulated, maker_fee_bps, order_id, event_book_id, owner);
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
    asks: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    maker_fee_collected: &mut Balance<Quote>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    budget: &mut Balance<Quote>,
    matched_base: &mut Balance<Base>,
    taker: address,
    event_book_id: ID,
    fills_consumed: &mut u64,
    max_fills: u64,
    price_scale: u64,
    last_price: &mut u64,
): (bool, bool) {
    let mut budget_exhausted = false;
    let mut hit_max_fills = false;
    let is_empty_now;
    {
        let level = asks.borrow_mut(leaf_ptr);
        loop {
            if (*remaining_size == 0) break;
            if (*fills_consumed == max_fills) {
                budget_exhausted = true;
                hit_max_fills = true;
                break
            };
            if (level.level_is_empty()) break;
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
                maker_order_id,
                order_book_id: event_book_id,
                price: best_price,
                size: fill_qty,
                maker: maker_addr,
                taker,
                maker_side: false,
                quote_amount: quote_cost,
            });

            *remaining_size = *remaining_size - fill_qty;
            *last_price = best_price;

            if (maker_remaining_after == 0) {
                let fee_basis = maker_order.fee_basis_accumulated();
                let mfee_bps = maker_order.maker_fee_bps();
                let (eb, eq, frb, frq) = maker_order.destroy();
                destroy_drained_ask_escrow(eb, eq);
                let reserve_quote = extract_drained_ask_fee_reserve(frb, frq);
                let (slack_quote, fee_quote_collected) = conclude_order_fee(
                    reserve_quote, fee_basis, mfee_bps, maker_order_id, event_book_id, maker_addr,
                );
                quote_payment.join(slack_quote);
                maker_fee_collected.join(fee_quote_collected);
                credit_maker_table(proceeds, maker_order_id, maker_addr, balance::zero<Base>(), quote_payment);
            } else {
                credit_maker_table(proceeds, maker_order_id, maker_addr, balance::zero<Base>(), quote_payment);
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
        let removed = asks.remove(leaf_ptr);
        removed.destroy_empty_price_level();
    };
    (budget_exhausted, hit_max_fills)
}

fun match_bid<Base, Quote>(
    asks: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    budget_in: Balance<Quote>,
    taker: address,
    event_book_id: ID,
    max_fills: u64,
    price_scale: u64,
    last_price: &mut u64,
): (Balance<Base>, Balance<Quote>, u64, bool, MakerFeeCollected<Quote>) {
    let mut remaining_size = remaining_size_in;
    let mut budget = budget_in;
    let mut matched_base = balance::zero<Base>();
    let mut fills_consumed: u64 = 0;
    let mut stopped_on_max_fills_while_crossing = false;
    let mut maker_fee_collected = balance::zero<Quote>();

    loop {
        if (remaining_size == 0) break;
        let best_opt = asks.min_leaf();
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let best_price = asks.key(leaf_ptr);
        if (limit_price.is_some() && best_price > *limit_price.borrow()) break;

        if (fills_consumed == max_fills) {
            stopped_on_max_fills_while_crossing = true;
            break
        };

        let (stop, hit_max_fills) = fill_level_bid(
            asks,
            proceeds,
            &mut maker_fee_collected,
            leaf_ptr,
            best_price,
            &mut remaining_size,
            &mut budget,
            &mut matched_base,
            taker,
            event_book_id,
            &mut fills_consumed,
            max_fills,
            price_scale,
            last_price,
        );
        if (hit_max_fills) stopped_on_max_fills_while_crossing = true;
        if (stop) break;
    };

    (matched_base, budget, remaining_size, stopped_on_max_fills_while_crossing, wrap_maker_fee_collected(maker_fee_collected))
}

fun fill_level_ask<Base, Quote>(
    bids: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    maker_fee_collected: &mut Balance<Base>,
    leaf_ptr: u64,
    best_price: u64,
    remaining_size: &mut u64,
    escrow_base: &mut Balance<Base>,
    matched_quote: &mut Balance<Quote>,
    taker: address,
    event_book_id: ID,
    fills_consumed: &mut u64,
    max_fills: u64,
    price_scale: u64,
    last_price: &mut u64,
): (bool, bool) {
    let mut stop = false;
    let mut hit_max_fills = false;
    let is_empty_now;
    {
        let level = bids.borrow_mut(leaf_ptr);
        loop {
            if (*remaining_size == 0) break;
            if (*fills_consumed == max_fills) {
                stop = true;
                hit_max_fills = true;
                break
            };
            if (level.level_is_empty()) break;
            let head_key = level.level_front_order_id().destroy_some();
            *fills_consumed = *fills_consumed + 1;
            let maker_remaining = level.level_borrow_order(head_key).remaining_size();
            let fill_qty = std::u64::min(*remaining_size, maker_remaining);

            let mut maker_order = level.level_remove_order(head_key);
            maker_order.decrease_remaining_size(fill_qty);
            // Maker-side (bid-resting-order) charge, split by which side this
            // fill is limited by (see the project's audit notes, findings
            // L-A/L-B, and the matching comment in `fill_level_bid`):
            //
            // - Maker-limited (`fill_qty == maker_remaining`, this fill fully
            //   drains the resting bid): simply drain whatever's left in the
            //   order's own reservation. Verified equal to the old
            //   proportional-ceiling formula's value at full drain (both
            //   telescope to exactly `total_reserved` minus whatever was
            //   already charged), so this is a pure simplification for this
            //   branch, not a behavior change.
            // - Taker-limited (maker order still has size left after this
            //   fill): `max(floor(price * fill_qty / price_scale), 1)`,
            //   clamped to never exceed what's actually left in the maker's
            //   reservation. The `escrow_quote_value` clamp is mandatory: a
            //   bid's fixed, placement-time Quote reservation can already be
            //   nearly exhausted by prior fills against the same order (its
            //   `total_reserved` was computed once, ceiling-rounded, at
            //   placement time), so an unclamped floor/ceiling here could
            //   demand more Quote than the order has left and abort
            //   `split_escrow_quote` -- a real, maker-triggerable DoS. Once
            //   `escrow_quote_value` is fully exhausted this correctly falls
            //   back to charging 0 on a taker-limited fill rather than
            //   aborting; no assertion or invariant in this module depends
            //   on `quote_cost > 0` for a fill with `fill_qty > 0` (see
            //   `tiny_fill_charges_nonzero_quote_and_forfeits_escrow_on_cancel`
            //   in `tests/escrow_shortfall_and_edge_case_tests.move`).
            let quote_cost = if (fill_qty == maker_remaining) {
                maker_order.escrow_quote_value()
            } else {
                let floor_u128 = ((best_price as u128) * (fill_qty as u128)) / (price_scale as u128);
                let floor_u128 = if (floor_u128 < 1) { 1 } else { floor_u128 };
                let escrow_u128 = maker_order.escrow_quote_value() as u128;
                (if (floor_u128 < escrow_u128) { floor_u128 } else { escrow_u128 }) as u64
            };

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
            let maker_remaining_after = maker_order.remaining_size();

            event::emit(OrderFilled {
                maker_order_id,
                order_book_id: event_book_id,
                price: best_price,
                size: fill_qty,
                maker: maker_addr,
                taker,
                maker_side: true,
                quote_amount: quote_cost,
            });

            *remaining_size = *remaining_size - fill_qty;
            *last_price = best_price;

            if (maker_remaining_after == 0) {
                let fee_basis = maker_order.fee_basis_accumulated();
                let mfee_bps = maker_order.maker_fee_bps();
                let (eb, eq, frb, frq) = maker_order.destroy();
                destroy_drained_bid_escrow(eb, eq);
                let reserve_base = extract_drained_bid_fee_reserve(frb, frq);
                let (slack_base, fee_base_collected) = conclude_order_fee(
                    reserve_base, fee_basis, mfee_bps, maker_order_id, event_book_id, maker_addr,
                );
                base_payment.join(slack_base);
                maker_fee_collected.join(fee_base_collected);
                credit_maker_table(proceeds, maker_order_id, maker_addr, base_payment, balance::zero<Quote>());
            } else {
                credit_maker_table(proceeds, maker_order_id, maker_addr, base_payment, balance::zero<Quote>());
                level.level_insert_order_front(head_key, maker_order);
            };
        };
        is_empty_now = level.level_is_empty();
    };
    if (is_empty_now) {
        let removed = bids.remove(leaf_ptr);
        removed.destroy_empty_price_level();
    };
    (stop, hit_max_fills)
}

fun match_ask<Base, Quote>(
    bids: &mut PriceTree<PriceLevel<Base, Quote>>,
    proceeds: &mut LinkedTable<u64, MakerBalance<Base, Quote>>,
    limit_price: Option<u64>,
    remaining_size_in: u64,
    escrow_base_in: Balance<Base>,
    taker: address,
    event_book_id: ID,
    max_fills: u64,
    price_scale: u64,
    last_price: &mut u64,
): (Balance<Quote>, Balance<Base>, u64, bool, MakerFeeCollected<Base>) {
    let mut remaining_size = remaining_size_in;
    let mut escrow_base = escrow_base_in;
    let mut matched_quote = balance::zero<Quote>();
    let mut fills_consumed: u64 = 0;
    let mut stopped_on_max_fills_while_crossing = false;
    let mut maker_fee_collected = balance::zero<Base>();

    loop {
        if (remaining_size == 0) break;
        let best_opt = bids.max_leaf();
        if (best_opt.is_none()) break;
        let leaf_ptr = best_opt.destroy_some();
        let best_price = bids.key(leaf_ptr);
        if (limit_price.is_some() && best_price < *limit_price.borrow()) break;

        if (fills_consumed == max_fills) {
            stopped_on_max_fills_while_crossing = true;
            break
        };

        let (stop, hit_max_fills) = fill_level_ask(
            bids,
            proceeds,
            &mut maker_fee_collected,
            leaf_ptr,
            best_price,
            &mut remaining_size,
            &mut escrow_base,
            &mut matched_quote,
            taker,
            event_book_id,
            &mut fills_consumed,
            max_fills,
            price_scale,
            last_price,
        );
        if (hit_max_fills) stopped_on_max_fills_while_crossing = true;
        if (stop) break;
    };

    (matched_quote, escrow_base, remaining_size, stopped_on_max_fills_while_crossing, wrap_maker_fee_collected(maker_fee_collected))
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
    assert!(!book.proceeds.contains(ticket.order_id), EProceedsNotEmpty);
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
    order_id: u64,
    order_book_id: ID,
    side: bool,
    price: u64,
    size: u64,
    trader: address,
    maker_fee_bps: u64,
}

public struct ProceedsClaimed has copy, drop {
    claimant: address,
    order_book_id: ID,
    base_amount: u64,
    quote_amount: u64,
}

/// Emitted exactly once, unconditionally, as the final event of every call to
/// `place_limit_order_bid`/`place_limit_order_ask`/`place_market_order_bid`/
/// `place_market_order_ask`/`swap_bid`/`swap_ask` (identified by
/// `entry_point`, see below) — after any slippage-guard asserts in the
/// market/swap functions, so an abort emits nothing.
///
/// Event-ordering contract: within one call, the sequence is zero-or-more
/// `OrderFilled`, then an optional `OrderPlaced`, then exactly one
/// `OrderExecuted` as a trailer — correlating fills to their triggering call
/// relies on this within-transaction ordering (Sui's event ordering within a
/// transaction's effects is deterministic).
public struct OrderExecuted has copy, drop {
    order_book_id: ID,
    taker: address,
    taker_side: bool,
    /// 0 = place_limit_order_bid, 1 = place_limit_order_ask,
    /// 2 = place_market_order_bid, 3 = place_market_order_ask,
    /// 4 = swap_bid, 5 = swap_ask
    entry_point: u8,
    /// `None` for market orders; for `place_limit_order_*`, the
    /// resting/placement price; for `swap_*`, the taker's protective
    /// slippage cap (exempt from the price band — see `swap_bid`/`swap_ask`'s
    /// own doc comment).
    limit_price: Option<u64>,
    /// The caller's own `size` argument.
    requested_size: u64,
    /// Remaining size after matching (gross base; NOT reduced by taker fee,
    /// so `requested_size - unmatched_size` does not equal the base actually
    /// returned to the taker when `taker_fee_bps > 0`).
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
    /// checks in `place_market_order_*`/`swap_*` and before the coin(s)
    /// returned to the taker. Denominated in Base for a bid-side taker
    /// (`taker_side == true`), Quote for an ask-side taker
    /// (`taker_side == false`). Replaces the old per-fill
    /// `OrderFilled.taker_fee_amount` field, which could over-collect across
    /// many small fills (finding F-6).
    taker_fee_amount: u64,
}

/// `price` is a raw, book-relative unit; see the module doc comment for how
/// it decodes to a true price via `price_scale`/`precision`/`exponent`, and
/// `clob_admin_set_price_band_factor` for the optional additional band
/// safeguard. Both checks are enforced here immediately after the
/// zero-price check, before any escrow is taken.
public fun place_limit_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    price: u64,
    size: u64,
    mut payment: Coin<Quote>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    assert!(price != 0, EZeroPrice);
    let price_scale = book.price_scale;
    assert_price_in_declared_range(
        price, price_scale, book.base_decimals, book.quote_decimals, book.precision, book.exponent,
    );
    if (book.price_band_factor.is_some()) {
        let factor = *book.price_band_factor.borrow();
        assert!((price as u128) * (factor as u128) >= (book.last_price as u128), EPriceBelowBand);
        assert!((price as u128) <= (book.last_price as u128) * (factor as u128), EPriceAboveBand);
    };
    validate_size(book, size);

    let escrow_amount = bid_escrow_amount(book, price, size);
    let mut escrow = payment.split(escrow_amount, ctx).into_balance();

    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees, last_price) =
        (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_base, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_bid(
            asks, proceeds, option::some(price), size, escrow, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.quote.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_base.value(), taker_fee_bps);
    let taker_fee_balance = matched_base.split(taker_fee_amount);
    fees.base.join(taker_fee_balance);
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
            order_id,
            order_book_id: event_book_id,
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
        order_book_id: event_book_id,
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

/// `price` is a raw, book-relative unit; see `place_limit_order_bid`'s doc
/// comment for the full note on price-range/band checks.
public fun place_limit_order_ask<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    price: u64,
    size: u64,
    mut payment: Coin<Base>,
    max_fills: u64,
    ctx: &mut TxContext,
): (Option<OrderTicket>, Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    assert!(price != 0, EZeroPrice);
    assert_price_in_declared_range(
        price, book.price_scale, book.base_decimals, book.quote_decimals, book.precision, book.exponent,
    );
    if (book.price_band_factor.is_some()) {
        let factor = *book.price_band_factor.borrow();
        assert!((price as u128) * (factor as u128) >= (book.last_price as u128), EPriceBelowBand);
        assert!((price as u128) <= (book.last_price as u128) * (factor as u128), EPriceAboveBand);
    };
    validate_size(book, size);

    let escrow_base = payment.split(size, ctx).into_balance();

    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let price_scale = book.price_scale;
    let (bids, proceeds, fees, last_price) =
        (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_ask(
            bids, proceeds, option::some(price), size, escrow_base, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.base.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_quote.value(), taker_fee_bps);
    let taker_fee_balance = matched_quote.split(taker_fee_amount);
    fees.quote.join(taker_fee_balance);

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
            order_id,
            order_book_id: event_book_id,
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
        order_book_id: event_book_id,
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

public fun place_market_order_bid<Base, Quote>(
    book: &mut OrderBook<Base, Quote>,
    size: u64,
    budget: u64,
    mut payment: Coin<Quote>,
    max_fills: u64,
    max_quote_in: Option<u64>,
    min_base_out: Option<u64>,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    validate_size(book, size);

    let price_scale = book.price_scale;
    let budget_balance = payment.split(budget, ctx).into_balance();
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees, last_price) =
        (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_base, remaining_budget, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_bid(
            asks, proceeds, option::none(), size, budget_balance, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.quote.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_base.value(), taker_fee_bps);
    let taker_fee_balance = matched_base.split(taker_fee_amount);
    fees.base.join(taker_fee_balance);

    if (max_quote_in.is_some()) {
        let quote_spent = budget - remaining_budget.value();
        assert!(quote_spent <= *max_quote_in.borrow(), ESlippageExceeded);
    };
    if (min_base_out.is_some()) {
        assert!(matched_base.value() >= *min_base_out.borrow(), ESlippageExceeded);
    };

    payment.join(remaining_budget.into_coin(ctx));

    event::emit(OrderExecuted {
        order_book_id: event_book_id,
        taker,
        taker_side: true,
        entry_point: 2,
        limit_price: option::none(),
        requested_size: size,
        unmatched_size: remaining_size,
        rested_size: 0,
        rested_order_id: option::none(),
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
    });

    (matched_base.into_coin(ctx), payment, stopped_on_max_fills_while_crossing)
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

    let escrow_base = payment.split(size, ctx).into_balance();
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let price_scale = book.price_scale;
    let (bids, proceeds, fees, last_price) =
        (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_ask(
            bids, proceeds, option::none(), size, escrow_base, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.base.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_quote.value(), taker_fee_bps);
    let taker_fee_balance = matched_quote.split(taker_fee_amount);
    fees.quote.join(taker_fee_balance);

    if (max_base_in.is_some()) {
        let base_spent = size - remaining_escrow.value();
        assert!(base_spent <= *max_base_in.borrow(), ESlippageExceeded);
    };
    if (min_quote_out.is_some()) {
        assert!(matched_quote.value() >= *min_quote_out.borrow(), ESlippageExceeded);
    };

    payment.join(remaining_escrow.into_coin(ctx));

    event::emit(OrderExecuted {
        order_book_id: event_book_id,
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

/// `limit_price`, when `Some`, is validated for representability via the
/// same price-range check documented on `place_limit_order_bid`, but is
/// NOT subject to the price-band check — it's the taker's own protective
/// slippage cap, not a price that can rest on the book, so a self-imposed
/// tighter cap must never be rejected.
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
): (Coin<Base>, Coin<Quote>, bool) {
    assert_book_version(book);
    assert!(!is_paused(book), EBookPaused);
    let price_scale = book.price_scale;
    if (limit_price.is_some()) {
        let price = *limit_price.borrow();
        assert_price_in_declared_range(
            price, price_scale, book.base_decimals, book.quote_decimals, book.precision, book.exponent,
        );
    };
    validate_size(book, size);

    let budget_balance = payment.split(budget, ctx).into_balance();
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let (asks, proceeds, fees, last_price) =
        (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_base, remaining_budget, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_bid(
            asks, proceeds, limit_price, size, budget_balance, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.quote.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_base.value(), taker_fee_bps);
    let taker_fee_balance = matched_base.split(taker_fee_amount);
    fees.base.join(taker_fee_balance);

    if (max_quote_in.is_some()) {
        let quote_spent = budget - remaining_budget.value();
        assert!(quote_spent <= *max_quote_in.borrow(), ESlippageExceeded);
    };
    if (min_base_out.is_some()) {
        assert!(matched_base.value() >= *min_base_out.borrow(), ESlippageExceeded);
    };

    payment.join(remaining_budget.into_coin(ctx));

    event::emit(OrderExecuted {
        order_book_id: event_book_id,
        taker,
        taker_side: true,
        entry_point: 4,
        limit_price,
        requested_size: size,
        unmatched_size: remaining_size,
        rested_size: 0,
        rested_order_id: option::none(),
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
    });

    (matched_base.into_coin(ctx), payment, stopped_on_max_fills_while_crossing)
}

/// `limit_price`, when `Some`, is validated for representability via the
/// same price-range check documented on `place_limit_order_bid`, but is
/// NOT subject to the price-band check — it's the taker's own protective
/// slippage cap, not a price that can rest on the book, so a self-imposed
/// tighter cap must never be rejected.
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
    if (limit_price.is_some()) {
        let price = *limit_price.borrow();
        assert_price_in_declared_range(
            price, book.price_scale, book.base_decimals, book.quote_decimals, book.precision, book.exponent,
        );
    };
    validate_size(book, size);

    let escrow_base = payment.split(size, ctx).into_balance();
    let event_book_id = book.event_id;
    let taker = ctx.sender();
    let taker_fee_bps = taker_fee_bps(book);
    let price_scale = book.price_scale;
    let (bids, proceeds, fees, last_price) =
        (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_ask(
            bids, proceeds, limit_price, size, escrow_base, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.base.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_quote.value(), taker_fee_bps);
    let taker_fee_balance = matched_quote.split(taker_fee_amount);
    fees.quote.join(taker_fee_balance);

    if (max_base_in.is_some()) {
        let base_spent = size - remaining_escrow.value();
        assert!(base_spent <= *max_base_in.borrow(), ESlippageExceeded);
    };
    if (min_quote_out.is_some()) {
        assert!(matched_quote.value() >= *min_quote_out.borrow(), ESlippageExceeded);
    };

    payment.join(remaining_escrow.into_coin(ctx));

    event::emit(OrderExecuted {
        order_book_id: event_book_id,
        taker,
        taker_side: false,
        entry_point: 5,
        limit_price,
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
    let event_book_id = book.event_id;
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
            eb, eq, frb, frq, fee_basis, mfee_bps, order_id, event_book_id, trader, &mut book.fee_accumulator,
        );
        event::emit(OrderCancelled { order_id, order_book_id: event_book_id, trader });
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

public struct OrderOwnerUpdated has copy, drop {
    order_id: u64,
    order_book_id: ID,
    old_owner: address,
    new_owner: address,
}

/// Finds the resting order identified by `ticket` and overwrites its
/// `owner` field in place. Returns `true` if an order was found and
/// updated, `false` if the price level or the order itself doesn't exist (a
/// no-op, mirroring `cancel_order`'s own not-found-is-a-no-op handling).
///
/// Emits `OrderOwnerUpdated { order_id, order_book_id, old_owner, new_owner }`
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
    let event_book_id = book.event_id;
    let side = ticket.side;
    let price = ticket.price;
    let order_id = ticket.order_id;
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
        sync_maker_balance_owner(&mut book.proceeds, order_id, new_owner);
        event::emit(OrderOwnerUpdated { order_id, order_book_id: event_book_id, old_owner, new_owner });
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
    let event_book_id = book.event_id;
    let (_owner, base, quote) = claim_maker_balance(book, order_id);
    let base_amount = base.value();
    let quote_amount = quote.value();

    let base_coin = coin_or_zero(base, ctx);
    let quote_coin = coin_or_zero(quote, ctx);

    if (base_amount != 0 || quote_amount != 0) {
        event::emit(ProceedsClaimed { claimant, order_book_id: event_book_id, base_amount, quote_amount });
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
    let base_amount = base.value();
    let quote_amount = quote.value();
    if (base_amount == 0 && quote_amount == 0) {
        base.destroy_zero();
        quote.destroy_zero();
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
    book.bids.size()
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
public fun last_price_set_fields_for_testing(e: &LastPriceSet): (ID, u64, address) {
    (e.order_book_id, e.last_price, e.setter)
}

#[test_only]
public fun event_id_for_testing<Base, Quote>(book: &OrderBook<Base, Quote>): ID { book.event_id }

#[test_only]
public fun book_version_upgraded_fields_for_testing(e: &BookVersionUpgraded): (ID, u64, u64) {
    (e.order_book_id, e.from, e.to)
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
public fun order_owner_updated_fields_for_testing(e: &OrderOwnerUpdated): (u64, ID, address, address) {
    (e.order_id, e.order_book_id, e.old_owner, e.new_owner)
}

#[test_only]
public fun order_placed_fields_for_testing(e: &OrderPlaced): (u64, ID, bool, u64, u64, address, u64) {
    (e.order_id, e.order_book_id, e.side, e.price, e.size, e.trader, e.maker_fee_bps)
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

#[test_only]
public fun order_filled_side_and_quote_fields_for_testing(e: &OrderFilled): (bool, u64) {
    (e.maker_side, e.quote_amount)
}

#[test_only]
public fun order_executed_fields_for_testing(e: &OrderExecuted): (ID, address, bool, u8, Option<u64>, u64, u64, u64, Option<u64>, bool, u64) {
    (e.order_book_id, e.taker, e.taker_side, e.entry_point, e.limit_price, e.requested_size, e.unmatched_size, e.rested_size, e.rested_order_id, e.stopped_on_max_fills_while_crossing, e.taker_fee_amount)
}

#[test_only]
public fun maker_fee_settled_fields_for_testing(e: &MakerFeeSettled): (u64, ID, address, u64) {
    (e.order_id, e.order_book_id, e.maker, e.amount)
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
): (Coin<Base>, Coin<Quote>, u64, bool, u64) {
    let taker = ctx.sender();
    let event_book_id = book.event_id;
    let budget = payment.into_balance();
    let taker_fee_bps = book.taker_fee_bps;
    let price_scale = book.price_scale;
    let (asks, proceeds, fees, last_price) =
        (&mut book.asks, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_base, remaining_budget, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_bid(
            asks, proceeds, limit_price, remaining_size_in, budget, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.quote.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_base.value(), taker_fee_bps);
    let taker_fee_balance = matched_base.split(taker_fee_amount);
    fees.base.join(taker_fee_balance);
    (
        matched_base.into_coin(ctx),
        remaining_budget.into_coin(ctx),
        remaining_size,
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
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
): (Coin<Quote>, Coin<Base>, u64, bool, u64) {
    let taker = ctx.sender();
    let event_book_id = book.event_id;
    let escrow_base = payment.into_balance();
    let taker_fee_bps = book.taker_fee_bps;
    let price_scale = book.price_scale;
    let (bids, proceeds, fees, last_price) =
        (&mut book.bids, &mut book.proceeds, &mut book.fee_accumulator, &mut book.last_price);
    let (mut matched_quote, remaining_escrow, remaining_size, stopped_on_max_fills_while_crossing, maker_fee_collected) =
        match_ask(
            bids, proceeds, limit_price, remaining_size_in, escrow_base, taker, event_book_id,
            max_fills, price_scale, last_price,
        );
    fees.base.join(unwrap_maker_fee_collected(maker_fee_collected));
    let taker_fee_amount = fee_amount(matched_quote.value(), taker_fee_bps);
    let taker_fee_balance = matched_quote.split(taker_fee_amount);
    fees.quote.join(taker_fee_balance);
    (
        matched_quote.into_coin(ctx),
        remaining_escrow.into_coin(ctx),
        remaining_size,
        stopped_on_max_fills_while_crossing,
        taker_fee_amount,
    )
}

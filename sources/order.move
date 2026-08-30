/// A resting order held in a price level's FIFO queue. Deliberately its own
/// module, separate from `price_tree`: both `price_tree` and `tiny_clob`
/// depend on it, but neither owns it. Every mutator here is safe to be
/// `public(package)` — unlike `price_tree::PriceLevel`, this struct carries
/// no aggregate invariant of its own to protect; the `total_size` invariant
/// that constrains WHEN an order's `remaining_size` may change lives in
/// `price_tree.move`.
///
/// That invariant is enforced structurally by the type system, not by
/// caller discipline: `price_tree.move` exposes no function, anywhere, that
/// returns `&mut Order` to a caller outside itself. It only ever hands out
/// a `&Order` (`level_borrow_order`) or an owned `Order` by value
/// (`level_remove_order`/`level_pop_front_order`). Because of that,
/// `tiny_clob.move` can only ever obtain a mutable reference to an `Order`
/// from a value it already owns outright, post-detachment — never while
/// that order is still attached inside a `PriceLevel`. A detached order is
/// later reinserted (still updating `total_size` correctly) via
/// `price_tree::level_insert_order_front`/`level_insert_order`.
///
/// This guarantee would silently break if anyone ever adds a function to
/// `price_tree.move` that returns `&mut Order` to an outside caller — that
/// is the one thing future reviewers of `price_tree.move` should watch for.
module tiny_clob::order;

use sui::balance::{Self, Balance};

public struct Order<phantom Base, phantom Quote> has store {
    order_id: u64,
    owner: address,
    /// For an ASK-side order: remaining Base quantity still open — decreased
    /// by exactly `fill_qty` on every fill, always exactly in sync with
    /// `escrow_base`'s live value.
    ///
    /// For a BID-side order (Quote-denominated — see `new`'s doc comment):
    /// remaining QUOTE buying-power still open, decreased by exactly
    /// `quote_cost` (never `fill_qty`) on every fill, always exactly in sync
    /// with `escrow_quote`'s live value — i.e. `remaining_size ==
    /// escrow_quote_value` is a maintained invariant for a bid-side order at
    /// all times, mirroring how `remaining_size == escrow_base value` already
    /// holds for an ask-side order. The remaining Base quantity a bid-side
    /// order can still accept is NOT this field — it must be derived as
    /// `original_size - fee_basis_accumulated` (see `tiny_clob::fill_level_ask`).
    remaining_size: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
    /// Set once, at construction, to the Base-denominated `base_size` (i.e.
    /// the quantity that actually starts resting — for a limit order that
    /// partially fills during its own placement sweep before resting, this
    /// is the post-sweep remainder, not the taker's original full requested
    /// size). Never mutated afterward. For a BID-side order, together with
    /// `fee_basis_accumulated` (which, for a bid-side order, doubles as the
    /// running cumulative-Base-filled counter — see that field's doc
    /// comment) and `escrow_quote_value`, this lets `fill_level_ask` charge
    /// a resting bid's escrow via a delta-of-cumulative-proportional-ceiling
    /// scheme: `ceil(total_reserved * cumulative_filled / original_size)`
    /// at each fill, minus what was already charged (the latter derived as
    /// `total_reserved - escrow_quote_value`). This telescopes to exactly
    /// the order's actual `total_reserved` escrow with zero dust, no matter
    /// how many separate fills/transactions the order is drained across,
    /// AND — unlike independently ceiling-rounding each fill in isolation —
    /// is not superadditive, so it never causes the order's own Base
    /// delivery to fall short of `original_size` (see `tiny_clob::
    /// fill_level_ask`'s doc comment for the full rationale and the
    /// regression this avoids). This field also exists (unused for the
    /// scheme above, but still set) on ask-side orders, matching how
    /// `escrow_base`/`escrow_quote` already sit unused on one side or the
    /// other.
    original_size: u64,
    /// Set once, at construction, to the actual `Quote` balance value
    /// handed to this order's escrow at that moment (0 if none). For a
    /// bid-side order, this is the ground truth for how much quote is
    /// really available to this order over its lifetime — unlike a fresh
    /// `bid_escrow_amount` recomputation, it already reflects any rounding
    /// shortfall clamped in at placement (see `place_limit_order_bid`'s
    /// resting-remainder clamp). `fill_level_ask` charges each fill a
    /// proportional ceiling of this value (see `original_size`'s doc
    /// comment above), so the running total can never exceed what was
    /// actually reserved. The running total already charged so far is not
    /// stored separately — it is always exactly `total_reserved -
    /// escrow_quote_value(&order)`, since every fill decrements the live
    /// escrow balance by precisely the amount it charges. Only bid-side
    /// resting orders need this field; it exists (unused) on ask-side
    /// orders too, matching how `escrow_base`/`escrow_quote` already sit
    /// unused on one side or the other.
    total_reserved: u64,
    /// Running sum of this order's maker-fee BASIS contribution across every
    /// fill it has ever taken part in — incremented identically by
    /// `fill_level_bid`/`fill_level_ask` regardless of side: `fill_qty`
    /// (Base) for a bid-side maker fill, `quote_cost` (Quote) for an
    /// ask-side maker fill (whichever currency this order's own maker fee is
    /// actually denominated in — see `fee_reserve_base`/`fee_reserve_quote`
    /// below). Used at order conclusion (see `tiny_clob::conclude_order_fee`)
    /// to compute the CORRECT aggregate fee owed,
    /// `fee_amount(fee_basis_accumulated, maker_fee_bps)`, instead of
    /// summing each fill's independently ceiling-rounded fee — the latter
    /// can over-collect when an order fills across many small fills (see the
    /// project's audit notes, finding F-6).
    ///
    /// For a BID-side order specifically, this field does double duty: since
    /// its value is always exactly the cumulative `fill_qty` (Base) summed
    /// across every fill so far, `fill_level_ask` also reads it (BEFORE this
    /// fill's own increment) as the running "cumulative Base filled" counter
    /// for the escrow-charging scheme described on `original_size`'s doc
    /// comment. `original_size - fee_basis_accumulated` (read before this
    /// fill's increment) is likewise how `fill_level_ask` derives how much
    /// more Base a resting bid can still accept — this order's `remaining_size`
    /// no longer holds that Base quantity directly, since it is
    /// Quote-denominated for a bid-side order (see its own doc comment).
    fee_basis_accumulated: u64,
    /// Per-fill maker-fee set-aside for a BID-side order (populated only
    /// then; `None` for an ask-side order) — mirrors `escrow_base`/
    /// `escrow_quote`'s optional-pair pattern. Each fill splits that fill's
    /// own ceiling-rounded fee off the maker's proceeds and joins it in here
    /// instead of crediting the book's fee accumulator immediately. Only the
    /// CORRECT aggregate fee (computed once, at conclusion, from
    /// `fee_basis_accumulated`) is ever actually transferred to the
    /// accumulator; any superadditive slack left over in this reserve is
    /// refunded back to the maker at that same conclusion — see
    /// `tiny_clob::conclude_order_fee`.
    fee_reserve_base: Option<Balance<Base>>,
    /// Per-fill maker-fee set-aside for an ASK-side order — the `Quote`-side
    /// mirror of `fee_reserve_base` above (populated only for ask-side
    /// orders, `None` for a bid-side order).
    fee_reserve_quote: Option<Balance<Quote>>,
}

/// `base_size` is always the Base-denominated order size (for a bid, the
/// quantity of Base this order wants to buy; for an ask, the quantity of
/// Base it wants to sell) — regardless of side. `original_size` is always
/// set to exactly this value. For an ASK-side order, `remaining_size` also
/// starts at this same value (Base-denominated, matching `escrow_base`'s
/// value). For a BID-side order, `remaining_size` instead starts at
/// `total_reserved` (the live `Quote` escrow value) — see the
/// `remaining_size` field doc comment above for why bid- and ask-side
/// orders deliberately diverge here.
public(package) fun new<Base, Quote>(
    order_id: u64,
    owner: address,
    base_size: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
): Order<Base, Quote> {
    let total_reserved = if (escrow_quote.is_some()) {
        escrow_quote.borrow().value()
    } else {
        0
    };
    // A bid-side order escrows Quote (`escrow_quote.is_some()`); an ask-side
    // order escrows Base. Every real call site (`place_limit_order_bid`/
    // `_ask`) populates exactly one of the two, mirroring the convention
    // `fee_reserve_base`/`fee_reserve_quote` follow below.
    let is_bid_side = escrow_quote.is_some();
    let remaining_size = if (is_bid_side) { total_reserved } else { base_size };
    let (fee_reserve_base, fee_reserve_quote) = if (is_bid_side) {
        (option::some(balance::zero<Base>()), option::none())
    } else {
        (option::none(), option::some(balance::zero<Quote>()))
    };
    Order {
        order_id, owner, remaining_size, escrow_base, escrow_quote, maker_fee_bps,
        original_size: base_size,
        total_reserved,
        fee_basis_accumulated: 0,
        fee_reserve_base,
        fee_reserve_quote,
    }
}

public(package) fun decrease_remaining_size<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64) {
    o.remaining_size = o.remaining_size - amount;
}

public(package) fun split_escrow_base<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64): Balance<Base> {
    o.escrow_base.borrow_mut().split(amount)
}

public(package) fun split_escrow_quote<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64): Balance<Quote> {
    o.escrow_quote.borrow_mut().split(amount)
}

public(package) fun set_owner<Base, Quote>(o: &mut Order<Base, Quote>, new_owner: address) {
    o.owner = new_owner;
}

/// Returns `(escrow_base, escrow_quote, fee_reserve_base, fee_reserve_quote)`.
/// The fee-reserve pair must be inspected/settled by the caller (via
/// `tiny_clob::conclude_order_fee` and its side-specific unwrap helpers) —
/// unlike the escrow pair, which may be safely destroyed once known to be
/// zero/empty, an order's `fee_reserve_base`/`fee_reserve_quote` may still
/// hold real, uncollected fee value even at conclusion and must never be
/// silently dropped.
public(package) fun destroy<Base, Quote>(
    o: Order<Base, Quote>,
): (Option<Balance<Base>>, Option<Balance<Quote>>, Option<Balance<Base>>, Option<Balance<Quote>>) {
    let Order {
        order_id: _, owner: _, remaining_size: _, escrow_base, escrow_quote, maker_fee_bps: _,
        original_size: _, total_reserved: _, fee_basis_accumulated: _,
        fee_reserve_base, fee_reserve_quote,
    } = o;
    (escrow_base, escrow_quote, fee_reserve_base, fee_reserve_quote)
}

public(package) fun id<Base, Quote>(o: &Order<Base, Quote>): u64 { o.order_id }
public(package) fun owner<Base, Quote>(o: &Order<Base, Quote>): address { o.owner }
public(package) fun remaining_size<Base, Quote>(o: &Order<Base, Quote>): u64 { o.remaining_size }
public(package) fun maker_fee_bps<Base, Quote>(o: &Order<Base, Quote>): u64 { o.maker_fee_bps }
public(package) fun original_size<Base, Quote>(o: &Order<Base, Quote>): u64 { o.original_size }
public(package) fun total_reserved<Base, Quote>(o: &Order<Base, Quote>): u64 { o.total_reserved }

/// The live `Quote` escrow balance still held by this order (0 if none, or
/// if this is an ask-side order with no `Quote` escrow leg). For a
/// bid-side order this is the ground truth used to derive how much has
/// already been charged so far: `total_reserved(o) - escrow_quote_value(o)`.
public(package) fun escrow_quote_value<Base, Quote>(o: &Order<Base, Quote>): u64 {
    if (o.escrow_quote.is_some()) o.escrow_quote.borrow().value() else 0
}

/// See the `fee_basis_accumulated` field doc comment.
public(package) fun fee_basis_accumulated<Base, Quote>(o: &Order<Base, Quote>): u64 {
    o.fee_basis_accumulated
}

public(package) fun increase_fee_basis_accumulated<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64) {
    o.fee_basis_accumulated = o.fee_basis_accumulated + amount;
}

/// Joins `b` into this (bid-side) order's `fee_reserve_base`. Aborts if this
/// order is ask-side (`fee_reserve_base` is `None`) — every call site is
/// expected to already know this order's side.
public(package) fun join_fee_reserve_base<Base, Quote>(o: &mut Order<Base, Quote>, b: Balance<Base>) {
    o.fee_reserve_base.borrow_mut().join(b);
}

/// Joins `b` into this (ask-side) order's `fee_reserve_quote`. Aborts if
/// this order is bid-side (`fee_reserve_quote` is `None`) — every call site
/// is expected to already know this order's side.
public(package) fun join_fee_reserve_quote<Base, Quote>(o: &mut Order<Base, Quote>, b: Balance<Quote>) {
    o.fee_reserve_quote.borrow_mut().join(b);
}

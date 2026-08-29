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
    remaining_size: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
    /// Set once, at construction, to whatever `remaining_size` is at that
    /// moment (i.e. the quantity that actually starts resting — for a limit
    /// order that partially fills during its own placement sweep before
    /// resting, this is the post-sweep remainder, not the taker's original
    /// full requested size). Never mutated afterward. Together with
    /// `escrow_quote_value` (the live escrow balance), this lets
    /// `fill_level_ask` charge a resting bid's escrow via a
    /// delta-of-cumulative-proportional-ceiling scheme
    /// (`ceil(total_reserved * cumulative_filled / original_size)`, clamped
    /// at `total_reserved`, at each fill, minus what was already charged —
    /// the latter derived as `total_reserved - escrow_quote_value`)
    /// that telescopes to exactly the order's actual `total_reserved`
    /// escrow with zero dust, no matter how many separate fills/transactions
    /// the order is drained across. Only
    /// bid-side resting orders need this field; it exists (unused) on
    /// ask-side orders too, matching how `escrow_base`/`escrow_quote`
    /// already sit unused on one side or the other.
    original_size: u64,
    /// Set once, at construction, to the actual `Quote` balance value
    /// handed to this order's escrow at that moment (0 if none). For a
    /// bid-side order, this is the ground truth for how much quote is
    /// really available to this order over its lifetime — unlike a fresh
    /// `bid_escrow_amount` recomputation, it already reflects any rounding
    /// shortfall clamped in at placement (see `place_limit_order_bid`'s
    /// resting-remainder clamp). `fill_level_ask` charges each fill a
    /// proportional ceiling of this value, clamped at `total_reserved`
    /// itself, so the running total can never exceed what was actually
    /// reserved. The running total already charged so far is not stored
    /// separately — it is always exactly `total_reserved -
    /// escrow_quote_value(&order)`, since every fill decrements the live
    /// escrow balance by precisely the amount it charges. Only bid-side
    /// resting orders need this field; it exists (unused) on ask-side
    /// orders too, matching how `escrow_base`/`escrow_quote` already sit
    /// unused on one side or the other.
    total_reserved: u64,
}

public(package) fun new<Base, Quote>(
    order_id: u64,
    owner: address,
    remaining_size: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
): Order<Base, Quote> {
    let total_reserved = if (escrow_quote.is_some()) {
        balance::value(escrow_quote.borrow())
    } else {
        0
    };
    Order {
        order_id, owner, remaining_size, escrow_base, escrow_quote, maker_fee_bps,
        original_size: remaining_size,
        total_reserved,
    }
}

public(package) fun decrease_remaining_size<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64) {
    o.remaining_size = o.remaining_size - amount;
}

public(package) fun split_escrow_base<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64): Balance<Base> {
    balance::split(o.escrow_base.borrow_mut(), amount)
}

public(package) fun split_escrow_quote<Base, Quote>(o: &mut Order<Base, Quote>, amount: u64): Balance<Quote> {
    balance::split(o.escrow_quote.borrow_mut(), amount)
}

public(package) fun set_owner<Base, Quote>(o: &mut Order<Base, Quote>, new_owner: address) {
    o.owner = new_owner;
}

public(package) fun destroy<Base, Quote>(
    o: Order<Base, Quote>,
): (Option<Balance<Base>>, Option<Balance<Quote>>) {
    let Order {
        order_id: _, owner: _, remaining_size: _, escrow_base, escrow_quote, maker_fee_bps: _,
        original_size: _, total_reserved: _,
    } = o;
    (escrow_base, escrow_quote)
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
    if (o.escrow_quote.is_some()) balance::value(o.escrow_quote.borrow()) else 0
}

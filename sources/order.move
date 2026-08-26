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
}

public(package) fun new<Base, Quote>(
    order_id: u64,
    owner: address,
    remaining_size: u64,
    escrow_base: Option<Balance<Base>>,
    escrow_quote: Option<Balance<Quote>>,
    maker_fee_bps: u64,
): Order<Base, Quote> {
    Order { order_id, owner, remaining_size, escrow_base, escrow_quote, maker_fee_bps }
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
    let Order { order_id: _, owner: _, remaining_size: _, escrow_base, escrow_quote, maker_fee_bps: _ } = o;
    (escrow_base, escrow_quote)
}

public(package) fun id<Base, Quote>(o: &Order<Base, Quote>): u64 { o.order_id }
public(package) fun owner<Base, Quote>(o: &Order<Base, Quote>): address { o.owner }
public(package) fun remaining_size<Base, Quote>(o: &Order<Base, Quote>): u64 { o.remaining_size }
public(package) fun maker_fee_bps<Base, Quote>(o: &Order<Base, Quote>): u64 { o.maker_fee_bps }

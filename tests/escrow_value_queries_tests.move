#[test_only]
module tiny_clob::escrow_value_queries_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};
use tiny_clob::test_utils::{
    Self, admin, other, taker, maker_a, maker_b, maker_c, min_size, max_min_size,
    default_price, default_size, shortfall_price, new_book, destroy_book_and_cap,
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks,
};


// === Change 2: `bid_quote_escrow_at_price` exact dual-aggregate tracking ===

#[test]
fun bid_quote_escrow_at_price_matches_single_order_after_partial_fill() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    let size = 100;
    scenario.next_tx(maker_a());
    let reserved = tiny_clob::bid_escrow_amount(&book, shortfall_price(), size);
    let bid_ticket = rest_bid(&mut book, shortfall_price(), size, 10, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    // Fresh order: the level's maintained aggregate must equal the single
    // order's own full reservation.
    assert!(tiny_clob::bid_quote_escrow_at_price(&book, shortfall_price()) == reserved, 0);
    // No bid level at any other price.
    assert!(tiny_clob::bid_quote_escrow_at_price(&book, shortfall_price() + 1) == 0, 1);

    // Partially fill it and confirm the aggregate exactly tracks the fill's
    // actual charge (read off the `OrderFilled` event's own `quote_amount`,
    // rather than re-deriving the ceiling formula by hand in the test).
    scenario.next_tx(maker_b());
    let fill_qty = 30;
    let base = coin::mint_for_testing<BTC>(fill_qty, scenario.ctx());
    let (t, lb, mq, _) = tiny_clob::place_limit_order_ask(&mut book, shortfall_price(), fill_qty, base, 10, scenario.ctx());
    assert!(t.is_none(), 2);
    option::destroy_none(t);
    coin::burn_for_testing(lb);
    let quote_charged = coin::burn_for_testing(mq);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 3);
    let (ev_maker_side, ev_quote_amount, _, _) = tiny_clob::order_filled_fee_fields_for_testing(&fills[0]);
    assert!(ev_maker_side, 4);
    assert!(ev_quote_amount == quote_charged, 5);

    let expected_remaining = reserved - quote_charged;
    assert!(tiny_clob::bid_quote_escrow_at_price(&book, shortfall_price()) == expected_remaining, 6);

    // Cross-check against the per-order query (Change 3), which must agree
    // exactly since there's only one order at this price.
    let escrow_opt = tiny_clob::resting_order_escrow(&book, true, shortfall_price(), order_id);
    assert!(escrow_opt.is_some(), 7);
    let (per_order_escrow, per_order_remaining_size) =
        tiny_clob::resting_order_escrow_fields(escrow_opt.borrow());
    assert!(per_order_escrow == expected_remaining, 8);
    assert!(per_order_remaining_size == size - fill_qty, 9);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun bid_quote_escrow_at_price_sums_two_orders_at_same_price() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size_a = 100;
    let reserved_a = tiny_clob::bid_escrow_amount(&book, shortfall_price(), size_a);
    let ticket_a = rest_bid(&mut book, shortfall_price(), size_a, 10, scenario.ctx());

    scenario.next_tx(maker_b());
    let size_b = 50;
    let reserved_b = tiny_clob::bid_escrow_amount(&book, shortfall_price(), size_b);
    let ticket_b = rest_bid(&mut book, shortfall_price(), size_b, 10, scenario.ctx());

    // The maintained aggregate is the exact sum of each order's own live
    // escrow -- not a derived/re-estimated value.
    assert!(tiny_clob::bid_quote_escrow_at_price(&book, shortfall_price()) == reserved_a + reserved_b, 0);

    // Cancelling both drains the level back to empty; the aggregate must
    // reach exactly 0 (proven indirectly: `destroy_empty_price_level`'s
    // strengthened assert on `total_quote_escrow == 0` would abort
    // otherwise, and this cancellation path exercises that cleanup).
    scenario.next_tx(maker_a());
    let (cb_a, cq_a) = tiny_clob::cancel_order(&mut book, ticket_a, scenario.ctx());
    coin::burn_for_testing(cb_a);
    assert!(coin::burn_for_testing(cq_a) == reserved_a, 1);
    assert!(tiny_clob::bid_quote_escrow_at_price(&book, shortfall_price()) == reserved_b, 2);

    scenario.next_tx(maker_b());
    let (cb_b, cq_b) = tiny_clob::cancel_order(&mut book, ticket_b, scenario.ctx());
    coin::burn_for_testing(cb_b);
    assert!(coin::burn_for_testing(cq_b) == reserved_b, 3);
    assert!(tiny_clob::bid_quote_escrow_at_price(&book, shortfall_price()) == 0, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Change 3: `resting_order_escrow` / `resting_order_escrow_by_ticket` ===

#[test]
fun resting_order_escrow_fresh_bid_and_ask() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let bid_size = default_size();
    let reserved = tiny_clob::bid_escrow_amount(&book, default_price(), bid_size);
    let bid_ticket = rest_bid(&mut book, default_price(), bid_size, 10, scenario.ctx());
    let bid_order_id = tiny_clob::ticket_order_id(&bid_ticket);

    let bid_escrow_opt = tiny_clob::resting_order_escrow(&book, true, default_price(), bid_order_id);
    assert!(bid_escrow_opt.is_some(), 0);
    let (bid_escrow, bid_remaining) = tiny_clob::resting_order_escrow_fields(bid_escrow_opt.borrow());
    assert!(bid_escrow == reserved, 1);
    assert!(bid_remaining == bid_size, 2);

    // Same result via the ticket-based wrapper.
    let bid_escrow_opt_via_ticket = tiny_clob::resting_order_escrow_by_ticket(&book, &bid_ticket);
    assert!(bid_escrow_opt_via_ticket.is_some(), 3);
    let (bid_escrow_2, bid_remaining_2) =
        tiny_clob::resting_order_escrow_fields(bid_escrow_opt_via_ticket.borrow());
    assert!(bid_escrow_2 == reserved, 4);
    assert!(bid_remaining_2 == bid_size, 5);

    scenario.next_tx(maker_b());
    let ask_price = default_price() + 1; // above best bid, so it just rests.
    let ask_size = default_size();
    let ask_ticket = rest_ask(&mut book, ask_price, ask_size, 10, scenario.ctx());
    let ask_order_id = tiny_clob::ticket_order_id(&ask_ticket);

    // An ask escrows Base, exactly equal to `remaining_size`.
    let ask_escrow_opt = tiny_clob::resting_order_escrow(&book, false, ask_price, ask_order_id);
    assert!(ask_escrow_opt.is_some(), 6);
    let (ask_escrow, ask_remaining) = tiny_clob::resting_order_escrow_fields(ask_escrow_opt.borrow());
    assert!(ask_escrow == ask_size, 7);
    assert!(ask_remaining == ask_size, 8);

    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun resting_order_escrow_after_partial_fill_full_fill_and_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size = 200;
    let reserved = tiny_clob::bid_escrow_amount(&book, default_price(), size);
    let bid_ticket = rest_bid(&mut book, default_price(), size, 10, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    // Partial fill: escrow decreases by exactly the fill's own charged
    // amount (read off the `OrderFilled` event), remaining_size decreases
    // by the fill quantity.
    scenario.next_tx(taker());
    let fill_qty = min_size();
    let ask_payment = coin::mint_for_testing<BTC>(fill_qty, scenario.ctx());
    let (leftover, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_qty, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover);
    let quote_charged = coin::burn_for_testing(matched_quote);

    let opt_after_partial = tiny_clob::resting_order_escrow(&book, true, default_price(), order_id);
    assert!(opt_after_partial.is_some(), 0);
    let (escrow_after_partial, remaining_after_partial) =
        tiny_clob::resting_order_escrow_fields(opt_after_partial.borrow());
    assert!(escrow_after_partial == reserved - quote_charged, 1);
    assert!(remaining_after_partial == size - fill_qty, 2);

    // Full fill: the order is completely drained and removed, so the query
    // must return None (distinct from `Some((0, r>0))`).
    scenario.next_tx(taker());
    let remaining_size = size - fill_qty;
    let ask_payment_2 = coin::mint_for_testing<BTC>(remaining_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = tiny_clob::place_market_order_ask(
        &mut book, remaining_size, ask_payment_2, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_2);
    coin::burn_for_testing(matched_quote_2);
    assert!(tiny_clob::resting_order_escrow(&book, true, default_price(), order_id).is_none(), 3);

    // Cancel path: rest a fresh order, then cancel it -- must also read back
    // as None.
    scenario.next_tx(maker_b());
    let bid_ticket_2 = rest_bid(&mut book, default_price(), size, 10, scenario.ctx());
    let order_id_2 = tiny_clob::ticket_order_id(&bid_ticket_2);
    assert!(tiny_clob::resting_order_escrow(&book, true, default_price(), order_id_2).is_some(), 4);
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket_2, scenario.ctx());
    coin::burn_for_testing(cb);
    coin::burn_for_testing(cq);
    assert!(tiny_clob::resting_order_escrow(&book, true, default_price(), order_id_2).is_none(), 5);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun resting_order_escrow_wrong_lookup_is_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    // Sanity: the correct lookup succeeds.
    assert!(tiny_clob::resting_order_escrow(&book, true, default_price(), order_id).is_some(), 0);

    // Wrong side: no ask level exists at this price at all.
    assert!(tiny_clob::resting_order_escrow(&book, false, default_price(), order_id).is_none(), 1);
    // Wrong price: no bid level exists there.
    assert!(tiny_clob::resting_order_escrow(&book, true, default_price() + 1, order_id).is_none(), 2);
    // Wrong order_id: the level exists but doesn't contain this id.
    assert!(tiny_clob::resting_order_escrow(&book, true, default_price(), order_id + 1).is_none(), 3);

    // Ticket-based wrapper aborts on a ticket minted by a different book.
    let (other_book, other_cap) = new_book(&mut scenario);
    let other_book_id = tiny_clob::id_for_testing(&other_book);
    let foreign_ticket = tiny_clob::new_ticket_for_testing(order_id, other_book_id, tiny_clob::bid_for_testing(), default_price());
    // (Not calling resting_order_escrow_by_ticket(&book, &foreign_ticket)
    // here to avoid an abort mid-test; wrong-book behavior is exercised in
    // resting_order_escrow_by_ticket_wrong_book_aborts below.)
    unit_test::destroy(foreign_ticket);
    destroy_book_and_cap(other_book, other_cap);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // EWrongBook
fun resting_order_escrow_by_ticket_wrong_book_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);
    let (other_book, other_cap) = new_book(&mut scenario);

    let other_book_id = tiny_clob::id_for_testing(&other_book);
    let foreign_ticket = tiny_clob::new_ticket_for_testing(0, other_book_id, tiny_clob::bid_for_testing(), default_price());
    let _ = tiny_clob::resting_order_escrow_by_ticket(&book, &foreign_ticket);

    unit_test::destroy(foreign_ticket);
    destroy_book_and_cap(book, cap);
    destroy_book_and_cap(other_book, other_cap);
    scenario.end();
}

// Reachable `Some((0, r))` state: the order's escrow is fully charged
// (clamped at its own `total_reserved`, which is strictly less than what a
// full drain of `original_size` would otherwise imply -- the shortfall
// scenario), yet it's still resting with real remaining size. Distinct from
// `None` (not resting at all).
#[test]
fun resting_order_escrow_reaches_some_zero_escrow_while_still_resting() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    // Same setup as `partial_cross_then_rest_full_drain_across_multiple_fills_is_zero_dust`:
    // resting bid remainder has original_size=7, total_reserved=2.
    scenario.next_tx(maker_a());
    let ask_ticket = rest_ask(&mut book, shortfall_price(), 1, 10, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, shortfall_price(), 10, payment, 10, scenario.ctx());
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);
    let bid_ticket = option::destroy_some(ticket_opt);
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    // Fill 4 of the remaining 7 units: ceil(2*4/7) = 2 = total_reserved
    // exactly, so the escrow is fully charged (clamped) while 3 units of
    // remaining_size are still genuinely resting.
    scenario.next_tx(maker_b());
    let base = coin::mint_for_testing<BTC>(4, scenario.ctx());
    let (t, lb, mq, _) = tiny_clob::place_limit_order_ask(&mut book, shortfall_price(), 4, base, 10, scenario.ctx());
    assert!(t.is_none(), 0);
    option::destroy_none(t);
    coin::burn_for_testing(lb);
    coin::burn_for_testing(mq);

    let escrow_opt = tiny_clob::resting_order_escrow(&book, true, shortfall_price(), order_id);
    assert!(escrow_opt.is_some(), 1);
    let (escrow, remaining) = tiny_clob::resting_order_escrow_fields(escrow_opt.borrow());
    assert!(escrow == 0, 2);
    assert!(remaining == 3, 3);

    // Matches the same read via `resting_order_escrow_by_ticket`.
    let escrow_opt_via_ticket = tiny_clob::resting_order_escrow_by_ticket(&book, &bid_ticket);
    assert!(escrow_opt_via_ticket.is_some(), 4);
    let (escrow_2, remaining_2) = tiny_clob::resting_order_escrow_fields(escrow_opt_via_ticket.borrow());
    assert!(escrow_2 == 0, 5);
    assert!(remaining_2 == 3, 6);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}


// === Additional coverage: independently-verified gaps from the design review ===

#[test]
fun bid_quote_escrow_at_price_sums_two_orders_one_partially_filled() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size_a = 500;
    let ticket_a = rest_bid(&mut book, shortfall_price(), size_a, 10, scenario.ctx());

    scenario.next_tx(maker_b());
    let size_b = 300;
    let ticket_b = rest_bid(&mut book, shortfall_price(), size_b, 10, scenario.ctx());

    // Partially cross the FRONT order (A, by FIFO) only.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(137, scenario.ctx());
    let (ask_ticket_opt, leftover_b, matched_q, _) =
        tiny_clob::place_limit_order_ask(&mut book, shortfall_price(), 137, ask_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(leftover_b) == 0, 0);
    coin::burn_for_testing(matched_q);
    assert!(ask_ticket_opt.is_none(), 1);
    option::destroy_none(ask_ticket_opt);

    // The maintained aggregate must equal the exact sum of each order's own
    // live escrow, even with one of the two orders now partially drained.
    let escrow_a = tiny_clob::resting_order_escrow(
        &book, tiny_clob::bid(), shortfall_price(), tiny_clob::ticket_order_id(&ticket_a),
    );
    let escrow_b = tiny_clob::resting_order_escrow(
        &book, tiny_clob::bid(), shortfall_price(), tiny_clob::ticket_order_id(&ticket_b),
    );
    let (escrow_a_val, _) = tiny_clob::resting_order_escrow_fields(escrow_a.borrow());
    let (escrow_b_val, _) = tiny_clob::resting_order_escrow_fields(escrow_b.borrow());
    assert!(escrow_a_val < tiny_clob::bid_escrow_amount(&book, shortfall_price(), size_a), 2); // A genuinely drained some
    assert!(
        tiny_clob::bid_quote_escrow_at_price(&book, shortfall_price()) == escrow_a_val + escrow_b_val,
        3,
    );

    unit_test::destroy(escrow_a);
    unit_test::destroy(escrow_b);
    unit_test::destroy(ticket_a);
    unit_test::destroy(ticket_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

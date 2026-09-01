#[test_only]
module tiny_clob::order_placement_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};
use tiny_clob::test_utils::{
    Self, admin, default_price, default_size, new_book, destroy_book_and_cap, rest_bid, rest_ask, u64_max,
};


#[test]
fun place_limit_order_bid_rests_and_emits_orderplaced() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, default_size(), 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == 0, 1);
    assert!(leftover_quote.burn_for_testing() == 0, 2);
    let ticket = ticket_opt.destroy_some();
    let t_order_id = ticket.ticket_order_id();
    let t_book_id = ticket.ticket_order_book_id();
    let t_side = ticket.ticket_side();
    let t_price = ticket.ticket_price();
    assert!(t_book_id == book_id, 3);
    assert!(t_side == true, 4);
    assert!(t_price == default_price(), 5);

    let placed_events = event::events_by_type<tiny_clob::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);
    let (ev_book_id, _ev_enclosing_id, ev_order_id, ev_side, ev_price, ev_size, ev_trader, ev_maker_fee_bps) =
        placed_events[0].order_placed_fields_for_testing();
    assert!(ev_order_id == t_order_id, 7);
    assert!(ev_book_id == book_id, 8);
    assert!(ev_side == true, 9);
    assert!(ev_price == default_price(), 10);
    assert!(ev_size == default_size(), 11);
    assert!(ev_trader == admin(), 12);
    assert!(ev_maker_fee_bps == 0, 13);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_rests_and_emits_orderplaced() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    let payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let expected_quote_output = book.bid_escrow_amount(default_price(), default_size());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1);
    assert!(matched_quote.burn_for_testing() == 0, 2);
    let ticket = ticket_opt.destroy_some();
    let t_order_id = ticket.ticket_order_id();
    let t_book_id = ticket.ticket_order_book_id();
    let t_side = ticket.ticket_side();
    let t_price = ticket.ticket_price();
    assert!(t_book_id == book_id, 3);
    assert!(t_side == false, 4);
    assert!(t_price == default_price(), 5);

    let placed_events = event::events_by_type<tiny_clob::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);
    let (ev_book_id, _ev_enclosing_id, ev_order_id, ev_side, ev_price, ev_size, ev_trader, ev_maker_fee_bps) =
        placed_events[0].order_placed_fields_for_testing();
    assert!(ev_order_id == t_order_id, 7);
    assert!(ev_book_id == book_id, 8);
    assert!(ev_side == false, 9);
    assert!(ev_price == default_price(), 10);
    assert!(ev_size == default_size(), 11);
    assert!(ev_trader == admin(), 12);
    assert!(ev_maker_fee_bps == 0, 13);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_bid_matches_resting_ask() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = book.bid_escrow_amount(default_price(), default_size());
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, _) = book.place_market_order_bid(bid_payment, 1_000_000_000, 0, default_size(), u64_max(), scenario.ctx(),
    );
    assert!(matched_base.burn_for_testing() == default_size(), 0);
    assert!(leftover_payment.burn_for_testing() == 0, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Regression: `place_market_order_bid` must merge the two leftover
/// `Coin<Quote>` pieces — the unspent portion of `budget` (from matching)
/// and the portion of the caller's original `payment` never earmarked as
/// `budget` — into a single returned coin. Here `budget` is fully spent
/// (exact match against a same-sized resting ask), so the entire merged
/// leftover must come from the untouched `payment - budget` slice alone.
#[test]
fun place_market_order_bid_merges_leftover_budget_and_payment_when_payment_exceeds_budget() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = book.bid_escrow_amount(default_price(), default_size());
    let bid_payment = coin::mint_for_testing<USDC>(budget + 777, scenario.ctx());
    let (matched_base, leftover_payment, _) = book.place_market_order_bid(bid_payment, 1_000_000_000, 0, default_size(), u64_max(), scenario.ctx(),
    );
    assert!(matched_base.burn_for_testing() == default_size(), 0);
    // budget is fully spent (0 leftover from matching) + 777 leftover from
    // the untouched payment slice above budget.
    assert!(leftover_payment.burn_for_testing() == 777, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_ask_matches_resting_bid() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    assert!(leftover_payment.burn_for_testing() == 0, 0);
    assert!(matched_quote.burn_for_testing() == escrow_amount, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}


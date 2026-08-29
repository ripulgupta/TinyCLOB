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
    Self, admin, other, taker, maker_a, maker_b, maker_c, min_size, max_min_size,
    default_price, default_size, shortfall_price, new_book, destroy_book_and_cap,
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks,
};


#[test]
fun place_limit_order_bid_rests_and_emits_orderplaced() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, default_price(), default_size());
    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, default_price(), default_size(), payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 0, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    let ticket = option::destroy_some(ticket_opt);
    let (t_order_id, t_book_id, t_side, t_price) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_book_id == book_id, 3);
    assert!(t_side == true, 4);
    assert!(t_price == default_price(), 5);

    let placed_events = event::events_by_type<tiny_clob::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);
    let (ev_order_id, ev_book_id, ev_side, ev_price, ev_size, ev_trader, ev_maker_fee_bps) =
        tiny_clob::order_placed_fields_for_testing(&placed_events[0]);
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
    let book_id = tiny_clob::id_for_testing(&book);

    let payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, default_price(), default_size(), payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == 0, 2);
    let ticket = option::destroy_some(ticket_opt);
    let (_t_order_id, t_book_id, t_side, t_price) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_book_id == book_id, 3);
    assert!(t_side == false, 4);
    assert!(t_price == default_price(), 5);

    let placed_events = event::events_by_type<tiny_clob::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);

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

    let budget = tiny_clob::bid_escrow_amount(&book, default_price(), default_size());
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, _) = tiny_clob::place_market_order_bid(
        &mut book, default_size(), budget, bid_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == default_size(), 0);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 1);

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

    let budget = tiny_clob::bid_escrow_amount(&book, default_price(), default_size());
    let bid_payment = coin::mint_for_testing<USDC>(budget + 777, scenario.ctx());
    let (matched_base, leftover_payment, _) = tiny_clob::place_market_order_bid(
        &mut book, default_size(), budget, bid_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == default_size(), 0);
    // budget is fully spent (0 leftover from matching) + 777 leftover from
    // the untouched payment slice above budget.
    assert!(coin::burn_for_testing(leftover_payment) == 777, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_ask_matches_resting_bid() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, default_price(), default_size());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, default_size(), ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(leftover_payment) == 0, 0);
    assert!(coin::burn_for_testing(matched_quote) == escrow_amount, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Merge item 1: unlike `place_market_order_bid`'s equivalent happy-path
// test, this exercises `swap_bid` with a real `Some(limit_price)` (loose
// enough to still allow the match — exactly the resting price) instead of
// `option::none()`, so it actually covers `swap_bid`'s limit-price
// acceptance path rather than duplicating market-order coverage verbatim.
#[test]
fun swap_bid_matches_resting_ask() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = tiny_clob::bid_escrow_amount(&book, default_price(), default_size());
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, stopped) = tiny_clob::swap_bid(
        &mut book, default_size(), budget, bid_payment, 1_000_000_000,
        option::some(default_price()), option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == default_size(), 1);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Merge item 1 (ask side): same rationale as `swap_bid_matches_resting_ask`
// above — a real `Some(limit_price)` at exactly the resting bid's price,
// loose enough to still fully match.
#[test]
fun swap_ask_matches_resting_bid() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, default_price(), default_size());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, stopped) = tiny_clob::swap_ask(
        &mut book, default_size(), ask_payment, 1_000_000_000,
        option::some(default_price()), option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == escrow_amount, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Regression: `swap_bid` must merge the two leftover `Coin<Quote>` pieces
/// into a single returned coin, mirroring the equivalent
/// `place_market_order_bid` regression test above. Here `budget` is only
/// partially spent — the resting ask covers only half the requested taker
/// size, so half the `budget` balance is never matched — so the merged
/// leftover must equal the sum of the matching engine's own unspent
/// `budget` remainder AND the untouched `payment - budget` slice.
#[test]
fun swap_bid_merges_leftover_budget_and_payment_when_payment_exceeds_budget() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let requested_size = default_size() * 2;
    let ask_ticket = rest_ask(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = tiny_clob::bid_escrow_amount(&book, default_price(), requested_size);
    let expected_spent = tiny_clob::bid_escrow_amount(&book, default_price(), default_size());
    let bid_payment = coin::mint_for_testing<USDC>(budget + 777, scenario.ctx());
    let (matched_base, leftover_payment, stopped) = tiny_clob::swap_bid(
        &mut book, requested_size, budget, bid_payment, 1_000_000_000,
        option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == default_size(), 1);
    // (budget - expected_spent) leftover from matching + 777 leftover from
    // the untouched payment slice above budget.
    assert!(coin::burn_for_testing(leftover_payment) == (budget - expected_spent) + 777, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test_only]
module tiny_clob::placement_validation_and_returns_tests;

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


const PLACEMENT_PRICE: u64 = 50_000;
const PLACEMENT_SIZE: u64 = 100;

// =====================================================================
// Option<OrderTicket> return: place_limit_order_bid/ask must only hand back
// a live ticket when the order genuinely rests. A fully-filled or
// max_fills-truncated placement must return `option::none()`.
// =====================================================================

const OPT_PRICE: u64 = 50_000;

#[test]
fun place_limit_order_bid_ask_happy_path_fills_and_rests() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Resting ask, then a crossing bid fills it fully.
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (ask_ticket_opt, ask_matched_base, ask_leftover_base, ask_stop) =
        tiny_clob::place_limit_order_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, ask_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(ask_matched_base) == 0, 0);
    assert!(coin::burn_for_testing(ask_leftover_base) == 0, 1);
    assert!(!ask_stop, 2);
    let ask_ticket = option::destroy_some(ask_ticket_opt);

    scenario.next_tx(taker());
    let bid_payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, bid_stop) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, bid_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(bid_matched_base) == PLACEMENT_SIZE, 3);
    assert!(coin::burn_for_testing(bid_leftover_quote) == 0, 4);
    assert!(!bid_stop, 5);
    assert!(bid_ticket_opt.is_none(), 6);
    option::destroy_none(bid_ticket_opt);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun place_limit_order_zero_price_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket_opt, mb, ml, _) = tiny_clob::place_limit_order_bid(&mut book, 0, PLACEMENT_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun place_limit_order_size_validation_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE - 1, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun placement_functions_abort_when_paused() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_bid_ask_happy_path() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, _) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(leftover) == 0, 1);

    scenario.next_tx(taker());
    let bid_ticket2 = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());
    let ask_payment2 = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, _) =
        tiny_clob::place_market_order_ask(&mut book, PLACEMENT_SIZE, ask_payment2, 10, option::none(), option::none(), scenario.ctx());
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 3);
    assert!(coin::burn_for_testing(leftover_base) == 0, 4);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun place_market_order_bid_slippage_bound_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, _) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::some(PLACEMENT_SIZE + 1), scenario.ctx(),
    );
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun swap_bid_ask_happy_path_and_max_fills_stop_signal() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, stop) = tiny_clob::swap_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(leftover) == 0, 1);
    assert!(!stop, 2);

    // max_fills = 0 against a crossing resting ask signals the stop-reason.
    scenario.next_tx(taker());
    let ask_ticket2 = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());
    scenario.next_tx(taker());
    let budget2 = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment2 = coin::mint_for_testing<USDC>(budget2, scenario.ctx());
    let (matched_base2, leftover2, stop2) = tiny_clob::swap_bid(
        &mut book, PLACEMENT_SIZE, budget2, bid_payment2, 0, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base2) == 0, 4);
    assert!(coin::burn_for_testing(leftover2) == budget2, 5);
    assert!(stop2, 6);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(ask_ticket2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 3: `place_market_order_bid`/`ask` now surface the max_fills
// truncation signal, matching `swap_bid`/`swap_ask`'s existing precedent ===

#[test]
fun place_market_order_bid_returns_true_when_truncated_by_max_fills() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    // max_fills = 0 against a crossing resting ask: nothing can be matched,
    // and the truncation signal must now come back as `true`.
    let (matched_base, leftover, stopped) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 0, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == 0, 0);
    assert!(coin::burn_for_testing(leftover) == budget, 1);
    assert!(stopped, 2);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_bid_returns_false_when_fully_filled_within_max_fills() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, stopped) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(leftover) == 0, 1);
    assert!(!stopped, 2);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_ask_returns_true_when_truncated_by_max_fills() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, stopped) = tiny_clob::place_market_order_ask(
        &mut book, PLACEMENT_SIZE, ask_payment, 0, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(leftover_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(matched_quote) == 0, 1);
    assert!(stopped, 2);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_ask_returns_false_when_fully_filled_within_max_fills() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, stopped) = tiny_clob::place_market_order_ask(
        &mut book, PLACEMENT_SIZE, ask_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(leftover_base) == 0, 0);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 1);
    assert!(!stopped, 2);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun swap_ask_slippage_bound_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let min_quote_bound = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE) + 1;
    let (leftover_base, matched_quote, stop) = tiny_clob::swap_ask(
        &mut book, PLACEMENT_SIZE, ask_payment, 10, option::none(),
        option::some(min_quote_bound), option::none(), scenario.ctx(),
    );
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    let _ = stop;
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_and_claim_never_block_on_pause_or_retiring() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid, pause the book, then cancel — must succeed despite pause.
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    let (cancel_base, cancel_quote) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cancel_base) == 0, 0);
    assert!(coin::burn_for_testing(cancel_quote) == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 1);

    // claim_proceeds also succeeds while retiring.
    // The order was never resting for this order_id, so use a synthetic
    // ticket (bypassing the placement path, which isn't needed here) — the
    // claim finds nothing pooled, and since order_id 999 was never actually
    // resting, claim_proceeds auto-destroys the ticket and returns
    // option::none().
    tiny_clob::clob_admin_retire(&cap, &mut book);
    let book_id = tiny_clob::id_for_testing(&book);
    let dummy_ticket =
        tiny_clob::new_ticket_for_testing(999, book_id, tiny_clob::bid_for_testing(), PLACEMENT_PRICE);
    let (claim_base, claim_quote, returned_ticket_opt) =
        tiny_clob::claim_proceeds(&mut book, dummy_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(claim_base) == 0, 2);
    assert!(coin::burn_for_testing(claim_quote) == 0, 3);
    assert!(returned_ticket_opt.is_none(), 4);
    option::destroy_none(returned_ticket_opt);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_transfers_maker_proceeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    // This bid crosses the resting ask above at the same price/size, so it
    // fully fills and never rests: the returned ticket option is `none`.
    let bid_payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, bid_payment, 10, scenario.ctx());
    option::destroy_none(bid_ticket_opt);
    coin::burn_for_testing(bid_matched_base);
    coin::burn_for_testing(bid_leftover_quote);

    scenario.next_tx(admin());
    // ask_ticket's order was fully filled by the crossing bid above, so it
    // is no longer resting — claim_proceeds auto-destroys the ticket and
    // hands back option::none().
    let (claim_base, claim_quote, returned_ticket_opt) =
        tiny_clob::claim_proceeds(&mut book, ask_ticket, scenario.ctx());
    let claimed = event::events_by_type<ProceedsClaimed>();
    assert!(claimed.length() == 1, 0);
    let (claimant, _, _base_amt, quote_amt) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed[0]);
    assert!(claimant == admin(), 1);
    assert!(quote_amt == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 2);
    coin::burn_for_testing(claim_base);
    coin::burn_for_testing(claim_quote);
    assert!(returned_ticket_opt.is_none(), 3);
    option::destroy_none(returned_ticket_opt);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_bid_fully_fills_returns_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 100, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 100, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_bid_truncated_by_max_fills_returns_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    // Two separate resting asks at the same price, so a bid limited to a
    // single fill can only drain the front one.
    let ask_a = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let ask_b = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 200), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 200, payment, 1, scenario.ctx());
    // Truncated after exactly one fill: 100 base matched, 100 remains
    // unmatched, but `should_rest` is false because the sweep stopped on
    // max_fills rather than genuinely running out of counterparty depth.
    assert!(stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 100, 1);
    assert!(coin::burn_for_testing(leftover_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(ask_a);
    unit_test::destroy(ask_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_bid_partial_fill_rests_returns_some_and_ticket_is_usable() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 300), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 300, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 100, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    assert!(ticket_opt.is_some(), 3);
    let ticket = option::destroy_some(ticket_opt);

    // The returned ticket genuinely rests for the unmatched 200 remainder:
    // cancelling it must hand back exactly that escrow.
    let (cb, cq) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cb) == 0, 4);
    assert!(coin::burn_for_testing(cq) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 200), 5);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_fully_fills_returns_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<BTC>(100, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, OPT_PRICE, 100, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_truncated_by_max_fills_returns_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_a = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let bid_b = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<BTC>(200, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, OPT_PRICE, 200, payment, 1, scenario.ctx());
    assert!(stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 100, 1);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(bid_a);
    unit_test::destroy(bid_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_partial_fill_rests_returns_some_and_ticket_is_usable() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<BTC>(300, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, OPT_PRICE, 300, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_some(), 3);
    let ticket = option::destroy_some(ticket_opt);

    // Nothing has matched against the resting 200-base remainder yet, so
    // claim_proceeds pays nothing but must still hand the ticket back
    // (it genuinely rests), proving it's a fully valid, reusable ticket.
    let (cb, cq, ticket_opt2) = tiny_clob::claim_proceeds(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cb) == 0, 4);
    assert!(coin::burn_for_testing(cq) == 0, 5);
    assert!(ticket_opt2.is_some(), 6);
    let ticket2 = option::destroy_some(ticket_opt2);

    let (rb, rq) = tiny_clob::cancel_order(&mut book, ticket2, scenario.ctx());
    assert!(coin::burn_for_testing(rb) == 200, 7);
    assert!(coin::burn_for_testing(rq) == 0, 8);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// REGRESSION: with a nonzero taker fee, a fully-filled bid's `matched_base`
/// is net of a ceiling-rounded fee, so `size - coin::value(&matched_base)`
/// is nonzero even though the order does NOT rest. A caller naively deriving
/// "still resting" from that subtraction would wrongly treat this ticket as
/// live. The real returned ticket option must be `none()`.
#[test]
fun place_limit_order_bid_full_fill_with_taker_fee_still_returns_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, 10); // 10 bps

    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 100, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    // Fee-net matched amount: ceil(100 * 10 / 10_000) = 1 taker fee -> 99.
    // The naive `size - coin::value(&matched_base)` derivation gives
    // 100 - 99 = 1 (nonzero), which would incorrectly imply the order is
    // still resting with 1 unit left. It is not: the order fully filled.
    let matched_value = coin::burn_for_testing(matched_base);
    assert!(matched_value == 99, 1);
    assert!(matched_value != 100, 2); // sanity: the naive derivation would be off
    assert!(coin::burn_for_testing(leftover_quote) == 0, 3);
    assert!(ticket_opt.is_none(), 4);
    option::destroy_none(ticket_opt);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun place_limit_order_bid_zero_price_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_bid(&mut book, 0, min_size(), 10, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun place_limit_order_ask_zero_price_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_ask(&mut book, 0, min_size(), 10, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

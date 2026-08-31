#[test_only]
module tiny_clob::events_order_filled_executed_tests;

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
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks, u64_max,
};

// Fee-rate/price/size fixture shared with the `match_bid`/`match_ask`
// regression tests in `matching_fifo_tests.move` (same values, duplicated
// here rather than promoted to `test_utils` — these are fee-fixture
// constants incidental to two topic files, not general-purpose test
// infrastructure).
const FEE_TEST_TAKER_FEE_BPS: u64 = 7;
const FEE_TEST_MAKER_FEE_BPS: u64 = 3;
const FEE_TEST_PRICE: u64 = 47_500;
const FEE_TEST_RESTING_SIZE: u64 = 4_000;
const FEE_TEST_TAKER_SIZE: u64 = 3_400;
const FEE_TEST_MAX_FILLS: u64 = 1_000_000_000;

// === OrderExecuted: fired once per entry point, discriminator proves ===
// === identity even when other fields coincide.                      ===

const OE_PRICE: u64 = 50_000;
const OE_SIZE: u64 = 100;
// Sized so a resting order this big still satisfies `min_size` (100) even
// after this test's partial fill leaves a remainder resting.
const OE_REST_SIZE: u64 = 150;
const OE_CROSS_SIZE: u64 = 200;

/// Seeds a resting ask directly via the low-level test-only insertion path
/// (bypassing `place_limit_order_ask`) so setup itself does not also emit an
/// `OrderExecuted`/`OrderPlaced` event that would contaminate the event
/// counts this test suite asserts on.
fun seed_resting_ask(book: &mut OrderBook<BTC, USDC>, price: u64, size: u64, ctx: &mut TxContext): u64 {
    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(size);
    let ask = order::new<BTC, USDC>(order_id, other(), size, option::some(escrow), option::none(), 0);
    book.insert_resting_order_for_testing(false, price, ask, ctx);
    order_id
}

/// Mirrors `seed_resting_ask` for the bid side.
fun seed_resting_bid(book: &mut OrderBook<BTC, USDC>, price: u64, size: u64, ctx: &mut TxContext): u64 {
    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(price * size);
    let bid = order::new<BTC, USDC>(order_id, other(), size, option::none(), option::some(escrow), 0);
    book.insert_resting_order_for_testing(true, price, bid, ctx);
    order_id
}

// === OrderFilled.maker_side regression: crossing direction determines ===
// === which side of the pre-existing resting order is the "maker".     ===

#[test]
fun order_filled_taker_buy_records_maker_side_false() {
    // Taker is BUYING (fill_level_bid, crossing resting ASKS) -> the
    // resting maker order is an ask -> maker_side must be false.
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, FEE_TEST_TAKER_FEE_BPS);
    cap.clob_admin_set_maker_fee(&mut book, FEE_TEST_MAKER_FEE_BPS);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(FEE_TEST_RESTING_SIZE);
    let ask = order::new<BTC, USDC>(
        order_id, other(), FEE_TEST_RESTING_SIZE, option::some(escrow), option::none(), FEE_TEST_MAKER_FEE_BPS,
    );
    book.insert_resting_order_for_testing(false, FEE_TEST_PRICE, ask, scenario.ctx());

    let payment = coin::mint_for_testing<USDC>(
        book.bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE), scenario.ctx(),
    );
    let (matched_base, remaining_budget, _remaining_size, _stopped, taker_fee_amount) = book.match_bid_for_testing(
        option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );
    matched_base.burn_for_testing();
    remaining_budget.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 0);
    let (maker_side, quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == false, 1);
    assert!(quote_amount == FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE, 2);
    // Single fill, so the once-per-call aggregate taker fee equals what the
    // old per-fill computation would have charged -- see
    // match_bid_produces_expected_fill_and_fee_amounts.
    assert!(taker_fee_amount == 3, 3); // taker fee in Base

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun order_filled_taker_sell_records_maker_side_true() {
    // Taker is SELLING (fill_level_ask, crossing resting BIDS) -> the
    // resting maker order is a bid -> maker_side must be true.
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, FEE_TEST_TAKER_FEE_BPS);
    cap.clob_admin_set_maker_fee(&mut book, FEE_TEST_MAKER_FEE_BPS);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(FEE_TEST_PRICE * FEE_TEST_RESTING_SIZE);
    let bid = order::new<BTC, USDC>(
        order_id, other(), FEE_TEST_RESTING_SIZE, option::none(), option::some(escrow), FEE_TEST_MAKER_FEE_BPS,
    );
    book.insert_resting_order_for_testing(true, FEE_TEST_PRICE, bid, scenario.ctx());

    let payment = coin::mint_for_testing<BTC>(FEE_TEST_TAKER_SIZE, scenario.ctx());
    let (matched_quote, remaining_escrow, _remaining_size, _stopped, taker_fee_amount) = book.match_ask_for_testing(
        option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );
    matched_quote.burn_for_testing();
    remaining_escrow.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 0);
    let (maker_side, quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == true, 1);
    assert!(quote_amount == FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE, 2);
    // Single fill, so the once-per-call aggregate taker fee equals what the
    // old per-fill computation would have charged -- see
    // match_ask_produces_expected_fill_and_fee_amounts.
    assert!(taker_fee_amount == 113_050, 3); // taker fee in Quote

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun order_executed_fires_from_place_limit_order_bid_with_partial_rest() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    seed_resting_ask(&mut book, OE_PRICE, OE_REST_SIZE, scenario.ctx());

    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(OE_PRICE, OE_CROSS_SIZE), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, OE_CROSS_SIZE, 1_000_000_000, scenario.ctx());
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    let (t_order_id, _t_book_id, _t_side, _t_price) = ticket.ticket_fields_for_testing();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 0);
    let (_book_id, taker, taker_side, entry_point, limit_price, requested_size, unmatched_size, rested_size, rested_order_id, stopped_flag, _taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
    assert!(taker == admin(), 1);
    assert!(taker_side == true, 2);
    assert!(entry_point == 0, 3);
    assert!(limit_price == option::some(OE_PRICE), 4);
    assert!(requested_size == OE_CROSS_SIZE, 5);
    assert!(unmatched_size == OE_CROSS_SIZE - OE_REST_SIZE, 6);
    assert!(rested_size == OE_CROSS_SIZE - OE_REST_SIZE, 7);
    assert!(rested_order_id == option::some(t_order_id), 8);
    assert!(stopped_flag == stopped, 9);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun order_executed_fires_from_place_limit_order_ask_with_partial_rest() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    seed_resting_bid(&mut book, OE_PRICE, OE_REST_SIZE, scenario.ctx());

    let payment = coin::mint_for_testing<BTC>(OE_CROSS_SIZE, scenario.ctx());
    let ask_expected_quote_output = book.bid_escrow_amount(OE_PRICE, OE_CROSS_SIZE);
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, ask_expected_quote_output, 1_000_000_000, scenario.ctx());
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    let (t_order_id, _t_book_id, _t_side, _t_price) = ticket.ticket_fields_for_testing();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 0);
    let (_book_id, taker, taker_side, entry_point, limit_price, requested_size, unmatched_size, rested_size, rested_order_id, stopped_flag, _taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
    assert!(taker == admin(), 1);
    assert!(taker_side == false, 2);
    assert!(entry_point == 1, 3);
    assert!(limit_price == option::some(OE_PRICE), 4);
    assert!(requested_size == OE_CROSS_SIZE, 5);
    assert!(unmatched_size == OE_CROSS_SIZE - OE_REST_SIZE, 6);
    assert!(rested_size == OE_CROSS_SIZE - OE_REST_SIZE, 7);
    assert!(rested_order_id == option::some(t_order_id), 8);
    assert!(stopped_flag == stopped, 9);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun order_executed_fires_from_place_market_order_bid_fully_filled() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    seed_resting_ask(&mut book, OE_PRICE, 200, scenario.ctx());

    let budget = book.bid_escrow_amount(OE_PRICE, OE_SIZE);
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, stopped) = book.place_market_order_bid(payment, 1_000_000_000, 0, OE_SIZE, u64_max(), scenario.ctx(),
    );
    matched_base.burn_for_testing();
    leftover_payment.burn_for_testing();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 0);
    let (_book_id, taker, taker_side, entry_point, limit_price, requested_size, unmatched_size, rested_size, rested_order_id, stopped_flag, _taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
    assert!(taker == admin(), 1);
    assert!(taker_side == true, 2);
    assert!(entry_point == 2, 3);
    assert!(limit_price == option::none(), 4);
    assert!(requested_size == OE_SIZE, 5);
    assert!(unmatched_size == 0, 6);
    assert!(rested_size == 0, 7);
    assert!(rested_order_id == option::none(), 8);
    assert!(stopped_flag == stopped, 9);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun order_executed_fires_from_place_market_order_ask_fully_filled() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    seed_resting_bid(&mut book, OE_PRICE, 200, scenario.ctx());

    let payment = coin::mint_for_testing<BTC>(OE_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, stopped) = book.place_market_order_ask(payment, 1_000_000_000, 0, OE_SIZE, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 0);
    let (_book_id, taker, taker_side, entry_point, limit_price, requested_size, unmatched_size, rested_size, rested_order_id, stopped_flag, _taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
    assert!(taker == admin(), 1);
    assert!(taker_side == false, 2);
    assert!(entry_point == 3, 3);
    assert!(limit_price == option::none(), 4);
    assert!(requested_size == OE_SIZE, 5);
    assert!(unmatched_size == 0, 6);
    assert!(rested_size == 0, 7);
    assert!(rested_order_id == option::none(), 8);
    assert!(stopped_flag == stopped, 9);

    destroy_book_and_cap(book, cap);
    scenario.end();
}


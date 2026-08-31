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
    bid_payment_for_price, ask_expected_output_for_price, realistic_decimals_book,
};

// Fee-rate fixture shared with the `match_bid`/`match_ask` regression tests
// in `matching_fifo_tests.move`: the fee-bps constants below (7/3) match
// that file's, but the price/size constants do not (this file uses
// 47_500/4_000/3_400-shaped values; `matching_fifo_tests.move` uses
// 1_037/500/337-shaped values suited to its own price-scale fixtures).
// Duplicated here rather than promoted to `test_utils` -- these are
// fee-fixture constants incidental to two topic files, not general-purpose
// test infrastructure.
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
        bid_payment_for_price(&book, FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE), scenario.ctx(),
    );
    let (ticket_opt, matched_base, remaining_budget, _stopped) = book.place_limit_order_bid(
        payment, FEE_TEST_TAKER_SIZE, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );
    ticket_opt.destroy_none();
    matched_base.burn_for_testing();
    remaining_budget.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 0);
    let (maker_side, quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == false, 1);
    assert!(quote_amount == FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE, 2);
    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 4);
    let (_book_id, _taker, _taker_side, _entry_point, _limit_price, _requested_size, _unmatched_size, _rested_size, _rested_order_id, _stopped_flag, taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
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
    let expected_quote_output = ask_expected_output_for_price(&book, FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE);
    let (ticket_opt, leftover_base, matched_quote, _stopped) = book.place_limit_order_ask(
        payment, expected_quote_output, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );
    ticket_opt.destroy_none();
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 0);
    let (maker_side, quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == true, 1);
    assert!(quote_amount == FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE, 2);
    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 4);
    let (_book_id, _taker, _taker_side, _entry_point, _limit_price, _requested_size, _unmatched_size, _rested_size, _rested_order_id, _stopped_flag, taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
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
    let t_order_id = ticket.ticket_order_id();
    let _t_book_id = ticket.ticket_order_book_id();
    let _t_side = ticket.ticket_side();
    let _t_price = ticket.ticket_price();

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
    let t_order_id = ticket.ticket_order_id();
    let _t_book_id = ticket.ticket_order_book_id();
    let _t_side = ticket.ticket_side();
    let _t_price = ticket.ticket_price();

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

// === OrderFilled.quote_amount rounding-direction regression: all 4        ===
// === (maker_side, drains-vs-still-resting) combinations, each on a book   ===
// === where `price * size` is NOT an exact multiple of `price_scale`, so   ===
// === `ceil` and `floor` genuinely diverge (see `fill_level_bid`'s and     ===
// === `fill_level_ask`'s doc comments in `sources/tiny_clob.move` for the  ===
// === exact rules being pinned down here). Fixture mirrors                ===
// === `fee_redesign_tests.move`'s `REALISTIC_PRICE`/`realistic_decimals_book` ===
// === pattern (`price_scale == 100`, `price == 1_037`), but these 4 tests ===
// === are independent regressions targeting `OrderFilled.quote_amount`    ===
// === specifically, not the maker-fee-reserve true-up that file covers.   ===

const RD_PRICE: u64 = 1_037; // not a multiple of 100 -- forces genuine rounding.
// ceil(1_037 * 1 / 100) = ceil(10.37) = 11
// floor(1_037 * 1 / 100) = floor(10.37) = 10
// 11 != 10, so a fill of size 1 at this price genuinely distinguishes ceil
// from floor -- exactly the divergence a swapped rounding branch would flip.

// `place_limit_order_bid`/`place_limit_order_ask` derive their own price
// from the payment/expected-output the taker supplies (see their doc
// comments); for `realistic_decimals_book`'s `price_scale == 100` and a
// size-1 crossing order, that derived price is always an exact multiple of
// 100, so it can never round-trip back to the non-multiple-of-100 `RD_PRICE`
// itself. A crossing order only needs its own *limit* price to reach the
// resting order's price to fully cross it -- the fill still executes at the
// resting order's own price, `RD_PRICE` -- so these are the nearest
// round-tripping multiples of 100 on each side (mirrors
// `fee_redesign_tests.move`'s `TAKER_LIMIT_PRICE_FOR_SIZE_ONE`).
const BID_LIMIT_PRICE_FOR_SIZE_ONE: u64 = 1_100; // smallest multiple of 100 >= RD_PRICE.
const ASK_LIMIT_PRICE_FOR_SIZE_ONE: u64 = 1_000; // largest multiple of 100 <= RD_PRICE.

#[test]
fun order_filled_maker_ask_fully_drains_uses_floor_not_ceil() {
    // maker-ask, fully drains: quote_amount = max(floor(price*size/scale), 1).
    // Resting ask sized exactly 1: the taker's 1-unit fill fully drains it,
    // so this hits the maker-limited (floor) branch, not the taker-limited
    // (ceil) branch below.
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(1);
    let ask = order::new<BTC, USDC>(order_id, other(), 1, option::some(escrow), option::none(), 0);
    book.insert_resting_order_for_testing(false, RD_PRICE, ask, scenario.ctx());

    let payment = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, BID_LIMIT_PRICE_FOR_SIZE_ONE, 1), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _stopped) =
        book.place_limit_order_bid(payment, 1, u64_max(), scenario.ctx());
    ticket_opt.destroy_none(); // fully crossed: nothing rests for the taker
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 0);
    let (maker_side, quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == false, 1);
    // Expected: floor = 10, NOT ceil = 11. A swapped/broken branch that
    // ceiling-rounded a full-drain fill here would read 11 instead.
    assert!(quote_amount == 10, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun order_filled_maker_ask_still_resting_uses_ceil_not_floor() {
    // maker-ask, still resting: quote_amount = ceil(price*size/scale) exactly.
    // Resting ask sized 2, taker fill of size 1 leaves 1 unit still resting,
    // so this hits the taker-limited (ceil) branch, not the maker-limited
    // (floor) branch above.
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(2);
    let ask = order::new<BTC, USDC>(order_id, other(), 2, option::some(escrow), option::none(), 0);
    book.insert_resting_order_for_testing(false, RD_PRICE, ask, scenario.ctx());

    let payment = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, BID_LIMIT_PRICE_FOR_SIZE_ONE, 1), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _stopped) =
        book.place_limit_order_bid(payment, 1, u64_max(), scenario.ctx());
    ticket_opt.destroy_none(); // exact-budget taker limit order -- nothing rests for the taker either
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 0);
    let (maker_side, quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == false, 1);
    // Expected: ceil = 11, NOT floor = 10. A swapped/broken branch that
    // floor-rounded a still-resting fill here would read 10 instead.
    assert!(quote_amount == 11, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// maker-bid fixture shared by the two tests below: a resting bid of BASE
// size 2, escrowed with EXACTLY `bid_escrow_amount(RD_PRICE, 2) ==
// ceil(1_037 * 2 / 100) = ceil(20.74) = 21` Quote (`total_reserved == 21`),
// so its two 1-unit fills exercise the telescoping cumulative-ceiling scheme
// in `fill_level_ask` (see that function's doc comment) exactly the way a
// resting bid placed via `place_limit_order_bid` at this price/size would
// have been escrowed.
//
// Fill 1 (cumulative_after = 1, taker-limited / still resting afterward):
//   target_charge = ceil(21 * 1 / 2) = ceil(10.5) = 11
//   already_charged = 0
//   quote_cost = 11 - 0 = 11
// Fill 2 (cumulative_after = 2, maker-limited / fully drains):
//   target_charge = ceil(21 * 2 / 2) = 21 (== total_reserved, exact)
//   already_charged = 11
//   quote_cost = 21 - 11 = 10
//
// 11 != 10: this genuinely diverges from "always ceil each fill's own
// price*fill_qty/scale" (which would give ceil(1_037*1/100) = 11 for BOTH
// fills, over-collecting fill 2 by 1) and from "always floor" (which would
// give 10 for both, under-collecting fill 1 by 1) -- exactly the kind of
// swapped/broken branch this pair of tests is meant to catch.
const RD_BID_SIZE: u64 = 2;
const RD_BID_ESCROW: u64 = 21;

#[test]
fun order_filled_maker_bid_still_resting_bounded_by_telescoping_ceiling() {
    // maker-bid, still resting: quote_amount is the telescoping proportional-
    // ceiling charge for this fill, bounded by the order's remaining escrow.
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(RD_BID_ESCROW);
    let bid = order::new<BTC, USDC>(order_id, other(), RD_BID_SIZE, option::none(), option::some(escrow), 0);
    book.insert_resting_order_for_testing(true, RD_PRICE, bid, scenario.ctx());

    // Ask taker of size 1: the resting bid still has 1 unit of BASE capacity
    // left afterward, so this fill is taker-limited, not maker-limited.
    let payment = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let expected_quote_output = ask_expected_output_for_price(&book, ASK_LIMIT_PRICE_FOR_SIZE_ONE, 1);
    let (ticket_opt, leftover_base, matched_quote, _stopped) =
        book.place_limit_order_ask(payment, expected_quote_output, u64_max(), scenario.ctx());
    ticket_opt.destroy_none(); // exact-output taker limit order -- nothing rests for the taker either
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 0);
    let (maker_side, quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == true, 1);
    // Expected: 11 (see the fixture's worked-out derivation above), NOT the
    // fully-drain fill's value of 10.
    assert!(quote_amount == 11, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun order_filled_maker_bid_fully_drains_settles_remaining_escrow() {
    // maker-bid, fully drains: quote_amount equals exactly whatever Quote
    // remains of the order's original escrow reservation -- here that is
    // `total_reserved(21) - already_charged(11) == 10`, NOT a fresh
    // `ceil(price*fill_qty/scale) == 11` recomputation.
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(RD_BID_ESCROW);
    let bid = order::new<BTC, USDC>(order_id, other(), RD_BID_SIZE, option::none(), option::some(escrow), 0);
    book.insert_resting_order_for_testing(true, RD_PRICE, bid, scenario.ctx());

    // Fill 1: 1 unit, still resting afterward (quote_cost == 11 -- pinned by
    // the sibling test above).
    let payment1 = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let expected_quote_output1 = ask_expected_output_for_price(&book, ASK_LIMIT_PRICE_FOR_SIZE_ONE, 1);
    let (ticket_opt1, leftover_base1, matched_quote1, _stopped1) =
        book.place_limit_order_ask(payment1, expected_quote_output1, u64_max(), scenario.ctx());
    ticket_opt1.destroy_none();
    leftover_base1.burn_for_testing();
    matched_quote1.burn_for_testing();

    // Fill 2: 1 more unit -- fully drains the resting bid's remaining BASE
    // capacity, hitting the maker-limited settlement branch.
    let payment2 = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let expected_quote_output2 = ask_expected_output_for_price(&book, ASK_LIMIT_PRICE_FOR_SIZE_ONE, 1);
    let (ticket_opt2, leftover_base2, matched_quote2, _stopped2) =
        book.place_limit_order_ask(payment2, expected_quote_output2, u64_max(), scenario.ctx());
    ticket_opt2.destroy_none();
    leftover_base2.burn_for_testing();
    matched_quote2.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 2, 0);
    let (maker_side, quote_amount) = fills[1].order_filled_side_and_quote_fields_for_testing();
    assert!(maker_side == true, 1);
    // Expected: 10 (whatever escrow remains), NOT a fresh ceil-recompute of 11.
    assert!(quote_amount == 10, 2);

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


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
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks, u64_max,
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
    let ask_expected_quote_output = book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let (ask_ticket_opt, ask_matched_base, ask_leftover_base, ask_stop) =
        book.place_limit_order_ask(ask_payment, ask_expected_quote_output, 10, scenario.ctx());
    assert!(ask_matched_base.burn_for_testing() == 0, 0);
    assert!(ask_leftover_base.burn_for_testing() == 0, 1);
    assert!(!ask_stop, 2);
    let ask_ticket = ask_ticket_opt.destroy_some();

    scenario.next_tx(taker());
    let bid_payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, bid_stop) =
        book.place_limit_order_bid(bid_payment, PLACEMENT_SIZE, 10, scenario.ctx());
    assert!(bid_matched_base.burn_for_testing() == PLACEMENT_SIZE, 3);
    assert!(bid_leftover_quote.burn_for_testing() == 0, 4);
    assert!(!bid_stop, 5);
    assert!(bid_ticket_opt.is_none(), 6);
    bid_ticket_opt.destroy_none();

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun place_limit_order_zero_price_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    // `payment` of 1 against `PLACEMENT_SIZE` derives `price ==
    // floor(1 * 1 / PLACEMENT_SIZE) == 0` -- the same `EZeroPrice` abort as
    // passing `price == 0` directly used to trigger, but via genuine
    // floor-rounding of a nonzero payment (not a trivially-zero payment).
    // This is meaningfully distinct from `place_limit_order_bid_zero_price_
    // aborts` below, which drives the derivation with `payment == 0`
    // directly (via `rest_bid(book, 0, ...)`, since `bid_escrow_amount(0,
    // size) == 0`): that only proves `0` maps to `0`, not that the guard is
    // on the *derived* price rather than on `payment == 0` specifically.
    // This test proves the latter: even a nonzero payment (1) that merely
    // rounds down to a zero derived price is caught the same way.
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket_opt, mb, ml, _) = book.place_limit_order_bid(payment, PLACEMENT_SIZE, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 12, location = tiny_clob)] // ESizeBelowMinSize
fun place_limit_order_size_validation_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    // `expected_base_output == min_size() - 1` is genuinely below `new_book`'s
    // `min_size` (100), so `validate_size` is the only check this fixture can
    // possibly fail. `payment` is chosen as `100 * expected_base_output` so
    // the derived `price == floor(payment * price_scale / expected_base_output)
    // == 100` (this book's `price_scale == 1`) is comfortably nonzero and well
    // within the book's declared `[1, 10^19]` range -- unlike the old `payment
    // == 1` fixture (which derived `price == 0`), `EZeroPrice` cannot also
    // fire here, so an `abort_code`-asserted failure unambiguously proves
    // `ESizeBelowMinSize` is what aborts (deleting the `validate_size` call
    // in `place_limit_order_bid` would make this test fail, not stay green).
    let size = min_size() - 1;
    let payment = coin::mint_for_testing<USDC>(size * 100, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_bid(payment, size, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 12, location = tiny_clob)] // ESizeBelowMinSize
fun place_limit_order_ask_size_validation_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    // Mirrors `place_limit_order_size_validation_aborts` above (the bid-side
    // test), for the ask side. `size == payment.value() == min_size() - 1` is
    // genuinely below `new_book`'s `min_size` (100), so `validate_size` is
    // the only check this fixture can possibly fail. `expected_quote_output`
    // is chosen as `100 * size` so the derived `price ==
    // ceil(expected_quote_output * price_scale / size) == 100` (this book's
    // `price_scale == 1`) is comfortably nonzero and well within the book's
    // declared `[1, 10^19]` range -- so `EZeroPrice` cannot also fire here,
    // and an `abort_code`-asserted failure unambiguously proves
    // `ESizeBelowMinSize` is what aborts (deleting the `validate_size` call
    // in `place_limit_order_ask` would make this test fail, not stay green).
    let size = min_size() - 1;
    let payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let expected_quote_output = size * 100;
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_ask(payment, expected_quote_output, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// =====================================================================
// A paused book must reject every placement/market entry point. Each of the
// 4 current entry points (`swap_bid`/`swap_ask` no longer exist) gets its own
// test below: `assert_book_version`/`is_paused` runs first in every one of
// them, before any size/price/ordering validation (verified by reading
// `sources/tiny_clob.move`), so a fixture that is otherwise fully valid
// (real payment, size >= min_size, a comfortably-in-range derived price)
// isolates `EBookPaused` as the only possible failure reason.
// =====================================================================

#[test]
#[expected_failure(abort_code = 15, location = tiny_clob)] // EBookPaused
fun place_limit_order_bid_aborts_when_paused() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_pause_book(&mut book);
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_bid(payment, PLACEMENT_SIZE, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 15, location = tiny_clob)] // EBookPaused
fun place_limit_order_ask_aborts_when_paused() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_pause_book(&mut book);
    let payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let expected_quote_output = book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_ask(payment, expected_quote_output, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 15, location = tiny_clob)] // EBookPaused
fun place_market_order_bid_aborts_when_paused() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_pause_book(&mut book);
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (mb, ml, _) =
        book.place_market_order_bid(payment, 10, 0, PLACEMENT_SIZE, u64_max(), scenario.ctx());
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 15, location = tiny_clob)] // EBookPaused
fun place_market_order_ask_aborts_when_paused() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_pause_book(&mut book);
    let payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (mb, ml, _) =
        book.place_market_order_ask(payment, 10, 0, PLACEMENT_SIZE, scenario.ctx());
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
    let budget = book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, _) = book.place_market_order_bid(bid_payment, 10, 0, PLACEMENT_SIZE, u64_max(), scenario.ctx(),
    );
    assert!(matched_base.burn_for_testing() == PLACEMENT_SIZE, 0);
    assert!(leftover.burn_for_testing() == 0, 1);

    scenario.next_tx(taker());
    let bid_ticket2 = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());
    let ask_payment2 = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, _) =
        book.place_market_order_ask(ask_payment2, 10, 0, PLACEMENT_SIZE, scenario.ctx());
    assert!(matched_quote.burn_for_testing() == book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 3);
    assert!(leftover_base.burn_for_testing() == 0, 4);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 17, location = tiny_clob)] // ESlippageExceeded
fun place_market_order_bid_slippage_bound_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    // `min_base_out == max_base_out == PLACEMENT_SIZE + 1` satisfies the
    // `min_base_out <= max_base_out` ordering assert on its own, so the only
    // available liquidity (`PLACEMENT_SIZE`) genuinely falls short of the
    // slippage floor -- an actual `ESlippageExceeded`, not the unrelated
    // `EMinExceedsMaxBaseOut` ordering check.
    let (matched_base, leftover, _) = book.place_market_order_bid(
        bid_payment, 10, PLACEMENT_SIZE + 1, PLACEMENT_SIZE + 1, u64_max(), scenario.ctx(),
    );
    matched_base.burn_for_testing();
    leftover.burn_for_testing();
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 3: `place_market_order_bid`/`ask` surface the max_fills
// truncation signal ===

#[test]
fun place_market_order_bid_returns_true_when_truncated_by_max_fills() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    // max_fills = 0 against a crossing resting ask: nothing can be matched,
    // and the truncation signal must now come back as `true`.
    let (matched_base, leftover, stopped) = book.place_market_order_bid(bid_payment, 0, 0, PLACEMENT_SIZE, u64_max(), scenario.ctx(),
    );
    assert!(matched_base.burn_for_testing() == 0, 0);
    assert!(leftover.burn_for_testing() == budget, 1);
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
    let budget = book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, stopped) = book.place_market_order_bid(bid_payment, 10, 0, PLACEMENT_SIZE, u64_max(), scenario.ctx(),
    );
    assert!(matched_base.burn_for_testing() == PLACEMENT_SIZE, 0);
    assert!(leftover.burn_for_testing() == 0, 1);
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
    let (leftover_base, matched_quote, stopped) = book.place_market_order_ask(ask_payment, 0, 0, PLACEMENT_SIZE, scenario.ctx(),
    );
    assert!(leftover_base.burn_for_testing() == PLACEMENT_SIZE, 0);
    assert!(matched_quote.burn_for_testing() == 0, 1);
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
    let (leftover_base, matched_quote, stopped) = book.place_market_order_ask(ask_payment, 10, 0, PLACEMENT_SIZE, scenario.ctx(),
    );
    assert!(leftover_base.burn_for_testing() == 0, 0);
    assert!(matched_quote.burn_for_testing() == book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 1);
    assert!(!stopped, 2);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_order_never_blocks_on_pause() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid, pause the book, then cancel — must succeed despite pause.
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    cap.clob_admin_pause_book(&mut book);
    let (cancel_base, cancel_quote) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cancel_base.burn_for_testing() == 0, 0);
    assert!(cancel_quote.burn_for_testing() == book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// `pause_never_blocks_cancel_claim_update_or_admin_recovery_paths` (in
// `cancellation_and_proceeds_tests.move`) already exercises `cancel_order`
// and `claim_proceeds` end-to-end against a merely-paused book. A retiring
// book is a strictly *stronger* condition than a paused one --
// `clob_admin_retire` sets both `paused = true` and `retiring = true`, and
// there is no way to be retiring without also being paused (see
// `sources/tiny_clob.move`'s doc comment on the `retiring` field). Reading
// both `cancel_order` and `claim_proceeds`'s bodies confirms neither checks
// `is_paused` NOR `retiring` at all -- the only guard either runs is
// `assert_book_version` -- so a retiring book exercises the *exact same*
// code path in these two functions as a merely-paused one. This test still
// verifies that explicitly, end-to-end, against a genuinely retiring book
// with real resting orders (not a synthetic zero-value ticket that can't
// fail regardless of correctness): one order is cancelled for a real,
// nonzero escrow refund, and a second order's real, nonzero pooled proceeds
// (from an actual prior partial fill) are claimed successfully.
#[test]
fun retiring_never_blocks_cancel_order_or_claim_proceeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // `proceeds_ticket` rests first (and thus is first in FIFO priority at
    // this price), so the market ask below fills it -- not `cancel_ticket`,
    // which is only rested afterward.
    let proceeds_size = PLACEMENT_SIZE * 2;
    let proceeds_fill_size = PLACEMENT_SIZE;
    let proceeds_ticket = rest_bid(&mut book, PLACEMENT_PRICE, proceeds_size, 10, scenario.ctx());
    let proceeds_order_id = proceeds_ticket.ticket_order_id();

    // Partially fill `proceeds_ticket` while the book is still live, so
    // there is a genuine, nonzero pooled proceeds balance to claim later.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(proceeds_fill_size, scenario.ctx());
    let (leftover_base, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 10, 0, proceeds_fill_size, scenario.ctx());
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(proceeds_order_id), 0);

    scenario.next_tx(admin());
    let cancel_escrow = book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let cancel_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    // Retire the book: this is genuinely stronger than merely pausing it.
    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);
    assert!(book.is_paused(), 1);
    assert!(book.is_book_retiring(), 2);

    // `cancel_order` on a real resting order still succeeds while retiring,
    // refunding real, nonzero escrow.
    let (cancel_base, cancel_quote) = book.cancel_order(cancel_ticket, scenario.ctx());
    assert!(cancel_base.burn_for_testing() == 0, 3);
    assert!(cancel_quote.burn_for_testing() == cancel_escrow, 4);

    // `claim_proceeds` on a real, nonzero pooled-proceeds entry still
    // succeeds while retiring, and returns the still-live ticket (the order
    // has `PLACEMENT_SIZE` left resting out of the original `proceeds_size`).
    let (claim_base, claim_quote, returned_ticket_opt) =
        book.claim_proceeds(proceeds_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == proceeds_fill_size, 5);
    assert!(claim_quote.burn_for_testing() == 0, 6);
    assert!(!book.proceeds_contains_for_testing(proceeds_order_id), 7);
    assert!(returned_ticket_opt.is_some(), 8);
    let returned_ticket = returned_ticket_opt.destroy_some();

    // The book is still retiring (and paused) throughout — confirms neither
    // path above accidentally reversed either flag.
    assert!(book.is_paused(), 9);
    assert!(book.is_book_retiring(), 10);

    unit_test::destroy(returned_ticket);
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
    let bid_payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, _) =
        book.place_limit_order_bid(bid_payment, PLACEMENT_SIZE, 10, scenario.ctx());
    bid_ticket_opt.destroy_none();
    bid_matched_base.burn_for_testing();
    bid_leftover_quote.burn_for_testing();

    scenario.next_tx(admin());
    // ask_ticket's order was fully filled by the crossing bid above, so it
    // is no longer resting — claim_proceeds auto-destroys the ticket and
    // hands back option::none().
    let (claim_base, claim_quote, returned_ticket_opt) =
        book.claim_proceeds(ask_ticket, scenario.ctx());
    let claimed = event::events_by_type<ProceedsClaimed>();
    assert!(claimed.length() == 1, 0);
    let (_, _, claimant, _base_amt, quote_amt) = claimed[0].proceeds_claimed_fields_for_testing();
    assert!(claimant == admin(), 1);
    assert!(quote_amt == book.bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 2);
    claim_base.burn_for_testing();
    claim_quote.burn_for_testing();
    assert!(returned_ticket_opt.is_none(), 3);
    returned_ticket_opt.destroy_none();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_bid_fully_fills_returns_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(OPT_PRICE, 100), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 100, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == 100, 1);
    assert!(leftover_quote.burn_for_testing() == 0, 2);
    assert!(ticket_opt.is_none(), 3);
    ticket_opt.destroy_none();

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
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(OPT_PRICE, 200), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 200, 1, scenario.ctx());
    // Truncated after exactly one fill: 100 base matched, 100 remains
    // unmatched, but `should_rest` is false because the sweep stopped on
    // max_fills rather than genuinely running out of counterparty depth.
    assert!(stopped, 0);
    assert!(matched_base.burn_for_testing() == 100, 1);
    assert!(leftover_quote.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    ticket_opt.destroy_none();

    unit_test::destroy(ask_a);
    unit_test::destroy(ask_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// PIN DOWN: `fill_level_bid`'s inner loop now checks `level_is_empty()`
/// BEFORE checking `fills_consumed == max_fills` (see
/// `sources/tiny_clob.move`, `fill_level_bid`). This fixes a prior ordering
/// bug where the `max_fills` check ran first: on the fill that exactly
/// drained the last resting order the level had, `fills_consumed` was
/// incremented to equal `max_fills`, and the loop's `max_fills` check fired
/// on the *next* iteration before the also-true `level_is_empty()` check
/// ever got a chance to run. That produced a false-positive
/// `stopped_on_max_fills_while_crossing = true` whenever `max_fills` exactly
/// equalled the number of resting orders present, even though the level was
/// completely, naturally drained -- there was no counterparty depth left to
/// truncate against.
///
/// With the fix, `level_is_empty()` is checked first, so a fill that exactly
/// drains the level's last order correctly reports `stopped = false`: the
/// sweep only ran out of counterparty depth, it was never capped short of
/// it. This has a real, user-visible consequence on the bid side:
/// `place_limit_order_bid`'s `should_rest` is
/// `actual_resting_size > 0 && !stopped_on_max_fills_while_crossing`, so a
/// taker whose own requested size exceeds what those exactly-`max_fills`
/// resting orders could supply now correctly gets `should_rest = true` --
/// its own leftover legitimately rests, mirroring the "one more than
/// needed" companion test right below. This test pins down the new, correct
/// behavior at that boundary so a future accidental change to the check
/// ordering becomes visible.
#[test]
fun place_limit_order_bid_max_fills_exact_match_does_not_falsely_report_stopped() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    // Exactly 3 resting asks at one price level.
    let ask_a = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let ask_b = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let ask_c = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    // Taker wants 400: strictly more than the 300 those 3 orders can supply,
    // so there is a genuine, nonzero leftover from the taker's own
    // perspective. max_fills == 3, exactly the number of resting orders.
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(OPT_PRICE, 400), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 400, 3, scenario.ctx());

    // Corrected behavior at the exact-match boundary: `stopped` comes back
    // `false` -- all 300 base of genuine counterparty depth was consumed and
    // nothing was actually left un-swept in the book, so this genuinely
    // wasn't a max_fills truncation.
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == 300, 1);
    assert!(leftover_quote.burn_for_testing() == 0, 2);
    // Consequence: the taker's own 100 leftover legitimately rests as a real
    // order.
    assert!(ticket_opt.is_some(), 3);
    let ticket = ticket_opt.destroy_some();
    // The level was genuinely, fully drained.
    assert!(book.ask_base_escrow_at_price(OPT_PRICE) == 0, 4);

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    let (_, _, _, _, _, _, _, unmatched_size, rested_size, _, event_stopped, _) =
        executed[0].order_executed_fields_for_testing();
    assert!(!event_stopped, 5);
    assert!(unmatched_size == 100, 6);
    assert!(rested_size == 100, 7);

    // The resting order's escrow is exactly the leftover 100's worth of
    // quote, and can be cancelled cleanly.
    let (cb, cq) = book.cancel_order(ticket, scenario.ctx());
    assert!(cb.burn_for_testing() == 0, 8);
    assert!(cq.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 100), 9);

    unit_test::destroy(ask_a);
    unit_test::destroy(ask_b);
    unit_test::destroy(ask_c);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Companion to the exact-match case above: with `max_fills` set to ONE MORE
/// than the number of resting orders needed (4, for 3 orders), the sweep
/// naturally ends via `level_is_empty()` on the loop's next check -- before
/// `fills_consumed` (which only reaches 3) could ever equal `max_fills` (4).
/// So `stopped_on_max_fills_while_crossing` correctly comes back `false`
/// here too, and the taker's own leftover legitimately rests -- the same
/// corrected outcome as the exact-match boundary pinned down above, just
/// reached without ever coming close to the `max_fills` cap.
#[test]
fun place_limit_order_bid_max_fills_one_more_than_needed_does_not_report_stopped() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_a = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let ask_b = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let ask_c = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(OPT_PRICE, 400), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 400, 4, scenario.ctx());

    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == 300, 1);
    assert!(leftover_quote.burn_for_testing() == 0, 2);
    // The taker's own 100 leftover genuinely rests this time.
    assert!(ticket_opt.is_some(), 3);
    let ticket = ticket_opt.destroy_some();
    let (cb, cq) = book.cancel_order(ticket, scenario.ctx());
    assert!(cb.burn_for_testing() == 0, 4);
    assert!(cq.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 100), 5);
    // The level is equally, fully drained in this case too.
    assert!(book.ask_base_escrow_at_price(OPT_PRICE) == 0, 6);

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    let (_, _, _, _, _, _, _, unmatched_size, rested_size, _, event_stopped, _) =
        executed[0].order_executed_fields_for_testing();
    assert!(!event_stopped, 7);
    assert!(unmatched_size == 100, 8);
    assert!(rested_size == 100, 9);

    unit_test::destroy(ask_a);
    unit_test::destroy(ask_b);
    unit_test::destroy(ask_c);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_bid_partial_fill_rests_returns_some_and_ticket_is_usable() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(OPT_PRICE, 300), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 300, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == 100, 1);
    assert!(leftover_quote.burn_for_testing() == 0, 2);
    assert!(ticket_opt.is_some(), 3);
    let ticket = ticket_opt.destroy_some();

    // The returned ticket genuinely rests for the unmatched 200 remainder:
    // cancelling it must hand back exactly that escrow.
    let (cb, cq) = book.cancel_order(ticket, scenario.ctx());
    assert!(cb.burn_for_testing() == 0, 4);
    assert!(cq.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 200), 5);

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
    let expected_quote_output = book.bid_escrow_amount(OPT_PRICE, 100);
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1);
    assert!(matched_quote.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    ticket_opt.destroy_none();

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
    let expected_quote_output_200 = book.bid_escrow_amount(OPT_PRICE, 200);
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output_200, 1, scenario.ctx());
    assert!(stopped, 0);
    assert!(leftover_base.burn_for_testing() == 100, 1);
    assert!(matched_quote.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    ticket_opt.destroy_none();

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
    let expected_quote_output_300 = book.bid_escrow_amount(OPT_PRICE, 300);
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output_300, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1);
    assert!(matched_quote.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_some(), 3);
    let ticket = ticket_opt.destroy_some();

    // Nothing has matched against the resting 200-base remainder yet, so
    // claim_proceeds pays nothing but must still hand the ticket back
    // (it genuinely rests), proving it's a fully valid, reusable ticket.
    let (cb, cq, ticket_opt2) = book.claim_proceeds(ticket, scenario.ctx());
    assert!(cb.burn_for_testing() == 0, 4);
    assert!(cq.burn_for_testing() == 0, 5);
    assert!(ticket_opt2.is_some(), 6);
    let ticket2 = ticket_opt2.destroy_some();

    let (rb, rq) = book.cancel_order(ticket2, scenario.ctx());
    assert!(rb.burn_for_testing() == 200, 7);
    assert!(rq.burn_for_testing() == 0, 8);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Ask-side mirror of
/// `place_limit_order_bid_max_fills_exact_match_does_not_falsely_report_stopped`:
/// with exactly 3 resting bids of size 100 each and `max_fills` set to
/// exactly 3, the fill that drains the last resting bid also brings
/// `fills_consumed` to `max_fills`. Since `fill_level_ask` now checks
/// `level_is_empty()` before `fills_consumed == max_fills`, this correctly
/// reports `stopped = false` -- the sweep ran out of genuine counterparty
/// depth, it was never capped short of it -- and the taker's own 100-base
/// leftover legitimately rests as a new ask.
#[test]
fun place_limit_order_ask_max_fills_exact_match_does_not_falsely_report_stopped() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    // Exactly 3 resting bids at one price level.
    let bid_a = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let bid_b = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let bid_c = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    // Taker wants to sell 400 base: strictly more than the 300 those 3
    // resting bids can absorb. max_fills == 3, exactly the number of
    // resting orders.
    let payment = coin::mint_for_testing<BTC>(400, scenario.ctx());
    let expected_quote_output_300 = book.bid_escrow_amount(OPT_PRICE, 300);
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output_300, 3, scenario.ctx());

    // Corrected behavior at the exact-match boundary: `stopped` comes back
    // `false` -- all 300 base of genuine counterparty depth was consumed and
    // nothing was left un-swept in the book.
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1);
    assert!(matched_quote.burn_for_testing() == book.bid_escrow_amount(OPT_PRICE, 300), 2);
    // The taker's own 100-base leftover legitimately rests as a new ask.
    assert!(ticket_opt.is_some(), 3);
    let ticket = ticket_opt.destroy_some();
    // The bid side was genuinely, fully drained.
    assert!(book.bid_quote_escrow_at_price(OPT_PRICE) == 0, 4);

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    let (_, _, _, _, _, _, _, unmatched_size, rested_size, _, event_stopped, _) =
        executed[0].order_executed_fields_for_testing();
    assert!(!event_stopped, 5);
    assert!(unmatched_size == 100, 6);
    assert!(rested_size == 100, 7);

    // The resting order's escrow is exactly the leftover 100 base, and can
    // be cancelled cleanly.
    let (cb, cq) = book.cancel_order(ticket, scenario.ctx());
    assert!(cb.burn_for_testing() == 100, 8);
    assert!(cq.burn_for_testing() == 0, 9);

    unit_test::destroy(bid_a);
    unit_test::destroy(bid_b);
    unit_test::destroy(bid_c);
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
    cap.clob_admin_set_taker_fee(&mut book, 10); // 10 bps

    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(OPT_PRICE, 100), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 100, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    // Fee-net matched amount: ceil(100 * 10 / 10_000) = 1 taker fee -> 99.
    // The naive `size - coin::value(&matched_base)` derivation gives
    // 100 - 99 = 1 (nonzero), which would incorrectly imply the order is
    // still resting with 1 unit left. It is not: the order fully filled.
    let matched_value = matched_base.burn_for_testing();
    assert!(matched_value == 99, 1);
    assert!(matched_value != 100, 2); // sanity: the naive derivation would be off
    assert!(leftover_quote.burn_for_testing() == 0, 3);
    assert!(ticket_opt.is_none(), 4);
    ticket_opt.destroy_none();

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

// =====================================================================
// `place_market_order_ask` deliberately has NO `min_size` check at all
// (unlike the limit-order path above) -- neither market side ever rests an
// order, so neither can ever create sub-`min_size` dust on the book, and
// `validate_size`'s entire purpose is bounding what can rest. This test
// demonstrates that absence directly, rather than merely not testing for
// it: selling a sub-`min_size` amount of Base via `place_market_order_ask`
// must succeed cleanly, mirroring `place_market_order_bid_below_min_size_
// succeeds` below.
// =====================================================================

#[test]
fun place_market_order_ask_below_min_size_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    // Resting bid depth (100) comfortably covers the sub-min_size sell below.
    let bid_ticket = rest_bid(&mut book, price, default_size(), 20, scenario.ctx());

    scenario.next_tx(taker());
    // Strictly below `min_size` (100) but > 0 -- if `place_market_order_ask`
    // had a `validate_size`/`min_size` guard (it deliberately does not),
    // this fixture would be exactly the case that guard would reject.
    let max_base_in = min_size() - 1;
    let payment = coin::mint_for_testing<BTC>(max_base_in, scenario.ctx());
    let (leftover_base, matched_quote, stopped) =
        book.place_market_order_ask(payment, 10, 0, max_base_in, scenario.ctx());
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1);
    unit_test::destroy(matched_quote);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// =====================================================================
// `place_market_order_bid` deliberately has NO `min_size` check at all
// (unlike the limit-order and market-ask paths above) -- see its doc comment
// in `sources/tiny_clob.move`: a market bid never rests an order, so it can
// never create sub-`min_size` dust on the book, and `validate_size`'s entire
// purpose is bounding what can rest. This test demonstrates that absence
// directly, rather than merely not testing for it: buying a sub-`min_size`
// amount of Base via `place_market_order_bid` must succeed cleanly.
// =====================================================================

#[test]
fun place_market_order_bid_below_min_size_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    // Resting ask depth (100) comfortably covers the sub-min_size buy below.
    let ask_ticket = rest_ask(&mut book, price, default_size(), 20, scenario.ctx());

    scenario.next_tx(taker());
    // Strictly below `min_size` (100) but > 0 -- if `place_market_order_bid`
    // had a `validate_size`/`min_size` guard (it deliberately does not),
    // this fixture would be exactly the case that guard would reject.
    let buy_size = min_size() - 1;
    let budget = book.bid_escrow_amount(price, buy_size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_quote, stopped) =
        book.place_market_order_bid(bid_payment, 20, 0, buy_size, u64_max(), scenario.ctx());
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == buy_size, 1);
    assert!(leftover_quote.burn_for_testing() == 0, 2);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

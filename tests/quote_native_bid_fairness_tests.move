/// New tests for the Quote-denominated bid-side `remaining_size` redesign
/// and its cumulative-proportional-ceiling escrow-charging scheme in
/// `fill_level_ask` (see `order.move`'s `remaining_size`/`original_size`
/// doc comments and the matching comment block in `tiny_clob.move`'s
/// `fill_level_ask`).
///
/// The core scenario here (a size-100 resting bid drained via 4 separate
/// incoming asks of size 7/13/29/51, at `price=5`/`price_scale=18`,
/// `total_reserved=28`) is the exact scenario used to originally identify
/// the "drain what's left" fairness problem in production
/// (`price_rounding_fragmentation_tests.move` documents the sibling
/// `fill_level_bid` fix for the SAME price_scale/price via `shortfall_book`,
/// but that file's scenario is a bid-as-TAKER sweep, not this file's
/// bid-as-MAKER drain).
///
/// OLD production (floor for taker-limited fills, "drain what's left" for
/// the final/maker-limited fill) would have charged this exact sequence:
///   fill1 (qty 7):  floor(5*7/18)  = floor(35/18)  = 1
///   fill2 (qty 13): floor(5*13/18) = floor(65/18)  = 3
///   fill3 (qty 29): floor(5*29/18) = floor(145/18) = 8
///   fill4 (qty 51): drain whatever's left = 28 - (1+3+8) = 16
/// (isolated-fair ceil for fill4 alone would be ceil(5*51/18)=ceil(255/18)=15
/// -- the old scheme dumps 1 full unit of the first three fills' accumulated
/// floor-rounding slack onto whichever fill happens to conclude the order.)
///
/// NEW (this file, cumulative-proportional-ceiling): each fill's charge is
/// `ceil(total_reserved * cumulative_filled / original_size) - already_charged`:
///   fill1: ceil(28*7/100)=ceil(1.96)=2,   delta = 2 - 0  = 2
///   fill2: ceil(28*20/100)=ceil(5.6)=6,   delta = 6 - 2  = 4
///   fill3: ceil(28*49/100)=ceil(13.72)=14,delta = 14 - 6 = 8
///   fill4: ceil(28*100/100)=28,           delta = 28 - 14 = 14
/// Both schemes conserve exactly (sum to 28, the order's full
/// `total_reserved`) and both necessarily agree that the LAST fill is
/// "whatever's left" (that's forced by conservation, not a formula choice —
/// see the comment in `fill_level_ask`). The difference is entirely in the
/// three earlier, taker-limited fills: 2/4/8 (isolated-fair: 2/4/9) versus
/// the old floor's 1/3/8 (isolated-fair: 2/4/9) -- the new scheme's total
/// absolute deviation from each fill's own isolated-fair ceil value is
/// smaller (0+0+1+1=2 vs 1+1+1+1=4 for the old scheme), and unlike the old
/// scheme, no single fill is ever OVER its own isolated-fair value -- the
/// rounding "loss" is spread more evenly instead of systematically dumped
/// onto whichever fill happens to conclude the order.
#[test_only]
module tiny_clob::quote_native_bid_fairness_tests;

use std::unit_test;
use sui::coin;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self};
use tiny_clob::test_markers::{BTC, USDC};
use tiny_clob::test_utils::{admin, maker_a, taker, shortfall_book, shortfall_price, new_book, default_price, default_size, rest_ask, rest_bid, u64_max};

const MAX_FILLS: u64 = 20;

/// Exercises the full scenario end-to-end through the real placement entry
/// points (`place_limit_order_bid`/`place_limit_order_ask`), checking every
/// fill's actual Quote payout against the hand-derived cumulative-ceiling
/// values above, and confirming exact conservation (100 Base delivered, 28
/// Quote drained to zero, order concludes on the 4th fill).
#[test]
fun cumulative_ceiling_scheme_delivers_full_size_and_conserves_exactly() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);
    let price = shortfall_price(); // 5, price_scale == 18 (asserted in shortfall_book)

    // Rest a size-100 bid at `price`. `bid_escrow_amount(price, 100) ==
    // ceil(5*100/18) == ceil(27.78) == 28` -- the `total_reserved` this
    // whole scenario is about draining exactly.
    scenario.next_tx(maker_a());
    let escrow_amount = book.bid_escrow_amount(price, 100);
    assert!(escrow_amount == 28, 100);
    let bid_payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, bid_stopped) =
        book.place_limit_order_bid(price, 100, bid_payment, MAX_FILLS, scenario.ctx());
    assert!(!bid_stopped, 101);
    assert!(bid_matched_base.burn_for_testing() == 0, 102);
    assert!(bid_leftover_quote.burn_for_testing() == 0, 103);
    let bid_ticket = bid_ticket_opt.destroy_some();

    // `resting_order_escrow`/`depth_at_price` must both report the FULL
    // Quote reservation up front -- Quote-denominated `remaining_size` for a
    // bid means these now report 28 (Quote), not 100 (Base).
    assert!(book.depth_at_price(tiny_clob::bid_for_testing(), price) == 28, 104);
    assert!(book.bid_quote_escrow_at_price(price) == 28, 105);

    // Fill 1: incoming ask sells 7 Base. Expect quote_cost == 2.
    scenario.next_tx(taker());
    let ask1_payment = coin::mint_for_testing<BTC>(7, scenario.ctx());
    let (ask1_ticket_opt, ask1_leftover_base, ask1_matched_quote, ask1_stopped) =
        book.place_limit_order_ask(price, 7, ask1_payment, MAX_FILLS, scenario.ctx());
    assert!(!ask1_stopped, 1);
    assert!(ask1_leftover_base.burn_for_testing() == 0, 2);
    assert!(ask1_matched_quote.burn_for_testing() == 2, 3);
    ask1_ticket_opt.destroy_none();
    assert!(book.bid_quote_escrow_at_price(price) == 26, 4); // 28 - 2

    // Fill 2: sells 13 Base. Expect quote_cost == 4 (cumulative charge 6).
    scenario.next_tx(taker());
    let ask2_payment = coin::mint_for_testing<BTC>(13, scenario.ctx());
    let (ask2_ticket_opt, ask2_leftover_base, ask2_matched_quote, ask2_stopped) =
        book.place_limit_order_ask(price, 13, ask2_payment, MAX_FILLS, scenario.ctx());
    assert!(!ask2_stopped, 5);
    assert!(ask2_leftover_base.burn_for_testing() == 0, 6);
    assert!(ask2_matched_quote.burn_for_testing() == 4, 7);
    ask2_ticket_opt.destroy_none();
    assert!(book.bid_quote_escrow_at_price(price) == 22, 8); // 28 - 6

    // Fill 3: sells 29 Base. Expect quote_cost == 8 (cumulative charge 14).
    scenario.next_tx(taker());
    let ask3_payment = coin::mint_for_testing<BTC>(29, scenario.ctx());
    let (ask3_ticket_opt, ask3_leftover_base, ask3_matched_quote, ask3_stopped) =
        book.place_limit_order_ask(price, 29, ask3_payment, MAX_FILLS, scenario.ctx());
    assert!(!ask3_stopped, 9);
    assert!(ask3_leftover_base.burn_for_testing() == 0, 10);
    assert!(ask3_matched_quote.burn_for_testing() == 8, 11);
    ask3_ticket_opt.destroy_none();
    assert!(book.bid_quote_escrow_at_price(price) == 14, 12); // 28 - 14

    // Fill 4: sells 51 Base, exactly the resting bid's remaining Base
    // capacity (7+13+29+51 == 100). Expect quote_cost == 14 (drains the
    // remaining escrow to exactly 0, concluding the order) -- LESS than the
    // OLD production formula's 16, and closer to (though still 1 below,
    // per the apportionment argument above) fill4's own isolated-fair
    // ceil(5*51/18) == 15.
    scenario.next_tx(taker());
    let ask4_payment = coin::mint_for_testing<BTC>(51, scenario.ctx());
    let (ask4_ticket_opt, ask4_leftover_base, ask4_matched_quote, ask4_stopped) =
        book.place_limit_order_ask(price, 51, ask4_payment, MAX_FILLS, scenario.ctx());
    assert!(!ask4_stopped, 13);
    assert!(ask4_leftover_base.burn_for_testing() == 0, 14);
    assert!(ask4_matched_quote.burn_for_testing() == 14, 15);
    ask4_ticket_opt.destroy_none();

    // The resting bid must now be fully gone (drained, popped off the book).
    assert!(book.depth_at_price(tiny_clob::bid_for_testing(), price) == 0, 16);
    assert!(book.bid_quote_escrow_at_price(price) == 0, 17);
    assert!(book.resting_order_escrow(tiny_clob::bid_for_testing(), price, 0).is_none(), 18);

    // Sum of all 4 quote_cost deltas exactly equals `total_reserved` -- zero
    // stranded, zero over-collected: 2+4+8+14 == 28.
    // (implicitly checked above via the running `bid_quote_escrow_at_price`
    // sequence 28 -> 26 -> 22 -> 14 -> 0)

    // The bid's pooled maker proceeds must hold exactly 100 Base -- every
    // fill (concluding or not) credits its own `fill_qty` of Base into the
    // pooled ledger via `credit_maker_table`, unaffected by the escrow
    // redesign (no maker fee configured on this book, so no fee deduction).
    scenario.next_tx(maker_a());
    let (claim_base, claim_quote, ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == 100, 19);
    assert!(claim_quote.burn_for_testing() == 0, 20);
    assert!(ticket_opt.is_none(), 21); // order no longer resting -> ticket consumed
    ticket_opt.destroy_none();

    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Cancelling a partially-filled resting bid must refund exactly whatever
/// live Quote escrow remains, plus whatever Base proceeds already accrued
/// from prior fills (no reserve/slack mechanism is needed for the bid's own
/// principal -- see this file's header comment: the cumulative scheme
/// conserves exactly on its own, so a cancellation's leftover Quote is
/// simply the order's live `escrow_quote_value`, already correctly tracked
/// by `remaining_size`).
#[test]
fun cancelling_a_partially_filled_bid_refunds_exactly_the_remaining_escrow() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);
    let price = shortfall_price();

    scenario.next_tx(maker_a());
    let escrow_amount = book.bid_escrow_amount(price, 100);
    let bid_payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, _) =
        book.place_limit_order_bid(price, 100, bid_payment, MAX_FILLS, scenario.ctx());
    bid_matched_base.burn_for_testing();
    bid_leftover_quote.burn_for_testing();
    let bid_ticket = bid_ticket_opt.destroy_some();

    // Only the first two fills (7 + 13 = 20 Base, cumulative charge 6).
    scenario.next_tx(taker());
    let ask1_payment = coin::mint_for_testing<BTC>(7, scenario.ctx());
    let (ask1_ticket_opt, ask1_leftover_base, ask1_matched_quote, _) =
        book.place_limit_order_ask(price, 7, ask1_payment, MAX_FILLS, scenario.ctx());
    ask1_leftover_base.burn_for_testing();
    assert!(ask1_matched_quote.burn_for_testing() == 2, 1);
    ask1_ticket_opt.destroy_none();

    scenario.next_tx(taker());
    let ask2_payment = coin::mint_for_testing<BTC>(13, scenario.ctx());
    let (ask2_ticket_opt, ask2_leftover_base, ask2_matched_quote, _) =
        book.place_limit_order_ask(price, 13, ask2_payment, MAX_FILLS, scenario.ctx());
    ask2_leftover_base.burn_for_testing();
    assert!(ask2_matched_quote.burn_for_testing() == 4, 2);
    ask2_ticket_opt.destroy_none();

    assert!(book.bid_quote_escrow_at_price(price) == 22, 3); // 28 - 6

    // Cancel the remainder: must refund exactly 22 Quote escrow, PLUS the 20
    // Base (7 + 13) already pooled as proceeds from the two fills so far --
    // `cancel_order` pays out both the live escrow principal and any pooled
    // proceeds in one call (no maker fee configured on this book).
    scenario.next_tx(maker_a());
    let (cancel_base, cancel_quote) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cancel_base.burn_for_testing() == 20, 4);
    assert!(cancel_quote.burn_for_testing() == 22, 5);

    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Smoke test for the new `place_limit_order_bid_expected_output` entry
/// point: handing over a whole payment coin plus a desired Base output
/// derives a price that never under-funds the resulting resting order.
#[test]
fun place_limit_order_bid_expected_output_smoke_test() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let escrow_amount = book.bid_escrow_amount(price, size);
    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid_expected_output(payment, size, 20, scenario.ctx());
    assert!(!stopped, 0);
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    book.destroy_orphaned_ticket(ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Smoke test for the new `place_limit_order_ask_expected_output` entry
/// point.
#[test]
fun place_limit_order_ask_expected_output_smoke_test() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let size = default_size();
    let expected_quote_output = book.bid_escrow_amount(default_price(), size);
    let payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask_expected_output(payment, expected_quote_output, 20, scenario.ctx());
    assert!(!stopped, 0);
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    book.destroy_orphaned_ticket(ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Smoke test for the redesigned `place_market_order_bid`/`_ask` interface
/// (whole payment coin as budget, `max_base_out`/`max_base_in` (`u64::MAX` =
/// unbounded, `0` = a real zero cap that no-ops) replacing the old explicit
/// `size`, `min_base_out`/`min_quote_out` (0 = not applicable) replacing the
/// old `Option`-wrapped slippage guards, and `max_quote_in` (same
/// `0`-is-real/`u64::MAX`-is-unbounded convention) restoring the old
/// Quote-spend cap). This also exercises `max_base_out`'s `u64::MAX`
/// "unbounded" sentinel end-to-end.
#[test]
fun place_market_order_bid_new_interface_smoke_test() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let ask_ticket = rest_ask(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(price, size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_quote, stopped) =
        book.place_market_order_bid(bid_payment, 20, size, u64_max(), u64_max(), scenario.ctx());
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == size, 1);
    leftover_quote.burn_for_testing();

    unit_test::destroy(ask_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// F1 coverage: `max_base_out == 0` is a real, literal zero cap on
/// `place_market_order_bid` -- NOT the old "0 = unbounded" sentinel -- so it
/// must no-op cleanly (nothing matched, `payment` returned untouched)
/// rather than either aborting or buying without limit.
#[test]
fun place_market_order_bid_max_base_out_zero_is_real_cap_and_no_ops() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let ask_ticket = rest_ask(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(price, size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_quote, stopped) =
        book.place_market_order_bid(bid_payment, 20, 0, 0, u64_max(), scenario.ctx());
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == 0, 1);
    assert!(leftover_quote.burn_for_testing() == budget, 2);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// F1 coverage (ask side, mirroring the bid-side test above): `max_base_in
/// == 0` on `place_market_order_ask` is a real, literal zero cap that
/// no-ops cleanly -- including skipping the `min_size` gate entirely, since
/// no order is actually being sized/placed at all (see the function's own
/// doc comment).
#[test]
fun place_market_order_ask_max_base_in_zero_is_real_cap_and_no_ops() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let bid_ticket = rest_bid(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (leftover_base, matched_quote, stopped) =
        book.place_market_order_ask(ask_payment, 20, 0, 0, scenario.ctx());
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == size, 1);
    assert!(matched_quote.burn_for_testing() == 0, 2);

    unit_test::destroy(bid_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// End-to-end coverage for `place_market_order_ask`'s new interface with a
/// genuine (non-`u64::MAX`, non-zero) `max_base_in` cap: mints more Base
/// than the resting bid can absorb, and proves the cap -- not
/// `payment.value()` -- determines how much is actually escrowed/sold, with
/// the rest returned untouched.
#[test]
fun place_market_order_ask_new_interface_end_to_end() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let bid_ticket = rest_bid(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(size + 50, scenario.ctx());
    let (leftover_base, matched_quote, stopped) =
        book.place_market_order_ask(ask_payment, 20, 0, size, scenario.ctx());
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 50, 1);
    assert!(matched_quote.burn_for_testing() == book.bid_escrow_amount(price, size), 2);

    unit_test::destroy(bid_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// F2 coverage: `max_quote_in` genuinely caps actual Quote spend on
/// `place_market_order_bid`, even when both `payment` and `max_base_out`
/// would allow buying more -- proving the restored cap is enforced up
/// front (by construction), not merely accepted as a no-op parameter.
#[test]
fun place_market_order_bid_max_quote_in_caps_actual_spend() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    // Twice the depth actually needed, so there's enough resting liquidity
    // to absorb more than the cap below allows.
    let ask_ticket = rest_ask(&mut book, price, size * 2, 20, scenario.ctx());

    scenario.next_tx(taker());
    let full_budget = book.bid_escrow_amount(price, size * 2);
    let bid_payment = coin::mint_for_testing<USDC>(full_budget, scenario.ctx());
    // Cap max_quote_in to exactly what buying `size` (half the available
    // depth) costs, while `max_base_out` stays unbounded and `payment`
    // covers the full depth -- only `max_quote_in` should be the binding
    // constraint.
    let quote_cap = book.bid_escrow_amount(price, size);
    let (matched_base, leftover_quote, stopped) =
        book.place_market_order_bid(bid_payment, 20, 0, u64_max(), quote_cap, scenario.ctx());
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == size, 1);
    assert!(leftover_quote.burn_for_testing() == full_budget - quote_cap, 2);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Slippage-guard coverage for the ask side (mirrors
/// `place_market_order_bid_slippage_bound_aborts` in
/// `placement_validation_and_returns_tests.move`): `min_quote_out` set just
/// above what will actually be received must abort with `ESlippageExceeded`.
#[test]
#[expected_failure(abort_code = 17, location = tiny_clob)] // ESlippageExceeded
fun place_market_order_ask_min_quote_out_slippage_bound_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let bid_ticket = rest_bid(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let expected_quote = book.bid_escrow_amount(price, size);
    let (leftover_base, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 20, expected_quote + 1, u64_max(), scenario.ctx());
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    unit_test::destroy(bid_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Coverage for the `min_base_out <= max_base_out` ordering assert added
/// alongside the `max_quote_in` restoration: both are Base-denominated, so
/// `min_base_out > max_base_out` is unconditionally rejected up front,
/// distinct from (and checked before) the post-match `ESlippageExceeded`.
#[test]
#[expected_failure(abort_code = 30, location = tiny_clob)] // EMinExceedsMaxBaseOut
fun place_market_order_bid_min_exceeds_max_base_out_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let ask_ticket = rest_ask(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(price, size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_quote, _) =
        book.place_market_order_bid(bid_payment, 20, size + 1, size, u64_max(), scenario.ctx());
    unit_test::destroy(matched_base);
    unit_test::destroy(leftover_quote);
    unit_test::destroy(ask_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

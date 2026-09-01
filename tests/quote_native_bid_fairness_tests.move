/// New tests for the Quote-denominated bid-side `remaining_size` redesign
/// and its cumulative-proportional-ceiling escrow-charging scheme in
/// `fill_level_ask` (see `order.move`'s `remaining_size`/`original_size`
/// doc comments and the matching comment block in `tiny_clob.move`'s
/// `fill_level_ask`).
///
/// The core scenario here (a size-100 resting bid drained via 4 separate
/// incoming asks of size 7/13/29/51, at `price=5`/`price_scale=10`,
/// `total_reserved=50`) is the exact scenario used to originally identify
/// the "drain what's left" fairness problem in production
/// (`price_rounding_fragmentation_tests.move` documents the sibling
/// `fill_level_bid` fix for the SAME price_scale/price via `shortfall_book`,
/// but that file's scenario is a bid-as-TAKER sweep, not this file's
/// bid-as-MAKER drain).
///
/// OLD production (floor for taker-limited fills, "drain what's left" for
/// the final/maker-limited fill) would have charged this exact sequence:
///   fill1 (qty 7):  floor(5*7/10)  = floor(35/10)  = 3
///   fill2 (qty 13): floor(5*13/10) = floor(65/10)  = 6
///   fill3 (qty 29): floor(5*29/10) = floor(145/10) = 14
///   fill4 (qty 51): drain whatever's left = 50 - (3+6+14) = 27
/// (isolated-fair ceil for fill4 alone would be ceil(5*51/10)=ceil(255/10)=26
/// -- the old scheme dumps 1 full unit of the first three fills' accumulated
/// floor-rounding slack onto whichever fill happens to conclude the order.)
///
/// NEW (this file, cumulative-proportional-ceiling): each fill's charge is
/// `ceil(total_reserved * cumulative_filled / original_size) - already_charged`:
///   fill1: ceil(50*7/100)=ceil(3.5)=4,     delta = 4 - 0  = 4
///   fill2: ceil(50*20/100)=ceil(10)=10,    delta = 10 - 4 = 6
///   fill3: ceil(50*49/100)=ceil(24.5)=25,  delta = 25 - 10 = 15
///   fill4: ceil(50*100/100)=50,            delta = 50 - 25 = 25
/// Both schemes conserve exactly (sum to 50, the order's full
/// `total_reserved`) and both compute their LAST fill the same way --
/// `total_reserved` minus the sum of the earlier fills, forced by
/// conservation, not a formula choice (see the comment in `fill_level_ask`).
/// But since the earlier three fills' own values differ between the two
/// schemes -- 4/6/15 here vs. the old floor's 3/6/14 -- their residual
/// LAST-fill value differs too, as a downstream consequence: 25 here vs.
/// 27 for the old scheme (isolated-fair ceil for fill4 alone is 26).
/// Comparing all four fills against their own isolated-fair ceil values
/// (4/7/15/26): the new scheme's total absolute deviation is smaller
/// (0+1+0+1=2 vs 1+1+1+1=4 for the old scheme), and unlike the old scheme,
/// no single fill here is ever OVER its own isolated-fair value -- the
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
/// values above, and confirming exact conservation (100 Base delivered, 50
/// Quote drained to zero, order concludes on the 4th fill).
#[test]
fun cumulative_ceiling_scheme_delivers_full_size_and_conserves_exactly() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);
    let price = shortfall_price(); // 5, price_scale == 10 (asserted in shortfall_book)

    // Rest a size-100 bid at `price`. `bid_escrow_amount(price, 100) ==
    // ceil(5*100/10) == 50` -- the `total_reserved` this whole scenario is
    // about draining exactly.
    scenario.next_tx(maker_a());
    let escrow_amount = book.bid_escrow_amount(price, 100);
    assert!(escrow_amount == 50, 100);
    let bid_payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, bid_stopped) =
        book.place_limit_order_bid(bid_payment, 100, MAX_FILLS, scenario.ctx());
    assert!(!bid_stopped, 101);
    assert!(bid_matched_base.burn_for_testing() == 0, 102);
    assert!(bid_leftover_quote.burn_for_testing() == 0, 103);
    let bid_ticket = bid_ticket_opt.destroy_some();

    // Must report the FULL Quote reservation up front -- Quote-denominated
    // `remaining_size` for a bid means this now reports 50 (Quote), not
    // 100 (Base).
    assert!(book.bid_quote_escrow_at_price(price) == 50, 104);

    // Fill 1: incoming ask sells 7 Base. Expect quote_cost == 4.
    scenario.next_tx(taker());
    let ask1_payment = coin::mint_for_testing<BTC>(7, scenario.ctx());
    // Pure crossing fill (never rests): `place_market_order_ask` needs no
    // price/expected-output derivation.
    let (ask1_leftover_base, ask1_matched_quote, ask1_stopped) =
        book.place_market_order_ask(ask1_payment, MAX_FILLS, 0, u64_max(), scenario.ctx());
    assert!(!ask1_stopped, 1);
    assert!(ask1_leftover_base.burn_for_testing() == 0, 2);
    assert!(ask1_matched_quote.burn_for_testing() == 4, 3);
    assert!(book.bid_quote_escrow_at_price(price) == 46, 4); // 50 - 4

    // Fill 2: sells 13 Base. Expect quote_cost == 6 (cumulative charge 10).
    scenario.next_tx(taker());
    let ask2_payment = coin::mint_for_testing<BTC>(13, scenario.ctx());
    let (ask2_leftover_base, ask2_matched_quote, ask2_stopped) =
        book.place_market_order_ask(ask2_payment, MAX_FILLS, 0, u64_max(), scenario.ctx());
    assert!(!ask2_stopped, 5);
    assert!(ask2_leftover_base.burn_for_testing() == 0, 6);
    assert!(ask2_matched_quote.burn_for_testing() == 6, 7);
    assert!(book.bid_quote_escrow_at_price(price) == 40, 8); // 50 - 10

    // Fill 3: sells 29 Base. Expect quote_cost == 15 (cumulative charge 25).
    scenario.next_tx(taker());
    let ask3_payment = coin::mint_for_testing<BTC>(29, scenario.ctx());
    let (ask3_leftover_base, ask3_matched_quote, ask3_stopped) =
        book.place_market_order_ask(ask3_payment, MAX_FILLS, 0, u64_max(), scenario.ctx());
    assert!(!ask3_stopped, 9);
    assert!(ask3_leftover_base.burn_for_testing() == 0, 10);
    assert!(ask3_matched_quote.burn_for_testing() == 15, 11);
    assert!(book.bid_quote_escrow_at_price(price) == 25, 12); // 50 - 25

    // Fill 4: sells 51 Base, exactly the resting bid's remaining Base
    // capacity (7+13+29+51 == 100). Expect quote_cost == 25 (drains the
    // remaining escrow to exactly 0, concluding the order) -- LESS than the
    // OLD production formula's 27, and closer to (though still 1 below,
    // per the apportionment argument above) fill4's own isolated-fair
    // ceil(5*51/10) == 26.
    scenario.next_tx(taker());
    let ask4_payment = coin::mint_for_testing<BTC>(51, scenario.ctx());
    let (ask4_leftover_base, ask4_matched_quote, ask4_stopped) =
        book.place_market_order_ask(ask4_payment, MAX_FILLS, 0, u64_max(), scenario.ctx());
    assert!(!ask4_stopped, 13);
    assert!(ask4_leftover_base.burn_for_testing() == 0, 14);
    assert!(ask4_matched_quote.burn_for_testing() == 25, 15);

    // The resting bid must now be fully gone (drained, popped off the book).
    assert!(book.bid_quote_escrow_at_price(price) == 0, 16);
    assert!(book.resting_order_escrow(tiny_clob::bid(), price, bid_ticket.ticket_order_id()).is_none(), 18);

    // Sum of all 4 quote_cost deltas exactly equals `total_reserved` -- zero
    // stranded, zero over-collected: 4+6+15+25 == 50.
    // (implicitly checked above via the running `bid_quote_escrow_at_price`
    // sequence 50 -> 46 -> 40 -> 25 -> 0)

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

/// Scale version of `cumulative_ceiling_scheme_delivers_full_size_and_conserves_exactly`:
/// same `shortfall_book`/`shortfall_price` fixture (price=5, price_scale=10),
/// but a size-1000 resting bid (`total_reserved =
/// ceil(5*1000/10) == 500`) drained across 25 separate incoming asks instead
/// of 4, with deliberately varied, non-round, mostly-small fill sizes
/// (1, 2, 3, 5, 7, 11, ... up to 101 -- the first 25 primes plus a leading
/// 1, chosen specifically so no two fills are the same size and the
/// remainders being ceil-rounded away vary fill to fill) summing to exactly
/// 1000. This is the exact regression class ("drain what's left" dumping
/// accumulated rounding slack onto whichever fill concludes the order) that
/// reportedly broke three prior implementations of this scheme -- a 4-fill
/// scenario can pass by accident, so this test hammers the same guarantee
/// with many more, more irregular fills to make an accidental pass far less
/// plausible.
///
/// Rather than hand-deriving each fill's expected `quote_cost` (as the
/// 4-fill test above does), this test tracks the RUNNING SUM of Quote
/// actually taken from the resting bid -- computed each iteration as the
/// drop in `bid_quote_escrow_at_price` -- and, after the 25th fill fully
/// drains the bid, asserts that running sum lands exactly on
/// `total_reserved` (zero dust, nothing stranded or over-collected) AND
/// that the maker's claimed Base proceeds exactly equal the bid's full
/// `original_size` (zero shortfall).
#[test]
fun cumulative_ceiling_scheme_at_scale_25_fragmented_fills_still_conserves_exactly() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);
    let price = shortfall_price(); // 5, price_scale == 10

    let original_size = 1000;

    scenario.next_tx(maker_a());
    let total_reserved = book.bid_escrow_amount(price, original_size);
    assert!(total_reserved == 500, 100);
    let bid_payment = coin::mint_for_testing<USDC>(total_reserved, scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, bid_stopped) =
        book.place_limit_order_bid(bid_payment, original_size, MAX_FILLS, scenario.ctx());
    assert!(!bid_stopped, 101);
    assert!(bid_matched_base.burn_for_testing() == 0, 102);
    assert!(bid_leftover_quote.burn_for_testing() == 0, 103);
    let bid_ticket = bid_ticket_opt.destroy_some();

    assert!(book.bid_quote_escrow_at_price(price) == total_reserved, 104);

    // 25 deliberately irregular, non-round fill sizes -- a leading 1 plus 24
    // distinct primes (not the first 24 -- 79 and 83 were swapped out for 97
    // and 101 so the total lands exactly on `original_size` (1000)) -- with
    // no two fills the same size.
    let fill_sizes = vector[
        1, 2, 3, 5, 7, 11, 13, 17, 19, 23,
        29, 31, 37, 41, 43, 47, 53, 59, 61, 67,
        71, 73, 89, 97, 101,
    ];
    assert!(fill_sizes.length() == 25, 105);
    let mut expected_total = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        expected_total = expected_total + fill_sizes[i];
        i = i + 1;
    };
    assert!(expected_total == original_size, 106);

    let mut cumulative_quote_charged = 0;
    let mut escrow_before = total_reserved;
    // Independently track the telescoping-ceiling scheme's expected
    // per-fill charge, per `fill_level_ask`'s documented handling of a
    // maker-bid in `sources/tiny_clob.move`:
    //   target_charge   = ceil(total_reserved * cumulative_filled / original_size)
    //   quote_cost      = target_charge - already_charged
    // This is computed here from scratch (not derived from the escrow
    // delta above), so a bug that mis-times *when* Quote gets charged --
    // even one that still sums to `total_reserved` overall and still
    // matches each fill's own escrow drop -- would surface as a mismatch
    // against this independently-computed expectation.
    let mut cumulative_filled = 0;
    let mut already_charged = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let fill_size = fill_sizes[i];
        scenario.next_tx(taker());
        let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
        let (ask_leftover_base, ask_matched_quote, _ask_stopped) =
            book.place_market_order_ask(ask_payment, MAX_FILLS, 0, u64_max(), scenario.ctx());
        assert!(ask_leftover_base.burn_for_testing() == 0, 200 + i);

        let quote_cost = ask_matched_quote.burn_for_testing();
        cumulative_quote_charged = cumulative_quote_charged + quote_cost;

        // Independently-computed expected charge for this fill, via the
        // telescoping-ceiling formula, using only `fill_sizes`.
        cumulative_filled = cumulative_filled + fill_size;
        let target_charge =
            (total_reserved * cumulative_filled + original_size - 1) / original_size;
        let expected_quote_cost = target_charge - already_charged;
        assert!(quote_cost == expected_quote_cost, 600 + i);
        already_charged = target_charge;

        let escrow_after = book.bid_quote_escrow_at_price(price);
        // Every fill's `quote_cost` must exactly equal the drop in the
        // resting bid's live Quote escrow -- no fill ever over- or
        // under-charges relative to what's actually deducted from the book.
        assert!(escrow_before - escrow_after == quote_cost, 300 + i);
        escrow_before = escrow_after;

        i = i + 1;
    };

    // After all 25 fills (cumulative Base = 1000 == original_size), the
    // resting bid must be fully gone: zero live escrow, popped off the book.
    assert!(book.bid_quote_escrow_at_price(price) == 0, 400);
    assert!(book.resting_order_escrow(tiny_clob::bid(), price, bid_ticket.ticket_order_id()).is_none(), 402);

    // (a) Zero dust: the running sum of Quote charged across all 25 fills
    // (each verified per-fill above to equal that fill's escrow drop)
    // exactly equals `total_reserved` -- nothing stranded, nothing
    // over-collected.
    assert!(cumulative_quote_charged == total_reserved, 500);

    // (b) Zero shortfall: the maker's claimed Base proceeds exactly equal
    // the bid's full `original_size`, no matter how fragmented the draining
    // fills were.
    scenario.next_tx(maker_a());
    let (claim_base, claim_quote, ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == original_size, 502);
    assert!(claim_quote.burn_for_testing() == 0, 503);
    assert!(ticket_opt.is_none(), 504);
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
        book.place_limit_order_bid(bid_payment, 100, MAX_FILLS, scenario.ctx());
    bid_matched_base.burn_for_testing();
    bid_leftover_quote.burn_for_testing();
    let bid_ticket = bid_ticket_opt.destroy_some();

    // Only the first two fills (7 + 13 = 20 Base, cumulative charge 10).
    scenario.next_tx(taker());
    let ask1_payment = coin::mint_for_testing<BTC>(7, scenario.ctx());
    let (ask1_leftover_base, ask1_matched_quote, _) =
        book.place_market_order_ask(ask1_payment, MAX_FILLS, 0, u64_max(), scenario.ctx());
    ask1_leftover_base.burn_for_testing();
    assert!(ask1_matched_quote.burn_for_testing() == 4, 1);

    scenario.next_tx(taker());
    let ask2_payment = coin::mint_for_testing<BTC>(13, scenario.ctx());
    let (ask2_leftover_base, ask2_matched_quote, _) =
        book.place_market_order_ask(ask2_payment, MAX_FILLS, 0, u64_max(), scenario.ctx());
    ask2_leftover_base.burn_for_testing();
    assert!(ask2_matched_quote.burn_for_testing() == 6, 2);

    assert!(book.bid_quote_escrow_at_price(price) == 40, 3); // 50 - 10

    // Cancel the remainder: must refund exactly 40 Quote escrow, PLUS the 20
    // Base (7 + 13) already pooled as proceeds from the two fills so far --
    // `cancel_order` pays out both the live escrow principal and any pooled
    // proceeds in one call (no maker fee configured on this book).
    scenario.next_tx(maker_a());
    let (cancel_base, cancel_quote) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cancel_base.burn_for_testing() == 20, 4);
    assert!(cancel_quote.burn_for_testing() == 40, 5);

    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Smoke test for the new `place_limit_order_bid` entry
/// point: handing over a whole payment coin plus a desired Base output
/// derives a price that never under-funds the resulting resting order.
#[test]
fun place_limit_order_bid_smoke_test() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let escrow_amount = book.bid_escrow_amount(price, size);
    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, size, 20, scenario.ctx());
    assert!(!stopped, 0);
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    // Nothing crosses on this empty book, so the order is still resting --
    // `cancel_order` concludes it and disposes of the ticket in one call
    // (this test is about `place_limit_order_bid`'s new entry point, not
    // ticket disposal).
    let (cancel_base, cancel_quote) = book.cancel_order(ticket, scenario.ctx());
    cancel_base.burn_for_testing();
    cancel_quote.burn_for_testing();
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Smoke test for the new `place_limit_order_ask` entry
/// point.
#[test]
fun place_limit_order_ask_smoke_test() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let size = default_size();
    let expected_quote_output = book.bid_escrow_amount(default_price(), size);
    let payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output, 20, scenario.ctx());
    assert!(!stopped, 0);
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    // Nothing crosses on this empty book, so the order is still resting --
    // `cancel_order` concludes it and disposes of the ticket in one call
    // (this test is about `place_limit_order_ask`'s new entry point, not
    // ticket disposal).
    let (cancel_base, cancel_quote) = book.cancel_order(ticket, scenario.ctx());
    cancel_base.burn_for_testing();
    cancel_quote.burn_for_testing();
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

/// `gross_size_bound_for_net_cap`'s `u64::MAX` clamp arm (the
/// `if (gross > U64_MAX) { U64_MAX as u64 }` branch in `tiny_clob.move`) is
/// only reached when `max_base_out == u64::MAX` (the "unbounded" sentinel)
/// is combined with a NONZERO `taker_fee_bps` -- every other
/// `max_base_out == u64_max()` test call site in this suite uses a book with
/// `taker_fee_bps == 0`, which takes the early `if (rate_bps == 0) { return
/// net_cap }` return and never reaches the clamp at all. Without the clamp,
/// inflating `u64::MAX` by `BPS_DENOM / (BPS_DENOM - rate_bps)` would
/// overflow the `u128 -> u64` narrowing cast and ABORT, breaking every
/// unbounded market bid whenever a nonzero taker fee is configured -- the
/// normal production case. This test's real assertion is simply that the
/// call below does not abort; the liquidity/fee bookkeeping is checked too,
/// to also confirm the resulting match is correct, not just non-aborting.
#[test]
fun place_market_order_bid_unbounded_cap_with_nonzero_taker_fee_does_not_abort() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size(); // 100
    cap.clob_admin_set_taker_fee(&mut book, 10); // 10 bps
    let ask_ticket = rest_ask(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(price, size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    // max_base_out = u64_max() (unbounded) with a nonzero taker fee: this is
    // exactly the combination that used to be entirely untested and would
    // abort without the clamp.
    let (matched_base, leftover_quote, stopped) =
        book.place_market_order_bid(bid_payment, 20, 0, u64_max(), u64_max(), scenario.ctx());
    assert!(!stopped, 0);
    // Gross matched = the full 100-unit resting ask (nothing else caps it).
    // taker_fee_amount = ceil(100 * 10 / 10_000) = ceil(0.1) = 1.
    // Net delivered = 100 - 1 = 99.
    assert!(matched_base.burn_for_testing() == 99, 1);
    leftover_quote.burn_for_testing();

    unit_test::destroy(ask_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

/// Success-path boundary coverage for `place_market_order_ask`'s
/// `min_quote_out` slippage guard: every existing test either disables the
/// check (`min_quote_out == 0`) or exercises the FAILING direction
/// (`place_market_order_ask_min_quote_out_slippage_bound_aborts` above, at
/// `expected_quote + 1`), leaving the success-path continuation after the
/// `assert!(matched_quote.value() >= min_quote_out, ...)` check entirely
/// uncovered. This hits the exact boundary from the other side --
/// `min_quote_out == expected_quote` exactly -- proving the guard is
/// `>=`, not `>`: if the code used a strict `>` here, this call would abort
/// instead of succeeding.
#[test]
fun place_market_order_ask_min_quote_out_exact_boundary_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let price = default_price();
    let size = default_size();
    let bid_ticket = rest_bid(&mut book, price, size, 20, scenario.ctx());

    scenario.next_tx(taker());
    let expected_quote = book.bid_escrow_amount(price, size);
    let ask_payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (leftover_base, matched_quote, stopped) =
        book.place_market_order_ask(ask_payment, 20, expected_quote, u64_max(), scenario.ctx());
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1);
    assert!(matched_quote.burn_for_testing() == expected_quote, 2);

    unit_test::destroy(bid_ticket);
    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

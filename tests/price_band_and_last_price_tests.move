#[test_only]
module tiny_clob::price_band_and_last_price_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};
use tiny_clob::test_utils::{
    Self, admin, other, taker, maker_a, min_size, new_book, destroy_book_and_cap, rest_bid, rest_ask, u64_max, realistic_decimals_book,
};


#[test]
fun price_band_factor_just_inside_band_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    // band: [1000/2, 1000*2] = [500, 2000]
    let low_ticket = rest_bid(&mut book, 500, min_size(), 10, scenario.ctx());
    let high_ticket = rest_bid(&mut book, 2000, min_size(), 10, scenario.ctx());
    unit_test::destroy(low_ticket);
    unit_test::destroy(high_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = tiny_clob)] // EPriceBelowBand
fun price_band_factor_just_outside_band_below_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    let ticket = rest_bid(&mut book, 499, min_size(), 10, scenario.ctx()); // just below the [500, 2000] band
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 24, location = tiny_clob)] // EPriceAboveBand
fun price_band_factor_just_outside_band_above_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    let ticket = rest_bid(&mut book, 2001, min_size(), 10, scenario.ctx()); // just above the [500, 2000] band
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun price_band_factor_just_inside_band_succeeds_ask() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    // band: [1000/2, 1000*2] = [500, 2000]
    let low_ticket = rest_ask(&mut book, 500, min_size(), 10, scenario.ctx());
    let high_ticket = rest_ask(&mut book, 2000, min_size(), 10, scenario.ctx());
    unit_test::destroy(low_ticket);
    unit_test::destroy(high_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = tiny_clob)] // EPriceBelowBand
fun price_band_factor_just_outside_band_below_aborts_ask() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    let ticket = rest_ask(&mut book, 499, min_size(), 10, scenario.ctx()); // just below the [500, 2000] band
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 24, location = tiny_clob)] // EPriceAboveBand
fun price_band_factor_just_outside_band_above_aborts_ask() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    let ticket = rest_ask(&mut book, 2001, min_size(), 10, scenario.ctx()); // just above the [500, 2000] band
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_empty_book_is_unconstrained() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(12_345, scenario.ctx());
    assert!(book.last_price() == 12_345, 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// The test above only ever moves `last_price` UPWARD on an empty book. This
/// proves the empty-book bracket-skip (no `best_bid`/`best_ask` to bound
/// against) genuinely works in the DOWNWARD direction too: rest a bid at
/// 1000, jump `last_price` up to 5000 (bounded by nothing, since there's no
/// resting ask), cancel the bid (book now empty again), then jump back down
/// to 1 -- which would abort `EResetPriceBelowBestBid` if the bid were still
/// resting, but must succeed cleanly now that the book is genuinely empty.
#[test]
fun set_last_price_empty_book_is_unconstrained_downward() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ticket = rest_bid(&mut book, 1000, min_size(), 10, scenario.ctx());
    book.set_last_price(5000, scenario.ctx());
    assert!(book.last_price() == 5000, 0);

    let (cb, cq) = book.cancel_order(ticket, scenario.ctx());
    cb.burn_for_testing();
    cq.burn_for_testing();
    assert!(book.best_bid().is_none() && book.best_ask().is_none(), 1); // genuinely empty again

    book.set_last_price(1, scenario.ctx());
    assert!(book.last_price() == 1, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 26, location = tiny_clob)] // EResetPriceBelowBestBid
fun set_last_price_below_best_bid_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_bid(&mut book, 1000, min_size(), 10, scenario.ctx());
    book.set_last_price(999, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_at_or_above_best_bid_succeeds_with_only_bid_present() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_bid(&mut book, 1000, min_size(), 10, scenario.ctx());
    // Pin down the pre-call value so the assertions below genuinely prove
    // each `set_last_price` call changed the value, rather than merely
    // being consistent with a silent no-op (the audit's L-02 finding: a
    // target value equal to the already-current `last_price` wouldn't
    // distinguish "the call worked" from "the call did nothing").
    assert!(book.last_price() == 1, 0); // book's initial_last_price, untouched so far
    book.set_last_price(1000, scenario.ctx()); // exactly the best bid; differs from the initial 1
    assert!(book.last_price() == 1000, 1);
    book.set_last_price(5_000_000, scenario.ctx()); // far above; no best ask to bound it
    assert!(book.last_price() == 5_000_000, 2);
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 27, location = tiny_clob)] // EResetPriceAboveBestAsk
fun set_last_price_above_best_ask_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_ask(&mut book, 2000, min_size(), 10, scenario.ctx());
    book.set_last_price(2001, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_at_or_below_best_ask_succeeds_with_only_ask_present() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_ask(&mut book, 2000, min_size(), 10, scenario.ctx());
    book.set_last_price(2000, scenario.ctx()); // exactly the best ask
    assert!(book.last_price() == 2000, 0);
    book.set_last_price(1, scenario.ctx()); // far below; no best bid to bound it
    assert!(book.last_price() == 1, 1);
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_within_spread_both_sides_present_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 1000, min_size(), 10, scenario.ctx());
    let ask_ticket = rest_ask(&mut book, 2000, min_size(), 10, scenario.ctx());
    book.set_last_price(1500, scenario.ctx());
    assert!(book.last_price() == 1500, 0);
    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 26, location = tiny_clob)] // EResetPriceBelowBestBid
fun set_last_price_below_bid_both_sides_present_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 1000, min_size(), 10, scenario.ctx());
    let ask_ticket = rest_ask(&mut book, 2000, min_size(), 10, scenario.ctx());
    book.set_last_price(999, scenario.ctx());
    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 27, location = tiny_clob)] // EResetPriceAboveBestAsk
fun set_last_price_above_ask_both_sides_present_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 1000, min_size(), 10, scenario.ctx());
    let ask_ticket = rest_ask(&mut book, 2000, min_size(), 10, scenario.ctx());
    book.set_last_price(2001, scenario.ctx());
    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A resting-ask sweep spans two price levels (100, then 200). The taker's
/// market-bid budget covers only the first level exactly, so the second
/// level's iteration computes `affordable_qty == 0` and breaks without ever
/// filling — `last_price` must reflect the first (real) fill's price and
/// must NOT be touched by the second, no-fill iteration.
#[test]
fun last_price_updates_on_real_fill_not_on_zero_qty_iteration() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask1 = rest_ask(&mut book, 100, min_size(), 10, scenario.ctx());
    let ask2 = rest_ask(&mut book, 200, min_size(), 10, scenario.ctx());
    assert!(book.last_price() == 1, 0); // untouched: nothing filled yet

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(100, min_size()); // exactly covers ask1, nothing left for ask2
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, stopped) = book.place_market_order_bid(payment, 10, 0, min_size() * 2, u64_max(), scenario.ctx(),
    );
    assert!(!stopped, 1);
    assert!(matched_base.burn_for_testing() == min_size(), 2); // only ask1 filled
    assert!(leftover.burn_for_testing() == 0, 3);
    assert!(book.last_price() == 100, 4); // ask1's price, not ask2's

    unit_test::destroy(ask1);
    unit_test::destroy(ask2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Market orders carry no price parameter/check, but must still update
/// `last_price` after a real fill — exercised here on the ask side (the
/// bid side is already covered by the zero-qty-iteration test above).
#[test]
fun market_order_ask_updates_last_price_after_real_fill() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 300, min_size(), 10, scenario.ctx());
    assert!(book.last_price() == 1, 0); // untouched: nothing filled yet

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<BTC>(min_size(), scenario.ctx());
    let (leftover_base, matched_quote, stopped) =
        book.place_market_order_ask(payment, 10, 0, min_size(), scenario.ctx());
    assert!(!stopped, 1);
    assert!(leftover_base.burn_for_testing() == 0, 2);
    assert!(matched_quote.burn_for_testing() == 300 * min_size(), 3);
    assert!(book.last_price() == 300, 4);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `last_price` across multiple fully-filled price levels in one match ---
//
// Unlike `last_price_updates_on_real_fill_not_on_zero_qty_iteration` above
// (where the second level is touched but never actually fills), the tests
// below fully drain BOTH resting levels in a single match and assert
// `last_price` reflects the LAST level touched, not the first.

#[test]
fun last_price_reflects_last_of_two_fully_filled_ask_levels() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let ask1 = rest_ask(&mut book, 100, min_size(), 10, scenario.ctx());
    let ask2 = rest_ask(&mut book, 200, min_size(), 10, scenario.ctx());

    scenario.next_tx(taker());
    // Exactly covers both levels: 100*min_size() + 200*min_size().
    let budget = book.bid_escrow_amount(100, min_size())
        + book.bid_escrow_amount(200, min_size());
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, stopped) = book.place_market_order_bid(payment, 10, 0, min_size() * 2, u64_max(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == min_size() * 2, 1); // both levels fully filled
    assert!(leftover.burn_for_testing() == 0, 2);
    assert!(book.last_price() == 200, 3); // the LAST level touched, not the first

    unit_test::destroy(ask1);
    unit_test::destroy(ask2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Mirrors the test above for two fully-drained bid levels swept by one
/// market ask order: best bid (300) is consumed first, then the next-best
/// (200) — `last_price` must land on 200, the last level touched.
#[test]
fun last_price_reflects_last_of_two_fully_filled_bid_levels() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let bid1 = rest_bid(&mut book, 300, min_size(), 10, scenario.ctx());
    let bid2 = rest_bid(&mut book, 200, min_size(), 10, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<BTC>(min_size() * 2, scenario.ctx());
    let (leftover_base, matched_quote, stopped) = book.place_market_order_ask(payment, 10, 0, min_size() * 2, scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1); // both levels fully filled
    assert!(matched_quote.burn_for_testing() == 300 * min_size() + 200 * min_size(), 2);
    assert!(book.last_price() == 200, 3); // the LAST level touched, not the first

    unit_test::destroy(bid1);
    unit_test::destroy(bid2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- Price band anchored to a fill-driven `last_price` change ---
//
// Every price-band test above sets `last_price` directly via `set_last_price`;
// none of them ever let a real fill move `last_price` and then re-checked the
// band against the new value. The tests below close that gap: a resting ask
// at 1900 is crossed by a market bid (updating `last_price` to 1900 via the
// fill path, not `set_last_price`), then the band -- now anchored to 1900,
// not the original 1000 -- is shown to have genuinely moved.

/// Shared setup: `last_price = 1000`, `factor = Some(2)` (old band
/// `[500, 2000]`), then a resting ask at 1900 is fully crossed by a market
/// bid, updating `last_price` to 1900 via the fill path. New band:
/// `[1900/2, 1900*2] = [950, 3800]` (per the source's `price * factor >=
/// last_price` / `price <= last_price * factor` check).
fun band_anchored_to_1900_fill(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap, OrderTicket) {
    let (mut book, cap) = new_book(scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));

    let ask_ticket = rest_ask(&mut book, 1900, min_size(), 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(1900, min_size());
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, stopped) =
        book.place_market_order_bid(payment, 10, 0, min_size(), u64_max(), scenario.ctx());
    assert!(!stopped, 90);
    assert!(matched_base.burn_for_testing() == min_size(), 91);
    assert!(leftover.burn_for_testing() == 0, 92);
    assert!(book.last_price() == 1900, 93); // moved via the fill path, not set_last_price

    (book, cap, ask_ticket)
}

#[test]
fun price_band_anchors_to_fill_driven_last_price_bid_at_new_high_edge_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap, ask_ticket) = band_anchored_to_1900_fill(&mut scenario);

    // New band's high edge (3800): succeeds.
    let ticket = rest_bid(&mut book, 3800, min_size(), 10, scenario.ctx());

    unit_test::destroy(ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 24, location = tiny_clob)] // EPriceAboveBand
fun price_band_anchors_to_fill_driven_last_price_bid_above_new_band_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap, ask_ticket) = band_anchored_to_1900_fill(&mut scenario);

    // One above the new band's high edge (3801): aborts.
    let ticket = rest_bid(&mut book, 3801, min_size(), 10, scenario.ctx());

    unit_test::destroy(ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = tiny_clob)] // EPriceBelowBand
fun price_band_anchors_to_fill_driven_last_price_bid_below_new_band_though_in_old_band_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap, ask_ticket) = band_anchored_to_1900_fill(&mut scenario);

    // 949 was comfortably inside the OLD band ([500, 2000], anchored to the
    // original last_price of 1000) but the band has genuinely moved to
    // [950, 3800] -- 949 is now rejected, proving the anchor really did move.
    let ticket = rest_bid(&mut book, 949, min_size(), 10, scenario.ctx());

    unit_test::destroy(ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- Price-band edge values: `factor == 1` and u128 headroom ---
//
// Every price-band test above uses `factor = 2` (or the incidental `1000` in
// `clob_admin_set_price_band_factor_none_clears_band_and_price_now_succeeds`,
// used there only for an id/field check, never for actually placing an
// order at the band's edge). The tests below cover `factor == 1` (the band
// collapses to a single exact point) and a maximal `factor` combined with a
// large `last_price` (confirming the `u128` band arithmetic has headroom and
// doesn't spuriously overflow/abort).

/// `factor == 1` collapses the band to exactly `{last_price}`: a bid placed
/// at exactly `last_price` (1000) must succeed. (Placing a bid AND an ask
/// both at exactly 1000 on the same book would cross and fully fill each
/// other rather than rest — that's a matching-engine property, not a
/// band-check one — so the ask side gets its own book below instead.)
#[test]
fun price_band_factor_one_collapses_band_to_exact_last_price_bid_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(1));
    // band: [1000/1, 1000*1] = [1000, 1000] -- a single point.

    let bid_ticket = rest_bid(&mut book, 1000, min_size(), 10, scenario.ctx());

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Ask-side counterpart to the bid test above, on its own book (see that
/// test's doc comment for why they can't share one book at this price).
#[test]
fun price_band_factor_one_collapses_band_to_exact_last_price_ask_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(1));

    let ask_ticket = rest_ask(&mut book, 1000, min_size(), 10, scenario.ctx());

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = tiny_clob)] // EPriceBelowBand
fun price_band_factor_one_rejects_one_below_collapsed_point() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(1));
    let ticket = rest_bid(&mut book, 999, min_size(), 10, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 24, location = tiny_clob)] // EPriceAboveBand
fun price_band_factor_one_rejects_one_above_collapsed_point() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(1));
    let ticket = rest_bid(&mut book, 1001, min_size(), 10, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A very large `price_band_factor` (`u64::MAX`) combined with a large
/// `last_price` must not overflow the band check's `u128` arithmetic
/// (`price * factor` / `last_price * factor`, both computed as `u128` in the
/// source). `large_last_price = 10^17` is chosen as the largest power of ten
/// still compatible with placing an actual resting order at `min_size()`
/// (100) on this `price_scale == 1` book -- `price * size` (the quote value
/// `bid_escrow_amount`/`ask_expected_output_for_price` must itself compute
/// and cast to `u64`) is a SEPARATE `u64`-sized quantity from the band
/// check's `u128` product, and caps how large a price this fixture can
/// legally place an order at (`10^17 * 100 = 10^19`, just under `u64::MAX`
/// =~ 1.8e19; `10^19 * 100` would itself overflow that unrelated cast). The
/// band product itself, `10^17 * u64::MAX =~ 1.8e36`, is still far below
/// `u128::MAX` (~3.4e38) but far above `u64::MAX` (~1.8e19) -- so a `u64`
/// implementation of this check would have overflowed here, while the
/// actual `u128` one doesn't: both a tiny price (1) and `large_last_price`
/// itself succeed.
#[test]
fun price_band_factor_max_u64_with_large_last_price_accepts_everything_without_overflow() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let large_last_price: u64 = 100_000_000_000_000_000; // 10^17
    book.set_last_price(large_last_price, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(u64_max()));

    let low_ticket = rest_bid(&mut book, 1, min_size(), 10, scenario.ctx());
    let high_ticket = rest_bid(&mut book, large_last_price, min_size(), 10, scenario.ctx());

    unit_test::destroy(low_ticket);
    unit_test::destroy(high_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- Price-band exemption for market orders ---
//
// `place_market_order_bid`/`_ask` never read `book.price_band_factor` at
// all in the source — the band only ever gates a NEW RESTING limit-order
// price, never a taker fill. The test below pins this down concretely: a
// resting ask is placed outside a band that is tightened only afterward,
// then a market order is shown to fill against it anyway.

#[test]
fun market_order_bid_fills_against_resting_ask_outside_subsequently_set_band() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    // Rest the ask BEFORE any band exists, at a price far outside the band
    // that will be set below.
    let ask_ticket = rest_ask(&mut book, 5000, min_size(), 10, scenario.ctx());
    book.set_last_price(1000, scenario.ctx()); // <= best_ask (5000), so this succeeds
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    // band is now [500, 2000] -- 5000 is well outside it.

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(5000, min_size());
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover, stopped) = book.place_market_order_bid(payment, 10, 0, min_size(), u64_max(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == min_size(), 1); // filled despite being outside the band
    assert!(leftover.burn_for_testing() == 0, 2);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `EZeroPriceBandFactor` ---

#[test]
#[expected_failure(abort_code = 25, location = tiny_clob)] // EZeroPriceBandFactor
fun clob_admin_set_price_band_factor_zero_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_price_band_factor(&mut book, option::some(0));
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun set_last_price_zero_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(0, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === L-02 coverage gaps: `LastPriceSet`, and `set_last_price`'s ===
// === permissionless / pause-and-retire-agnostic surface ===

// --- Gap 2: `LastPriceSet` event fields (`setter`, `last_price`) are ---
// --- otherwise never asserted anywhere in this file. ---

/// A genuinely value-changing `set_last_price` call, from a specific
/// non-admin sender, must emit exactly one `LastPriceSet` event whose
/// `setter` field is that sender's address (not the admin's, not some
/// other fixed address) and whose `last_price` field is the new value.
#[test]
fun last_price_set_event_records_setter_and_value() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    scenario.next_tx(maker_a());
    assert!(book.last_price() == 1, 0); // initial_last_price, not yet touched
    book.set_last_price(12_345, scenario.ctx());
    assert!(book.last_price() == 12_345, 1);

    let events = event::events_by_type<tiny_clob::LastPriceSet>();
    assert!(events.length() == 1, 2);
    let (ev_true_book_id, _ev_enclosing_id, ev_last_price, ev_setter) = events[0].last_price_set_fields_for_testing();
    assert!(ev_true_book_id == book_id, 3); // leading `book_id` field: the book's true, unforgeable id
    assert!(ev_last_price == 12_345, 4);
    assert!(ev_setter == maker_a(), 5); // the actual caller, not admin()
    assert!(ev_setter != admin(), 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A `set_last_price` call whose `new_last_price` equals the book's
/// current `last_price` is a no-op: it must not emit a second
/// `LastPriceSet` event on top of the one from the real, preceding change.
#[test]
fun last_price_set_noop_emits_no_additional_event() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    book.set_last_price(12_345, scenario.ctx()); // real change: 1 -> 12_345
    let events_after_real_change = event::events_by_type<tiny_clob::LastPriceSet>();
    assert!(events_after_real_change.length() == 1, 0);

    book.set_last_price(12_345, scenario.ctx()); // no-op: already 12_345
    assert!(book.last_price() == 12_345, 1);
    let events_after_noop = event::events_by_type<tiny_clob::LastPriceSet>();
    assert!(events_after_noop.length() == 1, 2); // unchanged -- no new event from the no-op call

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- Gap 3: `set_last_price` is deliberately not pause/retire-gated -- ---
// --- confirm it actually works on a paused book, and on a retiring one ---
// --- through to `clob_admin_finalize`. ---

#[test]
fun set_last_price_succeeds_on_paused_book() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_pause_book(&mut book);
    assert!(book.is_book_paused(), 0);

    // Not pause-gated: succeeds despite the book being paused.
    book.set_last_price(999, scenario.ctx());
    assert!(book.last_price() == 999, 1);

    // Pausing/unpausing still works normally afterward -- `set_last_price`
    // didn't interfere with the pause lifecycle.
    cap.clob_admin_unpause_book(&mut book);
    assert!(!book.is_book_paused(), 2);
    assert!(book.last_price() == 999, 3); // stuck through the unpause

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_succeeds_on_retiring_book_and_finalize_still_works() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();
    cap.clob_admin_retire(&mut book);

    // Not gated on `retiring` either: succeeds on a retiring book.
    book.set_last_price(4_242, scenario.ctx());
    assert!(book.last_price() == 4_242, 0);

    // The deletion lifecycle proceeds normally afterward: an empty book
    // drains trivially and finalizes.
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();
    assert!(deleted_id == book_id, 1);

    scenario.end();
}

// --- Gap 4: a non-admin sender can successfully call `set_last_price` ---
// --- without ever constructing or referencing a `ClobAdminCap`. ---

#[test]
fun set_last_price_succeeds_from_non_admin_sender_without_admin_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(other()); // switch to a sender that never held the ClobAdminCap
    book.set_last_price(777, scenario.ctx()); // no cap argument exists on this function at all
    assert!(book.last_price() == 777, 0);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Price-band interaction with derived-price tick-snapping ===
//
// Every price-band test above uses `new_book` (`price_scale == 1`), where a
// bid/ask's `payment`/`expected_output` ratio always decodes to an exact
// integer raw price -- `place_limit_order_bid`'s `floor` and
// `place_limit_order_ask`'s `ceil` derivation never actually round anything.
// On a `price_scale > 1` book (`realistic_decimals_book`, `price_scale ==
// 100`), a caller's exact ratio can imply a fractional true raw price that
// then snaps to a whole tick -- and the band check (added by one redesign)
// runs against that *snapped* `price`, not the caller's original ratio (the
// derive-price-from-payment redesign). The tests below hand-derive
// `payment`/`expected_base_output` (bid) and `expected_quote_output`/`size`
// (ask) pairs directly from the floor/ceil formulas in
// `place_limit_order_bid`/`_ask` (`sources/tiny_clob.move`) to exercise
// exactly this interaction -- `bid_payment_for_price`/
// `ask_expected_output_for_price` require an exact round-trip and cannot
// produce a deliberately-fractional ratio.
//
// Fixture used throughout: `last_price == 1000`, `price_band_factor ==
// Some(2)` => raw-price band `[500, 2000]` -- the same numeric style as
// `new_book`'s price-band tests above, now on a book where `price_scale ==
// 100` makes fractional true-price ratios possible.

/// Bid ratio `payment / expected_base_output * price_scale == 501.5` (exact:
/// `payment = 5015`, `expected_base_output = 1000`, `price_scale = 100` =>
/// `5015 * 100 / 1000 = 501.5`) floors to raw price `501` -- one tick below
/// the exact ratio, but comfortably WITHIN the band (`501 * factor(2) =
/// 1002 >= last_price`, `501 <= 2000`), not at either edge. This is the
/// "ordinary" mid-band tick-snap case, distinct from the boundary-exact
/// case covered by `bid_fractional_ratio_floor_just_inside_band_low_edge_succeeds`
/// below (which lands exactly on the band's low edge, not merely inside it).
#[test]
fun bid_fractional_ratio_floors_to_price_mid_band_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    assert!(book.price_band_factor() == option::some(2), 100);
    // band: [1000/2, 1000*2] = [500, 2000] (raw price units; price_scale == 100)

    let payment = coin::mint_for_testing<USDC>(5015, scenario.ctx()); // 5015*100/1000 = 501.5 -> floors to 501
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 1000, 10, scenario.ctx());
    assert!(!stopped, 0);
    assert!(matched_base.burn_for_testing() == 0, 1); // nothing to cross against
    leftover_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    assert!(ticket.ticket_price() == 501, 2);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Two bid ratios straddling the band's low edge by fractional amounts that
/// both floor toward it:
/// - `payment = 5005`, `expected_base_output = 1000` => exact ratio `500.5`,
///   floors to `500` -- still exactly the band's low edge, succeeds.
/// - `payment = 4999`, `expected_base_output = 1000` => exact ratio `499.9`,
///   floors to `499` -- now genuinely below the `[500, 2000]` band, aborts
///   `EPriceBelowBand`. Confirms it's the band check firing (`499 * 2 = 998
///   < 1000`), not the declared-range check (`499 >= 1`, well within this
///   book's declared range) or `EZeroPrice` (`499 != 0`).
#[test]
fun bid_fractional_ratio_floor_just_inside_band_low_edge_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    assert!(book.price_band_factor() == option::some(2), 100);

    let payment = coin::mint_for_testing<USDC>(5005, scenario.ctx()); // 5005*100/1000 = 500.5 -> floors to 500
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 1000, 10, scenario.ctx());
    assert!(!stopped, 0);
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    assert!(ticket.ticket_price() == 500, 1);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = tiny_clob)] // EPriceBelowBand
fun bid_fractional_ratio_floor_pushes_just_outside_band_low_edge_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    assert!(book.price_band_factor() == option::some(2), 100);

    let payment = coin::mint_for_testing<USDC>(4999, scenario.ctx()); // 4999*100/1000 = 499.9 -> floors to 499
    let (ticket_opt, matched_base, leftover_quote, _stopped) =
        book.place_limit_order_bid(payment, 1000, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(matched_base);
    unit_test::destroy(leftover_quote);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Mirrors the bid pair above for the ask side, at the band's HIGH edge:
/// `place_limit_order_ask` derives `price = ceil(expected_quote_output *
/// price_scale / size)`.
/// - `expected_quote_output = 19991`, `size = 1000` => exact ratio `1999.1`,
///   ceils to `2000` -- exactly the band's high edge, succeeds.
/// - `expected_quote_output = 20001`, `size = 1000` => exact ratio
///   `2000.1`, ceils to `2001` -- now genuinely above the `[500, 2000]`
///   band, aborts `EPriceAboveBand`.
#[test]
fun ask_fractional_ratio_ceil_just_inside_band_high_edge_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    assert!(book.price_band_factor() == option::some(2), 100);
    // band: [500, 2000]

    let payment = coin::mint_for_testing<BTC>(1000, scenario.ctx());
    // 19991*100/1000 = 1999.1 -> ceils to 2000
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, 19991, 10, scenario.ctx());
    assert!(!stopped, 0);
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    assert!(ticket.ticket_price() == 2000, 1);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 24, location = tiny_clob)] // EPriceAboveBand
fun ask_fractional_ratio_ceil_pushes_just_outside_band_high_edge_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    assert!(book.price_band_factor() == option::some(2), 100);

    let payment = coin::mint_for_testing<BTC>(1000, scenario.ctx());
    // 20001*100/1000 = 2000.1 -> ceils to 2001
    let (ticket_opt, leftover_base, matched_quote, _stopped) =
        book.place_limit_order_ask(payment, 20001, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Check-ordering pin: on a band-active `realistic_decimals_book` (`last_price
/// == 1000`, `factor == 2`, band `[500, 2000]`), a bid ratio whose floor
/// derivation rounds all the way down to raw price `0`
/// (`payment = 5`, `expected_base_output = 1000` => `5*100/1000 = 0.5`,
/// floors to `0`) must abort `EZeroPrice`, NOT `EPriceBelowBand` -- even
/// though `0` is also well below the active band (`0 * 2 = 0 < 1000`).
/// `place_limit_order_bid`'s actual check order (see `sources/tiny_clob.move`)
/// asserts `price != 0` (`EZeroPrice`) and the declared-range bounds BEFORE
/// ever consulting `price_band_factor`. If a future change accidentally
/// moved the band check earlier, this fixture would flip from aborting
/// `EZeroPrice` (14) to `EPriceBelowBand` (23) and this test would catch it.
#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice, not EPriceBelowBand
fun band_active_zero_price_derivation_aborts_zero_price_before_band_check() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    assert!(book.price_band_factor() == option::some(2), 100);
    // band: [500, 2000] -- genuinely active, and a price of 0 would also
    // fail EPriceBelowBand if the band check ran first.

    let payment = coin::mint_for_testing<USDC>(5, scenario.ctx()); // 5*100/1000 = 0.5 -> floors to 0
    let (ticket_opt, matched_base, leftover_quote, _stopped) =
        book.place_limit_order_bid(payment, 1000, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(matched_base);
    unit_test::destroy(leftover_quote);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Establishes the band is genuinely enforced at price 4000 (the same price
/// used, band-cleared, in
/// `clob_admin_set_price_band_factor_none_clears_band_and_price_now_succeeds`
/// below) before that test clears the band and reuses the exact same price
/// to prove the clear is real.
#[test]
#[expected_failure(abort_code = 24, location = tiny_clob)] // EPriceAboveBand
fun clob_admin_set_price_band_factor_band_active_rejects_price_4000() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    // band: [1000/2, 1000*2] = [500, 2000] -- 4000 is above it.
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(4000, min_size()), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, min_size(), 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(matched_base);
    unit_test::destroy(leftover_quote);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// `clob_admin_set_price_band_factor(option::none())` has never been
/// successfully called in any prior test -- the one existing `none()` call
/// site (`set_price_band_factor_rejects_wrong_cap`) aborts on the wrong-cap
/// check before ever reaching the field write, so the "turn the band off"
/// path, and the `PriceBandFactorSet.factor` event field, have zero
/// coverage. This sets a band, confirms it's enforced (a bid at 4000 aborts
/// while the [500, 2000] band is active), clears it with `option::none()`,
/// confirms the field write AND the emitted event's `factor` are genuinely
/// `None`, then confirms the exact same previously-rejected price of 4000
/// now succeeds -- proving the band is really off, not just internally
/// marked off while still somehow enforced.
#[test]
fun clob_admin_set_price_band_factor_none_clears_band_and_price_now_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_last_price(1000, scenario.ctx());
    cap.clob_admin_set_price_band_factor(&mut book, option::some(2));
    assert!(book.price_band_factor() == option::some(2), 0);

    // Clear the band with option::none() -- does not abort.
    cap.clob_admin_set_price_band_factor(&mut book, option::none());
    assert!(book.price_band_factor().is_none(), 1);

    // The emitted event's `factor` field is genuinely None for this second
    // call, not just the field write on the book.
    let events = event::events_by_type<tiny_clob::PriceBandFactorSet>();
    assert!(events.length() == 2, 2);
    let (_, _, ev_factor) = events[1].price_band_factor_set_fields_for_testing();
    assert!(ev_factor.is_none(), 3);

    // The same raw price of 4000, which would have aborted EPriceAboveBand
    // while the band was active, now succeeds cleanly -- proving the band is
    // genuinely off, not merely marked off while still somehow enforced.
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(4000, min_size()), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, min_size(), 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(matched_base);
    unit_test::destroy(leftover_quote);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

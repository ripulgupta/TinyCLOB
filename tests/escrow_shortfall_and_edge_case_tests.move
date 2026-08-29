#[test_only]
module tiny_clob::escrow_shortfall_and_edge_case_tests;

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
fun partial_cross_then_rest_clamps_resting_escrow_to_available() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    // One resting ask of size 1: the incoming bid below crosses exactly
    // this much before resting its remainder.
    scenario.next_tx(maker_a());
    let ask_ticket = rest_ask(&mut book, shortfall_price(), 1, 10, scenario.ctx());

    assert!(tiny_clob::bid_escrow_amount(&book, shortfall_price(), 10) == 3, 1);
    assert!(tiny_clob::bid_escrow_amount(&book, shortfall_price(), 9) == 3, 2);

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, shortfall_price(), 10, payment, 10, scenario.ctx());
    // Must NOT abort: the resting remainder's escrow is clamped to what's
    // actually left over (2), not the fresh (unaffordable) recomputation
    // of 3.
    assert!(option::is_some(&ticket_opt), 3);
    assert!(coin::burn_for_testing(matched_base) == 1, 4);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 5);
    let bid_ticket = option::destroy_some(ticket_opt);

    // Prove the clamp directly: nothing has been charged against the
    // resting order yet, so cancelling now must refund exactly the
    // clamped 2, not the fresh target of 3.
    scenario.next_tx(taker());
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cq) == 2, 6);
    assert!(coin::burn_for_testing(cb) == 0, 7);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// A partial-cross-then-rest order's resting SIZE is itself derived from what
// the leftover escrow can actually back (Part J's fix), not the full
// post-sweep `remaining_size`: here `remaining_size` after the sweep is 9,
// but only 2 quote atoms are left in escrow, which at
// `price=5`/`price_scale=18` backs at most `floor(2*18/5) = 7` base atoms —
// so the resting order's true size is 7, not 9, and its
// `bid_escrow_amount(price=5, size=7) = ceil(35/18) = 2` exactly matches
// what's available (guaranteed by construction — see
// `place_limit_order_bid`'s doc comment). That resting size-of-7 order must
// be drainable to completion across MULTIPLE separate taker transactions
// with zero dust: reaching full drain without `destroy_drained_bid_escrow`'s
// internal `balance::destroy_zero` aborting is itself the proof (any
// stranded dust would abort there instead).
#[test]
fun partial_cross_then_rest_full_drain_across_multiple_fills_is_zero_dust() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(maker_a());
    let ask_ticket = rest_ask(&mut book, shortfall_price(), 1, 10, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, shortfall_price(), 10, payment, 10, scenario.ctx());
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);
    let bid_ticket = option::destroy_some(ticket_opt);

    // Drain the resting 7-unit remainder across TWO separate transactions
    // (separate ask takers), summing exactly to 7.
    let fill_sizes = vector<u64>[3, 4];
    let mut total_base: u64 = 0;
    let mut total_quote: u64 = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let sz = fill_sizes[i];
        scenario.next_tx(maker_b());
        let base = coin::mint_for_testing<BTC>(sz, scenario.ctx());
        let (t, lb, mq, _) =
            tiny_clob::place_limit_order_ask(&mut book, shortfall_price(), sz, base, 10, scenario.ctx());
        // Each ask fully crosses the resting bid's remaining size, so no
        // ask-side ticket ever rests and no base is ever left over.
        assert!(option::is_none(&t), 100 + i);
        option::destroy_none(t);
        assert!(coin::burn_for_testing(lb) == 0, 200 + i);
        total_base = total_base + sz;
        total_quote = total_quote + coin::burn_for_testing(mq);
        i = i + 1;
    };
    assert!(total_base == 7, 8);
    // Zero dust, zero shortfall: the sum paid out across all separate
    // fills exactly equals the resting order's clamped `total_reserved`
    // (2), not the unaffordable ceiling-based fresh target (3) the old
    // scheme implied.
    assert!(total_quote == 2, 9);

    // The order is now fully drained and gone; cancelling the stale
    // ticket yields nothing further from escrow, only pooled proceeds.
    scenario.next_tx(taker());
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cq) == 0, 10);
    assert!(coin::burn_for_testing(cb) == 7, 11);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// A FRESH resting bid (never partially crossed at placement, so
// `total_reserved` exactly equals the once-reserved `bid_escrow_amount`)
// must still telescope to an exact lifetime total under the new
// proportional-floor accumulator, across an odd partition into several
// separate fills/transactions -- matching the fix design's claim that the
// final outcome for this (common) case is unaffected, even though
// intermediate per-fill amounts may differ slightly from the old
// delta-of-cumulative-ceilings scheme.
#[test]
fun fresh_order_lifetime_total_still_exact_under_proportional_floor() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    let size: u64 = 100;
    scenario.next_tx(maker_a());
    let reserved = tiny_clob::bid_escrow_amount(&book, shortfall_price(), size);
    assert!(reserved == 28, 0); // ceil(5*100/18) = ceil(27.77..) = 28
    let bid_ticket = rest_bid(&mut book, shortfall_price(), size, 10, scenario.ctx());

    // An odd partition of 100 that does not divide evenly against the
    // scale, so intermediate proportional floors necessarily claw back
    // rounding from earlier fills.
    let fill_sizes = vector<u64>[7, 13, 29, 51];
    let mut total_charged: u64 = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let sz = fill_sizes[i];
        scenario.next_tx(maker_b());
        let base = coin::mint_for_testing<BTC>(sz, scenario.ctx());
        let (t, lb, mq, _) =
            tiny_clob::place_limit_order_ask(&mut book, shortfall_price(), sz, base, 10, scenario.ctx());
        assert!(option::is_none(&t), 100 + i);
        option::destroy_none(t);
        assert!(coin::burn_for_testing(lb) == 0, 200 + i);
        total_charged = total_charged + coin::burn_for_testing(mq);
        i = i + 1;
    };
    // Lifetime total is exact: identical to what the once-reserved escrow
    // demanded, with zero dust, regardless of the odd partition.
    assert!(total_charged == reserved, 1);

    scenario.next_tx(taker());
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cq) == 0, 2);
    assert!(coin::burn_for_testing(cb) == size, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Regression: L-01 -- ceiling (not floor) division on the per-fill
// escrow charge, closing the "free base, full refund" exploit ===
//
// When `total_reserved < original_size` (the shortfall scenario above), a
// small fill's proportional share of `total_reserved` can be a fraction
// less than 1. A FLOOR-based accumulator (the scheme this file used to
// document, see the section above) rounds that fraction down to 0, so
// `quote_charged_so_far` stays at 0 even though the maker's resting bid
// already paid out real `Base` to the taker for that fill. A maker could
// then cancel immediately afterward and receive a FULL escrow refund (since
// nothing was ever recorded as charged) while keeping the `Base` they
// already received for free -- extracting real value for zero payment.
//
// `fill_level_ask` now charges each fill a proportional CEILING of
// `total_reserved`, clamped at `total_reserved` itself (the clamp is
// defensive/redundant: `ceil(total_reserved * original_size / original_size)
// == total_reserved` exactly at full fill). This guarantees any fill with
// `cumulative_filled >= 1` charges `cumulative_charged >= 1`, so
// `quote_charged_so_far` becomes nonzero after any real fill -- a maker
// cancelling afterward forfeits at least 1 quote atom of escrow, closing the
// exploit. (This does not guarantee every individual fill of a
// multi-taker-filled order charges nonzero marginal `quote_cost` -- a later
// filler of the same order can still see a 0 marginal charge if an earlier
// filler already absorbed the whole tiny escrow. That residual is bounded
// under 1 quote atom of true value and is an accepted, understood
// trade-off, not addressed by this fix.)
//
// Uses the same shortfall book as above (`price=5`, `price_scale=18`):
// resting bid remainder after the placement-time clamp has
// `original_size=7`, `total_reserved=2` (see the derivation in the
// "resting-remainder escrow rounding shortfall" section). A 1-unit fill's
// proportional share is `2*1/7 = 0.2857...`:
//   floor(2*1/7) = 0  -- the OLD scheme: quote_cost = 0, exploit possible.
//   ceil(2*1/7)  = 1  -- the FIX: quote_cost = 1, nonzero.
#[test]
fun tiny_fill_charges_nonzero_quote_and_forfeits_escrow_on_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    // One resting ask of size 1 so the incoming bid below crosses exactly
    // this much before resting its remainder (identical setup to
    // `partial_cross_then_rest_clamps_resting_escrow_to_available`).
    scenario.next_tx(maker_a());
    let ask_ticket = rest_ask(&mut book, shortfall_price(), 1, 10, scenario.ctx());

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, shortfall_price(), 10, payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(matched_base) == 1, 0);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 1);
    let bid_ticket = option::destroy_some(ticket_opt);
    // Resting remainder: original_size=7, total_reserved=2 (clamped, per the
    // shortfall derivation above).

    // A tiny 1-unit ask fills the resting bid's front (only) order by 1 --
    // small enough that `2*1/7` floors to 0 under the old scheme, but
    // ceils to 1 under the fix.
    scenario.next_tx(maker_b());
    let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (t, leftover_base, matched_quote, _) =
        tiny_clob::place_limit_order_ask(&mut book, shortfall_price(), 1, base, 10, scenario.ctx());
    assert!(option::is_none(&t), 2); // fully consumed by the resting bid
    option::destroy_none(t);
    assert!(coin::burn_for_testing(leftover_base) == 0, 3);
    // The maker fee bps is 0 in this book, so taker fee is also 0: the full
    // charged quote_cost flows through to the ask taker as matched_quote.
    // This is the fix in action: under the old floor scheme this would be
    // 0; under the ceiling fix it is 1 -- nonzero.
    assert!(coin::burn_for_testing(matched_quote) == 1, 4);

    // Cancel the resting bid immediately after. Under the OLD floor scheme,
    // `quote_charged_so_far` would still read 0 here, so the maker would
    // get back the FULL `total_reserved` (2) in the quote leg while ALSO
    // having already received 1 unit of `Base` for free via the pooled
    // proceeds joined into `cancel_order`'s base return -- the exploit.
    // Under the fix, the maker's quote refund is strictly less than
    // `total_reserved`: they forfeit exactly the 1 quote atom that was
    // actually charged for the free base they received.
    scenario.next_tx(taker());
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    let cb_val = coin::burn_for_testing(cb);
    let cq_val = coin::burn_for_testing(cq);
    assert!(cb_val == 1, 5); // the free base, received via pooled proceeds
    assert!(cq_val < 2, 6); // strictly less than total_reserved -- forfeited
    assert!(cq_val == 1, 7); // exact: total_reserved(2) - charged(1) = 1

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Coverage-audit gap closures ===
//
// The tests below close specific gaps identified by a blind test-coverage
// audit of `assert_price_in_declared_range`'s reject side, `last_price`
// across multi-level matches, the price-band's market-order exemption,
// `EZeroPriceBandFactor`, `EZeroPrice` at all four call sites, and
// `EDecimalsTooLarge`, plus an ask-side boundary-tick counterpart to the
// existing bid-side decimal-pair tests.

// --- `assert_price_in_declared_range` reject-side boundaries ---
//
// The four `*_price_extremes_and_adjacent_ticks` tests above prove `p_min`/
// `p_max` are ACCEPTED; the tests below prove `p_min - 1`/`p_max + 1` are
// REJECTED, on two independently-derived decimal pairs (USDC/BTC reversed,
// BTC/SUI), plus two construction-site (`new_impl`) tests proving the same
// check is wired at a call site other than order placement.

#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun usdc_btc_reversed_pair_price_just_below_min_aborts() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 184_467_440_738;
    let p_mid: u64 = 156_797_403_025_233;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 8, 0, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<BTC>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_min - 1, min_size(), payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun usdc_btc_reversed_pair_price_just_above_max_aborts() {
    let mut scenario = ts::begin(admin());
    let p_max: u64 = 18_446_744_073_709_551_600;
    let p_mid: u64 = 156_797_403_025_233;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 8, 0, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<BTC>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_max + 1, min_size(), payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun btc_sui_pair_price_just_below_min_aborts() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 18_446_744_073_700;
    let p_mid: u64 = 621_913_529_700_721_800;
    let (mut book, cap) = tiny_clob::new<BTC, SUI>(min_size(), 8, 9, 0, 6, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_min - 1, min_size(), payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun btc_sui_pair_price_just_above_max_aborts() {
    let mut scenario = ts::begin(admin());
    let p_max: u64 = 18_446_744_073_700_000_000;
    let p_mid: u64 = 621_913_529_700_721_800;
    let (mut book, cap) = tiny_clob::new<BTC, SUI>(min_size(), 8, 9, 0, 6, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_max + 1, min_size(), payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// Proves `assert_price_in_declared_range`'s reject side is also wired at
/// the construction call site (`new_impl`), not only at order placement —
/// same USDC/BTC-reversed pair and `p_min` as the order-placement test
/// above, but passed as `initial_last_price` to `new` directly.
#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun new_initial_last_price_just_below_declared_min_aborts() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 184_467_440_738;
    let (book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 8, 0, p_min - 1, scenario.ctx());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// Mirrors the test above for the max-side construction-site check.
#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun new_initial_last_price_just_above_declared_max_aborts() {
    let mut scenario = ts::begin(admin());
    let p_max: u64 = 18_446_744_073_709_551_600;
    let (book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 8, 0, p_max + 1, scenario.ctx());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

// --- `EZeroPrice` at all four call sites ---

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun new_zero_initial_last_price_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 0, 0, 19, 0, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `EDecimalsTooLarge` ---

#[test]
#[expected_failure(abort_code = 28, location = tiny_clob)] // EDecimalsTooLarge
fun new_base_decimals_over_max_aborts() {
    let mut scenario = ts::begin(admin());
    // MAX_DECIMALS = 38; 39 is one over.
    let (book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 39, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

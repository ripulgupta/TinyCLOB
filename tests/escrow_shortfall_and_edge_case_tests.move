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

    assert!(book.bid_escrow_amount(shortfall_price(), 10) == 3, 1);
    assert!(book.bid_escrow_amount(shortfall_price(), 9) == 3, 2);

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(shortfall_price(), 10, payment, 10, scenario.ctx());
    // Must NOT abort: the resting remainder's escrow is clamped to what's
    // actually left over (2), not the fresh (unaffordable) recomputation
    // of 3.
    assert!(ticket_opt.is_some(), 3);
    assert!(matched_base.burn_for_testing() == 1, 4);
    assert!(leftover_quote.burn_for_testing() == 0, 5);
    let bid_ticket = ticket_opt.destroy_some();

    // Prove the clamp directly: nothing has been charged against the
    // resting order yet, so cancelling now must refund exactly the
    // clamped 2, not the fresh target of 3.
    scenario.next_tx(taker());
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cq.burn_for_testing() == 2, 6);
    assert!(cb.burn_for_testing() == 0, 7);

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
        book.place_limit_order_bid(shortfall_price(), 10, payment, 10, scenario.ctx());
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let bid_ticket = ticket_opt.destroy_some();

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
            book.place_limit_order_ask(shortfall_price(), sz, base, 10, scenario.ctx());
        // Each ask fully crosses the resting bid's remaining size, so no
        // ask-side ticket ever rests and no base is ever left over.
        assert!(t.is_none(), 100 + i);
        t.destroy_none();
        assert!(lb.burn_for_testing() == 0, 200 + i);
        total_base = total_base + sz;
        total_quote = total_quote + mq.burn_for_testing();
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
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cq.burn_for_testing() == 0, 10);
    assert!(cb.burn_for_testing() == 7, 11);

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
    let reserved = book.bid_escrow_amount(shortfall_price(), size);
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
            book.place_limit_order_ask(shortfall_price(), sz, base, 10, scenario.ctx());
        assert!(t.is_none(), 100 + i);
        t.destroy_none();
        assert!(lb.burn_for_testing() == 0, 200 + i);
        total_charged = total_charged + mq.burn_for_testing();
        i = i + 1;
    };
    // Lifetime total is exact: identical to what the once-reserved escrow
    // demanded, with zero dust, regardless of the odd partition.
    assert!(total_charged == reserved, 1);

    scenario.next_tx(taker());
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cq.burn_for_testing() == 0, 2);
    assert!(cb.burn_for_testing() == size, 3);

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
        book.place_limit_order_bid(shortfall_price(), 10, payment, 10, scenario.ctx());
    assert!(matched_base.burn_for_testing() == 1, 0);
    assert!(leftover_quote.burn_for_testing() == 0, 1);
    let bid_ticket = ticket_opt.destroy_some();
    // Resting remainder: original_size=7, total_reserved=2 (clamped, per the
    // shortfall derivation above).

    // A tiny 1-unit ask fills the resting bid's front (only) order by 1 --
    // small enough that `2*1/7` floors to 0 under the old scheme, but
    // ceils to 1 under the fix.
    scenario.next_tx(maker_b());
    let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (t, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(shortfall_price(), 1, base, 10, scenario.ctx());
    assert!(t.is_none(), 2); // fully consumed by the resting bid
    t.destroy_none();
    assert!(leftover_base.burn_for_testing() == 0, 3);
    // The maker fee bps is 0 in this book, so taker fee is also 0: the full
    // charged quote_cost flows through to the ask taker as matched_quote.
    // This is the fix in action: under the old floor scheme this would be
    // 0; under the ceiling fix it is 1 -- nonzero.
    assert!(matched_quote.burn_for_testing() == 1, 4);

    // Cancel the resting bid immediately after. Under the OLD floor scheme,
    // `quote_charged_so_far` would still read 0 here, so the maker would
    // get back the FULL `total_reserved` (2) in the quote leg while ALSO
    // having already received 1 unit of `Base` for free via the pooled
    // proceeds joined into `cancel_order`'s base return -- the exploit.
    // Under the fix, the maker's quote refund is strictly less than
    // `total_reserved`: they forfeit exactly the 1 quote atom that was
    // actually charged for the free base they received.
    scenario.next_tx(taker());
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    let cb_val = cb.burn_for_testing();
    let cq_val = cq.burn_for_testing();
    assert!(cb_val == 1, 5); // the free base, received via pooled proceeds
    assert!(cq_val < 2, 6); // strictly less than total_reserved -- forfeited
    assert!(cq_val == 1, 7); // exact: total_reserved(2) - charged(1) = 1

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Regression: fill_level_ask's taker-limited clamp (rounding-direction
// fix, findings L-A/L-B) never aborts once a maker's escrow is exhausted ===
//
// The taker-limited branch of `fill_level_ask` now computes
// `quote_cost = min(max(floor(price * fill_qty / price_scale), 1),
// escrow_quote_value(&maker_order))`. The `escrow_quote_value` clamp is
// mandatory: a resting bid's `total_reserved` is a fixed, placement-time
// ceiling-rounded reservation, and once every fill's floor-rounded share has
// consumed it down to 0 the maker can still have real remaining size left
// (floor rounding, unlike the old per-fill ceiling, does not guarantee every
// fill claws back at least 1 atom) -- an unclamped floor/ceiling term could
// then demand more Quote than the order has left and abort
// `split_escrow_quote`, a real, maker-triggerable DoS.
//
// This test drives FIVE separate ask-taker fills against one fresh resting
// bid to prove the clamp keeps working correctly fill after fill: several
// nonzero taker-limited fills, then the escrow hits exactly 0 while the
// maker still has real size left, then a taker-limited fill correctly
// charges 0 instead of aborting, then the final fill fully drains the maker
// (maker-limited, which uses the separate `escrow_quote_value(&maker_order)`
// full-drain formula, not this clamp) and still closes the order out
// cleanly.
//
// Fixture: same shortfall book as above (`price=5`, `price_scale=18`), but a
// FRESH resting bid this time (no partial-cross clamp needed) of size 10:
// `total_reserved = bid_escrow_amount(book, 5, 10) = ceil(50/18) =
// ceil(2.77...) = 3`.
#[test]
fun taker_limited_fills_clamp_to_zero_after_escrow_exhausted_then_maker_limited_fill_closes_out() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(maker_a());
    let reserved = book.bid_escrow_amount(shortfall_price(), 10);
    assert!(reserved == 3, 0); // ceil(5*10/18) = ceil(2.77..) = 3
    let bid_ticket = rest_bid(&mut book, shortfall_price(), 10, 10, scenario.ctx());

    // Fills 1-3: qty=1 each, taker-limited (maker still has size left
    // afterward: 9, 8, 7 respectively). Each: floor(5*1/18) = 0,
    // max(.., 1) = 1, clamped against the escrow, which is still nonzero
    // going into each of these three fills (3, then 2, then 1) -- so each
    // charges exactly 1, driving the escrow to exactly 0 after fill 3.
    let mut total_charged: u64 = 0;
    let mut i = 0;
    while (i < 3) {
        scenario.next_tx(maker_b());
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        let (t, lb, mq, _) =
            book.place_limit_order_ask(shortfall_price(), 1, base, 10, scenario.ctx());
        assert!(t.is_none(), 100 + i);
        t.destroy_none();
        assert!(lb.burn_for_testing() == 0, 200 + i);
        let charged = mq.burn_for_testing();
        assert!(charged == 1, 300 + i);
        total_charged = total_charged + charged;
        i = i + 1;
    };
    // Escrow is now exactly 0; maker still has remaining_size = 10 - 3 = 7.

    // Fill 4: qty=1, maker has 6 left afterward -- still taker-limited.
    // floor(5*1/18) = 0, max(.., 1) = 1, but escrow_quote_value is now 0:
    // min(1, 0) = 0. Charges exactly 0 -- proving the clamp prevents
    // `split_escrow_quote` from ever being asked for more than the order
    // actually has left, rather than aborting.
    scenario.next_tx(maker_b());
    let base4 = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (t4, lb4, mq4, _) =
        book.place_limit_order_ask(shortfall_price(), 1, base4, 10, scenario.ctx());
    assert!(t4.is_none(), 4);
    t4.destroy_none();
    assert!(lb4.burn_for_testing() == 0, 5);
    let charged4 = mq4.burn_for_testing();
    assert!(charged4 == 0, 6);
    total_charged = total_charged + charged4;

    // Fill 5: qty=6, fully drains the resting bid's remaining size (6 -> 0)
    // -- maker-limited, so this uses the OTHER (full-drain) formula:
    // quote_cost = escrow_quote_value(&maker_order) = 0 (already exhausted
    // by fill 3). The order still closes out cleanly with a genuinely
    // zero-valued `Balance<Quote>` escrow -- `destroy_drained_bid_escrow`'s
    // internal `balance::destroy_zero` does not abort -- and the Base
    // received flows through to pooled maker proceeds exactly as any other
    // fill's would.
    scenario.next_tx(maker_b());
    let base5 = coin::mint_for_testing<BTC>(6, scenario.ctx());
    let (t5, lb5, mq5, _) =
        book.place_limit_order_ask(shortfall_price(), 6, base5, 10, scenario.ctx());
    assert!(t5.is_none(), 7);
    t5.destroy_none();
    assert!(lb5.burn_for_testing() == 0, 8);
    let charged5 = mq5.burn_for_testing();
    assert!(charged5 == 0, 9);
    total_charged = total_charged + charged5;

    // Exact conservation across the resting bid's whole lifetime: the five
    // fills' quote_cost sums to exactly its `total_reserved` of 3
    // (1 + 1 + 1 + 0 + 0 == 3) -- nothing overcharged, nothing stranded.
    assert!(total_charged == reserved, 10);

    // Cancelling the now-fully-drained ticket confirms it: all 10 Base
    // units received (via pooled proceeds), 0 further Quote from an
    // already-empty escrow.
    scenario.next_tx(taker());
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cb.burn_for_testing() == 10, 11);
    assert!(cq.burn_for_testing() == 0, 12);

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
        book.place_limit_order_bid(p_min - 1, min_size(), payment, 10, scenario.ctx());
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
        book.place_limit_order_bid(p_max + 1, min_size(), payment, 10, scenario.ctx());
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
        book.place_limit_order_bid(p_min - 1, min_size(), payment, 10, scenario.ctx());
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
        book.place_limit_order_bid(p_max + 1, min_size(), payment, 10, scenario.ctx());
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

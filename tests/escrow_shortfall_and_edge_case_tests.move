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
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks, u64_max,
};


#[test]
fun partial_cross_then_rest_clamps_resting_escrow_to_available() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    // A resting ask that ends up with exactly 1 unit of Base left: the
    // incoming bid below crosses exactly this much before resting its
    // remainder. Under the no-explicit-`price`-argument redesign,
    // `place_limit_order_ask` derives its resting price from
    // `expected_quote_output`/`size`, and at `price_scale == 10` this
    // derivation can only land exactly on `price == 5` when `price * size >=
    // price_scale` (see `test_utils::ask_expected_output_for_price`'s doc
    // comment) -- so an ask can no longer be constructed with an ORIGINAL
    // size of 1 at this price. Instead, rest a reproducible original size of
    // 8 (`price * size == 40 >= 10`), then pre-drain 7 of it via a plain
    // `place_market_order_bid` (no price derivation at all, so no such
    // constraint applies) so what the real test below sees is a resting ask
    // with exactly 1 unit of Base remaining -- reproducing the original
    // size-1 shortfall scenario exactly, with every number below unchanged
    // from before this redesign.
    scenario.next_tx(maker_a());
    let ask_ticket = rest_ask(&mut book, shortfall_price(), 8, 10, scenario.ctx());

    scenario.next_tx(other());
    let predrain_payment = coin::mint_for_testing<USDC>(1_000, scenario.ctx());
    let (predrain_base, predrain_quote, _) =
        book.place_market_order_bid(predrain_payment, 10, 0, 7, u64_max(), scenario.ctx());
    predrain_base.burn_for_testing();
    predrain_quote.burn_for_testing();

    assert!(book.bid_escrow_amount(shortfall_price(), 10) == 5, 1);
    assert!(book.bid_escrow_amount(shortfall_price(), 9) == 5, 2);

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(5, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, 10, 10, scenario.ctx());
    // Must NOT abort: the resting remainder's escrow is clamped to what's
    // actually left over (4), not the fresh (unaffordable) recomputation
    // of 5.
    assert!(ticket_opt.is_some(), 3);
    assert!(matched_base.burn_for_testing() == 1, 4);
    assert!(leftover_quote.burn_for_testing() == 0, 5);
    let bid_ticket = ticket_opt.destroy_some();

    // Prove the clamp directly: nothing has been charged against the
    // resting order yet, so cancelling now must refund exactly the
    // clamped 4, not the fresh target of 5.
    scenario.next_tx(taker());
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cq.burn_for_testing() == 4, 6);
    assert!(cb.burn_for_testing() == 0, 7);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// A partial-cross-then-rest order's resting SIZE is itself derived from what
// the leftover escrow can actually back (Part J's fix), not the full
// post-sweep `remaining_size`: here `remaining_size` after the sweep is 9,
// but only 4 quote atoms are left in escrow, which at
// `price=5`/`price_scale=10` backs at most `floor(4*10/5) = 8` base atoms —
// so the resting order's true size is 8, not 9, and its
// `bid_escrow_amount(price=5, size=8) = ceil(40/10) = 4` exactly matches
// what's available (guaranteed by construction — see
// `place_limit_order_bid`'s doc comment). That resting size-of-8 order must
// be drainable to completion across MULTIPLE separate taker transactions
// with zero dust: reaching full drain without `destroy_drained_bid_escrow`'s
// internal `balance::destroy_zero` aborting is itself the proof (any
// stranded dust would abort there instead).
#[test]
fun partial_cross_then_rest_full_drain_across_multiple_fills_is_zero_dust() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    // See `partial_cross_then_rest_clamps_resting_escrow_to_available`'s
    // comment for why this is now an original size-8 ask pre-drained down to
    // 1, rather than a bare size-1 ask.
    scenario.next_tx(maker_a());
    let ask_ticket = rest_ask(&mut book, shortfall_price(), 8, 10, scenario.ctx());

    scenario.next_tx(other());
    let predrain_payment = coin::mint_for_testing<USDC>(1_000, scenario.ctx());
    let (predrain_base, predrain_quote, _) =
        book.place_market_order_bid(predrain_payment, 10, 0, 7, u64_max(), scenario.ctx());
    predrain_base.burn_for_testing();
    predrain_quote.burn_for_testing();

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(5, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, 10, 10, scenario.ctx());
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let bid_ticket = ticket_opt.destroy_some();

    // Drain the resting 8-unit remainder across TWO separate transactions
    // (separate ask takers), summing exactly to 8. Uses
    // `place_market_order_ask` (no price/expected-output derivation) rather
    // than `place_limit_order_ask`, since these fills only ever cross the
    // resting bid -- they never rest themselves -- so no explicit or derived
    // price is needed at all.
    let fill_sizes = vector<u64>[3, 5];
    let mut total_base: u64 = 0;
    let mut total_quote: u64 = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let sz = fill_sizes[i];
        scenario.next_tx(maker_b());
        let base = coin::mint_for_testing<BTC>(sz, scenario.ctx());
        let (lb, mq, _) =
            book.place_market_order_ask(base, 10, 0, u64_max(), scenario.ctx());
        assert!(lb.burn_for_testing() == 0, 200 + i);
        total_base = total_base + sz;
        total_quote = total_quote + mq.burn_for_testing();
        i = i + 1;
    };
    assert!(total_base == 8, 8);
    // Zero dust, zero shortfall: the sum paid out across all separate
    // fills exactly equals the resting order's clamped `total_reserved`
    // (4), not the unaffordable ceiling-based fresh target (5) the old
    // scheme implied.
    assert!(total_quote == 4, 9);

    // The order is now fully drained and gone; cancelling the stale
    // ticket yields nothing further from escrow, only pooled proceeds.
    scenario.next_tx(taker());
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cq.burn_for_testing() == 0, 10);
    assert!(cb.burn_for_testing() == 8, 11);

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
    assert!(reserved == 50, 0); // ceil(5*100/10) = 50
    let bid_ticket = rest_bid(&mut book, shortfall_price(), size, 10, scenario.ctx());

    // An odd partition of 100 whose running totals aren't all multiples of
    // 2 relative to `size`, so intermediate proportional ceilings
    // (`ceil(50 * k / 100) = ceil(k / 2)`) still necessarily claw back
    // rounding from earlier fills whenever `k` is odd.
    let fill_sizes = vector<u64>[7, 13, 29, 51];
    let mut total_charged: u64 = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let sz = fill_sizes[i];
        scenario.next_tx(maker_b());
        let base = coin::mint_for_testing<BTC>(sz, scenario.ctx());
        // Pure crossing fill (never rests), so `place_market_order_ask` (no
        // price/expected-output derivation) replaces the old explicit-price
        // call here.
        let (lb, mq, _) =
            book.place_market_order_ask(base, 10, 0, u64_max(), scenario.ctx());
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
// Uses the same shortfall book as above (`price=5`, `price_scale=10`):
// resting bid remainder after the placement-time clamp has
// `original_size=8`, `total_reserved=4` (see the derivation in the
// "resting-remainder escrow rounding shortfall" section). A 1-unit fill's
// proportional share is `4*1/8 = 0.5`:
//   floor(4*1/8) = 0  -- the OLD scheme: quote_cost = 0, exploit possible.
//   ceil(4*1/8)  = 1  -- the FIX: quote_cost = 1, nonzero.
#[test]
fun tiny_fill_charges_nonzero_quote_and_forfeits_escrow_on_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    // A resting ask that ends up with exactly 1 unit of Base left, so the
    // incoming bid below crosses exactly this much before resting its
    // remainder (identical setup to
    // `partial_cross_then_rest_clamps_resting_escrow_to_available` -- see
    // that test's comment for why this is now an original size-8 ask
    // pre-drained down to 1, rather than a bare size-1 ask).
    scenario.next_tx(maker_a());
    let ask_ticket = rest_ask(&mut book, shortfall_price(), 8, 10, scenario.ctx());

    scenario.next_tx(other());
    let predrain_payment = coin::mint_for_testing<USDC>(1_000, scenario.ctx());
    let (predrain_base, predrain_quote, _) =
        book.place_market_order_bid(predrain_payment, 10, 0, 7, u64_max(), scenario.ctx());
    predrain_base.burn_for_testing();
    predrain_quote.burn_for_testing();

    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(5, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, 10, 10, scenario.ctx());
    assert!(matched_base.burn_for_testing() == 1, 0);
    assert!(leftover_quote.burn_for_testing() == 0, 1);
    let bid_ticket = ticket_opt.destroy_some();
    // Resting remainder: original_size=8, total_reserved=4 (clamped, per the
    // shortfall derivation above).

    // A tiny 1-unit ask fills the resting bid's front (only) order by 1 --
    // small enough that `4*1/8` floors to 0 under the old scheme, but
    // ceils to 1 under the fix. Pure crossing fill (never rests), so
    // `place_market_order_ask` replaces the old explicit-price call here.
    scenario.next_tx(maker_b());
    let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (leftover_base, matched_quote, _) =
        book.place_market_order_ask(base, 10, 0, u64_max(), scenario.ctx());
    assert!(leftover_base.burn_for_testing() == 0, 3);
    // The maker fee bps is 0 in this book, so taker fee is also 0: the full
    // charged quote_cost flows through to the ask taker as matched_quote.
    // This is the fix in action: under the old floor scheme this would be
    // 0; under the ceiling fix it is 1 -- nonzero.
    assert!(matched_quote.burn_for_testing() == 1, 4);

    // Cancel the resting bid immediately after. Under the OLD floor scheme,
    // `quote_charged_so_far` would still read 0 here, so the maker would
    // get back the FULL `total_reserved` (4) in the quote leg while ALSO
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
    assert!(cq_val < 4, 6); // strictly less than total_reserved -- forfeited
    assert!(cq_val == 3, 7); // exact: total_reserved(4) - charged(1) = 3

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
// `split_escrow_quote`.
//
// REDESIGNED for the telescoping cumulative-proportional-ceiling
// escrow-charging scheme (see `order::Order.original_size`'s doc comment and
// `fill_level_ask` in `tiny_clob.move`): there is no longer a separate
// per-fill floor/clamp formula to exercise here -- `quote_cost =
// ceil(total_reserved * cumulative_filled / original_size) - already_charged`
// is, by construction, always `<= ` the order's live escrow, so a
// taker-limited fill charging `0` once the escrow is fully accounted for is
// simply what the general formula produces, not a special clamp branch. This
// test still exercises the same externally-observable property the old
// clamp guaranteed: several nonzero taker-limited fills, then the escrow
// hits exactly 0 while the maker still has real Base size left (a live,
// still-resting, still-fillable bid with `remaining_size == 0` -- see
// `escrow_value_queries_tests::resting_order_escrow_reaches_some_zero_escrow_while_still_resting`
// for the dedicated coverage of that state), then a taker-limited fill
// correctly charges 0 without aborting, then the final fill fully drains the
// maker and still closes the order out cleanly.
//
// Fixture: same shortfall book as above (`price=5`, `price_scale=10`), but a
// FRESH resting bid this time (no partial-cross clamp needed) of size 10:
// `total_reserved = bid_escrow_amount(book, 5, 10) = ceil(50/10) = 5`.
//
// Hand-derived cumulative-ceiling values (`target(k) = ceil(5*k/10) =
// ceil(k/2)`, `k` = cumulative Base filled so far):
// `target(1..10) = 1,1,2,2,3,3,4,4,5,5`. Per-fill deltas therefore alternate
// `1,0,1,0,1,0,1,0,1,0`. Unlike the old (`price_scale=18`) fixture, the new
// `price_scale=10` derivation always makes this ratio (and hence this
// alternating pattern) exact -- see `new_impl`'s doc comment: `price_scale`
// is always a power of ten (or 1), so a non-power-of-ten `price` like `5`
// against it produces a clean recurring fraction (`1/2` here) rather than
// an irregular one. This test drives 10 unit fills totalling all 10 Base:
//   fills 1,3,5,7,9 (odd k): delta = 1 each (taker-limited while k<10)
//   fills 2,4,6,8 (even k, k<10): delta = 0 each (taker-limited, ALREADY
//     demonstrates a taker-limited fill charging exactly 0 without aborting)
//   fill 10 (k=10=original_size): delta = 0 -- maker-limited full drain,
//     the escrow having already been fully accounted for by fill 9.
// Sum: 1+0+1+0+1+0+1+0+1+0 == 5 == total_reserved, exactly.
#[test]
fun taker_limited_fills_clamp_to_zero_after_escrow_exhausted_then_maker_limited_fill_closes_out() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(maker_a());
    let reserved = book.bid_escrow_amount(shortfall_price(), 10);
    assert!(reserved == 5, 0); // ceil(5*10/10) = 5
    let bid_ticket = rest_bid(&mut book, shortfall_price(), 10, 10, scenario.ctx());

    // Fills 1-9: qty=1 each, all taker-limited (maker still has size left
    // afterward: 9, 8, ..., 1 respectively). Expected charges, per the
    // hand-derived alternating sequence above: 1, 0, 1, 0, 1, 0, 1, 0, 1 --
    // summing to exactly 5 (== total_reserved) by fill 9, which is itself
    // the fill that first drives the escrow down to exactly 0, while the
    // maker still has 10 - 9 = 1 Base of real remaining size. Every
    // even-indexed fill along the way (2, 4, 6, 8) already charges exactly
    // 0 while genuinely taker-limited (maker size still left afterward),
    // proving the general formula can charge 0 mid-lifetime without
    // aborting, not only at the very end.
    let expected_charges = vector[1u64, 0, 1, 0, 1, 0, 1, 0, 1];
    let mut total_charged: u64 = 0;
    let mut i = 0;
    while (i < 9) {
        scenario.next_tx(maker_b());
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        // Pure crossing fill (never rests): `place_market_order_ask` needs
        // no price/expected-output derivation.
        let (lb, mq, _) =
            book.place_market_order_ask(base, 10, 0, u64_max(), scenario.ctx());
        assert!(lb.burn_for_testing() == 0, 200 + i);
        let charged = mq.burn_for_testing();
        assert!(charged == expected_charges[i], 300 + i);
        total_charged = total_charged + charged;
        i = i + 1;
    };
    // Escrow is now exactly 0; maker still has remaining Base = 10 - 9 = 1.

    // Fill 10: qty=1, fully drains the resting bid's remaining Base (1 -> 0)
    // -- maker-limited (k=10=original_size): target(10) = ceil(5*10/10) = 5,
    // already_charged = 5, delta = 0. The order still closes out cleanly
    // with a genuinely zero-valued `Balance<Quote>` escrow --
    // `destroy_drained_bid_escrow`'s internal `balance::destroy_zero` does
    // not abort -- and the Base received flows through to pooled maker
    // proceeds exactly as any other fill's would.
    scenario.next_tx(maker_b());
    let base10 = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (lb10, mq10, _) =
        book.place_market_order_ask(base10, 10, 0, u64_max(), scenario.ctx());
    assert!(lb10.burn_for_testing() == 0, 11);
    let charged10 = mq10.burn_for_testing();
    assert!(charged10 == 0, 12);
    total_charged = total_charged + charged10;

    // Exact conservation across the resting bid's whole lifetime: the ten
    // fills' quote_cost sums to exactly its `total_reserved` of 5 -- nothing
    // overcharged, nothing stranded.
    assert!(total_charged == reserved, 13);

    // Cancelling the now-fully-drained ticket confirms it: all 10 Base
    // units received (via pooled proceeds), 0 further Quote from an
    // already-empty escrow.
    scenario.next_tx(taker());
    let (cb, cq) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(cb.burn_for_testing() == 10, 14);
    assert!(cq.burn_for_testing() == 0, 15);

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

// NOTE: this test deliberately does NOT reuse the `precision=8` USDC/BTC-
// reversed book from the `*_price_extremes_and_adjacent_ticks` test above.
// Under the new `price_scale = scale_lo` derivation, `base_decimals +
// precision >= quote_decimals` (6 + 8 >= 8) forces `P_min == 1` exactly for
// that book, so `p_min - 1 == 0` would trip `EZeroPrice` instead of the
// `EPriceBelowDeclaredMin` this test means to exercise. Using a shallower
// `precision=1` here (`base_decimals + precision (7) < quote_decimals (8)`)
// keeps `P_min` genuinely above `1` (`P_min = 10`), so `p_min - 1 = 9` stays
// nonzero and actually exercises the reject-side check.
#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun usdc_btc_reversed_pair_price_just_below_min_aborts() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 10;
    let p_mid: u64 = 50;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 1, 0, p_mid, scenario.ctx());
    // Both this book's `price_scale` and the BTC/SUI book below's are `1`
    // (see the doc comment above), so `test_utils::bid_payment_for_price`
    // always reproduces the target price exactly regardless of size.
    let payment = coin::mint_for_testing<BTC>(
        test_utils::bid_payment_for_price(&book, p_min - 1, min_size()), scenario.ctx(),
    );
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_bid(payment, min_size(), 10, scenario.ctx());
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
    let p_max: u64 = 100_000_000;
    let p_mid: u64 = 850;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 8, 0, p_mid, scenario.ctx());
    // Unlike `usdc_btc_reversed_pair_price_just_below_min_aborts` above, this
    // book's `precision == 8` gives `price_scale == 1_000_000` -- far larger
    // than `min_size()` (100) -- so `min_size()` can't round-trip back to
    // `p_max + 1` here; use `price_scale` itself as the size instead (any
    // size does, this test only cares about triggering the abort).
    let size = book.price_scale();
    let payment = coin::mint_for_testing<BTC>(
        test_utils::bid_payment_for_price(&book, p_max + 1, size), scenario.ctx(),
    );
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_bid(payment, size, 10, scenario.ctx());
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
    let p_min: u64 = 10;
    let p_mid: u64 = 337_140;
    let (mut book, cap) = tiny_clob::new<BTC, SUI>(min_size(), 8, 9, 0, 6, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(
        test_utils::bid_payment_for_price(&book, p_min - 1, min_size()), scenario.ctx(),
    );
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_bid(payment, min_size(), 10, scenario.ctx());
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
    let p_max: u64 = 10_000_000;
    let p_mid: u64 = 337_140;
    let (mut book, cap) = tiny_clob::new<BTC, SUI>(min_size(), 8, 9, 0, 6, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(
        test_utils::bid_payment_for_price(&book, p_max + 1, min_size()), scenario.ctx(),
    );
    let (ticket_opt, mb, ml, _) =
        book.place_limit_order_bid(payment, min_size(), 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// Proves `assert_price_in_declared_range`'s reject side is also wired at
/// the construction call site (`new_impl`), not only at order placement —
/// same USDC/BTC-reversed pair, decimals/precision/exponent shape, and
/// `p_min` as the order-placement test above (see that test's note on why
/// `precision=1`, not `precision=8`, is needed here), but passed as
/// `initial_last_price` to `new` directly.
#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun new_initial_last_price_just_below_declared_min_aborts() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 10;
    let (book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 1, 0, p_min - 1, scenario.ctx());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// Mirrors the test above for the max-side construction-site check.
#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun new_initial_last_price_just_above_declared_max_aborts() {
    let mut scenario = ts::begin(admin());
    let p_max: u64 = 100_000_000;
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

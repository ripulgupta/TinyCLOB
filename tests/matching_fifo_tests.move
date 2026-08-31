#[test_only]
module tiny_clob::matching_fifo_tests;

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
    default_price, default_size, shortfall_price, new_book, realistic_decimals_book, destroy_book_and_cap,
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks,
    bid_payment_for_price, ask_expected_output_for_price,
};


// Integration-level regression tests of the matching engine (`match_bid`/
// `match_ask`), driven entirely through the real public entry points
// `place_limit_order_bid`/`place_limit_order_ask` -- there is no test-only
// bypass into the matching engine in this codebase. Every taker call in
// this file is a full-cross scenario (the
// taker's requested size never exceeds available resting liquidity), so
// nothing ever rests for the taker and each call's returned
// `Option<OrderTicket>` is always `none()`. Every expected value below is
// computed independently from the known price/size/fee-rate inputs using
// the fee formula in `sources/tiny_clob.move` (`fee_amount`: `ceil(
// receive_amount * rate_bps / 10_000)`) — not by comparing two invocations
// of the same function. Fee rates are bounded by MAX_TAKER_FEE_BPS/
// MAX_MAKER_FEE_BPS (10/5 bps); 7/3 bps is used here, deliberately
// non-round relative to the fixture sizes so the ceiling-rounding on both
// fee legs is actually exercised.

const FEE_TEST_TAKER_FEE_BPS: u64 = 7;
const FEE_TEST_MAKER_FEE_BPS: u64 = 3;
// A realistic BTC(8 decimals)/USDC(6 decimals) book (`realistic_decimals_book`)
// derives `price_scale == 100` (see `full_lifecycle_tests.move`'s header
// comment for the full derivation). `FEE_TEST_PRICE` is deliberately NOT a
// multiple of 100, so `quote_cost = bid_escrow_amount(book, price, size) =
// ceil(price * size / 100)` requires genuine ceiling rounding -- unlike the
// `new_book()` fixture (`price_scale == 1`), where `quote_cost == price *
// size` exactly and rounding never actually happens.
const FEE_TEST_PRICE: u64 = 1_037;
const FEE_TEST_RESTING_SIZE: u64 = 500;
const FEE_TEST_TAKER_SIZE: u64 = 337;
const FEE_TEST_MAX_FILLS: u64 = 1_000_000_000;

// === Fix 2: fee rounding — ceiling division closes the dust-fee exploit ===

const FEE_ROUND_PRICE: u64 = 1_000;
const FEE_ROUND_TAKER_BPS: u64 = 10; // MAX_TAKER_FEE_BPS
const FEE_ROUND_RESTING_SIZE: u64 = 3_000;

// === fill_level_bid/fill_level_ask: detach-mutate-reinsert fill path.
// `price_tree::level_remove_order` + `order::decrease_remaining_size` +
// `price_tree::level_insert_order_front` (or `order::destroy` on full
// drain). These tests exercise that path through the public matching
// entry points and confirm FIFO order and total_size bookkeeping. ===

const FILL_INPLACE_PRICE: u64 = 25_000;

/// LCG-based distinct-key generator (rejects duplicates by linear scan) —
/// used below to synthesize a large set of distinct resting-bid prices.
fun gen_distinct_prices(n: u64, seed: u64, span: u64): vector<u64> {
    let mut out: vector<u64> = vector[];
    let mut s = seed as u128;
    let m = 0xFFFFFFFFFFFFFFFFu128;
    while (out.length() < n) {
        s = ((s * 6364136223846793005) + 1442695040888963407) & m;
        let k = (((s >> 13) as u64) % span);
        if (!out.contains(&k)) { out.push_back(k); };
    };
    out
}

#[test]
fun match_bid_produces_expected_fill_and_fee_amounts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, FEE_TEST_TAKER_FEE_BPS);
    cap.clob_admin_set_maker_fee(&mut book, FEE_TEST_MAKER_FEE_BPS);

    // Resting ask, inserted via the low-level test construction path this
    // suite already uses elsewhere.
    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(FEE_TEST_RESTING_SIZE);
    let ask = order::new<BTC, USDC>(
        order_id, other(), FEE_TEST_RESTING_SIZE, option::some(escrow), option::none(), FEE_TEST_MAKER_FEE_BPS,
    );
    book.insert_resting_order_for_testing(false, FEE_TEST_PRICE, ask, scenario.ctx());

    // Taker fully filled by the larger resting ask, so fill_qty ==
    // FEE_TEST_TAKER_SIZE. On this book, `price_scale == 100` and
    // `FEE_TEST_PRICE = 1_037` is deliberately not a multiple of it, so
    // `quote_cost` itself requires genuine ceiling rounding (unlike
    // `new_book()`, where `quote_cost == price * fill_qty` exactly):
    //   quote_cost = ceil(price * fill_qty / 100) = ceil(1_037 * 337 / 100)
    //              = ceil(3_494.69) = 3_495
    //   taker_fee_base = ceil(fill_qty * taker_bps / 10_000)
    //                  = ceil(337 * 7 / 10_000) = ceil(0.2359) = 1
    //   matched_base   = fill_qty - taker_fee_base = 337 - 1 = 336
    //   maker_fee_quote = ceil(quote_cost * maker_bps / 10_000)
    //                   = ceil(3_495 * 3 / 10_000) = ceil(1.0485) = 2
    //   remaining_budget = payment - quote_cost = 0 (exact full fill)
    // The taker fee is charged once, in aggregate, at the end of the
    // matching loop -- with a single fill this equals the old per-fill
    // amount exactly. The maker fee, by contrast, is now only SET ASIDE in
    // the resting ask's own `fee_reserve_quote` at fill time -- since this
    // resting order is only partially filled here (500 > 337) and
    // therefore never concludes, its maker fee is never actually
    // transferred into the book's fee accumulator; see
    // `resting_maker_order_defers_fee_until_conclusion` below for that
    // transfer actually happening.
    let expected_quote_cost = book.bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE);
    assert!(expected_quote_cost == 3_495, 100);
    let expected_taker_fee_base = 1;
    let expected_matched_base = FEE_TEST_TAKER_SIZE - expected_taker_fee_base;

    let payment = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE), scenario.ctx());
    let (ticket_opt, matched_base, remaining_budget, stopped) = book.place_limit_order_bid(
        payment, FEE_TEST_TAKER_SIZE, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_base_val = matched_base.burn_for_testing();
    let remaining_budget_val = remaining_budget.burn_for_testing();
    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 10);
    let (_, _, _, _, _, _, unmatched_size, _, _, _, taker_fee_amount) = executed[0].order_executed_fields_for_testing();

    assert!(matched_base_val == expected_matched_base, 0);
    assert!(remaining_budget_val == book.bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE) - expected_quote_cost, 1);
    ticket_opt.destroy_none();
    assert!(unmatched_size == 0, 2);
    assert!(stopped == false, 3);
    assert!(taker_fee_amount == expected_taker_fee_base, 4);
    assert!(fee_base_after == expected_taker_fee_base, 5);
    // Maker fee (Quote) not yet collected -- the maker's order still rests.
    assert!(fee_quote_after == 0, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun match_ask_produces_expected_fill_and_fee_amounts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, FEE_TEST_TAKER_FEE_BPS);
    cap.clob_admin_set_maker_fee(&mut book, FEE_TEST_MAKER_FEE_BPS);

    // Resting bid.
    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(book.bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_RESTING_SIZE));
    let bid = order::new<BTC, USDC>(
        order_id, other(), FEE_TEST_RESTING_SIZE, option::none(), option::some(escrow), FEE_TEST_MAKER_FEE_BPS,
    );
    book.insert_resting_order_for_testing(true, FEE_TEST_PRICE, bid, scenario.ctx());

    // Taker fully filled by the larger resting bid, so fill_qty ==
    // FEE_TEST_TAKER_SIZE, and since the resting bid (size 500) still has
    // size left afterward (500 > 337), this fill is TAKER-limited in
    // `fill_level_ask`. Under the telescoping cumulative-proportional-ceiling
    // escrow-charging scheme (see `order::Order.original_size`'s doc comment
    // and `fill_level_ask`'s own comment in `tiny_clob.move`), this is the
    // order's FIRST fill (`cumulative_before = 0`), so the general formula
    // collapses to a plain single-fill ceiling:
    //   total_reserved = bid_escrow_amount(book, 1_037, 500)
    //                   = ceil(518_500 / 100) = 5_185
    //   target_charge  = ceil(total_reserved * fill_qty / original_size)
    //                   = ceil(5_185 * 337 / 500) = ceil(3_494.69) = 3_495
    //   quote_cost     = target_charge - already_charged (0) = 3_495
    //   taker_fee_quote = ceil(quote_cost * taker_bps / 10_000)
    //                   = ceil(3_495 * 7 / 10_000) = ceil(2.4465) = 3
    //   matched_quote   = quote_cost - taker_fee_quote = 3_495 - 3 = 3_492
    //   maker_fee_base = ceil(fill_qty * maker_bps / 10_000)
    //                  = ceil(337 * 3 / 10_000) = ceil(0.1011) = 1
    //   remaining_escrow = escrow_base - fill_qty = 0 (exact full fill)
    // As in `match_bid_produces_expected_fill_and_fee_amounts` above, the
    // taker fee is charged once in aggregate; the maker fee is only set
    // aside in the resting bid's `fee_reserve_base` -- it never concludes
    // here (500 > 337), so it's never actually collected.
    //
    // `expected_quote_cost` (3_495) now EQUALS `bid_escrow_amount`'s own
    // ceiling formula for this single, first fill -- unlike the OLD
    // production scheme's clamped-floor value (a verified under-collection
    // relative to the fair isolated-ceil value the review confirmed this new
    // scheme now delivers instead).
    let expected_quote_cost = 3_495;
    let expected_taker_fee_quote = 3;
    let expected_matched_quote = expected_quote_cost - expected_taker_fee_quote;

    let expected_quote_output = ask_expected_output_for_price(&book, FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE);
    let payment = coin::mint_for_testing<BTC>(FEE_TEST_TAKER_SIZE, scenario.ctx());
    let (ticket_opt, remaining_escrow, matched_quote, stopped) = book.place_limit_order_ask(
        payment, expected_quote_output, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_quote_val = matched_quote.burn_for_testing();
    let remaining_escrow_val = remaining_escrow.burn_for_testing();
    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 10);
    let (_, _, _, _, _, _, unmatched_size, _, _, _, taker_fee_amount) = executed[0].order_executed_fields_for_testing();

    assert!(matched_quote_val == expected_matched_quote, 0);
    assert!(remaining_escrow_val == 0, 1);
    ticket_opt.destroy_none();
    assert!(unmatched_size == 0, 2);
    assert!(stopped == false, 3);
    assert!(taker_fee_amount == expected_taker_fee_quote, 4);
    assert!(fee_quote_after == expected_taker_fee_quote, 5);
    // Maker fee (Base) not yet collected -- the maker's order still rests.
    assert!(fee_base_after == 0, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun fee_amount_ceiling_rounds_up_dust_and_stays_exact_on_exact_division() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, FEE_ROUND_TAKER_BPS);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(FEE_ROUND_RESTING_SIZE);
    let ask = order::new<BTC, USDC>(order_id, other(), FEE_ROUND_RESTING_SIZE, option::some(escrow), option::none(), 0);
    book.insert_resting_order_for_testing(false, FEE_ROUND_PRICE, ask, scenario.ctx());

    // Fill 999 units: ceil(999 * 10 / 10_000) = ceil(0.999) = 1 — under the
    // old floor division this collected 0 fee; the fix now collects 1.
    let payment1 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, FEE_ROUND_PRICE, 999), scenario.ctx());
    let (ticket_opt1, matched_base1, remaining_budget1, _) =
        book.place_limit_order_bid(payment1, 999, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    ticket_opt1.destroy_none();
    let executed1 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed1.length() == 1, 10);
    let (_, _, _, _, _, _, unmatched_size1, _, _, _, _) = executed1[0].order_executed_fields_for_testing();
    assert!(unmatched_size1 == 0, 11);
    let (fee_base_after_1, _) = book.fee_accumulator_balances();
    assert!(fee_base_after_1 == 1, 1);

    // Fill exactly 1000 more units: ceil(1000 * 10 / 10_000) = ceil(1) = 1,
    // an exact-division case — confirms ceiling division doesn't
    // over-round when the division is already exact.
    let payment2 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, FEE_ROUND_PRICE, 1000), scenario.ctx());
    let (ticket_opt2, matched_base2, remaining_budget2, _) =
        book.place_limit_order_bid(payment2, 1000, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    ticket_opt2.destroy_none();
    let executed2 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed2.length() == 2, 12);
    let (_, _, _, _, _, _, unmatched_size2, _, _, _, _) = executed2[1].order_executed_fields_for_testing();
    assert!(unmatched_size2 == 0, 13);
    let (fee_base_after_2, _) = book.fee_accumulator_balances();
    assert!(fee_base_after_2 == 2, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Regression test for the dust-shredding exploit: at 10 bps, a fill of 50
/// units yields `50 * 10 / 10_000 = 0.05`. Under the old floor division this
/// rounded to exactly 0 — a taker could split a large order into many
/// sub-100-unit fills and pay literally zero total fee across all of them.
/// Ceiling division closes that: each such fill now collects 1 unit, so
/// repeating it several times collects a clearly nonzero total.
#[test]
fun repeated_dust_sized_fills_now_collect_nonzero_total_fee() {
    let mut scenario = ts::begin(admin());
    // `new_book()`'s `min_size == 100` would reject this test's 50-unit taker
    // fills outright via `place_limit_order_bid`'s `validate_size` check.
    // Since the whole point of this test is exercising
    // genuinely sub-100 dust fills, the fix is a bespoke book with a smaller
    // `min_size` instead of shrinking `dust_fill_size` — same
    // decimals/precision/exponent/price-scale-seed as `new_book()`
    // (0, 0, 0, 19, 1), just `min_size = 1`.
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 0, 19, 1, scenario.ctx());
    cap.clob_admin_set_taker_fee(&mut book, FEE_ROUND_TAKER_BPS);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(FEE_ROUND_RESTING_SIZE);
    let ask = order::new<BTC, USDC>(order_id, other(), FEE_ROUND_RESTING_SIZE, option::some(escrow), option::none(), 0);
    book.insert_resting_order_for_testing(false, FEE_ROUND_PRICE, ask, scenario.ctx());

    let dust_fill_size = 50;
    let num_fills = 10;
    let mut i = 0;
    while (i < num_fills) {
        let payment = coin::mint_for_testing<USDC>(
            bid_payment_for_price(&book, FEE_ROUND_PRICE, dust_fill_size), scenario.ctx(),
        );
        let (ticket_opt, matched_base, remaining_budget, _) = book.place_limit_order_bid(
            payment, dust_fill_size, 1_000_000, scenario.ctx(),
        );
        matched_base.burn_for_testing();
        remaining_budget.burn_for_testing();
        ticket_opt.destroy_none();
        let executed = event::events_by_type<tiny_clob::OrderExecuted>();
        assert!(executed.length() == i + 1, 102);
        let (_, _, _, _, _, _, unmatched_size, _, _, _, _) = executed[i].order_executed_fields_for_testing();
        assert!(unmatched_size == 0, 103);
        i = i + 1;
    };

    // Under the old floor-division formula, every one of these 10 fills
    // would have collected 0 fee, so the accumulator would still read 0
    // here. Ceiling division collects 1 unit per fill instead.
    let (fee_base_after, _) = book.fee_accumulator_balances();
    assert!(fee_base_after == num_fills, 100);
    assert!(fee_base_after > 0, 101);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Partial fill of the level's front order must leave it AT THE FRONT (no
/// detach/reinsert needed since nothing left the level) — FIFO is preserved
/// trivially. Confirmed the same way the pre-existing FIFO tests below do:
/// drive a second, larger fill and check fill order.
#[test]
fun fill_in_place_partial_fill_preserves_fifo_order() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = book.next_order_id();
    let ask_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), 300, option::some(balance::create_for_testing<BTC>(300)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, FILL_INPLACE_PRICE, ask_a, scenario.ctx());

    let order_id_b = book.next_order_id();
    let ask_b = order::new<BTC, USDC>(
        order_id_b, maker_b(), 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, FILL_INPLACE_PRICE, ask_b, scenario.ctx());

    // Partial fill of A (front order) — must remain in place at the front.
    let payment1 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, FILL_INPLACE_PRICE, 100), scenario.ctx());
    let (ticket_opt1, matched_base1, remaining_budget1, _) =
        book.place_limit_order_bid(payment1, 100, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    ticket_opt1.destroy_none();
    let executed1 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed1.length() == 1, 8);
    let (_, _, _, _, _, _, unmatched_size1, _, _, _, _) = executed1[0].order_executed_fields_for_testing();
    assert!(unmatched_size1 == 0, 9);
    assert!(book.depth_at_price(false, FILL_INPLACE_PRICE) == 400, 1); // 200 (A left) + 200 (B)

    // A large enough fill to drain the rest of A, then start on B: if A had
    // been silently demoted behind B, the first `OrderFilled` event here
    // would be for B instead of A.
    let payment2 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, FILL_INPLACE_PRICE, 250), scenario.ctx());
    let (ticket_opt2, matched_base2, remaining_budget2, _) =
        book.place_limit_order_bid(payment2, 250, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    ticket_opt2.destroy_none();
    let executed2 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed2.length() == 2, 10);
    let (_, _, _, _, _, _, unmatched_size2, _, _, _, _) = executed2[1].order_executed_fields_for_testing();
    assert!(unmatched_size2 == 0, 11);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 3, 3);
    let (id_2, _, _, size_2, _, _) = fills[1].order_filled_fields_for_testing();
    assert!(id_2 == order_id_a, 4); // A drains first (still at the front)
    assert!(size_2 == 200, 5);
    let (id_3, _, _, size_3, _, _) = fills[2].order_filled_fields_for_testing();
    assert!(id_3 == order_id_b, 6);
    assert!(size_3 == 50, 7);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A fill that exactly drains the front order must pop it entirely — the
/// level's depth must reflect its removal, and once the level itself is
/// fully emptied it must disappear from the tree (depth_at_price -> 0).
#[test]
fun fill_in_place_full_drain_removes_order_and_frees_level() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = book.next_order_id();
    let ask = order::new<BTC, USDC>(
        order_id, other(), 150, option::some(balance::create_for_testing<BTC>(150)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, FILL_INPLACE_PRICE, ask, scenario.ctx());
    assert!(book.depth_at_price(false, FILL_INPLACE_PRICE) == 150, 0);

    let payment = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, FILL_INPLACE_PRICE, 150), scenario.ctx());
    let (ticket_opt, matched_base, remaining_budget, _) =
        book.place_limit_order_bid(payment, 150, 1_000_000, scenario.ctx());
    assert!(matched_base.burn_for_testing() == 150, 1);
    assert!(remaining_budget.burn_for_testing() == 0, 2);
    ticket_opt.destroy_none();
    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 6);
    let (_, _, _, _, _, _, unmatched_size, _, _, _, _) = executed[0].order_executed_fields_for_testing();
    assert!(unmatched_size == 0, 7);

    // Level is now empty and must have been removed from the tree entirely.
    assert!(book.depth_at_price(false, FILL_INPLACE_PRICE) == 0, 4);
    assert!(book.best_ask().is_none(), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Strict, per-step regression guard against `total_size` drift: several
/// orders at one level, a mix of partial and full fills, asserting
/// `depth_at_price` (backed by `level_total_size`) exactly matches a
/// brute-force running total after EVERY SINGLE fill, not just at the end.
#[test]
fun fill_in_place_multi_order_sweep_total_size_matches_running_total_per_step() {
    let mut scenario = ts::begin(admin());
    // `new_book()`'s `min_size == 100` would reject this test's smaller sweep
    // steps (50, 30) via `place_limit_order_bid`'s `validate_size` check --
    // a bespoke book with the same decimals/precision/exponent/
    // price-scale-seed as `new_book()` (0, 0, 0, 19, 1) but `min_size = 1`
    // sidesteps that without changing the fill-size sequence under test.
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 0, 19, 1, scenario.ctx());

    let order_id_1 = book.next_order_id();
    let ask_1 = order::new<BTC, USDC>(
        order_id_1, maker_a(), 150, option::some(balance::create_for_testing<BTC>(150)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, FILL_INPLACE_PRICE, ask_1, scenario.ctx());

    let order_id_2 = book.next_order_id();
    let ask_2 = order::new<BTC, USDC>(
        order_id_2, maker_b(), 100, option::some(balance::create_for_testing<BTC>(100)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, FILL_INPLACE_PRICE, ask_2, scenario.ctx());

    let order_id_3 = book.next_order_id();
    let ask_3 = order::new<BTC, USDC>(
        order_id_3, maker_c(), 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, FILL_INPLACE_PRICE, ask_3, scenario.ctx());

    let mut expected_total: u64 = 150 + 100 + 200;
    assert!(book.depth_at_price(false, FILL_INPLACE_PRICE) == expected_total, 0);

    // Mixed partial/full fill sequence: 50 (partial 1), 100 (full-drain 1),
    // 30 (partial 2), 70 (full-drain 2), 50 (partial 3), 150 (full-drain 3,
    // which also empties and removes the level).
    let fill_sizes = vector[50, 100, 30, 70, 50, 150];
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let fill_size = fill_sizes[i];
        let payment = coin::mint_for_testing<USDC>(
            bid_payment_for_price(&book, FILL_INPLACE_PRICE, fill_size), scenario.ctx(),
        );
        let (ticket_opt, matched_base, remaining_budget, _) = book.place_limit_order_bid(
            payment, fill_size, 1_000_000, scenario.ctx(),
        );
        matched_base.burn_for_testing();
        remaining_budget.burn_for_testing();
        ticket_opt.destroy_none();
        let executed = event::events_by_type<tiny_clob::OrderExecuted>();
        assert!(executed.length() == i + 1, 300 + i);
        let (_, _, _, _, _, _, unmatched_size, _, _, _, _) = executed[i].order_executed_fields_for_testing();
        assert!(unmatched_size == 0, 400 + i);

        expected_total = expected_total - fill_size;
        let actual_total = book.depth_at_price(false, FILL_INPLACE_PRICE);
        assert!(actual_total == expected_total, 200 + i);
        i = i + 1;
    };

    assert!(expected_total == 0, 1);
    assert!(book.depth_at_price(false, FILL_INPLACE_PRICE) == 0, 2);
    assert!(book.best_ask().is_none(), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Price-time priority across partial fills ===
//
// A partially-filled maker order is detached from its price level
// (`price_tree::level_remove_order`), mutated off-tree, then reinserted at
// the FRONT of the same level's FIFO queue via
// `price_tree::level_insert_order_front` (`LinkedTable::push_front`) — this
// is what keeps a partially-filled order at the head of the line instead of
// letting it get shuffled behind orders that arrived later. A genuinely new
// order at the same price, by contrast, goes through the ordinary
// `price_tree::level_insert_order` (`push_back`) path and lands at the back.
//
// These four tests exist specifically to guard that distinction: flipping
// `push_front` to `push_back` (or vice versa) in either of those two
// functions must cause at least one of them to fail. Without tests like
// these, that mutation is invisible to the suite — a partially-filled
// maker order silently demoted to the back of its queue is a serious
// real-world correctness bug that produces no build or type error.

#[test]
fun ask_side_partial_fill_keeps_fifo_priority() {
    let price = 50_000;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = book.next_order_id();
    let ask_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), 300, option::some(balance::create_for_testing<BTC>(300)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_a, scenario.ctx());

    let order_id_b = book.next_order_id();
    let ask_b = order::new<BTC, USDC>(
        order_id_b, maker_b(), 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_b, scenario.ctx());

    let order_id_c = book.next_order_id();
    let ask_c = order::new<BTC, USDC>(
        order_id_c, maker_c(), 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_c, scenario.ctx());

    // First taker partially fills A by 100, leaving 200 resting — A must be
    // reinserted at the FRONT of the queue, ahead of B and C.
    scenario.next_tx(taker());
    let payment1 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, 100), scenario.ctx());
    let (ticket_opt1, matched_base1, remaining_budget1, _) =
        book.place_limit_order_bid(payment1, 100, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    ticket_opt1.destroy_none();
    let executed1 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed1.length() == 1, 12);
    let (_, _, _, _, _, _, unmatched_size1, _, _, _, _) = executed1[0].order_executed_fields_for_testing();
    assert!(unmatched_size1 == 0, 13);

    // Second taker buys 500 more: must drain A's remaining 200 first, then
    // B's full 200, then C's partial 100 — in that order.
    let payment2 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, 500), scenario.ctx());
    let (ticket_opt2, matched_base2, remaining_budget2, _) =
        book.place_limit_order_bid(payment2, 500, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    ticket_opt2.destroy_none();
    let executed2 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed2.length() == 2, 14);
    let (_, _, _, _, _, _, unmatched_size2, _, _, _, _) = executed2[1].order_executed_fields_for_testing();
    assert!(unmatched_size2 == 0, 15);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    // 1 event from the first taker + 3 from the second.
    assert!(fills.length() == 4, 2);

    let (id_1, _, _, size_1, maker_1, _) = fills[1].order_filled_fields_for_testing();
    assert!(id_1 == order_id_a, 3);
    assert!(size_1 == 200, 4);
    assert!(maker_1 == maker_a(), 5);

    let (id_2, _, _, size_2, maker_2, _) = fills[2].order_filled_fields_for_testing();
    assert!(id_2 == order_id_b, 6);
    assert!(size_2 == 200, 7);
    assert!(maker_2 == maker_b(), 8);

    let (id_3, _, _, size_3, maker_3, _) = fills[3].order_filled_fields_for_testing();
    assert!(id_3 == order_id_c, 9);
    assert!(size_3 == 100, 10);
    assert!(maker_3 == maker_c(), 11);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun bid_side_partial_fill_keeps_fifo_priority() {
    let price = 50_000;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = book.next_order_id();
    let bid_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), 300, option::none(), option::some(balance::create_for_testing<USDC>(price * 300)), 0,
    );
    book.insert_resting_order_for_testing(true, price, bid_a, scenario.ctx());

    let order_id_b = book.next_order_id();
    let bid_b = order::new<BTC, USDC>(
        order_id_b, maker_b(), 200, option::none(), option::some(balance::create_for_testing<USDC>(price * 200)), 0,
    );
    book.insert_resting_order_for_testing(true, price, bid_b, scenario.ctx());

    let order_id_c = book.next_order_id();
    let bid_c = order::new<BTC, USDC>(
        order_id_c, maker_c(), 200, option::none(), option::some(balance::create_for_testing<USDC>(price * 200)), 0,
    );
    book.insert_resting_order_for_testing(true, price, bid_c, scenario.ctx());

    // First taker partially fills A by 100, leaving 200 resting — A must be
    // reinserted at the FRONT of the queue, ahead of B and C.
    scenario.next_tx(taker());
    let expected_quote_output1 = ask_expected_output_for_price(&book, price, 100);
    let payment1 = coin::mint_for_testing<BTC>(100, scenario.ctx());
    let (ticket_opt1, remaining_escrow1, matched_quote1, _) =
        book.place_limit_order_ask(payment1, expected_quote_output1, 1_000_000, scenario.ctx());
    matched_quote1.burn_for_testing();
    remaining_escrow1.burn_for_testing();
    ticket_opt1.destroy_none();
    let executed1 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed1.length() == 1, 12);
    let (_, _, _, _, _, _, unmatched_size1, _, _, _, _) = executed1[0].order_executed_fields_for_testing();
    assert!(unmatched_size1 == 0, 13);

    // Second taker sells 500 more: must drain A's remaining 200 first, then
    // B's full 200, then C's partial 100 — in that order.
    let expected_quote_output2 = ask_expected_output_for_price(&book, price, 500);
    let payment2 = coin::mint_for_testing<BTC>(500, scenario.ctx());
    let (ticket_opt2, remaining_escrow2, matched_quote2, _) =
        book.place_limit_order_ask(payment2, expected_quote_output2, 1_000_000, scenario.ctx());
    matched_quote2.burn_for_testing();
    remaining_escrow2.burn_for_testing();
    ticket_opt2.destroy_none();
    let executed2 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed2.length() == 2, 14);
    let (_, _, _, _, _, _, unmatched_size2, _, _, _, _) = executed2[1].order_executed_fields_for_testing();
    assert!(unmatched_size2 == 0, 15);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    // 1 event from the first taker + 3 from the second.
    assert!(fills.length() == 4, 2);

    let (id_1, _, _, size_1, maker_1, _) = fills[1].order_filled_fields_for_testing();
    assert!(id_1 == order_id_a, 3);
    assert!(size_1 == 200, 4);
    assert!(maker_1 == maker_a(), 5);

    let (id_2, _, _, size_2, maker_2, _) = fills[2].order_filled_fields_for_testing();
    assert!(id_2 == order_id_b, 6);
    assert!(size_2 == 200, 7);
    assert!(maker_2 == maker_b(), 8);

    let (id_3, _, _, size_3, maker_3, _) = fills[3].order_filled_fields_for_testing();
    assert!(id_3 == order_id_c, 9);
    assert!(size_3 == 100, 10);
    assert!(maker_3 == maker_c(), 11);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun repeated_partial_fills_of_head_never_reorder() {
    let price = 50_000;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = book.next_order_id();
    let ask_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), 500, option::some(balance::create_for_testing<BTC>(500)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_a, scenario.ctx());

    let order_id_b = book.next_order_id();
    let ask_b = order::new<BTC, USDC>(
        order_id_b, maker_b(), 100, option::some(balance::create_for_testing<BTC>(100)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_b, scenario.ctx());

    scenario.next_tx(taker());
    // Five separate 100-unit takers, each landing on A alone (500 total),
    // proving A stays at the front of the queue across five consecutive
    // partial-fill/reinsert cycles rather than drifting behind B.
    let mut i = 0;
    while (i < 5) {
        let payment = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, 100), scenario.ctx());
        let (ticket_opt, matched_base, remaining_budget, _) =
            book.place_limit_order_bid(payment, 100, 1_000_000, scenario.ctx());
        matched_base.burn_for_testing();
        remaining_budget.burn_for_testing();
        ticket_opt.destroy_none();
        let executed = event::events_by_type<tiny_clob::OrderExecuted>();
        assert!(executed.length() == i + 1, 70 + i);
        let (_, _, _, _, _, _, unmatched_size, _, _, _, _) = executed[i].order_executed_fields_for_testing();
        assert!(unmatched_size == 0, 80 + i);
        assert!(book.depth_at_price(false, price) == 500 - (i + 1) * 100 + 100, 20 + i);
        i = i + 1;
    };

    // A is now fully drained, so the sixth fill must land on B.
    let payment6 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, 100), scenario.ctx());
    let (ticket_opt6, matched_base6, remaining_budget6, _) =
        book.place_limit_order_bid(payment6, 100, 1_000_000, scenario.ctx());
    matched_base6.burn_for_testing();
    remaining_budget6.burn_for_testing();
    ticket_opt6.destroy_none();
    let executed6 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed6.length() == 6, 90);
    let (_, _, _, _, _, _, unmatched_size6, _, _, _, _) = executed6[5].order_executed_fields_for_testing();
    assert!(unmatched_size6 == 0, 91);
    assert!(book.depth_at_price(false, price) == 0, 11);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 6, 12);

    let mut j = 0;
    while (j < 5) {
        let (fid, _, _, fsize, fmaker, _) = fills[j].order_filled_fields_for_testing();
        assert!(fid == order_id_a, 30 + j);
        assert!(fsize == 100, 40 + j);
        assert!(fmaker == maker_a(), 50 + j);
        j = j + 1;
    };

    let (id_6, _, _, size_6, maker_6, _) = fills[5].order_filled_fields_for_testing();
    assert!(id_6 == order_id_b, 60);
    assert!(size_6 == 100, 61);
    assert!(maker_6 == maker_b(), 62);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_order_at_same_price_goes_behind_partially_filled_one() {
    let price = 50_000;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = book.next_order_id();
    let ask_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), 300, option::some(balance::create_for_testing<BTC>(300)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_a, scenario.ctx());

    // Partially fill A by 100, leaving 200 resting, reinserted at the front.
    scenario.next_tx(taker());
    let payment1 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, 100), scenario.ctx());
    let (ticket_opt1, matched_base1, remaining_budget1, _) =
        book.place_limit_order_bid(payment1, 100, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    ticket_opt1.destroy_none();
    let executed1 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed1.length() == 1, 7);
    let (_, _, _, _, _, _, unmatched_size1, _, _, _, _) = executed1[0].order_executed_fields_for_testing();
    assert!(unmatched_size1 == 0, 8);

    // A brand-new maker rests at the same price via the ordinary placement
    // path (`level_insert_order`, appends to the back) — it must not jump
    // ahead of A's already-reinserted 200-unit remainder.
    scenario.next_tx(maker_b());
    let ticket_b = rest_ask(&mut book, price, 300, 10, scenario.ctx());
    let order_id_b = ticket_b.ticket_order_id();

    // `event::events_by_type` only sees events emitted in the *current*
    // transaction (test_scenario clears its recorded events on every
    // `next_tx`), so the final sweep's own two `OrderFilled` events are
    // freshly numbered [0, 1] here, independent of the earlier partial fill.
    scenario.next_tx(taker());
    let payment2 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, 500), scenario.ctx());
    let (ticket_opt2, matched_base2, remaining_budget2, _) =
        book.place_limit_order_bid(payment2, 500, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    ticket_opt2.destroy_none();
    let executed2 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed2.length() == 1, 9);
    let (_, _, _, _, _, _, unmatched_size2, _, _, _, _) = executed2[0].order_executed_fields_for_testing();
    assert!(unmatched_size2 == 0, 10);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 2, 2);

    let (id_1, _, _, size_1, maker_1, _) = fills[0].order_filled_fields_for_testing();
    assert!(id_1 == order_id_a, 3);
    assert!(size_1 == 200, 4);
    assert!(maker_1 == maker_a(), 5);

    let (id_2, _, _, size_2, maker_2, _) = fills[1].order_filled_fields_for_testing();
    assert!(id_2 == order_id_b, 6);
    assert!(size_2 == 300, 7);
    assert!(maker_2 == maker_b(), 8);

    unit_test::destroy(ticket_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun force_cancel_refunds_owner_not_caller() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    // Insert a resting bid directly via the `#[test_only]`
    // `insert_resting_order_for_testing` wrapper, bypassing the placement
    // functions entirely.
    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, other(), size, option::none(), option::some(escrow), 0);
    book.insert_resting_order_for_testing(true, price, order, scenario.ctx());

    cap.clob_admin_cancel_order(&mut book, true, price, order_id, scenario.ctx());

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 0);
    let (ev_order_id, ev_book, ev_trader) = cancelled_events[0].order_cancelled_fields_for_testing();
    assert!(ev_order_id == order_id, 1);
    assert!(ev_book == book_id, 2);
    assert!(ev_trader == other(), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Cancelling the MIDDLE order of a 3-deep FIFO queue exercises the
/// `LinkedTable` relink path in `price_tree`'s per-level order removal: the
/// removed node's own predecessor/successor links must be spliced together,
/// as opposed to head-removal (already covered by
/// `force_cancel_refunds_owner_not_caller` above), which only has to move
/// the level's head pointer. An earlier audit flagged this relink path as
/// under-covered.
///
/// Rests three asks A (300), B (200), C (200) at one price level, then
/// cancels B via the real owner-driven `cancel_order` entry point (using
/// `new_ticket_for_testing` to mint a ticket for the order seeded through
/// `insert_resting_order_for_testing`, since that seeding path returns no
/// ticket of its own) -- this is chosen over `clob_admin_cancel_order`
/// because it is the actual public path an ordinary trader uses, and
/// `force_cancel_refunds_owner_not_caller` above already covers the admin
/// path once (for head-removal). Confirms: B's escrow (200 base, its full
/// resting size) is refunded; the level's depth drops by exactly B's size;
/// B is no longer found by `resting_order_escrow`; and -- the actual point
/// of this test -- A and C are unaffected and still fill in FIFO order (A
/// before C) when a taker subsequently crosses the level, with B never
/// appearing in the resulting `OrderFilled` events.
#[test]
fun cancelling_middle_of_fifo_queue_preserves_neighbours_order() {
    let price = 50_000;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    let order_id_a = book.next_order_id();
    let ask_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), 300, option::some(balance::create_for_testing<BTC>(300)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_a, scenario.ctx());

    let order_id_b = book.next_order_id();
    let ask_b = order::new<BTC, USDC>(
        order_id_b, maker_b(), 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_b, scenario.ctx());

    let order_id_c = book.next_order_id();
    let ask_c = order::new<BTC, USDC>(
        order_id_c, maker_c(), 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_c, scenario.ctx());

    assert!(book.depth_at_price(false, price) == 700, 0);

    // Cancel B -- the middle order -- via the real owner-driven entry point.
    scenario.next_tx(maker_b());
    let ticket_b = tiny_clob::new_ticket_for_testing(order_id_b, book_id, false, price);
    let (refund_base, refund_quote) = book.cancel_order(ticket_b, scenario.ctx());
    assert!(refund_base.value() == 200, 1);
    assert!(refund_quote.value() == 0, 2);
    refund_base.burn_for_testing();
    refund_quote.burn_for_testing();

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 3);
    let (ev_order_id, ev_book, ev_trader) = cancelled_events[0].order_cancelled_fields_for_testing();
    assert!(ev_order_id == order_id_b, 4);
    assert!(ev_book == book_id, 5);
    assert!(ev_trader == maker_b(), 6);

    // Depth excludes B's size; B itself is gone; A and C are untouched.
    assert!(book.depth_at_price(false, price) == 500, 7);
    assert!(book.resting_order_escrow(false, price, order_id_b).is_none(), 8);
    let (escrow_a, remaining_a) =
        book.resting_order_escrow(false, price, order_id_a).destroy_some().resting_order_escrow_fields();
    assert!(escrow_a == 300 && remaining_a == 300, 9);
    let (escrow_c, remaining_c) =
        book.resting_order_escrow(false, price, order_id_c).destroy_some().resting_order_escrow_fields();
    assert!(escrow_c == 200 && remaining_c == 200, 10);

    // A taker crossing the level now must fill A fully, then C fully -- B's
    // removal must not have broken the A<->C link or corrupted either
    // order's own size/state.
    scenario.next_tx(taker());
    let payment = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, 500), scenario.ctx());
    let (ticket_opt, matched_base, remaining_budget, _) =
        book.place_limit_order_bid(payment, 500, 1_000_000, scenario.ctx());
    matched_base.burn_for_testing();
    remaining_budget.burn_for_testing();
    ticket_opt.destroy_none();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 11);
    let (_, _, _, _, _, _, unmatched_size, _, _, _, _) = executed[0].order_executed_fields_for_testing();
    assert!(unmatched_size == 0, 12);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 2, 13);

    let (fid_1, _, _, fsize_1, fmaker_1, _) = fills[0].order_filled_fields_for_testing();
    assert!(fid_1 == order_id_a, 14);
    assert!(fsize_1 == 300, 15);
    assert!(fmaker_1 == maker_a(), 16);

    let (fid_2, _, _, fsize_2, fmaker_2, _) = fills[1].order_filled_fields_for_testing();
    assert!(fid_2 == order_id_c, 17);
    assert!(fsize_2 == 200, 18);
    assert!(fmaker_2 == maker_c(), 19);

    assert!(book.depth_at_price(false, price) == 0, 20);
    assert!(book.resting_order_escrow(false, price, order_id_a).is_none(), 21);
    assert!(book.resting_order_escrow(false, price, order_id_c).is_none(), 22);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Rests orders at 60 distinct bid prices through the real
/// `insert_resting_order` path (via `insert_resting_order_for_testing`) and
/// checks `depth_at_price`/`best_bid` after every single insertion. None of
/// the other book-level tests in this file build a price tree deep enough
/// for `price_tree::insert`'s crit-bit routing to be observable
/// at the book level, so this is the only test that would catch a
/// structural corruption on that hot path.
#[test]
fun many_price_levels_depth_and_best_bid_correct_after_each_insertion() {
    let size = 7u64;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let prices = gen_distinct_prices(60, 20250827, 4_000_000);
    let mut i = 0;
    let mut best_bid_expected = 0u64;
    while (i < prices.length()) {
        let price = prices[i] + 1; // avoid price 0
        let order_id = book.next_order_id();
        let escrow = balance::create_for_testing<USDC>(price * size);
        let order = order::new<BTC, USDC>(order_id, admin(), size, option::none(), option::some(escrow), 0);
        book.insert_resting_order_for_testing(true, price, order, scenario.ctx());
        if (price > best_bid_expected) { best_bid_expected = price; };

        // Every previously rested level must still report exactly its depth.
        let mut j = 0;
        while (j <= i) {
            let q = prices[j] + 1;
            // `depth_at_price` for a bid is Quote-denominated: each order
            // here was constructed with an escrow of exactly `q * size`
            // (see `escrow` above), which is also this book's `price_scale
            // == 1` fixture's exact `bid_escrow_amount(q, size)` -- not the
            // Base `size` itself.
            assert!(book.depth_at_price(true, q) == q * size, 0);
            j = j + 1;
        };
        assert!(book.best_bid().destroy_some() == best_bid_expected, 1);
        assert!(book.bids_size_for_testing() == i + 1, 2);
        i = i + 1;
    };

    // An absent price reports zero depth (no misrouting into a neighbour
    // level).
    assert!(book.depth_at_price(true, 4_000_002) == 0, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Coverage gap #1: `fill_level_ask` sweeping >=2 resting bids in one
// call, with genuine rounding on BOTH bids ===
//
// Every multi-bid-in-one-call test above uses `new_book` (`price_scale ==
// 1`), where `bid_escrow_amount`'s ceiling division is always exact and
// never actually rounds anything. That leaves the interaction between
// `fill_level_ask`'s per-order telescoping charge (`target_charge =
// ceil(total_reserved * cumulative_after / original_size); quote_cost =
// target_charge - already_charged`, see the doc comment on
// `fill_level_ask` in `sources/tiny_clob.move`) and a genuinely-rounding
// book untested when TWO distinct resting orders are swept within the same
// call: `cumulative_before`/`already_charged` are read fresh, per-order,
// from `head_key`'s own maker order on every loop iteration, but nothing in
// this suite previously exercised that with real fractional
// ceil-division on more than one order per call -- a regression that
// smeared one order's `total_reserved`/`original_size`/`already_charged`
// into the next order's charge computation would not necessarily be caught
// by a single-order test, or by a `price_scale == 1` multi-order test where
// rounding never bites regardless.
#[test]
fun fill_level_ask_sweep_of_two_rounding_bids_computes_quote_cost_independently_per_order() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);
    let price = shortfall_price(); // 5; shortfall_book derives price_scale == 10.

    // Bid A: size 3. `bid_escrow_amount(5, 3) = ceil(15/10) = 2` -- genuine
    // rounding (15 is not a multiple of price_scale 10), and `2` is itself
    // not an exact multiple of price_scale either.
    let size_a = 3;
    let escrow_a = book.bid_escrow_amount(price, size_a);
    assert!(escrow_a == 2, 900);
    let order_id_a = book.next_order_id();
    let bid_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), size_a, option::none(), option::some(balance::create_for_testing<USDC>(escrow_a)), 0,
    );
    book.insert_resting_order_for_testing(true, price, bid_a, scenario.ctx());

    // Bid B: size 7. `bid_escrow_amount(5, 7) = ceil(35/10) = 4` -- also
    // genuine rounding, also not an exact multiple of price_scale.
    let size_b = 7;
    let escrow_b = book.bid_escrow_amount(price, size_b);
    assert!(escrow_b == 4, 901);
    let order_id_b = book.next_order_id();
    let bid_b = order::new<BTC, USDC>(
        order_id_b, maker_b(), size_b, option::none(), option::some(balance::create_for_testing<USDC>(escrow_b)), 0,
    );
    book.insert_resting_order_for_testing(true, price, bid_b, scenario.ctx());

    assert!(book.depth_at_price(true, price) == escrow_a + escrow_b, 0);

    // A single ask taker of size 7 sweeps BOTH bids in one
    // `place_limit_order_ask` call: fully drains A (3), then partially fills
    // B (4 of its 7, leaving 3 resting).
    let taker_size = size_a + 4;
    let expected_quote_output = ask_expected_output_for_price(&book, price, taker_size);
    let payment = coin::mint_for_testing<BTC>(taker_size, scenario.ctx());
    let (ticket_opt, remaining_escrow, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output, 1_000_000, scenario.ctx());

    assert!(stopped == false, 1);
    ticket_opt.destroy_none();
    assert!(remaining_escrow.burn_for_testing() == 0, 2);

    // Independent hand computation of EACH bid's own `quote_cost`, from
    // that order's OWN `total_reserved`/`original_size` only -- never
    // borrowing the other order's numbers -- exactly the telescoping
    // formula in `fill_level_ask`:
    //
    //   target_charge = ceil(total_reserved * cumulative_after / original_size)
    //   quote_cost    = target_charge - already_charged
    //
    // Bid A: single fill fully drains it (cumulative_before = 0,
    // cumulative_after = 3 = original_size):
    //   target_charge = ceil(2 * 3 / 3) = 2; already_charged = 0.
    //   quote_cost_a = 2.
    let expected_quote_cost_a = 2;
    // Bid B: single fill only partially fills it (cumulative_before = 0,
    // cumulative_after = 4, original_size = 7 -- a genuine, non-integer
    // ratio):
    //   target_charge = ceil(4 * 4 / 7) = ceil(16/7) = ceil(2.2857...) = 3;
    //   already_charged = 0 (B's first and only fill in this call).
    //   quote_cost_b = 3.
    let expected_quote_cost_b = 3;

    let expected_matched_quote = expected_quote_cost_a + expected_quote_cost_b;
    assert!(matched_quote.burn_for_testing() == expected_matched_quote, 3);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 2, 4);

    let (fid_a, _, _, fsize_a, fmaker_a, _) = fills[0].order_filled_fields_for_testing();
    let (fside_a, fquote_a) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(fid_a == order_id_a, 5);
    assert!(fsize_a == size_a, 6);
    assert!(fmaker_a == maker_a(), 7);
    assert!(fside_a == true, 8);
    assert!(fquote_a == expected_quote_cost_a, 9);

    let (fid_b, _, _, fsize_b, fmaker_b, _) = fills[1].order_filled_fields_for_testing();
    let (fside_b, fquote_b) = fills[1].order_filled_side_and_quote_fields_for_testing();
    assert!(fid_b == order_id_b, 10);
    assert!(fsize_b == 4, 11);
    assert!(fmaker_b == maker_b(), 12);
    assert!(fside_b == true, 13);
    assert!(fquote_b == expected_quote_cost_b, 14);

    // A is fully drained and gone; B still rests with exactly `escrow_b -
    // quote_cost_b` left in escrow (both `escrow` and `remaining_size` are
    // the same Quote-denominated value for a bid -- see
    // `resting_order_escrow`'s doc comment).
    assert!(book.resting_order_escrow(true, price, order_id_a).is_none(), 15);
    let (b_escrow_after, b_remaining_after) =
        book.resting_order_escrow(true, price, order_id_b).destroy_some().resting_order_escrow_fields();
    assert!(b_escrow_after == escrow_b - expected_quote_cost_b, 16);
    assert!(b_remaining_after == escrow_b - expected_quote_cost_b, 17);
    assert!(book.depth_at_price(true, price) == escrow_b - expected_quote_cost_b, 18);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Coverage gap #2: a `stopped_on_max_fills_while_crossing` sweep
// resumed by a second call ===
//
// `place_limit_order_bid`'s `should_rest` gate is forced `false` whenever
// `stopped_on_max_fills_while_crossing` is `true` -- a `max_fills`-capped
// partial sweep never rests its own leftover; the caller gets the unmatched
// escrow back and is expected to resubmit it itself. No existing test in
// this suite actually drives that resubmission and verifies the two calls'
// combined effect end-to-end (total matched, no double-counting across the
// call boundary, and final book depth) -- this test is the permanent
// version of that check.
#[test]
fun stopped_on_max_fills_sweep_is_correctly_resumed_by_a_second_call() {
    let price = 50_000;
    let mut scenario = ts::begin(admin());
    // `new_book()`'s `min_size == 100` would reject this test's 50-unit
    // second-call resubmission via `place_limit_order_bid`'s `validate_size`
    // check -- a bespoke book with the same decimals/precision/exponent/
    // price-scale-seed as `new_book()` (0, 0, 0, 19, 1) but `min_size = 1`
    // sidesteps that without changing anything else under test.
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 0, 19, 1, scenario.ctx());

    let order_id_a = book.next_order_id();
    let ask_a = order::new<BTC, USDC>(
        order_id_a, maker_a(), 100, option::some(balance::create_for_testing<BTC>(100)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_a, scenario.ctx());

    let order_id_b = book.next_order_id();
    let ask_b = order::new<BTC, USDC>(
        order_id_b, maker_b(), 100, option::some(balance::create_for_testing<BTC>(100)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_b, scenario.ctx());

    let order_id_c = book.next_order_id();
    let ask_c = order::new<BTC, USDC>(
        order_id_c, maker_c(), 100, option::some(balance::create_for_testing<BTC>(100)), option::none(), 0,
    );
    book.insert_resting_order_for_testing(false, price, ask_c, scenario.ctx());

    assert!(book.depth_at_price(false, price) == 300, 0);

    // First call: taker wants 250 total, but `max_fills == 2` caps the sweep
    // right as C would start (A and B each consume one of the two allowed
    // fills) -- must stop with a 200-unit partial match, and NOT rest the
    // 50-unit leftover (`should_rest` is forced false by `stopped == true`).
    let taker_total = 250;
    let first_call_size = taker_total;
    let payment1 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, first_call_size), scenario.ctx());
    let (ticket_opt1, matched_base1, remaining_budget1, stopped1) =
        book.place_limit_order_bid(payment1, first_call_size, 2, scenario.ctx());

    let matched_base1_val = matched_base1.burn_for_testing();
    let remaining_budget1_val = remaining_budget1.burn_for_testing();
    ticket_opt1.destroy_none();

    assert!(stopped1 == true, 1);
    assert!(matched_base1_val == 200, 2); // A (100) + B (100)
    // `new_book`'s `price_scale == 1` makes every quote-cost division exact
    // (floor == ceil), so the exact quote cost for 200 matched units is
    // simply `price * 200`; the untouched remainder of the escrow comes
    // back whole.
    let expected_quote_cost1 = price * 200;
    assert!(
        remaining_budget1_val == bid_payment_for_price(&book, price, first_call_size) - expected_quote_cost1,
        3,
    );

    let executed1 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed1.length() == 1, 4);
    let (_, _, _, _, _, requested_size1, unmatched_size1, rested_size1, rested_order_id1, exec_stopped1, _) =
        executed1[0].order_executed_fields_for_testing();
    assert!(requested_size1 == first_call_size, 5);
    assert!(unmatched_size1 == first_call_size - 200, 6); // 50
    assert!(rested_size1 == 0, 7);
    assert!(rested_order_id1.is_none(), 8);
    assert!(exec_stopped1 == true, 9);

    // Only A and B were touched; C is completely untouched by the first
    // call.
    assert!(book.depth_at_price(false, price) == 100, 10);
    assert!(book.resting_order_escrow(false, price, order_id_a).is_none(), 11);
    assert!(book.resting_order_escrow(false, price, order_id_b).is_none(), 12);
    let (c_escrow_before, c_remaining_before) =
        book.resting_order_escrow(false, price, order_id_c).destroy_some().resting_order_escrow_fields();
    assert!(c_escrow_before == 100 && c_remaining_before == 100, 13);

    // Second call: same taker, resubmits exactly the unmatched remainder
    // (50) with no `max_fills` cap this time -- must finish the sweep
    // against C alone.
    let second_call_size = unmatched_size1;
    let payment2 = coin::mint_for_testing<USDC>(bid_payment_for_price(&book, price, second_call_size), scenario.ctx());
    let (ticket_opt2, matched_base2, remaining_budget2, stopped2) =
        book.place_limit_order_bid(payment2, second_call_size, 1_000_000, scenario.ctx());

    let matched_base2_val = matched_base2.burn_for_testing();
    let remaining_budget2_val = remaining_budget2.burn_for_testing();
    ticket_opt2.destroy_none();

    assert!(stopped2 == false, 14);
    assert!(matched_base2_val == second_call_size, 15); // fully filled by C
    assert!(remaining_budget2_val == 0, 16);

    let executed2 = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed2.length() == 2, 17);
    let (_, _, _, _, _, requested_size2, unmatched_size2, rested_size2, rested_order_id2, exec_stopped2, _) =
        executed2[1].order_executed_fields_for_testing();
    assert!(requested_size2 == second_call_size, 18);
    assert!(unmatched_size2 == 0, 19);
    assert!(rested_size2 == 0, 20);
    assert!(rested_order_id2.is_none(), 21);
    assert!(exec_stopped2 == false, 22);

    // End-to-end across the two-call boundary: the sum of matched amounts
    // equals the taker's originally-intended total, exactly -- no
    // double-counting or missed fills.
    assert!(matched_base1_val + matched_base2_val == taker_total, 23);

    // Final book depth correctly reflects C's own leftover only (100 - 50);
    // A and B remain gone.
    assert!(book.depth_at_price(false, price) == 100 - second_call_size, 24);
    let (c_escrow_after, c_remaining_after) =
        book.resting_order_escrow(false, price, order_id_c).destroy_some().resting_order_escrow_fields();
    assert!(c_escrow_after == 100 - second_call_size, 25);
    assert!(c_remaining_after == 100 - second_call_size, 26);

    // Exactly one `OrderFilled` per maker across the WHOLE two-call
    // sequence, each with its correct size -- no double-counting.
    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 3, 27);
    let (fid_a, _, _, fsize_a, fmaker_a, _) = fills[0].order_filled_fields_for_testing();
    assert!(fid_a == order_id_a && fsize_a == 100 && fmaker_a == maker_a(), 28);
    let (fid_b, _, _, fsize_b, fmaker_b, _) = fills[1].order_filled_fields_for_testing();
    assert!(fid_b == order_id_b && fsize_b == 100 && fmaker_b == maker_b(), 29);
    let (fid_c, _, _, fsize_c, fmaker_c, _) = fills[2].order_filled_fields_for_testing();
    assert!(fid_c == order_id_c && fsize_c == second_call_size && fmaker_c == maker_c(), 30);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

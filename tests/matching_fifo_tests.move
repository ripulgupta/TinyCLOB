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
};


// Regression tests for the private `match_bid`/`match_ask` functions,
// invoked directly via the `match_bid_for_testing`/`match_ask_for_testing`
// test-only accessors. Every expected value below is computed
// independently from the known price/size/fee-rate inputs using the fee
// formula in `sources/tiny_clob.move` (`fee_amount`: `ceil(receive_amount *
// rate_bps / 10_000)`) — not by comparing two invocations of the
// same function. Fee rates are bounded by MAX_TAKER_FEE_BPS/
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
    //                   = ceil(1_832 * 3 / 10_000) = ceil(0.5496) = 1
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

    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE), scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, stopped, taker_fee_amount) = book.match_bid_for_testing(
        option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_base_val = matched_base.burn_for_testing();
    let remaining_budget_val = remaining_budget.burn_for_testing();
    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();

    assert!(matched_base_val == expected_matched_base, 0);
    assert!(remaining_budget_val == book.bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE) - expected_quote_cost, 1);
    assert!(remaining_size == 0, 2);
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

    let payment = coin::mint_for_testing<BTC>(FEE_TEST_TAKER_SIZE, scenario.ctx());
    let (matched_quote, remaining_escrow, remaining_size, stopped, taker_fee_amount) = book.match_ask_for_testing(
        option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_quote_val = matched_quote.burn_for_testing();
    let remaining_escrow_val = remaining_escrow.burn_for_testing();
    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();

    assert!(matched_quote_val == expected_matched_quote, 0);
    assert!(remaining_escrow_val == 0, 1);
    assert!(remaining_size == 0, 2);
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
    let payment1 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(FEE_ROUND_PRICE, 999), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _, _) =
        book.match_bid_for_testing(option::some(FEE_ROUND_PRICE), 999, payment1, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    assert!(remaining_size1 == 0, 0);
    let (fee_base_after_1, _) = book.fee_accumulator_balances();
    assert!(fee_base_after_1 == 1, 1);

    // Fill exactly 1000 more units: ceil(1000 * 10 / 10_000) = ceil(1) = 1,
    // an exact-division case — confirms ceiling division doesn't
    // over-round when the division is already exact.
    let payment2 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(FEE_ROUND_PRICE, 1000), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _, _) =
        book.match_bid_for_testing(option::some(FEE_ROUND_PRICE), 1000, payment2, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    assert!(remaining_size2 == 0, 2);
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
    let (mut book, cap) = new_book(&mut scenario);
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
            book.bid_escrow_amount(FEE_ROUND_PRICE, dust_fill_size), scenario.ctx(),
        );
        let (matched_base, remaining_budget, remaining_size, _, _) = book.match_bid_for_testing(
            option::some(FEE_ROUND_PRICE), dust_fill_size, payment, 1_000_000, scenario.ctx(),
        );
        matched_base.burn_for_testing();
        remaining_budget.burn_for_testing();
        assert!(remaining_size == 0, i);
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
    let payment1 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(FILL_INPLACE_PRICE, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _, _) =
        book.match_bid_for_testing(option::some(FILL_INPLACE_PRICE), 100, payment1, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    assert!(remaining_size1 == 0, 0);
    assert!(book.depth_at_price(false, FILL_INPLACE_PRICE) == 400, 1); // 200 (A left) + 200 (B)

    // A large enough fill to drain the rest of A, then start on B: if A had
    // been silently demoted behind B, the first `OrderFilled` event here
    // would be for B instead of A.
    let payment2 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(FILL_INPLACE_PRICE, 250), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _, _) =
        book.match_bid_for_testing(option::some(FILL_INPLACE_PRICE), 250, payment2, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    assert!(remaining_size2 == 0, 2);

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

    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(FILL_INPLACE_PRICE, 150), scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, _, _) =
        book.match_bid_for_testing(option::some(FILL_INPLACE_PRICE), 150, payment, 1_000_000, scenario.ctx());
    assert!(matched_base.burn_for_testing() == 150, 1);
    assert!(remaining_budget.burn_for_testing() == 0, 2);
    assert!(remaining_size == 0, 3);

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
    let (mut book, cap) = new_book(&mut scenario);

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
            book.bid_escrow_amount(FILL_INPLACE_PRICE, fill_size), scenario.ctx(),
        );
        let (matched_base, remaining_budget, remaining_size, _, _) = book.match_bid_for_testing(
            option::some(FILL_INPLACE_PRICE), fill_size, payment, 1_000_000, scenario.ctx(),
        );
        matched_base.burn_for_testing();
        remaining_budget.burn_for_testing();
        assert!(remaining_size == 0, 100 + i);

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
    let payment1 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(price, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _, _) =
        book.match_bid_for_testing(option::some(price), 100, payment1, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    assert!(remaining_size1 == 0, 0);

    // Second taker buys 500 more: must drain A's remaining 200 first, then
    // B's full 200, then C's partial 100 — in that order.
    let payment2 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(price, 500), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _, _) =
        book.match_bid_for_testing(option::some(price), 500, payment2, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    assert!(remaining_size2 == 0, 1);

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
    let payment1 = coin::mint_for_testing<BTC>(100, scenario.ctx());
    let (matched_quote1, remaining_escrow1, remaining_size1, _, _) =
        book.match_ask_for_testing(option::some(price), 100, payment1, 1_000_000, scenario.ctx());
    matched_quote1.burn_for_testing();
    remaining_escrow1.burn_for_testing();
    assert!(remaining_size1 == 0, 0);

    // Second taker sells 500 more: must drain A's remaining 200 first, then
    // B's full 200, then C's partial 100 — in that order.
    let payment2 = coin::mint_for_testing<BTC>(500, scenario.ctx());
    let (matched_quote2, remaining_escrow2, remaining_size2, _, _) =
        book.match_ask_for_testing(option::some(price), 500, payment2, 1_000_000, scenario.ctx());
    matched_quote2.burn_for_testing();
    remaining_escrow2.burn_for_testing();
    assert!(remaining_size2 == 0, 1);

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
        let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(price, 100), scenario.ctx());
        let (matched_base, remaining_budget, remaining_size, _, _) =
            book.match_bid_for_testing(option::some(price), 100, payment, 1_000_000, scenario.ctx());
        matched_base.burn_for_testing();
        remaining_budget.burn_for_testing();
        assert!(remaining_size == 0, i);
        assert!(book.depth_at_price(false, price) == 500 - (i + 1) * 100 + 100, 20 + i);
        i = i + 1;
    };

    // A is now fully drained, so the sixth fill must land on B.
    let payment6 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(price, 100), scenario.ctx());
    let (matched_base6, remaining_budget6, remaining_size6, _, _) =
        book.match_bid_for_testing(option::some(price), 100, payment6, 1_000_000, scenario.ctx());
    matched_base6.burn_for_testing();
    remaining_budget6.burn_for_testing();
    assert!(remaining_size6 == 0, 10);
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
    let payment1 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(price, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _, _) =
        book.match_bid_for_testing(option::some(price), 100, payment1, 1_000_000, scenario.ctx());
    matched_base1.burn_for_testing();
    remaining_budget1.burn_for_testing();
    assert!(remaining_size1 == 0, 0);

    // A brand-new maker rests at the same price via the ordinary placement
    // path (`level_insert_order`, appends to the back) — it must not jump
    // ahead of A's already-reinserted 200-unit remainder.
    scenario.next_tx(maker_b());
    let ticket_b = rest_ask(&mut book, price, 300, 10, scenario.ctx());
    let (order_id_b, _, _, _) = ticket_b.ticket_fields_for_testing();

    // `event::events_by_type` only sees events emitted in the *current*
    // transaction (test_scenario clears its recorded events on every
    // `next_tx`), so the final sweep's own two `OrderFilled` events are
    // freshly numbered [0, 1] here, independent of the earlier partial fill.
    scenario.next_tx(taker());
    let payment2 = coin::mint_for_testing<USDC>(book.bid_escrow_amount(price, 500), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _, _) =
        book.match_bid_for_testing(option::some(price), 500, payment2, 1_000_000, scenario.ctx());
    matched_base2.burn_for_testing();
    remaining_budget2.burn_for_testing();
    assert!(remaining_size2 == 0, 1);

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
    let book_id = book.id_for_testing();

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

/// Rests orders at 60 distinct bid prices through the real
/// `insert_resting_order` path (via `insert_resting_order_for_testing`) and
/// checks `depth_at_price`/`best_bid` after every single insertion. None of
/// the other book-level tests in this file build a price tree deep enough
/// for `price_tree::insert`/`insert_at`'s crit-bit routing to be observable
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

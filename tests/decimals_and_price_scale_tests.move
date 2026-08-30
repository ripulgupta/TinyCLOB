#[test_only]
module tiny_clob::decimals_and_price_scale_tests;

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


// === Phase 1 price-scaling redesign: price_scale/precision/exponent/price_band_factor/last_price ===

#[test]
#[expected_failure(abort_code = 20, location = tiny_clob)] // EPriceRangeInfeasible
fun new_infeasible_precision_exponent_aborts() {
    let mut scenario = ts::begin(admin());
    // base_decimals=0, quote_decimals=0: scale_lo = ceil(10^precision) = 10^19;
    // scale_hi = floor(u64::MAX / 10^exponent) = floor(u64::MAX / 10^19) = 1.
    // scale_lo (10^19) > scale_hi (1) -> infeasible.
    let (book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 0, 19, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A BTC(8 decimals)/USDC(6 decimals)-style book, configured to represent
/// prices up to 10^19 true quote-per-base units. With this book's derived
/// `price_scale` (184), `price = scale * 79_000` decodes to a true price of
/// $7,900,000 per BTC (not $79,000 — `price / price_scale` = 79,000, but the
/// true price also carries the `10^(quote_decimals - base_decimals)` =
/// `10^-2` factor, so the true price is `79_000 / 10^-2` = 7,900,000),
/// which this book's raw (unscaled) `u64` `price` representation cannot
/// express in its natural orientation at all. Places an order at that
/// price, confirms it rests, and confirms `bid_escrow_amount` computes the
/// expected scaled escrow.
#[test]
fun btc_usdc_realistic_price_scale_end_to_end() {
    let mut scenario = ts::begin(admin());
    // exponent=19 (not a "round" 10^N true-price bound): price_scale is
    // derived to *maximize* precision subject to the u64 ceiling, so with
    // base_decimals > quote_decimals the resulting price_scale is small
    // (on the order of 10^(base_decimals - quote_decimals)), which in turn
    // pushes the *minimum* representable raw price above 1 — hence seeding
    // `initial_last_price` with a comfortably-clear-of-the-minimum value
    // rather than `1`.
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 8, 6, 0, 19, 1_000_000_000, scenario.ctx());
    let scale = book.price_scale();

    let price = scale * 79_000; // true price = $7,900,000 per BTC (see doc comment above)
    let size = 100_000; // base atoms (8 decimals)
    let expected_escrow = book.bid_escrow_amount(price, size);
    // price is an exact multiple of scale, so the ceiling division is exact.
    assert!(expected_escrow == 79_000 * size, 0);

    let payment = coin::mint_for_testing<USDC>(expected_escrow, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(price, size, payment, 10, scenario.ctx());
    assert!(!stopped, 1);
    assert!(matched_base.burn_for_testing() == 0, 2);
    assert!(leftover_quote.burn_for_testing() == 0, 3);
    assert!(ticket_opt.is_some(), 4);
    let ticket = ticket_opt.destroy_some();
    assert!(book.depth_at_price(tiny_clob::bid_for_testing(), price) == size, 5);

    let (b, q) = book.cancel_order(ticket, scenario.ctx());
    assert!(b.burn_for_testing() == 0, 6);
    assert!(q.burn_for_testing() == expected_escrow, 7);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Pair-decimal coverage: realistic decimal combinations ===
//
// The tests below exercise `price_scale` derivation and the resulting raw
// `price` range for decimal-pair shapes not covered by
// `btc_usdc_realistic_price_scale_end_to_end` above: a base/quote decimals
// reversal (USDC/BTC), two more common Sui-ecosystem decimal shapes
// (BTC/SUI, SUI/BTC), and a same-decimals pair (WAL/SUI, both 9 decimals).
//
// For each pair, `P_min`/`P_max` (the smallest/largest raw `price` that
// `assert_price_in_declared_range` accepts) are derived by hand from that
// function's two inequalities, mirroring the derivation in its doc comment:
//   scale * 10^quote_dec <= price * 10^base_dec * 10^precision   (min bound)
//   price * 10^base_dec <= 10^exponent * scale * 10^quote_dec    (max bound)
// which solve to:
//   P_min = ceil(scale * 10^quote_dec / (10^base_dec * 10^precision))
//   P_max = floor(10^exponent * scale * 10^quote_dec / 10^base_dec)
// with `scale` itself derived the same way `new`/`price_scale` derive it
// (see that function's doc comment): `scale_hi = floor(u64::MAX * 10^base_dec
// / (10^quote_dec * 10^exponent))`, and `price_scale = scale_hi` whenever
// `scale_hi <= u64::MAX` (true for every book below). These were computed
// out-of-band (Python, mirroring the exact integer arithmetic) and are
// hardcoded here as named constants with the derivation shown per-test;
// `bid_escrow_amount` itself is always called through the real API rather
// than hand-computed, so only the raw `price` values below are "derived
// offline" — the escrow amounts they produce are asserted against the
// book's own computation.

/// `USDC/BTC`: `Base` = USDC (6 decimals), `Quote` = BTC (8 decimals) — the
/// reverse orientation of `btc_usdc_realistic_price_scale_end_to_end` above,
/// i.e. this book's raw prices express "BTC per USDC". A true BTC/USDC spot
/// price around $117,647 implies a true USDC/BTC price around
/// 1/117,647 ≈ 0.0000085 (8.5e-6) BTC per USDC — a tiny fraction, so this
/// book needs `precision` deep enough to represent values below `10^-6`.
/// `precision=8, exponent=0` declares a representable true-price range of
/// `[10^-8, 10^0]`, which comfortably straddles 8.5e-6 with margin on both
/// ends (unlike the BTC/USDC book, the max true price here is bounded by 1,
/// since a fraction of a BTC per USDC can never realistically reach 1).
///
/// With `base_decimals=6, quote_decimals=8, precision=8, exponent=0`:
/// `scale_hi = floor(u64::MAX * 10^6 / (10^8 * 10^0)) = floor(u64::MAX / 100)
/// = 184_467_440_737_095_516 = price_scale`.
/// `P_min = ceil(scale * 10^8 / (10^6 * 10^8)) = ceil(scale / 10^6)
/// = 184_467_440_738`.
/// `P_max = floor(10^0 * scale * 10^8 / 10^6) = floor(scale * 100)
/// = 18_446_744_073_709_551_600`.
#[test]
fun usdc_btc_reversed_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price ≈ 8.5e-6 BTC per USDC
    // (see doc comment above), which decodes to this raw price via
    // `price = true_price * price_scale * 10^(quote_dec - base_dec)`.
    assert_extremes_and_adjacent_ticks<USDC, BTC>(
        6, 8, 8, 0,
        184_467_440_738, 18_446_744_073_709_551_600, 156_797_403_025_233,
        184_467_440_737_095_516,
        &mut scenario,
    );
    scenario.end();
}

/// `BTC/SUI`: `Base` = BTC (8 decimals), `Quote` = SUI (9 decimals). A true
/// BTC/SUI spot price around 33,714 SUI per BTC (e.g. BTC ≈ $118,000, SUI ≈
/// $3.50). `precision=0, exponent=6` declares a representable true-price
/// range of `[10^0, 10^6]` (1 to 1,000,000 SUI per BTC), comfortably
/// straddling 33,714 with wide margin on both ends — SUI/BTC has never been,
/// and is unlikely soon to be, outside that six-decade band.
///
/// With `base_decimals=8, quote_decimals=9, precision=0, exponent=6`:
/// `scale_hi = floor(u64::MAX * 10^8 / (10^9 * 10^6)) = floor(u64::MAX /
/// 10^7) = 1_844_674_407_370 = price_scale`.
/// `P_min = ceil(scale * 10^9 / (10^8 * 10^0)) = ceil(scale * 10) =
/// 18_446_744_073_700`.
/// `P_max = floor(10^6 * scale * 10^9 / 10^8) = floor(scale * 10^7) =
/// 18_446_744_073_700_000_000`.
#[test]
fun btc_sui_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price = 33,714 SUI per BTC (see
    // doc comment above).
    assert_extremes_and_adjacent_ticks<BTC, SUI>(
        8, 9, 0, 6,
        18_446_744_073_700, 18_446_744_073_700_000_000, 621_913_529_700_721_800,
        1_844_674_407_370,
        &mut scenario,
    );
    scenario.end();
}

/// `SUI/BTC`: `Base` = SUI (9 decimals), `Quote` = BTC (8 decimals) — the
/// reverse orientation of the BTC/SUI book above, i.e. raw prices express
/// "BTC per SUI". A true SUI/BTC spot price around 1/33,714 ≈ 0.0000297
/// (2.97e-5) BTC per SUI. `precision=8, exponent=0` declares a representable
/// true-price range of `[10^-8, 10^0]`, comfortably straddling 2.97e-5.
///
/// With `base_decimals=9, quote_decimals=8, precision=8, exponent=0`:
/// `scale_hi = floor(u64::MAX * 10^9 / (10^8 * 10^0)) = floor(u64::MAX * 10)
/// `, which exceeds `u64::MAX`, so `price_scale = u64::MAX =
/// 18_446_744_073_709_551_615` (the `scale_hi > u64::MAX` clamp case in
/// `new_impl`, unlike the other three books here where `scale_hi` itself is
/// the binding value).
/// `P_min = ceil(scale * 10^8 / (10^9 * 10^8)) = ceil(scale / 10) =
/// 18_446_744_074` (rounds up since `scale` is odd).
/// `P_max = floor(10^0 * scale * 10^8 / 10^9) = floor(scale / 10) =
/// 1_844_674_407_370_955_161`.
#[test]
fun sui_btc_reversed_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price ≈ 2.97e-5 BTC per SUI
    // (see doc comment above).
    assert_extremes_and_adjacent_ticks<SUI, BTC>(
        9, 8, 8, 0,
        18_446_744_074, 1_844_674_407_370_955_161, 54_715_382_552_380,
        18_446_744_073_709_551_615,
        &mut scenario,
    );
    scenario.end();
}

/// `WAL/SUI`: a same-decimals pair (`Base` = WAL, `Quote` = SUI, both 9
/// decimals) — the case `base_decimals == quote_decimals`, where the
/// `10^(base_dec - quote_dec)` scaling factor from the module's true-price
/// formula is exactly 1 and raw price tracks true price most directly of
/// any shape covered here. A plausible WAL/SUI true price around 2.5 SUI
/// per WAL. `precision=2, exponent=4` declares a representable true-price
/// range of `[10^-2, 10^4]` (0.01 to 10,000), comfortably straddling 2.5.
///
/// With `base_decimals=9, quote_decimals=9, precision=2, exponent=4`:
/// `scale_hi = floor(u64::MAX * 10^9 / (10^9 * 10^4)) = floor(u64::MAX /
/// 10^4) = 1_844_674_407_370_955 = price_scale`.
/// `P_min = ceil(scale * 10^9 / (10^9 * 10^2)) = ceil(scale / 100) =
/// 18_446_744_073_710`.
/// `P_max = floor(10^4 * scale * 10^9 / 10^9) = floor(scale * 10^4) =
/// 18_446_744_073_709_550_000`.
#[test]
fun wal_sui_same_decimals_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price = 2.5 SUI per WAL (see
    // doc comment above).
    assert_extremes_and_adjacent_ticks<WAL, SUI>(
        9, 9, 2, 4,
        18_446_744_073_710, 18_446_744_073_709_550_000, 4_611_686_018_427_388,
        1_844_674_407_370_955,
        &mut scenario,
    );
    scenario.end();
}

// === Regression: F2 `affordable_qty` u128->u64 narrowing DoS ===
//
// price_scale = floor(u64::MAX / 10^9) = 18_446_744_073 (base=quote=0,
// precision=9, exponent=9). A resting ask at a low raw price plus a large
// taker budget makes (budget * price_scale / best_price) exceed u64::MAX
// before clamping; the old code narrowed to u64 before the `min` with
// `natural_fill_qty` and aborted the whole order instead of correctly
// clamping. With the fix, the order succeeds and the taker's fill is
// correctly bounded by the resting ask's size.
#[test]
fun affordable_qty_narrowing_does_not_abort_for_large_budget_taker() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 9, 9, 1_000_000_000, scenario.ctx());
    assert!(book.price_scale() == 18_446_744_073, 0);
    // Cheapest representable raw price is 19 (P ~= 1.03e-9 >= 10^-9).
    let ask_ticket = rest_ask(&mut book, 19, 1_000, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget: u64 = 20_000_000_000; // 2e10 quote atoms
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, stopped) = book.place_market_order_bid(
        1_000, budget, payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    // The resting ask only has 1_000 base atoms available, so the fill is
    // capped by natural_fill_qty (1_000), not by an abort.
    assert!(matched_base.burn_for_testing() == 1_000, 1);
    assert!(!stopped, 2);
    leftover_payment.burn_for_testing();

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Regression: F3 `price_scale` silently landing below `scale_lo` ===
//
// base=30, quote=0, precision=0, exponent=19:
//   scale_lo = 10^30, scale_hi = floor(u64::MAX * 10^30 / 10^19) ~= 1.8e30
//   scale_lo <= scale_hi, so without the `scale_lo <= u64::MAX` conjunct the
//   old code let construction succeed with price_scale = min(scale_hi,
//   u64::MAX) = u64::MAX, far below the true scale_lo -- silently delivering
//   coarser precision than declared. The fix rejects this with
//   EPriceRangeInfeasible instead.
#[test]
#[expected_failure(abort_code = 20, location = tiny_clob)] // EPriceRangeInfeasible
fun price_scale_below_scale_lo_now_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = tiny_clob::new<BTC, USDC>(1, 30, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `place_limit_order_ask` boundary-tick coverage ---
//
// Analogous to `usdc_btc_reversed_pair_price_extremes_and_adjacent_ticks`
// above, but through `place_limit_order_ask` instead of `_bid`, to catch a
// site-specific bug in the ask copy of the range/band check that the
// bid-side tests wouldn't catch.
#[test]
fun usdc_btc_reversed_pair_ask_side_price_extremes() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 184_467_440_738;
    let p_max: u64 = 18_446_744_073_709_551_600;
    let p_mid: u64 = 156_797_403_025_233;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 8, 0, p_mid, scenario.ctx());
    let size = min_size();

    // (a) Extreme minimum representable raw price: rests, checks depth,
    // cancels, verifies exact base refund.
    let min_payment = coin::mint_for_testing<USDC>(size, scenario.ctx());
    let (min_ticket_opt, min_leftover, min_matched, min_stopped) =
        book.place_limit_order_ask(p_min, size, min_payment, 10, scenario.ctx());
    assert!(!min_stopped, 0);
    assert!(min_leftover.burn_for_testing() == 0, 1);
    assert!(min_matched.burn_for_testing() == 0, 2);
    assert!(book.depth_at_price(tiny_clob::ask_for_testing(), p_min) == size, 3);
    let (min_b, min_q) = book.cancel_order(min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(min_b.burn_for_testing() == size, 4);
    assert!(min_q.burn_for_testing() == 0, 5);

    // (b) Extreme maximum representable raw price: same checks.
    let max_payment = coin::mint_for_testing<USDC>(size, scenario.ctx());
    let (max_ticket_opt, max_leftover, max_matched, max_stopped) =
        book.place_limit_order_ask(p_max, size, max_payment, 10, scenario.ctx());
    assert!(!max_stopped, 6);
    assert!(max_leftover.burn_for_testing() == 0, 7);
    assert!(max_matched.burn_for_testing() == 0, 8);
    assert!(book.depth_at_price(tiny_clob::ask_for_testing(), p_max) == size, 9);
    let (max_b, max_q) = book.cancel_order(max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(max_b.burn_for_testing() == size, 10);
    assert!(max_q.burn_for_testing() == 0, 11);

    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

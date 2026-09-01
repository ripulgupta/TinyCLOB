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
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks, u64_max,
};


// === Phase 1 price-scaling redesign: price_scale/precision/exponent/price_band_factor/last_price ===

#[test]
#[expected_failure(abort_code = 20, location = tiny_clob)] // EPriceRangeInfeasible
fun new_infeasible_precision_exponent_aborts() {
    let mut scenario = ts::begin(admin());
    // base_decimals=0, quote_decimals=0: scale_lo = ceil(10^precision) = 10^19;
    // scale_hi = floor(u64::MAX / 10^exponent) = floor(u64::MAX / 10^19) = 1.
    // scale_lo (10^19) > scale_hi (1) -> infeasible.
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 0, 19, 19, 1, &wrapper_uid, scenario.ctx());
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

/// A BTC(8 decimals)/USDC(6 decimals)-style book, configured to represent
/// prices up to 10^19 true quote-per-base units. With this book's derived
/// `price_scale` (100), `price = scale * 79_000` decodes to a true price of
/// $7,900,000 per BTC (not $79,000 — `price / price_scale` = 79,000, but the
/// true price also carries the `10^(base_decimals - quote_decimals)` =
/// `10^2` factor that it's multiplied by, so the true price is
/// `79_000 * 10^2` = 7,900,000),
/// which this book's raw (unscaled) `u64` `price` representation cannot
/// express in its natural orientation at all. Places an order at that
/// price, confirms it rests, and confirms `bid_escrow_amount` computes the
/// expected scaled escrow.
#[test]
fun btc_usdc_realistic_price_scale_end_to_end() {
    let mut scenario = ts::begin(admin());
    // exponent=19 (not a "round" 10^N true-price bound): price_scale is
    // derived as the SMALLEST value guaranteeing resolution at least as
    // fine as the declared `10^-precision` (precision=0 here), i.e.
    // `ceil(10^base_decimals / 10^quote_decimals)` = `ceil(10^8 / 10^6)` =
    // 100 — not the largest value fitting in a `u64`. `initial_last_price`
    // is seeded with a comfortably-clear-of-the-minimum value rather than
    // `1` regardless, since the minimum representable raw price can still
    // land above 1 for some decimals/precision/exponent shapes.
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 8, 6, 0, 19, 1_000_000_000, &wrapper_uid, scenario.ctx());
    let scale = book.price_scale();

    let price = scale * 79_000; // true price = $7,900,000 per BTC (see doc comment above)
    let size = 100_000; // base atoms (8 decimals)
    let expected_escrow = book.bid_escrow_amount(price, size);
    // price is an exact multiple of scale, so the ceiling division is exact.
    assert!(expected_escrow == 79_000 * size, 0);

    let payment = coin::mint_for_testing<USDC>(expected_escrow, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, size, 10, scenario.ctx());
    assert!(!stopped, 1);
    assert!(matched_base.burn_for_testing() == 0, 2);
    assert!(leftover_quote.burn_for_testing() == 0, 3);
    assert!(ticket_opt.is_some(), 4);
    let ticket = ticket_opt.destroy_some();
    // Quote-denominated for a bid -- equal to the escrow reserved, not `size`.
    assert!(book.bid_quote_escrow_at_price(price) == expected_escrow, 5);

    let (b, q) = book.cancel_order(ticket, scenario.ctx());
    assert!(b.burn_for_testing() == 0, 6);
    assert!(q.burn_for_testing() == expected_escrow, 7);

    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
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
// (see that function's doc comment): `scale_lo = ceil(10^base_dec *
// 10^precision / 10^quote_dec)`, and `price_scale = scale_lo` -- the
// smallest value guaranteeing resolution at least as fine as
// `10^-precision`, not the largest value fitting in a `u64` -- for every
// book below. These were computed out-of-band (Python, mirroring the exact
// integer arithmetic) and are hardcoded here as named constants with the
// derivation shown per-test;
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
/// `scale_lo = ceil(10^6 * 10^8 / 10^8) = 1_000_000 = price_scale`
/// (`scale_hi = floor(u64::MAX * 10^6 / (10^8 * 10^0)) = 184_467_440_737_095_516`,
/// comfortably above `scale_lo`, so the feasibility check passes).
/// `P_min = ceil(scale * 10^8 / (10^6 * 10^8)) = ceil(scale / 10^6) = 1`.
/// `P_max = floor(10^0 * scale * 10^8 / 10^6) = floor(scale * 100)
/// = 100_000_000`.
#[test]
fun usdc_btc_reversed_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price ≈ 8.5e-6 BTC per USDC
    // (see doc comment above), which decodes to this raw price via
    // `price = true_price * price_scale * 10^(quote_dec - base_dec)`
    // (`(1/117_647) * 1_000_000 * 10^2 ≈ 850`, rounded to the nearest tick).
    assert_extremes_and_adjacent_ticks<USDC, BTC>(
        6, 8, 8, 0,
        1, 100_000_000, 850,
        1_000_000,
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
/// `scale_lo = ceil(10^8 * 10^0 / 10^9) = ceil(0.1) = 1 = price_scale`
/// (`scale_hi = floor(u64::MAX * 10^8 / (10^9 * 10^6)) = 1_844_674_407_370`,
/// comfortably above `scale_lo`).
/// `P_min = ceil(scale * 10^9 / (10^8 * 10^0)) = ceil(scale * 10) = 10`.
/// `P_max = floor(10^6 * scale * 10^9 / 10^8) = floor(scale * 10^7) =
/// 10_000_000`.
#[test]
fun btc_sui_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price = 33,714 SUI per BTC (see
    // doc comment above); decodes via
    // `price = true_price * price_scale * 10^(quote_dec - base_dec)` =
    // `33_714 * 1 * 10 = 337_140`.
    assert_extremes_and_adjacent_ticks<BTC, SUI>(
        8, 9, 0, 6,
        10, 10_000_000, 337_140,
        1,
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
/// `scale_lo = ceil(10^9 * 10^8 / 10^8) = 1_000_000_000 = price_scale`
/// (`scale_hi = floor(u64::MAX * 10^9 / (10^8 * 10^0)) ≈ 1.8e20`, far above
/// `u64::MAX` itself, but that's fine -- only `scale_lo`, not `scale_hi`,
/// needs to fit in a `u64`; unlike the other three books here, this is the
/// shape where the OLD formula would have clamped to `u64::MAX`, but the
/// new formula uses the much smaller `scale_lo` instead).
/// `P_min = ceil(scale * 10^8 / (10^9 * 10^8)) = ceil(scale / 10) = 1`.
/// `P_max = floor(10^0 * scale * 10^8 / 10^9) = floor(scale / 10) =
/// 100_000_000`.
#[test]
fun sui_btc_reversed_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price ≈ 2.97e-5 BTC per SUI
    // (see doc comment above); decodes via
    // `price = true_price * price_scale * 10^(quote_dec - base_dec)` =
    // `(1/33_714) * 1_000_000_000 * 10^-1 ≈ 2_966`, rounded to the nearest
    // tick.
    assert_extremes_and_adjacent_ticks<SUI, BTC>(
        9, 8, 8, 0,
        1, 100_000_000, 2_966,
        1_000_000_000,
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
/// `scale_lo = ceil(10^9 * 10^2 / 10^9) = 100 = price_scale`
/// (`scale_hi = floor(u64::MAX * 10^9 / (10^9 * 10^4)) = 1_844_674_407_370_955`,
/// comfortably above `scale_lo`).
/// `P_min = ceil(scale * 10^9 / (10^9 * 10^2)) = ceil(scale / 100) = 1`.
/// `P_max = floor(10^4 * scale * 10^9 / 10^9) = floor(scale * 10^4) =
/// 1_000_000`.
#[test]
fun wal_sui_same_decimals_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(admin());
    // p_mid: realistic mid-range price, true price = 2.5 SUI per WAL (see
    // doc comment above); decodes via
    // `price = true_price * price_scale * 10^(quote_dec - base_dec)` =
    // `2.5 * 100 * 1 = 250`.
    assert_extremes_and_adjacent_ticks<WAL, SUI>(
        9, 9, 2, 4,
        1, 1_000_000, 250,
        100,
        &mut scenario,
    );
    scenario.end();
}

// === Regression: F2 `affordable_qty` u128->u64 narrowing DoS ===
//
// price_scale = ceil(10^0 * 10^9 / 10^0) = 1_000_000_000 (base=quote=0,
// precision=9, exponent=9) -- the smallest value guaranteeing resolution at
// least as fine as 10^-9. A resting ask at a low raw price plus a large
// taker budget makes (budget * price_scale / best_price) exceed u64::MAX
// before clamping; the old code narrowed to u64 before the `min` with
// `natural_fill_qty` and aborted the whole order instead of correctly
// clamping. With the fix, the order succeeds and the taker's fill is
// correctly bounded by the resting ask's size.
//
// `ASK_SIZE` (rather than the pre-redesign value of `1_000`): any
// legitimately-derivable nonzero resting-ask price satisfies `price * size >=
// price_scale`, so reproducing `price == 19` exactly at this book's
// `price_scale` (1_000_000_000) requires a size of at least `52_631_579`
// (verified out-of-band: `ceil(1_000_000_000 / 52_631_579) == 19` exactly).
// The budget below (400_000_000_000) is still sized so `budget * price_scale
// / price` (≈2.1e19) comfortably exceeds `u64::MAX` (≈1.84e19), and
// comfortably exceeds `ASK_SIZE` too, so the fill is still capped by
// `natural_fill_qty` (`ASK_SIZE`), not by the budget or an abort -- same
// property under test as before, just at the smallest size this API can
// still express this price at.
const ASK_SIZE: u64 = 52_631_579;
#[test]
fun affordable_qty_narrowing_does_not_abort_for_large_budget_taker() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 9, 9, 1_000_000_000, &wrapper_uid, scenario.ctx());
    assert!(book.price_scale() == 1_000_000_000, 0);
    // A low, comfortably-valid raw price (minimum representable is 1).
    let ask_ticket = rest_ask(&mut book, 19, ASK_SIZE, 10, scenario.ctx());

    scenario.next_tx(taker());
    let budget: u64 = 400_000_000_000; // 4e11 quote atoms
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, stopped) = book.place_market_order_bid(payment, 10, 0, u64_max(), u64_max(), scenario.ctx(),
    );
    // The resting ask only has `ASK_SIZE` base atoms available, so the fill
    // is capped by natural_fill_qty (`ASK_SIZE`), not by an abort.
    assert!(matched_base.burn_for_testing() == ASK_SIZE, 1);
    assert!(!stopped, 2);
    leftover_payment.burn_for_testing();

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
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
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<BTC, USDC>(1, 30, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
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
    let p_min: u64 = 1;
    let p_max: u64 = 100_000_000;
    let p_mid: u64 = 850;
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 8, 0, p_mid, &wrapper_uid, scenario.ctx());
    let scale = book.price_scale();
    let size = min_size();

    // (a) Extreme minimum representable raw price: rests, checks depth,
    // cancels, verifies exact base refund. `place_limit_order_ask` derives
    // `price = ceil(expected_quote_output * price_scale / size)`, and any
    // legitimately-derived nonzero price satisfies `price * size >=
    // price_scale` (`eq >= 1`). At `price == p_min == 1` that forces `size >=
    // price_scale` (1_000_000 here) -- far larger than `min_size()` (100) --
    // so this leg uses `scale` itself as its ask size instead of
    // `min_size()` (the (b) leg below is unaffected and keeps `min_size()`).
    let min_leg_size = scale;
    let min_payment = coin::mint_for_testing<USDC>(min_leg_size, scenario.ctx());
    let min_expected_quote_output = test_utils::ask_expected_output_for_price(&book, p_min, min_leg_size);
    let (min_ticket_opt, min_leftover, min_matched, min_stopped) =
        book.place_limit_order_ask(min_payment, min_expected_quote_output, 10, scenario.ctx());
    assert!(!min_stopped, 0);
    assert!(min_leftover.burn_for_testing() == 0, 1);
    assert!(min_matched.burn_for_testing() == 0, 2);
    assert!(book.ask_base_escrow_at_price(p_min) == min_leg_size, 3);
    let (min_b, min_q) = book.cancel_order(min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(min_b.burn_for_testing() == min_leg_size, 4);
    assert!(min_q.burn_for_testing() == 0, 5);

    // (b) Extreme maximum representable raw price: same checks. `p_max`
    // (100_000_000) is a whole multiple of `price_scale / size` at
    // `size == min_size()`, so it remains exactly reproducible at this size
    // unchanged.
    let max_payment = coin::mint_for_testing<USDC>(size, scenario.ctx());
    let max_expected_quote_output = test_utils::ask_expected_output_for_price(&book, p_max, size);
    let (max_ticket_opt, max_leftover, max_matched, max_stopped) =
        book.place_limit_order_ask(max_payment, max_expected_quote_output, 10, scenario.ctx());
    assert!(!max_stopped, 6);
    assert!(max_leftover.burn_for_testing() == 0, 7);
    assert!(max_matched.burn_for_testing() == 0, 8);
    assert!(book.ask_base_escrow_at_price(p_max) == size, 9);
    let (max_b, max_q) = book.cancel_order(max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(max_b.burn_for_testing() == size, 10);
    assert!(max_q.burn_for_testing() == 0, 11);

    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    wrapper_uid.delete();
    scenario.end();
}

// === Regression: `price_scale = scale_lo` snaps derived prices to a full
// declared tick, unlike the old, larger `scale_hi` ===
//
// A BTC(8 decimals)/USDC(6 decimals) book with `precision=0` declares only
// whole-dollar true-price resolution, so its raw `price_scale` is now the
// SMALLEST value achieving that: `scale_lo = ceil(10^base_decimals *
// 10^precision / 10^quote_decimals) = ceil(10^8 * 10^0 / 10^6) = 100`, not
// the OLD `scale_hi = floor(u64::MAX * 10^8 / (10^6 * 10^19)) = 184` value
// that the pre-fix formula would have picked instead.
// Since this book's `base_decimals - quote_decimals = 2` exactly cancels
// `price_scale = 100`, a raw `price` here numerically equals its own true
// dollar price.
//
// `place_limit_order_bid`/`place_limit_order_ask` derive their price from a
// `payment`/`expected_output` ratio that need not itself land on a
// whole-dollar boundary. Under the OLD `price_scale = 184`, that
// derivation could still express sub-dollar fractions of true price (e.g.
// $7_900.54...) despite the book's own `precision=0` declaring only
// whole-dollar resolution -- i.e. more precision than the book actually
// promises. Under the NEW `price_scale = 100`, the SAME derivation instead
// snaps down (bid) or up (ask) to the nearest whole dollar, matching what
// the book actually declares -- while remaining just as fund-safe (bid
// still floors, so escrow never exceeds `payment`; ask still ceils, so the
// filled proceeds never fall short of `expected_quote_output`).
#[test]
fun expected_output_price_snaps_to_declared_tick_under_new_price_scale() {
    let mut scenario = ts::begin(admin());
    // base_decimals=8, quote_decimals=6, precision=0, exponent=19:
    // price_scale = ceil(10^8 / 10^6) = 100 (see header comment above).
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 8, 6, 0, 19, 79_000, &wrapper_uid, scenario.ctx());
    assert!(book.price_scale() == 100, 0);

    // --- Bid side: payment/expected_base_output implies a fractional-dollar
    // --- ratio ($7_900.60), which must floor down to the whole-dollar tick
    // --- $7_900 -- NOT the sub-dollar-precise $7_900.54... the old
    // --- `price_scale = 184` formula would have derived from the identical
    // --- `payment`/`expected_base_output` inputs.
    scenario.next_tx(maker_a());
    let expected_base_output: u64 = 1_000;
    let payment_value: u64 = 79_006; // payment/expected_base_output * 100 = 7_900.6
    let payment = coin::mint_for_testing<USDC>(payment_value, scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, bid_stopped) =
        book.place_limit_order_bid(payment, expected_base_output, 10, scenario.ctx());
    assert!(!bid_stopped, 1);
    assert!(bid_matched_base.burn_for_testing() == 0, 2); // empty book, nothing to cross
    let bid_ticket = bid_ticket_opt.destroy_some();
    // Snapped down to the whole-dollar tick 7_900, not left at a
    // sub-declared-precision value like 7_900.6 or even 7_901.
    assert!(bid_ticket.ticket_price() == 7_900, 3);
    // Fund-safety still holds: the floor-rounded price's escrow never
    // exceeds what was actually paid in.
    assert!(book.bid_escrow_amount(7_900, expected_base_output) <= payment_value, 4);
    let leftover_quote_val = bid_leftover_quote.burn_for_testing();
    assert!(leftover_quote_val == payment_value - book.bid_escrow_amount(7_900, expected_base_output), 5);
    // The bid is still resting (nothing crossed it) -- `destroy_orphaned_ticket`
    // now aborts on a still-resting order (`EOrderStillResting`), so
    // `cancel_order` is used here to both conclude the order and dispose of
    // the ticket; disposal isn't what this test is about.
    let (bid_cancel_base, bid_cancel_quote) = book.cancel_order(bid_ticket, scenario.ctx());
    bid_cancel_base.burn_for_testing();
    bid_cancel_quote.burn_for_testing();

    // --- Ask side: expected_quote_output/size implies the same
    // --- fractional-dollar ratio, which must ceil UP to the whole-dollar
    // --- tick $7_901 -- NOT the sub-dollar-precise $7_901.09... the old
    // --- `price_scale = 184` formula would have derived.
    scenario.next_tx(maker_b());
    let size: u64 = 1_000;
    let expected_quote_output: u64 = 79_006; // expected_quote_output/size * 100 = 7_900.6
    let ask_payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (ask_ticket_opt, ask_leftover_base, ask_matched_quote, ask_stopped) =
        book.place_limit_order_ask(ask_payment, expected_quote_output, 10, scenario.ctx());
    assert!(!ask_stopped, 6);
    // The bid above was just cancelled, so the book has no resting bid to
    // cross regardless of price.
    assert!(ask_matched_quote.burn_for_testing() == 0, 7);
    let ask_ticket = ask_ticket_opt.destroy_some();
    // Snapped UP to the whole-dollar tick 7_901, not left at a
    // sub-declared-precision value like 7_900.6 or down at 7_900.
    assert!(ask_ticket.ticket_price() == 7_901, 8);
    // Fund-safety still holds: fully filling `size` at the ceil-rounded
    // price yields at least the caller's declared `expected_quote_output`.
    let full_fill_quote = (7_901 * size) / book.price_scale();
    assert!(full_fill_quote >= expected_quote_output, 9);
    ask_leftover_base.burn_for_testing();
    // Still resting (nothing crossed it either) -- same reasoning as the bid
    // above: cancel_order concludes it and disposes of the ticket in one call.
    let (ask_cancel_base, ask_cancel_quote) = book.cancel_order(ask_ticket, scenario.ctx());
    ask_cancel_base.burn_for_testing();
    ask_cancel_quote.burn_for_testing();

    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

// === `EPriceOverflow` coverage ===
//
// Both `place_limit_order_bid` and `place_limit_order_ask` derive their raw
// `price` via a `u128` intermediate and assert it fits in `u64` before
// casting (see `EPriceOverflow`'s doc comment on each). To reach that
// assert, the book needs a very large `price_scale` combined with a small
// size/expected-output so the intermediate product exceeds `u64::MAX`
// (~1.8446744e19).
//
// `base_decimals=0, quote_decimals=0, precision=18, exponent=1` gives
// `scale_lo = ceil(10^0 * 10^18 / 10^0) = 10^18` and
// `scale_hi = floor(u64::MAX * 10^0 / (10^0 * 10^1)) = floor(u64::MAX / 10)
// = 1_844_674_407_370_955_161`, which is `>= scale_lo`, so construction
// succeeds with `price_scale = 10^18`. `min_size=1` lets a size of `1` pass
// `validate_size`, and `initial_last_price=1` is comfortably within the
// declared `[10^-18, 10^1]` true-price range (true price `1e-18` sits
// exactly at the declared minimum).

/// Bid side: `price = payment.value() * price_scale / expected_base_output`.
/// With `price_scale = 10^18`, `payment.value() = 100`, and
/// `expected_base_output = 1`, the intermediate product is
/// `100 * 10^18 = 10^20`, far exceeding `u64::MAX` (~1.8446744e19).
#[test]
#[expected_failure(abort_code = 29, location = tiny_clob)] // EPriceOverflow
fun place_limit_order_bid_price_overflow_aborts() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 18, 1, 1, &wrapper_uid, scenario.ctx());

    let payment = coin::mint_for_testing<USDC>(100, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, 1, 10, scenario.ctx());
    assert!(!stopped, 0);
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    ticket_opt.destroy_none();

    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

/// Ask side: `price = ceil(expected_quote_output * price_scale /
/// payment.value())`. With `price_scale = 10^18`, `payment.value() = 1`, and
/// `expected_quote_output = 100`, the intermediate numerator is
/// `100 * 10^18 = 10^20`, far exceeding `u64::MAX` (~1.8446744e19).
#[test]
#[expected_failure(abort_code = 29, location = tiny_clob)] // EPriceOverflow
fun place_limit_order_ask_price_overflow_aborts() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 18, 1, 1, &wrapper_uid, scenario.ctx());

    let payment = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, 100, 10, scenario.ctx());
    assert!(!stopped, 0);
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    ticket_opt.destroy_none();

    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

// === Coverage-audit gap closures (round 2) ===
//
// Gaps 1-5 below close specific missing-coverage items identified by a later
// audit: `set_last_price`'s declared-range reject side, `place_limit_order_ask`'s
// declared-range reject side, `bid_escrow_amount(book, 0, size) == 0`, the
// `min_size` boundary on a `price_scale > 1` book, and the exact
// `EPriceRangeInfeasible` boundary (`scale_lo == scale_hi`). A former Gap 6
// (`new_with_event_id_override`'s price-scale-derivation equivalence with
// plain `new`) was removed along with that function — see the note where it
// used to live, below.

// --- Gap 1: `set_last_price` declared-range REJECT side ---
//
// USDC(6)/BTC(8), precision=1, exponent=0 -- the same shape used by
// `usdc_btc_reversed_pair_price_just_below_min_aborts`/`_just_above_max_aborts`
// above: `price_scale = ceil(10^6 * 10^1 / 10^8) = 1`, `p_min = 10`,
// `p_max = 100` (both derived the same way as those tests' doc comments).
// Neither book below has any resting order (`best_bid`/`best_ask` are both
// `None`), so `set_last_price`'s later best-bid/best-ask bound checks never
// engage -- confirmed explicitly below -- and these tests exercise only the
// declared-range check (which, per the source, runs unconditionally before
// the best-bid/best-ask checks regardless).
#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun set_last_price_below_declared_min_aborts() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 10;
    let p_mid: u64 = 50;
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 1, 0, p_mid, &wrapper_uid, scenario.ctx());
    assert!(book.best_bid().is_none() && book.best_ask().is_none(), 0);
    book.set_last_price(p_min - 1, scenario.ctx());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun set_last_price_above_declared_max_aborts() {
    let mut scenario = ts::begin(admin());
    let p_max: u64 = 100;
    let p_mid: u64 = 50;
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 1, 0, p_mid, &wrapper_uid, scenario.ctx());
    assert!(book.best_bid().is_none() && book.best_ask().is_none(), 0);
    book.set_last_price(p_max + 1, scenario.ctx());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    wrapper_uid.delete();
    scenario.end();
}

// --- Gap 2: `place_limit_order_ask` declared-range REJECT side ---
//
// Same USDC(6)/BTC(8), precision=1, exponent=0 book shape as Gap 1 above
// (`price_scale = 1`, `p_min = 10`, `p_max = 100`). Mirrors the existing
// bid-side reject tests (`usdc_btc_reversed_pair_price_just_below_min_aborts`/
// `_just_above_max_aborts`), but through `place_limit_order_ask` -- using
// `test_utils::ask_expected_output_for_price` to derive an
// `expected_quote_output` that round-trips back to exactly the target
// out-of-range price, same as `usdc_btc_reversed_pair_ask_side_price_extremes`
// does for the (in-range) accept side.
#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun place_limit_order_ask_price_just_below_min_aborts() {
    let mut scenario = ts::begin(admin());
    let p_min: u64 = 10;
    let p_mid: u64 = 50;
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 1, 0, p_mid, &wrapper_uid, scenario.ctx());
    let size = min_size();
    // expected_quote_output = floor((p_min - 1) * size / price_scale) =
    // floor(9 * 100 / 1) = 900; `place_limit_order_ask` re-derives
    // `price = ceil(900 * 1 / 100) = 9`, one below `p_min`.
    let expected_quote_output = test_utils::ask_expected_output_for_price(&book, p_min - 1, size);
    let payment = coin::mint_for_testing<USDC>(size, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(payment, expected_quote_output, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun place_limit_order_ask_price_just_above_max_aborts() {
    let mut scenario = ts::begin(admin());
    let p_max: u64 = 100;
    let p_mid: u64 = 50;
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(min_size(), 6, 8, 1, 0, p_mid, &wrapper_uid, scenario.ctx());
    let size = min_size();
    // expected_quote_output = floor((p_max + 1) * size / price_scale) =
    // floor(101 * 100 / 1) = 10_100; re-derived price =
    // ceil(10_100 * 1 / 100) = 101, one above `p_max`.
    let expected_quote_output = test_utils::ask_expected_output_for_price(&book, p_max + 1, size);
    let payment = coin::mint_for_testing<USDC>(size, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(payment, expected_quote_output, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    wrapper_uid.delete();
    scenario.end();
}

// --- Gap 3: `bid_escrow_amount(book, 0, size) == 0` ---
#[test]
fun bid_escrow_amount_zero_price_is_zero() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);
    assert!(book.bid_escrow_amount(0, 12_345) == 0, 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- Gap 4: `min_size` boundary on a `price_scale > 1` book ---
//
// `realistic_decimals_book` (base=8, quote=6, precision=0, exponent=19) has
// `price_scale = 100` -- unlike every existing min_size-boundary test, which
// uses `new_book` (`price_scale == 1`, no rounding to account for).
// `REALISTIC_MIN_SIZE` (200, not the shared `min_size()` constant) is used
// purely so both boundary values (200, 199) stay comfortably nonzero.
// `REALISTIC_BID_ASK_PRICE` is this book's own `initial_last_price`
// (`100 * 497`, see `realistic_decimals_book`'s definition), guaranteed to
// already be within the declared range and to round-trip exactly through
// `bid_payment_for_price`/`ask_expected_output_for_price` at this size, since
// `49_700 * 200` is an exact multiple of `price_scale` (100).
const REALISTIC_MIN_SIZE: u64 = 200;
const REALISTIC_BID_ASK_PRICE: u64 = 49_700;

#[test]
fun realistic_decimals_book_bid_at_exact_min_size_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) =
        test_utils::realistic_decimals_book<BTC, USDC>(REALISTIC_MIN_SIZE, &mut scenario);
    assert!(book.price_scale() == 100, 0);
    let size = REALISTIC_MIN_SIZE;
    let payment_value = test_utils::bid_payment_for_price(&book, REALISTIC_BID_ASK_PRICE, size);
    let payment = coin::mint_for_testing<USDC>(payment_value, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, size, 10, scenario.ctx());
    assert!(!stopped, 1);
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    // Nothing crosses on this empty book, so the order is still resting --
    // `cancel_order` concludes it and disposes of the ticket in one call
    // (this test is about the min_size boundary, not ticket disposal).
    let (cancel_base, cancel_quote) = book.cancel_order(ticket, scenario.ctx());
    cancel_base.burn_for_testing();
    cancel_quote.burn_for_testing();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 12, location = tiny_clob)] // ESizeBelowMinSize
fun realistic_decimals_book_bid_below_min_size_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) =
        test_utils::realistic_decimals_book<BTC, USDC>(REALISTIC_MIN_SIZE, &mut scenario);
    // `validate_size` runs before `price` is derived, so an arbitrary
    // payment value is fine -- the abort fires before it's ever used.
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, REALISTIC_MIN_SIZE - 1, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(matched_base);
    unit_test::destroy(leftover_quote);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
fun realistic_decimals_book_ask_at_exact_min_size_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) =
        test_utils::realistic_decimals_book<BTC, USDC>(REALISTIC_MIN_SIZE, &mut scenario);
    let size = REALISTIC_MIN_SIZE;
    let expected_quote_output =
        test_utils::ask_expected_output_for_price(&book, REALISTIC_BID_ASK_PRICE, size);
    let payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        book.place_limit_order_ask(payment, expected_quote_output, 10, scenario.ctx());
    assert!(!stopped, 0);
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    // Nothing crosses on this empty book, so the order is still resting --
    // `cancel_order` concludes it and disposes of the ticket in one call
    // (this test is about the min_size boundary, not ticket disposal).
    let (cancel_base, cancel_quote) = book.cancel_order(ticket, scenario.ctx());
    cancel_base.burn_for_testing();
    cancel_quote.burn_for_testing();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 12, location = tiny_clob)] // ESizeBelowMinSize
fun realistic_decimals_book_ask_below_min_size_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) =
        test_utils::realistic_decimals_book<BTC, USDC>(REALISTIC_MIN_SIZE, &mut scenario);
    // An ask's `size` is `payment.value()` itself, so a sub-min_size payment
    // is enough to trip `validate_size` regardless of `expected_quote_output`.
    let payment = coin::mint_for_testing<BTC>(REALISTIC_MIN_SIZE - 1, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(payment, 0, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

// --- Gap 5: exact `EPriceRangeInfeasible` boundary (`scale_lo == scale_hi`) ---
//
// base_decimals=0, quote_decimals=1, precision=0, exponent=18:
//   scale_lo = ceil(10^0 * 10^0 / 10^1) = ceil(1/10) = 1
//   scale_hi = floor(u64::MAX * 10^0 / (10^1 * 10^18)) = floor(u64::MAX / 10^19)
//            = floor(18_446_744_073_709_551_615 / 10_000_000_000_000_000_000)
//            = 1
// scale_lo == scale_hi == 1 EXACTLY -- this is the tightest possible feasible
// margin (`scale_lo <= scale_hi` holds with zero slack), so `new` must still
// succeed (not abort `EPriceRangeInfeasible`) and must derive
// `price_scale == 1`.
//
// Declared true-price range at this `price_scale`: from
// `assert_price_in_declared_range`, `price >= ceil(scale * 10^quote_dec /
// (10^base_dec * 10^prec)) = ceil(1 * 10 / (1 * 1)) = 10` and
// `price <= floor(10^exponent * scale * 10^quote_dec / 10^base_dec) =
// floor(10^18 * 1 * 10 / 1) = 10^19` -- `initial_last_price = 10` (the
// minimum) is used below.
#[test]
fun price_range_infeasibility_boundary_scale_lo_equals_scale_hi_accepts() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 1, 0, 18, 10, &wrapper_uid, scenario.ctx());
    assert!(book.price_scale() == 1, 0);
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

// Gap 6 ("`new_with_event_id_override` doesn't change price-scale
// derivation") was removed: `new_with_event_id_override` no longer exists —
// `new`'s `enclosing_object_id` parameter is now mandatory on the single
// remaining constructor, so there is no second construction path left to
// compare against.

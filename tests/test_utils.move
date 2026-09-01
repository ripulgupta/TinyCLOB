/// Shared test-only fixtures used across the split-out topic test modules in
/// this package. Move constants have no visibility modifiers — they are
/// always module-private (`sui move test` rejects `public`/`public(package)
/// const` outright) — so the shared values below are plain private
/// constants, each exposed to sibling `#[test_only]` test modules through a
/// thin `public(package) fun` accessor of the same name in `snake_case`
/// (e.g. `ADMIN` -> `admin()`). Everything else here is `public(package)`
/// directly, and the whole module stays test-only.
#[test_only]
module tiny_clob::test_utils;

use std::unit_test;
use sui::coin;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap};
use tiny_clob::test_markers::{BTC, USDC};

const ADMIN: address = @0xA11CE;
const OTHER: address = @0xB0B;
const TAKER: address = @0x2002;
const MAKER_A: address = @0xA001;
const MAKER_B: address = @0xA002;
const MAKER_C: address = @0xA003;

const MIN_SIZE: u64 = 100;
const MAX_MIN_SIZE: u64 = 1_000_000_000_000_000;
/// `u64::MAX` -- the "unbounded" sentinel for `place_market_order_bid`'s
/// `max_base_out`/`max_quote_in` and `place_market_order_ask`'s
/// `max_base_in` (see their doc comments in `sources/tiny_clob.move`).
const U64_MAX: u64 = 18_446_744_073_709_551_615;

/// Was `CH2_PRICE`/`CH2_SIZE` in the original monolith — renamed since "CH2"
/// was meaningless outside its original context.
const DEFAULT_PRICE: u64 = 50_000;
const DEFAULT_SIZE: u64 = 100;

public(package) fun admin(): address { ADMIN }
public(package) fun other(): address { OTHER }
public(package) fun taker(): address { TAKER }
public(package) fun maker_a(): address { MAKER_A }
public(package) fun maker_b(): address { MAKER_B }
public(package) fun maker_c(): address { MAKER_C }
public(package) fun min_size(): u64 { MIN_SIZE }
public(package) fun max_min_size(): u64 { MAX_MIN_SIZE }
public(package) fun u64_max(): u64 { U64_MAX }
public(package) fun default_price(): u64 { DEFAULT_PRICE }
public(package) fun default_size(): u64 { DEFAULT_SIZE }

/// A realistic BTC(8 decimals)/USDC(6 decimals)-shaped book (`price_scale =
/// 100`; see `full_lifecycle_tests.move`'s header comment for the full
/// derivation), generalized over `Base`/`Quote` so any pair sharing this
/// decimals/precision/exponent shape can reuse it, instead of each test
/// duplicating the inline `tiny_clob::new` call and its derivation comment.
/// Unlike `new_book` (`price_scale == 1`, no rounding to account for), this
/// book requires genuine ceiling rounding in `bid_escrow_amount`/
/// `scaled_ceil_mul_div` for any price that isn't an exact multiple of 100.
public(package) fun realistic_decimals_book<Base, Quote>(
    min_size: u64,
    scenario: &mut ts::Scenario,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<Base, Quote>(min_size, 8, 6, 0, 19, 100 * 497, &wrapper_uid, scenario.ctx());
    wrapper_uid.delete();
    (book, cap)
}

public(package) fun new_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<BTC, USDC>(MIN_SIZE, 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    wrapper_uid.delete();
    (book, cap)
}

public(package) fun destroy_book_and_cap(book: OrderBook<BTC, USDC>, cap: ClobAdminCap) {
    unit_test::destroy(book);
    unit_test::destroy(cap);
}

/// `place_limit_order_bid` no longer takes an explicit `price` — it derives
/// `price = floor(payment.value() * price_scale / expected_base_output)`
/// internally. This helper inverts that: given the `price`/`size` a test
/// wants a resting bid to end up at, it returns the `payment` value that,
/// passed alongside `expected_base_output = size`, makes the new function
/// derive back exactly `price`.
///
/// The natural candidate is `bid_escrow_amount(price, size) ==
/// ceil(price * size / price_scale)` (the same minimal escrow the old
/// explicit-price call used to require) -- but `floor(escrow * price_scale /
/// size)` does not always equal `price` back: it depends on the relative
/// magnitude of `size` vs `price_scale` (see the module-level doc comment on
/// `place_limit_order_bid` for the identity this relies on). Since `escrow`
/// is the *smallest* payment satisfying the lower bound the new function's
/// derivation needs, if it doesn't round-trip back to `price`, no larger
/// payment can either (a larger payment only derives a `price` >= this one).
/// Aborts if no such payment exists for this exact `(price, size)` pair --
/// callers hitting this need a different `(price, size)` combination, since
/// this exact one is no longer constructible without picking raw `price`
/// directly, which is exactly what this redesign disallows.
public(package) fun bid_payment_for_price<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    price: u64,
    size: u64,
): u64 {
    let price_scale = book.price_scale();
    let payment = book.bid_escrow_amount(price, size);
    let derived_price = ((payment as u128) * (price_scale as u128)) / (size as u128);
    assert!(derived_price == (price as u128), 0);
    payment
}

/// Mirrors `bid_payment_for_price` for the ask side: `place_limit_order_ask`
/// derives `price = ceil(expected_quote_output * price_scale / size)` where
/// `size = payment.value()`. This returns the `expected_quote_output` that
/// makes that derivation land back on exactly `price` for a payment of value
/// `size`.
///
/// NOTE: unlike the bid side, the natural first guess of `expected_quote_output
/// == ceil(price * size / price_scale)` (the same shape as
/// `bid_escrow_amount`) does NOT generally round-trip back to `price` here --
/// verified false in general (e.g. `price = 5, size = 3, price_scale = 10`
/// derives back `7`, not `5`). The correct candidate is instead the
/// *largest* `expected_quote_output` for which the derivation is still
/// `<= price`, namely `floor(price * size / price_scale)`: this is checked
/// against the ceiling formula's exact bounds
/// (`(price - 1) * size < expected_quote_output * price_scale <= price *
/// size`) before being returned. Aborts if no `expected_quote_output` exists
/// that reproduces `price` exactly for this `(price, size)` pair -- same
/// caveat as `bid_payment_for_price`.
public(package) fun ask_expected_output_for_price<Base, Quote>(
    book: &OrderBook<Base, Quote>,
    price: u64,
    size: u64,
): u64 {
    // `price == 0` is a trivial, always-reproducible special case
    // (`expected_quote_output == 0` derives `ceil(0 * price_scale / size) ==
    // 0` exactly) -- handled separately to avoid an underflow on `price - 1`
    // below, since callers legitimately use this to construct the
    // `EZeroPrice`-abort fixture.
    if (price == 0) { return 0 };
    let price_scale = book.price_scale();
    let price_u128 = price as u128;
    let size_u128 = size as u128;
    let price_scale_u128 = price_scale as u128;
    let expected_quote_output = (price_u128 * size_u128) / price_scale_u128;
    // Must satisfy (price - 1) * size < expected_quote_output * price_scale
    // <= price * size -- the exact bounds `ceil` needs to land back on `price`.
    assert!(expected_quote_output * price_scale_u128 <= price_u128 * size_u128, 1);
    assert!(
        expected_quote_output * price_scale_u128 > (price_u128 - 1) * size_u128,
        2,
    );
    expected_quote_output as u64
}

/// Rests a bid via `place_limit_order_bid`, discarding the matched/leftover
/// coin legs and returning only the resulting ticket — for call sites that
/// only need the ticket and have no assertions on the trade legs themselves.
public(package) fun rest_bid(
    book: &mut OrderBook<BTC, USDC>,
    price: u64,
    size: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): OrderTicket {
    let payment = coin::mint_for_testing<USDC>(bid_payment_for_price(book, price, size), ctx);
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, size, max_fills, ctx);
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    ticket_opt.destroy_some()
}

/// Mirrors `rest_bid` for the ask side.
public(package) fun rest_ask(
    book: &mut OrderBook<BTC, USDC>,
    price: u64,
    size: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): OrderTicket {
    let expected_quote_output = ask_expected_output_for_price(book, price, size);
    let payment = coin::mint_for_testing<BTC>(size, ctx);
    let (ticket_opt, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(payment, expected_quote_output, max_fills, ctx);
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    ticket_opt.destroy_some()
}

// === Regression: resting-remainder escrow rounding shortfall fixture ===
//
// Book: base_decimals=0, quote_decimals=0, precision=1, exponent=18 =>
// price_scale = ceil(10^0 * 10^1 / 10^0) = 10 exactly (the smallest value
// guaranteeing resolution at least as fine as 10^-1 — see `new`'s doc
// comment). See the topic file using this fixture for the full worked-out
// rounding-shortfall scenario.
//
// `SHORTFALL_PRICE_SCALE` is used only inside `shortfall_book` itself (to
// assert the derived `price_scale` matches what the doc comment above
// expects) — a prior read-only audit's plan claimed it was "referenced
// nowhere except its own declaration" and should be deleted outright, but
// that's not quite accurate: it IS referenced, once, right here. Since
// `shortfall_book` moves here in its entirety, this constant just moves with
// it rather than being deleted.
const SHORTFALL_PRICE_SCALE: u64 = 10;
const SHORTFALL_PRICE: u64 = 5;

public(package) fun shortfall_price(): u64 { SHORTFALL_PRICE }

public(package) fun shortfall_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 1, 18, SHORTFALL_PRICE, &wrapper_uid, scenario.ctx());
    wrapper_uid.delete();
    assert!(book.price_scale() == SHORTFALL_PRICE_SCALE, 0);
    (book, cap)
}

/// Generic body factored out of the four "pair price extremes and adjacent
/// ticks" tests (`usdc_btc_reversed_pair_price_extremes_and_adjacent_ticks`,
/// `btc_sui_pair_price_extremes_and_adjacent_ticks`,
/// `sui_btc_reversed_pair_price_extremes_and_adjacent_ticks`,
/// `wal_sui_same_decimals_pair_price_extremes_and_adjacent_ticks`), which
/// otherwise differed only in `Base`/`Quote`, the book's decimals/precision/
/// exponent, and the hand-derived `p_min`/`p_max`/`p_mid`/`expected_scale`
/// constants. `Quote` doubles as the currency the taker pays in (a bid always
/// pays in the book's quote asset), matching every one of the four original
/// call sites.
public(package) fun assert_extremes_and_adjacent_ticks<Base, Quote>(
    base_decimals: u8,
    quote_decimals: u8,
    precision: u8,
    exponent: u8,
    p_min: u64,
    p_max: u64,
    p_mid: u64,
    expected_scale: u64,
    scenario: &mut ts::Scenario,
) {
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<Base, Quote>(
        MIN_SIZE, base_decimals, quote_decimals, precision, exponent, p_mid, &wrapper_uid, scenario.ctx(),
    );
    wrapper_uid.delete();
    let scale = book.price_scale();
    assert!(scale == expected_scale, 0);

    // `size` must be at least `price_scale` for `place_limit_order_bid`'s new
    // derive-from-payment API to be able to round-trip back to an exact,
    // hand-picked `price`: with `size == price_scale`, `bid_escrow_amount`'s
    // ceiling division is always exact (`escrow == price`, no rounding), so
    // `floor(escrow * price_scale / size) == price` always holds regardless
    // of `price`. This replaces the old fixed `MIN_SIZE`/`1_000` sizes (which
    // predate the "no explicit `price` argument" redesign and can no longer
    // be used unmodified for the large-`price_scale` books this helper
    // covers -- e.g. `price_scale == 1_000_000` with `size == 100` cannot
    // reconstruct a small `price` like `1` at all). The extremes/adjacent-tick
    // behavior under test is unaffected by the specific size chosen.
    let size = if (MIN_SIZE > scale) { MIN_SIZE } else { scale };

    // (b) Extreme minimum representable raw price: rests, checks depth,
    // cancels, verifies exact escrow refund.
    let min_escrow = book.bid_escrow_amount(p_min, size);
    let min_payment = coin::mint_for_testing<Quote>(bid_payment_for_price(&book, p_min, size), scenario.ctx());
    let (min_ticket_opt, min_matched, min_leftover, min_stopped) =
        book.place_limit_order_bid(min_payment, size, 10, scenario.ctx());
    assert!(!min_stopped, 1);
    assert!(min_matched.burn_for_testing() == 0, 2);
    assert!(min_leftover.burn_for_testing() == 0, 3);
    // Quote-denominated for a bid (see `bid_quote_escrow_at_price`'s doc
    // comment) -- equal to the escrow reserved, not the Base `size`.
    assert!(book.bid_quote_escrow_at_price(p_min) == min_escrow, 4);
    let (min_b, min_q) = book.cancel_order(min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(min_b.burn_for_testing() == 0, 5);
    assert!(min_q.burn_for_testing() == min_escrow, 6);

    // (c) Extreme maximum representable raw price: same checks.
    let max_escrow = book.bid_escrow_amount(p_max, size);
    let max_payment = coin::mint_for_testing<Quote>(bid_payment_for_price(&book, p_max, size), scenario.ctx());
    let (max_ticket_opt, max_matched, max_leftover, max_stopped) =
        book.place_limit_order_bid(max_payment, size, 10, scenario.ctx());
    assert!(!max_stopped, 7);
    assert!(max_matched.burn_for_testing() == 0, 8);
    assert!(max_leftover.burn_for_testing() == 0, 9);
    assert!(book.bid_quote_escrow_at_price(p_max) == max_escrow, 10);
    let (max_b, max_q) = book.cancel_order(max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(max_b.burn_for_testing() == 0, 11);
    assert!(max_q.burn_for_testing() == max_escrow, 12);

    // (d) Two adjacent raw price ticks at a realistic fair-value level: both
    // rest as genuinely distinct price levels. Reuses the same
    // round-trip-safe `size` as (b)/(c) above (was `1_000` previously; see
    // the comment on `size` above for why that no longer works unmodified
    // for every `price_scale` this helper is exercised against).
    let mid_size = size;
    let mid_escrow = book.bid_escrow_amount(p_mid, mid_size);
    let mid_payment = coin::mint_for_testing<Quote>(bid_payment_for_price(&book, p_mid, mid_size), scenario.ctx());
    let (mid_ticket_opt, mid_matched, mid_leftover, mid_stopped) =
        book.place_limit_order_bid(mid_payment, mid_size, 10, scenario.ctx());
    assert!(!mid_stopped, 13);
    assert!(mid_matched.burn_for_testing() == 0, 14);
    assert!(mid_leftover.burn_for_testing() == 0, 15);

    let p_mid_next = p_mid + 1;
    let mid_next_escrow = book.bid_escrow_amount(p_mid_next, mid_size);
    let mid_next_payment = coin::mint_for_testing<Quote>(bid_payment_for_price(&book, p_mid_next, mid_size), scenario.ctx());
    let (mid_next_ticket_opt, mid_next_matched, mid_next_leftover, mid_next_stopped) =
        book.place_limit_order_bid(mid_next_payment, mid_size, 10, scenario.ctx());
    assert!(!mid_next_stopped, 16);
    assert!(mid_next_matched.burn_for_testing() == 0, 17);
    assert!(mid_next_leftover.burn_for_testing() == 0, 18);

    assert!(book.bid_quote_escrow_at_price(p_mid) == mid_escrow, 19);
    assert!(book.bid_quote_escrow_at_price(p_mid_next) == mid_next_escrow, 20);
    assert!(p_mid != p_mid_next, 21);

    unit_test::destroy(mid_ticket_opt.destroy_some());
    unit_test::destroy(mid_next_ticket_opt.destroy_some());
    unit_test::destroy(book);
    unit_test::destroy(cap);
}

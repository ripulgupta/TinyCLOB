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
public(package) fun default_price(): u64 { DEFAULT_PRICE }
public(package) fun default_size(): u64 { DEFAULT_SIZE }

/// A realistic BTC(8 decimals)/USDC(6 decimals)-shaped book (`price_scale =
/// 184`; see `full_lifecycle_tests.move`'s header comment for the full
/// derivation), generalized over `Base`/`Quote` so any pair sharing this
/// decimals/precision/exponent shape can reuse it, instead of each test
/// duplicating the inline `tiny_clob::new` call and its derivation comment.
/// Unlike `new_book` (`price_scale == 1`, no rounding to account for), this
/// book requires genuine ceiling rounding in `bid_escrow_amount`/
/// `scaled_ceil_mul_div` for any price that isn't an exact multiple of 184.
public(package) fun realistic_decimals_book<Base, Quote>(
    min_size: u64,
    scenario: &mut ts::Scenario,
): (OrderBook<Base, Quote>, ClobAdminCap) {
    tiny_clob::new<Base, Quote>(min_size, 8, 6, 0, 19, 184 * 497, scenario.ctx())
}

public(package) fun new_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    tiny_clob::new<BTC, USDC>(MIN_SIZE, 0, 0, 0, 19, 1, scenario.ctx())
}

public(package) fun destroy_book_and_cap(book: OrderBook<BTC, USDC>, cap: ClobAdminCap) {
    unit_test::destroy(book);
    unit_test::destroy(cap);
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
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(price, size), ctx);
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(price, size, payment, max_fills, ctx);
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
    let payment = coin::mint_for_testing<BTC>(size, ctx);
    let (ticket_opt, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(price, size, payment, max_fills, ctx);
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();
    ticket_opt.destroy_some()
}

// === Regression: resting-remainder escrow rounding shortfall fixture ===
//
// Book: base_decimals=0, quote_decimals=0, precision=1, exponent=18 =>
// price_scale = floor(u64::MAX / 10^18) = 18 exactly. See the topic file
// using this fixture for the full worked-out rounding-shortfall scenario.
//
// `SHORTFALL_PRICE_SCALE` is used only inside `shortfall_book` itself (to
// assert the derived `price_scale` matches what the doc comment above
// expects) — a prior read-only audit's plan claimed it was "referenced
// nowhere except its own declaration" and should be deleted outright, but
// that's not quite accurate: it IS referenced, once, right here. Since
// `shortfall_book` moves here in its entirety, this constant just moves with
// it rather than being deleted.
const SHORTFALL_PRICE_SCALE: u64 = 18;
const SHORTFALL_PRICE: u64 = 5;

public(package) fun shortfall_price(): u64 { SHORTFALL_PRICE }

public(package) fun shortfall_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    let (book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 1, 18, SHORTFALL_PRICE, scenario.ctx());
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
    let (mut book, cap) = tiny_clob::new<Base, Quote>(
        MIN_SIZE, base_decimals, quote_decimals, precision, exponent, p_mid, scenario.ctx(),
    );
    let scale = book.price_scale();
    assert!(scale == expected_scale, 0);

    // (b) Extreme minimum representable raw price: rests, checks depth,
    // cancels, verifies exact escrow refund.
    let size = MIN_SIZE;
    let min_escrow = book.bid_escrow_amount(p_min, size);
    let min_payment = coin::mint_for_testing<Quote>(min_escrow, scenario.ctx());
    let (min_ticket_opt, min_matched, min_leftover, min_stopped) =
        book.place_limit_order_bid(p_min, size, min_payment, 10, scenario.ctx());
    assert!(!min_stopped, 1);
    assert!(min_matched.burn_for_testing() == 0, 2);
    assert!(min_leftover.burn_for_testing() == 0, 3);
    assert!(book.depth_at_price(tiny_clob::bid_for_testing(), p_min) == size, 4);
    let (min_b, min_q) = book.cancel_order(min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(min_b.burn_for_testing() == 0, 5);
    assert!(min_q.burn_for_testing() == min_escrow, 6);

    // (c) Extreme maximum representable raw price: same checks.
    let max_escrow = book.bid_escrow_amount(p_max, size);
    let max_payment = coin::mint_for_testing<Quote>(max_escrow, scenario.ctx());
    let (max_ticket_opt, max_matched, max_leftover, max_stopped) =
        book.place_limit_order_bid(p_max, size, max_payment, 10, scenario.ctx());
    assert!(!max_stopped, 7);
    assert!(max_matched.burn_for_testing() == 0, 8);
    assert!(max_leftover.burn_for_testing() == 0, 9);
    assert!(book.depth_at_price(tiny_clob::bid_for_testing(), p_max) == size, 10);
    let (max_b, max_q) = book.cancel_order(max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(max_b.burn_for_testing() == 0, 11);
    assert!(max_q.burn_for_testing() == max_escrow, 12);

    // (d) Two adjacent raw price ticks at a realistic fair-value level: both
    // rest as genuinely distinct price levels.
    let mid_size = 1_000;
    let mid_escrow = book.bid_escrow_amount(p_mid, mid_size);
    let mid_payment = coin::mint_for_testing<Quote>(mid_escrow, scenario.ctx());
    let (mid_ticket_opt, mid_matched, mid_leftover, mid_stopped) =
        book.place_limit_order_bid(p_mid, mid_size, mid_payment, 10, scenario.ctx());
    assert!(!mid_stopped, 13);
    assert!(mid_matched.burn_for_testing() == 0, 14);
    assert!(mid_leftover.burn_for_testing() == 0, 15);

    let p_mid_next = p_mid + 1;
    let mid_next_escrow = book.bid_escrow_amount(p_mid_next, mid_size);
    let mid_next_payment = coin::mint_for_testing<Quote>(mid_next_escrow, scenario.ctx());
    let (mid_next_ticket_opt, mid_next_matched, mid_next_leftover, mid_next_stopped) =
        book.place_limit_order_bid(p_mid_next, mid_size, mid_next_payment, 10, scenario.ctx());
    assert!(!mid_next_stopped, 16);
    assert!(mid_next_matched.burn_for_testing() == 0, 17);
    assert!(mid_next_leftover.burn_for_testing() == 0, 18);

    assert!(book.depth_at_price(tiny_clob::bid_for_testing(), p_mid) == mid_size, 19);
    assert!(book.depth_at_price(tiny_clob::bid_for_testing(), p_mid_next) == mid_size, 20);
    assert!(p_mid != p_mid_next, 21);

    unit_test::destroy(mid_ticket_opt.destroy_some());
    unit_test::destroy(mid_next_ticket_opt.destroy_some());
    unit_test::destroy(book);
    unit_test::destroy(cap);
}

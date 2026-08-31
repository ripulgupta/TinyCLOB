/// Regression tests for two Low-severity findings from a security audit
/// (L-A and L-B) that are now FIXED, not merely documented as accepted.
///
/// Both findings traced back to `fill_level_bid`/`fill_level_ask` always
/// using `scaled_ceil_mul_div` (ceiling division) to compute a fill's
/// `quote_cost`, independently per fill -- ceiling division is superadditive
/// across separate resting orders at the same price, so a taker sweeping
/// fragmented liquidity paid strictly more Quote than sweeping one
/// consolidated order for the identical Base delivered (L-A), and a bid
/// escrowed with the textbook-exact `bid_escrow_amount` could underfill
/// against a sufficiently fragmented ask book (L-B).
///
/// The fix classifies each fill as MAKER-limited (it fully drains the
/// resting order being matched) or TAKER-limited (the maker still has size
/// left afterward), and only rounds up on the taker-limited branch, where
/// the fill's boundary is genuinely set by the taker's own remaining
/// size/budget rather than by fully draining a maker:
///
/// - `fill_level_bid` (bid taker vs. resting asks): maker-limited now floors
///   (`max(floor(price * fill_qty / price_scale), 1)`); taker-limited is
///   unchanged (ceiling).
/// - `fill_level_ask` (ask taker vs. resting bids): maker-limited now simply
///   drains `escrow_quote_value(&maker_order)`; taker-limited is
///   `min(max(floor(price * fill_qty / price_scale), 1),
///   escrow_quote_value(&maker_order))`.
///
/// Every fill in both tests below is maker-limited (each fragmented resting
/// order is sized 1 and always fully drained by a single fill), so both now
/// use the new floor formula, and fragmentation no longer costs the taker
/// any extra Quote: floor division is NOT superadditive the way ceiling
/// division is (in fact `floor(sum) >= sum(floor)` in general, and here the
/// two sides come out exactly equal). `docs/FEATURES.md`'s
/// `min_size * price / price_scale` sizing guidance remains good practice
/// for keeping any residual dust negligible, but is no longer needed to
/// bound a superadditive-cost failure mode, since that failure mode no
/// longer exists for maker-limited fills.
#[test_only]
module tiny_clob::price_rounding_fragmentation_tests;

use sui::coin;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket};
use tiny_clob::test_markers::{BTC, USDC};
use tiny_clob::test_utils::{Self, admin, maker_a, taker, realistic_decimals_book, destroy_book_and_cap, u64_max};

// `realistic_decimals_book<BTC, USDC>(1, &mut scenario)` (base_decimals=8,
// quote_decimals=6, precision=0, exponent=19) derives `price_scale == 100`
// (see `full_lifecycle_tests.move`'s header comment for the full
// derivation). `PRICE` is deliberately NOT a multiple of 100, so the floor
// term below performs genuine, nontrivial rounding on every fill instead of
// dividing evenly.
//
// FRAGMENT SIZE (redesigned for the no-explicit-`price`-argument change):
// `place_limit_order_ask` now derives its resting price from
// `expected_quote_output`/`size`, and any legitimately-derivable nonzero
// price satisfies `price * size >= price_scale` (`expected_quote_output >=
// 1`). At this book's `price_scale == 100`, that means a resting ask can
// never be constructed with a size smaller than 100 while still deriving
// back exactly `PRICE` -- the ORIGINAL size-1-per-fragment fixture (`n`
// separate 1-unit asks) is no longer constructible at all. `FRAGMENT_SIZE`
// (101, not a multiple of `price_scale`, so each fragment's own fill still
// genuinely floor-rounds) replaces the old implicit size-1 fragment, and
// `TOTAL_SIZE` is `FRAGMENT_SIZE * FRAGMENT_COUNT` accordingly -- the
// fragmentation story (`FRAGMENT_COUNT` separate maker-limited fills vs. one
// consolidated fill) is otherwise unchanged, with every downstream quote
// amount below recomputed for the new numbers.
const PRICE: u64 = 100 * 497 + 1; // 49_701
const FRAGMENT_SIZE: u64 = 101;
const FRAGMENT_COUNT: u64 = 5;
const TOTAL_SIZE: u64 = FRAGMENT_SIZE * FRAGMENT_COUNT; // 505
const MAX_FILLS: u64 = 200;
const BUDGET: u64 = 10_000_000;

/// Places `n` separate `FRAGMENT_SIZE`-unit resting asks at `PRICE`, via `n`
/// distinct `place_limit_order_ask` calls, returning their order tickets so
/// the caller can clean them up. This is the "fragmented liquidity" fixture
/// shared by both tests below: `n` maker orders of size `FRAGMENT_SIZE`
/// each, instead of one maker order of size `n * FRAGMENT_SIZE`.
fun rest_n_fragmented_asks(book: &mut OrderBook<BTC, USDC>, n: u64, ctx: &mut TxContext): vector<OrderTicket> {
    let mut tickets = vector[];
    let mut i = 0;
    while (i < n) {
        let payment = coin::mint_for_testing<BTC>(FRAGMENT_SIZE, ctx);
        let expected_quote_output = test_utils::ask_expected_output_for_price(book, PRICE, FRAGMENT_SIZE);
        let (ticket_opt, leftover_base, matched_quote, _stopped) =
            book.place_limit_order_ask(payment, expected_quote_output, MAX_FILLS, ctx);
        leftover_base.burn_for_testing();
        matched_quote.burn_for_testing();
        tickets.push_back(ticket_opt.destroy_some());
        i = i + 1;
    };
    tickets
}

/// Former finding L-A, now fixed: buying the same `TOTAL_SIZE` (505) Base
/// total costs a taker the SAME Quote whether the resting liquidity is one
/// consolidated 505-unit ask or `FRAGMENT_COUNT` (5) separate fragmented
/// `FRAGMENT_SIZE`-unit (101) asks, because every fill below is
/// maker-limited (fully drains its resting order) and maker-limited fills
/// now floor instead of ceiling.
///
/// Case A (one consolidated ask of size 505, a single maker-limited fill):
///   quote_cost = max(floor(49_701 * 505 / 100), 1) = floor(25_099_005 / 100)
///              = floor(250_990.05) = 250_990
///
/// Case B (5 separate asks of size 101 each, 5 maker-limited fills):
///   per-fill cost = max(floor(49_701 * 101 / 100), 1) = floor(50_198.01)
///                 = 50_198
///   total across 5 fills = 5 * 50_198 = 250_990
///
/// Identical Base delivered, identical Quote paid: fragmenting the maker's
/// liquidity no longer costs the taker anything extra.
#[test]
fun fragmenting_asks_no_longer_costs_taker_more_quote_than_one_consolidated_ask() {
    let mut scenario = ts::begin(admin());

    // Case A: one consolidated 505-unit ask.
    let (mut book_a, cap_a) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    scenario.next_tx(maker_a());
    let ask_payment = coin::mint_for_testing<BTC>(TOTAL_SIZE, scenario.ctx());
    let ask_expected_quote_output = test_utils::ask_expected_output_for_price(&book_a, PRICE, TOTAL_SIZE);
    let (ask_ticket_opt, ask_leftover_base, ask_matched_quote, _) =
        book_a.place_limit_order_ask(ask_payment, ask_expected_quote_output, MAX_FILLS, scenario.ctx());
    ask_leftover_base.burn_for_testing();
    ask_matched_quote.burn_for_testing();
    let ask_ticket = ask_ticket_opt.destroy_some();

    scenario.next_tx(taker());
    let bid_payment_a = coin::mint_for_testing<USDC>(BUDGET, scenario.ctx());
    let (matched_base_a, leftover_quote_a, stopped_a) = book_a.place_market_order_bid(bid_payment_a, MAX_FILLS, 0, TOTAL_SIZE, u64_max(), scenario.ctx(),
    );
    assert!(!stopped_a, 0);
    let base_received_a = matched_base_a.burn_for_testing();
    let leftover_a = leftover_quote_a.burn_for_testing();
    let quote_spent_a = BUDGET - leftover_a;
    assert!(base_received_a == TOTAL_SIZE, 1);
    assert!(quote_spent_a == 250_990, 2);

    ask_ticket.destroy_ticket_unconditionally();
    destroy_book_and_cap(book_a, cap_a);

    // Case B: `FRAGMENT_COUNT` separate `FRAGMENT_SIZE`-unit asks at the
    // identical price, fresh book.
    let (mut book_b, cap_b) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    scenario.next_tx(maker_a());
    let mut ask_tickets_b = rest_n_fragmented_asks(&mut book_b, FRAGMENT_COUNT, scenario.ctx());

    scenario.next_tx(taker());
    let bid_payment_b = coin::mint_for_testing<USDC>(BUDGET, scenario.ctx());
    let (matched_base_b, leftover_quote_b, stopped_b) = book_b.place_market_order_bid(bid_payment_b, MAX_FILLS, 0, TOTAL_SIZE, u64_max(), scenario.ctx(),
    );
    assert!(!stopped_b, 3);
    let base_received_b = matched_base_b.burn_for_testing();
    let leftover_b = leftover_quote_b.burn_for_testing();
    let quote_spent_b = BUDGET - leftover_b;
    assert!(base_received_b == TOTAL_SIZE, 4); // identical Base delivered to case A
    assert!(quote_spent_b == 250_990, 5);

    // The core of the fix: identical Base delivered, identical Quote paid,
    // regardless of how the maker's liquidity was fragmented.
    assert!(quote_spent_b == quote_spent_a, 6);

    while (!ask_tickets_b.is_empty()) {
        ask_tickets_b.pop_back().destroy_ticket_unconditionally();
    };
    ask_tickets_b.destroy_empty();
    destroy_book_and_cap(book_b, cap_b);

    scenario.end();
}

/// Former finding L-B, now fixed: a resting limit bid escrowed with the
/// textbook-correct `bid_escrow_amount` for a given quantity at a given
/// price now fully fills against a fragmented ask-side book -- it no longer
/// underfills, because the fragmented book's cumulative maker-limited cost
/// (all floor-rounded) never exceeds the single ceiling-rounded escrow
/// figure.
///
/// `escrow = bid_escrow_amount(book, PRICE, TOTAL_SIZE) = ceil(49_701 * 505 /
/// 100) = 250_991` (unchanged formula/value -- `bid_escrow_amount` itself
/// was not changed by this fix, only how fills consume it).
///
/// Against `FRAGMENT_COUNT` (5) separate `FRAGMENT_SIZE`-unit (101) resting
/// asks, each fill is maker-limited and now costs `max(floor(49_701 * 101 /
/// 100), 1) = 50_198`. Cumulative cost after all 5 fills is `50_198 * 5 =
/// 250_990 <= 250_991`, so all 505 units fill, leaving exactly `250_991 -
/// 250_990 = 1` Quote atom of escrow leftover -- unlike before the fix,
/// where the same escrow could underfill the requested size.
#[test]
fun limit_bid_no_longer_underfills_against_fragmented_book_with_exact_escrow() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);

    scenario.next_tx(maker_a());
    let mut ask_tickets = rest_n_fragmented_asks(&mut book, FRAGMENT_COUNT, scenario.ctx());

    scenario.next_tx(taker());
    let escrow = book.bid_escrow_amount(PRICE, TOTAL_SIZE);
    assert!(escrow == 250_991, 0);

    let payment = coin::mint_for_testing<USDC>(escrow, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        book.place_limit_order_bid(payment, TOTAL_SIZE, MAX_FILLS, scenario.ctx());
    assert!(!stopped, 1);

    let base_received = matched_base.burn_for_testing();
    assert!(base_received == TOTAL_SIZE, 2); // now fills completely, unlike before the fix

    let leftover = leftover_quote.burn_for_testing();
    assert!(leftover == 1, 3); // 250_991 - (50_198 * 5) = 1 atom of dust, nothing stranded

    // Fully filled, so no resting remainder -- the order never rests.
    if (ticket_opt.is_some()) {
        ticket_opt.destroy_some().destroy_ticket_unconditionally();
    } else {
        ticket_opt.destroy_none();
    };

    while (!ask_tickets.is_empty()) {
        ask_tickets.pop_back().destroy_ticket_unconditionally();
    };
    ask_tickets.destroy_empty();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

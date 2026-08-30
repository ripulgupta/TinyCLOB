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
use tiny_clob::test_utils::{admin, maker_a, taker, realistic_decimals_book, destroy_book_and_cap};

// `realistic_decimals_book<BTC, USDC>(1, &mut scenario)` (base_decimals=8,
// quote_decimals=6, precision=0, exponent=19) derives `price_scale == 184`
// (see `full_lifecycle_tests.move`'s header comment for the full
// derivation). `PRICE` is deliberately NOT a multiple of 184, so the floor
// term below performs genuine, nontrivial rounding on every fill instead of
// dividing evenly.
const PRICE: u64 = 184 * 497 + 1; // 91_449
const MAX_FILLS: u64 = 200;
const BUDGET: u64 = 10_000_000;

/// Places `n` separate 1-unit resting asks at `PRICE`, via `n` distinct
/// `place_limit_order_ask` calls, returning their order tickets so the
/// caller can clean them up. This is the "fragmented liquidity" fixture
/// shared by both tests below: `n` maker orders of size 1 each, instead of
/// one maker order of size `n`.
fun rest_n_fragmented_asks(book: &mut OrderBook<BTC, USDC>, n: u64, ctx: &mut TxContext): vector<OrderTicket> {
    let mut tickets = vector[];
    let mut i = 0;
    while (i < n) {
        let payment = coin::mint_for_testing<BTC>(1, ctx);
        let (ticket_opt, leftover_base, matched_quote, _stopped) =
            tiny_clob::place_limit_order_ask(book, PRICE, 1, payment, MAX_FILLS, ctx);
        coin::burn_for_testing(leftover_base);
        coin::burn_for_testing(matched_quote);
        tickets.push_back(option::destroy_some(ticket_opt));
        i = i + 1;
    };
    tickets
}

/// Former finding L-A, now fixed: buying the same 100 Base total costs a
/// taker the SAME Quote whether the resting liquidity is one consolidated
/// 100-unit ask or 100 separate fragmented 1-unit asks, because every fill
/// below is maker-limited (fully drains its resting order) and
/// maker-limited fills now floor instead of ceiling.
///
/// Case A (one consolidated ask of size 100, a single maker-limited fill):
///   quote_cost = max(floor(91_449 * 100 / 184), 1) = floor(9_144_900 / 184)
///              = floor(49_700.543...) = 49_700
///
/// Case B (100 separate asks of size 1 each, 100 maker-limited fills):
///   per-fill cost = max(floor(91_449 * 1 / 184), 1) = floor(497.005...) = 497
///   total across 100 fills = 100 * 497 = 49_700
///
/// Identical Base delivered, identical Quote paid: fragmenting the maker's
/// liquidity no longer costs the taker anything extra.
#[test]
fun fragmenting_asks_no_longer_costs_taker_more_quote_than_one_consolidated_ask() {
    let mut scenario = ts::begin(admin());

    // Case A: one consolidated 100-unit ask.
    let (mut book_a, cap_a) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    scenario.next_tx(maker_a());
    let ask_payment = coin::mint_for_testing<BTC>(100, scenario.ctx());
    let (ask_ticket_opt, ask_leftover_base, ask_matched_quote, _) =
        tiny_clob::place_limit_order_ask(&mut book_a, PRICE, 100, ask_payment, MAX_FILLS, scenario.ctx());
    coin::burn_for_testing(ask_leftover_base);
    coin::burn_for_testing(ask_matched_quote);
    let ask_ticket = option::destroy_some(ask_ticket_opt);

    scenario.next_tx(taker());
    let bid_payment_a = coin::mint_for_testing<USDC>(BUDGET, scenario.ctx());
    let (matched_base_a, leftover_quote_a, stopped_a) = tiny_clob::place_market_order_bid(
        &mut book_a, 100, BUDGET, bid_payment_a, MAX_FILLS, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped_a, 0);
    let base_received_a = coin::burn_for_testing(matched_base_a);
    let leftover_a = coin::burn_for_testing(leftover_quote_a);
    let quote_spent_a = BUDGET - leftover_a;
    assert!(base_received_a == 100, 1);
    assert!(quote_spent_a == 49_700, 2);

    tiny_clob::destroy_ticket_unconditionally(ask_ticket);
    destroy_book_and_cap(book_a, cap_a);

    // Case B: 100 separate 1-unit asks at the identical price, fresh book.
    let (mut book_b, cap_b) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    scenario.next_tx(maker_a());
    let mut ask_tickets_b = rest_n_fragmented_asks(&mut book_b, 100, scenario.ctx());

    scenario.next_tx(taker());
    let bid_payment_b = coin::mint_for_testing<USDC>(BUDGET, scenario.ctx());
    let (matched_base_b, leftover_quote_b, stopped_b) = tiny_clob::place_market_order_bid(
        &mut book_b, 100, BUDGET, bid_payment_b, MAX_FILLS, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped_b, 3);
    let base_received_b = coin::burn_for_testing(matched_base_b);
    let leftover_b = coin::burn_for_testing(leftover_quote_b);
    let quote_spent_b = BUDGET - leftover_b;
    assert!(base_received_b == 100, 4); // identical Base delivered to case A
    assert!(quote_spent_b == 49_700, 5);

    // The core of the fix: identical Base delivered, identical Quote paid,
    // regardless of how the maker's liquidity was fragmented.
    assert!(quote_spent_b == quote_spent_a, 6);

    while (!ask_tickets_b.is_empty()) {
        tiny_clob::destroy_ticket_unconditionally(ask_tickets_b.pop_back());
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
/// `escrow = bid_escrow_amount(book, PRICE, 100) = ceil(91_449 * 100 / 184)
/// = 49_701` (unchanged formula/value -- `bid_escrow_amount` itself was not
/// changed by this fix, only how fills consume it).
///
/// Against 100 separate 1-unit resting asks, each fill is maker-limited and
/// now costs `max(floor(91_449 / 184), 1) = 497` (vs. the old ceiling-based
/// 498). Cumulative cost after all 100 fills is `497 * 100 = 49_700 <=
/// 49_701`, so all 100 units fill, leaving exactly `49_701 - 49_700 = 1`
/// Quote atom of escrow leftover -- unlike before the fix, where the same
/// escrow could only back 99 of the 100 requested units.
#[test]
fun limit_bid_no_longer_underfills_against_fragmented_book_with_exact_escrow() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);

    scenario.next_tx(maker_a());
    let mut ask_tickets = rest_n_fragmented_asks(&mut book, 100, scenario.ctx());

    scenario.next_tx(taker());
    let escrow = tiny_clob::bid_escrow_amount(&book, PRICE, 100);
    assert!(escrow == 49_701, 0);

    let payment = coin::mint_for_testing<USDC>(escrow, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, PRICE, 100, payment, MAX_FILLS, scenario.ctx());
    assert!(!stopped, 1);

    let base_received = coin::burn_for_testing(matched_base);
    assert!(base_received == 100, 2); // now fills completely, unlike before the fix

    let leftover = coin::burn_for_testing(leftover_quote);
    assert!(leftover == 1, 3); // 49_701 - (497 * 100) = 1 atom of dust, nothing stranded

    // Fully filled, so no resting remainder -- the order never rests.
    if (ticket_opt.is_some()) {
        tiny_clob::destroy_ticket_unconditionally(option::destroy_some(ticket_opt));
    } else {
        option::destroy_none(ticket_opt);
    };

    while (!ask_tickets.is_empty()) {
        tiny_clob::destroy_ticket_unconditionally(ask_tickets.pop_back());
    };
    ask_tickets.destroy_empty();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

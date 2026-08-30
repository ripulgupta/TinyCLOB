/// Tests for the fee-accounting redesign: deferred-and-aggregated taker fee
/// (accumulated once per call, after matching, instead of per fill) and the
/// maker-fee reserve/true-up (each fill's own ceiling-rounded fee is set
/// aside per-order, and only the CORRECT aggregate fee -- computed once, at
/// conclusion -- is ever actually collected, with any superadditive slack
/// refunded back to the maker). See the project's audit notes, findings
/// L-01/F-6.
#[test_only]
module tiny_clob::fee_redesign_tests;

use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, ClobAdminCap};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC};
use tiny_clob::test_utils::{Self, admin, other, maker_a, new_book, realistic_decimals_book, destroy_book_and_cap};

// `new_book` (base_decimals = quote_decimals = precision = 0, exponent =
// 19) derives `price_scale == 1`, so `quote_cost == price * fill_qty`
// exactly, with no scaling rounding to account for -- every expected value
// below is computed by hand from that identity plus `fee_amount`'s ceiling
// formula (`ceil(x * bps / 10_000)`).
const PRICE: u64 = 100;
const MAKER_FEE_BPS: u64 = 1;

// The two `realistic_decimals_book`-based true-up tests below use a
// deliberately non-multiple-of-184 price so `bid_escrow_amount` itself
// requires genuine ceiling rounding (`price_scale == 184`; see
// `full_lifecycle_tests.move`'s header comment for the full derivation),
// instead of `PRICE`/`new_book()`'s `price_scale == 1` shape where
// `quote_cost == price * size` exactly.
const REALISTIC_PRICE: u64 = 1_000;

/// Category (a): fill-drain, inside `fill_level_bid` -- an ask-side maker
/// (fee denominated in Quote) fully drained across two separate 1-unit
/// fills. Under the rounding-direction fix (findings L-A/L-B), a fill's
/// `quote_cost` formula depends on whether it fully drains the maker:
///   - Fill 1 (ask still has 1 unit left afterward -- taker-limited, formula
///     UNCHANGED): `quote_cost = ceil(1_000 * 1 / 184) = ceil(5.43...) = 6`.
///   - Fill 2 (fully drains the ask -- maker-limited, formula CHANGED to
///     floor): `quote_cost = max(floor(1_000 * 1 / 184), 1) =
///     max(5, 1) = 5` (was 6 under the old ceiling formula).
/// Each fill's own dust fee still independently ceiling-rounds to 1
/// (`ceil(6 * 1 / 10_000) = 1`, `ceil(5 * 1 / 10_000) = 1`), for a reserve
/// of 2. The CORRECT aggregate fee owed on the full 11-unit basis (6 + 5) is
/// `ceil(11 * 1 / 10_000) = 1`, so this order's conclusion must refund
/// exactly 1 unit of slack back to the maker instead of over-collecting the
/// naive per-fill sum of 2.
///
/// Uses `realistic_decimals_book` (`price_scale == 184`) with a
/// non-multiple-of-184 price, so each fill's own `quote_cost` -- the basis
/// each per-fill fee and the final aggregate fee are computed from -- is
/// itself genuinely rounded (ceiling on fill 1, floor on fill 2), unlike
/// `new_book()`'s `price_scale == 1` shape where `quote_cost == price`
/// exactly and no such rounding ever occurs.
#[test]
fun maker_fee_reserve_trues_up_on_fill_drain_with_nonzero_slack() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    cap.clob_admin_set_maker_fee(&mut book, MAKER_FEE_BPS);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(2);
    let ask = order::new<BTC, USDC>(order_id, other(), 2, option::some(escrow), option::none(), MAKER_FEE_BPS);
    book.insert_resting_order_for_testing(false, REALISTIC_PRICE, ask, scenario.ctx());

    let unit_quote_cost = book.bid_escrow_amount(REALISTIC_PRICE, 1);
    assert!(unit_quote_cost == 6, 100);

    // Fill 1: 1 unit -- ask still rests with 1 unit remaining afterward.
    let payment1 = coin::mint_for_testing<USDC>(unit_quote_cost, scenario.ctx());
    let (mb1, mq1, _, _, _) = book.match_bid_for_testing(
        option::some(REALISTIC_PRICE), 1, payment1, 1_000_000, scenario.ctx(),
    );
    mb1.burn_for_testing();
    mq1.burn_for_testing();
    let (fee_base_mid, fee_quote_mid) = book.fee_accumulator_balances();
    assert!(fee_base_mid == 0 && fee_quote_mid == 0, 0); // still resting: fee only reserved, not collected
    assert!(event::events_by_type<tiny_clob::MakerFeeSettled>().length() == 0, 1);

    // Fill 2: 1 more unit -- fully drains the ask, triggering conclusion.
    let payment2 = coin::mint_for_testing<USDC>(unit_quote_cost, scenario.ctx());
    let (mb2, mq2, remaining_size2, _, _) = book.match_bid_for_testing(
        option::some(REALISTIC_PRICE), 1, payment2, 1_000_000, scenario.ctx(),
    );
    mb2.burn_for_testing();
    mq2.burn_for_testing();
    assert!(remaining_size2 == 0, 2);

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 3);
    let (ev_order_id, ev_book_id, ev_maker, ev_amount) = settled[0].maker_fee_settled_fields_for_testing();
    assert!(ev_order_id == order_id, 4);
    assert!(ev_book_id == book.id_for_testing(), 5);
    assert!(ev_maker == other(), 6);
    assert!(ev_amount == 1, 7); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == 0, 8);
    assert!(fee_quote_after == 1, 9);

    // The maker's pooled proceeds must reflect the slack refund: 5 (fill 1,
    // quote_cost=6 net of its own dust fee of 1) + 5 (fill 2's net-of-fee
    // quote_cost(5) - fee(1) = 4, plus the 1-unit slack folded in at
    // conclusion) = 10, not 9 (which is what over-collecting the naive
    // per-fill sum would have left).
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    scenario.next_tx(other());
    let payout = ts::take_from_address<coin::Coin<USDC>>(&scenario, other());
    assert!(payout.value() == 10, 10);
    payout.burn_for_testing();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Category (b): `cancel_order` -- a bid-side maker (fee denominated in
/// Base) partially filled across two 100-unit fills, each independently
/// ceiling-rounding its own fee to 1 (`ceil(100 * 1 / 10_000) = 1`), for a
/// reserve of 2. The CORRECT aggregate fee on the 200-unit basis is
/// `ceil(200 * 1 / 10_000) = 1`. The order never concludes via a fill (it
/// still rests with 100 units remaining), so cancellation is what must
/// trigger the true-up and refund the 1-unit slack -- folded directly into
/// the escrow leg returned to the caller, since a bid order's `escrow_base`
/// starts as `None`.
#[test]
fun maker_fee_reserve_trues_up_on_cancel_order_with_nonzero_slack() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_maker_fee(&mut book, MAKER_FEE_BPS);

    scenario.next_tx(maker_a());
    let payment = coin::mint_for_testing<USDC>(book.bid_escrow_amount(PRICE, 300), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(PRICE, 300, payment, 1_000_000, scenario.ctx());
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();
    let ticket = ticket_opt.destroy_some();
    let order_id = ticket.ticket_order_id();

    // Two 100-unit ask fills against the resting bid.
    scenario.next_tx(other());
    let mut i = 0;
    while (i < 2) {
        let ask_payment = coin::mint_for_testing<BTC>(100, scenario.ctx());
        let (leftover_base, matched_quote, _) = book.place_market_order_ask(
            100, ask_payment, 1_000_000, option::none(), option::none(), scenario.ctx(),
        );
        leftover_base.burn_for_testing();
        matched_quote.burn_for_testing();
        i = i + 1;
    };

    assert!(event::events_by_type<tiny_clob::MakerFeeSettled>().length() == 0, 0);

    scenario.next_tx(maker_a());
    let (base_coin, quote_coin) = book.cancel_order(ticket, scenario.ctx());
    // escrow_base slack (1) + pooled Base proceeds (99 + 99 = 198) = 199.
    assert!(base_coin.burn_for_testing() == 199, 1);
    // Unspent reserved Quote escrow: 30_000 - 10_000 - 10_000 = 10_000.
    assert!(quote_coin.burn_for_testing() == 10_000, 2);

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 3);
    let (ev_order_id, _ev_book_id, ev_maker, ev_amount) = settled[0].maker_fee_settled_fields_for_testing();
    assert!(ev_order_id == order_id, 4);
    assert!(ev_maker == maker_a(), 5);
    assert!(ev_amount == 1, 6); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == 1, 7);
    assert!(fee_quote_after == 0, 8);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Category (c): `clob_admin_cancel_order` -- an ask-side maker (fee
/// denominated in Quote), mirroring the fill-drain scenario's numbers but
/// force-cancelled instead of drained, while still holding 1 unit
/// unfilled. The slack refund folds into `escrow_quote`, which starts as
/// `None` for an ask-side order, exactly like `fold_maker_fee_slack`'s
/// bid-side mirror in the cancel_order test above.
///
/// Same `realistic_decimals_book` fixture and non-multiple-of-184 price as
/// `maker_fee_reserve_trues_up_on_fill_drain_with_nonzero_slack` above, so
/// the two 1-unit fills' `quote_cost` (`6` each) is itself genuinely
/// ceiling-rounded.
#[test]
fun maker_fee_reserve_trues_up_on_clob_admin_cancel_order_with_nonzero_slack() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    cap.clob_admin_set_maker_fee(&mut book, MAKER_FEE_BPS);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(3);
    let ask = order::new<BTC, USDC>(order_id, other(), 3, option::some(escrow), option::none(), MAKER_FEE_BPS);
    book.insert_resting_order_for_testing(false, REALISTIC_PRICE, ask, scenario.ctx());

    let unit_quote_cost = book.bid_escrow_amount(REALISTIC_PRICE, 1);
    assert!(unit_quote_cost == 6, 100);

    let mut i = 0;
    while (i < 2) {
        let payment = coin::mint_for_testing<USDC>(unit_quote_cost, scenario.ctx());
        let (mb, mq, _, _, _) =
            book.match_bid_for_testing(option::some(REALISTIC_PRICE), 1, payment, 1_000_000, scenario.ctx());
        mb.burn_for_testing();
        mq.burn_for_testing();
        i = i + 1;
    };

    cap.clob_admin_cancel_order(&mut book, false, REALISTIC_PRICE, order_id, scenario.ctx());

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 0);
    let (ev_order_id, _ev_book_id, ev_maker, ev_amount) = settled[0].maker_fee_settled_fields_for_testing();
    assert!(ev_order_id == order_id, 1);
    assert!(ev_maker == other(), 2);
    assert!(ev_amount == 1, 3); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == 0, 4);
    assert!(fee_quote_after == 1, 5);

    // Force-cancel refunds only the order's own escrow legs (never touches
    // already-pooled proceeds): 1 unmatched Base unit, and the 1-unit Quote
    // slack (folded into what was previously an empty `escrow_quote`).
    scenario.next_tx(other());
    let base_refund = ts::take_from_address<coin::Coin<BTC>>(&scenario, other());
    assert!(base_refund.value() == 1, 6);
    base_refund.burn_for_testing();
    let quote_refund = ts::take_from_address<coin::Coin<USDC>>(&scenario, other());
    assert!(quote_refund.value() == 1, 7);
    quote_refund.burn_for_testing();

    // The 10 units of Quote proceeds pooled by the two fills (5 each, net
    // of their own per-fill dust fee) are untouched by the force-cancel and
    // remain separately claimable.
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    scenario.next_tx(other());
    let proceeds_payout = ts::take_from_address<coin::Coin<USDC>>(&scenario, other());
    assert!(proceeds_payout.value() == 10, 8);
    proceeds_payout.burn_for_testing();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Category (d): `clob_admin_drain_step` (`drain_side`) -- same fixture as
/// the `cancel_order` test above (bid-side maker, Base-denominated fee,
/// 100-unit fills), but concluded via force-drain after `clob_admin_retire`
/// instead of the ticket holder's own cancellation.
#[test]
fun maker_fee_reserve_trues_up_on_clob_admin_drain_step_with_nonzero_slack() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_maker_fee(&mut book, MAKER_FEE_BPS);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(PRICE * 300);
    let bid = order::new<BTC, USDC>(order_id, other(), 300, option::none(), option::some(escrow), MAKER_FEE_BPS);
    book.insert_resting_order_for_testing(true, PRICE, bid, scenario.ctx());

    let mut i = 0;
    while (i < 2) {
        let ask_payment = coin::mint_for_testing<BTC>(100, scenario.ctx());
        let (leftover_base, matched_quote, _) = book.place_market_order_ask(
            100, ask_payment, 1_000_000, option::none(), option::none(), scenario.ctx(),
        );
        leftover_base.burn_for_testing();
        matched_quote.burn_for_testing();
        i = i + 1;
    };

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 0);
    let (ev_order_id, _ev_book_id, ev_maker, ev_amount) = settled[0].maker_fee_settled_fields_for_testing();
    assert!(ev_order_id == order_id, 1);
    assert!(ev_maker == other(), 2);
    assert!(ev_amount == 1, 3); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == 1, 4);
    assert!(fee_quote_after == 0, 5);

    let proceeds_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(proceeds_events.length() == 1, 6);
    let (_claimant, _book_id, base_amount, quote_amount) =
        proceeds_events[0].proceeds_claimed_fields_for_testing();
    // Pooled Base proceeds from the two fills: 99 + 99 = 198.
    assert!(base_amount == 198, 7);
    assert!(quote_amount == 0, 8);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Taker-side aggregation (Part D): 10 separate 1-unit fills against 10
/// distinct resting asks in a single call, at the max taker rate (10 bps).
/// Each fill's OWN per-fill ceiling would independently round up to 1 unit
/// of fee (`ceil(1 * 10 / 10_000) = 1`), for a naive per-fill sum of 10 --
/// the old, exploitable behavior (finding F-6). The new once-per-call
/// aggregate instead charges `ceil(10 * 10 / 10_000) = 1`, strictly less
/// than the naive sum, and matches exactly what `OrderExecuted.
/// taker_fee_amount` and the fee accumulator both report.
#[test]
fun taker_aggregate_fee_strictly_less_than_naive_per_fill_sum_across_many_small_fills() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let taker_fee_bps = 10; // MAX_TAKER_FEE_BPS
    cap.clob_admin_set_taker_fee(&mut book, taker_fee_bps);

    let num_fills = 10;
    let mut i = 0;
    while (i < num_fills) {
        let order_id = book.next_order_id();
        let escrow = balance::create_for_testing<BTC>(1);
        let ask = order::new<BTC, USDC>(order_id, other(), 1, option::some(escrow), option::none(), 0);
        book.insert_resting_order_for_testing(false, PRICE, ask, scenario.ctx());
        i = i + 1;
    };

    let payment = coin::mint_for_testing<USDC>(PRICE * num_fills, scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, _stopped, taker_fee_amount) =
        book.match_bid_for_testing(option::some(PRICE), num_fills, payment, 1_000_000, scenario.ctx());
    assert!(remaining_size == 0, 0);
    assert!(remaining_budget.burn_for_testing() == 0, 1);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == (num_fills as u64), 2);

    // Naive per-fill sum: this is exactly the OLD (pre-redesign) behavior --
    // each of the 10 one-unit fills, on its own, would have ceiling-rounded
    // to 1 unit of fee.
    let naive_per_fill_sum = num_fills; // 10 * ceil(1 * 10 / 10_000) = 10 * 1
    assert!(taker_fee_amount < naive_per_fill_sum, 3);
    assert!(taker_fee_amount == 1, 4); // ceil(10 * 10 / 10_000) = 1

    assert!(matched_base.burn_for_testing() == num_fills - taker_fee_amount, 5);
    let (fee_base_after, _fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == taker_fee_amount, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// `OrderExecuted.taker_fee_amount` (Part D), exercised through a real
/// public entry point rather than the `match_bid_for_testing` test-only
/// accessor: the same many-small-fills setup as the aggregation test above,
/// driven through `place_market_order_bid`, confirming the aggregate fee
/// reported on the event matches the fee accumulator and the taker's actual
/// net proceeds.
#[test]
fun order_executed_taker_fee_amount_matches_aggregate_across_many_small_fills() {
    let mut scenario = ts::begin(admin());
    // A `min_size` of 1 (rather than `test_utils::new_book`'s 100) is needed
    // so this test's 10-unit market order -- deliberately small, to keep
    // the many-small-fills setup readable -- clears placement validation;
    // `price_scale` still comes out to 1, same as `new_book`.
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 0, 19, 1, scenario.ctx());
    let taker_fee_bps = 10; // MAX_TAKER_FEE_BPS
    cap.clob_admin_set_taker_fee(&mut book, taker_fee_bps);

    let num_fills = 10;
    let mut i = 0;
    while (i < num_fills) {
        let order_id = book.next_order_id();
        let escrow = balance::create_for_testing<BTC>(1);
        let ask = order::new<BTC, USDC>(order_id, other(), 1, option::some(escrow), option::none(), 0);
        book.insert_resting_order_for_testing(false, PRICE, ask, scenario.ctx());
        i = i + 1;
    };

    let budget = PRICE * num_fills;
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, stopped) = book.place_market_order_bid(
        num_fills, budget, payment, 1_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    let matched_base_val = matched_base.burn_for_testing();
    leftover_payment.burn_for_testing();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 1);
    let (_book_id, _taker, _taker_side, _entry_point, _limit_price, requested_size, unmatched_size, _rested_size, _rested_order_id, _stopped_flag, taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
    assert!(requested_size == num_fills, 2);
    assert!(unmatched_size == 0, 3);
    assert!(taker_fee_amount == 1, 4); // ceil(10 * 10 / 10_000) = 1, not the naive per-fill sum of 10
    assert!(matched_base_val == num_fills - taker_fee_amount, 5);

    let (fee_base_after, _fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == taker_fee_amount, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Taker-side aggregation (Part D), ask-side mirror of
/// `taker_aggregate_fee_strictly_less_than_naive_per_fill_sum_across_many_small_fills`
/// above: that bid-side test's taker fee is Base-denominated, so
/// `price_scale` rounding of `quote_cost` never enters its fee basis at all.
/// Here the taker is an ASK, so its fee is Quote-denominated and computed
/// from the accumulated `quote_cost` across fills -- exactly the quantity
/// `realistic_decimals_book`'s non-multiple-of-184 price makes genuinely
/// rounded (`bid_escrow_amount(book, 1_000, 1) = ceil(1_000 * 1 / 184) = 6`,
/// not the `price * size` identity `new_book()` would give). 10 separate
/// 1-unit resting bids (maker fee zeroed out on each, to isolate taker-fee
/// behavior) are filled by one `place_market_order_ask` selling 10 Base
/// total, in 10 separate 1-unit fills. Each fill's OWN per-fill ceiling
/// would independently round up to 1 unit of fee (`ceil(6 * 10 / 10_000) =
/// 1`), for a naive per-fill sum of 10; the actual once-per-call aggregate
/// instead charges `ceil(60 * 10 / 10_000) = 1`, strictly less than the
/// naive sum, and matches exactly what `OrderExecuted.taker_fee_amount` and
/// the fee accumulator both report.
#[test]
fun taker_aggregate_fee_strictly_less_than_naive_per_fill_sum_across_many_small_fills_ask_side() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    let taker_fee_bps = 10; // MAX_TAKER_FEE_BPS
    cap.clob_admin_set_taker_fee(&mut book, taker_fee_bps);

    let unit_quote_cost = book.bid_escrow_amount(REALISTIC_PRICE, 1);
    assert!(unit_quote_cost == 6, 100);

    let num_fills = 10;
    let mut i = 0;
    while (i < num_fills) {
        let order_id = book.next_order_id();
        let escrow = balance::create_for_testing<USDC>(unit_quote_cost);
        let bid = order::new<BTC, USDC>(order_id, other(), 1, option::none(), option::some(escrow), 0);
        book.insert_resting_order_for_testing(true, REALISTIC_PRICE, bid, scenario.ctx());
        i = i + 1;
    };

    let payment = coin::mint_for_testing<BTC>(num_fills, scenario.ctx());
    let (leftover_base, matched_quote, stopped) = book.place_market_order_ask(
        num_fills, payment, 1_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(leftover_base.burn_for_testing() == 0, 1);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == (num_fills as u64), 2);

    let total_quote_basis = unit_quote_cost * num_fills;
    assert!(total_quote_basis == 60, 101);

    // Naive per-fill sum: this is exactly the OLD (pre-redesign) behavior --
    // each of the 10 one-unit fills, on its own, would have ceiling-rounded
    // its own 6-unit quote_cost to 1 unit of fee.
    let naive_per_fill_sum = num_fills; // 10 * ceil(6 * 10 / 10_000) = 10 * 1
    let matched_quote_val = matched_quote.burn_for_testing();

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 3);
    let (_book_id, _taker, _taker_side, _entry_point, _limit_price, requested_size, unmatched_size, _rested_size, _rested_order_id, _stopped_flag, taker_fee_amount) =
        executed[0].order_executed_fields_for_testing();
    assert!(requested_size == num_fills, 4);
    assert!(unmatched_size == 0, 5);
    assert!(taker_fee_amount < naive_per_fill_sum, 6);
    assert!(taker_fee_amount == 1, 7); // ceil(60 * 10 / 10_000) = 1
    assert!(matched_quote_val == total_quote_basis - taker_fee_amount, 8); // 60 - 1 = 59

    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == 0, 9);
    assert!(fee_quote_after == taker_fee_amount, 10);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// The two tests below use the same realistic BTC(8 decimals)/USDC(6
// decimals) book (`price_scale = 184`, same derivation as
// `full_lifecycle_tests.move`) as several of the true-up/aggregation tests
// above, with a price that is deliberately NOT a multiple of `price_scale`,
// so `bid_escrow_amount` itself requires genuine ceiling rounding -- not
// just `fee_amount`. They cover a case none of the other fee tests do: a
// nonzero `maker_fee_bps` is
// configured on the book, but the order is cancelled with ZERO fills ever
// having happened against it. `fee_basis_accumulated` therefore stays 0,
// `fee_amount(0, bps) == 0` exactly, and the maker must get back their FULL
// escrow -- computed under real price-scale rounding -- with not one atom
// deducted as fee, on both the bid and ask side.

#[test]
fun cancel_order_with_zero_fills_and_nonzero_fee_refunds_full_escrow_under_realistic_decimals_bid_side() {
    let mut scenario = ts::begin(admin());
    // base_decimals=8, quote_decimals=6, precision=0, exponent=19 => price_scale = 184
    // (identical derivation to full_lifecycle_tests.move's realistic book).
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    cap.clob_admin_set_maker_fee(&mut book, 3);

    scenario.next_tx(maker_a());
    let price = 1_000; // NOT a multiple of 184 -- forces real rounding below.
    let size = 37;
    let escrow_amount = book.bid_escrow_amount(price, size);
    assert!(escrow_amount == 202, 0); // ceil(1_000 * 37 / 184) = ceil(201.086...) = 202

    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(price, size, payment, 1_000_000, scenario.ctx());
    assert!(matched_base.burn_for_testing() == 0, 1); // empty book, nothing to match
    assert!(leftover_quote.burn_for_testing() == 0, 2); // payment was exactly the required escrow
    let ticket = ticket_opt.destroy_some();

    let (base_coin, quote_coin) = book.cancel_order(ticket, scenario.ctx());
    assert!(base_coin.burn_for_testing() == 0, 3); // a bid never holds Base escrow
    assert!(quote_coin.burn_for_testing() == escrow_amount, 4); // full refund, zero fee deducted

    let (fee_base, fee_quote) = book.fee_accumulator_balances();
    assert!(fee_base == 0 && fee_quote == 0, 5); // nothing was ever filled -- nothing collected

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 6); // the true-up still fires at conclusion...
    let (_, _, _, ev_amount) = settled[0].maker_fee_settled_fields_for_testing();
    assert!(ev_amount == 0, 7); // ...and correctly settles on a zero basis

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_order_with_zero_fills_and_nonzero_fee_refunds_full_escrow_under_realistic_decimals_ask_side() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(1, &mut scenario);
    cap.clob_admin_set_maker_fee(&mut book, 3);

    scenario.next_tx(maker_a());
    // An ask's own escrow is Base, with no price-scale division involved --
    // exact by construction -- so this side's rounding-under-load comes
    // entirely from the (zero) fee-basis true-up, not from the escrow itself.
    let price = 1_000; // still not a multiple of 184, for consistency with the bid-side test.
    let size = 53;
    let payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(price, size, payment, 1_000_000, scenario.ctx());
    assert!(leftover_base.burn_for_testing() == 0, 0); // payment was exactly `size`
    assert!(matched_quote.burn_for_testing() == 0, 1); // empty book, nothing to match
    let ticket = ticket_opt.destroy_some();

    let (base_coin, quote_coin) = book.cancel_order(ticket, scenario.ctx());
    assert!(base_coin.burn_for_testing() == size, 2); // full escrow refund, zero fee deducted
    assert!(quote_coin.burn_for_testing() == 0, 3); // an ask never holds Quote escrow

    let (fee_base, fee_quote) = book.fee_accumulator_balances();
    assert!(fee_base == 0 && fee_quote == 0, 4);

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 5);
    let (_, _, _, ev_amount) = settled[0].maker_fee_settled_fields_for_testing();
    assert!(ev_amount == 0, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

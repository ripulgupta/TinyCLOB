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
use tiny_clob::test_utils::{Self, admin, other, maker_a, new_book, destroy_book_and_cap};

// `new_book` (base_decimals = quote_decimals = precision = 0, exponent =
// 19) derives `price_scale == 1`, so `quote_cost == price * fill_qty`
// exactly, with no scaling rounding to account for -- every expected value
// below is computed by hand from that identity plus `fee_amount`'s ceiling
// formula (`ceil(x * bps / 10_000)`).
const PRICE: u64 = 100;
const MAKER_FEE_BPS: u64 = 1;

/// Category (a): fill-drain, inside `fill_level_bid` -- an ask-side maker
/// (fee denominated in Quote) fully drained across two separate 1-unit
/// fills, each independently ceiling-rounding its own fee to 1 (dust,
/// `ceil(100 * 1 / 10_000) = 1`), for a reserve of 2. The CORRECT aggregate
/// fee owed on the full 200-unit basis is `ceil(200 * 1 / 10_000) = 1`, so
/// this order's conclusion must refund exactly 1 unit of slack back to the
/// maker instead of over-collecting the naive per-fill sum of 2.
#[test]
fun maker_fee_reserve_trues_up_on_fill_drain_with_nonzero_slack() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, MAKER_FEE_BPS);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<BTC>(2);
    let ask = order::new<BTC, USDC>(order_id, other(), 2, option::some(escrow), option::none(), MAKER_FEE_BPS);
    tiny_clob::insert_resting_order_for_testing(&mut book, false, PRICE, ask, scenario.ctx());

    // Fill 1: 1 unit -- ask still rests with 1 unit remaining afterward.
    let payment1 = coin::mint_for_testing<USDC>(PRICE, scenario.ctx());
    let (mb1, mq1, _, _, _) = tiny_clob::match_bid_for_testing(
        &mut book, option::some(PRICE), 1, payment1, 1_000_000, scenario.ctx(),
    );
    coin::burn_for_testing(mb1);
    coin::burn_for_testing(mq1);
    let (fee_base_mid, fee_quote_mid) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_mid == 0 && fee_quote_mid == 0, 0); // still resting: fee only reserved, not collected
    assert!(event::events_by_type<tiny_clob::MakerFeeSettled>().length() == 0, 1);

    // Fill 2: 1 more unit -- fully drains the ask, triggering conclusion.
    let payment2 = coin::mint_for_testing<USDC>(PRICE, scenario.ctx());
    let (mb2, mq2, remaining_size2, _, _) = tiny_clob::match_bid_for_testing(
        &mut book, option::some(PRICE), 1, payment2, 1_000_000, scenario.ctx(),
    );
    coin::burn_for_testing(mb2);
    coin::burn_for_testing(mq2);
    assert!(remaining_size2 == 0, 2);

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 3);
    let (ev_order_id, ev_book_id, ev_maker, ev_amount) = tiny_clob::maker_fee_settled_fields_for_testing(&settled[0]);
    assert!(ev_order_id == order_id, 4);
    assert!(ev_book_id == tiny_clob::id_for_testing(&book), 5);
    assert!(ev_maker == other(), 6);
    assert!(ev_amount == 1, 7); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after == 0, 8);
    assert!(fee_quote_after == 1, 9);

    // The maker's pooled proceeds must reflect the slack refund: 99 (fill 1,
    // net of its own dust fee) + 100 (fill 2's net-of-fee 99, plus the 1-unit
    // slack folded in at conclusion) = 199, not 198 (which is what
    // over-collecting the naive per-fill sum would have left).
    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    scenario.next_tx(other());
    let payout = ts::take_from_address<coin::Coin<USDC>>(&scenario, other());
    assert!(coin::value(&payout) == 199, 10);
    coin::burn_for_testing(payout);

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
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, MAKER_FEE_BPS);

    scenario.next_tx(maker_a());
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, PRICE, 300), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, PRICE, 300, payment, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);
    let ticket = option::destroy_some(ticket_opt);
    let order_id = tiny_clob::ticket_order_id(&ticket);

    // Two 100-unit ask fills against the resting bid.
    scenario.next_tx(other());
    let mut i = 0;
    while (i < 2) {
        let ask_payment = coin::mint_for_testing<BTC>(100, scenario.ctx());
        let (leftover_base, matched_quote, _) = tiny_clob::place_market_order_ask(
            &mut book, 100, ask_payment, 1_000_000, option::none(), option::none(), scenario.ctx(),
        );
        coin::burn_for_testing(leftover_base);
        coin::burn_for_testing(matched_quote);
        i = i + 1;
    };

    assert!(event::events_by_type<tiny_clob::MakerFeeSettled>().length() == 0, 0);

    scenario.next_tx(maker_a());
    let (base_coin, quote_coin) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    // escrow_base slack (1) + pooled Base proceeds (99 + 99 = 198) = 199.
    assert!(coin::burn_for_testing(base_coin) == 199, 1);
    // Unspent reserved Quote escrow: 30_000 - 10_000 - 10_000 = 10_000.
    assert!(coin::burn_for_testing(quote_coin) == 10_000, 2);

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 3);
    let (ev_order_id, _ev_book_id, ev_maker, ev_amount) = tiny_clob::maker_fee_settled_fields_for_testing(&settled[0]);
    assert!(ev_order_id == order_id, 4);
    assert!(ev_maker == maker_a(), 5);
    assert!(ev_amount == 1, 6); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);
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
#[test]
fun maker_fee_reserve_trues_up_on_clob_admin_cancel_order_with_nonzero_slack() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, MAKER_FEE_BPS);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<BTC>(3);
    let ask = order::new<BTC, USDC>(order_id, other(), 3, option::some(escrow), option::none(), MAKER_FEE_BPS);
    tiny_clob::insert_resting_order_for_testing(&mut book, false, PRICE, ask, scenario.ctx());

    let mut i = 0;
    while (i < 2) {
        let payment = coin::mint_for_testing<USDC>(PRICE, scenario.ctx());
        let (mb, mq, _, _, _) =
            tiny_clob::match_bid_for_testing(&mut book, option::some(PRICE), 1, payment, 1_000_000, scenario.ctx());
        coin::burn_for_testing(mb);
        coin::burn_for_testing(mq);
        i = i + 1;
    };

    tiny_clob::clob_admin_cancel_order(&cap, &mut book, false, PRICE, order_id, scenario.ctx());

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 0);
    let (ev_order_id, _ev_book_id, ev_maker, ev_amount) = tiny_clob::maker_fee_settled_fields_for_testing(&settled[0]);
    assert!(ev_order_id == order_id, 1);
    assert!(ev_maker == other(), 2);
    assert!(ev_amount == 1, 3); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after == 0, 4);
    assert!(fee_quote_after == 1, 5);

    // Force-cancel refunds only the order's own escrow legs (never touches
    // already-pooled proceeds): 1 unmatched Base unit, and the 1-unit Quote
    // slack (folded into what was previously an empty `escrow_quote`).
    scenario.next_tx(other());
    let base_refund = ts::take_from_address<coin::Coin<BTC>>(&scenario, other());
    assert!(coin::value(&base_refund) == 1, 6);
    coin::burn_for_testing(base_refund);
    let quote_refund = ts::take_from_address<coin::Coin<USDC>>(&scenario, other());
    assert!(coin::value(&quote_refund) == 1, 7);
    coin::burn_for_testing(quote_refund);

    // The 198 units of Quote proceeds pooled by the two fills (99 each,
    // net of their own per-fill dust fee) are untouched by the force-cancel
    // and remain separately claimable.
    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    scenario.next_tx(other());
    let proceeds_payout = ts::take_from_address<coin::Coin<USDC>>(&scenario, other());
    assert!(coin::value(&proceeds_payout) == 198, 8);
    coin::burn_for_testing(proceeds_payout);

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
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, MAKER_FEE_BPS);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(PRICE * 300);
    let bid = order::new<BTC, USDC>(order_id, other(), 300, option::none(), option::some(escrow), MAKER_FEE_BPS);
    tiny_clob::insert_resting_order_for_testing(&mut book, true, PRICE, bid, scenario.ctx());

    let mut i = 0;
    while (i < 2) {
        let ask_payment = coin::mint_for_testing<BTC>(100, scenario.ctx());
        let (leftover_base, matched_quote, _) = tiny_clob::place_market_order_ask(
            &mut book, 100, ask_payment, 1_000_000, option::none(), option::none(), scenario.ctx(),
        );
        coin::burn_for_testing(leftover_base);
        coin::burn_for_testing(matched_quote);
        i = i + 1;
    };

    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 100, scenario.ctx());

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 0);
    let (ev_order_id, _ev_book_id, ev_maker, ev_amount) = tiny_clob::maker_fee_settled_fields_for_testing(&settled[0]);
    assert!(ev_order_id == order_id, 1);
    assert!(ev_maker == other(), 2);
    assert!(ev_amount == 1, 3); // CORRECT aggregate fee, not the naive per-fill sum of 2

    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after == 1, 4);
    assert!(fee_quote_after == 0, 5);

    let proceeds_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(proceeds_events.length() == 1, 6);
    let (_claimant, _book_id, base_amount, quote_amount) =
        tiny_clob::proceeds_claimed_fields_for_testing(&proceeds_events[0]);
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
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, taker_fee_bps);

    let num_fills = 10;
    let mut i = 0;
    while (i < num_fills) {
        let order_id = tiny_clob::next_order_id(&mut book);
        let escrow = balance::create_for_testing<BTC>(1);
        let ask = order::new<BTC, USDC>(order_id, other(), 1, option::some(escrow), option::none(), 0);
        tiny_clob::insert_resting_order_for_testing(&mut book, false, PRICE, ask, scenario.ctx());
        i = i + 1;
    };

    let payment = coin::mint_for_testing<USDC>(PRICE * num_fills, scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, _stopped, taker_fee_amount) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(PRICE), num_fills, payment, 1_000_000, scenario.ctx());
    assert!(remaining_size == 0, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == (num_fills as u64), 2);

    // Naive per-fill sum: this is exactly the OLD (pre-redesign) behavior --
    // each of the 10 one-unit fills, on its own, would have ceiling-rounded
    // to 1 unit of fee.
    let naive_per_fill_sum = num_fills; // 10 * ceil(1 * 10 / 10_000) = 10 * 1
    assert!(taker_fee_amount < naive_per_fill_sum, 3);
    assert!(taker_fee_amount == 1, 4); // ceil(10 * 10 / 10_000) = 1

    assert!(coin::burn_for_testing(matched_base) == num_fills - taker_fee_amount, 5);
    let (fee_base_after, _fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);
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
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, taker_fee_bps);

    let num_fills = 10;
    let mut i = 0;
    while (i < num_fills) {
        let order_id = tiny_clob::next_order_id(&mut book);
        let escrow = balance::create_for_testing<BTC>(1);
        let ask = order::new<BTC, USDC>(order_id, other(), 1, option::some(escrow), option::none(), 0);
        tiny_clob::insert_resting_order_for_testing(&mut book, false, PRICE, ask, scenario.ctx());
        i = i + 1;
    };

    let budget = PRICE * num_fills;
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, stopped) = tiny_clob::place_market_order_bid(
        &mut book, num_fills, budget, payment, 1_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    let matched_base_val = coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_payment);

    let executed = event::events_by_type<tiny_clob::OrderExecuted>();
    assert!(executed.length() == 1, 1);
    let (_book_id, _taker, _taker_side, _entry_point, _limit_price, requested_size, unmatched_size, _rested_size, _rested_order_id, _stopped_flag, taker_fee_amount) =
        tiny_clob::order_executed_fields_for_testing(&executed[0]);
    assert!(requested_size == num_fills, 2);
    assert!(unmatched_size == 0, 3);
    assert!(taker_fee_amount == 1, 4); // ceil(10 * 10 / 10_000) = 1, not the naive per-fill sum of 10
    assert!(matched_base_val == num_fills - taker_fee_amount, 5);

    let (fee_base_after, _fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after == taker_fee_amount, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

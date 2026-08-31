/// Broad, continuous end-to-end scenarios, each exercising a wide slice of
/// the module's surface in one uninterrupted story rather than isolating a
/// single behavior. Unlike the topic-split files elsewhere in this
/// directory, these two tests deliberately use two DIFFERENT book shapes —
/// neither is the plain zero-decimals BTC/USDC book most other tests use —
/// so between them they also cover genuinely different `price_scale`/
/// decimals combinations under one continuous story:
///   - `full_lifecycle_realistic_btc_usdc_decimals`: a BTC(8 decimals)/
///     USDC(6 decimals)-realistic book (`price_scale` = 100), with a
///     taker/maker fee change mid-lifecycle to prove the already-resting
///     order's snapshotted maker fee doesn't retroactively change.
///   - `full_lifecycle_wal_sui_distinct_price_scale_shape`: a same-decimals
///     WAL/SUI (9/9 decimals) book with a deliberately different
///     precision/exponent shape. `price_scale` is derived from
///     `ceil(10^base_decimals * 10^precision / 10^quote_decimals)` (see
///     `new_impl`'s doc comment), which doesn't depend on `exponent` at
///     all -- so despite the different precision/exponent shape here, this
///     book's `price_scale` (100) happens to coincide with the BTC/USDC
///     book's above; the two books are still genuinely different
///     decimals/precision/exponent combinations, exercised for their own
///     sake, and this test instead proves that a force-drained resting
///     order still pays out to a REASSIGNED owner rather than its original
///     one.
///
/// Every expected value below is derived by hand from the module's
/// documented formulas (`bid_escrow_amount`/`scaled_ceil_mul_div` =
/// `ceil(price * size / price_scale)`; `fee_amount` = `ceil(amount * bps /
/// 10_000)`), not guessed and not cross-checked only against the function
/// under test. Every raw `price` below is chosen as an exact multiple of
/// its book's `price_scale`, so every pre-fee quote amount in this file
/// divides out exactly (no rounding ambiguity to track by hand) — the
/// *sizes* are still deliberately non-round, arbitrary-looking numbers,
/// since they carry no rounding-boundary significance of their own.
#[test_only]
module tiny_clob::full_lifecycle_tests;

use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap};
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};
use tiny_clob::test_utils::{Self, admin, other, taker, maker_a, maker_b, maker_c, realistic_decimals_book};

#[test]
fun full_lifecycle_realistic_btc_usdc_decimals() {
    let mut scenario = ts::begin(admin());

    // base_decimals=8, quote_decimals=6, precision=0, exponent=19:
    // scale_lo = ceil(10^8 * 10^0 / 10^6) = ceil(100) = 100 -- the smallest
    // value guaranteeing resolution at least as fine as 10^0 (precision=0).
    // (scale_hi = floor(u64::MAX * 10^8 / (10^6 * 10^19)) = 184, comfortably
    // above scale_lo, so the feasibility check passes -> price_scale = 100.)
    // (see test_utils::realistic_decimals_book, shared with fee_redesign_tests.move)
    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(37, &mut scenario);
    assert!(book.price_scale() == 100, 0);

    // --- Two makers rest on opposite sides, at different prices. Every
    // --- price below is `100 * k` so every escrow/quote-cost divides out
    // --- exactly; sizes are arbitrary-looking, non-round numbers.
    let ask1_price = 100 * 623; // = 62_300
    let ask1_size = 269;
    scenario.next_tx(maker_a());
    let ask1_payment = coin::mint_for_testing<BTC>(ask1_size, scenario.ctx());
    // `ask1_price` is an exact multiple of `price_scale`, so
    // `bid_escrow_amount` -- the exact fair quote yield at this price -- is
    // also the `expected_quote_output` that derives this same price back
    // exactly (no rounding involved either way).
    let ask1_expected_quote_output = book.bid_escrow_amount(ask1_price, ask1_size);
    let (ask1_ticket_opt, ask1_leftover, ask1_matched, _) =
        book.place_limit_order_ask(ask1_payment, ask1_expected_quote_output, 10, scenario.ctx());
    assert!(ask1_leftover.burn_for_testing() == 0, 1);
    assert!(ask1_matched.burn_for_testing() == 0, 2);
    let ask1_ticket = ask1_ticket_opt.destroy_some();
    let ask1_order_id = ask1_ticket.ticket_order_id();

    let bid1_price = 100 * 601; // = 60_100
    let bid1_size = 401;
    scenario.next_tx(maker_b());
    let bid1_escrow = book.bid_escrow_amount(bid1_price, bid1_size);
    assert!(bid1_escrow == 601 * 401, 3); // = 241_001, exact
    let bid1_payment = coin::mint_for_testing<USDC>(bid1_escrow, scenario.ctx());
    let (bid1_ticket_opt, bid1_matched, bid1_leftover, _) =
        book.place_limit_order_bid(bid1_payment, bid1_size, 10, scenario.ctx());
    assert!(bid1_matched.burn_for_testing() == 0, 4);
    assert!(bid1_leftover.burn_for_testing() == 0, 5);
    let bid1_ticket = bid1_ticket_opt.destroy_some();
    let bid1_order_id = bid1_ticket.ticket_order_id();

    // A third maker rests a bid below the other two, at a still-lower
    // price, and is left untouched until the retire/drain finale.
    let bid2_price = 100 * 550; // = 55_000
    let bid2_size = 331;
    scenario.next_tx(maker_c());
    let bid2_escrow = book.bid_escrow_amount(bid2_price, bid2_size);
    assert!(bid2_escrow == 550 * 331, 6); // = 182_050, exact
    let bid2_payment = coin::mint_for_testing<USDC>(bid2_escrow, scenario.ctx());
    let (bid2_ticket_opt, bid2_matched, bid2_leftover, _) =
        book.place_limit_order_bid(bid2_payment, bid2_size, 10, scenario.ctx());
    assert!(bid2_matched.burn_for_testing() == 0, 7);
    assert!(bid2_leftover.burn_for_testing() == 0, 8);
    let bid2_ticket = bid2_ticket_opt.destroy_some();

    // --- A limit-order taker partially crosses ask1 (fees still 0). ---
    scenario.next_tx(taker());
    let cross1_size = 113;
    let cross1_budget = book.bid_escrow_amount(ask1_price, cross1_size);
    assert!(cross1_budget == 623 * 113, 9); // = 70_399, exact
    let cross1_payment = coin::mint_for_testing<USDC>(cross1_budget, scenario.ctx());
    let (cross1_ticket_opt, cross1_matched, cross1_leftover, cross1_stopped) =
        book.place_limit_order_bid(cross1_payment, cross1_size, 10, scenario.ctx());
    assert!(!cross1_stopped, 10);
    assert!(cross1_matched.burn_for_testing() == cross1_size, 11); // fee 0
    assert!(cross1_leftover.burn_for_testing() == 0, 12);
    assert!(cross1_ticket_opt.is_none(), 13); // taker's own order fully filled, doesn't rest
    cross1_ticket_opt.destroy_none();
    // ask1 now has 269 - 113 = 156 remaining, pooling 70_399 quote for maker_a().
    assert!(book.depth_at_price(tiny_clob::ask(), ask1_price) == 156, 14);

    // --- A market-order taker partially crosses bid1 (the higher of the ---
    // --- two resting bids; fees still 0).                              ---
    scenario.next_tx(taker());
    let cross2_size = 214;
    let cross2_payment = coin::mint_for_testing<BTC>(cross2_size, scenario.ctx());
    let (cross2_leftover, cross2_matched, cross2_stopped) = book.place_market_order_ask(cross2_payment, 10, 0, cross2_size, scenario.ctx(),
    );
    assert!(!cross2_stopped, 15);
    assert!(cross2_leftover.burn_for_testing() == 0, 16);
    assert!(cross2_matched.burn_for_testing() == 601 * 214, 17); // = 128_614, exact, fee 0
    // bid1 now has 401 - 214 = 187 Base remaining, pooling 214 base for
    // maker_b(). `depth_at_price` for a bid is Quote-denominated -- since
    // `bid1_price` is an exact multiple of `price_scale`, the escrow charge
    // divides out exactly with zero rounding slop at any cumulative fill
    // count, so the remaining Quote escrow is exactly `601 * 187 = 112_387`
    // (i.e. `bid_escrow_amount(bid1_price, 187)`, exactly), not `187`.
    assert!(book.depth_at_price(tiny_clob::bid(), bid1_price) == 601 * 187, 18);

    // --- Fees change mid-lifecycle. ---
    scenario.next_tx(admin());
    cap.clob_admin_set_taker_fee(&mut book, 7);
    cap.clob_admin_set_maker_fee(&mut book, 3);

    // --- Reassign bid1's remaining 187 to maker_c(), mid-fill-history. ---
    let reassigned = book.update_resting_order(&bid1_ticket, maker_c());
    assert!(reassigned, 19);

    // --- A market ask fully drains bid1's remaining 187. ---
    // bid1's maker_fee_bps was snapshotted at 0 (rested before the fee
    // change above), so despite the book's CURRENT maker_fee_bps now being
    // 3, this fill still charges 0 maker fee -- proving the snapshot, not
    // the live rate, governs an already-resting order.
    scenario.next_tx(taker());
    let cross3_size = 187;
    let cross3_payment = coin::mint_for_testing<BTC>(cross3_size, scenario.ctx());
    let (cross3_leftover, cross3_matched, cross3_stopped) =
        book.place_market_order_ask(cross3_payment, 10, 0, cross3_size, scenario.ctx());
    assert!(!cross3_stopped, 20);
    assert!(cross3_leftover.burn_for_testing() == 0, 21);
    let cross3_quote_cost = 601 * 187; // = 112_387, exact
    let cross3_taker_fee = (cross3_quote_cost * 7 + 9_999) / 10_000; // ceil(112_387 * 7 / 10_000) = 79
    assert!(cross3_taker_fee == 79, 22);
    assert!(cross3_matched.burn_for_testing() == cross3_quote_cost - cross3_taker_fee, 23); // = 112_308
    // bid1 is now fully drained; its 401 total pooled base (214 + 187,
    // credited across both the pre- and post-reassignment fills) is owed
    // to its FINAL owner, maker_c(), not to maker_b().
    assert!(book.resting_order_escrow(true, bid1_price, bid1_order_id).is_none(), 24);

    // --- A fresh bid from maker_a(), rested AFTER the fee change, so its ---
    // --- maker_fee_bps snapshot is the NEW rate (3), not 0.             ---
    let bid3_price = 100 * 610; // = 61_000 (above bid2's 55_000, so it -- not
    // bid2 -- is top-of-book and gets crossed first below; below ask1's
    // remaining 62_300 so it rests without auto-crossing that)
    let bid3_size = 68;
    scenario.next_tx(maker_a());
    let bid3_escrow = book.bid_escrow_amount(bid3_price, bid3_size);
    assert!(bid3_escrow == 610 * 68, 25); // = 41_480, exact
    let bid3_payment = coin::mint_for_testing<USDC>(bid3_escrow, scenario.ctx());
    let (bid3_ticket_opt, bid3_matched, bid3_leftover, _) =
        book.place_limit_order_bid(bid3_payment, bid3_size, 10, scenario.ctx());
    assert!(bid3_matched.burn_for_testing() == 0, 26);
    assert!(bid3_leftover.burn_for_testing() == 0, 27);
    let bid3_ticket = bid3_ticket_opt.destroy_some();

    // A taker fully crosses bid3: with the new maker_fee_bps=3 snapshot,
    // this fill charges a real, nonzero maker fee -- the contrasting case
    // to bid1's above.
    scenario.next_tx(taker());
    let cross4_size = 68;
    let cross4_payment = coin::mint_for_testing<BTC>(cross4_size, scenario.ctx());
    // Same exact-multiple-of-`price_scale` reasoning as `ask1` above.
    let cross4_expected_quote_output = book.bid_escrow_amount(bid3_price, cross4_size);
    let (cross4_ticket_opt, cross4_leftover, cross4_matched, cross4_stopped) =
        book.place_limit_order_ask(cross4_payment, cross4_expected_quote_output, 10, scenario.ctx());
    assert!(!cross4_stopped, 28);
    assert!(cross4_ticket_opt.is_none(), 29);
    cross4_ticket_opt.destroy_none();
    assert!(cross4_leftover.burn_for_testing() == 0, 30);
    let cross4_quote_cost = 610 * 68; // = 41_480, exact
    let cross4_taker_fee = (cross4_quote_cost * 7 + 9_999) / 10_000; // ceil(41_480 * 7 / 10_000) = 30
    assert!(cross4_taker_fee == 30, 31);
    assert!(cross4_matched.burn_for_testing() == cross4_quote_cost - cross4_taker_fee, 32); // = 41_450
    let cross4_maker_fee_base = (cross4_size * 3 + 9_999) / 10_000; // ceil(68 * 3 / 10_000) = 1
    assert!(cross4_maker_fee_base == 1, 33);

    // --- Claim proceeds for bid3, now fully drained: maker_a() is owed ---
    // --- 68 - 1 = 67 base; the ticket auto-destroys since nothing rests. ---
    scenario.next_tx(maker_a());
    let (bid3_claim_base, bid3_claim_quote, bid3_claim_ticket_opt) =
        book.claim_proceeds(bid3_ticket, scenario.ctx());
    assert!(bid3_claim_base.burn_for_testing() == cross4_size - cross4_maker_fee_base, 34); // = 67
    assert!(bid3_claim_quote.burn_for_testing() == 0, 35);
    assert!(bid3_claim_ticket_opt.is_none(), 36);
    bid3_claim_ticket_opt.destroy_none();

    // --- Claim proceeds for ask1, STILL resting with 156 left, then ---
    // --- cancel it afterwards.                                     ---
    scenario.next_tx(maker_a());
    let (ask1_claim_base, ask1_claim_quote, ask1_claim_ticket_opt) =
        book.claim_proceeds(ask1_ticket, scenario.ctx());
    assert!(ask1_claim_base.burn_for_testing() == 0, 37);
    assert!(ask1_claim_quote.burn_for_testing() == cross1_budget, 38); // = 70_399
    assert!(ask1_claim_ticket_opt.is_some(), 39); // still resting -> reusable ticket
    let (ask1_cancel_base, ask1_cancel_quote) =
        book.cancel_order(ask1_claim_ticket_opt.destroy_some(), scenario.ctx());
    assert!(ask1_cancel_base.burn_for_testing() == 156, 40); // unfilled remainder refunded
    assert!(ask1_cancel_quote.burn_for_testing() == 0, 41);

    // --- Admin-push bid1's pooled proceeds: pays the REASSIGNED owner ---
    // --- (maker_c()), not the original resting owner (maker_b()).    ---
    cap.push_proceeds(&mut book, bid1_order_id, scenario.ctx());
    scenario.next_tx(maker_c());
    let bid1_payout = ts::take_from_address<coin::Coin<BTC>>(&scenario, maker_c());
    assert!(bid1_payout.value() == 214 + 187, 42); // both pre- and post-reassignment fills
    bid1_payout.burn_for_testing();
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(maker_b()), 43);
    book.destroy_orphaned_ticket(bid1_ticket); // proceeds now empty; disposes cleanly

    // --- Claim accumulated fees: 1 base (from cross4) + 79 + 30 = 109 quote. ---
    scenario.next_tx(admin());
    let (fee_base, fee_quote) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(fee_base.burn_for_testing() == cross4_maker_fee_base, 44); // = 1
    assert!(fee_quote.burn_for_testing() == cross3_taker_fee + cross4_taker_fee, 45); // = 109

    // --- Retire, drain (across two calls, proving the incremental-drain ---
    // --- story), then finalize. Only bid2 (maker_c(), untouched) remains. ---
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 0, scenario.ctx()); // no-op
    assert!(book.bids_size_for_testing() == 1, 46);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    assert!(book.bids_size_for_testing() == 0, 47);

    scenario.next_tx(maker_c());
    let bid2_refund = ts::take_from_address<coin::Coin<USDC>>(&scenario, maker_c());
    assert!(bid2_refund.value() == bid2_escrow, 48); // = 182_050
    bid2_refund.burn_for_testing();
    unit_test_destroy_ticket(bid2_ticket);

    let deleted_id = cap.clob_admin_finalize(book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 49);
    let (deleted_order_book_id, _, _) = deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_order_book_id == deleted_id, 50);

    scenario.end();
}

#[test]
fun full_lifecycle_wal_sui_distinct_price_scale_shape() {
    let mut scenario = ts::begin(admin());

    // base_decimals=9, quote_decimals=9 (same-decimals, unlike the BTC/USDC
    // book above), precision=2, exponent=16:
    // scale_lo = ceil(10^9 * 10^2 / 10^9) = 100 -- the smallest value
    // guaranteeing resolution at least as fine as 10^-2, and (since
    // `scale_lo` doesn't depend on `exponent` at all) numerically the same
    // as the BTC/USDC book's `price_scale` above despite the different
    // decimals/precision/exponent shape.
    // (scale_hi = floor(u64::MAX * 10^9 / (10^9 * 10^16)) = 1_844,
    // comfortably above scale_lo, so the feasibility check passes ->
    // price_scale = 100.)
    let (mut book, cap) = tiny_clob::new<WAL, SUI>(41, 9, 9, 2, 16, 100 * 211, scenario.ctx());
    assert!(book.price_scale() == 100, 0);

    // No fee changes in this scenario -- taker/maker fees stay 0 throughout,
    // so every quote amount below is exact with no fee arithmetic to track.
    let ask_price = 100 * 307; // = 30_700
    let ask_size = 173;
    scenario.next_tx(maker_b());
    let ask_payment = coin::mint_for_testing<WAL>(ask_size, scenario.ctx());
    let ask_expected_quote_output = book.bid_escrow_amount(ask_price, ask_size);
    let (ask_ticket_opt, ask_leftover, ask_matched, _) =
        book.place_limit_order_ask(ask_payment, ask_expected_quote_output, 10, scenario.ctx());
    assert!(ask_leftover.burn_for_testing() == 0, 1);
    assert!(ask_matched.burn_for_testing() == 0, 2);
    let ask_ticket = ask_ticket_opt.destroy_some();
    let ask_order_id = ask_ticket.ticket_order_id();

    let bid_price = 100 * 289; // = 28_900
    let bid_size = 97;
    scenario.next_tx(maker_c());
    let bid_escrow = book.bid_escrow_amount(bid_price, bid_size);
    assert!(bid_escrow == 289 * 97, 3); // = 28_033, exact
    let bid_payment = coin::mint_for_testing<SUI>(bid_escrow, scenario.ctx());
    let (bid_ticket_opt, bid_matched, bid_leftover, _) =
        book.place_limit_order_bid(bid_payment, bid_size, 10, scenario.ctx());
    assert!(bid_matched.burn_for_testing() == 0, 4);
    assert!(bid_leftover.burn_for_testing() == 0, 5);
    let bid_ticket = bid_ticket_opt.destroy_some();

    // A limit-order taker partially crosses the ask.
    scenario.next_tx(taker());
    let cross1_size = 59;
    let cross1_budget = book.bid_escrow_amount(ask_price, cross1_size);
    assert!(cross1_budget == 307 * 59, 6); // = 18_113, exact
    let cross1_payment = coin::mint_for_testing<SUI>(cross1_budget, scenario.ctx());
    let (cross1_ticket_opt, cross1_matched, cross1_leftover, _) =
        book.place_limit_order_bid(cross1_payment, cross1_size, 10, scenario.ctx());
    assert!(cross1_matched.burn_for_testing() == cross1_size, 7);
    assert!(cross1_leftover.burn_for_testing() == 0, 8);
    assert!(cross1_ticket_opt.is_none(), 9);
    cross1_ticket_opt.destroy_none();
    // ask now has 173 - 59 = 114 remaining.
    assert!(book.depth_at_price(tiny_clob::ask(), ask_price) == 114, 10);

    // A market-order taker partially crosses the bid.
    scenario.next_tx(taker());
    let cross2_size = 41;
    let cross2_payment = coin::mint_for_testing<WAL>(cross2_size, scenario.ctx());
    let (cross2_leftover, cross2_matched, _) = book.place_market_order_ask(cross2_payment, 10, 0, cross2_size, scenario.ctx(),
    );
    assert!(cross2_leftover.burn_for_testing() == 0, 11);
    assert!(cross2_matched.burn_for_testing() == 289 * 41, 12); // = 11_849, exact
    // bid now has 97 - 41 = 56 remaining, pooling 41 base for maker_c().
    // bid now has 97 - 41 = 56 Base remaining. `depth_at_price` for a bid is
    // Quote-denominated; `bid_price` is an exact multiple of `price_scale`,
    // so the remaining escrow divides out exactly to `289 * 56 = 16_184`
    // (`bid_escrow_amount(bid_price, 56)`, exactly), not `56`.
    assert!(book.depth_at_price(tiny_clob::bid(), bid_price) == 289 * 56, 13);

    // Reassign the remaining 56 of the bid to maker_a() -- left resting
    // (untouched) until the retire/drain finale below, to prove force-drain
    // still pays out to the REASSIGNED owner, not the original one.
    scenario.next_tx(maker_c());
    let reassigned = book.update_resting_order(&bid_ticket, maker_a());
    assert!(reassigned, 14);

    // A market bid fully drains the remaining 114 of the ask.
    scenario.next_tx(taker());
    let cross3_size = 114;
    let cross3_budget = book.bid_escrow_amount(ask_price, cross3_size);
    assert!(cross3_budget == 307 * 114, 15); // = 34_998, exact
    let cross3_payment = coin::mint_for_testing<SUI>(cross3_budget, scenario.ctx());
    let (cross3_matched, cross3_leftover, cross3_stopped) =
        book.place_market_order_bid(cross3_payment, 10, 0, cross3_size, cross3_budget, scenario.ctx());
    assert!(!cross3_stopped, 16);
    assert!(cross3_matched.burn_for_testing() == cross3_size, 17);
    assert!(cross3_leftover.burn_for_testing() == 0, 18);

    // Claim the ask's total pooled proceeds (18_113 + 34_998 = 53_111),
    // now fully drained -- ticket auto-destroys.
    scenario.next_tx(maker_b());
    let (ask_claim_base, ask_claim_quote, ask_claim_ticket_opt) =
        book.claim_proceeds(ask_ticket, scenario.ctx());
    assert!(ask_claim_base.burn_for_testing() == 0, 19);
    assert!(ask_claim_quote.burn_for_testing() == cross1_budget + cross3_budget, 20); // = 53_111
    assert!(ask_claim_ticket_opt.is_none(), 21);
    ask_claim_ticket_opt.destroy_none();
    assert!(!book.proceeds_contains_for_testing(ask_order_id), 22);

    // Claim fees: zero balance the whole way through -- no `FeesClaimed`
    // event should fire.
    scenario.next_tx(admin());
    let (fee_base, fee_quote) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(fee_base.burn_for_testing() == 0, 23);
    assert!(fee_quote.burn_for_testing() == 0, 24);
    assert!(event::events_by_type<tiny_clob::FeesClaimed>().length() == 0, 25);

    // Retire, drain across two calls (the second one force-cancels the
    // reassigned bid), then finalize.
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 0, scenario.ctx()); // no-op
    assert!(book.bids_size_for_testing() == 1, 26);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    assert!(book.bids_size_for_testing() == 0, 27);

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 28);
    let (_, _, ev_trader) = cancelled_events[0].order_cancelled_fields_for_testing();
    assert!(ev_trader == maker_a(), 29); // force-drain paid the REASSIGNED owner

    // bid's total escrow (28_033) minus what cross2 already charged
    // (289 * 41 = 11_849) leaves 56 * 289 = 16_184 still escrowed, refunded
    // by the force-drain above to the REASSIGNED owner maker_a().
    scenario.next_tx(maker_a());
    let bid_refund = ts::take_from_address<coin::Coin<SUI>>(&scenario, maker_a());
    assert!(bid_refund.value() == bid_escrow - (289 * 41), 30);
    bid_refund.burn_for_testing();
    assert!(!ts::has_most_recent_for_address<coin::Coin<SUI>>(maker_c()), 31);
    unit_test_destroy_ticket(bid_ticket);

    let deleted_id = cap.clob_admin_finalize(book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 32);
    let (deleted_order_book_id, _, _) = deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_order_book_id == deleted_id, 33);

    scenario.end();
}

/// The REVERSE direction of `full_lifecycle_realistic_btc_usdc_decimals`'s
/// maker-fee-snapshot story above: there, an order rests while
/// `maker_fee_bps` is 0 and is later RAISED off of 0, proving the snapshot
/// (not the live rate) governs settlement. Here, an order rests while
/// `maker_fee_bps` is ALREADY nonzero (3) and is later raised AGAIN, to a
/// different nonzero value (`MAX_MAKER_FEE_BPS` = 5, the ceiling this module
/// enforces) -- the order must still settle at its ORIGINAL 3-bps snapshot,
/// not the live 5-bps rate. Uses the same realistic BTC/USDC book shape
/// (`price_scale = 100`) as that test.
#[test]
fun full_lifecycle_maker_fee_snapshot_survives_nonzero_to_nonzero_change() {
    let mut scenario = ts::begin(admin());

    let (mut book, cap) = realistic_decimals_book<BTC, USDC>(53, &mut scenario);
    assert!(book.price_scale() == 100, 0);

    // maker_fee_bps starts nonzero (3) -- unlike the 0-to-nonzero test above.
    cap.clob_admin_set_maker_fee(&mut book, 3);

    // A bid rests while maker_fee_bps == 3, snapshotting that rate.
    let bid_price = 100 * 500; // = 50_000, an exact multiple of price_scale
    let bid_size = 2500; // chosen so the 3-bps vs. 5-bps ceil()s land on
    // genuinely different integers (see the hand computation below), not on
    // the same value by coincidence.
    scenario.next_tx(maker_a());
    let bid_escrow = book.bid_escrow_amount(bid_price, bid_size);
    assert!(bid_escrow == 500 * 2500, 1); // = 1_250_000, exact
    let bid_payment = coin::mint_for_testing<USDC>(bid_escrow, scenario.ctx());
    let (bid_ticket_opt, bid_matched, bid_leftover, _) =
        book.place_limit_order_bid(bid_payment, bid_size, 10, scenario.ctx());
    assert!(bid_matched.burn_for_testing() == 0, 2);
    assert!(bid_leftover.burn_for_testing() == 0, 3);
    let bid_ticket = bid_ticket_opt.destroy_some();
    let bid_order_id = bid_ticket.ticket_order_id();

    // The rate is raised AGAIN, to a DIFFERENT nonzero value (the module's
    // max, 5), while the bid still rests -- this must not retroactively
    // touch its 3-bps snapshot.
    scenario.next_tx(admin());
    cap.clob_admin_set_maker_fee(&mut book, 5);

    // A taker fully crosses the bid with a matching-size limit ask; the
    // resting bid concludes in this single fill.
    scenario.next_tx(taker());
    let cross_size = bid_size;
    let cross_payment = coin::mint_for_testing<BTC>(cross_size, scenario.ctx());
    let cross_expected_quote_output = book.bid_escrow_amount(bid_price, cross_size);
    assert!(cross_expected_quote_output == 1_250_000, 4);
    let (cross_ticket_opt, cross_leftover, cross_matched, cross_stopped) =
        book.place_limit_order_ask(cross_payment, cross_expected_quote_output, 10, scenario.ctx());
    assert!(!cross_stopped, 5);
    assert!(cross_ticket_opt.is_none(), 6); // taker's own order fully filled, doesn't rest
    cross_ticket_opt.destroy_none();
    assert!(cross_leftover.burn_for_testing() == 0, 7);
    assert!(cross_matched.burn_for_testing() == cross_expected_quote_output, 8); // taker fee still 0

    // The bid is now fully concluded and gone from the book.
    assert!(book.resting_order_escrow(true, bid_price, bid_order_id).is_none(), 9);

    // The settled `MakerFeeSettled` amount must reflect the ORIGINAL 3-bps
    // snapshot (ceil(2_500 * 3 / 10_000) = 1), not the NEW live rate of 5
    // bps (which would have produced the visibly different ceil(2_500 * 5 /
    // 10_000) = 2).
    let original_rate_fee = (bid_size * 3 + 9_999) / 10_000;
    assert!(original_rate_fee == 1, 10);
    let wrong_live_rate_fee = (bid_size * 5 + 9_999) / 10_000;
    assert!(wrong_live_rate_fee == 2, 11);
    assert!(original_rate_fee != wrong_live_rate_fee, 12); // the two must be distinguishable

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 1, 13);
    let (ev_order_id, ev_book_id, ev_maker, ev_amount) = settled[0].maker_fee_settled_fields_for_testing();
    assert!(ev_order_id == bid_order_id, 14);
    assert!(ev_book_id == book.event_id_for_testing(), 15);
    assert!(ev_maker == maker_a(), 16);
    assert!(ev_amount == original_rate_fee, 17); // = 1, NOT wrong_live_rate_fee's 2

    let (fee_base, fee_quote) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(fee_base.burn_for_testing() == original_rate_fee, 18); // = 1
    assert!(fee_quote.burn_for_testing() == 0, 19);

    // Claim maker_a()'s pooled proceeds (bid_size - original_rate_fee base)
    // before disposing of the now-orphaned ticket.
    scenario.next_tx(maker_a());
    let (claim_base, claim_quote, claim_ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == bid_size - original_rate_fee, 20); // = 2_499
    assert!(claim_quote.burn_for_testing() == 0, 21);
    assert!(claim_ticket_opt.is_none(), 22); // nothing left resting -> ticket consumed
    claim_ticket_opt.destroy_none();
    std::unit_test::destroy(book);
    std::unit_test::destroy(cap);
    scenario.end();
}

fun unit_test_destroy_ticket(ticket: OrderTicket) {
    std::unit_test::destroy(ticket);
}

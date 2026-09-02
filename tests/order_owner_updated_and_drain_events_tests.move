#[test_only]
module tiny_clob::order_owner_updated_and_drain_events_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};
use tiny_clob::test_utils::{
    Self, admin, other, taker, maker_a, maker_b, maker_c, min_size, default_price, default_size, new_book, destroy_book_and_cap, rest_bid, rest_ask,
};


// === Change 4: `OrderOwnerUpdated` event ===

#[test]
fun update_resting_order_reassign_emits_order_owner_updated_with_correct_fields() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    let book_id = book.book_id();

    let found = book.update_resting_order(&mut bid_ticket, other());
    assert!(found, 0);

    let events = event::events_by_type<tiny_clob::OrderOwnerUpdated>();
    assert!(events.length() == 1, 1);
    let (ev_book_id, ev_enclosing_id, ev_order_id, ev_old_owner, ev_new_owner) =
        events[0].order_owner_updated_fields_for_testing();
    assert!(ev_order_id == order_id, 2);
    assert!(ev_book_id == book_id, 3);
    assert!(ev_enclosing_id == book.enclosing_object_id_for_testing(), 6);
    assert!(ev_old_owner == admin(), 4); // scenario sender at rest_bid time
    assert!(ev_new_owner == other(), 5);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_to_same_address_still_emits() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Reassigning to the SAME owner (admin(), unchanged) must still fire the
    // event -- the write is unconditional on the found branch, regardless
    // of whether the address actually changes.
    let found = book.update_resting_order(&mut bid_ticket, admin());
    assert!(found, 0);

    let events = event::events_by_type<tiny_clob::OrderOwnerUpdated>();
    assert!(events.length() == 1, 1);
    let (_, _, ev_order_id, ev_old_owner, ev_new_owner) =
        events[0].order_owner_updated_fields_for_testing();
    assert!(ev_order_id == order_id, 2);
    assert!(ev_old_owner == admin(), 3);
    assert!(ev_new_owner == admin(), 4);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_not_found_paths_emit_no_event() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Empty-book path: no price level exists at all.
    let book_id = book.book_id();
    let mut empty_book_ticket =
        tiny_clob::new_ticket_for_testing(0, book_id, tiny_clob::bid(), default_price());
    let found_empty = book.update_resting_order(&mut empty_book_ticket, other());
    assert!(!found_empty, 0);
    unit_test::destroy(empty_book_ticket);

    // Level-exists-but-wrong-order-id path.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    let side = bid_ticket.ticket_side();
    let price = bid_ticket.ticket_price();
    let mut wrong_id_ticket = tiny_clob::new_ticket_for_testing(order_id + 1, book_id, side, price);
    let found_wrong_id = book.update_resting_order(&mut wrong_id_ticket, other());
    assert!(!found_wrong_id, 1);
    unit_test::destroy(wrong_id_ticket);

    assert!(event::events_by_type<tiny_clob::OrderOwnerUpdated>().length() == 0, 2);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// A former test here, `update_resting_order_reassign_emits_event_and_syncs_
// pooled_proceeds`, covered the same ground as two other tests combined:
// `update_resting_order_reassign_emits_order_owner_updated_with_correct_fields`
// above (full `OrderOwnerUpdated` field assertions, including `book_id`/
// `enclosing_object_id`, which this test only ever asserted a subset of)
// and `update_resting_order_found_reassigns_owner_and_credits_new_owner_on_push`
// in `cancellation_and_proceeds_tests.move` (the identical rest-bid ->
// reassign -> cross -> retire -> push_proceeds -> assert-claimant-is-new-
// owner sequence). It added no assertion neither of those two already made
// together, so it was removed as a strict subset rather than kept as a
// third near-duplicate.

// === Change 5: per-item events in `clob_admin_drain_step`'s helpers ===

// A resting bid whose maker_fee_bps is (test-only, via direct `order::new`)
// set to 100% has its entire matched Base payment consumed by the maker
// fee, so its credited proceeds are zero in BOTH legs. `credit_maker_table`
// deliberately skips creating a pooled `MakerBalance` entry for a credit
// that is entirely zero-valued when no entry exists yet (closing a footgun
// where such an entry would otherwise block `destroy_orphaned_ticket`'s
// presence check despite protecting no real funds) -- so no entry ever
// exists for this order at all. `drain_proceeds` therefore has nothing to
// find for it and emits no `ProceedsClaimed`, while still emitting one for
// the ordinary (nonzero) order alongside it. NOTE: this does NOT exercise
// `drain_proceeds`'s own zero-value skip-guard -- since `credit_maker_table`
// is the only creator of `MakerBalance` entries and never creates one this
// way, that guard is unreachable in production and is not covered by this
// (or any) test; it remains only as defensive dead code.
#[test]
fun clob_admin_drain_step_emits_proceeds_claimed_only_for_the_nonzero_order() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let price = default_price();
    let size_zero = min_size();
    let size_normal = min_size();

    scenario.next_tx(maker_a());
    let order_id_zero = book.next_order_id();
    let escrow_zero = balance::create_for_testing<USDC>(price * size_zero);
    let order_zero =
        order::new<BTC, USDC>(order_id_zero, maker_a(), size_zero, option::none(), option::some(escrow_zero), 10_000);
    book.insert_resting_order_for_testing(true, price, order_zero, scenario.ctx());

    scenario.next_tx(maker_b());
    let order_id_normal = book.next_order_id();
    let escrow_normal = balance::create_for_testing<USDC>(price * size_normal);
    let order_normal =
        order::new<BTC, USDC>(order_id_normal, maker_b(), size_normal, option::none(), option::some(escrow_normal), 0);
    book.insert_resting_order_for_testing(true, price, order_normal, scenario.ctx());

    // Cross both resting bids fully with a single market ask (FIFO: fills
    // order_zero, then order_normal).
    scenario.next_tx(taker());
    let total_size = size_zero + size_normal;
    let ask_payment = coin::mint_for_testing<BTC>(total_size, scenario.ctx());
    let (leftover, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, total_size, scenario.ctx(),
    );
    leftover.burn_for_testing();
    matched_quote.burn_for_testing();

    // No entry is ever created for the zero-fee order -- there is nothing
    // to skip at drain time, only nothing to find.
    assert!(!book.proceeds_contains_for_testing(order_id_zero), 0);
    assert!(book.proceeds_contains_for_testing(order_id_normal), 1);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, ev_base, ev_quote) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == maker_b(), 3);
    assert!(ev_base == size_normal, 4);
    assert!(ev_quote == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Merge item 3: this test used to have a sibling,
// `clob_admin_drain_step_emits_order_cancelled_per_drained_order`, covering
// a mixed bid/bid/ask drain but asserting only the event COUNT (not
// per-event id/trader fields). That sibling is folded in here rather than
// kept separate: a 4th resting order (an ask, from a distinct trader at a
// distinct price) is added below to preserve its mixed-side-drain coverage,
// while this test's stronger per-event id/trader assertions now cover it
// too — `clob_admin_drain_step` always fully drains the bid side (in FIFO
// order per level) before the ask side (see `clob_admin_drain_step`'s
// body), so the ask's `OrderCancelled` is deterministically the 4th event.
#[test]
fun clob_admin_drain_step_order_cancelled_events_carry_correct_ids_and_traders() {
    let mut scenario = ts::begin(admin());
    // Constructed with a deliberately foreign `enclosing_object_id` (see the
    // idiom in construction_and_admin_tests.move's
    // `every_event_type_stamps_true_book_id_and_foreign_enclosing_object_id_independently`)
    // so this test can also assert `drain_side`'s `OrderCancelled` emit
    // stamps BOTH id fields correctly -- previously unchecked anywhere.
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 0, 0, 17, 1, &wrapper_uid, scenario.ctx());
    let true_book_id = book.book_id();
    assert!(true_book_id != foreign_id, 5);

    scenario.next_tx(maker_a());
    let ticket_a = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    scenario.next_tx(maker_b());
    let ticket_b = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    scenario.next_tx(maker_c());
    let ticket_c = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    scenario.next_tx(other());
    let ticket_d = rest_ask(&mut book, default_price() + 137, default_size(), 10, scenario.ctx());

    let id_a = ticket_a.ticket_order_id();
    let id_b = ticket_b.ticket_order_id();
    let id_c = ticket_c.ticket_order_id();
    let id_d = ticket_d.ticket_order_id();

    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    let events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(events.length() == 4, 0);
    // FIFO order within the bid side: A, B, C were inserted in that order at
    // the same price; the ask D drains only after the whole bid side does.
    let (ev_book_a, ev_enclosing_a, ev_id_a, ev_trader_a) = events[0].order_cancelled_fields_for_testing();
    let (ev_book_b, ev_enclosing_b, ev_id_b, ev_trader_b) = events[1].order_cancelled_fields_for_testing();
    let (ev_book_c, ev_enclosing_c, ev_id_c, ev_trader_c) = events[2].order_cancelled_fields_for_testing();
    let (ev_book_d, ev_enclosing_d, ev_id_d, ev_trader_d) = events[3].order_cancelled_fields_for_testing();
    assert!(ev_id_a == id_a && ev_trader_a == maker_a(), 1);
    assert!(ev_id_b == id_b && ev_trader_b == maker_b(), 2);
    assert!(ev_id_c == id_c && ev_trader_c == maker_c(), 3);
    assert!(ev_id_d == id_d && ev_trader_d == other(), 4);
    assert!(ev_book_a == true_book_id && ev_enclosing_a == foreign_id, 6);
    assert!(ev_book_b == true_book_id && ev_enclosing_b == foreign_id, 7);
    assert!(ev_book_c == true_book_id && ev_enclosing_c == foreign_id, 8);
    assert!(ev_book_d == true_book_id && ev_enclosing_d == foreign_id, 9);

    unit_test::destroy(ticket_a);
    unit_test::destroy(ticket_b);
    unit_test::destroy(ticket_c);
    unit_test::destroy(ticket_d);
    wrapper_uid.delete();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Multi-order drain, but now asserting `MakerFeeSettled`'s own fields
// per-order (not just `OrderCancelled`'s, covered above) --
// `clob_admin_drain_step` unconditionally runs the maker-fee true-up
// (`fold_maker_fee_slack` -> `conclude_order_fee`) on every drained order,
// alongside the `OrderCancelled` it emits for that same order (see
// `drain_side` in `sources/tiny_clob.move`), so this must hold for MULTIPLE
// simultaneously-drained orders in a single call, not just the single-order
// scenarios covered in `fee_redesign_tests.move`.
//
// Fixture: a nonzero `MAKER_FEE_BPS` (5 -- `MAX_MAKER_FEE_BPS`, the highest
// rate `clob_admin_set_maker_fee` accepts) is set via
// `clob_admin_set_maker_fee` *before* any order rests, so every order's
// snapshotted `maker_fee_bps` (captured at insertion time from the book's
// current rate -- see `place_limit_order_bid`/`_ask`'s
// `maker_fee_bps_snapshot`) is 5, not 0.
//
// Four resting orders, three bids (FIFO: A, B, C, all at `default_price()`,
// size 1_000 each) plus one ask (D, other(), size 1_000, at
// `default_price() + 137`):
//   - A is partially filled 150 units (of its 1_000) by a market ask with
//     `max_fills = 1` -- `max_fills` gates the number of *orders* a sweep can
//     touch (see `sources/tiny_clob.move`'s doc comment on `min_size`: "each
//     resting order ... consumes exactly one `max_fills` slot"), so this
//     touches ONLY A (the FIFO head), leaving B and C completely untouched.
//     (150, not something smaller, because `place_market_order_ask` itself
//     `validate_size`s its Base-denominated fill size against the book's
//     `min_size` floor of 100.) A bid's `fee_basis_accumulated` is
//     Base-denominated fill quantity directly (see `fill_level_ask`'s
//     `increase_fee_basis_accumulated(fill_qty)`), so A's fee basis is
//     exactly 150.
//   - B and C are never filled at all -- their `fee_basis_accumulated` stays
//     0, so `fee_amount(0, 5) == 0`: their settled amount must come out to
//     exactly 0 (not skipped -- `conclude_order_fee` emits unconditionally).
//   - D is partially filled 100 units (of its 1_000) by a market bid with
//     `max_fills = 1`, isolating it as the only (and therefore front-of-queue)
//     ask. An ask's `fee_basis_accumulated` is Quote-denominated cumulative
//     `quote_cost` (see `fill_level_bid`'s
//     `increase_fee_basis_accumulated(quote_cost)`), and at this book's
//     `price_scale == 1` (see `new_book`), `quote_cost == price * fill_qty`
//     exactly: `50_137 * 100 = 5_013_700`.
//
// Hand-computed expected `MakerFeeSettled.amount` (`ceil(fee_basis * 5 /
// 10_000)`, per `fee_amount`'s doc comment and formula in
// `sources/tiny_clob.move`):
//   - A: ceil(150 * 5 / 10_000) = ceil(750 / 10_000) = 1.
//   - B: ceil(0 * 5 / 10_000) = 0.
//   - C: ceil(0 * 5 / 10_000) = 0.
//   - D: ceil(5_013_700 * 5 / 10_000) = ceil(25_068_500 / 10_000) =
//     ceil(2_506.85) = 2_507.
//
// These four values are not all identical (1, 0, 0, 2_507), so the
// per-event assertions below actually distinguish correct from incorrect
// per-order attribution -- e.g. a bug that attributed D's amount to A (or
// vice versa) would be caught, unlike a fixture where every order settled
// for the same amount.
#[test]
fun clob_admin_drain_step_maker_fee_settled_events_carry_correct_per_order_amounts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let maker_fee_bps = 5; // MAX_MAKER_FEE_BPS
    cap.clob_admin_set_maker_fee(&mut book, maker_fee_bps);

    let price_bid = default_price();
    let size_a = 1_000;
    let size_b = 1_000;
    let size_c = 1_000;
    scenario.next_tx(maker_a());
    let ticket_a = rest_bid(&mut book, price_bid, size_a, 10, scenario.ctx());
    scenario.next_tx(maker_b());
    let ticket_b = rest_bid(&mut book, price_bid, size_b, 10, scenario.ctx());
    scenario.next_tx(maker_c());
    let ticket_c = rest_bid(&mut book, price_bid, size_c, 10, scenario.ctx());

    let price_ask = default_price() + 137;
    let size_d = 1_000;
    scenario.next_tx(other());
    let ticket_d = rest_ask(&mut book, price_ask, size_d, 10, scenario.ctx());

    let id_a = ticket_a.ticket_order_id();
    let id_b = ticket_b.ticket_order_id();
    let id_c = ticket_c.ticket_order_id();
    let id_d = ticket_d.ticket_order_id();

    // Partially fill A only: `max_fills = 1` caps the sweep to the single
    // FIFO-head bid (A), regardless of the 150-unit payment being far short
    // of A's 1_000-unit size and B/C sitting right behind it. (150, not a
    // smaller value like 40, because `place_market_order_ask` itself
    // `validate_size`s its Base-denominated `size` against the book's
    // `min_size` floor of 100 -- see `MIN_SIZE` in `test_utils.move`.)
    scenario.next_tx(taker());
    let fill_a_amount = 150;
    let ask_payment = coin::mint_for_testing<BTC>(fill_a_amount, scenario.ctx());
    let (leftover_base, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 1, 0, fill_a_amount, scenario.ctx());
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();

    // Partially fill D only: `max_fills = 1` again, and D is the book's only
    // resting ask, so it's trivially the front of its own queue.
    let fill_d_amount = 100;
    let fill_d_quote_cost = price_ask * fill_d_amount; // 50_137 * 100 = 5_013_700
    let bid_payment = coin::mint_for_testing<USDC>(fill_d_quote_cost, scenario.ctx());
    let (matched_base, leftover_quote, _) =
        book.place_market_order_bid(bid_payment, 1, 0, fill_d_amount, fill_d_quote_cost, scenario.ctx());
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();

    assert!(event::events_by_type<tiny_clob::MakerFeeSettled>().length() == 0, 0);

    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    let cancelled = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled.length() == 4, 1);

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 4, 2);

    // FIFO order within the bid side (A, B, C), then the ask side (D) --
    // same deterministic ordering as
    // `clob_admin_drain_step_order_cancelled_events_carry_correct_ids_and_traders`
    // above.
    let (ev_book_a, _, ev_id_a, ev_maker_a, ev_amount_a) = settled[0].maker_fee_settled_fields_for_testing();
    let (_, _, ev_id_b, ev_maker_b, ev_amount_b) = settled[1].maker_fee_settled_fields_for_testing();
    let (_, _, ev_id_c, ev_maker_c, ev_amount_c) = settled[2].maker_fee_settled_fields_for_testing();
    let (_, _, ev_id_d, ev_maker_d, ev_amount_d) = settled[3].maker_fee_settled_fields_for_testing();

    assert!(ev_id_a == id_a && ev_maker_a == maker_a() && ev_amount_a == 1, 3);
    assert!(ev_id_b == id_b && ev_maker_b == maker_b() && ev_amount_b == 0, 4);
    assert!(ev_id_c == id_c && ev_maker_c == maker_c() && ev_amount_c == 0, 5);
    assert!(ev_id_d == id_d && ev_maker_d == other() && ev_amount_d == 2_507, 6);
    assert!(ev_book_a == book.book_id(), 7);

    unit_test::destroy(ticket_a);
    unit_test::destroy(ticket_b);
    unit_test::destroy(ticket_c);
    unit_test::destroy(ticket_d);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Same 4-order fixture as
// `clob_admin_drain_step_maker_fee_settled_events_carry_correct_per_order_amounts`
// above, but this time checking a different property: not that each
// individual `MakerFeeSettled.amount` is independently plausible, but that
// the events COLLECTIVELY reconcile with the actual state change --
// `conclude_order_fee` (see `sources/tiny_clob.move`) splits exactly
// `correct_total_fee` out of the order's held-aside `fee_reserve` and
// `join`s it straight into `book.fee_accumulator`'s same-currency leg,
// alongside emitting `MakerFeeSettled` with that same `correct_total_fee` as
// `amount` -- so for a whole multi-order drain, summing every
// `MakerFeeSettled.amount` on one currency leg must equal exactly that
// leg's `fee_accumulator_balances` delta across the call. A bug that emitted
// a plausible-looking `amount` without actually moving that amount into the
// accumulator (or moved a different amount than it reported) would sail
// through the per-order test above but be caught here.
//
// A(bid), B(bid), C(bid) settle in Base (a bid's maker fee reserve is
// Base-denominated -- see `order::new`'s bid branch and
// `fill_level_ask`/`fold_maker_fee_slack`'s `fee_reserve_base` handling);
// D(ask) settles in Quote. Expected per-order amounts are hand-computed
// identically to the sibling test above:
//   - A: ceil(150 * 5 / 10_000) = 1.
//   - B: ceil(0 * 5 / 10_000) = 0.
//   - C: ceil(0 * 5 / 10_000) = 0.
//   - D: ceil(5_013_700 * 5 / 10_000) = 2_507.
// So the expected Base-leg accumulator delta is 1 + 0 + 0 = 1, and the
// expected Quote-leg accumulator delta is 2_507.
#[test]
fun clob_admin_drain_step_maker_fee_settled_events_sum_matches_accumulator_delta() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let maker_fee_bps = 5; // MAX_MAKER_FEE_BPS
    cap.clob_admin_set_maker_fee(&mut book, maker_fee_bps);

    let price_bid = default_price();
    let size_a = 1_000;
    let size_b = 1_000;
    let size_c = 1_000;
    scenario.next_tx(maker_a());
    let ticket_a = rest_bid(&mut book, price_bid, size_a, 10, scenario.ctx());
    scenario.next_tx(maker_b());
    let ticket_b = rest_bid(&mut book, price_bid, size_b, 10, scenario.ctx());
    scenario.next_tx(maker_c());
    let ticket_c = rest_bid(&mut book, price_bid, size_c, 10, scenario.ctx());

    let price_ask = default_price() + 137;
    let size_d = 1_000;
    scenario.next_tx(other());
    let ticket_d = rest_ask(&mut book, price_ask, size_d, 10, scenario.ctx());

    // Partially fill A only (max_fills = 1 caps the sweep to the FIFO-head
    // bid), same as the sibling test above.
    scenario.next_tx(taker());
    let fill_a_amount = 150;
    let ask_payment = coin::mint_for_testing<BTC>(fill_a_amount, scenario.ctx());
    let (leftover_base, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 1, 0, fill_a_amount, scenario.ctx());
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();

    // Partially fill D only (max_fills = 1, D is the book's only ask).
    let fill_d_amount = 100;
    let fill_d_quote_cost = price_ask * fill_d_amount; // 50_137 * 100 = 5_013_700
    let bid_payment = coin::mint_for_testing<USDC>(fill_d_quote_cost, scenario.ctx());
    let (matched_base, leftover_quote, _) =
        book.place_market_order_bid(bid_payment, 1, 0, fill_d_amount, fill_d_quote_cost, scenario.ctx());
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();

    let (fee_base_before, fee_quote_before) = book.fee_accumulator_balances();

    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();

    let order_id_a = ticket_a.ticket_order_id();
    let order_id_b = ticket_b.ticket_order_id();
    let order_id_c = ticket_c.ticket_order_id();
    let order_id_d = ticket_d.ticket_order_id();

    let settled = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled.length() == 4, 0);

    // Bind each event to its expected order by `order_id`, not by
    // positional index -- so the A/B/C -> Base, D -> Quote currency
    // grouping doesn't silently rest on an unasserted assumption about
    // drain order.
    let mut ev_amount_a = 0;
    let mut ev_amount_b = 0;
    let mut ev_amount_c = 0;
    let mut ev_amount_d = 0;
    let mut i = 0;
    while (i < settled.length()) {
        let (_, _, ev_order_id, _, ev_amount) = settled[i].maker_fee_settled_fields_for_testing();
        if (ev_order_id == order_id_a) { ev_amount_a = ev_amount }
        else if (ev_order_id == order_id_b) { ev_amount_b = ev_amount }
        else if (ev_order_id == order_id_c) { ev_amount_c = ev_amount }
        else if (ev_order_id == order_id_d) { ev_amount_d = ev_amount }
        else { assert!(false, 99) }; // unexpected order_id
        i = i + 1;
    };

    // Individual amounts, not just the sum: B and C never filled, so their
    // correct settled amount is exactly 0 each -- (0, 1, 0) would satisfy
    // only a sum-of-3 check but not this.
    assert!(ev_amount_a == 1, 5);
    assert!(ev_amount_b == 0, 6);
    assert!(ev_amount_c == 0, 7);
    assert!(ev_amount_d == 2_507, 8);

    let base_sum = ev_amount_a + ev_amount_b + ev_amount_c;
    let quote_sum = ev_amount_d;
    assert!(base_sum == 1, 1);
    assert!(quote_sum == 2_507, 2);

    // The actual reconciliation: the summed event amounts on each currency
    // leg must equal exactly that leg's real accumulator delta -- not just
    // look individually plausible.
    assert!(fee_base_after - fee_base_before == base_sum, 3);
    assert!(fee_quote_after - fee_quote_before == quote_sum, 4);

    unit_test::destroy(ticket_a);
    unit_test::destroy(ticket_b);
    unit_test::destroy(ticket_c);
    unit_test::destroy(ticket_d);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === `push_proceeds` on an already-claimed entry ===

// Distinct from `push_proceeds_with_no_pooled_entry_is_silent_noop` in
// `construction_and_admin_tests.move` (an order_id for which no pooled
// entry was EVER created): here the order genuinely earns pooled proceeds
// via a real partial fill, those proceeds are claimed once via
// `push_proceeds` (removing the entry -- see `claim_maker_balance`), and
// `push_proceeds` is then called AGAIN on the same, now-empty order_id.
// `claim_maker_balance` returns zero balances for a missing entry, so the
// second call must be an equally silent no-op: no abort, no second
// `ProceedsClaimed` event, and (checked concretely, not just via event
// absence) no second payment actually reaching the claimant.
#[test]
fun push_proceeds_on_already_claimed_entry_is_silent_noop() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let size = 300;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Partially fill so the order earns a real, nonzero pooled Base credit.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx());
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // First push_proceeds: genuinely claims the pooled credit. The retire
    // call below is a harmless no-op setup step, not a requirement of
    // push_proceeds itself.
    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    assert!(!book.proceeds_contains_for_testing(order_id), 1);

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, ev_base, ev_quote) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 3); // rest_bid's caller here (no next_tx before it)
    assert!(ev_base == fill_size, 4);
    assert!(ev_quote == 0, 5);

    // Second push_proceeds on the same, now-empty order_id, still in the
    // same transaction: a genuine no-op must NOT add a second event to the
    // event log accumulated so far this tx (`event::events_by_type` is
    // scoped per-transaction in this test framework -- it resets across
    // `scenario.next_tx`, but accumulates within one, exactly like the
    // multi-call drain tests elsewhere in this file), so the count must stay
    // at 1, not grow to 2.
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    assert!(event::events_by_type<tiny_clob::ProceedsClaimed>().length() == 1, 6);

    // Confirm exactly ONE payment ever reached the claimant -- not a silent
    // second transfer that merely skipped the event. take_from_address
    // consumes the single Coin<BTC> object created by the first (real) push;
    // if the second push had transferred anything at all, a second object
    // would still be sitting in admin()'s inventory afterward.
    scenario.next_tx(admin());
    let paid_base = scenario.take_from_address<coin::Coin<BTC>>(admin());
    assert!(paid_base.value() == fill_size, 7);
    paid_base.burn_for_testing();
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(admin()), 8);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === `destroy_ticket_unconditionally` mid-drain ===

// Distinct from both `destroy_ticket_unconditionally_disposes_with_real_escrow_and_proceeds_still_attached`
// (order still resting) and `destroy_ticket_unconditionally_disposes_ticket_after_book_finalized`
// (book already deleted) in `cancellation_and_proceeds_tests.move`: this is
// the middle case -- the book has been retired and a drain step has already
// force-cancelled this specific order OUT of the book (it no longer rests
// anywhere), but the book itself has NOT been finalized/deleted yet. The
// ticket needs neither the order to still exist (it doesn't self-serve via
// the book at all) nor the book to still exist (same reason) -- confirming
// this succeeds with no abort exercises that the function's two
// independences hold separately, not just in combination.
#[test]
fun destroy_ticket_unconditionally_disposes_ticket_after_mid_drain_force_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Retire, then force-cancel the resting order via a drain step -- this
    // removes it from the book (and refunds its escrow) without finalizing
    // (deleting) the book itself.
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    // The order is genuinely gone from the book, but the book object is
    // still alive: both halves of the "still alive, but order already gone"
    // premise hold before the disposal call below.
    assert!(book.bids_size_for_testing() == 0, 0);
    assert!(!book.proceeds_contains_for_testing(order_id), 1);
    let cancelled = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled.length() == 1, 2);

    bid_ticket.destroy_ticket_unconditionally(); // must not abort

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Multi-call `max_items` carry-over across bids/asks/proceeds ===

// Every prior `clob_admin_drain_step` test in this file uses a `max_items`
// generous enough to fully drain a small (<=4 order) fixture in ONE call.
// None of them ever observe `remaining` (the shared budget threaded through
// `drain_side(bids)` -> `drain_side(asks)` -> `drain_proceeds` inside a
// single call, and carried forward -- implicitly, via a fresh `max_items`
// argument -- across separate calls) actually being exhausted partway
// through a category and picked back up correctly.
//
// Fixture: 2 pooled-proceeds entries (P1, P2 -- created up front by fully
// filling two directly-inserted resting bids with one market ask, so they
// leave the resting tree entirely and become ordinary pooled
// `MakerBalance` entries in `book.proceeds`, untouched by `drain_side`),
// then 3 further resting bids (A, B, C, each at ITS OWN distinct price, so
// `bids_size_for_testing` -- a count of distinct PRICE LEVELS, not orders --
// tracks the remaining-bid-order count 1:1) and 3 resting asks (D, E, F,
// likewise each at its own distinct price). Total: 8 items across 3
// categories.
//
// `drain_side` drains bids highest-price-first (`want_max = true`) and asks
// lowest-price-first (`want_max = false`) -- see its `tree.max_leaf()` /
// `tree.min_leaf()` call in `sources/tiny_clob.move`. Bids are seeded at
// ascending prices A < B < C, so the drain order is C, B, A. Asks are seeded
// at ascending prices D < E < F, so the drain order is D, E, F. Proceeds
// drain FIFO (`LinkedTable::pop_front`), so P1 then P2.
//
// Three calls, chosen so the second call's `remaining` budget is exhausted
// PARTWAY into asks after finishing off the last bid -- the actual gap this
// test targets, per the task's own framing (not just "a category boundary
// lands on a call boundary", which every existing test already does trivially
// by using one oversized call):
//   - Call 1 (`max_items = 2`): drains bids C and B only. Bid A is left
//     resting -- `max_items` exhausts PARTWAY through the bid side.
//   - Call 2 (`max_items = 4`): `drain_side(bids)` drains the single
//     remaining bid A (consuming 1 of the 4), then -- WITHOUT a fresh
//     `max_items` from the caller -- `drain_side(asks)` picks up the
//     leftover budget of 3 and drains all of D, E, F exactly. This is the
//     one call that actually exercises the "remaining carries from bids into
//     asks within a single call" path a small, one-call-finishes-everything
//     fixture can never reach.
//   - Call 3 (`max_items = 2`): bids/asks are both empty (`drain_side`
//     no-ops instantly, without touching `remaining`), so all 2 units go to
//     `drain_proceeds`, draining P1 and P2.
//
// After call 3, the book must be fully drained -- proven definitively by a
// final `clob_admin_finalize` call succeeding (it asserts
// `bids.size() == 0 && asks.size() == 0 && proceeds.is_empty()`, aborting
// with `ENotFullyDrained` otherwise; the fee accumulator no longer needs to
// be pre-drained -- `clob_admin_finalize` sweeps it and returns the swept
// amount as `Coin<Base>`/`Coin<Quote>`).
#[test]
fun clob_admin_drain_step_carries_remaining_budget_across_bid_ask_proceeds_boundaries() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    let price = default_price();
    let size = min_size();

    // --- Two pooled-proceeds entries (P1, P2), fully filled and removed
    // from the resting tree before anything else is seeded, so they can
    // only ever be observed via `drain_proceeds`, never `drain_side`.
    scenario.next_tx(maker_a());
    let order_id_p1 = book.next_order_id();
    let escrow_p1 = balance::create_for_testing<USDC>(price * size);
    let order_p1 =
        order::new<BTC, USDC>(order_id_p1, maker_a(), size, option::none(), option::some(escrow_p1), 0);
    book.insert_resting_order_for_testing(true, price, order_p1, scenario.ctx());

    let order_id_p2 = book.next_order_id();
    let escrow_p2 = balance::create_for_testing<USDC>(price * size);
    let order_p2 =
        order::new<BTC, USDC>(order_id_p2, maker_b(), size, option::none(), option::some(escrow_p2), 0);
    book.insert_resting_order_for_testing(true, price, order_p2, scenario.ctx());

    scenario.next_tx(taker());
    let proceeds_fill_size = size * 2;
    let proceeds_ask_payment = coin::mint_for_testing<BTC>(proceeds_fill_size, scenario.ctx());
    let (proceeds_leftover, proceeds_matched_quote, _) = book.place_market_order_ask(
        proceeds_ask_payment, 1_000_000_000, 0, proceeds_fill_size, scenario.ctx(),
    );
    proceeds_leftover.burn_for_testing();
    proceeds_matched_quote.burn_for_testing();

    assert!(book.proceeds_contains_for_testing(order_id_p1), 0);
    assert!(book.proceeds_contains_for_testing(order_id_p2), 1);
    assert!(book.bids_size_for_testing() == 0, 2); // both proceeds bids fully filled, tree empty again

    // --- Three resting bids (A, B, C), each at its own distinct price, in
    // ascending order -- `drain_side`'s `want_max = true` for bids drains
    // highest-price-first, so the expected drain order is C, B, A.
    scenario.next_tx(maker_a());
    let order_id_a = book.next_order_id();
    let price_a = price + 10;
    let escrow_a = balance::create_for_testing<USDC>(book.bid_escrow_amount(price_a, size));
    let order_a = order::new<BTC, USDC>(order_id_a, maker_a(), size, option::none(), option::some(escrow_a), 0);
    book.insert_resting_order_for_testing(true, price_a, order_a, scenario.ctx());

    let order_id_b = book.next_order_id();
    let price_b = price + 20;
    let escrow_b = balance::create_for_testing<USDC>(book.bid_escrow_amount(price_b, size));
    let order_b = order::new<BTC, USDC>(order_id_b, maker_b(), size, option::none(), option::some(escrow_b), 0);
    book.insert_resting_order_for_testing(true, price_b, order_b, scenario.ctx());

    let order_id_c = book.next_order_id();
    let price_c = price + 30;
    let escrow_c = balance::create_for_testing<USDC>(book.bid_escrow_amount(price_c, size));
    let order_c = order::new<BTC, USDC>(order_id_c, maker_c(), size, option::none(), option::some(escrow_c), 0);
    book.insert_resting_order_for_testing(true, price_c, order_c, scenario.ctx());

    // --- Three resting asks (D, E, F), each at its own distinct price, in
    // ascending order -- `drain_side`'s `want_max = false` for asks drains
    // lowest-price-first, so the expected drain order is D, E, F.
    let ask_price = price + 137;
    let order_id_d = book.next_order_id();
    let escrow_d = balance::create_for_testing<BTC>(size);
    let order_d = order::new<BTC, USDC>(order_id_d, admin(), size, option::some(escrow_d), option::none(), 0);
    book.insert_resting_order_for_testing(false, ask_price + 10, order_d, scenario.ctx());

    let order_id_e = book.next_order_id();
    let escrow_e = balance::create_for_testing<BTC>(size);
    let order_e = order::new<BTC, USDC>(order_id_e, other(), size, option::some(escrow_e), option::none(), 0);
    book.insert_resting_order_for_testing(false, ask_price + 20, order_e, scenario.ctx());

    let order_id_f = book.next_order_id();
    let escrow_f = balance::create_for_testing<BTC>(size);
    let order_f = order::new<BTC, USDC>(order_id_f, taker(), size, option::some(escrow_f), option::none(), 0);
    book.insert_resting_order_for_testing(false, ask_price + 30, order_f, scenario.ctx());

    assert!(book.bids_size_for_testing() == 3, 3);

    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);

    // --- Call 1: max_items = 2 -- drains C and B, leaves A resting.
    cap.clob_admin_drain_step(&mut book, 2, scenario.ctx());

    assert!(book.bids_size_for_testing() == 1, 4);
    let cancelled_1 = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_1.length() == 2, 5);
    let (_, _, ev_id_0, ev_trader_0) = cancelled_1[0].order_cancelled_fields_for_testing();
    let (_, _, ev_id_1, ev_trader_1) = cancelled_1[1].order_cancelled_fields_for_testing();
    assert!(ev_id_0 == order_id_c && ev_trader_0 == maker_c(), 6);
    assert!(ev_id_1 == order_id_b && ev_trader_1 == maker_b(), 7);
    assert!(event::events_by_type<tiny_clob::ProceedsClaimed>().length() == 0, 8);
    assert!(book.proceeds_contains_for_testing(order_id_p1), 9);
    assert!(book.proceeds_contains_for_testing(order_id_p2), 10);

    // --- Call 2: max_items = 4 -- drains the last bid (A), consuming 1 of
    // the 4, then carries the leftover 3 straight into the ask side and
    // drains all of D, E, F exactly. This is the call that actually proves
    // `remaining` threads correctly from `drain_side(bids)` into
    // `drain_side(asks)` within one call.
    cap.clob_admin_drain_step(&mut book, 4, scenario.ctx());

    assert!(book.bids_size_for_testing() == 0, 11);
    let cancelled_2 = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_2.length() == 6, 12);
    let (_, _, ev_id_2, ev_trader_2) = cancelled_2[2].order_cancelled_fields_for_testing();
    let (_, _, ev_id_3, ev_trader_3) = cancelled_2[3].order_cancelled_fields_for_testing();
    let (_, _, ev_id_4, ev_trader_4) = cancelled_2[4].order_cancelled_fields_for_testing();
    let (_, _, ev_id_5, ev_trader_5) = cancelled_2[5].order_cancelled_fields_for_testing();
    assert!(ev_id_2 == order_id_a && ev_trader_2 == maker_a(), 13);
    assert!(ev_id_3 == order_id_d && ev_trader_3 == admin(), 14);
    assert!(ev_id_4 == order_id_e && ev_trader_4 == other(), 15);
    assert!(ev_id_5 == order_id_f && ev_trader_5 == taker(), 16);
    assert!(event::events_by_type<tiny_clob::ProceedsClaimed>().length() == 0, 17);
    assert!(book.proceeds_contains_for_testing(order_id_p1), 18);
    assert!(book.proceeds_contains_for_testing(order_id_p2), 19);

    // --- Call 3: max_items = 2 -- bids/asks are both empty (no-op, doesn't
    // touch `remaining`), so both units go to `drain_proceeds`, draining P1
    // then P2 (FIFO).
    cap.clob_admin_drain_step(&mut book, 2, scenario.ctx());

    // No new OrderCancelled events -- nothing left to cancel.
    assert!(event::events_by_type<tiny_clob::OrderCancelled>().length() == 6, 20);
    let claimed = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed.length() == 2, 21);
    let (_, _, ev_claimant_0, ev_base_0, ev_quote_0) = claimed[0].proceeds_claimed_fields_for_testing();
    let (_, _, ev_claimant_1, ev_base_1, ev_quote_1) = claimed[1].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant_0 == maker_a() && ev_base_0 == size && ev_quote_0 == 0, 22);
    assert!(ev_claimant_1 == maker_b() && ev_base_1 == size && ev_quote_1 == 0, 23);
    assert!(!book.proceeds_contains_for_testing(order_id_p1), 24);
    assert!(!book.proceeds_contains_for_testing(order_id_p2), 25);

    // The book is now fully drained -- `clob_admin_finalize` succeeding
    // (rather than aborting with `ENotFullyDrained`) is itself the
    // definitive proof, including for the ask side, which has no direct
    // `_for_testing` size accessor of its own.
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();
    assert!(deleted_id == book_id, 26);

    scenario.end();
}

// === Scale: a drain approaching real transaction-sized event counts ===

// Every other `clob_admin_drain_step` test in this file (and the multi-call
// boundary test above) uses a handful of orders. `clob_admin_drain_step`'s
// own doc comment calls out Sui's hard 1024-event-per-transaction cap and
// warns that an admin's chosen `max_items` should stay "comfortably under
// that limit (e.g. a few hundred)" given up to 2 events per drained order.
// Nothing exercises a drain anywhere near real scale. This seeds 60 resting
// bids (spread across 3 distinct price levels, 20 orders each, via
// `insert_resting_order_for_testing` in a loop -- far faster than 60 real
// `place_limit_order_bid` calls, and this file already uses the same
// test-only seeding path above) and drains them all in one
// `clob_admin_drain_step` call, confirming the exact count of emitted
// `OrderCancelled` events and that the drain completes cleanly at this
// scale (60 orders x up to 2 events each = up to 120 events, well under the
// 1024 cap, and no test-framework limit was hit at this size).
#[test]
fun clob_admin_drain_step_handles_dozens_of_orders_in_a_single_call() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let price = default_price();
    let size = min_size();
    let order_count: u64 = 60;
    let num_price_levels: u64 = 3;

    scenario.next_tx(maker_a());
    let mut i: u64 = 0;
    while (i < order_count) {
        let order_id = book.next_order_id();
        let order_price = price + (i % num_price_levels);
        let escrow = balance::create_for_testing<USDC>(book.bid_escrow_amount(order_price, size));
        let order =
            order::new<BTC, USDC>(order_id, maker_a(), size, option::none(), option::some(escrow), 0);
        book.insert_resting_order_for_testing(true, order_price, order, scenario.ctx());
        i = i + 1;
    };

    assert!(book.bids_size_for_testing() == num_price_levels, 0);

    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, order_count + 10, scenario.ctx());

    let cancelled = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled.length() == order_count, 1);
    assert!(book.bids_size_for_testing() == 0, 2);

    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    let _ = deleted_id;
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();

    scenario.end();
}

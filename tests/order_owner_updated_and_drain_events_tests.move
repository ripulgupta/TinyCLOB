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
    Self, admin, other, taker, maker_a, maker_b, maker_c, min_size, max_min_size,
    default_price, default_size, shortfall_price, new_book, destroy_book_and_cap,
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks,
};


// === Change 4: `OrderOwnerUpdated` event ===

#[test]
fun update_resting_order_reassign_emits_order_owner_updated_with_correct_fields() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    let book_id = book.id_for_testing();

    let found = book.update_resting_order(&bid_ticket, other());
    assert!(found, 0);

    let events = event::events_by_type<tiny_clob::OrderOwnerUpdated>();
    assert!(events.length() == 1, 1);
    let (ev_order_id, ev_book_id, ev_old_owner, ev_new_owner) =
        events[0].order_owner_updated_fields_for_testing();
    assert!(ev_order_id == order_id, 2);
    assert!(ev_book_id == book_id, 3);
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

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Reassigning to the SAME owner (admin(), unchanged) must still fire the
    // event -- the write is unconditional on the found branch, regardless
    // of whether the address actually changes.
    let found = book.update_resting_order(&bid_ticket, admin());
    assert!(found, 0);

    let events = event::events_by_type<tiny_clob::OrderOwnerUpdated>();
    assert!(events.length() == 1, 1);
    let (ev_order_id, _, ev_old_owner, ev_new_owner) =
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
    let book_id = book.id_for_testing();
    let empty_book_ticket =
        tiny_clob::new_ticket_for_testing(0, book_id, tiny_clob::bid_for_testing(), default_price());
    let found_empty = book.update_resting_order(&empty_book_ticket, other());
    assert!(!found_empty, 0);
    unit_test::destroy(empty_book_ticket);

    // Level-exists-but-wrong-order-id path.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let (order_id, _, side, price) = bid_ticket.ticket_fields_for_testing();
    let wrong_id_ticket = tiny_clob::new_ticket_for_testing(order_id + 1, book_id, side, price);
    let found_wrong_id = book.update_resting_order(&wrong_id_ticket, other());
    assert!(!found_wrong_id, 1);
    unit_test::destroy(wrong_id_ticket);

    assert!(event::events_by_type<tiny_clob::OrderOwnerUpdated>().length() == 0, 2);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_emits_event_and_syncs_pooled_proceeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    let found = book.update_resting_order(&bid_ticket, other());
    assert!(found, 0);
    let events = event::events_by_type<tiny_clob::OrderOwnerUpdated>();
    assert!(events.length() == 1, 1);
    let (_, _, ev_old_owner, ev_new_owner) = events[0].order_owner_updated_fields_for_testing();
    assert!(ev_old_owner == admin(), 2);
    assert!(ev_new_owner == other(), 3);
    unit_test::destroy(bid_ticket);

    // Cross the reassigned resting bid; proceeds must land on the new owner
    // (pooled-proceeds owner sync still works alongside the new event).
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 4);
    let (ev_claimant, _, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == other(), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

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
    let (ev_claimant, _, ev_base, ev_quote) = claimed_events[0].proceeds_claimed_fields_for_testing();
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
    let (mut book, cap) = new_book(&mut scenario);

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
    let (ev_id_a, _, ev_trader_a) = events[0].order_cancelled_fields_for_testing();
    let (ev_id_b, _, ev_trader_b) = events[1].order_cancelled_fields_for_testing();
    let (ev_id_c, _, ev_trader_c) = events[2].order_cancelled_fields_for_testing();
    let (ev_id_d, _, ev_trader_d) = events[3].order_cancelled_fields_for_testing();
    assert!(ev_id_a == id_a && ev_trader_a == maker_a(), 1);
    assert!(ev_id_b == id_b && ev_trader_b == maker_b(), 2);
    assert!(ev_id_c == id_c && ev_trader_c == maker_c(), 3);
    assert!(ev_id_d == id_d && ev_trader_d == other(), 4);

    unit_test::destroy(ticket_a);
    unit_test::destroy(ticket_b);
    unit_test::destroy(ticket_c);
    unit_test::destroy(ticket_d);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

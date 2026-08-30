#[test_only]
module tiny_clob::cancellation_and_proceeds_tests;

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


#[test]
fun cancel_order_refunds_escrow_and_emits_ordercancelled() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.id_for_testing();

    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let (t_order_id, _, _, _) = ticket.ticket_fields_for_testing();

    let (refund_base, refund_quote) = book.cancel_order(ticket, scenario.ctx());
    assert!(refund_base.burn_for_testing() == 0, 0);
    assert!(refund_quote.burn_for_testing() == escrow_amount, 1);

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 2);
    let (ev_order_id, ev_book_id, ev_trader) = cancelled_events[0].order_cancelled_fields_for_testing();
    assert!(ev_order_id == t_order_id, 3);
    assert!(ev_book_id == book_id, 4);
    assert!(ev_trader == admin(), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_order_sweeps_combined_escrow_and_proceeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // admin() rests a bid for 200; a partial market ask of 100 fills half,
    // crediting admin()'s order_id with base proceeds while the other half
    // stays resting with its own still-locked quote escrow. cancel_order
    // must return both legs combined in one call.
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let (order_id, _, _, _) = bid_ticket.ticket_fields_for_testing();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    // Both legs exist before cancelling: proceeds credited for the filled
    // half, and the order still resting (with locked escrow) for the
    // unfilled half.
    assert!(book.proceeds_contains_for_testing(order_id), 0);
    assert!(book.bids_size_for_testing() == 1, 1);

    scenario.next_tx(admin());
    let (refund_base, refund_quote) = book.cancel_order(bid_ticket, scenario.ctx());

    // Combined: base proceeds from the matched half (net of zero fees)
    // plus quote escrow still locked for the unfilled half.
    let expected_base = fill_size;
    let expected_quote = book.bid_escrow_amount(default_price(), size - fill_size);
    assert!(refund_base.burn_for_testing() == expected_base, 2);
    assert!(refund_quote.burn_for_testing() == expected_quote, 3);

    // ProceedsClaimed reports ONLY the swept proceeds leg (the matched
    // base), not the combined escrow+proceeds amount actually returned by
    // cancel_order. The remaining quote escrow for the unfilled half is
    // principal, not proceeds, so it must not appear in the event.
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 4);
    let (ev_claimant, _, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 5);
    assert!(ev_base == expected_base, 6);
    assert!(ev_quote == 0, 7);

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 8);

    assert!(!book.proceeds_contains_for_testing(order_id), 9);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_order_with_zero_proceeds_does_not_emit_proceeds_claimed() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // admin() rests a bid that never fills at all: pure escrow, zero
    // proceeds. cancel_order must still return the full escrow, but since
    // no proceeds were ever swept, ProceedsClaimed must not fire — firing
    // it here would falsely report escrow principal as trading proceeds.
    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    let (refund_base, refund_quote) = book.cancel_order(ticket, scenario.ctx());
    assert!(refund_base.burn_for_testing() == 0, 0);
    assert!(refund_quote.burn_for_testing() == escrow_amount, 1);

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 0, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// `event_id` is write-once, fixed at construction time via
// `new_with_event_id_override`, with no setter that could change it
// afterward. The override affects ONLY what gets stamped on emitted
// events — it has zero bearing on ticket/cancellation identity, which
// always follows the book's own immutable object id (`id: UID`),
// regardless of any override. This test confirms the override mechanism
// stamps events correctly and stays stable across placement/fill/cancel,
// while ticket authentication (`order_book_id`) tracks the book's own id,
// not the override.

#[test]
fun new_event_id_override_is_used_and_stable_across_placement_and_cancel() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let override_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new_with_event_id_override<BTC, USDC>(
        min_size(), 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx(),
    );

    // The override, not the book's own internal id, is what got stamped
    // on events.
    let book_own_id = book.id_for_testing();
    assert!(book.event_id_for_testing() == override_id, 0);
    assert!(override_id != book_own_id, 1);

    // Place a resting bid — the ticket must carry the book's own id, NOT
    // the event_id override. Ticket identity is unforgeable and
    // independent of whatever event_id_override was supplied at
    // construction.
    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let (_, t_book_id, _, _) = ticket.ticket_fields_for_testing();
    assert!(t_book_id == book_own_id, 2);

    // No function exists that could change event_id after the fact — it is
    // still the override id right before cancellation, and cancel_order
    // (which checks ticket.order_book_id == object::uid_to_inner(&book.id))
    // succeeds because the ticket carries the book's own id, which is also
    // never mutable after construction.
    assert!(book.event_id_for_testing() == override_id, 3);
    let (refund_base, refund_quote) = book.cancel_order(ticket, scenario.ctx());
    assert!(refund_base.burn_for_testing() == 0, 4);
    assert!(refund_quote.burn_for_testing() == escrow_amount, 5);

    wrapper_uid.delete();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_event_id_defaults_to_self_id_when_override_is_none() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);

    let book_own_id = book.id_for_testing();
    assert!(book.event_id_for_testing() == book_own_id, 0);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_pays_out_and_emits_proceedsclaimed() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.id_for_testing();

    // admin() rests a bid; other() crosses it fully as a market ask, crediting
    // admin()'s order_id proceeds table entry with quote. Keep the ticket
    // alive: it is now required to claim. The bid is fully filled and
    // removed from the book, so claim_proceeds auto-destroys the ticket and
    // hands back option::none().
    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    scenario.next_tx(other());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    scenario.next_tx(admin());
    let (claim_base, claim_quote, returned_ticket_opt) =
        book.claim_proceeds(bid_ticket, scenario.ctx());
    claim_base.burn_for_testing();
    claim_quote.burn_for_testing();

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_claimant, ev_book_id, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_base == default_size(), 3);
    assert!(ev_quote == 0, 4);

    // The order was fully filled and removed from the book, so nothing
    // more can ever be claimed through this ticket — claim_proceeds already
    // destroyed it and returned option::none().
    assert!(returned_ticket_opt.is_none(), 5);
    returned_ticket_opt.destroy_none();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun push_proceeds_matches_claim_proceeds_and_pays_recorded_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.id_for_testing();

    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    // push_proceeds takes the book's ClobAdminCap plus the order_id: called
    // here from other()'s transaction context (the cap authorizes the call
    // regardless of tx sender) — the payout still lands on admin(), the
    // address recorded as owner against this order_id at credit time, never
    // on the caller or the cap holder.
    scenario.next_tx(other());
    cap.push_proceeds(&mut book, order_id, scenario.ctx());

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_claimant, ev_book_id, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_base == default_size(), 3);
    assert!(ev_quote == 0, 4);
    // No live proceeds entry survives the push, matching claim_proceeds's
    // own claim-then-remove behavior.
    assert!(!book.proceeds_contains_for_testing(order_id), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_found_reassigns_owner_and_credits_new_owner_on_push() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // admin() rests a bid; its resting order's owner is reassigned to other()
    // via update_resting_order (authorized by ticket possession)
    // before it is ever crossed.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    let found = book.update_resting_order(&bid_ticket, other());
    assert!(found, 0);
    unit_test::destroy(bid_ticket);

    // Cross the reassigned resting bid with a market ask from a third party.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    // The proceeds ledger entry is now keyed by order_id, not address, so
    // its existence alone doesn't prove which address it pays out to.
    // push_proceeds pays whatever address was recorded as `owner` at credit
    // time (which is the order's live `owner` field at match time, i.e.
    // other() after reassignment) — proving the owner field was actually
    // overwritten, not just the ticket's own bookkeeping. Called here with
    // taker() as the tx sender (authorized via the book's cap, not the
    // sender) — the payout still lands on other().
    assert!(book.proceeds_contains_for_testing(order_id), 1);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == other(), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassignment_straddled_by_fills_credits_new_owner_only() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // admin() rests a bid big enough to be filled in two separate chunks: one
    // fill BEFORE the owner reassignment (creating the proceeds ledger
    // entry under admin()) and one fill AFTER (crediting the same order_id
    // again, this time while the live owner is other()). Bug 1 was that
    // credit_maker_table only stamped `owner` on the entry's first
    // creation, so the second credit kept attributing proceeds to admin()
    // even though ownership had moved to other() in between.
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // First fill, still owned by admin(): creates the ledger entry with
    // owner = admin().
    scenario.next_tx(taker());
    let ask_payment_1 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_1, matched_quote_1, _) = book.place_market_order_ask(ask_payment_1, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_1.burn_for_testing();
    matched_quote_1.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // Reassign ownership to other() while the order is still resting for the
    // remaining unfilled half.
    let found = book.update_resting_order(&bid_ticket, other());
    assert!(found, 1);
    unit_test::destroy(bid_ticket);

    // Second fill, now owned by other(): credits the SAME order_id's
    // existing ledger entry again.
    scenario.next_tx(taker());
    let ask_payment_2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = book.place_market_order_ask(ask_payment_2, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_2.burn_for_testing();
    matched_quote_2.burn_for_testing();

    // push_proceeds must pay out to other() — the order's CURRENT owner as
    // of the most recent credit — not admin(), the address that created the
    // ledger entry on the first fill. The pooled amount covers both fills.
    scenario.next_tx(taker());
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == other(), 3);
    assert!(ev_base == fill_size + fill_size, 4);
    assert!(ev_quote == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_not_found_is_a_noop() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // No resting order exists at all yet: neither the price level nor the
    // order_id exist. Must return false and touch nothing. Synthesize a
    // ticket for a non-existent order since the real not-found path has no
    // genuine ticket to offer.
    let book_id = book.id_for_testing();
    let empty_book_ticket =
        tiny_clob::new_ticket_for_testing(0, book_id, tiny_clob::bid_for_testing(), default_price());
    let found_empty_book =
        book.update_resting_order(&empty_book_ticket, other());
    assert!(!found_empty_book, 0);
    unit_test::destroy(empty_book_ticket);

    // Rest a real bid, then probe with a wrong order_id at the same,
    // now-existing price level — the level exists but the specific order
    // does not.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let (order_id, _, side, price) = bid_ticket.ticket_fields_for_testing();
    let wrong_order_id = order_id + 1;
    let wrong_id_ticket = tiny_clob::new_ticket_for_testing(wrong_order_id, book_id, side, price);
    let found_wrong_id = book.update_resting_order(&wrong_id_ticket, other());
    assert!(!found_wrong_id, 1);
    unit_test::destroy(wrong_id_ticket);

    // The real order's owner is untouched (still admin()): crossing it still
    // credits proceeds recorded against admin(), not other().
    unit_test::destroy(bid_ticket);
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 2);

    // push_proceeds (called here with taker() as tx sender, authorized via the
    // book's cap) pays whoever is recorded as owner for this order_id —
    // still admin(), proving the failed reassignment attempts above never
    // touched the real order.
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 3);
    let (ev_claimant, _, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun push_proceeds_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book1, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book1.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    cap2.push_proceeds(&mut book1, order_id, scenario.ctx());

    sui::test_utils::destroy(book1);
    sui::test_utils::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun update_resting_order_rejects_ticket_from_wrong_book() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let (mut other_book, other_cap) = new_book(&mut scenario);

    // Rest a bid on the *other* book and try to use its ticket against
    // `book` — the ticket's order_book_id won't match `book`'s own id.
    let other_ticket = rest_bid(&mut other_book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    book.update_resting_order(&other_ticket, other());

    unit_test::destroy(other_ticket);
    destroy_book_and_cap(book, cap);
    destroy_book_and_cap(other_book, other_cap);
    scenario.end();
}

// Regression tests for the event_id/order_book_id confusion vulnerability.
// Historically, `OrderTicket.order_book_id` was set to `book.event_id` at
// minting time and checked against `book.event_id` in `cancel_order` /
// `update_resting_order`. Since `event_id` used to be settable at
// construction to any caller-supplied `ID` with zero validation, an
// attacker could construct a forged book B whose `event_id` collided with
// a victim book A's own object id, rest a throwaway order on B to mint a
// legitimate ticket, and then use that ticket against the victim's real
// book to steal escrow via `cancel_order` or hijack proceeds via
// `update_resting_order`.
//
// This was already fixed once at the value-authentication level: ticket
// authentication is anchored to the book's own immutable object id
// (`object::uid_to_inner(&book.id)`), never to `event_id` or its override,
// so these tests' security property — a ticket minted on book B can never
// authenticate against book A — holds regardless of what `event_id` book B
// carries. It has since been fixed a second time at the type level: the
// override is only reachable via `new_with_event_id_override`, which takes
// a borrowed `&UID` rather than a bare `ID`. There is no way to obtain a
// `&UID` reference to another book's private internal `id` field from
// outside this module (no accessor exposes one, and none should be added —
// that would defeat the point of the fix), so the original "collide with
// the victim's id via event_id_override" attack this test was written
// against can no longer even be expressed as compiling code. This is a
// compile-time guarantee, not something a runtime test can exercise (a
// test file that doesn't compile can't be part of the same test suite) —
// similar in spirit to `order.move`'s own compile-time-enforced
// guarantees. These tests are simplified accordingly to construct book B
// normally (no override), since the ticket-authentication property they
// actually check never depended on the override in the first place.
#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun forged_event_id_ticket_cannot_cancel_victim_order() {
    let mut scenario = ts::begin(admin());
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (mut book_b, cap_b) = new_book(&mut scenario);

    let ticket_b = rest_bid(&mut book_b, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    // Must abort with EWrongBook: ticket_b's order_book_id is book_b's own
    // id, not book_a's.
    let (refund_base, refund_quote) = book_a.cancel_order(ticket_b, scenario.ctx());
    refund_base.burn_for_testing();
    refund_quote.burn_for_testing();

    destroy_book_and_cap(book_a, cap_a);
    destroy_book_and_cap(book_b, cap_b);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun forged_event_id_ticket_cannot_hijack_victim_order_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (mut book_b, cap_b) = new_book(&mut scenario);

    // Same setup as the cancel_order regression test above, but exercising
    // update_resting_order instead, which takes the ticket by reference
    // rather than consuming it.
    let ticket_b = rest_bid(&mut book_b, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    // Must abort with EWrongBook: ticket_b's order_book_id is book_b's own
    // id, not book_a's.
    book_a.update_resting_order(&ticket_b, other());

    unit_test::destroy(ticket_b);
    destroy_book_and_cap(book_a, cap_a);
    destroy_book_and_cap(book_b, cap_b);
    scenario.end();
}

// `OrderTicket` has `store` but not `key` (see its struct doc comment in
// `sources/tiny_clob.move`) — a compile-time guarantee, not something a
// runtime `#[test]` can exercise: it makes `transfer::share_object` on an
// `OrderTicket` a compile error unconditionally. The package compiling at
// all with `OrderTicket` held only by value is itself the confirming
// evidence.

#[test]
fun destroy_orphaned_ticket_disposes_with_no_abort() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);

    let order_id = 7;
    let order_book_id = book.id_for_testing();
    let side = true;
    let price = 50_000;
    let ticket = tiny_clob::new_ticket_for_testing(order_id, order_book_id, side, price);

    let (t_order_id, t_book_id, t_side, t_price) = ticket.ticket_fields_for_testing();
    assert!(t_order_id == order_id, 0);
    assert!(t_book_id == order_book_id, 1);
    assert!(t_side == side, 2);
    assert!(t_price == price, 3);

    // Happy path: `book.proceeds` has no entry for this `order_id`, so the
    // guarded public `destroy_orphaned_ticket` disposes it with no abort and
    // no leaked value.
    book.destroy_orphaned_ticket(ticket);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 2: guarded `destroy_orphaned_ticket` liveness check ===

#[test]
#[expected_failure(abort_code = 19, location = tiny_clob)] // tiny_clob::EProceedsNotEmpty
fun destroy_orphaned_ticket_with_nonzero_proceeds_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid big enough to be partially filled, leaving it still resting
    // afterward, and credits book.proceeds[order_id] with the matched Base
    // leg.
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // Bypass claim_proceeds entirely and call the guarded public disposal
    // function directly on a ticket whose order_id still has pooled
    // proceeds — must abort rather than strand those funds.
    book.destroy_orphaned_ticket(bid_ticket);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun destroy_orphaned_ticket_wrong_book_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (book_b, cap_b) = new_book(&mut scenario);

    // Mint a ticket on book A but pass it against book B — must abort with
    // EWrongBook, and must do so BEFORE the proceeds-emptiness check (book B
    // has no entry for this order_id either, so a proceeds-check-first
    // implementation would incorrectly pass through here).
    let ticket_a = rest_bid(&mut book_a, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    book_b.destroy_orphaned_ticket(ticket_a);

    destroy_book_and_cap(book_a, cap_a);
    destroy_book_and_cap(book_b, cap_b);
    scenario.end();
}

// A resting bid of size 1 at a price where `bid_escrow_amount`/fill quote
// cost is 1, with even the minimum nonzero maker_fee_bps (1), has its
// entire matched Base leg consumed by the fee ceiling (`fee_amount(1, 1)
// == 1`) -- so the fill credits (0 base, 0 quote) to the maker via the
// real production placement/matching path, not a synthetic order. Before
// the fix to `credit_maker_table`, this would have created a pooled
// zero-valued `MakerBalance` entry that blocked `destroy_orphaned_ticket`
// despite protecting no real funds; now no entry is created at all, and
// disposal succeeds immediately once the (now fully-drained) order is
// gone.
#[test]
fun destroy_orphaned_ticket_after_all_zero_credited_fill_disposes_cleanly() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    cap.clob_admin_set_maker_fee(&mut book, 1);

    scenario.next_tx(maker_a());
    let bid_ticket = rest_bid(&mut book, shortfall_price(), 1, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, 1, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    assert!(!book.proceeds_contains_for_testing(order_id), 0);
    book.destroy_orphaned_ticket(bid_ticket); // must NOT abort

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === `destroy_ticket_unconditionally` ===

// The headline new capability: unlike `destroy_orphaned_ticket`, this
// succeeds even while the order still has real escrow AND real pooled
// proceeds attached -- and neither is stranded, because the admin can
// still reach both without the ticket afterward.
#[test]
fun destroy_ticket_unconditionally_disposes_with_real_escrow_and_proceeds_still_attached() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let size = 300;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    let side = bid_ticket.ticket_side();
    let price = bid_ticket.ticket_price();

    // Partially fill it so book.proceeds[order_id] holds a real, nonzero
    // pooled Base credit, while the order keeps resting with real Quote
    // escrow still locked for the unfilled remainder.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // Snapshot the still-resting remainder's real, nonzero live escrow
    // before the ticket that could otherwise self-serve it is gone.
    let escrow_before = book.resting_order_escrow(side, price, order_id);
    let (expected_refund, _) = escrow_before.borrow().resting_order_escrow_fields();
    assert!(expected_refund > 0, 5);
    unit_test::destroy(escrow_before);

    // Would have aborted EProceedsNotEmpty via destroy_orphaned_ticket;
    // this succeeds instead, with no book reference at all.
    bid_ticket.destroy_ticket_unconditionally();

    // Neither leg is stranded: the admin can still force-cancel the
    // still-resting remainder's escrow, and still push out the pooled
    // proceeds, using only (side, price, order_id) -- no ticket needed.
    scenario.next_tx(admin());
    cap.clob_admin_cancel_order(&mut book, side, price, order_id, scenario.ctx());
    cap.push_proceeds(&mut book, order_id, scenario.ctx());

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 1);
    let claimed_events = event::events_by_type<ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, ev_base, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 3); // rest_bid's caller here (no next_tx before it)
    assert!(ev_base == fill_size, 4);

    // Confirm the escrow refund itself actually reached the owner, in the
    // exact amount snapshotted above, not just that a cancellation event
    // fired.
    scenario.next_tx(admin());
    let refunded_quote = scenario.take_from_address<coin::Coin<USDC>>(admin());
    assert!(refunded_quote.value() == expected_refund, 6);
    refunded_quote.burn_for_testing();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// The actual motivating scenario: a ticket that survives all the way past
// `clob_admin_finalize`, when the book it referenced no longer exists at
// all. No other disposal function can ever be called on it again -- this
// one takes no book reference, so it doesn't need to.
#[test]
fun destroy_ticket_unconditionally_disposes_ticket_after_book_finalized() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    // Retire + drain refunds the resting order's escrow to its owner
    // (independent of the ticket), leaving the book empty and finalizable.
    // The ticket itself is never touched by any of this.
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    let _deleted_id = cap.clob_admin_finalize(book);
    // `book`/`cap` no longer exist -- there is no way to construct a
    // `destroy_orphaned_ticket`/`cancel_order`/`claim_proceeds` call for
    // `bid_ticket` ever again. This is the only remaining disposal path.
    bid_ticket.destroy_ticket_unconditionally();

    scenario.end();
}

#[test]
fun destroy_orphaned_ticket_zero_proceeds_on_own_book_disposes_cleanly() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // A resting bid that has never been filled has no book.proceeds entry
    // yet — the guarded public destroy must dispose of it with no abort,
    // exercising the happy path through the real placement pipeline (rather
    // than a synthetic ticket unconnected to any order, as in
    // destroy_orphaned_ticket_disposes_with_no_abort above).
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    assert!(!book.proceeds_contains_for_testing(order_id), 0);
    book.destroy_orphaned_ticket(bid_ticket);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_auto_destroys_ticket_when_order_fully_filled() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Fully filling a resting bid removes it from the book. claim_proceeds
    // must auto-destroy the ticket and return option::none() — nothing more
    // can ever be claimed through it.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    scenario.next_tx(admin());
    let (claim_base, claim_quote, returned_ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == default_size(), 1);
    claim_quote.burn_for_testing();
    // Proceeds entry gone, and the order is no longer resting, so
    // claim_proceeds already destroyed the ticket for us.
    assert!(!book.proceeds_contains_for_testing(order_id), 2);
    assert!(returned_ticket_opt.is_none(), 3);
    returned_ticket_opt.destroy_none();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_still_resting_returns_claimable_ticket_for_reuse() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // A partial fill leaves the order still resting. claim_proceeds returns
    // the ticket via option::some, which must remain valid and reusable for
    // a further claim after a second fill.
    let size = 300;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    scenario.next_tx(admin());
    let (claim_base, claim_quote, returned_ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    claim_base.burn_for_testing();
    claim_quote.burn_for_testing();
    assert!(!book.proceeds_contains_for_testing(order_id), 0);
    assert!(returned_ticket_opt.is_some(), 4);
    let returned_ticket = returned_ticket_opt.destroy_some();

    // Second fill against the still-resting remainder, then claim again
    // using the SAME ticket returned above — confirms it remains usable
    // across multiple claims.
    scenario.next_tx(taker());
    let ask_payment2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment2, matched_quote2, _) = book.place_market_order_ask(ask_payment2, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment2.burn_for_testing();
    matched_quote2.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 1);

    scenario.next_tx(admin());
    let (claim_base2, claim_quote2, returned_ticket_opt2) =
        book.claim_proceeds(returned_ticket, scenario.ctx());
    assert!(claim_base2.burn_for_testing() == fill_size, 2);
    claim_quote2.burn_for_testing();
    assert!(!book.proceeds_contains_for_testing(order_id), 3);

    // size (300) minus two fills of 100 leaves 100 still resting, so the
    // ticket remains live.
    assert!(returned_ticket_opt2.is_some(), 5);
    let returned_ticket2 = returned_ticket_opt2.destroy_some();
    book.destroy_orphaned_ticket(returned_ticket2); // must NOT abort

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 3: `update_resting_order` syncs pooled proceeds owner ===

#[test]
fun update_resting_order_reassign_then_no_fill_syncs_proceeds_owner_on_push() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid big enough to be partially filled, leaving it still
    // resting, and creating a pooled proceeds entry under admin().
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // Reassign ownership to other(). No further fill ever happens for this
    // order — the only way the already-pooled proceeds balance can ever be
    // told about the new owner is an immediate sync inside
    // update_resting_order itself.
    let found = book.update_resting_order(&bid_ticket, other());
    assert!(found, 1);
    unit_test::destroy(bid_ticket);

    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == other(), 3);
    assert!(ev_base == fill_size, 4);
    assert!(ev_quote == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_then_no_fill_syncs_proceeds_owner_on_drain() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    let found = book.update_resting_order(&bid_ticket, other());
    assert!(found, 0);
    unit_test::destroy(bid_ticket);

    // Retire and force-drain: this exercises BOTH the remaining resting
    // order's escrow (drain_side, already correctly paid to the live
    // order.owner today) and the pooled proceeds entry (drain_proceeds,
    // paid to whatever address is stamped as the MakerBalance's owner) in
    // the same call, so the two payout addresses can be compared directly.
    cap.clob_admin_retire(&mut book);
    let remaining_size = size - fill_size;
    let expected_escrow_refund = book.bid_escrow_amount(default_price(), remaining_size);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    scenario.next_tx(other());
    let escrow_refund = scenario.take_from_address<coin::Coin<USDC>>(other());
    assert!(escrow_refund.value() == expected_escrow_refund, 1);
    escrow_refund.burn_for_testing();

    let proceeds_payout = scenario.take_from_address<coin::Coin<BTC>>(other());
    assert!(proceeds_payout.value() == fill_size, 2);
    proceeds_payout.burn_for_testing();

    // admin() (the original owner) received nothing — both legs went to other().
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(admin()), 3);
    assert!(!ts::has_most_recent_for_address<coin::Coin<USDC>>(admin()), 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_with_no_pooled_proceeds_yet_then_fill_credits_new_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid and reassign it before any fill ever happens: book.proceeds
    // has no entry for this order_id yet, so `sync_maker_balance_owner`'s
    // `contains` guard must be a no-op here, not an abort.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    assert!(!book.proceeds_contains_for_testing(order_id), 0);

    let found = book.update_resting_order(&bid_ticket, other());
    assert!(found, 1);
    unit_test::destroy(bid_ticket);

    // A later fill must still correctly credit the new owner via the
    // ordinary credit_maker_table path.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == other(), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Merge item 2: this test used to have a weaker sibling,
// `update_resting_order_reassigned_twice_final_payout_goes_to_latest_owner_
// only`, covering the same A -> B -> C reassignment-straddled-by-fills
// scenario but asserting only the `ProceedsClaimed` event's fields. That
// sibling is folded in here rather than kept separate: this test already
// covers the same scenario via stronger, Coin-transfer-based assertions
// (including the negative checks that neither intermediate owner A nor B
// ever receives a payout Coin object at all), and now also carries the
// event-field-shape assertions the deleted sibling contributed, so no
// coverage is lost.
#[test]
fun update_resting_order_reassign_chain_pays_only_final_owner_with_no_leakage() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // A (admin()) -> B (other()) -> C (maker_a()), pooling proceeds at each stage.
    let size = 400;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment_1 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_1, matched_quote_1, _) = book.place_market_order_ask(ask_payment_1, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_1.burn_for_testing();
    matched_quote_1.burn_for_testing(); // pooled under admin() (A)

    scenario.next_tx(admin());
    assert!(book.update_resting_order(&bid_ticket, other()), 0); // A -> B

    scenario.next_tx(taker());
    let ask_payment_2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = book.place_market_order_ask(ask_payment_2, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_2.burn_for_testing();
    matched_quote_2.burn_for_testing(); // pooled under other() (B)

    scenario.next_tx(admin());
    assert!(book.update_resting_order(&bid_ticket, maker_a()), 1); // B -> C
    unit_test::destroy(bid_ticket);

    cap.push_proceeds(&mut book, order_id, scenario.ctx());

    // Event-field-shape assertions carried over from the merged-away
    // `update_resting_order_reassigned_twice_final_payout_goes_to_latest_
    // owner_only` test.
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == maker_a(), 3);
    assert!(ev_base == fill_size + fill_size, 4);
    assert!(ev_quote == 0, 5);

    scenario.next_tx(maker_a());
    let payout = scenario.take_from_address<coin::Coin<BTC>>(maker_a());
    assert!(payout.value() == fill_size + fill_size, 6); // both fills
    payout.burn_for_testing();
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(admin()), 7);
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(other()), 8);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_does_not_touch_other_orders_proceeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Two resting bids at different prices; the higher one has strict price
    // priority. Fills consume the high order entirely (removing it from the
    // book) plus part of the low order (which stays resting), so both end up
    // with pooled proceeds. Reassigning ONLY the low order must not disturb
    // the high order's proceeds owner — a targeting-correctness check on
    // sync_maker_balance_owner keyed by order_id.
    let price_hi = default_price() + 1_000;
    let ticket_hi = rest_bid(&mut book, price_hi, 200, 1_000_000_000, scenario.ctx());
    let order_id_hi = ticket_hi.ticket_order_id();

    scenario.next_tx(admin());
    let ticket_lo = rest_bid(&mut book, default_price(), 200, 1_000_000_000, scenario.ctx());
    let order_id_lo = ticket_lo.ticket_order_id();
    assert!(order_id_hi != order_id_lo, 0);

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(300, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, 300, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id_hi), 1);
    assert!(book.proceeds_contains_for_testing(order_id_lo), 2);

    scenario.next_tx(admin());
    assert!(book.update_resting_order(&ticket_lo, other()), 3);
    unit_test::destroy(ticket_hi);
    unit_test::destroy(ticket_lo);

    cap.push_proceeds(&mut book, order_id_lo, scenario.ctx());
    cap.push_proceeds(&mut book, order_id_hi, scenario.ctx());

    scenario.next_tx(other());
    let payout_other = scenario.take_from_address<coin::Coin<BTC>>(other());
    assert!(payout_other.value() == 100, 4);
    payout_other.burn_for_testing();
    // hi order's proceeds still belong to admin(), untouched by the lo sync.
    let payout_admin = scenario.take_from_address<coin::Coin<BTC>>(admin());
    assert!(payout_admin.value() == 200, 5);
    payout_admin.burn_for_testing();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_failed_reassign_after_full_fill_does_not_sync_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Unlike update_resting_order_not_found_is_a_noop above (which probes a
    // never-existing order_id / a wrong id at an existing price level), this
    // targets the not-found path where the order genuinely DID exist and was
    // only just removed from the tree by being fully filled, while its
    // proceeds stay pooled. Reassignment must report not-found and must NOT
    // retarget those pooled proceeds.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing(); // fully filled -> no longer resting

    scenario.next_tx(admin());
    assert!(book.proceeds_contains_for_testing(order_id), 0);
    // Order is gone from the tree -> update must report not-found...
    assert!(!book.update_resting_order(&bid_ticket, other()), 1);
    unit_test::destroy(bid_ticket);

    // ...and must NOT have retargeted the pooled proceeds.
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

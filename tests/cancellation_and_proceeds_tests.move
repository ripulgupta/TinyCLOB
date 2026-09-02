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
    Self, admin, other, taker, maker_a, maker_b, maker_c, min_size, default_price, default_size, shortfall_price, new_book, destroy_book_and_cap, rest_bid, rest_ask, shortfall_book, u64_max,
};


#[test]
fun cancel_order_refunds_escrow_and_emits_ordercancelled() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let t_order_id = ticket.ticket_order_id();

    let (refund_base, refund_quote) = book.cancel_order(ticket, scenario.ctx());
    assert!(refund_base.burn_for_testing() == 0, 0);
    assert!(refund_quote.burn_for_testing() == escrow_amount, 1);

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 2);
    let (ev_true_book_id, _ev_enclosing_id, ev_order_id, ev_trader) = cancelled_events[0].order_cancelled_fields_for_testing();
    assert!(ev_order_id == t_order_id, 3);
    assert!(ev_true_book_id == book_id, 4);
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
    let order_id = bid_ticket.ticket_order_id();

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
    let (_, _, ev_claimant, ev_base, ev_quote) =
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

// `fill_level_ask`'s `OrderFilled` emit (maker_side == true: a taker ask
// crossing a resting bid) has no test anywhere asserting its id fields --
// only `fill_level_bid`'s emit (a taker bid crossing a resting ask,
// maker_side == false) is checked, in construction_and_admin_tests.move's
// `every_event_type_stamps_true_book_id_and_foreign_enclosing_object_id_independently`.
// This closes that gap using the same foreign-enclosing-id idiom.
#[test]
fun fill_level_ask_order_filled_stamps_true_book_id_and_foreign_enclosing_id() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    let true_book_id = book.book_id();
    assert!(true_book_id != foreign_id, 0);

    // Rest a bid, then a taker ask crosses it fully -- this is
    // `fill_level_ask`'s path (the maker is the resting bid, maker_side ==
    // true).
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx());
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    let filled_events = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(filled_events.length() == 1, 1);
    let (ev_book_id, ev_enclosing_id, _, _, _, _, _) = filled_events[0].order_filled_fields_for_testing();
    assert!(ev_book_id == true_book_id, 2);
    assert!(ev_enclosing_id == foreign_id, 3);
    let (ev_maker_side, _) = filled_events[0].order_filled_side_and_quote_fields_for_testing();
    assert!(ev_maker_side, 4); // confirms this is fill_level_ask's path, not fill_level_bid's

    wrapper_uid.delete();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// `enclosing_object_id` is write-once, fixed at construction time via
// `new`'s mandatory `enclosing_object_id: &UID` parameter, with no setter
// that could change it afterward. It affects ONLY what gets stamped on
// emitted events — it has zero bearing on ticket/cancellation identity,
// which always follows the book's own immutable object id (`id: UID`),
// regardless of what `enclosing_object_id` was supplied. This test confirms
// a foreign `enclosing_object_id` stamps events correctly and stays stable
// across placement/fill/cancel, while ticket authentication
// (`order_book_id`) tracks the book's own true id, not the caller-supplied
// one.
#[test]
fun new_enclosing_object_id_is_used_and_stable_across_placement_and_cancel() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(
        min_size(), 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx(),
    );

    // The caller-supplied `enclosing_object_id`, not the book's own internal
    // id, is what got stamped on events.
    let book_own_id = book.book_id();
    assert!(book.enclosing_object_id_for_testing() == foreign_id, 0);
    assert!(foreign_id != book_own_id, 1);

    // Place a resting bid — the ticket must carry the book's own id, NOT
    // the foreign `enclosing_object_id`. Ticket identity is unforgeable and
    // independent of whatever `enclosing_object_id` was supplied at
    // construction.
    let escrow_amount = book.bid_escrow_amount(default_price(), default_size());
    let ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let t_book_id = ticket.ticket_order_book_id();
    assert!(t_book_id == book_own_id, 2);

    // No function exists that could change `enclosing_object_id` after the
    // fact — it is still the foreign id right before cancellation, and
    // cancel_order (which checks ticket.order_book_id ==
    // object::uid_to_inner(&book.id)) succeeds because the ticket carries
    // the book's own id, which is also never mutable after construction.
    assert!(book.enclosing_object_id_for_testing() == foreign_id, 3);
    let (refund_base, refund_quote) = book.cancel_order(ticket, scenario.ctx());
    assert!(refund_base.burn_for_testing() == 0, 4);
    assert!(refund_quote.burn_for_testing() == escrow_amount, 5);

    wrapper_uid.delete();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// A former test here (`new_event_id_defaults_to_self_id_when_override_is_none`)
// asserted that the book's stamped event id defaults to its own true id when
// no override is supplied. That "no override" path no longer exists —
// `new`'s `enclosing_object_id` parameter is mandatory now, so there is no
// default-to-self behavior left to test; removed along with the two-
// constructor design it exercised.

#[test]
fun claim_proceeds_pays_out_and_emits_proceedsclaimed() {
    let mut scenario = ts::begin(admin());
    // Constructed with a deliberately foreign `enclosing_object_id` (see the
    // idiom in construction_and_admin_tests.move's
    // `every_event_type_stamps_true_book_id_and_foreign_enclosing_object_id_independently`)
    // so this test can assert BOTH `ProceedsClaimed` id fields on the
    // `claim_proceeds` emit site independently, not just `book_id` alone.
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    let book_id = book.book_id();
    assert!(book_id != foreign_id, 6);

    // admin() rests a bid; other() crosses it fully as a market ask, crediting
    // admin()'s order_id proceeds table entry with quote. Keep the ticket
    // alive: it is now required to claim. The bid is fully filled and
    // removed from the book, so claim_proceeds auto-destroys the ticket and
    // hands back option::none().
    // The bid is fully filled below, so there is no remaining escrow leg to
    // assert against; bid_escrow_amount is not computed here since it would
    // be unused.
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
    let (ev_book_id, ev_enclosing_id, ev_claimant, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_enclosing_id == foreign_id, 7);
    assert!(ev_base == default_size(), 3);
    assert!(ev_quote == 0, 4);

    // The order was fully filled and removed from the book, so nothing
    // more can ever be claimed through this ticket — claim_proceeds already
    // destroyed it and returned option::none().
    assert!(returned_ticket_opt.is_none(), 5);
    returned_ticket_opt.destroy_none();

    wrapper_uid.delete();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun push_proceeds_matches_claim_proceeds_and_pays_recorded_owner() {
    let mut scenario = ts::begin(admin());
    // Constructed with a deliberately foreign `enclosing_object_id` (same
    // idiom as `claim_proceeds_pays_out_and_emits_proceedsclaimed` above) so
    // this test can assert BOTH `ProceedsClaimed` id fields independently on
    // the `push_proceeds` emit site too.
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(min_size(), 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    let book_id = book.book_id();
    assert!(book_id != foreign_id, 6);

    // The bid is fully filled below, so there is no remaining escrow leg to
    // assert against; bid_escrow_amount is not computed here since it would
    // be unused.
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
    // on the caller or the cap holder. The retire call below is a harmless
    // no-op setup step, not a requirement of push_proceeds itself.
    scenario.next_tx(other());
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_book_id, ev_enclosing_id, ev_claimant, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_enclosing_id == foreign_id, 7);
    assert!(ev_base == default_size(), 3);
    assert!(ev_quote == 0, 4);
    // No live proceeds entry survives the push, matching claim_proceeds's
    // own claim-then-remove behavior.
    assert!(!book.proceeds_contains_for_testing(order_id), 5);

    wrapper_uid.delete();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Mirrors `push_proceeds_matches_claim_proceeds_and_pays_recorded_owner`
// above up through creating a genuine, nonzero pooled balance, but never
// calls `clob_admin_retire`. `push_proceeds` is now an unconditional
// admin-gated rescue path, parallel to `clob_admin_cancel_order` -- it must
// succeed on a live, non-retiring book, paying the recorded owner, exactly
// as it would after retirement.
#[test]
fun push_proceeds_on_live_non_retiring_book_with_real_pooled_balance_succeeds() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // `book.retiring` is still false here -- push_proceeds must still
    // succeed and pay out to the recorded owner (admin()), same as it would
    // on a retiring book.
    cap.push_proceeds(&mut book, order_id, scenario.ctx());

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 1);
    let (_ev_book_id, _ev_enclosing_id, ev_claimant, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 2);
    assert!(ev_base == default_size(), 3);
    assert!(ev_quote == 0, 4);
    assert!(!book.proceeds_contains_for_testing(order_id), 5);

    scenario.next_tx(admin());
    let payout = scenario.take_from_address<coin::Coin<BTC>>(admin());
    assert!(payout.value() == default_size(), 6);
    payout.burn_for_testing();

    unit_test::destroy(book);
    unit_test::destroy(cap);
    scenario.end();
}

#[test]
fun update_resting_order_found_reassigns_owner_and_credits_new_owner_on_push() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // admin() rests a bid; its resting order's owner is reassigned to other()
    // via update_resting_order (authorized by ticket possession)
    // before it is ever crossed.
    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    let found = book.update_resting_order(&mut bid_ticket, other());
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
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
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
    let mut bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
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
    let found = book.update_resting_order(&mut bid_ticket, other());
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
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, ev_base, ev_quote) =
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
    let book_id = book.book_id();
    let mut empty_book_ticket =
        tiny_clob::new_ticket_for_testing(0, book_id, tiny_clob::bid(), default_price());
    let found_empty_book =
        book.update_resting_order(&mut empty_book_ticket, other());
    assert!(!found_empty_book, 0);
    unit_test::destroy(empty_book_ticket);

    // Rest a real bid, then probe with a wrong order_id at the same,
    // now-existing price level — the level exists but the specific order
    // does not.
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    let side = bid_ticket.ticket_side();
    let price = bid_ticket.ticket_price();
    let wrong_order_id = order_id + 1;
    let mut wrong_id_ticket = tiny_clob::new_ticket_for_testing(wrong_order_id, book_id, side, price);
    let found_wrong_id = book.update_resting_order(&mut wrong_id_ticket, other());
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
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 3);
    let (_, _, ev_claimant, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
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

    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
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
    let mut other_ticket = rest_bid(&mut other_book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    book.update_resting_order(&mut other_ticket, other());

    unit_test::destroy(other_ticket);
    destroy_book_and_cap(book, cap);
    destroy_book_and_cap(other_book, other_cap);
    scenario.end();
}

// `new_owner == @0x0` must be rejected outright: it would otherwise silently
// arm a burn on every subsequent recorded-address payout path for this
// order (escrow refunds via a later force-cancel/drain, pooled proceeds
// sweeps via `push_proceeds`/`drain_proceeds`).
#[test]
#[expected_failure(abort_code = 33, location = tiny_clob)] // tiny_clob::EInvalidOwner
fun update_resting_order_rejects_zero_address_new_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    book.update_resting_order(&mut bid_ticket, @0x0);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// `update_resting_order`'s ticket fields (`order_id`, `order_book_id`,
// `side`, `price`) are read-only identity/routing data fixed at minting
// time -- the function only ever mutates the resting order's `owner` field
// and the pooled-proceeds ledger, never the ticket itself. Confirms all
// four accessors report identical values before and after a call.
#[test]
fun update_resting_order_does_not_mutate_ticket_fields() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id_before = bid_ticket.ticket_order_id();
    let book_id_before = bid_ticket.ticket_order_book_id();
    let side_before = bid_ticket.ticket_side();
    let price_before = bid_ticket.ticket_price();

    let found = book.update_resting_order(&mut bid_ticket, other());
    assert!(found, 0);

    assert!(bid_ticket.ticket_order_id() == order_id_before, 1);
    assert!(bid_ticket.ticket_order_book_id() == book_id_before, 2);
    assert!(bid_ticket.ticket_side() == side_before, 3);
    assert!(bid_ticket.ticket_price() == price_before, 4);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// `update_resting_order`'s very first assertion is `new_owner != @0x0`
// (`EInvalidOwner`) -- before `assert_book_version`, before the
// `EWrongBook` ticket check, before any tree lookup. A ticket minted on a
// different book, combined with `new_owner == @0x0`, must therefore abort
// `EInvalidOwner`, never reaching `EWrongBook`.
#[test]
#[expected_failure(abort_code = 33, location = tiny_clob)] // tiny_clob::EInvalidOwner
fun update_resting_order_zero_new_owner_aborts_before_wrong_book_check() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let (mut other_book, other_cap) = new_book(&mut scenario);

    let mut other_ticket = rest_bid(&mut other_book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    book.update_resting_order(&mut other_ticket, @0x0);

    unit_test::destroy(other_ticket);
    destroy_book_and_cap(book, cap);
    destroy_book_and_cap(other_book, other_cap);
    scenario.end();
}

// Same first-assertion property as above, but against a ticket for a
// genuinely valid book whose order was never found (never rested at all).
// The zero-address check runs before any tree lookup, so this aborts
// `EInvalidOwner` regardless of resting status -- it must NOT fall through
// to the not-found `false` return.
#[test]
#[expected_failure(abort_code = 33, location = tiny_clob)] // tiny_clob::EInvalidOwner
fun update_resting_order_zero_new_owner_aborts_even_when_order_not_found() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let book_id = book.book_id();
    let mut empty_ticket = tiny_clob::new_ticket_for_testing(0, book_id, tiny_clob::bid(), default_price());

    book.update_resting_order(&mut empty_ticket, @0x0);

    unit_test::destroy(empty_ticket);
    destroy_book_and_cap(book, cap);
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
// (`object::uid_to_inner(&book.id)`), never to `event_id` (now renamed
// `enclosing_object_id`) or its caller-supplied value, so these tests'
// security property — a ticket minted on book B can never authenticate
// against book A — holds regardless of what `enclosing_object_id` book B
// carries. It has since been fixed a second time at the type level: the
// caller-supplied `enclosing_object_id` is only reachable via `new`'s
// mandatory `enclosing_object_id: &UID` parameter, which takes a borrowed
// `&UID` rather than a bare `ID`. There is no way to obtain a `&UID`
// reference to another book's private internal `id` field from outside this
// module (no accessor exposes one, and none should be added — that would
// defeat the point of the fix), so the original "collide with the victim's
// id via a caller-supplied event id" attack this test was written against
// can no longer even be expressed as compiling code. This is a compile-time
// guarantee, not something a runtime test can exercise (a test file that
// doesn't compile can't be part of the same test suite) — similar in spirit
// to `order.move`'s own compile-time-enforced guarantees. These tests are
// simplified accordingly to construct book B normally, since the
// ticket-authentication property they actually check never depended on the
// specific `enclosing_object_id` supplied in the first place.
#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun forged_enclosing_id_ticket_cannot_cancel_victim_order() {
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
fun forged_enclosing_id_ticket_cannot_hijack_victim_order_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (mut book_b, cap_b) = new_book(&mut scenario);

    // Same setup as the cancel_order regression test above, but exercising
    // update_resting_order instead, which takes the ticket by reference
    // rather than consuming it.
    let mut ticket_b = rest_bid(&mut book_b, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    // Must abort with EWrongBook: ticket_b's order_book_id is book_b's own
    // id, not book_a's.
    book_a.update_resting_order(&mut ticket_b, other());

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
    let order_book_id = book.book_id();
    let side = true;
    let price = 50_000;
    let ticket = tiny_clob::new_ticket_for_testing(order_id, order_book_id, side, price);

    let t_order_id = ticket.ticket_order_id();
    let t_book_id = ticket.ticket_order_book_id();
    let t_side = ticket.ticket_side();
    let t_price = ticket.ticket_price();
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

// This fixture satisfies BOTH of `destroy_orphaned_ticket`'s guards at
// once -- the order is still resting (partially filled, not fully drained)
// AND its order_id already has pooled proceeds from the partial fill -- so
// this pins that `EProceedsNotEmpty` is what actually fires, matching
// `destroy_orphaned_ticket`'s own assert ordering (`EWrongBook`, then
// `EProceedsNotEmpty`, then `EOrderStillResting`: the proceeds check
// precedes the resting check).
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

// Isolates `EProceedsNotEmpty` firing ALONE, unlike the sibling test above
// (whose fixture is also still resting). Here the order is fully filled and
// removed from the tree -- genuinely NOT resting -- while its proceeds
// remain pooled and unclaimed, so `EOrderStillResting` could never fire
// even if the guard order were reversed; only `EProceedsNotEmpty` is live.
#[test]
#[expected_failure(abort_code = 19, location = tiny_clob)] // tiny_clob::EProceedsNotEmpty
fun destroy_orphaned_ticket_with_nonzero_proceeds_and_order_concluded_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    let side = bid_ticket.ticket_side();
    let price = bid_ticket.ticket_price();

    // Fully fill it with a market ask: the order is entirely matched and
    // removed from the tree, crediting its order_id's full proceeds.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    // Confirm the fixture actually is "not resting" (removed from the tree)
    // AND "has pooled proceeds" before relying on the abort code below.
    assert!(book.resting_order_escrow(side, price, order_id).is_none(), 0);
    assert!(book.proceeds_contains_for_testing(order_id), 1);

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

// `claim_proceeds`'s own `EWrongBook` guard, mirroring
// `destroy_orphaned_ticket_wrong_book_aborts` above -- a ticket minted by
// book A must be rejected by book B before any proceeds lookup happens.
#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // EWrongBook
fun claim_proceeds_wrong_book_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (mut book_b, cap_b) = new_book(&mut scenario);

    let ticket_a = rest_bid(&mut book_a, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let (base, quote, ticket_opt) = book_b.claim_proceeds(ticket_a, scenario.ctx());
    unit_test::destroy(base);
    unit_test::destroy(quote);
    unit_test::destroy(ticket_opt);

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
    // A genuinely resting bid of ORIGINAL size 1 can no longer be
    // constructed via `place_limit_order_bid`/`rest_bid` at this book's
    // `price_scale` (10): any legitimately-derived nonzero price satisfies
    // `price * size >= price_scale`, and `5 * 1 < 10`. Since this test isn't
    // exercising `place_limit_order_bid`'s price derivation at all -- only
    // `destroy_orphaned_ticket`'s behavior on a since-fully-drained,
    // zero-credit order -- it constructs the exact same size-1 fixture
    // directly via the test-only `insert_resting_order_for_testing` bypass
    // instead (mirroring the same pattern already used for precise fixture
    // construction in `fee_redesign_tests.move`).
    let order_id = book.next_order_id();
    let escrow_quote = balance::create_for_testing<USDC>(book.bid_escrow_amount(shortfall_price(), 1));
    let bid = order::new<BTC, USDC>(order_id, maker_a(), 1, option::none(), option::some(escrow_quote), 1);
    book.insert_resting_order_for_testing(true, shortfall_price(), bid, scenario.ctx());
    let bid_ticket = tiny_clob::new_ticket_for_testing(
        order_id, book.book_id(), tiny_clob::bid(), shortfall_price(),
    );

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
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 1);
    let claimed_events = event::events_by_type<ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, ev_base, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
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
    let (_deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();
    // `book`/`cap` no longer exist -- there is no way to construct a
    // `destroy_orphaned_ticket`/`cancel_order`/`claim_proceeds` call for
    // `bid_ticket` ever again. This is the only remaining disposal path.
    bid_ticket.destroy_ticket_unconditionally();

    scenario.end();
}

// A resting bid that has never been filled has an empty `book.proceeds`
// entry, but its order is still resting on `book`. `destroy_orphaned_ticket`
// used to allow discarding the ticket anyway (voluntarily abandoning a
// still-resting order), but that capability is now removed: while the order
// and the book both still exist, the ticket remains the only self-service
// path back to that order's escrow, and giving it up here would achieve
// nothing a caller couldn't get just as well by calling `cancel_order`
// instead. This must now abort with `EOrderStillResting`.
#[test]
#[expected_failure(abort_code = 31, location = tiny_clob)] // EOrderStillResting
fun destroy_orphaned_ticket_still_resting_order_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    assert!(!book.proceeds_contains_for_testing(order_id), 0);
    book.destroy_orphaned_ticket(bid_ticket);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Same guard as `destroy_orphaned_ticket_still_resting_order_aborts` above,
// but for a bid that is in the `(escrow: 0, remaining_size: 0)`
// "zero-escrow-while-still-resting" state (see
// `escrow_value_queries_tests::resting_order_escrow_reaches_some_zero_escrow_while_still_resting`
// for the full derivation of that state via 97 real fills) rather than a
// never-filled bid with nonzero escrow.
//
// NOTE: that realistic fill-based fixture cannot actually be used to
// exercise `EOrderStillResting` here -- `destroy_orphaned_ticket` checks
// `EProceedsNotEmpty` BEFORE `EOrderStillResting` (see its doc comment), and
// every one of those 97 fills credits real Base proceeds into
// `book.proceeds` for this maker, so that fixture would abort with
// `EProceedsNotEmpty` instead (a stricter, fund-safety-first guard ordering
// -- not a bug). To isolate the `EOrderStillResting` check specifically, this
// test instead constructs the `(escrow: 0, remaining_size: 0)` state
// directly, via the same test-only `insert_resting_order_for_testing`
// bypass `destroy_orphaned_ticket_after_all_zero_credited_fill_disposes_cleanly`
// above uses for precise fixture construction: a resting bid whose Quote
// escrow is zero from the moment it's inserted, so `book.proceeds` has no
// entry for it at all. Even though its *displayed* Quote escrow is exactly
// 0, it is still present/live on the book, so `destroy_orphaned_ticket` must
// abort with `EOrderStillResting` -- zero displayed escrow is not the same
// thing as "safe to discard the ticket".
#[test]
#[expected_failure(abort_code = 31, location = tiny_clob)] // EOrderStillResting
fun destroy_orphaned_ticket_zero_escrow_while_still_resting_bid_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let order_id = book.next_order_id();
    let bid = order::new<BTC, USDC>(
        order_id, maker_a(), 100, option::none(), option::some(balance::create_for_testing<USDC>(0)), 0,
    );
    book.insert_resting_order_for_testing(true, default_price(), bid, scenario.ctx());
    let bid_ticket = tiny_clob::new_ticket_for_testing(
        order_id, book.book_id(), tiny_clob::bid(), default_price(),
    );

    // Genuinely still resting (present in the book's price level), but with
    // 0 displayed Quote escrow, and never filled -- so `book.proceeds` has
    // no entry for it.
    let escrow_opt = book.resting_order_escrow(true, default_price(), order_id);
    assert!(escrow_opt.is_some(), 0);
    let (escrow, remaining) = escrow_opt.borrow().resting_order_escrow_fields();
    assert!(escrow == 0, 1);
    assert!(remaining == 0, 2);
    assert!(!book.proceeds_contains_for_testing(order_id), 3);

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
    // The order is still resting (100 left unfilled), so
    // `destroy_orphaned_ticket` would now abort with `EOrderStillResting` --
    // force-cancel the still-resting remainder independently of the ticket
    // (proceeds are already empty from the claim above) to conclude the
    // order first, then confirm the now-stale ticket disposes cleanly.
    let side2 = returned_ticket2.ticket_side();
    let price2 = returned_ticket2.ticket_price();
    cap.clob_admin_cancel_order(&mut book, side2, price2, order_id, scenario.ctx());
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
    let mut bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
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
    let found = book.update_resting_order(&mut bid_ticket, other());
    assert!(found, 1);
    unit_test::destroy(bid_ticket);

    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, ev_base, ev_quote) =
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
    let mut bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();

    let found = book.update_resting_order(&mut bid_ticket, other());
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
    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    assert!(!book.proceeds_contains_for_testing(order_id), 0);

    let found = book.update_resting_order(&mut bid_ticket, other());
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

    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
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
    let mut bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment_1 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_1, matched_quote_1, _) = book.place_market_order_ask(ask_payment_1, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_1.burn_for_testing();
    matched_quote_1.burn_for_testing(); // pooled under admin() (A)

    scenario.next_tx(admin());
    assert!(book.update_resting_order(&mut bid_ticket, other()), 0); // A -> B

    scenario.next_tx(taker());
    let ask_payment_2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = book.place_market_order_ask(ask_payment_2, 1_000_000_000, 0, fill_size, scenario.ctx(),
    );
    leftover_2.burn_for_testing();
    matched_quote_2.burn_for_testing(); // pooled under other() (B)

    scenario.next_tx(admin());
    assert!(book.update_resting_order(&mut bid_ticket, maker_a()), 1); // B -> C
    unit_test::destroy(bid_ticket);

    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());

    // Event-field-shape assertions carried over from the merged-away
    // `update_resting_order_reassigned_twice_final_payout_goes_to_latest_
    // owner_only` test.
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, ev_base, ev_quote) =
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
    let mut ticket_lo = rest_bid(&mut book, default_price(), 200, 1_000_000_000, scenario.ctx());
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
    assert!(book.update_resting_order(&mut ticket_lo, other()), 3);
    unit_test::destroy(ticket_hi);
    unit_test::destroy(ticket_lo);

    cap.clob_admin_retire(&mut book);
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

// === Pause never blocks recovery ===
//
// `clob_admin_pause_book` blocks placement/market entry points only (see
// its doc comment in `sources/tiny_clob.move`) — it must never block
// `cancel_order`, `claim_proceeds`, `update_resting_order`,
// `set_last_price`, or `clob_admin_cancel_order`. None of the five checks
// `is_paused` at all (confirmed by inspection: the `EBookPaused` guard only
// appears in the placement/market-order functions), but this was never
// exercised end-to-end against an actually-paused book. This test pauses a
// live book and confirms all five still succeed normally, with real
// assertions on their return values/state changes, not just "no abort".
#[test]
fun pause_never_blocks_cancel_claim_update_or_admin_recovery_paths() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Four resting bids at the same price, one per recovery path exercised
    // below: `proceeds_ticket` is partially filled first (while unpaused) to
    // pool real proceeds for `claim_proceeds`; `update_ticket` is reassigned
    // via `update_resting_order`; `admin_cancel_order_id` is force-cancelled
    // via `clob_admin_cancel_order`; `cancel_ticket` is self-cancelled via
    // `cancel_order`.
    let proceeds_size = 200;
    let proceeds_fill_size = 100;
    let proceeds_ticket = rest_bid(&mut book, default_price(), proceeds_size, 1_000_000_000, scenario.ctx());
    let proceeds_order_id = proceeds_ticket.ticket_order_id();

    let mut update_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    let admin_cancel_escrow = book.bid_escrow_amount(default_price(), default_size());
    let admin_cancel_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let admin_cancel_order_id = admin_cancel_ticket.ticket_order_id();
    let admin_cancel_side = admin_cancel_ticket.ticket_side();
    let admin_cancel_price = admin_cancel_ticket.ticket_price();
    unit_test::destroy(admin_cancel_ticket);

    let cancel_escrow = book.bid_escrow_amount(default_price(), default_size());
    let cancel_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());

    // Partially fill `proceeds_ticket` while the book is still unpaused, so
    // there is a genuine, nonzero pooled proceeds balance to claim later.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(proceeds_fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, proceeds_fill_size, scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(proceeds_order_id), 0);

    // Now pause the book. Everything from here on must succeed exactly as it
    // would on an unpaused book.
    scenario.next_tx(admin());
    cap.clob_admin_pause_book(&mut book);

    // (1) `set_last_price` still succeeds while paused. All resting bids sit
    // at `default_price()` with no asks in the book, so any price >=
    // `default_price()` is a valid reset target (>= best bid, no best ask to
    // violate). The earlier partial fill above already left `last_price ==
    // default_price()` as a side effect of matching, so asserting against
    // that same value here would be vacuous -- it would pass even if
    // `set_last_price` were a no-op. Target a strictly different value
    // (`default_price() + 1`) instead, so this assertion only passes if the
    // call genuinely updated `last_price`.
    let new_last_price = default_price() + 1;
    book.set_last_price(new_last_price, scenario.ctx());
    assert!(book.last_price() == new_last_price, 1);

    // (2) `update_resting_order` still succeeds while paused: reassigns the
    // resting order's owner and reports found.
    let found = book.update_resting_order(&mut update_ticket, other());
    assert!(found, 2);
    unit_test::destroy(update_ticket);

    // (3) `clob_admin_cancel_order` still succeeds while paused: force-cancels
    // a resting order and refunds its escrow to the original owner (admin()).
    cap.clob_admin_cancel_order(&mut book, admin_cancel_side, admin_cancel_price, admin_cancel_order_id, scenario.ctx());
    let admin_cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(admin_cancelled_events.length() == 1, 3);
    scenario.next_tx(admin());
    let admin_cancel_refund = scenario.take_from_address<coin::Coin<USDC>>(admin());
    assert!(admin_cancel_refund.value() == admin_cancel_escrow, 4);
    admin_cancel_refund.burn_for_testing();

    // (4) `cancel_order` still succeeds while paused: cancels via the ticket
    // itself and returns the correct escrow refund.
    let (cancel_refund_base, cancel_refund_quote) = book.cancel_order(cancel_ticket, scenario.ctx());
    assert!(cancel_refund_base.burn_for_testing() == 0, 5);
    assert!(cancel_refund_quote.burn_for_testing() == cancel_escrow, 6);

    // (5) `claim_proceeds` still succeeds while paused: pays out the real
    // pooled proceeds from the earlier fill, and returns the still-live
    // ticket (the order has 100 left resting out of the original 200).
    let (claim_base, claim_quote, returned_ticket_opt) = book.claim_proceeds(proceeds_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == proceeds_fill_size, 7);
    assert!(claim_quote.burn_for_testing() == 0, 8);
    assert!(!book.proceeds_contains_for_testing(proceeds_order_id), 9);
    assert!(returned_ticket_opt.is_some(), 10);
    let returned_ticket = returned_ticket_opt.destroy_some();

    // The book is still paused throughout — confirms none of the five paths
    // above went through some code path that accidentally unpaused it.
    assert!(book.is_paused(), 11);

    unit_test::destroy(returned_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Ticket possession, not the recorded `owner` field, is the real
// authority for claiming proceeds ===
//
// `update_resting_order`'s pooled-proceeds owner sync now runs
// unconditionally, regardless of whether the order it targets is still
// resting — this is documented on `update_resting_order`'s own doc comment
// in `sources/tiny_clob.move`. Even once an order has concluded (fully
// filled, `cancel_order`, `clob_admin_cancel_order`, or
// `clob_admin_drain_step`) but still has a pooled, unclaimed proceeds entry,
// a further `update_resting_order` call still returns `false` (the resting
// order itself genuinely isn't found), but the pooled entry's recorded
// `owner` IS resynced to the new target regardless. The pooled amount is
// never stranded or misdirected either way: it remains fully claimable via
// `push_proceeds`/`drain_proceeds` (pays the last-recorded `owner`) or via
// `claim_proceeds` through the `OrderTicket` (pays whoever holds the ticket,
// regardless of the recorded `owner`). These tests confirm both payout
// paths and, most importantly (the fourth test below), that ticket
// possession is the actual claim authority even with no force-cancellation
// involved at all — the recorded `owner` field is merely what
// `push_proceeds`/`drain_proceeds` happen to pay, not a capability in
// itself.

#[test]
fun update_resting_order_after_force_cancel_still_syncs_pooled_proceeds_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // maker_a() rests an ask big enough to be partially filled, leaving it
    // still resting, and pooling proceeds (Quote) under maker_a().
    let size = 200;
    let fill_size = 100;
    scenario.next_tx(maker_a());
    let mut ask_ticket = rest_ask(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = ask_ticket.ticket_order_id();
    let side = ask_ticket.ticket_side();
    let price = ask_ticket.ticket_price();

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(default_price(), fill_size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, _) =
        book.place_market_order_bid(bid_payment, 1_000_000_000, 0, fill_size, u64_max(), scenario.ctx());
    matched_base.burn_for_testing();
    leftover_payment.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // Reassign to maker_b() while still resting — sync succeeds, proceeds
    // now recorded under maker_b().
    scenario.next_tx(maker_a());
    assert!(book.update_resting_order(&mut ask_ticket, maker_b()), 1);

    // Force-cancel the still-resting remainder: the order is gone from the
    // book, but the pooled proceeds entry survives untouched.
    scenario.next_tx(admin());
    cap.clob_admin_cancel_order(&mut book, side, price, order_id, scenario.ctx());
    assert!(book.proceeds_contains_for_testing(order_id), 2);

    // A further reassignment attempt correctly reports not-found for the
    // resting-order half (the order is no longer resting) -- but the pooled
    // proceeds sync still runs unconditionally, so it DOES retarget the
    // pooled entry to maker_c() despite that `false`.
    assert!(!book.update_resting_order(&mut ask_ticket, maker_c()), 3);
    unit_test::destroy(ask_ticket);

    // push_proceeds pays maker_c() -- the target of this last reassignment
    // -- not maker_b(), proving the sync ran even though the call reported
    // the resting order itself as not-found.
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 4);
    let (_, _, ev_claimant, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == maker_c(), 5);
    assert!(ev_base == 0, 6);
    assert!(ev_quote == budget, 7);
    assert!(!book.proceeds_contains_for_testing(order_id), 8);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_via_ticket_pays_caller_not_stale_owner_after_force_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    // Same setup as above through the force-cancel step: maker_a() rests an
    // ask, a partial fill pools proceeds under maker_a(), a still-resting
    // reassignment syncs them to maker_b(), then the remainder is
    // force-cancelled — leaving a pooled entry recorded against maker_b().
    // This test never calls `update_resting_order` again, so it's
    // unaffected by that function's unconditional-sync behavior; it goes
    // straight to `claim_proceeds` via the ticket instead.
    let size = 200;
    let fill_size = 100;
    scenario.next_tx(maker_a());
    let mut ask_ticket = rest_ask(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = ask_ticket.ticket_order_id();
    let side = ask_ticket.ticket_side();
    let price = ask_ticket.ticket_price();

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(default_price(), fill_size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, _) =
        book.place_market_order_bid(bid_payment, 1_000_000_000, 0, fill_size, u64_max(), scenario.ctx());
    matched_base.burn_for_testing();
    leftover_payment.burn_for_testing();

    scenario.next_tx(maker_a());
    assert!(book.update_resting_order(&mut ask_ticket, maker_b()), 0);

    scenario.next_tx(admin());
    cap.clob_admin_cancel_order(&mut book, side, price, order_id, scenario.ctx());
    assert!(book.proceeds_contains_for_testing(order_id), 1);

    // An unrelated address holding the ticket claims via claim_proceeds —
    // it, not maker_b() (the recorded owner), receives the full pooled
    // amount. Ticket possession, not the recorded owner field, is what
    // actually authorizes payout via this path.
    scenario.next_tx(other());
    let (claim_base, claim_quote, returned_ticket_opt) =
        book.claim_proceeds(ask_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == 0, 2);
    assert!(claim_quote.burn_for_testing() == budget, 3);
    // The order is no longer resting (force-cancelled above), so the ticket
    // is auto-destroyed and nothing more can ever be claimed through it.
    assert!(returned_ticket_opt.is_none(), 4);
    returned_ticket_opt.destroy_none();

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 5);
    let (ev_book_id, _, ev_claimant, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == other(), 6);
    assert!(ev_book_id == book_id, 7);
    assert!(ev_base == 0, 8);
    assert!(ev_quote == budget, 9);

    // The pooled entry is now gone: a subsequent push_proceeds pays nobody
    // (claim_maker_balance returns zero balances for a missing entry, so no
    // transfer and no event fire). The retire call below is a harmless
    // no-op setup step, not a requirement of push_proceeds itself.
    assert!(!book.proceeds_contains_for_testing(order_id), 10);
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    assert!(event::events_by_type<tiny_clob::ProceedsClaimed>().length() == 1, 11);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_via_ticket_pays_holder_over_synced_owner_with_no_force_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    // The cleanest demonstration: no force-cancellation anywhere in this
    // test. maker_a() rests an ask big enough to be partially filled,
    // leaving it still resting, and pooling proceeds (Quote) under
    // maker_a().
    let size = 200;
    let fill_size = 100;
    scenario.next_tx(maker_a());
    let mut ask_ticket = rest_ask(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = ask_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let budget = book.bid_escrow_amount(default_price(), fill_size);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, leftover_payment, _) =
        book.place_market_order_bid(bid_payment, 1_000_000_000, 0, fill_size, u64_max(), scenario.ctx());
    matched_base.burn_for_testing();
    leftover_payment.burn_for_testing();
    assert!(book.proceeds_contains_for_testing(order_id), 0);

    // maker_a() reassigns the still-resting order to maker_b() — sync
    // succeeds (`true`), and the pooled proceeds entry's recorded owner
    // moves to maker_b() immediately, per Fix 3 above.
    scenario.next_tx(maker_a());
    assert!(book.update_resting_order(&mut ask_ticket, maker_b()), 1);

    // But maker_a() KEEPS the ticket and claims through it directly. Despite
    // the recorded owner now being maker_b(), the payout — and the
    // ProceedsClaimed event's claimant — go to maker_a(), the ticket holder,
    // proving ticket possession (not the recorded `owner` field) is the real
    // claim authority, exactly as it always was for a still-resting order.
    let (claim_base, claim_quote, returned_ticket_opt) =
        book.claim_proceeds(ask_ticket, scenario.ctx());
    assert!(claim_base.burn_for_testing() == 0, 2);
    assert!(claim_quote.burn_for_testing() == budget, 3);
    // The remaining 100 of the original 200 is still resting, so the ticket
    // remains live and reusable.
    assert!(returned_ticket_opt.is_some(), 4);
    let returned_ticket = returned_ticket_opt.destroy_some();

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 5);
    let (ev_book_id, _, ev_claimant, ev_base, ev_quote) =
        claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == maker_a(), 6);
    assert!(ev_book_id == book_id, 7);
    assert!(ev_base == 0, 8);
    assert!(ev_quote == budget, 9);
    assert!(!book.proceeds_contains_for_testing(order_id), 10);

    unit_test::destroy(returned_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_after_full_fill_still_syncs_pooled_proceeds_owner() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Unlike update_resting_order_not_found_is_a_noop above (which probes a
    // never-existing order_id / a wrong id at an existing price level), this
    // targets the not-found path where the order genuinely DID exist and was
    // only just removed from the tree by being fully filled, while its
    // proceeds stay pooled. The resting-order half of the reassignment must
    // still report not-found (the order itself is genuinely gone) -- but the
    // pooled-proceeds sync runs unconditionally on that outcome, so the
    // pooled entry IS retargeted to the new owner regardless.
    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(default_size(), scenario.ctx());
    let (leftover_payment, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, default_size(), scenario.ctx(),
    );
    leftover_payment.burn_for_testing();
    matched_quote.burn_for_testing(); // fully filled -> no longer resting

    scenario.next_tx(admin());
    assert!(book.proceeds_contains_for_testing(order_id), 0);
    // Order is gone from the tree -> the resting-order half reports not-found...
    assert!(!book.update_resting_order(&mut bid_ticket, other()), 1);
    unit_test::destroy(bid_ticket);

    // ...but the pooled proceeds ARE retargeted to `other()` regardless.
    cap.clob_admin_retire(&mut book);
    cap.push_proceeds(&mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (_, _, ev_claimant, _, _) = claimed_events[0].proceeds_claimed_fields_for_testing();
    assert!(ev_claimant == other(), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Owner-sync getters vs. actual drain/push payouts ===
//
// `resting_order_owner`/`resting_order_owner_by_ticket` and
// `proceeds_owner`/`proceeds_owner_by_ticket` are so far only exercised in
// isolation (escrow_value_queries_tests.move), checked against a known
// address but never against what `drain_side`/`push_proceeds` actually pay
// in the SAME test. This closes that gap end-to-end: predict via the
// getters first, then drain/push and confirm the real payout lands exactly
// where predicted.
#[test]
fun owner_sync_getters_predict_actual_drain_and_push_payouts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // maker_a() rests a bid big enough to be partially filled, leaving it
    // still resting (with locked escrow) AND creating a pooled proceeds
    // entry -- so both getter families have something live to predict.
    scenario.next_tx(maker_a());
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

    // Before any drain: the getters predict maker_a() for both the still-
    // resting order's escrow and the pooled proceeds -- via the raw lookups
    // and the ticket-based wrappers.
    assert!(book.resting_order_owner(true, default_price(), order_id).destroy_some() == maker_a(), 0);
    assert!(book.resting_order_owner_by_ticket(&bid_ticket).destroy_some() == maker_a(), 1);
    assert!(book.proceeds_owner(order_id).destroy_some() == maker_a(), 2);
    assert!(book.proceeds_owner_by_ticket(&bid_ticket).destroy_some() == maker_a(), 3);

    let remaining_size = size - fill_size;
    let expected_escrow_refund = book.bid_escrow_amount(default_price(), remaining_size);
    unit_test::destroy(bid_ticket);

    // Retire and force-drain: this exercises BOTH the remaining resting
    // order's escrow (drain_side) and the pooled proceeds entry
    // (drain_proceeds) in the same call.
    scenario.next_tx(admin());
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    // The actual payouts land exactly where the getters predicted: maker_a().
    scenario.next_tx(maker_a());
    let escrow_refund = scenario.take_from_address<coin::Coin<USDC>>(maker_a());
    assert!(escrow_refund.value() == expected_escrow_refund, 4);
    escrow_refund.burn_for_testing();

    let proceeds_payout = scenario.take_from_address<coin::Coin<BTC>>(maker_a());
    assert!(proceeds_payout.value() == fill_size, 5);
    proceeds_payout.burn_for_testing();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// The custody-drift scenario the getters exist to help detect: an order is
// placed by maker_a(), custody notionally changes hands off-chain (e.g. a
// wrapper reassigns the ticket internally), but `update_resting_order` is
// deliberately never called to sync that on-chain. `resting_order_owner`
// must keep reporting the RECORDED owner (maker_a()), correctly predicting
// that a subsequent force-cancel will pay maker_a() -- not whoever the
// ticket notionally belongs to off-chain, since the contract has no way to
// know that without an explicit `update_resting_order` call.
#[test]
fun resting_order_owner_predicts_stale_payout_when_update_resting_order_is_skipped() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    let (side, price) = (bid_ticket.ticket_side(), bid_ticket.ticket_price());

    // update_resting_order is deliberately never called here. The getter
    // still (correctly) predicts the stale recorded owner, maker_a().
    assert!(book.resting_order_owner(side, price, order_id).destroy_some() == maker_a(), 0);
    assert!(book.resting_order_owner_by_ticket(&bid_ticket).destroy_some() == maker_a(), 1);

    let expected_refund = book.bid_escrow_amount(default_price(), default_size());
    unit_test::destroy(bid_ticket);

    scenario.next_tx(admin());
    cap.clob_admin_cancel_order(&mut book, side, price, order_id, scenario.ctx());

    // The force-cancel pays exactly the address the getter predicted --
    // maker_a(), the last address recorded on-chain -- and nothing at all
    // goes to maker_b(), the notional "new" ticket holder that custody
    // would have moved to had update_resting_order actually been called.
    scenario.next_tx(maker_a());
    let refund = scenario.take_from_address<coin::Coin<USDC>>(maker_a());
    assert!(refund.value() == expected_refund, 2);
    refund.burn_for_testing();
    assert!(!ts::has_most_recent_for_address<coin::Coin<USDC>>(maker_b()), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

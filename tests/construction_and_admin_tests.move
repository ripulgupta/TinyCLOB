#[test_only]
module tiny_clob::construction_and_admin_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};
use tiny_clob::test_utils::{
    Self, admin, other, taker, maker_a, maker_b, min_size, max_min_size, default_price, default_size, new_book, destroy_book_and_cap, rest_bid, rest_ask,
};


public struct CapHolder has key, store {
    id: UID,
    cap: ClobAdminCap,
}

// `clob_admin_finalize`'s precondition assert no longer checks the book's
// fee_accumulator at all — it now sweeps whatever's left in the accumulator
// itself and hands it back to the caller as coins, so a nonzero
// fee_accumulator is no longer a precondition failure. The
// `clob_admin_finalize` tests below only ever exercise resting-order-only
// scenarios where fee_accumulator stays (0, 0), so that sweep path is never
// actually hit there. These tests close that gap: they generate a genuine
// fee-bearing fill, retire+drain the book, and confirm `clob_admin_finalize`
// succeeds either way — whether or not fees were claimed beforehand — and
// returns the correct swept fee amounts as coins.

const FINALIZE_FEES_PRICE: u64 = 50_000;
const FINALIZE_FEES_SIZE: u64 = 2_000;

/// Rests an ask (maker side, fee-rate snapshot taken at rest time) then
/// fully crosses it with a bid (taker side), so the book's
/// `fee_accumulator` ends up genuinely nonzero on both legs.
fun generate_one_fee_bearing_fill(
    scenario: &mut ts::Scenario,
    book: &mut OrderBook<BTC, USDC>,
    taker_fee_bps: u64,
    maker_fee_bps: u64,
): (u64, u64) {
    let ask_ticket = rest_ask(book, FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    // This bid crosses the resting ask above at the same price/size, so it
    // fully fills and never rests: the returned ticket option is `none`.
    let quote_cost = book.bid_escrow_amount(FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE);
    let payment = coin::mint_for_testing<USDC>(quote_cost, scenario.ctx());
    let (bid_ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, FINALIZE_FEES_SIZE, 1_000_000_000, scenario.ctx());
    bid_ticket_opt.destroy_none();
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();

    let taker_fee_base =
        (((FINALIZE_FEES_SIZE as u128) * (taker_fee_bps as u128) + 10_000 - 1) / 10_000) as u64;
    let maker_fee_quote =
        (((quote_cost as u128) * (maker_fee_bps as u128) + 10_000 - 1) / 10_000) as u64;
    (taker_fee_base, maker_fee_quote)
}

#[test]
fun new_succeeds_with_no_capability_argument_and_no_registry_interaction() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);

    assert!(book.min_size() == min_size(), 1);
    assert!(!book.is_paused(), 2);
    assert!(book.clob_admin_cap_id_for_testing() == cap.cap_id_for_testing(), 3);
    let (taker_bps, maker_bps) = book.fee_config();
    assert!(taker_bps == 0, 4);
    assert!(maker_bps == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 1, location = tiny_clob)] // tiny_clob::EZeroMinSize
fun new_zero_min_size_aborts() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<BTC, USDC>(0, 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob)] // tiny_clob::EMinSizeTooLarge
fun new_min_size_too_large_aborts() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (book, cap) = tiny_clob::new<BTC, USDC>(max_min_size() + 1, 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
fun new_size_at_max_boundary_succeeds() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    // exponent = 4, not 19: with `price_scale == 1` and `min_size ==
    // max_min_size() == 10^15`, the payment needed to reach `10^exponent` at
    // `min_size` is `10^exponent * 10^15`; at exponent 19 that's `10^34`,
    // far beyond `u64::MAX`, which would now trip
    // `EMinSizeExceedsReachableRange` at construction (this test's own
    // subject is the `min_size == max_min_size()` boundary, not the price
    // range, so a modest exponent keeps that boundary reachable: `10^4 *
    // 10^15 = 10^19`, comfortably under `u64::MAX`, ~1.8446744e19).
    let (book, cap) = tiny_clob::new<BTC, USDC>(max_min_size(), 0, 0, 0, 4, 1, &wrapper_uid, scenario.ctx());
    assert!(book.min_size() == max_min_size(), 0);
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
fun two_books_identical_types_fully_independent_construction() {
    let mut scenario = ts::begin(admin());
    let (mut book1, cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);

    assert!(book1.book_id() != book2.book_id(), 0);
    assert!(cap1.cap_id_for_testing() != cap2.cap_id_for_testing(), 1);

    cap1.clob_admin_set_taker_fee(&mut book1, 5);
    let (taker1, _) = book1.fee_config();
    let (taker2, _) = book2.fee_config();
    assert!(taker1 == 5, 2);
    assert!(taker2 == 0, 3);

    destroy_book_and_cap(book1, cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
fun clob_admin_cap_store_and_discard() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    // Demonstrates `store`-ability directly: holds the cap as a plain
    // field of a test-only wrapper struct.
    let holder = CapHolder { id: object::new(scenario.ctx()), cap };
    let CapHolder { id, cap } = holder;
    id.delete();

    let cap_id = cap.cap_id_for_testing();

    // The cap can now only be destroyed by consuming it inside
    // `clob_admin_finalize` — there is no standalone discard function
    // anymore. Run a full retire -> drain -> clob_admin_finalize sequence and
    // confirm `ClobAdminCapDiscarded` fires from inside `clob_admin_finalize`
    // with the correct `cap_id`/`book_id`.
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();
    assert!(deleted_id == book_id, 3);

    let discarded_events = event::events_by_type<tiny_clob::ClobAdminCapDiscarded>();
    assert!(discarded_events.length() == 1, 0);
    let (event_book_id, _event_enclosing_id, event_cap_id) =
        discarded_events[0].clob_admin_cap_discarded_fields_for_testing();
    assert!(event_cap_id == cap_id, 1);
    assert!(event_book_id == book_id, 2);

    scenario.end();
}

#[test]
fun version_guard_view_functions_do_not_abort_on_stale_version() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_book_version_for_testing(999);

    // The five pure-read view functions never assert the version guard.
    let (_taker, _maker) = book.fee_config();
    let (_base, _quote) = book.fee_accumulator_balances();
    let _ = book.is_book_paused();
    let _ = book.best_bid();
    let _ = book.best_ask();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 5, location = tiny_clob)] // tiny_clob::ENewVersionMismatch
fun version_guard_pause_aborts_on_future_version() {
    // A `version` AHEAD of CURRENT_VERSION means this package build doesn't
    // yet understand a `version` the book already carries — the one case
    // `assert_book_version` still refuses to silently paper over.
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_book_version_for_testing(999);
    cap.clob_admin_pause_book(&mut book);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun version_auto_upgrades_when_stale_lower_than_current() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();
    book.set_book_version_for_testing(0);
    // No explicit migration call needed — any ordinary version-guarded
    // function transparently upgrades the book's stored version in place,
    // and emits a BookVersionUpgraded observability event at the moment of
    // the bump.
    cap.clob_admin_pause_book(&mut book);
    assert!(book.book_version() == 2, 0);

    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 1, 1);
    let (ev_book_id, _ev_enclosing_id, ev_from, ev_to) = upgraded_events[0].book_version_upgraded_fields_for_testing();
    assert!(ev_book_id == book_id, 2);
    assert!(ev_from == 0, 3);
    assert!(ev_to == 2, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A book already at `CURRENT_VERSION` must NOT emit a spurious
/// `BookVersionUpgraded` event — the event only fires on an actual bump.
#[test]
fun version_already_current_emits_no_upgrade_event() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_pause_book(&mut book);
    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 0, 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// The version-guard auto-upgrade path above is only ever exercised via
// `clob_admin_pause_book`. `assert_book_version` runs at the top of every
// version-guarded function, `cancel_order` included, so it auto-upgrades
// exactly the same way there — this test pins that down through a
// completely different call path (an ordinary trader-facing function, not
// an admin one).
#[test]
fun version_auto_upgrades_through_cancel_order() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.book_id();

    let ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    book.set_book_version_for_testing(0);

    let (refund_base, refund_quote) = book.cancel_order(ticket, scenario.ctx());
    refund_base.burn_for_testing();
    refund_quote.burn_for_testing();
    assert!(book.book_version() == 2, 0);

    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 1, 1);
    let (ev_book_id, _ev_enclosing_id, ev_from, ev_to) = upgraded_events[0].book_version_upgraded_fields_for_testing();
    assert!(ev_book_id == book_id, 2);
    assert!(ev_from == 0, 3);
    assert!(ev_to == 2, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// `version_guard_pause_aborts_on_future_version` above is the only test
// exercising the ENewVersionMismatch abort path, and only through
// `clob_admin_pause_book`. This pins the same abort down through a
// completely different, non-admin function.
#[test]
#[expected_failure(abort_code = 5, location = tiny_clob)] // tiny_clob::ENewVersionMismatch
fun version_guard_cancel_order_aborts_on_future_version() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ticket = rest_bid(&mut book, default_price(), default_size(), 1_000_000_000, scenario.ctx());
    book.set_book_version_for_testing(999);

    let (refund_base, refund_quote) = book.cancel_order(ticket, scenario.ctx());
    refund_base.burn_for_testing();
    refund_quote.burn_for_testing();

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- Documented limitation: a book whose stored `version` is ahead of this
// --- package's `CURRENT_VERSION` has no escape hatch. `assert_book_version`
// --- aborts with `ENewVersionMismatch` on *every* version-guarded entry
// --- point once `book.version > CURRENT_VERSION`, and that includes
// --- `clob_admin_retire` — the very first step of the retire -> drain ->
// --- finalize teardown sequence. So once a book's version somehow ends up
// --- ahead of the running package build, it can never even begin being
// --- torn down: any resting orders, pooled proceeds, or accumulated fees on
// --- it are permanently stuck, with no admin recovery path whatsoever.
// --- This is a real, current limitation of `assert_book_version`'s design
// --- (not something these tests assert should be fixed) — pinned down here
// --- the same way other documented limitations in this codebase are
// --- test-pinned. `version_guard_cancel_order_aborts_on_future_version`
// --- above already shows an ordinary trader operation is blocked the same
// --- way; this test shows the teardown path is blocked too, at its very
// --- first step.
#[test]
#[expected_failure(abort_code = 5, location = tiny_clob)] // tiny_clob::ENewVersionMismatch
fun future_version_book_blocks_retire_teardown_path_too() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    book.set_book_version_for_testing(999);

    // Even the very first step of the retire -> drain -> finalize teardown
    // sequence is blocked — there is no way to ever retire, drain, or
    // finalize a book stuck at a future version.
    cap.clob_admin_retire(&mut book);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun fee_setters_bounds_and_events() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);
    let (taker, maker) = book.fee_config();
    assert!(taker == 10, 0);
    assert!(maker == 5, 1);

    let taker_events = event::events_by_type<tiny_clob::TakerFeeSet>();
    let maker_events = event::events_by_type<tiny_clob::MakerFeeSet>();
    assert!(taker_events.length() == 1, 2);
    assert!(maker_events.length() == 1, 3);
    let (ev_book_id, ev_enclosing_id, ev_rate) = taker_events[0].taker_fee_set_fields_for_testing();
    assert!(ev_book_id == book.book_id(), 40);
    assert!(ev_enclosing_id == book.enclosing_object_id_for_testing(), 4);
    assert!(ev_rate == 10, 5);
    let (ev_maker_book_id, ev_maker_enclosing_id, ev_maker_rate) = maker_events[0].maker_fee_set_fields_for_testing();
    assert!(ev_maker_book_id == book.book_id(), 60);
    assert!(ev_maker_enclosing_id == book.enclosing_object_id_for_testing(), 6);
    assert!(ev_maker_rate == 5, 7);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 6, location = tiny_clob)] // tiny_clob::ENotRetiring
fun drain_step_before_retire_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 6, location = tiny_clob)] // tiny_clob::ENotRetiring
fun finalize_before_retire_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    unit_test::destroy(deleted_id);
    unit_test::destroy(fee_base_coin);
    unit_test::destroy(fee_quote_coin);
    scenario.end();
}

// `clob_admin_finalize` now takes `cap` by value, but must still reject a
// cap minted for a different book — the by-value signature change must not
// weaken this authentication check.
#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun finalize_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (book1, _cap1) = new_book(&mut scenario);
    let (mut book2, cap2) = new_book(&mut scenario);
    cap2.clob_admin_retire(&mut book2);
    cap2.clob_admin_drain_step(&mut book2, 10, scenario.ctx());

    // cap2 belongs to book2, not book1 — must abort with EWrongClobAdminCap.
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap2.clob_admin_finalize(book1, scenario.ctx());
    unit_test::destroy(deleted_id);
    unit_test::destroy(fee_base_coin);
    unit_test::destroy(fee_quote_coin);
    unit_test::destroy(book2);
    unit_test::destroy(_cap1);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 7, location = tiny_clob)] // tiny_clob::ENotFullyDrained
fun finalize_while_nonempty_aborts_not_fully_drained() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, other(), size, option::none(), option::some(escrow), 0);
    book.insert_resting_order_for_testing(true, price, order, scenario.ctx());

    cap.clob_admin_retire(&mut book);
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    unit_test::destroy(deleted_id);
    unit_test::destroy(fee_base_coin);
    unit_test::destroy(fee_quote_coin);
    scenario.end();
}

// `finalize_while_nonempty_aborts_not_fully_drained` above only exercises a
// nonempty bids side. The precondition assert also checks `book.asks`, so
// this pins down the ask-side-nonempty variant: no bids, no pooled
// proceeds, zero fees — only a resting ask remains.
#[test]
#[expected_failure(abort_code = 7, location = tiny_clob)] // tiny_clob::ENotFullyDrained
fun finalize_while_only_asks_nonempty_aborts_not_fully_drained() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<BTC>(size);
    let order = order::new<BTC, USDC>(order_id, other(), size, option::some(escrow), option::none(), 0);
    book.insert_resting_order_for_testing(false, price, order, scenario.ctx());

    cap.clob_admin_retire(&mut book);
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    unit_test::destroy(deleted_id);
    unit_test::destroy(fee_base_coin);
    unit_test::destroy(fee_quote_coin);
    scenario.end();
}

// Pins down the pooled-proceeds-nonempty variant of the same precondition
// assert: no resting bids or asks (the ask below fully fills and is
// removed from the tree), zero fees (this book's default fee rates are
// both 0) — only a pooled proceeds entry for the filled maker remains.
#[test]
#[expected_failure(abort_code = 7, location = tiny_clob)] // tiny_clob::ENotFullyDrained
fun finalize_while_only_proceeds_nonempty_aborts_not_fully_drained() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, price, size, 1_000_000_000, scenario.ctx());
    let order_id = ask_ticket.ticket_order_id();
    unit_test::destroy(ask_ticket);

    // This bid crosses the resting ask above at the same price/size, so it
    // fully fills and the ask is removed from the tree entirely, leaving
    // only a pooled proceeds entry for it behind.
    let quote_cost = book.bid_escrow_amount(price, size);
    let payment = coin::mint_for_testing<USDC>(quote_cost, scenario.ctx());
    let (bid_ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(payment, size, 1_000_000_000, scenario.ctx());
    bid_ticket_opt.destroy_none();
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();

    // The resting ask must genuinely be gone from the tree (not merely
    // never-rested) for this test to isolate the proceeds-only arm of
    // finalize's emptiness check -- `bids_size_for_testing()` can't prove
    // this (no bid ever rested here), so check the ask side directly.
    assert!(book.best_ask().is_none(), 100);
    assert!(book.proceeds_contains_for_testing(order_id), 101);
    let (fee_base, fee_quote) = book.fee_accumulator_balances();
    assert!(fee_base == 0, 102);
    assert!(fee_quote == 0, 103);

    cap.clob_admin_retire(&mut book);
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    unit_test::destroy(deleted_id);
    unit_test::destroy(fee_base_coin);
    unit_test::destroy(fee_quote_coin);
    scenario.end();
}

#[test]
fun deletion_lifecycle_retire_drain_finalize_succeeds() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, other(), size, option::none(), option::some(escrow), 0);
    book.insert_resting_order_for_testing(true, price, order, scenario.ctx());

    cap.clob_admin_retire(&mut book);
    let retired_events = event::events_by_type<tiny_clob::OrderBookRetired>();
    assert!(retired_events.length() == 1, 0);
    let (ev_retired_book_id, ev_retired_enclosing_id) = retired_events[0].order_book_retired_fields_for_testing();
    assert!(ev_retired_book_id == book.book_id(), 10);
    assert!(ev_retired_enclosing_id == book.enclosing_object_id_for_testing(), 11);

    // Repeatable, bounded max_items — one call with max_items = 0 is a no-op.
    cap.clob_admin_drain_step(&mut book, 0, scenario.ctx());
    assert!(book.bids_size_for_testing() == 1, 1);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    assert!(book.bids_size_for_testing() == 0, 2);

    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 3);
    let (deleted_book_id, _deleted_enclosing_id, deleted_base, deleted_quote) =
        deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_book_id == deleted_id, 4);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 40);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 41);

    // Zero-fee finalize (nothing ever filled here, so `fee_accumulator`
    // stayed (0, 0)) must not spuriously emit a `FeesClaimed` event.
    let fees_claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(fees_claimed_events.length() == 0, 42);

    scenario.end();
}

// `clob_admin_finalize`'s return value must be the book's true,
// unforgeable object id (`object::uid_to_inner(&book.id)`), NOT
// `enclosing_object_id` — which is caller-supplied at construction and
// must never be trusted for identifying which book was just deleted.
// This test constructs a book with a foreign `enclosing_object_id` that
// differs from its own id, then confirms the two are correctly decoupled:
// the function's return value tracks the book's true id, and the emitted
// `OrderBookDeleted` event now carries BOTH — its own `book_id` field
// tracks the true id (matching the function's return value) while its
// `enclosing_object_id` field tracks the caller-supplied foreign id,
// confirming neither is accidentally populated with the other's value.
#[test]
fun clob_admin_finalize_returns_true_book_id_not_enclosing_object_id() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(
        min_size(), 0, 0, 0, 17, 1, &wrapper_uid, scenario.ctx(),
    );

    let true_book_id = book.book_id();
    assert!(true_book_id != foreign_id, 0);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();
    assert!(deleted_id == true_book_id, 1);

    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 2);
    let (deleted_book_id, deleted_enclosing_id, _, _) =
        deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_book_id == deleted_id, 3);
    assert!(deleted_enclosing_id == foreign_id, 4);
    assert!(deleted_book_id != deleted_enclosing_id, 5);

    wrapper_uid.delete();
    scenario.end();
}

// `BookVersionUpgraded`/`ClobAdminCapDiscarded` now both carry the same
// two-field id prefix as every other event: a `book_id` (the book's true,
// unforgeable id) and an `enclosing_object_id` (the caller-supplied id from
// construction). This test confirms both fields are correctly, independently
// populated on both events for a book constructed with a foreign
// `enclosing_object_id` — catching a copy-paste swap of the two fields at
// either emit site, which would otherwise compile cleanly (both are `ID`).
#[test]
fun book_version_upgraded_and_cap_discarded_stamp_both_book_id_and_enclosing_object_id() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(
        min_size(), 0, 0, 0, 17, 1, &wrapper_uid, scenario.ctx(),
    );
    let true_book_id = book.book_id();
    assert!(true_book_id != foreign_id, 0);

    book.set_book_version_for_testing(0);
    cap.clob_admin_pause_book(&mut book);

    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 1, 1);
    let (ev_book_id, ev_enclosing_id, _, _) = upgraded_events[0].book_version_upgraded_fields_for_testing();
    assert!(ev_book_id == true_book_id, 2);
    assert!(ev_enclosing_id == foreign_id, 3);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    fee_base_coin.burn_for_testing();
    fee_quote_coin.burn_for_testing();
    assert!(deleted_id == true_book_id, 4);

    let discarded_events = event::events_by_type<tiny_clob::ClobAdminCapDiscarded>();
    assert!(discarded_events.length() == 1, 5);
    let (ev_discard_book_id, ev_discard_enclosing_id, _) =
        discarded_events[0].clob_admin_cap_discarded_fields_for_testing();
    assert!(ev_discard_book_id == true_book_id, 6);
    assert!(ev_discard_enclosing_id == foreign_id, 7);

    wrapper_uid.delete();
    scenario.end();
}

// Required correctness gate: `book_id` (the book's true, unforgeable id)
// and `enclosing_object_id` (the caller-supplied id from construction) must
// be independently correct on every event this module emits — not merely
// "some `ID` value present", but specifically the RIGHT one in the RIGHT
// field. Both fields share the same type (`ID`), so a copy-paste swap of
// the two at any single `event::emit` call site would compile cleanly and
// pass every OTHER test that only ever checks one of the two fields in
// isolation. This test constructs one book with a deliberately foreign
// `enclosing_object_id`, then drives a broad spread of distinct event
// types from it and asserts BOTH fields on each: `book_id == book.book_id()`
// (unaffected by the foreign id) and `enclosing_object_id == foreign_id`
// (the wrapper this test controls, never the book's own true id).
#[test]
fun every_event_type_stamps_true_book_id_and_foreign_enclosing_object_id_independently() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let foreign_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx());
    let true_book_id = book.book_id();
    assert!(true_book_id != foreign_id, 0);

    // TakerFeeSet / MakerFeeSet
    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);
    let taker_events = event::events_by_type<tiny_clob::TakerFeeSet>();
    let (tb, te, _) = taker_events[0].taker_fee_set_fields_for_testing();
    assert!(tb == true_book_id, 1);
    assert!(te == foreign_id, 2);
    let maker_events = event::events_by_type<tiny_clob::MakerFeeSet>();
    let (mb, me, _) = maker_events[0].maker_fee_set_fields_for_testing();
    assert!(mb == true_book_id, 3);
    assert!(me == foreign_id, 4);

    // PriceBandFactorSet
    cap.clob_admin_set_price_band_factor(&mut book, option::some(1000));
    let band_events = event::events_by_type<tiny_clob::PriceBandFactorSet>();
    let (bb, be, _) = band_events[0].price_band_factor_set_fields_for_testing();
    assert!(bb == true_book_id, 5);
    assert!(be == foreign_id, 6);

    // Paused / Unpaused
    cap.clob_admin_pause_book(&mut book);
    let paused_events = event::events_by_type<tiny_clob::Paused>();
    let (pb, pe) = paused_events[0].paused_fields_for_testing();
    assert!(pb == true_book_id, 7);
    assert!(pe == foreign_id, 8);

    cap.clob_admin_unpause_book(&mut book);
    let unpaused_events = event::events_by_type<tiny_clob::Unpaused>();
    let (ub, ue) = unpaused_events[0].unpaused_fields_for_testing();
    assert!(ub == true_book_id, 9);
    assert!(ue == foreign_id, 10);

    // OrderPlaced / OrderExecuted -- rest an ask (nothing to cross yet).
    let ask_size = 100;
    let ask_expected_quote_output = test_utils::ask_expected_output_for_price(&book, 1, ask_size);
    let ask_payment = coin::mint_for_testing<BTC>(ask_size, scenario.ctx());
    let (ask_ticket_opt, ask_leftover_base, ask_matched_quote, _) =
        book.place_limit_order_ask(ask_payment, ask_expected_quote_output, 1_000_000_000, scenario.ctx());
    ask_leftover_base.burn_for_testing();
    ask_matched_quote.burn_for_testing();
    let ask_ticket = ask_ticket_opt.destroy_some();

    let placed_events = event::events_by_type<tiny_clob::OrderPlaced>();
    let (plb, ple, _, _, _, _, _, _) = placed_events[0].order_placed_fields_for_testing();
    assert!(plb == true_book_id, 11);
    assert!(ple == foreign_id, 12);

    let executed_events = event::events_by_type<tiny_clob::OrderExecuted>();
    let (exb, exe, _, _, _, _, _, _, _, _, _, _, _) = executed_events[0].order_executed_fields_for_testing();
    assert!(exb == true_book_id, 13);
    assert!(exe == foreign_id, 14);

    // OrderFilled / MakerFeeSettled -- a bid crosses the resting ask fully.
    let bid_payment_amount = test_utils::bid_payment_for_price(&book, 1, ask_size);
    let bid_payment = coin::mint_for_testing<USDC>(bid_payment_amount, scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, _) =
        book.place_limit_order_bid(bid_payment, ask_size, 1_000_000_000, scenario.ctx());
    bid_ticket_opt.destroy_none();
    bid_matched_base.burn_for_testing();
    bid_leftover_quote.burn_for_testing();

    let filled_events = event::events_by_type<tiny_clob::OrderFilled>();
    let (flb, fle, _, _, _, _, _) = filled_events[0].order_filled_fields_for_testing();
    assert!(flb == true_book_id, 15);
    assert!(fle == foreign_id, 16);

    let settled_events = event::events_by_type<tiny_clob::MakerFeeSettled>();
    let (stb, ste, _, _, _) = settled_events[0].maker_fee_settled_fields_for_testing();
    assert!(stb == true_book_id, 17);
    assert!(ste == foreign_id, 18);

    // OrderCancelled -- a second, never-filled resting ask, cancelled directly.
    let ask2_size = 50;
    let ask2_expected_quote_output = test_utils::ask_expected_output_for_price(&book, 1, ask2_size);
    let ask2_payment = coin::mint_for_testing<BTC>(ask2_size, scenario.ctx());
    let (ask2_ticket_opt, ask2_leftover_base, ask2_matched_quote, _) =
        book.place_limit_order_ask(ask2_payment, ask2_expected_quote_output, 1_000_000_000, scenario.ctx());
    ask2_leftover_base.burn_for_testing();
    ask2_matched_quote.burn_for_testing();
    let ask2_ticket = ask2_ticket_opt.destroy_some();

    let (cancel_base, cancel_quote) = book.cancel_order(ask2_ticket, scenario.ctx());
    cancel_base.burn_for_testing();
    cancel_quote.burn_for_testing();

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    let (clb, cle, _, _) = cancelled_events[0].order_cancelled_fields_for_testing();
    assert!(clb == true_book_id, 19);
    assert!(cle == foreign_id, 20);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
fun finalize_succeeds_and_sweeps_fee_accumulator_without_claim() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);

    let (fee_base, fee_quote) = generate_one_fee_bearing_fill(&mut scenario, &mut book, 10, 5);
    assert!(fee_base > 0, 0);
    let (fee_base_bal, fee_quote_bal) = book.fee_accumulator_balances();
    assert!(fee_base_bal == fee_base, 1);
    assert!(fee_quote_bal == fee_quote, 2);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    // Fee accumulator is still nonzero (never claimed) — `clob_admin_finalize`
    // now sweeps it automatically instead of requiring a prior claim.
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    assert!(fee_base_coin.burn_for_testing() == fee_base, 3);
    assert!(fee_quote_coin.burn_for_testing() == fee_quote, 4);

    let fees_claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(fees_claimed_events.length() == 1, 5);
    let (ev_book_id, _ev_enclosing_id, _ev_claimant, ev_base_amount, ev_quote_amount) =
        fees_claimed_events[0].fees_claimed_fields_for_testing();
    assert!(ev_book_id == deleted_id, 6);
    assert!(ev_base_amount == fee_base, 7);
    assert!(ev_quote_amount == fee_quote, 8);

    unit_test::destroy(deleted_id);
    scenario.end();
}

#[test]
fun finalize_succeeds_after_fees_claimed() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);

    let (fee_base, fee_quote) = generate_one_fee_bearing_fill(&mut scenario, &mut book, 10, 5);
    assert!(fee_base > 0, 0);

    // Claim first: drains the accumulator to (0, 0) before clob_admin_finalize.
    let (base_coin, quote_coin) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(base_coin.burn_for_testing() == fee_base, 1);
    assert!(quote_coin.burn_for_testing() == fee_quote, 2);
    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == 0, 3);
    assert!(fee_quote_after == 0, 4);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    // Fees were already claimed, so finalize sweeps nothing further.
    assert!(fee_base_coin.burn_for_testing() == 0, 62);
    assert!(fee_quote_coin.burn_for_testing() == 0, 63);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 5);
    let (deleted_book_id, _deleted_enclosing_id, deleted_base, deleted_quote) =
        deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_book_id == deleted_id, 6);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 60);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 61);

    // Exactly one `FeesClaimed` event total, from the up-front
    // `clob_admin_claim_fees` call above -- finalize's zero-fee auto-sweep
    // must not emit a spurious SECOND one (which a bare `>= 1` check would
    // miss).
    let fees_claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(fees_claimed_events.length() == 1, 64);

    scenario.end();
}

// --- Regression: claim-fees / drain-step ordering around a partially-filled
// --- resting order (see `clob_admin_drain_step`'s and `clob_admin_finalize`'s
// --- doc comments in `sources/tiny_clob.move`). Force-cancelling a
// --- partially-filled resting order via `clob_admin_drain_step` settles its
// --- maker-fee reserve into `book.fee_accumulator`, same as any other order
// --- conclusion. So if `clob_admin_claim_fees` is called BEFORE every drain
// --- step has run, a later step can re-credit the accumulator after it was
// --- already claimed down to zero. Under the OLD design this blocked
// --- `clob_admin_finalize` with `ENotFullyDrained` until fees were reclaimed;
// --- now `clob_admin_finalize` simply sweeps the residual itself. The three
// --- tests below pin down: finalize succeeding directly on a re-credited
// --- residual without any second claim (the exact scenario that used to
// --- trap an admin operationally), reclaiming as an equally-valid
// --- alternative, and the trivially-safe claim-after-drain ordering.

const CLAIM_DRAIN_ORDER_PRICE: u64 = 50_000;
const CLAIM_DRAIN_ORDER_SIZE: u64 = 200;
const CLAIM_DRAIN_ORDER_FILL: u64 = 100;

/// Rests an ask (maker side, fee-rate snapshot taken at rest time) and
/// partially fills it, leaving a genuine resting remainder whose maker-fee
/// reserve has not yet been released into `book.fee_accumulator` — that
/// only happens once the remainder is later drained or fully filled.
fun rest_and_partially_fill_ask(
    scenario: &mut ts::Scenario,
    book: &mut OrderBook<BTC, USDC>,
): u64 {
    scenario.next_tx(maker_a());
    let ticket = rest_ask(book, CLAIM_DRAIN_ORDER_PRICE, CLAIM_DRAIN_ORDER_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = ticket.ticket_order_id();
    unit_test::destroy(ticket);

    scenario.next_tx(taker());
    let quote_cost = book.bid_escrow_amount(CLAIM_DRAIN_ORDER_PRICE, CLAIM_DRAIN_ORDER_FILL);
    let payment = coin::mint_for_testing<USDC>(quote_cost, scenario.ctx());
    let (base_out, leftover, _) = book.place_market_order_bid(
        payment, 1_000_000_000, 0, CLAIM_DRAIN_ORDER_FILL, quote_cost, scenario.ctx(),
    );
    base_out.burn_for_testing();
    leftover.burn_for_testing();

    assert!(book.resting_order_escrow(tiny_clob::ask(), CLAIM_DRAIN_ORDER_PRICE, order_id).is_some(), 100);
    assert!(book.proceeds_contains_for_testing(order_id), 101);
    order_id
}

#[test]
fun finalize_recovers_after_reclaiming_fees_post_drain() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);

    rest_and_partially_fill_ask(&mut scenario, &mut book);

    // Taker fee on the 100 filled Base at 10 bps, ceiling-rounded:
    // ceil(100 * 10 / 10_000) = 1. The maker-fee reserve on the matched
    // Quote leg stays parked on the still-resting order itself until it is
    // drained, so the accumulator is (1, 0) here, not yet (1, 2_500).
    let (base_before, quote_before) = book.fee_accumulator_balances();
    assert!(base_before == 1, 0);
    assert!(quote_before == 0, 1);

    let (base_coin, quote_coin) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(base_coin.burn_for_testing() == 1, 2);
    assert!(quote_coin.burn_for_testing() == 0, 3);
    let (base_after_claim, quote_after_claim) = book.fee_accumulator_balances();
    assert!(base_after_claim == 0, 4);
    assert!(quote_after_claim == 0, 5);

    cap.clob_admin_retire(&mut book);
    // Force-cancels the still-resting 100-remaining ask, settling its
    // maker-fee reserve — ceil(50_000 * 100 * 5 / 10_000) = 2_500 — into
    // the accumulator, which is therefore nonzero again right after this.
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    let (base_after_drain, quote_after_drain) = book.fee_accumulator_balances();
    assert!(base_after_drain == 0, 6);
    assert!(quote_after_drain == 2_500, 7);

    // Reclaiming after the drain empties the accumulator again, unblocking
    // `clob_admin_finalize`.
    let (base_coin2, quote_coin2) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(base_coin2.burn_for_testing() == 0, 8);
    assert!(quote_coin2.burn_for_testing() == 2_500, 9);
    let (base_final, quote_final) = book.fee_accumulator_balances();
    assert!(base_final == 0, 10);
    assert!(quote_final == 0, 11);

    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    assert!(fee_base_coin.burn_for_testing() == 0, 12);
    assert!(fee_quote_coin.burn_for_testing() == 0, 13);
    unit_test::destroy(deleted_id);
    scenario.end();
}

/// Regression test for the reported operational trap: an admin calls
/// `clob_admin_claim_fees` before every `clob_admin_drain_step` has run, a
/// later drain step force-cancels a still-resting, previously-partially-
/// filled order and re-credits the maker-fee reserve into the accumulator,
/// and the admin then calls `clob_admin_finalize` directly — WITHOUT
/// reclaiming fees a second time. Under the old design this aborted with
/// `ENotFullyDrained` until fees were reclaimed; `clob_admin_finalize` must
/// now succeed unconditionally and return the correct residual fee amount
/// (2_500 Quote, 0 Base) as a swept coin.
#[test]
fun finalize_succeeds_directly_when_drain_reintroduces_reserve_after_claim() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);

    rest_and_partially_fill_ask(&mut scenario, &mut book);

    // Claim once, up front, before the resting remainder is ever drained.
    let (base_coin, quote_coin) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    base_coin.burn_for_testing();
    quote_coin.burn_for_testing();

    cap.clob_admin_retire(&mut book);
    // Drains the still-resting order, which re-credits the maker-fee
    // reserve (2_500 Quote) into the accumulator this claim already
    // thought was empty.
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    let (fee_base, fee_quote) = book.fee_accumulator_balances();
    assert!(fee_base == 0, 0);
    assert!(fee_quote == 2_500, 1);

    // The accumulator is nonzero again, but `clob_admin_finalize` sweeps it
    // itself now — no re-claim required, and no abort.
    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    assert!(fee_base_coin.burn_for_testing() == 0, 2);
    assert!(fee_quote_coin.burn_for_testing() == 2_500, 3);

    // Two `FeesClaimed` events total: one from the up-front
    // `clob_admin_claim_fees` call above (base=1, quote=0), one from
    // `clob_admin_finalize`'s own sweep of the re-credited residual.
    let fees_claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(fees_claimed_events.length() == 2, 4);
    let (ev_book_id, _ev_enclosing_id, _ev_claimant, ev_base_amount, ev_quote_amount) =
        fees_claimed_events[1].fees_claimed_fields_for_testing();
    assert!(ev_book_id == deleted_id, 5);
    assert!(ev_base_amount == 0, 6);
    assert!(ev_quote_amount == 2_500, 7);

    unit_test::destroy(deleted_id);
    scenario.end();
}

#[test]
fun finalize_succeeds_when_fees_claimed_after_all_drain_steps() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);

    rest_and_partially_fill_ask(&mut scenario, &mut book);

    cap.clob_admin_retire(&mut book);
    // Drain first, then claim: still a perfectly valid ordering, though no
    // longer a required one.
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    let (fee_base, fee_quote) = book.fee_accumulator_balances();
    assert!(fee_base == 1, 0);
    assert!(fee_quote == 2_500, 1);

    let (base_coin, quote_coin) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(base_coin.burn_for_testing() == 1, 2);
    assert!(quote_coin.burn_for_testing() == 2_500, 3);
    let (fee_base_after, fee_quote_after) = book.fee_accumulator_balances();
    assert!(fee_base_after == 0, 4);
    assert!(fee_quote_after == 0, 5);

    let (deleted_id, fee_base_coin, fee_quote_coin) = cap.clob_admin_finalize(book, scenario.ctx());
    assert!(fee_base_coin.burn_for_testing() == 0, 6);
    assert!(fee_quote_coin.burn_for_testing() == 0, 7);
    unit_test::destroy(deleted_id);
    scenario.end();
}

// --- `retiring` is a sticky, separate flag from `paused` (see `OrderBook`
// --- doc comment): `clob_admin_retire` sets both `paused` and `retiring`
// --- to `true`, but `retiring` is never cleared by any function.
// --- `clob_admin_unpause_book` now refuses to run on a retiring book —
// --- there is no way to reverse retirement once started, so allowing an
// --- unpause to clear `paused` while `retiring` stayed `true` would let
// --- new orders resume on a book that's supposedly being torn down.

#[test]
#[expected_failure(abort_code = 18, location = tiny_clob)] // tiny_clob::EBookRetiring
fun unpause_after_retire_aborts_with_ebookretiring() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    cap.clob_admin_retire(&mut book);
    // Retiring is sticky and irreversible: unpausing a retiring book must
    // abort instead of un-retiring it.
    cap.clob_admin_unpause_book(&mut book);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun retire_then_drain_step_succeeds_and_retiring_stays_set() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    cap.clob_admin_retire(&mut book);
    // A Move test aborts on its first failing call, so this can't chain an
    // actual failed unpause attempt before draining (a prior name/comment
    // here claimed exactly that, but the body never called `unpause` at
    // all) -- what this test actually pins down is simpler: after
    // `clob_admin_retire`, `clob_admin_drain_step` succeeds and `retiring`
    // remains `true` throughout.
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    assert!(book.is_book_retiring(), 0);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// This is the property that had zero test coverage before `retiring` was
// split out from `paused`: a plain, reversible `clob_admin_pause_book` call
// alone — never having called `clob_admin_retire` — must NOT unlock the
// destructive `clob_admin_drain_step` force-drain path.
#[test]
#[expected_failure(abort_code = 6, location = tiny_clob)] // tiny_clob::ENotRetiring
fun drain_step_aborts_when_only_paused_not_retiring() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = book.next_order_id();
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, other(), size, option::none(), option::some(escrow), 0);
    book.insert_resting_order_for_testing(true, price, order, scenario.ctx());

    cap.clob_admin_pause_book(&mut book);
    assert!(book.is_paused(), 0);
    assert!(!book.is_book_retiring(), 1);
    // Plain pause alone must not unlock draining.
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun pause_then_unpause_emit_paused_and_unpaused_events() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    cap.clob_admin_pause_book(&mut book);
    assert!(book.is_paused(), 0);

    let paused_events = event::events_by_type<tiny_clob::Paused>();
    assert!(paused_events.length() == 1, 1);
    let (ev_paused_book_id, ev_paused_enclosing_id) = paused_events[0].paused_fields_for_testing();
    assert!(ev_paused_book_id == book.book_id(), 20);
    assert!(ev_paused_enclosing_id == book.enclosing_object_id_for_testing(), 2);

    cap.clob_admin_unpause_book(&mut book);
    assert!(!book.is_paused(), 3);

    let unpaused_events = event::events_by_type<tiny_clob::Unpaused>();
    assert!(unpaused_events.length() == 1, 4);
    let (ev_unpaused_book_id, ev_unpaused_enclosing_id) = unpaused_events[0].unpaused_fields_for_testing();
    assert!(ev_unpaused_book_id == book.book_id(), 50);
    assert!(ev_unpaused_enclosing_id == book.enclosing_object_id_for_testing(), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 8, location = tiny_clob)] // tiny_clob::ETakerFeeRateTooHigh
fun taker_fee_above_bound_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, 11);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 9, location = tiny_clob)] // tiny_clob::EMakerFeeRateTooHigh
fun maker_fee_above_bound_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_maker_fee(&mut book, 6);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_fees_drains_full_accumulator() {
    // Two real crossing fills, each producing a genuine taker fee on a
    // different leg (per `OrderExecuted.taker_fee_amount`'s doc comment: a
    // bid-side taker's fee is denominated in Base, an ask-side taker's fee
    // in Quote), so the accumulator ends up nonzero on both legs without
    // any test-only backdoor.
    //
    // Both legs below are seeded (via `rest_ask`/`rest_bid`) and then
    // crossed using the same `scenario.ctx()`, i.e. the admin address acts
    // as both the resting maker and the crossing taker on each leg. This
    // relies on self-trading being permitted by the book -- an intentional
    // test simplification to produce genuine fee accrual without a second
    // party, not a claim about production self-trading semantics.
    let ask_price = 50_000;
    let ask_size = 2_000;
    let bid_price = 50_000;
    let bid_size = 3_000;
    let taker_fee_bps = 10;

    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, taker_fee_bps);

    // Leg 1: rest an ask, then fully cross it with a bid taker.
    // taker_fee_base = ceil(ask_size * taker_fee_bps / 10_000)
    //                = ceil(2_000 * 10 / 10_000) = ceil(2) = 2.
    let ask_ticket = rest_ask(&mut book, ask_price, ask_size, 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);
    let bid_payment = coin::mint_for_testing<USDC>(
        book.bid_escrow_amount(ask_price, ask_size),
        scenario.ctx(),
    );
    let (bid_ticket_opt, matched_base, leftover_quote, _) =
        book.place_limit_order_bid(bid_payment, ask_size, 1_000_000_000, scenario.ctx());
    bid_ticket_opt.destroy_none();
    matched_base.burn_for_testing();
    leftover_quote.burn_for_testing();

    // Leg 2: rest a bid, then fully cross it with an ask taker. This book's
    // price_scale is 1 (base/quote decimals 0, precision 0), so the fully
    // matched quote leg is exactly price * size = 50_000 * 3_000 =
    // 150_000_000.
    // taker_fee_quote = ceil(150_000_000 * 10 / 10_000)
    //                 = ceil(1_500_000_000 / 10_000) = ceil(150_000) = 150_000.
    let bid_ticket = rest_bid(&mut book, bid_price, bid_size, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);
    let ask_payment = coin::mint_for_testing<BTC>(bid_size, scenario.ctx());
    let expected_quote_output = test_utils::ask_expected_output_for_price(&book, bid_price, bid_size);
    let (ask_ticket_opt, leftover_base, matched_quote, _) =
        book.place_limit_order_ask(ask_payment, expected_quote_output, 1_000_000_000, scenario.ctx());
    ask_ticket_opt.destroy_none();
    leftover_base.burn_for_testing();
    matched_quote.burn_for_testing();

    let expected_base_fee = 2;
    let expected_quote_fee = 150_000;

    let (before_base, before_quote) = book.fee_accumulator_balances();
    assert!(before_base == expected_base_fee, 0);
    assert!(before_quote == expected_quote_fee, 1);

    let (base_coin, quote_coin) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(base_coin.burn_for_testing() == expected_base_fee, 2);
    assert!(quote_coin.burn_for_testing() == expected_quote_fee, 3);

    let (after_base, after_quote) = book.fee_accumulator_balances();
    assert!(after_base == 0, 4);
    assert!(after_quote == 0, 5);

    let claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(claimed_events.length() == 1, 6);
    let (ev_book_id, ev_enclosing_id, ev_claimant, ev_base_amount, ev_quote_amount) =
        claimed_events[0].fees_claimed_fields_for_testing();
    assert!(ev_claimant == admin(), 7);
    assert!(ev_book_id == book.book_id(), 80);
    assert!(ev_enclosing_id == book.enclosing_object_id_for_testing(), 8);
    assert!(ev_base_amount == expected_base_fee, 9);
    assert!(ev_quote_amount == expected_quote_fee, 10);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_fees_zero_balance_emits_no_event() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let (base_coin, quote_coin) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(base_coin.burn_for_testing() == 0, 0);
    assert!(quote_coin.burn_for_testing() == 0, 1);
    let claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(claimed_events.length() == 0, 2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun claim_fees_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    let (base_coin, quote_coin) = cap2.clob_admin_claim_fees(&mut book1, scenario.ctx());
    base_coin.burn_for_testing();
    quote_coin.burn_for_testing();
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

// --- EWrongClobAdminCap coverage for the remaining ClobAdminCap-gated
// --- functions. `clob_admin_finalize` is already covered above
// --- (`finalize_rejects_wrong_cap`); each of the other six functions gets
// --- its own test here, using a cap minted for a completely separate book.
// --- `assert_clob_admin` runs before any other check inside each of these
// --- functions (confirmed by reading `sources/tiny_clob.move`), so the
// --- fixture arguments below are deliberately minimal/arbitrary — the cap
// --- mismatch fires first regardless of their values.

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun pause_book_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    cap2.clob_admin_pause_book(&mut book1);
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun unpause_book_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    // book1 is not even paused — the cap check must fire before that state
    // is ever consulted.
    cap2.clob_admin_unpause_book(&mut book1);
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun set_taker_fee_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    // rate_bps = 0 is always within bounds, so a mismatched-cap abort here
    // can only be EWrongClobAdminCap, never ETakerFeeRateTooHigh.
    cap2.clob_admin_set_taker_fee(&mut book1, 0);
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun set_maker_fee_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    // rate_bps = 0 is always within bounds, so a mismatched-cap abort here
    // can only be EWrongClobAdminCap, never EMakerFeeRateTooHigh.
    cap2.clob_admin_set_maker_fee(&mut book1, 0);
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun set_price_band_factor_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    // option::none() never trips EZeroPriceBandFactor, so a mismatched-cap
    // abort here can only be EWrongClobAdminCap.
    cap2.clob_admin_set_price_band_factor(&mut book1, option::none());
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun cancel_order_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    // book1 has no such resting order at all — the cap check must fire
    // before the (side, price, order_id) lookup is ever attempted.
    cap2.admin_redeem_ticket(&mut book1, true, 1, 1, scenario.ctx());
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun drain_step_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    // book1 was never retired — the cap check must fire before ENotRetiring
    // is ever consulted.
    cap2.clob_admin_drain_step(&mut book1, 10, scenario.ctx());
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun retire_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    // cap2 belongs to book2, not book1 — must abort with EWrongClobAdminCap
    // before book1's paused/retiring flags are ever touched.
    cap2.clob_admin_retire(&mut book1);
    unit_test::destroy(book1);
    unit_test::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

// --- `admin_redeem_ticket`'s order-cancellation and proceeds-sweep halves are both documented as
// --- silent no-ops when the given key doesn't correspond to any actual
// --- entry (a nonexistent resting order for the former, a pooled-proceeds
// --- entry that was never credited for the latter): no abort, and no
// --- domain event fires. Confirmed against each function's current doc
// --- comment and body in `sources/tiny_clob.move` before writing these.

#[test]
fun cancel_order_on_nonexistent_order_is_silent_noop() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // Freshly-constructed, empty book: no resting orders exist at all, so
    // this (side, price, order_id) triple cannot match anything.
    cap.admin_redeem_ticket(&mut book, true, default_price(), 1, scenario.ctx());

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 0, 0);
    let settled_events = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled_events.length() == 0, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// `find_and_remove_order`'s "level exists but this order_id isn't in it"
// branch (sources/price_tree.move) is never exercised by the no-op test
// above, since that test's price level doesn't exist at all. Here two other
// makers' bids genuinely rest at the target price, so a bug that
// unconditionally removed the tree leaf (instead of gating removal on
// whether the order was actually found) would delete a price level still
// holding two live escrowed orders.
#[test]
fun cancel_order_on_nonexistent_order_id_at_live_price_level_is_silent_noop() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let ticket_a = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    scenario.next_tx(maker_b());
    let ticket_b = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());

    assert!(book.bids_size_for_testing() == 1, 0);
    let order_id_a = ticket_a.ticket_order_id();
    let order_id_b = ticket_b.ticket_order_id();
    let escrow_a_before = book.resting_order_escrow(true, default_price(), order_id_a);
    let escrow_b_before = book.resting_order_escrow(true, default_price(), order_id_b);
    assert!(escrow_a_before.is_some(), 1);
    assert!(escrow_b_before.is_some(), 2);

    // 9999 is neither `order_id_a` nor `order_id_b`, but `default_price()`
    // is a genuine, live price level.
    cap.admin_redeem_ticket(&mut book, true, default_price(), 9999, scenario.ctx());

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 0, 3);
    let settled_events = event::events_by_type<tiny_clob::MakerFeeSettled>();
    assert!(settled_events.length() == 0, 4);

    // The price level must still exist, untouched, with both original
    // orders still resting and findable.
    assert!(book.bids_size_for_testing() == 1, 5);
    assert!(book.resting_order_escrow(true, default_price(), order_id_a).is_some(), 6);
    assert!(book.resting_order_escrow(true, default_price(), order_id_b).is_some(), 7);

    unit_test::destroy(ticket_a);
    unit_test::destroy(ticket_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun admin_redeem_ticket_with_no_pooled_entry_is_silent_noop() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    // No order has ever been filled/credited on this book, so `order_id = 1`
    // has no pooled proceeds entry whatsoever, nor any resting order at
    // `(true, default_price(), 1)`. The retire call below is a harmless
    // no-op setup step, not a requirement of admin_redeem_ticket itself.
    cap.clob_admin_retire(&mut book);
    cap.admin_redeem_ticket(&mut book, true, default_price(), 1, scenario.ctx());

    let claimed_events = event::events_by_type<ProceedsClaimed>();
    assert!(claimed_events.length() == 0, 0);
    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 0, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

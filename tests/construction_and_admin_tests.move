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
    Self, admin, other, taker, maker_a, maker_b, maker_c, min_size, max_min_size,
    default_price, default_size, shortfall_price, new_book, destroy_book_and_cap,
    rest_bid, rest_ask, shortfall_book, assert_extremes_and_adjacent_ticks,
};


public struct CapHolder has key, store {
    id: UID,
    cap: ClobAdminCap,
}

// `clob_admin_finalize`'s precondition assert now also checks the book's
// fee_accumulator is empty, so an unclaimed-fees book fails fast with the
// module's own clear `ENotFullyDrained` instead of aborting deep inside
// `balance::destroy_zero` with a generic Sui-framework-level abort. The
// clob_admin_finalize tests above only ever exercise resting-order-only
// scenarios where fee_accumulator stays (0, 0), so that path is never
// actually hit there. These two tests close that gap: the first generates
// a genuine fee-bearing fill, retires+drains the book, and confirms
// clob_admin_finalize aborts on the unclaimed fees; the second repeats the setup but
// claims the fees first, confirming the claim-then-clob_admin_finalize path succeeds.

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

    let taker_fee_base = (FINALIZE_FEES_SIZE * taker_fee_bps) / 10_000;
    let maker_fee_quote = (quote_cost * maker_fee_bps) / 10_000;
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
    let (book, cap) = tiny_clob::new<BTC, USDC>(0, 0, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob)] // tiny_clob::EMinSizeTooLarge
fun new_min_size_too_large_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = tiny_clob::new<BTC, USDC>(max_min_size() + 1, 0, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_size_at_max_boundary_succeeds() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = tiny_clob::new<BTC, USDC>(max_min_size(), 0, 0, 0, 19, 1, scenario.ctx());
    assert!(book.min_size() == max_min_size(), 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun two_books_identical_types_fully_independent_construction() {
    let mut scenario = ts::begin(admin());
    let (mut book1, cap1) = new_book(&mut scenario);
    let (mut book2, cap2) = new_book(&mut scenario);

    assert!(book1.id_for_testing() != book2.id_for_testing(), 0);
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
    let book_id = book.id_for_testing();

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
    // with the correct `cap_id`/`for_book`.
    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    let deleted_id = cap.clob_admin_finalize(book);
    assert!(deleted_id == book_id, 3);

    let discarded_events = event::events_by_type<tiny_clob::ClobAdminCapDiscarded>();
    assert!(discarded_events.length() == 1, 0);
    let (event_cap_id, event_for_book) = discarded_events[0].clob_admin_cap_discarded_fields_for_testing();
    assert!(event_cap_id == cap_id, 1);
    assert!(event_for_book == book_id, 2);

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
    let book_id = book.id_for_testing();
    book.set_book_version_for_testing(0);
    // No explicit migration call needed — any ordinary version-guarded
    // function transparently upgrades the book's stored version in place,
    // and emits a BookVersionUpgraded observability event at the moment of
    // the bump.
    cap.clob_admin_pause_book(&mut book);
    assert!(book.book_version() == 1, 0);

    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 1, 1);
    let (ev_book_id, ev_from, ev_to) = upgraded_events[0].book_version_upgraded_fields_for_testing();
    assert!(ev_book_id == book_id, 2);
    assert!(ev_from == 0, 3);
    assert!(ev_to == 1, 4);

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

#[test]
fun fee_setters_bounds_and_events() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = book.id_for_testing();

    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);
    let (taker, maker) = book.fee_config();
    assert!(taker == 10, 0);
    assert!(maker == 5, 1);

    let taker_events = event::events_by_type<tiny_clob::TakerFeeSet>();
    let maker_events = event::events_by_type<tiny_clob::MakerFeeSet>();
    assert!(taker_events.length() == 1, 2);
    assert!(maker_events.length() == 1, 3);
    let (ev_book, ev_rate) = taker_events[0].taker_fee_set_fields_for_testing();
    assert!(ev_book == book_id, 4);
    assert!(ev_rate == 10, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun drain_step_before_retire_aborts() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun finalize_before_retire_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);
    let deleted_id = cap.clob_admin_finalize(book);
    sui::test_utils::destroy(deleted_id);
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
    let deleted_id = cap2.clob_admin_finalize(book1);
    sui::test_utils::destroy(deleted_id);
    sui::test_utils::destroy(book2);
    sui::test_utils::destroy(_cap1);
    scenario.end();
}

#[test]
#[expected_failure]
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
    let deleted_id = cap.clob_admin_finalize(book);
    sui::test_utils::destroy(deleted_id);
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

    // Repeatable, bounded max_items — one call with max_items = 0 is a no-op.
    cap.clob_admin_drain_step(&mut book, 0, scenario.ctx());
    assert!(book.bids_size_for_testing() == 1, 1);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    assert!(book.bids_size_for_testing() == 0, 2);

    let deleted_id = cap.clob_admin_finalize(book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 3);
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_order_book_id == deleted_id, 4);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 40);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 41);

    scenario.end();
}

// `clob_admin_finalize`'s return value must be the book's true,
// unforgeable object id (`object::uid_to_inner(&book.id)`), NOT
// `event_id` — which is caller-controllable via `event_id_override` and
// must never be trusted for identifying which book was just deleted.
// This test constructs a book with an override that differs from its own
// id, then confirms the two are correctly decoupled: the function's
// return value tracks the book's true id, while the emitted
// `OrderBookDeleted` event's `order_book_id` field tracks the override.
#[test]
fun clob_admin_finalize_returns_true_book_id_not_event_id_override() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let override_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new_with_event_id_override<BTC, USDC>(
        min_size(), 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx(),
    );

    let true_book_id = book.id_for_testing();
    assert!(true_book_id != override_id, 0);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());

    let deleted_id = cap.clob_admin_finalize(book);
    assert!(deleted_id == true_book_id, 1);

    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 2);
    let (deleted_order_book_id, _, _) =
        deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_order_book_id == override_id, 3);
    assert!(deleted_order_book_id != deleted_id, 4);

    wrapper_uid.delete();
    scenario.end();
}

// `BookVersionUpgraded.book_id` and `ClobAdminCapDiscarded.for_book` used to
// stamp the book's true, unforgeable id while every other event in this
// module stamps `event_id` -- an inconsistency that broke correlation for
// any indexer joining on `order_book_id`/`for_book` for a book constructed
// with an override. Both now stamp `event_id` like every other event.
#[test]
fun book_version_upgraded_and_cap_discarded_stamp_event_id_override_not_true_id() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let override_id = wrapper_uid.uid_to_inner();
    let (mut book, cap) = tiny_clob::new_with_event_id_override<BTC, USDC>(
        min_size(), 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx(),
    );
    let true_book_id = book.id_for_testing();
    assert!(true_book_id != override_id, 0);

    book.set_book_version_for_testing(0);
    cap.clob_admin_pause_book(&mut book);

    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 1, 1);
    let (ev_book_id, _, _) = upgraded_events[0].book_version_upgraded_fields_for_testing();
    assert!(ev_book_id == override_id, 2);
    assert!(ev_book_id != true_book_id, 3);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 100, scenario.ctx());
    let deleted_id = cap.clob_admin_finalize(book);
    assert!(deleted_id == true_book_id, 4);

    let discarded_events = event::events_by_type<tiny_clob::ClobAdminCapDiscarded>();
    assert!(discarded_events.length() == 1, 5);
    let (_, ev_for_book) = discarded_events[0].clob_admin_cap_discarded_fields_for_testing();
    assert!(ev_for_book == override_id, 6);
    assert!(ev_for_book != true_book_id, 7);

    wrapper_uid.delete();
    scenario.end();
}

#[test, expected_failure(abort_code = 7, location = tiny_clob)] // tiny_clob::ENotFullyDrained
fun finalize_aborts_when_fee_accumulator_nonzero() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);
    cap.clob_admin_set_taker_fee(&mut book, 10);
    cap.clob_admin_set_maker_fee(&mut book, 5);

    let (fee_base, _fee_quote) = generate_one_fee_bearing_fill(&mut scenario, &mut book, 10, 5);
    assert!(fee_base > 0, 0);
    let (fee_base_bal, _) = book.fee_accumulator_balances();
    assert!(fee_base_bal == fee_base, 1);

    cap.clob_admin_retire(&mut book);
    cap.clob_admin_drain_step(&mut book, 10, scenario.ctx());
    // Fee accumulator is still nonzero (never claimed) — this aborts.
    let deleted_id = cap.clob_admin_finalize(book);

    sui::test_utils::destroy(deleted_id);
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
    let deleted_id = cap.clob_admin_finalize(book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 5);
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        deleted_events[0].order_book_deleted_fields_for_testing();
    assert!(deleted_order_book_id == deleted_id, 6);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 60);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 61);

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
fun drain_step_remains_callable_after_failed_unpause_attempt() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    cap.clob_admin_retire(&mut book);
    // An unpause attempt against a retiring book aborts before mutating
    // anything (see unpause_after_retire_aborts_with_ebookretiring above),
    // so `retiring` stays sticky regardless of any such attempt —
    // clob_admin_drain_step remains callable exactly as if no unpause had
    // ever been attempted.
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
    let base_amount = 500;
    let quote_amount = 20_000;
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    book.credit_fee_accumulator_for_testing(
        balance::create_for_testing<BTC>(base_amount),
        balance::create_for_testing<USDC>(quote_amount),
    );

    let (before_base, before_quote) = book.fee_accumulator_balances();
    assert!(before_base == base_amount, 0);
    assert!(before_quote == quote_amount, 1);

    let (base_coin, quote_coin) = cap.clob_admin_claim_fees(&mut book, scenario.ctx());
    assert!(base_coin.burn_for_testing() == base_amount, 2);
    assert!(quote_coin.burn_for_testing() == quote_amount, 3);

    let (after_base, after_quote) = book.fee_accumulator_balances();
    assert!(after_base == 0, 4);
    assert!(after_quote == 0, 5);

    let claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(claimed_events.length() == 1, 6);

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
#[expected_failure]
fun claim_fees_rejects_wrong_cap() {
    let mut scenario = ts::begin(admin());
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    let (base_coin, quote_coin) = cap2.clob_admin_claim_fees(&mut book1, scenario.ctx());
    base_coin.burn_for_testing();
    quote_coin.burn_for_testing();
    sui::test_utils::destroy(book1);
    sui::test_utils::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

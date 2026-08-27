#[test_only]
module tiny_clob::tiny_clob_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC};

const ADMIN: address = @0xA11CE;
const OTHER: address = @0xB0B;
const TAKER: address = @0x2002;
const MAKER_A: address = @0xA001;
const MAKER_B: address = @0xA002;
const MAKER_C: address = @0xA003;

const MIN_SIZE: u64 = 100;
const MAX_MIN_SIZE: u64 = 1_000_000_000_000_000;

fun new_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    tiny_clob::new<BTC, USDC>(MIN_SIZE, scenario.ctx())
}

fun destroy_book_and_cap(book: OrderBook<BTC, USDC>, cap: ClobAdminCap) {
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
}

/// Rests a bid via `place_limit_order_bid`, discarding the matched/leftover
/// coin legs and returning only the resulting ticket — for call sites that
/// only need the ticket and have no assertions on the trade legs themselves.
fun rest_bid(
    book: &mut OrderBook<BTC, USDC>,
    price: u64,
    size: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): OrderTicket {
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(price, size), ctx);
    let (ticket, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(book, price, size, payment, max_fills, ctx);
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);
    ticket
}

/// Mirrors `rest_bid` for the ask side.
fun rest_ask(
    book: &mut OrderBook<BTC, USDC>,
    price: u64,
    size: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): OrderTicket {
    let payment = coin::mint_for_testing<BTC>(size, ctx);
    let (ticket, leftover_base, matched_quote, _) =
        tiny_clob::place_limit_order_ask(book, price, size, payment, max_fills, ctx);
    coin::burn_for_testing(leftover_base);
    coin::burn_for_testing(matched_quote);
    ticket
}

#[test]
fun new_succeeds_with_no_capability_argument_and_no_registry_interaction() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);

    assert!(tiny_clob::min_size(&book) == MIN_SIZE, 1);
    assert!(!tiny_clob::is_paused(&book), 2);
    assert!(tiny_clob::clob_admin_cap_id_for_testing(&book) == object::id(&cap), 3);
    let (taker_bps, maker_bps) = tiny_clob::fee_config(&book);
    assert!(taker_bps == 0, 4);
    assert!(maker_bps == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 1, location = tiny_clob)] // tiny_clob::EZeroMinSize
fun new_zero_min_size_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(0, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob)] // tiny_clob::EMinSizeTooLarge
fun new_min_size_too_large_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(MAX_MIN_SIZE + 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_size_at_max_boundary_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(MAX_MIN_SIZE, scenario.ctx());
    assert!(tiny_clob::min_size(&book) == MAX_MIN_SIZE, 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun two_books_identical_types_fully_independent_construction() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book1, cap1) = new_book(&mut scenario);
    let (mut book2, cap2) = new_book(&mut scenario);

    assert!(tiny_clob::id_for_testing(&book1) != tiny_clob::id_for_testing(&book2), 0);
    assert!(object::id(&cap1) != object::id(&cap2), 1);

    tiny_clob::clob_admin_set_taker_fee(&cap1, &mut book1, 5);
    let (taker1, _) = tiny_clob::fee_config(&book1);
    let (taker2, _) = tiny_clob::fee_config(&book2);
    assert!(taker1 == 5, 2);
    assert!(taker2 == 0, 3);

    destroy_book_and_cap(book1, cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

public struct CapHolder has key, store {
    id: UID,
    cap: ClobAdminCap,
}

#[test]
fun clob_admin_cap_store_and_discard() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    // Demonstrates `store`-ability directly: holds the cap as a plain
    // field of a test-only wrapper struct.
    let holder = CapHolder { id: object::new(scenario.ctx()), cap };
    let CapHolder { id, cap } = holder;
    id.delete();

    let cap_id = object::id(&cap);

    // The cap can now only be destroyed by consuming it inside
    // `clob_admin_finalize` — there is no standalone discard function
    // anymore. Run a full retire -> drain -> clob_admin_finalize sequence and
    // confirm `ClobAdminCapDiscarded` fires from inside `clob_admin_finalize`
    // with the correct `cap_id`/`for_book`.
    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 100, scenario.ctx());
    let deleted_id = tiny_clob::clob_admin_finalize(cap, book);
    assert!(deleted_id == book_id, 3);

    let discarded_events = event::events_by_type<tiny_clob::ClobAdminCapDiscarded>();
    assert!(discarded_events.length() == 1, 0);
    let (event_cap_id, event_for_book) = tiny_clob::clob_admin_cap_discarded_fields_for_testing(
        &discarded_events[0],
    );
    assert!(event_cap_id == cap_id, 1);
    assert!(event_for_book == book_id, 2);

    scenario.end();
}

#[test]
fun version_guard_view_functions_do_not_abort_on_stale_version() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_book_version_for_testing(&mut book, 999);

    // The five pure-read view functions never assert the version guard.
    let (_taker, _maker) = tiny_clob::fee_config(&book);
    let (_base, _quote) = tiny_clob::fee_accumulator_balances(&book);
    let _ = tiny_clob::is_book_paused(&book);
    let _ = tiny_clob::best_bid(&book);
    let _ = tiny_clob::best_ask(&book);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 5, location = tiny_clob)] // tiny_clob::ENewVersionMismatch
fun version_guard_pause_aborts_on_future_version() {
    // A `version` AHEAD of CURRENT_VERSION means this package build doesn't
    // yet understand a `version` the book already carries — the one case
    // `assert_book_version` still refuses to silently paper over.
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_book_version_for_testing(&mut book, 999);
    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun version_auto_upgrades_when_stale_lower_than_current() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);
    tiny_clob::set_book_version_for_testing(&mut book, 0);
    // No explicit migration call needed — any ordinary version-guarded
    // function transparently upgrades the book's stored version in place,
    // and emits a BookVersionUpgraded observability event at the moment of
    // the bump.
    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    assert!(tiny_clob::book_version_is_for_testing(&book, 1), 0);

    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 1, 1);
    let (ev_book_id, ev_from, ev_to) = tiny_clob::book_version_upgraded_fields_for_testing(&upgraded_events[0]);
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
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    let upgraded_events = event::events_by_type<tiny_clob::BookVersionUpgraded>();
    assert!(upgraded_events.length() == 0, 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun fee_setters_bounds_and_events() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, 10);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, 5);
    let (taker, maker) = tiny_clob::fee_config(&book);
    assert!(taker == 10, 0);
    assert!(maker == 5, 1);

    let taker_events = event::events_by_type<tiny_clob::TakerFeeSet>();
    let maker_events = event::events_by_type<tiny_clob::MakerFeeSet>();
    assert!(taker_events.length() == 1, 2);
    assert!(maker_events.length() == 1, 3);
    let (ev_book, ev_rate) = tiny_clob::taker_fee_set_fields_for_testing(&taker_events[0]);
    assert!(ev_book == book_id, 4);
    assert!(ev_rate == 10, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun drain_step_before_retire_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 10, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun finalize_before_retire_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);
    let deleted_id = tiny_clob::clob_admin_finalize(cap, book);
    sui::test_utils::destroy(deleted_id);
    scenario.end();
}

// `clob_admin_finalize` now takes `cap` by value, but must still reject a
// cap minted for a different book — the by-value signature change must not
// weaken this authentication check.
#[test]
#[expected_failure(abort_code = 4, location = tiny_clob)] // tiny_clob::EWrongClobAdminCap
fun finalize_rejects_wrong_cap() {
    let mut scenario = ts::begin(ADMIN);
    let (book1, _cap1) = new_book(&mut scenario);
    let (mut book2, cap2) = new_book(&mut scenario);
    tiny_clob::clob_admin_retire(&cap2, &mut book2);
    tiny_clob::clob_admin_drain_step(&cap2, &mut book2, 10, scenario.ctx());

    // cap2 belongs to book2, not book1 — must abort with EWrongClobAdminCap.
    let deleted_id = tiny_clob::clob_admin_finalize(cap2, book1);
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
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    tiny_clob::clob_admin_retire(&cap, &mut book);
    let deleted_id = tiny_clob::clob_admin_finalize(cap, book);
    sui::test_utils::destroy(deleted_id);
    scenario.end();
}

#[test]
fun deletion_lifecycle_retire_drain_finalize_succeeds() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    tiny_clob::clob_admin_retire(&cap, &mut book);
    let retired_events = event::events_by_type<tiny_clob::OrderBookRetired>();
    assert!(retired_events.length() == 1, 0);

    // Repeatable, bounded max_items — one call with max_items = 0 is a no-op.
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 0, scenario.ctx());
    assert!(tiny_clob::bids_size_for_testing(&book) == 1, 1);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 100, scenario.ctx());
    assert!(tiny_clob::bids_size_for_testing(&book) == 0, 2);

    let deleted_id = tiny_clob::clob_admin_finalize(cap, book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 3);
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        tiny_clob::order_book_deleted_fields_for_testing(&deleted_events[0]);
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
    let mut scenario = ts::begin(ADMIN);
    let wrapper_uid = object::new(scenario.ctx());
    let override_id = object::uid_to_inner(&wrapper_uid);
    let (mut book, cap) = tiny_clob::new_with_event_id_override<BTC, USDC>(
        MIN_SIZE, &wrapper_uid, scenario.ctx(),
    );

    let true_book_id = tiny_clob::id_for_testing(&book);
    assert!(true_book_id != override_id, 0);

    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 100, scenario.ctx());

    let deleted_id = tiny_clob::clob_admin_finalize(cap, book);
    assert!(deleted_id == true_book_id, 1);

    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 2);
    let (deleted_order_book_id, _, _) =
        tiny_clob::order_book_deleted_fields_for_testing(&deleted_events[0]);
    assert!(deleted_order_book_id == override_id, 3);
    assert!(deleted_order_book_id != deleted_id, 4);

    object::delete(wrapper_uid);
    scenario.end();
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

    let quote_cost = tiny_clob::bid_escrow_amount(FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE);
    let bid_ticket = rest_bid(book, FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let taker_fee_base = (FINALIZE_FEES_SIZE * taker_fee_bps) / 10_000;
    let maker_fee_quote = (quote_cost * maker_fee_bps) / 10_000;
    (taker_fee_base, maker_fee_quote)
}

#[test, expected_failure(abort_code = 7, location = tiny_clob)] // tiny_clob::ENotFullyDrained
fun finalize_aborts_when_fee_accumulator_nonzero() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, 10);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, 5);

    let (fee_base, _fee_quote) = generate_one_fee_bearing_fill(&mut scenario, &mut book, 10, 5);
    assert!(fee_base > 0, 0);
    let (fee_base_bal, _) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_bal == fee_base, 1);

    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 10, scenario.ctx());
    // Fee accumulator is still nonzero (never claimed) — this aborts.
    let deleted_id = tiny_clob::clob_admin_finalize(cap, book);

    sui::test_utils::destroy(deleted_id);
    scenario.end();
}

#[test]
fun finalize_succeeds_after_fees_claimed() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, 10);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, 5);

    let (fee_base, fee_quote) = generate_one_fee_bearing_fill(&mut scenario, &mut book, 10, 5);
    assert!(fee_base > 0, 0);

    // Claim first: drains the accumulator to (0, 0) before clob_admin_finalize.
    let (base_coin, quote_coin) = tiny_clob::clob_admin_claim_fees(&cap, &mut book, scenario.ctx());
    assert!(coin::burn_for_testing(base_coin) == fee_base, 1);
    assert!(coin::burn_for_testing(quote_coin) == fee_quote, 2);
    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after == 0, 3);
    assert!(fee_quote_after == 0, 4);

    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 10, scenario.ctx());
    let deleted_id = tiny_clob::clob_admin_finalize(cap, book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 5);
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        tiny_clob::order_book_deleted_fields_for_testing(&deleted_events[0]);
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
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    tiny_clob::clob_admin_retire(&cap, &mut book);
    // Retiring is sticky and irreversible: unpausing a retiring book must
    // abort instead of un-retiring it.
    tiny_clob::clob_admin_unpause_book(&cap, &mut book);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun drain_step_remains_callable_after_failed_unpause_attempt() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    tiny_clob::clob_admin_retire(&cap, &mut book);
    // An unpause attempt against a retiring book aborts before mutating
    // anything (see unpause_after_retire_aborts_with_ebookretiring above),
    // so `retiring` stays sticky regardless of any such attempt —
    // clob_admin_drain_step remains callable exactly as if no unpause had
    // ever been attempted.
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 10, scenario.ctx());
    assert!(tiny_clob::is_book_retiring(&book), 0);

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
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    assert!(tiny_clob::is_paused(&book), 0);
    assert!(!tiny_clob::is_book_retiring(&book), 1);
    // Plain pause alone must not unlock draining.
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 10, scenario.ctx());

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 8, location = tiny_clob)] // tiny_clob::ETakerFeeRateTooHigh
fun taker_fee_above_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, 11);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 9, location = tiny_clob)] // tiny_clob::EMakerFeeRateTooHigh
fun maker_fee_above_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, 6);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_fees_drains_full_accumulator() {
    let base_amount = 500;
    let quote_amount = 20_000;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    tiny_clob::credit_fee_accumulator_for_testing(
        &mut book,
        balance::create_for_testing<BTC>(base_amount),
        balance::create_for_testing<USDC>(quote_amount),
    );

    let (before_base, before_quote) = tiny_clob::fee_accumulator_balances(&book);
    assert!(before_base == base_amount, 0);
    assert!(before_quote == quote_amount, 1);

    let (base_coin, quote_coin) = tiny_clob::clob_admin_claim_fees(&cap, &mut book, scenario.ctx());
    assert!(coin::burn_for_testing(base_coin) == base_amount, 2);
    assert!(coin::burn_for_testing(quote_coin) == quote_amount, 3);

    let (after_base, after_quote) = tiny_clob::fee_accumulator_balances(&book);
    assert!(after_base == 0, 4);
    assert!(after_quote == 0, 5);

    let claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(claimed_events.length() == 1, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_fees_zero_balance_emits_no_event() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let (base_coin, quote_coin) = tiny_clob::clob_admin_claim_fees(&cap, &mut book, scenario.ctx());
    assert!(coin::burn_for_testing(base_coin) == 0, 0);
    assert!(coin::burn_for_testing(quote_coin) == 0, 1);
    let claimed_events = event::events_by_type<tiny_clob::FeesClaimed>();
    assert!(claimed_events.length() == 0, 2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun claim_fees_rejects_wrong_cap() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    let (base_coin, quote_coin) = tiny_clob::clob_admin_claim_fees(&cap2, &mut book1, scenario.ctx());
    coin::burn_for_testing(base_coin);
    coin::burn_for_testing(quote_coin);
    sui::test_utils::destroy(book1);
    sui::test_utils::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
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
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);

    let order_id = 7;
    let order_book_id = tiny_clob::id_for_testing(&book);
    let side = true;
    let price = 50_000;
    let ticket = tiny_clob::new_ticket_for_testing(order_id, order_book_id, side, price);

    let (t_order_id, t_book_id, t_side, t_price) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_order_id == order_id, 0);
    assert!(t_book_id == order_book_id, 1);
    assert!(t_side == side, 2);
    assert!(t_price == price, 3);

    // Happy path: `book.proceeds` has no entry for this `order_id`, so the
    // guarded public `destroy_orphaned_ticket` disposes it with no abort and
    // no leaked value.
    tiny_clob::destroy_orphaned_ticket(&book, ticket);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// Regression tests for the private `match_bid`/`match_ask` functions,
// invoked directly via the `match_bid_for_testing`/`match_ask_for_testing`
// test-only accessors. Every expected value below is computed
// independently from the known price/size/fee-rate inputs using the fee
// formula in `sources/tiny_clob.move` (`fee_amount`: `ceil(receive_amount *
// rate_bps / 10_000)`) — not by comparing two invocations of the
// same function. Fee rates are bounded by MAX_TAKER_FEE_BPS/
// MAX_MAKER_FEE_BPS (10/5 bps); 7/3 bps is used here, deliberately
// non-round relative to the fixture sizes so the ceiling-rounding on both
// fee legs is actually exercised.

const FEE_TEST_TAKER_FEE_BPS: u64 = 7;
const FEE_TEST_MAKER_FEE_BPS: u64 = 3;
const FEE_TEST_PRICE: u64 = 47_500;
const FEE_TEST_RESTING_SIZE: u64 = 4_000;
const FEE_TEST_TAKER_SIZE: u64 = 3_400;
const FEE_TEST_MAX_FILLS: u64 = 1_000_000_000;

#[test]
fun match_bid_produces_expected_fill_and_fee_amounts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, FEE_TEST_TAKER_FEE_BPS);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, FEE_TEST_MAKER_FEE_BPS);

    // Resting ask, inserted via the low-level test construction path this
    // suite already uses elsewhere.
    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<BTC>(FEE_TEST_RESTING_SIZE);
    let ask = order::new<BTC, USDC>(
        order_id, OTHER, FEE_TEST_RESTING_SIZE, option::some(escrow), option::none(), FEE_TEST_MAKER_FEE_BPS,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FEE_TEST_PRICE, ask, scenario.ctx());

    // Taker fully filled by the larger resting ask, so fill_qty ==
    // FEE_TEST_TAKER_SIZE:
    //   quote_cost = price * fill_qty = 47_500 * 3_400 = 161_500_000
    //   taker_fee_base = ceil(fill_qty * taker_bps / 10_000)
    //                  = ceil(3_400 * 7 / 10_000) = ceil(2.38) = 3
    //   matched_base   = fill_qty - taker_fee_base = 3_400 - 3 = 3_397
    //   maker_fee_quote = ceil(quote_cost * maker_bps / 10_000)
    //                   = ceil(161_500_000 * 3 / 10_000) = 48_450 (exact)
    //   remaining_budget = payment - quote_cost = 0 (exact full fill)
    let expected_quote_cost = FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE;
    let expected_taker_fee_base = 3;
    let expected_matched_base = FEE_TEST_TAKER_SIZE - expected_taker_fee_base;
    let expected_maker_fee_quote = 48_450;

    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE), scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, stopped) = tiny_clob::match_bid_for_testing(
        &mut book, option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_base_val = coin::burn_for_testing(matched_base);
    let remaining_budget_val = coin::burn_for_testing(remaining_budget);
    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);

    assert!(matched_base_val == expected_matched_base, 0);
    assert!(remaining_budget_val == tiny_clob::bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE) - expected_quote_cost, 1);
    assert!(remaining_size == 0, 2);
    assert!(stopped == false, 3);
    assert!(fee_base_after == expected_taker_fee_base, 4);
    assert!(fee_quote_after == expected_maker_fee_quote, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun match_ask_produces_expected_fill_and_fee_amounts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, FEE_TEST_TAKER_FEE_BPS);
    tiny_clob::clob_admin_set_maker_fee(&cap, &mut book, FEE_TEST_MAKER_FEE_BPS);

    // Resting bid.
    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(FEE_TEST_PRICE * FEE_TEST_RESTING_SIZE);
    let bid = order::new<BTC, USDC>(
        order_id, OTHER, FEE_TEST_RESTING_SIZE, option::none(), option::some(escrow), FEE_TEST_MAKER_FEE_BPS,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, true, FEE_TEST_PRICE, bid, scenario.ctx());

    // Taker fully filled by the larger resting bid, so fill_qty ==
    // FEE_TEST_TAKER_SIZE:
    //   quote_cost = price * fill_qty = 47_500 * 3_400 = 161_500_000
    //   taker_fee_quote = ceil(quote_cost * taker_bps / 10_000)
    //                   = ceil(161_500_000 * 7 / 10_000) = 113_050 (exact)
    //   matched_quote   = quote_cost - taker_fee_quote = 161_386_950
    //   maker_fee_base = ceil(fill_qty * maker_bps / 10_000)
    //                  = ceil(3_400 * 3 / 10_000) = ceil(1.02) = 2
    //   remaining_escrow = escrow_base - fill_qty = 0 (exact full fill)
    let expected_quote_cost = FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE;
    let expected_taker_fee_quote = 113_050;
    let expected_matched_quote = expected_quote_cost - expected_taker_fee_quote;
    let expected_maker_fee_base = 2;

    let payment = coin::mint_for_testing<BTC>(FEE_TEST_TAKER_SIZE, scenario.ctx());
    let (matched_quote, remaining_escrow, remaining_size, stopped) = tiny_clob::match_ask_for_testing(
        &mut book, option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_quote_val = coin::burn_for_testing(matched_quote);
    let remaining_escrow_val = coin::burn_for_testing(remaining_escrow);
    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);

    assert!(matched_quote_val == expected_matched_quote, 0);
    assert!(remaining_escrow_val == 0, 1);
    assert!(remaining_size == 0, 2);
    assert!(stopped == false, 3);
    assert!(fee_base_after == expected_maker_fee_base, 4);
    assert!(fee_quote_after == expected_taker_fee_quote, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 2: fee rounding — ceiling division closes the dust-fee exploit ===

const FEE_ROUND_PRICE: u64 = 1_000;
const FEE_ROUND_TAKER_BPS: u64 = 10; // MAX_TAKER_FEE_BPS
const FEE_ROUND_RESTING_SIZE: u64 = 3_000;

#[test]
fun fee_amount_ceiling_rounds_up_dust_and_stays_exact_on_exact_division() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, FEE_ROUND_TAKER_BPS);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<BTC>(FEE_ROUND_RESTING_SIZE);
    let ask = order::new<BTC, USDC>(order_id, OTHER, FEE_ROUND_RESTING_SIZE, option::some(escrow), option::none(), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FEE_ROUND_PRICE, ask, scenario.ctx());

    // Fill 999 units: ceil(999 * 10 / 10_000) = ceil(0.999) = 1 — under the
    // old floor division this collected 0 fee; the fix now collects 1.
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(FEE_ROUND_PRICE, 999), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(FEE_ROUND_PRICE), 999, payment1, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base1);
    coin::burn_for_testing(remaining_budget1);
    assert!(remaining_size1 == 0, 0);
    let (fee_base_after_1, _) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after_1 == 1, 1);

    // Fill exactly 1000 more units: ceil(1000 * 10 / 10_000) = ceil(1) = 1,
    // an exact-division case — confirms ceiling division doesn't
    // over-round when the division is already exact.
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(FEE_ROUND_PRICE, 1000), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(FEE_ROUND_PRICE), 1000, payment2, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base2);
    coin::burn_for_testing(remaining_budget2);
    assert!(remaining_size2 == 0, 2);
    let (fee_base_after_2, _) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after_2 == 2, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Regression test for the dust-shredding exploit: at 10 bps, a fill of 50
/// units yields `50 * 10 / 10_000 = 0.05`. Under the old floor division this
/// rounded to exactly 0 — a taker could split a large order into many
/// sub-100-unit fills and pay literally zero total fee across all of them.
/// Ceiling division closes that: each such fill now collects 1 unit, so
/// repeating it several times collects a clearly nonzero total.
#[test]
fun repeated_dust_sized_fills_now_collect_nonzero_total_fee() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, FEE_ROUND_TAKER_BPS);

    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<BTC>(FEE_ROUND_RESTING_SIZE);
    let ask = order::new<BTC, USDC>(order_id, OTHER, FEE_ROUND_RESTING_SIZE, option::some(escrow), option::none(), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FEE_ROUND_PRICE, ask, scenario.ctx());

    let dust_fill_size = 50;
    let num_fills = 10;
    let mut i = 0;
    while (i < num_fills) {
        let payment = coin::mint_for_testing<USDC>(
            tiny_clob::bid_escrow_amount(FEE_ROUND_PRICE, dust_fill_size), scenario.ctx(),
        );
        let (matched_base, remaining_budget, remaining_size, _) = tiny_clob::match_bid_for_testing(
            &mut book, option::some(FEE_ROUND_PRICE), dust_fill_size, payment, 1_000_000, scenario.ctx(),
        );
        coin::burn_for_testing(matched_base);
        coin::burn_for_testing(remaining_budget);
        assert!(remaining_size == 0, i);
        i = i + 1;
    };

    // Under the old floor-division formula, every one of these 10 fills
    // would have collected 0 fee, so the accumulator would still read 0
    // here. Ceiling division collects 1 unit per fill instead.
    let (fee_base_after, _) = tiny_clob::fee_accumulator_balances(&book);
    assert!(fee_base_after == num_fills, 100);
    assert!(fee_base_after > 0, 101);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === fill_level_bid/fill_level_ask: detach-mutate-reinsert fill path.
// `price_tree::level_remove_order` + `order::decrease_remaining_size` +
// `price_tree::level_insert_order_front` (or `order::destroy` on full
// drain). These tests exercise that path through the public matching
// entry points and confirm FIFO order and total_size bookkeeping. ===

const FILL_INPLACE_PRICE: u64 = 25_000;

/// Partial fill of the level's front order must leave it AT THE FRONT (no
/// detach/reinsert needed since nothing left the level) — FIFO is preserved
/// trivially. Confirmed the same way the pre-existing FIFO tests below do:
/// drive a second, larger fill and check fill order.
#[test]
fun fill_in_place_partial_fill_preserves_fifo_order() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = tiny_clob::next_order_id(&mut book);
    let ask_a = order::new<BTC, USDC>(
        order_id_a, MAKER_A, 300, option::some(balance::create_for_testing<BTC>(300)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FILL_INPLACE_PRICE, ask_a, scenario.ctx());

    let order_id_b = tiny_clob::next_order_id(&mut book);
    let ask_b = order::new<BTC, USDC>(
        order_id_b, MAKER_B, 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FILL_INPLACE_PRICE, ask_b, scenario.ctx());

    // Partial fill of A (front order) — must remain in place at the front.
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(FILL_INPLACE_PRICE, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(FILL_INPLACE_PRICE), 100, payment1, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base1);
    coin::burn_for_testing(remaining_budget1);
    assert!(remaining_size1 == 0, 0);
    assert!(tiny_clob::depth_at_price(&book, false, FILL_INPLACE_PRICE) == 400, 1); // 200 (A left) + 200 (B)

    // A large enough fill to drain the rest of A, then start on B: if A had
    // been silently demoted behind B, the first `OrderFilled` event here
    // would be for B instead of A.
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(FILL_INPLACE_PRICE, 250), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(FILL_INPLACE_PRICE), 250, payment2, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base2);
    coin::burn_for_testing(remaining_budget2);
    assert!(remaining_size2 == 0, 2);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 3, 3);
    let (id_2, _, _, size_2, _, _) = tiny_clob::order_filled_fields_for_testing(&fills[1]);
    assert!(id_2 == order_id_a, 4); // A drains first (still at the front)
    assert!(size_2 == 200, 5);
    let (id_3, _, _, size_3, _, _) = tiny_clob::order_filled_fields_for_testing(&fills[2]);
    assert!(id_3 == order_id_b, 6);
    assert!(size_3 == 50, 7);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A fill that exactly drains the front order must pop it entirely — the
/// level's depth must reflect its removal, and once the level itself is
/// fully emptied it must disappear from the tree (depth_at_price -> 0).
#[test]
fun fill_in_place_full_drain_removes_order_and_frees_level() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = tiny_clob::next_order_id(&mut book);
    let ask = order::new<BTC, USDC>(
        order_id, OTHER, 150, option::some(balance::create_for_testing<BTC>(150)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FILL_INPLACE_PRICE, ask, scenario.ctx());
    assert!(tiny_clob::depth_at_price(&book, false, FILL_INPLACE_PRICE) == 150, 0);

    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(FILL_INPLACE_PRICE, 150), scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(FILL_INPLACE_PRICE), 150, payment, 1_000_000, scenario.ctx());
    assert!(coin::burn_for_testing(matched_base) == 150, 1);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 2);
    assert!(remaining_size == 0, 3);

    // Level is now empty and must have been removed from the tree entirely.
    assert!(tiny_clob::depth_at_price(&book, false, FILL_INPLACE_PRICE) == 0, 4);
    assert!(tiny_clob::best_ask(&book).is_none(), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Strict, per-step regression guard against `total_size` drift: several
/// orders at one level, a mix of partial and full fills, asserting
/// `depth_at_price` (backed by `level_total_size`) exactly matches a
/// brute-force running total after EVERY SINGLE fill, not just at the end.
#[test]
fun fill_in_place_multi_order_sweep_total_size_matches_running_total_per_step() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_1 = tiny_clob::next_order_id(&mut book);
    let ask_1 = order::new<BTC, USDC>(
        order_id_1, MAKER_A, 150, option::some(balance::create_for_testing<BTC>(150)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FILL_INPLACE_PRICE, ask_1, scenario.ctx());

    let order_id_2 = tiny_clob::next_order_id(&mut book);
    let ask_2 = order::new<BTC, USDC>(
        order_id_2, MAKER_B, 100, option::some(balance::create_for_testing<BTC>(100)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FILL_INPLACE_PRICE, ask_2, scenario.ctx());

    let order_id_3 = tiny_clob::next_order_id(&mut book);
    let ask_3 = order::new<BTC, USDC>(
        order_id_3, MAKER_C, 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FILL_INPLACE_PRICE, ask_3, scenario.ctx());

    let mut expected_total: u64 = 150 + 100 + 200;
    assert!(tiny_clob::depth_at_price(&book, false, FILL_INPLACE_PRICE) == expected_total, 0);

    // Mixed partial/full fill sequence: 50 (partial 1), 100 (full-drain 1),
    // 30 (partial 2), 70 (full-drain 2), 50 (partial 3), 150 (full-drain 3,
    // which also empties and removes the level).
    let fill_sizes = vector[50, 100, 30, 70, 50, 150];
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let fill_size = fill_sizes[i];
        let payment = coin::mint_for_testing<USDC>(
            tiny_clob::bid_escrow_amount(FILL_INPLACE_PRICE, fill_size), scenario.ctx(),
        );
        let (matched_base, remaining_budget, remaining_size, _) = tiny_clob::match_bid_for_testing(
            &mut book, option::some(FILL_INPLACE_PRICE), fill_size, payment, 1_000_000, scenario.ctx(),
        );
        coin::burn_for_testing(matched_base);
        coin::burn_for_testing(remaining_budget);
        assert!(remaining_size == 0, 100 + i);

        expected_total = expected_total - fill_size;
        let actual_total = tiny_clob::depth_at_price(&book, false, FILL_INPLACE_PRICE);
        assert!(actual_total == expected_total, 200 + i);
        i = i + 1;
    };

    assert!(expected_total == 0, 1);
    assert!(tiny_clob::depth_at_price(&book, false, FILL_INPLACE_PRICE) == 0, 2);
    assert!(tiny_clob::best_ask(&book).is_none(), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Price-time priority across partial fills ===
//
// A partially-filled maker order is detached from its price level
// (`price_tree::level_remove_order`), mutated off-tree, then reinserted at
// the FRONT of the same level's FIFO queue via
// `price_tree::level_insert_order_front` (`LinkedTable::push_front`) — this
// is what keeps a partially-filled order at the head of the line instead of
// letting it get shuffled behind orders that arrived later. A genuinely new
// order at the same price, by contrast, goes through the ordinary
// `price_tree::level_insert_order` (`push_back`) path and lands at the back.
//
// These four tests exist specifically to guard that distinction: flipping
// `push_front` to `push_back` (or vice versa) in either of those two
// functions must cause at least one of them to fail. Without tests like
// these, that mutation is invisible to the suite — a partially-filled
// maker order silently demoted to the back of its queue is a serious
// real-world correctness bug that produces no build or type error.

#[test]
fun ask_side_partial_fill_keeps_fifo_priority() {
    let price = 50_000;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = tiny_clob::next_order_id(&mut book);
    let ask_a = order::new<BTC, USDC>(
        order_id_a, MAKER_A, 300, option::some(balance::create_for_testing<BTC>(300)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, price, ask_a, scenario.ctx());

    let order_id_b = tiny_clob::next_order_id(&mut book);
    let ask_b = order::new<BTC, USDC>(
        order_id_b, MAKER_B, 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, price, ask_b, scenario.ctx());

    let order_id_c = tiny_clob::next_order_id(&mut book);
    let ask_c = order::new<BTC, USDC>(
        order_id_c, MAKER_C, 200, option::some(balance::create_for_testing<BTC>(200)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, price, ask_c, scenario.ctx());

    // First taker partially fills A by 100, leaving 200 resting — A must be
    // reinserted at the FRONT of the queue, ahead of B and C.
    scenario.next_tx(TAKER);
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(price, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(price), 100, payment1, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base1);
    coin::burn_for_testing(remaining_budget1);
    assert!(remaining_size1 == 0, 0);

    // Second taker buys 500 more: must drain A's remaining 200 first, then
    // B's full 200, then C's partial 100 — in that order.
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(price, 500), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(price), 500, payment2, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base2);
    coin::burn_for_testing(remaining_budget2);
    assert!(remaining_size2 == 0, 1);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    // 1 event from the first taker + 3 from the second.
    assert!(fills.length() == 4, 2);

    let (id_1, _, _, size_1, maker_1, _) = tiny_clob::order_filled_fields_for_testing(&fills[1]);
    assert!(id_1 == order_id_a, 3);
    assert!(size_1 == 200, 4);
    assert!(maker_1 == MAKER_A, 5);

    let (id_2, _, _, size_2, maker_2, _) = tiny_clob::order_filled_fields_for_testing(&fills[2]);
    assert!(id_2 == order_id_b, 6);
    assert!(size_2 == 200, 7);
    assert!(maker_2 == MAKER_B, 8);

    let (id_3, _, _, size_3, maker_3, _) = tiny_clob::order_filled_fields_for_testing(&fills[3]);
    assert!(id_3 == order_id_c, 9);
    assert!(size_3 == 100, 10);
    assert!(maker_3 == MAKER_C, 11);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun bid_side_partial_fill_keeps_fifo_priority() {
    let price = 50_000;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = tiny_clob::next_order_id(&mut book);
    let bid_a = order::new<BTC, USDC>(
        order_id_a, MAKER_A, 300, option::none(), option::some(balance::create_for_testing<USDC>(price * 300)), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, bid_a, scenario.ctx());

    let order_id_b = tiny_clob::next_order_id(&mut book);
    let bid_b = order::new<BTC, USDC>(
        order_id_b, MAKER_B, 200, option::none(), option::some(balance::create_for_testing<USDC>(price * 200)), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, bid_b, scenario.ctx());

    let order_id_c = tiny_clob::next_order_id(&mut book);
    let bid_c = order::new<BTC, USDC>(
        order_id_c, MAKER_C, 200, option::none(), option::some(balance::create_for_testing<USDC>(price * 200)), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, bid_c, scenario.ctx());

    // First taker partially fills A by 100, leaving 200 resting — A must be
    // reinserted at the FRONT of the queue, ahead of B and C.
    scenario.next_tx(TAKER);
    let payment1 = coin::mint_for_testing<BTC>(100, scenario.ctx());
    let (matched_quote1, remaining_escrow1, remaining_size1, _) =
        tiny_clob::match_ask_for_testing(&mut book, option::some(price), 100, payment1, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_quote1);
    coin::burn_for_testing(remaining_escrow1);
    assert!(remaining_size1 == 0, 0);

    // Second taker sells 500 more: must drain A's remaining 200 first, then
    // B's full 200, then C's partial 100 — in that order.
    let payment2 = coin::mint_for_testing<BTC>(500, scenario.ctx());
    let (matched_quote2, remaining_escrow2, remaining_size2, _) =
        tiny_clob::match_ask_for_testing(&mut book, option::some(price), 500, payment2, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_quote2);
    coin::burn_for_testing(remaining_escrow2);
    assert!(remaining_size2 == 0, 1);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    // 1 event from the first taker + 3 from the second.
    assert!(fills.length() == 4, 2);

    let (id_1, _, _, size_1, maker_1, _) = tiny_clob::order_filled_fields_for_testing(&fills[1]);
    assert!(id_1 == order_id_a, 3);
    assert!(size_1 == 200, 4);
    assert!(maker_1 == MAKER_A, 5);

    let (id_2, _, _, size_2, maker_2, _) = tiny_clob::order_filled_fields_for_testing(&fills[2]);
    assert!(id_2 == order_id_b, 6);
    assert!(size_2 == 200, 7);
    assert!(maker_2 == MAKER_B, 8);

    let (id_3, _, _, size_3, maker_3, _) = tiny_clob::order_filled_fields_for_testing(&fills[3]);
    assert!(id_3 == order_id_c, 9);
    assert!(size_3 == 100, 10);
    assert!(maker_3 == MAKER_C, 11);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun repeated_partial_fills_of_head_never_reorder() {
    let price = 50_000;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = tiny_clob::next_order_id(&mut book);
    let ask_a = order::new<BTC, USDC>(
        order_id_a, MAKER_A, 500, option::some(balance::create_for_testing<BTC>(500)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, price, ask_a, scenario.ctx());

    let order_id_b = tiny_clob::next_order_id(&mut book);
    let ask_b = order::new<BTC, USDC>(
        order_id_b, MAKER_B, 100, option::some(balance::create_for_testing<BTC>(100)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, price, ask_b, scenario.ctx());

    scenario.next_tx(TAKER);
    // Five separate 100-unit takers, each landing on A alone (500 total),
    // proving A stays at the front of the queue across five consecutive
    // partial-fill/reinsert cycles rather than drifting behind B.
    let mut i = 0;
    while (i < 5) {
        let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(price, 100), scenario.ctx());
        let (matched_base, remaining_budget, remaining_size, _) =
            tiny_clob::match_bid_for_testing(&mut book, option::some(price), 100, payment, 1_000_000, scenario.ctx());
        coin::burn_for_testing(matched_base);
        coin::burn_for_testing(remaining_budget);
        assert!(remaining_size == 0, i);
        assert!(tiny_clob::depth_at_price(&book, false, price) == 500 - (i + 1) * 100 + 100, 20 + i);
        i = i + 1;
    };

    // A is now fully drained, so the sixth fill must land on B.
    let payment6 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(price, 100), scenario.ctx());
    let (matched_base6, remaining_budget6, remaining_size6, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(price), 100, payment6, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base6);
    coin::burn_for_testing(remaining_budget6);
    assert!(remaining_size6 == 0, 10);
    assert!(tiny_clob::depth_at_price(&book, false, price) == 0, 11);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 6, 12);

    let mut j = 0;
    while (j < 5) {
        let (fid, _, _, fsize, fmaker, _) = tiny_clob::order_filled_fields_for_testing(&fills[j]);
        assert!(fid == order_id_a, 30 + j);
        assert!(fsize == 100, 40 + j);
        assert!(fmaker == MAKER_A, 50 + j);
        j = j + 1;
    };

    let (id_6, _, _, size_6, maker_6, _) = tiny_clob::order_filled_fields_for_testing(&fills[5]);
    assert!(id_6 == order_id_b, 60);
    assert!(size_6 == 100, 61);
    assert!(maker_6 == MAKER_B, 62);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_order_at_same_price_goes_behind_partially_filled_one() {
    let price = 50_000;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id_a = tiny_clob::next_order_id(&mut book);
    let ask_a = order::new<BTC, USDC>(
        order_id_a, MAKER_A, 300, option::some(balance::create_for_testing<BTC>(300)), option::none(), 0,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, price, ask_a, scenario.ctx());

    // Partially fill A by 100, leaving 200 resting, reinserted at the front.
    scenario.next_tx(TAKER);
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(price, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(price), 100, payment1, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base1);
    coin::burn_for_testing(remaining_budget1);
    assert!(remaining_size1 == 0, 0);

    // A brand-new maker rests at the same price via the ordinary placement
    // path (`level_insert_order`, appends to the back) — it must not jump
    // ahead of A's already-reinserted 200-unit remainder.
    scenario.next_tx(MAKER_B);
    let ticket_b = rest_ask(&mut book, price, 300, 10, scenario.ctx());
    let (order_id_b, _, _, _) = tiny_clob::ticket_fields_for_testing(&ticket_b);

    // `event::events_by_type` only sees events emitted in the *current*
    // transaction (test_scenario clears its recorded events on every
    // `next_tx`), so the final sweep's own two `OrderFilled` events are
    // freshly numbered [0, 1] here, independent of the earlier partial fill.
    scenario.next_tx(TAKER);
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(price, 500), scenario.ctx());
    let (matched_base2, remaining_budget2, remaining_size2, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(price), 500, payment2, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base2);
    coin::burn_for_testing(remaining_budget2);
    assert!(remaining_size2 == 0, 1);

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 2, 2);

    let (id_1, _, _, size_1, maker_1, _) = tiny_clob::order_filled_fields_for_testing(&fills[0]);
    assert!(id_1 == order_id_a, 3);
    assert!(size_1 == 200, 4);
    assert!(maker_1 == MAKER_A, 5);

    let (id_2, _, _, size_2, maker_2, _) = tiny_clob::order_filled_fields_for_testing(&fills[1]);
    assert!(id_2 == order_id_b, 6);
    assert!(size_2 == 300, 7);
    assert!(maker_2 == MAKER_B, 8);

    unit_test::destroy(ticket_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun force_cancel_refunds_owner_not_caller() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    // Insert a resting bid directly via the `#[test_only]`
    // `insert_resting_order_for_testing` wrapper, bypassing the placement
    // functions entirely.
    let order_id = tiny_clob::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = order::new<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    tiny_clob::clob_admin_cancel_order(&cap, &mut book, true, price, order_id, scenario.ctx());

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 0);
    let (ev_order_id, ev_book, ev_trader) = tiny_clob::order_cancelled_fields_for_testing(&cancelled_events[0]);
    assert!(ev_order_id == order_id, 1);
    assert!(ev_book == book_id, 2);
    assert!(ev_trader == OTHER, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

const CH2_PRICE: u64 = 50_000;
const CH2_SIZE: u64 = 100;

#[test]
fun place_limit_order_bid_rests_and_emits_orderplaced() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, CH2_PRICE, CH2_SIZE, payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 0, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    let (t_order_id, t_book_id, t_side, t_price) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_book_id == book_id, 3);
    assert!(t_side == true, 4);
    assert!(t_price == CH2_PRICE, 5);

    let placed_events = event::events_by_type<tiny_clob::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);
    let (ev_order_id, ev_book_id, ev_side, ev_price, ev_size, ev_trader) =
        tiny_clob::order_placed_fields_for_testing(&placed_events[0]);
    assert!(ev_order_id == t_order_id, 7);
    assert!(ev_book_id == book_id, 8);
    assert!(ev_side == true, 9);
    assert!(ev_price == CH2_PRICE, 10);
    assert!(ev_size == CH2_SIZE, 11);
    assert!(ev_trader == ADMIN, 12);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_rests_and_emits_orderplaced() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    let payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (ticket, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, CH2_PRICE, CH2_SIZE, payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == 0, 2);
    let (_t_order_id, t_book_id, t_side, t_price) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_book_id == book_id, 3);
    assert!(t_side == false, 4);
    assert!(t_price == CH2_PRICE, 5);

    let placed_events = event::events_by_type<tiny_clob::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_bid_matches_resting_ask() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover_payment, _) = tiny_clob::place_market_order_bid(
        &mut book, CH2_SIZE, budget, bid_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == CH2_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_ask_matches_resting_bid() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(leftover_payment) == 0, 0);
    assert!(coin::burn_for_testing(matched_quote) == escrow_amount, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun swap_bid_matches_resting_ask() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover_payment, stopped) = tiny_clob::swap_bid(
        &mut book, CH2_SIZE, budget, bid_payment, 1_000_000_000,
        option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == CH2_SIZE, 1);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 2);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun swap_ask_matches_resting_bid() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, stopped) = tiny_clob::swap_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == escrow_amount, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_order_refunds_escrow_and_emits_ordercancelled() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (t_order_id, _, _, _) = tiny_clob::ticket_fields_for_testing(&ticket);

    let (refund_base, refund_quote) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(refund_base) == 0, 0);
    assert!(coin::burn_for_testing(refund_quote) == escrow_amount, 1);

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 2);
    let (ev_order_id, ev_book_id, ev_trader) = tiny_clob::order_cancelled_fields_for_testing(&cancelled_events[0]);
    assert!(ev_order_id == t_order_id, 3);
    assert!(ev_book_id == book_id, 4);
    assert!(ev_trader == ADMIN, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_order_sweeps_combined_escrow_and_proceeds() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // ADMIN rests a bid for 200; a partial market ask of 100 fills half,
    // crediting ADMIN's order_id with base proceeds while the other half
    // stays resting with its own still-locked quote escrow. cancel_order
    // must return both legs combined in one call.
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());
    let (order_id, _, _, _) = tiny_clob::ticket_fields_for_testing(&bid_ticket);

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    // Both legs exist before cancelling: proceeds credited for the filled
    // half, and the order still resting (with locked escrow) for the
    // unfilled half.
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);
    assert!(tiny_clob::bids_size_for_testing(&book) == 1, 1);

    scenario.next_tx(ADMIN);
    let (refund_base, refund_quote) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());

    // Combined: base proceeds from the matched half (net of zero fees)
    // plus quote escrow still locked for the unfilled half.
    let expected_base = fill_size;
    let expected_quote = tiny_clob::bid_escrow_amount(CH2_PRICE, size - fill_size);
    assert!(coin::burn_for_testing(refund_base) == expected_base, 2);
    assert!(coin::burn_for_testing(refund_quote) == expected_quote, 3);

    // ProceedsClaimed reports ONLY the swept proceeds leg (the matched
    // base), not the combined escrow+proceeds amount actually returned by
    // cancel_order. The remaining quote escrow for the unfilled half is
    // principal, not proceeds, so it must not appear in the event.
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 4);
    let (ev_claimant, _, ev_base, ev_quote) =
        tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 5);
    assert!(ev_base == expected_base, 6);
    assert!(ev_quote == 0, 7);

    let cancelled_events = event::events_by_type<tiny_clob::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 8);

    assert!(!tiny_clob::proceeds_contains_for_testing(&book, order_id), 9);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_order_with_zero_proceeds_does_not_emit_proceeds_claimed() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // ADMIN rests a bid that never fills at all: pure escrow, zero
    // proceeds. cancel_order must still return the full escrow, but since
    // no proceeds were ever swept, ProceedsClaimed must not fire — firing
    // it here would falsely report escrow principal as trading proceeds.
    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());

    let (refund_base, refund_quote) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(refund_base) == 0, 0);
    assert!(coin::burn_for_testing(refund_quote) == escrow_amount, 1);

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
    let mut scenario = ts::begin(ADMIN);
    let wrapper_uid = object::new(scenario.ctx());
    let override_id = object::uid_to_inner(&wrapper_uid);
    let (mut book, cap) = tiny_clob::new_with_event_id_override<BTC, USDC>(
        MIN_SIZE, &wrapper_uid, scenario.ctx(),
    );

    // The override, not the book's own internal id, is what got stamped
    // on events.
    let book_own_id = tiny_clob::id_for_testing(&book);
    assert!(tiny_clob::event_id_for_testing(&book) == override_id, 0);
    assert!(override_id != book_own_id, 1);

    // Place a resting bid — the ticket must carry the book's own id, NOT
    // the event_id override. Ticket identity is unforgeable and
    // independent of whatever event_id_override was supplied at
    // construction.
    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (_, t_book_id, _, _) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_book_id == book_own_id, 2);

    // No function exists that could change event_id after the fact — it is
    // still the override id right before cancellation, and cancel_order
    // (which checks ticket.order_book_id == object::uid_to_inner(&book.id))
    // succeeds because the ticket carries the book's own id, which is also
    // never mutable after construction.
    assert!(tiny_clob::event_id_for_testing(&book) == override_id, 3);
    let (refund_base, refund_quote) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(refund_base) == 0, 4);
    assert!(coin::burn_for_testing(refund_quote) == escrow_amount, 5);

    object::delete(wrapper_uid);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_event_id_defaults_to_self_id_when_override_is_none() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);

    let book_own_id = tiny_clob::id_for_testing(&book);
    assert!(tiny_clob::event_id_for_testing(&book) == book_own_id, 0);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_pays_out_and_emits_proceedsclaimed() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    // ADMIN rests a bid; OTHER crosses it fully as a market ask, crediting
    // ADMIN's order_id proceeds table entry with quote. Keep the ticket
    // alive: it is now required to claim. The bid is fully filled and
    // removed from the book, so claim_proceeds auto-destroys the ticket and
    // hands back option::none().
    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());

    scenario.next_tx(OTHER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    scenario.next_tx(ADMIN);
    let (claim_base, claim_quote, returned_ticket_opt) =
        tiny_clob::claim_proceeds(&mut book, bid_ticket, scenario.ctx());
    coin::burn_for_testing(claim_base);
    coin::burn_for_testing(claim_quote);

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_claimant, ev_book_id, ev_base, ev_quote) =
        tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_base == CH2_SIZE, 3);
    assert!(ev_quote == 0, 4);

    // The order was fully filled and removed from the book, so nothing
    // more can ever be claimed through this ticket — claim_proceeds already
    // destroyed it and returned option::none().
    assert!(returned_ticket_opt.is_none(), 5);
    option::destroy_none(returned_ticket_opt);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun push_proceeds_matches_claim_proceeds_and_pays_recorded_owner() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    // push_proceeds takes the book's ClobAdminCap plus the order_id: called
    // here from OTHER's transaction context (the cap authorizes the call
    // regardless of tx sender) — the payout still lands on ADMIN, the
    // address recorded as owner against this order_id at credit time, never
    // on the caller or the cap holder.
    scenario.next_tx(OTHER);
    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_claimant, ev_book_id, ev_base, ev_quote) =
        tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_base == CH2_SIZE, 3);
    assert!(ev_quote == 0, 4);
    // No live proceeds entry survives the push, matching claim_proceeds's
    // own claim-then-remove behavior.
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, order_id), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_found_reassigns_owner_and_credits_new_owner_on_push() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // ADMIN rests a bid; its resting order's owner is reassigned to OTHER
    // via update_resting_order (authorized by ticket possession)
    // before it is ever crossed.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    let found = tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER);
    assert!(found, 0);
    unit_test::destroy(bid_ticket);

    // Cross the reassigned resting bid with a market ask from a third party.
    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    // The proceeds ledger entry is now keyed by order_id, not address, so
    // its existence alone doesn't prove which address it pays out to.
    // push_proceeds pays whatever address was recorded as `owner` at credit
    // time (which is the order's live `owner` field at match time, i.e.
    // OTHER after reassignment) — proving the owner field was actually
    // overwritten, not just the ticket's own bookkeeping. Called here with
    // TAKER as the tx sender (authorized via the book's cap, not the
    // sender) — the payout still lands on OTHER.
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 1);
    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, _, _) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == OTHER, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassignment_straddled_by_fills_credits_new_owner_only() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // ADMIN rests a bid big enough to be filled in two separate chunks: one
    // fill BEFORE the owner reassignment (creating the proceeds ledger
    // entry under ADMIN) and one fill AFTER (crediting the same order_id
    // again, this time while the live owner is OTHER). Bug 1 was that
    // credit_maker_table only stamped `owner` on the entry's first
    // creation, so the second credit kept attributing proceeds to ADMIN
    // even though ownership had moved to OTHER in between.
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    // First fill, still owned by ADMIN: creates the ledger entry with
    // owner = ADMIN.
    scenario.next_tx(TAKER);
    let ask_payment_1 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_1, matched_quote_1, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment_1, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_1);
    coin::burn_for_testing(matched_quote_1);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);

    // Reassign ownership to OTHER while the order is still resting for the
    // remaining unfilled half.
    let found = tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER);
    assert!(found, 1);
    unit_test::destroy(bid_ticket);

    // Second fill, now owned by OTHER: credits the SAME order_id's
    // existing ledger entry again.
    scenario.next_tx(TAKER);
    let ask_payment_2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment_2, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_2);
    coin::burn_for_testing(matched_quote_2);

    // push_proceeds must pay out to OTHER — the order's CURRENT owner as
    // of the most recent credit — not ADMIN, the address that created the
    // ledger entry on the first fill. The pooled amount covers both fills.
    scenario.next_tx(TAKER);
    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, ev_base, ev_quote) =
        tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == OTHER, 3);
    assert!(ev_base == fill_size + fill_size, 4);
    assert!(ev_quote == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_not_found_is_a_noop() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // No resting order exists at all yet: neither the price level nor the
    // order_id exist. Must return false and touch nothing. Synthesize a
    // ticket for a non-existent order since the real not-found path has no
    // genuine ticket to offer.
    let book_id = tiny_clob::id_for_testing(&book);
    let empty_book_ticket =
        tiny_clob::new_ticket_for_testing(0, book_id, tiny_clob::bid_for_testing(), CH2_PRICE);
    let found_empty_book =
        tiny_clob::update_resting_order(&mut book, &empty_book_ticket, OTHER);
    assert!(!found_empty_book, 0);
    unit_test::destroy(empty_book_ticket);

    // Rest a real bid, then probe with a wrong order_id at the same,
    // now-existing price level — the level exists but the specific order
    // does not.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (order_id, _, side, price) = tiny_clob::ticket_fields_for_testing(&bid_ticket);
    let wrong_order_id = order_id + 1;
    let wrong_id_ticket = tiny_clob::new_ticket_for_testing(wrong_order_id, book_id, side, price);
    let found_wrong_id = tiny_clob::update_resting_order(&mut book, &wrong_id_ticket, OTHER);
    assert!(!found_wrong_id, 1);
    unit_test::destroy(wrong_id_ticket);

    // The real order's owner is untouched (still ADMIN): crossing it still
    // credits proceeds recorded against ADMIN, not OTHER.
    unit_test::destroy(bid_ticket);
    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 2);

    // push_proceeds (called here with TAKER as tx sender, authorized via the
    // book's cap) pays whoever is recorded as owner for this order_id —
    // still ADMIN, proving the failed reassignment attempts above never
    // touched the real order.
    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 3);
    let (ev_claimant, _, _, _) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun push_proceeds_rejects_wrong_cap() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);

    let bid_ticket = rest_bid(&mut book1, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book1, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    tiny_clob::push_proceeds(&cap2, &mut book1, order_id, scenario.ctx());

    sui::test_utils::destroy(book1);
    sui::test_utils::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun update_resting_order_rejects_ticket_from_wrong_book() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let (mut other_book, other_cap) = new_book(&mut scenario);

    // Rest a bid on the *other* book and try to use its ticket against
    // `book` — the ticket's order_book_id won't match `book`'s own id.
    let other_ticket = rest_bid(&mut other_book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());

    tiny_clob::update_resting_order(&mut book, &other_ticket, OTHER);

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
    let mut scenario = ts::begin(ADMIN);
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (mut book_b, cap_b) = new_book(&mut scenario);

    let ticket_b = rest_bid(&mut book_b, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());

    // Must abort with EWrongBook: ticket_b's order_book_id is book_b's own
    // id, not book_a's.
    let (refund_base, refund_quote) = tiny_clob::cancel_order(&mut book_a, ticket_b, scenario.ctx());
    coin::burn_for_testing(refund_base);
    coin::burn_for_testing(refund_quote);

    destroy_book_and_cap(book_a, cap_a);
    destroy_book_and_cap(book_b, cap_b);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun forged_event_id_ticket_cannot_hijack_victim_order_owner() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (mut book_b, cap_b) = new_book(&mut scenario);

    // Same setup as the cancel_order regression test above, but exercising
    // update_resting_order instead, which takes the ticket by reference
    // rather than consuming it.
    let ticket_b = rest_bid(&mut book_b, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());

    // Must abort with EWrongBook: ticket_b's order_book_id is book_b's own
    // id, not book_a's.
    tiny_clob::update_resting_order(&mut book_a, &ticket_b, OTHER);

    unit_test::destroy(ticket_b);
    destroy_book_and_cap(book_a, cap_a);
    destroy_book_and_cap(book_b, cap_b);
    scenario.end();
}

const PLACEMENT_PRICE: u64 = 50_000;
const PLACEMENT_SIZE: u64 = 100;

#[test]
fun place_limit_order_bid_ask_happy_path_fills_and_rests() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Resting ask, then a crossing bid fills it fully.
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (ask_ticket, ask_matched_base, ask_leftover_base, ask_stop) =
        tiny_clob::place_limit_order_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, ask_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(ask_matched_base) == 0, 0);
    assert!(coin::burn_for_testing(ask_leftover_base) == 0, 1);
    assert!(!ask_stop, 2);

    scenario.next_tx(TAKER);
    let bid_payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (bid_ticket, bid_matched_base, bid_leftover_quote, bid_stop) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, bid_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(bid_matched_base) == PLACEMENT_SIZE, 3);
    assert!(coin::burn_for_testing(bid_leftover_quote) == 0, 4);
    assert!(!bid_stop, 5);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun place_limit_order_zero_price_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket, mb, ml, _) = tiny_clob::place_limit_order_bid(&mut book, 0, PLACEMENT_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun place_limit_order_size_validation_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE - 1, payment, 10, scenario.ctx());
    unit_test::destroy(ticket);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun placement_functions_abort_when_paused() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (ticket, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_bid_ask_happy_path() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, _) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover) == 0, 2);

    scenario.next_tx(TAKER);
    let bid_ticket2 = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());
    let ask_payment2 = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, _) =
        tiny_clob::place_market_order_ask(&mut book, PLACEMENT_SIZE, ask_payment2, 10, option::none(), option::none(), scenario.ctx());
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 3);
    assert!(coin::burn_for_testing(leftover_base) == 0, 4);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun place_market_order_bid_slippage_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, _) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::some(PLACEMENT_SIZE + 1), scenario.ctx(),
    );
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(remaining_budget);
    coin::burn_for_testing(leftover);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun swap_bid_ask_happy_path_and_max_fills_stop_signal() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, stop) = tiny_clob::swap_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover) == 0, 2);
    assert!(!stop, 3);

    // max_fills = 0 against a crossing resting ask signals the stop-reason.
    scenario.next_tx(TAKER);
    let ask_ticket2 = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());
    scenario.next_tx(TAKER);
    let budget2 = tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment2 = coin::mint_for_testing<USDC>(budget2, scenario.ctx());
    let (matched_base2, remaining_budget2, leftover2, stop2) = tiny_clob::swap_bid(
        &mut book, PLACEMENT_SIZE, budget2, bid_payment2, 0, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base2) == 0, 4);
    assert!(coin::burn_for_testing(remaining_budget2) == budget2, 5);
    assert!(coin::burn_for_testing(leftover2) == 0, 6);
    assert!(stop2, 7);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(ask_ticket2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 3: `place_market_order_bid`/`ask` now surface the max_fills
// truncation signal, matching `swap_bid`/`swap_ask`'s existing precedent ===

#[test]
fun place_market_order_bid_returns_true_when_truncated_by_max_fills() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    // max_fills = 0 against a crossing resting ask: nothing can be matched,
    // and the truncation signal must now come back as `true`.
    let (matched_base, remaining_budget, leftover, stopped) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 0, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == 0, 0);
    assert!(coin::burn_for_testing(remaining_budget) == budget, 1);
    assert!(coin::burn_for_testing(leftover) == 0, 2);
    assert!(stopped, 3);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_bid_returns_false_when_fully_filled_within_max_fills() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, stopped) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover) == 0, 2);
    assert!(!stopped, 3);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_ask_returns_true_when_truncated_by_max_fills() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, stopped) = tiny_clob::place_market_order_ask(
        &mut book, PLACEMENT_SIZE, ask_payment, 0, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(leftover_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(matched_quote) == 0, 1);
    assert!(stopped, 2);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_market_order_ask_returns_false_when_fully_filled_within_max_fills() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, stopped) = tiny_clob::place_market_order_ask(
        &mut book, PLACEMENT_SIZE, ask_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(leftover_base) == 0, 0);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 1);
    assert!(!stopped, 2);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun swap_ask_slippage_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, stop) = tiny_clob::swap_ask(
        &mut book, PLACEMENT_SIZE, ask_payment, 10, option::none(),
        option::some(tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE) + 1), option::none(), scenario.ctx(),
    );
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    let _ = stop;
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun cancel_and_claim_never_block_on_pause_or_retiring() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid, pause the book, then cancel — must succeed despite pause.
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    let (cancel_base, cancel_quote) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cancel_base) == 0, 0);
    assert!(coin::burn_for_testing(cancel_quote) == tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 1);

    // claim_proceeds also succeeds while retiring.
    // The order was never resting for this order_id, so use a synthetic
    // ticket (bypassing the placement path, which isn't needed here) — the
    // claim finds nothing pooled, and since order_id 999 was never actually
    // resting, claim_proceeds auto-destroys the ticket and returns
    // option::none().
    tiny_clob::clob_admin_retire(&cap, &mut book);
    let book_id = tiny_clob::id_for_testing(&book);
    let dummy_ticket =
        tiny_clob::new_ticket_for_testing(999, book_id, tiny_clob::bid_for_testing(), PLACEMENT_PRICE);
    let (claim_base, claim_quote, returned_ticket_opt) =
        tiny_clob::claim_proceeds(&mut book, dummy_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(claim_base) == 0, 2);
    assert!(coin::burn_for_testing(claim_quote) == 0, 3);
    assert!(returned_ticket_opt.is_none(), 4);
    option::destroy_none(returned_ticket_opt);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_transfers_maker_proceeds() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let bid_ticket = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());

    scenario.next_tx(ADMIN);
    // ask_ticket's order was fully filled by the crossing bid above, so it
    // is no longer resting — claim_proceeds auto-destroys the ticket and
    // hands back option::none().
    let (claim_base, claim_quote, returned_ticket_opt) =
        tiny_clob::claim_proceeds(&mut book, ask_ticket, scenario.ctx());
    let claimed = event::events_by_type<ProceedsClaimed>();
    assert!(claimed.length() == 1, 0);
    let (claimant, _, _base_amt, quote_amt) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed[0]);
    assert!(claimant == ADMIN, 1);
    assert!(quote_amt == tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 2);
    coin::burn_for_testing(claim_base);
    coin::burn_for_testing(claim_quote);
    assert!(returned_ticket_opt.is_none(), 3);
    option::destroy_none(returned_ticket_opt);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// LCG-based distinct-key generator (rejects duplicates by linear scan) —
/// used below to synthesize a large set of distinct resting-bid prices.
fun gen_distinct_prices(n: u64, seed: u64, span: u64): vector<u64> {
    let mut out: vector<u64> = vector[];
    let mut s = seed as u128;
    let m = 0xFFFFFFFFFFFFFFFFu128;
    while (out.length() < n) {
        s = ((s * 6364136223846793005) + 1442695040888963407) & m;
        let k = (((s >> 13) as u64) % span);
        if (!out.contains(&k)) { out.push_back(k); };
    };
    out
}

/// Rests orders at 60 distinct bid prices through the real
/// `insert_resting_order` path (via `insert_resting_order_for_testing`) and
/// checks `depth_at_price`/`best_bid` after every single insertion. None of
/// the other book-level tests in this file build a price tree deep enough
/// for `price_tree::insert`/`insert_at`'s crit-bit routing to be observable
/// at the book level, so this is the only test that would catch a
/// structural corruption on that hot path.
#[test]
fun many_price_levels_depth_and_best_bid_correct_after_each_insertion() {
    let size = 7u64;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let prices = gen_distinct_prices(60, 20250827, 4_000_000);
    let mut i = 0;
    let mut best_bid_expected = 0u64;
    while (i < prices.length()) {
        let price = prices[i] + 1; // avoid price 0
        let order_id = tiny_clob::next_order_id(&mut book);
        let escrow = balance::create_for_testing<USDC>(price * size);
        let order = order::new<BTC, USDC>(order_id, ADMIN, size, option::none(), option::some(escrow), 0);
        tiny_clob::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());
        if (price > best_bid_expected) { best_bid_expected = price; };

        // Every previously rested level must still report exactly its depth.
        let mut j = 0;
        while (j <= i) {
            let q = prices[j] + 1;
            assert!(tiny_clob::depth_at_price(&book, true, q) == size, 0);
            j = j + 1;
        };
        assert!(tiny_clob::best_bid(&book).destroy_some() == best_bid_expected, 1);
        assert!(tiny_clob::bids_size_for_testing(&book) == i + 1, 2);
        i = i + 1;
    };

    // An absent price reports zero depth (no misrouting into a neighbour
    // level).
    assert!(tiny_clob::depth_at_price(&book, true, 4_000_002) == 0, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 2: guarded `destroy_orphaned_ticket` liveness check ===

#[test]
#[expected_failure(abort_code = 19, location = tiny_clob)] // tiny_clob::EProceedsNotEmpty
fun destroy_orphaned_ticket_with_nonzero_proceeds_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid big enough to be partially filled, leaving it still resting
    // afterward, and credits book.proceeds[order_id] with the matched Base
    // leg.
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);

    // Bypass claim_proceeds entirely and call the guarded public disposal
    // function directly on a ticket whose order_id still has pooled
    // proceeds — must abort rather than strand those funds.
    tiny_clob::destroy_orphaned_ticket(&book, bid_ticket);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // tiny_clob::EWrongBook
fun destroy_orphaned_ticket_wrong_book_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book_a, cap_a) = new_book(&mut scenario);
    let (book_b, cap_b) = new_book(&mut scenario);

    // Mint a ticket on book A but pass it against book B — must abort with
    // EWrongBook, and must do so BEFORE the proceeds-emptiness check (book B
    // has no entry for this order_id either, so a proceeds-check-first
    // implementation would incorrectly pass through here).
    let ticket_a = rest_bid(&mut book_a, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    tiny_clob::destroy_orphaned_ticket(&book_b, ticket_a);

    destroy_book_and_cap(book_a, cap_a);
    destroy_book_and_cap(book_b, cap_b);
    scenario.end();
}

#[test]
fun destroy_orphaned_ticket_zero_proceeds_on_own_book_disposes_cleanly() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // A resting bid that has never been filled has no book.proceeds entry
    // yet — the guarded public destroy must dispose of it with no abort,
    // exercising the happy path through the real placement pipeline (rather
    // than a synthetic ticket unconnected to any order, as in
    // destroy_orphaned_ticket_disposes_with_no_abort above).
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);
    tiny_clob::destroy_orphaned_ticket(&book, bid_ticket);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_auto_destroys_ticket_when_order_fully_filled() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Fully filling a resting bid removes it from the book. claim_proceeds
    // must auto-destroy the ticket and return option::none() — nothing more
    // can ever be claimed through it.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);

    scenario.next_tx(ADMIN);
    let (claim_base, claim_quote, returned_ticket_opt) = tiny_clob::claim_proceeds(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(claim_base) == CH2_SIZE, 1);
    coin::burn_for_testing(claim_quote);
    // Proceeds entry gone, and the order is no longer resting, so
    // claim_proceeds already destroyed the ticket for us.
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, order_id), 2);
    assert!(returned_ticket_opt.is_none(), 3);
    option::destroy_none(returned_ticket_opt);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun claim_proceeds_still_resting_returns_claimable_ticket_for_reuse() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // A partial fill leaves the order still resting. claim_proceeds returns
    // the ticket via option::some, which must remain valid and reusable for
    // a further claim after a second fill.
    let size = 300;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    scenario.next_tx(ADMIN);
    let (claim_base, claim_quote, returned_ticket_opt) = tiny_clob::claim_proceeds(&mut book, bid_ticket, scenario.ctx());
    coin::burn_for_testing(claim_base);
    coin::burn_for_testing(claim_quote);
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);
    assert!(returned_ticket_opt.is_some(), 4);
    let returned_ticket = option::destroy_some(returned_ticket_opt);

    // Second fill against the still-resting remainder, then claim again
    // using the SAME ticket returned above — confirms it remains usable
    // across multiple claims.
    scenario.next_tx(TAKER);
    let ask_payment2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment2, matched_quote2, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment2, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment2);
    coin::burn_for_testing(matched_quote2);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 1);

    scenario.next_tx(ADMIN);
    let (claim_base2, claim_quote2, returned_ticket_opt2) =
        tiny_clob::claim_proceeds(&mut book, returned_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(claim_base2) == fill_size, 2);
    coin::burn_for_testing(claim_quote2);
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, order_id), 3);

    // size (300) minus two fills of 100 leaves 100 still resting, so the
    // ticket remains live.
    assert!(returned_ticket_opt2.is_some(), 5);
    let returned_ticket2 = option::destroy_some(returned_ticket_opt2);
    tiny_clob::destroy_orphaned_ticket(&book, returned_ticket2); // must NOT abort

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Fix 3: `update_resting_order` syncs pooled proceeds owner ===

#[test]
fun update_resting_order_reassign_then_no_fill_syncs_proceeds_owner_on_push() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid big enough to be partially filled, leaving it still
    // resting, and creating a pooled proceeds entry under ADMIN.
    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);

    // Reassign ownership to OTHER. No further fill ever happens for this
    // order — the only way the already-pooled proceeds balance can ever be
    // told about the new owner is an immediate sync inside
    // update_resting_order itself.
    let found = tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER);
    assert!(found, 1);
    unit_test::destroy(bid_ticket);

    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, ev_base, ev_quote) =
        tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == OTHER, 3);
    assert!(ev_base == fill_size, 4);
    assert!(ev_quote == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_then_no_fill_syncs_proceeds_owner_on_drain() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let size = 200;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    let found = tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER);
    assert!(found, 0);
    unit_test::destroy(bid_ticket);

    // Retire and force-drain: this exercises BOTH the remaining resting
    // order's escrow (drain_side, already correctly paid to the live
    // order.owner today) and the pooled proceeds entry (drain_proceeds,
    // paid to whatever address is stamped as the MakerBalance's owner) in
    // the same call, so the two payout addresses can be compared directly.
    tiny_clob::clob_admin_retire(&cap, &mut book);
    let remaining_size = size - fill_size;
    let expected_escrow_refund = tiny_clob::bid_escrow_amount(CH2_PRICE, remaining_size);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 100, scenario.ctx());

    scenario.next_tx(OTHER);
    let escrow_refund = ts::take_from_address<coin::Coin<USDC>>(&scenario, OTHER);
    assert!(coin::value(&escrow_refund) == expected_escrow_refund, 1);
    coin::burn_for_testing(escrow_refund);

    let proceeds_payout = ts::take_from_address<coin::Coin<BTC>>(&scenario, OTHER);
    assert!(coin::value(&proceeds_payout) == fill_size, 2);
    coin::burn_for_testing(proceeds_payout);

    // ADMIN (the original owner) received nothing — both legs went to OTHER.
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(ADMIN), 3);
    assert!(!ts::has_most_recent_for_address<coin::Coin<USDC>>(ADMIN), 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_with_no_pooled_proceeds_yet_then_fill_credits_new_owner() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid and reassign it before any fill ever happens: book.proceeds
    // has no entry for this order_id yet, so `sync_maker_balance_owner`'s
    // `contains` guard must be a no-op here, not an abort.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);

    let found = tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER);
    assert!(found, 1);
    unit_test::destroy(bid_ticket);

    // A later fill must still correctly credit the new owner via the
    // ordinary credit_maker_table path.
    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, _, _) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == OTHER, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassigned_twice_final_payout_goes_to_latest_owner_only() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // A (ADMIN) -> B (OTHER) -> C (MAKER_A), with a fill pooling proceeds
    // between each reassignment.
    let size = 300;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    // Fill #1 while owned by A: pools proceeds under ADMIN.
    scenario.next_tx(TAKER);
    let ask_payment_1 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_1, matched_quote_1, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment_1, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_1);
    coin::burn_for_testing(matched_quote_1);

    // A -> B.
    let found_b = tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER);
    assert!(found_b, 0);

    // Fill #2 while owned by B: credits the same pooled entry again.
    scenario.next_tx(TAKER);
    let ask_payment_2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment_2, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_2);
    coin::burn_for_testing(matched_quote_2);

    // B -> C. No further fill after this point.
    let found_c = tiny_clob::update_resting_order(&mut book, &bid_ticket, MAKER_A);
    assert!(found_c, 1);
    unit_test::destroy(bid_ticket);

    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, ev_base, ev_quote) =
        tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == MAKER_A, 3);
    assert!(ev_base == fill_size + fill_size, 4);
    assert!(ev_quote == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_chain_pays_only_final_owner_with_no_leakage() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // A (ADMIN) -> B (OTHER) -> C (MAKER_A), pooling proceeds at each stage.
    // Strengthens update_resting_order_reassigned_twice_final_payout_goes_
    // to_latest_owner_only above with explicit negative assertions: neither
    // intermediate owner ever receives a coin object at all, not just a
    // differently-attributed event.
    let size = 400;
    let fill_size = 100;
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, size, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    scenario.next_tx(TAKER);
    let ask_payment_1 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_1, matched_quote_1, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment_1, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_1);
    coin::burn_for_testing(matched_quote_1); // pooled under ADMIN (A)

    scenario.next_tx(ADMIN);
    assert!(tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER), 0); // A -> B

    scenario.next_tx(TAKER);
    let ask_payment_2 = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = tiny_clob::place_market_order_ask(
        &mut book, fill_size, ask_payment_2, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_2);
    coin::burn_for_testing(matched_quote_2); // pooled under OTHER (B)

    scenario.next_tx(ADMIN);
    assert!(tiny_clob::update_resting_order(&mut book, &bid_ticket, MAKER_A), 1); // B -> C
    unit_test::destroy(bid_ticket);

    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    scenario.next_tx(MAKER_A);
    let payout = ts::take_from_address<coin::Coin<BTC>>(&scenario, MAKER_A);
    assert!(coin::value(&payout) == fill_size + fill_size, 2); // both fills
    coin::burn_for_testing(payout);
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(ADMIN), 3);
    assert!(!ts::has_most_recent_for_address<coin::Coin<BTC>>(OTHER), 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_reassign_does_not_touch_other_orders_proceeds() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Two resting bids at different prices; the higher one has strict price
    // priority. Fills consume the high order entirely (removing it from the
    // book) plus part of the low order (which stays resting), so both end up
    // with pooled proceeds. Reassigning ONLY the low order must not disturb
    // the high order's proceeds owner — a targeting-correctness check on
    // sync_maker_balance_owner keyed by order_id.
    let price_hi = CH2_PRICE + 1_000;
    let ticket_hi = rest_bid(&mut book, price_hi, 200, 1_000_000_000, scenario.ctx());
    let order_id_hi = tiny_clob::ticket_order_id(&ticket_hi);

    scenario.next_tx(ADMIN);
    let ticket_lo = rest_bid(&mut book, CH2_PRICE, 200, 1_000_000_000, scenario.ctx());
    let order_id_lo = tiny_clob::ticket_order_id(&ticket_lo);
    assert!(order_id_hi != order_id_lo, 0);

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(300, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, 300, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id_hi), 1);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id_lo), 2);

    scenario.next_tx(ADMIN);
    assert!(tiny_clob::update_resting_order(&mut book, &ticket_lo, OTHER), 3);
    unit_test::destroy(ticket_hi);
    unit_test::destroy(ticket_lo);

    tiny_clob::push_proceeds(&cap, &mut book, order_id_lo, scenario.ctx());
    tiny_clob::push_proceeds(&cap, &mut book, order_id_hi, scenario.ctx());

    scenario.next_tx(OTHER);
    let payout_other = ts::take_from_address<coin::Coin<BTC>>(&scenario, OTHER);
    assert!(coin::value(&payout_other) == 100, 4);
    coin::burn_for_testing(payout_other);
    // hi order's proceeds still belong to ADMIN, untouched by the lo sync.
    let payout_admin = ts::take_from_address<coin::Coin<BTC>>(&scenario, ADMIN);
    assert!(coin::value(&payout_admin) == 200, 5);
    coin::burn_for_testing(payout_admin);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_failed_reassign_after_full_fill_does_not_sync_owner() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Unlike update_resting_order_not_found_is_a_noop above (which probes a
    // never-existing order_id / a wrong id at an existing price level), this
    // targets the not-found path where the order genuinely DID exist and was
    // only just removed from the tree by being fully filled, while its
    // proceeds stay pooled. Reassignment must report not-found and must NOT
    // retarget those pooled proceeds.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let order_id = tiny_clob::ticket_order_id(&bid_ticket);

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, _) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote); // fully filled -> no longer resting

    scenario.next_tx(ADMIN);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, order_id), 0);
    // Order is gone from the tree -> update must report not-found...
    assert!(!tiny_clob::update_resting_order(&mut book, &bid_ticket, OTHER), 1);
    unit_test::destroy(bid_ticket);

    // ...and must NOT have retargeted the pooled proceeds.
    tiny_clob::push_proceeds(&cap, &mut book, order_id, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 2);
    let (ev_claimant, _, _, _) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}


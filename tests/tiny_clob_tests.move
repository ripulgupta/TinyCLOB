#[test_only]
module tiny_clob::tiny_clob_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};

const ADMIN: address = @0xA11CE;
const OTHER: address = @0xB0B;
const TAKER: address = @0x2002;
const MAKER_A: address = @0xA001;
const MAKER_B: address = @0xA002;
const MAKER_C: address = @0xA003;

const MIN_SIZE: u64 = 100;
const MAX_MIN_SIZE: u64 = 1_000_000_000_000_000;

fun new_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    tiny_clob::new<BTC, USDC>(MIN_SIZE, 0, 0, 0, 19, 1, scenario.ctx())
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
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(book, price, size), ctx);
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(book, price, size, payment, max_fills, ctx);
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);
    option::destroy_some(ticket_opt)
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
    let (ticket_opt, leftover_base, matched_quote, _) =
        tiny_clob::place_limit_order_ask(book, price, size, payment, max_fills, ctx);
    coin::burn_for_testing(leftover_base);
    coin::burn_for_testing(matched_quote);
    option::destroy_some(ticket_opt)
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
    let (book, cap) = tiny_clob::new<BTC, USDC>(0, 0, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob)] // tiny_clob::EMinSizeTooLarge
fun new_min_size_too_large_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(MAX_MIN_SIZE + 1, 0, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_size_at_max_boundary_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(MAX_MIN_SIZE, 0, 0, 0, 19, 1, scenario.ctx());
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
        MIN_SIZE, 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx(),
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

    // This bid crosses the resting ask above at the same price/size, so it
    // fully fills and never rests: the returned ticket option is `none`.
    let quote_cost = tiny_clob::bid_escrow_amount(book, FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE);
    let payment = coin::mint_for_testing<USDC>(quote_cost, scenario.ctx());
    let (bid_ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(book, FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE, payment, 1_000_000_000, scenario.ctx());
    option::destroy_none(bid_ticket_opt);
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);

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

    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE), scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, stopped) = tiny_clob::match_bid_for_testing(
        &mut book, option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_base_val = coin::burn_for_testing(matched_base);
    let remaining_budget_val = coin::burn_for_testing(remaining_budget);
    let (fee_base_after, fee_quote_after) = tiny_clob::fee_accumulator_balances(&book);

    assert!(matched_base_val == expected_matched_base, 0);
    assert!(remaining_budget_val == tiny_clob::bid_escrow_amount(&book, FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE) - expected_quote_cost, 1);
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
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, FEE_ROUND_PRICE, 999), scenario.ctx());
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
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, FEE_ROUND_PRICE, 1000), scenario.ctx());
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
            tiny_clob::bid_escrow_amount(&book, FEE_ROUND_PRICE, dust_fill_size), scenario.ctx(),
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
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, FILL_INPLACE_PRICE, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(FILL_INPLACE_PRICE), 100, payment1, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base1);
    coin::burn_for_testing(remaining_budget1);
    assert!(remaining_size1 == 0, 0);
    assert!(tiny_clob::depth_at_price(&book, false, FILL_INPLACE_PRICE) == 400, 1); // 200 (A left) + 200 (B)

    // A large enough fill to drain the rest of A, then start on B: if A had
    // been silently demoted behind B, the first `OrderFilled` event here
    // would be for B instead of A.
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, FILL_INPLACE_PRICE, 250), scenario.ctx());
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

    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, FILL_INPLACE_PRICE, 150), scenario.ctx());
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
            tiny_clob::bid_escrow_amount(&book, FILL_INPLACE_PRICE, fill_size), scenario.ctx(),
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
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, price, 100), scenario.ctx());
    let (matched_base1, remaining_budget1, remaining_size1, _) =
        tiny_clob::match_bid_for_testing(&mut book, option::some(price), 100, payment1, 1_000_000, scenario.ctx());
    coin::burn_for_testing(matched_base1);
    coin::burn_for_testing(remaining_budget1);
    assert!(remaining_size1 == 0, 0);

    // Second taker buys 500 more: must drain A's remaining 200 first, then
    // B's full 200, then C's partial 100 — in that order.
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, price, 500), scenario.ctx());
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
        let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, price, 100), scenario.ctx());
        let (matched_base, remaining_budget, remaining_size, _) =
            tiny_clob::match_bid_for_testing(&mut book, option::some(price), 100, payment, 1_000_000, scenario.ctx());
        coin::burn_for_testing(matched_base);
        coin::burn_for_testing(remaining_budget);
        assert!(remaining_size == 0, i);
        assert!(tiny_clob::depth_at_price(&book, false, price) == 500 - (i + 1) * 100 + 100, 20 + i);
        i = i + 1;
    };

    // A is now fully drained, so the sixth fill must land on B.
    let payment6 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, price, 100), scenario.ctx());
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
    let payment1 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, price, 100), scenario.ctx());
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
    let payment2 = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, price, 500), scenario.ctx());
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

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, CH2_PRICE, CH2_SIZE, payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 0, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    let ticket = option::destroy_some(ticket_opt);
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
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, CH2_PRICE, CH2_SIZE, payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == 0, 2);
    let ticket = option::destroy_some(ticket_opt);
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

    let budget = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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

    let budget = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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
    let expected_quote = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, size - fill_size);
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
    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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
        MIN_SIZE, 0, 0, 0, 19, 1, &wrapper_uid, scenario.ctx(),
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
    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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
    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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

    let escrow_amount = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, CH2_SIZE);
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
    let (ask_ticket_opt, ask_matched_base, ask_leftover_base, ask_stop) =
        tiny_clob::place_limit_order_ask(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, ask_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(ask_matched_base) == 0, 0);
    assert!(coin::burn_for_testing(ask_leftover_base) == 0, 1);
    assert!(!ask_stop, 2);
    let ask_ticket = option::destroy_some(ask_ticket_opt);

    scenario.next_tx(TAKER);
    let bid_payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, bid_stop) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, bid_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(bid_matched_base) == PLACEMENT_SIZE, 3);
    assert!(coin::burn_for_testing(bid_leftover_quote) == 0, 4);
    assert!(!bid_stop, 5);
    assert!(bid_ticket_opt.is_none(), 6);
    option::destroy_none(bid_ticket_opt);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun place_limit_order_zero_price_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket_opt, mb, ml, _) = tiny_clob::place_limit_order_bid(&mut book, 0, PLACEMENT_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
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
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE - 1, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
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
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
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
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
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
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 3);
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
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
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
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
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
    let budget2 = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
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
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
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
    let budget = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE);
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
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 1);
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
    let min_quote_bound = tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE) + 1;
    let (leftover_base, matched_quote, stop) = tiny_clob::swap_ask(
        &mut book, PLACEMENT_SIZE, ask_payment, 10, option::none(),
        option::some(min_quote_bound), option::none(), scenario.ctx(),
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
    assert!(coin::burn_for_testing(cancel_quote) == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 1);

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
    // This bid crosses the resting ask above at the same price/size, so it
    // fully fills and never rests: the returned ticket option is `none`.
    let bid_payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), scenario.ctx());
    let (bid_ticket_opt, bid_matched_base, bid_leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, bid_payment, 10, scenario.ctx());
    option::destroy_none(bid_ticket_opt);
    coin::burn_for_testing(bid_matched_base);
    coin::burn_for_testing(bid_leftover_quote);

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
    assert!(quote_amt == tiny_clob::bid_escrow_amount(&book, PLACEMENT_PRICE, PLACEMENT_SIZE), 2);
    coin::burn_for_testing(claim_base);
    coin::burn_for_testing(claim_quote);
    assert!(returned_ticket_opt.is_none(), 3);
    option::destroy_none(returned_ticket_opt);

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
    let expected_escrow_refund = tiny_clob::bid_escrow_amount(&book, CH2_PRICE, remaining_size);
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

// =====================================================================
// Option<OrderTicket> return: place_limit_order_bid/ask must only hand back
// a live ticket when the order genuinely rests. A fully-filled or
// max_fills-truncated placement must return `option::none()`.
// =====================================================================

const OPT_PRICE: u64 = 50_000;

#[test]
fun place_limit_order_bid_fully_fills_returns_none() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 100, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 100, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_bid_truncated_by_max_fills_returns_none() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    // Two separate resting asks at the same price, so a bid limited to a
    // single fill can only drain the front one.
    let ask_a = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let ask_b = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 200), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 200, payment, 1, scenario.ctx());
    // Truncated after exactly one fill: 100 base matched, 100 remains
    // unmatched, but `should_rest` is false because the sweep stopped on
    // max_fills rather than genuinely running out of counterparty depth.
    assert!(stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 100, 1);
    assert!(coin::burn_for_testing(leftover_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(ask_a);
    unit_test::destroy(ask_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_bid_partial_fill_rests_returns_some_and_ticket_is_usable() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 300), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 300, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 100, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    assert!(ticket_opt.is_some(), 3);
    let ticket = option::destroy_some(ticket_opt);

    // The returned ticket genuinely rests for the unmatched 200 remainder:
    // cancelling it must hand back exactly that escrow.
    let (cb, cq) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cb) == 0, 4);
    assert!(coin::burn_for_testing(cq) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 200), 5);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_fully_fills_returns_none() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<BTC>(100, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, OPT_PRICE, 100, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_truncated_by_max_fills_returns_none() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_a = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());
    let bid_b = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<BTC>(200, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, OPT_PRICE, 200, payment, 1, scenario.ctx());
    assert!(stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 100, 1);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_none(), 3);
    option::destroy_none(ticket_opt);

    unit_test::destroy(bid_a);
    unit_test::destroy(bid_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun place_limit_order_ask_partial_fill_rests_returns_some_and_ticket_is_usable() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<BTC>(300, scenario.ctx());
    let (ticket_opt, leftover_base, matched_quote, stopped) =
        tiny_clob::place_limit_order_ask(&mut book, OPT_PRICE, 300, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), 2);
    assert!(ticket_opt.is_some(), 3);
    let ticket = option::destroy_some(ticket_opt);

    // Nothing has matched against the resting 200-base remainder yet, so
    // claim_proceeds pays nothing but must still hand the ticket back
    // (it genuinely rests), proving it's a fully valid, reusable ticket.
    let (cb, cq, ticket_opt2) = tiny_clob::claim_proceeds(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cb) == 0, 4);
    assert!(coin::burn_for_testing(cq) == 0, 5);
    assert!(ticket_opt2.is_some(), 6);
    let ticket2 = option::destroy_some(ticket_opt2);

    let (rb, rq) = tiny_clob::cancel_order(&mut book, ticket2, scenario.ctx());
    assert!(coin::burn_for_testing(rb) == 200, 7);
    assert!(coin::burn_for_testing(rq) == 0, 8);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// REGRESSION: with a nonzero taker fee, a fully-filled bid's `matched_base`
/// is net of a ceiling-rounded fee, so `size - coin::value(&matched_base)`
/// is nonzero even though the order does NOT rest. A caller naively deriving
/// "still resting" from that subtraction would wrongly treat this ticket as
/// live. The real returned ticket option must be `none()`.
#[test]
fun place_limit_order_bid_full_fill_with_taker_fee_still_returns_none() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_taker_fee(&cap, &mut book, 10); // 10 bps

    let ask_ticket = rest_ask(&mut book, OPT_PRICE, 100, 1_000_000_000, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<USDC>(tiny_clob::bid_escrow_amount(&book, OPT_PRICE, 100), scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, OPT_PRICE, 100, payment, 1_000_000_000, scenario.ctx());
    assert!(!stopped, 0);
    // Fee-net matched amount: ceil(100 * 10 / 10_000) = 1 taker fee -> 99.
    // The naive `size - coin::value(&matched_base)` derivation gives
    // 100 - 99 = 1 (nonzero), which would incorrectly imply the order is
    // still resting with 1 unit left. It is not: the order fully filled.
    let matched_value = coin::burn_for_testing(matched_base);
    assert!(matched_value == 99, 1);
    assert!(matched_value != 100, 2); // sanity: the naive derivation would be off
    assert!(coin::burn_for_testing(leftover_quote) == 0, 3);
    assert!(ticket_opt.is_none(), 4);
    option::destroy_none(ticket_opt);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Phase 1 price-scaling redesign: price_scale/precision/exponent/price_band_factor/last_price ===

#[test]
#[expected_failure(abort_code = 20, location = tiny_clob)] // EPriceRangeInfeasible
fun new_infeasible_precision_exponent_aborts() {
    let mut scenario = ts::begin(ADMIN);
    // base_decimals=0, quote_decimals=0: scale_lo = ceil(10^precision) = 10^19;
    // scale_hi = floor(u64::MAX / 10^exponent) = floor(u64::MAX / 10^19) = 1.
    // scale_lo (10^19) > scale_hi (1) -> infeasible.
    let (book, cap) = tiny_clob::new<BTC, USDC>(MIN_SIZE, 0, 0, 19, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A BTC(8 decimals)/USDC(6 decimals)-style book, configured to represent
/// prices up to 10^19 true quote-per-base units. With this book's derived
/// `price_scale` (184), `price = scale * 79_000` decodes to a true price of
/// $7,900,000 per BTC (not $79,000 — `price / price_scale` = 79,000, but the
/// true price also carries the `10^(quote_decimals - base_decimals)` =
/// `10^-2` factor, so the true price is `79_000 / 10^-2` = 7,900,000),
/// which this book's raw (unscaled) `u64` `price` representation cannot
/// express in its natural orientation at all. Places an order at that
/// price, confirms it rests, and confirms `bid_escrow_amount` computes the
/// expected scaled escrow.
#[test]
fun btc_usdc_realistic_price_scale_end_to_end() {
    let mut scenario = ts::begin(ADMIN);
    // exponent=19 (not a "round" 10^N true-price bound): price_scale is
    // derived to *maximize* precision subject to the u64 ceiling, so with
    // base_decimals > quote_decimals the resulting price_scale is small
    // (on the order of 10^(base_decimals - quote_decimals)), which in turn
    // pushes the *minimum* representable raw price above 1 — hence seeding
    // `initial_last_price` with a comfortably-clear-of-the-minimum value
    // rather than `1`.
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(MIN_SIZE, 8, 6, 0, 19, 1_000_000_000, scenario.ctx());
    let scale = tiny_clob::price_scale(&book);

    let price = scale * 79_000; // true price = $7,900,000 per BTC (see doc comment above)
    let size = 100_000; // base atoms (8 decimals)
    let expected_escrow = tiny_clob::bid_escrow_amount(&book, price, size);
    // price is an exact multiple of scale, so the ceiling division is exact.
    assert!(expected_escrow == 79_000 * size, 0);

    let payment = coin::mint_for_testing<USDC>(expected_escrow, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, stopped) =
        tiny_clob::place_limit_order_bid(&mut book, price, size, payment, 10, scenario.ctx());
    assert!(!stopped, 1);
    assert!(coin::burn_for_testing(matched_base) == 0, 2);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 3);
    assert!(ticket_opt.is_some(), 4);
    let ticket = ticket_opt.destroy_some();
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), price) == size, 5);

    let (b, q) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(b) == 0, 6);
    assert!(coin::burn_for_testing(q) == expected_escrow, 7);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Pair-decimal coverage: realistic decimal combinations ===
//
// The tests below exercise `price_scale` derivation and the resulting raw
// `price` range for decimal-pair shapes not covered by
// `btc_usdc_realistic_price_scale_end_to_end` above: a base/quote decimals
// reversal (USDC/BTC), two more common Sui-ecosystem decimal shapes
// (BTC/SUI, SUI/BTC), and a same-decimals pair (WAL/SUI, both 9 decimals).
//
// For each pair, `P_min`/`P_max` (the smallest/largest raw `price` that
// `assert_price_in_declared_range` accepts) are derived by hand from that
// function's two inequalities, mirroring the derivation in its doc comment:
//   scale * 10^quote_dec <= price * 10^base_dec * 10^precision   (min bound)
//   price * 10^base_dec <= 10^exponent * scale * 10^quote_dec    (max bound)
// which solve to:
//   P_min = ceil(scale * 10^quote_dec / (10^base_dec * 10^precision))
//   P_max = floor(10^exponent * scale * 10^quote_dec / 10^base_dec)
// with `scale` itself derived the same way `new`/`price_scale` derive it
// (see that function's doc comment): `scale_hi = floor(u64::MAX * 10^base_dec
// / (10^quote_dec * 10^exponent))`, and `price_scale = scale_hi` whenever
// `scale_hi <= u64::MAX` (true for every book below). These were computed
// out-of-band (Python, mirroring the exact integer arithmetic) and are
// hardcoded here as named constants with the derivation shown per-test;
// `bid_escrow_amount` itself is always called through the real API rather
// than hand-computed, so only the raw `price` values below are "derived
// offline" — the escrow amounts they produce are asserted against the
// book's own computation.

/// `USDC/BTC`: `Base` = USDC (6 decimals), `Quote` = BTC (8 decimals) — the
/// reverse orientation of `btc_usdc_realistic_price_scale_end_to_end` above,
/// i.e. this book's raw prices express "BTC per USDC". A true BTC/USDC spot
/// price around $117,647 implies a true USDC/BTC price around
/// 1/117,647 ≈ 0.0000085 (8.5e-6) BTC per USDC — a tiny fraction, so this
/// book needs `precision` deep enough to represent values below `10^-6`.
/// `precision=8, exponent=0` declares a representable true-price range of
/// `[10^-8, 10^0]`, which comfortably straddles 8.5e-6 with margin on both
/// ends (unlike the BTC/USDC book, the max true price here is bounded by 1,
/// since a fraction of a BTC per USDC can never realistically reach 1).
///
/// With `base_decimals=6, quote_decimals=8, precision=8, exponent=0`:
/// `scale_hi = floor(u64::MAX * 10^6 / (10^8 * 10^0)) = floor(u64::MAX / 100)
/// = 184_467_440_737_095_516 = price_scale`.
/// `P_min = ceil(scale * 10^8 / (10^6 * 10^8)) = ceil(scale / 10^6)
/// = 184_467_440_738`.
/// `P_max = floor(10^0 * scale * 10^8 / 10^6) = floor(scale * 100)
/// = 18_446_744_073_709_551_600`.
#[test]
fun usdc_btc_reversed_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 184_467_440_738;
    let p_max: u64 = 18_446_744_073_709_551_600;
    // Realistic mid-range price: true price ≈ 8.5e-6 BTC per USDC (see doc
    // comment above), which decodes to this raw price via
    // `price = true_price * price_scale * 10^(quote_dec - base_dec)`.
    let p_mid: u64 = 156_797_403_025_233;

    let (mut book, cap) = tiny_clob::new<USDC, BTC>(MIN_SIZE, 6, 8, 8, 0, p_mid, scenario.ctx());
    let scale = tiny_clob::price_scale(&book);
    assert!(scale == 184_467_440_737_095_516, 0);

    // (b) Extreme minimum representable raw price: rests, checks depth,
    // cancels, verifies exact escrow refund.
    let size = MIN_SIZE;
    let min_escrow = tiny_clob::bid_escrow_amount(&book, p_min, size);
    let min_payment = coin::mint_for_testing<BTC>(min_escrow, scenario.ctx());
    let (min_ticket_opt, min_matched, min_leftover, min_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_min, size, min_payment, 10, scenario.ctx());
    assert!(!min_stopped, 1);
    assert!(coin::burn_for_testing(min_matched) == 0, 2);
    assert!(coin::burn_for_testing(min_leftover) == 0, 3);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_min) == size, 4);
    let (min_b, min_q) = tiny_clob::cancel_order(&mut book, min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(min_b) == 0, 5);
    assert!(coin::burn_for_testing(min_q) == min_escrow, 6);

    // (c) Extreme maximum representable raw price: same checks.
    let max_escrow = tiny_clob::bid_escrow_amount(&book, p_max, size);
    let max_payment = coin::mint_for_testing<BTC>(max_escrow, scenario.ctx());
    let (max_ticket_opt, max_matched, max_leftover, max_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_max, size, max_payment, 10, scenario.ctx());
    assert!(!max_stopped, 7);
    assert!(coin::burn_for_testing(max_matched) == 0, 8);
    assert!(coin::burn_for_testing(max_leftover) == 0, 9);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_max) == size, 10);
    let (max_b, max_q) = tiny_clob::cancel_order(&mut book, max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(max_b) == 0, 11);
    assert!(coin::burn_for_testing(max_q) == max_escrow, 12);

    // (d) Two adjacent raw price ticks at a realistic fair-value level: both
    // rest as genuinely distinct price levels.
    let mid_size = 1_000;
    let mid_escrow = tiny_clob::bid_escrow_amount(&book, p_mid, mid_size);
    let mid_payment = coin::mint_for_testing<BTC>(mid_escrow, scenario.ctx());
    let (mid_ticket_opt, mid_matched, mid_leftover, mid_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid, mid_size, mid_payment, 10, scenario.ctx());
    assert!(!mid_stopped, 13);
    assert!(coin::burn_for_testing(mid_matched) == 0, 14);
    assert!(coin::burn_for_testing(mid_leftover) == 0, 15);

    let p_mid_next = p_mid + 1;
    let mid_next_escrow = tiny_clob::bid_escrow_amount(&book, p_mid_next, mid_size);
    let mid_next_payment = coin::mint_for_testing<BTC>(mid_next_escrow, scenario.ctx());
    let (mid_next_ticket_opt, mid_next_matched, mid_next_leftover, mid_next_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid_next, mid_size, mid_next_payment, 10, scenario.ctx());
    assert!(!mid_next_stopped, 16);
    assert!(coin::burn_for_testing(mid_next_matched) == 0, 17);
    assert!(coin::burn_for_testing(mid_next_leftover) == 0, 18);

    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid) == mid_size, 19);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid_next) == mid_size, 20);
    assert!(p_mid != p_mid_next, 21);

    unit_test::destroy(mid_ticket_opt.destroy_some());
    unit_test::destroy(mid_next_ticket_opt.destroy_some());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// `BTC/SUI`: `Base` = BTC (8 decimals), `Quote` = SUI (9 decimals). A true
/// BTC/SUI spot price around 33,714 SUI per BTC (e.g. BTC ≈ $118,000, SUI ≈
/// $3.50). `precision=0, exponent=6` declares a representable true-price
/// range of `[10^0, 10^6]` (1 to 1,000,000 SUI per BTC), comfortably
/// straddling 33,714 with wide margin on both ends — SUI/BTC has never been,
/// and is unlikely soon to be, outside that six-decade band.
///
/// With `base_decimals=8, quote_decimals=9, precision=0, exponent=6`:
/// `scale_hi = floor(u64::MAX * 10^8 / (10^9 * 10^6)) = floor(u64::MAX /
/// 10^7) = 1_844_674_407_370 = price_scale`.
/// `P_min = ceil(scale * 10^9 / (10^8 * 10^0)) = ceil(scale * 10) =
/// 18_446_744_073_700`.
/// `P_max = floor(10^6 * scale * 10^9 / 10^8) = floor(scale * 10^7) =
/// 18_446_744_073_700_000_000`.
#[test]
fun btc_sui_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 18_446_744_073_700;
    let p_max: u64 = 18_446_744_073_700_000_000;
    // Realistic mid-range price: true price = 33,714 SUI per BTC (see doc
    // comment above).
    let p_mid: u64 = 621_913_529_700_721_800;

    let (mut book, cap) = tiny_clob::new<BTC, SUI>(MIN_SIZE, 8, 9, 0, 6, p_mid, scenario.ctx());
    let scale = tiny_clob::price_scale(&book);
    assert!(scale == 1_844_674_407_370, 0);

    // (b) Extreme minimum representable raw price.
    let size = MIN_SIZE;
    let min_escrow = tiny_clob::bid_escrow_amount(&book, p_min, size);
    let min_payment = coin::mint_for_testing<SUI>(min_escrow, scenario.ctx());
    let (min_ticket_opt, min_matched, min_leftover, min_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_min, size, min_payment, 10, scenario.ctx());
    assert!(!min_stopped, 1);
    assert!(coin::burn_for_testing(min_matched) == 0, 2);
    assert!(coin::burn_for_testing(min_leftover) == 0, 3);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_min) == size, 4);
    let (min_b, min_q) = tiny_clob::cancel_order(&mut book, min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(min_b) == 0, 5);
    assert!(coin::burn_for_testing(min_q) == min_escrow, 6);

    // (c) Extreme maximum representable raw price.
    let max_escrow = tiny_clob::bid_escrow_amount(&book, p_max, size);
    let max_payment = coin::mint_for_testing<SUI>(max_escrow, scenario.ctx());
    let (max_ticket_opt, max_matched, max_leftover, max_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_max, size, max_payment, 10, scenario.ctx());
    assert!(!max_stopped, 7);
    assert!(coin::burn_for_testing(max_matched) == 0, 8);
    assert!(coin::burn_for_testing(max_leftover) == 0, 9);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_max) == size, 10);
    let (max_b, max_q) = tiny_clob::cancel_order(&mut book, max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(max_b) == 0, 11);
    assert!(coin::burn_for_testing(max_q) == max_escrow, 12);

    // (d) Two adjacent raw price ticks at a realistic fair-value level.
    let mid_size = 1_000;
    let mid_escrow = tiny_clob::bid_escrow_amount(&book, p_mid, mid_size);
    let mid_payment = coin::mint_for_testing<SUI>(mid_escrow, scenario.ctx());
    let (mid_ticket_opt, mid_matched, mid_leftover, mid_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid, mid_size, mid_payment, 10, scenario.ctx());
    assert!(!mid_stopped, 13);
    assert!(coin::burn_for_testing(mid_matched) == 0, 14);
    assert!(coin::burn_for_testing(mid_leftover) == 0, 15);

    let p_mid_next = p_mid + 1;
    let mid_next_escrow = tiny_clob::bid_escrow_amount(&book, p_mid_next, mid_size);
    let mid_next_payment = coin::mint_for_testing<SUI>(mid_next_escrow, scenario.ctx());
    let (mid_next_ticket_opt, mid_next_matched, mid_next_leftover, mid_next_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid_next, mid_size, mid_next_payment, 10, scenario.ctx());
    assert!(!mid_next_stopped, 16);
    assert!(coin::burn_for_testing(mid_next_matched) == 0, 17);
    assert!(coin::burn_for_testing(mid_next_leftover) == 0, 18);

    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid) == mid_size, 19);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid_next) == mid_size, 20);
    assert!(p_mid != p_mid_next, 21);

    unit_test::destroy(mid_ticket_opt.destroy_some());
    unit_test::destroy(mid_next_ticket_opt.destroy_some());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// `SUI/BTC`: `Base` = SUI (9 decimals), `Quote` = BTC (8 decimals) — the
/// reverse orientation of the BTC/SUI book above, i.e. raw prices express
/// "BTC per SUI". A true SUI/BTC spot price around 1/33,714 ≈ 0.0000297
/// (2.97e-5) BTC per SUI. `precision=8, exponent=0` declares a representable
/// true-price range of `[10^-8, 10^0]`, comfortably straddling 2.97e-5.
///
/// With `base_decimals=9, quote_decimals=8, precision=8, exponent=0`:
/// `scale_hi = floor(u64::MAX * 10^9 / (10^8 * 10^0)) = floor(u64::MAX * 10)
/// `, which exceeds `u64::MAX`, so `price_scale = u64::MAX =
/// 18_446_744_073_709_551_615` (the `scale_hi > u64::MAX` clamp case in
/// `new_impl`, unlike the other three books here where `scale_hi` itself is
/// the binding value).
/// `P_min = ceil(scale * 10^8 / (10^9 * 10^8)) = ceil(scale / 10) =
/// 18_446_744_074` (rounds up since `scale` is odd).
/// `P_max = floor(10^0 * scale * 10^8 / 10^9) = floor(scale / 10) =
/// 1_844_674_407_370_955_161`.
#[test]
fun sui_btc_reversed_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 18_446_744_074;
    let p_max: u64 = 1_844_674_407_370_955_161;
    // Realistic mid-range price: true price ≈ 2.97e-5 BTC per SUI (see doc
    // comment above).
    let p_mid: u64 = 54_715_382_552_380;

    let (mut book, cap) = tiny_clob::new<SUI, BTC>(MIN_SIZE, 9, 8, 8, 0, p_mid, scenario.ctx());
    let scale = tiny_clob::price_scale(&book);
    assert!(scale == 18_446_744_073_709_551_615, 0);

    // (b) Extreme minimum representable raw price.
    let size = MIN_SIZE;
    let min_escrow = tiny_clob::bid_escrow_amount(&book, p_min, size);
    let min_payment = coin::mint_for_testing<BTC>(min_escrow, scenario.ctx());
    let (min_ticket_opt, min_matched, min_leftover, min_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_min, size, min_payment, 10, scenario.ctx());
    assert!(!min_stopped, 1);
    assert!(coin::burn_for_testing(min_matched) == 0, 2);
    assert!(coin::burn_for_testing(min_leftover) == 0, 3);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_min) == size, 4);
    let (min_b, min_q) = tiny_clob::cancel_order(&mut book, min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(min_b) == 0, 5);
    assert!(coin::burn_for_testing(min_q) == min_escrow, 6);

    // (c) Extreme maximum representable raw price.
    let max_escrow = tiny_clob::bid_escrow_amount(&book, p_max, size);
    let max_payment = coin::mint_for_testing<BTC>(max_escrow, scenario.ctx());
    let (max_ticket_opt, max_matched, max_leftover, max_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_max, size, max_payment, 10, scenario.ctx());
    assert!(!max_stopped, 7);
    assert!(coin::burn_for_testing(max_matched) == 0, 8);
    assert!(coin::burn_for_testing(max_leftover) == 0, 9);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_max) == size, 10);
    let (max_b, max_q) = tiny_clob::cancel_order(&mut book, max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(max_b) == 0, 11);
    assert!(coin::burn_for_testing(max_q) == max_escrow, 12);

    // (d) Two adjacent raw price ticks at a realistic fair-value level.
    let mid_size = 1_000;
    let mid_escrow = tiny_clob::bid_escrow_amount(&book, p_mid, mid_size);
    let mid_payment = coin::mint_for_testing<BTC>(mid_escrow, scenario.ctx());
    let (mid_ticket_opt, mid_matched, mid_leftover, mid_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid, mid_size, mid_payment, 10, scenario.ctx());
    assert!(!mid_stopped, 13);
    assert!(coin::burn_for_testing(mid_matched) == 0, 14);
    assert!(coin::burn_for_testing(mid_leftover) == 0, 15);

    let p_mid_next = p_mid + 1;
    let mid_next_escrow = tiny_clob::bid_escrow_amount(&book, p_mid_next, mid_size);
    let mid_next_payment = coin::mint_for_testing<BTC>(mid_next_escrow, scenario.ctx());
    let (mid_next_ticket_opt, mid_next_matched, mid_next_leftover, mid_next_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid_next, mid_size, mid_next_payment, 10, scenario.ctx());
    assert!(!mid_next_stopped, 16);
    assert!(coin::burn_for_testing(mid_next_matched) == 0, 17);
    assert!(coin::burn_for_testing(mid_next_leftover) == 0, 18);

    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid) == mid_size, 19);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid_next) == mid_size, 20);
    assert!(p_mid != p_mid_next, 21);

    unit_test::destroy(mid_ticket_opt.destroy_some());
    unit_test::destroy(mid_next_ticket_opt.destroy_some());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// `WAL/SUI`: a same-decimals pair (`Base` = WAL, `Quote` = SUI, both 9
/// decimals) — the case `base_decimals == quote_decimals`, where the
/// `10^(base_dec - quote_dec)` scaling factor from the module's true-price
/// formula is exactly 1 and raw price tracks true price most directly of
/// any shape covered here. A plausible WAL/SUI true price around 2.5 SUI
/// per WAL. `precision=2, exponent=4` declares a representable true-price
/// range of `[10^-2, 10^4]` (0.01 to 10,000), comfortably straddling 2.5.
///
/// With `base_decimals=9, quote_decimals=9, precision=2, exponent=4`:
/// `scale_hi = floor(u64::MAX * 10^9 / (10^9 * 10^4)) = floor(u64::MAX /
/// 10^4) = 1_844_674_407_370_955 = price_scale`.
/// `P_min = ceil(scale * 10^9 / (10^9 * 10^2)) = ceil(scale / 100) =
/// 18_446_744_073_710`.
/// `P_max = floor(10^4 * scale * 10^9 / 10^9) = floor(scale * 10^4) =
/// 18_446_744_073_709_550_000`.
#[test]
fun wal_sui_same_decimals_pair_price_extremes_and_adjacent_ticks() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 18_446_744_073_710;
    let p_max: u64 = 18_446_744_073_709_550_000;
    // Realistic mid-range price: true price = 2.5 SUI per WAL (see doc
    // comment above).
    let p_mid: u64 = 4_611_686_018_427_388;

    let (mut book, cap) = tiny_clob::new<WAL, SUI>(MIN_SIZE, 9, 9, 2, 4, p_mid, scenario.ctx());
    let scale = tiny_clob::price_scale(&book);
    assert!(scale == 1_844_674_407_370_955, 0);

    // (b) Extreme minimum representable raw price.
    let size = MIN_SIZE;
    let min_escrow = tiny_clob::bid_escrow_amount(&book, p_min, size);
    let min_payment = coin::mint_for_testing<SUI>(min_escrow, scenario.ctx());
    let (min_ticket_opt, min_matched, min_leftover, min_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_min, size, min_payment, 10, scenario.ctx());
    assert!(!min_stopped, 1);
    assert!(coin::burn_for_testing(min_matched) == 0, 2);
    assert!(coin::burn_for_testing(min_leftover) == 0, 3);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_min) == size, 4);
    let (min_b, min_q) = tiny_clob::cancel_order(&mut book, min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(min_b) == 0, 5);
    assert!(coin::burn_for_testing(min_q) == min_escrow, 6);

    // (c) Extreme maximum representable raw price.
    let max_escrow = tiny_clob::bid_escrow_amount(&book, p_max, size);
    let max_payment = coin::mint_for_testing<SUI>(max_escrow, scenario.ctx());
    let (max_ticket_opt, max_matched, max_leftover, max_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_max, size, max_payment, 10, scenario.ctx());
    assert!(!max_stopped, 7);
    assert!(coin::burn_for_testing(max_matched) == 0, 8);
    assert!(coin::burn_for_testing(max_leftover) == 0, 9);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_max) == size, 10);
    let (max_b, max_q) = tiny_clob::cancel_order(&mut book, max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(max_b) == 0, 11);
    assert!(coin::burn_for_testing(max_q) == max_escrow, 12);

    // (d) Two adjacent raw price ticks at a realistic fair-value level.
    let mid_size = 1_000;
    let mid_escrow = tiny_clob::bid_escrow_amount(&book, p_mid, mid_size);
    let mid_payment = coin::mint_for_testing<SUI>(mid_escrow, scenario.ctx());
    let (mid_ticket_opt, mid_matched, mid_leftover, mid_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid, mid_size, mid_payment, 10, scenario.ctx());
    assert!(!mid_stopped, 13);
    assert!(coin::burn_for_testing(mid_matched) == 0, 14);
    assert!(coin::burn_for_testing(mid_leftover) == 0, 15);

    let p_mid_next = p_mid + 1;
    let mid_next_escrow = tiny_clob::bid_escrow_amount(&book, p_mid_next, mid_size);
    let mid_next_payment = coin::mint_for_testing<SUI>(mid_next_escrow, scenario.ctx());
    let (mid_next_ticket_opt, mid_next_matched, mid_next_leftover, mid_next_stopped) =
        tiny_clob::place_limit_order_bid(&mut book, p_mid_next, mid_size, mid_next_payment, 10, scenario.ctx());
    assert!(!mid_next_stopped, 16);
    assert!(coin::burn_for_testing(mid_next_matched) == 0, 17);
    assert!(coin::burn_for_testing(mid_next_leftover) == 0, 18);

    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid) == mid_size, 19);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::bid_for_testing(), p_mid_next) == mid_size, 20);
    assert!(p_mid != p_mid_next, 21);

    unit_test::destroy(mid_ticket_opt.destroy_some());
    unit_test::destroy(mid_next_ticket_opt.destroy_some());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
fun price_band_factor_just_inside_band_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_last_price(&mut book, 1000, scenario.ctx());
    tiny_clob::clob_admin_set_price_band_factor(&cap, &mut book, option::some(2));
    // band: [1000/2, 1000*2] = [500, 2000]
    let low_ticket = rest_bid(&mut book, 500, MIN_SIZE, 10, scenario.ctx());
    let high_ticket = rest_bid(&mut book, 2000, MIN_SIZE, 10, scenario.ctx());
    unit_test::destroy(low_ticket);
    unit_test::destroy(high_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23, location = tiny_clob)] // EPriceBelowBand
fun price_band_factor_just_outside_band_below_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_last_price(&mut book, 1000, scenario.ctx());
    tiny_clob::clob_admin_set_price_band_factor(&cap, &mut book, option::some(2));
    let ticket = rest_bid(&mut book, 499, MIN_SIZE, 10, scenario.ctx()); // just below the [500, 2000] band
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 24, location = tiny_clob)] // EPriceAboveBand
fun price_band_factor_just_outside_band_above_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_last_price(&mut book, 1000, scenario.ctx());
    tiny_clob::clob_admin_set_price_band_factor(&cap, &mut book, option::some(2));
    let ticket = rest_bid(&mut book, 2001, MIN_SIZE, 10, scenario.ctx()); // just above the [500, 2000] band
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_empty_book_is_unconstrained() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_last_price(&mut book, 12_345, scenario.ctx());
    assert!(tiny_clob::last_price_for_testing(&book) == 12_345, 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 26, location = tiny_clob)] // EResetPriceBelowBestBid
fun set_last_price_below_best_bid_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_bid(&mut book, 1000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 999, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_at_or_above_best_bid_succeeds_with_only_bid_present() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_bid(&mut book, 1000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 1000, scenario.ctx()); // exactly the best bid
    assert!(tiny_clob::last_price_for_testing(&book) == 1000, 0);
    tiny_clob::set_last_price(&mut book, 5_000_000, scenario.ctx()); // far above; no best ask to bound it
    assert!(tiny_clob::last_price_for_testing(&book) == 5_000_000, 1);
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 27, location = tiny_clob)] // EResetPriceAboveBestAsk
fun set_last_price_above_best_ask_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_ask(&mut book, 2000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 2001, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_at_or_below_best_ask_succeeds_with_only_ask_present() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_ask(&mut book, 2000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 2000, scenario.ctx()); // exactly the best ask
    assert!(tiny_clob::last_price_for_testing(&book) == 2000, 0);
    tiny_clob::set_last_price(&mut book, 1, scenario.ctx()); // far below; no best bid to bound it
    assert!(tiny_clob::last_price_for_testing(&book) == 1, 1);
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun set_last_price_within_spread_both_sides_present_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 1000, MIN_SIZE, 10, scenario.ctx());
    let ask_ticket = rest_ask(&mut book, 2000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 1500, scenario.ctx());
    assert!(tiny_clob::last_price_for_testing(&book) == 1500, 0);
    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 26, location = tiny_clob)] // EResetPriceBelowBestBid
fun set_last_price_below_bid_both_sides_present_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 1000, MIN_SIZE, 10, scenario.ctx());
    let ask_ticket = rest_ask(&mut book, 2000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 999, scenario.ctx());
    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 27, location = tiny_clob)] // EResetPriceAboveBestAsk
fun set_last_price_above_ask_both_sides_present_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 1000, MIN_SIZE, 10, scenario.ctx());
    let ask_ticket = rest_ask(&mut book, 2000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 2001, scenario.ctx());
    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// A resting-ask sweep spans two price levels (100, then 200). The taker's
/// market-bid budget covers only the first level exactly, so the second
/// level's iteration computes `affordable_qty == 0` and breaks without ever
/// filling — `last_price` must reflect the first (real) fill's price and
/// must NOT be touched by the second, no-fill iteration.
#[test]
fun last_price_updates_on_real_fill_not_on_zero_qty_iteration() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask1 = rest_ask(&mut book, 100, MIN_SIZE, 10, scenario.ctx());
    let ask2 = rest_ask(&mut book, 200, MIN_SIZE, 10, scenario.ctx());
    assert!(tiny_clob::last_price_for_testing(&book) == 1, 0); // untouched: nothing filled yet

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(&book, 100, MIN_SIZE); // exactly covers ask1, nothing left for ask2
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, stopped) = tiny_clob::place_market_order_bid(
        &mut book, MIN_SIZE * 2, budget, payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 1);
    assert!(coin::burn_for_testing(matched_base) == MIN_SIZE, 2); // only ask1 filled
    assert!(coin::burn_for_testing(remaining_budget) == 0, 3);
    assert!(coin::burn_for_testing(leftover) == 0, 4);
    assert!(tiny_clob::last_price_for_testing(&book) == 100, 5); // ask1's price, not ask2's

    unit_test::destroy(ask1);
    unit_test::destroy(ask2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Market orders carry no price parameter/check, but must still update
/// `last_price` after a real fill — exercised here on the ask side (the
/// bid side is already covered by the zero-qty-iteration test above).
#[test]
fun market_order_ask_updates_last_price_after_real_fill() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, 300, MIN_SIZE, 10, scenario.ctx());
    assert!(tiny_clob::last_price_for_testing(&book) == 1, 0); // untouched: nothing filled yet

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<BTC>(MIN_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, stopped) =
        tiny_clob::place_market_order_ask(&mut book, MIN_SIZE, payment, 10, option::none(), option::none(), scenario.ctx());
    assert!(!stopped, 1);
    assert!(coin::burn_for_testing(leftover_base) == 0, 2);
    assert!(coin::burn_for_testing(matched_quote) == 300 * MIN_SIZE, 3);
    assert!(tiny_clob::last_price_for_testing(&book) == 300, 4);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Regression: F2 `affordable_qty` u128->u64 narrowing DoS ===
//
// price_scale = floor(u64::MAX / 10^9) = 18_446_744_073 (base=quote=0,
// precision=9, exponent=9). A resting ask at a low raw price plus a large
// taker budget makes (budget * price_scale / best_price) exceed u64::MAX
// before clamping; the old code narrowed to u64 before the `min` with
// `natural_fill_qty` and aborted the whole order instead of correctly
// clamping. With the fix, the order succeeds and the taker's fill is
// correctly bounded by the resting ask's size.
#[test]
fun affordable_qty_narrowing_does_not_abort_for_large_budget_taker() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 9, 9, 1_000_000_000, scenario.ctx());
    assert!(tiny_clob::price_scale(&book) == 18_446_744_073, 0);
    // Cheapest representable raw price is 19 (P ~= 1.03e-9 >= 10^-9).
    let ask_ticket = rest_ask(&mut book, 19, 1_000, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget: u64 = 20_000_000_000; // 2e10 quote atoms
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover_payment, stopped) = tiny_clob::place_market_order_bid(
        &mut book, 1_000, budget, payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    // The resting ask only has 1_000 base atoms available, so the fill is
    // capped by natural_fill_qty (1_000), not by an abort.
    assert!(coin::burn_for_testing(matched_base) == 1_000, 1);
    assert!(!stopped, 2);
    coin::burn_for_testing(remaining_budget);
    coin::burn_for_testing(leftover_payment);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Regression: F3 `price_scale` silently landing below `scale_lo` ===
//
// base=30, quote=0, precision=0, exponent=19:
//   scale_lo = 10^30, scale_hi = floor(u64::MAX * 10^30 / 10^19) ~= 1.8e30
//   scale_lo <= scale_hi, so without the `scale_lo <= u64::MAX` conjunct the
//   old code let construction succeed with price_scale = min(scale_hi,
//   u64::MAX) = u64::MAX, far below the true scale_lo -- silently delivering
//   coarser precision than declared. The fix rejects this with
//   EPriceRangeInfeasible instead.
#[test]
#[expected_failure(abort_code = 20, location = tiny_clob)] // EPriceRangeInfeasible
fun price_scale_below_scale_lo_now_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(1, 30, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Regression: resting-remainder escrow rounding shortfall ===
//
// `place_limit_order_bid` used to recompute the resting remainder's escrow
// from scratch via a fresh `bid_escrow_amount(book, price, remaining_size)`
// call, which -- by ceiling-division superadditivity -- can demand strictly
// more than what's actually left over in the taker's escrow after the
// crossing sweep, aborting a legitimate partial-cross-then-rest order. The
// fix instead derives the resting remainder's SIZE from what escrow is
// actually left over -- `actual_resting_size =
// min(remaining_size, floor(available * price_scale / price))` -- so the
// resting reservation (`bid_escrow_amount(book, price, actual_resting_size)`)
// can never exceed what's available by construction. `fill_level_ask`'s
// per-fill accumulator charges a proportional floor of the resting order's
// actual `total_reserved` (never a fresh, independently-rounded ceiling),
// so the running total can never exceed what was truly reserved.
//
// Book: base_decimals=0, quote_decimals=0, precision=1, exponent=18 =>
// price_scale = floor(u64::MAX / 10^18) = 18 exactly. At price=5:
//   bid_escrow_amount(price=5, size=10) = ceil(50/18)  = 3  (funds the bid)
//   fill charge for the 1-unit sweep    = ceil(5*1/18) = 1
//   leftover after the sweep                           = 3 - 1 = 2
//   bid_escrow_amount(price=5, size=9)  = ceil(45/18)  = 3  (naive fresh
//     target, which would exceed the 2 left over -- exactly the
//     rounding-shortfall scenario this fix closes)
//   actual_resting_size = floor(2*18/5)                = 7  (derived size,
//     backed by bid_escrow_amount(price=5, size=7) = ceil(35/18) = 2 <= 2)
const SHORTFALL_PRICE_SCALE: u64 = 18;
const SHORTFALL_PRICE: u64 = 5;

fun shortfall_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    let (book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 1, 18, SHORTFALL_PRICE, scenario.ctx());
    assert!(tiny_clob::price_scale(&book) == SHORTFALL_PRICE_SCALE, 0);
    (book, cap)
}

#[test]
fun partial_cross_then_rest_clamps_resting_escrow_to_available() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = shortfall_book(&mut scenario);

    // One resting ask of size 1: the incoming bid below crosses exactly
    // this much before resting its remainder.
    scenario.next_tx(MAKER_A);
    let ask_ticket = rest_ask(&mut book, SHORTFALL_PRICE, 1, 10, scenario.ctx());

    assert!(tiny_clob::bid_escrow_amount(&book, SHORTFALL_PRICE, 10) == 3, 1);
    assert!(tiny_clob::bid_escrow_amount(&book, SHORTFALL_PRICE, 9) == 3, 2);

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, SHORTFALL_PRICE, 10, payment, 10, scenario.ctx());
    // Must NOT abort: the resting remainder's escrow is clamped to what's
    // actually left over (2), not the fresh (unaffordable) recomputation
    // of 3.
    assert!(option::is_some(&ticket_opt), 3);
    assert!(coin::burn_for_testing(matched_base) == 1, 4);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 5);
    let bid_ticket = option::destroy_some(ticket_opt);

    // Prove the clamp directly: nothing has been charged against the
    // resting order yet, so cancelling now must refund exactly the
    // clamped 2, not the fresh target of 3.
    scenario.next_tx(TAKER);
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cq) == 2, 6);
    assert!(coin::burn_for_testing(cb) == 0, 7);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// A partial-cross-then-rest order's resting SIZE is itself derived from what
// the leftover escrow can actually back (Part J's fix), not the full
// post-sweep `remaining_size`: here `remaining_size` after the sweep is 9,
// but only 2 quote atoms are left in escrow, which at
// `price=5`/`price_scale=18` backs at most `floor(2*18/5) = 7` base atoms —
// so the resting order's true size is 7, not 9, and its
// `bid_escrow_amount(price=5, size=7) = ceil(35/18) = 2` exactly matches
// what's available (guaranteed by construction — see
// `place_limit_order_bid`'s doc comment). That resting size-of-7 order must
// be drainable to completion across MULTIPLE separate taker transactions
// with zero dust: reaching full drain without `destroy_drained_bid_escrow`'s
// internal `balance::destroy_zero` aborting is itself the proof (any
// stranded dust would abort there instead).
#[test]
fun partial_cross_then_rest_full_drain_across_multiple_fills_is_zero_dust() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(MAKER_A);
    let ask_ticket = rest_ask(&mut book, SHORTFALL_PRICE, 1, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, SHORTFALL_PRICE, 10, payment, 10, scenario.ctx());
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);
    let bid_ticket = option::destroy_some(ticket_opt);

    // Drain the resting 7-unit remainder across TWO separate transactions
    // (separate ask takers), summing exactly to 7.
    let fill_sizes = vector<u64>[3, 4];
    let mut total_base: u64 = 0;
    let mut total_quote: u64 = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let sz = fill_sizes[i];
        scenario.next_tx(MAKER_B);
        let base = coin::mint_for_testing<BTC>(sz, scenario.ctx());
        let (t, lb, mq, _) =
            tiny_clob::place_limit_order_ask(&mut book, SHORTFALL_PRICE, sz, base, 10, scenario.ctx());
        // Each ask fully crosses the resting bid's remaining size, so no
        // ask-side ticket ever rests and no base is ever left over.
        assert!(option::is_none(&t), 100 + i);
        option::destroy_none(t);
        assert!(coin::burn_for_testing(lb) == 0, 200 + i);
        total_base = total_base + sz;
        total_quote = total_quote + coin::burn_for_testing(mq);
        i = i + 1;
    };
    assert!(total_base == 7, 8);
    // Zero dust, zero shortfall: the sum paid out across all separate
    // fills exactly equals the resting order's clamped `total_reserved`
    // (2), not the unaffordable ceiling-based fresh target (3) the old
    // scheme implied.
    assert!(total_quote == 2, 9);

    // The order is now fully drained and gone; cancelling the stale
    // ticket yields nothing further from escrow, only pooled proceeds.
    scenario.next_tx(TAKER);
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cq) == 0, 10);
    assert!(coin::burn_for_testing(cb) == 7, 11);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// A FRESH resting bid (never partially crossed at placement, so
// `total_reserved` exactly equals the once-reserved `bid_escrow_amount`)
// must still telescope to an exact lifetime total under the new
// proportional-floor accumulator, across an odd partition into several
// separate fills/transactions -- matching the fix design's claim that the
// final outcome for this (common) case is unaffected, even though
// intermediate per-fill amounts may differ slightly from the old
// delta-of-cumulative-ceilings scheme.
#[test]
fun fresh_order_lifetime_total_still_exact_under_proportional_floor() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = shortfall_book(&mut scenario);

    let size: u64 = 100;
    scenario.next_tx(MAKER_A);
    let reserved = tiny_clob::bid_escrow_amount(&book, SHORTFALL_PRICE, size);
    assert!(reserved == 28, 0); // ceil(5*100/18) = ceil(27.77..) = 28
    let bid_ticket = rest_bid(&mut book, SHORTFALL_PRICE, size, 10, scenario.ctx());

    // An odd partition of 100 that does not divide evenly against the
    // scale, so intermediate proportional floors necessarily claw back
    // rounding from earlier fills.
    let fill_sizes = vector<u64>[7, 13, 29, 51];
    let mut total_charged: u64 = 0;
    let mut i = 0;
    while (i < fill_sizes.length()) {
        let sz = fill_sizes[i];
        scenario.next_tx(MAKER_B);
        let base = coin::mint_for_testing<BTC>(sz, scenario.ctx());
        let (t, lb, mq, _) =
            tiny_clob::place_limit_order_ask(&mut book, SHORTFALL_PRICE, sz, base, 10, scenario.ctx());
        assert!(option::is_none(&t), 100 + i);
        option::destroy_none(t);
        assert!(coin::burn_for_testing(lb) == 0, 200 + i);
        total_charged = total_charged + coin::burn_for_testing(mq);
        i = i + 1;
    };
    // Lifetime total is exact: identical to what the once-reserved escrow
    // demanded, with zero dust, regardless of the odd partition.
    assert!(total_charged == reserved, 1);

    scenario.next_tx(TAKER);
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cq) == 0, 2);
    assert!(coin::burn_for_testing(cb) == size, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Regression: L-01 -- ceiling (not floor) division on the per-fill
// escrow charge, closing the "free base, full refund" exploit ===
//
// When `total_reserved < original_size` (the shortfall scenario above), a
// small fill's proportional share of `total_reserved` can be a fraction
// less than 1. A FLOOR-based accumulator (the scheme this file used to
// document, see the section above) rounds that fraction down to 0, so
// `quote_charged_so_far` stays at 0 even though the maker's resting bid
// already paid out real `Base` to the taker for that fill. A maker could
// then cancel immediately afterward and receive a FULL escrow refund (since
// nothing was ever recorded as charged) while keeping the `Base` they
// already received for free -- extracting real value for zero payment.
//
// `fill_level_ask` now charges each fill a proportional CEILING of
// `total_reserved`, clamped at `total_reserved` itself (the clamp is
// defensive/redundant: `ceil(total_reserved * original_size / original_size)
// == total_reserved` exactly at full fill). This guarantees any fill with
// `cumulative_filled >= 1` charges `cumulative_charged >= 1`, so
// `quote_charged_so_far` becomes nonzero after any real fill -- a maker
// cancelling afterward forfeits at least 1 quote atom of escrow, closing the
// exploit. (This does not guarantee every individual fill of a
// multi-taker-filled order charges nonzero marginal `quote_cost` -- a later
// filler of the same order can still see a 0 marginal charge if an earlier
// filler already absorbed the whole tiny escrow. That residual is bounded
// under 1 quote atom of true value and is an accepted, understood
// trade-off, not addressed by this fix.)
//
// Uses the same shortfall book as above (`price=5`, `price_scale=18`):
// resting bid remainder after the placement-time clamp has
// `original_size=7`, `total_reserved=2` (see the derivation in the
// "resting-remainder escrow rounding shortfall" section). A 1-unit fill's
// proportional share is `2*1/7 = 0.2857...`:
//   floor(2*1/7) = 0  -- the OLD scheme: quote_cost = 0, exploit possible.
//   ceil(2*1/7)  = 1  -- the FIX: quote_cost = 1, nonzero.
#[test]
fun tiny_fill_charges_nonzero_quote_and_forfeits_escrow_on_cancel() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = shortfall_book(&mut scenario);

    // One resting ask of size 1 so the incoming bid below crosses exactly
    // this much before resting its remainder (identical setup to
    // `partial_cross_then_rest_clamps_resting_escrow_to_available`).
    scenario.next_tx(MAKER_A);
    let ask_ticket = rest_ask(&mut book, SHORTFALL_PRICE, 1, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<USDC>(3, scenario.ctx());
    let (ticket_opt, matched_base, leftover_quote, _) =
        tiny_clob::place_limit_order_bid(&mut book, SHORTFALL_PRICE, 10, payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(matched_base) == 1, 0);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 1);
    let bid_ticket = option::destroy_some(ticket_opt);
    // Resting remainder: original_size=7, total_reserved=2 (clamped, per the
    // shortfall derivation above).

    // A tiny 1-unit ask fills the resting bid's front (only) order by 1 --
    // small enough that `2*1/7` floors to 0 under the old scheme, but
    // ceils to 1 under the fix.
    scenario.next_tx(MAKER_B);
    let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (t, leftover_base, matched_quote, _) =
        tiny_clob::place_limit_order_ask(&mut book, SHORTFALL_PRICE, 1, base, 10, scenario.ctx());
    assert!(option::is_none(&t), 2); // fully consumed by the resting bid
    option::destroy_none(t);
    assert!(coin::burn_for_testing(leftover_base) == 0, 3);
    // The maker fee bps is 0 in this book, so taker fee is also 0: the full
    // charged quote_cost flows through to the ask taker as matched_quote.
    // This is the fix in action: under the old floor scheme this would be
    // 0; under the ceiling fix it is 1 -- nonzero.
    assert!(coin::burn_for_testing(matched_quote) == 1, 4);

    // Cancel the resting bid immediately after. Under the OLD floor scheme,
    // `quote_charged_so_far` would still read 0 here, so the maker would
    // get back the FULL `total_reserved` (2) in the quote leg while ALSO
    // having already received 1 unit of `Base` for free via the pooled
    // proceeds joined into `cancel_order`'s base return -- the exploit.
    // Under the fix, the maker's quote refund is strictly less than
    // `total_reserved`: they forfeit exactly the 1 quote atom that was
    // actually charged for the free base they received.
    scenario.next_tx(TAKER);
    let (cb, cq) = tiny_clob::cancel_order(&mut book, bid_ticket, scenario.ctx());
    let cb_val = coin::burn_for_testing(cb);
    let cq_val = coin::burn_for_testing(cq);
    assert!(cb_val == 1, 5); // the free base, received via pooled proceeds
    assert!(cq_val < 2, 6); // strictly less than total_reserved -- forfeited
    assert!(cq_val == 1, 7); // exact: total_reserved(2) - charged(1) = 1

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Coverage-audit gap closures ===
//
// The tests below close specific gaps identified by a blind test-coverage
// audit of `assert_price_in_declared_range`'s reject side, `last_price`
// across multi-level matches, the price-band's market-order exemption,
// `EZeroPriceBandFactor`, `EZeroPrice` at all four call sites, and
// `EDecimalsTooLarge`, plus an ask-side boundary-tick counterpart to the
// existing bid-side decimal-pair tests.

// --- `assert_price_in_declared_range` reject-side boundaries ---
//
// The four `*_price_extremes_and_adjacent_ticks` tests above prove `p_min`/
// `p_max` are ACCEPTED; the tests below prove `p_min - 1`/`p_max + 1` are
// REJECTED, on two independently-derived decimal pairs (USDC/BTC reversed,
// BTC/SUI), plus two construction-site (`new_impl`) tests proving the same
// check is wired at a call site other than order placement.

#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun usdc_btc_reversed_pair_price_just_below_min_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 184_467_440_738;
    let p_mid: u64 = 156_797_403_025_233;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(MIN_SIZE, 6, 8, 8, 0, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<BTC>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_min - 1, MIN_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun usdc_btc_reversed_pair_price_just_above_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let p_max: u64 = 18_446_744_073_709_551_600;
    let p_mid: u64 = 156_797_403_025_233;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(MIN_SIZE, 6, 8, 8, 0, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<BTC>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_max + 1, MIN_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun btc_sui_pair_price_just_below_min_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 18_446_744_073_700;
    let p_mid: u64 = 621_913_529_700_721_800;
    let (mut book, cap) = tiny_clob::new<BTC, SUI>(MIN_SIZE, 8, 9, 0, 6, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_min - 1, MIN_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun btc_sui_pair_price_just_above_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let p_max: u64 = 18_446_744_073_700_000_000;
    let p_mid: u64 = 621_913_529_700_721_800;
    let (mut book, cap) = tiny_clob::new<BTC, SUI>(MIN_SIZE, 8, 9, 0, 6, p_mid, scenario.ctx());
    let payment = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    let (ticket_opt, mb, ml, _) =
        tiny_clob::place_limit_order_bid(&mut book, p_max + 1, MIN_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket_opt);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// Proves `assert_price_in_declared_range`'s reject side is also wired at
/// the construction call site (`new_impl`), not only at order placement —
/// same USDC/BTC-reversed pair and `p_min` as the order-placement test
/// above, but passed as `initial_last_price` to `new` directly.
#[test]
#[expected_failure(abort_code = 21, location = tiny_clob)] // EPriceBelowDeclaredMin
fun new_initial_last_price_just_below_declared_min_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 184_467_440_738;
    let (book, cap) = tiny_clob::new<USDC, BTC>(MIN_SIZE, 6, 8, 8, 0, p_min - 1, scenario.ctx());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

/// Mirrors the test above for the max-side construction-site check.
#[test]
#[expected_failure(abort_code = 22, location = tiny_clob)] // EPriceAboveDeclaredMax
fun new_initial_last_price_just_above_declared_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let p_max: u64 = 18_446_744_073_709_551_600;
    let (book, cap) = tiny_clob::new<USDC, BTC>(MIN_SIZE, 6, 8, 8, 0, p_max + 1, scenario.ctx());
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}

// --- `last_price` across multiple fully-filled price levels in one match ---
//
// Unlike `last_price_updates_on_real_fill_not_on_zero_qty_iteration` above
// (where the second level is touched but never actually fills), the tests
// below fully drain BOTH resting levels in a single match and assert
// `last_price` reflects the LAST level touched, not the first.

#[test]
fun last_price_reflects_last_of_two_fully_filled_ask_levels() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask1 = rest_ask(&mut book, 100, MIN_SIZE, 10, scenario.ctx());
    let ask2 = rest_ask(&mut book, 200, MIN_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    // Exactly covers both levels: 100*MIN_SIZE + 200*MIN_SIZE.
    let budget = tiny_clob::bid_escrow_amount(&book, 100, MIN_SIZE)
        + tiny_clob::bid_escrow_amount(&book, 200, MIN_SIZE);
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, stopped) = tiny_clob::place_market_order_bid(
        &mut book, MIN_SIZE * 2, budget, payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == MIN_SIZE * 2, 1); // both levels fully filled
    assert!(coin::burn_for_testing(remaining_budget) == 0, 2);
    assert!(coin::burn_for_testing(leftover) == 0, 3);
    assert!(tiny_clob::last_price_for_testing(&book) == 200, 4); // the LAST level touched, not the first

    unit_test::destroy(ask1);
    unit_test::destroy(ask2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Mirrors the test above for two fully-drained bid levels swept by one
/// market ask order: best bid (300) is consumed first, then the next-best
/// (200) — `last_price` must land on 200, the last level touched.
#[test]
fun last_price_reflects_last_of_two_fully_filled_bid_levels() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid1 = rest_bid(&mut book, 300, MIN_SIZE, 10, scenario.ctx());
    let bid2 = rest_bid(&mut book, 200, MIN_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let payment = coin::mint_for_testing<BTC>(MIN_SIZE * 2, scenario.ctx());
    let (leftover_base, matched_quote, stopped) = tiny_clob::place_market_order_ask(
        &mut book, MIN_SIZE * 2, payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1); // both levels fully filled
    assert!(coin::burn_for_testing(matched_quote) == 300 * MIN_SIZE + 200 * MIN_SIZE, 2);
    assert!(tiny_clob::last_price_for_testing(&book) == 200, 3); // the LAST level touched, not the first

    unit_test::destroy(bid1);
    unit_test::destroy(bid2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- Price-band exemption for market orders / no-limit swaps ---
//
// `place_market_order_bid`/`_ask` and `swap_bid`/`_ask` (when called with
// `limit_price = option::none()`) never read `book.price_band_factor` at
// all in the source — the band only ever gates a NEW RESTING limit-order
// price, never a taker fill. The tests below pin this down concretely: a
// resting ask is placed outside a band that is tightened only afterward,
// then a market order / swap with no limit price is shown to fill against
// it anyway.

#[test]
fun market_order_bid_fills_against_resting_ask_outside_subsequently_set_band() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    // Rest the ask BEFORE any band exists, at a price far outside the band
    // that will be set below.
    let ask_ticket = rest_ask(&mut book, 5000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 1000, scenario.ctx()); // <= best_ask (5000), so this succeeds
    tiny_clob::clob_admin_set_price_band_factor(&cap, &mut book, option::some(2));
    // band is now [500, 2000] -- 5000 is well outside it.

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(&book, 5000, MIN_SIZE);
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, stopped) = tiny_clob::place_market_order_bid(
        &mut book, MIN_SIZE, budget, payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == MIN_SIZE, 1); // filled despite being outside the band
    assert!(coin::burn_for_testing(remaining_budget) == 0, 2);
    assert!(coin::burn_for_testing(leftover) == 0, 3);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Mirrors the test above for `swap_bid` called with `limit_price =
/// option::none()`.
#[test]
fun swap_bid_with_no_limit_price_fills_against_resting_ask_outside_band() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, 5000, MIN_SIZE, 10, scenario.ctx());
    tiny_clob::set_last_price(&mut book, 1000, scenario.ctx());
    tiny_clob::clob_admin_set_price_band_factor(&cap, &mut book, option::some(2));
    // band is now [500, 2000] -- 5000 is well outside it.

    scenario.next_tx(TAKER);
    let budget = tiny_clob::bid_escrow_amount(&book, 5000, MIN_SIZE);
    let payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, stopped) = tiny_clob::swap_bid(
        &mut book, MIN_SIZE, budget, payment, 10, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == MIN_SIZE, 1); // filled despite being outside the band
    assert!(coin::burn_for_testing(remaining_budget) == 0, 2);
    assert!(coin::burn_for_testing(leftover) == 0, 3);

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `EZeroPriceBandFactor` ---

#[test]
#[expected_failure(abort_code = 25, location = tiny_clob)] // EZeroPriceBandFactor
fun clob_admin_set_price_band_factor_zero_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_set_price_band_factor(&cap, &mut book, option::some(0));
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `EZeroPrice` at all four call sites ---

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun new_zero_initial_last_price_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(MIN_SIZE, 0, 0, 0, 19, 0, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun set_last_price_zero_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_last_price(&mut book, 0, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun place_limit_order_bid_zero_price_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_bid(&mut book, 0, MIN_SIZE, 10, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 14, location = tiny_clob)] // EZeroPrice
fun place_limit_order_ask_zero_price_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ticket = rest_ask(&mut book, 0, MIN_SIZE, 10, scenario.ctx());
    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `EDecimalsTooLarge` ---

#[test]
#[expected_failure(abort_code = 28, location = tiny_clob)] // EDecimalsTooLarge
fun new_base_decimals_over_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    // MAX_DECIMALS = 38; 39 is one over.
    let (book, cap) = tiny_clob::new<BTC, USDC>(MIN_SIZE, 39, 0, 0, 19, 1, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- `place_limit_order_ask` boundary-tick coverage ---
//
// Analogous to `usdc_btc_reversed_pair_price_extremes_and_adjacent_ticks`
// above, but through `place_limit_order_ask` instead of `_bid`, to catch a
// site-specific bug in the ask copy of the range/band check that the
// bid-side tests wouldn't catch.
#[test]
fun usdc_btc_reversed_pair_ask_side_price_extremes() {
    let mut scenario = ts::begin(ADMIN);
    let p_min: u64 = 184_467_440_738;
    let p_max: u64 = 18_446_744_073_709_551_600;
    let p_mid: u64 = 156_797_403_025_233;
    let (mut book, cap) = tiny_clob::new<USDC, BTC>(MIN_SIZE, 6, 8, 8, 0, p_mid, scenario.ctx());
    let size = MIN_SIZE;

    // (a) Extreme minimum representable raw price: rests, checks depth,
    // cancels, verifies exact base refund.
    let min_payment = coin::mint_for_testing<USDC>(size, scenario.ctx());
    let (min_ticket_opt, min_leftover, min_matched, min_stopped) =
        tiny_clob::place_limit_order_ask(&mut book, p_min, size, min_payment, 10, scenario.ctx());
    assert!(!min_stopped, 0);
    assert!(coin::burn_for_testing(min_leftover) == 0, 1);
    assert!(coin::burn_for_testing(min_matched) == 0, 2);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::ask_for_testing(), p_min) == size, 3);
    let (min_b, min_q) = tiny_clob::cancel_order(&mut book, min_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(min_b) == size, 4);
    assert!(coin::burn_for_testing(min_q) == 0, 5);

    // (b) Extreme maximum representable raw price: same checks.
    let max_payment = coin::mint_for_testing<USDC>(size, scenario.ctx());
    let (max_ticket_opt, max_leftover, max_matched, max_stopped) =
        tiny_clob::place_limit_order_ask(&mut book, p_max, size, max_payment, 10, scenario.ctx());
    assert!(!max_stopped, 6);
    assert!(coin::burn_for_testing(max_leftover) == 0, 7);
    assert!(coin::burn_for_testing(max_matched) == 0, 8);
    assert!(tiny_clob::depth_at_price(&book, tiny_clob::ask_for_testing(), p_max) == size, 9);
    let (max_b, max_q) = tiny_clob::cancel_order(&mut book, max_ticket_opt.destroy_some(), scenario.ctx());
    assert!(coin::burn_for_testing(max_b) == size, 10);
    assert!(coin::burn_for_testing(max_q) == 0, 11);

    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
    scenario.end();
}


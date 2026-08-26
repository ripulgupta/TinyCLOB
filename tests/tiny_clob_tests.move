#[test_only]
module tiny_clob::tiny_clob_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed};
use tiny_clob::test_markers::{BTC, USDC};

const ADMIN: address = @0xA11CE;
const OTHER: address = @0xB0B;
const TAKER: address = @0x2002;

const LOT_SIZE: u64 = 100;
const MIN_SIZE: u64 = 100;
const MAX_LOT_OR_MIN_SIZE: u64 = 1_000_000_000_000_000;

fun new_book(scenario: &mut ts::Scenario): (OrderBook<BTC, USDC>, ClobAdminCap) {
    tiny_clob::new<BTC, USDC>(LOT_SIZE, MIN_SIZE, option::none(), scenario.ctx())
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

    assert!(tiny_clob::lot_size(&book) == LOT_SIZE, 0);
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
#[expected_failure(abort_code = 0, location = tiny_clob)] // tiny_clob::EZeroLotSize
fun new_zero_lot_size_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(0, MIN_SIZE, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 1, location = tiny_clob)] // tiny_clob::EZeroMinSize
fun new_zero_min_size_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(LOT_SIZE, 0, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 2, location = tiny_clob)] // tiny_clob::EMinSizeNotMultipleOfLotSize
fun new_min_size_not_multiple_of_lot_size_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(100, 150, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob)] // tiny_clob::ELotOrMinSizeTooLarge
fun new_lot_size_too_large_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(MAX_LOT_OR_MIN_SIZE + 1, MAX_LOT_OR_MIN_SIZE + 1, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob)] // tiny_clob::ELotOrMinSizeTooLarge
fun new_min_size_too_large_aborts_lot_size_valid() {
    let mut scenario = ts::begin(ADMIN);
    // lot_size is within bounds and min_size is a valid multiple of lot_size,
    // but min_size itself exceeds MAX_LOT_OR_MIN_SIZE — isolates the
    // min_size-only branch of the too-large check from the lot_size-only
    // branch already covered by `new_lot_size_too_large_aborts`.
    let (book, cap) =
        tiny_clob::new<BTC, USDC>(LOT_SIZE, MAX_LOT_OR_MIN_SIZE + LOT_SIZE, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_size_at_max_boundary_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = tiny_clob::new<BTC, USDC>(MAX_LOT_OR_MIN_SIZE, MAX_LOT_OR_MIN_SIZE, option::none(), scenario.ctx());
    assert!(tiny_clob::lot_size(&book) == MAX_LOT_OR_MIN_SIZE, 0);
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
    let (book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    // Demonstrates `store`-ability directly: holds the cap as a plain
    // field of a test-only wrapper struct.
    let holder = CapHolder { id: object::new(scenario.ctx()), cap };
    let CapHolder { id, cap } = holder;
    id.delete();

    let cap_id = object::id(&cap);
    tiny_clob::discard_clob_admin_cap(cap);

    let discarded_events = event::events_by_type<tiny_clob::ClobAdminCapDiscarded>();
    assert!(discarded_events.length() == 1, 0);
    let (event_cap_id, event_for_book) = tiny_clob::clob_admin_cap_discarded_fields_for_testing(
        &discarded_events[0],
    );
    assert!(event_cap_id == cap_id, 1);
    assert!(event_for_book == book_id, 2);

    sui::test_utils::destroy(book);
    scenario.end();
}

#[test]
fun version_guard_view_functions_do_not_abort_on_stale_version() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_book_version(&mut book, 999);

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
#[expected_failure]
fun version_guard_pause_aborts_on_stale_version() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_book_version(&mut book, 999);
    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun migration_succeeds_and_updates_version_stale_book_still_callable() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::set_book_version(&mut book, 999);
    // Deliberately does NOT call assert_book_version first — a stale-version
    // book must still accept its own migration call.
    tiny_clob::clob_admin_migrate_book_version(&cap, &mut book, 1);
    assert!(tiny_clob::book_version_is_for_testing(&book, 1), 0);
    // Now non-stale: an ordinary guarded function succeeds.
    tiny_clob::clob_admin_pause_book(&cap, &mut book);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun migration_wrong_new_version_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_migrate_book_version(&cap, &mut book, 999);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun migration_wrong_cap_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    tiny_clob::clob_admin_migrate_book_version(&cap2, &mut book1, 1);
    sui::test_utils::destroy(book1);
    sui::test_utils::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
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
    let deleted_id = tiny_clob::clob_admin_finalize(&cap, book);
    sui::test_utils::destroy(deleted_id);
    sui::test_utils::destroy(cap);
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
    let order = tiny_clob::new_order<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    tiny_clob::clob_admin_retire(&cap, &mut book);
    let deleted_id = tiny_clob::clob_admin_finalize(&cap, book);
    sui::test_utils::destroy(deleted_id);
    sui::test_utils::destroy(cap);
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
    let order = tiny_clob::new_order<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    tiny_clob::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    tiny_clob::clob_admin_retire(&cap, &mut book);
    let retired_events = event::events_by_type<tiny_clob::OrderBookRetired>();
    assert!(retired_events.length() == 1, 0);

    // Repeatable, bounded max_items — one call with max_items = 0 is a no-op.
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 0, scenario.ctx());
    assert!(tiny_clob::bids_size_for_testing(&book) == 1, 1);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 100, scenario.ctx());
    assert!(tiny_clob::bids_size_for_testing(&book) == 0, 2);

    let deleted_id = tiny_clob::clob_admin_finalize(&cap, book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 3);
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        tiny_clob::order_book_deleted_fields_for_testing(&deleted_events[0]);
    assert!(deleted_order_book_id == deleted_id, 4);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 40);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 41);

    sui::test_utils::destroy(cap);
    scenario.end();
}

// `clob_admin_finalize` destroys the book's fee_accumulator legs via
// `balance::destroy_zero`, which aborts (`ENonZero`) if either leg is
// nonzero. The clob_admin_finalize tests above only ever exercise resting-order-only
// scenarios where fee_accumulator stays (0, 0), so that abort path is
// never actually hit. These two tests close that gap: the first generates
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

#[test, expected_failure(abort_code = sui::balance::ENonZero, location = sui::balance)]
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
    let deleted_id = tiny_clob::clob_admin_finalize(&cap, book);

    sui::test_utils::destroy(deleted_id);
    sui::test_utils::destroy(cap);
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
    let deleted_id = tiny_clob::clob_admin_finalize(&cap, book);
    let deleted_events = event::events_by_type<tiny_clob::OrderBookDeleted>();
    assert!(deleted_events.length() == 1, 5);
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        tiny_clob::order_book_deleted_fields_for_testing(&deleted_events[0]);
    assert!(deleted_order_book_id == deleted_id, 6);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 60);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 61);

    sui::test_utils::destroy(cap);
    scenario.end();
}

// --- unpause_after_retire_clears_retiring_gate (accepted design) ---

#[test]
fun unpause_after_retire_clears_retiring_gate() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::clob_admin_unpause_book(&cap, &mut book);

    // `paused` (the merged field) was cleared — `clob_admin_drain_step`'s abort on this
    // state is exercised separately by
    // `drain_step_aborts_after_unpause_clears_retiring_gate` below
    // (Move's `#[expected_failure]` needs its own dedicated test function).
    assert!(!tiny_clob::is_paused(&book), 0);

    // Calling clob_admin_retire again restores the gate.
    tiny_clob::clob_admin_retire(&cap, &mut book);
    assert!(tiny_clob::is_paused(&book), 1);
    tiny_clob::clob_admin_drain_step(&cap, &mut book, 10, scenario.ctx());

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun drain_step_aborts_after_unpause_clears_retiring_gate() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::clob_admin_unpause_book(&cap, &mut book);
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
    let order_id = 7;
    let order_book_id = object::id_from_address(@0xBEEF);
    let side = true;
    let price = 50_000;
    let ticket = tiny_clob::new_ticket_for_testing(order_id, order_book_id, side, price);

    let (t_order_id, t_book_id, t_side, t_price) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_order_id == order_id, 0);
    assert!(t_book_id == order_book_id, 1);
    assert!(t_side == side, 2);
    assert!(t_price == price, 3);

    // No liveness check, no abort, no leaked value — the whole point of a
    // dedicated `public(package)` disposal function.
    tiny_clob::destroy_orphaned_ticket(ticket);
}

// Regression tests for the private `match_bid`/`match_ask` functions,
// invoked directly via the `match_bid_for_testing`/`match_ask_for_testing`
// test-only accessors. Every expected value below is computed
// independently from the known price/size/fee-rate inputs using the fee
// formula in `sources/tiny_clob.move` (`fee_amount`: `receive_amount *
// rate_bps / 10_000`, floored) — not by comparing two invocations of the
// same function. Fee rates are bounded by MAX_TAKER_FEE_BPS/
// MAX_MAKER_FEE_BPS (10/5 bps); 7/3 bps is used here, deliberately
// non-round relative to the fixture sizes so the floor-rounding on both
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
    let ask = tiny_clob::new_order<BTC, USDC>(
        order_id, OTHER, FEE_TEST_RESTING_SIZE, option::some(escrow), option::none(), FEE_TEST_MAKER_FEE_BPS,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, false, FEE_TEST_PRICE, ask, scenario.ctx());

    // Taker fully filled by the larger resting ask, so fill_qty ==
    // FEE_TEST_TAKER_SIZE:
    //   quote_cost = price * fill_qty = 47_500 * 3_400 = 161_500_000
    //   taker_fee_base = floor(fill_qty * taker_bps / 10_000)
    //                  = floor(3_400 * 7 / 10_000) = floor(2.38) = 2
    //   matched_base   = fill_qty - taker_fee_base = 3_400 - 2 = 3_398
    //   maker_fee_quote = floor(quote_cost * maker_bps / 10_000)
    //                   = floor(161_500_000 * 3 / 10_000) = 48_450
    //   remaining_budget = payment - quote_cost = 0 (exact full fill)
    let expected_quote_cost = FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE;
    let expected_taker_fee_base = 2;
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
    let bid = tiny_clob::new_order<BTC, USDC>(
        order_id, OTHER, FEE_TEST_RESTING_SIZE, option::none(), option::some(escrow), FEE_TEST_MAKER_FEE_BPS,
    );
    tiny_clob::insert_resting_order_for_testing(&mut book, true, FEE_TEST_PRICE, bid, scenario.ctx());

    // Taker fully filled by the larger resting bid, so fill_qty ==
    // FEE_TEST_TAKER_SIZE:
    //   quote_cost = price * fill_qty = 47_500 * 3_400 = 161_500_000
    //   taker_fee_quote = floor(quote_cost * taker_bps / 10_000)
    //                   = floor(161_500_000 * 7 / 10_000) = 113_050
    //   matched_quote   = quote_cost - taker_fee_quote = 161_386_950
    //   maker_fee_base = floor(fill_qty * maker_bps / 10_000)
    //                  = floor(3_400 * 3 / 10_000) = floor(1.02) = 1
    //   remaining_escrow = escrow_base - fill_qty = 0 (exact full fill)
    let expected_quote_cost = FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE;
    let expected_taker_fee_quote = 113_050;
    let expected_matched_quote = expected_quote_cost - expected_taker_fee_quote;
    let expected_maker_fee_base = 1;

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
    let order = tiny_clob::new_order<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
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
    let (matched_base, remaining_budget, leftover_payment) = tiny_clob::place_market_order_bid(
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
    let (leftover_payment, matched_quote) = tiny_clob::place_market_order_ask(
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

// `event_id` is write-once, fixed at construction time via
// `event_id_override`, with no setter that could change it afterward. This
// guards against a class of bug where changing a book's event_id after a
// resting order already exists would strand that order's ticket (stale
// `order_book_id`) and make `cancel_order` wrongly abort with
// `EWrongBook`, permanently denying the trader self-service cancellation
// of their own resting order. Since no setter exists, that scenario can't
// be reproduced directly; these tests instead confirm the override
// mechanism behaves correctly and stays stable across
// placement/fill/cancel.

#[test]
fun new_event_id_override_is_used_and_stable_across_placement_and_cancel() {
    let mut scenario = ts::begin(ADMIN);
    let override_id = object::id_from_address(@0xFACE);
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(
        LOT_SIZE, MIN_SIZE, option::some(override_id), scenario.ctx(),
    );

    // The override, not the book's own internal id, is what got stamped.
    let book_own_id = tiny_clob::id_for_testing(&book);
    assert!(tiny_clob::event_id_for_testing(&book) == override_id, 0);
    assert!(override_id != book_own_id, 1);

    // Place a resting bid — the ticket must carry the override id.
    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (_, t_book_id, _, _) = tiny_clob::ticket_fields_for_testing(&ticket);
    assert!(t_book_id == override_id, 2);

    // No function exists that could change event_id after the fact — it is
    // still the override id right before cancellation, and cancel_order
    // (which checks ticket.order_book_id == book.event_id) succeeds.
    assert!(tiny_clob::event_id_for_testing(&book) == override_id, 3);
    let (refund_base, refund_quote) = tiny_clob::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(refund_base) == 0, 4);
    assert!(coin::burn_for_testing(refund_quote) == escrow_amount, 5);

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

    // ADMIN rests a bid; OTHER crosses it as a market ask, crediting
    // ADMIN's maker proceeds table with quote.
    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    scenario.next_tx(OTHER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    scenario.next_tx(ADMIN);
    tiny_clob::claim_proceeds(&mut book, scenario.ctx());

    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_claimant, ev_book_id, ev_base, ev_quote) =
        tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_base == CH2_SIZE, 3);
    assert!(ev_quote == 0, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun clob_admin_push_proceeds_matches_claim_proceeds_when_addr_is_self() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = tiny_clob::id_for_testing(&book);

    let escrow_amount = tiny_clob::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    tiny_clob::clob_admin_push_proceeds(&cap, &mut book, ADMIN, scenario.ctx());

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
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, ADMIN), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_owner_found_reassigns_owner_and_credits_new_owner_on_fill() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // ADMIN rests a bid; its resting order's owner is reassigned to OTHER
    // via update_resting_order_owner before it is ever crossed.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (order_id, _, side, price) = tiny_clob::ticket_fields_for_testing(&bid_ticket);
    unit_test::destroy(bid_ticket);

    let found = tiny_clob::update_resting_order_owner(&mut book, side, price, order_id, OTHER);
    assert!(found, 0);

    // Cross the reassigned resting bid with a market ask from a third party.
    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    // Maker proceeds landed on OTHER (the reassigned owner), not ADMIN (the
    // original owner) — proving the owner field was actually overwritten,
    // not just the ticket's own bookkeeping.
    assert!(tiny_clob::proceeds_contains_for_testing(&book, OTHER), 1);
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, ADMIN), 2);

    scenario.next_tx(OTHER);
    tiny_clob::claim_proceeds(&mut book, scenario.ctx());
    let claimed_events = event::events_by_type<tiny_clob::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 3);
    let (ev_claimant, _, _, _) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == OTHER, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun update_resting_order_owner_not_found_is_a_noop() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // No resting order exists at all yet: neither the price level nor the
    // order_id exist. Must return false and touch nothing.
    let found_empty_book =
        tiny_clob::update_resting_order_owner(&mut book, tiny_clob::bid_for_testing(), CH2_PRICE, 0, OTHER);
    assert!(!found_empty_book, 0);

    // Rest a real bid, then probe with a wrong order_id at the same,
    // now-existing price level — the level exists but the specific order
    // does not.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (order_id, _, side, price) = tiny_clob::ticket_fields_for_testing(&bid_ticket);
    let wrong_order_id = order_id + 1;
    let found_wrong_id = tiny_clob::update_resting_order_owner(&mut book, side, price, wrong_order_id, OTHER);
    assert!(!found_wrong_id, 1);

    // The real order's owner is untouched (still ADMIN): crossing it still
    // credits ADMIN's proceeds, not OTHER's.
    unit_test::destroy(bid_ticket);
    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = tiny_clob::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);
    assert!(tiny_clob::proceeds_contains_for_testing(&book, ADMIN), 2);
    assert!(!tiny_clob::proceeds_contains_for_testing(&book, OTHER), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun clob_admin_push_proceeds_rejects_wrong_cap() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, _cap) = new_book(&mut scenario);
    let (_other_book, wrong_cap) = new_book(&mut scenario);

    tiny_clob::clob_admin_push_proceeds(&wrong_cap, &mut book, ADMIN, scenario.ctx());

    sui::test_utils::destroy(book);
    sui::test_utils::destroy(_cap);
    sui::test_utils::destroy(_other_book);
    sui::test_utils::destroy(wrong_cap);
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
    let (matched_base, remaining_budget, leftover) = tiny_clob::place_market_order_bid(
        &mut book, PLACEMENT_SIZE, budget, bid_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == PLACEMENT_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover) == 0, 2);

    scenario.next_tx(TAKER);
    let bid_ticket2 = rest_bid(&mut book, PLACEMENT_PRICE, PLACEMENT_SIZE, 10, scenario.ctx());
    let ask_payment2 = coin::mint_for_testing<BTC>(PLACEMENT_SIZE, scenario.ctx());
    let (leftover_base, matched_quote) =
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
    let (matched_base, remaining_budget, leftover) = tiny_clob::place_market_order_bid(
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

    // claim_proceeds also succeeds while retiring (paused merged field).
    tiny_clob::clob_admin_retire(&cap, &mut book);
    tiny_clob::claim_proceeds(&mut book, scenario.ctx());

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
    tiny_clob::claim_proceeds(&mut book, scenario.ctx());
    let claimed = event::events_by_type<ProceedsClaimed>();
    assert!(claimed.length() == 1, 0);
    let (claimant, _, _base_amt, quote_amt) = tiny_clob::proceeds_claimed_fields_for_testing(&claimed[0]);
    assert!(claimant == ADMIN, 1);
    assert!(quote_amt == tiny_clob::bid_escrow_amount(PLACEMENT_PRICE, PLACEMENT_SIZE), 2);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}


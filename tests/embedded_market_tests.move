/// `embedded_market.move`'s own unit tests. See `docs/plan-m13.md` Chunks 3
/// and 5, `docs/spec/embedded_market.md`'s own Verification section.
#[test_only]
module tiny_clob::embedded_market_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::embedded_market::{Self, EmbeddedOrderBook, EmbeddedOrderTicket, EmbeddedPoolAdminCap, ProceedsClaimed};
use tiny_clob::test_markers::{BTC, USDC};

const ADMIN: address = @0xA11CE;
const OTHER: address = @0xB0B;
const TAKER: address = @0x2002;

const LOT_SIZE: u64 = 100;
const MIN_SIZE: u64 = 100;
const MAX_LOT_OR_MIN_SIZE: u64 = 1_000_000_000_000_000;

fun new_book(scenario: &mut ts::Scenario): (EmbeddedOrderBook<BTC, USDC>, EmbeddedPoolAdminCap) {
    embedded_market::new<BTC, USDC>(LOT_SIZE, MIN_SIZE, option::none(), scenario.ctx())
}

fun destroy_book_and_cap(book: EmbeddedOrderBook<BTC, USDC>, cap: EmbeddedPoolAdminCap) {
    sui::test_utils::destroy(book);
    sui::test_utils::destroy(cap);
}

/// Rests a bid via `place_limit_order_bid`, discarding the matched/leftover
/// coin legs and returning only the resulting ticket — for call sites that
/// only need the ticket and have no assertions on the trade legs themselves.
fun rest_bid(
    book: &mut EmbeddedOrderBook<BTC, USDC>,
    price: u64,
    size: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): EmbeddedOrderTicket {
    let payment = coin::mint_for_testing<USDC>(embedded_market::bid_escrow_amount(price, size), ctx);
    let (ticket, matched_base, leftover_quote, _) =
        embedded_market::place_limit_order_bid(book, price, size, payment, max_fills, ctx);
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(leftover_quote);
    ticket
}

/// Mirrors `rest_bid` for the ask side.
fun rest_ask(
    book: &mut EmbeddedOrderBook<BTC, USDC>,
    price: u64,
    size: u64,
    max_fills: u64,
    ctx: &mut TxContext,
): EmbeddedOrderTicket {
    let payment = coin::mint_for_testing<BTC>(size, ctx);
    let (ticket, leftover_base, matched_quote, _) =
        embedded_market::place_limit_order_ask(book, price, size, payment, max_fills, ctx);
    coin::burn_for_testing(leftover_base);
    coin::burn_for_testing(matched_quote);
    ticket
}

// === new_succeeds_with_no_capability_argument_and_no_registry_interaction
// (REQ-EMBED-007, REQ-EMBED-016) ===

#[test]
fun new_succeeds_with_no_capability_argument_and_no_registry_interaction() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);

    assert!(embedded_market::lot_size(&book) == LOT_SIZE, 0);
    assert!(embedded_market::min_size(&book) == MIN_SIZE, 1);
    assert!(!embedded_market::is_paused(&book), 2);
    assert!(embedded_market::pool_admin_cap_id(&book) == object::id(&cap), 3);
    let (taker_bps, maker_bps) = embedded_market::fee_config(&book);
    assert!(taker_bps == 0, 4);
    assert!(maker_bps == 0, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === new_size_validation_mirrors_create_market (REQ-EMBED-007) ===

#[test]
#[expected_failure(abort_code = 0, location = tiny_clob::embedded_market)] // embedded_market::EZeroLotSize
fun new_zero_lot_size_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = embedded_market::new<BTC, USDC>(0, MIN_SIZE, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 1, location = tiny_clob::embedded_market)] // embedded_market::EZeroMinSize
fun new_zero_min_size_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = embedded_market::new<BTC, USDC>(LOT_SIZE, 0, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 2, location = tiny_clob::embedded_market)] // embedded_market::EMinSizeNotMultipleOfLotSize
fun new_min_size_not_multiple_of_lot_size_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = embedded_market::new<BTC, USDC>(100, 150, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob::embedded_market)] // embedded_market::ELotOrMinSizeTooLarge
fun new_lot_size_too_large_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = embedded_market::new<BTC, USDC>(MAX_LOT_OR_MIN_SIZE + 1, MAX_LOT_OR_MIN_SIZE + 1, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3, location = tiny_clob::embedded_market)] // embedded_market::ELotOrMinSizeTooLarge
fun new_min_size_too_large_aborts_lot_size_valid() {
    let mut scenario = ts::begin(ADMIN);
    // lot_size is within bounds and min_size is a valid multiple of lot_size,
    // but min_size itself exceeds MAX_LOT_OR_MIN_SIZE — isolates the
    // min_size-only branch of the too-large check from the lot_size-only
    // branch already covered by `new_lot_size_too_large_aborts`.
    let (book, cap) =
        embedded_market::new<BTC, USDC>(LOT_SIZE, MAX_LOT_OR_MIN_SIZE + LOT_SIZE, option::none(), scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_size_at_max_boundary_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = embedded_market::new<BTC, USDC>(MAX_LOT_OR_MIN_SIZE, MAX_LOT_OR_MIN_SIZE, option::none(), scenario.ctx());
    assert!(embedded_market::lot_size(&book) == MAX_LOT_OR_MIN_SIZE, 0);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === two_embedded_books_identical_types_fully_independent
// (construction/accessor half; fill-independence half is m13_integration_tests.move)
// (REQ-EMBED-016) ===

#[test]
fun two_embedded_books_identical_types_fully_independent_construction() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book1, cap1) = new_book(&mut scenario);
    let (mut book2, cap2) = new_book(&mut scenario);

    assert!(embedded_market::id(&book1) != embedded_market::id(&book2), 0);
    assert!(object::id(&cap1) != object::id(&cap2), 1);

    embedded_market::pool_admin_set_taker_fee(&cap1, &mut book1, 5);
    let (taker1, _) = embedded_market::fee_config(&book1);
    let (taker2, _) = embedded_market::fee_config(&book2);
    assert!(taker1 == 5, 2);
    assert!(taker2 == 0, 3);

    destroy_book_and_cap(book1, cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

// === embedded_pool_admin_cap_store_and_discard (REQ-EMBED-003, REQ-EMBED-004) ===

public struct CapHolder has key, store {
    id: UID,
    cap: EmbeddedPoolAdminCap,
}

#[test]
fun embedded_pool_admin_cap_store_and_discard() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    // Demonstrates `store`-ability directly: embeds the cap as a plain
    // field of a test-only wrapper struct.
    let holder = CapHolder { id: object::new(scenario.ctx()), cap };
    let CapHolder { id, cap } = holder;
    id.delete();

    let cap_id = object::id(&cap);
    embedded_market::discard_embedded_pool_admin_cap(cap);

    let discarded_events = event::events_by_type<embedded_market::EmbeddedPoolAdminCapDiscarded>();
    assert!(discarded_events.length() == 1, 0);
    let (event_cap_id, event_for_book) = embedded_market::embedded_pool_admin_cap_discarded_fields_for_testing(
        &discarded_events[0],
    );
    assert!(event_cap_id == cap_id, 1);
    assert!(event_for_book == book_id, 2);

    sui::test_utils::destroy(book);
    scenario.end();
}

// === embedded_version_guard_stale_aborts_migration_succeeds
// (REQ-EMBED-015, REQ-EMBED-017) ===

#[test]
fun embedded_version_guard_view_functions_do_not_abort_on_stale_version() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::set_book_version(&mut book, 999);

    // The five pure-read view functions never assert the version guard.
    let (_taker, _maker) = embedded_market::fee_config(&book);
    let (_base, _quote) = embedded_market::fee_accumulator_balances(&book);
    let _ = embedded_market::is_book_paused(&book);
    let _ = embedded_market::best_bid(&book);
    let _ = embedded_market::best_ask(&book);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_version_guard_pause_aborts_on_stale_version() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::set_book_version(&mut book, 999);
    embedded_market::pool_admin_pause_market(&cap, &mut book);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun embedded_migration_succeeds_and_updates_version_stale_book_still_callable() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::set_book_version(&mut book, 999);
    // Deliberately does NOT call assert_book_version first — a stale-version
    // book must still accept its own migration call.
    embedded_market::migrate_embedded_order_book_version(&cap, &mut book, 1);
    assert!(embedded_market::book_version_is_for_testing(&book, 1), 0);
    // Now non-stale: an ordinary guarded function succeeds.
    embedded_market::pool_admin_pause_market(&cap, &mut book);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_migration_wrong_new_version_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::migrate_embedded_order_book_version(&cap, &mut book, 999);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_migration_wrong_cap_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    embedded_market::migrate_embedded_order_book_version(&cap2, &mut book1, 1);
    sui::test_utils::destroy(book1);
    sui::test_utils::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

// === M13 Chunk 5: EmbeddedPoolAdminCap-gated functions ===

// --- embedded_fee_setters_bounds_and_events (REQ-EMBED-013) ---

#[test]
fun embedded_fee_setters_bounds_and_events() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    embedded_market::pool_admin_set_taker_fee(&cap, &mut book, 10);
    embedded_market::pool_admin_set_maker_fee(&cap, &mut book, 5);
    let (taker, maker) = embedded_market::fee_config(&book);
    assert!(taker == 10, 0);
    assert!(maker == 5, 1);

    let taker_events = event::events_by_type<embedded_market::TakerFeeSet>();
    let maker_events = event::events_by_type<embedded_market::MakerFeeSet>();
    assert!(taker_events.length() == 1, 2);
    assert!(maker_events.length() == 1, 3);
    let (ev_book, ev_rate) = embedded_market::taker_fee_set_fields_for_testing(&taker_events[0]);
    assert!(ev_book == book_id, 4);
    assert!(ev_rate == 10, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- embedded_deletion_lifecycle_retire_drain_finalize (REQ-EMBED-008, REQ-EMBED-017) ---

#[test]
#[expected_failure]
fun embedded_drain_step_before_retire_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::drain_step(&cap, &mut book, 10, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_finalize_before_retire_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);
    let deleted_id = embedded_market::finalize(&cap, book);
    sui::test_utils::destroy(deleted_id);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_finalize_while_nonempty_aborts_not_fully_drained() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = embedded_market::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = embedded_market::new_order<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    embedded_market::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    embedded_market::retire(&cap, &mut book);
    let deleted_id = embedded_market::finalize(&cap, book);
    sui::test_utils::destroy(deleted_id);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
fun embedded_deletion_lifecycle_retire_drain_finalize_succeeds() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let order_id = embedded_market::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = embedded_market::new_order<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    embedded_market::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    embedded_market::retire(&cap, &mut book);
    let retired_events = event::events_by_type<embedded_market::MarketRetired>();
    assert!(retired_events.length() == 1, 0);

    // Repeatable, bounded max_items — one call with max_items = 0 is a no-op.
    embedded_market::drain_step(&cap, &mut book, 0, scenario.ctx());
    assert!(embedded_market::bids_size(&book) == 1, 1);
    embedded_market::drain_step(&cap, &mut book, 100, scenario.ctx());
    assert!(embedded_market::bids_size(&book) == 0, 2);

    let deleted_id = embedded_market::finalize(&cap, book);
    let deleted_events = event::events_by_type<embedded_market::MarketDeleted>();
    assert!(deleted_events.length() == 1, 3);
    // M14 Chunk 2: `market_deleted_fields_for_testing` widened from a bare
    // `ID` to a 3-tuple `(ID, TypeName, TypeName)` — the pre-existing
    // `order_book_id` assertion is preserved exactly; two new assertions
    // are added for `base`/`quote` (§Test-assertion-vs-call-site-rename
    // judgment call, `docs/plan-m14.md`).
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        embedded_market::market_deleted_fields_for_testing(&deleted_events[0]);
    assert!(deleted_order_book_id == deleted_id, 4);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 40);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 41);

    sui::test_utils::destroy(cap);
    scenario.end();
}

// --- embedded_finalize_aborts_when_fee_accumulator_nonzero /
// embedded_finalize_succeeds_after_fees_claimed (M13, mirrors M12's
// finalize_market_deletion_aborts_when_fee_accumulator_nonzero /
// finalize_market_deletion_succeeds_after_fees_claimed in
// tests/admin_tests.move) ---
//
// `embedded_market::finalize` `balance::destroy_zero`s the book's two
// `fee_accumulator` legs (see the destructure/`withdraw_fee_accumulator_raw`/
// `balance::destroy_zero` sequence at the end of `finalize` in
// `sources/embedded_market.move`) — exactly like `market::destroy_empty_book`
// does for the shared-book path. That call aborts (via `sui::balance`'s own
// `ENonZero`, abort code 0) if either leg is nonzero. The two prior
// `embedded_finalize_*` tests above only ever exercise resting-order-only
// scenarios (a single untouched resting order, or the fully-drained empty
// case) — no fee rate is ever set and no fill ever happens, so
// `fee_accumulator` is always (0, 0) and this precondition is never actually
// hit. These two tests close that gap: the first generates a genuinely
// fee-bearing fill (nonzero taker fee bps, so this isn't a degenerate
// zero-fee case), retires+drains the book, and confirms `finalize` aborts
// rather than silently discarding unclaimed pool-admin fees. The second
// repeats the identical setup but drains the accumulator via
// `embedded_market::pool_admin_claim_fees` first, confirming the
// claim-then-finalize path succeeds.

const FINALIZE_FEES_PRICE: u64 = 50_000;
const FINALIZE_FEES_SIZE: u64 = 2_000;

/// Mirrors `admin_tests.move`'s `generate_one_fee_bearing_fill` helper,
/// adapted to the embedded-book placement functions: a resting ask (maker
/// side, its fee-rate snapshot taken at rest time) followed by a fully
/// crossing bid (taker side) so the book's `fee_accumulator` ends up
/// genuinely nonzero on both legs.
fun generate_one_fee_bearing_fill_embedded(
    scenario: &mut ts::Scenario,
    book: &mut EmbeddedOrderBook<BTC, USDC>,
    taker_fee_bps: u64,
    maker_fee_bps: u64,
): (u64, u64) {
    let ask_ticket = rest_ask(book, FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let quote_cost = embedded_market::bid_escrow_amount(FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE);
    let bid_ticket = rest_bid(book, FINALIZE_FEES_PRICE, FINALIZE_FEES_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let taker_fee_base = (FINALIZE_FEES_SIZE * taker_fee_bps) / 10_000;
    let maker_fee_quote = (quote_cost * maker_fee_bps) / 10_000;
    (taker_fee_base, maker_fee_quote)
}

#[test, expected_failure(abort_code = sui::balance::ENonZero, location = sui::balance)]
fun embedded_finalize_aborts_when_fee_accumulator_nonzero() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::pool_admin_set_taker_fee(&cap, &mut book, 10);
    embedded_market::pool_admin_set_maker_fee(&cap, &mut book, 5);

    let (fee_base, _fee_quote) = generate_one_fee_bearing_fill_embedded(&mut scenario, &mut book, 10, 5);
    assert!(fee_base > 0, 0);
    let (fee_base_bal, _) = embedded_market::fee_accumulator_balances(&book);
    assert!(fee_base_bal == fee_base, 1);

    embedded_market::retire(&cap, &mut book);
    embedded_market::drain_step(&cap, &mut book, 10, scenario.ctx());
    // Fee accumulator is still nonzero (never claimed) — this aborts.
    let deleted_id = embedded_market::finalize(&cap, book);

    sui::test_utils::destroy(deleted_id);
    sui::test_utils::destroy(cap);
    scenario.end();
}

#[test]
fun embedded_finalize_succeeds_after_fees_claimed() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::pool_admin_set_taker_fee(&cap, &mut book, 10);
    embedded_market::pool_admin_set_maker_fee(&cap, &mut book, 5);

    let (fee_base, fee_quote) = generate_one_fee_bearing_fill_embedded(&mut scenario, &mut book, 10, 5);
    assert!(fee_base > 0, 0);

    // Claim first: drains the accumulator to (0, 0) before finalize.
    let (base_coin, quote_coin) = embedded_market::pool_admin_claim_fees(&cap, &mut book, scenario.ctx());
    assert!(coin::burn_for_testing(base_coin) == fee_base, 1);
    assert!(coin::burn_for_testing(quote_coin) == fee_quote, 2);
    let (fee_base_after, fee_quote_after) = embedded_market::fee_accumulator_balances(&book);
    assert!(fee_base_after == 0, 3);
    assert!(fee_quote_after == 0, 4);

    embedded_market::retire(&cap, &mut book);
    embedded_market::drain_step(&cap, &mut book, 10, scenario.ctx());
    let deleted_id = embedded_market::finalize(&cap, book);
    let deleted_events = event::events_by_type<embedded_market::MarketDeleted>();
    assert!(deleted_events.length() == 1, 5);
    // M14 Chunk 2: same widened-arity accommodation as above.
    let (deleted_order_book_id, deleted_base, deleted_quote) =
        embedded_market::market_deleted_fields_for_testing(&deleted_events[0]);
    assert!(deleted_order_book_id == deleted_id, 6);
    assert!(deleted_base == std::type_name::with_defining_ids<BTC>(), 60);
    assert!(deleted_quote == std::type_name::with_defining_ids<USDC>(), 61);

    sui::test_utils::destroy(cap);
    scenario.end();
}

// --- embedded_unpause_after_retire_clears_retiring_gate (accepted design) ---

#[test]
fun embedded_unpause_after_retire_clears_retiring_gate() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    embedded_market::retire(&cap, &mut book);
    embedded_market::pool_admin_unpause_market(&cap, &mut book);

    // `paused` (the merged field) was cleared — `drain_step`'s abort on this
    // state is exercised separately by
    // `embedded_drain_step_aborts_after_unpause_clears_retiring_gate` below
    // (Move's `#[expected_failure]` needs its own dedicated test function).
    assert!(!embedded_market::is_paused(&book), 0);

    // Calling retire again restores the gate.
    embedded_market::retire(&cap, &mut book);
    assert!(embedded_market::is_paused(&book), 1);
    embedded_market::drain_step(&cap, &mut book, 10, scenario.ctx());

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_drain_step_aborts_after_unpause_clears_retiring_gate() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::retire(&cap, &mut book);
    embedded_market::pool_admin_unpause_market(&cap, &mut book);
    embedded_market::drain_step(&cap, &mut book, 10, scenario.ctx());
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 8, location = tiny_clob::embedded_market)] // embedded_market::ETakerFeeRateTooHigh
fun embedded_taker_fee_above_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::pool_admin_set_taker_fee(&cap, &mut book, 11);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 9, location = tiny_clob::embedded_market)] // embedded_market::EMakerFeeRateTooHigh
fun embedded_maker_fee_above_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::pool_admin_set_maker_fee(&cap, &mut book, 6);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- embedded_claim_fees_drains_full_accumulator (REQ-EMBED-013) ---

#[test]
fun embedded_claim_fees_drains_full_accumulator() {
    let base_amount = 500;
    let quote_amount = 20_000;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    embedded_market::credit_fee_accumulator_for_testing(
        &mut book,
        balance::create_for_testing<BTC>(base_amount),
        balance::create_for_testing<USDC>(quote_amount),
    );

    let (before_base, before_quote) = embedded_market::fee_accumulator_balances(&book);
    assert!(before_base == base_amount, 0);
    assert!(before_quote == quote_amount, 1);

    let (base_coin, quote_coin) = embedded_market::pool_admin_claim_fees(&cap, &mut book, scenario.ctx());
    assert!(coin::burn_for_testing(base_coin) == base_amount, 2);
    assert!(coin::burn_for_testing(quote_coin) == quote_amount, 3);

    let (after_base, after_quote) = embedded_market::fee_accumulator_balances(&book);
    assert!(after_base == 0, 4);
    assert!(after_quote == 0, 5);

    let claimed_events = event::events_by_type<embedded_market::FeesClaimed>();
    assert!(claimed_events.length() == 1, 6);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun embedded_claim_fees_zero_balance_emits_no_event() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let (base_coin, quote_coin) = embedded_market::pool_admin_claim_fees(&cap, &mut book, scenario.ctx());
    assert!(coin::burn_for_testing(base_coin) == 0, 0);
    assert!(coin::burn_for_testing(quote_coin) == 0, 1);
    let claimed_events = event::events_by_type<embedded_market::FeesClaimed>();
    assert!(claimed_events.length() == 0, 2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_claim_fees_rejects_wrong_cap() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book1, _cap1) = new_book(&mut scenario);
    let (book2, cap2) = new_book(&mut scenario);
    let (base_coin, quote_coin) = embedded_market::pool_admin_claim_fees(&cap2, &mut book1, scenario.ctx());
    coin::burn_for_testing(base_coin);
    coin::burn_for_testing(quote_coin);
    sui::test_utils::destroy(book1);
    sui::test_utils::destroy(_cap1);
    destroy_book_and_cap(book2, cap2);
    scenario.end();
}

// === M14 Chunk 1: relocated matching engine + EmbeddedOrderTicket
// (REQ-ARCH-004, REQ-ARCH-005, REQ-ARCH-011, REQ-ARCH-013, REQ-ARCH-014) ===

// --- embedded_order_ticket_has_no_key_ability (REQ-ARCH-005, REQ-ARCH-013) ---
// Structural, not runtime: `EmbeddedOrderTicket`'s `has` clause
// (`sources/embedded_market.move`) is `store` only — no `key`. This is a
// compile-time guarantee (it makes `transfer::share_object` on a value of
// this type a compile error, unconditionally) rather than something a
// runtime `#[test]` can meaningfully exercise — mirroring both
// `EmbeddedOrderBook`'s own struct-comment-only precedent (`sources/
// embedded_market.move`'s `EmbeddedOrderBook` doc comment) and `order_
// tests.move`'s `order_ticket_has_no_store_ability` precedent (a comment
// section, no `#[test]` fn, `tests/order_tests.move:1538-1543`). The
// package compiling at all with `EmbeddedOrderTicket` held only by value
// (never inside a `key`-typed wrapper anywhere in this chunk's own test
// code) is itself the confirming evidence.

// --- embedded_ticket_disposal_no_abort (REQ-ARCH-011) ---

#[test]
fun destroy_orphaned_embedded_ticket_disposes_with_no_abort() {
    let order_id = 7;
    let order_book_id = object::id_from_address(@0xBEEF);
    let side = true;
    let price = 50_000;
    let ticket = embedded_market::new_embedded_ticket_for_testing(order_id, order_book_id, side, price);

    let (t_order_id, t_book_id, t_side, t_price) = embedded_market::embedded_ticket_fields_for_testing(&ticket);
    assert!(t_order_id == order_id, 0);
    assert!(t_book_id == order_book_id, 1);
    assert!(t_side == side, 2);
    assert!(t_price == price, 3);

    // No liveness check, no abort, no leaked value — the whole point of a
    // dedicated `public(package)` disposal function.
    embedded_market::destroy_orphaned_embedded_ticket(ticket);
}

// --- match_bid_produces_expected_fill_and_fee_amounts /
// match_ask_produces_expected_fill_and_fee_amounts (REQ-ARCH-004,
// REQ-ARCH-005) ---
//
// Regression tests for `match_bid`/`match_ask` (and, transitively,
// `fill_level_bid`/`fill_level_ask`) in `embedded_market.move`, invoked
// directly via the `match_bid_for_testing`/`match_ask_for_testing`
// test-only accessors (necessary since `match_bid`/`match_ask` are
// private). Every expected value below is computed independently from the
// known price/size/fee-rate inputs using the spec's own fee formula
// (`sources/embedded_market.move`'s `fee_amount`: `receive_amount *
// rate_bps / 10_000`, floored) — not by comparing two invocations of the
// same function against each other. Fee rates (37 bps taker, 13 bps maker)
// are deliberately non-round so the floor-rounding arithmetic is actually
// exercised, and fixture magnitudes (price, lot-aligned sizes) match this
// suite's existing house style elsewhere in this file. Fee rates are
// bounded by `MAX_TAKER_FEE_BPS`/`MAX_MAKER_FEE_BPS` (10/5 bps), so 7/3 bps
// is used here — non-round relative to the fixture sizes below, so the
// floor-rounding still bites on both the taker- and maker-side fee legs.

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
    embedded_market::pool_admin_set_taker_fee(&cap, &mut book, FEE_TEST_TAKER_FEE_BPS);
    embedded_market::pool_admin_set_maker_fee(&cap, &mut book, FEE_TEST_MAKER_FEE_BPS);

    // Resting ask, inserted via the low-level test construction path this
    // suite already uses elsewhere.
    let order_id = embedded_market::next_order_id(&mut book);
    let escrow = balance::create_for_testing<BTC>(FEE_TEST_RESTING_SIZE);
    let ask = embedded_market::new_order<BTC, USDC>(
        order_id, OTHER, FEE_TEST_RESTING_SIZE, option::some(escrow), option::none(), FEE_TEST_MAKER_FEE_BPS,
    );
    embedded_market::insert_resting_order_for_testing(&mut book, false, FEE_TEST_PRICE, ask, scenario.ctx());

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

    let payment = coin::mint_for_testing<USDC>(embedded_market::bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE), scenario.ctx());
    let (matched_base, remaining_budget, remaining_size, stopped) = embedded_market::match_bid_for_testing(
        &mut book, option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_base_val = coin::burn_for_testing(matched_base);
    let remaining_budget_val = coin::burn_for_testing(remaining_budget);
    let (fee_base_after, fee_quote_after) = embedded_market::fee_accumulator_balances(&book);

    assert!(matched_base_val == expected_matched_base, 0);
    assert!(remaining_budget_val == embedded_market::bid_escrow_amount(FEE_TEST_PRICE, FEE_TEST_TAKER_SIZE) - expected_quote_cost, 1);
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
    embedded_market::pool_admin_set_taker_fee(&cap, &mut book, FEE_TEST_TAKER_FEE_BPS);
    embedded_market::pool_admin_set_maker_fee(&cap, &mut book, FEE_TEST_MAKER_FEE_BPS);

    // Resting bid.
    let order_id = embedded_market::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(FEE_TEST_PRICE * FEE_TEST_RESTING_SIZE);
    let bid = embedded_market::new_order<BTC, USDC>(
        order_id, OTHER, FEE_TEST_RESTING_SIZE, option::none(), option::some(escrow), FEE_TEST_MAKER_FEE_BPS,
    );
    embedded_market::insert_resting_order_for_testing(&mut book, true, FEE_TEST_PRICE, bid, scenario.ctx());

    // Taker fully filled by the larger resting bid, so fill_qty ==
    // FEE_TEST_TAKER_SIZE:
    //   quote_amt = price * fill_qty = 47_500 * 3_400 = 161_500_000
    //   taker_fee_quote = floor(quote_amt * taker_bps / 10_000)
    //                   = floor(161_500_000 * 7 / 10_000) = 113_050
    //   matched_quote   = quote_amt - taker_fee_quote = 161_386_950
    //   maker_fee_base = floor(fill_qty * maker_bps / 10_000)
    //                  = floor(3_400 * 3 / 10_000) = floor(1.02) = 1
    //   remaining_wallet = own_wallet - fill_qty = 0 (exact full fill)
    let expected_quote_amt = FEE_TEST_PRICE * FEE_TEST_TAKER_SIZE;
    let expected_taker_fee_quote = 113_050;
    let expected_matched_quote = expected_quote_amt - expected_taker_fee_quote;
    let expected_maker_fee_base = 1;

    let payment = coin::mint_for_testing<BTC>(FEE_TEST_TAKER_SIZE, scenario.ctx());
    let (matched_quote, remaining_wallet, remaining_size, stopped) = embedded_market::match_ask_for_testing(
        &mut book, option::some(FEE_TEST_PRICE), FEE_TEST_TAKER_SIZE, payment, FEE_TEST_MAX_FILLS, scenario.ctx(),
    );

    let matched_quote_val = coin::burn_for_testing(matched_quote);
    let remaining_wallet_val = coin::burn_for_testing(remaining_wallet);
    let (fee_base_after, fee_quote_after) = embedded_market::fee_accumulator_balances(&book);

    assert!(matched_quote_val == expected_matched_quote, 0);
    assert!(remaining_wallet_val == 0, 1);
    assert!(remaining_size == 0, 2);
    assert!(stopped == false, 3);
    assert!(fee_base_after == expected_maker_fee_base, 4);
    assert!(fee_quote_after == expected_taker_fee_quote, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- embedded_force_cancel_refunds_owner_not_caller (REQ-EMBED-014) ---

#[test]
fun embedded_force_cancel_refunds_owner_not_caller() {
    let price = 50_000;
    let size = 100;
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    // Insert a resting bid directly via the `#[test_only]`
    // `insert_resting_order_for_testing` wrapper — mirrors how
    // `order_tests.move`/`admin_tests.move` construct resting orders for a
    // force-cancel test, without going through `order.move`'s own placement
    // functions.
    let order_id = embedded_market::next_order_id(&mut book);
    let escrow = balance::create_for_testing<USDC>(price * size);
    let order = embedded_market::new_order<BTC, USDC>(order_id, OTHER, size, option::none(), option::some(escrow), 0);
    embedded_market::insert_resting_order_for_testing(&mut book, true, price, order, scenario.ctx());

    embedded_market::pool_admin_cancel_order(&cap, &mut book, true, price, order_id, scenario.ctx());

    let cancelled_events = event::events_by_type<embedded_market::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 0);
    let (ev_order_id, ev_book, ev_trader) = embedded_market::order_cancelled_fields_for_testing(&cancelled_events[0]);
    assert!(ev_order_id == order_id, 1);
    assert!(ev_book == book_id, 2);
    assert!(ev_trader == OTHER, 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === M14 Chunk 2: canonical (un-suffixed) placement/cancel/claim functions
// (REQ-ARCH-003, REQ-ARCH-008) — one happy-path/boundary/abort scenario per
// function, each a direct pairwise mirror of the pre-existing `_embedded`-
// suffixed test's own shape above, called against the new un-suffixed name,
// proving the rename-plus-substitution introduced no behavior change. ===

const CH2_PRICE: u64 = 50_000;
const CH2_SIZE: u64 = 100;

#[test]
fun canonical_place_limit_order_bid_rests_and_emits_orderplaced() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    let escrow_amount = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let payment = coin::mint_for_testing<USDC>(escrow_amount, scenario.ctx());
    let (ticket, matched_base, leftover_quote, stopped) =
        embedded_market::place_limit_order_bid(&mut book, CH2_PRICE, CH2_SIZE, payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(matched_base) == 0, 1);
    assert!(coin::burn_for_testing(leftover_quote) == 0, 2);
    let (t_order_id, t_book_id, t_side, t_price) = embedded_market::embedded_ticket_fields_for_testing(&ticket);
    assert!(t_book_id == book_id, 3);
    assert!(t_side == true, 4);
    assert!(t_price == CH2_PRICE, 5);

    let placed_events = event::events_by_type<embedded_market::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);
    let (ev_order_id, ev_book_id, ev_side, ev_price, ev_size, ev_trader) =
        embedded_market::order_placed_fields_for_testing(&placed_events[0]);
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
fun canonical_place_limit_order_ask_rests_and_emits_orderplaced() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    let payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (ticket, leftover_base, matched_quote, stopped) =
        embedded_market::place_limit_order_ask(&mut book, CH2_PRICE, CH2_SIZE, payment, 1_000_000_000, scenario.ctx());

    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_base) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == 0, 2);
    let (_t_order_id, t_book_id, t_side, t_price) = embedded_market::embedded_ticket_fields_for_testing(&ticket);
    assert!(t_book_id == book_id, 3);
    assert!(t_side == false, 4);
    assert!(t_price == CH2_PRICE, 5);

    let placed_events = event::events_by_type<embedded_market::OrderPlaced>();
    assert!(placed_events.length() == 1, 6);

    unit_test::destroy(ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun canonical_place_market_order_bid_matches_resting_ask() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover_payment) = embedded_market::place_market_order_bid(
        &mut book, CH2_SIZE, budget, bid_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == CH2_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun canonical_place_market_order_ask_matches_resting_bid() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let escrow_amount = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = embedded_market::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(leftover_payment) == 0, 0);
    assert!(coin::burn_for_testing(matched_quote) == escrow_amount, 1);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun canonical_swap_bid_matches_resting_ask() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(ask_ticket);

    let budget = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover_payment, stopped) = embedded_market::swap_bid(
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
fun canonical_swap_ask_matches_resting_bid() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let escrow_amount = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote, stopped) = embedded_market::swap_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(!stopped, 0);
    assert!(coin::burn_for_testing(leftover_payment) == 0, 1);
    assert!(coin::burn_for_testing(matched_quote) == escrow_amount, 2);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun canonical_cancel_order_refunds_escrow_and_emits_ordercancelled() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    let escrow_amount = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (t_order_id, _, _, _) = embedded_market::embedded_ticket_fields_for_testing(&ticket);

    let (refund_base, refund_quote) = embedded_market::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(refund_base) == 0, 0);
    assert!(coin::burn_for_testing(refund_quote) == escrow_amount, 1);

    let cancelled_events = event::events_by_type<embedded_market::OrderCancelled>();
    assert!(cancelled_events.length() == 1, 2);
    let (ev_order_id, ev_book_id, ev_trader) = embedded_market::order_cancelled_fields_for_testing(&cancelled_events[0]);
    assert!(ev_order_id == t_order_id, 3);
    assert!(ev_book_id == book_id, 4);
    assert!(ev_trader == ADMIN, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === I-1 fix regression (blind-audit finding): `event_id` is now
// write-once, fixed at `new`'s construction time via `event_id_override`,
// with no setter that could ever change it afterward. This is the
// structural fix for the old bug where a post-construction `set_event_id`
// setter could be called after a resting order already existed, stranding
// that order's own ticket (stale `order_book_id`) and causing
// `cancel_order` to wrongly abort with `EWrongMarket` — permanently
// denying the trader self-service cancellation of their own resting order.
// Since no setter exists anymore, there is no way to reproduce the old bug
// scenario at all; these tests instead confirm the override mechanism
// itself behaves correctly and stays stable across placement/fill/cancel.

#[test]
fun new_event_id_override_is_used_and_stable_across_placement_and_cancel() {
    let mut scenario = ts::begin(ADMIN);
    let override_id = object::id_from_address(@0xFACE);
    let (mut book, cap) = embedded_market::new<BTC, USDC>(
        LOT_SIZE, MIN_SIZE, option::some(override_id), scenario.ctx(),
    );

    // The override, not the book's own internal id, is what got stamped.
    let book_own_id = embedded_market::id(&book);
    assert!(embedded_market::event_id_for_testing(&book) == override_id, 0);
    assert!(override_id != book_own_id, 1);

    // Place a resting bid — the ticket must carry the override id.
    let escrow_amount = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (_, t_book_id, _, _) = embedded_market::embedded_ticket_fields_for_testing(&ticket);
    assert!(t_book_id == override_id, 2);

    // No function exists that could change event_id after the fact — it is
    // still the override id right before cancellation, and cancel_order
    // (which checks ticket.order_book_id == book.event_id) succeeds.
    assert!(embedded_market::event_id_for_testing(&book) == override_id, 3);
    let (refund_base, refund_quote) = embedded_market::cancel_order(&mut book, ticket, scenario.ctx());
    assert!(coin::burn_for_testing(refund_base) == 0, 4);
    assert!(coin::burn_for_testing(refund_quote) == escrow_amount, 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun new_event_id_defaults_to_self_id_when_override_is_none() {
    let mut scenario = ts::begin(ADMIN);
    let (book, cap) = new_book(&mut scenario);

    let book_own_id = embedded_market::id(&book);
    assert!(embedded_market::event_id_for_testing(&book) == book_own_id, 0);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun canonical_claim_proceeds_pays_out_and_emits_proceedsclaimed() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    // ADMIN rests a bid; OTHER crosses it as a market ask, crediting
    // ADMIN's maker proceeds table with quote.
    let escrow_amount = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    scenario.next_tx(OTHER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = embedded_market::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    scenario.next_tx(ADMIN);
    embedded_market::claim_proceeds(&mut book, scenario.ctx());

    let claimed_events = event::events_by_type<embedded_market::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_claimant, ev_book_id, ev_base, ev_quote) =
        embedded_market::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_base == CH2_SIZE, 3);
    assert!(ev_quote == 0, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- pool_admin_push_proceeds (REQ-ARCH-012) ---

#[test]
fun pool_admin_push_proceeds_matches_claim_proceeds_when_addr_is_self() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let book_id = embedded_market::id(&book);

    let escrow_amount = embedded_market::bid_escrow_amount(CH2_PRICE, CH2_SIZE);
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    unit_test::destroy(bid_ticket);

    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = embedded_market::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    embedded_market::pool_admin_push_proceeds(&cap, &mut book, ADMIN, scenario.ctx());

    let claimed_events = event::events_by_type<embedded_market::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 0);
    let (ev_claimant, ev_book_id, ev_base, ev_quote) =
        embedded_market::proceeds_claimed_fields_for_testing(&claimed_events[0]);
    assert!(ev_claimant == ADMIN, 1);
    assert!(ev_book_id == book_id, 2);
    assert!(ev_base == CH2_SIZE, 3);
    assert!(ev_quote == 0, 4);
    // No live proceeds entry survives the push, matching claim_proceeds's
    // own claim-then-remove behavior.
    assert!(!embedded_market::proceeds_contains_for_testing(&book, ADMIN), 5);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// --- update_resting_order_owner (encapsulation-leak fix, Problem 1) ---

#[test]
fun update_resting_order_owner_found_reassigns_owner_and_credits_new_owner_on_fill() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // ADMIN rests a bid; its resting order's owner is reassigned to OTHER
    // via update_resting_order_owner before it is ever crossed.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (order_id, _, side, price) = embedded_market::embedded_ticket_fields_for_testing(&bid_ticket);
    unit_test::destroy(bid_ticket);

    let found = embedded_market::update_resting_order_owner(&mut book, side, price, order_id, OTHER);
    assert!(found, 0);

    // Cross the reassigned resting bid with a market ask from a third party.
    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = embedded_market::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);

    // Maker proceeds landed on OTHER (the reassigned owner), not ADMIN (the
    // original owner) — proving the owner field was actually overwritten,
    // not just the ticket's own bookkeeping.
    assert!(embedded_market::proceeds_contains_for_testing(&book, OTHER), 1);
    assert!(!embedded_market::proceeds_contains_for_testing(&book, ADMIN), 2);

    scenario.next_tx(OTHER);
    embedded_market::claim_proceeds(&mut book, scenario.ctx());
    let claimed_events = event::events_by_type<embedded_market::ProceedsClaimed>();
    assert!(claimed_events.length() == 1, 3);
    let (ev_claimant, _, _, _) = embedded_market::proceeds_claimed_fields_for_testing(&claimed_events[0]);
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
        embedded_market::update_resting_order_owner(&mut book, embedded_market::bid_for_testing(), CH2_PRICE, 0, OTHER);
    assert!(!found_empty_book, 0);

    // Rest a real bid, then probe with a wrong order_id at the same,
    // now-existing price level — the level exists but the specific order
    // does not.
    let bid_ticket = rest_bid(&mut book, CH2_PRICE, CH2_SIZE, 1_000_000_000, scenario.ctx());
    let (order_id, _, side, price) = embedded_market::embedded_ticket_fields_for_testing(&bid_ticket);
    let wrong_order_id = order_id + 1;
    let found_wrong_id = embedded_market::update_resting_order_owner(&mut book, side, price, wrong_order_id, OTHER);
    assert!(!found_wrong_id, 1);

    // The real order's owner is untouched (still ADMIN): crossing it still
    // credits ADMIN's proceeds, not OTHER's.
    unit_test::destroy(bid_ticket);
    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(CH2_SIZE, scenario.ctx());
    let (leftover_payment, matched_quote) = embedded_market::place_market_order_ask(
        &mut book, CH2_SIZE, ask_payment, 1_000_000_000, option::none(), option::none(), scenario.ctx(),
    );
    coin::burn_for_testing(leftover_payment);
    coin::burn_for_testing(matched_quote);
    assert!(embedded_market::proceeds_contains_for_testing(&book, ADMIN), 2);
    assert!(!embedded_market::proceeds_contains_for_testing(&book, OTHER), 3);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun pool_admin_push_proceeds_rejects_wrong_cap() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, _cap) = new_book(&mut scenario);
    let (_other_book, wrong_cap) = new_book(&mut scenario);

    embedded_market::pool_admin_push_proceeds(&wrong_cap, &mut book, ADMIN, scenario.ctx());

    sui::test_utils::destroy(book);
    sui::test_utils::destroy(_cap);
    sui::test_utils::destroy(_other_book);
    sui::test_utils::destroy(wrong_cap);
    scenario.end();
}

const EMBEDDED_PRICE: u64 = 50_000;
const EMBEDDED_SIZE: u64 = 100;

#[test]
fun embedded_place_limit_order_bid_ask_happy_path_fills_and_rests() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Resting ask, then a crossing bid fills it fully.
    let ask_payment = coin::mint_for_testing<BTC>(EMBEDDED_SIZE, scenario.ctx());
    let (ask_ticket, ask_matched_base, ask_leftover_base, ask_stop) =
        embedded_market::place_limit_order_ask(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, ask_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(ask_matched_base) == 0, 0);
    assert!(coin::burn_for_testing(ask_leftover_base) == 0, 1);
    assert!(!ask_stop, 2);

    scenario.next_tx(TAKER);
    let bid_payment = coin::mint_for_testing<USDC>(embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE), scenario.ctx());
    let (bid_ticket, bid_matched_base, bid_leftover_quote, bid_stop) =
        embedded_market::place_limit_order_bid(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, bid_payment, 10, scenario.ctx());
    assert!(coin::burn_for_testing(bid_matched_base) == EMBEDDED_SIZE, 3);
    assert!(coin::burn_for_testing(bid_leftover_quote) == 0, 4);
    assert!(!bid_stop, 5);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_place_limit_order_zero_price_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket, mb, ml, _) = embedded_market::place_limit_order_bid(&mut book, 0, EMBEDDED_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_place_limit_order_size_validation_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let payment = coin::mint_for_testing<USDC>(1, scenario.ctx());
    let (ticket, mb, ml, _) =
        embedded_market::place_limit_order_bid(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE - 1, payment, 10, scenario.ctx());
    unit_test::destroy(ticket);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_placement_functions_abort_when_paused() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    embedded_market::pool_admin_pause_market(&cap, &mut book);
    let payment = coin::mint_for_testing<USDC>(embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE), scenario.ctx());
    let (ticket, mb, ml, _) =
        embedded_market::place_limit_order_bid(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, payment, 10, scenario.ctx());
    unit_test::destroy(ticket);
    unit_test::destroy(mb);
    unit_test::destroy(ml);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun embedded_place_market_order_bid_ask_happy_path() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover) = embedded_market::place_market_order_bid(
        &mut book, EMBEDDED_SIZE, budget, bid_payment, 10, option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == EMBEDDED_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover) == 0, 2);

    scenario.next_tx(TAKER);
    let bid_ticket2 = rest_bid(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());
    let ask_payment2 = coin::mint_for_testing<BTC>(EMBEDDED_SIZE, scenario.ctx());
    let (leftover_base, matched_quote) =
        embedded_market::place_market_order_ask(&mut book, EMBEDDED_SIZE, ask_payment2, 10, option::none(), option::none(), scenario.ctx());
    assert!(coin::burn_for_testing(matched_quote) == embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE), 3);
    assert!(coin::burn_for_testing(leftover_base) == 0, 4);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket2);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure]
fun embedded_place_market_order_bid_slippage_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let ask_ticket = rest_ask(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover) = embedded_market::place_market_order_bid(
        &mut book, EMBEDDED_SIZE, budget, bid_payment, 10, option::none(), option::some(EMBEDDED_SIZE + 1), scenario.ctx(),
    );
    coin::burn_for_testing(matched_base);
    coin::burn_for_testing(remaining_budget);
    coin::burn_for_testing(leftover);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun embedded_swap_bid_ask_happy_path_and_max_fills_stop_signal() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let budget = embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE);
    let bid_payment = coin::mint_for_testing<USDC>(budget, scenario.ctx());
    let (matched_base, remaining_budget, leftover, stop) = embedded_market::swap_bid(
        &mut book, EMBEDDED_SIZE, budget, bid_payment, 10, option::none(), option::none(), option::none(), scenario.ctx(),
    );
    assert!(coin::burn_for_testing(matched_base) == EMBEDDED_SIZE, 0);
    assert!(coin::burn_for_testing(remaining_budget) == 0, 1);
    assert!(coin::burn_for_testing(leftover) == 0, 2);
    assert!(!stop, 3);

    // max_fills = 0 against a crossing resting ask signals the stop-reason.
    scenario.next_tx(TAKER);
    let ask_ticket2 = rest_ask(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());
    scenario.next_tx(TAKER);
    let budget2 = embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE);
    let bid_payment2 = coin::mint_for_testing<USDC>(budget2, scenario.ctx());
    let (matched_base2, remaining_budget2, leftover2, stop2) = embedded_market::swap_bid(
        &mut book, EMBEDDED_SIZE, budget2, bid_payment2, 0, option::none(), option::none(), option::none(), scenario.ctx(),
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
fun embedded_swap_ask_slippage_bound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);
    let bid_ticket = rest_bid(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let ask_payment = coin::mint_for_testing<BTC>(EMBEDDED_SIZE, scenario.ctx());
    let (leftover_base, matched_quote, stop) = embedded_market::swap_ask(
        &mut book, EMBEDDED_SIZE, ask_payment, 10, option::none(),
        option::some(embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE) + 1), option::none(), scenario.ctx(),
    );
    unit_test::destroy(leftover_base);
    unit_test::destroy(matched_quote);
    let _ = stop;
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun embedded_cancel_and_claim_never_block_on_pause_or_retiring() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    // Rest a bid, pause the book, then cancel — must succeed despite pause.
    let bid_ticket = rest_bid(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());

    embedded_market::pool_admin_pause_market(&cap, &mut book);
    let (cancel_base, cancel_quote) = embedded_market::cancel_order(&mut book, bid_ticket, scenario.ctx());
    assert!(coin::burn_for_testing(cancel_base) == 0, 0);
    assert!(coin::burn_for_testing(cancel_quote) == embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE), 1);

    // claim_proceeds_embedded also succeeds while retiring (paused merged field).
    embedded_market::retire(&cap, &mut book);
    embedded_market::claim_proceeds(&mut book, scenario.ctx());

    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun embedded_claim_proceeds_transfers_maker_proceeds() {
    let mut scenario = ts::begin(ADMIN);
    let (mut book, cap) = new_book(&mut scenario);

    let ask_ticket = rest_ask(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());

    scenario.next_tx(TAKER);
    let bid_ticket = rest_bid(&mut book, EMBEDDED_PRICE, EMBEDDED_SIZE, 10, scenario.ctx());

    scenario.next_tx(ADMIN);
    embedded_market::claim_proceeds(&mut book, scenario.ctx());
    let claimed = event::events_by_type<ProceedsClaimed>();
    assert!(claimed.length() == 1, 0);
    let (claimant, _, _base_amt, quote_amt) = embedded_market::proceeds_claimed_fields_for_testing(&claimed[0]);
    assert!(claimant == ADMIN, 1);
    assert!(quote_amt == embedded_market::bid_escrow_amount(EMBEDDED_PRICE, EMBEDDED_SIZE), 2);

    unit_test::destroy(ask_ticket);
    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}


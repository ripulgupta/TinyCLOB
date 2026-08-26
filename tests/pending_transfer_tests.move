/// M6 Chunk 1 test module for `pending_transfer.md`'s generic delayed
/// capability-transfer mechanism. Exercises the module in isolation against
/// a test-only dummy `T: key` type — no dependency on `market`/`order`/
/// `admin` capability types (those full-lifecycle flows are covered in
/// Chunk 5's integration tests).
#[test_only]
module tiny_clob::pending_transfer_tests;

use sui::clock::{Self, Clock};
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::pending_transfer::{
    Self,
    PendingTransferRegistry,
    PendingTransfer,
    TransferInitiated,
    TransferAccepted,
    TransferCancelled,
    TransferFinalized,
};

const OFF_VERSION: u64 = 999;

/// A minimal `key`-only dummy capability type, standing in for
/// `AdminCap`/`PoolAdminCap`/`OrderTicket` for this module's own isolated
/// unit tests.
public struct DummyCap has key {
    id: UID,
}

const SENDER: address = @0xA11CE;
const RECIPIENT: address = @0xB0B;
const THIRD_PARTY: address = @0xC0DE;

const DELAY_MS: u64 = 172_800_000;

fun setup(): ts::Scenario {
    let mut scenario = ts::begin(SENDER);
    pending_transfer::init_for_testing(scenario.ctx());
    scenario.next_tx(SENDER);
    scenario
}

/// Mints a `DummyCap`, transfers it to `SENDER`, and hands back its id —
/// mirroring real capability ownership so `ts::ids_for_sender` reflects it.
fun mint_dummy_cap_to_sender(scenario: &mut ts::Scenario): ID {
    let cap = DummyCap { id: object::new(scenario.ctx()) };
    let cap_id = object::id(&cap);
    transfer::transfer(cap, SENDER);
    scenario.next_tx(SENDER);
    cap_id
}

fun new_clock(scenario: &mut ts::Scenario): Clock {
    clock::create_for_testing(scenario.ctx())
}

/// Mints a `DummyCap` to `SENDER` and immediately initiates a transfer of it
/// to `RECIPIENT`. Returns the cap's id and the `Clock` (still owned by the
/// caller, `proposed_at_ms == 0`).
fun setup_pending(scenario: &mut ts::Scenario): (ID, Clock) {
    let cap_id = mint_dummy_cap_to_sender(scenario);
    let clock = new_clock(scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(scenario);
    let cap = ts::take_from_sender<DummyCap>(scenario);
    pending_transfer::initiate_transfer(&cap, RECIPIENT, &mut registry, &clock, scenario.ctx());
    ts::return_to_sender(scenario, cap);
    ts::return_shared(registry);
    (cap_id, clock)
}

/// Accepts the currently-pending transfer as `RECIPIENT` — the repeated
/// "accept as RECIPIENT" block (`next_tx` + `take_shared` + `accept_transfer`
/// + `return_shared`) shared verbatim by several `finalize_transfer` tests
/// below.
fun accept_as_recipient(scenario: &mut ts::Scenario) {
    scenario.next_tx(RECIPIENT);
    let mut pending = ts::take_shared<PendingTransfer<DummyCap>>(scenario);
    pending_transfer::accept_transfer(&mut pending, scenario.ctx());
    ts::return_shared(pending);
}

// === init_creates_exactly_one_pendingtransferregistry ===

#[test]
fun init_creates_exactly_one_pendingtransferregistry() {
    let scenario = setup();
    let registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    assert!(pending_transfer::registry_active_len_for_testing(&registry) == 0, 0);
    ts::return_shared(registry);
    scenario.end();
}

// === initiate_transfer ===

#[test]
fun initiate_transfer_records_pending_and_registry_entry() {
    let mut scenario = setup();
    let (cap_id, clock) = setup_pending(&mut scenario);

    scenario.next_tx(SENDER);
    let registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    assert!(pending_transfer::registry_contains_for_testing(&registry, cap_id), 0);
    let pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let (p_cap_id, from, to, proposed_at_ms, accepted) =
        pending_transfer::pending_fields_for_testing(&pending);
    assert!(p_cap_id == cap_id, 1);
    assert!(from == SENDER, 2);
    assert!(to == RECIPIENT, 3);
    assert!(proposed_at_ms == 0, 4);
    assert!(!accepted, 5);

    // Sender's ownership of `cap` is unaffected — still holds it directly.
    let ids = ts::ids_for_sender<DummyCap>(&scenario);
    assert!(ids.length() == 1, 6);

    ts::return_shared(pending);
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun transfer_initiated_event_emitted_with_correct_fields() {
    let mut scenario = setup();
    // `setup_pending`'s own `initiate_transfer` call is the last action
    // before returning — inspect the event log in this same transaction,
    // mirroring `market_tests.move`'s "same transaction it emits it in"
    // convention (the harness's event log does not carry across
    // `next_tx`).
    let (cap_id, clock) = setup_pending(&mut scenario);

    let events = event::events_by_type<TransferInitiated>();
    assert!(events.length() == 1, 0);
    let (e_cap_id, e_from, e_to) = pending_transfer::transfer_initiated_fields_for_testing(events.borrow(0));
    assert!(e_cap_id == cap_id, 1);
    assert!(e_from == SENDER, 2);
    assert!(e_to == RECIPIENT, 3);

    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 0, location = tiny_clob::pending_transfer)] // pending_transfer::EParallelTransferActive — `location` pins the aborting module, discriminating this from `sui::dynamic_field::EFieldAlreadyExists` (also 0), which is what `table::add` would raise instead if the app-level guard below it were ever deleted.
fun initiate_transfer_aborts_on_parallel_pending_transfer() {
    let mut scenario = setup();
    let (_cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(SENDER);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    let cap = ts::take_from_sender<DummyCap>(&scenario);

    pending_transfer::initiate_transfer(&cap, THIRD_PARTY, &mut registry, &clock, scenario.ctx());

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

// === accept_transfer ===

#[test]
#[expected_failure(abort_code = 1)] // pending_transfer::ENotRecipient
fun accept_transfer_aborts_when_not_called_by_to() {
    let mut scenario = setup();
    let (_cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(THIRD_PARTY);
    let mut pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    pending_transfer::accept_transfer(&mut pending, scenario.ctx());
    ts::return_shared(pending);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun accept_transfer_sets_accepted_true_and_emits_event() {
    let mut scenario = setup();
    let (_cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(RECIPIENT);
    let mut pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    pending_transfer::accept_transfer(&mut pending, scenario.ctx());
    let (_, _, _, _, accepted) = pending_transfer::pending_fields_for_testing(&pending);
    assert!(accepted, 0);
    ts::return_shared(pending);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun transfer_accepted_event_emitted_with_correct_fields() {
    let mut scenario = setup();
    let (cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(RECIPIENT);
    let mut pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    pending_transfer::accept_transfer(&mut pending, scenario.ctx());

    let events = event::events_by_type<TransferAccepted>();
    assert!(events.length() == 1, 0);
    let (e_cap_id, e_to) = pending_transfer::transfer_accepted_fields_for_testing(events.borrow(0));
    assert!(e_cap_id == cap_id, 1);
    assert!(e_to == RECIPIENT, 2);

    ts::return_shared(pending);
    clock::destroy_for_testing(clock);
    scenario.end();
}

// === cancel_transfer_request ===

#[test]
#[expected_failure(abort_code = 2)] // pending_transfer::ENotSender
fun cancel_transfer_request_aborts_when_not_called_by_from() {
    let mut scenario = setup();
    let (_cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(RECIPIENT);
    let pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    pending_transfer::cancel_transfer_request(pending, &mut registry, scenario.ctx());
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun cancel_transfer_request_succeeds_before_acceptance_and_after() {
    // Before acceptance.
    let mut scenario = setup();
    let (cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(SENDER);
    let pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    pending_transfer::cancel_transfer_request(pending, &mut registry, scenario.ctx());
    assert!(!pending_transfer::registry_contains_for_testing(&registry, cap_id), 0);
    // Sender still holds cap directly (nothing to return, it never moved).
    let ids = ts::ids_for_sender<DummyCap>(&scenario);
    assert!(ids.length() == 1, 1);
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();

    // After acceptance.
    let mut scenario2 = setup();
    let (cap_id2, clock2) = setup_pending(&mut scenario2);
    accept_as_recipient(&mut scenario2);
    scenario2.next_tx(SENDER);
    let pending2b = ts::take_shared<PendingTransfer<DummyCap>>(&scenario2);
    let mut registry2 = ts::take_shared<PendingTransferRegistry>(&scenario2);
    pending_transfer::cancel_transfer_request(pending2b, &mut registry2, scenario2.ctx());
    assert!(!pending_transfer::registry_contains_for_testing(&registry2, cap_id2), 2);
    ts::return_shared(registry2);
    clock::destroy_for_testing(clock2);
    scenario2.end();
}

#[test]
fun transfer_cancelled_event_emitted_with_correct_fields() {
    let mut scenario = setup();
    let (cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(SENDER);
    let pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    pending_transfer::cancel_transfer_request(pending, &mut registry, scenario.ctx());

    let events = event::events_by_type<TransferCancelled>();
    assert!(events.length() == 1, 0);
    let (e_cap_id, e_from) = pending_transfer::transfer_cancelled_fields_for_testing(events.borrow(0));
    assert!(e_cap_id == cap_id, 1);
    assert!(e_from == SENDER, 2);

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

// === finalize_transfer ===

#[test]
#[expected_failure(abort_code = 3)] // pending_transfer::ENotAccepted
fun finalize_transfer_aborts_when_not_accepted() {
    let mut scenario = setup();
    let (_cap_id, mut clock) = setup_pending(&mut scenario);
    clock::set_for_testing(&mut clock, DELAY_MS);
    scenario.next_tx(SENDER);
    let pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    let ticket = pending_transfer::finalize_transfer(pending, &mut registry, &clock, scenario.ctx());
    let (_id, _to) = pending_transfer::unwrap_ticket(ticket);
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 4)] // pending_transfer::EDelayNotElapsed
fun finalize_transfer_aborts_before_delay_elapsed() {
    let mut scenario = setup();
    let (_cap_id, mut clock) = setup_pending(&mut scenario);
    accept_as_recipient(&mut scenario);

    // One millisecond short of the threshold.
    clock::set_for_testing(&mut clock, DELAY_MS - 1);
    scenario.next_tx(SENDER);
    let pending2 = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    let ticket = pending_transfer::finalize_transfer(pending2, &mut registry, &clock, scenario.ctx());
    let (_id, _to) = pending_transfer::unwrap_ticket(ticket);
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun finalize_transfer_succeeds_at_exact_delay_boundary_and_returns_ticket() {
    let mut scenario = setup();
    let (cap_id, mut clock) = setup_pending(&mut scenario);
    accept_as_recipient(&mut scenario);

    clock::set_for_testing(&mut clock, DELAY_MS);
    scenario.next_tx(SENDER);
    let pending2 = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    let ticket = pending_transfer::finalize_transfer(pending2, &mut registry, &clock, scenario.ctx());
    let (ticket_cap_id, ticket_to) = pending_transfer::unwrap_ticket(ticket);
    assert!(ticket_cap_id == cap_id, 0);
    assert!(ticket_to == RECIPIENT, 1);
    assert!(!pending_transfer::registry_contains_for_testing(&registry, cap_id), 2);

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun transfer_finalized_event_emitted_with_correct_fields() {
    let mut scenario = setup();
    let (cap_id, mut clock) = setup_pending(&mut scenario);
    accept_as_recipient(&mut scenario);

    clock::set_for_testing(&mut clock, DELAY_MS);
    scenario.next_tx(SENDER);
    let pending2 = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    let ticket = pending_transfer::finalize_transfer(pending2, &mut registry, &clock, scenario.ctx());

    let events = event::events_by_type<TransferFinalized>();
    assert!(events.length() == 1, 0);
    let (e_cap_id, e_to) = pending_transfer::transfer_finalized_fields_for_testing(events.borrow(0));
    assert!(e_cap_id == cap_id, 1);
    assert!(e_to == RECIPIENT, 2);

    let (_id, _to) = pending_transfer::unwrap_ticket(ticket);
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun finalize_transfer_callable_by_third_party() {
    let mut scenario = setup();
    let (_cap_id, mut clock) = setup_pending(&mut scenario);
    accept_as_recipient(&mut scenario);

    clock::set_for_testing(&mut clock, DELAY_MS);
    scenario.next_tx(THIRD_PARTY);
    let pending2 = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    let ticket = pending_transfer::finalize_transfer(pending2, &mut registry, &clock, scenario.ctx());
    let (_id, to) = pending_transfer::unwrap_ticket(ticket);
    assert!(to == RECIPIENT, 0);

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

// === M7 Chunk 1: unwrap_ticket visibility hardening (fixes I-1) ===
//
// `unwrap_ticket<T>` (`sources/pending_transfer.move`) is now
// `public(package)`, not `public` (REQ-XFER-013). Every call site above
// (`finalize_transfer_callable_by_third_party`,
// `finalize_transfer_transfer_ticket_carries_correct_recipient`, etc.)
// continues to compile with no code change of its own, since this test
// module is itself part of the same package (`tiny_clob`) —
// `public(package)` is the exact visibility level that permits this.
//
// The three tasks below are structural/code-review checks, not
// `#[test]` functions — matching `order_tests.move`'s
// `order_ticket_never_written_after_mint` precedent for this class of
// check — since no `#[expected_failure]` test can observe "a call from
// outside the package was rejected" from inside this same package's own
// test suite (a same-package test calling `unwrap_ticket` directly proves
// nothing about whether an external module could; only Move's compiler,
// at compile time, enforces that boundary).
//
// - `unwrap_ticket_is_public_package_not_public`: confirmed directly by
//   `sources/pending_transfer.move`'s `unwrap_ticket` declaration itself —
//   `public(package) fun unwrap_ticket<T>(ticket: TransferTicket<T>): (ID,
//   address)`, not `public fun ...`.
// - `unwrap_ticket_callers_are_exactly_the_three_redeem_functions`:
//   grep-confirmed — the package's only three call sites are
//   `market::redeem_transfer_ticket` (`sources/order.move`),
//   `admin::redeem_admin_cap_transfer_ticket` (`sources/admin.move`), and
//   `market::redeem_pool_admin_cap_transfer_ticket`
//   (`sources/market.move`), plus this test module's own direct unit-test
//   calls above — each production call site always follows the unwrap
//   with a real `transfer::transfer` on the just-obtained capability.
// - `finalize_transfer_remains_public_unchanged_by_i1_fix`: confirmed
//   directly by `sources/pending_transfer.move` — `finalize_transfer`'s
//   declaration is still `public fun finalize_transfer<T>(...)`, entirely
//   untouched by this milestone's visibility change to `unwrap_ticket`.

// === M8 Chunk 1: initiate_transfer visibility narrowing (fixes Mi-2) ===
//
// `initiate_transfer<T: key>` (`sources/pending_transfer.move`) is now
// `public(package)`, not `public` (REQ-XFER-014). Every call site above
// (`setup_pending`, `initiate_transfer_aborts_on_parallel_pending_transfer`,
// etc.) continues to compile with no code change of its own, since this
// test module is itself part of the same package — `public(package)` is
// the exact visibility level that permits this, mirroring
// `unwrap_ticket`'s M7 precedent above.
//
// The two tasks below are structural/code-review checks, not `#[test]`
// functions, for the same reason `unwrap_ticket`'s own structural checks
// above are not: no `#[expected_failure]` test run from inside this same
// package's own test suite can observe "a call from outside the package
// was rejected."
//
// - `initiate_transfer_is_public_package_not_public`: confirmed directly
//   by `sources/pending_transfer.move`'s `initiate_transfer` declaration
//   itself — `public(package) fun initiate_transfer<T: key>(...)`, not
//   `public fun ...`. Grep-confirmed: the package's only three call sites
//   in production (non-test) code are the three typed wrappers added this
//   cycle — `admin::initiate_admin_cap_transfer`,
//   `admin::initiate_pool_admin_cap_transfer` (`sources/admin.move`), and
//   `market::initiate_order_ticket_transfer` (`sources/order.move`); this
//   test module's own direct `initiate_transfer` calls (above, and in
//   `tests/m6_integration_tests.move`/`tests/order_tests.move`) are
//   same-package test-suite exceptions, not production call sites.
// - `accept_transfer_cancel_transfer_request_finalize_transfer_remain_
//   generic_and_public_unaffected_by_xfer_014`: confirmed directly by
//   `sources/pending_transfer.move` — `accept_transfer<T>`,
//   `cancel_transfer_request<T>`, and `finalize_transfer<T>` remain
//   declared exactly as before (`public fun ...<T>(...)`), untouched by
//   this cycle's narrowing of `initiate_transfer` alone.

// === M9 Chunk 1: PendingTransferRegistry.version guard (fixes C-2, REQ-XFER-015) ===

#[test]
fun registry_version_defaults_to_current_version() {
    let scenario = setup();
    let registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    assert!(
        pending_transfer::registry_version_is_for_testing(&registry, pending_transfer::current_version()),
        0,
    );
    ts::return_shared(registry);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 5)] // pending_transfer::EStaleObjectVersion
fun initiate_transfer_aborts_on_stale_registry_version() {
    let mut scenario = setup();
    let _cap_id = mint_dummy_cap_to_sender(&mut scenario);
    let clock = new_clock(&mut scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    pending_transfer::set_registry_version(&mut registry, OFF_VERSION);
    let cap = ts::take_from_sender<DummyCap>(&scenario);

    pending_transfer::initiate_transfer(&cap, RECIPIENT, &mut registry, &clock, scenario.ctx());

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 5)] // pending_transfer::EStaleObjectVersion
fun cancel_transfer_request_aborts_on_stale_registry_version() {
    let mut scenario = setup();
    let (_cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(SENDER);
    let pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    pending_transfer::set_registry_version(&mut registry, OFF_VERSION);

    pending_transfer::cancel_transfer_request(pending, &mut registry, scenario.ctx());

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 5)] // pending_transfer::EStaleObjectVersion
fun finalize_transfer_aborts_on_stale_registry_version() {
    let mut scenario = setup();
    let (_cap_id, mut clock) = setup_pending(&mut scenario);
    accept_as_recipient(&mut scenario);

    clock::set_for_testing(&mut clock, DELAY_MS);
    scenario.next_tx(SENDER);
    let pending2 = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);
    pending_transfer::set_registry_version(&mut registry, OFF_VERSION);

    let ticket = pending_transfer::finalize_transfer(pending2, &mut registry, &clock, scenario.ctx());
    let (_id, _to) = pending_transfer::unwrap_ticket(ticket);

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun pending_transfer_registry_version_guard_blocks_stale_then_migration_unblocks() {
    // Confirm the guard blocks all three functions while stale (proven
    // independently above by the three `#[expected_failure]` tests), then
    // confirm restoring `version` via `set_registry_version` unblocks all
    // three again, and confirm `accept_transfer` (no registry parameter at
    // all) is entirely unaffected either way.
    let mut scenario = setup();
    let cap_id = mint_dummy_cap_to_sender(&mut scenario);
    let mut clock = new_clock(&mut scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);

    // Go stale, then restore, before ever calling `initiate_transfer`.
    pending_transfer::set_registry_version(&mut registry, OFF_VERSION);
    assert!(!pending_transfer::registry_version_is_for_testing(&registry, pending_transfer::current_version()), 0);
    pending_transfer::set_registry_version(&mut registry, pending_transfer::current_version());
    assert!(pending_transfer::registry_version_is_for_testing(&registry, pending_transfer::current_version()), 1);

    // initiate_transfer succeeds now that version is restored.
    let cap = ts::take_from_sender<DummyCap>(&scenario);
    pending_transfer::initiate_transfer(&cap, RECIPIENT, &mut registry, &clock, scenario.ctx());
    ts::return_to_sender(&scenario, cap);
    scenario.next_tx(RECIPIENT);

    // accept_transfer takes no registry parameter — unaffected by version
    // state entirely, regardless of whether the registry is stale.
    let mut pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    pending_transfer::accept_transfer(&mut pending, scenario.ctx());
    let (_, _, _, _, accepted) = pending_transfer::pending_fields_for_testing(&pending);
    assert!(accepted, 2);
    ts::return_shared(pending);

    // finalize_transfer succeeds with version restored.
    clock::set_for_testing(&mut clock, DELAY_MS);
    scenario.next_tx(SENDER);
    let pending2 = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let ticket = pending_transfer::finalize_transfer(pending2, &mut registry, &clock, scenario.ctx());
    let (ticket_cap_id, ticket_to) = pending_transfer::unwrap_ticket(ticket);
    assert!(ticket_cap_id == cap_id, 3);
    assert!(ticket_to == RECIPIENT, 4);

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

#[test]
fun cancel_transfer_request_succeeds_after_version_restored() {
    let mut scenario = setup();
    let (cap_id, clock) = setup_pending(&mut scenario);
    scenario.next_tx(SENDER);
    let pending = ts::take_shared<PendingTransfer<DummyCap>>(&scenario);
    let mut registry = ts::take_shared<PendingTransferRegistry>(&scenario);

    pending_transfer::set_registry_version(&mut registry, OFF_VERSION);
    pending_transfer::set_registry_version(&mut registry, pending_transfer::current_version());

    pending_transfer::cancel_transfer_request(pending, &mut registry, scenario.ctx());
    assert!(!pending_transfer::registry_contains_for_testing(&registry, cap_id), 0);

    ts::return_shared(registry);
    clock::destroy_for_testing(clock);
    scenario.end();
}

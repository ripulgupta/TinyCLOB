/// Generic, capability-type-agnostic delayed capability-transfer mechanism.
/// See `docs/spec/pending_transfer.md`.
///
/// Standalone module: no dependency on `market`/`order`/`admin`. Generic
/// over any `T: key` — `AdminCap`, `PoolAdminCap`, `OrderTicket`, or any
/// future capability type this package defines.
module tiny_clob::pending_transfer;

use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

// === Errors ===

/// `initiate_transfer` called while a pending transfer is already active for
/// this capability's id (REQ-XFER-004/-005).
const EParallelTransferActive: u64 = 0;
/// `accept_transfer` called by an address other than `pending.to`
/// (REQ-XFER-006).
const ENotRecipient: u64 = 1;
/// `cancel_transfer_request` called by an address other than `pending.from`
/// (REQ-XFER-007).
const ENotSender: u64 = 2;
/// `finalize_transfer` called before `accept_transfer` (REQ-XFER-008).
const ENotAccepted: u64 = 3;
/// `finalize_transfer` called before `TRANSFER_DELAY_MS` has elapsed since
/// `proposed_at_ms` (REQ-XFER-008/-009).
const EDelayNotElapsed: u64 = 4;
/// `initiate_transfer`/`finalize_transfer`/`cancel_transfer_request` called
/// against a `PendingTransferRegistry` whose `version` does not equal
/// `CURRENT_VERSION` (REQ-XFER-015, fixes C-2).
const EStaleObjectVersion: u64 = 5;

// === The fixed 2-day delay (REQ-XFER-009) ===

/// Fixed, not configurable anywhere in this package.
const TRANSFER_DELAY_MS: u64 = 172_800_000;

// === Cross-module `CURRENT_VERSION` mechanism (REQ-XFER-015, fixes C-2) ===

/// This module is the canonical, package-wide home for `CURRENT_VERSION`:
/// it is the one module in this package with zero dependencies of its own,
/// already depended on by `market.move`/`admin.move`/`order.move`. See
/// `docs/spec/pending_transfer.md` §Cross-module `CURRENT_VERSION`
/// mechanism (full rationale cross-linked from `docs/spec/market.md`'s
/// identically-named section).
const CURRENT_VERSION: u64 = 1;

/// Cross-module accessor for `CURRENT_VERSION` — every other module's own
/// version guard reads this rather than declaring its own copy of the
/// constant.
public(package) fun current_version(): u64 {
    CURRENT_VERSION
}

// === Types ===

/// `pending_transfer.md` §PendingTransfer. `key` only — no `store`. Shared
/// so both `from` and `to` can independently interact with it. Never holds
/// the actual capability object `T` in any field or dynamic field — only
/// its id plus bookkeeping metadata (REQ-XFER-002).
public struct PendingTransfer<phantom T> has key {
    id: UID,
    cap_id: ID,
    from: address,
    to: address,
    proposed_at_ms: u64,
    accepted: bool,
}

/// `pending_transfer.md` §TransferTicket. No abilities at all — a hot
/// potato. Must be consumed via `unwrap_ticket` within the same transaction
/// `finalize_transfer` produced it in (REQ-XFER-003).
public struct TransferTicket<phantom T> {
    cap_id: ID,
    to: address,
}

/// `pending_transfer.md` §PendingTransferRegistry. Shared singleton, created
/// exactly once at this module's own `init`. Keyed by capability object id,
/// not by type `T` — one instance covers every capability type this module
/// is ever used for (REQ-XFER-004).
public struct PendingTransferRegistry has key {
    id: UID,
    active: Table<ID, ID>,
    version: u64,   // REQ-XFER-015 — C-2 version guard
}

// === Events (REQ-XFER-012) ===

public struct TransferInitiated has copy, drop {
    cap_id: ID,
    from: address,
    to: address,
}

public struct TransferAccepted has copy, drop {
    cap_id: ID,
    to: address,
}

public struct TransferCancelled has copy, drop {
    cap_id: ID,
    from: address,
}

public struct TransferFinalized has copy, drop {
    cap_id: ID,
    to: address,
}

// === Init ===

/// Creates the single shared `PendingTransferRegistry` (REQ-XFER-004). Sui
/// invokes this automatically, once, at package publish.
fun init(ctx: &mut TxContext) {
    transfer::share_object(PendingTransferRegistry {
        id: object::new(ctx),
        active: table::new(ctx),
        version: CURRENT_VERSION,
    });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Asserts `registry.version == CURRENT_VERSION` (REQ-XFER-015). Private —
/// only this module's own three guarded functions
/// (`initiate_transfer`/`finalize_transfer`/`cancel_transfer_request`) call
/// it, same-module, with no cross-module caller needing it.
/// `accept_transfer` takes no `&PendingTransferRegistry` parameter and is
/// therefore not subject to this check, per REQ-XFER-015's own explicit
/// exclusion.
fun assert_registry_version(registry: &PendingTransferRegistry) {
    assert!(registry.version == CURRENT_VERSION, EStaleObjectVersion);
}

/// Package-visible setter for `admin.move`'s forthcoming
/// `migrate_pending_transfer_registry_version` (REQ-ADMIN-030, Chunk 6) to
/// bump `registry.version` after a migration. No validation of
/// `new_version` — mirrors `set_pool_admin_cap_id`'s existing convention.
public(package) fun set_registry_version(registry: &mut PendingTransferRegistry, new_version: u64) {
    registry.version = new_version;
}

// === initiate_transfer (REQ-XFER-005) ===

/// Takes only a reference to `cap` — the sender's physical custody never
/// changes as a result of this call. Aborts if a pending transfer is
/// already active for `object::id(cap)` (the parallel-transfer guard).
///
/// `public(package)` (REQ-XFER-014, fixes audit finding Mi-2) — narrowed
/// from `public` so only this same package's own typed wrapper functions
/// (`admin::initiate_admin_cap_transfer`, `admin::initiate_pool_admin_cap_
/// transfer`, `market::initiate_order_ticket_transfer`) can call it; a
/// `public` visibility here would let any external module initiate a
/// pending transfer for an arbitrary key-only type this mechanism was
/// never meant to protect.
public(package) fun initiate_transfer<T: key>(
    cap: &T,
    to: address,
    registry: &mut PendingTransferRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_registry_version(registry);
    let cap_id = object::id(cap);
    assert!(!table::contains(&registry.active, cap_id), EParallelTransferActive);

    let pending = PendingTransfer<T> {
        id: object::new(ctx),
        cap_id,
        from: ctx.sender(),
        to,
        proposed_at_ms: clock.timestamp_ms(),
        accepted: false,
    };
    // Capture the id before `pending` is consumed by value below — mirrors
    // `market.md`'s "capture the id before consuming by value" pattern.
    let pending_id = object::id(&pending);
    transfer::share_object(pending);
    table::add(&mut registry.active, cap_id, pending_id);

    event::emit(TransferInitiated { cap_id, from: ctx.sender(), to });
}

// === accept_transfer (REQ-XFER-006) ===

/// Callable only by `pending.to`. Touches no actual capability object.
public fun accept_transfer<T>(pending: &mut PendingTransfer<T>, ctx: &mut TxContext) {
    assert!(ctx.sender() == pending.to, ENotRecipient);
    pending.accepted = true;
    event::emit(TransferAccepted { cap_id: pending.cap_id, to: pending.to });
}

// === cancel_transfer_request (REQ-XFER-007) ===

/// Callable only by `pending.from`, at any time before `finalize_transfer`
/// has resolved this `PendingTransfer` — no minimum-elapsed-time or
/// acceptance-state gate. Nothing to return: the capability was never held
/// by this module.
public fun cancel_transfer_request<T>(
    pending: PendingTransfer<T>,
    registry: &mut PendingTransferRegistry,
    ctx: &mut TxContext,
) {
    assert_registry_version(registry);
    assert!(ctx.sender() == pending.from, ENotSender);
    let PendingTransfer { id, cap_id, from, to: _, proposed_at_ms: _, accepted: _ } = pending;
    table::remove(&mut registry.active, cap_id);
    id.delete();
    event::emit(TransferCancelled { cap_id, from });
}

// === finalize_transfer (REQ-XFER-008/-009) ===

/// Callable by anyone — only touches `PendingTransfer` bookkeeping, never
/// the actual capability. Aborts unless both accepted and the fixed 2-day
/// delay has elapsed.
///
/// A standalone, non-same-PTB-following call by a third party outside this
/// package cannot *complete* a transfer on its own: the returned
/// `TransferTicket<T>` is a hot potato (no abilities at all) that only
/// `unwrap_ticket` (`public(package)`) can consume, and `unwrap_ticket`
/// aborts for any caller outside this package's own `redeem_*` functions
/// (`market::redeem_transfer_ticket`, `admin::redeem_admin_cap_transfer_
/// ticket`, `market::redeem_pool_admin_cap_transfer_ticket`). A hot potato
/// with no abilities cannot be dropped or stored, so a transaction that
/// calls `finalize_transfer` alone (with no same-PTB `redeem_*` call
/// following it) cannot even complete successfully.
public fun finalize_transfer<T>(
    pending: PendingTransfer<T>,
    registry: &mut PendingTransferRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): TransferTicket<T> {
    assert_registry_version(registry);
    assert!(pending.accepted, ENotAccepted);
    assert!(clock.timestamp_ms() >= pending.proposed_at_ms + TRANSFER_DELAY_MS, EDelayNotElapsed);

    let PendingTransfer { id, cap_id, from: _, to, proposed_at_ms: _, accepted: _ } = pending;
    table::remove(&mut registry.active, cap_id);
    id.delete();
    event::emit(TransferFinalized { cap_id, to });
    let _ = ctx;
    TransferTicket { cap_id, to }
}

// === unwrap_ticket (REQ-XFER-010) ===

/// The only way another module can obtain a `TransferTicket`'s contents.
/// `public(package)` (REQ-XFER-013, fixes audit finding I-1) — narrowed from
/// `public` so only this same package's own `redeem_*` functions
/// (`market::redeem_transfer_ticket`, `admin::redeem_admin_cap_transfer_ticket`,
/// `market::redeem_pool_admin_cap_transfer_ticket`) can call it; a
/// `public` visibility here would let any external module unwrap a ticket
/// without following it with a real `transfer::transfer`, burning the
/// capability transfer without ever delivering it.
public(package) fun unwrap_ticket<T>(ticket: TransferTicket<T>): (ID, address) {
    let TransferTicket { cap_id, to } = ticket;
    (cap_id, to)
}

// === test-only accessors ===

#[test_only]
public fun transfer_delay_ms_for_testing(): u64 {
    TRANSFER_DELAY_MS
}

#[test_only]
public fun registry_active_len_for_testing(registry: &PendingTransferRegistry): u64 {
    registry.active.length()
}

#[test_only]
public fun registry_contains_for_testing(registry: &PendingTransferRegistry, cap_id: ID): bool {
    table::contains(&registry.active, cap_id)
}

#[test_only]
public fun registry_version_is_for_testing(registry: &PendingTransferRegistry, expected: u64): bool {
    registry.version == expected
}

#[test_only]
public fun pending_fields_for_testing<T>(p: &PendingTransfer<T>): (ID, address, address, u64, bool) {
    (p.cap_id, p.from, p.to, p.proposed_at_ms, p.accepted)
}

#[test_only]
public fun transfer_initiated_fields_for_testing(e: &TransferInitiated): (ID, address, address) {
    (e.cap_id, e.from, e.to)
}

#[test_only]
public fun transfer_accepted_fields_for_testing(e: &TransferAccepted): (ID, address) {
    (e.cap_id, e.to)
}

#[test_only]
public fun transfer_cancelled_fields_for_testing(e: &TransferCancelled): (ID, address) {
    (e.cap_id, e.from)
}

#[test_only]
public fun transfer_finalized_fields_for_testing(e: &TransferFinalized): (ID, address) {
    (e.cap_id, e.to)
}

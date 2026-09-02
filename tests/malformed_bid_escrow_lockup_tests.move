/// Regression test for finding I-01: `order::new`'s doc comment claims
/// "every real call site... populates exactly one of the two [escrow_base,
/// escrow_quote]", but `new` used to never assert this. Since `new` is
/// `public(package)`, any sibling module in this package -- including a
/// test module, as here -- can call it directly with BOTH escrow options
/// populated.
///
/// Before the fix, this malformed construction would silently succeed, and
/// the resulting order would only fail much later -- and unrecoverably --
/// the moment it fully drained: `destroy_drained_bid_escrow`
/// (sources/tiny_clob.move) unconditionally does `escrow_base.destroy_none()`,
/// which aborts because `escrow_base` is unexpectedly `Some`, permanently
/// blocking the front of its price-level FIFO queue for any other order.
///
/// `order::new` now asserts `escrow_base.is_some() != escrow_quote.is_some()`
/// up front, so the malformed construction itself aborts immediately, with
/// `order::EEscrowMustBeExclusive`, instead of deferring the failure to a
/// much later, harder-to-diagnose, and permanently-stuck call site.
#[test_only]
module tiny_clob::malformed_bid_escrow_lockup_tests;

use sui::balance;
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC};
use tiny_clob::test_utils::{Self, admin, maker_a, new_book, destroy_book_and_cap, default_price, default_size};

/// `order::new`'s own module-local error constant -- see
/// `order::EEscrowMustBeExclusive`'s doc comment.
const EESCROW_MUST_BE_EXCLUSIVE: u64 = 0;

#[test]
#[expected_failure(abort_code = EESCROW_MUST_BE_EXCLUSIVE, location = tiny_clob::order)]
fun malformed_bid_with_both_escrows_is_rejected_at_construction() {
    let mut scenario = sui::test_scenario::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    let price = default_price();
    let size = default_size();

    // Build the malformed bid directly via `order::new`, deliberately
    // violating the "exactly one of the two" invariant the doc comment
    // claims: BOTH `escrow_base` and `escrow_quote` are populated with
    // real, non-zero balances.
    scenario.next_tx(maker_a());
    let order_id = book.next_order_id();
    // `price_scale == 1` for `new_book`, so the minimal Quote escrow for a
    // bid of this (price, size) is exactly `price * size`.
    let escrow_quote = balance::create_for_testing<USDC>(price * size);
    let escrow_base = balance::create_for_testing<BTC>(1); // should be `option::none()` for a real bid
    let malformed_bid = order::new<BTC, USDC>(
        order_id,
        maker_a(),
        size,
        option::some(escrow_base),
        option::some(escrow_quote),
        0,
    );

    // Unreachable -- `order::new` above aborts. Kept only so the function
    // type-checks if the abort is ever fixed out from under this test.
    let (escrow_base_opt, escrow_quote_opt, fee_reserve_base_opt, fee_reserve_quote_opt) =
        order::destroy(malformed_bid);
    escrow_base_opt.destroy_some().destroy_for_testing();
    escrow_quote_opt.destroy_some().destroy_for_testing();
    fee_reserve_base_opt.destroy_some().destroy_for_testing();
    fee_reserve_quote_opt.destroy_none();
    destroy_book_and_cap(book, cap);
    scenario.end();
}

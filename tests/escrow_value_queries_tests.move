#[test_only]
module tiny_clob::escrow_value_queries_tests;

use std::unit_test;
use sui::balance;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;
use tiny_clob::tiny_clob::{Self, OrderBook, OrderTicket, ClobAdminCap, ProceedsClaimed, MakerFeeSettled};
use tiny_clob::order;
use tiny_clob::test_markers::{BTC, USDC, SUI, WAL};
use tiny_clob::test_utils::{
    Self, admin, other, taker, maker_a, maker_b, min_size, default_price, default_size, shortfall_price, new_book, destroy_book_and_cap, rest_bid, rest_ask, shortfall_book, u64_max,
};


// === Change 2: `bid_quote_escrow_at_price` exact dual-aggregate tracking ===

#[test]
fun bid_quote_escrow_at_price_matches_single_order_after_partial_fill() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    let size = 100;
    scenario.next_tx(maker_a());
    let reserved = book.bid_escrow_amount(shortfall_price(), size);
    let bid_ticket = rest_bid(&mut book, shortfall_price(), size, 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Fresh order: the level's maintained aggregate must equal the single
    // order's own full reservation.
    assert!(book.bid_quote_escrow_at_price(shortfall_price()) == reserved, 0);
    // No bid level at any other price.
    assert!(book.bid_quote_escrow_at_price(shortfall_price() + 1) == 0, 1);

    // Partially fill it and confirm the aggregate exactly tracks the fill's
    // actual charge (read off the `OrderFilled` event's own `quote_amount`,
    // rather than re-deriving the ceiling formula by hand in the test).
    scenario.next_tx(maker_b());
    let fill_qty = 30;
    let base = coin::mint_for_testing<BTC>(fill_qty, scenario.ctx());
    // Pure crossing fill (never rests): `place_market_order_ask` needs no
    // price/expected-output derivation.
    let (lb, mq, _) = book.place_market_order_ask(base, 10, 0, u64_max(), scenario.ctx());
    lb.burn_for_testing();
    let quote_charged = mq.burn_for_testing();

    let fills = event::events_by_type<tiny_clob::OrderFilled>();
    assert!(fills.length() == 1, 3);
    let (ev_maker_side, ev_quote_amount) = fills[0].order_filled_side_and_quote_fields_for_testing();
    assert!(ev_maker_side, 4);
    assert!(ev_quote_amount == quote_charged, 5);

    let expected_remaining = reserved - quote_charged;
    assert!(book.bid_quote_escrow_at_price(shortfall_price()) == expected_remaining, 6);

    // Cross-check against the per-order query (Change 3), which must agree
    // exactly since there's only one order at this price.
    let escrow_opt = book.resting_order_escrow(true, shortfall_price(), order_id);
    assert!(escrow_opt.is_some(), 7);
    let (per_order_escrow, per_order_remaining_size) =
        escrow_opt.borrow().resting_order_escrow_fields();
    assert!(per_order_escrow == expected_remaining, 8);
    // `remaining_size` is Quote-denominated for a bid, equal to the live
    // escrow value (see `order::Order.remaining_size`'s doc comment) -- NOT
    // the Base `size - fill_qty` this would have been under the old scheme.
    assert!(per_order_remaining_size == expected_remaining, 9);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun bid_quote_escrow_at_price_sums_two_orders_at_same_price() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size_a = 100;
    let reserved_a = book.bid_escrow_amount(shortfall_price(), size_a);
    let ticket_a = rest_bid(&mut book, shortfall_price(), size_a, 10, scenario.ctx());

    scenario.next_tx(maker_b());
    let size_b = 50;
    let reserved_b = book.bid_escrow_amount(shortfall_price(), size_b);
    let ticket_b = rest_bid(&mut book, shortfall_price(), size_b, 10, scenario.ctx());

    // The maintained aggregate is the exact sum of each order's own live
    // escrow -- not a derived/re-estimated value.
    assert!(book.bid_quote_escrow_at_price(shortfall_price()) == reserved_a + reserved_b, 0);

    // Cancelling both drains the level back to empty; the aggregate must
    // reach exactly 0 (proven indirectly: `destroy_empty_price_level`'s
    // strengthened assert on `total_quote_escrow == 0` would abort
    // otherwise, and this cancellation path exercises that cleanup).
    scenario.next_tx(maker_a());
    let (cb_a, cq_a) = book.cancel_order(ticket_a, scenario.ctx());
    cb_a.burn_for_testing();
    assert!(cq_a.burn_for_testing() == reserved_a, 1);
    assert!(book.bid_quote_escrow_at_price(shortfall_price()) == reserved_b, 2);

    scenario.next_tx(maker_b());
    let (cb_b, cq_b) = book.cancel_order(ticket_b, scenario.ctx());
    cb_b.burn_for_testing();
    assert!(cq_b.burn_for_testing() == reserved_b, 3);
    assert!(book.bid_quote_escrow_at_price(shortfall_price()) == 0, 4);

    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Change 3: `resting_order_escrow` / `resting_order_escrow_by_ticket` ===

#[test]
fun resting_order_escrow_fresh_bid_and_ask() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let bid_size = default_size();
    let reserved = book.bid_escrow_amount(default_price(), bid_size);
    let bid_ticket = rest_bid(&mut book, default_price(), bid_size, 10, scenario.ctx());
    let bid_order_id = bid_ticket.ticket_order_id();

    let bid_escrow_opt = book.resting_order_escrow(true, default_price(), bid_order_id);
    assert!(bid_escrow_opt.is_some(), 0);
    let (bid_escrow, bid_remaining) = bid_escrow_opt.borrow().resting_order_escrow_fields();
    assert!(bid_escrow == reserved, 1);
    // Quote-denominated for a bid -- equal to `reserved`, not `bid_size`.
    assert!(bid_remaining == reserved, 2);

    // Same result via the ticket-based wrapper.
    let bid_escrow_opt_via_ticket = book.resting_order_escrow_by_ticket(&bid_ticket);
    assert!(bid_escrow_opt_via_ticket.is_some(), 3);
    let (bid_escrow_2, bid_remaining_2) =
        bid_escrow_opt_via_ticket.borrow().resting_order_escrow_fields();
    assert!(bid_escrow_2 == reserved, 4);
    assert!(bid_remaining_2 == reserved, 5);

    scenario.next_tx(maker_b());
    let ask_price = default_price() + 1; // above best bid, so it just rests.
    let ask_size = default_size();
    let ask_ticket = rest_ask(&mut book, ask_price, ask_size, 10, scenario.ctx());
    let ask_order_id = ask_ticket.ticket_order_id();

    // An ask escrows Base, exactly equal to `remaining_size`.
    let ask_escrow_opt = book.resting_order_escrow(false, ask_price, ask_order_id);
    assert!(ask_escrow_opt.is_some(), 6);
    let (ask_escrow, ask_remaining) = ask_escrow_opt.borrow().resting_order_escrow_fields();
    assert!(ask_escrow == ask_size, 7);
    assert!(ask_remaining == ask_size, 8);

    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun resting_order_escrow_after_partial_fill_full_fill_and_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size = 200;
    let reserved = book.bid_escrow_amount(default_price(), size);
    let bid_ticket = rest_bid(&mut book, default_price(), size, 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Partial fill: escrow decreases by exactly the fill's own charged
    // amount (read off the `OrderFilled` event), remaining_size decreases
    // by the fill quantity.
    scenario.next_tx(taker());
    let fill_qty = min_size();
    let ask_payment = coin::mint_for_testing<BTC>(fill_qty, scenario.ctx());
    let (leftover, matched_quote, _) = book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_qty, scenario.ctx(),
    );
    leftover.burn_for_testing();
    let quote_charged = matched_quote.burn_for_testing();

    let opt_after_partial = book.resting_order_escrow(true, default_price(), order_id);
    assert!(opt_after_partial.is_some(), 0);
    let (escrow_after_partial, remaining_after_partial) =
        opt_after_partial.borrow().resting_order_escrow_fields();
    assert!(escrow_after_partial == reserved - quote_charged, 1);
    // Quote-denominated for a bid -- equal to `escrow_after_partial`, not
    // the Base `size - fill_qty`.
    assert!(remaining_after_partial == reserved - quote_charged, 2);

    // Full fill: the order is completely drained and removed, so the query
    // must return None (distinct from `Some((0, r>0))`).
    scenario.next_tx(taker());
    let remaining_size = size - fill_qty;
    let ask_payment_2 = coin::mint_for_testing<BTC>(remaining_size, scenario.ctx());
    let (leftover_2, matched_quote_2, _) = book.place_market_order_ask(ask_payment_2, 1_000_000_000, 0, remaining_size, scenario.ctx(),
    );
    leftover_2.burn_for_testing();
    matched_quote_2.burn_for_testing();
    assert!(book.resting_order_escrow(true, default_price(), order_id).is_none(), 3);

    // Cancel path: rest a fresh order, then cancel it -- must also read back
    // as None.
    scenario.next_tx(maker_b());
    let bid_ticket_2 = rest_bid(&mut book, default_price(), size, 10, scenario.ctx());
    let order_id_2 = bid_ticket_2.ticket_order_id();
    assert!(book.resting_order_escrow(true, default_price(), order_id_2).is_some(), 4);
    let (cb, cq) = book.cancel_order(bid_ticket_2, scenario.ctx());
    cb.burn_for_testing();
    cq.burn_for_testing();
    assert!(book.resting_order_escrow(true, default_price(), order_id_2).is_none(), 5);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun resting_order_escrow_wrong_lookup_is_none() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Sanity: the correct lookup succeeds.
    assert!(book.resting_order_escrow(true, default_price(), order_id).is_some(), 0);

    // Wrong side: no ask level exists at this price at all.
    assert!(book.resting_order_escrow(false, default_price(), order_id).is_none(), 1);
    // Wrong price: no bid level exists there.
    assert!(book.resting_order_escrow(true, default_price() + 1, order_id).is_none(), 2);
    // Wrong order_id: the level exists but doesn't contain this id.
    assert!(book.resting_order_escrow(true, default_price(), order_id + 1).is_none(), 3);

    // Ticket-based wrapper aborts on a ticket minted by a different book.
    let (other_book, other_cap) = new_book(&mut scenario);
    let other_book_id = other_book.book_id();
    let foreign_ticket = tiny_clob::new_ticket_for_testing(order_id, other_book_id, tiny_clob::bid(), default_price());
    // (Not calling resting_order_escrow_by_ticket(&book, &foreign_ticket)
    // here to avoid an abort mid-test; wrong-book behavior is exercised in
    // resting_order_escrow_by_ticket_wrong_book_aborts below.)
    unit_test::destroy(foreign_ticket);
    destroy_book_and_cap(other_book, other_cap);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // EWrongBook
fun resting_order_escrow_by_ticket_wrong_book_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);
    let (other_book, other_cap) = new_book(&mut scenario);

    let other_book_id = other_book.book_id();
    let foreign_ticket = tiny_clob::new_ticket_for_testing(0, other_book_id, tiny_clob::bid(), default_price());
    let _ = book.resting_order_escrow_by_ticket(&foreign_ticket);

    unit_test::destroy(foreign_ticket);
    destroy_book_and_cap(book, cap);
    destroy_book_and_cap(other_book, other_cap);
    scenario.end();
}

// Reachable `Some((0, 0))` state (RETARGETED for the telescoping
// cumulative-proportional-ceiling escrow-charging scheme -- see
// `order::Order.original_size`'s doc comment and `fill_level_ask` in
// `tiny_clob.move`): a bid's escrow (Quote) can hit exactly `0` strictly
// before its Base side (`original_size - fee_basis_accumulated`) is
// exhausted, so the order is still resting with real remaining Base
// capacity even though `resting_order_escrow_fields` reports `(escrow: 0,
// remaining_size: 0)` (both fields are the same live Quote escrow value for
// a bid -- see the field's own doc comment). Distinct from `None` (not
// resting at all).
//
// NOTE: this does NOT reuse the shared `shortfall_book`/`shortfall_price`
// fixture (`price=5`, `price_scale=10`). Under the new `price_scale =
// scale_lo` derivation `price_scale` is always a power of ten (see
// `new`'s doc comment), so a `price` of `5` against a `price_scale` of
// `10` is always exactly `1/2` -- the cumulative-ceiling target reaches
// `total_reserved` only ONE unit before `original_size` is exhausted (a
// structural consequence of a `1/2` ratio, independent of the chosen size),
// leaving no room for a genuinely resting, zero-escrow, NOT-yet-fully-drained
// state with more than one further fill's worth of slack. A bespoke book
// with a `1/3`-ish ratio (`price=33`, `price_scale=100`) is used instead so
// the plateau at `total_reserved` has real width (`target(k)` first reaches
// `33` at `k=97`, ninety-seven fills before `original_size=100`), leaving 3
// full units of genuinely resting Base capacity to demonstrate this state
// with.
#[test]
fun resting_order_escrow_reaches_some_zero_escrow_while_still_resting() {
    let mut scenario = ts::begin(admin());
    // base_decimals=0, quote_decimals=0, precision=2, exponent=16:
    // scale_lo = ceil(10^2) = 100 = price_scale (scale_hi = floor(u64::MAX /
    // 10^16) = 1_844, comfortably above scale_lo, so feasible).
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 2, 16, 33, &wrapper_uid, scenario.ctx());
    assert!(book.price_scale() == 100, 0);

    // A FRESH resting bid (no partial-cross clamp needed): size=100,
    // total_reserved = bid_escrow_amount(33, 100) = ceil(3_300/100) = 33.
    scenario.next_tx(maker_a());
    let reserved = book.bid_escrow_amount(33, 100);
    assert!(reserved == 33, 1);
    let bid_ticket = rest_bid(&mut book, 33, 100, 200, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Ninety-seven 1-unit fills of the 100-unit order, each taker-limited
    // (maker still has size left afterward). Hand-derived cumulative-ceiling
    // values: `target(k) = ceil(33*k/100)` first reaches `33`
    // (`total_reserved`) at `k=97`, ninety-seven fills before
    // `original_size=100` -- leaving 3 full units of genuinely resting Base
    // capacity once the escrow is exhausted.
    scenario.next_tx(maker_b());
    let mut total_charged: u64 = 0;
    let mut i = 0u64;
    while (i < 97) {
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        // Pure crossing fill (never rests): `place_market_order_ask` needs
        // no price/expected-output derivation. This also sidesteps a
        // structural constraint of the new API worth noting: any
        // legitimately-DERIVED resting-ask price/size pair must satisfy
        // `price * size >= price_scale`, so a genuinely resting size-1 ask
        // could never derive a price as low as `33` at this book's
        // `price_scale == 100` -- irrelevant here since this fill only ever
        // crosses, never rests.
        let (lb, mq, _) = book.place_market_order_ask(base, 200, 0, u64_max(), scenario.ctx());
        lb.burn_for_testing();
        total_charged = total_charged + mq.burn_for_testing();
        i = i + 1;
    };
    // Sum == total_reserved: the escrow hits exactly 0 after the 97th fill,
    // while the maker still has 100 - 97 = 3 units of genuinely resting
    // Base capacity.
    assert!(total_charged == reserved, 2);

    let escrow_opt = book.resting_order_escrow(true, 33, order_id);
    assert!(escrow_opt.is_some(), 3);
    let (escrow, remaining) = escrow_opt.borrow().resting_order_escrow_fields();
    assert!(escrow == 0, 4);
    // `remaining_size` is Quote-denominated for a bid (equal to `escrow`),
    // NOT the Base remaining capacity (which is genuinely 3, still
    // resting/fillable -- see the header comment above).
    assert!(remaining == 0, 5);

    // Matches the same read via `resting_order_escrow_by_ticket`.
    let escrow_opt_via_ticket = book.resting_order_escrow_by_ticket(&bid_ticket);
    assert!(escrow_opt_via_ticket.is_some(), 6);
    let (escrow_2, remaining_2) = escrow_opt_via_ticket.borrow().resting_order_escrow_fields();
    assert!(escrow_2 == 0, 7);
    assert!(remaining_2 == 0, 8);

    // The order is genuinely still live and fillable: one more 1-unit ask
    // fill succeeds and is charged 0 (target(98) = ceil(33*98/100) =
    // ceil(32.34) = 33, already_charged = 33, delta = 0), proving this is
    // NOT the same as `None` (not resting at all) -- and NOT yet fully
    // drained either (maker still has 100 - 98 = 2 remaining after this).
    scenario.next_tx(maker_b());
    let base_extra = coin::mint_for_testing<BTC>(1, scenario.ctx());
    let (lbe, mqe, _) = book.place_market_order_ask(base_extra, 200, 0, u64_max(), scenario.ctx());
    lbe.burn_for_testing();
    assert!(mqe.burn_for_testing() == 0, 10);
    assert!(book.resting_order_escrow(true, 33, order_id).is_some(), 11);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}


// === Follow-ons to the zero-escrow-while-still-resting state above ===
//
// Three scenarios sharing the exact same book/price/size construction as
// `resting_order_escrow_reaches_some_zero_escrow_while_still_resting`
// (`base_decimals = quote_decimals = 0, precision = 2, exponent = 16` =>
// `price_scale = 100`; a fresh size-100 bid at price 33, reserving
// `total_reserved = ceil(33*100/100) = 33`; the escrow hits exactly 0 after
// 97 one-unit taker fills, while 3 units of genuinely resting Base capacity
// remain) but each continuing past that point differently: (1) draining the
// remaining 3 units to full conclusion, (2) cancelling mid-way through that
// zero-escrow state, (3) repeating the same construction with a nonzero
// `maker_fee_bps` set beforehand.

#[test]
fun resting_order_zero_escrow_continues_to_full_drain_conclusion() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 2, 16, 33, &wrapper_uid, scenario.ctx());
    assert!(book.price_scale() == 100, 0);

    scenario.next_tx(maker_a());
    let reserved = book.bid_escrow_amount(33, 100);
    assert!(reserved == 33, 1);
    let bid_ticket = rest_bid(&mut book, 33, 100, 200, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Same 97-fill sequence as the base fixture: escrow hits exactly 0 while
    // 3 units of Base capacity are still genuinely resting.
    scenario.next_tx(maker_b());
    let mut i = 0u64;
    while (i < 97) {
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        let (lb, mq, _) = book.place_market_order_ask(base, 200, 0, u64_max(), scenario.ctx());
        lb.burn_for_testing();
        mq.burn_for_testing();
        i = i + 1;
    };
    let escrow_opt = book.resting_order_escrow(true, 33, order_id);
    let (escrow, remaining) = escrow_opt.borrow().resting_order_escrow_fields();
    assert!(escrow == 0, 2);
    assert!(remaining == 0, 3);

    // Continue draining the remaining 3 genuinely-resting Base units to full
    // conclusion (through `destroy_drained_bid_escrow`/`conclude_order_fee`
    // in `fill_level_bid`), starting from a Quote escrow that was already 0
    // *before* this final stretch of fills -- exercising whether the drain
    // path underflows or double-charges when there's nothing left in escrow
    // to draw from. `already_charged == total_reserved` for every one of
    // these remaining fills, so each one's `quote_cost` is exactly 0.
    while (i < 100) {
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        let (lb, mq, _) = book.place_market_order_ask(base, 200, 0, u64_max(), scenario.ctx());
        lb.burn_for_testing();
        assert!(mq.burn_for_testing() == 0, 4);
        i = i + 1;
    };

    // The order must now be fully gone from the book (fully drained and
    // removed at the 100th fill).
    assert!(book.resting_order_escrow(true, 33, order_id).is_none(), 5);

    // Claiming must return the ticket's full `original_size = 100` worth of
    // Base proceeds (no fee, so no shortfall), 0 Quote (all consumed as
    // escrow across the 97 charged fills), and no ticket back (order fully
    // concluded).
    scenario.next_tx(maker_a());
    let (base_coin, quote_coin, ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    assert!(ticket_opt.is_none(), 6);
    ticket_opt.destroy_none();
    assert!(base_coin.burn_for_testing() == 100, 7);
    assert!(quote_coin.burn_for_testing() == 0, 8);

    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
fun resting_order_zero_escrow_cancel_returns_pooled_base_proceeds() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 2, 16, 33, &wrapper_uid, scenario.ctx());
    assert!(book.price_scale() == 100, 0);

    scenario.next_tx(maker_a());
    let reserved = book.bid_escrow_amount(33, 100);
    assert!(reserved == 33, 1);
    let bid_ticket = rest_bid(&mut book, 33, 100, 200, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    scenario.next_tx(maker_b());
    let mut i = 0u64;
    while (i < 97) {
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        let (lb, mq, _) = book.place_market_order_ask(base, 200, 0, u64_max(), scenario.ctx());
        lb.burn_for_testing();
        mq.burn_for_testing();
        i = i + 1;
    };
    let escrow_opt = book.resting_order_escrow(true, 33, order_id);
    let (escrow, remaining) = escrow_opt.borrow().resting_order_escrow_fields();
    assert!(escrow == 0, 2);
    assert!(remaining == 0, 3);

    // Cancel while still zero-escrow-but-resting: the ticket's own Quote
    // escrow is genuinely empty (0 additional Quote), but the 97 units of
    // Base proceeds already pooled in the maker-proceeds table by the prior
    // 97 fills (1 unit credited per fill, no fee) must still be returned in
    // full.
    scenario.next_tx(maker_a());
    let (base_coin, quote_coin) = book.cancel_order(bid_ticket, scenario.ctx());
    assert!(base_coin.burn_for_testing() == 97, 4);
    assert!(quote_coin.burn_for_testing() == 0, 5);

    assert!(book.resting_order_escrow(true, 33, order_id).is_none(), 6);

    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}

#[test]
fun resting_order_zero_escrow_with_nonzero_maker_fee_settles_correctly() {
    let mut scenario = ts::begin(admin());
    let wrapper_uid = object::new(scenario.ctx());
    let (mut book, cap) = tiny_clob::new<BTC, USDC>(1, 0, 0, 2, 16, 33, &wrapper_uid, scenario.ctx());
    assert!(book.price_scale() == 100, 0);

    // Nonzero maker fee (the max allowed rate), set on the book BEFORE the
    // bid rests -- the base fixture test uses `maker_fee_bps == 0` to
    // isolate the Quote-escrow mechanic; this repeats the exact same
    // construction with the Base-side maker-fee reserve/settlement
    // machinery (`fee_reserve_base`/`conclude_order_fee`) also live.
    let nonzero_maker_fee_bps: u64 = 5; // == MAX_MAKER_FEE_BPS in sources/tiny_clob.move
    scenario.next_tx(admin());
    cap.clob_admin_set_maker_fee(&mut book, nonzero_maker_fee_bps);

    scenario.next_tx(maker_a());
    let reserved = book.bid_escrow_amount(33, 100);
    assert!(reserved == 33, 1);
    let bid_ticket = rest_bid(&mut book, 33, 100, 200, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // Each 1-unit fill's own dust fee independently ceiling-rounds up to 1
    // (`fee_amount(1, 5) = ceil(5/10_000) = 1`), so the maker's
    // `fee_reserve_base` grows by 1 per fill and each fill's own credited
    // Base proceeds are 0 (the whole 1-unit fill is absorbed by its own
    // dust fee) -- this is exactly the superadditive over-collection
    // `conclude_order_fee` exists to true up.
    scenario.next_tx(maker_b());
    let mut i = 0u64;
    while (i < 97) {
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        let (lb, mq, _) = book.place_market_order_ask(base, 200, 0, u64_max(), scenario.ctx());
        lb.burn_for_testing();
        mq.burn_for_testing();
        i = i + 1;
    };
    let escrow_opt = book.resting_order_escrow(true, 33, order_id);
    let (escrow, remaining) = escrow_opt.borrow().resting_order_escrow_fields();
    assert!(escrow == 0, 2);
    assert!(remaining == 0, 3);

    // Continue to full conclusion (same rationale as the fill-drain
    // follow-on above, now with the fee reserve also live).
    while (i < 100) {
        let base = coin::mint_for_testing<BTC>(1, scenario.ctx());
        let (lb, mq, _) = book.place_market_order_ask(base, 200, 0, u64_max(), scenario.ctx());
        lb.burn_for_testing();
        assert!(mq.burn_for_testing() == 0, 4);
        i = i + 1;
    };
    assert!(book.resting_order_escrow(true, 33, order_id).is_none(), 5);

    // Hand-computed expected settled fee: the CORRECT aggregate fee over the
    // order's whole fill history is `fee_amount(fee_basis_accumulated =
    // original_size = 100, maker_fee_bps = 5) = ceil(100*5/10_000) =
    // ceil(0.05) = 1` -- collected exactly once, at conclusion, regardless
    // of the 100 separate per-fill dust fees (100 total) independently
    // ceiling-rounding to 1 each; the superadditive slack (100 - 1 = 99) is
    // refunded back into the maker's own proceeds instead of being
    // double-charged.
    let settled = event::events_by_type<MakerFeeSettled>();
    assert!(settled.length() == 1, 6);
    let (_settled_book_id, _settled_enclosing_id, _settled_order_id, _settled_maker, settled_amount) =
        settled[0].maker_fee_settled_fields_for_testing();
    assert!(settled_amount == 1, 7);

    // Total claimed Base proceeds must be exactly `original_size(100) -
    // correct_total_fee(1) = 99`, with 0 Quote and no ticket back.
    scenario.next_tx(maker_a());
    let (base_coin, quote_coin, ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    assert!(ticket_opt.is_none(), 8);
    ticket_opt.destroy_none();
    assert!(base_coin.burn_for_testing() == 99, 9);
    assert!(quote_coin.burn_for_testing() == 0, 10);

    destroy_book_and_cap(book, cap);
    wrapper_uid.delete();
    scenario.end();
}


// === Non-tautological cross-check: literal `escrow_base` Balance value ===
//
// `resting_order_escrow`'s ask-side branch (`sources/tiny_clob.move`) returns
// `order.remaining_size()` for BOTH the "escrow" and "remaining_size" fields
// of its result -- by construction, not by re-reading two independently
// maintained values. So `resting_order_escrow_fields` agreeing with itself on
// the ask side (as asserted in `resting_order_escrow_fresh_bid_and_ask` and
// elsewhere in this file) can never fail regardless of whether the order's
// *actual* `escrow_base: Option<Balance<Base>>` field genuinely tracks
// `remaining_size` -- there is no public/`test_only` accessor that reads
// `escrow_base`'s literal `Balance` value directly.
//
// The genuinely non-tautological check available with the current API
// surface is not an extra assertion the test computes -- it's already baked
// into the Move runtime's own balance primitives, and this test is built to
// let a real divergence surface as an abort rather than a silently-passing
// re-read:
//
//   - Every fill against a resting ask calls `split_escrow_base(fill_qty)`
//     (`Order::split_escrow_base`, `sources/order.move`), which is
//     `o.escrow_base.borrow_mut().split(amount)` -- `sui::balance::split`
//     ABORTS if `amount` exceeds the balance's real, live value. If
//     `escrow_base` had ever silently fallen behind `remaining_size` (held
//     LESS than the getter reports), the very next fill's split would abort
//     the whole test right there -- not produce a comparison this test could
//     get wrong.
//   - The final fill that fully drains the order (`fill_level_bid`) removes
//     it and calls `destroy_drained_ask_escrow`, which does
//     `escrow_base.destroy_some().destroy_zero()` -- `sui::balance::destroy_zero`
//     ABORTS unless the balance's real, live value is EXACTLY zero. If
//     `escrow_base` had instead drifted AHEAD of `remaining_size` (held MORE,
//     leftover Base never spent), `remaining_size` would reach 0 while
//     `escrow_base` was still nonzero, and this call would abort.
//
// So a test that drives several varying-size fills against one resting ask
// down to an exact, fully-draining final fill, and simply completes without
// aborting while ending in `resting_order_escrow(..) == None`, is a real,
// runtime-enforced proof that `escrow_base`'s literal value tracked
// `remaining_size` exactly at every step -- a divergence in EITHER direction
// would have aborted the transaction instead of letting the test finish.
// Layered on top: `ask_base_escrow_at_price`'s ask-side aggregate (`level.total_size`,
// `price_tree.move`) is maintained via `level_remove_order`/
// `level_insert_order_front` at fill time -- a different code path
// (per-price-level bookkeeping across the FIFO queue) than the single
// order's own `remaining_size()` getter that `resting_order_escrow` reads --
// so cross-checking it against the test's own independently-computed
// "original size minus cumulative fills" catches FIFO/level-aggregate bugs
// that a per-order-only check would miss.
#[test]
fun resting_ask_escrow_base_tracks_remaining_size_exactly_across_fills() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario); // price_scale == 1, no rounding to account for.

    scenario.next_tx(maker_a());
    let price = default_price();
    let original_size = 500;
    let ask_ticket = rest_ask(&mut book, price, original_size, 10, scenario.ctx());
    let order_id = ask_ticket.ticket_order_id();

    // Fresh order: both cross-checks agree with the full size.
    let fresh_opt = book.resting_order_escrow(false, price, order_id);
    assert!(fresh_opt.is_some(), 0);
    let (fresh_escrow, fresh_remaining) = fresh_opt.borrow().resting_order_escrow_fields();
    assert!(fresh_escrow == original_size, 1);
    assert!(fresh_remaining == original_size, 2);
    assert!(book.ask_base_escrow_at_price(price) == original_size, 3);

    // Five varying-size fills, none of which drain the order except the
    // last: 80 + 150 + 40 + 130 + 100 == 500 == original_size. `price_scale
    // == 1` means every fill's Quote cost is exactly `price * fill_qty`, no
    // rounding, so an exact-value payment produces an exact-`fill_qty` match
    // every time (taker-limited on the budget, not the resting order, for
    // every fill but the last).
    let fill_sizes = vector[80, 150, 40, 130, 100];
    let mut cumulative: u64 = 0;
    let mut i = 0;
    scenario.next_tx(taker());
    while (i < fill_sizes.length()) {
        let fill_qty = fill_sizes[i];
        let quote_payment_value = price * fill_qty;
        let payment = coin::mint_for_testing<USDC>(quote_payment_value, scenario.ctx());
        let (matched_base, leftover_quote, _) =
            book.place_market_order_bid(payment, 10, 0, u64_max(), u64_max(), scenario.ctx());
        // Confirms this fill matched exactly `fill_qty` Base (0 taker fee on
        // this book) and consumed the whole exact payment -- so `cumulative`
        // below is genuinely this fill's own contribution, not a guess.
        assert!(matched_base.burn_for_testing() == fill_qty, 4);
        assert!(leftover_quote.burn_for_testing() == 0, 5);

        cumulative = cumulative + fill_qty;
        let expected_remaining = original_size - cumulative;
        i = i + 1;

        if (expected_remaining > 0) {
            // Order still resting: both cross-checks must independently
            // agree with the test's own hand-computed expected remainder.
            let opt = book.resting_order_escrow(false, price, order_id);
            assert!(opt.is_some(), 6);
            let (escrow, remaining) = opt.borrow().resting_order_escrow_fields();
            assert!(escrow == expected_remaining, 7);
            assert!(remaining == expected_remaining, 8);
            // Independently-derived aggregate (level.total_size, a different
            // code path than the order's own remaining_size() getter).
            assert!(book.ask_base_escrow_at_price(price) == expected_remaining, 9);
        } else {
            // Last fill fully drained the order: `sui::balance::destroy_zero`
            // inside `destroy_drained_ask_escrow` would already have aborted
            // this transaction had `escrow_base` held anything other than
            // exactly 0 at this point -- reaching here at all is part of the
            // genuine, non-tautological proof (see the header comment
            // above). The order must now be entirely gone from the book.
            assert!(book.resting_order_escrow(false, price, order_id).is_none(), 10);
            assert!(book.ask_base_escrow_at_price(price) == 0, 11);
        };
    };

    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

// === Additional coverage: independently-verified gaps from the design review ===

// === `resting_order_owner` / `resting_order_owner_by_ticket` ===

#[test]
fun resting_order_owner_fresh_bid_and_ask_and_wrong_lookup() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let bid_order_id = bid_ticket.ticket_order_id();

    let owner_opt = book.resting_order_owner(true, default_price(), bid_order_id);
    assert!(owner_opt.is_some(), 0);
    assert!(owner_opt.destroy_some() == maker_a(), 1);

    // Same result via the ticket-based wrapper.
    let owner_opt_via_ticket = book.resting_order_owner_by_ticket(&bid_ticket);
    assert!(owner_opt_via_ticket.is_some(), 2);
    assert!(owner_opt_via_ticket.destroy_some() == maker_a(), 3);

    // Wrong side / wrong price / wrong order_id all read back None, mirroring
    // resting_order_escrow_wrong_lookup_is_none.
    assert!(book.resting_order_owner(false, default_price(), bid_order_id).is_none(), 4);
    assert!(book.resting_order_owner(true, default_price() + 1, bid_order_id).is_none(), 5);
    assert!(book.resting_order_owner(true, default_price(), bid_order_id + 1).is_none(), 6);

    scenario.next_tx(maker_b());
    let ask_price = default_price() + 1; // above best bid, so it just rests.
    let ask_ticket = rest_ask(&mut book, ask_price, default_size(), 10, scenario.ctx());
    let ask_order_id = ask_ticket.ticket_order_id();

    let ask_owner_opt = book.resting_order_owner(false, ask_price, ask_order_id);
    assert!(ask_owner_opt.is_some(), 7);
    assert!(ask_owner_opt.destroy_some() == maker_b(), 8);

    unit_test::destroy(bid_ticket);
    unit_test::destroy(ask_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun resting_order_owner_none_after_full_fill_and_cancel() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size = 200;
    let bid_ticket = rest_bid(&mut book, default_price(), size, 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    assert!(book.resting_order_owner(true, default_price(), order_id).is_some(), 0);

    // Full fill: the order is completely drained and removed, so the owner
    // query must also return None (same lifecycle as resting_order_escrow).
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(size, scenario.ctx());
    let (leftover, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 1_000_000_000, 0, size, scenario.ctx());
    leftover.burn_for_testing();
    matched_quote.burn_for_testing();
    assert!(book.resting_order_owner(true, default_price(), order_id).is_none(), 1);

    // Cancel path: rest a fresh order, then cancel it -- must also read back
    // as None.
    scenario.next_tx(maker_b());
    let bid_ticket_2 = rest_bid(&mut book, default_price(), size, 10, scenario.ctx());
    let order_id_2 = bid_ticket_2.ticket_order_id();
    assert!(book.resting_order_owner(true, default_price(), order_id_2).is_some(), 2);
    let (cb, cq) = book.cancel_order(bid_ticket_2, scenario.ctx());
    cb.burn_for_testing();
    cq.burn_for_testing();
    assert!(book.resting_order_owner(true, default_price(), order_id_2).is_none(), 3);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
fun resting_order_owner_reflects_update_resting_order_reassignment() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let mut bid_ticket = rest_bid(&mut book, default_price(), default_size(), 10, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();
    assert!(book.resting_order_owner(true, default_price(), order_id).destroy_some() == maker_a(), 0);

    let found = book.update_resting_order(&mut bid_ticket, other());
    assert!(found, 1);

    // The recorded owner must now reflect the NEW owner, not the placement-
    // time one -- via both the raw lookup and the ticket-based wrapper.
    assert!(book.resting_order_owner(true, default_price(), order_id).destroy_some() == other(), 2);
    assert!(book.resting_order_owner_by_ticket(&bid_ticket).destroy_some() == other(), 3);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // EWrongBook
fun resting_order_owner_by_ticket_wrong_book_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);
    let (other_book, other_cap) = new_book(&mut scenario);

    let other_book_id = other_book.book_id();
    let foreign_ticket = tiny_clob::new_ticket_for_testing(0, other_book_id, tiny_clob::bid(), default_price());
    let _ = book.resting_order_owner_by_ticket(&foreign_ticket);

    unit_test::destroy(foreign_ticket);
    destroy_book_and_cap(book, cap);
    destroy_book_and_cap(other_book, other_cap);
    scenario.end();
}

// === `proceeds_owner` / `proceeds_owner_by_ticket` ===

#[test]
fun proceeds_owner_none_before_credit_some_after_and_synced_by_update_resting_order() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = new_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size = 200;
    let fill_size = 100;
    let mut bid_ticket = rest_bid(&mut book, default_price(), size, 1_000_000_000, scenario.ctx());
    let order_id = bid_ticket.ticket_order_id();

    // No pooled proceeds entry yet: both the raw lookup and the ticket-based
    // wrapper read back None.
    assert!(book.proceeds_owner(order_id).is_none(), 0);
    assert!(book.proceeds_owner_by_ticket(&bid_ticket).is_none(), 1);

    // Partially fill: creates a pooled MakerBalance entry credited to the
    // order's live owner, maker_a().
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(fill_size, scenario.ctx());
    let (leftover, matched_quote, _) =
        book.place_market_order_ask(ask_payment, 1_000_000_000, 0, fill_size, scenario.ctx());
    leftover.burn_for_testing();
    matched_quote.burn_for_testing();

    assert!(book.proceeds_owner(order_id).destroy_some() == maker_a(), 2);
    assert!(book.proceeds_owner_by_ticket(&bid_ticket).destroy_some() == maker_a(), 3);

    // Reassign ownership via update_resting_order -- this must immediately
    // resync the already-pooled proceeds entry's recorded owner, which is
    // exactly the scenario resting_order_owner/proceeds_owner exist to let
    // an integrator verify ahead of relying on push_proceeds/drain_proceeds.
    let found = book.update_resting_order(&mut bid_ticket, other());
    assert!(found, 4);
    assert!(book.proceeds_owner(order_id).destroy_some() == other(), 5);
    assert!(book.proceeds_owner_by_ticket(&bid_ticket).destroy_some() == other(), 6);

    // Consuming the pooled entry via `claim_proceeds` must clear it back to
    // `None` -- the order still has a resting remainder (100 of 200), so the
    // ticket comes back for future claims/cancellation, but the entry itself
    // is gone until a later fill re-credits it.
    let (claimed_base, claimed_quote, ticket_opt) = book.claim_proceeds(bid_ticket, scenario.ctx());
    assert!(claimed_base.burn_for_testing() == fill_size, 7);
    assert!(claimed_quote.burn_for_testing() == 0, 8);
    let bid_ticket = ticket_opt.destroy_some();
    assert!(book.proceeds_owner(order_id).is_none(), 9);
    assert!(book.proceeds_owner_by_ticket(&bid_ticket).is_none(), 10);

    unit_test::destroy(bid_ticket);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16, location = tiny_clob)] // EWrongBook
fun proceeds_owner_by_ticket_wrong_book_aborts() {
    let mut scenario = ts::begin(admin());
    let (book, cap) = new_book(&mut scenario);
    let (other_book, other_cap) = new_book(&mut scenario);

    let other_book_id = other_book.book_id();
    let foreign_ticket = tiny_clob::new_ticket_for_testing(0, other_book_id, tiny_clob::bid(), default_price());
    let _ = book.proceeds_owner_by_ticket(&foreign_ticket);

    unit_test::destroy(foreign_ticket);
    destroy_book_and_cap(book, cap);
    destroy_book_and_cap(other_book, other_cap);
    scenario.end();
}

#[test]
fun bid_quote_escrow_at_price_sums_two_orders_one_partially_filled() {
    let mut scenario = ts::begin(admin());
    let (mut book, cap) = shortfall_book(&mut scenario);

    scenario.next_tx(maker_a());
    let size_a = 500;
    let ticket_a = rest_bid(&mut book, shortfall_price(), size_a, 10, scenario.ctx());

    scenario.next_tx(maker_b());
    let size_b = 300;
    let ticket_b = rest_bid(&mut book, shortfall_price(), size_b, 10, scenario.ctx());

    // Partially cross the FRONT order (A, by FIFO) only.
    scenario.next_tx(taker());
    let ask_payment = coin::mint_for_testing<BTC>(137, scenario.ctx());
    // Pure crossing fill (never rests): `place_market_order_ask` needs no
    // price/expected-output derivation.
    let (leftover_b, matched_q, _) =
        book.place_market_order_ask(ask_payment, 10, 0, u64_max(), scenario.ctx());
    assert!(leftover_b.burn_for_testing() == 0, 0);
    matched_q.burn_for_testing();

    // The maintained aggregate must equal the exact sum of each order's own
    // live escrow, even with one of the two orders now partially drained.
    let escrow_a = book.resting_order_escrow(
        tiny_clob::bid(), shortfall_price(), ticket_a.ticket_order_id(),
    );
    let escrow_b = book.resting_order_escrow(
        tiny_clob::bid(), shortfall_price(), ticket_b.ticket_order_id(),
    );
    let (escrow_a_val, _) = escrow_a.borrow().resting_order_escrow_fields();
    let (escrow_b_val, _) = escrow_b.borrow().resting_order_escrow_fields();
    assert!(escrow_a_val < book.bid_escrow_amount(shortfall_price(), size_a), 2); // A genuinely drained some
    assert!(
        book.bid_quote_escrow_at_price(shortfall_price()) == escrow_a_val + escrow_b_val,
        3,
    );

    unit_test::destroy(escrow_a);
    unit_test::destroy(escrow_b);
    unit_test::destroy(ticket_a);
    unit_test::destroy(ticket_b);
    destroy_book_and_cap(book, cap);
    scenario.end();
}

/// Tests for `price_tree`.
///
/// `MockLevel` stands in for a real order-book price level (a FIFO queue of
/// resting orders); `price_tree` treats it as fully opaque, so a
/// `vector<u64>` of order ids is enough to exercise the tree mechanics
/// without pulling in any order-domain type. Used for tests of the generic
/// `insert`/`remove`/`find`/etc. surface.
///
/// `insert_or_append_order`, in contrast, is `PriceLevel<Base, Quote>`
/// specific (it needs a real `Order` to append), so tests exercising it use
/// real `PriceLevel<BTC, USDC>`/`Order<BTC, USDC>` values instead, built via
/// the `tiny_clob::order`/`tiny_clob::price_tree` `public(package)`
/// constructors (reachable here since this test module lives in the same
/// `tiny_clob` package).
#[test_only]
module tiny_clob::price_tree_tests;

use sui::balance;
use sui::test_scenario as ts;
use tiny_clob::order::{Self, Order};
use tiny_clob::price_tree::{Self, PriceTree, PriceLevel};
use tiny_clob::test_markers::{BTC, USDC};

public struct MockLevel has store, drop {
    orders: vector<u64>,
}

fun mock(order_id: u64): MockLevel {
    MockLevel { orders: vector[order_id] }
}

const ADMIN: address = @0xA11CE;

// === PriceLevel/Order test helpers (for `insert_or_append_order`) ===

/// A minimal, fully self-contained resting order (no escrow) — the escrow
/// legs are irrelevant to `price_tree`'s bookkeeping, so both are `none`.
fun mock_order(order_id: u64): Order<BTC, USDC> {
    order::new<BTC, USDC>(order_id, ADMIN, 1, option::none(), option::none(), 0)
}

fun setup_levels(): (ts::Scenario, PriceTree<PriceLevel<BTC, USDC>>) {
    let mut scenario = ts::begin(ADMIN);
    let tree = price_tree::new<PriceLevel<BTC, USDC>>(scenario.ctx());
    (scenario, tree)
}

fun teardown_levels(scenario: ts::Scenario, tree: PriceTree<PriceLevel<BTC, USDC>>) {
    price_tree::destroy_empty(tree);
    scenario.end();
}

/// Fully destroys a `PriceLevel` popped off the tree via `remove`: drains
/// every order (destroying its empty escrow legs) then destroys the empty
/// level itself.
fun destroy_level(mut level: PriceLevel<BTC, USDC>) {
    while (!price_tree::level_is_empty(&level)) {
        let (_id, order) = price_tree::level_pop_front_order(&mut level);
        let (escrow_base, escrow_quote, fee_reserve_base, fee_reserve_quote) = order::destroy(order);
        escrow_base.destroy_none();
        escrow_quote.destroy_none();
        // `mock_order` constructs orders with both escrow legs `none()`, so
        // `order::new` treats them as ask-side (`fee_reserve_quote` — see
        // its doc comment); `fee_reserve_base` is therefore always `none()`
        // and `fee_reserve_quote` is always a zero-valued `Some`.
        fee_reserve_base.destroy_none();
        balance::destroy_zero(fee_reserve_quote.destroy_some());
    };
    price_tree::destroy_empty_price_level(level);
}

/// Removes and fully destroys every leaf in `keys` — the `PriceLevel`
/// analogue of `cleanup` below.
fun cleanup_levels(tree: &mut PriceTree<PriceLevel<BTC, USDC>>, keys: vector<u64>) {
    let mut i = 0;
    while (i < keys.length()) {
        let ptr = price_tree::find(tree, keys[i]).destroy_some();
        let level = price_tree::remove(tree, ptr);
        destroy_level(level);
        i = i + 1;
    };
}

/// Inserts one fresh order (order_id = its position in `keys`) at each price
/// in `keys` via `insert_or_append_order` — the find-or-insert entry point
/// used by `insert_resting_order`.
fun insert_via_find_or_append(
    tree: &mut PriceTree<PriceLevel<BTC, USDC>>,
    keys: &vector<u64>,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    while (i < keys.length()) {
        let order = mock_order(i);
        price_tree::insert_or_append_order(tree, keys[i], i, order, ctx);
        i = i + 1;
    };
}

/// Inserts a brand-new price level directly via plain `insert` (bypassing
/// `insert_or_append_order`'s find-or-insert logic) — used to mix insertion
/// entry points on the same `PriceLevel`-typed tree, mirroring what
/// `insert_or_append_order` itself does on its empty-tree/not-found paths.
fun insert_plain_level(
    tree: &mut PriceTree<PriceLevel<BTC, USDC>>,
    key: u64,
    order_id: u64,
    ctx: &mut TxContext,
) {
    let mut level = price_tree::new_price_level<BTC, USDC>(ctx);
    price_tree::level_insert_order(&mut level, order_id, mock_order(order_id));
    price_tree::insert(tree, key, level);
}

/// Drains the whole `PriceLevel` tree via repeated `min_leaf` + `remove`,
/// fully destroying each popped level, and returns the keys in the order
/// the tree yielded them.
fun drain_ascending_levels(tree: &mut PriceTree<PriceLevel<BTC, USDC>>): vector<u64> {
    let mut out: vector<u64> = vector[];
    loop {
        let m = price_tree::min_leaf(tree);
        if (m.is_none()) { m.destroy_none(); break };
        let ptr = m.destroy_some();
        out.push_back(price_tree::key(tree, ptr));
        let level = price_tree::remove(tree, ptr);
        destroy_level(level);
    };
    out
}

// === insert_single_key_becomes_root_min_max ===

#[test]
fun insert_single_key_becomes_root_min_max() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 42_000_000, mock(1));

    let min_ptr = price_tree::min_leaf(&tree).destroy_some();
    let max_ptr = price_tree::max_leaf(&tree).destroy_some();
    let found_ptr = price_tree::find(&tree, 42_000_000).destroy_some();
    assert!(min_ptr == max_ptr, 0);
    assert!(min_ptr == found_ptr, 1);
    assert!(price_tree::size(&tree) == 1, 2);

    let _v = price_tree::remove(&mut tree, found_ptr);
    teardown(scenario, tree);
}

// === insert_ascending_keys_updates_max_leaf_incrementally ===

/// Verifies `max_leaf`'s *correctness* after each insert (the returned
/// pointer is the right one). This does not verify that the update is O(1)
/// without re-descending — Move's test harness has no way to count `Table`
/// reads or measure gas from inside a unit test, so that cost property can
/// only be confirmed by reading `insert`'s implementation.
#[test]
fun insert_ascending_keys_updates_max_leaf_incrementally() {
    let (mut scenario, mut tree) = setup();

    // Ascending resting-bid-style prices (6-decimal USDC-style raw units).
    let prices = vector[1_000_000u64, 1_500_000, 2_000_000, 2_750_000, 3_100_000];
    let mut i = 0;
    let mut last_max_ptr = option::none<u64>();
    while (i < prices.length()) {
        let price = prices[i];
        price_tree::insert(&mut tree, price, mock(i));
        let max_ptr = price_tree::max_leaf(&tree).destroy_some();
        // Each insert's new key is a fresh max: max_leaf must move to it,
        // read directly as a tracked field (not re-derived by descent).
        assert!(price_tree::find(&tree, price).destroy_some() == max_ptr, i);
        last_max_ptr = option::some(max_ptr);
        i = i + 1;
    };
    assert!(last_max_ptr.destroy_some() == price_tree::max_leaf(&tree).destroy_some(), 100);

    // Min never moved off the first-inserted (lowest) key.
    let expected_min = price_tree::find(&tree, 1_000_000).destroy_some();
    assert!(price_tree::min_leaf(&tree).destroy_some() == expected_min, 101);

    cleanup(&mut tree, prices);
    teardown(scenario, tree);
}

// === insert_descending_keys_updates_min_leaf_incrementally ===

/// Symmetric to `insert_ascending_keys_updates_max_leaf_incrementally`
/// above, for `min_leaf`.
#[test]
fun insert_descending_keys_updates_min_leaf_incrementally() {
    let (mut scenario, mut tree) = setup();

    let prices = vector[9_000_000u64, 8_400_000, 7_950_000, 7_000_000, 6_100_000];
    let mut i = 0;
    while (i < prices.length()) {
        let price = prices[i];
        price_tree::insert(&mut tree, price, mock(i));
        let min_ptr = price_tree::min_leaf(&tree).destroy_some();
        assert!(price_tree::find(&tree, price).destroy_some() == min_ptr, i);
        i = i + 1;
    };

    let expected_max = price_tree::find(&tree, 9_000_000).destroy_some();
    assert!(price_tree::max_leaf(&tree).destroy_some() == expected_max, 100);

    cleanup(&mut tree, prices);
    teardown(scenario, tree);
}

// === insert_middle_key_leaves_min_max_unchanged ===

/// Exercises the FALSE branch of both min/max update guards in `insert`: a
/// low key then a high key establish min and max, and a subsequent MIDDLE
/// key is neither a new min nor a new max. All other insert tests in this
/// file are monotonic (strictly ascending or descending), so this is the
/// only test that inserts a key strictly between the current min and max.
#[test]
fun insert_middle_key_leaves_min_max_unchanged() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1)); // low -> min
    price_tree::insert(&mut tree, 8_800_000, mock(2)); // high -> max

    let min_before = price_tree::min_leaf(&tree).destroy_some();
    let max_before = price_tree::max_leaf(&tree).destroy_some();

    price_tree::insert(&mut tree, 6_250_000, mock(3)); // middle -> neither

    assert!(price_tree::min_leaf(&tree).destroy_some() == min_before, 0);
    assert!(price_tree::max_leaf(&tree).destroy_some() == max_before, 1);
    assert!(price_tree::size(&tree) == 3, 2);

    cleanup(&mut tree, vector[5_000_000, 6_250_000, 8_800_000]);
    teardown(scenario, tree);
}

// === remove_non_extreme_leaf_leaves_min_max_unchanged ===

#[test]
fun remove_non_extreme_leaf_leaves_min_max_unchanged() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1)); // min
    price_tree::insert(&mut tree, 6_250_000, mock(2)); // middle
    price_tree::insert(&mut tree, 8_800_000, mock(3)); // max

    let min_before = price_tree::min_leaf(&tree).destroy_some();
    let max_before = price_tree::max_leaf(&tree).destroy_some();

    let middle_ptr = price_tree::find(&tree, 6_250_000).destroy_some();
    let _v = price_tree::remove(&mut tree, middle_ptr);

    assert!(price_tree::min_leaf(&tree).destroy_some() == min_before, 0);
    assert!(price_tree::max_leaf(&tree).destroy_some() == max_before, 1);
    assert!(price_tree::size(&tree) == 2, 2);
    assert!(price_tree::find(&tree, 6_250_000).is_none(), 3);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

// === remove_min_leaf_recomputes_new_min ===

#[test]
fun remove_min_leaf_recomputes_new_min() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1)); // min
    price_tree::insert(&mut tree, 6_250_000, mock(2)); // new min after removal
    price_tree::insert(&mut tree, 8_800_000, mock(3)); // max

    let old_min_ptr = price_tree::find(&tree, 5_000_000).destroy_some();
    let _v = price_tree::remove(&mut tree, old_min_ptr);

    let expected_new_min = price_tree::find(&tree, 6_250_000).destroy_some();
    assert!(price_tree::min_leaf(&tree).destroy_some() == expected_new_min, 0);

    cleanup(&mut tree, vector[6_250_000, 8_800_000]);
    teardown(scenario, tree);
}

// === remove_max_leaf_recomputes_new_max ===

#[test]
fun remove_max_leaf_recomputes_new_max() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1)); // min
    price_tree::insert(&mut tree, 6_250_000, mock(2)); // new max after removal
    price_tree::insert(&mut tree, 8_800_000, mock(3)); // max

    let old_max_ptr = price_tree::find(&tree, 8_800_000).destroy_some();
    let _v = price_tree::remove(&mut tree, old_max_ptr);

    let expected_new_max = price_tree::find(&tree, 6_250_000).destroy_some();
    assert!(price_tree::max_leaf(&tree).destroy_some() == expected_new_max, 0);

    cleanup(&mut tree, vector[5_000_000, 6_250_000]);
    teardown(scenario, tree);
}

// === remove_last_leaf_empties_tree ===

#[test]
fun remove_last_leaf_empties_tree() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 12_500_000, mock(1));
    let ptr = price_tree::find(&tree, 12_500_000).destroy_some();
    let _v = price_tree::remove(&mut tree, ptr);

    assert!(price_tree::min_leaf(&tree).is_none(), 0);
    assert!(price_tree::max_leaf(&tree).is_none(), 1);
    assert!(price_tree::size(&tree) == 0, 2);
    assert!(price_tree::find(&tree, 12_500_000).is_none(), 3);

    teardown(scenario, tree);
}

// === find_missing_key_returns_none / find_present_key_returns_some_pointer ===

#[test]
fun find_missing_key_returns_none() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 3_300_000, mock(1));
    assert!(price_tree::find(&tree, 9_900_000).is_none(), 0);

    cleanup(&mut tree, vector[3_300_000]);
    teardown(scenario, tree);
}

#[test]
fun find_present_key_returns_some_pointer() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 3_300_000, mock(1));
    assert!(price_tree::find(&tree, 3_300_000).is_some(), 0);

    cleanup(&mut tree, vector[3_300_000]);
    teardown(scenario, tree);
}

// === insert_many_distinct_prices_grows_tree_depth ===

#[test]
fun insert_many_distinct_prices_grows_tree_depth() {
    let (mut scenario, mut tree) = setup();

    // 12 distinct adjacent prices, realistic 6-decimal magnitude.
    let base = 4_000_000u64;
    let mut i = 0;
    while (i < 12) {
        price_tree::insert(&mut tree, base + i, mock(i));
        i = i + 1;
    };
    assert!(price_tree::size(&tree) == 12, 0);

    i = 0;
    while (i < 12) {
        assert!(price_tree::find(&tree, base + i).is_some(), 1);
        i = i + 1;
    };

    // Remove a subset (every other price); confirm only those disappear.
    i = 0;
    while (i < 12) {
        if (i % 2 == 0) {
            let ptr = price_tree::find(&tree, base + i).destroy_some();
            let _v = price_tree::remove(&mut tree, ptr);
        };
        i = i + 1;
    };
    assert!(price_tree::size(&tree) == 6, 2);
    i = 0;
    while (i < 12) {
        let present = price_tree::find(&tree, base + i).is_some();
        assert!(present == (i % 2 == 1), 3);
        i = i + 1;
    };

    // Remove the remaining odd-indexed leaves to empty the tree.
    i = 1;
    while (i < 12) {
        let ptr = price_tree::find(&tree, base + i).destroy_some();
        let _v = price_tree::remove(&mut tree, ptr);
        i = i + 2;
    };
    assert!(price_tree::size(&tree) == 0, 4);

    teardown(scenario, tree);
}

// === insert_same_price_repeatedly_leaves_tree_depth_unchanged ===

#[test]
fun insert_same_price_repeatedly_leaves_tree_depth_unchanged() {
    let (mut scenario, mut tree) = setup();

    // First order at this price creates the leaf.
    price_tree::insert(&mut tree, 7_500_000, mock(1));
    assert!(price_tree::size(&tree) == 1, 0);

    // Additional orders at the same already-present price never call
    // `insert` again — they mutate the existing leaf's FIFO queue in place
    // via `borrow_mut`.
    let ptr = price_tree::find(&tree, 7_500_000).destroy_some();
    let mut n = 2;
    while (n <= 5) {
        price_tree::borrow_mut(&mut tree, ptr).orders.push_back(n);
        n = n + 1;
    };

    // No new InternalNode/Leaf was created beyond the first.
    assert!(price_tree::size(&tree) == 1, 1);
    assert!(price_tree::borrow(&tree, ptr).orders.length() == 5, 2);

    cleanup(&mut tree, vector[7_500_000]);
    teardown(scenario, tree);
}

// === no_tick_divisibility_check ===

#[test]
fun no_tick_divisibility_check() {
    let (mut scenario, mut tree) = setup();

    // 7 and 13 share no common divisor beyond 1 — no tick-size/divisibility
    // check exists anywhere in price_tree, so both inserts succeed with no
    // abort.
    price_tree::insert(&mut tree, 7, mock(1));
    price_tree::insert(&mut tree, 13, mock(2));
    assert!(price_tree::find(&tree, 7).is_some(), 0);
    assert!(price_tree::find(&tree, 13).is_some(), 1);

    cleanup(&mut tree, vector[7, 13]);
    teardown(scenario, tree);
}

// === Duplicate-key insert aborts ===

#[test]
#[expected_failure(abort_code = price_tree::EKeyAlreadyExists)]
fun insert_duplicate_key_aborts() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 2_000_000, mock(1));
    price_tree::insert(&mut tree, 2_000_000, mock(2));

    cleanup(&mut tree, vector[2_000_000]);
    teardown(scenario, tree);
}

// === Invalid leaf pointer aborts (M-1) ===

/// Builds a 2-leaf tree (so exactly one internal node exists), then passes
/// that internal node's raw numeric index — which is `< PARTITION_INDEX`,
/// i.e. not a leaf pointer at all — to `borrow`. Must abort with
/// `EInvalidLeafPtr`, not `sui::table`'s generic missing-key abort.
#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1));
    price_tree::insert(&mut tree, 8_800_000, mock(2));

    // The tree now has exactly one internal node, allocated at index 0
    // (internal-node indices are allocated bottom-up from 0). Index 0 is
    // `< PARTITION_INDEX`, so it is not a leaf pointer.
    let bad_ptr: u64 = 0;
    let _v = price_tree::borrow(&tree, bad_ptr);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun remove_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1));
    price_tree::insert(&mut tree, 8_800_000, mock(2));

    let bad_ptr: u64 = 0;
    let _v = price_tree::remove(&mut tree, bad_ptr);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun key_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1));
    price_tree::insert(&mut tree, 8_800_000, mock(2));

    let bad_ptr: u64 = 0;
    let _k = price_tree::key(&tree, bad_ptr);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_mut_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();

    price_tree::insert(&mut tree, 5_000_000, mock(1));
    price_tree::insert(&mut tree, 8_800_000, mock(2));

    let bad_ptr: u64 = 0;
    let _v = price_tree::borrow_mut(&mut tree, bad_ptr);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

// === insert_order_independence_same_key_set ===

/// Crit-bit trees are query-behavior-independent of insertion order, even
/// though internal node layout may differ. Inserts the same key set in
/// several different orders and confirms `size`, `min_leaf`/`max_leaf`
/// keys, and every key's `find`-ability come out identical regardless of
/// order — added as extra confidence for Fix 1's single-descent replay
/// (any subtle bug in the in-memory path replay would be very likely to
/// perturb the resulting tree shape/queries for at least one of these
/// permutations).
#[test]
fun insert_order_independence_same_key_set() {
    let keys = vector[
        5_000_000u64, 1_250_000, 9_900_000, 3_300_000, 7_000_000,
        2_000_000, 8_800_000, 4_100_000, 6_600_000, 1_000_000,
    ];

    let orders = vector[
        vector[0u64, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        vector[9u64, 8, 7, 6, 5, 4, 3, 2, 1, 0],
        vector[3u64, 0, 7, 1, 9, 2, 8, 4, 6, 5],
        vector[5u64, 4, 6, 3, 7, 2, 8, 1, 9, 0],
    ];

    let mut o = 0;
    while (o < orders.length()) {
        let order = orders[o];
        let (mut scenario, mut tree) = setup();

        let mut i = 0;
        while (i < order.length()) {
            let idx = order[i];
            price_tree::insert(&mut tree, keys[idx], mock(idx));
            i = i + 1;
        };

        assert!(price_tree::size(&tree) == keys.length(), o);

        // Every key is findable regardless of insertion order.
        i = 0;
        while (i < keys.length()) {
            assert!(price_tree::find(&tree, keys[i]).is_some(), o);
            i = i + 1;
        };

        // min/max are the same actual keys regardless of insertion order.
        let min_ptr = price_tree::min_leaf(&tree).destroy_some();
        let max_ptr = price_tree::max_leaf(&tree).destroy_some();
        assert!(price_tree::key(&tree, min_ptr) == 1_000_000, o);
        assert!(price_tree::key(&tree, max_ptr) == 9_900_000, o);

        cleanup(&mut tree, keys);
        teardown(scenario, tree);
        o = o + 1;
    };
}

// === insert_or_append_order_not_found_lands_correctly ===

/// Exercises the not-found path of `insert_or_append_order` — the atomic
/// find-or-insert operation that replaced the old `descend_probe` +
/// `insert_at` two-call pattern used by `insert_resting_order`: builds a
/// multi-level tree, then calls `insert_or_append_order` for an absent
/// price, and confirms the new key is findable afterward, the existing
/// levels are untouched, and the tree's invariants (size, min/max) hold.
#[test]
fun insert_or_append_order_not_found_lands_correctly() {
    let (mut scenario, mut tree) = setup_levels();
    let ctx = scenario.ctx();

    let existing = vector[2_000_000u64, 5_000_000, 9_000_000, 4_100_000, 6_600_000];
    insert_via_find_or_append(&mut tree, &existing, ctx);

    let new_key = 3_300_000u64;
    price_tree::insert_or_append_order(&mut tree, new_key, 100, mock_order(100), ctx);

    assert!(price_tree::size(&tree) == existing.length() + 1, 0);
    let new_ptr = price_tree::find(&tree, new_key).destroy_some();
    assert!(price_tree::level_contains_order(price_tree::borrow(&tree, new_ptr), 100), 1);

    // Existing keys remain findable, and min/max are unaffected (new_key is
    // strictly between the existing min and max).
    let mut i = 0;
    while (i < existing.length()) {
        assert!(price_tree::find(&tree, existing[i]).is_some(), 2);
        i = i + 1;
    };
    let min_ptr = price_tree::min_leaf(&tree).destroy_some();
    let max_ptr = price_tree::max_leaf(&tree).destroy_some();
    assert!(price_tree::key(&tree, min_ptr) == 2_000_000, 3);
    assert!(price_tree::key(&tree, max_ptr) == 9_000_000, 4);

    let mut all_keys = existing;
    all_keys.push_back(new_key);
    cleanup_levels(&mut tree, all_keys);
    teardown_levels(scenario, tree);
}

// === insert_or_append_order_found_appends_without_new_leaf ===

/// Exercises the found path: a second (and third) order at an
/// already-present price must append to the SAME leaf's `PriceLevel`
/// in FIFO order, without creating a new leaf/internal node.
#[test]
fun insert_or_append_order_found_appends_without_new_leaf() {
    let (mut scenario, mut tree) = setup_levels();
    let ctx = scenario.ctx();

    let existing = vector[2_000_000u64, 5_000_000, 9_000_000];
    insert_via_find_or_append(&mut tree, &existing, ctx);
    assert!(price_tree::size(&tree) == 3, 0);

    price_tree::insert_or_append_order(&mut tree, 5_000_000, 200, mock_order(200), ctx);
    price_tree::insert_or_append_order(&mut tree, 5_000_000, 201, mock_order(201), ctx);

    // No new leaf was created for the repeated price.
    assert!(price_tree::size(&tree) == 3, 1);

    let ptr = price_tree::find(&tree, 5_000_000).destroy_some();
    let level = price_tree::borrow(&tree, ptr);
    assert!(price_tree::level_contains_order(level, 1), 2); // original order (order_id=1)
    assert!(price_tree::level_contains_order(level, 200), 3);
    assert!(price_tree::level_contains_order(level, 201), 4);
    // FIFO order preserved: original order stays at the front.
    assert!(price_tree::level_front_order_id(level).destroy_some() == 1, 5);

    cleanup_levels(&mut tree, existing);
    teardown_levels(scenario, tree);
}

// === insert_or_append_order_regression: PoC scenario ===
//
// Motivating PoC for the old `insert_at` hint-provenance gap: a caller could
// (in principle) pass a stale/foreign/mismatched-key hint pointer across the
// `descend_probe`/`insert_at` module boundary, silently corrupting the
// tree. `insert_or_append_order` has no hint parameter at all — the whole
// find-or-insert operation happens within one continuous borrow — so that
// class of bug is structurally impossible now. This is therefore a thorough
// correctness regression test instead: interleave finds-or-creates at
// several distinct prices, some of them landing at different tree depths,
// with repeat inserts at already-present prices, and confirm every price
// level ends up with exactly (and only) the orders it should contain, with
// no duplication and no lost reachability.

#[test]
fun insert_or_append_order_regression_no_duplication_or_corruption() {
    let (mut scenario, mut tree) = setup_levels();
    let ctx = scenario.ctx();

    // Pre-existing prices spanning a range of crit-bit depths.
    let base_prices = vector[1_000_000u64, 2_000_000, 4_000_000, 8_000_000, 16_000_000, 3_000_000, 5_500_000];
    insert_via_find_or_append(&mut tree, &base_prices, ctx);

    // Interleave: repeat-insert at several existing prices (multiple times,
    // in different orders) and find-or-insert brand-new prices at various
    // depths — designed so some new prices land shallow, some deep.
    let mut expected: vector<vector<u64>> = vector[]; // parallel to base_prices ∪ new prices
    let mut all_prices = base_prices;
    // seed expected with the one order (order_id = index) each base price got.
    let mut i = 0;
    while (i < base_prices.length()) {
        expected.push_back(vector[i]);
        i = i + 1;
    };

    let mut next_order_id = base_prices.length();
    let op_prices = vector[
        2_000_000u64, 9_000_000, 4_000_000,
        1_500_000, 1_000_000, 12_000_000,
        8_000_000, 2_000_000, 5_500_000,
        1_500_000, 3_000_000, 12_000_000,
    ];
    let op_is_new = vector[
        false, true, false,
        true, false, true,
        false, false, false,
        false, false, false,
    ];
    let mut j = 0;
    while (j < op_prices.length()) {
        let price = op_prices[j];
        let is_new = op_is_new[j];
        price_tree::insert_or_append_order(&mut tree, price, next_order_id, mock_order(next_order_id), ctx);
        if (is_new) {
            all_prices.push_back(price);
            expected.push_back(vector[next_order_id]);
        } else {
            let (found, idx) = all_prices.index_of(&price);
            assert!(found, 0);
            let e = expected.borrow_mut(idx);
            e.push_back(next_order_id);
        };
        next_order_id = next_order_id + 1;
        j = j + 1;
    };

    assert!(price_tree::size(&tree) == all_prices.length(), 1);
    assert!(all_prices.length() == expected.length(), 5);

    // Every price level contains exactly the expected order ids, in FIFO
    // order, and nothing else.
    let mut k = 0;
    while (k < all_prices.length()) {
        let ptr = price_tree::find(&tree, all_prices[k]).destroy_some();
        let level = price_tree::borrow(&tree, ptr);
        let want = expected.borrow(k);
        let mut m = 0;
        while (m < want.length()) {
            assert!(price_tree::level_contains_order(level, want[m]), 2);
            m = m + 1;
        };
        k = k + 1;
    };

    cleanup_levels(&mut tree, all_prices);
    teardown_levels(scenario, tree);
}

// === order_independence_full_drain_across_orderings_and_entry_points ===

/// LCG-based distinct-key generator (rejects duplicates by linear scan).
fun gen_distinct_keys(n: u64, seed: u64, span: u64): vector<u64> {
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

/// Reorders `keys` per `kind`: `0` = ascending, `1` = descending, anything
/// else = a stride-`kind` shuffle over the original order.
fun reorder_keys(keys: &vector<u64>, kind: u64): vector<u64> {
    let n = keys.length();
    let mut out: vector<u64> = vector[];
    if (kind == 0) {
        let mut sorted = *keys;
        let mut a = 0;
        while (a < n) {
            let mut b = a + 1;
            while (b < n) {
                if (sorted[b] < sorted[a]) { sorted.swap(a, b); };
                b = b + 1;
            };
            a = a + 1;
        };
        out = sorted;
    } else if (kind == 1) {
        let mut sorted = *keys;
        let mut a = 0;
        while (a < n) {
            let mut b = a + 1;
            while (b < n) {
                if (sorted[b] > sorted[a]) { sorted.swap(a, b); };
                b = b + 1;
            };
            a = a + 1;
        };
        out = sorted;
    } else {
        let stride = kind;
        let mut idx = 0;
        let mut count = 0;
        let mut seen: vector<u64> = vector[];
        while (count < n) {
            if (!seen.contains(&idx)) {
                seen.push_back(idx);
                out.push_back(keys[idx]);
                count = count + 1;
            };
            idx = (idx + stride) % n;
            if (seen.contains(&idx) && count < n) {
                let mut j = 0;
                while (j < n && seen.contains(&j)) { j = j + 1; };
                if (j < n) { idx = j; };
            };
        };
    };
    out
}

/// Confirms every key in `keys` is present with the right size, then fully
/// drains the tree ascending via `min_leaf` + `remove`, checking structural
/// integrity (sortedness, size, `max_leaf` staying correct) at every step —
/// this exercises parent/child rewiring on every removal, so any structural
/// corruption from insertion tends to surface here.
fun assert_full_ascending_drain(tree: &mut PriceTree<MockLevel>, keys: &vector<u64>) {
    let n = keys.length();
    assert!(price_tree::size(tree) == n, 0);

    let mut i = 0;
    while (i < n) {
        assert!(price_tree::find(tree, keys[i]).is_some(), 1);
        i = i + 1;
    };

    let mut hi = keys[0];
    i = 1;
    while (i < n) {
        if (keys[i] > hi) { hi = keys[i] };
        i = i + 1;
    };

    let mut prev = 0;
    let mut first = true;
    let mut remaining = n;
    while (remaining > 0) {
        let mp = price_tree::min_leaf(tree).destroy_some();
        let k = price_tree::key(tree, mp);
        if (!first) { assert!(k > prev, 2); };
        assert!(keys.contains(&k), 3);
        assert!(price_tree::key(tree, price_tree::max_leaf(tree).destroy_some()) == hi, 4);
        let _v = price_tree::remove(tree, mp);
        prev = k;
        first = false;
        remaining = remaining - 1;
        assert!(price_tree::size(tree) == remaining, 5);
    };
    assert!(price_tree::min_leaf(tree).is_none(), 6);
    assert!(price_tree::max_leaf(tree).is_none(), 7);
}

/// `assert_full_ascending_drain`'s counterpart for the `PriceLevel`-typed
/// tree used by `insert_or_append_order` tests below.
fun assert_full_ascending_drain_levels(tree: &mut PriceTree<PriceLevel<BTC, USDC>>, keys: &vector<u64>) {
    let n = keys.length();
    assert!(price_tree::size(tree) == n, 0);

    let mut i = 0;
    while (i < n) {
        assert!(price_tree::find(tree, keys[i]).is_some(), 1);
        i = i + 1;
    };

    let mut hi = keys[0];
    i = 1;
    while (i < n) {
        if (keys[i] > hi) { hi = keys[i] };
        i = i + 1;
    };

    let mut prev = 0;
    let mut first = true;
    let mut remaining = n;
    while (remaining > 0) {
        let mp = price_tree::min_leaf(tree).destroy_some();
        let k = price_tree::key(tree, mp);
        if (!first) { assert!(k > prev, 2); };
        assert!(keys.contains(&k), 3);
        assert!(price_tree::key(tree, price_tree::max_leaf(tree).destroy_some()) == hi, 4);
        let level = price_tree::remove(tree, mp);
        destroy_level(level);
        prev = k;
        first = false;
        remaining = remaining - 1;
        assert!(price_tree::size(tree) == remaining, 5);
    };
    assert!(price_tree::min_leaf(tree).is_none(), 6);
    assert!(price_tree::max_leaf(tree).is_none(), 7);
}

/// Strengthens `insert_order_independence_same_key_set` above: inserts a
/// 60-key set in 7 different orderings (ascending, descending, and 5 stride
/// shuffles) through plain `insert`, and — since `insert_or_append_order`'s
/// `PriceLevel`/`LinkedTable`-backed values are far more expensive per
/// operation than `MockLevel` (real `Table`+`LinkedTable` bookkeeping, not a
/// plain `vector`), a smaller 20-key subset of the same base set through
/// `insert_or_append_order` (the find-or-insert operation used by
/// `insert_resting_order`) — to stay within the test harness's step budget.
/// Fully drains ascending after each build — checking structural integrity
/// throughout rather than only at the end.
#[test]
fun order_independence_full_drain_across_orderings_and_entry_points() {
    let base = gen_distinct_keys(60, 77777, 5_000_000);
    let mut level_base: vector<u64> = vector[];
    let mut li = 0;
    while (li < 20) {
        level_base.push_back(base[li]);
        li = li + 1;
    };
    let kinds = vector[0u64, 1, 2, 3, 7, 11, 13];
    let mut c = 0;
    while (c < kinds.length()) {
        let order = reorder_keys(&base, kinds[c]);
        assert!(order.length() == base.length(), 8);

        let (scenario, mut tree) = setup();
        let mut i = 0;
        while (i < order.length()) {
            price_tree::insert(&mut tree, order[i], mock(i));
            i = i + 1;
        };
        assert_full_ascending_drain(&mut tree, &base);
        teardown(scenario, tree);

        // Same permutation (restricted to the smaller subset), through
        // `insert_or_append_order`.
        let level_order = reorder_keys(&level_base, kinds[c]);
        let (mut scenario2, mut tree2) = setup_levels();
        insert_via_find_or_append(&mut tree2, &level_order, scenario2.ctx());
        assert_full_ascending_drain_levels(&mut tree2, &level_base);
        teardown_levels(scenario2, tree2);

        c = c + 1;
    };
}

// === Insertion stress and differential tests (plain `insert` vs
// === `insert_or_append_order`) ===
//
// These strengthen `insert_order_independence_same_key_set` and
// `order_independence_full_drain_across_orderings_and_entry_points` above
// with a deterministic pseudo-random (xorshift-style) key generator
// independent of the LCG-based `gen_distinct_keys` used elsewhere, plus a
// direct differential comparison between the two insertion entry points and
// a combined insert/remove churn test.

// === insert_bulk_random_matches_sorted_reference ===

/// Bulk pseudo-random `insert` across several seeds: every key findable,
/// size correct, min/max correct, and a full ascending drain matches an
/// independently computed sorted reference.
#[test]
fun insert_bulk_random_matches_sorted_reference() {
    let mut seed = 1;
    while (seed <= 6) {
        let (scenario, mut tree) = setup();
        let keys = prng_keys(120, seed * 7919);
        let mut i = 0;
        while (i < keys.length()) {
            price_tree::insert(&mut tree, keys[i], mock(keys[i]));
            i = i + 1;
        };
        assert!(price_tree::size(&tree) == keys.length(), 0);

        // Every inserted key must be findable at a leaf carrying that key.
        let mut j = 0;
        while (j < keys.length()) {
            let ptr = price_tree::find(&tree, keys[j]).destroy_some();
            assert!(price_tree::key(&tree, ptr) == keys[j], 1);
            j = j + 1;
        };

        let want = sorted(&keys);
        assert!(price_tree::key(&tree, price_tree::min_leaf(&tree).destroy_some()) == want[0], 2);
        assert!(
            price_tree::key(&tree, price_tree::max_leaf(&tree).destroy_some())
                == want[want.length() - 1],
            3,
        );

        let got = drain_ascending(&mut tree);
        assert!(got == want, 4);
        teardown(scenario, tree);
        seed = seed + 1;
    };
}

// === insert_or_append_order_matches_plain_insert_differential ===

/// Differential test: the same bulk pseudo-random workload driven through
/// `insert_or_append_order` (the find-or-insert operation
/// `insert_resting_order` uses) must produce a tree indistinguishable, by
/// full ascending drain (compared by key sequence — the two trees hold
/// different value types), from one built purely with plain `insert` on the
/// identical key set.
#[test]
fun insert_or_append_order_matches_plain_insert_differential() {
    let mut seed = 1;
    while (seed <= 3) {
        let keys = prng_keys(60, seed * 104729);

        // Reference tree, built with plain `insert`.
        let (scenario1, mut ref_tree) = setup();
        let mut i = 0;
        while (i < keys.length()) {
            price_tree::insert(&mut ref_tree, keys[i], mock(keys[i]));
            i = i + 1;
        };
        let ref_drain = drain_ascending(&mut ref_tree);
        teardown(scenario1, ref_tree);

        // Subject tree, built exactly the way `insert_resting_order` does.
        let (mut scenario2, mut tree) = setup_levels();
        let ctx = scenario2.ctx();
        let mut j = 0;
        while (j < keys.length()) {
            let k = keys[j];
            price_tree::insert_or_append_order(&mut tree, k, j, mock_order(j), ctx);
            j = j + 1;
        };
        assert!(price_tree::size(&tree) == keys.length(), 1);
        let got = drain_ascending_levels(&mut tree);
        assert!(got == ref_drain, 2);
        teardown_levels(scenario2, tree);
        seed = seed + 1;
    };
}

// === mixed_insert_paths_with_removals_stay_consistent ===

/// Interleaves both insertion entry points (plain `insert` and
/// `insert_or_append_order`, both usable on the same `PriceLevel`-typed
/// tree) with periodic removals of the current minimum, tracking an
/// in-memory `live` model alongside the tree and checking size and full
/// sortedness at every step — the combined insert/insert_or_append_order/
/// remove churn that neither of the two tests above exercises in isolation.
#[test]
fun mixed_insert_paths_with_removals_stay_consistent() {
    let (mut scenario, mut tree) = setup_levels();
    let ctx = scenario.ctx();
    let keys = prng_keys(90, 424_242);
    let mut live: vector<u64> = vector[];

    let mut i = 0;
    while (i < keys.length()) {
        let k = keys[i];
        // Alternate between the two insertion entry points.
        if (i % 2 == 0) {
            insert_plain_level(&mut tree, k, i, ctx);
        } else {
            price_tree::insert_or_append_order(&mut tree, k, i, mock_order(i), ctx);
        };
        live.push_back(k);

        // Every third step, remove the current minimum.
        if (i % 3 == 2) {
            let ptr = price_tree::min_leaf(&tree).destroy_some();
            let mk = price_tree::key(&tree, ptr);
            let level = price_tree::remove(&mut tree, ptr);
            destroy_level(level);
            let (found, idx) = live.index_of(&mk);
            assert!(found, 0);
            live.remove(idx);
        };
        assert!(price_tree::size(&tree) == live.length(), 1);
        i = i + 1;
    };

    let got = drain_ascending_levels(&mut tree);
    assert!(got == sorted(&live), 2);
    teardown_levels(scenario, tree);
}

// === NO_PARENT blind-spot guard (Fix 6) ===
//
// `NO_PARENT` numerically equals `PARTITION_INDEX`, so `is_leaf_ptr(NO_PARENT)`
// (`ptr >= PARTITION_INDEX`) incorrectly evaluates to `true`. Before the
// guard was tightened, passing `NO_PARENT` to `remove`/`borrow`/`borrow_mut`/
// `key` would skip the leaf-shape check and fall through to
// `leaf_index_of(NO_PARENT)` — an out-of-range leaf index that only aborted
// via `sui::table`'s generic missing-key error, not a purpose-built one.
// These four tests confirm each function now aborts immediately, with its
// own clear error code, when passed `NO_PARENT` explicitly. (`insert_at` had
// its own such guard test too, but `insert_at` — and its `hint_ptr`
// parameter entirely — was deleted when `insert_or_append_order` replaced
// it; there is no longer a hint parameter to misuse.)

/// Numerically identical to the private `NO_PARENT`/`PARTITION_INDEX`
/// constants in `price_tree.move` (`0x8000000000000000`) — duplicated here
/// since those constants aren't exported.
const NO_PARENT_FOR_TESTING: u64 = 0x8000000000000000;

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun remove_with_no_parent_ptr_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();
    price_tree::insert(&mut tree, 5_000_000, mock(1));
    let _v = price_tree::remove(&mut tree, NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_with_no_parent_ptr_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();
    price_tree::insert(&mut tree, 5_000_000, mock(1));
    let _v = price_tree::borrow(&tree, NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_mut_with_no_parent_ptr_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();
    price_tree::insert(&mut tree, 5_000_000, mock(1));
    let _v = price_tree::borrow_mut(&mut tree, NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun key_with_no_parent_ptr_aborts_invalid_leaf_ptr() {
    let (mut scenario, mut tree) = setup();
    price_tree::insert(&mut tree, 5_000_000, mock(1));
    let _k = price_tree::key(&tree, NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

// === test helpers ===

fun setup(): (ts::Scenario, PriceTree<MockLevel>) {
    let mut scenario = ts::begin(ADMIN);
    let tree = price_tree::new<MockLevel>(scenario.ctx());
    (scenario, tree)
}

fun teardown(scenario: ts::Scenario, tree: PriceTree<MockLevel>) {
    price_tree::destroy_empty(tree);
    scenario.end();
}

fun cleanup(tree: &mut PriceTree<MockLevel>, keys: vector<u64>) {
    let mut i = 0;
    while (i < keys.length()) {
        let ptr = price_tree::find(tree, keys[i]).destroy_some();
        let _v = price_tree::remove(tree, ptr);
        i = i + 1;
    };
}

/// Insertion-sort a copy of `v` ascending (reference implementation used by
/// the stress/differential tests above).
fun sorted(v: &vector<u64>): vector<u64> {
    let mut out: vector<u64> = vector[];
    let mut i = 0;
    while (i < v.length()) {
        let x = v[i];
        let mut j = 0;
        while (j < out.length() && out[j] < x) { j = j + 1; };
        out.insert(x, j);
        i = i + 1;
    };
    out
}

/// Deterministic pseudo-random key stream (xorshift-ish), deliberately
/// independent of `gen_distinct_keys`'s LCG so the stress tests above don't
/// share any accidental structure with the ordering tests they strengthen.
fun prng_keys(n: u64, seed: u64): vector<u64> {
    let mut out: vector<u64> = vector[];
    let mut x = seed;
    let mut i = 0;
    while (i < n) {
        x = x ^ (x << 13);
        x = x ^ (x >> 7);
        x = x ^ (x << 17);
        let k = x % 1_000_000;
        if (!out.contains(&k)) { out.push_back(k); };
        i = i + 1;
    };
    out
}

/// Drains the whole tree via repeated `min_leaf` + `remove`, returning the
/// keys in the order the tree yielded them.
fun drain_ascending(tree: &mut PriceTree<MockLevel>): vector<u64> {
    let mut out: vector<u64> = vector[];
    loop {
        let m = price_tree::min_leaf(tree);
        if (m.is_none()) { m.destroy_none(); break };
        let ptr = m.destroy_some();
        out.push_back(price_tree::key(tree, ptr));
        let MockLevel { orders: _ } = price_tree::remove(tree, ptr);
    };
    out
}

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
    tree.destroy_empty();
    scenario.end();
}

/// Fully destroys a `PriceLevel` popped off the tree via `remove`: drains
/// every order (destroying its empty escrow legs) then destroys the empty
/// level itself.
fun destroy_level(mut level: PriceLevel<BTC, USDC>) {
    while (!level.level_is_empty()) {
        let (_id, order) = level.level_pop_front_order();
        let (escrow_base, escrow_quote, fee_reserve_base, fee_reserve_quote) = order.destroy();
        escrow_base.destroy_none();
        escrow_quote.destroy_none();
        // `mock_order` constructs orders with both escrow legs `none()`, so
        // `order::new` treats them as ask-side (`fee_reserve_quote` — see
        // its doc comment); `fee_reserve_base` is therefore always `none()`
        // and `fee_reserve_quote` is always a zero-valued `Some`.
        fee_reserve_base.destroy_none();
        fee_reserve_quote.destroy_some().destroy_zero();
    };
    level.destroy_empty_price_level();
}

/// Removes and fully destroys every leaf in `keys` — the `PriceLevel`
/// analogue of `cleanup` below.
fun cleanup_levels(tree: &mut PriceTree<PriceLevel<BTC, USDC>>, keys: vector<u64>) {
    let mut i = 0;
    while (i < keys.length()) {
        let ptr = tree.find(keys[i]).destroy_some();
        let level = tree.remove(ptr);
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
        tree.insert_or_append_order(keys[i], i, order, ctx);
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
    level.level_insert_order(order_id, mock_order(order_id));
    tree.insert(key, level);
}

/// Drains the whole `PriceLevel` tree via repeated `min_leaf` + `remove`,
/// fully destroying each popped level, and returns the keys in the order
/// the tree yielded them.
fun drain_ascending_levels(tree: &mut PriceTree<PriceLevel<BTC, USDC>>): vector<u64> {
    let mut out: vector<u64> = vector[];
    loop {
        let m = tree.min_leaf();
        if (m.is_none()) { m.destroy_none(); break };
        let ptr = m.destroy_some();
        out.push_back(tree.key(ptr));
        let level = tree.remove(ptr);
        destroy_level(level);
    };
    out
}

// === insert_single_key_becomes_root_min_max ===

#[test]
fun insert_single_key_becomes_root_min_max() {
    let (scenario, mut tree) = setup();

    tree.insert(42_000_000, mock(1));

    let min_ptr = tree.min_leaf().destroy_some();
    let max_ptr = tree.max_leaf().destroy_some();
    let found_ptr = tree.find(42_000_000).destroy_some();
    assert!(min_ptr == max_ptr, 0);
    assert!(min_ptr == found_ptr, 1);
    assert!(tree.size() == 1, 2);

    let _v = tree.remove(found_ptr);
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
    let (scenario, mut tree) = setup();

    // Ascending resting-bid-style prices (6-decimal USDC-style raw units).
    let prices = vector[1_000_000u64, 1_500_000, 2_000_000, 2_750_000, 3_100_000];
    let mut i = 0;
    let mut last_max_ptr = option::none<u64>();
    while (i < prices.length()) {
        let price = prices[i];
        tree.insert(price, mock(i));
        let max_ptr = tree.max_leaf().destroy_some();
        // Each insert's new key is a fresh max: max_leaf must move to it,
        // read directly as a tracked field (not re-derived by descent).
        assert!(tree.find(price).destroy_some() == max_ptr, i);
        last_max_ptr = option::some(max_ptr);
        i = i + 1;
    };
    assert!(last_max_ptr.destroy_some() == tree.max_leaf().destroy_some(), 100);

    // Min never moved off the first-inserted (lowest) key.
    let expected_min = tree.find(1_000_000).destroy_some();
    assert!(tree.min_leaf().destroy_some() == expected_min, 101);

    cleanup(&mut tree, prices);
    teardown(scenario, tree);
}

// === insert_descending_keys_updates_min_leaf_incrementally ===

/// Symmetric to `insert_ascending_keys_updates_max_leaf_incrementally`
/// above, for `min_leaf`.
#[test]
fun insert_descending_keys_updates_min_leaf_incrementally() {
    let (scenario, mut tree) = setup();

    let prices = vector[9_000_000u64, 8_400_000, 7_950_000, 7_000_000, 6_100_000];
    let mut i = 0;
    while (i < prices.length()) {
        let price = prices[i];
        tree.insert(price, mock(i));
        let min_ptr = tree.min_leaf().destroy_some();
        assert!(tree.find(price).destroy_some() == min_ptr, i);
        i = i + 1;
    };

    let expected_max = tree.find(9_000_000).destroy_some();
    assert!(tree.max_leaf().destroy_some() == expected_max, 100);

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
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1)); // low -> min
    tree.insert(8_800_000, mock(2)); // high -> max

    let min_before = tree.min_leaf().destroy_some();
    let max_before = tree.max_leaf().destroy_some();

    tree.insert(6_250_000, mock(3)); // middle -> neither

    assert!(tree.min_leaf().destroy_some() == min_before, 0);
    assert!(tree.max_leaf().destroy_some() == max_before, 1);
    assert!(tree.size() == 3, 2);

    cleanup(&mut tree, vector[5_000_000, 6_250_000, 8_800_000]);
    teardown(scenario, tree);
}

// === remove_non_extreme_leaf_leaves_min_max_unchanged ===

#[test]
fun remove_non_extreme_leaf_leaves_min_max_unchanged() {
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1)); // min
    tree.insert(6_250_000, mock(2)); // middle
    tree.insert(8_800_000, mock(3)); // max

    let min_before = tree.min_leaf().destroy_some();
    let max_before = tree.max_leaf().destroy_some();

    let middle_ptr = tree.find(6_250_000).destroy_some();
    let _v = tree.remove(middle_ptr);

    assert!(tree.min_leaf().destroy_some() == min_before, 0);
    assert!(tree.max_leaf().destroy_some() == max_before, 1);
    assert!(tree.size() == 2, 2);
    assert!(tree.find(6_250_000).is_none(), 3);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

// === remove_min_leaf_recomputes_new_min ===

#[test]
fun remove_min_leaf_recomputes_new_min() {
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1)); // min
    tree.insert(6_250_000, mock(2)); // new min after removal
    tree.insert(8_800_000, mock(3)); // max

    let old_min_ptr = tree.find(5_000_000).destroy_some();
    let _v = tree.remove(old_min_ptr);

    let expected_new_min = tree.find(6_250_000).destroy_some();
    assert!(tree.min_leaf().destroy_some() == expected_new_min, 0);

    cleanup(&mut tree, vector[6_250_000, 8_800_000]);
    teardown(scenario, tree);
}

// === remove_max_leaf_recomputes_new_max ===

#[test]
fun remove_max_leaf_recomputes_new_max() {
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1)); // min
    tree.insert(6_250_000, mock(2)); // new max after removal
    tree.insert(8_800_000, mock(3)); // max

    let old_max_ptr = tree.find(8_800_000).destroy_some();
    let _v = tree.remove(old_max_ptr);

    let expected_new_max = tree.find(6_250_000).destroy_some();
    assert!(tree.max_leaf().destroy_some() == expected_new_max, 0);

    cleanup(&mut tree, vector[5_000_000, 6_250_000]);
    teardown(scenario, tree);
}

// === remove_last_leaf_empties_tree ===

#[test]
fun remove_last_leaf_empties_tree() {
    let (scenario, mut tree) = setup();

    tree.insert(12_500_000, mock(1));
    let ptr = tree.find(12_500_000).destroy_some();
    let _v = tree.remove(ptr);

    assert!(tree.min_leaf().is_none(), 0);
    assert!(tree.max_leaf().is_none(), 1);
    assert!(tree.size() == 0, 2);
    assert!(tree.find(12_500_000).is_none(), 3);

    teardown(scenario, tree);
}

// === find_missing_key_returns_none / find_present_key_returns_some_pointer ===

#[test]
fun find_missing_key_returns_none() {
    let (scenario, mut tree) = setup();

    tree.insert(3_300_000, mock(1));
    assert!(tree.find(9_900_000).is_none(), 0);

    cleanup(&mut tree, vector[3_300_000]);
    teardown(scenario, tree);
}

#[test]
fun find_present_key_returns_some_pointer() {
    let (scenario, mut tree) = setup();

    tree.insert(3_300_000, mock(1));
    assert!(tree.find(3_300_000).is_some(), 0);

    cleanup(&mut tree, vector[3_300_000]);
    teardown(scenario, tree);
}

// === insert_many_prices_in_narrow_cluster_and_verify_structure ===

#[test]
fun insert_many_prices_in_narrow_cluster_and_verify_structure() {
    let (scenario, mut tree) = setup();

    // 12 distinct adjacent prices, realistic 6-decimal magnitude.
    let base = 4_000_000u64;
    let mut i = 0;
    while (i < 12) {
        tree.insert(base + i, mock(i));
        i = i + 1;
    };
    assert!(tree.size() == 12, 0);

    i = 0;
    while (i < 12) {
        assert!(tree.find(base + i).is_some(), 1);
        i = i + 1;
    };

    // Remove a subset (every other price); confirm only those disappear.
    i = 0;
    while (i < 12) {
        if (i % 2 == 0) {
            let ptr = tree.find(base + i).destroy_some();
            let _v = tree.remove(ptr);
        };
        i = i + 1;
    };
    assert!(tree.size() == 6, 2);
    i = 0;
    while (i < 12) {
        let present = tree.find(base + i).is_some();
        assert!(present == (i % 2 == 1), 3);
        i = i + 1;
    };

    // Remove the remaining odd-indexed leaves to empty the tree.
    i = 1;
    while (i < 12) {
        let ptr = tree.find(base + i).destroy_some();
        let _v = tree.remove(ptr);
        i = i + 2;
    };
    assert!(tree.size() == 0, 4);

    teardown(scenario, tree);
}

// === insert_staircase_keys_ascending/descending_forces_max_depth_spine ===

/// Inserts keys `1u64 << i` for `i` in `0..64`, ascending. Each key's single
/// set bit is strictly higher than every previously-inserted key's, so the
/// crit-bit chosen for each new insertion is always the just-inserted key's
/// own high bit — forcing a maximal-depth spine (each new leaf becomes an
/// ancestor of all previous ones) rather than a balanced tree. This exercises
/// the true worst case for this crit-bit implementation, unlike
/// `insert_many_prices_in_narrow_cluster_and_verify_structure` above (whose
/// keys differ only in their low 4 bits and so stay shallow).
#[test]
fun insert_staircase_keys_ascending_forces_max_depth_spine() {
    let (scenario, mut tree) = setup();

    let mut keys: vector<u64> = vector[];
    let mut i = 0;
    while (i < 64) {
        let key = 1u64 << (i as u8);
        tree.insert(key, mock(i));
        keys.push_back(key);
        i = i + 1;
    };
    assert!(tree.size() == 64, 0);

    // Spot-check several of the 64 keys, not all, to keep this readable.
    let mut j = 0;
    while (j < keys.length()) {
        assert!(tree.find(keys[j]).is_some(), 1);
        j = j + 8;
    };
    assert!(tree.find(keys[0]).is_some(), 2);
    assert!(tree.find(keys[63]).is_some(), 3);

    cleanup(&mut tree, keys);
    teardown(scenario, tree);
}

/// Symmetric to `insert_staircase_keys_ascending_forces_max_depth_spine`
/// above, inserting the same staircase key set in DESCENDING order — since
/// insertion order can affect which specific internal-node structure results
/// (even though the tree's externally-visible behavior must not depend on
/// it), this is a genuinely distinct test, not a duplicate.
#[test]
fun insert_staircase_keys_descending_forces_max_depth_spine() {
    let (scenario, mut tree) = setup();

    let mut keys: vector<u64> = vector[];
    let mut i = 64;
    while (i > 0) {
        i = i - 1;
        let key = 1u64 << (i as u8);
        tree.insert(key, mock(i));
        keys.push_back(key);
    };
    assert!(tree.size() == 64, 0);

    let mut j = 0;
    while (j < keys.length()) {
        assert!(tree.find(keys[j]).is_some(), 1);
        j = j + 8;
    };
    assert!(tree.find(keys[0]).is_some(), 2);
    assert!(tree.find(keys[63]).is_some(), 3);

    cleanup(&mut tree, keys);
    teardown(scenario, tree);
}

// === insert_same_price_repeatedly_leaves_tree_depth_unchanged ===

#[test]
fun insert_same_price_repeatedly_leaves_tree_depth_unchanged() {
    let (scenario, mut tree) = setup();

    // First order at this price creates the leaf.
    tree.insert(7_500_000, mock(1));
    assert!(tree.size() == 1, 0);

    // Additional orders at the same already-present price never call
    // `insert` again — they mutate the existing leaf's FIFO queue in place
    // via `borrow_mut`.
    let ptr = tree.find(7_500_000).destroy_some();
    let mut n = 2;
    while (n <= 5) {
        tree.borrow_mut(ptr).orders.push_back(n);
        n = n + 1;
    };

    // No new InternalNode/Leaf was created beyond the first.
    assert!(tree.size() == 1, 1);
    assert!(tree.borrow(ptr).orders.length() == 5, 2);

    cleanup(&mut tree, vector[7_500_000]);
    teardown(scenario, tree);
}

// === no_tick_divisibility_check ===

#[test]
fun no_tick_divisibility_check() {
    let (scenario, mut tree) = setup();

    // 7 and 13 share no common divisor beyond 1 — no tick-size/divisibility
    // check exists anywhere in price_tree, so both inserts succeed with no
    // abort.
    tree.insert(7, mock(1));
    tree.insert(13, mock(2));
    assert!(tree.find(7).is_some(), 0);
    assert!(tree.find(13).is_some(), 1);

    cleanup(&mut tree, vector[7, 13]);
    teardown(scenario, tree);
}

// === Duplicate-key insert aborts ===

#[test]
#[expected_failure(abort_code = price_tree::EKeyAlreadyExists)]
fun insert_duplicate_key_aborts() {
    let (scenario, mut tree) = setup();

    tree.insert(2_000_000, mock(1));
    tree.insert(2_000_000, mock(2));

    cleanup(&mut tree, vector[2_000_000]);
    teardown(scenario, tree);
}

// === Non-empty price level cannot be destroyed ===

/// `destroy_empty_price_level` must abort with `EPriceLevelNotEmpty` when the
/// level still has a live order in it (`total_size != 0`), rather than
/// silently discarding the order — see the error's doc comment.
#[test]
#[expected_failure(abort_code = price_tree::EPriceLevelNotEmpty, location = tiny_clob::price_tree)]
fun destroy_empty_price_level_with_live_order_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let mut level = price_tree::new_price_level<BTC, USDC>(scenario.ctx());
    level.level_insert_order(1, mock_order(1));

    level.destroy_empty_price_level();

    scenario.end();
}

// === Invalid leaf pointer aborts (M-1) ===

/// Builds a 2-leaf tree (so exactly one internal node exists), then passes
/// that internal node's raw numeric index — which is `< PARTITION_INDEX`,
/// i.e. not a leaf pointer at all — to `borrow`. Must abort with
/// `EInvalidLeafPtr`, not `sui::table`'s generic missing-key abort.
#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1));
    tree.insert(8_800_000, mock(2));

    // The tree now has exactly one internal node, allocated at index 0
    // (internal-node indices are allocated bottom-up from 0). Index 0 is
    // `< PARTITION_INDEX`, so it is not a leaf pointer.
    let bad_ptr: u64 = 0;
    let _v = tree.borrow(bad_ptr);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun remove_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1));
    tree.insert(8_800_000, mock(2));

    let bad_ptr: u64 = 0;
    let _v = tree.remove(bad_ptr);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun key_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1));
    tree.insert(8_800_000, mock(2));

    let bad_ptr: u64 = 0;
    let _k = tree.key(bad_ptr);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_mut_with_internal_node_index_aborts_invalid_leaf_ptr() {
    let (scenario, mut tree) = setup();

    tree.insert(5_000_000, mock(1));
    tree.insert(8_800_000, mock(2));

    let bad_ptr: u64 = 0;
    let _v = tree.borrow_mut(bad_ptr);

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
        let (scenario, mut tree) = setup();

        let mut i = 0;
        while (i < order.length()) {
            let idx = order[i];
            tree.insert(keys[idx], mock(idx));
            i = i + 1;
        };

        assert!(tree.size() == keys.length(), o);

        // Every key is findable regardless of insertion order.
        i = 0;
        while (i < keys.length()) {
            assert!(tree.find(keys[i]).is_some(), o);
            i = i + 1;
        };

        // min/max are the same actual keys regardless of insertion order.
        let min_ptr = tree.min_leaf().destroy_some();
        let max_ptr = tree.max_leaf().destroy_some();
        assert!(tree.key(min_ptr) == 1_000_000, o);
        assert!(tree.key(max_ptr) == 9_900_000, o);

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
    tree.insert_or_append_order(new_key, 100, mock_order(100), ctx);

    assert!(tree.size() == existing.length() + 1, 0);
    let new_ptr = tree.find(new_key).destroy_some();
    assert!(tree.borrow(new_ptr).level_contains_order(100), 1);

    // Existing keys remain findable, and min/max are unaffected (new_key is
    // strictly between the existing min and max).
    let mut i = 0;
    while (i < existing.length()) {
        assert!(tree.find(existing[i]).is_some(), 2);
        i = i + 1;
    };
    let min_ptr = tree.min_leaf().destroy_some();
    let max_ptr = tree.max_leaf().destroy_some();
    assert!(tree.key(min_ptr) == 2_000_000, 3);
    assert!(tree.key(max_ptr) == 9_000_000, 4);

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
    assert!(tree.size() == 3, 0);

    tree.insert_or_append_order(5_000_000, 200, mock_order(200), ctx);
    tree.insert_or_append_order(5_000_000, 201, mock_order(201), ctx);

    // No new leaf was created for the repeated price.
    assert!(tree.size() == 3, 1);

    let ptr = tree.find(5_000_000).destroy_some();
    let level = tree.borrow(ptr);
    assert!(level.level_contains_order(1), 2); // original order (order_id=1)
    assert!(level.level_contains_order(200), 3);
    assert!(level.level_contains_order(201), 4);
    // FIFO order preserved: original order stays at the front.
    assert!(level.level_front_order_id().destroy_some() == 1, 5);

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
        tree.insert_or_append_order(price, next_order_id, mock_order(next_order_id), ctx);
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

    assert!(tree.size() == all_prices.length(), 1);
    assert!(all_prices.length() == expected.length(), 5);

    // Every price level contains exactly the expected order ids, in FIFO
    // order, and nothing else.
    let mut k = 0;
    while (k < all_prices.length()) {
        let ptr = tree.find(all_prices[k]).destroy_some();
        let level = tree.borrow(ptr);
        let want = expected.borrow(k);
        let mut m = 0;
        while (m < want.length()) {
            assert!(level.level_contains_order(want[m]), 2);
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
    assert!(tree.size() == n, 0);

    let mut i = 0;
    while (i < n) {
        assert!(tree.find(keys[i]).is_some(), 1);
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
        let mp = tree.min_leaf().destroy_some();
        let k = tree.key(mp);
        if (!first) { assert!(k > prev, 2); };
        assert!(keys.contains(&k), 3);
        assert!(tree.key(tree.max_leaf().destroy_some()) == hi, 4);
        let _v = tree.remove(mp);
        prev = k;
        first = false;
        remaining = remaining - 1;
        assert!(tree.size() == remaining, 5);
    };
    assert!(tree.min_leaf().is_none(), 6);
    assert!(tree.max_leaf().is_none(), 7);
}

/// `assert_full_ascending_drain`'s counterpart for the `PriceLevel`-typed
/// tree used by `insert_or_append_order` tests below.
fun assert_full_ascending_drain_levels(tree: &mut PriceTree<PriceLevel<BTC, USDC>>, keys: &vector<u64>) {
    let n = keys.length();
    assert!(tree.size() == n, 0);

    let mut i = 0;
    while (i < n) {
        assert!(tree.find(keys[i]).is_some(), 1);
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
        let mp = tree.min_leaf().destroy_some();
        let k = tree.key(mp);
        if (!first) { assert!(k > prev, 2); };
        assert!(keys.contains(&k), 3);
        assert!(tree.key(tree.max_leaf().destroy_some()) == hi, 4);
        let level = tree.remove(mp);
        destroy_level(level);
        prev = k;
        first = false;
        remaining = remaining - 1;
        assert!(tree.size() == remaining, 5);
    };
    assert!(tree.min_leaf().is_none(), 6);
    assert!(tree.max_leaf().is_none(), 7);
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
            tree.insert(order[i], mock(i));
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
            tree.insert(keys[i], mock(keys[i]));
            i = i + 1;
        };
        assert!(tree.size() == keys.length(), 0);

        // Every inserted key must be findable at a leaf carrying that key.
        let mut j = 0;
        while (j < keys.length()) {
            let ptr = tree.find(keys[j]).destroy_some();
            assert!(tree.key(ptr) == keys[j], 1);
            j = j + 1;
        };

        let want = sorted(&keys);
        assert!(tree.key(tree.min_leaf().destroy_some()) == want[0], 2);
        assert!(
            tree.key(tree.max_leaf().destroy_some())
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
            ref_tree.insert(keys[i], mock(keys[i]));
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
            tree.insert_or_append_order(k, j, mock_order(j), ctx);
            j = j + 1;
        };
        assert!(tree.size() == keys.length(), 1);
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
            tree.insert_or_append_order(k, i, mock_order(i), ctx);
        };
        live.push_back(k);

        // Every third step, remove the current minimum.
        if (i % 3 == 2) {
            let ptr = tree.min_leaf().destroy_some();
            let mk = tree.key(ptr);
            let level = tree.remove(ptr);
            destroy_level(level);
            let (found, idx) = live.index_of(&mk);
            assert!(found, 0);
            live.remove(idx);
        };
        assert!(tree.size() == live.length(), 1);
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
    let (scenario, mut tree) = setup();
    tree.insert(5_000_000, mock(1));
    let _v = tree.remove(NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_with_no_parent_ptr_aborts_invalid_leaf_ptr() {
    let (scenario, mut tree) = setup();
    tree.insert(5_000_000, mock(1));
    let _v = tree.borrow(NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun borrow_mut_with_no_parent_ptr_aborts_invalid_leaf_ptr() {
    let (scenario, mut tree) = setup();
    tree.insert(5_000_000, mock(1));
    let _v = tree.borrow_mut(NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

#[test]
#[expected_failure(abort_code = price_tree::EInvalidLeafPtr, location = tiny_clob::price_tree)]
fun key_with_no_parent_ptr_aborts_invalid_leaf_ptr() {
    let (scenario, mut tree) = setup();
    tree.insert(5_000_000, mock(1));
    let _k = tree.key(NO_PARENT_FOR_TESTING);
    cleanup(&mut tree, vector[5_000_000]);
    teardown(scenario, tree);
}

// === High-bit / crit-bit-mask boundary tests ===
//
// Every key used elsewhere in this file is well under 2^23 in magnitude, so
// `highest_set_bit_mask` (the crit-bit mask computation in `insert`) has
// never been exercised with a mask anywhere near bit 63 — the sign/top bit,
// which numerically aliases `PARTITION_INDEX`/`NO_PARENT`
// (`0x8000000000000000`). These tests specifically exercise keys that force
// a crit-bit split right at bit 63, plus the extreme `u64` boundary values.
// (Key `0` is not exercised here: `price_tree` itself has no zero-key check
// — see `no_tick_divisibility_check` above — but `0` is not a legal price in
// this tree's real caller, `tiny_clob`, which rejects it via `EZeroPrice`
// before it would ever reach `price_tree::insert`. Testing it here would
// exercise a state the tree never actually sees in practice.)

const U64_MAX: u64 = 0xFFFFFFFFFFFFFFFF;
const U64_SIGN_BIT: u64 = 0x8000000000000000;
const U64_MAX_MINUS_SIGN_BIT: u64 = 0x7FFFFFFFFFFFFFFF; // U64_MAX with bit 63 cleared

// === insert_keys_differing_only_at_bit_63_splits_correctly ===

/// Two keys identical in every bit except bit 63 (the sign/top bit): `1` and
/// `0x8000000000000001`. Their XOR is exactly `U64_SIGN_BIT`, so
/// `highest_set_bit_mask` must return that value as the crit-bit mask — the
/// same numeric value as `PARTITION_INDEX`/`NO_PARENT`. Confirms the split
/// still lands correctly (right key ends up on the correct side, min/max
/// track correctly, both remain independently findable and removable).
#[test]
fun insert_keys_differing_only_at_bit_63_splits_correctly() {
    let (scenario, mut tree) = setup();

    let low_key = 1u64;
    let high_key = 0x8000000000000001u64; // low_key with bit 63 also set
    // Confirm the two keys genuinely differ by exactly the sign bit, not
    // merely by hex literals that happen to look that way.
    assert!((low_key ^ high_key) == U64_SIGN_BIT, 100);

    tree.insert(low_key, mock(1));
    tree.insert(high_key, mock(2));

    assert!(tree.size() == 2, 0);
    assert!(tree.find(low_key).is_some(), 1);
    assert!(tree.find(high_key).is_some(), 2);

    let min_ptr = tree.min_leaf().destroy_some();
    let max_ptr = tree.max_leaf().destroy_some();
    assert!(tree.key(min_ptr) == low_key, 3);
    assert!(tree.key(max_ptr) == high_key, 4);

    // Remove the high (max) key first, then confirm the low key alone
    // becomes both min and max of the now-single-leaf tree.
    let high_ptr = tree.find(high_key).destroy_some();
    let _v1 = tree.remove(high_ptr);
    assert!(tree.size() == 1, 5);
    assert!(tree.find(low_key).is_some(), 6);
    assert!(tree.find(high_key).is_none(), 7);
    let sole_ptr = tree.min_leaf().destroy_some();
    assert!(sole_ptr == tree.max_leaf().destroy_some(), 8);
    assert!(tree.key(sole_ptr) == low_key, 9);

    let _v2 = tree.remove(sole_ptr);
    assert!(tree.size() == 0, 10);
    teardown(scenario, tree);
}

/// Same key pair as above, but the LOW key (min) is removed first instead of
/// the high one — exercises `remove`'s `min_leaf` re-descent path when the
/// sibling subtree is the bit-63-tagged leaf.
#[test]
fun insert_keys_differing_only_at_bit_63_remove_min_first() {
    let (scenario, mut tree) = setup();

    let low_key = 1u64;
    let high_key = 0x8000000000000001u64;
    // Confirm the two keys genuinely differ by exactly the sign bit, not
    // merely by hex literals that happen to look that way.
    assert!((low_key ^ high_key) == U64_SIGN_BIT, 100);

    tree.insert(low_key, mock(1));
    tree.insert(high_key, mock(2));

    let low_ptr = tree.find(low_key).destroy_some();
    let _v1 = tree.remove(low_ptr);

    assert!(tree.size() == 1, 0);
    assert!(tree.find(low_key).is_none(), 1);
    assert!(tree.find(high_key).is_some(), 2);
    let sole_ptr = tree.min_leaf().destroy_some();
    assert!(sole_ptr == tree.max_leaf().destroy_some(), 3);
    assert!(tree.key(sole_ptr) == high_key, 4);

    let _v2 = tree.remove(sole_ptr);
    teardown(scenario, tree);
}

// === insert_extreme_boundary_keys_with_normal_magnitudes ===

/// Inserts `1`, `u64::MAX`, and a handful of normal-magnitude (6-decimal
/// price-like) keys together, confirming correct min/max tracking and
/// find-ability across the whole span, then removes in a mixed order (max
/// first, then min, then a middle key, then the rest) — following this
/// file's established practice of varying removal order across tests.
#[test]
fun insert_extreme_boundary_keys_with_normal_magnitudes() {
    let (scenario, mut tree) = setup();

    let normal_keys = vector[5_000_000u64, 6_250_000, 8_800_000];
    tree.insert(1, mock(0));
    let mut i = 0;
    while (i < normal_keys.length()) {
        tree.insert(normal_keys[i], mock(i + 1));
        i = i + 1;
    };
    tree.insert(U64_MAX, mock(99));

    assert!(tree.size() == 5, 0);
    assert!(tree.find(1).is_some(), 1);
    assert!(tree.find(U64_MAX).is_some(), 2);
    i = 0;
    while (i < normal_keys.length()) {
        assert!(tree.find(normal_keys[i]).is_some(), 3);
        i = i + 1;
    };

    assert!(tree.key(tree.min_leaf().destroy_some()) == 1, 4);
    assert!(tree.key(tree.max_leaf().destroy_some()) == U64_MAX, 5);

    // Remove max first.
    let max_ptr = tree.find(U64_MAX).destroy_some();
    let _v1 = tree.remove(max_ptr);
    assert!(tree.size() == 4, 6);
    assert!(tree.key(tree.max_leaf().destroy_some()) == 8_800_000, 7);
    assert!(tree.key(tree.min_leaf().destroy_some()) == 1, 8);

    // Then remove min.
    let min_ptr = tree.find(1).destroy_some();
    let _v2 = tree.remove(min_ptr);
    assert!(tree.size() == 3, 9);
    assert!(tree.key(tree.min_leaf().destroy_some()) == 5_000_000, 10);
    assert!(tree.key(tree.max_leaf().destroy_some()) == 8_800_000, 11);

    // Then remove a middle key.
    let mid_ptr = tree.find(6_250_000).destroy_some();
    let _v3 = tree.remove(mid_ptr);
    assert!(tree.size() == 2, 12);
    assert!(tree.find(6_250_000).is_none(), 13);
    assert!(tree.key(tree.min_leaf().destroy_some()) == 5_000_000, 14);
    assert!(tree.key(tree.max_leaf().destroy_some()) == 8_800_000, 15);

    cleanup(&mut tree, vector[5_000_000, 8_800_000]);
    teardown(scenario, tree);
}

// === insert_max_u64_and_sign_bit_boundary_key_together ===

/// `u64::MAX` (`0xFFFFFFFFFFFFFFFF`) and `0x7FFFFFFFFFFFFFFF` differ ONLY at
/// bit 63 — the sign boundary itself. Together with a normal-magnitude key
/// (to give the tree some depth beyond a single 2-leaf split), confirms the
/// crit-bit split at this exact boundary lands correctly: `min`/`max`
/// tracking, `find`-ability, and removal in a third distinct order (middle
/// first, then min, then max) not yet used by the tests above.
#[test]
fun insert_max_u64_and_sign_bit_boundary_key_together() {
    let (scenario, mut tree) = setup();

    tree.insert(U64_MAX, mock(1));
    tree.insert(U64_MAX_MINUS_SIGN_BIT, mock(2));
    tree.insert(4_000_000, mock(3));

    assert!(tree.size() == 3, 0);
    assert!(tree.find(U64_MAX).is_some(), 1);
    assert!(tree.find(U64_MAX_MINUS_SIGN_BIT).is_some(), 2);
    assert!(tree.find(4_000_000).is_some(), 3);

    // 4_000_000 is the smallest of the three; U64_MAX is the largest.
    assert!(tree.key(tree.min_leaf().destroy_some()) == 4_000_000, 4);
    assert!(tree.key(tree.max_leaf().destroy_some()) == U64_MAX, 5);

    // Remove the middle key first.
    let mid_ptr = tree.find(U64_MAX_MINUS_SIGN_BIT).destroy_some();
    let _v1 = tree.remove(mid_ptr);
    assert!(tree.size() == 2, 6);
    assert!(tree.find(U64_MAX_MINUS_SIGN_BIT).is_none(), 7);
    assert!(tree.key(tree.min_leaf().destroy_some()) == 4_000_000, 8);
    assert!(tree.key(tree.max_leaf().destroy_some()) == U64_MAX, 9);

    // Then remove the min.
    let min_ptr = tree.find(4_000_000).destroy_some();
    let _v2 = tree.remove(min_ptr);
    assert!(tree.size() == 1, 10);
    let sole_ptr = tree.min_leaf().destroy_some();
    assert!(sole_ptr == tree.max_leaf().destroy_some(), 11);
    assert!(tree.key(sole_ptr) == U64_MAX, 12);

    // Then remove the last (max) leaf, emptying the tree.
    let _v3 = tree.remove(sole_ptr);
    assert!(tree.size() == 0, 13);
    assert!(tree.min_leaf().is_none(), 14);
    assert!(tree.max_leaf().is_none(), 15);
    teardown(scenario, tree);
}

// === remove_genuinely_mixed_order_recomputes_min_max_every_step ===

/// The removal-order tests above are all either min-first, max-first, or
/// "arbitrary order but only checked at the very end"
/// (`insert_many_prices_in_narrow_cluster_and_verify_structure`'s odd/even removal, and
/// the middle-key removal in `remove_non_extreme_leaf_leaves_min_max_unchanged`
/// above, both check only a couple of snapshots). This test instead: inserts
/// 16 distinct pseudo-random keys (via `gen_distinct_keys`, this file's
/// existing LCG-based generator — used elsewhere in this file, e.g.
/// `order_independence_full_drain_across_orderings_and_entry_points`), then
/// removes them one at a time in a genuinely mixed order that cycles through
/// the CURRENT min, then the CURRENT middle, then the CURRENT max of
/// whatever keys are still live — recomputed fresh after every removal, so
/// neither the "middle" nor the "max" target is a fixed pre-computed index
/// into the original key set. This forces `remove`'s
/// `descend_extreme(sibling_ptr, ...)` min/max-recomputation path to run
/// repeatedly against a variety of shrinking tree shapes, not just the two
/// trivial already-sorted removal orders every other test in this file uses.
///
/// After EVERY removal (not just at the end), asserts: `size()` decremented
/// by exactly one, `find()` returns `none` for the just-removed key, `find()`
/// (and the key it resolves to) is still correct for every remaining key, and
/// `min_leaf`/`max_leaf` still match an independently maintained sorted
/// in-memory model (`remaining`) of the keys still live in the tree.
#[test]
fun remove_genuinely_mixed_order_recomputes_min_max_every_step() {
    let (scenario, mut tree) = setup();

    let keys = gen_distinct_keys(16, 314159, 20_000_000);
    let mut i = 0;
    while (i < keys.length()) {
        tree.insert(keys[i], mock(i));
        i = i + 1;
    };
    assert!(tree.size() == keys.length(), 0);

    // In-memory sorted model of the keys still live in the tree — kept
    // sorted throughout since removal is always by index, never a re-sort.
    let mut remaining = sorted(&keys);

    let mut step = 0;
    while (remaining.length() > 0) {
        let n = remaining.length();
        // Cycle: current min -> current middle -> current max -> repeat,
        // against whatever keys are still live at this step (not a static
        // permutation of the original key set).
        let pick_idx = if (step % 3 == 0) {
            0
        } else if (step % 3 == 1) {
            n / 2
        } else {
            n - 1
        };
        let target_key = remaining.remove(pick_idx);

        let ptr = tree.find(target_key).destroy_some();
        let _v = tree.remove(ptr);

        // size() decremented correctly.
        assert!(tree.size() == remaining.length(), step);

        // The just-removed key is gone.
        assert!(tree.find(target_key).is_none(), 100 + step);

        // Every remaining key is still findable, resolving to itself.
        let mut j = 0;
        while (j < remaining.length()) {
            let rk = remaining[j];
            let fp = tree.find(rk);
            assert!(fp.is_some(), 200 + step);
            assert!(tree.key(fp.destroy_some()) == rk, 300 + step);
            j = j + 1;
        };

        // min_leaf/max_leaf still match the in-memory sorted model. Min and
        // max codes are spaced far enough apart (1000 vs 2000) that no two
        // steps can ever collide, unlike the earlier `500 + step`/
        // `501 + step` pairing, which aliased at adjacent steps.
        if (remaining.length() == 0) {
            assert!(tree.min_leaf().is_none(), 1000 + step);
            assert!(tree.max_leaf().is_none(), 2000 + step);
        } else {
            let expected_min = remaining[0];
            let expected_max = remaining[remaining.length() - 1];
            assert!(tree.key(tree.min_leaf().destroy_some()) == expected_min, 1000 + step);
            assert!(tree.key(tree.max_leaf().destroy_some()) == expected_max, 2000 + step);
        };

        step = step + 1;
    };

    teardown(scenario, tree);
}

// === test helpers ===

fun setup(): (ts::Scenario, PriceTree<MockLevel>) {
    let mut scenario = ts::begin(ADMIN);
    let tree = price_tree::new<MockLevel>(scenario.ctx());
    (scenario, tree)
}

fun teardown(scenario: ts::Scenario, tree: PriceTree<MockLevel>) {
    tree.destroy_empty();
    scenario.end();
}

fun cleanup(tree: &mut PriceTree<MockLevel>, keys: vector<u64>) {
    let mut i = 0;
    while (i < keys.length()) {
        let ptr = tree.find(keys[i]).destroy_some();
        let _v = tree.remove(ptr);
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
    while (out.length() < n) {
        x = x ^ (x << 13);
        x = x ^ (x >> 7);
        x = x ^ (x << 17);
        let k = x % 1_000_000;
        if (!out.contains(&k)) { out.push_back(k); };
    };
    out
}

/// Drains the whole tree via repeated `min_leaf` + `remove`, returning the
/// keys in the order the tree yielded them.
fun drain_ascending(tree: &mut PriceTree<MockLevel>): vector<u64> {
    let mut out: vector<u64> = vector[];
    loop {
        let m = tree.min_leaf();
        if (m.is_none()) { m.destroy_none(); break };
        let ptr = m.destroy_some();
        out.push_back(tree.key(ptr));
        let MockLevel { orders: _ } = tree.remove(ptr);
    };
    out
}

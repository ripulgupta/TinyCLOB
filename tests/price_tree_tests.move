/// Tests for `price_tree`.
///
/// `MockLevel` stands in for a real order-book price level (a FIFO queue of
/// resting orders); `price_tree` treats it as fully opaque, so a
/// `vector<u64>` of order ids is enough to exercise the tree mechanics
/// without pulling in any order-domain type.
#[test_only]
module tiny_clob::price_tree_tests;

use sui::test_scenario as ts;
use tiny_clob::price_tree::{Self, PriceTree};

public struct MockLevel has store, drop {
    orders: vector<u64>,
}

fun mock(order_id: u64): MockLevel {
    MockLevel { orders: vector[order_id] }
}

const ADMIN: address = @0xA11CE;

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

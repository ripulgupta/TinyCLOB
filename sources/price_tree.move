/// Generic critbit price-level tree, indexed by `Table` rather than a
/// vector so leaves and internal nodes can be added/removed independently.
/// Generic over the leaf value type `V`, with no dependency on any
/// order/market-specific type.
module tiny_clob::price_tree;

use sui::table::{Self, Table};

// === Errors ===

/// `insert` was called with a `key` that already has a leaf in the tree.
/// A second order resting at an already-present price must be applied via
/// `find` + `borrow_mut` on the existing leaf's value, never by calling
/// `insert` again for the same key.
const EKeyAlreadyExists: u64 = 0;

// === Constants (Pointer encoding + sentinels) ===

/// Values `>= PARTITION_INDEX` address a leaf (see `leaf_index_of`);
/// values `< PARTITION_INDEX` address `internal_nodes` directly by index.
const PARTITION_INDEX: u64 = 0x8000000000000000;

/// Sentinel for "this tree currently has zero leaves" — used by `root`,
/// `min_leaf`, `max_leaf`. Numerically `PARTITION_INDEX - 1`, distinct from
/// `NO_PARENT`/`PARTITION_INDEX` itself so it can never collide with a real
/// pointer.
const EMPTY_TREE: u64 = 0x7FFFFFFFFFFFFFFF;

/// Sentinel for "this node/leaf has no parent because it is the root".
/// Deliberately reuses `PARTITION_INDEX`'s numeric value (safe: `parent`
/// fields only ever address `internal_nodes`, whose indices are allocated
/// bottom-up from `0` and can never practically reach `PARTITION_INDEX`).
const NO_PARENT: u64 = 0x8000000000000000;

const MAX_U64: u64 = 0xFFFFFFFFFFFFFFFF;

// === Types ===

public struct Leaf<V: store> has store {
    key: u64,
    value: V,
    /// Pointer into `internal_nodes`, or `NO_PARENT` if this leaf is root.
    parent: u64,
}

public struct InternalNode has store {
    /// Critical-bit mask distinguishing left/right subtrees. Strictly
    /// decreases root-to-leaf (crit-bit ordering invariant).
    mask: u64,
    /// Pointer: `internal_nodes` index, or encoded leaf index.
    left: u64,
    right: u64,
    /// Pointer into `internal_nodes`, or `NO_PARENT` if this node is root.
    parent: u64,
}

public struct PriceTree<V: store> has store {
    /// `EMPTY_TREE` when the tree has zero leaves.
    root: u64,
    internal_nodes: Table<u64, InternalNode>,
    leaves: Table<u64, Leaf<V>>,
    /// O(1)-tracked pointer to the lowest-price leaf; `EMPTY_TREE` if empty.
    min_leaf: u64,
    /// O(1)-tracked pointer to the highest-price leaf; `EMPTY_TREE` if empty.
    max_leaf: u64,
    next_internal_index: u64,
    next_leaf_index: u64,
}

// === Construction ===

public fun new<V: store>(ctx: &mut TxContext): PriceTree<V> {
    PriceTree {
        root: EMPTY_TREE,
        internal_nodes: table::new(ctx),
        leaves: table::new(ctx),
        min_leaf: EMPTY_TREE,
        max_leaf: EMPTY_TREE,
        next_internal_index: 0,
        next_leaf_index: 0,
    }
}

/// Consumes an empty `PriceTree`. Aborts (via `table::destroy_empty`) if
/// either table is non-empty. Needed because `Table` has no `drop`, so a
/// tree can only go out of scope once both of its tables are empty.
public fun destroy_empty<V: store>(tree: PriceTree<V>) {
    let PriceTree {
        root: _,
        internal_nodes,
        leaves,
        min_leaf: _,
        max_leaf: _,
        next_internal_index: _,
        next_leaf_index: _,
    } = tree;
    table::destroy_empty(internal_nodes);
    table::destroy_empty(leaves);
}

// === Pointer encoding helpers ===

fun is_leaf_ptr(ptr: u64): bool {
    ptr >= PARTITION_INDEX
}

fun leaf_index_of(ptr: u64): u64 {
    MAX_U64 - ptr
}

fun encode_leaf_ptr(leaf_index: u64): u64 {
    MAX_U64 - leaf_index
}

/// Returns a `u64` with only the highest set bit of `x` set. `x` must be
/// non-zero (only ever called on an XOR of two distinct keys). A bounded
/// 64-iteration bit scan substituting for a native leading-zero-count
/// primitive, which `std::u64` does not expose.
fun highest_set_bit_mask(x: u64): u64 {
    let mut mask = 0x8000000000000000u64;
    while (mask > 0) {
        if (x & mask != 0) {
            return mask
        };
        mask = mask >> 1;
    };
    0
}

fun set_parent<V: store>(tree: &mut PriceTree<V>, ptr: u64, new_parent: u64) {
    if (is_leaf_ptr(ptr)) {
        table::borrow_mut(&mut tree.leaves, leaf_index_of(ptr)).parent = new_parent;
    } else {
        table::borrow_mut(&mut tree.internal_nodes, ptr).parent = new_parent;
    }
}

fun descend_to_leaf<V: store>(tree: &PriceTree<V>, key: u64): u64 {
    let mut ptr = tree.root;
    while (!is_leaf_ptr(ptr)) {
        let node = table::borrow(&tree.internal_nodes, ptr);
        ptr = if (key & node.mask == 0) node.left else node.right;
    };
    ptr
}

fun descend_extreme<V: store>(tree: &PriceTree<V>, want_min: bool): u64 {
    let mut ptr = tree.root;
    while (!is_leaf_ptr(ptr)) {
        let node = table::borrow(&tree.internal_nodes, ptr);
        ptr = if (want_min) node.left else node.right;
    };
    ptr
}

// === Operations ===

/// Inserts `value` under `key`. Aborts with `EKeyAlreadyExists` if `key` is
/// already present — a second order resting at an already-present price
/// must be applied via `find` + `borrow_mut`, not a second `insert`.
///
/// Cost: O(log distinct_price_count) `Table` reads/writes.
public fun insert<V: store>(tree: &mut PriceTree<V>, key: u64, value: V) {
    if (tree.root == EMPTY_TREE) {
        let leaf_idx = tree.next_leaf_index;
        tree.next_leaf_index = leaf_idx + 1;
        let leaf_ptr = encode_leaf_ptr(leaf_idx);
        table::add(&mut tree.leaves, leaf_idx, Leaf { key, value, parent: NO_PARENT });
        tree.root = leaf_ptr;
        tree.min_leaf = leaf_ptr;
        tree.max_leaf = leaf_ptr;
        return
    };

    let closest_ptr = descend_to_leaf(tree, key);
    let closest_leaf_idx = leaf_index_of(closest_ptr);
    let closest_key = table::borrow(&tree.leaves, closest_leaf_idx).key;
    assert!(closest_key != key, EKeyAlreadyExists);

    let xor = closest_key ^ key;
    let new_mask = highest_set_bit_mask(xor);

    // Re-descend, stopping where the existing node's mask is lower than
    // `new_mask` — masks strictly decrease root-to-leaf, so this finds the
    // correct insertion point for the new critical bit.
    let mut parent_ptr = NO_PARENT;
    let mut current_ptr = tree.root;
    while (!is_leaf_ptr(current_ptr)) {
        let node = table::borrow(&tree.internal_nodes, current_ptr);
        if (node.mask < new_mask) break;
        parent_ptr = current_ptr;
        current_ptr = if (key & node.mask == 0) node.left else node.right;
    };

    let leaf_idx = tree.next_leaf_index;
    tree.next_leaf_index = leaf_idx + 1;
    let leaf_ptr = encode_leaf_ptr(leaf_idx);

    let internal_idx = tree.next_internal_index;
    tree.next_internal_index = internal_idx + 1;

    let (left, right) = if (key & new_mask == 0) {
        (leaf_ptr, current_ptr)
    } else {
        (current_ptr, leaf_ptr)
    };
    table::add(
        &mut tree.internal_nodes,
        internal_idx,
        InternalNode { mask: new_mask, left, right, parent: parent_ptr },
    );
    table::add(&mut tree.leaves, leaf_idx, Leaf { key, value, parent: internal_idx });

    set_parent(tree, current_ptr, internal_idx);

    if (parent_ptr == NO_PARENT) {
        tree.root = internal_idx;
    } else {
        let gp = table::borrow_mut(&mut tree.internal_nodes, parent_ptr);
        if (gp.left == current_ptr) {
            gp.left = internal_idx;
        } else {
            gp.right = internal_idx;
        };
    };

    let min_key = table::borrow(&tree.leaves, leaf_index_of(tree.min_leaf)).key;
    if (key < min_key) {
        tree.min_leaf = leaf_ptr;
    };
    let max_key = table::borrow(&tree.leaves, leaf_index_of(tree.max_leaf)).key;
    if (key > max_key) {
        tree.max_leaf = leaf_ptr;
    };
}

/// Removes and returns the leaf's value. `leaf_ptr` is a leaf pointer as
/// returned by `find`/`min_leaf`/`max_leaf` (not a raw price key).
///
/// Cost: O(log distinct_price_count).
public fun remove<V: store>(tree: &mut PriceTree<V>, leaf_ptr: u64): V {
    let leaf_idx = leaf_index_of(leaf_ptr);
    let Leaf { key: _, value, parent } = table::remove(&mut tree.leaves, leaf_idx);

    if (parent == NO_PARENT) {
        // The removed leaf was the tree's only leaf.
        tree.root = EMPTY_TREE;
        tree.min_leaf = EMPTY_TREE;
        tree.max_leaf = EMPTY_TREE;
        return value
    };

    let InternalNode { mask: _, left, right, parent: grandparent } =
        table::remove(&mut tree.internal_nodes, parent);
    let sibling_ptr = if (left == leaf_ptr) right else left;

    set_parent(tree, sibling_ptr, grandparent);

    if (grandparent == NO_PARENT) {
        tree.root = sibling_ptr;
    } else {
        let gp = table::borrow_mut(&mut tree.internal_nodes, grandparent);
        if (gp.left == parent) {
            gp.left = sibling_ptr;
        } else {
            gp.right = sibling_ptr;
        };
    };

    if (leaf_ptr == tree.min_leaf) {
        tree.min_leaf = descend_extreme(tree, true);
    };
    if (leaf_ptr == tree.max_leaf) {
        tree.max_leaf = descend_extreme(tree, false);
    };

    value
}

/// Returns the leaf pointer for `key` if present.
public fun find<V: store>(tree: &PriceTree<V>, key: u64): Option<u64> {
    if (tree.root == EMPTY_TREE) {
        return option::none()
    };
    let ptr = descend_to_leaf(tree, key);
    let leaf = table::borrow(&tree.leaves, leaf_index_of(ptr));
    if (leaf.key == key) option::some(ptr) else option::none()
}

public fun borrow<V: store>(tree: &PriceTree<V>, leaf_ptr: u64): &V {
    &table::borrow(&tree.leaves, leaf_index_of(leaf_ptr)).value
}

/// Returns the price `key` a leaf pointer (as returned by `find`/
/// `min_leaf`/`max_leaf`) was inserted under.
public fun key<V: store>(tree: &PriceTree<V>, leaf_ptr: u64): u64 {
    table::borrow(&tree.leaves, leaf_index_of(leaf_ptr)).key
}

public fun borrow_mut<V: store>(tree: &mut PriceTree<V>, leaf_ptr: u64): &mut V {
    &mut table::borrow_mut(&mut tree.leaves, leaf_index_of(leaf_ptr)).value
}

/// O(1): the tracked pointer, not a derived-by-traversal value.
public fun min_leaf<V: store>(tree: &PriceTree<V>): Option<u64> {
    if (tree.min_leaf == EMPTY_TREE) option::none() else option::some(tree.min_leaf)
}

/// O(1): the tracked pointer, not a derived-by-traversal value.
public fun max_leaf<V: store>(tree: &PriceTree<V>): Option<u64> {
    if (tree.max_leaf == EMPTY_TREE) option::none() else option::some(tree.max_leaf)
}

/// Number of distinct keys (leaves) currently in the tree.
public fun size<V: store>(tree: &PriceTree<V>): u64 {
    table::length(&tree.leaves)
}

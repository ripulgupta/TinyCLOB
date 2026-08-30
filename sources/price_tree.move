/// Generic critbit price-level tree, indexed by `Table` rather than a
/// vector so leaves and internal nodes can be added/removed independently.
/// Generic over the leaf value type `V`, with no dependency on any
/// order/market-specific type.
module tiny_clob::price_tree;

use sui::linked_table::{Self, LinkedTable};
use sui::table::{Self, Table};
use tiny_clob::order::{Self, Order};

// === Errors ===

/// `insert` was called with a `key` that already has a leaf in the tree.
/// A second order resting at an already-present price must be applied via
/// `find` + `borrow_mut` on the existing leaf's value, never by calling
/// `insert` again for the same key.
const EKeyAlreadyExists: u64 = 1;

/// `remove`/`borrow`/`key`/`borrow_mut` was called with a `leaf_ptr` that is
/// not leaf-shaped (i.e. `< PARTITION_INDEX`, so it would actually address
/// `internal_nodes` rather than `leaves`) — e.g. an internal-node index
/// passed by mistake, or other garbage input. Note this check is narrower
/// than "pointer is valid": a leaf-shaped pointer whose `leaf_idx` is no
/// longer present in the table (e.g. reuse of an already-`remove`d pointer)
/// still aborts via `sui::table`'s own missing-key check, not this one —
/// `Table` exposes no cheap existence check that would be worth adding here.
const EInvalidLeafPtr: u64 = 2;

/// `destroy_empty_price_level` was called on a `PriceLevel` whose
/// `total_size` is nonzero. Since `linked_table::destroy_empty` already
/// aborts if `orders` is non-empty, a nonzero `total_size` here can only
/// mean the `total_size` invariant was already broken elsewhere — this
/// assertion exists purely to fail loudly at that point instead of
/// silently discarding the evidence.
const EPriceLevelNotEmpty: u64 = 3;

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

// === PriceLevel ===

/// One price level's FIFO queue of resting orders, with an incrementally
/// maintained running total of `remaining_size` across every order in it —
/// kept correct by construction: every function in this module that can
/// change the order set or an order's `remaining_size` updates `total_size`
/// in the same call, and neither `orders` nor `Order.remaining_size` is
/// reachable from outside this module, so `total_size` can never drift.
public struct PriceLevel<phantom Base, phantom Quote> has store {
    orders: LinkedTable<u64, Order<Base, Quote>>,
    total_size: u64,
    /// Incrementally maintained running total of live `Quote` escrow
    /// (`order::escrow_quote_value`) across every order in this level —
    /// mirrors `total_size`'s exact structure and is kept correct at the
    /// same four mutation points (`level_insert_order`,
    /// `level_insert_order_front`, `level_remove_order`,
    /// `level_pop_front_order`). Meaningful for bid levels (where orders
    /// carry live `Quote` escrow); always `0` for ask levels, since an
    /// ask-side order's `escrow_quote_value` is always `0`.
    total_quote_escrow: u64,
}

public(package) fun new_price_level<Base, Quote>(ctx: &mut TxContext): PriceLevel<Base, Quote> {
    PriceLevel { orders: linked_table::new(ctx), total_size: 0, total_quote_escrow: 0 }
}

public(package) fun destroy_empty_price_level<Base, Quote>(level: PriceLevel<Base, Quote>) {
    let PriceLevel { orders, total_size, total_quote_escrow } = level;
    assert!(total_size == 0, EPriceLevelNotEmpty);
    assert!(total_quote_escrow == 0, EPriceLevelNotEmpty);
    orders.destroy_empty();
}

/// The maintained running total — O(1), replaces a linear-scan sum.
public(package) fun level_total_size<Base, Quote>(level: &PriceLevel<Base, Quote>): u64 {
    level.total_size
}

/// The maintained running total of live `Quote` escrow across every order
/// in this level — O(1), replaces a linear-scan sum. See
/// `PriceLevel.total_quote_escrow`'s doc comment.
public(package) fun level_total_quote_escrow<Base, Quote>(level: &PriceLevel<Base, Quote>): u64 {
    level.total_quote_escrow
}

public(package) fun level_is_empty<Base, Quote>(level: &PriceLevel<Base, Quote>): bool {
    level.orders.is_empty()
}

public(package) fun level_contains_order<Base, Quote>(level: &PriceLevel<Base, Quote>, order_id: u64): bool {
    level.orders.contains(order_id)
}

/// The order_id at the front of the FIFO queue, or none if empty.
public(package) fun level_front_order_id<Base, Quote>(level: &PriceLevel<Base, Quote>): Option<u64> {
    *level.orders.front()
}

public(package) fun level_borrow_order<Base, Quote>(level: &PriceLevel<Base, Quote>, order_id: u64): &Order<Base, Quote> {
    level.orders.borrow(order_id)
}

/// Inserts `order` into `level`'s FIFO queue and adds its `remaining_size`
/// to `level.total_size` in the same call. For brand-new orders being
/// rested for the first time — always correctly goes to the back.
public(package) fun level_insert_order<Base, Quote>(
    level: &mut PriceLevel<Base, Quote>,
    order_id: u64,
    order: Order<Base, Quote>,
) {
    level.total_size = level.total_size + order.remaining_size();
    level.total_quote_escrow = level.total_quote_escrow + order.escrow_quote_value();
    level.orders.push_back(order_id, order);
}

/// Re-inserts `order` at the FRONT of `level`'s FIFO queue — for putting a
/// still-partially-filled order back where it was, preserving its
/// price-time priority after being detached via `level_remove_order` for
/// mutation. NOT for brand-new orders (use `level_insert_order`, which
/// correctly goes to the back).
public(package) fun level_insert_order_front<Base, Quote>(
    level: &mut PriceLevel<Base, Quote>,
    order_id: u64,
    order: Order<Base, Quote>,
) {
    level.total_size = level.total_size + order.remaining_size();
    level.total_quote_escrow = level.total_quote_escrow + order.escrow_quote_value();
    level.orders.push_front(order_id, order);
}

/// Removes and returns the order at `order_id`, decrementing
/// `level.total_size` by its `remaining_size` in the same call. Aborts if
/// `order_id` isn't present (matches `linked_table::remove`'s own behavior
/// — callers must check `level_contains_order` first if they need a
/// non-aborting not-found path, exactly as the existing call sites already do).
public(package) fun level_remove_order<Base, Quote>(
    level: &mut PriceLevel<Base, Quote>,
    order_id: u64,
): Order<Base, Quote> {
    let order = level.orders.remove(order_id);
    level.total_size = level.total_size - order.remaining_size();
    level.total_quote_escrow = level.total_quote_escrow - order.escrow_quote_value();
    order
}

/// Pops the front order off the FIFO queue, decrementing `level.total_size`
/// by its `remaining_size` in the same call. Aborts if empty (matches
/// `linked_table::pop_front`'s own behavior — callers must check
/// `level_is_empty` first, exactly as the existing call sites already do).
public(package) fun level_pop_front_order<Base, Quote>(
    level: &mut PriceLevel<Base, Quote>,
): (u64, Order<Base, Quote>) {
    let (order_id, order) = level.orders.pop_front();
    level.total_size = level.total_size - order.remaining_size();
    level.total_quote_escrow = level.total_quote_escrow - order.escrow_quote_value();
    (order_id, order)
}

/// Overwrites the `owner` field of the order at `order_id` — does not
/// touch `remaining_size`/`total_size` at all, so no aggregate update needed.
public(package) fun level_set_order_owner<Base, Quote>(
    level: &mut PriceLevel<Base, Quote>,
    order_id: u64,
    new_owner: address,
) {
    level.orders.borrow_mut(order_id).set_owner(new_owner);
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
    internal_nodes.destroy_empty();
    leaves.destroy_empty();
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
        tree.leaves.borrow_mut(leaf_index_of(ptr)).parent = new_parent;
    } else {
        tree.internal_nodes.borrow_mut(ptr).parent = new_parent;
    }
}

fun descend_to_leaf<V: store>(tree: &PriceTree<V>, key: u64): u64 {
    let mut ptr = tree.root;
    while (!is_leaf_ptr(ptr)) {
        let node = tree.internal_nodes.borrow(ptr);
        ptr = if (key & node.mask == 0) node.left else node.right;
    };
    ptr
}

/// Descends from `start_ptr` (an internal-node or leaf pointer) always
/// taking the `left` (if `want_min`) or `right` child, until reaching a
/// leaf. If `start_ptr` is already a leaf pointer, the loop body never runs
/// and `start_ptr` is returned unchanged — correct, since a single leaf is
/// trivially its own min and max.
fun descend_extreme<V: store>(tree: &PriceTree<V>, start_ptr: u64, want_min: bool): u64 {
    let mut ptr = start_ptr;
    while (!is_leaf_ptr(ptr)) {
        let node = tree.internal_nodes.borrow(ptr);
        ptr = if (want_min) node.left else node.right;
    };
    ptr
}

// === Operations ===

/// Inserts `value` under `key`. Aborts with `EKeyAlreadyExists` if `key` is
/// already present — a second order resting at an already-present price
/// must be applied via `find` + `borrow_mut`, not a second `insert`.
///
/// Cost: a single root-to-leaf descent (O(log distinct_price_count) `Table`
/// reads), plus O(log distinct_price_count) `Table` writes. The
/// insertion-point search that used to be a second independent root-to-leaf
/// descent is now replayed from an in-memory record of the first descent's
/// path instead of touching `Table` again — see the comments below for why
/// that replay is always exactly a prefix of the first descent's path.
public fun insert<V: store>(tree: &mut PriceTree<V>, key: u64, value: V) {
    if (tree.root == EMPTY_TREE) {
        let leaf_idx = tree.next_leaf_index;
        tree.next_leaf_index = leaf_idx + 1;
        let leaf_ptr = encode_leaf_ptr(leaf_idx);
        tree.leaves.add(leaf_idx, Leaf { key, value, parent: NO_PARENT });
        tree.root = leaf_ptr;
        tree.min_leaf = leaf_ptr;
        tree.max_leaf = leaf_ptr;
        return
    };

    // Single descent: record every internal node visited (ptr + mask) so
    // the insertion-point search below can replay it from memory instead
    // of touching `tree.internal_nodes` a second time. Correct because both
    // this descent and the (replaced) insertion-point search descend using
    // the exact same rule (`key & node.mask == 0 ? left : right`) on the
    // exact same `key` — so the insertion-point search's path is always
    // exactly a prefix of this descent's path, by construction, regardless
    // of any ordering relationship between `new_mask` and the masks on the
    // path.
    let mut path_ptrs: vector<u64> = vector[];
    let mut path_masks: vector<u64> = vector[];
    let mut ptr = tree.root;
    while (!is_leaf_ptr(ptr)) {
        let node = tree.internal_nodes.borrow(ptr);
        path_ptrs.push_back(ptr);
        path_masks.push_back(node.mask);
        ptr = if (key & node.mask == 0) node.left else node.right;
    };
    let closest_ptr = ptr;
    let closest_leaf_idx = leaf_index_of(closest_ptr);
    let closest_key = tree.leaves.borrow(closest_leaf_idx).key;
    assert!(closest_key != key, EKeyAlreadyExists);

    let xor = closest_key ^ key;
    let new_mask = highest_set_bit_mask(xor);

    // Replay the recorded path in memory — no further `Table` reads —
    // reproducing exactly the original loop's semantics: for each
    // recorded node (in order), if its mask < new_mask, stop with
    // current_ptr = that node's own ptr and parent_ptr unchanged from the
    // previous iteration; otherwise advance parent_ptr to this node and
    // current_ptr to the NEXT recorded node (or closest_ptr, if this was
    // the last recorded node — i.e. the descent reached a leaf).
    let mut parent_ptr = NO_PARENT;
    let mut current_ptr = tree.root;
    let n = path_ptrs.length();
    let mut i = 0;
    while (i < n) {
        let node_mask = path_masks[i];
        if (node_mask < new_mask) {
            current_ptr = path_ptrs[i];
            break
        };
        parent_ptr = path_ptrs[i];
        current_ptr = if (i + 1 < n) path_ptrs[i + 1] else closest_ptr;
        i = i + 1;
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
    tree.internal_nodes.add(
        internal_idx,
        InternalNode { mask: new_mask, left, right, parent: parent_ptr },
    );
    tree.leaves.add(leaf_idx, Leaf { key, value, parent: internal_idx });

    set_parent(tree, current_ptr, internal_idx);

    if (parent_ptr == NO_PARENT) {
        tree.root = internal_idx;
    } else {
        let gp = tree.internal_nodes.borrow_mut(parent_ptr);
        if (gp.left == current_ptr) {
            gp.left = internal_idx;
        } else {
            gp.right = internal_idx;
        };
    };

    let min_key = tree.leaves.borrow(leaf_index_of(tree.min_leaf)).key;
    if (key < min_key) {
        tree.min_leaf = leaf_ptr;
    };
    let max_key = tree.leaves.borrow(leaf_index_of(tree.max_leaf)).key;
    if (key > max_key) {
        tree.max_leaf = leaf_ptr;
    };
}

/// Finds-or-creates the `PriceLevel` at `price` and inserts `order`
/// (keyed by `order_id`) into it, in a single atomic operation: one
/// root-to-leaf descent, then either an in-place mutation of the existing
/// level (found) or a replay of the recorded descent path to complete the
/// insertion (not found) — all within one continuous `&mut PriceTree`
/// borrow.
///
/// This replaces the old two-call `descend_probe` + `insert_at` pattern.
/// That pattern required threading a raw leaf pointer (the "hint") from
/// `descend_probe`'s result across the module boundary into a later,
/// separate `insert_at` call, relying on caller discipline (a documented
/// but runtime-unenforced trust contract) that the hint was fresh, from
/// this same tree, and for this same key. Because this function never
/// exposes that pointer outside of a single unbroken borrow of `tree`,
/// there is no gap in which a stale, foreign, or mismatched-key hint could
/// ever be passed — the class of bug is closed by construction, not by a
/// runtime check.
///
/// Cost: identical to plain `insert`'s — a single root-to-leaf descent,
/// with the insertion-point search (only reached on the not-found branch)
/// replayed in memory from the path recorded during that same descent, no
/// second `Table`-backed traversal. This is strictly cheaper than the old
/// `descend_probe` + `insert_at` split (which re-walked `internal_nodes`
/// via `Table` reads a second time for its insertion-point search, since it
/// had no recorded path to replay), and strictly cheaper than a naive
/// `find` + `insert` pattern (three descents: one inside `find`, discarded
/// on a miss, plus `insert`'s own two).
public(package) fun insert_or_append_order<Base, Quote>(
    tree: &mut PriceTree<PriceLevel<Base, Quote>>,
    price: u64,
    order_id: u64,
    order: Order<Base, Quote>,
    ctx: &mut TxContext,
) {
    if (tree.root == EMPTY_TREE) {
        let mut level = new_price_level<Base, Quote>(ctx);
        level_insert_order(&mut level, order_id, order);
        insert(tree, price, level);
        return
    };

    // Single descent, recording the path exactly like `insert` does, so the
    // insertion-point search below (only reached on the not-found branch)
    // can replay it from memory instead of touching `Table` a second time.
    let mut path_ptrs: vector<u64> = vector[];
    let mut path_masks: vector<u64> = vector[];
    let mut ptr = tree.root;
    while (!is_leaf_ptr(ptr)) {
        let node = tree.internal_nodes.borrow(ptr);
        path_ptrs.push_back(ptr);
        path_masks.push_back(node.mask);
        ptr = if (price & node.mask == 0) node.left else node.right;
    };
    let closest_ptr = ptr;
    let closest_leaf_idx = leaf_index_of(closest_ptr);
    let closest_key = tree.leaves.borrow(closest_leaf_idx).key;

    if (closest_key == price) {
        // Found — insert into the existing level, no further tree traversal.
        let leaf = tree.leaves.borrow_mut(closest_leaf_idx);
        level_insert_order(&mut leaf.value, order_id, order);
        return
    };

    // Not found — complete the insertion at the point this single descent
    // already found, replaying the recorded path in memory for the
    // insertion-point search exactly like `insert` does.
    let xor = closest_key ^ price;
    let new_mask = highest_set_bit_mask(xor);

    let mut parent_ptr = NO_PARENT;
    let mut current_ptr = tree.root;
    let n = path_ptrs.length();
    let mut i = 0;
    while (i < n) {
        let node_mask = path_masks[i];
        if (node_mask < new_mask) {
            current_ptr = path_ptrs[i];
            break
        };
        parent_ptr = path_ptrs[i];
        current_ptr = if (i + 1 < n) path_ptrs[i + 1] else closest_ptr;
        i = i + 1;
    };

    let mut level = new_price_level<Base, Quote>(ctx);
    level_insert_order(&mut level, order_id, order);

    let leaf_idx = tree.next_leaf_index;
    tree.next_leaf_index = leaf_idx + 1;
    let leaf_ptr = encode_leaf_ptr(leaf_idx);

    let internal_idx = tree.next_internal_index;
    tree.next_internal_index = internal_idx + 1;

    let (left, right) = if (price & new_mask == 0) {
        (leaf_ptr, current_ptr)
    } else {
        (current_ptr, leaf_ptr)
    };
    tree.internal_nodes.add(
        internal_idx,
        InternalNode { mask: new_mask, left, right, parent: parent_ptr },
    );
    tree.leaves.add(leaf_idx, Leaf { key: price, value: level, parent: internal_idx });

    set_parent(tree, current_ptr, internal_idx);

    if (parent_ptr == NO_PARENT) {
        tree.root = internal_idx;
    } else {
        let gp = tree.internal_nodes.borrow_mut(parent_ptr);
        if (gp.left == current_ptr) {
            gp.left = internal_idx;
        } else {
            gp.right = internal_idx;
        };
    };

    let min_key = tree.leaves.borrow(leaf_index_of(tree.min_leaf)).key;
    if (price < min_key) {
        tree.min_leaf = leaf_ptr;
    };
    let max_key = tree.leaves.borrow(leaf_index_of(tree.max_leaf)).key;
    if (price > max_key) {
        tree.max_leaf = leaf_ptr;
    };
}

/// Finds the price level at `price`, and if it contains `order_id`, removes
/// and returns that order — cleaning up the price level's leaf from the
/// tree if removing the order leaves it empty. Returns `option::none()` if
/// the price level doesn't exist, or exists but doesn't contain `order_id`
/// (in the latter case, the level is left untouched — a `PriceLevel`
/// present in the tree always holds at least one order, since every
/// creation path inserts an order in the same call that creates it and
/// every removal path cleans up an emptied level in the same call that
/// empties it, so "found but this specific order_id isn't in it" never
/// implies the level itself needs cleanup).
public(package) fun find_and_remove_order<Base, Quote>(
    tree: &mut PriceTree<PriceLevel<Base, Quote>>,
    price: u64,
    order_id: u64,
): Option<Order<Base, Quote>> {
    let leaf_opt = tree.find(price);
    if (leaf_opt.is_none()) {
        return option::none()
    };
    let leaf_ptr = leaf_opt.destroy_some();

    let (found, order_opt, level_now_empty) = {
        let level = tree.borrow_mut(leaf_ptr);
        if (level.level_contains_order(order_id)) {
            let order = level.level_remove_order(order_id);
            (true, option::some(order), level.level_is_empty())
        } else {
            (false, option::none(), level.level_is_empty())
        }
    };
    if (found && level_now_empty) {
        let removed = tree.remove(leaf_ptr);
        removed.destroy_empty_price_level();
    };
    order_opt
}

/// Removes and returns the leaf's value. `leaf_ptr` is a leaf pointer as
/// returned by `find`/`min_leaf`/`max_leaf` (not a raw price key).
///
/// Cost: O(log distinct_price_count).
public fun remove<V: store>(tree: &mut PriceTree<V>, leaf_ptr: u64): V {
    assert!(is_leaf_ptr(leaf_ptr) && leaf_ptr != NO_PARENT, EInvalidLeafPtr);
    let leaf_idx = leaf_index_of(leaf_ptr);
    let Leaf { key: _, value, parent } = tree.leaves.remove(leaf_idx);

    if (parent == NO_PARENT) {
        // The removed leaf was the tree's only leaf.
        tree.root = EMPTY_TREE;
        tree.min_leaf = EMPTY_TREE;
        tree.max_leaf = EMPTY_TREE;
        return value
    };

    let InternalNode { mask: _, left, right, parent: grandparent } =
        tree.internal_nodes.remove(parent);
    let sibling_ptr = if (left == leaf_ptr) right else left;

    set_parent(tree, sibling_ptr, grandparent);

    if (grandparent == NO_PARENT) {
        tree.root = sibling_ptr;
    } else {
        let gp = tree.internal_nodes.borrow_mut(grandparent);
        if (gp.left == parent) {
            gp.left = sibling_ptr;
        } else {
            gp.right = sibling_ptr;
        };
    };

    // `sibling_ptr` is the subtree that replaces the removed leaf's parent;
    // when the removed leaf WAS the tracked extreme, its sibling subtree
    // provably contains the new extreme, so descend from there rather than
    // re-descending the whole tree from `tree.root`.
    if (leaf_ptr == tree.min_leaf) {
        tree.min_leaf = descend_extreme(tree, sibling_ptr, true);
    };
    if (leaf_ptr == tree.max_leaf) {
        tree.max_leaf = descend_extreme(tree, sibling_ptr, false);
    };

    value
}

/// Returns the leaf pointer for `key` if present.
public fun find<V: store>(tree: &PriceTree<V>, key: u64): Option<u64> {
    if (tree.root == EMPTY_TREE) {
        return option::none()
    };
    let ptr = descend_to_leaf(tree, key);
    let leaf = tree.leaves.borrow(leaf_index_of(ptr));
    if (leaf.key == key) option::some(ptr) else option::none()
}

public fun borrow<V: store>(tree: &PriceTree<V>, leaf_ptr: u64): &V {
    assert!(is_leaf_ptr(leaf_ptr) && leaf_ptr != NO_PARENT, EInvalidLeafPtr);
    &tree.leaves.borrow(leaf_index_of(leaf_ptr)).value
}

/// Returns the price `key` a leaf pointer (as returned by `find`/
/// `min_leaf`/`max_leaf`) was inserted under.
public fun key<V: store>(tree: &PriceTree<V>, leaf_ptr: u64): u64 {
    assert!(is_leaf_ptr(leaf_ptr) && leaf_ptr != NO_PARENT, EInvalidLeafPtr);
    tree.leaves.borrow(leaf_index_of(leaf_ptr)).key
}

public fun borrow_mut<V: store>(tree: &mut PriceTree<V>, leaf_ptr: u64): &mut V {
    assert!(is_leaf_ptr(leaf_ptr) && leaf_ptr != NO_PARENT, EInvalidLeafPtr);
    &mut tree.leaves.borrow_mut(leaf_index_of(leaf_ptr)).value
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
    tree.leaves.length()
}

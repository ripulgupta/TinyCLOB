# TinyCLOB — Security Review

Went through the full codebase: `tiny_clob.move` (4,600+ lines), `order.move`, `price_tree.move`, and all 19 test files. Focused on fund-extraction paths from an unprivileged attacker.

No critical or high-severity issues found. The code is unusually well-defended — rounding direction choices, fee-settlement logic, and the escrow model all hold up under adversarial analysis. Details below.

---

## What I checked

Traced every path where money enters or leaves the protocol. 14 exit points total — 8 return to the caller, 4 transfer to the stored owner, 2 return to admin (ClobAdminCap required). Every balance movement uses `split`/`join` only — no minting, no raw arithmetic on amounts.

Attack angles tested:

| Angle | Result |
|-------|--------|
| Cancel order returns more than escrowed | No — escrow + proceeds merged, no creation |
| Claim someone else's proceeds | No — requires OrderTicket (no `copy`, no `key`) |
| Fee rounding creates extractable surplus | Theoretically yes (ceil superadditivity), economically no — max fee is 10 bps, surplus per fill is < 1 atom, gas cost exceeds any possible extraction |
| Self-cross to generate money | No — just swaps base↔quote and pays fees |
| set_last_price manipulation for fund theft | No — bounded by best_bid/best_ask when orders exist, griefing only (already documented in your comments) |
| Admin drain_step steals user funds | No — escrow goes to order.owner(), admin only gets fee_accumulator |
| Destroy orphaned ticket for double claim | No — aborts if proceeds exist or order still resting |
| Market order at any price | By design — budget constraint and min_base_out/min_quote_out prevent overspending |
| Race condition between update_resting_order and fill | No — Sui's &mut borrow rules prevent same-PTB overlap |
| Partial fill leaves order underfunded | No — bid-side uses cumulative proportional ceiling (telescoping), ask-side uses floor+conclude |
| admin_redeem_ticket sends funds to admin | No — escrow to owner, proceeds to proceeds_owner |
| OrderTicket transferred to attacker | By design — ticket possession IS authority, same as holding a Coin |
| FIFO ordering manipulation | No — new orders append, partial fills re-insert at front |
| Overflow in bid_escrow_amount or quote_cost | No — u128 intermediate, u64 narrowing aborts on overflow (DoS, not drain) |

---

## Rounding design (worth noting, not a finding)

The bid-side and ask-side matching use different rounding strategies for the same problem (preventing ceil superadditivity from exhausting escrow before full delivery):

**Ask-side makers** (fill_level_bid): per-fill floor for full-drain fills, ceil for partial. Accumulated ceil fee goes to `fee_reserve`, then `conclude_order_fee` settles the correct total and returns slack to maker.

**Bid-side makers** (fill_level_ask): cumulative proportional ceiling — `target_charge = ceil(total_reserved × cumulative_filled / original_size)`, with per-fill cost = target_charge − already_charged. Telescopes to exactly `total_reserved` on full drain.

Both conserve money. The asymmetry is a design choice, not a bug. The bid-side approach is cleaner (no slack to settle), but the ask-side approach works correctly with the conclude mechanism.

---

## Low/informational

**Shared abort codes (9 instances):** `EZeroPrice` used in 4 functions, `EWrongBook` in 7, `EBookPaused` in 4, etc. When a transaction aborts, the caller sees the module + error code but can't distinguish which function threw it. Not a security issue — makes debugging harder.

**set_last_price griefing:** Your comments already document the pin attack (resting a min_size order to lock the price band). The escape hatch via market order works. One gap: a naive integrator that only places limit orders won't know to use a market order as the fix — but you noted this too.

---

## What I didn't check

- Off-chain integration (keepers, indexers, UI)
- The enclosing object that wraps OrderBook + ClobAdminCap — security depends on how the integrator exposes these
- Gas/compute DoS (intentionally out of scope for this review)
- Formal verification of the rounding invariants

---

## Summary

14 attack angles, every money-movement path traced line by line. No way to extract funds without the corresponding OrderTicket or ClobAdminCap. The fee math is correct under fragmented fills, the escrow model prevents overspending, and the admin paths send user funds to users (not to admin).

The `set_last_price` griefing vector exists but is already documented and does not touch funds.

This is a clean codebase. If you make changes to the matching logic or fee model in the future, the rounding invariants (especially the bid/ask asymmetry) are the area most likely to break — worth re-reviewing after any change there.

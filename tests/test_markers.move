/// Minimal test-only marker types for `tests/embedded_market_tests.move`.
///
/// In the original `TenorCLOB` (`tiny_clob`) package, `BTC`/`USDC` are
/// defined in `tests/test_utils.move`, a shared wrapper-layer fixture
/// module that also pulls in `tiny_clob::admin` and `tiny_clob::market`
/// (registry/global-admin setup helpers) — none of which exist in this
/// standalone core package. `tests/embedded_market_tests.move` only ever
/// used `test_utils` for these two zero-field marker types (as `Base`/
/// `Quote` type parameters; `embedded_market::new` never touches real
/// coin/balance machinery, so no real `Coin<T>` is needed), so this file
/// exists solely to provide that narrow slice without dragging in the
/// wrapper-layer dependency. Definitions copied verbatim from
/// `TenorCLOB/tests/test_utils.move`.
#[test_only]
module tiny_clob::test_markers;

public struct BTC has drop {}
public struct USDC has drop {}

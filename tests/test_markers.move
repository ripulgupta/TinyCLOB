/// Minimal zero-field marker types used as `Base`/`Quote` type parameters
/// throughout this package's test suite.
#[test_only]
module tiny_clob::test_markers;

public struct BTC has drop {}
public struct USDC has drop {}
public struct SUI has drop {}
public struct WAL has drop {}

/// SplitMix64 (Steele, Lea and Flood): a tiny, fast, fully specified PRNG.
///
/// The shuffle must produce the same order in the app and the widget, on every OS version, so it
/// uses this instead of `SystemRandomNumberGenerator` or the standard library's shuffle algorithms,
/// whose implementations may change.
public struct SplitMix64: RandomNumberGenerator, Hashable, Sendable {
    /// The current state. The next output depends only on this.
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<bound` by plain modulo reduction (the bias is negligible for small bounds).
    public mutating func nextIndex(below bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return Int(next() % UInt64(bound))
    }

    /// A Fisher–Yates permutation of `0..<count` determined only by `seed`.
    public static func permutation(count: Int, seed: UInt64) -> [Int] {
        guard count > 0 else { return [] }
        var result = Array(0..<count)
        var generator = SplitMix64(seed: seed)
        var index = count - 1
        while index > 0 {
            let other = generator.nextIndex(below: index + 1)
            result.swapAt(index, other)
            index -= 1
        }
        return result
    }
}

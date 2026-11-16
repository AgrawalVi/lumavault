extension Sequence where Element == UInt8 {
    /// Lowercase hex, the form the gateway uses for SHA-256 digests.
    var lowercaseHex: String {
        map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }
}

extension String {
    /// The text of a C buffer up to its first NUL, decoded as UTF-8 (invalid bytes become U+FFFD).
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

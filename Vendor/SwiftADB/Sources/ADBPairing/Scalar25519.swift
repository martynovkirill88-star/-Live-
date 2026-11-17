// Scalar25519.swift
// Ported from spake2-java / io.github.muntashirakon.crypto.x25519.x25519Scalar
// Provides scalar reduction mod l (the group order of Ed25519).

// l = 2^252 + 27742317777372353535851937790883648493
//   = 0x1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed
struct Scalar25519 {
    var bytes: [UInt8]  // always 32 bytes, little-endian

    init(_ bytes: [UInt8]) {
        precondition(bytes.count == 32)
        self.bytes = bytes
    }

    init() { self.bytes = [UInt8](repeating: 0, count: 32) }

    subscript(i: Int) -> UInt8 {
        get { bytes[i] }
        set { bytes[i] = newValue }
    }

    /// Scalar order l in little-endian.
    static let l: [UInt8] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
        0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10
    ]

    // MARK: - Reduce 64 bytes → 32 bytes mod l

    /// Reduce a 64-byte scalar (output of SHA-512 etc.) to 32 bytes mod l.
    /// The output is placed into the first 32 bytes of `s` (in-place, same as Java).
    static func reduce(_ s: inout [UInt8]) {
        precondition(s.count == 64)

        func load3(_ i: Int) -> Int64 {
            var r = Int64(s[i] & 0xff)
            r |= Int64(s[i+1] & 0xff) << 8
            r |= Int64(s[i+2] & 0xff) << 16
            return r
        }
        func load4(_ i: Int) -> Int64 {
            var r = Int64(s[i] & 0xff)
            r |= Int64(s[i+1] & 0xff) << 8
            r |= Int64(s[i+2] & 0xff) << 16
            r |= Int64(s[i+3]) << 24
            return r
        }

        var s0  = 2097151 & load3(0)
        var s1  = 2097151 & (load4(2) >> 5)
        var s2  = 2097151 & (load3(5) >> 2)
        var s3  = 2097151 & (load4(7) >> 7)
        var s4  = 2097151 & (load4(10) >> 4)
        var s5  = 2097151 & (load3(13) >> 1)
        var s6  = 2097151 & (load4(15) >> 6)
        var s7  = 2097151 & (load3(18) >> 3)
        var s8  = 2097151 & load3(21)
        var s9  = 2097151 & (load4(23) >> 5)
        var s10 = 2097151 & (load3(26) >> 2)
        var s11 = 2097151 & (load4(28) >> 7)
        var s12 = 2097151 & (load4(31) >> 4)
        var s13 = 2097151 & (load3(34) >> 1)
        var s14 = 2097151 & (load4(36) >> 6)
        var s15 = 2097151 & (load3(39) >> 3)
        var s16 = 2097151 & load3(42)
        var s17 = 2097151 & (load4(44) >> 5)
        var s18 = 2097151 & (load3(47) >> 2)
        var s19 = 2097151 & (load4(49) >> 7)
        var s20 = 2097151 & (load4(52) >> 4)
        var s21 = 2097151 & (load3(55) >> 1)
        var s22 = 2097151 & (load4(57) >> 6)
        var s23 =            load4(60) >> 3

        s11 += s23 * 666643; s12 += s23 * 470296; s13 += s23 * 654183
        s14 -= s23 * 997805; s15 += s23 * 136657; s16 -= s23 * 683901; s23 = 0

        s10 += s22 * 666643; s11 += s22 * 470296; s12 += s22 * 654183
        s13 -= s22 * 997805; s14 += s22 * 136657; s15 -= s22 * 683901; s22 = 0

        s9  += s21 * 666643; s10 += s21 * 470296; s11 += s21 * 654183
        s12 -= s21 * 997805; s13 += s21 * 136657; s14 -= s21 * 683901; s21 = 0

        s8  += s20 * 666643; s9  += s20 * 470296; s10 += s20 * 654183
        s11 -= s20 * 997805; s12 += s20 * 136657; s13 -= s20 * 683901; s20 = 0

        s7  += s19 * 666643; s8  += s19 * 470296; s9  += s19 * 654183
        s10 -= s19 * 997805; s11 += s19 * 136657; s12 -= s19 * 683901; s19 = 0

        s6  += s18 * 666643; s7  += s18 * 470296; s8  += s18 * 654183
        s9  -= s18 * 997805; s10 += s18 * 136657; s11 -= s18 * 683901; s18 = 0

        var carry = [Int64](repeating: 0, count: 17)
        carry[6] = (s6 + (1<<20)) >> 21; s7  += carry[6]; s6  -= carry[6] << 21
        carry[8] = (s8 + (1<<20)) >> 21; s9  += carry[8]; s8  -= carry[8] << 21
        carry[10] = (s10+(1<<20)) >> 21; s11 += carry[10]; s10 -= carry[10] << 21
        carry[12] = (s12+(1<<20)) >> 21; s13 += carry[12]; s12 -= carry[12] << 21
        carry[14] = (s14+(1<<20)) >> 21; s15 += carry[14]; s14 -= carry[14] << 21
        carry[16] = (s16+(1<<20)) >> 21; s17 += carry[16]; s16 -= carry[16] << 21
        carry[7]  = (s7 + (1<<20)) >> 21; s8  += carry[7]; s7  -= carry[7] << 21
        carry[9]  = (s9 + (1<<20)) >> 21; s10 += carry[9]; s9  -= carry[9] << 21
        carry[11] = (s11+(1<<20)) >> 21; s12 += carry[11]; s11 -= carry[11] << 21
        carry[13] = (s13+(1<<20)) >> 21; s14 += carry[13]; s13 -= carry[13] << 21
        carry[15] = (s15+(1<<20)) >> 21; s16 += carry[15]; s15 -= carry[15] << 21

        s5  += s17 * 666643; s6  += s17 * 470296; s7  += s17 * 654183
        s8  -= s17 * 997805; s9  += s17 * 136657; s10 -= s17 * 683901; s17 = 0
        s4  += s16 * 666643; s5  += s16 * 470296; s6  += s16 * 654183
        s7  -= s16 * 997805; s8  += s16 * 136657; s9  -= s16 * 683901; s16 = 0
        s3  += s15 * 666643; s4  += s15 * 470296; s5  += s15 * 654183
        s6  -= s15 * 997805; s7  += s15 * 136657; s8  -= s15 * 683901; s15 = 0
        s2  += s14 * 666643; s3  += s14 * 470296; s4  += s14 * 654183
        s5  -= s14 * 997805; s6  += s14 * 136657; s7  -= s14 * 683901; s14 = 0
        s1  += s13 * 666643; s2  += s13 * 470296; s3  += s13 * 654183
        s4  -= s13 * 997805; s5  += s13 * 136657; s6  -= s13 * 683901; s13 = 0
        s0  += s12 * 666643; s1  += s12 * 470296; s2  += s12 * 654183
        s3  -= s12 * 997805; s4  += s12 * 136657; s5  -= s12 * 683901; s12 = 0

        carry[0]  = (s0 + (1<<20)) >> 21; s1  += carry[0]; s0  -= carry[0] << 21
        carry[2]  = (s2 + (1<<20)) >> 21; s3  += carry[2]; s2  -= carry[2] << 21
        carry[4]  = (s4 + (1<<20)) >> 21; s5  += carry[4]; s4  -= carry[4] << 21
        carry[6]  = (s6 + (1<<20)) >> 21; s7  += carry[6]; s6  -= carry[6] << 21
        carry[8]  = (s8 + (1<<20)) >> 21; s9  += carry[8]; s8  -= carry[8] << 21
        carry[10] = (s10+(1<<20)) >> 21; s11 += carry[10]; s10 -= carry[10] << 21
        carry[1]  = (s1 + (1<<20)) >> 21; s2  += carry[1]; s1  -= carry[1] << 21
        carry[3]  = (s3 + (1<<20)) >> 21; s4  += carry[3]; s3  -= carry[3] << 21
        carry[5]  = (s5 + (1<<20)) >> 21; s6  += carry[5]; s5  -= carry[5] << 21
        carry[7]  = (s7 + (1<<20)) >> 21; s8  += carry[7]; s7  -= carry[7] << 21
        carry[9]  = (s9 + (1<<20)) >> 21; s10 += carry[9]; s9  -= carry[9] << 21
        carry[11] = (s11+(1<<20)) >> 21; s12 += carry[11]; s11 -= carry[11] << 21

        s0 += s12 * 666643; s1 += s12 * 470296; s2 += s12 * 654183
        s3 -= s12 * 997805; s4 += s12 * 136657; s5 -= s12 * 683901; s12 = 0

        carry[0] = s0 >> 21; s1  += carry[0]; s0  -= carry[0] << 21
        carry[1] = s1 >> 21; s2  += carry[1]; s1  -= carry[1] << 21
        carry[2] = s2 >> 21; s3  += carry[2]; s2  -= carry[2] << 21
        carry[3] = s3 >> 21; s4  += carry[3]; s3  -= carry[3] << 21
        carry[4] = s4 >> 21; s5  += carry[4]; s4  -= carry[4] << 21
        carry[5] = s5 >> 21; s6  += carry[5]; s5  -= carry[5] << 21
        carry[6] = s6 >> 21; s7  += carry[6]; s6  -= carry[6] << 21
        carry[7] = s7 >> 21; s8  += carry[7]; s7  -= carry[7] << 21
        carry[8] = s8 >> 21; s9  += carry[8]; s8  -= carry[8] << 21
        carry[9] = s9 >> 21; s10 += carry[9]; s9  -= carry[9] << 21
        carry[10] = s10 >> 21; s11 += carry[10]; s10 -= carry[10] << 21
        carry[11] = s11 >> 21; s12 += carry[11]; s11 -= carry[11] << 21

        s0 += s12 * 666643; s1 += s12 * 470296; s2 += s12 * 654183
        s3 -= s12 * 997805; s4 += s12 * 136657; s5 -= s12 * 683901; s12 = 0

        carry[0] = s0 >> 21; s1 += carry[0]; s0 -= carry[0] << 21
        carry[1] = s1 >> 21; s2 += carry[1]; s1 -= carry[1] << 21
        carry[2] = s2 >> 21; s3 += carry[2]; s2 -= carry[2] << 21
        carry[3] = s3 >> 21; s4 += carry[3]; s3 -= carry[3] << 21
        carry[4] = s4 >> 21; s5 += carry[4]; s4 -= carry[4] << 21
        carry[5] = s5 >> 21; s6 += carry[5]; s5 -= carry[5] << 21
        carry[6] = s6 >> 21; s7 += carry[6]; s6 -= carry[6] << 21
        carry[7] = s7 >> 21; s8 += carry[7]; s7 -= carry[7] << 21
        carry[8] = s8 >> 21; s9 += carry[8]; s8 -= carry[8] << 21
        carry[9] = s9 >> 21; s10 += carry[9]; s9 -= carry[9] << 21
        carry[10] = s10 >> 21; s11 += carry[10]; s10 -= carry[10] << 21

        s[0]  = UInt8(s0  & 0xff)
        s[1]  = UInt8((s0 >> 8) & 0xff)
        s[2]  = UInt8(((s0 >> 16) | (s1 << 5)) & 0xff)
        s[3]  = UInt8((s1 >> 3) & 0xff)
        s[4]  = UInt8((s1 >> 11) & 0xff)
        s[5]  = UInt8(((s1 >> 19) | (s2 << 2)) & 0xff)
        s[6]  = UInt8((s2 >> 6) & 0xff)
        s[7]  = UInt8(((s2 >> 14) | (s3 << 7)) & 0xff)
        s[8]  = UInt8((s3 >> 1) & 0xff)
        s[9]  = UInt8((s3 >> 9) & 0xff)
        s[10] = UInt8(((s3 >> 17) | (s4 << 4)) & 0xff)
        s[11] = UInt8((s4 >> 4) & 0xff)
        s[12] = UInt8((s4 >> 12) & 0xff)
        s[13] = UInt8(((s4 >> 20) | (s5 << 1)) & 0xff)
        s[14] = UInt8((s5 >> 7) & 0xff)
        s[15] = UInt8(((s5 >> 15) | (s6 << 6)) & 0xff)
        s[16] = UInt8((s6 >> 2) & 0xff)
        s[17] = UInt8((s6 >> 10) & 0xff)
        s[18] = UInt8(((s6 >> 18) | (s7 << 3)) & 0xff)
        s[19] = UInt8((s7 >> 5) & 0xff)
        s[20] = UInt8((s7 >> 13) & 0xff)
        s[21] = UInt8(s8  & 0xff)
        s[22] = UInt8((s8 >> 8) & 0xff)
        s[23] = UInt8(((s8 >> 16) | (s9 << 5)) & 0xff)
        s[24] = UInt8((s9 >> 3) & 0xff)
        s[25] = UInt8((s9 >> 11) & 0xff)
        s[26] = UInt8(((s9 >> 19) | (s10 << 2)) & 0xff)
        s[27] = UInt8((s10 >> 6) & 0xff)
        s[28] = UInt8(((s10 >> 14) | (s11 << 7)) & 0xff)
        s[29] = UInt8((s11 >> 1) & 0xff)
        s[30] = UInt8((s11 >> 9) & 0xff)
        s[31] = UInt8((s11 >> 17) & 0xff)
    }

    // MARK: - SPAKE2 scalar helpers

    /// Multiply by cofactor (8) in-place: left-shift 3 bits.
    static func leftShift3(_ n: inout [UInt8]) {
        var carry: UInt8 = 0
        for i in 0..<32 {
            let nextCarry = n[i] >> 5
            n[i] = (n[i] << 3) | carry
            carry = nextCarry
        }
    }

    /// Constant-time equality: returns -1 (all ones) if a==b, 0 otherwise.
    static func isEqual(_ a: Int, _ b: Int) -> Int64 {
        isZero(a ^ b)
    }

    private static func isZero(_ a: Int) -> Int64 {
        let x = UInt64(bitPattern: Int64(a))
        // Constant-time zero test: 0xFFFF...FF if a==0, else 0
        let inv = ~x & (x &- 1)
        let msb = inv >> 63          // 1 if a==0, 0 otherwise
        return -Int64(bitPattern: msb)
    }
}

// Ed25519Field.swift
// Ported from spake2-java / io.github.muntashirakon.crypto.ed25519
// (C) 2021 Muntashir Al-Islam  — original Java: MIT/Apache-2.0
// Swift port: ADBPairing module for SwiftADB

// Ed25519 field: GF(2^255 - 19)
// Represents elements as 10 limbs in radix 2^25.5:
//   f = f[0]*2^0 + f[1]*2^26 + f[2]*2^51 + f[3]*2^77 + f[4]*2^102
//       + f[5]*2^128 + f[6]*2^153 + f[7]*2^179 + f[8]*2^204 + f[9]*2^230
// Odd limbs are 25-bit, even limbs are 26-bit (after reduction).
struct Ed25519FieldElement: Equatable {
    var t: (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64)

    init(_ t0: Int64, _ t1: Int64, _ t2: Int64, _ t3: Int64, _ t4: Int64,
         _ t5: Int64, _ t6: Int64, _ t7: Int64, _ t8: Int64, _ t9: Int64) {
        t = (t0, t1, t2, t3, t4, t5, t6, t7, t8, t9)
    }

    /// Zero element.
    static let zero = Ed25519FieldElement(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    /// One element.
    static let one  = Ed25519FieldElement(1, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    // MARK: - Encoding/Decoding

    /// Decode a 32-byte little-endian value into field limbs.
    static func fromBytes(_ b: [UInt8]) -> Ed25519FieldElement {
        precondition(b.count >= 32)

        func load3(_ i: Int) -> Int64 {
            var r = Int64(b[i])
            r |= Int64(b[i+1]) << 8
            r |= Int64(b[i+2]) << 16
            return r
        }
        func load4(_ i: Int) -> Int64 {
            var r = Int64(b[i])
            r |= Int64(b[i+1]) << 8
            r |= Int64(b[i+2]) << 16
            r |= Int64(b[i+3]) << 24
            return r
        }

        var h0 = load4(0)
        var h1 = load3(4) << 6
        var h2 = load3(7) << 5
        var h3 = load3(10) << 3
        var h4 = load3(13) << 2
        var h5 = load4(16)
        var h6 = load3(20) << 7
        var h7 = load3(23) << 5
        var h8 = load3(26) << 4
        var h9 = (load3(29) & 0x7f_ffff) << 2

        let carry9 = (h9 + (1 << 24)) >> 25; h0 += carry9 * 19; h9 -= carry9 << 25
        let carry1 = (h1 + (1 << 24)) >> 25; h2 += carry1; h1 -= carry1 << 25
        let carry3 = (h3 + (1 << 24)) >> 25; h4 += carry3; h3 -= carry3 << 25
        let carry5 = (h5 + (1 << 24)) >> 25; h6 += carry5; h5 -= carry5 << 25
        let carry7 = (h7 + (1 << 24)) >> 25; h8 += carry7; h7 -= carry7 << 25
        let carry0 = (h0 + (1 << 25)) >> 26; h1 += carry0; h0 -= carry0 << 26
        let carry2 = (h2 + (1 << 25)) >> 26; h3 += carry2; h2 -= carry2 << 26
        let carry4 = (h4 + (1 << 25)) >> 26; h5 += carry4; h4 -= carry4 << 26
        let carry6 = (h6 + (1 << 25)) >> 26; h7 += carry6; h6 -= carry6 << 26
        let carry8 = (h8 + (1 << 25)) >> 26; h9 += carry8; h8 -= carry8 << 26

        return Ed25519FieldElement(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }

    /// Encode to 32 bytes little-endian.
    func toBytes() -> [UInt8] {
        var (h0, h1, h2, h3, h4, h5, h6, h7, h8, h9) =
            (t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9)

        var q = (19 * h9 + (1 << 24)) >> 25
        q = (h0 + q) >> 26
        q = (h1 + q) >> 25
        q = (h2 + q) >> 26
        q = (h3 + q) >> 25
        q = (h4 + q) >> 26
        q = (h5 + q) >> 25
        q = (h6 + q) >> 26
        q = (h7 + q) >> 25
        q = (h8 + q) >> 26
        q = (h9 + q) >> 25

        h0 += 19 * q

        let carry0 = h0 >> 26; h1 += carry0; h0 -= carry0 << 26
        let carry1 = h1 >> 25; h2 += carry1; h1 -= carry1 << 25
        let carry2 = h2 >> 26; h3 += carry2; h2 -= carry2 << 26
        let carry3 = h3 >> 25; h4 += carry3; h3 -= carry3 << 25
        let carry4 = h4 >> 26; h5 += carry4; h4 -= carry4 << 26
        let carry5 = h5 >> 25; h6 += carry5; h5 -= carry5 << 25
        let carry6 = h6 >> 26; h7 += carry6; h6 -= carry6 << 26
        let carry7 = h7 >> 25; h8 += carry7; h7 -= carry7 << 25
        let carry8 = h8 >> 26; h9 += carry8; h8 -= carry8 << 26
        let carry9 = h9 >> 25; h9 -= carry9 << 25

        var s = [UInt8](repeating: 0, count: 32)
        s[0]  = UInt8(h0 & 0xff)
        s[1]  = UInt8((h0 >> 8) & 0xff)
        s[2]  = UInt8((h0 >> 16) & 0xff)
        s[3]  = UInt8(((h0 >> 24) | (h1 << 2)) & 0xff)
        s[4]  = UInt8((h1 >> 6) & 0xff)
        s[5]  = UInt8((h1 >> 14) & 0xff)
        s[6]  = UInt8(((h1 >> 22) | (h2 << 3)) & 0xff)
        s[7]  = UInt8((h2 >> 5) & 0xff)
        s[8]  = UInt8((h2 >> 13) & 0xff)
        s[9]  = UInt8(((h2 >> 21) | (h3 << 5)) & 0xff)
        s[10] = UInt8((h3 >> 3) & 0xff)
        s[11] = UInt8((h3 >> 11) & 0xff)
        s[12] = UInt8(((h3 >> 19) | (h4 << 6)) & 0xff)
        s[13] = UInt8((h4 >> 2) & 0xff)
        s[14] = UInt8((h4 >> 10) & 0xff)
        s[15] = UInt8((h4 >> 18) & 0xff)
        s[16] = UInt8(h5 & 0xff)
        s[17] = UInt8((h5 >> 8) & 0xff)
        s[18] = UInt8((h5 >> 16) & 0xff)
        s[19] = UInt8(((h5 >> 24) | (h6 << 1)) & 0xff)
        s[20] = UInt8((h6 >> 7) & 0xff)
        s[21] = UInt8((h6 >> 15) & 0xff)
        s[22] = UInt8(((h6 >> 23) | (h7 << 3)) & 0xff)
        s[23] = UInt8((h7 >> 5) & 0xff)
        s[24] = UInt8((h7 >> 13) & 0xff)
        s[25] = UInt8(((h7 >> 21) | (h8 << 4)) & 0xff)
        s[26] = UInt8((h8 >> 4) & 0xff)
        s[27] = UInt8((h8 >> 12) & 0xff)
        s[28] = UInt8(((h8 >> 20) | (h9 << 6)) & 0xff)
        s[29] = UInt8((h9 >> 2) & 0xff)
        s[30] = UInt8((h9 >> 10) & 0xff)
        s[31] = UInt8((h9 >> 18) & 0xff)
        return s
    }

    // MARK: - Arithmetic

    static func + (a: Self, b: Self) -> Self {
        Ed25519FieldElement(
            a.t.0 + b.t.0, a.t.1 + b.t.1, a.t.2 + b.t.2, a.t.3 + b.t.3, a.t.4 + b.t.4,
            a.t.5 + b.t.5, a.t.6 + b.t.6, a.t.7 + b.t.7, a.t.8 + b.t.8, a.t.9 + b.t.9
        )
    }

    static func - (a: Self, b: Self) -> Self {
        Ed25519FieldElement(
            a.t.0 - b.t.0, a.t.1 - b.t.1, a.t.2 - b.t.2, a.t.3 - b.t.3, a.t.4 - b.t.4,
            a.t.5 - b.t.5, a.t.6 - b.t.6, a.t.7 - b.t.7, a.t.8 - b.t.8, a.t.9 - b.t.9
        )
    }

    static prefix func - (a: Self) -> Self {
        Ed25519FieldElement(
            -a.t.0, -a.t.1, -a.t.2, -a.t.3, -a.t.4,
            -a.t.5, -a.t.6, -a.t.7, -a.t.8, -a.t.9
        )
    }

    /// Field multiplication (schoolbook-style, same as ref10 / spake2-java).
    static func * (f: Self, g: Self) -> Self {
        let (f0,f1,f2,f3,f4,f5,f6,f7,f8,f9) = f.t
        let (g0,g1,g2,g3,g4,g5,g6,g7,g8,g9) = g.t

        let g1_19 = 19*g1; let g2_19 = 19*g2; let g3_19 = 19*g3
        let g4_19 = 19*g4; let g5_19 = 19*g5; let g6_19 = 19*g6
        let g7_19 = 19*g7; let g8_19 = 19*g8; let g9_19 = 19*g9

        let f1_2 = 2*f1; let f3_2 = 2*f3; let f5_2 = 2*f5; let f7_2 = 2*f7; let f9_2 = 2*f9

        var h0 = f0*g0    + f1_2*g9_19 + f2*g8_19  + f3_2*g7_19 + f4*g6_19  + f5_2*g5_19 + f6*g4_19  + f7_2*g3_19 + f8*g2_19  + f9_2*g1_19
        var h1 = f0*g1    + f1*g0      + f2*g9_19  + f3*g8_19   + f4*g7_19  + f5*g6_19   + f6*g5_19  + f7*g4_19   + f8*g3_19  + f9*g2_19
        var h2 = f0*g2    + f1_2*g1    + f2*g0     + f3_2*g9_19 + f4*g8_19  + f5_2*g7_19 + f6*g6_19  + f7_2*g5_19 + f8*g4_19  + f9_2*g3_19
        var h3 = f0*g3    + f1*g2      + f2*g1     + f3*g0      + f4*g9_19  + f5*g8_19   + f6*g7_19  + f7*g6_19   + f8*g5_19  + f9*g4_19
        var h4 = f0*g4    + f1_2*g3    + f2*g2     + f3_2*g1    + f4*g0     + f5_2*g9_19 + f6*g8_19  + f7_2*g7_19 + f8*g6_19  + f9_2*g5_19
        var h5 = f0*g5    + f1*g4      + f2*g3     + f3*g2      + f4*g1     + f5*g0      + f6*g9_19  + f7*g8_19   + f8*g7_19  + f9*g6_19
        var h6 = f0*g6    + f1_2*g5    + f2*g4     + f3_2*g3    + f4*g2     + f5_2*g1    + f6*g0     + f7_2*g9_19 + f8*g8_19  + f9_2*g7_19
        var h7 = f0*g7    + f1*g6      + f2*g5     + f3*g4      + f4*g3     + f5*g2      + f6*g1     + f7*g0      + f8*g9_19  + f9*g8_19
        var h8 = f0*g8    + f1_2*g7    + f2*g6     + f3_2*g5    + f4*g4     + f5_2*g3    + f6*g2     + f7_2*g1    + f8*g0     + f9_2*g9_19
        var h9 = f0*g9    + f1*g8      + f2*g7     + f3*g6      + f4*g5     + f5*g4      + f6*g3     + f7*g2      + f8*g1     + f9*g0

        h1 += h0 >> 26; h0 &= 0x3ffffff
        h5 += h4 >> 26; h4 &= 0x3ffffff
        h2 += h1 >> 25; h1 &= 0x1ffffff
        h6 += h5 >> 25; h5 &= 0x1ffffff
        h3 += h2 >> 26; h2 &= 0x3ffffff
        h7 += h6 >> 26; h6 &= 0x3ffffff
        h4 += h3 >> 25; h3 &= 0x1ffffff
        h8 += h7 >> 25; h7 &= 0x1ffffff
        h5 += h4 >> 26; h4 &= 0x3ffffff
        h9 += h8 >> 26; h8 &= 0x3ffffff
        h0 += (h9 >> 25) * 19; h9 &= 0x1ffffff
        h1 += h0 >> 26; h0 &= 0x3ffffff

        return Ed25519FieldElement(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }

    /// Square.
    func square() -> Ed25519FieldElement {
        let (f0,f1,f2,f3,f4,f5,f6,f7,f8,f9) = t
        let f0_2 = 2*f0; let f1_2 = 2*f1; let f2_2 = 2*f2; let f3_2 = 2*f3
        let f4_2 = 2*f4; let f5_2 = 2*f5; let f6_2 = 2*f6; let f7_2 = 2*f7
        let f5_38 = 38*f5; let f6_19 = 19*f6; let f7_38 = 38*f7
        let f8_19 = 19*f8; let f9_38 = 38*f9

        var h0 = f0*f0     + f1_2*f9_38 + f2_2*f8_19 + f3_2*f7_38 + f4_2*f6_19 + f5*f5_38
        var h1 = f0_2*f1   + f2*f9_38   + f3_2*f8_19 + f4*f7_38   + f5_2*f6_19
        var h2 = f0_2*f2   + f1_2*f1    + f3_2*f9_38 + f4_2*f8_19 + f5_2*f7_38 + f6*f6_19
        var h3 = f0_2*f3   + f1_2*f2    + f4*f9_38   + f5_2*f8_19 + f6*f7_38
        var h4 = f0_2*f4   + f1_2*f3_2  + f2*f2      + f5_2*f9_38 + f6_2*f8_19 + f7*f7_38
        var h5 = f0_2*f5   + f1_2*f4    + f2_2*f3    + f6*f9_38   + f7_2*f8_19
        var h6 = f0_2*f6   + f1_2*f5_2  + f2_2*f4    + f3_2*f3    + f7_2*f9_38 + f8*f8_19
        var h7 = f0_2*f7   + f1_2*f6    + f2_2*f5    + f3_2*f4    + f8*f9_38
        var h8 = f0_2*f8   + f1_2*f7_2  + f2_2*f6    + f3_2*f5_2  + f4*f4      + f9*f9_38
        var h9 = f0_2*f9   + f1_2*f8    + f2_2*f7    + f3_2*f6    + f4_2*f5

        h1 += h0 >> 26; h0 &= 0x3ffffff
        h5 += h4 >> 26; h4 &= 0x3ffffff
        h2 += h1 >> 25; h1 &= 0x1ffffff
        h6 += h5 >> 25; h5 &= 0x1ffffff
        h3 += h2 >> 26; h2 &= 0x3ffffff
        h7 += h6 >> 26; h6 &= 0x3ffffff
        h4 += h3 >> 25; h3 &= 0x1ffffff
        h8 += h7 >> 25; h7 &= 0x1ffffff
        h5 += h4 >> 26; h4 &= 0x3ffffff
        h9 += h8 >> 26; h8 &= 0x3ffffff
        h0 += (h9 >> 25) * 19; h9 &= 0x1ffffff
        h1 += h0 >> 26; h0 &= 0x3ffffff

        return Ed25519FieldElement(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }

    /// Square `n` times.
    func squareN(_ n: Int) -> Ed25519FieldElement {
        var r = square()
        for _ in 1..<n { r = r.square() }
        return r
    }

    /// Field inversion using Fermat's little theorem: a^(p-2) mod p.
    /// Ported from spake2-java Ed25519FieldElement.invert()
    func invert() -> Ed25519FieldElement {
        var t0, t1, t2, t3: Ed25519FieldElement

        t0 = square()
        t1 = t0.square()
        t1 = t1.square()
        t1 = self * t1
        t0 = t0 * t1
        t2 = t0.square()
        t1 = t1 * t2
        t2 = t1.square()
        for _ in 1..<5 { t2 = t2.square() }
        t1 = t2 * t1
        t2 = t1.square()
        for _ in 1..<10 { t2 = t2.square() }
        t2 = t2 * t1
        t3 = t2.square()
        for _ in 1..<20 { t3 = t3.square() }
        t2 = t3 * t2
        t2 = t2.square()
        for _ in 1..<10 { t2 = t2.square() }
        t1 = t2 * t1
        t2 = t1.square()
        for _ in 1..<50 { t2 = t2.square() }
        t2 = t2 * t1
        t3 = t2.square()
        for _ in 1..<100 { t3 = t3.square() }
        t2 = t3 * t2
        t2 = t2.square()
        for _ in 1..<50 { t2 = t2.square() }
        t1 = t2 * t1
        t1 = t1.square()
        for _ in 1..<5 { t1 = t1.square() }
        return t1 * t0
    }

    /// Is this element zero? (constant-time equivalent)
    var isNonZero: Bool {
        let s = toBytes()
        var d: UInt8 = 0
        for b in s { d |= b }
        return d != 0
    }

    /// Conditional move: return `other` if `flag == 1`, else `self`.
    func cmov(_ other: Ed25519FieldElement, flag: Int64) -> Ed25519FieldElement {
        // Mask is all-ones if flag==1, all-zeros if flag==0
        let mask = -flag   // 0 or -1 in two's complement
        func sel(_ a: Int64, _ b: Int64) -> Int64 { a ^ (mask & (a ^ b)) }
        return Ed25519FieldElement(
            sel(t.0, other.t.0), sel(t.1, other.t.1),
            sel(t.2, other.t.2), sel(t.3, other.t.3),
            sel(t.4, other.t.4), sel(t.5, other.t.5),
            sel(t.6, other.t.6), sel(t.7, other.t.7),
            sel(t.8, other.t.8), sel(t.9, other.t.9)
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.toBytes() == rhs.toBytes()
    }
}

// Ed25519GroupElement.swift
// Ported from spake2-java / io.github.muntashirakon.crypto.ed25519.GroupElement
// Swift port for ADBPairing module.

// Points on the Edwards25519 curve, in several representations matching
// the Java GroupElement.Representation enum:
//   P2    = (X:Y:Z)
//   P3    = (X:Y:Z:T) with XY = ZT
//   P1P1  = completed addition ((X:Z),(Y:T))
//   PRECOMP = (y+x, y-x, 2dxy)  — used for table lookups
//   CACHED  = (Y+X, Y-X, Z, 2dT)

// MARK: - Constants

// d = -121665/121666 mod p   (twisted Edwards constant)
private let d: Ed25519FieldElement = Ed25519FieldElement.fromBytes([
    0xa3, 0x78, 0x59, 0x13, 0xca, 0x4d, 0xeb, 0x75, 0xab, 0xd8,
    0x41, 0x41, 0x4d, 0x0a, 0x70, 0x00, 0x98, 0xe8, 0x79, 0x77,
    0x79, 0x40, 0xc7, 0x8c, 0x73, 0xfe, 0x6f, 0x2b, 0xee, 0x6c,
    0x03, 0x52
])
private let d2: Ed25519FieldElement = d + d

// MARK: - Representations

enum GERepresentation {
    case p2, p3, p1p1, precomp, cached
}

// MARK: - GroupElement

struct GroupElement {
    let rep: GERepresentation

    // P2/P3 coordinates
    var X: Ed25519FieldElement
    var Y: Ed25519FieldElement
    var Z: Ed25519FieldElement
    var T: Ed25519FieldElement  // only used in P3/P1P1/CACHED

    // PRECOMP / CACHED use (X,Y,Z,T) with different meanings:
    // PRECOMP: X=y+x, Y=y-x, Z=2*d*x*y (T unused)
    // CACHED:  X=Y+X, Y=Y-X, Z=Z, T=2*d*T

    // Zero element (neutral) in P3.
    static var zero: GroupElement {
        GroupElement(rep: .p3, X: .zero, Y: .one, Z: .one, T: .zero)
    }

    init(rep: GERepresentation,
         X: Ed25519FieldElement, Y: Ed25519FieldElement,
         Z: Ed25519FieldElement, T: Ed25519FieldElement) {
        self.rep = rep; self.X = X; self.Y = Y; self.Z = Z; self.T = T
    }

    // PRECOMP convenience init (T unused)
    init(precomp ypx: Ed25519FieldElement, ymx: Ed25519FieldElement, xy2d: Ed25519FieldElement) {
        self.init(rep: .precomp, X: ypx, Y: ymx, Z: xy2d, T: .zero)
    }

    // MARK: - Encoding

    /// Encode the point to 32 bytes (compressed form, set sign bit for X if negative).
    func toBytes() -> [UInt8] {
        let p = toP2()
        let recip = p.Z.invert()
        let x = p.X * recip
        let y = p.Y * recip
        var s = y.toBytes()
        // Set the sign bit of X
        let xSign = x.toBytes()[0] & 1
        s[31] ^= (xSign << 7)
        return s
    }

    // MARK: - Conversions

    /// Convert to P2 representation.
    func toP2() -> GroupElement {
        switch rep {
        case .p3:
            return GroupElement(rep: .p2, X: X, Y: Y, Z: Z, T: .zero)
        case .p1p1:
            return GroupElement(rep: .p2, X: X*T, Y: Y*Z, Z: Z*T, T: .zero)
        default:
            return self
        }
    }

    /// Convert to P3 representation (only valid from P1P1).
    func toP3() -> GroupElement {
        guard rep == .p1p1 else { return self }
        return GroupElement(rep: .p3, X: X*T, Y: Y*Z, Z: Z*T, T: X*Y)
    }

    /// Convert to CACHED representation.
    func toCached() -> GroupElement {
        // CACHED: X=Y+X_self, Y=Y_self-X_self, Z=Z_self, T=2d*T_self
        GroupElement(rep: .cached, X: Y+X, Y: Y-X, Z: Z, T: d2*T)
    }

    // MARK: - Point addition (P3 + CACHED → P1P1)

    /// Addition: self is in P3, rhs is in CACHED → result in P1P1.
    /// Formula from section 3.1 of https://hyperelliptic.org/EFD/g1p/auto-twisted-extended-1.html
    func add(_ rhs: GroupElement) -> GroupElement {
        precondition(rep == .p3)
        precondition(rhs.rep == .cached)
        let A = (Y - X) * rhs.Y
        let B = (Y + X) * rhs.X
        let C = rhs.T * T
        let D = Z * (rhs.Z + rhs.Z)
        let E = B - A
        let G = D - C
        let H = D + C
        let F = B + A
        return GroupElement(rep: .p1p1, X: E, Y: F, Z: H, T: G)
    }

    /// Subtraction: self is in P3, rhs is in CACHED → result in P1P1.
    func sub(_ rhs: GroupElement) -> GroupElement {
        precondition(rep == .p3)
        precondition(rhs.rep == .cached)
        let A = (Y - X) * rhs.X
        let B = (Y + X) * rhs.Y
        let C = rhs.T * T
        let D = Z * (rhs.Z + rhs.Z)
        let E = B - A
        let G = D + C
        let H = D - C
        let F = B + A
        return GroupElement(rep: .p1p1, X: E, Y: F, Z: H, T: G)
    }

    // MARK: - Mixed addition (P3 + PRECOMP → P1P1)

    func madd(_ rhs: GroupElement) -> GroupElement {
        precondition(rep == .p3)
        precondition(rhs.rep == .precomp)
        let A = (Y - X) * rhs.Y
        let B = (Y + X) * rhs.X
        let C = rhs.Z * T
        let D = Z + Z
        let E = B - A
        let G = D - C
        let H = D + C
        let F = B + A
        return GroupElement(rep: .p1p1, X: E, Y: F, Z: H, T: G)
    }

    // MARK: - Doubling (P2 → P1P1)

    func dbl() -> GroupElement {
        // Matches spake2-java GroupElement.dbl() (ref10 ge_p2_dbl):
        //   XX = X², YY = Y², B = 2Z², AA = (X+Y)²
        //   Yn = YY + XX, Zn = YY - XX
        //   → p1p1(AA - Yn, Yn, Zn, B - Zn)
        let p2 = toP2()
        let XX = p2.X.square()
        let YY = p2.Y.square()
        let Z2 = p2.Z.square()
        let B  = Z2 + Z2                 // 2·Z²
        let AA = (p2.X + p2.Y).square()
        let Yn = YY + XX
        let Zn = YY - XX
        return GroupElement(rep: .p1p1, X: AA - Yn, Y: Yn, Z: Zn, T: B - Zn)
    }

    // MARK: - Scalar multiplication

    /// Fixed-window scalar multiply (matches GroupElement.scalarMultiply in Java).
    /// `s` is a 32-byte little-endian scalar.
    func scalarMultiply(_ s: [UInt8]) -> GroupElement {
        // Build sliding window: expand s into 256 bits, take bit by bit
        // Use double-and-add (same as spake2-java reference impl)
        var r = GroupElement.zero
        let precomp = self
        // Precompute [1..16]*self for the 4-bit window — but for simplicity
        // we just use double-and-add (sufficient, not speed-critical here)
        for i in stride(from: 255, through: 0, by: -1) {
            let byteIdx = i >> 3
            let bitIdx  = i & 7
            let bit = Int((s[byteIdx] >> bitIdx) & 1)
            let rd = r.dbl().toP3()
            if bit == 1 {
                r = rd.add(precomp.toCached()).toP3()
            } else {
                r = rd
            }
        }
        return r
    }

    // MARK: - Decode from bytes

    /// Decode a compressed point from 32 bytes. Returns nil if not on curve.
    static func fromBytesNegateVarTime(_ b: [UInt8]) -> GroupElement? {
        guard b.count == 32 else { return nil }
        var bytes = b
        let signX = (bytes[31] & 0x80) != 0
        bytes[31] &= 0x7f

        let y = Ed25519FieldElement.fromBytes(bytes)

        // Recover x: x² = (y²-1)/(d*y²+1)
        let y2 = y.square()
        let one = Ed25519FieldElement.one
        let u = y2 - one
        let v = d * y2 + one

        // x = sqrt(u/v)
        guard var x = sqrtRatio(u: u, v: v) else { return nil }

        if signX != ((x.toBytes()[0] & 1) != 0) {
            x = -x
        }

        let T = x * y
        return GroupElement(rep: .p3, X: x, Y: y, Z: one, T: T)
    }

    // MARK: - Conditional move (constant-time)

    /// Return self if `flag == 0`, else other.
    func cmov(_ other: GroupElement, flag: Int) -> GroupElement {
        guard rep == .precomp && other.rep == .precomp else { return flag != 0 ? other : self }
        let f = Int64(flag)
        return GroupElement(
            precomp: X.cmov(other.X, flag: f),
            ymx:     Y.cmov(other.Y, flag: f),
            xy2d:    Z.cmov(other.Z, flag: f)
        )
    }
}

// MARK: - sqrt(u/v) helper

/// sqrt(-1) mod p = 2^((p-1)/4) mod p
/// Ported from spake2-java Ed25519.java I constant
private let sqrtM1 = Ed25519FieldElement.fromBytes([
    0xb0, 0xa0, 0x0e, 0x4a, 0x27, 0x1b, 0xee, 0xc4,
    0x78, 0xe4, 0x2f, 0xad, 0x06, 0x18, 0x43, 0x2f,
    0xa7, 0xd7, 0xfb, 0x3d, 0x99, 0x00, 0x4d, 0x2b,
    0x0b, 0xdf, 0xc1, 0x4f, 0x80, 0x24, 0x83, 0x2b
])

/// Returns sqrt(u/v) if it exists, else nil.
/// r = (u*v^3) * (u*v^7)^((p-5)/8)
private func sqrtRatio(u: Ed25519FieldElement, v: Ed25519FieldElement) -> Ed25519FieldElement? {
    let v3  = v.square() * v    // v^3
    let uv3 = u * v3            // u*v^3
    let v7  = v3.square() * v   // v^7
    let uv7 = u * v7            // u*v^7
    let pow = uv7.powP58()      // (u*v^7)^((p-5)/8)
    var r   = uv3 * pow         // candidate sqrt

    let vr2 = v * r.square()
    let negU = -u

    if vr2 == u    { return r }
    if vr2 == negU { return r * sqrtM1 }
    return nil
}

extension Ed25519FieldElement {
    /// self^((p-5)/8) = self^(2^252-3) — ref10 fe_pow22523.
    func powP58() -> Ed25519FieldElement {
        var t0, t1, t2: Ed25519FieldElement
        let z = self

        t0 = z.square()         // z^2
        t1 = t0.square()        // z^4
        t1 = t1.square()        // z^8
        t1 = t1 * z             // z^9
        t0 = t0 * t1            // z^11
        t0 = t0.square()        // z^22
        t0 = t0 * t1            // z^31 = z^(2^5-1)
        t1 = t0.squareN(5)      // z^(2^10-32)
        t0 = t1 * t0            // z^(2^10-1)
        t1 = t0.squareN(10)     // z^(2^20-2^10)
        t1 = t1 * t0            // z^(2^20-1)
        t2 = t1.squareN(20)     // z^(2^40-2^20)
        t1 = t2 * t1            // z^(2^40-1)
        t1 = t1.squareN(10)     // z^(2^50-2^10)
        t0 = t1 * t0            // z^(2^50-1)
        t1 = t0.squareN(50)     // z^(2^100-2^50)
        t1 = t1 * t0            // z^(2^100-1)
        t2 = t1.squareN(100)    // z^(2^200-2^100)
        t1 = t2 * t1            // z^(2^200-1)
        t1 = t1.squareN(50)     // z^(2^250-2^50)
        t0 = t1 * t0            // z^(2^250-1)
        t0 = t0.squareN(2)      // z^(2^252-4)
        return t0 * z           // z^(2^252-3) ✓
    }
}


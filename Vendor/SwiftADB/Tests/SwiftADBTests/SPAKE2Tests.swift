// SPAKE2Tests.swift
// Tests for the SPAKE2 + PairingAuthCtx implementation.
// Validates that Alice and Bob derive the same shared key given the same password.

import Testing
import Foundation
@testable import ADBPairing

@Suite("SPAKE2 Protocol Tests")
struct SPAKE2Tests {

    // MARK: - Basic round-trip

    @Test("Alice and Bob derive the same 64-byte key")
    func testAliceBobKeyAgreement() throws {
        let password = Array("123456".utf8)

        let alice = SPAKE2Context(role: .alice,
                                  myName: Array("adb pair client\0".utf8),
                                  theirName: Array("adb pair server\0".utf8))
        let bob   = SPAKE2Context(role: .bob,
                                  myName: Array("adb pair server\0".utf8),
                                  theirName: Array("adb pair client\0".utf8))

        // Generate messages
        let aliceMsg = try alice.generateMessage(password: password)
        let bobMsg   = try bob.generateMessage(password: password)

        #expect(aliceMsg.count == 32, "Alice message must be 32 bytes")
        #expect(bobMsg.count == 32,   "Bob message must be 32 bytes")

        // Process messages
        let aliceKey = try alice.processMessage(bobMsg)
        let bobKey   = try bob.processMessage(aliceMsg)

        #expect(aliceKey.count == 64, "Key must be 64 bytes")
        #expect(aliceKey == bobKey,   "Alice and Bob must derive the same key")
    }

    // MARK: - Cross-validation against a standard (BoringSSL / RFC 8032) SPAKE2
    //
    // Golden values produced by an independent, standard-conformant SPAKE2-over-
    // Ed25519 implementation (verified against RFC 8032 base-point vectors: the
    // base point compresses to 5866…66 and 2·B to c9a3f86a…). These prove the
    // Swift port is BYTE-IDENTICAL to a real BoringSSL/ADB implementation and so
    // will interoperate with a physical Android device.
    //
    // NOTE: The spake2-java clone in the sibling directory is NOT used as the
    // reference — its GroupElement.scalarMultiply is buggy (1·B ≠ B), so it is
    // only self-consistent and would not pair with a real device. Swift is the
    // correct one; do not "fix" Swift to match that clone.
    //
    // The M / N SPAKE2 points (compressed) are:
    //   M = 5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e
    //   N = 10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778

    private static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private static let alicePriv = hex("47f6c458e5f062db8427d2d9bb20c954a76d6943959756a18d11d45e1ad190f980a86d185a93ca1d3025c5febe3aac4045b34a39b1f511385ca97fc4332137f3")
    private static let bobPriv   = hex("a6bf9f9bf7819e0ded8c2dd82a1aa38acb2f8a6403429cff33d64ea9c40439d5fd7029811a5f5a8f7c89c8b44ac0b421f6b24ca2ba18d2069995831730cd8c5a")
    private static let pairPw     = hex("353932373831e63dd959651c211600f3b6561d0b9d90af09d0a4a453ee2059a480cc7c5a94d4d48933f9fff5fe43317d52fa7bff8f8bc4f3488b8007330fec7c7edc91c20e5d")

    private static let GOLD_ALICE_MSG = "135d85fa69022bbc7445653e19047e5b6981aa5b9d309b0de6d2e704dfe1568c"
    private static let GOLD_BOB_MSG   = "d5bd4ead287e42f0a073adcb8dc46acc0630c4925fe1d43350e7441a8b29e03a"
    private static let GOLD_KEY       = "c6aa9dd57cb181e3e855ec36d2dd8d5a8c7b2d60fc7ebca9469188f8e67f718139c13dc9e66bd13a092f65df97059d3182e39c914ab797d2b8b215bb682583b1"

    private static func hexstr(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    @Test("Scalar25519 reduce+leftShift3 matches BoringSSL known-answer vector")
    func testScalarReduceKAT() {
        var pk = Self.alicePriv
        Scalar25519.reduce(&pk)
        Scalar25519.leftShift3(&pk)
        #expect(Self.hexstr(pk) == "00f4f4563dba61b24551c122bbbb630855b1b5ed3f0a619792a0d9fd2a2cfb3880a86d185a93ca1d3025c5febe3aac4045b34a39b1f511385ca97fc4332137f3")
    }

    @Test("Base point scalar multiply matches RFC 8032 vectors")
    func testBasePointKAT() {
        // Construct the standard Ed25519 base point and verify 1·B and 2·B.
        let Bx = Ed25519FieldElement.fromBytes([0x1a,0xd5,0x25,0x8f,0x60,0x2d,0x56,0xc9,0xb2,0xa7,0x25,0x95,0x60,0xc7,0x2c,0x69,0x5c,0xdc,0xd6,0xfd,0x31,0xe2,0xa4,0xc0,0xfe,0x53,0x6e,0xcd,0xd3,0x36,0x69,0x21])
        let By = Ed25519FieldElement.fromBytes([0x58,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66])
        let B = GroupElement(rep: .p3, X: Bx, Y: By, Z: .one, T: Bx * By)
        var one = [UInt8](repeating: 0, count: 32); one[0] = 1
        var two = [UInt8](repeating: 0, count: 32); two[0] = 2
        #expect(Self.hexstr(B.toBytes()) == "5866666666666666666666666666666666666666666666666666666666666666")
        #expect(Self.hexstr(B.scalarMultiply(one).toBytes()) == "5866666666666666666666666666666666666666666666666666666666666666", "1·B must equal B")
        #expect(Self.hexstr(B.scalarMultiply(two).toBytes()) == "c9a3f86aae465f0e56513864510f3997561fa2c9e85ea21dc2292309f3cd6022", "2·B must equal the RFC 8032 value")
    }

    @Test("SPAKE2 messages + keys are byte-identical to a standard BoringSSL/ADB implementation")
    func testCrossValidateAgainstStandard() throws {
        let names = (alice: Array("adb pair client ".utf8),
                     server: Array("adb pair server ".utf8))

        let alice = SPAKE2Context(role: .alice, myName: names.alice, theirName: names.server)
        let bob   = SPAKE2Context(role: .bob,   myName: names.server, theirName: names.alice)

        let aliceMsg = try alice.generateMessage(password: Self.pairPw, privateKeyMaterial: Self.alicePriv)
        let bobMsg   = try bob.generateMessage(password: Self.pairPw, privateKeyMaterial: Self.bobPriv)

        #expect(Self.hexstr(aliceMsg) == Self.GOLD_ALICE_MSG, "Alice message must match the standard reference")
        #expect(Self.hexstr(bobMsg)   == Self.GOLD_BOB_MSG,   "Bob message must match the standard reference")

        let aliceKey = try alice.processMessage(bobMsg)
        let bobKey   = try bob.processMessage(aliceMsg)

        #expect(Self.hexstr(aliceKey) == Self.GOLD_KEY, "Alice key must match the standard reference")
        #expect(Self.hexstr(bobKey)   == Self.GOLD_KEY, "Bob key must match the standard reference")
        #expect(aliceKey == bobKey,                     "Alice and Bob must derive the same key")
    }

    // MARK: - Wrong password

    @Test("Different passwords produce different keys")
    func testWrongPassword() throws {
        let alicePass = Array("123456".utf8)
        let bobPass   = Array("654321".utf8)

        let alice = SPAKE2Context(role: .alice,
                                  myName: Array("adb pair client\0".utf8),
                                  theirName: Array("adb pair server\0".utf8))
        let bob   = SPAKE2Context(role: .bob,
                                  myName: Array("adb pair server\0".utf8),
                                  theirName: Array("adb pair client\0".utf8))

        let aliceMsg = try alice.generateMessage(password: alicePass)
        let bobMsg   = try bob.generateMessage(password: bobPass)
        let aliceKey = try alice.processMessage(bobMsg)
        let bobKey   = try bob.processMessage(aliceMsg)

        #expect(aliceKey != bobKey, "Different passwords must produce different keys")
    }

    // MARK: - PairingAuthCtx round-trip

    @Test("PairingAuthCtx: encrypt/decrypt round-trip after SPAKE2")
    func testPairingAuthCtxEncryptDecrypt() throws {
        let password = Array("test_password".utf8)

        let alice = try PairingAuthCtx.createAlice(password: password)
        let bob   = try PairingAuthCtx.createBob(password: password)

        // Exchange SPAKE2 msgs and derive symmetric key
        try alice.initCipher(peerMsg: bob.msg)
        try bob.initCipher(peerMsg: alice.msg)

        // Alice encrypts, Bob decrypts
        let plaintext  = Array("Hello from Alice!".utf8)
        let ciphertext = try alice.encrypt(plaintext)
        let recovered  = try bob.decrypt(ciphertext)

        #expect(recovered == plaintext, "Round-trip encrypt/decrypt must recover plaintext")
    }

    // MARK: - Field arithmetic sanity

    @Test("Ed25519 field: 1 + 1 == 2")
    func testFieldAddition() {
        let one = Ed25519FieldElement.one
        let two = one + one
        let twoBytes = two.toBytes()
        #expect(twoBytes[0] == 2)
        twoBytes.dropFirst().forEach { #expect($0 == 0) }
    }

    @Test("Ed25519 field: a * a^(-1) == 1")
    func testFieldInversion() {
        var b = [UInt8](repeating: 0, count: 32)
        b[0] = 7
        let f = Ed25519FieldElement.fromBytes(b)
        let fi = f.invert()
        let product = f * fi
        let expected = Ed25519FieldElement.one
        #expect(product == expected, "f * f^-1 must equal 1")
    }

    // MARK: - Scalar reduction

    @Test("Scalar25519.reduce output is 32 bytes")
    func testScalarReduce() {
        var s = [UInt8](repeating: 0xFF, count: 64)
        Scalar25519.reduce(&s)
        // After reduction the top bytes should be zeroed (reduced mod l)
        #expect(s[31] < 0x11, "Top byte of reduced scalar must be < 0x11")
    }

    // MARK: - generateMessage error handling

    @Test("generateMessage throws if called twice")
    func testGenerateMessageTwice() throws {
        let ctx = SPAKE2Context(role: .alice,
                                myName: Array("a".utf8),
                                theirName: Array("b".utf8))
        _ = try ctx.generateMessage(password: Array("pw".utf8))
        #expect(throws: SPAKE2Error.self) {
            _ = try ctx.generateMessage(password: Array("pw".utf8))
        }
    }

    @Test("processMessage throws before generateMessage")
    func testProcessMessageBeforeGenerate() throws {
        let ctx = SPAKE2Context(role: .alice,
                                myName: Array("a".utf8),
                                theirName: Array("b".utf8))
        #expect(throws: SPAKE2Error.self) {
            _ = try ctx.processMessage([UInt8](repeating: 0, count: 32))
        }
    }
}

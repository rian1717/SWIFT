import XCTest
@testable import SWIFTCore

/// The decoder is the first thing to touch bytes from an unauthenticated peer.
/// It must reject malformed input by throwing — never by trapping, hanging, or
/// allocating on an attacker's say-so.
final class WireRobustnessTests: XCTestCase {

    // MARK: Varints

    func testVarintRoundTrip() throws {
        let values: [UInt64] = [0, 1, 127, 128, 300, 16383, 16384,
                                UInt64(UInt32.max), UInt64.max, UInt64.max - 1]
        for v in values {
            var w = ProtoWriter()
            w.writeVarint(v)
            var r = ProtoReader(w.data)
            XCTAssertEqual(try r.readVarint(), v)
            XCTAssertTrue(r.isAtEnd)
        }
    }

    /// A varint padded past 10 bytes must be rejected rather than scanned forever.
    func testOverlongVarintIsRejected() {
        var r = ProtoReader(Data([UInt8](repeating: 0x80, count: 16)))
        XCTAssertThrowsError(try r.readVarint()) { error in
            XCTAssertEqual(error as? ProtoWireError, .malformedVarint)
        }
    }

    func testTruncatedVarintIsRejected() {
        var r = ProtoReader(Data([0x80, 0x80]))   // continuation bit never cleared
        XCTAssertThrowsError(try r.readVarint()) { error in
            XCTAssertEqual(error as? ProtoWireError, .truncated)
        }
    }

    // MARK: Length prefixes

    /// The crucial one: a huge declared length must be refused against the bytes
    /// actually present, before any allocation.
    func testAbsurdLengthPrefixIsRejectedWithoutAllocating() {
        var w = ProtoWriter()
        w.writeVarint(UInt64(Int32.max))    // "here comes 2 GB"
        var r = ProtoReader(w.data + Data([0x01, 0x02]))   // ...followed by 2 bytes
        XCTAssertThrowsError(try r.readBytes()) { error in
            guard case .lengthTooLarge = (error as? ProtoWireError) else {
                return XCTFail("expected lengthTooLarge, got \(error)")
            }
        }
    }

    func testNegativeLengthPrefixIsRejected() {
        var w = ProtoWriter()
        w.writeVarint(UInt64(bitPattern: -1))   // 0xFFFF...FF
        var r = ProtoReader(w.data)
        XCTAssertThrowsError(try r.readBytes())
    }

    func testTruncatedBytesFieldIsRejected() {
        var r = ProtoReader(Data([0x05, 0x01, 0x02]))   // says 5, has 2
        XCTAssertThrowsError(try r.readBytes())
    }

    // MARK: Structure

    func testGroupWireTypesAreRejected() {
        // Wire types 3 and 4 (start/end group) are deprecated and unsupported.
        for raw: UInt8 in [3, 4, 6, 7] {
            XCTAssertThrowsError(try ProtoWireType(rawTag: raw))
        }
    }

    func testZeroFieldNumberIsRejected() {
        var r = ProtoReader(Data([0x00]))   // field 0, wire type 0
        XCTAssertThrowsError(try r.nextTag())
    }

    /// Nesting must hit the depth limit rather than the stack.
    ///
    /// No message in this schema is self-recursive, so this drives the reader
    /// directly — that's where the guard lives, and it accumulates across
    /// `decodeNested` too.
    func testNestingDepthIsLimited() throws {
        // 64 levels of length-delimited field 1, each containing the next.
        var payload = Data()
        for _ in 0..<64 {
            var w = ProtoWriter()
            w.write(field: 1, bytes: payload)
            payload = w.data
        }

        var reader = ProtoReader(payload)
        var depth = 0
        var threw: Error?
        do {
            while true {
                guard let tag = try reader.nextTag() else { break }
                XCTAssertEqual(tag.wireType, .lengthDelimited)
                reader = try reader.readNested()
                depth += 1
            }
        } catch {
            threw = error
        }

        XCTAssertEqual(threw as? ProtoWireError, .depthLimitExceeded,
                       "expected the depth guard to fire, stopped at depth \(depth)")
        XCTAssertEqual(depth, ProtoReader.maxDepth,
                       "depth guard fired at the wrong level")
    }

    func testInvalidUTF8StringIsRejected() {
        var w = ProtoWriter()
        w.write(field: 1, bytes: Data([0xFF, 0xFE]))
        var r = ProtoReader(w.data)
        _ = try? r.nextTag()
        XCTAssertThrowsError(try r.readString()) { error in
            XCTAssertEqual(error as? ProtoWireError, .invalidUTF8)
        }
    }

    /// Unknown fields are skipped, not retained, and must not disturb parsing of
    /// the fields we do model.
    func testUnknownFieldsAreSkipped() throws {
        var w = ProtoWriter()
        w.write(field: 1, bytes: Data([0xAA]))            // SecureMessage.headerAndBody
        w.write(field: 2, bytes: Data([0xBB]))            // SecureMessage.signature
        w.write(field: 99, string: "unmodelled")          // unknown
        w.write(field: 100, int64: -12345)                // unknown varint
        let msg = try SecureMessage(serialized: w.data)
        XCTAssertEqual(msg.headerAndBody, Data([0xAA]))
        XCTAssertEqual(msg.signature, Data([0xBB]))
    }

    /// Truncating a valid message at every possible point must throw, never trap.
    func testEveryTruncationOfAValidFrameIsHandled() throws {
        var header = PayloadHeader()
        header.id = 1234567890
        header.type = .bytes
        header.totalSize = 512
        var chunk = PayloadChunk()
        chunk.offset = 0
        chunk.flags = 1
        chunk.body = Data(repeating: 0x66, count: 64)
        var transfer = PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader = header
        transfer.payloadChunk = chunk
        let bytes = OfflineFrame.payloadTransfer(transfer).serialized()

        for cut in 0..<bytes.count {
            // Either parses (a valid prefix can be a valid message) or throws.
            _ = try? OfflineFrame(serialized: bytes.prefix(cut))
        }
        XCTAssertNoThrow(try OfflineFrame(serialized: bytes))
    }

    /// Random bytes must never trap the decoder.
    func testRandomInputNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...256, using: &rng)
            let data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try? OfflineFrame(serialized: data)
            _ = try? SharingFrame(serialized: data)
            _ = try? SecureMessage(serialized: data)
            _ = try? Ukey2Message(serialized: data)
        }
    }

    /// Bit-flipping a valid frame must never trap either.
    func testBitFlipsNeverCrash() throws {
        let bytes = [UInt8](SharingFrame.introduction({
            var i = IntroductionFrame()
            var f = SharingFileMetadata()
            f.name = "a.jpg"; f.type = .image; f.payloadID = 1; f.size = 10
            i.fileMetadata = [f]
            return i
        }()).serialized())

        for index in bytes.indices {
            for bit in 0..<8 {
                var mutated = bytes
                mutated[index] ^= (1 << bit)
                _ = try? SharingFrame(serialized: Data(mutated))
            }
        }
    }

    // MARK: Declared sizes

    /// Summing peer-declared file sizes must saturate, not trap.
    ///
    /// This is read to present the offer — before the user has accepted
    /// anything — so a trap here is a remote peer killing the process without
    /// any interaction at all. Two files of `Int64.max` used to do it.
    func testOfferTotalSaturatesInsteadOfOverflowing() {
        let huge = (0..<2).map {
            IncomingFile(name: "f\($0)", size: .max, mimeType: "application/octet-stream",
                         payloadID: Int64($0))
        }
        let offer = IncomingOffer(id: "x",
                                  device: SWIFTDevice(id: "d", name: "d", type: .phone),
                                  files: huge, textTitle: nil, pinCode: "0000")
        XCTAssertEqual(offer.totalBytes, .max)
    }

    /// The declared-size bound has to leave enough headroom that a full-sized
    /// offer cannot overflow the sum in the first place.
    func testDeclaredSizeBoundsCannotOverflow() {
        let (product, overflowed) = InboundSession.maxFileBytes
            .multipliedReportingOverflow(by: Int64(InboundSession.maxFilesPerTransfer))
        XCTAssertFalse(overflowed)
        XCTAssertLessThan(product, Int64.max / 2)
    }
}

import XCTest
@testable import SWIFTCore

/// Byte-exactness for the transport and application frames.
final class OfflineWireFormatTests: GoldenWireTestCase {

    private var samplePayload: PayloadTransferFrame {
        var header = PayloadHeader()
        header.id = 1234567890
        header.type = .bytes
        header.totalSize = 512
        header.isSensitive = false

        var chunk = PayloadChunk()
        chunk.offset = 0
        chunk.flags = 1
        chunk.body = Data(repeating: 0x66, count: 32)

        var frame = PayloadTransferFrame()
        frame.packetType = .data
        frame.payloadHeader = header
        frame.payloadChunk = chunk
        return frame
    }

    func testOsInfo() throws {
        try assertMatchesGolden(OsInfo(type: .apple), "OsInfo")
    }

    func testConnectionRequestFrame() throws {
        var f = ConnectionRequestFrame()
        f.endpointID = "ABCD"
        f.endpointName = "Test Mac"
        f.endpointInfo = Data(repeating: 0x55, count: 20)
        try assertMatchesGolden(f, "ConnectionRequestFrame")
    }

    func testConnectionResponseFrame() throws {
        var f = ConnectionResponseFrame()
        f.response = .accept
        f.status = 0
        f.osInfo = OsInfo(type: .apple)
        try assertMatchesGolden(f, "ConnectionResponseFrame")
    }

    func testPayloadTransferFrame() throws {
        try assertMatchesGolden(samplePayload, "PayloadTransferFrame")
    }

    /// Negative ids and large sizes exercise full-width varint encoding.
    func testPayloadTransferFrameFile() throws {
        var header = PayloadHeader()
        header.id = -98765
        header.type = .file
        header.totalSize = 9_000_000

        var chunk = PayloadChunk()
        chunk.offset = 4096
        chunk.flags = 0

        var frame = PayloadTransferFrame()
        frame.packetType = .data
        frame.payloadHeader = header
        frame.payloadChunk = chunk
        try assertMatchesGolden(frame, "PayloadTransferFrameFile")
    }

    func testOfflineFramePayload() throws {
        try assertMatchesGolden(OfflineFrame.payloadTransfer(samplePayload), "OfflineFramePayload")
    }

    func testOfflineFrameKeepAlive() throws {
        try assertMatchesGolden(OfflineFrame.keepAlive(ack: true), "OfflineFrameKeepAlive")
    }

    func testOfflineFrameDisconnection() throws {
        try assertMatchesGolden(OfflineFrame.disconnection(), "OfflineFrameDisconnection")
    }

    func testOfflineFrameConnectionRequest() throws {
        var req = ConnectionRequestFrame()
        req.endpointID = "ABCD"
        req.endpointName = "Test Mac"
        req.endpointInfo = Data(repeating: 0x55, count: 20)

        var v1 = V1Frame()
        v1.type = .connectionRequest
        v1.connectionRequest = req
        try assertMatchesGolden(OfflineFrame.wrapping(v1), "OfflineFrameConnectionRequest")
    }

    func testOfflineFrameConnectionResponse() throws {
        var resp = ConnectionResponseFrame()
        resp.response = .accept
        resp.status = 0
        resp.osInfo = OsInfo(type: .apple)

        var v1 = V1Frame()
        v1.type = .connectionResponse
        v1.connectionResponse = resp
        try assertMatchesGolden(OfflineFrame.wrapping(v1), "OfflineFrameConnectionResponse")
    }
}

final class SharingFrameWireTests: GoldenWireTestCase {

    private var sampleFile: SharingFileMetadata {
        var m = SharingFileMetadata()
        m.name = "photo.jpg"
        m.type = .image
        m.payloadID = 42
        m.size = 123456
        m.mimeType = "image/jpeg"
        m.id = 9
        return m
    }

    private var sampleText: SharingTextMetadata {
        var m = SharingTextMetadata()
        m.textTitle = "a link"
        m.type = .url
        m.payloadID = 77
        m.size = 20
        m.id = 3
        return m
    }

    private var sampleIntro: IntroductionFrame {
        var i = IntroductionFrame()
        i.fileMetadata = [sampleFile]
        i.textMetadata = [sampleText]
        return i
    }

    func testFileMetadata() throws { try assertMatchesGolden(sampleFile, "FileMetadata") }
    func testTextMetadata() throws { try assertMatchesGolden(sampleText, "TextMetadata") }
    func testIntroductionFrame() throws { try assertMatchesGolden(sampleIntro, "IntroductionFrame") }

    func testPairedKeyEncryptionFrame() throws {
        var f = PairedKeyEncryptionFrame()
        f.secretIDHash = Data(repeating: 0x77, count: 6)
        f.signedData = Data(repeating: 0x88, count: 72)
        try assertMatchesGolden(f, "PairedKeyEncryptionFrame")
    }

    func testPairedKeyResultFrame() throws {
        try assertMatchesGolden(PairedKeyResultFrame(status: .unable), "PairedKeyResultFrame")
    }

    func testSharingConnectionResponseFrame() throws {
        try assertMatchesGolden(SharingConnectionResponseFrame(status: .accept),
                                "SharingConnectionResponseFrame")
    }

    func testSharingFrameIntroduction() throws {
        try assertMatchesGolden(SharingFrame.introduction(sampleIntro), "SharingFrameIntroduction")
    }

    func testSharingFrameCancel() throws {
        try assertMatchesGolden(SharingFrame.cancel(), "SharingFrameCancel")
    }

    func testSharingFramePairedKeyEncryption() throws {
        let f = SharingFrame.pairedKeyEncryption(secretIDHash: Data(repeating: 0x77, count: 6),
                                                 signedData: Data(repeating: 0x88, count: 72))
        try assertMatchesGolden(f, "SharingFramePairedKeyEncryption")
    }

    func testSharingFramePairedKeyResult() throws {
        try assertMatchesGolden(SharingFrame.pairedKeyResult(.unable), "SharingFramePairedKeyResult")
    }

    func testSharingFrameResponse() throws {
        try assertMatchesGolden(SharingFrame.response(.accept), "SharingFrameResponse")
    }
}

final class Ukey2WireTests: GoldenWireTestCase {

    private var sampleGeneric: GenericPublicKey {
        GenericPublicKey(ecP256: EcP256PublicKey(x: Data((1...32).map { UInt8($0) }),
                                                 y: Data((33...64).map { UInt8($0) })))
    }

    private var sampleCommitment: Ukey2CipherCommitment {
        var c = Ukey2CipherCommitment()
        c.handshakeCipher = .p256Sha512
        c.commitment = Data(repeating: 0x22, count: 32)
        return c
    }

    private var sampleClientInit: Ukey2ClientInit {
        var ci = Ukey2ClientInit()
        ci.version = 1
        ci.random = Data(repeating: 0x33, count: 32)
        ci.nextProtocol = "AES_256_CBC-HMAC_SHA256"
        ci.cipherCommitments = [sampleCommitment]
        return ci
    }

    func testCipherCommitment() throws {
        try assertMatchesGolden(sampleCommitment, "CipherCommitment")
    }

    func testUkey2ClientInit() throws {
        try assertMatchesGolden(sampleClientInit, "Ukey2ClientInit")
    }

    func testUkey2ServerInit() throws {
        var si = Ukey2ServerInit()
        si.version = 1
        si.random = Data(repeating: 0x44, count: 32)
        si.handshakeCipher = .p256Sha512
        si.publicKey = sampleGeneric.serialized()
        try assertMatchesGolden(si, "Ukey2ServerInit")
    }

    func testUkey2ClientFinished() throws {
        var cf = Ukey2ClientFinished()
        cf.publicKey = sampleGeneric.serialized()
        try assertMatchesGolden(cf, "Ukey2ClientFinished")
    }

    func testUkey2Alert() throws {
        try assertMatchesGolden(Ukey2Alert(type: .badMessageType), "Ukey2Alert")
    }

    func testUkey2Message() throws {
        let m = Ukey2Message(type: .clientInit, data: sampleClientInit.serialized())
        try assertMatchesGolden(m, "Ukey2Message")
    }
}

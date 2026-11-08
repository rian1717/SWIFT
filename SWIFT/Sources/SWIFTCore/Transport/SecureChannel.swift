import Foundation

/// The encrypted half of a session: wraps `FrameChannel` once the handshake has
/// produced keys, and handles sequence numbers plus bytes-payload reassembly.
///
/// Resource limits live here because this is the first place a peer's frames
/// become "structured" — and the last place before they become allocations.
actor SecureChannel {

    /// Cap on a single reassembled bytes payload (setup frames are small).
    static let maxPayloadBytes = 5 * 1024 * 1024
    /// Cap on how many payloads may be in flight at once.
    static let maxConcurrentPayloads = 16

    private let channel: FrameChannel
    private let codec: SecureMessageCodec

    // Sequence numbers are per-direction and must increase by one each frame.
    private var sendSequence: Int32 = 0
    private var expectedReceiveSequence: Int32 = 0

    private var payloadBuffers: [Int64: Data] = [:]

    init(channel: FrameChannel, keys: UKey2.SessionKeys) {
        self.channel = channel
        self.codec = SecureMessageCodec(keys: keys)
    }

    // MARK: Sending

    func send(_ frame: OfflineFrame) async throws {
        sendSequence &+= 1
        let d2d = DeviceToDeviceMessage(message: frame.serialized(), sequenceNumber: sendSequence)
        let sealed = try codec.seal(d2d.serialized())
        try await channel.send(frame: sealed.serialized())
    }

    /// Sends a Quick Share setup frame as a complete bytes payload (body chunk
    /// then an empty final chunk, which is how the protocol marks the end).
    func sendSetupFrame(_ frame: SharingFrame) async throws {
        let payloadID = Int64.random(in: Int64.min...Int64.max)
        let body = frame.serialized()

        var header = PayloadHeader()
        header.id = payloadID
        header.type = .bytes
        header.totalSize = Int64(body.count)
        header.isSensitive = false

        var chunk = PayloadChunk()
        chunk.offset = 0
        chunk.flags = 0
        chunk.body = body

        var transfer = PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader = header
        transfer.payloadChunk = chunk
        try await send(.payloadTransfer(transfer))

        var endChunk = PayloadChunk()
        endChunk.offset = Int64(body.count)
        endChunk.flags = PayloadChunk.lastChunkFlag
        transfer.payloadChunk = endChunk
        try await send(.payloadTransfer(transfer))
    }

    func sendKeepAlive(ack: Bool) async throws {
        try await send(.keepAlive(ack: ack))
    }

    func sendDisconnect() async throws {
        try await send(.disconnection())
    }

    // MARK: Receiving

    /// What a decrypted frame turned out to be.
    enum Incoming: Sendable {
        /// A complete Quick Share setup frame reassembled from a bytes payload.
        case setupFrame(SharingFrame)
        /// A chunk of a file payload.
        case fileChunk(header: PayloadHeader, chunk: PayloadChunk)
        /// A complete non-setup bytes payload (used for shared text/URLs).
        case bytesPayload(id: Int64, data: Data)
        case keepAlive
        case disconnected
        /// Something we don't model; the caller should ignore it.
        case ignored
    }

    func receive() async throws -> Incoming {
        let raw = try await channel.receiveFrame()
        let secure = try SecureMessage(serialized: raw)
        let plaintext = try codec.open(secure)
        let d2d = try DeviceToDeviceMessage(serialized: plaintext)

        guard let sequence = d2d.sequenceNumber, let messageBytes = d2d.message else {
            throw SWIFTError.missingField("DeviceToDeviceMessage")
        }
        expectedReceiveSequence &+= 1
        // Rejecting out-of-order frames is what stops replay and reordering.
        guard sequence == expectedReceiveSequence else {
            throw SWIFTError.protocolViolation(
                "unexpected sequence \(sequence), expected \(expectedReceiveSequence)")
        }

        let frame = try OfflineFrame(serialized: messageBytes)
        guard let v1 = frame.v1, let type = v1.type else { return .ignored }

        switch type {
        case .keepAlive:
            return .keepAlive
        case .disconnection:
            return .disconnected
        case .payloadTransfer:
            guard let transfer = v1.payloadTransfer,
                  let header = transfer.payloadHeader,
                  let chunk = transfer.payloadChunk else {
                throw SWIFTError.missingField("payloadTransfer")
            }
            switch header.type {
            case .file:
                return .fileChunk(header: header, chunk: chunk)
            case .bytes:
                return try accumulate(header: header, chunk: chunk)
            default:
                return .ignored
            }
        default:
            return .ignored
        }
    }

    /// Reassembles a bytes payload across chunks, refusing to be used as a
    /// memory sink.
    private func accumulate(header: PayloadHeader, chunk: PayloadChunk) throws -> Incoming {
        guard let payloadID = header.id else {
            throw SWIFTError.missingField("payloadHeader.id")
        }
        // A declared size is attacker-controlled: bound it on both sides. An
        // unchecked negative value reaches NSMutableData(capacity:), which
        // crashes the process outright.
        let declared = header.totalSize ?? 0
        guard declared >= 0, declared <= Int64(Self.maxPayloadBytes) else {
            payloadBuffers.removeValue(forKey: payloadID)
            throw SWIFTError.protocolViolation("payload size out of range (\(declared))")
        }

        var buffer: Data
        if let existing = payloadBuffers[payloadID] {
            buffer = existing
        } else {
            guard payloadBuffers.count < Self.maxConcurrentPayloads else {
                throw SWIFTError.protocolViolation("too many concurrent payloads")
            }
            buffer = Data()
        }

        guard chunk.offset ?? 0 == Int64(buffer.count) else {
            payloadBuffers.removeValue(forKey: payloadID)
            throw SWIFTError.protocolViolation("unexpected chunk offset")
        }

        if let body = chunk.body, !body.isEmpty {
            // Bound the accumulated total, not just each individual frame.
            guard buffer.count + body.count <= Self.maxPayloadBytes else {
                payloadBuffers.removeValue(forKey: payloadID)
                throw SWIFTError.protocolViolation("payload exceeded the maximum size")
            }
            buffer.append(body)
        }

        guard chunk.isLastChunk else {
            payloadBuffers[payloadID] = buffer
            return .ignored
        }

        payloadBuffers.removeValue(forKey: payloadID)
        // A complete bytes payload is normally a Quick Share setup frame; if it
        // doesn't parse as one, hand the raw bytes back (shared text/URLs).
        if let frame = try? SharingFrame(serialized: buffer), frame.v1 != nil {
            return .setupFrame(frame)
        }
        return .bytesPayload(id: payloadID, data: buffer)
    }

    func close() async {
        await channel.close()
    }
}

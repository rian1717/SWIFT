import Foundation
import Network
import CryptoKit
import Darwin

/// Receives a transfer: performs the UKEY2 handshake as the server, presents the
/// peer's offer for consent, then writes the files.
///
/// Events are delivered on an `AsyncStream`; the caller answers an offer by
/// calling `respond(accept:)`.
public actor InboundSession {

    /// Most files one offer may contain. Generous next to any real Quick Share
    /// transfer, small enough that the per-file work done before consent stays
    /// trivial.
    public static let maxFilesPerTransfer = 1024
    /// Largest size a peer may *declare* for one file (1 TiB). Far beyond a
    /// real transfer, and far enough below `Int64.max` that summing
    /// `maxFilesPerTransfer` of them cannot overflow.
    static let maxFileBytes: Int64 = 1 << 40

    public let id: String
    private let channel: FrameChannel
    private let receiveDirectory: URL

    private var secure: SecureChannel?
    private var device: SWIFTDevice?
    private var pinCode: String?

    private var pendingFiles: [Int64: PendingFile] = [:]
    private var savedURLs: [URL] = []
    private var totalExpectedBytes: Int64 = 0
    private var totalReceivedBytes: Int64 = 0

    /// Set once a text/link offer is accepted, so `receiveLoop` knows the bytes
    /// payload with this id is the shared text and not something to ignore.
    private var expectedTextPayload: (id: Int64, title: String, isLink: Bool)?

    private var consent: CheckedContinuation<Bool, Never>?
    private var continuation: AsyncStream<InboundEvent>.Continuation?
    private var started = false
    private var finished = false

    private struct PendingFile {
        let metadata: IncomingFile
        let destination: URL
        let temporaryURL: URL
        var handle: FileHandle?
        var bytesWritten: Int64 = 0
    }

    public init(connection: NWConnection, id: String, receiveDirectory: URL) {
        self.id = id
        self.channel = FrameChannel(connection: connection)
        self.receiveDirectory = receiveDirectory
    }

    /// Runs the session. The stream finishes when the transfer ends.
    ///
    /// Callable once. A second call would replace the event continuation and
    /// start a second handshake on a socket already in use, so it hands back an
    /// already-finished stream instead.
    public func events() -> AsyncStream<InboundEvent> {
        guard !started else { return AsyncStream { $0.finish() } }
        started = true
        return AsyncStream { continuation in
            self.continuation = continuation
            // Only when the consumer walks away — `.finished` also fires here,
            // and cancelling then would send a cancel frame after a transfer
            // that already succeeded.
            continuation.onTermination = { [weak self] reason in
                guard case .cancelled = reason else { return }
                Task { await self?.cancel() }
            }
            Task { await self.run() }
        }
    }

    /// Answers a pending offer.
    public func respond(accept: Bool) {
        consent?.resume(returning: accept)
        consent = nil
    }

    public func cancel() async {
        await finish(.failed(.rejected(.userCanceled)))
    }

    // MARK: Main loop

    private func run() async {
        do {
            try await channel.start()
            try await performHandshake()
            try await exchangeSetupFrames()
            try await receiveLoop()
        } catch let error as SWIFTError {
            await finish(.failed(error))
        } catch {
            await finish(.failed(.localFailure(error.localizedDescription)))
        }
    }

    // MARK: Handshake

    private func performHandshake() async throws {
        // 1. ConnectionRequest — carries the peer's name and device type.
        let requestFrame = try OfflineFrame(serialized: try await channel.receiveFrame())
        guard let request = requestFrame.v1?.connectionRequest,
              let endpointInfo = request.endpointInfo else {
            throw SWIFTError.missingField("connectionRequest.endpointInfo")
        }
        let info = try EndpointInfo(serialized: endpointInfo)
        device = SWIFTDevice(id: UUID().uuidString,
                                  name: info.name ?? request.endpointName ?? "Unknown device",
                                  type: info.deviceType)

        // 2. Ukey2ClientInit — the exact bytes matter; they go into the transcript.
        let clientInitBytes = try await channel.receiveFrame()
        let clientInitMessage = try Ukey2Message(serialized: clientInitBytes)
        guard clientInitMessage.messageType == .clientInit else {
            try await sendAlert(.badMessageType)
            throw SWIFTError.handshakeFailed("expected client init")
        }
        let clientInit = try Ukey2ClientInit(serialized: clientInitMessage.messageData ?? Data())
        guard clientInit.nextProtocol == "AES_256_CBC-HMAC_SHA256" else {
            try await sendAlert(.badNextProtocol)
            throw SWIFTError.handshakeFailed("unsupported next protocol")
        }
        guard clientInit.cipherCommitments.contains(where: { $0.handshakeCipher == .p256Sha512 }) else {
            try await sendAlert(.badHandshakeCipher)
            throw SWIFTError.handshakeFailed("no supported cipher offered")
        }

        // 3. Ukey2ServerInit — our ephemeral key.
        let keyPair = UKey2.KeyPair()
        var serverInit = Ukey2ServerInit()
        serverInit.version = 1
        serverInit.random = Data.secureRandom(count: 32)
        serverInit.handshakeCipher = .p256Sha512
        serverInit.publicKey = keyPair.genericPublicKey.serialized()
        let serverInitBytes = Ukey2Message(type: .serverInit, data: serverInit.serialized()).serialized()
        try await channel.send(frame: serverInitBytes)

        // 4. Ukey2ClientFinished — the peer's key.
        let finishMessage = try Ukey2Message(serialized: try await channel.receiveFrame())
        guard finishMessage.messageType == .clientFinish else {
            try await sendAlert(.badMessageType)
            throw SWIFTError.handshakeFailed("expected client finish")
        }
        let clientFinished = try Ukey2ClientFinished(serialized: finishMessage.messageData ?? Data())
        guard let peerKeyBytes = clientFinished.publicKey else {
            throw SWIFTError.missingField("clientFinished.publicKey")
        }
        let peerGeneric = try GenericPublicKey(serialized: peerKeyBytes)
        guard let peerEc = peerGeneric.ecP256PublicKey else {
            throw SWIFTError.missingField("peer public key")
        }
        let peerKey = try UKey2.publicKey(from: peerEc)

        let keys = try UKey2.deriveSessionKeys(
            ourPrivateKey: keyPair.privateKey,
            peerPublicKey: peerKey,
            clientInitBytes: clientInitBytes,
            serverInitBytes: serverInitBytes,
            isServer: true)
        pinCode = keys.pinCode

        // 5. ConnectionResponse, in the clear, then everything is encrypted.
        let response = try OfflineFrame(serialized: try await channel.receiveFrame())
        guard response.v1?.type == .connectionResponse else {
            throw SWIFTError.protocolViolation("expected a connection response")
        }
        var accept = ConnectionResponseFrame()
        accept.response = .accept
        accept.status = 0
        accept.osInfo = OsInfo(type: .apple)
        var v1 = V1Frame()
        v1.type = .connectionResponse
        v1.connectionResponse = accept
        try await channel.send(frame: OfflineFrame.wrapping(v1).serialized())

        secure = SecureChannel(channel: channel, keys: keys)
    }

    private func sendAlert(_ type: Ukey2AlertType) async throws {
        let alert = Ukey2Message(type: .alert, data: Ukey2Alert(type: type).serialized())
        try? await channel.send(frame: alert.serialized())
    }

    // MARK: Setup frames

    private func exchangeSetupFrames() async throws {
        guard let secure else { throw SWIFTError.internalFailure("no secure channel") }
        // The paired-key exchange is vestigial for us: we have no contact
        // certificates, so we send placeholders and answer `.unable`, which is
        // what the reference did and what Android tolerates.
        try await secure.sendSetupFrame(.pairedKeyEncryption(
            secretIDHash: Data.secureRandom(count: 6),
            signedData: Data.secureRandom(count: 72)))

        // Drive the exchange until the peer's introduction arrives.
        while true {
            switch try await secure.receive() {
            case .setupFrame(let frame):
                guard let type = frame.v1?.type else { continue }
                switch type {
                case .pairedKeyEncryption:
                    try await secure.sendSetupFrame(.pairedKeyResult(.unable))
                case .pairedKeyResult:
                    continue
                case .introduction:
                    guard let introduction = frame.v1?.introduction else {
                        throw SWIFTError.missingField("introduction")
                    }
                    try await handleIntroduction(introduction)
                    return
                case .cancel:
                    throw SWIFTError.rejected(.userCanceled)
                default:
                    continue
                }
            case .keepAlive:
                try await secure.sendKeepAlive(ack: true)
            case .disconnected:
                throw SWIFTError.connectionLost
            default:
                continue
            }
        }
    }

    private func handleIntroduction(_ introduction: IntroductionFrame) async throws {
        guard let secure, let device, let pinCode else {
            throw SWIFTError.internalFailure("session not ready")
        }

        // A shared link or snippet of text. It arrives as a bytes payload rather
        // than a file payload, so it needs its own path — falling through to
        // the file-handling code below would accept the offer and then drop
        // the payload, telling the sender it worked while producing nothing.
        if introduction.fileMetadata.isEmpty, let text = introduction.textMetadata.first {
            guard let payloadID = text.payloadID else {
                throw SWIFTError.missingField("textMetadata.payloadID")
            }
            let title = text.textTitle ?? "Shared text"
            let offer = IncomingOffer(id: id, device: device, files: [],
                                      textTitle: title, pinCode: pinCode)
            let accepted = await requestConsent(offer)
            try await secure.sendSetupFrame(.response(accepted ? .accept : .reject))
            guard accepted else { throw SWIFTError.rejected(.userRejected) }

            expectedTextPayload = (id: payloadID, title: title, isLink: text.type == .url)
            return
        }

        guard !introduction.fileMetadata.isEmpty else {
            try await secure.sendSetupFrame(.response(.unsupportedAttachmentType))
            throw SWIFTError.rejected(.unsupportedType)
        }
        // The peer chooses this count, and every entry costs a filesystem probe
        // below — before the user has agreed to anything — plus an open file
        // handle for the length of the transfer. Bound it rather than letting a
        // 5 MB introduction frame turn into ~100k of each.
        guard introduction.fileMetadata.count <= Self.maxFilesPerTransfer else {
            try await secure.sendSetupFrame(.response(.unsupportedAttachmentType))
            throw SWIFTError.protocolViolation("too many files in one transfer")
        }

        // Resolve destinations before asking, so a bad name is refused up front.
        var files: [IncomingFile] = []
        var pending: [Int64: PendingFile] = [:]
        var reservedDestinations: Set<URL> = []
        for meta in introduction.fileMetadata {
            guard let payloadID = meta.payloadID else {
                throw SWIFTError.missingField("fileMetadata.payloadID")
            }
            guard pending[payloadID] == nil else {
                throw SWIFTError.protocolViolation("duplicate payload id")
            }
            let size = meta.size ?? 0
            // Upper bound as well as lower: these are summed to show the offer,
            // and an unbounded value overflows that sum. Sanity-checking the
            // declaration costs nothing — the real byte count is enforced
            // separately, per chunk, in `writeChunk`.
            guard size >= 0, size <= Self.maxFileBytes else {
                throw SWIFTError.protocolViolation("declared file size out of range")
            }
            let safeName = ReceivedFileName.sanitize(meta.name ?? "")
            var destination = try ReceivedFileName.uniqueDestination(
                for: safeName, in: receiveDirectory)
            var suffix = 2
            while reservedDestinations.contains(destination) {
                let stem = (safeName as NSString).deletingPathExtension
                let ext = (safeName as NSString).pathExtension
                let candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
                destination = try ReceivedFileName.uniqueDestination(
                    for: candidate, in: receiveDirectory)
                suffix += 1
            }
            reservedDestinations.insert(destination)
            let temporaryURL = receiveDirectory.appendingPathComponent(
                ".\(destination.lastPathComponent).swift-\(UUID().uuidString).part")
            let file = IncomingFile(name: destination.lastPathComponent, size: size,
                                    mimeType: meta.mimeType ?? "application/octet-stream",
                                    payloadID: payloadID)
            files.append(file)
            pending[payloadID] = PendingFile(
                metadata: file, destination: destination, temporaryURL: temporaryURL)
        }

        let offer = IncomingOffer(id: id, device: device, files: files,
                                  textTitle: nil, pinCode: pinCode)
        let requiredBytes = files.reduce(Int64(0)) { partial, file in
            let (sum, overflowed) = partial.addingReportingOverflow(file.size)
            return overflowed ? Int64.max : sum
        }
        if let values = try? receiveDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < requiredBytes {
            try await secure.sendSetupFrame(.response(.notEnoughSpace))
            throw SWIFTError.rejected(.notEnoughSpace)
        }
        let accepted = await requestConsent(offer)
        guard accepted else {
            try await secure.sendSetupFrame(.response(.reject))
            throw SWIFTError.rejected(.userRejected)
        }

        pendingFiles = pending
        totalExpectedBytes = files.reduce(0) { $0 + $1.size }
        totalReceivedBytes = 0

        // Only create files once the user has actually said yes.
        for (payloadID, var file) in pendingFiles {
            FileManager.default.createFile(atPath: file.temporaryURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: file.temporaryURL) else {
                throw SWIFTError.localFailure("couldn't create \(file.destination.lastPathComponent)")
            }
            file.handle = handle
            pendingFiles[payloadID] = file
        }
        try await secure.sendSetupFrame(.response(.accept))
    }

    private func requestConsent(_ offer: IncomingOffer) async -> Bool {
        continuation?.yield(.offerReceived(offer))
        return await withCheckedContinuation { continuation in
            self.consent = continuation
        }
    }

    // MARK: Transfer

    private func receiveLoop() async throws {
        guard let secure else { throw SWIFTError.internalFailure("no secure channel") }
        while !finished {
            switch try await secure.receive() {
            case .fileChunk(let header, let chunk):
                try writeChunk(header: header, chunk: chunk)
                if pendingFiles.isEmpty {
                    try? await secure.sendDisconnect()
                    await finish(.finished(savedFiles: savedURLs))
                    return
                }
            case .setupFrame(let frame):
                if frame.v1?.type == .cancel {
                    throw SWIFTError.rejected(.userCanceled)
                }
            case .bytesPayload(let payloadID, let data):
                guard let expected = expectedTextPayload, expected.id == payloadID else {
                    continue   // not ours; ignore rather than guess
                }
                expectedTextPayload = nil
                let url = try saveSharedText(data, title: expected.title, isLink: expected.isLink)
                savedURLs.append(url)
                try? await secure.sendDisconnect()
                await finish(.finished(savedFiles: savedURLs))
                return
            case .keepAlive:
                try await secure.sendKeepAlive(ack: true)
            case .disconnected:
                if pendingFiles.isEmpty && expectedTextPayload == nil {
                    await finish(.finished(savedFiles: savedURLs))
                } else {
                    throw SWIFTError.connectionLost
                }
                return
            case .ignored:
                continue
            }
        }
    }

    /// Test seam for `saveSharedText`, which is otherwise only reachable partway
    /// through a live session.
    nonisolated func saveSharedTextForTesting(_ data: Data, title: String, isLink: Bool) throws -> URL {
        try saveSharedText(data, title: title, isLink: isLink)
    }

    /// Writes shared text to the receive folder.
    ///
    /// A link is saved as a `.webloc`, which Finder treats as a clickable
    /// bookmark. Deliberately *not* opened automatically the way the reference
    /// implementation did: with auto-accept enabled that would let a device on
    /// the network open a URL on this Mac with no interaction at all.
    nonisolated private func saveSharedText(_ data: Data, title: String, isLink: Bool) throws -> URL {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw SWIFTError.protocolViolation("shared text is not valid UTF-8")
        }

        // Colons are legal in HFS names but read as path separators in Finder,
        // so the fallback name uses dots.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let fallback = "Shared text \(stamp.string(from: Date()))"

        let base = ReceivedFileName.sanitize(title.isEmpty ? fallback : title)
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        if isLink, let link = URL(string: trimmed), link.scheme != nil {
            let destination = try ReceivedFileName.uniqueDestination(
                for: "\(base).webloc", in: receiveDirectory)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["URL": link.absoluteString],
                format: .xml, options: 0)
            try plist.write(to: destination, options: .atomic)
            Self.applyQuarantine(to: destination)
            return destination
        }

        let destination = try ReceivedFileName.uniqueDestination(
            for: "\(base).txt", in: receiveDirectory)
        try Data(contents.utf8).write(to: destination, options: .atomic)
        Self.applyQuarantine(to: destination)
        return destination
    }

    /// Marks network-delivered content so Gatekeeper and Finder treat it like
    /// a browser download. Failure is non-fatal because some filesystems do not
    /// support extended attributes.
    nonisolated private static func applyQuarantine(to url: URL) {
        let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));SWIFT;"
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            value.withCString { bytes in
                _ = setxattr(path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0)
            }
        }
    }

    private func writeChunk(header: PayloadHeader, chunk: PayloadChunk) throws {
        guard let payloadID = header.id, var file = pendingFiles[payloadID] else {
            throw SWIFTError.protocolViolation("chunk for an unknown payload")
        }
        guard chunk.offset ?? 0 == file.bytesWritten else {
            throw SWIFTError.protocolViolation("unexpected file chunk offset")
        }

        if let body = chunk.body, !body.isEmpty {
            // Never write more than was declared and consented to.
            guard file.bytesWritten + Int64(body.count) <= file.metadata.size else {
                throw SWIFTError.protocolViolation("file exceeded its declared size")
            }
            file.handle?.write(body)
            file.bytesWritten += Int64(body.count)
            totalReceivedBytes += Int64(body.count)
            pendingFiles[payloadID] = file

            if totalExpectedBytes > 0 {
                continuation?.yield(.progress(
                    min(1.0, Double(totalReceivedBytes) / Double(totalExpectedBytes))))
            }
        }

        if chunk.isLastChunk {
            guard file.bytesWritten == file.metadata.size else {
                throw SWIFTError.protocolViolation("file ended before its declared size")
            }
            try? file.handle?.close()
            do {
                try FileManager.default.moveItem(
                    at: file.temporaryURL, to: file.destination)
            } catch {
                try? FileManager.default.removeItem(at: file.temporaryURL)
                throw SWIFTError.localFailure(
                    "couldn't finish \(file.destination.lastPathComponent)")
            }
            Self.applyQuarantine(to: file.destination)
            savedURLs.append(file.destination)
            pendingFiles.removeValue(forKey: payloadID)
        }
    }

    // MARK: Teardown

    private func finish(_ event: InboundEvent) async {
        guard !finished else { return }
        finished = true

        // A failed transfer must not leave half-written files behind.
        if case .finished = event {} else {
            for (_, file) in pendingFiles {
                try? file.handle?.close()
                try? FileManager.default.removeItem(at: file.temporaryURL)
            }
        }
        pendingFiles.removeAll()

        continuation?.yield(event)
        continuation?.finish()
        continuation = nil
        await channel.close()
    }
}

import Foundation
import Network
import CryptoKit
import UniformTypeIdentifiers

/// Sends a transfer: performs the UKEY2 handshake as the client, offers the
/// files, and streams them once the remote user accepts.
public actor OutboundSession {

    /// How much file data goes in one chunk.
    private static let chunkSize = 512 * 1024

    public let id: String
    private let channel: FrameChannel
    private let files: [OutgoingFile]
    private let localName: String
    private let localEndpointID: String
    /// Set when the phone arrived by scanning our QR code.
    private let qrSession: QRCodeSession?
    /// Sends this short text instead of files.
    private let note: String?
    private var notePayloadID: Int64 = 0

    private var secure: SecureChannel?
    private var continuation: AsyncStream<OutboundEvent>.Continuation?
    private var started = false
    private var finished = false
    private var cancelled = false
    /// Set once the UKEY2 handshake has produced keys. Until then a silent
    /// peer is a stuck transfer, not a slow file copy.
    private var handshakeFinished = false

    private var totalBytes: Int64 = 0
    private var sentBytes: Int64 = 0
    private var payloadIDs: [Int64] = []

    // MARK: Concurrent reading
    //
    // The peer keeps talking while we send: it sends keep-alives that expect an
    // ack, and it may cancel. A send loop that never reads misses both — the
    // phone concludes the link is dead and aborts, while we happily finish
    // writing and report success. So one reader runs for the whole session,
    // concurrently with the writes.
    private var readerTask: Task<Void, Never>?
    /// A failure the peer reported. Checked between chunks and before finishing.
    private var peerError: SWIFTError?
    /// Set once every byte is out, so a socket close after that reads as normal
    /// rather than as a failure.
    private var sendingComplete = false
    private var peerDisconnected = false
    private var consentWaiter: CheckedContinuation<SharingResponseStatus, Never>?
    /// A decision that arrived before anyone was waiting for it.
    ///
    /// Sending the introduction has `await` points, so a peer that answers
    /// instantly — anything automated, or a fast link — can be answered before
    /// the waiter exists. Dropping that signal deadlocks the send.
    private var bufferedConsent: SharingResponseStatus?
    /// Woken when the peer reacts after the last byte — see `waitForPeerToSettle`.
    private var settleWaiter: CheckedContinuation<Void, Never>?

    public init(connection: NWConnection, id: String, files: [OutgoingFile],
                localName: String, localEndpointID: String,
                qrSession: QRCodeSession? = nil, note: String? = nil) {
        self.qrSession = qrSession
        self.note = note
        self.id = id
        self.channel = FrameChannel(connection: connection)
        self.files = files
        self.localName = localName
        self.localEndpointID = localEndpointID
    }

    /// Runs the session. The stream finishes when the transfer ends.
    ///
    /// Callable once. A second call would replace the event continuation and
    /// start a second handshake on a socket already in use, so it hands back an
    /// already-finished stream instead.
    public func events() -> AsyncStream<OutboundEvent> {
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

    public func cancel() async {
        cancelled = true
        if let secure {
            try? await secure.sendSetupFrame(.cancel())
            try? await secure.sendDisconnect()
        }
        await finish(.failed(.rejected(.userCanceled)))
    }

    // MARK: Main flow

    private func run() async {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.abortStuckHandshake()
        }
        defer { watchdog.cancel() }
        do {
            try await channel.start()
            let keys = try await performHandshake()
            handshakeFinished = true
            watchdog.cancel()
            continuation?.yield(.connected(pinCode: keys.pinCode))
            try await exchangeSetupFrames(authKey: keys.authString)
            // From here the peer can speak unprompted, so read continuously.
            startReader()
            try await sendIntroductionAndAwaitConsent()
            if note != nil { try await sendNote() } else { try await sendFiles() }
        } catch let error as SWIFTError {
            await finish(.failed(error))
        } catch {
            await finish(.failed(.localFailure(error.localizedDescription)))
        }
    }

    /// Ends a transfer that never got past the handshake. A file already in
    /// flight is left alone; that wait is the phone accepting or reading.
    private func abortStuckHandshake() async {
        guard !handshakeFinished, !finished else { return }
        await finish(.failed(.timedOut))
    }

    private func performHandshake() async throws -> UKey2.SessionKeys {
        // 1. ConnectionRequest.
        var request = ConnectionRequestFrame()
        request.endpointID = localEndpointID
        request.endpointName = localName
        request.endpointInfo = EndpointInfo(name: localName, deviceType: .computer).serialized()
        // Declare the transport, matching the reference implementation —
        // omitting it would be an unexplained divergence on a path that
        // talks to real Android devices.
        request.mediums = [.wifiLan]
        var v1 = V1Frame()
        v1.type = .connectionRequest
        v1.connectionRequest = request
        try await channel.send(frame: OfflineFrame.wrapping(v1).serialized())

        // 2. Ukey2ClientInit. The commitment is SHA-512 over the *exact* bytes of
        // the ClientFinished we will send later, so build that first.
        let keyPair = UKey2.KeyPair()
        let clientFinished: Ukey2ClientFinished = {
            var f = Ukey2ClientFinished()
            f.publicKey = keyPair.genericPublicKey.serialized()
            return f
        }()
        let clientFinishedBytes = Ukey2Message(type: .clientFinish,
                                               data: clientFinished.serialized()).serialized()

        var commitment = Ukey2CipherCommitment()
        commitment.handshakeCipher = .p256Sha512
        commitment.commitment = Data(SHA512.hash(data: clientFinishedBytes))

        var clientInit = Ukey2ClientInit()
        clientInit.version = 1
        clientInit.random = Data.secureRandom(count: 32)
        clientInit.nextProtocol = "AES_256_CBC-HMAC_SHA256"
        clientInit.cipherCommitments = [commitment]
        let clientInitBytes = Ukey2Message(type: .clientInit,
                                           data: clientInit.serialized()).serialized()
        try await channel.send(frame: clientInitBytes)

        // 3. Ukey2ServerInit.
        let serverInitBytes = try await channel.receiveFrame()
        let serverInitMessage = try Ukey2Message(serialized: serverInitBytes)
        guard serverInitMessage.messageType == .serverInit else {
            throw SWIFTError.handshakeFailed("expected server init")
        }
        let serverInit = try Ukey2ServerInit(serialized: serverInitMessage.messageData ?? Data())
        guard serverInit.version == 1 else {
            throw SWIFTError.handshakeFailed("unsupported UKEY2 version")
        }
        guard serverInit.random?.count == 32 else {
            throw SWIFTError.handshakeFailed("bad server random")
        }
        guard serverInit.handshakeCipher == .p256Sha512 else {
            throw SWIFTError.handshakeFailed("unsupported handshake cipher")
        }
        guard let serverKeyBytes = serverInit.publicKey else {
            throw SWIFTError.missingField("serverInit.publicKey")
        }
        let serverGeneric = try GenericPublicKey(serialized: serverKeyBytes)
        guard let serverEc = serverGeneric.ecP256PublicKey else {
            throw SWIFTError.missingField("server public key")
        }
        let peerKey = try UKey2.publicKey(from: serverEc)

        // 4. Ukey2ClientFinished — the same bytes the commitment covered.
        try await channel.send(frame: clientFinishedBytes)

        let keys = try UKey2.deriveSessionKeys(
            ourPrivateKey: keyPair.privateKey,
            peerPublicKey: peerKey,
            clientInitBytes: clientInitBytes,
            serverInitBytes: serverInitBytes,
            isServer: false)

        // 5. ConnectionResponse in the clear, then encryption is live.
        var accept = ConnectionResponseFrame()
        accept.response = .accept
        accept.status = 0
        accept.osInfo = OsInfo(type: .apple)
        var responseFrame = V1Frame()
        responseFrame.type = .connectionResponse
        responseFrame.connectionResponse = accept
        try await channel.send(frame: OfflineFrame.wrapping(responseFrame).serialized())

        let peerResponse = try OfflineFrame(serialized: try await channel.receiveFrame())
        guard peerResponse.v1?.connectionResponse?.response == .accept else {
            throw SWIFTError.rejected(.userRejected)
        }

        secure = SecureChannel(channel: channel, keys: keys)
        return keys
    }

    private func exchangeSetupFrames(authKey: SymmetricKey) async throws {
        guard let secure else { throw SWIFTError.internalFailure("no secure channel") }
        try await secure.sendSetupFrame(.pairedKeyEncryption(
            secretIDHash: Data.secureRandom(count: 6),
            signedData: Data.secureRandom(count: 72),
            // A phone that scanned a code refuses a sender that can't prove it showed it.
            qrCodeHandshakeData: qrSession?.handshakeSignature(authKey: authKey)))

        var sawEncryption = false
        var sawResult = false
        while !(sawEncryption && sawResult) {
            switch try await secure.receive() {
            case .setupFrame(let frame):
                switch frame.v1?.type {
                case .pairedKeyEncryption:
                    sawEncryption = true
                    try await secure.sendSetupFrame(.pairedKeyResult(.unable))
                case .pairedKeyResult:
                    sawResult = true
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

    // MARK: Reader

    private func startReader() {
        guard let secure else { return }
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let incoming = try await secure.receive()
                    await self?.handle(incoming, on: secure)
                } catch let error as SWIFTError {
                    await self?.readerStopped(error)
                    return
                } catch {
                    await self?.readerStopped(.connectionLost)
                    return
                }
            }
        }
    }

    private func handle(_ incoming: SecureChannel.Incoming, on secure: SecureChannel) async {
        switch incoming {
        case .keepAlive:
            // The whole point of reading during a send: miss these and the peer
            // decides we're gone.
            try? await secure.sendKeepAlive(ack: true)

        case .setupFrame(let frame):
            guard let v1 = frame.v1 else { return }
            if v1.type == .cancel {
                fail(.rejected(.userCanceled))
                return
            }
            if v1.type == .response, let status = v1.connectionResponse?.status {
                resumeConsent(status)
            }

        case .disconnected:
            peerDisconnected = true
            // A close before we've finished sending means it didn't land.
            if !sendingComplete { fail(.connectionLost) }
            resumeConsent(.reject)
            signalSettled()

        case .fileChunk, .bytesPayload, .ignored:
            return
        }
    }

    private func readerStopped(_ error: SWIFTError) {
        peerDisconnected = true
        // Once every byte is out, the peer hanging up is the expected ending.
        if !sendingComplete { fail(error) }
        resumeConsent(.reject)
        signalSettled()
    }

    private func fail(_ error: SWIFTError) {
        if peerError == nil { peerError = error }
        // Anyone waiting on the peer's verdict has it now.
        signalSettled()
    }

    private func resumeConsent(_ status: SharingResponseStatus) {
        if let waiter = consentWaiter {
            consentWaiter = nil
            waiter.resume(returning: status)
        } else if bufferedConsent == nil {
            bufferedConsent = status
        }
    }

    /// Waits for the peer's decision, taking one that already arrived.
    ///
    /// The check and the continuation install happen with no `await` between
    /// them, so the reader cannot slip in and be dropped.
    private func awaitConsent() async -> SharingResponseStatus {
        if let already = bufferedConsent {
            bufferedConsent = nil
            return already
        }
        return await withCheckedContinuation { continuation in
            self.consentWaiter = continuation
        }
    }

    // MARK: Offer

    private func sendIntroductionAndAwaitConsent() async throws {
        guard let secure else { throw SWIFTError.internalFailure("no secure channel") }
        guard note != nil || (!files.isEmpty && files.count <= InboundSession.maxFilesPerTransfer) else {
            throw SWIFTError.localFailure(
                "A transfer can contain at most \(InboundSession.maxFilesPerTransfer) files")
        }

        var introduction = IntroductionFrame()
        for file in files {
            guard file.size >= 0, file.size <= InboundSession.maxFileBytes else {
                throw SWIFTError.localFailure("\(file.name) has an unsupported size")
            }
            let (newTotal, overflowed) = totalBytes.addingReportingOverflow(file.size)
            guard !overflowed else {
                throw SWIFTError.localFailure("The selected files are too large")
            }
            var meta = SharingFileMetadata()
            meta.name = file.name
            meta.size = file.size
            meta.mimeType = file.mimeType
            meta.type = Self.fileType(for: file)
            let payloadID = Int64.random(in: Int64.min...Int64.max)
            meta.payloadID = payloadID
            payloadIDs.append(payloadID)
            introduction.fileMetadata.append(meta)
            totalBytes = newTotal
        }
        if let note {
            var text = SharingTextMetadata()
            text.textTitle = "SWIFT"
            text.type = .text
            notePayloadID = Int64.random(in: 1...Int64.max)
            text.payloadID = notePayloadID
            text.size = Int64(note.utf8.count)
            text.id = Int64.random(in: 1...Int64.max)
            introduction.textMetadata.append(text)
        }
        try await secure.sendSetupFrame(.introduction(introduction))

        // The reader delivers the decision; it also keeps acking keep-alives
        // while the user takes their time over the prompt.
        let status = await awaitConsent()

        if let peerError { throw peerError }

        switch status {
        case .accept:
            continuation?.yield(.accepted)
        case .reject, .unknown:          throw SWIFTError.rejected(.userRejected)
        case .notEnoughSpace:            throw SWIFTError.rejected(.notEnoughSpace)
        case .unsupportedAttachmentType: throw SWIFTError.rejected(.unsupportedType)
        case .timedOut:                  throw SWIFTError.rejected(.timedOut)
        }
    }

    private func sendNote() async throws {
        guard let secure, let note else { throw SWIFTError.internalFailure("no secure channel") }
        let body = Data(note.utf8)
        var header = PayloadHeader()
        header.id = notePayloadID
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
        try await secure.send(.payloadTransfer(transfer))

        var end = PayloadChunk()
        end.offset = Int64(body.count)
        end.flags = PayloadChunk.lastChunkFlag
        transfer.payloadChunk = end
        try await secure.send(.payloadTransfer(transfer))

        sendingComplete = true
        try? await secure.sendDisconnect()
        await waitForPeerToSettle()
        if let peerError { throw peerError }
        await finish(.finished)
    }

    private func sendFiles() async throws {
        guard let secure else { throw SWIFTError.internalFailure("no secure channel") }

        for (index, file) in files.enumerated() {
            guard !cancelled else { throw SWIFTError.rejected(.userCanceled) }
            if let peerError { throw peerError }
            let payloadID = payloadIDs[index]
            guard let handle = try? FileHandle(forReadingFrom: file.url) else {
                throw SWIFTError.localFailure("couldn't read \(file.name)")
            }
            defer { try? handle.close() }

            var offset: Int64 = 0
            while offset < file.size {
                guard !cancelled else { throw SWIFTError.rejected(.userCanceled) }
                // Stop the moment the peer says it can't take this, instead of
                // writing megabytes into a connection that's already given up.
                if let peerError { throw peerError }
                // Distinguish a read failure from end-of-file: silently sending
                // short would leave the receiver waiting on bytes that never come.
                let chunkData: Data?
                do {
                    chunkData = try handle.read(upToCount: Self.chunkSize)
                } catch {
                    throw SWIFTError.localFailure("couldn't read \(file.name)")
                }
                guard let body = chunkData, !body.isEmpty else { break }

                var header = PayloadHeader()
                header.id = payloadID
                header.type = .file
                header.totalSize = file.size
                header.isSensitive = false

                var chunk = PayloadChunk()
                chunk.offset = offset
                chunk.flags = 0
                chunk.body = body

                var transfer = PayloadTransferFrame()
                transfer.packetType = .data
                transfer.payloadHeader = header
                transfer.payloadChunk = chunk
                try await secure.send(.payloadTransfer(transfer))

                offset += Int64(body.count)
                sentBytes += Int64(body.count)
                if totalBytes > 0 {
                    continuation?.yield(.progress(min(1.0, Double(sentBytes) / Double(totalBytes))))
                }
            }

            // The size went out in the introduction the peer consented to, so a
            // file that shrank underneath us is an error, not a short send.
            guard offset == file.size else {
                throw SWIFTError.localFailure("\(file.name) changed while sending")
            }

            // Empty final chunk marks end of file.
            var header = PayloadHeader()
            header.id = payloadID
            header.type = .file
            header.totalSize = file.size
            header.isSensitive = false

            var endChunk = PayloadChunk()
            endChunk.offset = offset
            endChunk.flags = PayloadChunk.lastChunkFlag

            var transfer = PayloadTransferFrame()
            transfer.packetType = .data
            transfer.payloadHeader = header
            transfer.payloadChunk = endChunk
            try await secure.send(.payloadTransfer(transfer))
        }

        // Every byte is out. From here a socket close is the normal ending.
        sendingComplete = true
        try? await secure.sendDisconnect()

        // Give the peer a chance to object before calling this a success — the
        // difference between "sent" and "the phone couldn't take it". The reader
        // wakes us the moment it knows, so the usual case costs nothing; the
        // timeout only applies to a peer that goes quiet without closing.
        await waitForPeerToSettle()
        if let peerError { throw peerError }

        await finish(.finished)
    }

    /// How long to wait for the peer's reaction after the last byte.
    private static let settleTimeout = Duration.seconds(2)

    private func waitForPeerToSettle() async {
        if peerError != nil || peerDisconnected { return }

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.settleTimeout)
            await self?.signalSettled()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.settleWaiter = continuation
        }
        timeout.cancel()
    }

    /// Wakes `waitForPeerToSettle`. Safe to call when nobody is waiting.
    private func signalSettled() {
        guard let waiter = settleWaiter else { return }
        settleWaiter = nil
        waiter.resume()
    }

    /// Best-effort content classification from the MIME type.
    private static func fileType(for file: OutgoingFile) -> SharingFileType {
        if file.mimeType.hasPrefix("image/") { return .image }
        if file.mimeType.hasPrefix("video/") { return .video }
        if file.mimeType.hasPrefix("audio/") { return .audio }
        if file.url.pathExtension.lowercased() == "apk" { return .androidApp }
        return .unknown
    }

    private func finish(_ event: OutboundEvent) async {
        guard !finished else { return }
        finished = true

        // Closing the channel is what actually releases the reader: it's parked
        // in a continuation around an NWConnection callback, which task
        // cancellation can't interrupt. The cancel below only stops it looping
        // again once that callback returns.
        readerTask?.cancel()
        readerTask = nil
        // Nothing is going to answer these now.
        resumeConsent(.reject)
        signalSettled()

        continuation?.yield(event)
        continuation?.finish()
        continuation = nil
        await channel.close()
    }
}

public extension OutgoingFile {
    /// Builds an outgoing file from a URL, resolving size and MIME type.
    static func from(url: URL) throws -> OutgoingFile {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, values.isReadable != false else {
            throw SWIFTError.localFailure("\(url.lastPathComponent) is not a readable file")
        }
        guard let fileSize = values.fileSize, fileSize >= 0 else {
            throw SWIFTError.localFailure("Couldn't determine the size of \(url.lastPathComponent)")
        }
        let size = Int64(fileSize)
        guard size <= InboundSession.maxFileBytes else {
            throw SWIFTError.localFailure("\(url.lastPathComponent) is too large")
        }
        let mime = OutgoingFile.advertisedMIMEType(
            sniffed: values.contentType?.preferredMIMEType,
            pathExtension: url.pathExtension)
        // The name goes to a remote device; keep it to one plain component.
        return OutgoingFile(url: url,
                            name: ReceivedFileName.sanitize(url.lastPathComponent),
                            size: size,
                            mimeType: mime)
    }
}

import Foundation
import Network

/// The whole protocol, behind one object.
///
/// Everything above this line — the app — deals in devices, offers and
/// progress. Sockets, protobufs and key schedules stay below it.
@MainActor
public final class SWIFTEngine {

    // MARK: Callbacks

    /// Advertising actually started or stopped (not merely requested).
    public var onVisibilityChange: (@MainActor (Bool) -> Void)?
    public var onDeviceFound: (@MainActor (SWIFTDevice) -> Void)?
    public var onDeviceLost: (@MainActor (String) -> Void)?
    /// A peer is offering files. Answer with `respondToOffer(id:accept:)`.
    public var onOfferReceived: (@MainActor (IncomingOffer) -> Void)?
    public var onIncomingProgress: (@MainActor (String, Double) -> Void)?
    public var onIncomingFinished: (@MainActor (String, [URL], SWIFTError?) -> Void)?
    public var onOutgoingEvent: (@MainActor (String, OutboundEvent) -> Void)?
    /// A device scanned our QR code and is now reachable.
    public var onQRDeviceMatched: (@MainActor (SWIFTDevice) -> Void)?

    // MARK: State

    public private(set) var deviceName: String
    public var receiveDirectory: URL

    private let advertiser: ServiceAdvertiser
    private let browser: ServiceBrowser
    private let endpointID: [UInt8]

    private var inboundSessions: [String: InboundSession] = [:]
    private var outboundSessions: [String: OutboundSession] = [:]

    /// - Parameter endpointID: A previously used 4-character id. Reusing it keeps
    ///   one stable entry on nearby phones across launches. Without it, every
    ///   relaunch looks like a second Mac until the phone's old entry expires.
    public init(deviceName: String, receiveDirectory: URL, endpointID: [UInt8]? = nil) {
        self.deviceName = deviceName
        self.receiveDirectory = receiveDirectory
        let chosenID: [UInt8]
        if let endpointID, Self.isValidEndpointID(endpointID) {
            chosenID = endpointID
        } else {
            chosenID = Self.makeEndpointID()
        }
        self.endpointID = chosenID
        self.advertiser = ServiceAdvertiser(deviceName: deviceName, endpointID: chosenID)
        self.browser = ServiceBrowser()

        advertiser.onVisibilityChange = { [weak self] visible in
            self?.onVisibilityChange?(visible)
        }
        advertiser.onConnection = { [weak self] connection, id in
            self?.acceptInbound(connection: connection, id: id)
        }
        browser.onFound = { [weak self] device, _ in self?.onDeviceFound?(device) }
        browser.onLost = { [weak self] id in self?.onDeviceLost?(id) }
        browser.onQRMatch = { [weak self] device in self?.onQRDeviceMatched?(device) }
    }

    // MARK: QR send

    /// Starts a QR offer and returns the link to display. Discovery must be
    /// running for the scanning device to be spotted.
    public func beginQRSession() -> String {
        let session = QRCodeSession()
        browser.qrSession = session
        return session.url
    }

    public func endQRSession() {
        browser.qrSession = nil
    }

    /// The id is exactly four ASCII letters or digits.
    nonisolated public static func isValidEndpointID(_ id: [UInt8]?) -> Bool {
        guard let id, id.count == 4 else { return false }
        return id.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }
    }

    /// The id this engine advertises, so the app can store it.
    public var advertisedEndpointID: [UInt8] { endpointID }

    /// Four random alphanumerics, as the protocol expects.
    nonisolated public static func makeEndpointID() -> [UInt8] {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var rng = SystemRandomNumberGenerator()
        return (0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
    }

    // MARK: Receiving

    public func startAdvertising() { advertiser.start() }
    public func stopAdvertising() { advertiser.stop() }

    public func setDeviceName(_ name: String) {
        deviceName = name
        advertiser.updateDeviceName(name)
    }

    public func respondToOffer(id: String, accept: Bool) {
        guard let session = inboundSessions[id] else { return }
        Task { await session.respond(accept: accept) }
    }

    /// Names learned earlier. Load this before discovery starts.
    public var peerMemory: PeerMemory {
        get { browser.memory }
        set { browser.memory = newValue }
    }

    public var onPeerMemoryChanged: (@MainActor (PeerMemory) -> Void)? {
        get { browser.onMemoryChanged }
        set { browser.onMemoryChanged = newValue }
    }

    /// The sender's IPv4 address, including one carried in an IPv6 socket.
    nonisolated static func ipv4Host(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16, bytes[..<10].allSatisfy({ $0 == 0 }),
                  bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
            return bytes[12...].map(String.init).joined(separator: ".")
        default:
            return nil
        }
    }

    private func acceptInbound(connection: NWConnection, id: String) {
        let session = InboundSession(connection: connection, id: id,
                                     receiveDirectory: receiveDirectory)
        inboundSessions[id] = session

        Task { [weak self] in
            let stream = await session.events()
            for await event in stream {
                guard let self else { return }
                switch event {
                case .offerReceived(let offer):
                    if let host = Self.ipv4Host(of: connection.endpoint) {
                        self.browser.learnFromTransfer(name: offer.device.name, host: host)
                    }
                    self.onOfferReceived?(offer)
                case .progress(let fraction):
                    self.onIncomingProgress?(id, fraction)
                case .finished(let urls):
                    self.onIncomingFinished?(id, urls, nil)
                case .failed(let error):
                    self.onIncomingFinished?(id, [], error)
                }
            }
            self?.inboundSessions.removeValue(forKey: id)
        }
    }

    // MARK: Sending

    public func startDiscovery() { browser.start() }

    /// Address the browser has for this phone, when the advertisement included one.
    public func dialAddress(for deviceID: String) -> (host: String, port: Int)? {
        guard let address = browser.address(for: deviceID) else { return nil }
        return (address.host, Int(address.port))
    }

    /// The share sheet resolved the phone. Make that the device a send dials.
    public func supplyDevice(id: String, name: String, host: String, port: Int) {
        guard (1...65535).contains(port) else { return }
        browser.supply(id: id, name: name, host: host, port: UInt16(port))
    }

    /// The phone's own name, read from its Bluetooth announcement.
    public func noteBluetoothName(endpointID: String, name: String) {
        browser.noteBluetoothName(endpointID: endpointID, name: name)
    }
    public func stopDiscovery() { browser.stop() }

    /// Connects to `device` and offers `files`. The transfer id is returned so
    /// the caller can correlate events and cancel.
    ///
    /// One transfer is in flight per device. A new send replaces a previous
    /// one that is still open, instead of failing while that socket sits in
    /// the map. The previous task only drops the map entry when it still owns
    /// it, so its cleanup cannot erase the replacement.
    @discardableResult
    public func send(files: [OutgoingFile], to device: SWIFTDevice) -> String {
        let transferID = device.id
        if let previous = outboundSessions.removeValue(forKey: transferID) {
            Task { await previous.cancel() }
        }
        let localEndpointID = String(decoding: endpointID, as: UTF8.self)
        // The address in the advertisement is what the phone is listening on
        // right now. The service name is the second try, for a port that moved.
        let routes = connectionRoutes(for: device.id)
        guard let first = routes.first else {
            onOutgoingEvent?(transferID, .failed(.localFailure("Couldn't reach \(device.name)")))
            return transferID
        }
        startOutbound(files: files, to: device, transferID: transferID,
                      localEndpointID: localEndpointID, connection: first,
                      remaining: Array(routes.dropFirst()))
        return transferID
    }

    /// Opens the transfer on `connection`. If that socket never comes up, the
    /// next route is tried before the sheet is told the phone is unreachable.
    private func startOutbound(files: [OutgoingFile], to device: SWIFTDevice,
                               transferID: String, localEndpointID: String,
                               connection: NWConnection, remaining: [NWConnection]) {
        let session = OutboundSession(connection: connection, id: transferID, files: files,
                                      localName: deviceName, localEndpointID: localEndpointID,
                                      qrSession: browser.qrSession)
        outboundSessions[transferID] = session

        Task { [weak self] in
            let stream = await session.events()
            var reachedPhone = false
            for await event in stream {
                guard self?.outboundSessions[transferID] === session else { return }
                if case .connected = event { reachedPhone = true }
                if case .failed = event, !reachedPhone, let next = remaining.first {
                    self?.startOutbound(files: files, to: device, transferID: transferID,
                                        localEndpointID: localEndpointID, connection: next,
                                        remaining: Array(remaining.dropFirst()))
                    return
                }
                self?.onOutgoingEvent?(transferID, event)
            }
            if self?.outboundSessions[transferID] === session {
                self?.outboundSessions.removeValue(forKey: transferID)
            }
        }
    }

    /// Routes to try, fastest first. An explicit same-subnet address connects
    /// in about a second. Forcing the Wi-Fi interface type on that socket
    /// leaves it in `.waiting`, so the phone never shows a PIN.
    private func connectionRoutes(for deviceID: String) -> [NWConnection] {
        func lanParameters() -> NWParameters {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            return parameters
        }
        var routes: [NWConnection] = []
        if let address = browser.address(for: deviceID),
           QuickShareAddress.sharesSubnet(address.host),
           let ip = IPv4Address(address.host),
           let port = NWEndpoint.Port(rawValue: address.port) {
            routes.append(NWConnection(host: .ipv4(ip), port: port, using: lanParameters()))
        }
        if let endpoint = browser.wifiEndpoint(for: deviceID) {
            routes.append(NWConnection(to: endpoint, using: lanParameters()))
        }
        return routes
    }

    /// A phone that scans a code waits for the sender. Connect and leave it a
    /// short confirmation, so scanning ends normally rather than with an error.
    public func finishAddPhone(device: SWIFTDevice) {
        guard let qrSession = browser.qrSession else { return }
        let note = "Added to \(deviceName)"
        let localID = String(decoding: endpointID, as: UTF8.self)
        let routes = connectionRoutes(for: device.id)
        Task { [deviceName, self] in
            for route in routes {
                let session = OutboundSession(connection: route, id: "add-\(device.id)", files: [],
                                              localName: deviceName, localEndpointID: localID,
                                              qrSession: qrSession, note: note)
                var reachedPhone = false
                var failedEarly = false
                for await event in await session.events() {
                    if case .connected = event {
                        reachedPhone = true
                        // The address of the live connection, in case the
                        // advertisement never gave one.
                        if let path = route.currentPath?.remoteEndpoint, let host = Self.ipv4Host(of: path) {
                            self.browser.learnFromTransfer(name: device.name, host: host)
                        }
                    }
                    if case .failed = event, !reachedPhone { failedEarly = true }
                }
                if !failedEarly { return }
            }
        }
    }

    public func cancelTransfer(id: String) {
        if let outbound = outboundSessions[id] {
            Task { await outbound.cancel() }
        }
        if let inbound = inboundSessions[id] {
            Task { await inbound.cancel() }
        }
    }
}

import CryptoKit
import Darwin
import Foundation
import Network

/// The small binary blob a device advertises about itself — in the mDNS TXT
/// record when browsing, and in the connection request when connecting.
///
/// Layout:
///   byte 0      flags: bit 4 set means "no name"; bits 1-3 are the device type
///   bytes 1-16  16 random bytes (purpose unknown; treated as opaque)
///   byte 17     device-name length, when a name is present
///   bytes 18..  device name, UTF-8
///   remainder   optional TLV records (type 1 carries QR handshake data)
public struct EndpointInfo: Sendable, Equatable {
    public var name: String?
    public var deviceType: SWIFTDevice.DeviceType
    public var qrCodeData: Data?

    /// Longest name we will emit or accept; the length field is a single byte.
    static let maxNameBytes = 255
    private static let noNameFlag: UInt8 = 0x10
    private static let headerLength = 18

    public init(name: String?, deviceType: SWIFTDevice.DeviceType, qrCodeData: Data? = nil) {
        self.name = name
        self.deviceType = deviceType
        self.qrCodeData = qrCodeData
    }

    // MARK: Decoding

    public init(serialized data: Data) throws {
        let bytes = [UInt8](data)
        // A phone that is not "visible to everyone" omits the name. Samsung
        // Quick Share does this while its receive screen is open: one flag byte
        // and 16 id bytes, 17 in total. Named records are longer.
        guard bytes.count >= 17 else {
            throw SWIFTError.protocolViolation("endpoint info too short")
        }

        let flags = bytes[0]
        // Device type is bits 1-3.
        self.deviceType = SWIFTDevice.DeviceType(rawDeviceType: Int((flags & 0x0E) >> 1))

        var offset = 17
        if flags & Self.noNameFlag == 0 {
            guard bytes.count >= Self.headerLength else {
                throw SWIFTError.protocolViolation("endpoint info too short")
            }
            let nameLength = Int(bytes[17])
            offset = 18
            guard bytes.count >= offset + nameLength else {
                throw SWIFTError.protocolViolation("endpoint info name overruns the buffer")
            }
            guard let decoded = String(bytes: bytes[offset..<(offset + nameLength)], encoding: .utf8) else {
                throw SWIFTError.protocolViolation("endpoint info name is not valid UTF-8")
            }
            self.name = decoded
            offset += nameLength
        } else {
            self.name = nil
            offset = 17
        }

        // Optional TLV tail. Every iteration consumes at least the 2-byte header,
        // so a malformed record can shorten the scan but never stall it.
        var qr: Data?
        while bytes.count - offset > 2 {
            let type = bytes[offset]
            let length = Int(bytes[offset + 1])
            offset += 2
            guard bytes.count - offset >= length else { break }
            if type == 1 { qr = Data(bytes[offset..<(offset + length)]) }
            offset += length
        }
        self.qrCodeData = qr
    }

    // MARK: Encoding

    public func serialized() -> Data {
        var out = Data()
        var flags = UInt8(deviceType.rawValue & 0x07) << 1
        if name == nil { flags |= Self.noNameFlag }
        out.append(flags)
        out.append(Data.secureRandom(count: 16))

        if let name {
            var nameBytes = [UInt8](name.utf8)
            if nameBytes.count > Self.maxNameBytes {
                // Truncate on a character boundary so the name stays valid UTF-8.
                var truncated = name
                while truncated.utf8.count > Self.maxNameBytes { truncated = String(truncated.dropLast()) }
                nameBytes = [UInt8](truncated.utf8)
            }
            out.append(UInt8(nameBytes.count))
            out.append(contentsOf: nameBytes)
        }
        return out
    }
}

// MARK: - Advertising

/// Advertises this Mac over mDNS and accepts incoming connections.
///
/// Visibility is reported from what actually happened — the listener becoming
/// ready and Bonjour confirming the publish — never from the fact that we asked.
/// A UI that says "visible" while nothing is listening is worse than one that
/// says nothing.
@MainActor
public final class ServiceAdvertiser {

    public static let serviceType = "_FC9F5ED42C8A._tcp."

    /// Called when advertising actually starts or stops.
    public var onVisibilityChange: (@MainActor (Bool) -> Void)?
    /// Called with each accepted connection.
    public var onConnection: (@MainActor (NWConnection, String) -> Void)?

    private var listener: NWListener?
    private var netService: NetService?
    private var serviceDelegate: PublishObserver?
    private let endpointID: [UInt8]
    private var deviceName: String
    private var isRequested = false
    private var reportedVisible = false

    public init(deviceName: String, endpointID: [UInt8]) {
        self.deviceName = deviceName
        self.endpointID = endpointID
    }

    public func updateDeviceName(_ name: String) {
        guard name != deviceName else { return }
        deviceName = name
        // Republish so peers see the new name.
        if isRequested {
            stop()
            start()
        }
    }

    public func start() {
        // Starting an already-started listener is invalid, and visibility is
        // reported asynchronously, so the caller can legitimately ask twice
        // before the first attempt resolves.
        guard !isRequested else { return }
        isRequested = true

        // A cancelled NWListener can never be restarted, so always build a fresh
        // one. Deciding this from an explicit flag rather than by polling
        // `listener.state` avoids racing cancel(), which is asynchronous.
        guard let listener = try? NWListener(using: makeParameters()) else {
            isRequested = false
            report(false)
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.publishBonjour()
                case .failed, .cancelled:
                    self.report(false)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.onConnection?(connection, UUID().uuidString)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        isRequested = false
        netService?.stop()
        netService = nil
        serviceDelegate = nil
        listener?.cancel()
        listener = nil
        report(false)
    }

    private func makeParameters() -> NWParameters {
        let params = NWParameters(tls: nil, tcp: .init())
        params.includePeerToPeer = false
        return params
    }

    private func publishBonjour() {
        guard isRequested, let port = listener?.port else {
            report(false)
            return
        }

        // The service name encodes a fixed prefix plus our endpoint id.
        let nameBytes: [UInt8] = [
            0x23,                                                    // PCP
            endpointID[0], endpointID[1], endpointID[2], endpointID[3],
            0xFC, 0x9F, 0x5E,                                        // service id hash
            0, 0,
        ]
        let serviceName = Data(nameBytes).urlSafeBase64EncodedString()
        let info = EndpointInfo(name: deviceName, deviceType: .computer)
        guard let txtValue = info.serialized().urlSafeBase64EncodedString().data(using: .utf8) else {
            report(false)
            return
        }

        let service = NetService(domain: "", type: Self.serviceType,
                                 name: serviceName, port: Int32(port.rawValue))
        // NetService delivers its delegate callbacks on the run loop it was
        // scheduled on. This runs on the main actor, whose run loop is live, so
        // didPublish/didNotPublish actually arrive — publishing from a bare
        // dispatch queue leaves them silently unfired.
        let observer = PublishObserver { [weak self] visible in
            Task { @MainActor in self?.report(visible) }
        }
        service.delegate = observer
        service.setTXTRecord(NetService.data(fromTXTRecord: ["n": txtValue]))
        serviceDelegate = observer
        netService = service
        service.publish()
    }

    private func report(_ visible: Bool) {
        guard reportedVisible != visible else { return }
        reportedVisible = visible
        onVisibilityChange?(visible)
    }
}

/// Bridges NetService's delegate callbacks back to the advertiser.
///
/// `NetServiceDelegate` is not actor-isolated, so the callback is handed a
/// `@Sendable` reporter that hops to the main actor itself rather than assuming
/// it is already there. Holding only that immutable closure is what makes the
/// unchecked conformance honest.
private final class PublishObserver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let report: @Sendable (Bool) -> Void

    init(report: @escaping @Sendable (Bool) -> Void) {
        self.report = report
    }

    func netServiceDidPublish(_ sender: NetService) {
        report(true)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("SWIFT: mDNS publish failed: \(errorDict)")
        report(false)
    }

    func netServiceDidStop(_ sender: NetService) {
        report(false)
    }
}

// MARK: - URL-safe base64

extension Data {
    /// Base64 with the URL-safe alphabet and no padding, as the protocol uses.
    func urlSafeBase64EncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    static func fromUrlSafeBase64(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        while normalized.count % 4 != 0 { normalized += "=" }
        return Data(base64Encoded: normalized, options: .ignoreUnknownCharacters)
    }
}

// MARK: - Browsing

/// Browses for nearby Quick Share receivers over mDNS.
@MainActor
public final class ServiceBrowser {

    public var onFound: (@MainActor (SWIFTDevice, NWEndpoint) -> Void)?
    public var onLost: (@MainActor (String) -> Void)?
    /// A device that scanned our QR code has appeared.
    public var onQRMatch: (@MainActor (SWIFTDevice) -> Void)?

    /// Set while a QR code is on screen, so we can spot the scanner.
    public var qrSession: QRCodeSession?

    private var browser: NWBrowser?
    /// What we can dial right now. The Bonjour name is not enough: Samsung
    /// replaces that hostname every few seconds, and a connection aimed at the
    /// old name sits until it times out.
    private var peers: [String: Peer] = [:]
    private var resolvers: [String: AddressResolver] = [:]
    /// A disappearance is ignored if the same phone is back before this token changes.
    private var dropTokens: [String: UUID] = [:]

    private struct Peer {
        var endpoint: NWEndpoint
        var address: QuickShareAddress?
        var advertisedIPv4: String?
        var deviceType: SWIFTDevice.DeviceType
        var advertisedName: String?
        /// The Wi-Fi interface this phone was seen on. Connecting on any other
        /// interface is what made a send time out once two phones were online.
        var wifi: NWInterface?
        var resolveToken: UUID
    }
    /// Names read from Bluetooth, keyed by the 4-character Quick Share id.
    /// Only a name from that same phone is stored here.
    private var bluetoothNames: [String: String] = [:]
    /// Service names currently shown in the list. A second advertisement of
    /// the same phone is not one of these.
    private var shownIDs: Set<String> = []
    /// Wi-Fi hardware address of each advertisement that has answered.
    private var hardware: [String: String] = [:]
    private var lookingUp: Set<String> = []
    private var lookupLoop: Task<Void, Never>?
    /// Scans whose name is still waiting for the phone's hardware address.
    private var scanLookups: Set<String> = []
    var hardwareLookup: @Sendable (String) async -> String? = { await HardwareAddress.lookup(host: $0) }
    var scanRetryDelay: Duration = .seconds(1)
    static let scanLookupAttempts = 30
    /// Real names learned earlier. The app loads and saves this.
    public var memory = PeerMemory()
    public var onMemoryChanged: (@MainActor (PeerMemory) -> Void)?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: ServiceAdvertiser.serviceType, domain: nil)
        // Samsung Quick Share publishes on the peer-to-peer interface. A browser
        // that only watches the Wi-Fi LAN never sees that phone, which is why a
        // QR scan was the only way it appeared.
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] _, changes in
            Task { @MainActor in
                guard let self else { return }
                for change in changes {
                    switch change {
                    case .added(let result):
                        self.handleFound(result)
                    case .removed(let result):
                        self.handleLost(result)
                    case .changed(_, let result, _):
                        // A new TXT record is the same phone, not a new one.
                        self.handleFound(result)
                    default:
                        break
                    }
                }
            }
        }
        // Release the reference only once the browse has actually reached
        // `.cancelled` — see `stop()`.
        browser.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            Task { @MainActor in
                guard let self, self.browser === browser else { return }
                browser.browseResultsChangedHandler = nil
                browser.stateUpdateHandler = nil
                self.browser = nil
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
        lookupLoop?.cancel()
        lookupLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self else { return }
                for id in Array(self.peers.keys) where self.hardware[id] == nil { self.identify(id) }
            }
        }
    }

    public func stop() {
        lookupLoop?.cancel()
        lookupLoop = nil
        hardware.removeAll()
        lookingUp.removeAll()
        guard let browser else { return }
        // `cancel()` is asynchronous. Releasing the last strong reference here
        // leaves the nw_browser mid-teardown with its handlers still registered
        // and it never finishes, so the reference is held until
        // `stateUpdateHandler` reports `.cancelled`.
        browser.cancel()
        peers.removeAll()
        resolvers.removeAll()
        dropTokens.removeAll()
        bluetoothNames.removeAll()
        shownIDs.removeAll()
    }

    /// The name from this phone's own Bluetooth packet. `endpointID` is the
    /// 4-character id that packet shares with the Quick Share service.
    public func noteBluetoothName(endpointID: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickShareBLE.isDeviceName(clean), DeviceName.isPossiblePhoneName(clean) else { return }
        bluetoothNames[endpointID] = clean
        reconcile()
    }

    /// The Bonjour endpoint pinned to the Wi-Fi interface it was discovered on.
    /// The system resolves the current host when the connection starts, so a
    /// phone that renames `Android_*.local` is still reachable.
    public func wifiEndpoint(for deviceID: String) -> NWEndpoint? {
        guard let peer = peers[deviceID] else { return nil }
        guard case let .service(name, type, domain, _) = peer.endpoint else { return peer.endpoint }
        return .service(name: name, type: type, domain: domain, interface: peer.wifi)
    }

    /// The share sheet already resolved this phone. Put that address where a
    /// send can use it, including the name the sheet is showing.
    public func supply(id: String, name: String, host: String, port: UInt16) {
        guard let ip = IPv4Address(host), let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(ip), port: nwPort)
        var peer = peers[id] ?? Peer(
            endpoint: endpoint, address: nil, advertisedIPv4: host,
            deviceType: .phone, advertisedName: name, wifi: nil, resolveToken: UUID())
        peer.advertisedName = name
        peer.advertisedIPv4 = host
        peer.address = QuickShareAddress(host: host, port: port)
        if case .hostPort = peer.endpoint { peer.endpoint = endpoint }
        peers[id] = peer
        dropTokens[id] = nil
        reconcile()
    }

    /// The Bonjour endpoint, used when the phone has not given us an address yet.
    public func endpoint(for deviceID: String) -> NWEndpoint? { peers[deviceID]?.endpoint }

    /// The Wi-Fi address from the advertisement. This is the one that stays put.
    public func address(for deviceID: String) -> QuickShareAddress? { peers[deviceID]?.address }

    private func handleFound(_ result: NWBrowser.Result) {
        // Ignore our own advertisement. It is the one that also appears on loopback.
        for interface in result.interfaces where interface.type == .loopback { return }

        guard let endpointID = Self.endpointID(for: result),
              case let .bonjour(txtRecord) = result.metadata,
              let encoded = txtRecord.dictionary["n"],
              let raw = Data.fromUrlSafeBase64(encoded),
              let info = try? EndpointInfo(serialized: raw) else { return }

        // A device that scanned our code advertises a token derived from it, and
        // may be otherwise invisible — its name arrives encrypted instead.
        remember(endpointID, endpoint: result.endpoint,
                advertisedIPv4: txtRecord.dictionary["IPv4"],
                deviceType: info.deviceType, advertisedName: info.name,
                wifi: result.interfaces.first { $0.type == .wifi })
        resolve(endpointID)
        identify(endpointID)

        if let qrSession, let qrData = info.qrCodeData {
            if qrSession.matches(advertisedQRData: qrData) {
                let name = info.name ?? "Scanned device"
                learnScanned(deviceID: endpointID, name: name)
                onQRMatch?(SWIFTDevice(id: endpointID, name: name, type: info.deviceType))
            } else if let decrypted = qrSession.decryptDeviceName(from: qrData) {
                peers[endpointID]?.advertisedName = decrypted
                learnScanned(deviceID: endpointID, name: decrypted)
                onQRMatch?(SWIFTDevice(id: endpointID, name: decrypted, type: info.deviceType))
            }
        }

        reconcile()
    }

    /// One row per phone. A second advertisement of the same phone is dropped,
    /// and a row without that phone's own name is not shown.
    private func reconcile() {
        let sightings = peers.map { id, peer in
            ShareSighting(
                id: id,
                endpointKey: QuickShareBLE.endpointID(fromServiceName: id),
                address: peer.advertisedIPv4 ?? peer.address?.host,
                advertisedName: peer.advertisedName,
                matchedName: QuickShareBLE.endpointID(fromServiceName: id).flatMap { bluetoothNames[$0] }
                    ?? hardware[id].flatMap { memory.name(hardware: $0) })
        }
        let rows = NearbyPeers.rows(sightings)
        let visible = Set(rows.map(\.id))
        for id in shownIDs where !visible.contains(id) {
            onLost?(id)
        }
        shownIDs = visible
        for row in rows {
            guard let peer = peers[row.id] else { continue }
            onFound?(SWIFTDevice(id: row.id, name: row.name, type: peer.deviceType), peer.endpoint)
        }
    }

    private func remember(_ id: String, endpoint: NWEndpoint, advertisedIPv4: String?,
                          deviceType: SWIFTDevice.DeviceType, advertisedName: String?,
                          wifi: NWInterface?) {
        dropTokens[id] = nil
        var peer = peers[id] ?? Peer(endpoint: endpoint, address: nil, advertisedIPv4: nil,
                                     deviceType: deviceType, advertisedName: advertisedName,
                                     wifi: wifi, resolveToken: UUID())
        peer.endpoint = endpoint
        peer.deviceType = deviceType
        // A later advertisement often drops the name. Keep the one we already have.
        if let advertisedName { peer.advertisedName = advertisedName }
        if let wifi { peer.wifi = wifi }
        if let ip = QuickShareAddress.usable(advertisedIPv4), QuickShareAddress.sharesSubnet(ip) {
            peer.advertisedIPv4 = ip
        }
        if let chosen = QuickShareAddress.choose(
            advertisedIPv4: peer.advertisedIPv4,
            resolvedIPv4: peer.address?.host,
            port: Int(peer.address?.port ?? 0)),
           QuickShareAddress.sharesSubnet(chosen.host) {
            peer.address = chosen
        }
        peers[id] = peer
    }

    private func resolve(_ id: String) {
        resolvers[id]?.cancel()
        let token = UUID()
        peers[id]?.resolveToken = token
        let resolver = AddressResolver(name: id, serviceType: ServiceAdvertiser.serviceType) { [weak self] host, port, name in
            Task { @MainActor in
                guard let self, var peer = self.peers[id], peer.resolveToken == token else { return }
                if peer.advertisedName == nil, let name { peer.advertisedName = name }
                if let chosen = QuickShareAddress.choose(
                    advertisedIPv4: peer.advertisedIPv4,
                    resolvedIPv4: host,
                    port: port),
                   QuickShareAddress.sharesSubnet(chosen.host) {
                    peer.address = chosen
                }
                self.peers[id] = peer
                self.resolvers[id] = nil
                self.reconcile()
            }
        }
        resolvers[id] = resolver
    }

    /// Finds the Wi-Fi hardware address behind an advertisement, so a real name
    /// seen once is shown again when the same phone later hides it.
    private func identify(_ id: String) {
        guard let address = peers[id]?.address, !lookingUp.contains(id) else { return }
        lookingUp.insert(id)
        Task { @MainActor [weak self] in
            // The connection is what fills the system's address table.
            let ok = await Self.canConnect(host: address.host, port: address.port, timeout: 2.5)
            let found = ok ? await HardwareAddress.lookup(host: address.host) : nil
            guard let self else { return }
            self.lookingUp.remove(id)
            guard let found, self.peers[id] != nil else { return }
            self.hardware[id] = found
            let bluetooth = QuickShareBLE.endpointID(fromServiceName: id).flatMap { self.bluetoothNames[$0] }
            if let name = self.peers[id]?.advertisedName ?? bluetooth { self.learn(name: name, hardware: found) }
            self.reconcile()
        }
    }

    private func learn(name: String, hardware: String) {
        guard memory.learn(name: name, hardware: hardware) else { return }
        onMemoryChanged?(memory)
    }

    /// A scan delivers the name once, usually before the phone's address is
    /// known, and the phone can stop advertising right after. So the name is
    /// held here and the address is looked up until it appears, even if the
    /// phone has left the list by then.
    func learnScanned(deviceID: String, name: String, host knownHost: String? = nil) {
        guard PeerMemory.isLearnable(name.trimmingCharacters(in: .whitespacesAndNewlines)),
              scanLookups.insert(deviceID).inserted else { return }
        Task { @MainActor [weak self] in
            var host = knownHost
            for _ in 0..<Self.scanLookupAttempts {
                guard let self else { return }
                host = self.peers[deviceID]?.address?.host ?? host
                if let host, let found = await self.hardwareLookup(host) {
                    self.scanLookups.remove(deviceID)
                    self.hardware[deviceID] = found
                    self.learn(name: name, hardware: found)
                    self.reconcile()
                    return
                }
                try? await Task.sleep(for: self.scanRetryDelay)
            }
            self?.scanLookups.remove(deviceID)
        }
    }

    /// A phone gave its real name during a transfer.
    public func learnFromTransfer(name: String, host: String) {
        Task { @MainActor [weak self] in
            guard let found = await HardwareAddress.lookup(host: host), let self else { return }
            self.learn(name: name, hardware: found)
            self.reconcile()
        }
    }

    /// True when something accepts a TCP connection at `host:port` in time.
    nonisolated static func canConnect(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let ip = IPv4Address(host), let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: .ipv4(ip), port: nwPort, using: .tcp)
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .waiting:
                    if once.take() { continuation.resume(returning: false) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.take() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }

    private func handleLost(_ result: NWBrowser.Result) {
        guard let endpointID = Self.endpointID(for: result) else { return }
        let token = UUID()
        dropTokens[endpointID] = token
        // Samsung refreshes the same advertisement and briefly looks gone.
        // Dropping it immediately is what made a tap find nobody to send to.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.dropTokens[endpointID] == token else { return }
            self.peers[endpointID] = nil
            self.resolvers[endpointID] = nil
            self.dropTokens[endpointID] = nil
            self.shownIDs.remove(endpointID)
            self.hardware[endpointID] = nil
            self.onLost?(endpointID)
            self.reconcile()
        }
    }

    private static func endpointID(for result: NWBrowser.Result) -> String? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        return name
    }
}

/// Lets exactly one of several racing callbacks win.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Where a file transfer should connect. The address in the advertisement
/// wins over the one we resolved, because Samsung's hostname changes while
/// that address does not.
public struct QuickShareAddress: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public static func choose(advertisedIPv4: String?, resolvedIPv4: String?, port: Int) -> QuickShareAddress? {
        guard (1...65535).contains(port) else { return nil }
        guard let host = usable(advertisedIPv4) ?? usable(resolvedIPv4) else { return nil }
        return QuickShareAddress(host: host, port: UInt16(port))
    }

    /// True when `host` is on the same local network as this Mac.
    /// A phone can also advertise a VPN address, and dialing that is a timeout.
    public static func sharesSubnet(_ host: String, locals: [String]? = nil) -> Bool {
        guard usable(host) != nil else { return false }
        let locals = locals ?? localIPv4s()
        if locals.isEmpty { return true }
        let hostParts = host.split(separator: ".")
        guard hostParts.count == 4 else { return false }
        return locals.contains { local in
            let parts = local.split(separator: ".")
            return parts.count == 4
                && parts[0] == hostParts[0]
                && parts[1] == hostParts[1]
                && parts[2] == hostParts[2]
        }
    }

    /// Private IPv4 addresses of this Mac, skipping loopback.
    public static func localIPv4s() -> [String] {
        var found: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if host != "127.0.0.1", usable(host) != nil { found.append(host) }
                }
            }
            cursor = current.pointee.ifa_next
        }
        return found
    }

    /// A phone on this network. Anything else is not a Quick Share receiver we should dial.
    public static func usable(_ host: String?) -> String? {
        guard let host, let address = IPv4Address(host) else { return nil }
        let bytes = Array(address.rawValue)
        guard bytes.count == 4 else { return nil }
        switch bytes[0] {
        case 10: return host
        case 192 where bytes[1] == 168: return host
        case 172 where (16...31).contains(bytes[1]): return host
        default: return nil
        }
    }
}

/// Reads the port and address behind one Quick Share advertisement.
private final class AddressResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let finished: (String?, Int, String?) -> Void
    private var reported = false

    init(name: String, serviceType: String, finished: @escaping (String?, Int, String?) -> Void) {
        self.service = NetService(domain: "local.", type: serviceType, name: name)
        self.finished = finished
        super.init()
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        deliver(sender)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        deliver(sender)
    }

    func cancel() {
        reported = true
        service.stop()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard !reported else { return }
        reported = true
        finished(nil, 0, nil)
    }

    /// The address and the name can arrive separately. Send whichever is new,
    /// and stay resolved until the name shows up or the resolve times out.
    private func deliver(_ sender: NetService) {
        guard !reported else { return }
        let name = Self.deviceName(sender)
        let host = Self.bestIPv4(sender.addresses)
        guard name != nil || host != nil else { return }
        finished(host, sender.port, name)
        if name != nil {
            reported = true
            sender.stop()
        }
    }

    /// The browse result often carries the address without the phone's name.
    /// The resolved record has the name, which is what the list has to show.
    private static func deviceName(_ sender: NetService) -> String? {
        guard let data = sender.txtRecordData() else { return nil }
        let record = NetService.dictionary(fromTXTRecord: data)
        guard let encoded = record["n"].flatMap({ String(data: $0, encoding: .utf8) }),
              let raw = Data.fromUrlSafeBase64(encoded),
              let info = try? EndpointInfo(serialized: raw),
              let name = info.name, !name.isEmpty else { return nil }
        return name
    }

    /// The address on the same network as this Mac. A VPN address on the same
    /// record is ignored, because connecting to it never completes.
    private static func bestIPv4(_ addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        var hosts: [String] = []
        for address in addresses {
            guard address.count >= MemoryLayout<sockaddr_in>.size else { continue }
            var storage = sockaddr_storage()
            _ = withUnsafeMutableBytes(of: &storage) { raw in
                address.copyBytes(to: raw.bindMemory(to: UInt8.self))
            }
            guard Int32(storage.ss_family) == AF_INET else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, &storage, MemoryLayout<sockaddr_in>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if host != "0.0.0.0", QuickShareAddress.usable(host) != nil { hosts.append(host) }
        }
        return hosts.first { QuickShareAddress.sharesSubnet($0) }
    }
}

// MARK: - QR code sessions

/// The QR path, for reaching a device that isn't visible in the discovery list.
///
/// We generate an ephemeral key and show it as a Quick Share App Link. A phone
/// that scans it starts advertising a token derived from the same key, which we
/// recognise while browsing — at which point the transfer proceeds normally.
public struct QRCodeSession: Sendable {

    /// The blob encoded into the QR link.
    public let keyData: Data
    /// What we watch for in a peer's advertisement.
    public let advertisingToken: Data
    /// Decrypts the device name an otherwise-invisible peer advertises.
    let nameEncryptionKey: SymmetricKey
    /// Signs the handshake so the peer can tie the connection to the scan.
    let signingKey: P256.Signing.PrivateKey

    /// Android only routes this exact URL form to Quick Share.
    public var url: String {
        "https://quickshare.google/qrcode#key=\(keyData.urlSafeBase64EncodedString())"
    }

    public init() {
        let signingKey = P256.Signing.PrivateKey()
        self.signingKey = signingKey

        // Prefix, then the public key's X coordinate.
        var blob = Data([0, 0, 2])
        let x = Data(signingKey.publicKey.rawRepresentation.prefix(32))
        // The signed encoding can carry a leading zero byte; Android rejects the
        // endpoint info outright if it survives, so keep only the low 32 bytes.
        blob.append(UKey2.signedBytes(x).suffix(32))
        self.keyData = blob

        let ikm = SymmetricKey(data: blob)
        self.advertisingToken = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: Data(),
            info: Data("advertisingContext".utf8), outputByteCount: 16)
            .withUnsafeBytes { Data($0) }
        self.nameEncryptionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: Data(),
            info: Data("encryptionKey".utf8), outputByteCount: 16)
    }

    /// True when this advertisement is the device that scanned our code.
    public func matches(advertisedQRData data: Data) -> Bool {
        // Constant time isn't required — this is a public token, not a secret —
        // but the lengths must match before comparing.
        data.count == advertisingToken.count && data == advertisingToken
    }

    /// Decrypts the name an invisible peer advertises alongside its token.
    ///
    /// The token is the AEAD's associated data, so a name only decrypts if the
    /// peer really did derive it from our QR key.
    public func decryptDeviceName(from data: Data) -> String? {
        guard data.count > 28 else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(box, using: nameEncryptionKey,
                                                authenticating: advertisingToken) else {
            return nil
        }
        return String(data: plaintext, encoding: .utf8)
    }

    /// Signs the handshake's auth string so the peer can bind this connection to
    /// the code it scanned. Returned as raw r‖s, which is what the wire expects.
    public func handshakeSignature(authKey: SymmetricKey) -> Data? {
        let message = authKey.withUnsafeBytes { Data($0) }
        guard let signature = try? signingKey.signature(for: message) else { return nil }
        return signature.rawRepresentation
    }
}

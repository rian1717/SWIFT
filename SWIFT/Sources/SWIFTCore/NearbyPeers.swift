import Foundation

/// One Quick Share advertisement. A phone can publish more than one.
public struct ShareSighting: Equatable, Sendable {
    public var id: String
    /// The 4-character id inside the Quick Share service name.
    public var endpointKey: String?
    /// The phone's address, when the advertisement included one.
    public var address: String?
    /// The name inside this advertisement.
    public var advertisedName: String?
    /// A name read from the same phone's Bluetooth packet, already matched
    /// to this advertisement's endpoint id.
    public var matchedName: String?

    public init(id: String, endpointKey: String? = nil, address: String? = nil,
                advertisedName: String? = nil, matchedName: String? = nil) {
        self.id = id
        self.endpointKey = endpointKey
        self.address = address
        self.advertisedName = advertisedName
        self.matchedName = matchedName
    }
}

/// The row to show for one physical device.
public struct ShareRow: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which Quick Share advertisements are actually separate devices.
///
/// A phone with Quick Share open is one device, even when it advertises
/// twice. A saved controller, headset, or other accessory is not a device
/// here. A row is shown only once its own name is known.
public enum NearbyPeers {
    public static func rows(_ sightings: [ShareSighting]) -> [ShareRow] {
        cluster(sightings).compactMap(row(for:))
    }

    private static func row(for group: [ShareSighting]) -> ShareRow? {
        guard let name = bestName(in: group), let keeper = keeper(in: group) else { return nil }
        return ShareRow(id: keeper.id, name: name)
    }

    /// The name this phone put in its own advertisement or matching
    /// Bluetooth packet. A name from some other saved device is ignored.
    private static func bestName(in group: [ShareSighting]) -> String? {
        let names = group.flatMap { [real($0.advertisedName), real($0.matchedName)] }.compactMap { $0 }
        guard var best = names.first else { return nil }
        for name in names.dropFirst() {
            best = DeviceName.display(existing: best, advertised: name, bluetooth: nil, alias: nil)
        }
        return best == DeviceName.unnamed ? nil : best
    }

    private static func real(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != DeviceName.unnamed,
              DeviceName.isPossiblePhoneName(trimmed) else { return nil }
        return trimmed
    }

    /// The advertisement a send should use: one that has an address, and
    /// the one that carried the name when several do.
    private static func keeper(in group: [ShareSighting]) -> ShareSighting? {
        group.max { lhs, rhs in
            let left = rank(lhs)
            let right = rank(rhs)
            if left != right { return left < right }
            return lhs.id > rhs.id
        }
    }

    private static func rank(_ sighting: ShareSighting) -> Int {
        let address = (sighting.address?.isEmpty == false) ? 2 : 0
        let named = real(sighting.advertisedName) == nil ? 0 : 1
        return address + named
    }

    private static func cluster(_ sightings: [ShareSighting]) -> [[ShareSighting]] {
        var parent: [String: String] = [:]
        for sighting in sightings { parent[sighting.id] = sighting.id }

        func find(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current { current = next }
            var cursor = id
            while cursor != current {
                let next = parent[cursor] ?? current
                parent[cursor] = current
                cursor = next
            }
            return current
        }

        func unite(_ lhs: String, _ rhs: String) {
            let left = find(lhs)
            let right = find(rhs)
            if left != right { parent[right] = left }
        }

        var byAddress: [String: String] = [:]
        var byEndpoint: [String: String] = [:]
        for sighting in sightings {
            if let address = sighting.address, !address.isEmpty {
                if let previous = byAddress[address] { unite(sighting.id, previous) }
                byAddress[address] = sighting.id
            }
            if let key = sighting.endpointKey, !key.isEmpty {
                if let previous = byEndpoint[key] { unite(sighting.id, previous) }
                byEndpoint[key] = sighting.id
            }
        }

        var groups: [String: [ShareSighting]] = [:]
        for sighting in sightings {
            groups[find(sighting.id), default: []].append(sighting)
        }
        return groups.values.sorted { ($0.first?.id ?? "") < ($1.first?.id ?? "") }
    }
}

import SWIFTCore
import CoreBluetooth
import Foundation

/// Listens for the name inside a phone's own Quick Share Bluetooth packet.
///
/// The packet carries the same 4-character id as the Wi-Fi advertisement.
/// A name is used only together with that id. Saved Bluetooth devices that
/// are not this phone are never turned into a row.
final class PhoneNameMonitor: NSObject, CBCentralManagerDelegate {
    var onName: ((String, String) -> Void)?
    private var central: CBCentralManager?
    private let service = CBUUID(string: "FEF3")
    private var seen: [UUID: (endpointID: String?, name: String?)] = [:]

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        var sight = seen[peripheral.identifier] ?? (nil, nil)
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        guard let data = serviceData?[service], let parsed = QuickShareBLE.parse(serviceData: data) else {
            return
        }
        sight.endpointID = parsed.endpointID
        if let name = parsed.name {
            sight.name = name
        } else if sight.name == nil,
                  let local = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                  QuickShareBLE.isDeviceName(local), DeviceName.isPossiblePhoneName(local) {
            sight.name = local
        }
        seen[peripheral.identifier] = sight
        if let id = sight.endpointID, let name = sight.name, DeviceName.isPossiblePhoneName(name) {
            onName?(id, name)
        }
    }
}
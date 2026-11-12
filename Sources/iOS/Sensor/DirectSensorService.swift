import CoreBluetooth
import Foundation
import UserNotifications

/// Settings › Live from sensor: a reading from the Libre 2 / 2 Plus over Bluetooth every minute,
/// once an NFC tap has moved the sensor's stream from LibreLink to GlucOS.
///
/// The sensor connects about once a minute, sends one encrypted 46-byte packet (the last 15 minutes
/// and 3 history points) and drops the connection. GlucOS keeps a connection request open the whole
/// time, so iOS wakes the app for each packet even in the background (`bluetooth-central`), and
/// restores the request if iOS ended the app meanwhile. Each connection has to be unlocked with
/// the next payload in a sequence, so the count is saved before every write.
///
/// LibreLink's alarms and LinkUp sharing stop while GlucOS has the stream. GlucOS's own alerts take
/// over (see `PhoneServices`), and a "no signal" alert is kept 20 minutes ahead of the last packet,
/// so it goes off even if iOS stops waking the app.
@MainActor
final class DirectSensorService: NSObject, ObservableObject {
    enum Status: Equatable {
        case off
        case bluetoothOff
        case unauthorized
        /// Waiting for the sensor to come in range (it connects about once a minute).
        case waiting
        case receiving
        case sensorEnded
    }

    @Published private(set) var sensor: DirectSensor?
    @Published private(set) var status: Status = .off
    @Published private(set) var problem: String?

    var isEnabled: Bool { sensor != nil }

    /// New readings from the sensor, oldest first.
    var onReadings: (@MainActor ([GlucoseReading]) -> Void)?
    /// Whether GlucOS alerts are on, for the no-signal alert.
    var alertsEnabled: @MainActor () -> Bool = { true }

    static let service = CBUUID(string: "FDE3")
    static let writeCharacteristic = CBUUID(string: "F001")
    static let notifyCharacteristic = CBUUID(string: "F002")
    private static let restoreID = "au.com.declanmayo.glucos.libre2"
    private static let defaultsKey = "directSensor"
    static let signalLossID = "glucos.sensor.signal"
    /// How long without a packet before the no-signal alert.
    static let signalLossAfter: TimeInterval = 20 * 60

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var assembler = LibreBLEAssembler()
    private var badPackets = 0

    override init() {
        super.init()
        sensor = Self.load()
        // Has to exist at launch, so iOS can hand back a connection it kept while the app was gone.
        if sensor != nil { makeCentral() }
    }

    // MARK: Turning it on and off

    /// After the takeover tap: remember the sensor, start listening, and pass on the tap's 8 hours.
    func takeOver(_ scan: SensorScanResult) throws {
        guard let fram = scan.fram, let mac = scan.bluetoothAddress, scan.uid.count == 8 else {
            throw SensorScanError.cannotStream
        }
        disconnect()
        sensor = DirectSensor(uid: scan.uid, patchInfo: scan.patchInfo.raw, serial: scan.serial, macAddress: mac,
                              calibration: fram.calibration, maxLife: fram.maxLife, takenOverAt: scan.scannedAt)
        sensor?.lastAge = fram.age
        save()
        problem = nil
        badPackets = 0
        if central == nil { makeCentral() } else { connectOrScan() }
        onReadings?(scan.readings)
        scheduleSignalLoss()
    }

    /// Stops listening. The sensor keeps streaming to nobody until LibreLink scans it again.
    func stop() {
        disconnect()
        sensor = nil
        save()
        status = .off
        problem = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.signalLossID])
    }

    /// An ordinary NFC read of the same sensor (Settings › Read sensor) fills in the last 8 hours,
    /// for instance after the phone was out of range.
    func backfill(_ scan: SensorScanResult) {
        guard let sensor, scan.uid == sensor.uid, !scan.readings.isEmpty else { return }
        onReadings?(scan.readings)
    }

    // MARK: Bluetooth

    private func makeCentral() {
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    private func disconnect() {
        if let central, let peripheral { central.cancelPeripheralConnection(peripheral) }
        if central?.isScanning == true { central?.stopScan() }
        peripheral = nil
        assembler.reset()
    }

    /// Asks iOS to connect whenever the sensor is next in range. The request never times out.
    private func connectOrScan() {
        guard let central, central.state == .poweredOn, let sensor else { return }
        if status != .sensorEnded { status = .waiting }
        if let p = peripheral ?? sensor.peripheralID.flatMap({ central.retrievePeripherals(withIdentifiers: [$0]).first }) {
            peripheral = p
            p.delegate = self
            switch p.state {
            case .connected: p.discoverServices([Self.service])
            case .connecting: break
            default: central.connect(p)
            }
        } else if !central.isScanning {
            // The service filter is what lets a scan run in the background.
            central.scanForPeripherals(withServices: [Self.service])
        }
    }

    private func handle(packet: [UInt8], at date: Date) {
        guard var s = sensor else { return }
        do {
            let (readings, age) = try s.readings(packet: packet, receivedAt: date)
            badPackets = 0
            problem = nil
            s.lastPacketAt = date
            s.lastAge = age
            sensor = s
            save()
            status = age >= s.maxLife ? .sensorEnded : .receiving
            onReadings?(readings)
            scheduleSignalLoss()
        } catch DirectSensor.PacketError.noReadings {
            // Warming up or a temporary sensor error: the sensor is there, just nothing to show.
            s.lastPacketAt = date
            sensor = s
            save()
            problem = "The sensor sent no glucose this minute. Libre sensors do this briefly now and then."
        } catch {
            badPackets += 1
            if badPackets >= 3 {
                problem = "The sensor's packets aren't decoding. If you've started a new sensor, tap it on the Live from sensor screen."
            }
        }
    }

    /// Replaces the pending no-signal alert with one 20 minutes from now.
    private func scheduleSignalLoss() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.signalLossID])
        guard sensor != nil, alertsEnabled() else { return }
        let content = UNMutableNotificationContent()
        content.title = "No signal from your sensor"
        content.body = "GlucOS hasn't had a reading for 20 minutes. Keep your iPhone near the sensor and open GlucOS. LibreLink's alarms are off while GlucOS has the sensor."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "glucos.alerts"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.signalLossAfter, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.signalLossID, content: content, trigger: trigger))
    }

    // MARK: Storage

    private static func load() -> DirectSensor? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(DirectSensor.self, from: data)
    }

    private func save() {
        if let sensor, let data = try? JSONEncoder().encode(sensor) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }
}

// The central's queue is the main queue, so every callback is already on the main actor.
extension DirectSensorService: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central === self.central else { return }
            switch central.state {
            case .poweredOn: connectOrScan()
            case .poweredOff: status = sensor == nil ? .off : .bluetoothOff
            case .unauthorized: status = .unauthorized
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            guard let id = sensor?.peripheralID, let p = restored.first(where: { $0.identifier == id }) else { return }
            peripheral = p
            p.delegate = self
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard let s = sensor else { return }
            let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            guard s.isAdvertisement(name: name, manufacturerData: maker) else { return }
            central.stopScan()
            sensor?.peripheralID = peripheral.identifier
            save()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            assembler.reset()
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral, sensor != nil else { return }
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            // The sensor hangs up after every packet. Ask for the next connection straight away.
            guard peripheral === self.peripheral, sensor != nil else { return }
            assembler.reset()
            central.connect(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
            peripheral.discoverCharacteristics([Self.writeCharacteristic, Self.notifyCharacteristic], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard sensor != nil else { return }
            for c in service.characteristics ?? [] {
                if c.uuid == Self.writeCharacteristic {
                    // Saved before it's sent: reusing a count would be refused by the sensor.
                    guard let payload = sensor?.nextUnlockPayload() else { return }
                    save()
                    peripheral.writeValue(Data(payload), for: c, type: .withResponse)
                } else if c.uuid == Self.notifyCharacteristic {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.notifyCharacteristic, let value = characteristic.value, error == nil else { return }
            let now = Date()
            if let packet = assembler.append([UInt8](value), at: now) { handle(packet: packet, at: now) }
        }
    }
}

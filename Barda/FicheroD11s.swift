import CoreBluetooth
import Foundation

/// Pilote BLE de l'étiqueteuse Fichero D11s (AiYin D11s).
///
/// Protocole repris tel quel du client TypeScript de `fichero-printer` (MIT), que
/// la version web utilise déjà : mêmes UUID, mêmes commandes, mêmes temporisations.
/// Ici, seule la couche transport change — CoreBluetooth au lieu de Web Bluetooth.
///
/// Tout le dialogue se déroule sur `workQueue`, qui a le droit de bloquer sur des
/// sémaphores ; les rappels CoreBluetooth arrivent sur `bleQueue`. Le thread
/// principal n'est jamais bloqué.
final class FicheroD11s: NSObject, LabelPrinter {

    // MARK: - Identité (mêmes valeurs que `src/lib/printers/models.ts` côté web)

    let id = "fichero-d11s"
    let name = "Fichero D11s"
    let bytesPerRow = 12      // 96 points de tête d'impression

    // MARK: - Constantes du protocole

    private static let serviceUUID = CBUUID(string: "000018F0-0000-1000-8000-00805F9B34FB")
    private static let writeUUID   = CBUUID(string: "00002AF1-0000-1000-8000-00805F9B34FB")
    private static let notifyUUID  = CBUUID(string: "00002AF0-0000-1000-8000-00805F9B34FB")

    private static let namePrefixes = ["FICHERO", "D11s_"]
    private static let chunkSize    = 200
    private static let chunkDelay   = 0.020

    private enum Cmd {
        static let getStatus:      [UInt8] = [0x10, 0xff, 0x40]
        static let enablePrinter:  [UInt8] = [0x10, 0xff, 0xfe, 0x01]
        static let stopPrint:      [UInt8] = [0x10, 0xff, 0xfe, 0x45]
        static let formFeed:       [UInt8] = [0x1d, 0x0c]
        static func setDensity(_ level: UInt8) -> [UInt8] { [0x10, 0xff, 0x10, 0x00, level] }
        static func setPaperType(_ type: UInt8) -> [UInt8] { [0x10, 0xff, 0x84, type] }
    }

    enum Failure: LocalizedError {
        case bluetoothUnavailable(String)
        case notFound
        case connectionFailed(String)
        case missingCharacteristics
        case coverOpen
        case noPaper
        case overheated

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable(let why): return why
            case .notFound: return "Imprimante introuvable. Elle est allumée ?"
            case .connectionFailed(let why): return "Connexion impossible : \(why)"
            case .missingCharacteristics: return "Imprimante reconnue mais muette (service BLE incomplet)."
            case .coverOpen: return "Le capot est ouvert."
            case .noPaper: return "Plus d'étiquettes."
            case .overheated: return "L'imprimante a surchauffé, laisse-la refroidir."
            }
        }
    }

    // MARK: - État

    private let bleQueue  = DispatchQueue(label: "barda.fichero-d11s.ble")
    private let workQueue = DispatchQueue(label: "barda.fichero-d11s.print")
    private let lock = NSLock()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var powerSemaphore   = DispatchSemaphore(value: 0)
    private var scanSemaphore    = DispatchSemaphore(value: 0)
    private var connectSemaphore = DispatchSemaphore(value: 0)
    private var serviceSemaphore = DispatchSemaphore(value: 0)
    private var notifySemaphore  = DispatchSemaphore(value: 0)
    private var writeSemaphore   = DispatchSemaphore(value: 0)

    private var connectError: String?
    private var notifyBuffer = Data()
    private var found: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - API

    /// Imprime `copies` exemplaires d'une image déjà tramée en 1 bit par pixel,
    /// 12 octets par ligne — exactement ce que produit `ImageEncoder` côté web.
    func print(rows: Int, raster: Data, copies: Int, density: UInt8,
               progress: @escaping (String) -> Void,
               completion: @escaping (Result<Void, Error>) -> Void) {
        workQueue.async {
            do {
                try self.run(rows: rows, raster: raster, copies: max(1, copies),
                             density: density, progress: progress)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func disconnect() {
        lock.lock(); let p = peripheral; lock.unlock()
        if let p { central.cancelPeripheralConnection(p) }
    }

    // MARK: - Séquence d'impression

    private func run(rows: Int, raster: Data, copies: Int, density: UInt8,
                     progress: @escaping (String) -> Void) throws {
        try ensureConnected(progress: progress)

        progress("Préparation…")
        let status = try send(Cmd.getStatus, waitReply: true)
        if let last = status.last {
            if last & 0x02 != 0 { throw Failure.coverOpen }
            if last & 0x04 != 0 { throw Failure.noPaper }
            if last & 0x50 != 0 { throw Failure.overheated }
        }
        _ = try send(Cmd.setDensity(density), waitReply: true)
        Thread.sleep(forTimeInterval: 0.1)

        var header: [UInt8] = [0x1d, 0x76, 0x30, 0x00, UInt8(bytesPerRow), 0x00,
                               UInt8(rows & 0xff), UInt8((rows >> 8) & 0xff)]
        var payload = Data(header); payload.append(raster)
        header.removeAll()

        for copy in 1...copies {
            progress(copies == 1 ? "Impression…" : "Impression \(copy)/\(copies)…")

            _ = try send(Cmd.setPaperType(0), waitReply: true)   // étiquettes prédécoupées
            Thread.sleep(forTimeInterval: 0.05)
            _ = try send([UInt8](repeating: 0, count: 12))        // réveil
            Thread.sleep(forTimeInterval: 0.05)
            _ = try send(Cmd.enablePrinter)
            Thread.sleep(forTimeInterval: 0.05)

            try sendChunked(payload)
            Thread.sleep(forTimeInterval: 0.5)

            _ = try send(Cmd.formFeed)
            Thread.sleep(forTimeInterval: 0.3)
            _ = try send(Cmd.stopPrint, waitReply: true, timeout: 60)
        }
    }

    // MARK: - Connexion

    private func ensureConnected(progress: @escaping (String) -> Void) throws {
        lock.lock()
        let alreadyUp = peripheral?.state == .connected && writeChar != nil && notifyChar != nil
        lock.unlock()
        if alreadyUp { return }

        progress("Bluetooth…")
        if central.state != .poweredOn {
            powerSemaphore = DispatchSemaphore(value: 0)
            if powerSemaphore.wait(timeout: .now() + 6) == .timedOut {
                throw Failure.bluetoothUnavailable("Bluetooth indisponible.")
            }
        }
        switch central.state {
        case .poweredOn: break
        case .unauthorized: throw Failure.bluetoothUnavailable("Barda n'a pas l'autorisation Bluetooth (Réglages ▸ Barda).")
        case .poweredOff: throw Failure.bluetoothUnavailable("Le Bluetooth est éteint.")
        default: throw Failure.bluetoothUnavailable("Bluetooth indisponible.")
        }

        progress("Recherche de l'imprimante…")
        lock.lock(); found = nil; lock.unlock()
        scanSemaphore = DispatchSemaphore(value: 0)
        bleQueue.async { self.central.scanForPeripherals(withServices: nil) }
        let timedOut = scanSemaphore.wait(timeout: .now() + 12) == .timedOut
        bleQueue.async { self.central.stopScan() }
        if timedOut { throw Failure.notFound }

        lock.lock(); let target = found; lock.unlock()
        guard let target else { throw Failure.notFound }

        progress("Connexion…")
        connectError = nil
        connectSemaphore = DispatchSemaphore(value: 0)
        serviceSemaphore = DispatchSemaphore(value: 0)
        target.delegate = self
        lock.lock(); peripheral = target; lock.unlock()
        bleQueue.async { self.central.connect(target) }
        if connectSemaphore.wait(timeout: .now() + 15) == .timedOut {
            throw Failure.connectionFailed("délai dépassé")
        }
        if let connectError { throw Failure.connectionFailed(connectError) }

        if serviceSemaphore.wait(timeout: .now() + 15) == .timedOut {
            throw Failure.missingCharacteristics
        }
        lock.lock()
        let ok = writeChar != nil && notifyChar != nil
        lock.unlock()
        if !ok { throw Failure.missingCharacteristics }
    }

    // MARK: - Transport

    @discardableResult
    private func send(_ bytes: [UInt8], waitReply: Bool = false, timeout: TimeInterval = 2) throws -> Data {
        if waitReply { lock.lock(); notifyBuffer = Data(); lock.unlock() }
        try write(Data(bytes))
        guard waitReply else { return Data() }

        notifySemaphore = DispatchSemaphore(value: 0)
        _ = notifySemaphore.wait(timeout: .now() + timeout)   // silence = pas d'erreur, comme côté web
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); let reply = notifyBuffer; lock.unlock()
        return reply
    }

    private func sendChunked(_ data: Data) throws {
        lock.lock(); let p = peripheral; lock.unlock()
        // CoreBluetooth tronque silencieusement au-delà du MTU négocié, là où le
        // navigateur fragmentait tout seul : on découpe à la taille annoncée.
        let maxLen = p.map { min(Self.chunkSize, $0.maximumWriteValueLength(for: .withoutResponse)) }
            ?? Self.chunkSize
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxLen, data.count)
            try write(data.subdata(in: offset..<end))
            offset = end
            Thread.sleep(forTimeInterval: Self.chunkDelay)
        }
    }

    private func write(_ data: Data) throws {
        lock.lock()
        let p = peripheral
        let c = writeChar
        lock.unlock()
        guard let p, let c, p.state == .connected else {
            throw Failure.connectionFailed("lien perdu")
        }
        // Attendre que la pile soit prête évite les paquets jetés en silence.
        if !p.canSendWriteWithoutResponse {
            writeSemaphore = DispatchSemaphore(value: 0)
            _ = writeSemaphore.wait(timeout: .now() + 1)
        }
        bleQueue.async { p.writeValue(data, for: c, type: .withoutResponse) }
    }
}

// MARK: - Rappels CoreBluetooth

extension FicheroD11s: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .unknown && central.state != .resetting { powerSemaphore.signal() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard Self.namePrefixes.contains(where: { name.uppercased().hasPrefix($0.uppercased()) }) else { return }
        lock.lock()
        if found == nil { found = peripheral }
        lock.unlock()
        scanSemaphore.signal()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
        connectSemaphore.signal()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectError = error?.localizedDescription ?? "échec"
        connectSemaphore.signal()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        self.peripheral = nil; writeChar = nil; notifyChar = nil
        lock.unlock()
    }
}

extension FicheroD11s: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            serviceSemaphore.signal(); return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        lock.lock()
        writeChar  = service.characteristics?.first { $0.uuid == Self.writeUUID }
        notifyChar = service.characteristics?.first { $0.uuid == Self.notifyUUID }
        let n = notifyChar
        lock.unlock()
        if let n { peripheral.setNotifyValue(true, for: n) }
        serviceSemaphore.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        lock.lock(); notifyBuffer.append(value); lock.unlock()
        notifySemaphore.signal()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeSemaphore.signal()
    }
}

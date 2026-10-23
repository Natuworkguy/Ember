import CoreBluetooth
import Foundation

/// The way to the Ember server on your computer: Bluetooth LE, not the
/// network. The computer advertises one service; the watch finds it,
/// connects, and sends the same requests the HTTP API takes.
///
/// A request goes up as frames written to one characteristic, and its
/// answer comes back one frame per read of the other. The server reads
/// and writes them the same way, in server/ember_server/ble.py: change
/// one, change both.
///
///     request:  S id:u16 total:u32 size:u16 data, then C id:u16 offset:u32 data
///     answer:   W (not yet), R id:u16 total:u32 data, C id:u16 offset:u32 data, E
///
/// A message, either way, is a line of JSON and then the body.
final class BluetoothLink: NSObject, @unchecked Sendable {
    static let shared = BluetoothLink()

    static let service = CBUUID(string: "6C1F0001-4E8B-4A51-9D3E-656D62657201")
    static let request = CBUUID(string: "6C1F0002-4E8B-4A51-9D3E-656D62657201")
    static let answer = CBUUID(string: "6C1F0003-4E8B-4A51-9D3E-656D62657201")

    struct Answer {
        let status: Int
        let body: Data
    }

    enum LinkError: LocalizedError {
        case off, notAllowed, unsupported, notFound, lost, garbled

        var errorDescription: String? {
            switch self {
            case .off: return "Bluetooth is off. It will sync when it's on."
            case .notAllowed: return "Ember isn't allowed to use Bluetooth. Turn it on in Settings, Privacy & Security, Bluetooth."
            case .unsupported: return "This watch can't use Bluetooth LE."
            case .notFound: return "Your computer isn't nearby, or Ember isn't running there. It will sync when it is."
            case .lost: return "The connection to your computer dropped. It will try again."
            case .garbled: return "Your computer's answer didn't come through whole. It will try again."
            }
        }
    }

    // Everything below is only touched on this queue, where Core
    // Bluetooth calls back too.
    private let queue = DispatchQueue(label: "ember.bluetooth")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var requestCharacteristic: CBCharacteristic?
    private var answerCharacteristic: CBCharacteristic?
    private var ready: [CheckedContinuation<Void, Error>] = []
    private var reading: CheckedContinuation<Data, Error>?
    private var writable: CheckedContinuation<Void, Error>?
    private var nextID: UInt16 = 0
    private let turn = Turn()

    /// One request at a time: the link carries one exchange.
    private actor Turn {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func take() async {
            if busy {
                await withCheckedContinuation { waiting.append($0) }
            } else {
                busy = true
            }
        }

        func give() {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
    }

    /// Send a request, and wait up to TIMEOUT seconds for all of its answer.
    func send(_ method: String, _ path: String, query: String = "",
              headers: [String: String] = [:], body: Data = Data(),
              timeout: TimeInterval) async throws -> Answer {
        await turn.take()
        do {
            let answer = try await withDeadline(timeout) {
                try await self.exchange(method, path, query, headers, body)
            }
            await turn.give()
            return answer
        } catch {
            await turn.give()
            throw error
        }
    }

    // MARK: One exchange

    private func exchange(_ method: String, _ path: String, _ query: String,
                          _ headers: [String: String], _ body: Data) async throws -> Answer {
        try await connect()
        let (size, ident) = try await onQueue { () throws -> (Int, UInt16) in
            guard let peripheral = self.peripheral else { throw LinkError.lost }
            self.nextID &+= 1
            let most = peripheral.maximumWriteValueLength(for: .withoutResponse)
            return (max(20, min(512, most)), self.nextID)
        }

        let head: [String: Any] = ["m": method, "p": path, "q": query, "h": headers]
        var message = try JSONSerialization.data(withJSONObject: head)
        message.append(0x0A)
        message.append(body)

        for frame in Self.frames(message, ident: ident, size: size) {
            try Task.checkCancellation()
            try await waitToWrite()
            try await onQueue {
                guard let peripheral = self.peripheral,
                      let characteristic = self.requestCharacteristic
                else { throw LinkError.lost }
                peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
            }
        }

        var total = -1
        var got = Data()
        while total < 0 || got.count < total {
            try Task.checkCancellation()
            let frame = try await readFrame()
            guard let kind = frame.first else { throw LinkError.garbled }
            switch kind {
            case UInt8(ascii: "W"):
                try await Task.sleep(nanoseconds: 60_000_000)
            case UInt8(ascii: "R"):
                guard frame.count >= 7, Self.u16(frame, 1) == ident else { throw LinkError.garbled }
                total = Self.u32(frame, 3)
                got = frame.subdata(in: 7..<frame.count)
            case UInt8(ascii: "C"):
                guard total >= 0, frame.count >= 7, Self.u16(frame, 1) == ident,
                      Self.u32(frame, 3) == got.count
                else { throw LinkError.garbled }
                got.append(frame.subdata(in: 7..<frame.count))
            default:
                throw LinkError.garbled
            }
        }

        guard let line = got.firstIndex(of: 0x0A),
              let said = try? JSONSerialization.jsonObject(with: got.subdata(in: 0..<line)) as? [String: Any],
              let status = said["s"] as? Int
        else { throw LinkError.garbled }
        return Answer(status: status, body: got.subdata(in: (line + 1)..<got.count))
    }

    static func frames(_ message: Data, ident: UInt16, size: Int) -> [Data] {
        var first = Data([UInt8(ascii: "S")])
        first.append(be(UInt32(ident), 2))
        first.append(be(UInt32(message.count), 4))
        first.append(be(UInt32(size), 2))
        var at = min(message.count, size - first.count)
        first.append(message.subdata(in: 0..<at))
        var frames = [first]
        while at < message.count {
            var frame = Data([UInt8(ascii: "C")])
            frame.append(be(UInt32(ident), 2))
            frame.append(be(UInt32(at), 4))
            let end = min(message.count, at + size - frame.count)
            frame.append(message.subdata(in: at..<end))
            frames.append(frame)
            at = end
        }
        return frames
    }

    private static func be(_ value: UInt32, _ bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt32($0) * 8)) })
    }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 {
        let bytes = [UInt8](data)
        return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    private static func u32(_ data: Data, _ at: Int) -> Int {
        let bytes = [UInt8](data)
        return (at..<(at + 4)).reduce(0) { $0 << 8 | Int(bytes[$1]) }
    }

    // MARK: Waiting on Core Bluetooth

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.peripheral?.state == .connected,
                   self.requestCharacteristic != nil, self.answerCharacteristic != nil {
                    continuation.resume()
                    return
                }
                self.ready.append(continuation)
                self.begin()
            }
        }
    }

    /// On the queue: get to a connected server, as far as Bluetooth allows.
    private func begin() {
        let central = self.central ?? CBCentralManager(
            delegate: self, queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        self.central = central
        switch central.state {
        case .poweredOn:
            if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
                return
            }
            if !central.isScanning {
                central.scanForPeripherals(withServices: [Self.service])
            }
        case .poweredOff: fail(LinkError.off)
        case .unauthorized: fail(LinkError.notAllowed)
        case .unsupported: fail(LinkError.unsupported)
        default: break  // still starting: its state update carries on
        }
    }

    private func waitToWrite() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, peripheral.state == .connected else {
                    continuation.resume(throwing: LinkError.lost)
                    return
                }
                if peripheral.canSendWriteWithoutResponse {
                    continuation.resume()
                } else {
                    self.writable = continuation
                }
            }
        }
    }

    private func readFrame() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                guard let peripheral = self.peripheral,
                      let characteristic = self.answerCharacteristic
                else {
                    continuation.resume(throwing: LinkError.lost)
                    return
                }
                self.reading = continuation
                peripheral.readValue(for: characteristic)
            }
        }
    }

    /// On the queue: everyone waiting hears ERROR.
    private func fail(_ error: Error) {
        let waiting = ready
        ready = []
        waiting.forEach { $0.resume(throwing: error) }
        if let reading {
            self.reading = nil
            reading.resume(throwing: error)
        }
        if let writable {
            self.writable = nil
            writable.resume(throwing: error)
        }
    }

    /// Give up on what is under way: past its time, nothing more waits.
    private func abandon() {
        queue.async {
            self.central?.stopScan()
            if let peripheral = self.peripheral, peripheral.state != .connected {
                self.central?.cancelPeripheralConnection(peripheral)
                self.peripheral = nil
            }
            self.fail(LinkError.notFound)
        }
    }

    private func withDeadline<T>(_ seconds: TimeInterval,
                                 _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { self.abandon() }
                return nil
            }
            defer { group.cancelAll() }
            // The first to finish: the answer, or the deadline (nil).
            if let finished = try await group.next(), let answer = finished {
                return answer
            }
            throw LinkError.notFound
        }
    }
}

extension BluetoothLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !ready.isEmpty else { return }
        begin()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let current = self.peripheral, current.state != .disconnected { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        fail(LinkError.notFound)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        requestCharacteristic = nil
        answerCharacteristic = nil
        fail(LinkError.lost)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail(LinkError.notFound)
            return
        }
        peripheral.discoverCharacteristics([Self.request, Self.answer], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        requestCharacteristic = service.characteristics?.first { $0.uuid == Self.request }
        answerCharacteristic = service.characteristics?.first { $0.uuid == Self.answer }
        guard requestCharacteristic != nil, answerCharacteristic != nil else {
            fail(LinkError.notFound)
            return
        }
        let waiting = ready
        ready = []
        waiting.forEach { $0.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.answer, let reading else { return }
        self.reading = nil
        if error != nil {
            reading.resume(throwing: LinkError.lost)
        } else {
            reading.resume(returning: Data(characteristic.value ?? Data()))
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let writable {
            self.writable = nil
            writable.resume()
        }
    }
}

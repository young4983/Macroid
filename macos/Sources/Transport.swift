import Foundation
import Network

// Mutable connection/parser/request state is confined to queue; callbacks are immutable.
final class Transport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.macroid.transport", qos: .userInteractive)
    private var connection: NWConnection?
    private var parser = WireParser()
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false
    private let onVideo: (@MainActor (WirePacket) -> Void)?
    private let onEvent: (@MainActor ([String: Any]) -> Void)?
    private let onDisconnect: (@MainActor (Error) -> Void)?

    init(onVideo: (@MainActor (WirePacket) -> Void)? = nil, onEvent: (@MainActor ([String: Any]) -> Void)? = nil, onDisconnect: (@MainActor (Error) -> Void)? = nil) {
        self.onVideo = onVideo; self.onEvent = onEvent; self.onDisconnect = onDisconnect
    }

    func connect(port: UInt16) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                self.connection = connection
                var waiting = true
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if waiting { waiting = false; continuation.resume(); self.receive() }
                    case .failed(let error):
                        if waiting { waiting = false; continuation.resume(throwing: error) }
                        self.fail(error)
                    case .cancelled:
                        if waiting { waiting = false; continuation.resume(throwing: WireError.disconnected) }
                    default: break
                    }
                }
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 10) {
                    if waiting { waiting = false; continuation.resume(throwing: WireError.timeout); self.fail(WireError.timeout) }
                }
            }
        }
    }
    func request(_ op: String, _ values: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.closed, self.connection != nil else { continuation.resume(throwing: WireError.disconnected); return }
                let id = self.nextID; self.nextID += 1
                var object = values; object["op"] = op; object["id"] = id
                self.pending[id] = continuation
                do { try self.send(object) } catch { self.pending.removeValue(forKey: id)?.resume(throwing: error) }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pending.removeValue(forKey: id)?.resume(throwing: WireError.timeout)
                }
            }
        }
    }
    func notify(_ op: String, _ values: [String: Any]) {
        queue.async {
            guard !self.closed else { return }
            var object = values; object["op"] = op; object["id"] = 0
            do { try self.send(object) } catch { self.fail(error) }
        }
    }
    private func send(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        let bytes = try WirePacket(payload: payload).encoded()
        connection?.send(content: bytes, completion: .contentProcessed { [weak self] error in if let error { self?.fail(error) } })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for packet in try self.parser.append(data) {
                        if packet.kind == 2 {
                            // A single FIFO main-queue path orders configuration events and video packets.
                            DispatchQueue.main.async { self.onVideo?(packet) }; continue
                        }
                        guard let object = try JSONSerialization.jsonObject(with: packet.payload) as? [String: Any] else { throw WireError.malformed }
                        let id = object["id"] as? Int ?? 0
                        if id != 0, let continuation = self.pending.removeValue(forKey: id) {
                            DispatchQueue.main.async {
                                if object["ok"] as? Bool == true { continuation.resume(returning: object["result"] as? [String: Any] ?? [:]) }
                                else { continuation.resume(throwing: WireError.remote(object["error"] as? String ?? "手机操作失败")) }
                            }
                        } else { DispatchQueue.main.async { self.onEvent?(object) } }
                    }
                } catch { self.fail(error); return }
            }
            if let error { self.fail(error) }
            else if complete { self.fail(WireError.disconnected) }
            else { self.receive() }
        }
    }
    private func fail(_ error: Error, notify: Bool = true) {
        guard !closed else { return }
        closed = true; connection?.cancel()
        let continuations = pending.values; pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
        if notify { DispatchQueue.main.async { self.onDisconnect?(error) } }
    }
    func close() { queue.async { self.fail(WireError.disconnected, notify: false) } }
}

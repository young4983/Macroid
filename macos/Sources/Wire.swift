import Foundation

enum WireError: Error, LocalizedError {
    case malformed, oversized, disconnected, remote(String), timeout
    var errorDescription: String? {
        switch self {
        case .malformed: return "Macroid 协议数据无效"
        case .oversized: return "数据超过协议大小限制"
        case .disconnected: return "设备连接已断开"
        case .remote(let text): return text
        case .timeout: return "手机响应超时，请检查连接"
        }
    }
}

struct WirePacket {
    static let maxPayload = 16 * 1024 * 1024
    var kind: UInt8 = 1
    var flags: UInt16 = 0
    var stream: UInt32 = 0
    var payload: Data
    func encoded() throws -> Data {
        guard payload.count <= Self.maxPayload else { throw WireError.oversized }
        var output = Data([0x4d, 0x43, 0x52, 0x44, 1, kind, UInt8(flags >> 8), UInt8(flags & 255)])
        output.appendBE(stream); output.appendBE(UInt32(payload.count)); output.append(payload)
        return output
    }
}

struct WireParser {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [WirePacket] {
        buffer.append(data)
        var cursor = 0, packets: [WirePacket] = []
        while buffer.count - cursor >= 16 {
            guard buffer.uint32BE(at: cursor) == 0x4d435244, buffer[cursor + 4] == 1,
                  [UInt8(1), 2].contains(buffer[cursor + 5]) else { throw WireError.malformed }
            let size = Int(buffer.uint32BE(at: cursor + 12))
            guard size <= WirePacket.maxPayload else { throw WireError.oversized }
            guard buffer.count - cursor - 16 >= size else { break }
            packets.append(WirePacket(kind: buffer[cursor + 5], flags: UInt16(buffer[cursor + 6]) << 8 | UInt16(buffer[cursor + 7]),
                                      stream: buffer.uint32BE(at: cursor + 8), payload: buffer.subdata(in: (cursor + 16)..<(cursor + 16 + size))))
            cursor += 16 + size
        }
        if cursor > 0 { buffer = Data(buffer.dropFirst(cursor)) }
        return packets
    }
}

extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    func uint32BE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}

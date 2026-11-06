import Foundation

enum NALUnit {
    /// Accept both three-byte and four-byte Annex B start codes. Returned NALs exclude start codes.
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        return starts.enumerated().compactMap { n, start in
            let end = n + 1 < starts.count ? starts[n + 1].0 : bytes.count
            guard end > start.0 + start.1 else { return nil }
            return Data(bytes[(start.0 + start.1)..<end])
        }
    }
}

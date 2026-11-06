import XCTest
@testable import MacroidWire

final class WireTests: XCTestCase {
    func testFragmentedAndCoalescedFrames() throws {
        let first = WirePacket(payload: Data("你好 Macroid".utf8))
        let second = WirePacket(kind: 2, flags: 3, stream: 19, payload: Data([0, 0, 0, 1, 103, 32]))
        let bytes = try first.encoded() + second.encoded()
        var parser = WireParser(), packets: [WirePacket] = []
        for byte in bytes { packets += try parser.append(Data([byte])) }
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].payload, first.payload)
        XCTAssertEqual(packets[1].flags, 3)
        XCTAssertEqual(packets[1].stream, 19)
        var bulk = WireParser()
        XCTAssertEqual(try bulk.append(bytes).count, 2)
    }
    func testRejectsOversizedAndWrongVersion() throws {
        var bytes = try WirePacket(payload: Data()).encoded()
        bytes[12] = 0x7f
        var parser = WireParser()
        XCTAssertThrowsError(try parser.append(bytes))
        bytes[4] = 2
        var other = WireParser()
        XCTAssertThrowsError(try other.append(bytes))
    }
    func testAnnexBMixedStartCodesAndEmulationPrevention() {
        let nals = NALUnit.split(Data([0, 0, 0, 1, 103, 0, 0, 3, 1, 0, 0, 1, 104, 9, 0, 0, 0, 1, 101, 6]))
        XCTAssertEqual(nals, [Data([103, 0, 0, 3, 1]), Data([104, 9]), Data([101, 6])])
        XCTAssertTrue(NALUnit.split(Data()).isEmpty)
    }
}

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
    func testFusionGeometryTracksLogicalSizeAndClampsInvalidInput() {
        let phone = StreamGeometry(contentWidth: 420, contentHeight: 720)
        let wide = StreamGeometry(contentWidth: 960, contentHeight: 640)
        XCTAssertEqual(phone.width * 160 / phone.density, 420)
        XCTAssertEqual(wide.width * 160 / wide.density, 960)
        XCTAssertEqual(wide.height * 160 / wide.density, 640)
        let invalid = StreamGeometry(contentWidth: .nan, contentHeight: -.infinity)
        XCTAssertEqual(invalid, phone)
        let tiny = StreamGeometry(contentWidth: 10, contentHeight: 10)
        XCTAssertEqual(tiny.width, 640); XCTAssertEqual(tiny.height, 480)
        let huge = StreamGeometry(contentWidth: 10000, contentHeight: 10000)
        XCTAssertLessThanOrEqual(huge.width, 8192); XCTAssertEqual(huge.width % 2, 0)
    }
    func testRetinaPixelsAndCompatibilityPreserveTheSameLogicalLayout() {
        let retina = StreamGeometry(contentWidth: 420, contentHeight: 720, pixelScale: 2)
        let compatible = StreamGeometry(contentWidth: 420, contentHeight: 720, pixelScale: 1.5)
        XCTAssertEqual(retina.width, 840); XCTAssertEqual(retina.height, 1440); XCTAssertEqual(retina.density, 320)
        XCTAssertEqual(compatible.width, 630); XCTAssertEqual(compatible.height, 1080); XCTAssertEqual(compatible.density, 240)
        for geometry in [retina, compatible] {
            XCTAssertEqual(geometry.width * 160 / geometry.density, 420)
            XCTAssertEqual(geometry.height * 160 / geometry.density, 720)
        }
        XCTAssertEqual(FusionQuality.automatic.pixelScale(for: 2), 2)
        XCTAssertEqual(FusionQuality.compatibility.pixelScale(for: 2), 1.5)
        XCTAssertEqual(StreamGeometry(contentWidth: 420, contentHeight: 720, pixelScale: .nan), retina)
    }
    func testConfigurationBoundarySurvivesFragmentation() throws {
        let packets = [
            WirePacket(kind: 2, flags: 2, stream: 3, payload: Data([1])),
            WirePacket(payload: Data(#"{"event":"stream.config","stream":3,"generation":2}"#.utf8)),
            WirePacket(kind: 2, flags: 1, stream: 3, payload: Data([2])),
            WirePacket(kind: 2, flags: 2, stream: 3, payload: Data([3]))
        ]
        let bytes = try packets.reduce(Data()) { try $0 + $1.encoded() }
        var parser = WireParser(), decoded: [WirePacket] = []
        for byte in bytes { decoded += try parser.append(Data([byte])) }
        XCTAssertEqual(decoded.map(\.kind), [2, 1, 2, 2])
        XCTAssertEqual(decoded.map(\.payload), packets.map(\.payload))
    }
    func testAnnexBMixedStartCodesAndEmulationPrevention() {
        let nals = NALUnit.split(Data([0, 0, 0, 1, 103, 0, 0, 3, 1, 0, 0, 1, 104, 9, 0, 0, 0, 1, 101, 6]))
        XCTAssertEqual(nals, [Data([103, 0, 0, 3, 1]), Data([104, 9]), Data([101, 6])])
        XCTAssertTrue(NALUnit.split(Data()).isEmpty)
    }
}

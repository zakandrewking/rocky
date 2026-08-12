import XCTest

@testable import Rocky

/// Mirrors apps/robot/src/protocol.test.ts's coverage -- same spec, same cases, ported not
/// reinvented. No device or network needed.
final class RobotProtocolTests: XCTestCase {
    func testClampsOversizedDriveDistance() {
        let bounded = boundCommand(.drive(id: "1", distanceCm: 10_000, speed: 50))
        guard case .drive(_, let distanceCm, let speed) = bounded else {
            return XCTFail("expected .drive")
        }
        XCTAssertEqual(distanceCm, RobotLimits.driveDistanceMaxCm)
        XCTAssertEqual(speed, 50)
    }

    func testClampsNegativeDriveDistanceSymmetrically() {
        let bounded = boundCommand(.drive(id: "1", distanceCm: -10_000, speed: 50))
        guard case .drive(_, let distanceCm, _) = bounded else {
            return XCTFail("expected .drive")
        }
        XCTAssertEqual(distanceCm, -RobotLimits.driveDistanceMaxCm)
    }

    func testClampsOutOfRangeSpeed() {
        let bounded = boundCommand(.drive(id: "1", distanceCm: 10, speed: 500))
        guard case .drive(_, _, let speed) = bounded else {
            return XCTFail("expected .drive")
        }
        XCTAssertEqual(speed, RobotLimits.speedMax)
    }

    func testClampsTurnDegrees() {
        let bounded = boundCommand(.turn(id: "1", degrees: 1000, speed: 50))
        guard case .turn(_, let degrees, _) = bounded else {
            return XCTFail("expected .turn")
        }
        XCTAssertEqual(degrees, RobotLimits.turnDegreesMax)
    }

    func testClampsLightChannels() {
        let bounded = boundCommand(.setLights(id: "1", r: 999, g: -50, b: 129))
        guard case .setLights(_, let r, let g, let b) = bounded else {
            return XCTFail("expected .setLights")
        }
        XCTAssertEqual(r, 255)
        XCTAssertEqual(g, 0)
        XCTAssertEqual(b, 129)
    }

    func testPassesStopThrough() {
        let bounded = boundCommand(.stop(id: "1"))
        guard case .stop(let id) = bounded else {
            return XCTFail("expected .stop")
        }
        XCTAssertEqual(id, "1")
    }

    func testEncodesDriveAsNewlineTerminatedJSON() throws {
        let data = try RobotWireFormat.encode(.stop(id: "1"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"type\":\"stop\""))
        XCTAssertTrue(text.contains("\"id\":\"1\""))
    }

    func testDecodesAck() throws {
        let json = Data("{\"type\":\"ack\",\"id\":\"1\",\"ok\":true}".utf8)
        let message = try RobotWireFormat.decodeTelemetry(json)
        guard case .ack(let id) = message else {
            return XCTFail("expected .ack")
        }
        XCTAssertEqual(id, "1")
    }

    func testDecodesDistance() throws {
        let json = Data("{\"type\":\"distance\",\"id\":\"1\",\"ok\":true,\"cm\":42}".utf8)
        let message = try RobotWireFormat.decodeTelemetry(json)
        guard case .distance(_, let cm) = message else {
            return XCTFail("expected .distance")
        }
        XCTAssertEqual(cm, 42)
    }

    func testDecodesStatusWithNoCorrelationId() throws {
        let json = Data("{\"type\":\"status\",\"battery\":87,\"connected\":true}".utf8)
        let message = try RobotWireFormat.decodeTelemetry(json)
        XCTAssertNil(message.id)
        guard case .status(let battery, let connected) = message else {
            return XCTFail("expected .status")
        }
        XCTAssertEqual(battery, 87)
        XCTAssertTrue(connected)
    }

    func testRejectsUnknownType() {
        let json = Data("{\"type\":\"mystery\"}".utf8)
        XCTAssertThrowsError(try RobotWireFormat.decodeTelemetry(json))
    }
}

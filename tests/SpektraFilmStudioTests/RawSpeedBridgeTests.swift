import RawSpeedBridge
import XCTest

final class RawSpeedBridgeTests: XCTestCase {
    func testSupportedExtensions() {
        let extensions = RawSpeedDecoder.getSupportedExtensions()
        XCTAssertTrue(extensions.contains("cr2"))
        XCTAssertTrue(extensions.contains("nef"))
        XCTAssertTrue(extensions.contains("arw"))
        XCTAssertTrue(extensions.contains("dng"))
        XCTAssertFalse(extensions.contains("txt"))
    }

    func testExtensionSupported() {
        XCTAssertTrue(RawSpeedDecoder.isExtensionSupported(URL(fileURLWithPath: "test.cr2")))
        XCTAssertTrue(RawSpeedDecoder.isExtensionSupported(URL(fileURLWithPath: "test.NEF")))
        XCTAssertFalse(RawSpeedDecoder.isExtensionSupported(URL(fileURLWithPath: "test.txt")))
    }

    func testMetadataStructure() {
        // Test that the metadata structs can be created
        let metadata = RawSpeedMetadata(from: RawSpeedBridge.RawSpeedMetadata())
        XCTAssertEqual(metadata.cameraMaker, "")
        XCTAssertEqual(metadata.cameraModel, "")
        XCTAssertEqual(metadata.rawBlackLevelSeparate.count, 4)
        XCTAssertEqual(metadata.wbCoeffs.count, 4)
        XCTAssertEqual(metadata.colorMatrix.count, 12)
        XCTAssertEqual(metadata.xtrans.count, 6)
        XCTAssertEqual(metadata.xtrans[0].count, 6)
    }

    func testImageStructure() {
        let image = RawSpeedImage(from: RawSpeedBridge.RawSpeedImage())
        XCTAssertEqual(image.data.count, 0)
        XCTAssertEqual(image.width, 0)
        XCTAssertEqual(image.height, 0)
        XCTAssertEqual(image.channels, 0)
        XCTAssertEqual(image.rowStride, 0)
    }
}

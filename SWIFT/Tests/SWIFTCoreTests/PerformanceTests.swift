import XCTest
@testable import SWIFTCore

final class PerformanceTests: XCTestCase {
    /// Deterministic CPU benchmark for the largest accepted introduction. This
    /// catches parser regressions without depending on CI network conditions.
    func testMaximumIntroductionDecodePerformance() throws {
        var introduction = IntroductionFrame()
        introduction.fileMetadata = (0..<InboundSession.maxFilesPerTransfer).map { index in
            var metadata = SharingFileMetadata()
            metadata.name = "fixture-\(index).bin"
            metadata.payloadID = Int64(index + 1)
            metadata.size = 512 * 1024
            metadata.mimeType = "application/octet-stream"
            return metadata
        }
        let bytes = introduction.serialized()

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<20 {
                _ = try? IntroductionFrame(serialized: bytes)
            }
        }
    }

    /// Keeps frame parsing cost visible independently of protobuf message work.
    func testVarintAndLengthDecodePerformance() throws {
        var writer = ProtoWriter()
        for field in 1...100 {
            writer.write(field: UInt32(field), bytes: Data(repeating: UInt8(field), count: 1_024))
        }
        let bytes = writer.data

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<100 {
                var reader = ProtoReader(bytes)
                while !reader.isAtEnd {
                    guard let tag = try? reader.nextTag() else { break }
                    _ = try? reader.readBytes()
                    _ = tag
                }
            }
        }
    }
}

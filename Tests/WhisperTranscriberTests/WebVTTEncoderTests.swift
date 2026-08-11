import XCTest
@testable import WhisperTranscriber

final class WebVTTEncoderTests: XCTestCase {
    func testFormatsHourBoundary() {
        XCTAssertEqual(WebVTTEncoder.timestamp(3_659_999), "01:00:59.999")
    }

    func testEncodesEscapedCue() {
        let output = WebVTTEncoder.encode([
            TranscriptSegment(startMilliseconds: 0, endMilliseconds: 1_230, text: "A < B & C")
        ])
        XCTAssertEqual(output, "WEBVTT\n\n00:00:00.000 --> 00:00:01.230\nA &lt; B &amp; C\n")
    }

    func testDropsEmptyOrInvalidCues() {
        let output = WebVTTEncoder.encode([
            TranscriptSegment(startMilliseconds: 1_000, endMilliseconds: 1_000, text: "skip"),
            TranscriptSegment(startMilliseconds: 1_000, endMilliseconds: 2_000, text: " ")
        ])
        XCTAssertEqual(output, "WEBVTT\n")
    }

    func testKeepsBlankLinesInsideOneCue() {
        let output = WebVTTEncoder.encode([
            TranscriptSegment(startMilliseconds: 0, endMilliseconds: 1_000, text: "First\n\nSecond")
        ])
        XCTAssertTrue(output.contains("First\n \nSecond"))
    }

    func testFormatsKnownModelDownloadProgress() {
        let progress = ModelDownloadProgress(bytesReceived: 524_288_000, totalBytes: 1_048_576_000)
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertTrue(progress.description.contains("50%"))
    }

}

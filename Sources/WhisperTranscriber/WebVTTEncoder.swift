import Foundation

enum WebVTTEncoder {
    static func encode(_ segments: [TranscriptSegment]) -> String {
        let cues = segments.compactMap { segment -> String? in
            guard segment.endMilliseconds > segment.startMilliseconds else { return nil }
            let text = sanitize(segment.text)
            guard !text.isEmpty else { return nil }
            return "\(timestamp(segment.startMilliseconds)) --> \(timestamp(segment.endMilliseconds))\n\(text)"
        }
        return (["WEBVTT"] + cues).joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ milliseconds: Int64) -> String {
        let value = max(0, milliseconds)
        let hours = value / 3_600_000
        let minutes = (value / 60_000) % 60
        let seconds = (value / 1_000) % 60
        let fraction = value % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, fraction)
    }

    private static func sanitize(_ text: String) -> String {
        let escaped = text.unicodeScalars.compactMap { scalar in
            scalar.value == 0 || (scalar.value < 0x20 && scalar != "\n" && scalar != "\t") ? nil : Character(String(scalar))
        }
        .reduce(into: "") { $0.append($1) }
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        // Blank lines terminate WebVTT cues, so keep visual separation without ending a cue.
        var result = escaped
        while result.contains("\n\n") {
            result = result.replacingOccurrences(of: "\n\n", with: "\n \n")
        }
        return result
    }
}

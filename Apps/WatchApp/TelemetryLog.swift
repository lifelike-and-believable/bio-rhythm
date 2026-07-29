import Foundation
import HRDJCore

/// Append-only JSONL, one file per session. SPEC.md §11.3.
///
/// This is the tuning instrument for §6.7 and a first-class deliverable, not
/// debug output. M2's whole purpose is producing these files and reading them
/// afterwards, so the format is fixed now, before it starts carrying data
/// anyone wants to compare across sessions.
///
/// `Decision` deliberately has no wall-clock field — `HRDJCore` has no wall
/// clock. The `"t"` stamp is added here, at the only layer that does.
actor TelemetryLog {
    /// §11.3 suggests capping at roughly 5 MB and 10 sessions.
    static let maximumSessions = 10
    static let maximumTotalBytes = 5 * 1024 * 1024

    private let fileURL: URL
    private var handle: FileHandle?
    /// Instance rather than static: `JSONEncoder` is a non-Sendable class, so a
    /// shared static one is a data race the compiler rejects outright. Held by
    /// the actor, it is isolated for free.
    private let encoder: JSONEncoder

    /// §11.3's stamps are "2026-07-28T14:03:11.482Z". `ISO8601FormatStyle` is a
    /// struct and Sendable, unlike `ISO8601DateFormatter`, so it can be shared.
    private static let stampStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )

    /// Where session logs live. Inside the app container, so the system reclaims
    /// them with the app and nothing needs a privacy prompt.
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    init(directory: URL, startedAt: Date = Date()) throws {
        let encoder = JSONEncoder()
        // `.iso8601` drops the fractional seconds, and there is no built-in
        // strategy that keeps them, so the style does the work. Millisecond
        // precision matters when reconstructing a commit window afterwards.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.stampStyle))
        }
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder

        // Colons are legal in a filename but a nuisance in every shell that
        // will later be pointed at these files.
        let stamp = startedAt
            .formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
            .replacingOccurrences(of: ":", with: "")
        self.fileURL = directory.appendingPathComponent("session-\(stamp).jsonl")

        try Self.rotate(in: directory)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: fileURL)
    }

    /// Appends one record. Failures are swallowed on purpose: a full disk must
    /// not take the workout down with it. The session is the product; the log
    /// is evidence about the session.
    func append(_ decision: Decision, at wallClock: Date = Date()) {
        guard let handle else { return }
        do {
            let data = try encoder.encode(Record(t: wallClock, decision: decision))
            handle.write(data)
            handle.write(Data("\n".utf8))
        } catch {
            // Nothing useful to do here, and nowhere to report it that would
            // not itself be a log write.
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    var url: URL { fileURL }

    // MARK: - Wire format

    /// Flattens the §11.3 fields and the wall-clock stamp into one object.
    private struct Record: Encodable {
        let t: Date
        let decision: Decision

        private enum StampKey: String, CodingKey { case t }

        func encode(to encoder: any Encoder) throws {
            try decision.encode(to: encoder)
            var container = encoder.container(keyedBy: StampKey.self)
            try container.encode(t, forKey: .t)
        }
    }

    // MARK: - Rotation

    /// Drops the oldest sessions until both caps are satisfied. Runs before the
    /// new file is created, so the cap counts the session about to start.
    private static func rotate(in directory: URL) throws {
        let manager = FileManager.default
        let existing = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return leftDate > rightDate  // newest first
        }

        var keptBytes = 0
        for (index, url) in existing.enumerated() {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let overSessionCap = index >= maximumSessions - 1
            let overByteCap = keptBytes + size > maximumTotalBytes

            if overSessionCap || overByteCap {
                try? manager.removeItem(at: url)
            } else {
                keptBytes += size
            }
        }
    }
}

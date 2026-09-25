import Foundation

/// A record commits independently; one failure must not prevent later records being checked.
public enum SummaryRecordBatch {
    public static func run<Record>(records: [Record], process: (Record, Int) async throws -> Void,
                                   failed: (Record, Error) -> Void) async throws {
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            do { try await process(record, index) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                failed(record, error)
            }
        }
    }
}

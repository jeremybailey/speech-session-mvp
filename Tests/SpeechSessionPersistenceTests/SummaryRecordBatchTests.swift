import XCTest
@testable import SpeechSessionPersistence

final class SummaryRecordBatchTests: XCTestCase {
    func testFailedInvoiceDoesNotBlockLaterRecordsOrRepeatSuccesses() async throws {
        var saved: [Int] = [], failed: [Int] = [], visits: [Int] = []
        try await SummaryRecordBatch.run(records: [1,2,3,4]) { record, index in
            visits.append(record)
            XCTAssertEqual(index, record - 1)
            if record == 2 { throw SummaryResponseError.responseTooLong }
            saved.append(record)
        } failed: { record, _ in failed.append(record) }
        XCTAssertEqual(visits, [1,2,3,4])
        XCTAssertEqual(saved, [1,3,4])
        XCTAssertEqual(failed, [2])
        try await SummaryRecordBatch.run(records: failed) { record, _ in saved.append(record) } failed: { _, _ in XCTFail() }
        XCTAssertEqual(saved, [1,3,4,2])
    }
    func testCancellationStopsTheBatchWithoutReportingTechnicalFailure() async {
        var visits: [Int] = []
        do {
            try await SummaryRecordBatch.run(records: [1,2,3]) { record, _ in
                visits.append(record)
                if record == 2 { throw CancellationError() }
            } failed: { _, _ in XCTFail() }
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(visits, [1,2])
    }
}

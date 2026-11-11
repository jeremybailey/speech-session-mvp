import XCTest
@testable import SpeechSessionPersistence

final class StoryOverviewRefreshTests: XCTestCase {
    func testOnlyReviewedSentencesAndTheirSourcesArePublished() throws {
        let sources = ["E1","E2"].map { StoryEvidence(id:$0,text:"Synthetic evidence",recordID:UUID(),title:"Test") }
        let draft = #"{"sentences":[{"text":"A.","citationIDs":["E2"]},{"text":"B.","citationIDs":["missing"]},{"text":"C.","citationIDs":["E1"]}]}"#
        let sentences = try StoryOverviewRefresh.sentences(draft,sources:sources)
        XCTAssertEqual(sentences.map(\.text),["A.","C."])
        let result = try StoryOverviewRefresh.publication(#"{"supported":[2,2]}"#, sentences:sentences,sources:sources)
        XCTAssertEqual(result.text,"C.")
        XCTAssertEqual(result.evidence,[sources[0]])
        for bad in [#"{"supported":[]}"#, #"{"supported":[1,3]}"#, #"{"kind":"answer","text":"A."}"#] {
            XCTAssertThrowsError(try StoryOverviewRefresh.publication(bad,sentences:sentences,sources:sources))
        }
    }
}

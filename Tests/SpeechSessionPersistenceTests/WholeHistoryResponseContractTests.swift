import XCTest
import Foundation
@testable import SpeechSessionPersistence

final class WholeHistoryResponseContractTests: XCTestCase {
    func testSharedServerAndActualAppDecoderContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("vercel-openai-proxy/tests/fixtures/whole-history-contract.json"))
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(corpus["records"] as? [[String: Any]])
        let locators = try XCTUnwrap(corpus["locators"] as? [String: [String: Any]])
        for item in try XCTUnwrap(corpus["cases"] as? [[String: Any]]) {
            let name = try XCTUnwrap(item["name"] as? String)
            let raw = String(data: try JSONSerialization.data(withJSONObject: item["proposal"]!), encoding: .utf8)!
            if item["valid"] as? Bool == true {
                let result = try WholeHistoryResponseContract.decode(raw, locators: locators, originals: records, version: "category-semantics-v8")
                XCTAssertFalse(result.facts.isEmpty, name)
                if name == "sole explicit evidence restores empty reciprocal allergy link" {
                    XCTAssertEqual(result.facts.first?.groups,["c1"])
                    XCTAssertEqual(result.facts.first?.category,"allergies")
                    XCTAssertEqual(result.facts.first?.text,"Synthetic eye discomfort reported.")
                }
                if name == "distinct source context annotations are preserved" {
                    XCTAssertEqual(result.facts.first?.fields?.filter{$0.label == "Context"}.count,2)
                }
                if name == "compound allergy keeps existing link and completes sole explicit reciprocal evidence" {
                    XCTAssertEqual(result.facts.first?.groups,["c1","c2"])
                    XCTAssertEqual(result.facts.first?.status,"reported")
                }
                if name == "historical structured medication instructions" {
                    XCTAssertEqual(result.facts.first?.status, "historical")
                    XCTAssertEqual(result.facts.first?.category, "medications")
                    XCTAssertNotNil(result.facts.first?.plan)
                }
                if name == "test plan projects to care" { XCTAssertEqual(result.facts.first?.category, "carePlan") }
            } else {
                XCTAssertThrowsError(try WholeHistoryResponseContract.decode(raw, locators: locators, originals: records, version: "category-semantics-v8"), name)
            }
        }
        var altered = locators
        altered["r1.p1"]?["sourceSHA256"] = "altered"
        let raw = String(data: try JSONSerialization.data(withJSONObject: (corpus["cases"] as! [[String: Any]])[0]["proposal"]!), encoding: .utf8)!
        XCTAssertThrowsError(try WholeHistoryResponseContract.decode(raw, locators: altered, originals: records, version: nil))
    }
    func testBalancedProviderOutputThroughActualAppDecoder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("vercel-openai-proxy/tests/fixtures/whole-history-balanced-synthetic.json"))
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(corpus["records"] as? [[String: Any]])
        let locators = try XCTUnwrap(corpus["locators"] as? [String: [String: Any]])
        let raw = String(data: try JSONSerialization.data(withJSONObject: corpus["proposal"]!), encoding: .utf8)!
        let result = try WholeHistoryResponseContract.decode(raw, locators: locators, originals: records, version: "category-balanced-v10")
        let categories = Set(result.facts.map(\.category))
        for category in ["testsAndLabs", "vaccinations", "symptoms", "findings", "practitionerContact", "allergies", "medications", "carePlan", "followUp", "biopsychosocialContext"] {
            XCTAssertTrue(categories.contains(category), category)
        }
    }

    func testAggregateFindingKeepsBothNamesAndFullStatement() {
        let entry=SummaryEntry(category:.findings,title:"Tenderness with swelling.",fields:[.init(label:"Name",value:"Tenderness"),.init(label:"Name",value:"Swelling")])
        let rendered=StructuredArtifact.display(entry)
        XCTAssertEqual(rendered.title,"Tenderness · Swelling")
        XCTAssertTrue(rendered.details.contains("Tenderness with swelling."))
        XCTAssertEqual(rendered.fields.count,2)
    }

}

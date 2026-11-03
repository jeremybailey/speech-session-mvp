import XCTest
@testable import SpeechSessionPersistence
final class StructuredArtifactTests:XCTestCase {
 private func b(_ text:String, _ category:SummaryEntryCategory = .practitionerContact)->SummaryEntry {
  var e=SummaryEntry(category:category,title:text)
  var evidence=ClinicalEvidence();evidence.assessmentMethod=WholeHistoryPublication.version;e.evidence=evidence;return e
 }
 func testTypedContactIncludesEditableAddressOrganizationAndRoleWithoutNarrativeInventory() {
  let source="Dr. Jane Doe, Example Clinic. Physician. Suite 2, 123 Example St, Toronto ON M1M 1M1. Phone 416-555-0123."
  let values=[["name","Dr. Jane Doe"],["organization","Example Clinic"],["role","Physician"],["address","Suite 2, 123 Example St, Toronto ON M1M 1M1"],["phone","416-555-0123"],["email","invented@example.org"]]
  var e=b("Dr. Jane Doe");e.fields=StructuredArtifact.grounded(values,category:.practitionerContact,sources:[source]);e.evidence?.artifactSchema=StructuredArtifact.version
  let d=BClinicalPresentation.display(e)
  XCTAssertEqual(d.title,"Dr. Jane Doe");XCTAssertTrue(d.details.isEmpty)
  XCTAssertEqual(d.fields.first{$0.label=="Address"}?.value,values[3][1])
  XCTAssertEqual(d.fields.first{$0.label=="Organization"}?.value,"Example Clinic")
  XCTAssertNil(d.fields.first{$0.label=="Email"})
  XCTAssertEqual(HealthDetailPresentation.fields(d).count,4)
 }
 func testSourceOnlyFieldsAcrossAllStructuredCategoriesPreserveNegationAndContext() {
  for (category,keys) in StructuredArtifact.keys {
   let values=keys.map{[$0,"value for "+$0]}
   let source=values.map{$0[1]}.joined(separator:"; ")
   let fields=StructuredArtifact.grounded(values,category:category,sources:[source])
   XCTAssertEqual(fields.count,keys.count)
   XCTAssertTrue(StructuredArtifact.grounded([["bad","value"]],category:category,sources:["value"]).isEmpty)
   var e=b("No confirmed diagnosis; investigation only",category);e.fields=fields;e.evidence?.artifactSchema=StructuredArtifact.version
   let display=BClinicalPresentation.display(e)
   XCTAssertTrue(display.details.contains("No confirmed diagnosis; investigation only"),category.rawValue)
  }
 }
 func testCachedContactRestoresExplicitAddressAndOrganizationAndRole() {
  let e=b("Eye invoice identifies Dr. Jessica Yang, OD, and Eyedeology; clinic address is Suite 245, 520 3rd Ave SW, Calgary, AB; phone (587) 353-5061.")
  let d=BClinicalPresentation.display(e)
  XCTAssertEqual(d.fields.first{$0.label=="Address"}?.value,"Suite 245, 520 3rd Ave SW, Calgary, AB")
  XCTAssertTrue(d.details.isEmpty)
  let organization=BClinicalPresentation.display(b("Prescription label identifies Dr. Brett Poulis, Mitchell Eye Centre."))
  XCTAssertEqual(organization.fields.first{$0.label=="Organization"}?.value,"Mitchell Eye Centre")
  XCTAssertTrue(organization.details.isEmpty)
  let role=BClinicalPresentation.display(b("Identifies Dr. Bama as the doctor treating this eye condition; spelling as transcribed."))
  XCTAssertEqual(role.fields.first{$0.label=="Role or specialty"}?.value,"the doctor treating this eye condition")
  XCTAssertEqual(role.fields.first{$0.label=="Review"}?.value,"spelling as transcribed.")
 }
 func testPrintedRosterIsStructuredWithoutSelectingAPrescriberOrChannelOwner() {
  let e=b("Prescription image lists Dr. Jamie Bhamra, Dr. Ugo Dodd, Dr. Brett Poulis and Dr. Carolyn Draude; prescriber/signature unclear.")
  let d=BClinicalPresentation.display(e)
  XCTAssertEqual(d.title,"Contacts listed on record")
  XCTAssertEqual(d.fields.first{$0.label=="Names listed"}?.value.split(separator:"\n").count,4)
  XCTAssertTrue(d.details.contains("prescriber/signature unclear"))
  XCTAssertNil(d.evidence?.practitioner)
  XCTAssertFalse(d.fields.contains{$0.label=="Phone" || $0.label=="Role or specialty"})
 }
}

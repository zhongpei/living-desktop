import MyPetContent
import XCTest

final class ContentBoundaryTests: XCTestCase {
    func testMissingPackReportsContractError() {
        XCTAssertThrowsError(try ClipLibrary.load(from: URL(fileURLWithPath: "/missing/petpack")))
    }
}

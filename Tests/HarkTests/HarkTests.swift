import XCTest
@testable import Hark

final class HarkTests: XCTestCase {
    func testHarkBundleLoads() {
        let bundle = Bundle(for: type(of: self))
        XCTAssertNotNil(bundle)
    }
}

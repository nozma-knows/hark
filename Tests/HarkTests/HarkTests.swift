@testable import Hark
import XCTest

final class HarkTests: XCTestCase {
    func testHarkBundleLoads() {
        let bundle = Bundle(for: type(of: self))
        XCTAssertNotNil(bundle)
    }
}

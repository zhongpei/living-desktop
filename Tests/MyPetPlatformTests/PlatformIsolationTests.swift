import CoreGraphics
import XCTest
@testable import MyPetPlatform

final class PlatformIsolationTests: XCTestCase {
    func testLatestValueWorkerCollapsesUpdatesWhileConsumerIsBusy() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let finished = expectation(description: "latest value consumed")
        let lock = NSLock()
        var values: [Int] = []
        let worker = LatestValueWorker<Int>(label: "test.latest") { value in
            if value == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
            lock.lock()
            values.append(value)
            lock.unlock()
            if value == 3 { finished.fulfill() }
        }

        worker.submit(1)
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)
        worker.submit(2)
        worker.submit(3)
        releaseFirst.signal()
        wait(for: [finished], timeout: 2)
        worker.cancelPendingAndWait()

        XCTAssertEqual(values, [1, 3])
    }

    func testMacWindowSourceDecodesPlainWindowFactsWithoutGameplayTypes() {
        let item: [String: Any] = [
            kCGWindowLayer as String: 0,
            kCGWindowOwnerPID as String: 42,
            kCGWindowOwnerName as String: "Editor",
            kCGWindowNumber as String: 7,
            kCGWindowAlpha as String: 1.0,
            kCGWindowName as String: "Document",
            kCGWindowBounds as String: ["X": 10.0, "Y": 20.0, "Width": 800.0, "Height": 600.0],
        ]

        let window = MacWindowSource.decodeWindow(item, ownPID: 99)

        XCTAssertEqual(window?.id, 7)
        XCTAssertEqual(window?.owner, "Editor")
        XCTAssertEqual(window?.title, "Document")
        XCTAssertEqual(window?.bounds, CGRect(x: 10, y: 20, width: 800, height: 600))
    }
}

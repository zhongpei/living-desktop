import CoreGraphics
import MyPetContent
@testable import MyPetRender
import XCTest

final class SkeletonMotionRuntimeTests: XCTestCase {
    func testOneMotionRetargetsAcrossThreeDifferentCharacterRigs() throws {
        let document = try motionDocument()
        let player = try SkeletonMotionPlayer(document: document, looping: true)

        let small = try SkeletonRig2D.humanoid(
            spine: 30, head: 12, shoulderHalfWidth: 10, hipHalfWidth: 7,
            upperArm: 14, forearm: 12, thigh: 18, calf: 16)
        let normal = try SkeletonRig2D.humanoid(
            spine: 45, head: 18, shoulderHalfWidth: 16, hipHalfWidth: 10,
            upperArm: 22, forearm: 19, thigh: 28, calf: 25)
        let tall = try SkeletonRig2D.humanoid(
            spine: 60, head: 22, shoulderHalfWidth: 20, hipHalfWidth: 12,
            upperArm: 28, forearm: 25, thigh: 42, calf: 38)

        let smallPose = try player.sample(at: 0, rig: small)
        let normalPose = try player.sample(at: 0, rig: normal)
        let tallPose = try player.sample(at: 0, rig: tall)

        // Same H3 motion direction, different target-character proportions.
        XCTAssertEqual(smallPose["head"]?.y, -42, accuracy: 0.001)
        XCTAssertEqual(normalPose["head"]?.y, -63, accuracy: 0.001)
        XCTAssertEqual(tallPose["head"]?.y, -82, accuracy: 0.001)

        XCTAssertEqual(smallPose["left_wrist"]?.x, -36, accuracy: 0.001)
        XCTAssertEqual(normalPose["left_wrist"]?.x, -57, accuracy: 0.001)
        XCTAssertEqual(tallPose["left_wrist"]?.x, -73, accuracy: 0.001)

        XCTAssertEqual(smallPose["left_ankle"]?.y, 34, accuracy: 0.001)
        XCTAssertEqual(normalPose["left_ankle"]?.y, 53, accuracy: 0.001)
        XCTAssertEqual(tallPose["left_ankle"]?.y, 80, accuracy: 0.001)
    }

    func testPlayerInterpolatesDirectionsBeforeRetargeting() throws {
        let first = frame(index: 0, time: 0, leftUpperArm: MotionVector3(x: -1, y: 0, confidence: 1))
        let second = frame(index: 1, time: 1, leftUpperArm: MotionVector3(x: 0, y: 1, confidence: 1))
        let document = UniversalMotionDocument(
            fps: 1,
            durationSeconds: 1,
            frames: [first, second])
        let rig = try SkeletonRig2D.humanoid(
            spine: 40, head: 15, shoulderHalfWidth: 10, hipHalfWidth: 8,
            upperArm: 20, forearm: 10, thigh: 25, calf: 20)
        let player = try SkeletonMotionPlayer(document: document, looping: false)

        let pose = try player.sample(at: 0.5, rig: rig)
        let shoulder = try XCTUnwrap(pose["left_shoulder"])
        let elbow = try XCTUnwrap(pose["left_elbow"])
        let dx = elbow.x - shoulder.x
        let dy = elbow.y - shoulder.y

        XCTAssertEqual(hypot(dx, dy), 20, accuracy: 0.001)
        XCTAssertLessThan(dx, 0)
        XCTAssertGreaterThan(dy, 0)
        XCTAssertEqual(abs(dx), abs(dy), accuracy: 0.001)
    }

    func testInvalidRigIsRejectedBeforePlayback() {
        XCTAssertThrowsError(try SkeletonRig2D(lengths: [:])) { error in
            XCTAssertEqual(
                error as? SkeletonMotionRuntimeError,
                .invalidRigSegment("spine"))
        }
    }

    private func motionDocument() throws -> UniversalMotionDocument {
        let document = UniversalMotionDocument(
            fps: 24,
            durationSeconds: 0,
            source: UniversalMotionSource(
                kind: "h3-passed-attempt",
                character: "teacher",
                action: "run",
                attempt: 0),
            frames: [frame(index: 0, time: 0)])
        try document.validate()
        return document
    }

    private func frame(
        index: Int,
        time: Double,
        leftUpperArm: MotionVector3 = MotionVector3(x: -1, y: 0, confidence: 1)
    ) -> UniversalMotionFrame {
        UniversalMotionFrame(
            index: index,
            time: time,
            rootScreen: MotionVector3(x: 0.5, y: 0.75, confidence: 1),
            joints: [
                "left_hip": MotionVector3(x: -1, y: 0, confidence: 1),
                "right_hip": MotionVector3(x: 1, y: 0, confidence: 1),
            ],
            bones: [
                "spine": MotionVector3(x: 0, y: -1, confidence: 1),
                "head": MotionVector3(x: 0, y: -1, confidence: 1),
                "left_shoulder": MotionVector3(x: -1, y: 0, confidence: 1),
                "right_shoulder": MotionVector3(x: 1, y: 0, confidence: 1),
                "left_upper_arm": leftUpperArm,
                "right_upper_arm": MotionVector3(x: 1, y: 0, confidence: 1),
                "left_forearm": MotionVector3(x: -1, y: 0, confidence: 1),
                "right_forearm": MotionVector3(x: 1, y: 0, confidence: 1),
                "left_thigh": MotionVector3(x: 0, y: 1, confidence: 1),
                "right_thigh": MotionVector3(x: 0, y: 1, confidence: 1),
                "left_calf": MotionVector3(x: 0, y: 1, confidence: 1),
                "right_calf": MotionVector3(x: 0, y: 1, confidence: 1),
            ])
    }
}

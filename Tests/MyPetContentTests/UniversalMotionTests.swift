import Foundation
@testable import MyPetContent
import XCTest

final class UniversalMotionTests: XCTestCase {
    func testDecodesCompilerDocumentIncludingNullableJoints() throws {
        let data = Data(
            """
            {
              "format":"mypet-motion-v1",
              "skeleton":"coco17-v1",
              "joint_order":["nose"],
              "bone_order":["spine"],
              "coordinates":{"x":"right"},
              "fps":24,
              "frame_count":1,
              "duration_seconds":0,
              "source":{
                "kind":"h3-passed-attempt",
                "character":"alice",
                "action":"run",
                "attempt":1,
                "plan_sha256":"abc",
                "generation_mode":"baseline_20",
                "seed":7,
                "raw_frame_count":107
              },
              "quality":{
                "detection_rate":1.0,
                "mean_confidence":0.91,
                "min_confidence":0.25
              },
              "frames":[{
                "index":0,
                "time":0,
                "root_screen":[0.5,0.7,0.95],
                "torso_scale_pixels":120,
                "mean_confidence":0.91,
                "joints":{
                  "left_hip":[-0.2,0,0.95],
                  "right_hip":[0.2,0,0.95],
                  "left_wrist":null
                },
                "bones":{
                  "spine":[0,-1,0.95]
                }
              }]
            }
            """.utf8)

        let motion = try UniversalMotionDocument.decode(data)

        XCTAssertEqual(motion.source?.character, "alice")
        XCTAssertEqual(motion.source?.action, "run")
        XCTAssertEqual(motion.frames[0].rootScreen, MotionVector3(x: 0.5, y: 0.7, confidence: 0.95))
        XCTAssertNil(motion.frames[0].joints["left_wrist"] ?? nil)
        let spine = try XCTUnwrap(motion.frames[0].bones["spine"] ?? nil)
        XCTAssertEqual(spine.y, -1)
    }

    func testRejectsMismatchedFrameCount() throws {
        let frame = UniversalMotionFrame(
            index: 0,
            time: 0,
            rootScreen: MotionVector3(x: 0.5, y: 0.5, confidence: 1),
            joints: [:],
            bones: [:])
        let motion = UniversalMotionDocument(
            fps: 24,
            frameCount: 2,
            durationSeconds: 0,
            frames: [frame])

        XCTAssertThrowsError(try motion.validate()) { error in
            XCTAssertEqual(
                error as? UniversalMotionError,
                .invalidMetadata("frame_count does not match frames"))
        }
    }

    func testRejectsUnknownSkeletonContract() {
        let frame = UniversalMotionFrame(
            index: 0,
            time: 0,
            rootScreen: MotionVector3(x: 0, y: 0, confidence: 1),
            joints: [:],
            bones: [:])
        let motion = UniversalMotionDocument(
            skeleton: "other-v1",
            fps: 24,
            durationSeconds: 0,
            frames: [frame])

        XCTAssertThrowsError(try motion.validate()) { error in
            XCTAssertEqual(
                error as? UniversalMotionError,
                .unsupportedSkeleton("other-v1"))
        }
    }
}

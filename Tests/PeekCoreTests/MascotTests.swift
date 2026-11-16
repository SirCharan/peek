import XCTest
@testable import PeekCore

final class MascotTests: XCTestCase {
    func testGazeStaysInsideUnitDisk() {
        for p in [CGPoint(x: 5000, y: -3000), CGPoint(x: 3, y: 4), CGPoint(x: -40, y: 90)] {
            let g = MascotMath.gaze(from: .zero, to: p)
            XCTAssertLessThanOrEqual((g.dx * g.dx + g.dy * g.dy).squareRoot(), 1.0001)
        }
        XCTAssertEqual(MascotMath.gaze(from: .zero, to: .zero), .zero)
    }
    func testGazePointsTowardCursorInEachQuadrant() {
        for (sx, sy) in [(1.0, 1.0), (-1, 1), (-1, -1), (1, -1)] {
            let g = MascotMath.gaze(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10 + 50 * sx, y: 10 + 30 * sy))
            XCTAssertEqual(g.dx.sign, sx.sign); XCTAssertEqual(g.dy.sign, sy.sign)
        }
    }
    func testReduceMotionPoseIsStatic() {
        for s in MascotState.allCases {
            for t in [0.2, 1.0, 3.3, 9.1] {
                let p = MascotMath.pose(s, t: t, reduceMotion: true)
                XCTAssertEqual(p.hop, 0); XCTAssertNil(p.sweep)
            }
            XCTAssertEqual(MascotMath.pose(s, t: 3, reduceMotion: true), MascotMath.pose(s, t: 8, reduceMotion: true))
        }
    }
    func testStatePoses() {
        XCTAssertEqual(MascotMath.pose(.done, t: 1, reduceMotion: false).happy, 1)
        XCTAssertEqual(MascotMath.pose(.done, t: 3, reduceMotion: false).open, 1)
        XCTAssertNotNil(MascotMath.pose(.working, t: 1, reduceMotion: false).sweep)
        XCTAssertEqual(MascotMath.pose(.failed, t: 1, reduceMotion: false).open, 0)
        XCTAssertEqual(MascotState(buddy: "compacting"), .working)
    }
}

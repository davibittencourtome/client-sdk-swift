/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// `VideoPublishOptions.scalabilityMode` must reach the RTP encoding parameters of an SVC publish.
/// Oracle: the `scalabilityMode` strings are the ones `livekit-client` (JS) sends and the SFU
/// understands (`L3T3_KEY`, `L1T3`), not what this implementation happened to produce.
class VideoEncodingsScalabilityModeTests: LKTestCase {
    private let dimensions = Dimensions(width: 1280, height: 720)

    func testSvcDefaultCameraIsL3T3Key() {
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: VideoPublishOptions(preferredCodec: .vp9))
        XCTAssertEqual(encodings.count, 1)
        XCTAssertEqual(encodings[0].scalabilityMode, "L3T3_KEY")
    }

    func testSvcDefaultScreenShareIsL1T3() {
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: VideoPublishOptions(preferredCodec: .vp9),
                                                    isScreenShare: true)
        XCTAssertEqual(encodings.count, 1)
        XCTAssertEqual(encodings[0].scalabilityMode, "L1T3")
    }

    func testExplicitScalabilityModeWinsForSvcCamera() {
        let options = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: options)
        XCTAssertEqual(encodings.count, 1)
        XCTAssertEqual(encodings[0].scalabilityMode, "L1T3")
    }

    func testExplicitScalabilityModeSurvivesCodecOverride() {
        // Backup-codec / republish paths pass `overrideVideoCodec`; the option must still apply.
        let options = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: options,
                                                    overrideVideoCodec: .av1)
        XCTAssertEqual(encodings.count, 1)
        XCTAssertEqual(encodings[0].scalabilityMode, "L1T3")
    }

    func testScalabilityModeIsIgnoredForNonSvcCodec() {
        // VP8 has no SVC: simulcast layers, none of them carrying a scalability mode.
        let options = VideoPublishOptions(preferredCodec: .vp8, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: options)
        XCTAssertGreaterThan(encodings.count, 1)
        XCTAssertTrue(encodings.allSatisfy { $0.scalabilityMode == nil })
    }

    func testOptionsEqualityIncludesScalabilityMode() {
        let a = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        let b = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L3T3_KEY)
        let c = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertEqual(a.hash, c.hash)
    }
}

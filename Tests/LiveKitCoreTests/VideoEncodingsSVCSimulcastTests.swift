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
import Testing

/// VP9 published as rid based simulcast with one spatial layer per stream (`L1T3` on every
/// layer), so the server has smaller versions for subscribers with little bandwidth. Parity with
/// livekit-client (`isSVCSimulcast`, server newer than v1.13.6).
struct VideoEncodingsSVCSimulcastTests {
    private let dimensions = Dimensions(width: 1280, height: 720)
    private let l1t3Simulcast = VideoPublishOptions(simulcast: true, preferredCodec: .vp9, scalabilityMode: .L1T3)

    @Test func publishesVP9AsSimulcastWhenServerSupportsIt() {
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: l1t3Simulcast,
                                                    serverVersion: "1.13.11")
        #expect(encodings.map(\.rid) == ["q", "h", "f"])
        #expect(encodings.map { $0.scaleResolutionDownBy?.doubleValue } == [4.0, 2.0, 1.0])
        #expect(encodings.allSatisfy { $0.scalabilityMode == "L1T3" })
        #expect(!Utils.isSVC(encodings: encodings))

        let layers = dimensions.videoLayers(for: encodings)
        #expect(layers.map(\.width) == [320, 640, 1280])
        #expect(layers.map(\.height) == [180, 360, 720])
        #expect(layers.map(\.quality) == [.low, .medium, .high])
    }

    @Test func keepsSVCWhenServerDoesNotSupportSimulcast() {
        // Last server version without support for VP9/AV1 simulcast.
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: l1t3Simulcast,
                                                    serverVersion: "1.13.6")
        #expect(encodings.count == 1)
        #expect((encodings[0].rid ?? "").isEmpty)
        #expect(encodings[0].scalabilityMode == "L1T3")
        #expect(Utils.isSVC(encodings: encodings))
        // A single SVC layer at full resolution, reported as before this change.
        let layers = dimensions.videoLayers(for: encodings)
        #expect(layers.map(\.width) == [1280])
        #expect(layers.map(\.height) == [720])
    }

    @Test func keepsSVCWhenServerVersionIsUnknown() {
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: l1t3Simulcast, serverVersion: nil)
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L1T3")
    }

    @Test func keepsMultipleSpatialLayerModesAsSVC() {
        let options = VideoPublishOptions(simulcast: true, preferredCodec: .vp9, scalabilityMode: .L3T3_KEY)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: options, serverVersion: "1.13.11")
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L3T3_KEY")
    }

    @Test func keepsSVCWhenSimulcastIsDisabled() {
        let options = VideoPublishOptions(simulcast: false, preferredCodec: .vp9, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: options, serverVersion: "1.13.11")
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L1T3")
    }

    @Test func keepsSingleL1T3ForScreenShare() {
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: l1t3Simulcast,
                                                    isScreenShare: true,
                                                    serverVersion: "1.13.11")
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L1T3")
    }

    @Test func publishesTwoVersionsBelow960() {
        let small = Dimensions(width: 640, height: 480)
        let encodings = Utils.computeVideoEncodings(dimensions: small, publishOptions: l1t3Simulcast, serverVersion: "1.13.11")
        // rids are handed out from the smallest layer up, as for VP8 simulcast.
        #expect(encodings.map(\.rid) == ["q", "h"])
        #expect(encodings.allSatisfy { $0.scalabilityMode == "L1T3" })
    }

    @Test func nonSVCCodecsAreUnchanged() {
        let options = VideoPublishOptions(simulcast: true, preferredCodec: .vp8, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: options, serverVersion: "1.13.11")
        #expect(encodings.count == 3)
        #expect(encodings.allSatisfy { $0.scalabilityMode == nil })
    }

    @Test func serverVersionGate() {
        #expect(!Utils.isSVCSimulcastSupported(serverVersion: nil))
        #expect(!Utils.isSVCSimulcastSupported(serverVersion: ""))
        #expect(!Utils.isSVCSimulcastSupported(serverVersion: "1.9.3"))
        #expect(!Utils.isSVCSimulcastSupported(serverVersion: "1.13.6"))
        #expect(Utils.isSVCSimulcastSupported(serverVersion: "1.13.7"))
        #expect(Utils.isSVCSimulcastSupported(serverVersion: "1.13.11"))
        #expect(Utils.isSVCSimulcastSupported(serverVersion: "1.14.0"))
    }
}

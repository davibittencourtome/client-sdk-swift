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
import LiveKitWebRTC
import Testing

/// libwebrtc only publishes VP9/AV1 as real simulcast when the encodings it holds carry their
/// scalabilityMode next to scaleResolutionDownBy. These checks read the encodings back from the
/// native sender, after every path that rewrites the sender parameters.
struct SVCSimulcastSenderParametersTests {
    private func describe(_ encodings: [LKRTCRtpEncodingParameters]) -> [String] {
        encodings.map { "\($0.rid ?? "-"):\($0.scalabilityMode ?? "nil"):\($0.scaleResolutionDownBy?.doubleValue ?? -1)" }
    }

    @Test func nativeSenderKeepsScalabilityModeOnEveryLayer() async throws {
        let options = VideoPublishOptions(simulcast: true, preferredCodec: .vp9, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: Dimensions(width: 720, height: 1280),
                                                    publishOptions: options,
                                                    serverVersion: "1.13.11")
        let wanted = describe(encodings)

        let (afterAdd, afterDegradation) = try await RTC.run { () throws -> ([String], [String]) in
            let pc = try #require(RTC.peerConnectionFactory.peerConnection(with: .liveKitDefault(),
                                                                           constraints: .defaultPCConstraints,
                                                                           delegate: nil))
            defer { pc.close() }
            let transInit = LKRTCRtpTransceiverInit()
            transInit.direction = .sendOnly
            transInit.sendEncodings = encodings
            let track = RTC.createVideoTrack(source: RTC.createVideoSource(forScreenShare: false))
            let transceiver = try #require(pc.addTransceiver(with: track, init: transInit))
            let afterAdd = self.describe(transceiver.sender.parameters.encodings)
            transceiver.sender.set(degradationPreference: .maintainFramerate)
            let afterDegradation = self.describe(transceiver.sender.parameters.encodings)
            return (afterAdd, afterDegradation)
        }
        print("SVCSIM wanted:", wanted)
        print("SVCSIM afterAdd:", afterAdd)
        print("SVCSIM afterDegradation:", afterDegradation)
        #expect(afterAdd == wanted)
        #expect(afterDegradation == wanted)
    }
}

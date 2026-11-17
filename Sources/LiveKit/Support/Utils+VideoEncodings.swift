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

internal import LiveKitWebRTC

extension Utils {
    /// Last server version that does not honour `SimulcastCodec.videoLayerMode`, i.e. that
    /// cannot receive VP9/AV1 as rid based simulcast. Same value as livekit-client.
    static let svcSimulcastLastUnsupportedServerVersion = "1.13.6"

    /// Whether the connected server accepts VP9/AV1 published as rid based simulcast.
    /// An unknown version is treated as unsupported, so the publish falls back to SVC.
    static func isSVCSimulcastSupported(serverVersion: String?) -> Bool {
        guard let serverVersion, !serverVersion.isEmpty else { return false }
        return serverVersion.compare(svcSimulcastLastUnsupportedServerVersion, options: .numeric) == .orderedDescending
    }

    /// Whether the camera is published with an SVC codec (VP9/AV1) as rid based simulcast, one
    /// spatial layer per stream, instead of SVC: the caller asked for simulcast with a single
    /// spatial layer `scalabilityMode` (`L1T*`) and the server supports it. Parity with
    /// livekit-client `isSVCSimulcast`. Screen share keeps its single `L1T3` encoding.
    static func isSVCSimulcast(videoCodec: VideoCodec?,
                               publishOptions: VideoPublishOptions,
                               isScreenShare: Bool,
                               serverVersion: String?) -> Bool
    {
        guard let videoCodec, videoCodec.isSVC, !isScreenShare, publishOptions.simulcast,
              let scalabilityMode = publishOptions.scalabilityMode, scalabilityMode.spatial == 1
        else { return false }
        return isSVCSimulcastSupported(serverVersion: serverVersion)
    }

    /// SVC publishes a single encoding without a rid that carries every layer. VP9/AV1 published
    /// as rid based simulcast also set `scalabilityMode`, on every layer, and are paused and
    /// reported per layer like any other simulcast.
    static func isSVC(encodings: [LKRTCRtpEncodingParameters]) -> Bool {
        guard let firstEncoding = encodings.first,
              ScalabilityMode.fromString(firstEncoding.scalabilityMode) != nil
        else { return false }
        return encodings.allSatisfy { ($0.rid ?? "").isEmpty }
    }

    /// - Parameter serverVersion: version of the connected server (`Room.serverVersion`), which decides
    ///   whether VP9/AV1 may be published as rid based simulcast. Deliberately without a default: a
    ///   call site that forgets it silently computes SVC encodings, and one that recomputes the sender
    ///   parameters of a simulcast track that way strips the scale of every layer, so libwebrtc falls
    ///   back to a single full resolution stream.
    static func computeVideoEncodings(
        dimensions: Dimensions,
        publishOptions: VideoPublishOptions?,
        isScreenShare: Bool = false,
        overrideVideoCodec: VideoCodec? = nil,
        serverVersion: String?,
    ) -> [LKRTCRtpEncodingParameters] {
        let publishOptions = publishOptions ?? VideoPublishOptions()
        let preferredEncoding: VideoEncoding? = isScreenShare ? publishOptions.screenShareEncoding : publishOptions.encoding
        let encoding = preferredEncoding ?? dimensions.computeSuggestedPreset(in: dimensions.computeSuggestedPresets(isScreenShare: isScreenShare))

        let videoCodec = overrideVideoCodec ?? publishOptions.preferredCodec
        let svcSimulcast = isSVCSimulcast(videoCodec: videoCodec,
                                          publishOptions: publishOptions,
                                          isScreenShare: isScreenShare,
                                          serverVersion: serverVersion)

        if let videoCodec, videoCodec.isSVC, !svcSimulcast {
            // SVC mode
            // VP9/AV1 with screen sharing requires single spatial layer, so `.L1T3` stays forced
            // there — a multi-spatial mode publishes no frames at all. An explicit
            // `publishOptions.scalabilityMode` only applies to camera encodings (parity with
            // livekit-client `scalabilityMode`).
            let scalabilityMode: ScalabilityMode = isScreenShare ? .L1T3 : (publishOptions.scalabilityMode ?? .L3T3_KEY)
            log("Using SVC mode, scalabilityMode: \(scalabilityMode)")
            return [RTC.createRtpEncodingParameters(encoding: encoding, scalabilityMode: scalabilityMode)]
        } else if !publishOptions.simulcast {
            // Not-simulcast mode
            log("Simulcast not enabled")
            return [RTC.createRtpEncodingParameters(encoding: encoding)]
        }

        // Continue to simulcast encoding computation...

        let baseParameters = VideoParameters(dimensions: dimensions,
                                             encoding: encoding)

        let requestedPresets = isScreenShare ? publishOptions.screenShareSimulcastLayers : publishOptions.simulcastLayers
        let resultPresets = computeSimulcastPresets(dimensions: dimensions,
                                                    baseParameters: baseParameters,
                                                    requestedPresets: requestedPresets,
                                                    isScreenShare: isScreenShare)

        log("Using presets: \(resultPresets), count: \(resultPresets.count) isScreenShare: \(isScreenShare)")

        let encodings = dimensions.encodings(from: resultPresets)

        if svcSimulcast, let scalabilityMode = publishOptions.scalabilityMode {
            // libwebrtc only treats several encodings of an SVC capable codec as real simulcast
            // when every encoding carries its own scalabilityMode next to its
            // scaleResolutionDownBy; otherwise they are read as legacy SVC.
            log("Using SVC simulcast, scalabilityMode \(scalabilityMode) on \(encodings.count) layer(s)")
            for encoding in encodings {
                encoding.scalabilityMode = scalabilityMode.rawStringValue
            }
        }

        return encodings
    }

    /// Builds the ordered simulcast layer list (low → high). The top layer is always
    /// `baseParameters`; lower layers are clamped so that no layer exceeds the top layer's
    /// `maxFps`, and same-resolution lower layers are additionally clamped against the top's
    /// `maxBitrate` (a layer that does not scale resolution down must not be allowed to spend
    /// more bandwidth than the top). Layer count depends on the larger output dimension:
    /// `< 480` → 1 layer, `[480, 960)` → 2 layers, `≥ 960` → 3 layers.
    static func computeSimulcastPresets(
        dimensions: Dimensions,
        baseParameters: VideoParameters,
        requestedPresets: [VideoParameters],
        isScreenShare: Bool,
    ) -> [VideoParameters] {
        let presets = (!requestedPresets.isEmpty
            ? requestedPresets
            : baseParameters.defaultSimulcastLayers(isScreenShare: isScreenShare))
            .sorted { $0 < $1 }

        guard let lowPreset = presets.first else {
            return [baseParameters]
        }
        let midPreset = presets[safe: 1]

        if dimensions.max >= 960, let midPreset {
            return [clamp(preset: lowPreset, to: baseParameters, in: dimensions),
                    clamp(preset: midPreset, to: baseParameters, in: dimensions),
                    baseParameters]
        }
        if dimensions.max >= 480 {
            return [clamp(preset: lowPreset, to: baseParameters, in: dimensions),
                    baseParameters]
        }
        return [baseParameters]
    }

    private static func clamp(preset: VideoParameters,
                              to base: VideoParameters,
                              in dimensions: Dimensions) -> VideoParameters
    {
        let presetEncoding = preset.encoding
        let baseEncoding = base.encoding
        let scaleDownBy = Double(dimensions.max) / Double(preset.dimensions.max)

        let clampedFps = Swift.min(presetEncoding.maxFps, baseEncoding.maxFps)
        // Only clamp bitrate when the preset would not actually scale resolution down — a
        // same-resolution lower layer must not be allowed to spend more bandwidth than the top.
        let clampedBitrate = scaleDownBy <= 1.0
            ? Swift.min(presetEncoding.maxBitrate, baseEncoding.maxBitrate)
            : presetEncoding.maxBitrate

        if clampedFps == presetEncoding.maxFps, clampedBitrate == presetEncoding.maxBitrate {
            return preset
        }
        return VideoParameters(
            dimensions: preset.dimensions,
            encoding: VideoEncoding(
                maxBitrate: clampedBitrate,
                maxFps: clampedFps,
                bitratePriority: presetEncoding.bitratePriority,
                networkPriority: presetEncoding.networkPriority,
            ),
        )
    }
}

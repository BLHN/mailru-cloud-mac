// winrec: records ONE window of a process with ScreenCaptureKit into a .mov, for the demo film.
//
//   swiftc -O -o <bin>/winrec Packaging/dev/winrec.swift
//   winrec --pid <pid> --seconds <N> --out <file.mov> [--fps 60] [--codec hevca|h264|prores]
//          [--mode window|display] [--wait-window <seconds>]
//
// - The window is the largest normal-layer window of that pid. It is captured with a
//   desktop-independent window filter, so it may sit behind other windows: nothing is brought
//   forward, nothing is activated, no input is sent.
// - Native pixels (point size x the display's pixel scale), cursor hidden, no shadow.
// - ScreenCaptureKit delivers a frame only when the window changes (up to --fps); the file keeps
//   those timestamps (variable frame rate) and ends exactly N seconds after the first frame.
//   Transcode with `ffmpeg -vf fps=60` for constant frame rate.
// - Default codec "hevca": HEVC with alpha, so the window's rounded corners stay transparent.
// - Prints a JSON summary: window size, frames written, effective and peak frame rate.
// - Exit 3 when screen recording is not allowed (it never falls back to screenshots).
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct Options {
    var pid: pid_t = 0
    var seconds: Double = 8
    var out = ""
    var fps = 60
    var codec = "hevca"
    var waitWindow: Double = 10
    /// "window" (default): a desktop-independent window filter, works while the window is covered
    /// or on another Space. "display": a display filter that includes only this window, cropped to
    /// it (needs the window on the current Space). "app", "exclude": experiments, kept for reference.
    var mode = "window"

    static func parse() -> Options {
        var o = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        func value() -> String {
            guard !args.isEmpty else { fail("missing value", code: 2) }
            return args.removeFirst()
        }
        while !args.isEmpty {
            switch args.removeFirst() {
            case "--pid": o.pid = pid_t(value()) ?? 0
            case "--seconds": o.seconds = Double(value()) ?? 8
            case "--out": o.out = value()
            case "--fps": o.fps = Int(value()) ?? 60
            case "--codec": o.codec = value()
            case "--wait-window": o.waitWindow = Double(value()) ?? 10
            case "--mode": o.mode = value()
            case let a: fail("unknown argument \(a)", code: 2)
            }
        }
        guard o.pid > 0, !o.out.isEmpty, o.seconds > 0 else {
            fail("usage: winrec --pid <pid> --seconds <N> --out <file.mov> [--fps 60] [--codec hevca|h264|prores]", code: 2)
        }
        return o
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("winrec: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let queue = DispatchQueue(label: "winrec.frames")
    private(set) var first: CMTime?
    private(set) var last: CMTime?
    private(set) var frames = 0
    private(set) var maxGap = 0.0
    private(set) var minGap = Double.infinity
    var stopped = false
    var streamError: Error?

    init(url: URL, width: Int, height: Int, fps: Int, codec: String) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            // The capture is sRGB; tagged BT.709 so players and ffmpeg do not guess.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch codec {
        case "h264":
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: 60_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any]
        case "prores":
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        default:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoQualityKey: 0.92,
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any]
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw NSError(domain: "winrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot add video input"]) }
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sb.isValid else { return }
        // Only complete frames carry a new image; idle frames mean "nothing changed".
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if first == nil {
            guard writer.startWriting() else {
                streamError = writer.error
                return
            }
            writer.startSession(atSourceTime: pts)
            first = pts
        }
        if let l = last {
            let gap = (pts - l).seconds
            guard gap > 0 else { return }
            maxGap = max(maxGap, gap)
            minGap = min(minGap, gap)
        }
        guard input.isReadyForMoreMediaData else { return }
        if adaptor.append(pixels, withPresentationTime: pts) {
            last = pts
            frames += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
    }
}

@MainActor
func run() async {
    let o = Options.parse()
    guard CGPreflightScreenCaptureAccess() else {
        fail("screen recording is not allowed for this process (System Settings > Privacy & Security > Screen & System Audio Recording). Nothing was recorded.", code: 3)
    }

    // Find the window (the app may still be building it).
    var window: SCWindow?
    var displays: [SCDisplay] = []
    var allWindows: [SCWindow] = []
    let deadline = Date().addingTimeInterval(o.waitWindow)
    repeat {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            displays = content.displays
            allWindows = content.windows
            window = content.windows
                .filter { $0.owningApplication?.processID == o.pid && $0.windowLayer == 0 && $0.frame.width > 200 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        } catch {
            fail("ScreenCaptureKit refused: \(error.localizedDescription). Nothing was recorded.", code: 3)
        }
        if window == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
    } while window == nil && Date() < deadline
    guard let window else { fail("no window for pid \(o.pid)") }

    let config = SCStreamConfiguration()
    let filter: SCContentFilter
    let scale: CGFloat
    let width: Int
    let height: Int
    if o.mode == "window" {
        filter = SCContentFilter(desktopIndependentWindow: window)
        scale = CGFloat(filter.pointPixelScale)
        width = Int((filter.contentRect.width * scale).rounded())
        height = Int((filter.contentRect.height * scale).rounded())
    } else {
        // Only this window is composited, so windows above it do not show; cropped to its frame.
        guard let display = displays.first(where: { $0.frame.intersects(window.frame) }) ?? displays.first else {
            fail("no display")
        }
        switch o.mode {
        case "app":
            guard let owner = window.owningApplication else { fail("window has no owning application") }
            filter = SCContentFilter(display: display, including: [owner], exceptingWindows: [])
        case "exclude":
            filter = SCContentFilter(display: display, excludingWindows: allWindows.filter { $0.windowID != window.windowID })
        default:
            filter = SCContentFilter(display: display, including: [window])
        }
        scale = CGFloat(filter.pointPixelScale)
        let f = window.frame
        config.sourceRect = CGRect(x: f.minX - display.frame.minX, y: f.minY - display.frame.minY,
                                   width: f.width, height: f.height)
        width = Int((f.width * scale).rounded())
        height = Int((f.height * scale).rounded())
        config.backgroundColor = .clear
    }
    config.width = width
    config.height = height
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
    config.showsCursor = false
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.queueDepth = 8
    config.capturesAudio = false
    config.ignoreShadowsSingleWindow = true
    config.scalesToFit = false
    config.colorSpaceName = CGColorSpace.sRGB

    let recorder: Recorder
    do {
        recorder = try Recorder(url: URL(fileURLWithPath: o.out), width: width, height: height, fps: o.fps, codec: o.codec)
    } catch {
        fail("writer: \(error.localizedDescription)")
    }
    let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
    do {
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
    } catch {
        fail("ScreenCaptureKit refused to start: \(error.localizedDescription). Nothing was recorded.", code: 3)
    }
    let started = Date()
    FileHandle.standardError.write("winrec: recording window \(window.windowID) \(width)x\(height) for \(o.seconds) s\n".data(using: .utf8)!)

    // Wait for the first frame, then exactly N seconds of timeline after it.
    while recorder.queue.sync(execute: { recorder.first == nil }) && Date().timeIntervalSince(started) < 5 {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    try? await Task.sleep(nanoseconds: UInt64(o.seconds * 1_000_000_000))
    try? await stream.stopCapture()

    let (first, frames, maxGap, minGap, error) = recorder.queue.sync { () -> (CMTime?, Int, Double, Double, Error?) in
        recorder.stopped = true
        return (recorder.first, recorder.frames, recorder.maxGap, recorder.minGap, recorder.streamError)
    }
    if let error { fail("capture failed: \(error.localizedDescription)") }
    guard let first else { fail("no frame arrived (is the window on screen and not minimised?)") }
    recorder.input.markAsFinished()
    recorder.writer.endSession(atSourceTime: first + CMTime(seconds: o.seconds, preferredTimescale: 600))
    await recorder.writer.finishWriting()
    if recorder.writer.status != .completed {
        fail("writing failed: \(recorder.writer.error?.localizedDescription ?? "unknown")")
    }
    let summary: [String: Any] = [
        "out": o.out, "window": Int(window.windowID), "width": width, "height": height,
        "seconds": o.seconds, "frames": frames,
        "meanFps": Double(frames) / o.seconds,
        "peakFps": minGap.isFinite && minGap > 0 ? (1 / minGap).rounded() : 0,
        "maxGapSeconds": maxGap,
    ]
    let json = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
    print(String(data: json, encoding: .utf8)!)
    exit(0)
}

// ScreenCaptureKit needs a window-server connection; a plain command-line tool has none until
// AppKit is initialised. Accessory policy: no Dock icon, never activated.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
app.run()

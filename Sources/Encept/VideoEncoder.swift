// VideoEncoder.swift
// Hardware H.264 encoding using VideoToolbox

import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreImage

public enum VideoEncoderError: Error {
    case sessionCreationFailed(OSStatus)
    case encodingFailed(OSStatus)
    case invalidPixelBuffer
    case noOutputData
    case timeout
    case imageConversionFailed
}

public struct EncoderConfig: Sendable {
    public var width: Int32
    public var height: Int32
    public var bitrate: Int32
    public var profile: CFString
    public var iFrameOnly: Bool
    public var quality: Float

    public init(width: Int32 = 0, height: Int32 = 0, bitrate: Int32 = 1_000_000,
                profile: CFString = kVTProfileLevel_H264_Main_AutoLevel,
                iFrameOnly: Bool = true, quality: Float = 0.5) {
        self.width = width; self.height = height; self.bitrate = bitrate
        self.profile = profile; self.iFrameOnly = iFrameOnly; self.quality = quality
    }

    public static var `default`: EncoderConfig { EncoderConfig() }
    public static var highQuality: EncoderConfig {
        EncoderConfig(bitrate: 5_000_000, profile: kVTProfileLevel_H264_High_AutoLevel, quality: 0.8)
    }
    public static var fast: EncoderConfig {
        EncoderConfig(bitrate: 500_000, profile: kVTProfileLevel_H264_Baseline_AutoLevel, quality: 0.3)
    }
}

public struct EncodedFrame: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let pts: CMTime
    public let isKeyframe: Bool
}

public final class VideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let config: EncoderConfig
    private var outputData: Data?
    private var outputError: Error?
    private let outputQueue = DispatchQueue(label: "com.encept.encoder")
    private let semaphore = DispatchSemaphore(value: 0)
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0

    public init(config: EncoderConfig = .default) { self.config = config }
    deinit { destroySession() }

    public func encode(image: CGImage) throws -> EncodedFrame {
        let pixelBuffer = try createPixelBuffer(from: image)
        return try encode(pixelBuffer: pixelBuffer)
    }

    public func encode(pixelBuffer: CVPixelBuffer) throws -> EncodedFrame {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || width != currentWidth || height != currentHeight {
            try createSession(width: width, height: height)
        }
        guard let session = session else { throw VideoEncoderError.sessionCreationFailed(-1) }
        outputData = nil; outputError = nil

        var frameProperties: [CFString: Any] = [:]
        if config.iFrameOnly { frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }

        let pts = CMTime(value: 0, timescale: 30)
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 30),
            frameProperties: frameProperties as CFDictionary, sourceFrameRefcon: nil, infoFlagsOut: &flags)
        guard status == noErr else { throw VideoEncoderError.encodingFailed(status) }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let waitResult = semaphore.wait(timeout: .now() + .seconds(5))
        if waitResult == .timedOut { throw VideoEncoderError.timeout }
        if let error = outputError { throw error }
        guard let data = outputData else { throw VideoEncoderError.noOutputData }

        return EncodedFrame(data: data, width: Int(width), height: Int(height), pts: pts, isKeyframe: config.iFrameOnly)
    }

    private func createSession(width: Int32, height: Int32) throws {
        destroySession()
        let actualWidth = config.width > 0 ? config.width : width
        let actualHeight = config.height > 0 ? config.height : height

        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: actualWidth, kCVPixelBufferHeightKey: actualHeight
        ]

        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: actualWidth, height: actualHeight, codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: videoEncoderCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &sessionOut)

        guard status == noErr, let session = sessionOut else { throw VideoEncoderError.sessionCreationFailed(status) }
        self.session = session; currentWidth = actualWidth; currentHeight = actualHeight
        try configureSession(session)
    }

    private func configureSession(_ session: VTCompressionSession) throws {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: config.profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: config.bitrate))
        if config.iFrameOnly {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 1))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 0.0))
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: config.quality))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CAVLC)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func destroySession() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    private func createPixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width, height = image.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw VideoEncoderError.invalidPixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw VideoEncoderError.imageConversionFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    fileprivate func handleEncodedData(_ sampleBuffer: CMSampleBuffer) {
        outputQueue.sync {
            do { self.outputData = try extractAnnexBData(from: sampleBuffer) }
            catch { self.outputError = error }
            semaphore.signal()
        }
    }

    fileprivate func handleEncodingError(_ status: OSStatus) {
        outputQueue.sync { self.outputError = VideoEncoderError.encodingFailed(status); semaphore.signal() }
    }

    private func extractAnnexBData(from sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw VideoEncoderError.noOutputData }
        var lengthAtOffset = 0, totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let pointer = dataPointer else { throw VideoEncoderError.noOutputData }

        var output = Data()
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsSize = 0, spsPointer: UnsafePointer<UInt8>?
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let sps = spsPointer {
                output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                output.append(UnsafeBufferPointer(start: sps, count: spsSize))
            }
            var ppsSize = 0, ppsPointer: UnsafePointer<UInt8>?
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let pps = ppsPointer {
                output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                output.append(UnsafeBufferPointer(start: pps, count: ppsSize))
            }
        }

        var offset = 0
        while offset < totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            output.append(UnsafeBufferPointer(start: UnsafeRawPointer(pointer.advanced(by: offset)).assumingMemoryBound(to: UInt8.self), count: Int(nalLength)))
            offset += Int(nalLength)
        }
        return output
    }
}

private func videoEncoderCallback(outputCallbackRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    if status != noErr { encoder.handleEncodingError(status); return }
    guard let buffer = sampleBuffer else { encoder.handleEncodingError(-1); return }
    encoder.handleEncodedData(buffer)
}

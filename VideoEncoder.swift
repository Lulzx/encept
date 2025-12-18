// VideoEncoder.swift
// Hardware H.264 encoding using VideoToolbox

import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreImage

/// Errors that can occur during video encoding
public enum VideoEncoderError: Error {
    case sessionCreationFailed(OSStatus)
    case encodingFailed(OSStatus)
    case invalidPixelBuffer
    case noOutputData
    case timeout
    case imageConversionFailed
}

/// Configuration for the hardware encoder
public struct EncoderConfig {
    /// Target width (0 = use source dimensions)
    public var width: Int32
    
    /// Target height (0 = use source dimensions)
    public var height: Int32
    
    /// Bitrate (affects QP selection)
    public var bitrate: Int32
    
    /// Profile (baseline, main, high)
    public var profile: CFString
    
    /// Force I-frame only encoding (best for hashing)
    public var iFrameOnly: Bool
    
    /// Quality level (0.0 to 1.0)
    public var quality: Float
    
    public init(
        width: Int32 = 0,
        height: Int32 = 0,
        bitrate: Int32 = 1_000_000,
        profile: CFString = kVTProfileLevel_H264_Main_AutoLevel,
        iFrameOnly: Bool = true,
        quality: Float = 0.5
    ) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.profile = profile
        self.iFrameOnly = iFrameOnly
        self.quality = quality
    }
    
    public static var `default`: EncoderConfig { EncoderConfig() }
    
    public static var highQuality: EncoderConfig {
        EncoderConfig(
            bitrate: 5_000_000,
            profile: kVTProfileLevel_H264_High_AutoLevel,
            quality: 0.8
        )
    }
    
    public static var fast: EncoderConfig {
        EncoderConfig(
            bitrate: 500_000,
            profile: kVTProfileLevel_H264_Baseline_AutoLevel,
            quality: 0.3
        )
    }
}

/// Result of encoding a single frame
public struct EncodedFrame {
    /// Raw H.264 NAL units (Annex B format)
    public let data: Data
    
    /// Frame dimensions
    public let width: Int
    public let height: Int
    
    /// Presentation timestamp
    public let pts: CMTime
    
    /// Whether this is a keyframe
    public let isKeyframe: Bool
}

/// Hardware H.264 encoder using VideoToolbox
public final class VideoEncoder {
    private var session: VTCompressionSession?
    private let config: EncoderConfig
    private var outputData: Data?
    private var outputError: Error?
    private let outputQueue = DispatchQueue(label: "com.encept.encoder")
    private let semaphore = DispatchSemaphore(value: 0)
    
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    
    public init(config: EncoderConfig = .default) {
        self.config = config
    }
    
    deinit {
        destroySession()
    }
    
    // MARK: - Public API
    
    /// Encode a CGImage to H.264
    public func encode(image: CGImage) throws -> EncodedFrame {
        let pixelBuffer = try createPixelBuffer(from: image)
        return try encode(pixelBuffer: pixelBuffer)
    }
    
    /// Encode a CVPixelBuffer to H.264
    public func encode(pixelBuffer: CVPixelBuffer) throws -> EncodedFrame {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        
        // Create or recreate session if dimensions changed
        if session == nil || width != currentWidth || height != currentHeight {
            try createSession(width: width, height: height)
        }
        
        guard let session = session else {
            throw VideoEncoderError.sessionCreationFailed(-1)
        }
        
        // Reset output
        outputData = nil
        outputError = nil
        
        // Create frame properties
        var frameProperties: [CFString: Any] = [:]
        
        if config.iFrameOnly {
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
        }
        
        let framePropertiesRef = frameProperties as CFDictionary
        
        // Encode
        let pts = CMTime(value: 0, timescale: 30)
        let duration = CMTime(value: 1, timescale: 30)
        
        var flags = VTEncodeInfoFlags()
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: framePropertiesRef,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        
        guard status == noErr else {
            throw VideoEncoderError.encodingFailed(status)
        }
        
        // Force completion
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        
        // Wait for output
        let waitResult = semaphore.wait(timeout: .now() + .seconds(5))
        
        if waitResult == .timedOut {
            throw VideoEncoderError.timeout
        }
        
        if let error = outputError {
            throw error
        }
        
        guard let data = outputData else {
            throw VideoEncoderError.noOutputData
        }
        
        return EncodedFrame(
            data: data,
            width: Int(width),
            height: Int(height),
            pts: pts,
            isKeyframe: config.iFrameOnly
        )
    }
    
    /// Encode multiple images in batch
    public func encodeBatch(images: [CGImage]) throws -> [EncodedFrame] {
        return try images.map { try encode(image: $0) }
    }
    
    // MARK: - Session Management
    
    private func createSession(width: Int32, height: Int32) throws {
        destroySession()
        
        let actualWidth = config.width > 0 ? config.width : width
        let actualHeight = config.height > 0 ? config.height : height
        
        // Encoder specification - prefer hardware
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        
        // Source image buffer attributes
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: actualWidth,
            kCVPixelBufferHeightKey: actualHeight
        ]
        
        var sessionOut: VTCompressionSession?
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: actualWidth,
            height: actualHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            sourceImageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: videoEncoderCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionOut
        )
        
        guard status == noErr, let session = sessionOut else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }
        
        self.session = session
        self.currentWidth = actualWidth
        self.currentHeight = actualHeight
        
        // Configure session
        try configureSession(session)
    }
    
    private func configureSession(_ session: VTCompressionSession) throws {
        // Real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        // Profile level
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: config.profile)
        
        // Bitrate
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: config.bitrate)
        )
        
        // I-frame interval (1 = every frame is I-frame)
        if config.iFrameOnly {
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: 1)
            )
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                value: NSNumber(value: 0.0)
            )
        }
        
        // Quality
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: NSNumber(value: config.quality)
        )
        
        // Allow frame reordering (false for lower latency)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        
        // Entropy mode (CAVLC for faster parsing)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_H264EntropyMode,
            value: kVTH264EntropyMode_CAVLC
        )
        
        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    
    private func destroySession() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
    
    // MARK: - Pixel Buffer Creation
    
    private func createPixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width
        let height = image.height
        
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw VideoEncoderError.invalidPixelBuffer
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw VideoEncoderError.imageConversionFailed
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
    }
    
    // MARK: - Output Handling
    
    fileprivate func handleEncodedData(_ sampleBuffer: CMSampleBuffer) {
        outputQueue.sync {
            do {
                let data = try extractAnnexBData(from: sampleBuffer)
                self.outputData = data
            } catch {
                self.outputError = error
            }
            semaphore.signal()
        }
    }
    
    fileprivate func handleEncodingError(_ status: OSStatus) {
        outputQueue.sync {
            self.outputError = VideoEncoderError.encodingFailed(status)
            semaphore.signal()
        }
    }
    
    /// Extract H.264 data in Annex B format (with start codes)
    private func extractAnnexBData(from sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw VideoEncoderError.noOutputData
        }
        
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let pointer = dataPointer else {
            throw VideoEncoderError.noOutputData
        }
        
        var output = Data()
        
        // Get format description for parameter sets
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Extract SPS
            var spsSize: Int = 0
            var spsCount: Int = 0
            var spsPointer: UnsafePointer<UInt8>?
            
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &spsCount,
                nalUnitHeaderLengthOut: nil
            )
            
            if let sps = spsPointer {
                output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                output.append(UnsafeBufferPointer(start: sps, count: spsSize))
            }
            
            // Extract PPS
            var ppsSize: Int = 0
            var ppsPointer: UnsafePointer<UInt8>?
            
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            
            if let pps = ppsPointer {
                output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                output.append(UnsafeBufferPointer(start: pps, count: ppsSize))
            }
        }
        
        // Convert AVCC to Annex B (replace length prefix with start code)
        var offset = 0
        let nalLengthSize = 4
        
        while offset < totalLength {
            // Read NAL length (big-endian)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), nalLengthSize)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += nalLengthSize
            
            // Write start code
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            
            // Write NAL data
            output.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(pointer.advanced(by: offset)).assumingMemoryBound(to: UInt8.self),
                count: Int(nalLength)
            ))
            
            offset += Int(nalLength)
        }
        
        return output
    }
}

// MARK: - Callback

private func videoEncoderCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    
    if status != noErr {
        encoder.handleEncodingError(status)
        return
    }
    
    guard let buffer = sampleBuffer else {
        encoder.handleEncodingError(-1)
        return
    }
    
    encoder.handleEncodedData(buffer)
}

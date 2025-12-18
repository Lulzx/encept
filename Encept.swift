// Encept.swift
// Main API for the Encept library

import SwiftUI
import CoreGraphics
import CoreImage

/// Main entry point for perceptual hashing
@MainActor
public final class Encept: ObservableObject {

    /// Shared instance with default configuration
    public static let shared = Encept()

    private let encoder: VideoEncoder
    private let extractor: HashExtractor

    /// Configuration for the hasher
    public struct Config: Sendable {
        /// Encoder quality (affects hash stability)
        public var encoderConfig: EncoderConfig

        /// Whether to cache encoder sessions
        public var cacheSession: Bool

        public static var `default`: Config {
            Config(encoderConfig: .default, cacheSession: true)
        }

        public static var highQuality: Config {
            Config(encoderConfig: .highQuality, cacheSession: true)
        }

        public static var fast: Config {
            Config(encoderConfig: .fast, cacheSession: true)
        }
    }

    private let config: Config

    /// Initialize with configuration
    public init(config: Config = .default) {
        self.config = config
        self.encoder = VideoEncoder(config: config.encoderConfig)
        self.extractor = try! HashExtractor()
    }

    // MARK: - Public API

    /// Hash a CGImage
    public func hash(image: CGImage) throws -> EnceptHash {
        let encoded = try encoder.encode(image: image)
        return try extractor.extract(from: encoded.data)
    }

    /// Hash a SwiftUI Image (requires ImageRenderer on macOS 13+/iOS 16+)
    @available(macOS 13.0, iOS 16.0, *)
    public func hash<V: View>(view: V, size: CGSize = CGSize(width: 1920, height: 1080)) async throws -> EnceptHash {
        let renderer = await ImageRenderer(content: view.frame(width: size.width, height: size.height))
        guard let cgImage = await renderer.cgImage else {
            throw EnceptError.imageConversionFailed
        }
        return try hash(image: cgImage)
    }

    /// Hash image data (JPEG, PNG, etc.)
    public func hash(imageData: Data) throws -> EnceptHash {
        guard let provider = CGDataProvider(data: imageData as CFData),
              let cgImage = CGImage(
                jpegDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) ?? CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            // Try using CIImage as fallback
            guard let ciImage = CIImage(data: imageData),
                  let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
                throw EnceptError.imageConversionFailed
            }
            return try hash(image: cgImage)
        }
        return try hash(image: cgImage)
    }

    /// Hash an image file
    public func hash(fileURL: URL) throws -> EnceptHash {
        let data = try Data(contentsOf: fileURL)
        return try hash(imageData: data)
    }

    /// Hash an image resource
    @available(macOS 14.0, iOS 17.0, *)
    public func hash(resource: ImageResource) throws -> EnceptHash {
        #if os(macOS)
        let nsImage = NSImage(resource: resource)
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw EnceptError.imageConversionFailed
        }
        return try hash(image: cgImage)
        #else
        let uiImage = UIImage(resource: resource)
        guard let cgImage = uiImage.cgImage else {
            throw EnceptError.imageConversionFailed
        }
        return try hash(image: cgImage)
        #endif
    }

    /// Hash multiple images in parallel
    public func hashBatch(images: [CGImage]) async throws -> [EnceptHash] {
        try await withThrowingTaskGroup(of: (Int, EnceptHash).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask {
                    let encoder = VideoEncoder(config: self.config.encoderConfig)
                    let extractor = try HashExtractor()
                    let encoded = try encoder.encode(image: image)
                    let hash = try extractor.extract(from: encoded.data)
                    return (index, hash)
                }
            }

            var results = [EnceptHash?](repeating: nil, count: images.count)
            for try await (index, hash) in group {
                results[index] = hash
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: - Comparison Utilities

    /// Compare two images directly
    public func compare(_ image1: CGImage, to image2: CGImage) throws -> Float {
        let hash1 = try hash(image: image1)
        let hash2 = try hash(image: image2)
        return hash1.distanceFull(to: hash2)
    }

    /// Check if two images are similar
    public func areSimilar(_ image1: CGImage, _ image2: CGImage, threshold: Float = 50.0) throws -> Bool {
        let distance = try compare(image1, to: image2)
        return distance < threshold
    }

    /// Find matches in a collection
    public func findMatches(
        query: CGImage,
        in images: [CGImage],
        threshold: Float = 50.0
    ) async throws -> [(index: Int, distance: Float)] {
        let queryHash = try hash(image: query)
        let hashes = try await hashBatch(images: images)

        var matches: [(Int, Float)] = []

        for (i, hash) in hashes.enumerated() {
            let distance = queryHash.distanceFull(to: hash)
            if distance < threshold {
                matches.append((i, distance))
            }
        }

        return matches.sorted { $0.1 < $1.1 }
    }
}

// MARK: - Errors

public enum EnceptError: Error, LocalizedError {
    case imageConversionFailed
    case encodingFailed
    case extractionFailed
    case fileNotFound

    public var errorDescription: String? {
        switch self {
        case .imageConversionFailed: return "Failed to convert image to processable format"
        case .encodingFailed: return "H.264 encoding failed"
        case .extractionFailed: return "Hash extraction from bitstream failed"
        case .fileNotFound: return "Image file not found"
        }
    }
}

// MARK: - CGImage Extensions

extension CGImage {
    /// Compute perceptual hash using Encept
    @MainActor
    public func enceptHash() throws -> EnceptHash {
        return try Encept.shared.hash(image: self)
    }

    /// Check similarity to another image
    @MainActor
    public func isSimilar(to other: CGImage, threshold: Float = 50.0) throws -> Bool {
        return try Encept.shared.areSimilar(self, other, threshold: threshold)
    }
}

// MARK: - SwiftUI Image Extensions

extension Image {
    /// Create an Image from an EnceptHash visualization (debug only)
    #if DEBUG
    public init?(hashVisualization hash: EnceptHash) {
        guard let cgImage = hash.visualize() else { return nil }
        #if os(macOS)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        self.init(nsImage: nsImage)
        #else
        self.init(uiImage: UIImage(cgImage: cgImage))
        #endif
    }
    #endif
}

// MARK: - EnceptHash Extensions

extension EnceptHash {
    /// Similarity score (0-1, higher = more similar)
    public func similarity(to other: EnceptHash) -> Float {
        let cosine = cosineSimilarity(to: other)
        return max(0, min(1, (cosine + 1) / 2))
    }

    /// Check if similar to another hash
    public func isSimilar(to other: EnceptHash, threshold: Float = 0.8) -> Bool {
        return similarity(to: other) >= threshold
    }
}

// MARK: - SwiftUI View Modifier

/// A view modifier that computes perceptual hash on appear
public struct EnceptHashModifier: ViewModifier {
    let onHash: (EnceptHash) -> Void
    let size: CGSize

    @State private var hasComputed = false

    public func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { _ in
                    Color.clear
                        .task {
                            guard !hasComputed else { return }
                            hasComputed = true
                            if #available(macOS 13.0, iOS 16.0, *) {
                                do {
                                    let hash = try await Encept.shared.hash(view: content, size: size)
                                    onHash(hash)
                                } catch {
                                    print("Encept hash failed: \(error)")
                                }
                            }
                        }
                }
            )
    }
}

extension View {
    /// Compute perceptual hash of this view
    public func onEnceptHash(size: CGSize = CGSize(width: 1920, height: 1080), perform: @escaping (EnceptHash) -> Void) -> some View {
        modifier(EnceptHashModifier(onHash: perform, size: size))
    }
}

// MARK: - Debug Utilities

#if DEBUG
extension EnceptHash {
    /// Visualize the DC coefficients as a thumbnail
    public func visualize() -> CGImage? {
        let dims = dimensions
        let width = dims.widthMbs
        let height = dims.heightMbs

        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let dcLuma = self.dcLuma

        // Normalize DC values to 0-255
        let minDC = dcLuma.min() ?? 0
        let maxDC = dcLuma.max() ?? 255
        let range = max(Float(maxDC - minDC), 1)

        for i in 0..<min(dcLuma.count, width * height) {
            let normalized = (Float(dcLuma[i] - minDC) / range) * 255
            let byte = UInt8(max(0, min(255, normalized)))

            let pixelIndex = i * 4
            pixels[pixelIndex] = byte     // R
            pixels[pixelIndex + 1] = byte // G
            pixels[pixelIndex + 2] = byte // B
            pixels[pixelIndex + 3] = 255  // A
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }
}
#endif

// MARK: - Platform Imports

#if os(macOS)
import AppKit
#else
import UIKit
#endif

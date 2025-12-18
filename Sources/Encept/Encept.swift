// Encept.swift
// Main API for the Encept library

import SwiftUI
import CoreGraphics
import CoreImage

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum EnceptError: Error, LocalizedError {
    case imageConversionFailed, encodingFailed, extractionFailed, fileNotFound
    public var errorDescription: String? {
        switch self {
        case .imageConversionFailed: return "Failed to convert image"
        case .encodingFailed: return "H.264 encoding failed"
        case .extractionFailed: return "Hash extraction failed"
        case .fileNotFound: return "Image file not found"
        }
    }
}

@MainActor
public final class Encept: ObservableObject {
    public static let shared = Encept()

    private let encoder: VideoEncoder
    private let extractor: HashExtractor

    public struct Config: Sendable {
        public var encoderConfig: EncoderConfig
        public var cacheSession: Bool
        public static var `default`: Config { Config(encoderConfig: .default, cacheSession: true) }
        public static var highQuality: Config { Config(encoderConfig: .highQuality, cacheSession: true) }
        public static var fast: Config { Config(encoderConfig: .fast, cacheSession: true) }
    }

    private let config: Config

    public init(config: Config = .default) {
        self.config = config
        self.encoder = VideoEncoder(config: config.encoderConfig)
        self.extractor = HashExtractor()
    }

    public func hash(image: CGImage) throws -> EnceptHash {
        let encoded = try encoder.encode(image: image)
        return try extractor.extract(from: encoded.data)
    }

    @available(macOS 13.0, iOS 16.0, *)
    public func hash<V: View>(view: V, size: CGSize = CGSize(width: 1920, height: 1080)) async throws -> EnceptHash {
        let renderer = await ImageRenderer(content: view.frame(width: size.width, height: size.height))
        guard let cgImage = await renderer.cgImage else { throw EnceptError.imageConversionFailed }
        return try hash(image: cgImage)
    }

    public func hash(imageData: Data) throws -> EnceptHash {
        guard let provider = CGDataProvider(data: imageData as CFData),
              let cgImage = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                ?? CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            guard let ciImage = CIImage(data: imageData),
                  let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent)
            else { throw EnceptError.imageConversionFailed }
            return try hash(image: cgImage)
        }
        return try hash(image: cgImage)
    }

    public func hash(fileURL: URL) throws -> EnceptHash {
        let data = try Data(contentsOf: fileURL)
        return try hash(imageData: data)
    }

    @available(macOS 14.0, iOS 17.0, *)
    public func hash(resource: ImageResource) throws -> EnceptHash {
        #if os(macOS)
        let nsImage = NSImage(resource: resource)
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw EnceptError.imageConversionFailed }
        #else
        let uiImage = UIImage(resource: resource)
        guard let cgImage = uiImage.cgImage else { throw EnceptError.imageConversionFailed }
        #endif
        return try hash(image: cgImage)
    }

    public func hashBatch(images: [CGImage]) async throws -> [EnceptHash] {
        try await withThrowingTaskGroup(of: (Int, EnceptHash).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask {
                    let encoder = VideoEncoder(config: self.config.encoderConfig)
                    let extractor = HashExtractor()
                    let encoded = try encoder.encode(image: image)
                    return (index, try extractor.extract(from: encoded.data))
                }
            }
            var results = [EnceptHash?](repeating: nil, count: images.count)
            for try await (index, hash) in group { results[index] = hash }
            return results.compactMap { $0 }
        }
    }

    public func compare(_ image1: CGImage, to image2: CGImage) throws -> Float {
        let hash1 = try hash(image: image1), hash2 = try hash(image: image2)
        return hash1.distanceFull(to: hash2)
    }

    public func areSimilar(_ image1: CGImage, _ image2: CGImage, threshold: Float = 50.0) throws -> Bool {
        try compare(image1, to: image2) < threshold
    }

    public func findMatches(query: CGImage, in images: [CGImage], threshold: Float = 50.0) async throws -> [(index: Int, distance: Float)] {
        let queryHash = try hash(image: query)
        let hashes = try await hashBatch(images: images)
        return hashes.enumerated().compactMap { i, h in
            let d = queryHash.distanceFull(to: h); return d < threshold ? (i, d) : nil
        }.sorted { $0.1 < $1.1 }
    }
}

// MARK: - CGImage Extension
extension CGImage {
    @MainActor public func enceptHash() throws -> EnceptHash { try Encept.shared.hash(image: self) }
    @MainActor public func isSimilar(to other: CGImage, threshold: Float = 50.0) throws -> Bool {
        try Encept.shared.areSimilar(self, other, threshold: threshold)
    }
}

// MARK: - SwiftUI View Modifier
public struct EnceptHashModifier: ViewModifier {
    let onHash: (EnceptHash) -> Void
    let size: CGSize
    @State private var hasComputed = false

    public func body(content: Content) -> some View {
        content.background(GeometryReader { _ in
            Color.clear.task {
                guard !hasComputed else { return }
                hasComputed = true
                if #available(macOS 13.0, iOS 16.0, *) {
                    do { onHash(try await Encept.shared.hash(view: content, size: size)) }
                    catch { print("Encept error: \(error)") }
                }
            }
        })
    }
}

extension View {
    public func onEnceptHash(size: CGSize = CGSize(width: 1920, height: 1080), perform: @escaping (EnceptHash) -> Void) -> some View {
        modifier(EnceptHashModifier(onHash: perform, size: size))
    }
}

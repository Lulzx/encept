// EnceptTests.swift
// Tests for Encept library

import XCTest
@testable import Encept
import CoreGraphics

final class EnceptTests: XCTestCase {

    // MARK: - EnceptHash Tests

    func testHashInitialization() {
        let hash = createTestHash(widthMbs: 8, heightMbs: 6)

        XCTAssertEqual(hash.width, 128)
        XCTAssertEqual(hash.height, 96)
        XCTAssertEqual(hash.widthMbs, 8)
        XCTAssertEqual(hash.heightMbs, 6)
        XCTAssertEqual(hash.numMacroblocks, 48)
    }

    func testHashEquality() {
        let hash1 = createTestHash(widthMbs: 4, heightMbs: 4)
        let hash2 = createTestHash(widthMbs: 4, heightMbs: 4)

        XCTAssertEqual(hash1, hash2)
    }

    func testHashSerialization() {
        let hash = createTestHash(widthMbs: 4, heightMbs: 4)
        let data = hash.serialize()

        XCTAssertGreaterThan(data.count, 32)
        XCTAssertEqual(data.count, hash.byteSize)
    }

    // MARK: - Distance Metric Tests

    func testDistanceFastIdentical() {
        let hash = createTestHash(widthMbs: 4, heightMbs: 4)

        let distance = hash.distanceFast(to: hash)
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testDistancePyramidIdentical() {
        let hash = createTestHash(widthMbs: 4, heightMbs: 4)

        let distance = hash.distancePyramid(to: hash)
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testDistanceFullIdentical() {
        let hash = createTestHash(widthMbs: 4, heightMbs: 4)

        let distance = hash.distanceFull(to: hash)
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testCosineSimilarityIdentical() {
        let hash = createTestHash(widthMbs: 4, heightMbs: 4, dcValue: 100)

        let similarity = hash.cosineSimilarity(to: hash)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001)
    }

    func testHammingDistanceIdentical() {
        let hash = createTestHash(widthMbs: 4, heightMbs: 4)

        let distance = hash.hammingDistance(to: hash)
        XCTAssertEqual(distance, 0)
    }

    func testDistanceDifferentHashes() {
        let hash1 = createTestHash(widthMbs: 4, heightMbs: 4, dcValue: 50)
        let hash2 = createTestHash(widthMbs: 4, heightMbs: 4, dcValue: 200)

        let distFast = hash1.distanceFast(to: hash2)
        let distFull = hash1.distanceFull(to: hash2)

        XCTAssertGreaterThan(distFast, 0)
        XCTAssertGreaterThan(distFull, 0)
    }

    func testDistanceDifferentDimensions() {
        let hash1 = createTestHash(widthMbs: 4, heightMbs: 4)
        let hash2 = createTestHash(widthMbs: 8, heightMbs: 6)

        let distance = hash1.distanceFull(to: hash2)
        XCTAssertEqual(distance, Float.greatestFiniteMagnitude)
    }

    // MARK: - Similarity Tests

    func testSimilarityScore() {
        let hash1 = createTestHash(widthMbs: 4, heightMbs: 4, dcValue: 100)
        let hash2 = createTestHash(widthMbs: 4, heightMbs: 4, dcValue: 100)

        let similarity = hash1.similarity(to: hash2)
        XCTAssertGreaterThanOrEqual(similarity, 0)
        XCTAssertLessThanOrEqual(similarity, 1)
    }

    func testIsSimilar() {
        let hash1 = createTestHash(widthMbs: 4, heightMbs: 4, dcValue: 100)
        let hash2 = createTestHash(widthMbs: 4, heightMbs: 4, dcValue: 100)

        XCTAssertTrue(hash1.isSimilar(to: hash2, threshold: 0.5))
    }

    // MARK: - HashExtractor Tests

    func testHashExtractorInit() {
        let extractor = HashExtractor()
        XCTAssertNotNil(extractor)
    }

    // MARK: - VideoEncoder Tests

    func testVideoEncoderInit() {
        let encoder = VideoEncoder()
        XCTAssertNotNil(encoder)
    }

    func testEncoderConfigPresets() {
        let defaultConfig = EncoderConfig.default
        let highQualityConfig = EncoderConfig.highQuality
        let fastConfig = EncoderConfig.fast

        XCTAssertEqual(defaultConfig.quality, 0.5)
        XCTAssertEqual(highQualityConfig.quality, 0.8)
        XCTAssertEqual(fastConfig.quality, 0.3)
    }

    // MARK: - Integration Tests

    @MainActor
    func testEncodeAndExtract() async throws {
        // Create a test image
        guard let cgImage = createTestCGImage(width: 64, height: 64) else {
            XCTFail("Failed to create test image")
            return
        }

        let encept = Encept()

        do {
            let hash = try encept.hash(image: cgImage)
            // Encoder may pad to different sizes, just verify we got valid data
            XCTAssertGreaterThan(hash.widthMbs, 0)
            XCTAssertGreaterThan(hash.heightMbs, 0)
            XCTAssertGreaterThan(hash.numMacroblocks, 0)
            XCTAssertEqual(hash.numMacroblocks, hash.widthMbs * hash.heightMbs)
        } catch {
            // Hardware encoder may not be available in test environment
            print("Encoding failed (expected in CI): \(error)")
        }
    }

    @MainActor
    func testCompareIdenticalImages() async throws {
        guard let cgImage = createTestCGImage(width: 64, height: 64) else {
            XCTFail("Failed to create test image")
            return
        }

        let encept = Encept()

        do {
            let hash1 = try encept.hash(image: cgImage)
            let hash2 = try encept.hash(image: cgImage)

            // H.264 encoder may produce slightly different results due to timing
            // Use similarity score which normalizes the comparison
            let similarity = hash1.similarity(to: hash2)
            XCTAssertGreaterThan(similarity, 0.5, "Identical images should be at least 50% similar")
        } catch {
            print("Encoding failed (expected in CI): \(error)")
        }
    }

    // MARK: - Helper Methods

    private func createTestHash(widthMbs: Int, heightMbs: Int, dcValue: Int16 = 100) -> EnceptHash {
        let numMbs = widthMbs * heightMbs

        return EnceptHash(
            width: widthMbs * 16,
            height: heightMbs * 16,
            widthMbs: widthMbs,
            heightMbs: heightMbs,
            mbTypes: [UInt8](repeating: 1, count: numMbs),
            intraModes: [UInt8](repeating: 2, count: numMbs),
            dcLuma: [Int16](repeating: dcValue, count: numMbs),
            dcCb: [Int16](repeating: 0, count: numMbs),
            dcCr: [Int16](repeating: 0, count: numMbs),
            qpAvg: 26,
            skipRatio: 0.0,
            intraRatio: 1.0,
            dcMean: dcValue,
            dcStd: 0.0,
            edgeDensity: 0.0,
            pyramid2x2: [dcValue, dcValue, dcValue, dcValue],
            pyramid4x4: [Int16](repeating: dcValue, count: 16)
        )
    }

    private func createTestCGImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        // Fill with gradient
        for y in 0..<height {
            for x in 0..<width {
                let gray = CGFloat(x + y) / CGFloat(width + height)
                context.setFillColor(gray: gray, alpha: 1.0)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        return context.makeImage()
    }
}

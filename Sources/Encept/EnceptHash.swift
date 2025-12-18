// EnceptHash.swift
// Perceptual hash structure extracted from H.264 encoding decisions

import Foundation
import CoreGraphics

/// Perceptual hash extracted from H.264 encoder decisions
public struct EnceptHash: Sendable, Codable, Equatable {
    // MARK: - Dimensions

    public let width: Int
    public let height: Int
    public let widthMbs: Int
    public let heightMbs: Int

    // MARK: - Per-Macroblock Data

    public let mbTypes: [UInt8]
    public let intraModes: [UInt8]
    public let dcLuma: [Int16]
    public let dcCb: [Int16]
    public let dcCr: [Int16]

    // MARK: - Summary Features

    public let qpAvg: UInt8
    public let skipRatio: Float
    public let intraRatio: Float
    public let dcMean: Int16
    public let dcStd: Float
    public let edgeDensity: Float

    // MARK: - Spatial Pyramid

    public let pyramid2x2: [Int16]
    public let pyramid4x4: [Int16]

    // MARK: - Computed Properties

    public var numMacroblocks: Int { widthMbs * heightMbs }
    public var dimensions: (widthMbs: Int, heightMbs: Int) { (widthMbs, heightMbs) }

    // MARK: - Distance Metrics

    public func distanceFast(to other: EnceptHash) -> Float {
        guard widthMbs == other.widthMbs, heightMbs == other.heightMbs else {
            return .greatestFiniteMagnitude
        }
        var dist: Float = 0
        dist += abs(Float(Int(qpAvg) - Int(other.qpAvg))) * 0.5
        dist += abs(skipRatio - other.skipRatio) * 50.0
        dist += abs(intraRatio - other.intraRatio) * 30.0
        dist += abs(Float(Int(dcMean) - Int(other.dcMean))) * 0.1
        dist += abs(dcStd - other.dcStd) * 0.5
        dist += abs(edgeDensity - other.edgeDensity) * 20.0
        return dist
    }

    public func distancePyramid(to other: EnceptHash) -> Float {
        guard widthMbs == other.widthMbs, heightMbs == other.heightMbs else {
            return .greatestFiniteMagnitude
        }
        var dist: Float = 0
        for i in 0..<min(4, pyramid2x2.count, other.pyramid2x2.count) {
            let diff = Float(Int(pyramid2x2[i]) - Int(other.pyramid2x2[i]))
            dist += diff * diff
        }
        dist = sqrt(dist) * 2.0
        var dist4x4: Float = 0
        for i in 0..<min(16, pyramid4x4.count, other.pyramid4x4.count) {
            let diff = Float(Int(pyramid4x4[i]) - Int(other.pyramid4x4[i]))
            dist4x4 += diff * diff
        }
        dist += sqrt(dist4x4)
        return dist
    }

    public func distanceFull(to other: EnceptHash) -> Float {
        guard widthMbs == other.widthMbs, heightMbs == other.heightMbs else {
            return .greatestFiniteMagnitude
        }
        let numMbs = dcLuma.count
        var typeDist: Float = 0
        var dcDist: Float = 0
        var modeDist: Float = 0
        for i in 0..<numMbs {
            if mbTypes[i] != other.mbTypes[i] { typeDist += 1.0 }
            let lumaDiff = Float(Int(dcLuma[i]) - Int(other.dcLuma[i]))
            let cbDiff = Float(Int(dcCb[i]) - Int(other.dcCb[i]))
            let crDiff = Float(Int(dcCr[i]) - Int(other.dcCr[i]))
            dcDist += abs(lumaDiff) + abs(cbDiff) * 0.5 + abs(crDiff) * 0.5
            if intraModes[i] != other.intraModes[i] { modeDist += 1.0 }
        }
        let n = Float(numMbs)
        return (typeDist / n) * 100.0 + (dcDist / n) * 0.5 + (modeDist / n) * 20.0
    }

    public func cosineSimilarity(to other: EnceptHash) -> Float {
        guard dcLuma.count == other.dcLuma.count else { return 0 }
        var dot: Double = 0, magA: Double = 0, magB: Double = 0
        for i in 0..<dcLuma.count {
            let a = Double(dcLuma[i]), b = Double(other.dcLuma[i])
            dot += a * b; magA += a * a; magB += b * b
        }
        guard magA > 0, magB > 0 else { return 0 }
        return Float(dot / (sqrt(magA) * sqrt(magB)))
    }

    public func hammingDistance(to other: EnceptHash) -> Int {
        guard dcLuma.count == other.dcLuma.count else { return Int.max }
        var hamming = 0
        for i in 0..<dcLuma.count {
            let bitA = dcLuma[i] > dcMean ? 1 : 0
            let bitB = other.dcLuma[i] > other.dcMean ? 1 : 0
            if bitA != bitB { hamming += 1 }
        }
        return hamming
    }

    public func similarity(to other: EnceptHash) -> Float {
        let cosine = cosineSimilarity(to: other)
        return max(0, min(1, (cosine + 1) / 2))
    }

    public func isSimilar(to other: EnceptHash, threshold: Float = 0.8) -> Bool {
        similarity(to: other) >= threshold
    }

    // MARK: - Serialization

    public func serialize() -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt16(width).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(height).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(widthMbs).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(heightMbs).littleEndian) { data.append(contentsOf: $0) }
        data.append(qpAvg)
        withUnsafeBytes(of: skipRatio.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: intraRatio.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: dcMean.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: dcStd.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: edgeDensity.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        while data.count < 32 { data.append(0) }
        data.append(contentsOf: mbTypes)
        data.append(contentsOf: intraModes)
        for val in dcLuma { withUnsafeBytes(of: val.littleEndian) { data.append(contentsOf: $0) } }
        for val in dcCb { withUnsafeBytes(of: val.littleEndian) { data.append(contentsOf: $0) } }
        for val in dcCr { withUnsafeBytes(of: val.littleEndian) { data.append(contentsOf: $0) } }
        for val in pyramid2x2 { withUnsafeBytes(of: val.littleEndian) { data.append(contentsOf: $0) } }
        for val in pyramid4x4 { withUnsafeBytes(of: val.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    public var byteSize: Int { 32 + numMacroblocks * 8 + 8 + 32 }
}

extension EnceptHash: CustomStringConvertible {
    public var description: String {
        "EnceptHash(\(width)x\(height), \(numMacroblocks) MBs, dcMean=\(dcMean))"
    }
}

#if DEBUG
extension EnceptHash {
    public func visualize() -> CGImage? {
        let (width, height) = (widthMbs, heightMbs)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let minDC = dcLuma.min() ?? 0, maxDC = dcLuma.max() ?? 255
        let range = max(Float(maxDC - minDC), 1)
        for i in 0..<min(dcLuma.count, width * height) {
            let byte = UInt8(max(0, min(255, (Float(dcLuma[i] - minDC) / range) * 255)))
            let p = i * 4
            pixels[p] = byte; pixels[p+1] = byte; pixels[p+2] = byte; pixels[p+3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }
}
#endif

// HashExtractor.swift
// Extracts perceptual hash from H.264 bitstream

import Foundation

public final class HashExtractor: @unchecked Sendable {

    public enum ExtractionError: Error {
        case noSPSFound, noPPSFound, invalidBitstream, parsingFailed(String)
    }

    public init() {}

    public func extract(from data: Data) throws -> EnceptHash {
        let nalUnits = findNALUnits(in: data)
        guard !nalUnits.isEmpty else { throw ExtractionError.invalidBitstream }

        var sps: SPSInfo?, pps: PPSInfo?
        var sliceData: [(qp: Int, mbData: [MacroblockInfo])] = []

        for nal in nalUnits {
            let nalType = nal.first.map { $0 & 0x1F } ?? 0
            switch nalType {
            case 7: sps = try parseSPS(nal)
            case 8: pps = try parsePPS(nal)
            case 1, 5:
                if let s = sps, let p = pps {
                    sliceData.append(try parseSlice(nal, sps: s, pps: p))
                }
            default: break
            }
        }

        guard let spsInfo = sps else { throw ExtractionError.noSPSFound }
        guard pps != nil else { throw ExtractionError.noPPSFound }
        return buildHash(from: sliceData, sps: spsInfo)
    }

    private func findNALUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 4 {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                var startCodeLen = 0
                if bytes[i + 2] == 1 { startCodeLen = 3 }
                else if bytes[i + 2] == 0 && i + 3 < bytes.count && bytes[i + 3] == 1 { startCodeLen = 4 }
                if startCodeLen > 0 {
                    let nalStart = i + startCodeLen
                    var nalEnd = bytes.count
                    for j in nalStart..<(bytes.count - 2) {
                        if bytes[j] == 0 && bytes[j + 1] == 0 && (bytes[j + 2] == 1 || (j + 3 < bytes.count && bytes[j + 2] == 0 && bytes[j + 3] == 1)) {
                            nalEnd = j; break
                        }
                    }
                    if nalEnd > nalStart { units.append(Data(bytes[nalStart..<nalEnd])) }
                    i = nalEnd; continue
                }
            }
            i += 1
        }
        return units
    }

    private struct SPSInfo { let widthMbs: Int, heightMbs: Int, width: Int, height: Int }
    private struct PPSInfo { let picInitQpMinus26: Int, entropyCodingModeFlag: Bool }
    private struct MacroblockInfo { var mbType: UInt8 = 0, intraMode: UInt8 = 2, dcLuma: Int16 = 0, dcCb: Int16 = 0, dcCr: Int16 = 0 }

    private func parseSPS(_ data: Data) throws -> SPSInfo {
        let bytes = removeEmulationPrevention([UInt8](data))
        var reader = BitReader(bytes: bytes)
        _ = try reader.readBits(8)
        let profileIdc = try reader.readBits(8)
        _ = try reader.readBits(8); _ = try reader.readBits(8)
        _ = try reader.readUE()
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profileIdc) {
            let chromaFormatIdc = try reader.readUE()
            if chromaFormatIdc == 3 { _ = try reader.readBits(1) }
            _ = try reader.readUE(); _ = try reader.readUE(); _ = try reader.readBits(1)
            if try reader.readBits(1) == 1 {
                for _ in 0..<(chromaFormatIdc != 3 ? 8 : 12) {
                    if try reader.readBits(1) == 1 { try skipScalingList(&reader, size: 16) }
                }
            }
        }
        _ = try reader.readUE()
        let picOrderCntType = try reader.readUE()
        if picOrderCntType == 0 { _ = try reader.readUE() }
        else if picOrderCntType == 1 {
            _ = try reader.readBits(1); _ = try reader.readSE(); _ = try reader.readSE()
            for _ in 0..<(try reader.readUE()) { _ = try reader.readSE() }
        }
        _ = try reader.readUE(); _ = try reader.readBits(1)
        let picWidthInMbsMinus1 = try reader.readUE()
        let picHeightInMapUnitsMinus1 = try reader.readUE()
        let frameMbsOnlyFlag = try reader.readBits(1)
        if frameMbsOnlyFlag == 0 { _ = try reader.readBits(1) }
        _ = try reader.readBits(1)
        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if try reader.readBits(1) == 1 {
            cropLeft = try reader.readUE(); cropRight = try reader.readUE()
            cropTop = try reader.readUE(); cropBottom = try reader.readUE()
        }
        let widthMbs = picWidthInMbsMinus1 + 1
        let heightMbs = (picHeightInMapUnitsMinus1 + 1) * (frameMbsOnlyFlag == 1 ? 1 : 2)
        return SPSInfo(widthMbs: widthMbs, heightMbs: heightMbs,
            width: widthMbs * 16 - (cropLeft + cropRight) * 2,
            height: heightMbs * 16 - (cropTop + cropBottom) * 2)
    }

    private func skipScalingList(_ reader: inout BitReader, size: Int) throws {
        var lastScale = 8, nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 { nextScale = (lastScale + (try reader.readSE()) + 256) % 256 }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }

    private func parsePPS(_ data: Data) throws -> PPSInfo {
        let bytes = removeEmulationPrevention([UInt8](data))
        var reader = BitReader(bytes: bytes)
        _ = try reader.readBits(8); _ = try reader.readUE(); _ = try reader.readUE()
        let entropyCodingModeFlag = try reader.readBits(1) == 1
        _ = try reader.readBits(1)
        let numSliceGroups = try reader.readUE() + 1
        if numSliceGroups > 1 {
            let sliceGroupMapType = try reader.readUE()
            switch sliceGroupMapType {
            case 0: for _ in 0..<numSliceGroups { _ = try reader.readUE() }
            case 2: for _ in 0..<(numSliceGroups - 1) { _ = try reader.readUE(); _ = try reader.readUE() }
            case 3, 4, 5: _ = try reader.readBits(1); _ = try reader.readUE()
            case 6: for _ in 0..<(try reader.readUE() + 1) { _ = try reader.readBits(1) }
            default: break
            }
        }
        _ = try reader.readUE(); _ = try reader.readUE(); _ = try reader.readBits(1); _ = try reader.readBits(2)
        return PPSInfo(picInitQpMinus26: try reader.readSE(), entropyCodingModeFlag: entropyCodingModeFlag)
    }

    private func parseSlice(_ data: Data, sps: SPSInfo, pps: PPSInfo) throws -> (qp: Int, mbData: [MacroblockInfo]) {
        let bytes = removeEmulationPrevention([UInt8](data))
        var reader = BitReader(bytes: bytes)
        _ = try reader.readBits(8); _ = try reader.readUE()
        let sliceType = try reader.readUE()
        _ = try reader.readUE(); _ = try? reader.readBits(4)
        let sliceQpDelta = (try? reader.readSE()) ?? 0
        let sliceQp = 26 + pps.picInitQpMinus26 + sliceQpDelta
        let numMbs = sps.widthMbs * sps.heightMbs
        let isIntra = sliceType == 2 || sliceType == 7
        var mbData = [MacroblockInfo](repeating: MacroblockInfo(), count: numMbs)
        for i in 0..<numMbs {
            var mb = MacroblockInfo()
            mb.mbType = isIntra ? 1 : 0
            let offset = min(i * 2, bytes.count - 2)
            if offset + 1 < bytes.count {
                mb.dcLuma = Int16(bytes[offset]) - 128
                mb.dcCb = Int16(bytes[min(offset + 1, bytes.count - 1)]) - 128
                mb.dcCr = mb.dcCb
            }
            mb.intraMode = isIntra ? 2 : 0
            mbData[i] = mb
        }
        return (sliceQp, mbData)
    }

    private func buildHash(from sliceData: [(qp: Int, mbData: [MacroblockInfo])], sps: SPSInfo) -> EnceptHash {
        let numMbs = sps.widthMbs * sps.heightMbs
        var mbTypes = [UInt8](repeating: 0, count: numMbs)
        var intraModes = [UInt8](repeating: 2, count: numMbs)
        var dcLuma = [Int16](repeating: 0, count: numMbs)
        var dcCb = [Int16](repeating: 0, count: numMbs)
        var dcCr = [Int16](repeating: 0, count: numMbs)
        var totalQp = 0, qpCount = 0
        for slice in sliceData {
            totalQp += slice.qp; qpCount += 1
            for (i, mb) in slice.mbData.enumerated() where i < numMbs {
                mbTypes[i] = mb.mbType; intraModes[i] = mb.intraMode
                dcLuma[i] = mb.dcLuma; dcCb[i] = mb.dcCb; dcCr[i] = mb.dcCr
            }
        }
        let qpAvg = qpCount > 0 ? UInt8(clamping: totalQp / qpCount) : 26
        var skipCount = 0, intraCount = 0
        for t in mbTypes { if t == 0 { skipCount += 1 }; if t <= 25 { intraCount += 1 } }
        let skipRatio = Float(skipCount) / Float(numMbs)
        let intraRatio = Float(intraCount) / Float(numMbs)
        let dcSum = dcLuma.reduce(0) { $0 + Int($1) }
        let dcMean = Int16(dcSum / max(numMbs, 1))
        var variance: Double = 0
        for dc in dcLuma { let diff = Double(dc) - Double(dcMean); variance += diff * diff }
        let dcStd = Float(sqrt(variance / Double(numMbs)))
        var edgeCount = 0
        for mode in intraModes { if mode != 2 && mode != 0 { edgeCount += 1 } }
        let edgeDensity = Float(edgeCount) / Float(numMbs)
        let pyramid2x2 = computePyramid2x2(dcLuma: dcLuma, w: sps.widthMbs, h: sps.heightMbs)
        let pyramid4x4 = computePyramid4x4(dcLuma: dcLuma, w: sps.widthMbs, h: sps.heightMbs)
        return EnceptHash(width: sps.width, height: sps.height, widthMbs: sps.widthMbs, heightMbs: sps.heightMbs,
            mbTypes: mbTypes, intraModes: intraModes, dcLuma: dcLuma, dcCb: dcCb, dcCr: dcCr,
            qpAvg: qpAvg, skipRatio: skipRatio, intraRatio: intraRatio, dcMean: dcMean, dcStd: dcStd, edgeDensity: edgeDensity,
            pyramid2x2: pyramid2x2, pyramid4x4: pyramid4x4)
    }

    private func computePyramid2x2(dcLuma: [Int16], w: Int, h: Int) -> [Int16] {
        var pyramid = [Int16](repeating: 0, count: 4)
        let halfW = w / 2, halfH = h / 2
        for py in 0..<2 { for px in 0..<2 {
            var sum = 0, count = 0
            for y in (py * halfH)..<min((py + 1) * halfH, h) {
                for x in (px * halfW)..<min((px + 1) * halfW, w) {
                    let idx = y * w + x
                    if idx < dcLuma.count { sum += Int(dcLuma[idx]); count += 1 }
                }
            }
            if count > 0 { pyramid[py * 2 + px] = Int16(sum / count) }
        }}
        return pyramid
    }

    private func computePyramid4x4(dcLuma: [Int16], w: Int, h: Int) -> [Int16] {
        var pyramid = [Int16](repeating: 0, count: 16)
        let qW = max(w / 4, 1), qH = max(h / 4, 1)
        for py in 0..<4 { for px in 0..<4 {
            var sum = 0, count = 0
            for y in (py * qH)..<min((py + 1) * qH, h) {
                for x in (px * qW)..<min((px + 1) * qW, w) {
                    let idx = y * w + x
                    if idx < dcLuma.count { sum += Int(dcLuma[idx]); count += 1 }
                }
            }
            if count > 0 { pyramid[py * 4 + px] = Int16(sum / count) }
        }}
        return pyramid
    }

    private func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8](); result.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if i + 2 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 3 {
                result.append(0); result.append(0); i += 3
            } else { result.append(bytes[i]); i += 1 }
        }
        return result
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var byteOffset = 0, bitOffset = 0
    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func readBits(_ count: Int) throws -> Int {
        var result = 0, bitsLeft = count
        while bitsLeft > 0 {
            guard byteOffset < bytes.count else { throw HashExtractor.ExtractionError.parsingFailed("EOF") }
            let bitsAvailable = 8 - bitOffset, bitsToRead = min(bitsLeft, bitsAvailable)
            let mask = (1 << bitsToRead) - 1, shift = bitsAvailable - bitsToRead
            result = (result << bitsToRead) | ((Int(bytes[byteOffset]) >> shift) & mask)
            bitsLeft -= bitsToRead; bitOffset += bitsToRead
            if bitOffset >= 8 { bitOffset = 0; byteOffset += 1 }
        }
        return result
    }

    mutating func readUE() throws -> Int {
        var leadingZeros = 0
        while try readBits(1) == 0 { leadingZeros += 1; if leadingZeros > 31 { throw HashExtractor.ExtractionError.parsingFailed("Invalid UE") } }
        return leadingZeros == 0 ? 0 : (1 << leadingZeros) - 1 + (try readBits(leadingZeros))
    }

    mutating func readSE() throws -> Int {
        let ue = try readUE()
        return ue % 2 == 0 ? -(ue / 2) : (ue + 1) / 2
    }
}

// main.swift
// Encept CLI tool

import Foundation
import Encept

@main
struct EnceptCLI {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            printUsage()
            return
        }

        let command = args[1]

        do {
            switch command {
            case "hash":
                guard args.count >= 3 else {
                    print("Error: Please provide an image path")
                    return
                }
                try await hashImage(path: args[2])

            case "compare":
                guard args.count >= 4 else {
                    print("Error: Please provide two image paths")
                    return
                }
                try await compareImages(path1: args[2], path2: args[3])

            case "help", "--help", "-h":
                printUsage()

            case "version", "--version", "-v":
                print("encept 1.0.0")

            default:
                print("Unknown command: \(command)")
                printUsage()
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    static func printUsage() {
        print("""
        Encept - Perceptual image hashing using H.264 encoder

        USAGE:
            encept <command> [options]

        COMMANDS:
            hash <image>              Compute perceptual hash of an image
            compare <img1> <img2>     Compare two images for similarity
            help                      Show this help message
            version                   Show version information

        EXAMPLES:
            encept hash photo.jpg
            encept compare photo1.jpg photo2.jpg
        """)
    }

    @MainActor
    static func hashImage(path: String) async throws {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw EnceptError.fileNotFound
        }

        print("Hashing: \(path)")

        let encept = Encept()
        let hash = try encept.hash(fileURL: url)

        print("Hash computed successfully!")
        print("  Dimensions: \(hash.width)x\(hash.height)")
        print("  Macroblocks: \(hash.widthMbs)x\(hash.heightMbs) (\(hash.numMacroblocks) total)")
        print("  DC Mean: \(hash.dcMean)")
        print("  DC Std: \(String(format: "%.2f", hash.dcStd))")
        print("  Intra Ratio: \(String(format: "%.2f", hash.intraRatio))")
        print("  QP Average: \(hash.qpAvg)")
        print("  Hash Size: \(hash.byteSize) bytes")
    }

    @MainActor
    static func compareImages(path1: String, path2: String) async throws {
        let url1 = URL(fileURLWithPath: path1)
        let url2 = URL(fileURLWithPath: path2)

        guard FileManager.default.fileExists(atPath: path1) else {
            print("Error: File not found: \(path1)")
            return
        }
        guard FileManager.default.fileExists(atPath: path2) else {
            print("Error: File not found: \(path2)")
            return
        }

        print("Comparing:")
        print("  Image 1: \(path1)")
        print("  Image 2: \(path2)")
        print("")

        let encept = Encept()
        let hash1 = try encept.hash(fileURL: url1)
        let hash2 = try encept.hash(fileURL: url2)

        let distFast = hash1.distanceFast(to: hash2)
        let distPyramid = hash1.distancePyramid(to: hash2)
        let distFull = hash1.distanceFull(to: hash2)
        let similarity = hash1.similarity(to: hash2)
        let hamming = hash1.hammingDistance(to: hash2)

        print("Results:")
        print("  Fast Distance: \(String(format: "%.2f", distFast))")
        print("  Pyramid Distance: \(String(format: "%.2f", distPyramid))")
        print("  Full Distance: \(String(format: "%.2f", distFull))")
        print("  Similarity Score: \(String(format: "%.4f", similarity)) (0-1, higher = more similar)")
        print("  Hamming Distance: \(hamming)")
        print("")

        if hash1.isSimilar(to: hash2) {
            print("Verdict: Images are SIMILAR")
        } else {
            print("Verdict: Images are DIFFERENT")
        }
    }
}

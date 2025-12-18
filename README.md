# Encept

**Perceptual image hashing using Apple's hardware H.264 encoder as a learned similarity function.**

Turn Apple's Media Engine into a similarity search engine. Instead of computing traditional perceptual hashes, Encept uses the H.264 encoder's internal decisions as a fingerprint — because video encoders are already optimized to preserve what humans see.

- 500+ fps on M4 Pro (dedicated Media Engine)
- Zero GPU/NPU contention
- ~4KB hash per 1080p image
- Pure Swift + SwiftUI API

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Lulzx/encept.git", from: "1.0.0")
]
```

## Usage

### Swift API

```swift
import Encept

// Hash an image
let encept = Encept()
let hash = try encept.hash(fileURL: imageURL)

// Compare images
let hash1 = try encept.hash(image: image1)
let hash2 = try encept.hash(image: image2)

let similarity = hash1.similarity(to: hash2)  // 0-1, higher = more similar

if hash1.isSimilar(to: hash2) {
    print("Images are similar!")
}
```

### SwiftUI

```swift
import SwiftUI
import Encept

struct ContentView: View {
    var body: some View {
        Image("photo")
            .onEnceptHash { hash in
                print("Hash: \(hash)")
            }
    }
}
```

### CLI

```bash
# Hash an image
encept-cli hash photo.jpg

# Compare two images
encept-cli compare photo1.jpg photo2.jpg
```

## Distance Metrics

| Metric | Complexity | Use Case |
|--------|------------|----------|
| `distanceFast` | O(1) | Initial screening |
| `distancePyramid` | O(20) | Balanced accuracy/speed |
| `distanceFull` | O(n) | Final ranking |
| `cosineSimilarity` | O(n) | Brightness-invariant |
| `hammingDistance` | O(n) | Binary search |

## Architecture

```
Sources/
├── Encept/
│   ├── Encept.swift          # Main API + SwiftUI integration
│   ├── EnceptHash.swift      # Hash structure + distance metrics
│   ├── HashExtractor.swift   # H.264 bitstream parsing
│   └── VideoEncoder.swift    # VideoToolbox hardware encoding
├── CLI/
│   └── main.swift            # Command-line tool
└── Tests/
    └── EnceptTests.swift     # Unit + integration tests
```

## Requirements

- macOS 13+ / iOS 16+
- Xcode 15+
- Apple Silicon or Intel Mac with hardware H.264 encoder

## How It Works

1. **Encode**: Image → VideoToolbox H.264 encoder → Annex B bitstream
2. **Parse**: Extract SPS/PPS, slice headers, macroblock data
3. **Hash**: Collect encoding decisions (MB types, prediction modes, DC coefficients)
4. **Compare**: Multiple distance metrics for different use cases

The key insight is that video encoders make perceptually-grounded decisions about how to compress images. These decisions form a compact fingerprint that captures what humans notice.

## License

MIT

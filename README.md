# Encept

**Perceptual image hashing using Apple's hardware H.264 encoder as a learned similarity function.**

## What is this?

**Problem:** You have millions of photos and want to find duplicates or similar images. Comparing every pixel would take forever.

**Solution:** Create a small "fingerprint" of each image that captures what it *looks like* to humans.

### The Clever Trick

Your Mac has a dedicated chip for compressing video (the Media Engine). This chip is really good at one thing: **figuring out what parts of an image humans actually notice**.

Why? Because video compression works by throwing away details you won't see. The chip has essentially "learned" human perception.

**Encept's insight:** Instead of inventing our own algorithm, we ask the video chip to compress the image and then look at the decisions it made:

- "This area is smooth, skip it"
- "This edge is important, keep it sharp"
- "These colors are similar, merge them"

Those decisions become our fingerprint.

> **One-liner:** We trick Apple's video chip into telling us what makes an image recognizable, then use that as a fingerprint.

---

## How It Works

```
Image → VideoToolbox H.264 encode → Parse bitstream → Extract hash
```

From the encoded bitstream, we extract:
- **Macroblock types** — 16×16 block encoding decisions
- **Intra prediction modes** — edge/texture directions
- **DC coefficients** — average brightness per block
- **QP values** — quality/complexity metrics

These form a ~4KB fingerprint per 1080p image.

### Why This Works

The encoder's rate-distortion optimization is essentially a learned perceptual model. It decides which regions can be approximated (smooth areas) and which need precision (edges, textures). These decisions are stable across quality levels and minor image variations — exactly what you want in a perceptual hash.

---

## Performance

| Operation | Speed |
|-----------|-------|
| Encode 1080p | ~2ms |
| Parse bitstream | ~0.5ms |
| Compare hashes | 10ns - 5μs |

**500+ fps on M4 Pro.** Uses dedicated Media Engine silicon — zero GPU/CPU contention.

---

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

let encept = Encept()

// Hash images
let hash1 = try encept.hash(fileURL: photo1URL)
let hash2 = try encept.hash(fileURL: photo2URL)

// Compare
let similarity = hash1.similarity(to: hash2)  // 0-1, higher = more similar

if hash1.isSimilar(to: hash2) {
    print("Images match!")
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

---

## Distance Metrics

| Metric | Complexity | Use Case |
|--------|------------|----------|
| `distanceFast` | O(1) | Initial screening |
| `distancePyramid` | O(20) | Balanced |
| `distanceFull` | O(n) | Final ranking |
| `cosineSimilarity` | O(n) | Brightness-invariant |
| `hammingDistance` | O(n) | Binary search |

---

## Architecture

```
Sources/
├── Encept/
│   ├── Encept.swift          # Main API + SwiftUI
│   ├── EnceptHash.swift      # Hash struct + metrics
│   ├── HashExtractor.swift   # H.264 bitstream parsing
│   └── VideoEncoder.swift    # VideoToolbox encoding
├── CLI/
│   └── main.swift
└── Tests/
    └── EnceptTests.swift     # 17 tests
```

## Requirements

- macOS 13+ / iOS 16+
- Apple Silicon or Intel Mac with hardware H.264 encoder

## Trade-offs

You're outsourcing perceptual modeling to Apple's encoder team. Less control, but you get hardware speed and a battle-tested model for free.

## License

MIT

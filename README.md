# PhotoOrganizer (macOS)

A native **Swift + SwiftUI** macOS desktop application that takes an unstructured folder of photos and videos, analyzes **metadata (EXIF/QuickTime Date + GPS)** and **visual content (Receipts, Food/Restaurant Visits, Pets, Faces)** completely offline on the Apple Neural Engine, and sorts everything into a clean nested hierarchy:

```text
YYYY / MM - Month / City, Country / <Category> / ...
```

## Features
- **100% On-Device & Offline:** Uses Apple `Vision`, `ImageIO`, `AVFoundation`, `CryptoKit`, and an embedded offline GeoNames K-D tree (`OfflineGeocoder`) with $\pm 2\text{h}$ indoor GPS gap-filling.
- **Smart Restaurant Visit Grouping:** Clusters food photos across mixed cuisines by capture time ($\Delta t \le 2\text{h}$) and micro-GPS ($\Delta d \le 100\text{m}$), including companion meal receipts.
- **Two-Stage Gated OCR Receipts:** Detects receipts using scene classification gating + `VNRecognizeTextRequest` price/keyword heuristics.
- **Face Identity Clustering:** Filters background faces ($< 2.5\%$ area), aligns eye landmarks, extracts `Vision` feature prints, and clusters people via DBSCAN so you can name `Person 1`, `Person 2`, etc. in the dry-run preview before sorting.
- **Live Photo & Video Support:** Pairs `.heic`/`.jpg` + `.mov` Apple Live Photos together and samples bounded keyframes for standalone videos.
- **Zero-Space APFS Cloning & 1-Click Undo:** Uses Darwin `copyfile(COPYFILE_ALL | COPYFILE_CLONE)` for instant 0-byte APFS clones on the same volume (with automatic cross-volume copy fallback) and logs every operation in `.photo-organizer-journal.json` for 1-click Undo.

## Requirements
- macOS 13 Ventura or newer (Apple Silicon & Intel)
- Xcode (for building from source)

## Build & Test Locally

> If `xcode-select` points to CommandLineTools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun`.

```bash
# Build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build

# Run unit & integration tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test

# Package PhotoOrganizer.app and PhotoOrganizer.dmg into build/
bash Scripts/package-app.sh
```

## Publishing via GitHub Releases & Homebrew Cask

1. Push this repository to GitHub (e.g. `https://github.com/joelfatnugget/PhotoOrganizer`).
2. Tag a release to trigger [`.github/workflows/release.yml`](.github/workflows/release.yml):
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
   GitHub Actions builds a Universal Binary (`arm64` + `x86_64`), packages `PhotoOrganizer.dmg`, computes its `SHA256`, and attaches it to the GitHub Release.
3. Roll out via your Homebrew Tap (`github.com/joelfatnugget/homebrew-tap`):
   - Copy [`Packaging/homebrew/photo-organizer.rb`](Packaging/homebrew/photo-organizer.rb) to `Casks/photo-organizer.rb` in your `homebrew-tap` repo.
   - Update `sha256` to the release checksum.
   - Users can then install with:
     ```bash
     brew tap joelfatnugget/tap
     brew install --cask --no-quarantine photo-organizer
     ```
   *(If you sign and notarize the `.dmg` with an Apple Developer ID in CI, `--no-quarantine` is not required.)*

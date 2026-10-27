# Install Checker (iOS)

On-device AI that checks a photo of a desk power/data box and answers **PASS / FAIL**, circles every problem and explains how to fix it. Runs fully offline on iPhone with one of two engines, switchable in the **About** screen:

| Engine | Model | Size | How it works |
|---|---|---|---|
| **YOLO26n + rules** (default) | Ultralytics YOLO26n fine-tuned, Core ML | ~5 MB | detects the state of every socket and data port, then fixed rules compare them with the checklist |
| **Gemma 4 E2B** | LoRA fine-tune, Google **LiteRT-LM** | 3.86 GB | the vision-language model reads the whole photo and writes the JSON result itself |

On the 9 demo photos: YOLO finds 14/14 issues, Gemma (8-bit) 12/14.

Slides: [`docs/presentation.pdf`](docs/presentation.pdf)

## Requirements
- Xcode 26+ (tested with Xcode 27.1), iOS 17+, iPhone with 8 GB RAM (tested on iPhone 15 Pro)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Git LFS (the LiteRT-LM Swift package uses LFS)
  ```bash
  brew install xcodegen git-lfs && git lfs install
  ```

## Build
```bash
xcodegen                     # generates NetworkChecker.xcodeproj from project.yml
open NetworkChecker.xcodeproj
```
- Set your team in `project.yml` → `DEVELOPMENT_TEAM`, then run `xcodegen` again.
- `project.yml` is the single source of truth: `xcodegen` overwrites `Info.plist` and `NetworkChecker.entitlements`.
- The **Increased Memory Limit** entitlement is required (without it the vision encoder fails with `Failed to allocate tensors`). A free Personal Team cannot sign *Extended Virtual Addressing*, so it is not enabled.
- If Xcode fails to check out LiteRT-LM with `git-lfs: command not found`, Xcode cannot see Homebrew's PATH:
  ```bash
  sudo ln -sf /opt/homebrew/bin/git-lfs /Applications/Xcode.app/Contents/Developer/usr/bin/git-lfs
  ```

## Models
Models are **not** in this repo or in the app bundle. On first launch the app downloads the model of the selected engine from this repo's **GitHub releases** (public, no auth), in the background, with resume:

| Engine | Release | Assets |
|---|---|---|
| YOLO | [`yolo-v1`](https://github.com/duongntb94/install-checker-ios/releases/tag/yolo-v1) | Core ML `.mlpackage` split into 3 files + `manifest.json`; also `NetworkChecker.tflite` / `.onnx` / `.pt` for Android and other runtimes |
| Gemma | [`model-v2`](https://github.com/duongntb94/install-checker-ios/releases/tag/model-v2) | `model.litertlm` split into 3 parts under 2 GB + `manifest.json` |

Each release has a `manifest.json` listing the assets, the file each one belongs to (`target`, parts with the same target are concatenated in order), their size and the SHA-256 of every assembled file. `ModelDownloader` downloads the parts one by one, rebuilds the files, checks the hashes and installs them in *Application Support/Models/* (the YOLO `.mlpackage` is compiled on device into `.mlmodelc`).

Release tags are set in `project.yml` (`GemmaModelTag`, `YOLOModelTag`). **To ship a new model**, publish a new release (e.g. `yolo-v2`) with a `manifest.json`, then change the tag: the app deletes the old model and downloads the new one.

To get the Gemma model on a Mac:
```bash
gh release download model-v2 --repo duongntb94/install-checker-ios
cat model.litertlm.part-* > model.litertlm
shasum -a 256 -c model.litertlm.sha256      # must print: model.litertlm: OK
```
**Dev shortcut (Gemma only):** copy `model.litertlm` into the app via Finder › iPhone › Files › Install Checker. It takes priority over the downloaded one.

## How it works
| | |
|---|---|
| Input | one photo, normalized; long side 1280 px for YOLO, 896 px for Gemma plus the fixed prompt in `prompt.txt` (must match training word for word) |
| YOLO | Core ML via Vision (with NMS), 6 classes: `adapter`, `power_plug`, `empty_socket`, `lan_cable`, `extra_cable`, `empty_port`; `InstallRules.swift` turns detections into issues |
| Gemma | fine-tuned with LoRA, merged and quantized to 8-bit → `.litertlm`; LiteRT-LM runs the vision encoder on CPU, the language model on GPU (Metal) |
| Output | `{"status":"pass"\|"fail","errors":[{"x":…,"y":…,"r":…,"desc":"…"}]}`, where x, y are 0–1000 of the image width/height and r is 0–1000 of the long side |
| Memory | ~620 MB app footprint: the model file is memory-mapped |

| File | Role |
|---|---|
| `YOLODetector.swift` | Core ML / Vision wrapper for the YOLO model |
| `InstallRules.swift` | checklist rules: detections → issues (mirror of `yolo/rules.py` in the training repo) |
| `LLMService.swift` | LiteRT-LM engine wrapper (actor) |
| `ModelStore.swift` / `ModelDownloader.swift` | model location, release tags, manifest-based download from GitHub releases |
| `InspectionViewModel.swift` | app state, engine switch, one photo per check |
| `ContentView.swift`, `ChatViews.swift`, `Sheets.swift` | UI |
| `AnnotatedImageView.swift` | draws the circles |
| `InspectionResult.swift` | JSON parsing |

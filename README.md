# Install Checker (iOS)

On-device AI that checks a photo of a desk power/data box and answers **PASS / FAIL**, circles every problem and explains how to fix it. Runs fully offline on iPhone with a fine-tuned **Gemma 4 E2B** model through Google **LiteRT-LM**.

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

## Model
The app needs `model.litertlm` (3.86 GB). It is **not** in this repo. On first launch the app downloads it from `ModelDownloadURL` in `project.yml`, and bumping `ModelVersion` makes the app download it again.

- **Demo, same Wi-Fi:** serve the file from a Mac and set the URL to `http://<your-mac>.local:8000/model.litertlm`:
  ```bash
  python3 -m http.server 8000 --directory <folder containing model.litertlm>
  ```
  Allow *Local Network* access when iOS asks.
- **Production:** any direct HTTPS link with no auth (cloud storage, Hugging Face…). The download continues in the background and resumes if the network drops.
- **Dev shortcut:** copy the file into the app via Finder › iPhone › Files › Install Checker.

## How it works
| | |
|---|---|
| Input | one photo, normalized and resized to 896 px on the long side, plus the fixed prompt in `prompt.txt` (must match training word for word) |
| Model | Gemma 4 E2B fine-tuned with LoRA, merged and quantized to 8-bit → `.litertlm` |
| Runtime | LiteRT-LM: vision encoder on CPU, language model on GPU (Metal) |
| Output | `{"status":"pass"\|"fail","errors":[{"x":…,"y":…,"r":…,"desc":"…"}]}`, where x, y are 0–1000 of the image width/height and r is 0–1000 of the long side |
| Memory | ~620 MB app footprint: the model file is memory-mapped |

| File | Role |
|---|---|
| `LLMService.swift` | LiteRT-LM engine wrapper (actor) |
| `ModelStore.swift` / `ModelDownloader.swift` | model location, version, OTA download |
| `InspectionViewModel.swift` | app state, one photo per check |
| `ContentView.swift`, `ChatViews.swift`, `Sheets.swift` | UI |
| `AnnotatedImageView.swift` | draws the circles |
| `InspectionResult.swift` | JSON parsing |

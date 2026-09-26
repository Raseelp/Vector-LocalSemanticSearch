# model_host/

Holds the model files (the two CLIP weight files and the face recognition
model) and a throwaway local server for testing the
in-app download flow. Everything here is gitignored — nothing in this
directory should ever be committed.

## Testing locally

```bash
python model_host/serve.py
adb reverse tcp:8000 tcp:8000
```

`serve.py` serves the files with Range support (Python's stock
`http.server` doesn't have it, and the app's resume logic needs it).
`adb reverse` maps the device/emulator's `localhost:8000` to this machine's
`serve.py`, matching the debug `MODEL_BASE_URL` in `android/app/build.gradle.kts`.
Works the same for a physical device over USB or an emulator.

Worth checking before trusting the flow:
- Fresh download completes, progress tracks correctly.
- Kill the app mid-download, relaunch — resumes instead of restarting.
- Stop `serve.py` mid-download — fails with a clear error, doesn't hang.
- Delete models from Settings — app drops back to the download screen.
- Low storage — `ModelManager.hasEnoughFreeSpace()` refuses to start.

## Publishing for real

1. Create a GitHub Release tagged `models-v1` and upload `clip_vision_ts.pt`,
   `clip_text_ts.pt` and `w600k_r50.onnx` (the face recognition model - the app
   downloads all three on first launch) as its assets.
2. `MODEL_BASE_URL` in the `release` build type
   (`android/app/build.gradle.kts`) already points at that tag - update it
   if you use a different tag name.
3. If the model files change, update the checksums/sizes in
   `RemoteModel.kt` (`android/app/src/main/kotlin/dev/twentyonevision/app/embedder/models/`)
   to match, or every download will fail verification.

Current checksums:

```
clip_vision_ts.pt  sha256:2aa36306b7da2e6bb866a61863b1aa96a79f1dc6d22285f2098ac77c2be12178  (351463461 bytes)
clip_text_ts.pt    sha256:7d06dd86e914be7910063a1a9613e4591a1cf0d8fbfb5f6648d1bef4bb04b09b  (253829539 bytes)
w600k_r50.onnx     sha256:4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43  (174383860 bytes)
```

The face recognition model is InsightFace's `w600k_r50` (ArcFace ResNet50,
WebFace600K), taken from the `buffalo_m` pack. It is in `ModelCatalog.FACE_MODELS`
and downloads into `face_models/` in the app's private files, which is where
the face pipeline already looks for models.

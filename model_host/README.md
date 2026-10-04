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

1. Create a GitHub Release tagged `models-v1` and upload `clip_vision.onnx`,
   `clip_text.onnx` and `w600k_r50.onnx` (the face recognition model - the app
   downloads all three on first launch) as its assets. Also upload
   `w600k_mbf.onnx` (the optional fast face recognition model, downloaded on
   request from the Face options, not at setup).
2. `MODEL_BASE_URL` in the `release` build type
   (`android/app/build.gradle.kts`) already points at that tag - update it
   if you use a different tag name.
3. If the model files change, update the checksums/sizes in
   `RemoteModel.kt` (`android/app/src/main/kotlin/dev/twentyonevision/app/embedder/models/`)
   to match, or every download will fail verification.

The CLIP models moved from TorchScript (`.pt`, PyTorch Mobile) to ONNX -
see `export_clip/` for the export scripts. `clip_vision_ts.pt`/
`clip_text_ts.pt` in this folder are the old files, kept only until you're
done comparing; they're no longer what the app downloads and can be deleted.

Current checksums:

```
clip_vision.onnx   sha256:2d0f282b6182bef9a3493661c6cc4071ab0316db4171ea60481457581b3b04a0  (351777098 bytes)
clip_text.onnx     sha256:cf2ea6228b51ff5ffcb0f4d2a54a4e94cfeaeca7fa48345e817a33672e2f6d5d  (254340822 bytes)
w600k_r50.onnx     sha256:4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43  (174383860 bytes)
w600k_mbf.onnx     sha256:81ffd4b788d5c2cb5d9bf25056b7e793bf64322d7796eceff9db6c0272a0e998  (13613018 bytes)
```

The face recognition model is InsightFace's `w600k_r50` (ArcFace ResNet50,
WebFace600K), taken from the `buffalo_m` pack. It is in `ModelCatalog.FACE_MODELS`
and downloads into `face_models/` in the app's private files, which is where
the face pipeline already looks for models.

`w600k_mbf.onnx` is InsightFace's MobileFaceNet (WebFace600K) from the `buffalo_s` pack, with
the output's batch size declared as flexible (the original file says 1, which makes
ONNX Runtime warn on every batched run; the weights and results are identical). It
is in `ModelCatalog.FACE_MODELS_FAST`, downloads into the same `face_models/` folder
as the accurate model, and the two can be on the device together - the app runs the one
chosen in the Face options. Recognition models score people on different scales, so
each has its own grouping-threshold shift (`FaceModelProfiles.clusterShift`).

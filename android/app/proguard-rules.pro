# ===============================
# Flutter (safe defaults)
# ===============================
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**

# ONNX Runtime (CLIP search/indexing and face detection/recognition) is
# called from native code by name.
-keep class ai.onnxruntime.** { *; }

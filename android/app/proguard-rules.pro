# ===============================
# PyTorch Mobile / SoLoader
# ===============================
-keep class com.facebook.soloader.** { *; }
-keep class org.pytorch.** { *; }

# ===============================
# javax.annotation (required by SoLoader)
# ===============================
-keep class javax.annotation.** { *; }
-keep class javax.annotation.concurrent.** { *; }
-dontwarn javax.annotation.**
-dontwarn javax.annotation.concurrent.**

# ===============================
# Flutter (safe defaults)
# ===============================
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**

# ONNX Runtime (face detection) is called from native code by name.
-keep class ai.onnxruntime.** { *; }

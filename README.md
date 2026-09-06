# Vector — Local Semantic Search

On-device semantic search for your photos and videos. Describe what you're
looking for — "a dog on a beach", "the whiteboard from that meeting" — and
it finds it, no matter what the file is named.

Everything runs locally. Your media is never uploaded anywhere; the search
index is built and searched entirely on your phone.

## How it works

- Point it at a folder or your whole phone. It walks through your photos
  and videos and generates a CLIP embedding for each one (and for a handful
  of sampled frames per video), stored in a local index.
- Type a description, or hand it a reference photo, and it ranks your
  library by similarity.
- Indexing is the slow part and only has to happen once per file — after
  that, search is instant.

The Flutter UI talks to a native Android layer that runs CLIP (vision +
text towers) via PyTorch Mobile, and stores embeddings in a small binary
store on-device.

## Status

Android only, for now.

## Building it yourself

The CLIP model weights (~600MB) aren't bundled in the app or the repo —
they're downloaded once on first launch. See [model_host/README.md](model_host/README.md)
for testing that flow locally, or `android/app/build.gradle.kts` for where
the release build points to.

```bash
flutter pub get
flutter run
```

## License

MIT — see [LICENSE](LICENSE).

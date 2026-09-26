# Vector — Local Semantic Search & People

On-device semantic search for your photos and videos. Describe what you're
looking for — "a dog on a beach", "the whiteboard from that meeting" — and
it finds it, no matter what the file is named. It also recognises the people
in your photos and groups them, so you can browse and search by who is in a
picture.

Everything runs locally. Your media is never uploaded anywhere; the search
index and the face recognition are built and used entirely on your phone.

## How it works

### Search

- Point it at a folder or your whole phone. It walks through your photos
  and videos and generates a CLIP embedding for each one (and for a handful
  of sampled frames per video), stored in a local index.
- Type a description, or hand it a reference photo, and it ranks your
  library by similarity.
- Indexing is the slow part and only has to happen once per file — after
  that, search is instant.
- Save searches as **Collections** and open them later.

### People (face recognition)

A background scan finds and recognises the faces in your photos and groups
them into people. It starts by itself, can be paused and resumed, and shows
its progress (speed and time left) while people appear as they are found.

- **Detect → align → recognise → group.** A small detector (SCRFD) finds
  faces, each is straightened, and a recognition model (ArcFace, `w600k_r50`)
  turns it into a 512-number fingerprint. Faces are grouped by comparing
  fingerprints. Blurry, tiny or turned-away faces never start a person; they
  can only join one that already exists.
- **Faces tab.** A grid of the people found, most photographed first. Open a
  person to see all their photos; rename them; hide people you don't want
  listed.
- **Fixing mistakes.** *Review faces* takes out a face that isn't them.
  *Same person as someone else* merges two groups, and Vector suggests likely
  merges (with a certainty level). Merges can be undone (**Undo a merge**), and
  **Split into two people** separates a person who was two people mixed up.
  Your edits stick: they are remembered for photos scanned later, and pairs you
  said are different are never suggested again.
- **Find photos by people.** Pick one or more people (*Find together* on the
  Faces tab, or long-press a person) and see the photos with them — with
  anyone, on their own, any of them, plus others, or only that group. From the
  results you can add or remove people.
- **Teaser on Search.** When the search box is idle, the people found so far
  sit beside your collections.
- **Tap a face in a photo.** In the full-screen viewer, recognised faces can be
  tapped: a morphing, glowing outline draws itself round the head and a small
  card shows who it is — tap it to open that person. A photo the background
  scan hasn't reached yet (or has only partly recognised) is scanned the moment
  you open it, with a quiet glow and live progress ("Found 12 faces ·
  identifying"), and is then marked complete so it isn't looked at again.

The recognition pipeline is model-independent: the detector and the recognition
model are described by their own specs, so either can be swapped without code
changes. A tuning step times the model on your phone (threads, batching,
hardware acceleration) and picks what is fastest.

The Flutter UI talks to a native Android layer that runs CLIP (vision +
text towers) via PyTorch Mobile, the face models via ONNX Runtime, and stores
embeddings and faces in small on-device stores (a binary store for CLIP, SQLite
for faces).

## Status

Android only, for now (minimum Android 7.0 / API 24).

## Building it yourself

Two sets of model weights are downloaded once on first launch — neither is
bundled in the app or the repo:

- **Search** — the CLIP weights (~575 MB).
- **People** — the face recognition model (~166 MB). The small face detector
  (SCRFD, ~3 MB) is bundled with the app.

The setup screen downloads both with one button, with speed, time left and
resume. Both can be removed again from Settings, which returns you to the
setup screen. See [model_host/README.md](model_host/README.md) for testing the
download flow locally (including the face model's checksum and how it is
published), or `android/app/build.gradle.kts` for where the release build
points to.

```bash
flutter pub get
flutter run
```

To watch the face scan's timing on a device:

```bash
adb logcat -s FaceScanner FaceTuner
```

## License

MIT — see [LICENSE](LICENSE).

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
them into people. It runs along with indexing (every so many photos Vector
finds their faces before it carries on), or from **Sync faces** on the People
tab; it never starts by itself. It can be paused and resumed, and people appear
as they are found.

- **Detect → align → recognise → group.** A small detector (SCRFD) finds
  faces, each is straightened, and a small recognition model (MobileFaceNet,
  `w600k_mbf`, ~13 MB) turns it into a 512-number fingerprint. Faces are grouped by comparing
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
- **Videos too.** After the photos, the scan goes through your videos: it looks at
  frames spread through each one (fast / balanced / thorough in the face options),
  links a face across neighbouring frames into one track and recognises only the best
  one or two faces of each track, so a clip costs a handful of recognitions, not
  hundreds. Faces in video must be clearer than in photos (motion blur), a small
  picture of each kept face is saved, and a video counts as one item however many frames
  someone is in. People's pages and *Find together* mix photos and videos; a video opens
  at the moment the person shows up. In the video viewer, the people found are a row of
  faces above the playback bar: tap one to jump to where they appear (and see those
  moments on the bar), tap again for their next appearance. It can be switched off in the
  face options.
- **Tap a face in a photo.** In the full-screen viewer, recognised faces can be
  tapped: a morphing, glowing outline draws itself round the head and a small
  card shows who it is — tap it to open that person. A photo the background
  scan hasn't reached yet (or has only partly recognised) is scanned the moment
  you open it, with a quiet glow and live progress ("Found 12 faces ·
  identifying"), and is then marked complete so it isn't looked at again.
- **Scan a video from its viewer.** A video the background scan hasn't reached has a
  "find people" button in the top bar. Tapping it scans that video while it plays and
  everything else keeps working: the same quiet glow, with live progress ("Scanning frame 7
  of 20 · 5 faces"), and the people found appear as a row above the playback bar. Tapping the
  button again scans again and replaces the first result.
- **Tap a face in a paused video.** Pause a video (or scrub and let go): after a moment
  the frame on screen is looked at and every face that matches someone you know gets the
  same tappable outline as in a photo. This is looked up on the spot and stores nothing,
  so it works even before the background scan has reached the video.

The recognition pipeline is model-independent: the detector and the recognition
model are described by their own specs, so either can be swapped without code
changes. A tuning step times the model on your phone (threads, batching,
hardware acceleration) and picks what is fastest.

The Flutter UI talks to a native Android layer that runs CLIP (vision +
text towers) and the face models both via ONNX Runtime, and stores
embeddings and faces in small on-device stores (a binary store for CLIP, SQLite
for faces).

## Status

Android only, for now (minimum Android 7.0 / API 24).

## Building it yourself

One set of model weights is downloaded once on first launch — it is not
bundled in the app or the repo:

- **Search** — the CLIP weights (~575 MB).

The face models are part of the app (in `android/app/src/main/assets/`): the
face detector (SCRFD, ~3 MB) and the face recognition model (MobileFaceNet,
~13 MB).

The setup screen downloads the search models with one button, with speed, time
left and resume. They can be removed again from Settings, which returns you to
the setup screen. See [model_host/README.md](model_host/README.md) for testing
the download flow locally (including the checksums and how they are
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

# Collections - plan

Status: **agreed, v1 in progress.**

## 1. What it is

A **collection** is a named, live, on-device smart search. It has a display name and a query,
and the two are independent: search "dog", name it "Mittu".

- Comes from built-ins (shipped with the app) or from the user.
- **Live:** only the definition is stored. Membership is re-evaluated from the embedding index, so new scans appear automatically.
- Everything stays on device.

## 2. Data model

| Field | Notes |
|---|---|
| `id`, `name`, `emoji` | name is what the user sees |
| `kind` | `text` (v1), `photos` and `mixed` (v2) |
| `queryText` / `prompts[]` | built-ins use several prompt variants ("a photo of a dog", "a dog") and average their embeddings |
| `seedEmbedding` | averaged embedding of the example photos (v2) |
| `contentMode` | images / videos / both, carried over from the search filter |
| `sensitivity` | maps to the z-score threshold `k`; default per collection, exposed as strict/loose later |
| `excludedKeys[]` | items the user marked "not this" (v2) |
| `isBuiltIn`, `hidden`, `sortOrder`, `createdAt` | |
| `embeddingModelVersion` | cached embeddings are invalidated if the model is ever swapped |

Storage: new `collections` table in the existing SQLite database (`IndexedFolderDbHelper`).
Built-ins are defined **in code**, not as DB rows. The DB holds only user overrides (hidden, reordered,
sensitivity tweaks) and user-created collections, so app updates can improve the defaults without
overwriting anything the user changed.

## 3. Membership cutoff (decided): per-query z-score

CLIP always returns *something*, and raw similarity scores aren't comparable across queries. So
membership is decided by a **per-query z-score**: for each collection, compute how each item's score
compares to that query's mean and standard deviation across the whole library, and keep items above
`mean + k * sigma`.

- Self-calibrating per query, no hand-tuned absolute thresholds.
- Cheap: mean/sigma come from the same single pass as the scoring.
- `k` defaults to about 3 and is tuned per built-in on a real library. It is later exposed as a hidden strict/loose control.
- Optional refinement for confusable built-ins (e.g. pets vs wildlife): a zero-shot label-margin check against the label set.
- Videos: already de-duplicated per video, so a video counts once by its best frame.

## 4. Decided features

**Built-ins (14, vibes included, not a separate feature):**
Pets, Flowers, Beach, Food, Documents, Screenshots, Selfies, Collage,
Golden hour, Neon night, Cozy, Minimal, Rainy, Road trip.

**Photo-seeded collections (v2):** pick a few example photos; the collection searches by their
averaged embedding. Works better than text for "my dog". Copy says "looks like", not "is": CLIP
finds similar-looking subjects, it cannot identify one individual.

**Exclude (v2):** long-press a wrong result, choose "not this"; the collection remembers it.

## 5. Creation and editing flows (decided, aim for 3 taps or fewer)

- **From a search:** once results show, a bookmark / "Save as collection" chip sits next to the
  filter button. It opens a small sheet: name (pre-filled with the query), an emoji row, Save.
  Confirmation reads "Saved · View".
- **From the Collections page (v2):** "+ New" opens a sheet with a query box and a live preview
  strip of 4-6 thumbnails that updates as you type (debounced), so you see what you'll get before
  saving. "Add example photos" is the photo-seeding option.
- **Edit:** long-press a card for rename, change query, change emoji, hide, delete.
  Built-ins can only be hidden, with a "restore" option.

## 6. Placement - PENDING DECISION

What other apps do (researched):

- **Google Photos:** simplified its Search tab into a text-first list with "Suggestions", and moved the
  browsable groups (People & pets, Places, Documents, Albums, ...) into a dedicated **Collections tab**
  that replaced "Library". ([Android Authority](https://www.androidauthority.com/google-photos-collections-redesign-apk-teardown-3660010/), [9to5Google](https://9to5google.com/2025/03/23/year-long-google-photos-redesign/))
- **Apple Photos:** iOS 18 removed tabs and put everything in one scrolling Library with a Collections
  section (Recent Days, People & Pets, Albums, ...), with "Customize & Reorder" to hide and reorder
  sections. After user backlash, **iOS 26 brought tabs back.** ([TechCrunch](https://techcrunch.com/2025/06/09/after-user-backlash-apple-brings-back-tabs-to-the-photos-app-in-ios-26/), [MacRumors](https://www.macrumors.com/how-to/ios-customize-reorder-photos-app/))

Takeaways:

1. Both ended up with collections as a real destination (a tab), not something hidden in an empty state or one long scroll.
2. Both let the user hide and reorder sections, which matches our edit flow.
3. Search stays text-first; a light set of shortcuts on it is fine.

Options for our app (currently: Search tab, Library tab):

| | Option | Pros | Cons |
|---|---|---|---|
| A | Third tab "Collections" only | permanent, discoverable, room for the "+ New" card and grid | search tab stays bare; three tabs |
| B | Strip on the Search tab's empty state + "See all" page | uses the empty space, no new tab | disappears once you type; discoverability depends on the empty state; the pattern both apps moved away from |
| C | **A + shortcuts:** third **Collections tab** (full grid, "+ New", customize) and a compact **row of pinned-collection chips** on the empty Search tab | mirrors where Google landed; permanent home plus quick access; empty search state gets purpose | slightly more to build; keep the chip row to about 6 |

Recommendation: **C.** Ship the tab first, add the chip row right after; neither blocks the other.

**Decision: C.** Collections tab first, then the pinned-chip row on the empty Search tab (max ~6).

## 7. Technical outline

- **Text embeddings:** tokenization is on the Dart side (`ClipTokenizer`), so Dart tokenizes each prompt,
  native `encodeText` embeds it, Dart averages the variants and caches the result in the DB
  (tied to `embeddingModelVersion`).
- **One-pass scoring:** a new native call takes all collection embeddings and returns, per collection, the
  member count, the z-score stats and the top few covers, in one read of the store. It runs on scan
  completion and on first open, and the result is cached until the index changes.
- **Collection view:** reuses the existing results grid (and the viewer, zoom, "why this matched"). The
  header adds emoji, name, count, edit and "search with this". Loads the full member list, not top-K.
- **Live preview (v2):** the same scoring on a single query, run on a debounced timer.
- **Edge cases:** empty collection ("nothing yet, scan more"), counts updating during a scan, duplicate
  names, hidden built-in restore, a deleted example photo in a photo-seeded collection.

## 7b. As built (v1)

- Cached query embeddings live in SharedPreferences (keyed by collection id + prompt signature + model version), not a DB blob.
- The Collections page has a basic "New collection" (query + name + emoji); the live preview strip is still v2.
- Save-from-search is a bookmark button inside the search bar, shown once a text search has results.
- Members are capped at 200 per collection view; thumbnails fill in progressively.
- Per-collection sensitivity values in `default_collections.dart` are starting points, untuned.
- Every collection (built-in or yours) can be edited, hidden or deleted; deleting a built-in just takes it off the list until Settings > "Restore default collections".
- Covers rotate daily through a collection's top 6 matches. Settings holds "Resync collections".
- Photo-seeded collections shipped ahead of v2: saved from any image search (bookmark in the search bar); the photo's embedding is stored in the row. "Not this" exclusion and "Add example photos" are still to do.

## 8. Phasing

1. **v1:** ~14 built-ins with tuned cutoffs, the collection UI per the placement decision, save-a-search-as-collection, rename / hide / delete.
2. **v2:** photo-seeded collections, exclude, creating from the Collections page with live preview.
3. **v3:** suggested collections from clustering, negative terms ("dogs but not indoors"), pinning to the Android home screen.

## 9. Known risks

- Quality is limited by CLIP ViT-B/32. Beach and pets will be strong; abstract ones (Collage, Minimal, Cozy) will be uneven. `k` needs tuning on real data, and the DataComp model upgrade would lift all of them.
- Individual pet or person identity is not something CLIP can do; photo-seeding narrows results but doesn't identify.

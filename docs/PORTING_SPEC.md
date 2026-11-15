# Immich Swipe: Swift porting spec

Derived from the Android source at `reference/immich-swipe-apk` (commit `7515587`, v4.4.0).
Paths below are relative to `app/src/main/java/com/markvoronin/immichswipe/`.

Scope: API surface, data models, swipe and decision logic, settings. The duplicates screen
(face-based "best shot" analysis), reminders UI, and tutorials are only summarised at the end.

---

## 1. API

### 1.1 Transport

| Concern | Android behaviour | Source |
|---|---|---|
| Base URL | User-entered server URL, trailing `/` added; every path is prefixed `api/` | `data/api/RetrofitFactory.kt` |
| Auth | Header `x-api-key: <key>` on every request, media included | `RetrofitFactory.kt`, `core/net/ImmichAuthInterceptor.kt` |
| Login check | `GET /api/users/me` with the entered key; success = logged in, the returned `id` becomes `userId` | `data/repository/AuthRepository.kt` |
| Retry | Up to 3 attempts, backoff 500 ms, 1 s. Retries I/O errors and HTTP 429/502/503/504. Only replay-safe requests: GET/HEAD/OPTIONS/PUT/DELETE, and POST only for `/api/search/*` | `data/api/RetryInterceptor.kt` |
| Connection status | 2xx → online. 401/403 → auth error. 502/503/504 → unavailable. Other 5xx → unexpected. DNS failure → offline. Timeout → issues. Other I/O → no internet. Cancellations are ignored | `RetrofitFactory.kt` |
| Insecure URL warning | `http://` to a public host needs explicit confirmation. Private = `localhost`, single-label names, `.local .lan .home.arpa .internal .localdomain .ts.net`, 10/8, 127/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, IPv6 `::1`, `fc..`/`fd..`, `fe8.`–`feb.` | `core/UrlPolicy.kt` (tests in `app/src/test/.../UrlPolicyTest.kt`) |

### 1.2 JSON endpoints

OpenAPI `operationId`s below were checked against Immich's published spec
(`open-api/immich-openapi-specs.json`). With Swift OpenAPI Generator these become the method
names on the generated `Client`.

| # | Method and path | operationId | Request | Response | Used for |
|---|---|---|---|---|---|
| 1 | `GET /users/me` | `getMyUser` | – | `UserAdminResponseDto` | Login check, account info, storage quota |
| 2 | `GET /albums` | `getAllAlbums` | – | `[AlbumResponseDto]` | Home album list, "add to album" picker |
| 3 | `GET /albums?assetId={id}` | `getAllAlbums` | query `assetId` | `[AlbumResponseDto]` | Albums containing the current asset (metadata panel) |
| 4 | `GET /albums/{id}` | `getAlbumInfo` | – | `AlbumResponseDto` | Album contents, see note A |
| 5 | `POST /albums` | `createAlbum` | `CreateAlbumDto {albumName, description?, assetIds?}` | `AlbumResponseDto` | Create album from the picker |
| 6 | `PUT /albums/{id}/assets` | `addAssetsToAlbum` | `BulkIdsDto {ids}` | `[BulkIdResponseDto]` | Add to album |
| 7 | `DELETE /albums/{id}/assets` (with body) | `removeAssetFromAlbum` | `BulkIdsDto {ids}` | `[BulkIdResponseDto]` | SKIP album only (feature disabled) |
| 8 | `GET /duplicates` | `getAssetDuplicates` | – | `[DuplicateResponseDto]` | "Duplicates" virtual album and duplicates screen |
| 9 | `POST /search/metadata` | `searchAssets` | `MetadataSearchDto` | `SearchResponseDto` | Paged asset listing, 500 per page |
| 10 | `POST /search/statistics` | `searchAssetStatistics` | `StatisticsSearchDto` | `{total}` | Accurate totals and album counts |
| 11 | `GET /assets/{id}` | `getAssetInfo` | – | `AssetResponseDto` | Full detail (EXIF, size) for the current card |
| 12 | `DELETE /assets` (with body) | `deleteAssets` | `AssetBulkDeleteDto {ids, force:false}` | 204 | DELETE decisions. `force:false` sends them to the Immich trash |
| 13 | `PUT /assets` | `updateAssets` | `AssetBulkUpdateDto {ids, isFavorite?, visibility?}` | 204 | Archive, lock, favourite. Chunked by 500 ids |
| 14 | `PUT /assets/{id}/edits` | `editAsset` | `AssetEditsCreateDto {edits:[{action:"rotate", parameters:{angle}}]}` | `AssetEditsResponseDto` | Rotation, `angle` in {90,180,270} |

`MetadataSearchDto` fields the app sends: `albumIds`, `isNotInAlbum`, `visibility`
(`timeline|archive|hidden|locked`), `type`, `isFavorite`, `withExif:true`, `order` (`asc|desc`),
`page` (1-based), `size` (500). Paging follows `assets.nextPage` (string, `nil` = last page).

Note A, album contents: the Android code reads `assets` from `GET /albums/{id}`. Current
`AlbumResponseDto` has no `assets` property. On Android this throws (Gson leaves the field
`null`), which drops it into the fallback path, `POST /search/metadata` with `albumIds:[id]`.
**In Swift, skip `getAlbumInfo` and go straight to search.**

### 1.3 Media URLs

These are hit directly by the image and video loaders, not through Retrofit. They also need the
`x-api-key` header, so `AsyncImage` and a plain `AVPlayer(url:)` won't work as-is. Use a
`URLSession`-backed image loader, and an `AVURLAsset` with
`AVURLAssetHTTPHeaderFieldsKey` (or a resource loader).

| Purpose | URL | operationId |
|---|---|---|
| Card and fullscreen image | `/api/assets/{id}/thumbnail?size=preview&edited=true` | `viewAsset` |
| Timeline strip | `/api/assets/{id}/thumbnail?size=thumbnail&edited=true` | `viewAsset` |
| Duplicates and summary grids | `/api/assets/{id}/thumbnail?size=preview` | `viewAsset` |
| GIFs, "full resolution" toggle, download, share | `/api/assets/{id}/original` | `downloadAsset` |
| Video | `/api/assets/{id}/video/playback` | `playAssetVideo` |
| Avatar | `/api/users/{userId}/profile-image` | `getProfileImage` |

Android also appends `format=WEBP`. That isn't a spec parameter and can be dropped. `size`
accepts `original|fullsize|preview|thumbnail`. The legacy fallback `/api/asset/file/{id}` (very
old Immich) can also be dropped.

### 1.4 Generating the client from OpenAPI

Recommended: [apple/swift-openapi-generator](https://github.com/apple/swift-openapi-generator)
with `swift-openapi-runtime` and `swift-openapi-urlsession`, as a build plugin.

- **Pin the spec to a release tag**, not `main`. `main` is currently `3.4.0-rc.0` and the latest
  stable tag is `v3.3.5`. Download
  `https://raw.githubusercontent.com/immich-app/immich/v3.3.5/open-api/immich-openapi-specs.json`
  (or whatever your server runs) and commit it as `openapi.json`.
- **Filter it.** The full spec is about 1 MB. Generating all of it slows builds a lot.
  `openapi-generator-config.yaml`:

  ```yaml
  generate:
    - types
    - client
  accessModifier: internal
  filter:
    operations:
      - getMyUser
      - getAllAlbums
      - getAlbumInfo
      - createAlbum
      - addAssetsToAlbum
      - removeAssetFromAlbum
      - getAssetDuplicates
      - searchAssets
      - searchAssetStatistics
      - getAssetInfo
      - deleteAssets
      - updateAssets
      - editAsset
  ```

  Media endpoints are left out on purpose. Build those URLs by hand (§1.3) so the image cache and
  `AVPlayer` can use them.
- The spec's `servers` entry is the relative `/api`. Pass
  `serverURL: baseURL.appending(path: "api")` to `Client`.
- Auth: add a `ClientMiddleware` that sets `x-api-key`. Put retry (§1.1) and connection-status
  reporting in middlewares too.

---

## 2. Data models

### 2.1 Domain models (`domain/model/`)

**Asset** (subset of `AssetResponseDto`)

| Field | Type | Notes |
|---|---|---|
| `id` | String (UUID) | |
| `ownerId` | String | |
| `fileCreatedAt` | String (ISO-8601) | |
| `type` | `IMAGE` / `VIDEO` (spec also has `AUDIO`, `OTHER`) | |
| `duration` | String? | |
| `isFavorite`, `isArchived`, `isTrashed` | Bool | |
| `visibility` | `archive/timeline/hidden/locked` | Not read on Android, see below |
| `originalFileName` | String? | |
| `checksum` | String? (base64 SHA-1) | |
| `isEdited` | Bool | |
| `exifInfo` | ExifInfo? | |

Derived:
- `effectiveDate = exifInfo.dateTimeOriginal` if non-blank, else `fileCreatedAt`. All date sorting
  uses this and compares it as a **string**.
- `isGif = originalFileName` ends with `.gif` (case-insensitive).

Fields Android declares but the server never sends: `isLocked`, `extension`, `rotation`. They
always default to false, nil and 0. In Swift, derive `isLocked` from `visibility == .locked`, and
treat server rotation as 0.

**ExifInfo**: `fileSizeInByte` (Int64), `exifImageWidth`, `exifImageHeight`, `dateTimeOriginal`,
`orientation`, `projectionType`.

**Album**: `id`, `albumName`, `description?`, `assetCount`, `albumThumbnailAssetId?`.

Virtual albums are client-side ids that look like real albums in the home list:

| id | Shows | Source |
|---|---|---|
| `virtual_all_assets` | All assets | search with `visibility:"timeline"` |
| `virtual_orphans` | Assets in no album | search with `isNotInAlbum:true, visibility:"timeline"` |
| `virtual_duplicates` | Duplicate clusters, flattened | `GET /duplicates` |

Duplicates ordering: clusters sorted by size desc, then total bytes desc. Within a cluster,
file size desc, then pixel count desc. Never cached.

`isVirtual` is also true for an album named `SKIP`. The whole SKIP feature is off
(`Album.IS_SKIP_FEATURE_ENABLED = false`). **Don't port it**, but hide any album named `SKIP`.

**User**: `id`, `email`, `name?`, `profileImagePath?`, `avatarColor?`, `quotaUsageInBytes?`,
`quotaSizeInBytes?`.

**AccountSummary** (multi-account switcher): `userId`, `baseUrl`, `userName?`, `userEmail`,
`avatarColor?`, `lastActive`. It never holds the API key.

**SessionConfig**: `baseUrl`, `apiKey`, `userId`.

### 2.2 Local persistence (Room v13 → SwiftData or SQLite)

Schema reference: `app/schemas/.../AppDatabase/13.json`. Migrations don't need porting. Start
fresh.

**`swipe_decisions`**, PK `(assetId, userId)`, upsert (REPLACE)

| Column | Type | Meaning |
|---|---|---|
| assetId | String | |
| albumId | String | Album the decision was made in (a real or virtual id) |
| userId | String | |
| decision | String | `KEEP`, `DELETE`, `ARCHIVE`, `LOCK` (`SKIP` is legacy) |
| fileSize | Int64? | Snapshot used for "space saved" totals |
| createdAt | Int64 ms | |
| isSynced | Bool | Server step done |
| wasSyncedSkip | Bool | Legacy, ignore |

A decision belongs to an **asset**, not an album. "Decisions for album X" means rows with
`albumId == X` **or** whose asset is cached under album X in `album_assets`. So deciding on a
photo in "All" also shows it as decided inside every real album that contains it.

**`album_assets`** (listing cache), PK `(albumId, assetId, userId)`. Columns: `type`,
`fileCreatedAt` (stores `effectiveDate`), `originalFileName`, `fileSizeInBytes`, `imageWidth`,
`imageHeight`, `rotation` (local only).

**`sync_history`**: autoincrement `id`, `userId`, `timestamp`, `deletedCount`, `bytesSaved`,
`keptCount`, `archivedCount`, `lockedCount`, `skippedCount` (always 0). One row per successful
"apply changes".

**`user_accounts`**: PK `userId`, `baseUrl`, `apiKey` (encrypted), `userName?`, `userEmail`,
`avatarColor?`, `lastActive`. On iOS, keep API keys in the **Keychain**, keyed by `userId`, not
in the database.

Aggregate queries the home screen needs (`data/local/dao/SwipeDecisionDao.kt`):
- Per album: distinct decided assets and unsynced count, excluding SKIP.
- Global: distinct decided assets, and distinct unsynced assets.
- Unsynced KEEP and ARCHIVE counts.

Export and import (`data/local/model/DatabaseExport.kt`, `SwipeDecisionRepository.importData`)
covers decisions plus history, scoped per user. Imported history ids are reset, rows matching an
existing `(userId, timestamp)` are skipped, and SKIP rows are dropped.

---

## 3. Swipe and decision logic

### 3.1 Decisions

`enum SwipeDecision { KEEP, DELETE, ARCHIVE, LOCK, SKIP }`. Drop SKIP.

| Input | Decision |
|---|---|
| Swipe right / Keep button / tap right 30% (tap-to-swipe on) | KEEP |
| Swipe left / Delete button / tap left 30% (tap-to-swipe on) | DELETE |
| Archive button | ARCHIVE |
| Lock button | LOCK |
| Favourite while `autoNextOnFav` is on (only when turning it **on**, current card only) | KEEP |
| Pull card down (only if there's something to undo) | Undo |

Decisions are optimistic. In-memory state updates first, then the row is written
(`isSynced = false`). **Nothing touches the server until "Apply changes".**

### 3.2 Card gesture (`feature/swipe/components/SwipeCard.kt`)

Android thresholds are in **pixels**. Convert to points: about ÷2.75 on a typical Android
density, so 250 px ≈ 90 pt and 1000 px/s ≈ 360 pt/s. Tune by feel.

- **Direction lock** once moved > 12 px on either axis:
  - Mostly upward (`|dy| > |dx|` and `dy < 0`), or the metadata panel is already > 10% open
    and `|dy| > 5` → **metadata panel drag**.
  - Anything else → **free drag**. The card follows the finger in x. In y it only moves down,
    and only at 0.2× resistance when there's nothing to undo. Card rotation = `x / 40` degrees.
- **Release from free drag**, checked in this order:
  1. Undo: `y > |x|` and (`y > 250` or `vy > 1000`) and undo is possible → animate down, undo.
  2. Keep: `x > 250`, or (`vx > 1000` and `x ≥ -50`) → fly right (150 ms), KEEP.
  3. Delete: `x < -250`, or (`vx < -1000` and `x ≤ 50`) → fly left, DELETE.
  4. Otherwise spring back.
- **Metadata panel release**: open if `vy < -500`, close if `vy > 500`, else open when
  progress ≥ 0.4. Over-pulling past fully open stretches up to 15% with resistance.
- **Tap**: closes the metadata panel if open. Otherwise, with tap-to-swipe on, left 30% DELETE,
  right 30% KEEP, middle toggles mute. With it off, any tap toggles mute.
- **Double tap**: when enabled, `FULLSCREEN` (default) or `FAVORITE`.
- **Long press** (500 ms) is a hold: it pauses video, and releasing does nothing.

### 3.3 Deck state (`feature/swipe/SwipeUiState.kt`, `SwipeViewModel.kt`)

State: `assets` (sorted work pile), `currentIndex`, `decisions: [assetId: Decision]`,
`history: [assetId]` (undo stack), `assetSizes`, `localFavorites`, `localRotations`,
`remoteTotalCount`.

- **Next card**: first index **after** `currentIndex` whose asset has no decision. If there's
  none, `currentIndex = assets.count`, which is the "done" state.
- **Jump to first unprocessed**: on first load, when the sort changes, after reset, and after
  apply. Otherwise a re-sort keeps the current asset if it's still undecided.
- **Undo**: pop the last id from `history`, remove its decision (memory and DB), move
  `currentIndex` to that asset. `undoSpecificDecision(id)` removes any one decision from the
  summary list without moving the deck.
- **Reset album**: delete all decisions for the album (§2.2 union rule) and for every asset in
  the pile, clear history, jump to first.
- **On launch**: rebuild `history` from DB rows with `isSynced == false`, so you can undo
  decisions made before the app was closed.
- **Leaving a card** clears full resolution unless `keepFullResolution` is on.
- **Detail fetch**: on each card change call `getAssetInfo` and merge in EXIF and size.
- **Favourite**: toggles `localFavorites[id]`, server sync waits for apply.
- **Rotate**: `(current + 90) % 360` into `localRotations`. Saved to the local cache right away,
  synced to the server on apply.
- **Add to album**: immediate server call (not deferred). On success, if the deck is "Orphans",
  the asset leaves the pile.
- **Bulk mode** (delete or keep): select a set, then apply one decision to all of them. The next
  card is the first undecided index after the last selected one.

Counters: processed = `decisions.count`. Remaining = `max(total - processed, 0)`. Kept, deleted,
archived and locked counts. Sizes come from `assetSizes`, then `exifInfo.fileSizeInByte`, else 0.
Progress = `min(processed, total) / total`. `isRemainingEstimated` is true while some undecided
asset has an unknown size or not every page has loaded. For "All" and "Duplicates" with a known
quota, the quota is used instead.

### 3.4 Sorting (`data/repository/AssetRepository.applySort`)

11 orders. The default is `CHRONOLOGICAL_DESC`. They're grouped into Time, Size and Type in the
UI.

| SortOrder | Rule |
|---|---|
| `CHRONOLOGICAL_DESC` / `_ASC` | `effectiveDate` string desc / asc |
| `SHUFFLED` | ascending `shuffleHash(id, seed)` |
| `SIZE_DESC` / `_ASC` | file size, nil = 0 |
| `TYPE_VIDEO_FIRST` / `TYPE_PHOTO_FIRST` | target type first, then date desc |
| `TYPE_VIDEO_FIRST_ASC` / `TYPE_PHOTO_FIRST_ASC` | target type first, then date asc |
| `TYPE_VIDEO_FIRST_SHUFFLED` / `TYPE_PHOTO_FIRST_SHUFFLED` | target type first, each group shuffled |

`seed` is the app-launch time in ms, so the shuffle is stable within a session and changes on
relaunch. Port the hash exactly, with wrapping 64-bit arithmetic:

```swift
func shuffleHash(_ id: String, seed: Int64) -> Int64 {
    var h = seed ^ 0x5DEECE66D
    for unit in id.utf16 { h = h &* 31 &+ Int64(unit) }
    func mix(_ x: Int64) -> Int64 { x ^ Int64(bitPattern: UInt64(bitPattern: x) >> 33) }
    h = mix(h); h = h &* Int64(bitPattern: 0xff51afd7ed558ccd)
    h = mix(h); h = h &* Int64(bitPattern: 0xc4ceb9fe1a85ec53)
    return mix(h)
}
```

The SQL shuffle in `AlbumAssetDao` is a different formula, but it only orders the initial cache
read and gets re-sorted in memory. Ignore it.

### 3.5 Loading and caching (`AssetRepository.getAssetsByAlbum`)

A stream of `AssetBatch { assets, total, isLocalCache, isSyncing }`:

1. Emit cached `album_assets` rows right away (`isLocalCache`, `isSyncing`).
2. Duplicates: fetch `/duplicates`, emit once, done.
3. Get `total` from `/search/statistics` (more reliable than the search total), then fetch
   page 1 (500).
4. Single page: sync the cache (drop stale rows, insert new ones), emit, done.
5. Several pages: the cache counts as complete when its count equals the total and page 1 has no
   new or stale ids. If complete, emit the cache and stop.
6. Otherwise page through `nextPage`. After each page, insert new rows and emit the growing list.
   Purge stale cached rows **only after a full pass**, then emit a final batch. The safety cap is
   500,000 assets.
7. Ids deleted or locked while a sync runs are filtered out of every later batch.
8. Abort if the active user changes mid-sync.

While paging, a decision for an asset missing from the current batch is kept, because the batch
is partial.

Album counts on the home screen: when archived assets are excluded, each album's count is
`assetCount - statistics(albumIds:[id], visibility:"archive").total`, with 15 requests in
parallel. "All" and "Orphans" counts come from statistics, and include archive when that's on.

### 3.6 Apply changes (`domain/usecase/ApplySwipeDecisionsUseCase.kt`)

Each step runs on its own. A failed step is recorded, its ids stay pending (unsynced), and the
remaining steps still run.

| Order | Step | Server call | On success, locally |
|---|---|---|---|
| 1 | DELETE | `deleteAssets(ids, force:false)` | Delete cache rows **and decision rows** |
| 2 | ARCHIVE | `updateAssets(ids, visibility:"archive")` | Mark synced |
| 3 | LOCK | `updateAssets(ids, visibility:"locked")` | Delete cache rows and decision rows |
| 4 | KEEP | none | Mark synced |
| 5 | Rotation | per asset: `editAsset(id, rotate angle)` when angle ≠ 0 | Cache `rotation` |
| 6 | Favourites | `updateAssets(addIds, isFavorite:true)`, then `(removeIds, false)` | Failed ids stay in `localFavorites` for retry |
| 7 | History | one `sync_history` row with counts that actually applied | |

History counting: deleted count and bytes only if DELETE succeeded, same for archive and lock.
Kept is only counted if **all three** server steps succeeded, so a retry can't count it twice.
No row is written if nothing applied.

Local cleanup after a server step is best-effort. Its failure is logged but doesn't turn the
server success into a failure.

After apply, in the UI:
- Deleted and locked assets leave the pile, and `remoteTotalCount` drops by that many.
- KEEP and ARCHIVE decisions stay (synced), so those cards still count as processed.
- `history` is cleared, so you can't undo past an apply.
- Jump to the first unprocessed card.
- Stay in "syncing" until any in-flight paging finishes. Then show the success animation (2 s),
  or a "some changes failed" message.

Local device deletion (`syncLocalDeletion`, default off): matches deleted assets to on-device
media by file name plus size, then asks the OS to delete or trash them. On iOS, use PhotoKit:
match with `PHAssetResource.originalFilename` and the `fileSize` resource value, then
`PHAssetChangeRequest.deleteAssets`. iOS always confirms and always moves to Recently Deleted,
so the trash-vs-delete choice doesn't apply.

### 3.7 Android quirks: don't copy these

1. **Rotating back to 0° never reaches the server.** `syncAssetRotationToServer` returns early on
   0. Send an empty-edits reset instead (check what the server accepts).
2. **`includeArchived` is inconsistent.** It defaults to `true` with no setter, so home counts
   include archived. The swipe deck always fetches `visibility:"timeline"` for All and Orphans.
   Pick one rule.
3. `trash_local_deletion` and `default_card_display_mode` have getters but no UI or setter.
4. The DataStore key `card_display_icon_pos` / `show_card_display_icon` actually controls the
   **rotation** button.

---

## 4. Settings

The Android store is the `session` DataStore (`data/datastore/SessionDataStore.kt`). On iOS:
`@AppStorage` / `UserDefaults` for preferences, **Keychain** for the API key. Enums are stored by
their case name.

### 4.1 Session and accounts

| Key | Type | Default | Notes |
|---|---|---|---|
| `base_url` | String | – | Active server |
| `api_key` | String | – | Encrypted on Android → Keychain on iOS |
| `user_id` | String | – | Active user. A session exists only when all three are set |
| `saved_server_urls` | Set<String> | [] | Trimmed, no trailing `/`. Merged with account URLs, sorted, for login suggestions |

### 4.2 Swipe-card buttons

`IconPosition` = `TOP_LEFT | TOP_RIGHT | BOTTOM_LEFT | BOTTOM_RIGHT`.

| Button | Visible key (default) | Position key (default) |
|---|---|---|
| Fullscreen | `show_fullscreen_icon` (true) | `fullscreen_icon_pos` (TOP_RIGHT) |
| Open in Immich | `show_immich_icon` (false) | `immich_icon_pos` (BOTTOM_LEFT) |
| Rotate | `show_card_display_icon` (true) | `card_display_icon_pos` (TOP_LEFT) |
| Mute | `show_mute_icon` (true) | `mute_icon_pos` (BOTTOM_RIGHT) |
| Download | `show_download_icon` (true) | `download_icon_pos` (BOTTOM_LEFT) |
| Share | `show_share_icon` (false) | `share_icon_pos` (BOTTOM_RIGHT) |
| Full resolution | `show_full_size_icon` (true) | `full_size_icon_pos` (BOTTOM_RIGHT) |
| Favourite | `show_favorite` (true) | – |
| Archive | `show_archive` (true) | – |
| Lock | `show_lock` (false) | – |
| Add to album | `show_add_to_album` (true) | – |
| Keep/Delete buttons | `show_swipe_buttons` (false) | – |

`button_stack_orientation`: `VERTICAL` (default) or `HORIZONTAL`, the layout of buttons sharing
a corner.

### 4.3 Behaviour

| Key | Type | Default | Effect |
|---|---|---|---|
| `sort_order` | SortOrder | `CHRONOLOGICAL_DESC` | §3.4, set from the swipe screen's sort menu |
| `audio_focus` | `PAUSE_OTHERS` / `IGNORE` | `PAUSE_OTHERS` | Whether video pauses other audio. iOS: `AVAudioSession` category `.playback` vs `.ambient` |
| `auto_next_on_fav` | Bool | false | Favouriting also keeps and advances |
| `tap_to_swipe` | Bool | false | Edge taps decide (§3.2) |
| `double_tap_enabled` | Bool | true | |
| `double_tap_action` | `FULLSCREEN` / `FAVORITE` | `FULLSCREEN` | |
| `keep_full_resolution` | Bool | false | The full-resolution toggle survives card changes |
| `immich_open_mode` | `APP` / `WEB` | `APP` | "Open in Immich" target |
| `immich_long_press_web` | Bool | true | Long-press the Immich button to open the web version |
| `sync_local_deletion` | Bool | false | §3.6 |
| `trash_local_deletion` | Bool | true | No UI. Not applicable on iOS |
| `include_archived` | Bool | true | No UI. See quirk 2 |
| `default_card_display_mode` | `FIT` / `FILL` | `FIT` | No UI |
| `default_layout_grid` | Bool | false | Home list vs grid |

### 4.4 Appearance, reminders, onboarding

| Key | Type | Default | Notes |
|---|---|---|---|
| `theme_mode` | `SYSTEM` / `LIGHT` / `DARK` | `SYSTEM` | `preferredColorScheme` |
| `dynamic_color` | Bool | true | Android Material You only, drop |
| `reminder_enabled` | Bool | false | Local notification nudging the user to sort |
| `reminder_interval` | `OFTEN` (7–14 d) / `RARELY` (21–35 d) / `CUSTOM` | `OFTEN` | Fires at a random day between min and max |
| `reminder_custom_min_days` / `_max_days` | Int64 | 3 / 7 | For `CUSTOM` |
| `has_completed_swipe_tutorial` | Bool | false on fresh install, true when upgrading with an account | Holds back paging until the tutorial is done |
| `has_completed_duplicates_tutorial` | Bool | same rule | |
| `skip_deep_analyze_confirmation` | Bool | false | Duplicates screen |
| `backup_warning_shown` | Bool | false | One-time warning before the first delete |
| `initial_install_processed` | Bool | – | Internal flag for the tutorial default rule |

Logging out clears the whole store.

---

## 5. Out of scope here (summary only)

- **Duplicates screen** (`feature/duplicates/`): per-cluster keep/delete choices,
  auto-select largest, and "best shot" scoring (sharpness, eyes open, smile from MediaPipe face
  landmarks, with tile-based "deep analyze" on originals). On iOS use the Vision framework:
  `VNDetectFaceLandmarksRequest`, `VNDetectFaceCaptureQualityRequest`.
- **Reminders** (`core/reminder/`): WorkManager → `UNUserNotificationCenter` with a calendar
  trigger.
- **Cache management** (`core/cache/`): video preloading and disk cache limits →
  `URLCache` / `AVAssetDownloadURLSession`.
- **Deep links** (`navigation/DeepLinkHandler.kt`).

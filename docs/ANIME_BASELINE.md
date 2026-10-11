# Anime Baseline

This baseline adds anime to the existing single-filesystem media workflow
without introducing another Sonarr instance or breaking hardlinks.

## Validated corrections

The implementation was checked against the current Sonarr v4 API, Recyclarr v8
schema/templates, Jellyfin API/source models, the Chapter Segments Provider
source, and Bazarr's current settings implementation.

- Sonarr v4 still uses `/api/v3`. Its root-folder, naming, and series resources
  support the required automation.
- `seriesType` is a per-series value. There is no reliable global switch that
  can classify arbitrary existing series as anime.
- Recyclarr's old `include: template:` syntax is obsolete. The repository was
  already using the current v8 `trash_id` profile model.
- Jellyfin backdrops are controlled by `TypeOptions[].ImageOptions`, not a
  top-level "Backdrop fetcher" switch. The Anime library sets the Series
  `Backdrop` limit to zero.
- Jellyfin user subtitle preferences have a supported API and are automated for
  the administrator used during bootstrap.
- Bazarr language-profile writes and most setting changes use a hidden,
  multipart internal endpoint. That is not treated as a stable automation
  contract in this baseline.

## Automated baseline

Run:

```bash
./stack.sh setup-data
source ./scripts/set-env.sh --include-tailscale
./stack.sh bootstrap
./stack.sh audit-anime
```

PowerShell:

```powershell
.\stack.ps1 setup-data
.\stack.ps1 env --include-tailscale
.\stack.ps1 bootstrap
.\stack.ps1 audit-anime
```

Bootstrap now performs these idempotent operations:

- creates `/data/media/anime` and `/data/media/anime-movies`;
- configures Sonarr's `/data/media/anime` root folder;
- configures an absolute-number token in `animeEpisodeFormat`;
- synchronizes the current Recyclarr v8 series and anime profiles;
- sets `seriesType=anime` for series already stored below
  `/data/media/anime/`;
- configures Seerr's anime override to use `/data/media/anime` and
  `[Anime] Remux-1080p`;
- creates a Jellyfin Shows library named `Anime`;
- disables new Series backdrop generation in that library; and
- sets the bootstrap administrator's Jellyfin subtitle preference to English
  with subtitle mode `Always`.

Jellyfin stores subtitle preferences per user. For additional household users,
the supported automation surface is `GET /Users/{userId}` followed by
`POST /Users/Configuration?userId={userId}` with the returned
`Configuration` object updated to `SubtitleLanguagePreference: eng` and
`SubtitleMode: Always`. Bootstrap does not overwrite every user's personal
preferences automatically.

`audit-anime` verifies the Sonarr root, absolute-number naming, root-based series
types, and Seerr anime root/profile.

## Existing series migration

Automation only changes a series to `seriesType=anime` when its path is already
under `/data/media/anime/`. This is a deliberate safety boundary: neither title
text nor metadata keywords are reliable enough to mass-edit arbitrary shows.

For existing anime still under `/data/media/tv`:

1. In Sonarr, use Series > Mass Editor.
2. Select only known anime.
3. Set Root Folder to `/data/media/anime`.
4. Set Series Type to `Anime`.
5. Allow Sonarr to move/rename files.
6. Run `audit-anime`.

For every first request through Seerr, confirm the resulting Sonarr series has
both the anime root and `seriesType=anime`. Seerr's metadata classification can
miss obscure or incorrectly tagged titles. If it misses, correct the series in
Sonarr; the next bootstrap/audit will preserve and verify that state.

## Bazarr

Bazarr remains an explicit operator step because its profile/settings write
surface is an undocumented internal form endpoint that upstream hides from its
OpenAPI document. Automating that endpoint would create a brittle upgrade
dependency.

Configure:

1. Languages > Language Profiles: create `Anime English`.
2. Add English and leave Forced disabled.
3. Assign the profile to anime series.
4. Settings > Subtitles: keep the embedded-subtitle parser enabled.
5. Enable automatic synchronization only after testing it against representative
   ASS releases.
6. Add several providers. Jimaku requires an API key.

The authoritative configuration is
`config/bazarr/config/config.yaml`. Current upstream keys include:

- `general.embedded_subtitles_parser`;
- `subsync.use_subsync`;
- `subsync.use_subsync_threshold`;
- `subsync.subsync_threshold`;
- `jimaku.api_key`;
- `jimaku.enable_name_search_fallback`;
- `jimaku.enable_archives_download`; and
- `jimaku.enable_ai_subs`.

Do not commit that file: it contains credentials and generated application
state. Language profiles should be maintained through the Bazarr UI until
Bazarr exposes a supported write API.

## Chapter-based segments

First inspect a representative file:

```bash
docker compose exec jellyfin ffprobe -v error -show_chapters \
  "/data/media/anime/<show>/<episode>.mkv"
```

If it contains correctly named opening/ending chapters:

1. Install `Chapter Segments Provider` from Jellyfin's official plugin catalog.
2. Restart Jellyfin.
3. Confirm the Anime library has that media-segment provider enabled.
4. Query `GET /ScheduledTasks` and locate the task whose `Name` is
   `Media Segment Scan`.
5. Trigger the discovered task ID with
   `POST /ScheduledTasks/Running/{taskId}`.

The scan is intentionally discovered by name instead of hard-coding an ID.
Plugin installation is not pinned here because plugin/Jellyfin compatibility is
version-specific and the repository does not yet maintain a tested plugin
release manifest.

Automatic skip behavior is client-specific. Segment detection alone does not
guarantee that every Jellyfin client will skip segments.

## Playback verification

ASS subtitle support depends on the client. After starting an anime episode,
open Jellyfin Dashboard > Activity and confirm `Direct Play`. If playback
transcodes specifically to burn subtitles, use a client that supports ASS and
embedded fonts natively. Hardware purchase recommendations are intentionally not
encoded into deployment automation.

## Deferred architecture

Shoko Server and Shokofin remain out of the baseline. They introduce AniDB
identity, another stateful service, and a different library-management model.
Evaluate them when library size and OVA/special mapping problems justify that
operational cost.

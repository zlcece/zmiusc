# Zmusic UI Redesign Design

## Goal

Upgrade the Zmusic home experience to a three-tab information architecture across phone, tablet, and desktop:

- Search
- Music
- Settings

The default tab is Music. The current product color direction can remain; this redesign focuses on structure, navigation, and responsive layout rather than a full palette replacement.

## Approved Direction

Use option A from the browser mockup:

- Phone, tablet, and desktop share the same top-level tabs.
- The app opens on the Music tab by default.
- A search component stays above tab content.
- The playback component stays below tab content.
- Desktop keeps higher information density, while mobile keeps the floating compact player style.
- Existing detail pages must not cover or hide the bottom playback area unless they are the dedicated full playback detail view.

## Layout

### Shared Shell

The main shell has three persistent regions:

1. Header and tab navigation.
2. Active tab content.
3. Playback bar or mobile floating mini player.

The current app bar source summary can remain on desktop, but it should not compete with the three main tabs. Source status, refresh, and settings entry should be folded into the new Music and Settings structure where appropriate.

### Mobile and Tablet

Mobile and tablet use a top tab strip inspired by the provided screenshots:

- Search icon tab.
- Music icon tab.
- Settings icon tab.

Below the tabs is a large rounded search field. The bottom player remains a compact floating bar; tapping it opens the playback detail page.

### Desktop

Desktop uses the same Search / Music / Settings tabs, but with a wider layout:

- Top tab controls can use text plus icons.
- The search component is centered or constrained to a comfortable width.
- The Music tab uses card/grid sections instead of a narrow mobile-only column.
- The bottom player stays fixed at the bottom and keeps desktop controls such as progress, queue, and volume.

## Tab Content

### Search Tab

The Search tab is for discovery. It contains:

- Latest albums.
- Recently played.
- Most played.
- Random albums.

The search field on this tab opens or updates the existing search results flow. Search results remain a separate page/state and must not cover the bottom playback component.

Data sources:

- Navidrome/Subsonic: use compatible API data when available, such as album list types for newest, recent, frequent, and random.
- Local source: derive available sections from local library data where practical. Sections with no data use clear empty states.

### Music Tab

The Music tab is the default landing tab. It contains:

- A source summary card showing the current source and song count.
- Function entries:
  - Songs
  - Favorites
  - Albums
  - Artists
  - Radio
  - My playlists
  - Public playlists

My playlists include local playlists for the current source and user-owned cloud playlists. Public playlists show shared cloud playlists. Local playlists continue to be source-scoped and should not appear when another source is active.

Album and artist browsing continues to open dedicated paginated pages. Selecting an album opens the album songs page rather than the search results page.

### Settings Tab

The Settings tab contains all current settings page functionality:

- Source settings.
- Theme settings.
- Cache settings.
- Custom logo/background and taskbar/tray icon settings where supported.
- Window close behavior where supported.
- Local playlist import/export controls where they currently belong.

Desktop-only settings remain hidden on mobile and tablet. Settings content must remain scrollable above the playback component.

## Navigation Behavior

- Default app launch state is the Music tab.
- Switching tabs does not stop playback.
- Search, settings, browse pages, playlist detail pages, and artist/album pages do not cover the bottom player.
- Playback detail remains a dedicated full view because it is intentionally focused on album art and lyrics.
- The current queue remains accessible from the playback component.

## Visual Direction

Keep the current Zmusic color direction unless a later request changes it:

- Existing green/dark glass style can remain.
- The provided blue reference is used for structure and rhythm, not as a required palette.
- Dark and light themes should keep icon contrast readable.
- Cards use translucent glass treatment without adding nested card clutter.

## Data and API Changes

Expected additions:

- Extend the library overview/discovery model to include discovery sections for latest albums, recently played, most played, and random albums.
- Add or reuse Subsonic-compatible endpoints for album list sections.
- Add favorite songs/albums support for the Favorites entry if not already surfaced.
- Add radio listing support if the selected source exposes radio data.
- Split playlists into My playlists and Public playlists while preserving local source scoping.

No import/export encryption change is part of this UI redesign.

## Testing

Add or update widget tests for:

- App opens on Music tab by default.
- Three top-level tabs are visible on desktop and mobile widths.
- Search component appears above active tab content.
- Bottom playback component remains visible on Search, Music, Settings, browse, and playlist pages.
- Music tab shows source summary and function entries.
- Search tab shows discovery sections.
- Settings tab hides desktop-only settings on non-desktop platforms.
- My playlists only show local playlists for the current source.

Run before completion:

- `.\.flutter-sdk\bin\flutter.bat analyze`
- `.\.flutter-sdk\bin\flutter.bat test`

## Out of Scope

- Full theme color replacement.
- Removing existing playback detail behavior.
- Packaging unless the user explicitly asks to package after implementation.
- Android/iOS release build unless explicitly requested.

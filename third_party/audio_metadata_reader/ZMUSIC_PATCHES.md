# Zmusic metadata changes

Vendored from pub.dev `audio_metadata_reader` 1.8.1 (upstream source and MIT
license retained). This copy is required because the published package does
not independently read/write album artists for every format editable in Zmusic.

Upstream archive: `https://pub.dev/api/archives/audio_metadata_reader-1.8.1.tar.gz`
SHA256: `66e8e216deab90008fa161c345e93c7c3cab28667042264976eb03865122a7b9`

- Add `setAlbumArtist` and preserve the separate album artist in MP3 (`TPE2`),
  MP4/M4A (`aART`) and WAV (embedded ID3 `TPE2`). FLAC already uses `ALBUMARTIST`.
- Read MP3/WAV track artist from `TPE1`, independently of the album artist.
- Reuse the ID3 writer to update WAV's embedded tag together with its common
  fields, preserving parsed ID3 fields and replacing existing ID3 chunks.
- Write ID3v2 for MP3 files carrying only ID3v1 (or no existing tag), since ID3v1
  cannot represent a separate album artist.
- Encode WAV INFO text as UTF-8 so saving Chinese artist names succeeds; read
  UTF-8 with a Latin-1 fallback for existing INFO text.

Zmusic still restricts editable formats with `canWriteAudioMetadataPath`;
adding upstream writer capabilities does not enable new formats in the UI.

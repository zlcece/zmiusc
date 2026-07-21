import 'dart:io';

import 'models.dart';

class PlaybackTrack {
  const PlaybackTrack({required this.track, this.streamingCacheFile});

  final Track track;
  final File? streamingCacheFile;
}

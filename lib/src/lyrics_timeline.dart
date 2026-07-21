class LyricLine {
  const LyricLine({required this.time, required this.text});

  final Duration time;
  final String text;
}

List<LyricLine> parseLyricsTimeline(String lyrics) {
  final entries = <LyricLine>[];
  final timestampPattern = RegExp(
    r'\[(\d{1,2}:)?(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );

  for (final rawLine in lyrics.split(RegExp(r'\r?\n'))) {
    final matches = timestampPattern.allMatches(rawLine).toList();
    if (matches.isEmpty) {
      continue;
    }

    final text = rawLine.replaceAll(timestampPattern, '').trim();
    if (text.isEmpty) {
      continue;
    }

    for (final match in matches) {
      final time = _durationFromTimestamp(match);
      if (time == null) {
        continue;
      }
      entries.add(LyricLine(time: time, text: text));
    }
  }

  entries.sort((left, right) => left.time.compareTo(right.time));
  return entries;
}

int currentLyricIndex(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty || position < lines.first.time) {
    return -1;
  }

  var low = 0;
  var high = lines.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (lines[mid].time <= position) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return high;
}

Duration? _durationFromTimestamp(RegExpMatch match) {
  final hoursText = match.group(1);
  final minutes = int.tryParse(match.group(2) ?? '');
  final seconds = int.tryParse(match.group(3) ?? '');
  if (minutes == null || seconds == null) {
    return null;
  }

  final hours = hoursText == null
      ? 0
      : int.tryParse(hoursText.substring(0, hoursText.length - 1)) ?? 0;
  final fraction = match.group(4) ?? '';
  final milliseconds = switch (fraction.length) {
    0 => 0,
    1 => int.parse(fraction) * 100,
    2 => int.parse(fraction) * 10,
    _ => int.parse(fraction.substring(0, 3)),
  };

  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: milliseconds,
  );
}

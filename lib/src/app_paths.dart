import 'dart:io';

const installedDataMarkerFileName = 'zmusic.installed';

Directory executableDirectory() {
  return File(Platform.resolvedExecutable).parent;
}

bool shouldUseInstallDirectoryData() {
  if (!Platform.isWindows) {
    return false;
  }
  return File(
    _joinPath(executableDirectory().path, [installedDataMarkerFileName]),
  ).existsSync();
}

Directory installDataDirectory() {
  return Directory(_joinPath(executableDirectory().path, ['userdata']));
}

Directory installCacheDirectory() {
  return Directory(_joinPath(installDataDirectory().path, ['cache']));
}

File installStoreFile() {
  return File(_joinPath(installDataDirectory().path, ['library_store.json']));
}

String joinPath(String base, List<String> segments) {
  return _joinPath(base, segments);
}

String _joinPath(String base, List<String> segments) {
  final separator = Platform.pathSeparator;
  final normalizedBase = base.endsWith(separator)
      ? base.substring(0, base.length - separator.length)
      : base;
  return [normalizedBase, ...segments].join(separator);
}

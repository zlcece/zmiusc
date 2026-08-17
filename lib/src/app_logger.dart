import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_paths.dart';
import 'settings_models.dart';

class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.module,
    required this.message,
    this.stackTrace,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String module;
  final String message;
  final String? stackTrace;

  String get formatted {
    final time = timestamp.toIso8601String();
    final buffer = StringBuffer(
      '[$time] [${level.name.toUpperCase()}] [$module] $message',
    );
    final trace = stackTrace?.trim();
    if (trace != null && trace.isNotEmpty) {
      buffer
        ..writeln()
        ..write(trace);
    }
    return buffer.toString();
  }
}

class AppLogger extends ChangeNotifier {
  AppLogger({
    this.maxFileBytes = 2 * 1024 * 1024,
    this.retainedFileCount = 3,
    this.maxMemoryEntries = 1000,
  });

  static final AppLogger instance = AppLogger();

  final int maxFileBytes;
  final int retainedFileCount;
  final int maxMemoryEntries;
  final List<AppLogEntry> _entries = <AppLogEntry>[];
  Future<void> _pendingWrite = Future<void>.value();
  Directory? _directory;

  AppLogLevel _level = AppLogLevel.error;

  AppLogLevel get level => _level;
  List<AppLogEntry> get entries => List.unmodifiable(_entries);
  String? get directoryPath => _directory?.path;

  Future<void> initialize({Directory? directory}) async {
    await flush();
    _directory = directory ?? await _defaultLogDirectory();
    await _directory!.create(recursive: true);
    await _clearPreviousSession();
    _entries.clear();
  }

  void setLevel(AppLogLevel value) {
    if (_level == value) {
      return;
    }
    _level = value;
    notifyListeners();
  }

  void error(
    String module,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _record(
      AppLogLevel.error,
      module,
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void warning(
    String module,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _record(
      AppLogLevel.warning,
      module,
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void info(String module, String message) {
    _record(AppLogLevel.info, module, message);
  }

  void debug(String module, String message) {
    _record(AppLogLevel.debug, module, message);
  }

  Future<void> clear() async {
    await flush();
    final directory = _directory;
    if (directory != null && await directory.exists()) {
      for (var index = 0; index < retainedFileCount; index += 1) {
        final file = _logFile(index);
        if (await file.exists()) {
          try {
            await file.delete();
          } on FileSystemException {
            // A concurrently written or externally opened file can be skipped.
          }
        }
      }
    }
    _entries.clear();
    notifyListeners();
  }

  Future<String> exportText() async {
    await flush();
    final chunks = <String>[];
    for (var index = retainedFileCount - 1; index >= 0; index -= 1) {
      final file = _logFile(index);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          chunks.add(content.trimRight());
        }
      }
    }
    if (chunks.isNotEmpty) {
      return '${chunks.join('\n')}\n';
    }
    if (_entries.isEmpty) {
      return '';
    }
    return '${_entries.map((entry) => entry.formatted).join('\n')}\n';
  }

  Future<void> flush() => _pendingWrite;

  void _record(
    AppLogLevel level,
    String module,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.index > _level.index) {
      return;
    }
    final details = error == null ? message : '$message: $error';
    final entry = AppLogEntry(
      timestamp: DateTime.now(),
      level: level,
      module: _sanitize(module),
      message: _sanitize(details),
      stackTrace: stackTrace == null ? null : _sanitize('$stackTrace'),
    );
    _entries.add(entry);
    if (_entries.length > maxMemoryEntries) {
      _entries.removeRange(0, _entries.length - maxMemoryEntries);
    }
    notifyListeners();

    if (_directory != null) {
      _pendingWrite = _pendingWrite
          .catchError((_) {})
          .then((_) => _append(entry));
    }
  }

  Future<void> _append(AppLogEntry entry) async {
    final line = '${entry.formatted}\n';
    final bytes = utf8.encode(line).length;
    final file = _logFile(0);
    if (await file.exists() && await file.length() + bytes > maxFileBytes) {
      await _rotateFiles();
    }
    await file.writeAsString(line, mode: FileMode.append, flush: false);
  }

  Future<void> _rotateFiles() async {
    for (var index = retainedFileCount - 1; index >= 1; index -= 1) {
      final target = _logFile(index);
      if (await target.exists()) {
        await target.delete();
      }
      final source = _logFile(index - 1);
      if (await source.exists()) {
        await source.rename(target.path);
      }
    }
  }

  Future<void> _clearPreviousSession() async {
    for (var index = 0; index < retainedFileCount; index += 1) {
      final file = _logFile(index);
      if (!await file.exists()) {
        continue;
      }
      try {
        await file.delete();
      } on FileSystemException {
        try {
          await file.writeAsString('', mode: FileMode.write);
        } on FileSystemException {
          // Logging must never prevent the application from starting.
        }
      }
    }
  }

  File _logFile(int index) {
    final directory = _directory;
    if (directory == null) {
      throw StateError('AppLogger has not been initialized.');
    }
    final name = index == 0 ? 'zmusic.log' : 'zmusic.$index.log';
    return File(joinPath(directory.path, [name]));
  }

  Future<Directory> _defaultLogDirectory() async {
    if (shouldUseInstallDirectoryData()) {
      return Directory(joinPath(installDataDirectory().path, ['logs']));
    }
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(joinPath(supportDirectory.path, ['logs']));
  }
}

String _sanitize(String value) {
  var result = value.replaceAllMapped(
    RegExp(
      r'([?&](?:u|p|t|s|token|password|auth|authorization|api[_-]?key|key)=)[^&\s]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'((?:password|token|authorization|api[_-]?key)\s*[:=]\s*)[^,;\s}]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );
  return result.replaceAllMapped(
    RegExp(r'(https?://[^:/\s]+:)[^@/\s]+@', caseSensitive: false),
    (match) => '${match.group(1)}<redacted>@',
  );
}

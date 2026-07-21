import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models.dart';
import 'musicbrainz_metadata.dart';

class MetadataManagerPage extends StatefulWidget {
  const MetadataManagerPage({
    required this.controller,
    required this.onBack,
    super.key,
  });

  final AppController controller;
  final VoidCallback onBack;

  @override
  State<MetadataManagerPage> createState() => _MetadataManagerPageState();
}

class _MetadataManagerPageState extends State<MetadataManagerPage> {
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _artistController = TextEditingController();
  final TextEditingController _albumController = TextEditingController();
  final TextEditingController _genresController = TextEditingController();
  final TextEditingController _yearController = TextEditingController();
  final TextEditingController _trackNumberController = TextEditingController();
  final TextEditingController _lyricsController = TextEditingController();
  late final MusicBrainzMetadataService _musicBrainzService;

  List<String> _audioFiles = const [];
  LocalAudioMetadata? _metadata;
  List<MusicBrainzMetadataCandidate> _musicBrainzResults = const [];
  MusicBrainzMetadataCandidate? _selectedMusicBrainzResult;
  Set<MusicBrainzMetadataField> _selectedMusicBrainzFields = const {};
  bool _isScanning = false;
  bool _isReading = false;
  bool _isSaving = false;
  bool _isSearchingMusicBrainz = false;
  String? _message;
  bool _messageIsError = false;
  int _selectionRequest = 0;
  int _musicBrainzRequest = 0;

  @override
  void initState() {
    super.initState();
    _musicBrainzService = MusicBrainzMetadataService();
  }

  @override
  void dispose() {
    _pathController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _genresController.dispose();
    _yearController.dispose();
    _trackNumberController.dispose();
    _lyricsController.dispose();
    _musicBrainzService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('metadata-manager-back'),
                tooltip: '返回设置',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 8),
              Text(
                '标签管理',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 350, child: _buildFilePane(context)),
                const SizedBox(width: 12),
                Expanded(child: _buildMetadataPane(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilePane(BuildContext context) {
    return _MetadataPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('本地音频', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('metadata-path-input'),
            controller: _pathController,
            onSubmitted: (_) => _loadInputPath(),
            decoration: InputDecoration(
              hintText: '输入文件或文件夹路径',
              isDense: true,
              suffixIcon: IconButton(
                tooltip: '读取路径',
                onPressed: _isScanning || _isSaving ? null : _loadInputPath,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  key: const ValueKey('metadata-pick-file'),
                  onPressed: _isScanning || _isSaving ? null : _pickFile,
                  icon: const Icon(Icons.audio_file_outlined),
                  label: const Text('选择文件'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton.icon(
                  key: const ValueKey('metadata-pick-folder'),
                  onPressed: _isScanning || _isSaving ? null : _pickFolder,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('选择文件夹'),
                ),
              ),
            ],
          ),
          if (_message != null && _metadata == null) ...[
            const SizedBox(height: 6),
            Text(
              _message!,
              style: TextStyle(
                color: _messageIsError
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '音频文件 ${_audioFiles.length}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (_isScanning)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Divider(height: 1),
          Expanded(child: _buildFileList(context)),
        ],
      ),
    );
  }

  Widget _buildFileList(BuildContext context) {
    if (_audioFiles.isEmpty) {
      return Center(
        child: Text(
          _isScanning ? '正在扫描音频文件' : '请选择一个音频文件或文件夹',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }

    return ListView.separated(
      itemCount: _audioFiles.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final path = _audioFiles[index];
        final selected = _metadata?.path == path;
        return ListTile(
          key: ValueKey('metadata-file-$path'),
          dense: true,
          selected: selected,
          selectedTileColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.08),
          leading: Icon(
            selected ? Icons.audio_file : Icons.audio_file_outlined,
            size: 22,
          ),
          title: Text(
            _fileName(path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _parentPath(path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(_audioFormat(path)),
          onTap: _isReading || _isSaving ? null : () => _selectAudioFile(path),
        );
      },
    );
  }

  Widget _buildMetadataPane(BuildContext context) {
    final metadata = _metadata;
    return _MetadataPanel(
      child: metadata == null
          ? Center(
              child: _isReading
                  ? const CircularProgressIndicator()
                  : Text(
                      '从左侧选择音频文件后查看元数据',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
            )
          : ListView(
              children: [
                _buildMetadataHeader(context, metadata),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                _buildValueField('标题', _titleController),
                _buildValueField('歌手', _artistController),
                _buildValueField('专辑', _albumController),
                _buildValueField('流派', _genresController),
                Row(
                  children: [
                    Expanded(
                      child: _buildValueField(
                        '年份',
                        _yearController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildValueField(
                        '曲目号',
                        _trackNumberController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                _buildValueField(
                  '歌词',
                  _lyricsController,
                  minLines: 3,
                  maxLines: 6,
                ),
                if (_message != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _message!,
                    style: TextStyle(
                      color: _messageIsError
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 14),
                _buildMusicBrainzSection(context, metadata),
              ],
            ),
    );
  }

  Widget _buildMetadataHeader(
    BuildContext context,
    LocalAudioMetadata metadata,
  ) {
    final writable = canWriteAudioMetadataPath(metadata.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _fileName(metadata.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${_audioFormat(metadata.path)} · ${_formatDuration(metadata.duration)} · ${writable ? '可编辑' : '只读'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton.icon(
              key: const ValueKey('metadata-save'),
              onPressed: !writable || _isSaving ? null : _saveMetadata,
              icon: _isSaving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存元数据'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SelectableText(
          metadata.path,
          maxLines: 2,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (!writable) ...[
          const SizedBox(height: 6),
          Text(
            '当前格式支持读取但不能写入；APE 等格式需要 APEv2 写入能力。',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _buildValueField(
    String label,
    TextEditingController controller, {
    TextInputType? keyboardType,
    int minLines = 1,
    int maxLines = 1,
  }) {
    final editable =
        _metadata != null &&
        canWriteAudioMetadataPath(_metadata!.path) &&
        !_isSaving;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: minLines > 1
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          SizedBox(width: 72, child: Text(label)),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: editable,
              keyboardType: keyboardType,
              minLines: minLines,
              maxLines: maxLines,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMusicBrainzSection(
    BuildContext context,
    LocalAudioMetadata metadata,
  ) {
    final selected = _selectedMusicBrainzResult;
    final writable = canWriteAudioMetadataPath(metadata.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MusicBrainz',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Text('按当前标题、歌手和专辑搜索，不提供歌词。'),
                ],
              ),
            ),
            TextButton.icon(
              key: const ValueKey('metadata-musicbrainz-search'),
              onPressed: _isSearchingMusicBrainz || _isSaving
                  ? null
                  : _searchMusicBrainz,
              icon: _isSearchingMusicBrainz
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore_outlined),
              label: Text(_isSearchingMusicBrainz ? '搜索中' : '搜索'),
            ),
          ],
        ),
        if (_musicBrainzResults.isEmpty && !_isSearchingMusicBrainz) ...[
          const SizedBox(height: 12),
          Text(
            '搜索结果会显示在这里。',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
        if (_musicBrainzResults.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._musicBrainzResults.map(
            (candidate) => _buildMusicBrainzResult(context, candidate),
          ),
        ],
        if (selected != null) ...[
          const SizedBox(height: 12),
          Text('替换字段', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: _availableMusicBrainzFields(selected)
                .map(
                  (field) => SizedBox(
                    width: 140,
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(_musicBrainzFieldLabel(field)),
                      value: _selectedMusicBrainzFields.contains(field),
                      onChanged: writable && !_isSaving
                          ? (value) {
                              setState(() {
                                final fields = Set<MusicBrainzMetadataField>.of(
                                  _selectedMusicBrainzFields,
                                );
                                if (value ?? false) {
                                  fields.add(field);
                                } else {
                                  fields.remove(field);
                                }
                                _selectedMusicBrainzFields = fields;
                              });
                            }
                          : null,
                    ),
                  ),
                )
                .toList(growable: false),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: writable && !_isSaving
                    ? () => _applyMusicBrainzFields(
                        Set<MusicBrainzMetadataField>.of(
                          _availableMusicBrainzFields(selected),
                        ),
                      )
                    : null,
                child: const Text('全部填入'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed:
                    writable &&
                        !_isSaving &&
                        _selectedMusicBrainzFields.isNotEmpty
                    ? () => _applyMusicBrainzFields(_selectedMusicBrainzFields)
                    : null,
                icon: const Icon(Icons.playlist_add_check_outlined),
                label: const Text('填入选中字段'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMusicBrainzResult(
    BuildContext context,
    MusicBrainzMetadataCandidate candidate,
  ) {
    final selected = _selectedMusicBrainzResult?.id == candidate.id;
    final details = [
      if (candidate.artist.isNotEmpty) candidate.artist,
      if (candidate.album.isNotEmpty) candidate.album,
      if (candidate.year.isNotEmpty) candidate.year,
    ].join(' · ');
    return InkWell(
      onTap: () => _selectMusicBrainzResult(candidate),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (details.isNotEmpty)
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (candidate.score > 0) Text('${candidate.score}%'),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: [_audioTypeGroup()]);
    if (file == null) {
      return;
    }
    _pathController.text = file.path;
    await _loadInputPath();
  }

  Future<void> _pickFolder() async {
    final currentPath = _cleanInputPath(_pathController.text);
    String? initialDirectory;
    if (currentPath.isNotEmpty) {
      final currentFile = File(currentPath);
      initialDirectory = currentFile.existsSync()
          ? currentFile.parent.path
          : Directory(currentPath).existsSync()
          ? currentPath
          : null;
    }
    final path = await getDirectoryPath(initialDirectory: initialDirectory);
    if (path == null) {
      return;
    }
    _pathController.text = path;
    await _loadInputPath();
  }

  Future<void> _loadInputPath() async {
    if (_isScanning || _isSaving) {
      return;
    }
    final path = _cleanInputPath(_pathController.text);
    if (path.isEmpty) {
      _showMessage('请输入文件或文件夹路径。', isError: true);
      return;
    }

    setState(() {
      _isScanning = true;
      _selectionRequest += 1;
      _message = null;
      _metadata = null;
      _audioFiles = const [];
      _clearMusicBrainzResults();
    });
    try {
      final type = await FileSystemEntity.type(path, followLinks: true);
      final files = <String>[];
      if (type == FileSystemEntityType.file) {
        if (!isSupportedAudioPath(path)) {
          throw Exception('不支持的音频格式。');
        }
        files.add(File(path).absolute.path);
      } else if (type == FileSystemEntityType.directory) {
        await for (final entity in Directory(
          path,
        ).list(recursive: true, followLinks: false)) {
          if (entity is File && isSupportedAudioPath(entity.path)) {
            files.add(entity.absolute.path);
          }
        }
      } else {
        throw Exception('文件或文件夹不存在。');
      }
      files.sort(
        (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
      );
      if (!mounted) {
        return;
      }
      setState(() => _audioFiles = files);
      if (files.isEmpty) {
        _showMessage('没有找到支持的音频文件。', isError: true);
      } else {
        await _selectAudioFile(files.first);
      }
    } catch (error) {
      if (mounted) {
        _showMessage(_errorText(error), isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _selectAudioFile(String path) async {
    final request = ++_selectionRequest;
    setState(() {
      _isReading = true;
      _message = null;
      _clearMusicBrainzResults();
    });
    try {
      final metadata = await widget.controller.readLocalAudioMetadata(path);
      if (!mounted || request != _selectionRequest) {
        return;
      }
      setState(() => _setMetadata(metadata));
    } catch (error) {
      if (mounted && request == _selectionRequest) {
        _showMessage(_errorText(error), isError: true);
      }
    } finally {
      if (mounted && request == _selectionRequest) {
        setState(() => _isReading = false);
      }
    }
  }

  Future<void> _saveMetadata() async {
    final metadata = _metadata;
    if (metadata == null || _isSaving) {
      return;
    }
    setState(() {
      _isSaving = true;
      _message = null;
    });
    try {
      final updated = await widget.controller.saveAudioMetadata(
        metadata.copyWith(
          title: _titleController.text.trim(),
          artist: _artistController.text.trim(),
          album: _albumController.text.trim(),
          genres: _genresController.text.trim(),
          year: _yearController.text.trim(),
          trackNumber: _trackNumberController.text.trim(),
          lyrics: _lyricsController.text,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _setMetadata(updated);
        _message = '元数据已保存。';
        _messageIsError = false;
      });
    } catch (error) {
      if (mounted) {
        _showMessage(_errorText(error), isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _searchMusicBrainz() async {
    setState(() {
      _message = null;
      _clearMusicBrainzResults();
      _isSearchingMusicBrainz = true;
    });
    final request = _musicBrainzRequest;
    try {
      final results = await _musicBrainzService.search(
        title: _titleController.text,
        artist: _artistController.text,
        album: _albumController.text,
      );
      if (!mounted || request != _musicBrainzRequest) {
        return;
      }
      setState(() {
        _musicBrainzResults = results;
        if (results.isNotEmpty) {
          _setSelectedMusicBrainzResult(results.first);
        } else {
          _message = 'MusicBrainz 未找到匹配结果。';
          _messageIsError = false;
        }
      });
    } catch (error) {
      if (mounted && request == _musicBrainzRequest) {
        _showMessage(_errorText(error), isError: true);
      }
    } finally {
      if (mounted && request == _musicBrainzRequest) {
        setState(() => _isSearchingMusicBrainz = false);
      }
    }
  }

  void _selectMusicBrainzResult(MusicBrainzMetadataCandidate candidate) {
    setState(() => _setSelectedMusicBrainzResult(candidate));
  }

  void _setSelectedMusicBrainzResult(MusicBrainzMetadataCandidate candidate) {
    _selectedMusicBrainzResult = candidate;
    _selectedMusicBrainzFields = Set<MusicBrainzMetadataField>.of(
      _availableMusicBrainzFields(candidate),
    );
  }

  void _applyMusicBrainzFields(Set<MusicBrainzMetadataField> fields) {
    final candidate = _selectedMusicBrainzResult;
    if (candidate == null) {
      return;
    }
    for (final field in fields) {
      final value = candidate.valueFor(field);
      if (value.isEmpty) {
        continue;
      }
      switch (field) {
        case MusicBrainzMetadataField.title:
          _titleController.text = value;
        case MusicBrainzMetadataField.artist:
          _artistController.text = value;
        case MusicBrainzMetadataField.album:
          _albumController.text = value;
        case MusicBrainzMetadataField.genres:
          _genresController.text = value;
        case MusicBrainzMetadataField.year:
          _yearController.text = value;
      }
    }
    _showMessage('已填入 MusicBrainz 数据，保存后写入文件。');
  }

  List<MusicBrainzMetadataField> _availableMusicBrainzFields(
    MusicBrainzMetadataCandidate candidate,
  ) {
    return MusicBrainzMetadataField.values
        .where((field) => candidate.valueFor(field).isNotEmpty)
        .toList(growable: false);
  }

  void _setMetadata(LocalAudioMetadata metadata) {
    _metadata = metadata;
    _titleController.text = metadata.title;
    _artistController.text = metadata.artist;
    _albumController.text = metadata.album;
    _genresController.text = metadata.genres;
    _yearController.text = metadata.year;
    _trackNumberController.text = metadata.trackNumber;
    _lyricsController.text = metadata.lyrics;
  }

  void _clearMusicBrainzResults() {
    _musicBrainzRequest += 1;
    _musicBrainzResults = const [];
    _selectedMusicBrainzResult = null;
    _selectedMusicBrainzFields = const {};
    _isSearchingMusicBrainz = false;
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _message = message;
      _messageIsError = isError;
    });
  }
}

class _MetadataPanel extends StatelessWidget {
  const _MetadataPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (isDark ? Colors.black : Colors.white).withValues(
          alpha: isDark ? 0.28 : 0.62,
        ),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    );
  }
}

XTypeGroup _audioTypeGroup() {
  return XTypeGroup(
    label: '音频文件',
    extensions: supportedFileExtensions
        .map((extension) => extension.substring(1))
        .toList(),
  );
}

String _cleanInputPath(String value) {
  final path = value.trim();
  if (path.length >= 2 &&
      ((path.startsWith('"') && path.endsWith('"')) ||
          (path.startsWith("'") && path.endsWith("'")))) {
    return path.substring(1, path.length - 1).trim();
  }
  return path;
}

String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;

String _parentPath(String path) {
  final normalized = path.replaceAll('/', '\\');
  final separator = normalized.lastIndexOf('\\');
  return separator <= 0 ? '' : normalized.substring(0, separator);
}

String _audioFormat(String path) {
  final name = _fileName(path);
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toUpperCase();
}

String _musicBrainzFieldLabel(MusicBrainzMetadataField field) {
  return switch (field) {
    MusicBrainzMetadataField.title => '标题',
    MusicBrainzMetadataField.artist => '歌手',
    MusicBrainzMetadataField.album => '专辑',
    MusicBrainzMetadataField.genres => '流派',
    MusicBrainzMetadataField.year => '年份',
  };
}

String _errorText(Object error) {
  return error.toString().replaceFirst('Exception: ', '');
}

Future<void> showMetadataAdminDialog(
  BuildContext context,
  AppController controller, {
  String? initialPath,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _MetadataAdminDialog(controller: controller, initialPath: initialPath),
  );
}

class _MetadataAdminDialog extends StatefulWidget {
  const _MetadataAdminDialog({required this.controller, this.initialPath});

  final AppController controller;
  final String? initialPath;

  @override
  State<_MetadataAdminDialog> createState() => _MetadataAdminDialogState();
}

class _MetadataAdminDialogState extends State<_MetadataAdminDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _artistController = TextEditingController();
  final TextEditingController _albumController = TextEditingController();
  final TextEditingController _genresController = TextEditingController();
  final TextEditingController _yearController = TextEditingController();
  final TextEditingController _trackNumberController = TextEditingController();
  final TextEditingController _lyricsController = TextEditingController();

  LocalAudioMetadata? _metadata;
  String? _message;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    final initialPath = widget.initialPath;
    if (initialPath != null && initialPath.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _run(() => _loadPath(initialPath));
        }
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _genresController.dispose();
    _yearController.dispose();
    _trackNumberController.dispose();
    _lyricsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metadata = _metadata;
    return AlertDialog(
      title: const Text('音频元数据'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _isBusy ? null : _pickFile,
                    icon: const Icon(Icons.audio_file_outlined),
                    label: const Text('选择本地音频'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      metadata?.path ??
                          '支持读取 MP3、FLAC、MP4/M4A、OGG、Opus、WAV 等格式',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('可写格式：MP3、MP4/M4A、FLAC、WAV。其他格式只读。'),
              if (_isBusy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(
                  _message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (metadata != null) ...[
                const SizedBox(height: 20),
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                TextField(
                  controller: _artistController,
                  decoration: const InputDecoration(labelText: '歌手'),
                ),
                TextField(
                  controller: _albumController,
                  decoration: const InputDecoration(labelText: '专辑'),
                ),
                TextField(
                  controller: _genresController,
                  decoration: const InputDecoration(labelText: '流派（用逗号分隔）'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _yearController,
                        decoration: const InputDecoration(labelText: '年份'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _trackNumberController,
                        decoration: const InputDecoration(labelText: '曲目号'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: _lyricsController,
                  decoration: const InputDecoration(labelText: '歌词'),
                  minLines: 3,
                  maxLines: 6,
                ),
                const SizedBox(height: 12),
                Text('时长：${_formatDuration(metadata.duration)}'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isBusy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (metadata != null)
          OutlinedButton.icon(
            onPressed: _isBusy ? null : _addToPlaylist,
            icon: const Icon(Icons.playlist_add),
            label: const Text('加入播放'),
          ),
        if (metadata != null)
          FilledButton.icon(
            onPressed: _isBusy ? null : _saveMetadata,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存元数据'),
          ),
      ],
    );
  }

  Future<void> _pickFile() async {
    await _run(() async {
      final typeGroup = XTypeGroup(
        label: '音频文件',
        extensions: supportedFileExtensions
            .map((extension) => extension.substring(1))
            .toList(),
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) {
        return;
      }
      await _loadPath(file.path);
    });
  }

  Future<void> _loadPath(String path) async {
    final metadata = await widget.controller.readLocalAudioMetadata(path);
    _setMetadata(metadata);
    _message = null;
  }

  Future<void> _saveMetadata() async {
    final metadata = _metadata;
    if (metadata == null) {
      return;
    }

    await _run(() async {
      final updated = await widget.controller.saveAudioMetadata(
        metadata.copyWith(
          title: _titleController.text,
          artist: _artistController.text,
          album: _albumController.text,
          genres: _genresController.text,
          year: _yearController.text,
          trackNumber: _trackNumberController.text,
          lyrics: _lyricsController.text,
        ),
      );
      _setMetadata(updated);
      _message = '元数据已保存。';
    });
  }

  Future<void> _addToPlaylist() async {
    final metadata = _metadata;
    if (metadata == null) {
      return;
    }

    await _run(() async {
      final updated = metadata.copyWith(
        title: _titleController.text,
        artist: _artistController.text,
        album: _albumController.text,
        genres: _genresController.text,
        year: _yearController.text,
        trackNumber: _trackNumberController.text,
        lyrics: _lyricsController.text,
      );
      await widget.controller.addLocalAudioTrack(updated);
      _message = '已加入本地播放列表。';
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _isBusy = true;
      _message = null;
    });
    try {
      await operation();
    } catch (error) {
      _message = error.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _setMetadata(LocalAudioMetadata metadata) {
    _metadata = metadata;
    _titleController.text = metadata.title;
    _artistController.text = metadata.artist;
    _albumController.text = metadata.album;
    _genresController.text = metadata.genres;
    _yearController.text = metadata.year;
    _trackNumberController.text = metadata.trackNumber;
    _lyricsController.text = metadata.lyrics;
  }
}

String _formatDuration(Duration? value) {
  if (value == null) {
    return '--:--';
  }
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (value.inHours > 0) {
    return '${value.inHours}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

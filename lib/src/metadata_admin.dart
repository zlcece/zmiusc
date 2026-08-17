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
  late final OnlineMetadataService _onlineMetadataService;

  List<String> _audioFiles = const [];
  LocalAudioMetadata? _metadata;
  OnlineMetadataSource _metadataSource = OnlineMetadataSource.musicBrainz;
  List<OnlineMetadataCandidate> _onlineMetadataResults = const [];
  OnlineMetadataCandidate? _selectedOnlineMetadataResult;
  Set<OnlineMetadataField> _selectedOnlineMetadataFields = const {};
  bool _isScanning = false;
  bool _isReading = false;
  bool _isSaving = false;
  bool _isSearchingOnlineMetadata = false;
  String? _message;
  bool _messageIsError = false;
  int _selectionRequest = 0;
  int _onlineMetadataRequest = 0;

  @override
  void initState() {
    super.initState();
    _onlineMetadataService = OnlineMetadataService();
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
    _onlineMetadataService.dispose();
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
                _buildOnlineMetadataSection(context, metadata),
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
            _buildArtwork(metadata.coverUrl, size: 76),
            const SizedBox(width: 12),
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

  Widget _buildOnlineMetadataSection(
    BuildContext context,
    LocalAudioMetadata metadata,
  ) {
    final selected = _selectedOnlineMetadataResult;
    final writable = canWriteAudioMetadataPath(metadata.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Text('在线元数据', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 12),
                  DropdownButton<OnlineMetadataSource>(
                    key: const ValueKey('metadata-online-source'),
                    value: _metadataSource,
                    underline: const SizedBox.shrink(),
                    onChanged: _isSearchingOnlineMetadata || _isSaving
                        ? null
                        : (source) {
                            if (source == null || source == _metadataSource) {
                              return;
                            }
                            setState(() {
                              _metadataSource = source;
                              _clearOnlineMetadataResults();
                            });
                          },
                    items: OnlineMetadataSource.values
                        .map(
                          (source) => DropdownMenuItem(
                            value: source,
                            child: Text(source.label),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              key: const ValueKey('metadata-online-search'),
              onPressed: _isSearchingOnlineMetadata || _isSaving
                  ? null
                  : _searchOnlineMetadata,
              icon: _isSearchingOnlineMetadata
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore_outlined),
              label: Text(_isSearchingOnlineMetadata ? '搜索中' : '搜索'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '按当前标题、歌手和专辑搜索；各平台可提供的字段可能不同。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_onlineMetadataResults.isEmpty && !_isSearchingOnlineMetadata) ...[
          const SizedBox(height: 12),
          Text(
            '搜索结果会显示在这里。',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
        if (_onlineMetadataResults.isNotEmpty) ...[
          const SizedBox(height: 10),
          ..._onlineMetadataResults.map(
            (candidate) => _buildOnlineMetadataResult(context, candidate),
          ),
        ],
        if (selected != null) ...[
          const SizedBox(height: 12),
          Text('替换字段', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: _availableOnlineMetadataFields(selected)
                .map(
                  (field) => SizedBox(
                    width: 140,
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(_onlineMetadataFieldLabel(field)),
                      value: _selectedOnlineMetadataFields.contains(field),
                      onChanged: writable && !_isSaving
                          ? (value) {
                              setState(() {
                                final fields = Set<OnlineMetadataField>.of(
                                  _selectedOnlineMetadataFields,
                                );
                                if (value ?? false) {
                                  fields.add(field);
                                } else {
                                  fields.remove(field);
                                }
                                _selectedOnlineMetadataFields = fields;
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
                    ? () => _applyOnlineMetadataFields(
                        Set<OnlineMetadataField>.of(
                          _availableOnlineMetadataFields(selected),
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
                        _selectedOnlineMetadataFields.isNotEmpty
                    ? () => _applyOnlineMetadataFields(
                        _selectedOnlineMetadataFields,
                      )
                    : null,
                icon: const Icon(Icons.playlist_add_check_outlined),
                label: const Text('填入选中字段'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('metadata-online-replace'),
                onPressed: writable && !_isSaving
                    ? _confirmAndReplaceOnlineMetadata
                    : null,
                icon: const Icon(Icons.find_replace_outlined),
                label: const Text('一键替换'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildOnlineMetadataResult(
    BuildContext context,
    OnlineMetadataCandidate candidate,
  ) {
    final selected =
        _selectedOnlineMetadataResult?.source == candidate.source &&
        _selectedOnlineMetadataResult?.id == candidate.id;
    final details = [
      if (candidate.artist.isNotEmpty) candidate.artist,
      if (candidate.album.isNotEmpty) candidate.album,
      if (candidate.year.isNotEmpty) candidate.year,
    ].join(' · ');
    return InkWell(
      onTap: () => _selectOnlineMetadataResult(candidate),
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
            _buildArtwork(candidate.artworkUrl, size: 48),
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

  Widget _buildArtwork(String? artworkUrl, {required double size}) {
    final url = artworkUrl?.trim() ?? '';
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.album_outlined, size: size * 0.42),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox.square(
        dimension: size,
        child: url.isEmpty
            ? placeholder
            : FutureBuilder<File?>(
                future: widget.controller.artworkCacheManager.cacheArtwork(url),
                builder: (context, snapshot) {
                  final file = snapshot.data;
                  if (file == null) {
                    return placeholder;
                  }
                  return Image.file(
                    file,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => placeholder,
                  );
                },
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
      _clearOnlineMetadataResults();
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
      _clearOnlineMetadataResults();
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

  Future<void> _searchOnlineMetadata() async {
    setState(() {
      _message = null;
      _clearOnlineMetadataResults();
      _isSearchingOnlineMetadata = true;
    });
    final request = _onlineMetadataRequest;
    try {
      final results = await _onlineMetadataService.search(
        source: _metadataSource,
        title: _titleController.text,
        artist: _artistController.text,
        album: _albumController.text,
      );
      if (!mounted || request != _onlineMetadataRequest) {
        return;
      }
      setState(() {
        _onlineMetadataResults = results;
        if (results.isNotEmpty) {
          _setSelectedOnlineMetadataResult(results.first);
        } else {
          _message = '${_metadataSource.label}未找到匹配结果。';
          _messageIsError = false;
        }
      });
    } catch (error) {
      if (mounted && request == _onlineMetadataRequest) {
        _showMessage(_errorText(error), isError: true);
      }
    } finally {
      if (mounted && request == _onlineMetadataRequest) {
        setState(() => _isSearchingOnlineMetadata = false);
      }
    }
  }

  void _selectOnlineMetadataResult(OnlineMetadataCandidate candidate) {
    setState(() => _setSelectedOnlineMetadataResult(candidate));
  }

  void _setSelectedOnlineMetadataResult(OnlineMetadataCandidate candidate) {
    _selectedOnlineMetadataResult = candidate;
    _selectedOnlineMetadataFields = Set<OnlineMetadataField>.of(
      _availableOnlineMetadataFields(candidate),
    );
  }

  void _applyOnlineMetadataFields(Set<OnlineMetadataField> fields) {
    final candidate = _selectedOnlineMetadataResult;
    if (candidate == null) {
      return;
    }
    for (final field in fields) {
      final value = candidate.valueFor(field);
      if (value.isEmpty) {
        continue;
      }
      switch (field) {
        case OnlineMetadataField.title:
          _titleController.text = value;
        case OnlineMetadataField.artist:
          _artistController.text = value;
        case OnlineMetadataField.album:
          _albumController.text = value;
        case OnlineMetadataField.genres:
          _genresController.text = value;
        case OnlineMetadataField.year:
          _yearController.text = value;
        case OnlineMetadataField.trackNumber:
          _trackNumberController.text = value;
      }
    }
    _showMessage('已填入${candidate.source.label}数据，保存后写入文件。');
  }

  Future<void> _confirmAndReplaceOnlineMetadata() async {
    final candidate = _selectedOnlineMetadataResult;
    final metadata = _metadata;
    if (candidate == null || metadata == null || _isSaving) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('替换歌曲元数据'),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildArtwork(candidate.artworkUrl, size: 72),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.title,
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  ),
                  if (candidate.artist.isNotEmpty) Text(candidate.artist),
                  if (candidate.album.isNotEmpty) Text(candidate.album),
                  const SizedBox(height: 10),
                  Text(
                    candidate.artworkUrl.isEmpty
                        ? '确认后将直接写入可用字段；当前来源没有返回专辑封面。'
                        : '确认后将直接写入可用字段和专辑封面。',
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认替换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _isSaving = true;
      _message = null;
    });
    try {
      OnlineMetadataArtwork? artwork;
      String? artworkWarning;
      if (candidate.artworkUrl.isNotEmpty) {
        try {
          artwork = await _onlineMetadataService.downloadArtwork(
            candidate.artworkUrl,
          );
        } catch (error) {
          artworkWarning = _errorText(error);
        }
      }
      final updated = await widget.controller.saveAudioMetadata(
        metadata.copyWith(
          title: _replacementValue(candidate.title, metadata.title),
          artist: _replacementValue(candidate.artist, metadata.artist),
          album: _replacementValue(candidate.album, metadata.album),
          genres: _replacementValue(candidate.genres, metadata.genres),
          year: _replacementValue(candidate.year, metadata.year),
          trackNumber: _replacementValue(
            candidate.trackNumber,
            metadata.trackNumber,
          ),
        ),
        artworkBytes: artwork?.bytes,
        artworkMimeType: artwork?.mimeType,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _setMetadata(updated);
        _message = artworkWarning == null
            ? '${candidate.source.label}元数据已写入文件。'
            : '${candidate.source.label}字段已写入，$artworkWarning';
        _messageIsError = artworkWarning != null;
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

  List<OnlineMetadataField> _availableOnlineMetadataFields(
    OnlineMetadataCandidate candidate,
  ) {
    return OnlineMetadataField.values
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

  void _clearOnlineMetadataResults() {
    _onlineMetadataRequest += 1;
    _onlineMetadataResults = const [];
    _selectedOnlineMetadataResult = null;
    _selectedOnlineMetadataFields = const {};
    _isSearchingOnlineMetadata = false;
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

String _replacementValue(String candidate, String current) {
  final value = candidate.trim();
  return value.isEmpty ? current : value;
}

String _onlineMetadataFieldLabel(OnlineMetadataField field) {
  return switch (field) {
    OnlineMetadataField.title => '标题',
    OnlineMetadataField.artist => '歌手',
    OnlineMetadataField.album => '专辑',
    OnlineMetadataField.genres => '流派',
    OnlineMetadataField.year => '年份',
    OnlineMetadataField.trackNumber => '曲目号',
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

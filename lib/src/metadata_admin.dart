import 'dart:async';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models.dart';
import 'music_ext_upload.dart';
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
  final TextEditingController _albumArtistController = TextEditingController();
  final TextEditingController _albumController = TextEditingController();
  final TextEditingController _genresController = TextEditingController();
  final TextEditingController _yearController = TextEditingController();
  final TextEditingController _trackNumberController = TextEditingController();
  final TextEditingController _lyricsController = TextEditingController();
  late final OnlineMetadataService _onlineMetadataService;

  List<String> _audioFiles = const [];
  LocalAudioMetadata? _metadata;
  OnlineMetadataArtwork? _pendingArtwork;
  OnlineMetadataSource _metadataSource = OnlineMetadataSource.musicBrainz;
  List<OnlineMetadataCandidate> _onlineMetadataResults = const [];
  OnlineMetadataCandidate? _selectedOnlineMetadataResult;
  Set<OnlineMetadataField> _selectedOnlineMetadataFields = const {};
  bool _isScanning = false;
  bool _isReading = false;
  bool _isSaving = false;
  bool _isFillingOnlineMetadata = false;
  bool _isSearchingOnlineMetadata = false;
  String? _message;
  bool _messageIsError = false;
  int _selectionRequest = 0;
  int _onlineMetadataRequest = 0;
  bool _albumArtistFollowsArtist = true;
  ServerConfig? _libraryServer;
  int _libraryCheckRequest = 0;
  bool _isCheckingLibrary = false;
  bool? _libraryExists;
  MusicExtUploadClient? _uploadClient;
  DialogRoute<bool>? _uploadConfirmationRoute;
  late String _musicExtAddress;
  final Set<String> _uploadedPaths = {};
  bool _isUploading = false;
  double? _uploadProgress;
  String? _uploadStatus;
  int _uploadRequest = 0;

  bool get _isEditingLocked =>
      _isSaving || _isUploading || _isFillingOnlineMetadata;

  @override
  void initState() {
    super.initState();
    _onlineMetadataService = OnlineMetadataService();
    _artistController.addListener(_syncAlbumArtist);
    _libraryServer = widget.controller.selectedServer;
    _musicExtAddress = widget.controller.settings.musicExtUrl;
    widget.controller.addListener(_handleLibraryAccountChange);
  }

  @override
  void dispose() {
    _libraryCheckRequest += 1;
    _closeUploadClient();
    widget.controller.removeListener(_handleLibraryAccountChange);
    _pathController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _albumArtistController.dispose();
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
            enabled: !_isEditingLocked,
            onSubmitted: (_) => _loadInputPath(),
            decoration: InputDecoration(
              hintText: '输入文件或文件夹路径',
              isDense: true,
              suffixIcon: IconButton(
                tooltip: '读取路径',
                onPressed: _isScanning || _isEditingLocked
                    ? null
                    : _loadInputPath,
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
                  onPressed: _isScanning || _isEditingLocked ? null : _pickFile,
                  icon: const Icon(Icons.audio_file_outlined),
                  label: const Text('选择文件'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton.icon(
                  key: const ValueKey('metadata-pick-folder'),
                  onPressed: _isScanning || _isEditingLocked
                      ? null
                      : _pickFolder,
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
          onTap: _isReading || _isEditingLocked
              ? null
              : () => _selectAudioFile(path),
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
                _MetadataFieldRow(
                  left: _buildValueField(
                    '标题',
                    _titleController,
                    savedValue: metadata.title,
                  ),
                  right: _buildValueField(
                    '歌手',
                    _artistController,
                    savedValue: metadata.artist,
                  ),
                ),
                _MetadataFieldRow(
                  left: _buildValueField(
                    '专辑',
                    _albumController,
                    savedValue: metadata.album,
                  ),
                  right: _buildValueField(
                    '专辑歌手',
                    _albumArtistController,
                    savedValue: metadata.albumArtist,
                    onChanged: (value) => _albumArtistFollowsArtist =
                        value.trim().isEmpty ||
                        value.trim() == _artistController.text.trim(),
                  ),
                ),
                _MetadataFieldRow(
                  left: _buildValueField(
                    '流派',
                    _genresController,
                    savedValue: metadata.genres,
                  ),
                  right: _buildValueField(
                    '年份',
                    _yearController,
                    savedValue: metadata.year,
                    keyboardType: TextInputType.number,
                  ),
                ),
                _MetadataFieldRow(
                  left: _buildValueField(
                    '曲目号',
                    _trackNumberController,
                    savedValue: metadata.trackNumber,
                    keyboardType: TextInputType.number,
                  ),
                ),
                _buildValueField(
                  '歌词',
                  _lyricsController,
                  savedValue: metadata.lyrics,
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
    final uploadUnavailableReason = _uploadUnavailableReason(metadata);
    final uploadBusy = _isEditingLocked || _isReading || _isScanning;
    final alreadyUploaded = _uploadedPaths.contains(metadata.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _buildCurrentArtwork(metadata),
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
            const SizedBox(width: 8),
            _buildLibraryStatus(context),
            const SizedBox(width: 8),
            TextButton.icon(
              key: const ValueKey('metadata-save'),
              onPressed: !writable || _isEditingLocked ? null : _saveMetadata,
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
        Row(
          children: [
            Expanded(
              child: SelectableText(
                metadata.path,
                maxLines: 2,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (alreadyUploaded) ...[
              const SizedBox(width: 8),
              const Icon(Icons.check_circle_outline, size: 18),
              const SizedBox(width: 4),
              const Text('已上传'),
            ] else if (_libraryExists != true) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: uploadUnavailableReason ?? '上传至 Music Ext',
                child: TextButton.icon(
                  key: const ValueKey('metadata-upload'),
                  onPressed: uploadBusy || uploadUnavailableReason != null
                      ? null
                      : _uploadAudioFile,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(_isUploading ? '上传中' : '上传'),
                ),
              ),
            ],
          ],
        ),
        if (_libraryExists != true &&
            !alreadyUploaded &&
            !uploadBusy &&
            uploadUnavailableReason != null) ...[
          const SizedBox(height: 6),
          Text(
            uploadUnavailableReason,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
        if (_isUploading) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            key: const ValueKey('metadata-upload-progress'),
            value: _uploadProgress == 1 ? null : _uploadProgress,
          ),
          const SizedBox(height: 4),
          Text(_uploadStatus ?? '正在准备上传…'),
        ],
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

  List<String> _missingUploadFields(LocalAudioMetadata metadata) => [
    if (metadata.title.trim().isEmpty) '标题',
    if (metadata.artist.trim().isEmpty) '歌手',
    if (metadata.album.trim().isEmpty) '专辑',
    if (metadata.coverUrl?.trim().isEmpty ?? true) '封面',
  ];

  String? _uploadUnavailableReason(LocalAudioMetadata metadata) {
    if (!widget.controller.isAuthenticated) {
      return '请先登录 Navidrome 后再上传。';
    }
    final missingFields = _missingUploadFields(metadata);
    if (missingFields.isNotEmpty) {
      return '上传前请补齐并保存：${missingFields.join('、')}。';
    }
    if (_isCheckingLibrary) {
      return '正在检查曲库，请稍候。';
    }
    if (_libraryExists == null) {
      return '曲库状态尚未确认，请先重试检查。';
    }
    return null;
  }

  Widget _buildLibraryStatus(BuildContext context) {
    if (_isCheckingLibrary) {
      return const Text('曲库：检查中');
    }
    if (_libraryExists == null) {
      final metadata = _metadata;
      if (metadata != null &&
          (_libraryBaseTitle(metadata.title).isEmpty ||
              metadata.artist.trim().isEmpty)) {
        return const Tooltip(
          message: '补齐并保存标题和歌手后才能检查曲库。',
          child: Text('曲库：标签待补齐'),
        );
      }
      return TextButton(
        onPressed: _checkLibraryPresence,
        child: const Text('曲库未确认 · 重试'),
      );
    }
    return Text(
      _libraryExists! ? '已存在' : '未存在',
      style: TextStyle(
        color: _libraryExists!
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
    );
  }

  void _handleLibraryAccountChange() {
    final accountChanged = !identical(
      _libraryServer,
      widget.controller.selectedServer,
    );
    final address = widget.controller.settings.musicExtUrl;
    if (accountChanged || address != _musicExtAddress) {
      final wasUploading = _isUploading;
      _closeUploadClient();
      setState(() {
        _musicExtAddress = address;
        _uploadedPaths.clear();
        _isUploading = false;
        _uploadProgress = null;
        _uploadStatus = null;
        if (wasUploading) {
          _message = '账号或服务地址已变化，上传已停止。保存结果未确认，请检查原 Music Ext 保存目录。';
          _messageIsError = true;
        }
      });
    }
    if (accountChanged) {
      unawaited(_checkLibraryPresence());
    }
  }

  void _closeUploadClient() {
    _uploadRequest += 1;
    final client = _uploadClient;
    _uploadClient = null;
    if (client != null) {
      unawaited(client.close());
    }
    final route = _uploadConfirmationRoute;
    _uploadConfirmationRoute = null;
    if (route != null) {
      scheduleMicrotask(() {
        if (route.isActive) {
          route.navigator?.removeRoute(route);
        }
      });
    }
  }

  bool get _hasUnsavedMetadata {
    final metadata = _metadata;
    if (metadata == null) {
      return false;
    }
    // Read-only formats also display a default album artist without editing it.
    final albumArtist =
        metadata.albumArtist.trim().isEmpty &&
            !canWriteAudioMetadataPath(metadata.path)
        ? metadata.artist
        : metadata.albumArtist;
    return _pendingArtwork != null ||
        _titleController.text != metadata.title ||
        _artistController.text != metadata.artist ||
        _albumArtistController.text != albumArtist ||
        _albumController.text != metadata.album ||
        _genresController.text != metadata.genres ||
        _yearController.text != metadata.year ||
        _trackNumberController.text != metadata.trackNumber ||
        _lyricsController.text != metadata.lyrics;
  }

  Future<void> _uploadAudioFile() async {
    final metadata = _metadata;
    final server = widget.controller.selectedServer;
    if (metadata == null ||
        server == null ||
        !widget.controller.isAuthenticated ||
        _isEditingLocked ||
        _isReading ||
        _isScanning ||
        _libraryExists != false ||
        _isCheckingLibrary ||
        _uploadedPaths.contains(metadata.path)) {
      return;
    }
    if (_hasUnsavedMetadata) {
      _showMessage('请先保存红框中的元数据修改，再上传文件。', isError: true);
      return;
    }
    final missingFields = _missingUploadFields(metadata);
    if (missingFields.isNotEmpty) {
      _showMessage('上传前请补齐并保存：${missingFields.join('、')}。', isError: true);
      return;
    }
    final client = _uploadClient ??= MusicExtUploadClient(
      _musicExtAddress,
      server,
    );
    final request = ++_uploadRequest;
    bool isCurrent() => mounted && request == _uploadRequest;
    setState(() {
      _isUploading = true;
      _uploadProgress = null;
      _uploadStatus = '正在检查上传权限…';
      _message = null;
    });
    try {
      var result = await client.upload(
        File(metadata.path),
        onProgress: (sent, total) {
          if (!isCurrent()) {
            return;
          }
          final progress = (sent / total).clamp(0.0, 1.0).toDouble();
          if (_uploadProgress != null &&
              (progress * 100).floor() == (_uploadProgress! * 100).floor()) {
            return;
          }
          setState(() {
            _uploadProgress = progress;
            _uploadStatus = progress == 1
                ? '传输完成，正在校验并保存…'
                : '正在上传 ${(progress * 100).floor()}%';
          });
        },
      );
      if (!mounted || request != _uploadRequest) {
        return;
      }
      if (result == null) {
        setState(() => _uploadStatus = '缺少有效歌词，等待确认…');
        final route = DialogRoute<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('确认保存无歌词文件'),
            content: Text(
              client.lyricsConfirmationMessage ?? '未检测到有效的内嵌歌词，仍要保存吗？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消保存'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('仍然保存'),
              ),
            ],
          ),
        );
        _uploadConfirmationRoute = route;
        final confirmed = await Navigator.of(
          context,
          rootNavigator: true,
        ).push(route);
        if (identical(_uploadConfirmationRoute, route)) {
          _uploadConfirmationRoute = null;
        }
        if (!isCurrent()) {
          return;
        }
        if (confirmed != true) {
          await client.cancelPending();
          if (isCurrent()) {
            _showMessage('已取消保存。');
          }
          return;
        }
        setState(() => _uploadStatus = '正在保存文件…');
        result = await client.confirm();
      }
      if (isCurrent()) {
        final saved = result;
        setState(() {
          _uploadedPaths.add(metadata.path);
          _message = '已上传：${saved.filename}\n保存目录：${saved.directory}';
          _messageIsError = false;
        });
      }
    } catch (error) {
      if (isCurrent()) {
        _showMessage(_errorText(error), isError: true);
        _closeUploadClient();
        setState(() {
          _isUploading = false;
          _uploadProgress = null;
          _uploadStatus = null;
        });
      }
    } finally {
      if (isCurrent()) {
        setState(() {
          _isUploading = false;
          _uploadProgress = null;
          _uploadStatus = null;
        });
      }
    }
  }

  Future<void> _checkLibraryPresence() async {
    final metadata = _metadata;
    final server = widget.controller.selectedServer;
    _libraryServer = server;
    final request = ++_libraryCheckRequest;
    if (metadata == null) {
      return;
    }
    final query = _libraryBaseTitle(metadata.title);
    if (!widget.controller.isAuthenticated ||
        server == null ||
        server.isLocalFolder ||
        query.isEmpty ||
        metadata.artist.trim().isEmpty) {
      setState(() {
        _isCheckingLibrary = false;
        _libraryExists = null;
      });
      return;
    }
    setState(() {
      _isCheckingLibrary = true;
      _libraryExists = null;
    });
    try {
      final exists = await (() async {
        for (var offset = 0; offset < 500; offset += 100) {
          final tracks = await widget.controller.searchTracksForSource(
            server,
            query,
            offset: offset,
            limit: 100,
          );
          if (!mounted || request != _libraryCheckRequest) {
            return null;
          }
          if (tracks.any((track) => _librarySongMatches(metadata, track))) {
            return true;
          }
          if (tracks.length < 100) {
            return false;
          }
        }
        return null;
      })().timeout(const Duration(seconds: 15));
      if (mounted && request == _libraryCheckRequest) {
        setState(() {
          _libraryExists = exists;
          _isCheckingLibrary = false;
        });
      }
    } catch (_) {
      if (mounted && request == _libraryCheckRequest) {
        _libraryCheckRequest += 1;
        setState(() {
          _libraryExists = null;
          _isCheckingLibrary = false;
        });
      }
    }
  }

  Widget _buildValueField(
    String label,
    TextEditingController controller, {
    required String savedValue,
    TextInputType? keyboardType,
    int minLines = 1,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    final editable =
        _metadata != null &&
        canWriteAudioMetadataPath(_metadata!.path) &&
        !_isEditingLocked;
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
            child: _MetadataTextField(
              controller: controller,
              savedValue: savedValue,
              onChanged: onChanged,
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
                    onChanged: _isSearchingOnlineMetadata || _isEditingLocked
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
              onPressed: _isSearchingOnlineMetadata || _isEditingLocked
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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _availableOnlineMetadataFields(selected)
                  .map((field) {
                    final checked = _selectedOnlineMetadataFields.contains(
                      field,
                    );
                    final enabled = writable && !_isEditingLocked;
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: MergeSemantics(
                        child: InkWell(
                          onTap: enabled
                              ? () => _setOnlineMetadataFieldSelected(
                                  field,
                                  !checked,
                                )
                              : null,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Checkbox(
                                value: checked,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                onChanged: enabled
                                    ? (value) =>
                                          _setOnlineMetadataFieldSelected(
                                            field,
                                            value ?? false,
                                          )
                                    : null,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                _onlineMetadataFieldLabel(field),
                                maxLines: 1,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_isFillingOnlineMetadata) ...[
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                const Text('正在填入封面…'),
                const SizedBox(width: 12),
              ],
              TextButton(
                onPressed: writable && !_isEditingLocked
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
                        !_isEditingLocked &&
                        _selectedOnlineMetadataFields.isNotEmpty
                    ? () => _applyOnlineMetadataFields(
                        _selectedOnlineMetadataFields,
                      )
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
      onTap: _isEditingLocked
          ? null
          : () => _selectOnlineMetadataResult(candidate),
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

  Widget _buildCurrentArtwork(LocalAudioMetadata metadata) {
    final pending = _pendingArtwork;
    if (pending == null) {
      return _buildArtwork(metadata.coverUrl, size: 76);
    }
    return Tooltip(
      message: '封面有未保存的修改',
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.error,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(
            pending.bytes,
            width: 76,
            height: 76,
            fit: BoxFit.cover,
          ),
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
    if (_isScanning || _isEditingLocked) {
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
    if (_isEditingLocked) {
      return;
    }
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
    if (metadata == null || _isEditingLocked) {
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
          albumArtist: _albumArtistController.text.trim(),
          album: _albumController.text.trim(),
          genres: _genresController.text.trim(),
          year: _yearController.text.trim(),
          trackNumber: _trackNumberController.text.trim(),
          lyrics: _lyricsController.text,
        ),
        artworkBytes: _pendingArtwork?.bytes,
        artworkMimeType: _pendingArtwork?.mimeType,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _uploadedPaths.remove(updated.path);
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
    if (_isEditingLocked) {
      return;
    }
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

  void _setOnlineMetadataFieldSelected(
    OnlineMetadataField field,
    bool selected,
  ) {
    setState(() {
      final fields = Set<OnlineMetadataField>.of(_selectedOnlineMetadataFields);
      if (selected) {
        fields.add(field);
      } else {
        fields.remove(field);
      }
      _selectedOnlineMetadataFields = fields;
    });
  }

  Future<void> _applyOnlineMetadataFields(
    Set<OnlineMetadataField> fields,
  ) async {
    if (_isEditingLocked || _isReading || _isScanning) {
      return;
    }
    final candidate = _selectedOnlineMetadataResult;
    final metadata = _metadata;
    if (candidate == null ||
        metadata == null ||
        !canWriteAudioMetadataPath(metadata.path)) {
      return;
    }
    final selectionRequest = _selectionRequest;
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
        case OnlineMetadataField.artwork:
          // Load the selected cover after filling the text fields.
          break;
      }
    }
    if (!fields.contains(OnlineMetadataField.artwork) ||
        candidate.artworkUrl.trim().isEmpty) {
      _showMessage('已填入${candidate.source.label}数据，保存后写入文件。');
      return;
    }
    setState(() {
      _isFillingOnlineMetadata = true;
      _message = null;
    });
    try {
      final artwork = await _onlineMetadataService.downloadArtwork(
        candidate.artworkUrl,
      );
      if (!mounted || selectionRequest != _selectionRequest) {
        return;
      }
      if (artwork == null) {
        throw Exception('封面地址无效。');
      }
      var artworkChanged = true;
      try {
        final savedFile = await widget.controller.artworkCacheManager
            .cacheArtwork(metadata.coverUrl);
        final savedBytes = await savedFile?.readAsBytes();
        final replacementBytes = artwork.bytes;
        artworkChanged =
            savedBytes == null ||
            savedBytes.length != replacementBytes.length ||
            savedBytes.indexed.any(
              (entry) => entry.$2 != replacementBytes[entry.$1],
            );
      } catch (_) {
        // Keep a visible pending change if the saved cover cannot be compared.
      }
      if (!mounted || selectionRequest != _selectionRequest) {
        return;
      }
      setState(() => _pendingArtwork = artworkChanged ? artwork : null);
      _showMessage('已填入${candidate.source.label}数据及封面，保存后写入文件。');
    } catch (error) {
      if (mounted && selectionRequest == _selectionRequest) {
        _showMessage('封面未填入：${_errorText(error)}', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isFillingOnlineMetadata = false);
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
    _pendingArtwork = null;
    _setEditingValues(metadata);
    unawaited(_checkLibraryPresence());
  }

  void _setEditingValues(LocalAudioMetadata metadata) {
    _titleController.text = metadata.title;
    _albumArtistFollowsArtist = false;
    _artistController.text = metadata.artist;
    _albumArtistFollowsArtist =
        metadata.albumArtist.trim().isEmpty ||
        metadata.albumArtist.trim() == metadata.artist.trim();
    _albumArtistController.text = metadata.albumArtist.trim().isEmpty
        ? metadata.artist
        : metadata.albumArtist;
    _albumController.text = metadata.album;
    _genresController.text = metadata.genres;
    _yearController.text = metadata.year;
    _trackNumberController.text = metadata.trackNumber;
    _lyricsController.text = metadata.lyrics;
  }

  void _syncAlbumArtist() {
    if (_albumArtistFollowsArtist) {
      _albumArtistController.text = _artistController.text;
    }
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

class _MetadataTextField extends StatelessWidget {
  const _MetadataTextField({
    required this.controller,
    required this.savedValue,
    required this.decoration,
    this.enabled = true,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
    this.onChanged,
  });

  final TextEditingController controller;
  final String savedValue;
  final InputDecoration decoration;
  final bool enabled;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final changed = value.text != savedValue;
        final border = OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.error,
            width: 1.5,
          ),
        );
        return Tooltip(
          message: changed ? '有未保存的修改' : '',
          child: TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: keyboardType,
            minLines: minLines,
            maxLines: maxLines,
            onChanged: onChanged,
            decoration: changed
                ? decoration.copyWith(
                    border: border,
                    enabledBorder: border,
                    focusedBorder: border,
                    disabledBorder: border,
                    errorBorder: border,
                    focusedErrorBorder: border,
                  )
                : decoration,
          ),
        );
      },
    );
  }
}

class _MetadataFieldRow extends StatelessWidget {
  const _MetadataFieldRow({required this.left, this.right});

  final Widget left;
  final Widget? right;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right ?? const SizedBox.shrink()),
      ],
    );
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

String _onlineMetadataFieldLabel(OnlineMetadataField field) {
  return switch (field) {
    OnlineMetadataField.title => '标题',
    OnlineMetadataField.artist => '歌手',
    OnlineMetadataField.album => '专辑',
    OnlineMetadataField.genres => '流派',
    OnlineMetadataField.year => '年份',
    OnlineMetadataField.trackNumber => '曲目号',
    OnlineMetadataField.artwork => '封面',
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
  final TextEditingController _albumArtistController = TextEditingController();
  final TextEditingController _albumController = TextEditingController();
  final TextEditingController _genresController = TextEditingController();
  final TextEditingController _yearController = TextEditingController();
  final TextEditingController _trackNumberController = TextEditingController();
  final TextEditingController _lyricsController = TextEditingController();

  LocalAudioMetadata? _metadata;
  String? _message;
  bool _isBusy = false;
  bool _albumArtistFollowsArtist = true;

  @override
  void initState() {
    super.initState();
    _artistController.addListener(_syncAlbumArtist);
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
    _albumArtistController.dispose();
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
                _MetadataFieldRow(
                  left: _MetadataTextField(
                    controller: _titleController,
                    savedValue: metadata.title,
                    enabled:
                        !_isBusy && canWriteAudioMetadataPath(metadata.path),
                    decoration: const InputDecoration(labelText: '标题'),
                  ),
                  right: _MetadataTextField(
                    controller: _artistController,
                    savedValue: metadata.artist,
                    enabled:
                        !_isBusy && canWriteAudioMetadataPath(metadata.path),
                    decoration: const InputDecoration(labelText: '歌手'),
                  ),
                ),
                _MetadataFieldRow(
                  left: _MetadataTextField(
                    controller: _albumController,
                    savedValue: metadata.album,
                    enabled:
                        !_isBusy && canWriteAudioMetadataPath(metadata.path),
                    decoration: const InputDecoration(labelText: '专辑'),
                  ),
                  right: _MetadataTextField(
                    controller: _albumArtistController,
                    savedValue: metadata.albumArtist,
                    enabled:
                        !_isBusy && canWriteAudioMetadataPath(metadata.path),
                    decoration: const InputDecoration(labelText: '专辑歌手'),
                    onChanged: (value) => _albumArtistFollowsArtist =
                        value.trim().isEmpty ||
                        value.trim() == _artistController.text.trim(),
                  ),
                ),
                _MetadataFieldRow(
                  left: _MetadataTextField(
                    controller: _genresController,
                    savedValue: metadata.genres,
                    enabled:
                        !_isBusy && canWriteAudioMetadataPath(metadata.path),
                    decoration: const InputDecoration(labelText: '流派（用逗号分隔）'),
                  ),
                  right: _MetadataTextField(
                    controller: _yearController,
                    savedValue: metadata.year,
                    enabled:
                        !_isBusy && canWriteAudioMetadataPath(metadata.path),
                    decoration: const InputDecoration(labelText: '年份'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                _MetadataFieldRow(
                  left: _MetadataTextField(
                    controller: _trackNumberController,
                    savedValue: metadata.trackNumber,
                    enabled:
                        !_isBusy && canWriteAudioMetadataPath(metadata.path),
                    decoration: const InputDecoration(labelText: '曲目号'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                _MetadataTextField(
                  controller: _lyricsController,
                  savedValue: metadata.lyrics,
                  enabled: !_isBusy && canWriteAudioMetadataPath(metadata.path),
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
          albumArtist: _albumArtistController.text,
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
        albumArtist: _albumArtistController.text,
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
    _albumArtistFollowsArtist = false;
    _artistController.text = metadata.artist;
    _albumArtistFollowsArtist =
        metadata.albumArtist.trim().isEmpty ||
        metadata.albumArtist.trim() == metadata.artist.trim();
    _albumArtistController.text = metadata.albumArtist.trim().isEmpty
        ? metadata.artist
        : metadata.albumArtist;
    _albumController.text = metadata.album;
    _genresController.text = metadata.genres;
    _yearController.text = metadata.year;
    _trackNumberController.text = metadata.trackNumber;
    _lyricsController.text = metadata.lyrics;
  }

  void _syncAlbumArtist() {
    if (_albumArtistFollowsArtist) {
      _albumArtistController.text = _artistController.text;
    }
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

final _libraryVersionMarker = RegExp(
  r'\b(?:live|remaster(?:ed)?|remix|version|ver|instrumental|acoustic|demo)\b|伴奏|现场|演唱会|重制|重录|混音|版',
  caseSensitive: false,
);

String _libraryBaseTitle(String value) {
  final title = _libraryWidthNormalized(value).replaceAllMapped(
    RegExp(r'\([^()]*\)|\[[^\[\]]*\]|【[^【】]*】'),
    (match) => _libraryVersionMarker.hasMatch(match[0]!) ? '' : match[0]!,
  );
  return title
      .replaceFirstMapped(
        RegExp(r'\s+[-–—]\s+(.+)$'),
        (match) => _libraryVersionMarker.hasMatch(match[1]!) ? '' : match[0]!,
      )
      .trim();
}

String _libraryWidthNormalized(String value) {
  return String.fromCharCodes(
    value.runes.map((rune) {
      if (rune >= 0xff01 && rune <= 0xff5e) {
        return rune - 0xfee0;
      }
      return rune == 0x3000 ? 0x20 : rune;
    }),
  );
}

String _libraryTextKey(String value) =>
    _libraryWidthNormalized(value).toLowerCase().replaceAll(RegExp(r'\s+'), '');

bool _librarySongMatches(LocalAudioMetadata metadata, Track track) {
  final title = _libraryTextKey(_libraryBaseTitle(metadata.title));
  if (title.isEmpty ||
      title != _libraryTextKey(_libraryBaseTitle(track.title))) {
    return false;
  }
  final artist = _libraryTextKey(metadata.artist);
  if (artist.isEmpty) {
    return false;
  }
  if (artist == _libraryTextKey(track.artist)) {
    return true;
  }
  Set<String> artists(String value) => _libraryWidthNormalized(value)
      .split(RegExp(r'[/、,，;&；]'))
      .map(_libraryTextKey)
      .where((name) => name.isNotEmpty)
      .toSet();
  final left = artists(metadata.artist);
  final right = artists(track.artist);
  return left.isNotEmpty &&
      left.length == right.length &&
      left.containsAll(right);
}

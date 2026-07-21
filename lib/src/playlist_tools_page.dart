import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'compact_switch.dart';
import 'models.dart';
import 'playlist_sync.dart';

const int _playlistSearchPageSize = 60;
const double _androidPhonePlaylistWidthBreakpoint = 510;
const EdgeInsets _playlistFieldContentPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 9,
);

InputDecoration _playlistFieldDecoration({String? hintText}) {
  return InputDecoration(
    hintText: hintText,
    border: const OutlineInputBorder(),
    isDense: true,
    contentPadding: _playlistFieldContentPadding,
  );
}

bool _usesAndroidPhonePlaylistFlow(BuildContext context) {
  return defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.sizeOf(context).width < _androidPhonePlaylistWidthBreakpoint;
}

class PlaylistSyncPage extends StatefulWidget {
  const PlaylistSyncPage({
    required this.controller,
    required this.onBack,
    super.key,
  });

  final AppController controller;
  final VoidCallback onBack;

  @override
  State<PlaylistSyncPage> createState() => _PlaylistSyncPageState();
}

class _PlaylistSyncPageState extends State<PlaylistSyncPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  PlaylistSyncProgress? _progress;
  PlaylistSyncResult? _result;
  String? _error;
  bool _allowDifferentArtistSameTitle = false;
  bool _preferHighQuality = false;
  bool _running = false;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final result = _result;
    return _PlaylistToolPageFrame(
      title: '同步歌单',
      icon: Icons.sync_rounded,
      onBack: widget.onBack,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _PlaylistToolSurface(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PlaylistLabeledField(
                    label: '网易云音乐 / QQ 音乐歌单地址',
                    child: TextField(
                      key: const ValueKey('playlist-sync-url'),
                      controller: _urlController,
                      enabled: !_running,
                      keyboardType: TextInputType.url,
                      decoration: _playlistFieldDecoration(
                        hintText: '粘贴歌单链接或歌单 ID',
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _PlaylistLabeledField(
                    label: '目标歌单名称',
                    child: TextField(
                      key: const ValueKey('playlist-sync-name'),
                      controller: _nameController,
                      enabled: !_running,
                      decoration: _playlistFieldDecoration(
                        hintText: '留空使用外部歌单名称，同名时同步到已有歌单',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CompactSwitchListTile(
                    key: const ValueKey('playlist-sync-different-artist'),
                    contentPadding: EdgeInsets.zero,
                    value: _allowDifferentArtistSameTitle,
                    onChanged: _running
                        ? null
                        : (value) => setState(
                            () => _allowDifferentArtistSameTitle = value,
                          ),
                    title: const Text('允许匹配不同歌手的同名歌曲'),
                    subtitle: const Text('歌手严格匹配失败时，允许使用曲库中的同名歌曲'),
                  ),
                  CompactSwitchListTile(
                    key: const ValueKey('playlist-sync-high-quality'),
                    contentPadding: EdgeInsets.zero,
                    value: _preferHighQuality,
                    onChanged: _running
                        ? null
                        : (value) => setState(() => _preferHighQuality = value),
                    title: const Text('高品质优先'),
                    subtitle: const Text('同一首歌有多个格式时，按 APE、FLAC、MP3 选择'),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: progress.total <= 0 ? null : progress.fraction,
                    ),
                    const SizedBox(height: 8),
                    Text(progress.message),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      key: const ValueKey('playlist-sync-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (result != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      result.playlistName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        Text('来源歌曲：${result.sourceCount} 首'),
                        Text('匹配成功：${result.matchedCount} 首'),
                        Text('本次新增：${result.addedCount} 首'),
                        Text('歌单已有：${result.alreadyPresentCount} 首'),
                        Text('未匹配：${result.missingCount} 首'),
                        if (result.duplicateMatchCount > 0)
                          Text('重复跳过：${result.duplicateMatchCount} 首'),
                      ],
                    ),
                    if (result.missingTracks.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        '未匹配歌曲',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ListView.separated(
                        key: const ValueKey('playlist-sync-missing-tracks'),
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: result.missingTracks.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final track = result.missingTracks[index];
                          final title = track.title.trim().isEmpty
                              ? '未知歌曲'
                              : track.title.trim();
                          final artists = track.artists.trim();
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 32,
                                  child: Text('${index + 1}.'),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(title),
                                      if (artists.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          artists,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.center,
                    child: FilledButton.icon(
                      key: const ValueKey('playlist-sync-submit'),
                      onPressed: _running ? null : _start,
                      icon: _running
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_rounded),
                      label: Text(_running ? '同步中' : '开始同步'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _start() async {
    if (_urlController.text.trim().isEmpty) {
      setState(() => _error = '请输入歌单地址。');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await widget.controller.syncExternalPlaylist(
        _urlController.text,
        targetPlaylistName: _nameController.text,
        allowDifferentArtistSameTitle: _allowDifferentArtistSameTitle,
        preferHighQuality: _preferHighQuality,
        onProgress: (progress) {
          if (mounted) {
            setState(() => _progress = progress);
          }
        },
      );
      if (mounted) {
        setState(() => _result = result);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }
}

class PlaylistMergePage extends StatefulWidget {
  const PlaylistMergePage({
    required this.controller,
    required this.playlists,
    required this.onBack,
    super.key,
  });

  final AppController controller;
  final List<LibrarySectionItem> playlists;
  final VoidCallback onBack;

  @override
  State<PlaylistMergePage> createState() => _PlaylistMergePageState();
}

class _PlaylistMergePageState extends State<PlaylistMergePage> {
  String? _sourcePlaylistId;
  String? _targetPlaylistId;
  List<Track> _sourceTracks = const [];
  List<Track> _targetTracks = const [];
  final Map<String, Track> _selectedTracks = {};
  bool _loadingSource = false;
  bool _loadingTarget = false;
  bool _moving = false;
  bool _showMobileTargetStep = false;
  String? _message;
  int _sourceRequest = 0;
  int _targetRequest = 0;

  @override
  void initState() {
    super.initState();
    if (widget.playlists.length >= 2) {
      _sourcePlaylistId = widget.playlists.first.id;
      _targetPlaylistId = widget.playlists[1].id;
      unawaited(_loadSource());
      unawaited(_loadTarget());
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetIds = _targetTracks.map(_trackKey).toSet();
    final sourcePane = _PlaylistTracksPane(
      key: const ValueKey('playlist-merge-source-pane'),
      title: '来源歌单',
      header: _playlistSelector(
        value: _sourcePlaylistId,
        playlists: widget.playlists
            .where((item) => item.id != _targetPlaylistId)
            .toList(),
        label: '选择来源歌单',
        onChanged: (id) {
          setState(() {
            _sourcePlaylistId = id;
            _selectedTracks.clear();
          });
          unawaited(_loadSource());
        },
      ),
      tracks: _sourceTracks,
      loading: _loadingSource,
      emptyText: '来源歌单暂无歌曲',
      selectedTracks: _selectedTracks,
      disabledTrackIds: targetIds,
      onTrackChanged: _toggleSourceTrack,
    );
    final targetPane = _PlaylistTracksPane(
      key: const ValueKey('playlist-merge-target-pane'),
      title: '目标歌单',
      header: _playlistSelector(
        value: _targetPlaylistId,
        playlists: widget.playlists
            .where((item) => item.id != _sourcePlaylistId)
            .toList(),
        label: '选择目标歌单',
        onChanged: (id) {
          setState(() => _targetPlaylistId = id);
          unawaited(_loadTarget());
        },
      ),
      tracks: _targetTracks,
      loading: _loadingTarget,
      emptyText: '目标歌单暂无歌曲',
    );
    final useMobileFlow = _usesAndroidPhonePlaylistFlow(context);
    return _PlaylistToolPageFrame(
      title: '合并歌单',
      icon: Icons.merge_type_rounded,
      onBack: widget.onBack,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_message != null) ...[
            Text(
              _message!,
              key: const ValueKey('playlist-merge-message'),
              style: TextStyle(
                color: _message!.startsWith('失败')
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: useMobileFlow
                ? _AndroidPhonePlaylistTransferFlow(
                    source: sourcePane,
                    target: targetPane,
                    showTarget: _showMobileTargetStep,
                    moving: _moving,
                    selectedCount: _selectedTracks.length,
                    onBackToSource: () =>
                        setState(() => _showMobileTargetStep = false),
                    onContinue: () =>
                        setState(() => _showMobileTargetStep = true),
                    onComplete: _moveSelected,
                  )
                : _PlaylistTransferLayout(
                    left: sourcePane,
                    right: targetPane,
                    moving: _moving,
                    selectedCount: _selectedTracks.length,
                    onSwap: _swapPlaylists,
                    onMove: _moveSelected,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _playlistSelector({
    required String? value,
    required List<LibrarySectionItem> playlists,
    required String label,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      key: ValueKey('$label:$value'),
      initialValue: playlists.any((item) => item.id == value) ? value : null,
      isExpanded: true,
      decoration: _playlistFieldDecoration(),
      items: [
        for (final playlist in playlists)
          DropdownMenuItem(
            value: playlist.id,
            child: Text(
              playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _moving
          ? null
          : (id) {
              if (id != null) {
                onChanged(id);
              }
            },
    );
  }

  void _toggleSourceTrack(Track track, bool selected) {
    setState(() {
      final key = _trackKey(track);
      if (selected) {
        _selectedTracks[key] = track;
      } else {
        _selectedTracks.remove(key);
      }
    });
  }

  void _swapPlaylists() {
    final sourceId = _sourcePlaylistId;
    final targetId = _targetPlaylistId;
    if (_moving || sourceId == null || targetId == null) {
      return;
    }
    setState(() {
      _sourcePlaylistId = targetId;
      _targetPlaylistId = sourceId;
      _sourceTracks = const [];
      _targetTracks = const [];
      _selectedTracks.clear();
      _showMobileTargetStep = false;
      _message = null;
      _sourceRequest += 1;
      _targetRequest += 1;
    });
    unawaited(_loadSource());
    unawaited(_loadTarget());
  }

  Future<void> _loadSource() async {
    final playlist = _playlistById(widget.playlists, _sourcePlaylistId);
    if (playlist == null) {
      return;
    }
    final request = ++_sourceRequest;
    setState(() => _loadingSource = true);
    try {
      final tracks = await widget.controller.playlistTracks(playlist);
      if (!mounted || request != _sourceRequest) {
        return;
      }
      setState(() {
        _sourceTracks = tracks;
        _selectedTracks.removeWhere(
          (key, value) => !tracks.any((track) => _trackKey(track) == key),
        );
      });
    } catch (error) {
      if (mounted && request == _sourceRequest) {
        setState(() => _message = '失败：${_errorText(error)}');
      }
    } finally {
      if (mounted && request == _sourceRequest) {
        setState(() => _loadingSource = false);
      }
    }
  }

  Future<void> _loadTarget() async {
    final playlist = _playlistById(widget.playlists, _targetPlaylistId);
    if (playlist == null) {
      return;
    }
    final request = ++_targetRequest;
    setState(() => _loadingTarget = true);
    try {
      final tracks = await widget.controller.playlistTracks(playlist);
      if (!mounted || request != _targetRequest) {
        return;
      }
      final ids = tracks.map(_trackKey).toSet();
      setState(() {
        _targetTracks = tracks;
        _selectedTracks.removeWhere((key, value) => ids.contains(key));
      });
    } catch (error) {
      if (mounted && request == _targetRequest) {
        setState(() => _message = '失败：${_errorText(error)}');
      }
    } finally {
      if (mounted && request == _targetRequest) {
        setState(() => _loadingTarget = false);
      }
    }
  }

  Future<void> _moveSelected() async {
    final source = _playlistById(widget.playlists, _sourcePlaylistId);
    final target = _playlistById(widget.playlists, _targetPlaylistId);
    if (source == null || target == null || _selectedTracks.isEmpty) {
      return;
    }
    final selectedTracks = _selectedTracks.values.toList();
    final selectedKeys = selectedTracks.map(_trackKey).toSet();
    final sourceIndexes = <int>[
      for (var index = 0; index < _sourceTracks.length; index += 1)
        if (selectedKeys.contains(_trackKey(_sourceTracks[index]))) index,
    ];
    final keepInSource = await _confirmMove(
      source: source,
      target: target,
      count: selectedTracks.length,
    );
    if (keepInSource == null || !mounted) {
      return;
    }
    setState(() {
      _moving = true;
      _message = null;
    });
    try {
      final added = await widget.controller.addTracksToRemotePlaylist(
        target,
        selectedTracks,
      );
      final removed = keepInSource
          ? 0
          : await widget.controller.removeRemotePlaylistTracks(
              source,
              sourceIndexes,
            );
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedTracks.clear();
        _showMobileTargetStep = false;
        _message = keepInSource
            ? added == 0
                  ? '所选歌曲已在目标歌单中。'
                  : '已加入 $added 首歌曲。'
            : '已加入目标歌单，并从来源歌单移除 $removed 首歌曲。';
      });
      await Future.wait([_loadSource(), _loadTarget()]);
    } catch (error) {
      if (mounted) {
        setState(() => _message = '失败：${_errorText(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _moving = false);
      }
    }
  }

  Future<bool?> _confirmMove({
    required LibrarySectionItem source,
    required LibrarySectionItem target,
    required int count,
  }) {
    var keepInSource = true;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const ValueKey('playlist-merge-confirmation'),
          title: const Text('确认加入歌曲'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('将 $count 首歌曲从“${source.title}”加入“${target.title}”？'),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const ValueKey('playlist-merge-keep-source'),
                contentPadding: EdgeInsets.zero,
                value: keepInSource,
                onChanged: (value) =>
                    setDialogState(() => keepInSource = value ?? true),
                title: const Text('在来源歌单中保留'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton.tonal(
              key: const ValueKey('playlist-merge-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(keepInSource),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaylistBatchAddPage extends StatefulWidget {
  const PlaylistBatchAddPage({
    required this.controller,
    required this.playlists,
    required this.onBack,
    this.initialPlaylistId,
    super.key,
  });

  final AppController controller;
  final List<LibrarySectionItem> playlists;
  final VoidCallback onBack;
  final String? initialPlaylistId;

  @override
  State<PlaylistBatchAddPage> createState() => _PlaylistBatchAddPageState();
}

class _PlaylistBatchAddPageState extends State<PlaylistBatchAddPage> {
  final TextEditingController _queryController = TextEditingController();
  final Map<String, Track> _selectedTracks = {};
  String? _targetPlaylistId;
  List<Track> _results = const [];
  List<Track> _targetTracks = const [];
  bool _searching = false;
  bool _loadingTarget = false;
  bool _moving = false;
  bool _showMobileTargetStep = false;
  String? _message;
  int _targetRequest = 0;
  int _searchPageIndex = 0;
  bool _hasNextSearchPage = false;
  String _activeQuery = '';

  @override
  void initState() {
    super.initState();
    if (widget.playlists.isNotEmpty) {
      _targetPlaylistId =
          widget.playlists.any(
            (playlist) => playlist.id == widget.initialPlaylistId,
          )
          ? widget.initialPlaylistId
          : widget.playlists.first.id;
      unawaited(_loadTarget());
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targetIds = _targetTracks.map(_trackKey).toSet();
    final libraryPane = _PlaylistTracksPane(
      key: const ValueKey('playlist-batch-library-pane'),
      title: '曲库搜索',
      header: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('playlist-batch-search'),
              controller: _queryController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_search(pageIndex: 0)),
              decoration: _playlistFieldDecoration(hintText: '输入歌曲或歌手'),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '搜索曲库',
            onPressed: _searching
                ? null
                : () => unawaited(_search(pageIndex: 0)),
            icon: _searching
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search_rounded),
          ),
        ],
      ),
      tracks: _results,
      loading: _searching,
      emptyText: '搜索曲库后选择歌曲',
      selectedTracks: _selectedTracks,
      disabledTrackIds: targetIds,
      onTrackChanged: _toggleLibraryTrack,
      footer: _activeQuery.isEmpty
          ? null
          : _PlaylistSearchPagination(
              pageIndex: _searchPageIndex,
              hasNextPage: _hasNextSearchPage,
              loading: _searching,
              onPrevious: _searchPageIndex <= 0
                  ? null
                  : () => unawaited(_search(pageIndex: _searchPageIndex - 1)),
              onNext: !_hasNextSearchPage
                  ? null
                  : () => unawaited(_search(pageIndex: _searchPageIndex + 1)),
            ),
    );
    final targetPane = _PlaylistTracksPane(
      key: const ValueKey('playlist-batch-target-pane'),
      title: '目标歌单',
      header: DropdownButtonFormField<String>(
        key: ValueKey('batch-target:$_targetPlaylistId'),
        initialValue: _targetPlaylistId,
        isExpanded: true,
        decoration: _playlistFieldDecoration(),
        items: [
          for (final playlist in widget.playlists)
            DropdownMenuItem(
              value: playlist.id,
              child: Text(
                playlist.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _moving
            ? null
            : (id) {
                if (id == null) {
                  return;
                }
                setState(() => _targetPlaylistId = id);
                unawaited(_loadTarget());
              },
      ),
      tracks: _targetTracks,
      loading: _loadingTarget,
      emptyText: '目标歌单暂无歌曲',
    );
    final useMobileFlow = _usesAndroidPhonePlaylistFlow(context);
    return _PlaylistToolPageFrame(
      title: '批量添加歌曲',
      icon: Icons.playlist_add_rounded,
      onBack: widget.onBack,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_message != null) ...[
            Text(
              _message!,
              key: const ValueKey('playlist-batch-message'),
              style: TextStyle(
                color: _message!.startsWith('失败')
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: useMobileFlow
                ? _AndroidPhonePlaylistTransferFlow(
                    source: libraryPane,
                    target: targetPane,
                    showTarget: _showMobileTargetStep,
                    moving: _moving,
                    selectedCount: _selectedTracks.length,
                    onBackToSource: () =>
                        setState(() => _showMobileTargetStep = false),
                    onContinue: () =>
                        setState(() => _showMobileTargetStep = true),
                    onComplete: _moveSelected,
                  )
                : _PlaylistTransferLayout(
                    left: libraryPane,
                    right: targetPane,
                    moving: _moving,
                    selectedCount: _selectedTracks.length,
                    onMove: _moveSelected,
                  ),
          ),
        ],
      ),
    );
  }

  void _toggleLibraryTrack(Track track, bool selected) {
    setState(() {
      final key = _trackKey(track);
      if (selected) {
        _selectedTracks[key] = track;
      } else {
        _selectedTracks.remove(key);
      }
    });
  }

  Future<void> _search({required int pageIndex}) async {
    final server = widget.controller.selectedServer;
    final query = _queryController.text.trim();
    if (server == null) {
      setState(() => _message = '失败：请先登录。');
      return;
    }
    if (query.isEmpty) {
      setState(() => _message = '请输入搜索关键词。');
      return;
    }
    setState(() {
      _searching = true;
      _message = null;
    });
    try {
      final results = await widget.controller.searchTracksForSource(
        server,
        query,
        offset: pageIndex * _playlistSearchPageSize,
        limit: _playlistSearchPageSize,
      );
      if (mounted) {
        setState(() {
          _results = results;
          _activeQuery = query;
          _searchPageIndex = pageIndex;
          _hasNextSearchPage = results.length == _playlistSearchPageSize;
          _message = results.isEmpty
              ? pageIndex == 0
                    ? '没有找到歌曲。'
                    : '第 ${pageIndex + 1} 页没有更多歌曲。'
              : '第 ${pageIndex + 1} 页，显示 ${results.length} 首歌曲。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '失败：${_errorText(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _loadTarget() async {
    final target = _playlistById(widget.playlists, _targetPlaylistId);
    if (target == null) {
      return;
    }
    final request = ++_targetRequest;
    setState(() => _loadingTarget = true);
    try {
      final tracks = await widget.controller.playlistTracks(target);
      if (!mounted || request != _targetRequest) {
        return;
      }
      final ids = tracks.map(_trackKey).toSet();
      setState(() {
        _targetTracks = tracks;
        _selectedTracks.removeWhere((key, value) => ids.contains(key));
      });
    } catch (error) {
      if (mounted && request == _targetRequest) {
        setState(() => _message = '失败：${_errorText(error)}');
      }
    } finally {
      if (mounted && request == _targetRequest) {
        setState(() => _loadingTarget = false);
      }
    }
  }

  Future<void> _moveSelected() async {
    final target = _playlistById(widget.playlists, _targetPlaylistId);
    if (target == null || _selectedTracks.isEmpty) {
      return;
    }
    setState(() {
      _moving = true;
      _message = null;
    });
    try {
      final added = await widget.controller.addTracksToRemotePlaylist(
        target,
        _selectedTracks.values.toList(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedTracks.clear();
        _showMobileTargetStep = false;
        _message = added == 0 ? '所选歌曲已在目标歌单中。' : '已加入 $added 首歌曲。';
      });
      await _loadTarget();
    } catch (error) {
      if (mounted) {
        setState(() => _message = '失败：${_errorText(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _moving = false);
      }
    }
  }
}

class _PlaylistToolPageFrame extends StatelessWidget {
  const _PlaylistToolPageFrame({
    required this.title,
    required this.icon,
    required this.onBack,
    required this.child,
  });

  final String title;
  final IconData icon;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '返回我的歌单',
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(40),
                  padding: EdgeInsets.zero,
                ),
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 8),
              Icon(icon, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistLabeledField extends StatelessWidget {
  const _PlaylistLabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _AndroidPhonePlaylistTransferFlow extends StatelessWidget {
  const _AndroidPhonePlaylistTransferFlow({
    required this.source,
    required this.target,
    required this.showTarget,
    required this.moving,
    required this.selectedCount,
    required this.onBackToSource,
    required this.onContinue,
    required this.onComplete,
  });

  final Widget source;
  final Widget target;
  final bool showTarget;
  final bool moving;
  final int selectedCount;
  final VoidCallback onBackToSource;
  final VoidCallback onContinue;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final enabled = !moving && selectedCount > 0;
    return Column(
      children: [
        Expanded(child: showTarget ? target : source),
        const SizedBox(height: 6),
        Row(
          children: showTarget
              ? [
                  TextButton.icon(
                    key: const ValueKey('playlist-transfer-back'),
                    onPressed: moving ? null : onBackToSource,
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('上一步'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    key: const ValueKey('playlist-transfer-complete'),
                    onPressed: enabled ? onComplete : null,
                    icon: moving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(moving ? '添加中' : '完成 ($selectedCount)'),
                  ),
                ]
              : [
                  const Spacer(),
                  TextButton.icon(
                    key: const ValueKey('playlist-transfer-continue'),
                    onPressed: enabled ? onContinue : null,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text('下一步 ($selectedCount)'),
                  ),
                ],
        ),
      ],
    );
  }
}

class _PlaylistTransferLayout extends StatelessWidget {
  const _PlaylistTransferLayout({
    required this.left,
    required this.right,
    required this.moving,
    required this.selectedCount,
    required this.onMove,
    this.onSwap,
  });

  final Widget left;
  final Widget right;
  final bool moving;
  final int selectedCount;
  final VoidCallback onMove;
  final VoidCallback? onSwap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical = constraints.maxWidth < 760;
        final enabled = !moving && selectedCount > 0;
        final moveButton = vertical
            ? TextButton.icon(
                key: const ValueKey('playlist-transfer-move'),
                onPressed: enabled ? onMove : null,
                icon: moving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_downward_rounded),
                label: Text(moving ? '添加中' : '加入右侧 ($selectedCount)'),
              )
            : Tooltip(
                message: '将选中的 $selectedCount 首歌曲加入右侧歌单',
                child: IconButton(
                  key: const ValueKey('playlist-transfer-move'),
                  onPressed: enabled ? onMove : null,
                  icon: moving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded),
                ),
              );
        final swapButton = onSwap == null
            ? null
            : IconButton(
                key: const ValueKey('playlist-transfer-swap'),
                tooltip: '互换来源歌单和目标歌单',
                onPressed: moving ? null : onSwap,
                icon: Icon(
                  vertical ? Icons.swap_vert_rounded : Icons.swap_horiz_rounded,
                ),
              );

        if (vertical) {
          return Column(
            children: [
              Expanded(child: left),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (swapButton != null) ...[
                      swapButton,
                      const SizedBox(width: 8),
                    ],
                    moveButton,
                  ],
                ),
              ),
              Expanded(child: right),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: left),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (swapButton != null) ...[
                    swapButton,
                    const SizedBox(height: 8),
                  ],
                  moveButton,
                ],
              ),
            ),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

class _PlaylistTracksPane extends StatelessWidget {
  const _PlaylistTracksPane({
    required this.title,
    required this.header,
    required this.tracks,
    required this.loading,
    required this.emptyText,
    this.selectedTracks,
    this.disabledTrackIds = const {},
    this.onTrackChanged,
    this.footer,
    super.key,
  });

  final String title;
  final Widget header;
  final List<Track> tracks;
  final bool loading;
  final String emptyText;
  final Map<String, Track>? selectedTracks;
  final Set<String> disabledTrackIds;
  final void Function(Track track, bool selected)? onTrackChanged;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return _PlaylistToolSurface(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text('${tracks.length} 首'),
            ],
          ),
          const SizedBox(height: 10),
          header,
          const SizedBox(height: 10),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : tracks.isEmpty
                ? Center(child: Text(emptyText))
                : ListView.separated(
                    itemCount: tracks.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final track = tracks[index];
                      final key = _trackKey(track);
                      final disabled = disabledTrackIds.contains(key);
                      final selected = selectedTracks?.containsKey(key) == true;
                      final title = _PlaylistToolTrackTitle(track: track);
                      final subtitle = Text(
                        disabled
                            ? '${_artistLabel(track)} · 已在右侧'
                            : _artistLabel(track),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      );
                      if (onTrackChanged == null || selectedTracks == null) {
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: const Icon(Icons.music_note_rounded),
                          title: title,
                          subtitle: subtitle,
                        );
                      }
                      return CheckboxListTile(
                        key: ValueKey('playlist-tool-track-$key'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 2,
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        value: selected || disabled,
                        onChanged: disabled
                            ? null
                            : (value) => onTrackChanged!(track, value ?? false),
                        title: title,
                        subtitle: subtitle,
                      );
                    },
                  ),
          ),
          if (footer != null) ...[const SizedBox(height: 8), footer!],
        ],
      ),
    );
  }
}

class _PlaylistSearchPagination extends StatelessWidget {
  const _PlaylistSearchPagination({
    required this.pageIndex,
    required this.hasNextPage,
    required this.loading,
    required this.onPrevious,
    required this.onNext,
  });

  final int pageIndex;
  final bool hasNextPage;
  final bool loading;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('playlist-search-pagination'),
      children: [
        IconButton(
          key: const ValueKey('playlist-search-previous'),
          tooltip: '上一页',
          onPressed: loading ? null : onPrevious,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: Text('第 ${pageIndex + 1} 页', textAlign: TextAlign.center),
        ),
        IconButton(
          key: const ValueKey('playlist-search-next'),
          tooltip: '下一页',
          onPressed: loading || !hasNextPage ? null : onNext,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

class _PlaylistToolTrackTitle extends StatelessWidget {
  const _PlaylistToolTrackTitle({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final format = track.audioFormat?.trim().toUpperCase() ?? '';
    return Row(
      children: [
        Expanded(
          child: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (format.isNotEmpty) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              format,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 8,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PlaylistToolSurface extends StatelessWidget {
  const _PlaylistToolSurface({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface.withValues(alpha: 0.78),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
  }
}

LibrarySectionItem? _playlistById(
  List<LibrarySectionItem> playlists,
  String? id,
) {
  if (id == null) {
    return null;
  }
  for (final playlist in playlists) {
    if (playlist.id == id) {
      return playlist;
    }
  }
  return null;
}

String _trackKey(Track track) {
  final sourceId = track.sourceServerId ?? '';
  final itemId = track.sourceItemId?.trim().isNotEmpty == true
      ? track.sourceItemId!
      : track.id;
  return '$sourceId:$itemId';
}

String _artistLabel(Track track) {
  final artist = track.artist.trim();
  return artist.isEmpty ? '未知歌手' : artist;
}

String _errorText(Object error) {
  return error
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('FormatException: ', '');
}

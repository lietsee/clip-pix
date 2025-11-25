import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/grid_layout_settings_repository.dart';
import '../../data/models/grid_layout_settings.dart';
import '../../system/audio_service.dart';
import '../../system/clipboard_monitor.dart';
import '../../system/state/folder_view_mode.dart';
import '../../system/state/grid_resize_controller.dart';
import '../../system/state/selected_folder_notifier.dart';

class GridSettingsDialog extends StatefulWidget {
  const GridSettingsDialog({super.key});

  @override
  State<GridSettingsDialog> createState() => _GridSettingsDialogState();
}

class _GridSettingsDialogState extends State<GridSettingsDialog> {
  late int _preferredColumns;
  late int _maxColumns;
  late GridBackgroundTone _backgroundTone;
  late int _bulkSpan;
  late bool _soundEnabled;
  bool _isSaving = false;
  bool _isBulkApplying = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<GridLayoutSettingsRepository>().value;
    _preferredColumns = settings.preferredColumns;
    _maxColumns = settings.maxColumns;
    _backgroundTone = settings.background;
    _bulkSpan = settings.bulkSpan.clamp(1, settings.maxColumns);
    _soundEnabled = settings.soundEnabled;
  }

  @override
  Widget build(BuildContext context) {
    final resizeController = context.watch<GridResizeController>();
    final clipboardMonitor = context.watch<ClipboardMonitor>();
    final selectedFolder = context.watch<SelectedFolderNotifier>();

    return AlertDialog(
      title: const Text('アプリ設定'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildClipboardMonitorSection(context, clipboardMonitor),
            const SizedBox(height: 16),
            _buildMinimapSection(context, selectedFolder),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            _buildColumnsSection(),
            const SizedBox(height: 16),
            _buildBackgroundSection(),
            const SizedBox(height: 16),
            _buildSoundSection(),
            const SizedBox(height: 16),
            _buildBulkResizeSection(resizeController),
            const SizedBox(height: 16),
            _buildUndoRedoSection(resizeController),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _handleSave,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildColumnsSection() {
    final options = List<int>.generate(12, (index) => index + 1);
    final preferredOptions =
        options.where((value) => value <= _maxColumns).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('列数設定', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(width: 80, child: Text('最大列数')),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: _maxColumns,
              items: options
                  .map(
                    (value) => DropdownMenuItem<int>(
                      value: value,
                      child: Text('$value 列'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _maxColumns = value;
                  if (_preferredColumns > _maxColumns) {
                    _preferredColumns = _maxColumns;
                  }
                  if (_bulkSpan > _maxColumns) {
                    _bulkSpan = _maxColumns;
                  }
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(width: 80, child: Text('デフォルト列数')),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: _preferredColumns,
              items: preferredOptions
                  .map(
                    (value) => DropdownMenuItem<int>(
                      value: value,
                      child: Text('$value 列'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _preferredColumns = value;
                });
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBackgroundSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('背景色', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          children: GridBackgroundTone.values
              .map(
                (tone) => ChoiceChip(
                  label: Text(_localizedTone(tone)),
                  selected: _backgroundTone == tone,
                  onSelected: (_) {
                    setState(() {
                      _backgroundTone = tone;
                    });
                  },
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Widget _buildClipboardMonitorSection(
      BuildContext context, ClipboardMonitor monitor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('クリップボード監視', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('クリップボードから画像を自動保存'),
          subtitle: monitor.isRunning
              ? const Text('監視中', style: TextStyle(color: Colors.green))
              : const Text('停止中', style: TextStyle(color: Colors.grey)),
          value: monitor.isRunning,
          onChanged: (value) async {
            if (value) {
              await monitor.start();
            } else {
              await monitor.stop();
            }
            // Force UI update after state change
            if (mounted) {
              setState(() {});
            }
          },
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _buildMinimapSection(
      BuildContext context, SelectedFolderNotifier notifier) {
    final isEnabled = notifier.state.viewMode == FolderViewMode.root;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('マップ表示', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('ミニマップを常に表示 (Ctrl+M)'),
          subtitle: !isEnabled
              ? const Text('ルートビューでのみ有効',
                  style: TextStyle(color: Colors.orange))
              : null,
          value: notifier.state.isMinimapAlwaysVisible,
          onChanged: isEnabled
              ? (value) {
                  notifier.toggleMinimapAlwaysVisible();
                  // Force UI update after state change
                  if (mounted) {
                    setState(() {});
                  }
                }
              : null,
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _buildSoundSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('通知音', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('保存時に効果音を鳴らす'),
          value: _soundEnabled,
          onChanged: (value) {
            setState(() {
              _soundEnabled = value;
            });
          },
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _buildBulkResizeSection(GridResizeController controller) {
    final spanOptions = List<int>.generate(_maxColumns, (index) => index + 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('カード一括サイズ調整', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: [
            DropdownButton<int>(
              value: _bulkSpan,
              items: spanOptions
                  .map(
                    (value) => DropdownMenuItem<int>(
                      value: value,
                      child: Text('$value 列幅'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _bulkSpan = value;
                });
              },
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _isBulkApplying
                  ? null
                  : () async {
                      setState(() {
                        _isBulkApplying = true;
                      });
                      await controller.applyBulkSpan(_bulkSpan);
                      await context.read<GridLayoutSettingsRepository>().update(
                            context
                                .read<GridLayoutSettingsRepository>()
                                .value
                                .copyWith(bulkSpan: _bulkSpan),
                          );
                      if (mounted) {
                        context
                            .read<SelectedFolderNotifier>()
                            .requestScrollToTop();
                        setState(() {
                          _isBulkApplying = false;
                        });
                      }
                    },
              icon: _isBulkApplying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.grid_view),
              label: const Text('全カードを揃える'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUndoRedoSection(GridResizeController controller) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: controller.canUndo ? controller.undo : null,
            icon: const Icon(Icons.undo),
            label: const Text('サイズを戻す'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: controller.canRedo ? controller.redo : null,
            icon: const Icon(Icons.redo),
            label: const Text('サイズをやり直す'),
          ),
        ),
      ],
    );
  }

  Future<void> _handleSave() async {
    setState(() {
      _isSaving = true;
    });
    final repo = context.read<GridLayoutSettingsRepository>();
    final current = repo.value;
    final next = current.copyWith(
      preferredColumns: _preferredColumns,
      maxColumns: _maxColumns,
      background: _backgroundTone,
      bulkSpan: _bulkSpan,
      soundEnabled: _soundEnabled,
    );
    await repo.update(next);
    context.read<AudioService>().setSoundEnabled(_soundEnabled);
    if (mounted) {
      setState(() {
        _isSaving = false;
      });
      Navigator.of(context).pop();
    }
  }

  String _localizedTone(GridBackgroundTone tone) {
    switch (tone) {
      case GridBackgroundTone.white:
        return '白';
      case GridBackgroundTone.lightGray:
        return '明るい灰';
      case GridBackgroundTone.darkGray:
        return '暗い灰';
      case GridBackgroundTone.black:
        return '黒';
    }
  }
}

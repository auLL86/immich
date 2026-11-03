import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/backup/backup_filter_profile.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/backup_filter_sync.service.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:intl/intl.dart';

const _powerKeys = ['requireCharging', 'batteryCheckEnabled', 'minBatteryPercent'];

/// Settings for the shared backup filters (synced through the immich-filters service).
class BackupFilterSettings extends ConsumerStatefulWidget {
  const BackupFilterSettings({super.key});

  @override
  ConsumerState<BackupFilterSettings> createState() => _BackupFilterSettingsState();
}

class _BackupFilterSettingsState extends ConsumerState<BackupFilterSettings> {
  bool _syncing = false;
  bool _syncFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_sync());
  }

  Future<void> _sync() async {
    if (!mounted) {
      return;
    }
    setState(() => _syncing = true);
    final doc = await BackupFilterSyncService.sync(force: true);
    if (!mounted) {
      return;
    }
    setState(() {
      _syncing = false;
      _syncFailed = doc == null && ref.read(appConfigProvider).backup.filterSyncEnabled;
    });
  }

  Future<void> _update(Map<String, Object?> changes) => BackupFilterSyncService.updateProfile(changes);

  Future<void> _updatePower(Map<String, Object?> changes) {
    final overrides = BackupFilterSyncService.deviceOverrides;
    if (overrides != null) {
      return BackupFilterSyncService.updateDeviceOverrides({...overrides, ...changes});
    }
    return _update(changes);
  }

  Future<int?> _numberDialog(String title, int current, {String? hint}) async {
    final controller = TextEditingController(text: current.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ImmichTextInput(
          controller: controller,
          autofocus: true,
          keyboardType: .number,
          keyboardAction: .done,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          hintText: hint,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.t.cancel.toUpperCase(), style: const TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, int.tryParse(controller.text) ?? 0),
            child: Text(context.t.save.toUpperCase()),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _pickDate(String key, DateTime? current, BackupFilterProfile p) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null || !mounted) {
      return;
    }
    final start = key == 'startDate' ? picked : p.startDate;
    final end = key == 'endDate' ? picked : p.endDate;
    if (start != null && end != null && end.isBefore(start)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t.backup_filter_date_invalid)));
      return;
    }
    await _update({key: DateFormat('yyyy-MM-dd').format(picked)});
  }

  Future<void> _pickAlbums(BackupFilterProfile p) async {
    final names = await ref.read(driftProvider).backupRepository.getLocalAlbumNames();
    if (!mounted) {
      return;
    }
    final selected = {...p.alwaysBackupAlbums};
    // keep names that exist on other devices only (e.g. Mac/Windows albums)
    final all = {...names, ...p.alwaysBackupAlbums}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.t.backup_filter_always_albums_title),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final name in all)
                  CheckboxListTile(
                    value: selected.any((s) => BackupFilterProfile.albumKey(s) == BackupFilterProfile.albumKey(name)),
                    title: Text(name),
                    onChanged: (v) => setDialogState(() {
                      selected.removeWhere(
                        (s) => BackupFilterProfile.albumKey(s) == BackupFilterProfile.albumKey(name),
                      );
                      if (v == true) {
                        selected.add(name);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.t.cancel.toUpperCase(), style: const TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, selected.toList()),
              child: Text(context.t.save.toUpperCase()),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await _update({'alwaysBackupAlbums': result});
    }
  }

  Widget _switch({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: title,
        subtitle: subtitle,
        trailing: Switch(value: value, onChanged: onChanged),
      ),
    );
  }

  Widget _tile({required String title, String? subtitle, required String value, VoidCallback? onTap, Widget? extra}) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: title,
        subtitle: subtitle,
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value, style: context.textTheme.labelLarge),
            ?extra,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // rebuild whenever the cached shared profile or sync toggle changes
    ref.watch(
      appConfigProvider.select((c) => (c.backup.filterProfile, c.backup.filterSyncEnabled, c.backup.maxFileSizeMb)),
    );
    final syncEnabled = ref.watch(appConfigProvider.select((c) => c.backup.filterSyncEnabled));
    final doc = BackupFilterSyncService.document;
    final p = doc.profile;
    final effective = BackupFilterSyncService.effectiveProfile;
    final deviceOnly = BackupFilterSyncService.deviceOverrides != null;
    final t = context.t;
    final dateFmt = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag());

    String syncStatus() {
      if (_syncing) {
        return '…';
      }
      if (doc.dirty) {
        return t.backup_filter_sync_pending;
      }
      if (_syncFailed) {
        return t.backup_filter_sync_failed;
      }
      return t.backup_filter_sync_status(version: doc.version);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroupTitle(
          title: t.backup_filter_group,
          subtitle: t.backup_filter_group_subtitle,
          icon: Icons.filter_alt_outlined,
        ),
        _switch(
          title: t.backup_filter_sync_title,
          subtitle: '${t.backup_filter_sync_subtitle}\n${syncStatus()}',
          value: syncEnabled,
          onChanged: (v) async {
            await ref.read(settingsProvider).write(SettingsKey.backupFilterSyncEnabled, v);
            if (v) {
              await _sync();
            }
          },
        ),
        if (syncEnabled)
          Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: TextButton.icon(
              onPressed: _syncing ? null : _sync,
              icon: const Icon(Icons.sync, size: 18),
              label: Text(t.backup_filter_sync_now),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: SettingListTile(
            title: t.backup_filter_media_type_title,
            trailing: DropdownButton<BackupMediaTypeFilter>(
              value: p.mediaType,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: BackupMediaTypeFilter.all, child: Text(t.backup_filter_media_all)),
                DropdownMenuItem(value: BackupMediaTypeFilter.photos, child: Text(t.backup_filter_media_photos)),
                DropdownMenuItem(value: BackupMediaTypeFilter.videos, child: Text(t.backup_filter_media_videos)),
              ],
              onChanged: (v) => v == null ? null : _update({'mediaType': v.name}),
            ),
          ),
        ),
        _tile(
          title: t.backup_filter_start_date_title,
          subtitle: t.backup_filter_date_subtitle,
          value: p.startDate == null ? t.backup_filter_date_none : dateFmt.format(p.startDate!),
          onTap: () => _pickDate('startDate', p.startDate, p),
          extra: p.startDate == null
              ? null
              : IconButton(
                  tooltip: t.backup_filter_date_clear,
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => _update({'startDate': null}),
                ),
        ),
        _tile(
          title: t.backup_filter_end_date_title,
          value: p.endDate == null ? t.backup_filter_date_none : dateFmt.format(p.endDate!),
          onTap: () => _pickDate('endDate', p.endDate, p),
          extra: p.endDate == null
              ? null
              : IconButton(
                  tooltip: t.backup_filter_date_clear,
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => _update({'endDate': null}),
                ),
        ),
        _tile(
          title: t.backup_filter_always_albums_title,
          subtitle: p.alwaysBackupAlbums.isEmpty
              ? t.backup_filter_always_albums_subtitle
              : '${t.backup_filter_always_albums_subtitle}\n${p.alwaysBackupAlbums.join(', ')}',
          value: p.alwaysBackupAlbums.isEmpty
              ? t.backup_filter_none_selected
              : t.backup_filter_albums_count(count: p.alwaysBackupAlbums.length),
          onTap: () => _pickAlbums(p),
        ),
        _switch(
          title: t.backup_filter_only_selected_title,
          subtitle: t.backup_filter_only_selected_subtitle,
          value: p.onlySelectedAlbums,
          onChanged: (v) => _update({'onlySelectedAlbums': v}),
        ),
        _switch(
          title: t.backup_filter_skip_screenshots_title,
          subtitle: t.backup_filter_skip_screenshots_subtitle,
          value: p.skipScreenshots,
          onChanged: (v) => _update({'skipScreenshots': v}),
        ),
        _switch(
          title: t.backup_filter_favorites_only_title,
          subtitle: t.backup_filter_favorites_only_subtitle,
          value: p.favoritesOnly,
          onChanged: (v) => _update({'favoritesOnly': v}),
        ),
        _switch(
          title: t.backup_filter_skip_messaging_title,
          subtitle: t.backup_filter_skip_messaging_subtitle,
          value: p.skipMessagingApps,
          onChanged: (v) => _update({'skipMessagingApps': v}),
        ),
        _switch(
          title: t.backup_filter_large_lan_title,
          subtitle: t.backup_filter_large_lan_subtitle,
          value: p.largeFilesLanOnly,
          onChanged: (v) => _update({'largeFilesLanOnly': v}),
        ),
        if (p.largeFilesLanOnly)
          _tile(
            title: t.backup_filter_large_threshold_title,
            value: t.backup_max_file_size_value(size: p.largeFileThresholdMb),
            onTap: () async {
              final v = await _numberDialog(t.backup_filter_large_threshold_title, p.largeFileThresholdMb);
              if (v != null) {
                await _update({'largeFileThresholdMb': v});
              }
            },
          ),
        _switch(
          title: t.backup_filter_delay_videos_title,
          subtitle: t.backup_filter_delay_videos_subtitle(minutes: p.delayRecentVideosMinutes),
          value: p.delayRecentVideos,
          onChanged: (v) => _update({'delayRecentVideos': v}),
        ),
        if (p.delayRecentVideos)
          _tile(
            title: t.backup_filter_delay_minutes_title,
            value: '${p.delayRecentVideosMinutes}',
            onTap: () async {
              final v = await _numberDialog(t.backup_filter_delay_minutes_title, p.delayRecentVideosMinutes);
              if (v != null) {
                await _update({'delayRecentVideosMinutes': v});
              }
            },
          ),
        Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: SettingListTile(
            title: t.backup_filter_live_photo_title,
            trailing: DropdownButton<LivePhotoMode>(
              value: p.livePhotoMode,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: LivePhotoMode.full, child: Text(t.backup_filter_live_full)),
                DropdownMenuItem(value: LivePhotoMode.still, child: Text(t.backup_filter_live_still)),
              ],
              onChanged: (v) => v == null ? null : _update({'livePhotoMode': v.name}),
            ),
          ),
        ),
        _switch(
          title: t.backup_filter_charging_title,
          subtitle: t.backup_filter_charging_subtitle,
          value: effective.requireCharging,
          onChanged: (v) => _updatePower({'requireCharging': v}),
        ),
        _switch(
          title: t.backup_filter_battery_title,
          subtitle: t.backup_filter_battery_subtitle,
          value: effective.batteryCheckEnabled,
          onChanged: (v) => _updatePower({'batteryCheckEnabled': v}),
        ),
        if (effective.batteryCheckEnabled)
          _tile(
            title: t.backup_filter_battery_title,
            value: t.backup_filter_battery_value(percent: effective.minBatteryPercent),
            onTap: () async {
              final v = await _numberDialog(t.backup_filter_battery_title, effective.minBatteryPercent);
              if (v != null) {
                await _updatePower({'minBatteryPercent': v.clamp(0, 100)});
              }
            },
          ),
        _switch(
          title: t.backup_filter_device_only_title,
          subtitle: t.backup_filter_device_only_subtitle,
          value: deviceOnly,
          onChanged: (v) {
            final json = effective.toJson();
            unawaited(
              BackupFilterSyncService.updateDeviceOverrides(v ? {for (final k in _powerKeys) k: json[k]} : null),
            );
          },
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../providers/current_song_provider.dart';
import '../models/song.dart'; // For Song model
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/haptic_service.dart'; // Import HapticService

class DownloadQueueScreen extends StatefulWidget {
  const DownloadQueueScreen({super.key});

  @override
  State<DownloadQueueScreen> createState() => _DownloadQueueScreenState();
}

class _DownloadQueueScreenState extends State<DownloadQueueScreen> {
  bool _isCancelling = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Ensure wakelock is set correctly when screen appears
    final provider = Provider.of<CurrentSongProvider>(context, listen: false);
    _updateWakelock(provider);
  }

  void _updateWakelock(CurrentSongProvider provider) {
    final bool hasDownloads = provider.activeDownloadTasks.isNotEmpty ||
        provider.songsQueuedForDownload.isNotEmpty;
    if (hasDownloads) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  @override
  void dispose() {
    // Disable wakelock when leaving the screen
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Download Queue'),
        actions: [
          // Refresh button to check for stuck downloads
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Check for stuck downloads',
            onPressed: () async {
              await HapticService().lightImpact();
              final provider =
                  Provider.of<CurrentSongProvider>(context, listen: false);
              provider.checkForStuckDownloads();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Checking for stuck downloads...')),
              );
            },
          ),
          // Reinitialize download manager button
          IconButton(
            icon: const Icon(Icons.settings_backup_restore),
            tooltip: 'Reinitialize download manager',
            onPressed: () async {
              await HapticService().lightImpact();
              final provider =
                  Provider.of<CurrentSongProvider>(context, listen: false);
              await provider.reinitializeDownloadManagerIfNeeded();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Download manager reinitialized')),
              );
            },
          ),
          Consumer<CurrentSongProvider>(
            // Use Consumer here to access provider for button visibility
            builder: (context, provider, child) {
              final bool hasDownloads =
                  provider.activeDownloadTasks.isNotEmpty ||
                      provider.songsQueuedForDownload.isNotEmpty;
              if (hasDownloads) {
                return IconButton(
                  icon: const Icon(Icons.clear_all),
                  tooltip: 'Cancel All Downloads',
                  onPressed: _isCancelling
                      ? null
                      : () async {
                          await HapticService().mediumImpact();
                          showDialog(
                            context: context,
                            builder: (BuildContext dialogContext) {
                              return AlertDialog(
                                title: const Text('Cancel All Downloads?'),
                                content: const Text(
                                    'Are you sure you want to cancel all pending and active downloads?'),
                                actions: <Widget>[
                                  TextButton(
                                    child: const Text('No'),
                                    onPressed: () async {
                                      await HapticService().lightImpact();
                                      Navigator.of(dialogContext)
                                          .pop(); // Close the dialog
                                    },
                                  ),
                                  TextButton(
                                    child: const Text('Yes, Cancel All'),
                                    onPressed: () async {
                                      await HapticService().mediumImpact();
                                      Navigator.of(dialogContext)
                                          .pop(); // Close the dialog
                                      setState(() {
                                        _isCancelling = true;
                                      });
                                      provider.cancelAllDownloads();
                                    },
                                  ),
                                ],
                              );
                            },
                          );
                        },
                );
              }
              return const SizedBox
                  .shrink(); // Return an empty widget if no downloads
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Consumer<CurrentSongProvider>(
            builder: (context, provider, child) {
              // Update wakelock whenever the queue changes
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _updateWakelock(provider);
              });

              final activeTasksMap = provider.activeDownloadTasks;
              final queuedSongsList = provider.songsQueuedForDownload;
              final downloadProgressMap = provider.downloadProgress;

              final bool hasDownloads =
                  activeTasksMap.isNotEmpty || queuedSongsList.isNotEmpty;

              if (_isCancelling && !hasDownloads) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    setState(() {
                      _isCancelling = false;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('All downloads cancelled.')),
                    );
                  }
                });
              }

              // Combine active tasks and queued songs for display.
              // Active tasks are songs currently being processed by the provider/DownloadManager.
              // Queued songs are waiting in the provider's internal queue.
              final List<Song> allDownloadItems = [
                ...activeTasksMap.values,
                ...queuedSongsList,
              ];

              if (allDownloadItems.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'Download queue is empty.',
                      style: TextStyle(fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              return Column(children: [
                // Header with concurrent download info
                Container(
                  padding: const EdgeInsets.all(16.0),
                  margin: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.download,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Download Status',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            FutureBuilder<SharedPreferences>(
                              future: SharedPreferences.getInstance(),
                              builder: (context, snapshot) {
                                if (snapshot.hasData) {
                                  final maxConcurrent = snapshot.data!
                                          .getInt('maxConcurrentDownloads') ??
                                      1;
                                  return Text(
                                    '${activeTasksMap.length} active • ${queuedSongsList.length} queued • Max: $maxConcurrent concurrent',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  );
                                }
                                return Text(
                                  '${activeTasksMap.length} active • ${queuedSongsList.length} queued',
                                  style: Theme.of(context).textTheme.bodySmall,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Download list
                Expanded(
                    child: ListView.builder(
                  itemCount: allDownloadItems.length,
                  itemBuilder: (context, index) {
                    final song = allDownloadItems[index];
                    final bool isActive = activeTasksMap.containsKey(song.id);
                    final double? progress = downloadProgressMap[song.id];

                    Widget leadingWidget;
                    if (song.localFilePath != null &&
                        song.localFilePath!.isNotEmpty) {
                      leadingWidget = FutureBuilder<String>(
                        future: () async {
                          final dir = await getApplicationDocumentsDirectory();
                          final fullPath = p.join(dir.path, 'ltunes_downloads',
                              song.localFilePath!);
                          return (await File(fullPath).exists())
                              ? fullPath
                              : '';
                        }(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                                  ConnectionState.done &&
                              snapshot.hasData &&
                              snapshot.data!.isNotEmpty) {
                            return Image.file(
                              File(snapshot.data!),
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.album, size: 40),
                            );
                          }
                          return const Icon(Icons.album, size: 40);
                        },
                      );
                    } else if (song.albumArtUrl.startsWith('http')) {
                      leadingWidget = CachedNetworkImage(
                        imageUrl: song.albumArtUrl,
                        width: 40,
                        height: 40,
                        memCacheWidth: 80,
                        memCacheHeight: 80,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            const Icon(Icons.album, size: 40),
                        errorWidget: (context, url, error) =>
                            const Icon(Icons.error, size: 40),
                      );
                    } else {
                      leadingWidget = Image.file(
                        File(song.albumArtUrl),
                        width: 40,
                        height: 40,
                        cacheWidth: 80,
                        cacheHeight: 80,
                        fit: BoxFit.cover,
                      );
                    }

                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 8.0, vertical: 4.0),
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(4.0),
                          child: leadingWidget,
                        ),
                        title: Text(song.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              song.artist.isNotEmpty
                                  ? song.artist
                                  : "Unknown Artist",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            if (isActive) ...[
                              // Song is actively being processed
                              if (progress != null && progress > 0) ...[
                                LinearProgressIndicator(
                                  value: progress,
                                  backgroundColor: Colors.grey[300],
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Theme.of(context).colorScheme.primary),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Downloading... ${(progress * 100).toStringAsFixed(0)}%',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ] else ...[
                                // Active, but progress not yet available (e.g., preparing)
                                // Show a pulsing indicator for stuck downloads
                                Row(
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          Theme.of(context).colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Preparing download...',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ],
                            ] else ...[
                              // Song is in the provider's queue, not yet active
                              Text(
                                'Queued',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Redownload button for failed downloads
                            if (song.isDownloaded &&
                                song.localFilePath != null) ...[
                              IconButton(
                                icon: const Icon(Icons.refresh),
                                tooltip: 'Redownload',
                                color: Colors.blue,
                                onPressed: () async {
                                  await HapticService().lightImpact();
                                  final scaffoldMessenger =
                                      ScaffoldMessenger.of(
                                          context); // Capture before async
                                  await provider.redownloadSong(song);
                                  scaffoldMessenger.showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            'Redownloading "${song.title}"...')),
                                  );
                                },
                              ),
                            ],
                            // Cancel button
                            IconButton(
                              icon: const Icon(Icons.cancel_outlined),
                              tooltip: 'Cancel Download',
                              color: Colors.orangeAccent,
                              onPressed: () async {
                                await HapticService().mediumImpact();
                                provider.cancelDownload(song.id);
                                // Optional: Show a SnackBar
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          'Cancelled download for "${song.title}".')),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ))
              ]);
            },
          ),
          if (_isCancelling)
            Container(
              color: Colors.black.withValues(alpha: 0.5),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}

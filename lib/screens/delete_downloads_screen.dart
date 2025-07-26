import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class DeleteDownloadsScreen extends StatefulWidget {
  const DeleteDownloadsScreen({super.key});

  @override
  State<DeleteDownloadsScreen> createState() => _DeleteDownloadsScreenState();
}

class _DeleteDownloadsScreenState extends State<DeleteDownloadsScreen> {
  late Directory _currentDir;
  List<FileSystemEntity> _entities = [];
  List<dynamic> _displayList = [];
  bool _loading = true;
  List<Directory> _navStack = [];
  bool _clearingDeadFiles = false;

  @override
  void initState() {
    super.initState();
    _initRoot();
  }

  Future<void> _initRoot() async {
    setState(() => _loading = true);
    final dir = await getApplicationDocumentsDirectory();
    _currentDir = dir;
    _navStack = [];
    await _loadEntities();
  }

  Future<void> _loadEntities() async {
    setState(() => _loading = true);
    final allEntities = _currentDir.listSync()
      .where((e) => p.basename(e.path) != '.DS_Store')
      .toList();
    allEntities.sort((a, b) => a.path.compareTo(b.path));

    File? plist;
    if (_navStack.isEmpty) {
      final candidatePlist = await getPlistFile();
      if (await candidatePlist.exists()) {
        plist = candidatePlist;
      }
    }

    if (_navStack.isEmpty) {
      final albumArt = <File>[];
      final music = <File>[];
      final stationIcons = <File>[];
      Directory? audioFilesDir;
      final folders = <Directory>[];
      final others = <FileSystemEntity>[];
      for (final e in allEntities) {
        final name = p.basename(e.path).toLowerCase();
        if (e is File) {
          if ((name.startsWith('albumart') || name.startsWith('art')) && (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png') || name.endsWith('.webp'))) {
            albumArt.add(e);
          } else if (name.startsWith('stationicon') && (name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.webp'))) {
            stationIcons.add(e);
          } else if (name.endsWith('.mp3') || name.endsWith('.m4a') || name.endsWith('.flac') || name.endsWith('.wav') || name.endsWith('.opus')) {
            music.add(e);
          } else {
            others.add(e);
          }
        } else if (e is Directory) {
          if (name == 'ltunes_downloads') {
            audioFilesDir = e;
          } else {
            folders.add(e);
          }
        }
      }
      final grouped = <_GroupedFolderEntry>[];
      if (albumArt.isNotEmpty) grouped.add(_GroupedFolderEntry('Album Art', Icons.image, albumArt));
      if (music.isNotEmpty) grouped.add(_GroupedFolderEntry('Music', Icons.music_note, music));
      if (stationIcons.isNotEmpty) grouped.add(_GroupedFolderEntry('Station Icons', Icons.radio, stationIcons));
      setState(() {
        _entities = [
          if (plist != null) plist,
          if (audioFilesDir != null) audioFilesDir,
          ...folders,
          ...others,
        ];
        _displayList = [
          if (plist != null) plist,
          if (albumArt.isNotEmpty) grouped.firstWhere((g) => g.label == 'Album Art'),
          if (music.isNotEmpty) grouped.firstWhere((g) => g.label == 'Music'),
          if (stationIcons.isNotEmpty) grouped.firstWhere((g) => g.label == 'Station Icons'),
          if (audioFilesDir != null) _GroupedFolderEntry('Audio Files', Icons.library_music, []),
          ...folders,
          ...others,
        ];
        _loading = false;
      });
    } else {
      setState(() {
        _entities = allEntities;
        _displayList = allEntities;
        _loading = false;
      });
    }
  }

  Future<bool> _showDangerConfirmDialog(String action) async {
    return await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Are you sure?'),
        content: Text('This $action may break the app or cause data loss. Only continue if you know what you are doing.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue', style: TextStyle(color: Colors.red))),
        ],
      ),
    ) ?? false;
  }

  Future<void> _deleteEntity(FileSystemEntity entity) async {
    final isDir = entity is Directory;
    final fileName = p.basename(entity.path);
    final navigator = Navigator.of(context); // Capture before async
    final confirmDanger = await _showDangerConfirmDialog('delete operation');
    if (!confirmDanger) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    if (!context.mounted) return; // Guard after async
    final confirm = await showDialog<bool>(
      context: navigator.context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${isDir ? 'Folder' : 'File'}?'),
        content: Text('Are you sure you want to delete "$fileName"?${isDir ? '\n(Folder must be empty)' : ''}'),
        actions: [
          TextButton(onPressed: () => navigator.pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => navigator.pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      try {
        if (isDir) {
          if ((entity).listSync().isNotEmpty) {
            if (context.mounted) {
              scaffoldMessenger.showSnackBar(
                SnackBar(content: Text('Folder is not empty: $fileName')),
              );
            }
            return;
          }
          await entity.delete();
        } else {
          await entity.delete();

          // Update song metadata if this was an audio file or art file
          final prefs = await SharedPreferences.getInstance();
          final keys = prefs.getKeys();
          for (final key in keys) {
            if (key.startsWith('song_')) {
              final songJson = prefs.getString(key);
              if (songJson != null) {
                final songMap = jsonDecode(songJson) as Map<String, dynamic>;
                bool updated = false;
                if (songMap['localFilePath'] == fileName) {
                  songMap['isDownloaded'] = false;
                  songMap['localFilePath'] = null;
                  updated = true;
                }
                if (songMap['albumArtUrl'] == fileName) {
                  songMap['albumArtUrl'] = '';
                  updated = true;
                }
                if (updated) {
                  await prefs.setString(key, jsonEncode(songMap));
                }
              }
            }
          }
        }
        if (context.mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(content: Text('Deleted $fileName')),
          );
        }
        await _loadEntities();
      } catch (e) {
        if (context.mounted) {
          scaffoldMessenger.showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
  }

  void _navigateTo(Directory dir) {
    _navStack.add(_currentDir);
    _currentDir = dir;
    _loadEntities();
  }

  void _goBack() {
    if (_navStack.isNotEmpty) {
      _currentDir = _navStack.removeLast();
      _loadEntities();
    }
  }

  void _openGroupedFolder(String label, List<File> files, IconData icon) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _GroupedFolderScreen(label: label, files: files, onDelete: (file) async {
        await _deleteEntity(file);
        await _loadEntities();
      }),
    ));
  }

  void _openAudioFilesFolder() {
    final dir = _entities.firstWhere(
      (e) => e is Directory && p.basename(e.path).toLowerCase() == 'ltunes_downloads',
      orElse: () => Directory("")
    );
    if (dir is Directory && dir.path.isNotEmpty) {
      _navigateTo(dir);
    }
  }

  Future<void> _clearDeadAudioFiles() async {
    setState(() => _clearingDeadFiles = true);
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    final downloadsDir = await getDownloadsDir();
    if (!await downloadsDir.exists()) {
      setState(() => _clearingDeadFiles = false);
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Audio Files folder does not exist.')),
      );
      return;
    }
    final files = downloadsDir.listSync().whereType<File>().toList();
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final usedFiles = <String>{};
    for (final key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          final songMap = jsonDecode(songJson) as Map<String, dynamic>;
          final localFilePath = songMap['localFilePath'];
          if (localFilePath != null && localFilePath is String && localFilePath.isNotEmpty) {
            usedFiles.add(localFilePath);
          }
        }
      }
    }
    int deleted = 0;
    for (final file in files) {
      final name = p.basename(file.path);
      if (!usedFiles.contains(name)) {
        try {
          await file.delete();
          deleted++;
        } catch (_) {}
      }
    }
    setState(() => _clearingDeadFiles = false);
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text('Cleared $deleted dead file${deleted == 1 ? '' : 's'} from Audio Files')),
    );
    await _loadEntities();
  }

  Future<void> _clearDeadFilesWithPrompt() async {
    setState(() => _clearingDeadFiles = true);
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    final downloadsDir = await getDownloadsDir();
    final docsDir = await getApplicationDocumentsDirectory();
    final audioFiles = downloadsDir.existsSync() ? downloadsDir.listSync().whereType<File>().toList() : <File>[];
    final allFiles = docsDir.parent.listSync().whereType<File>().toList();
    // Find art files in root (albumart/art prefix)
    final artFiles = allFiles.where((f) {
      final name = p.basename(f.path).toLowerCase();
      return (name.startsWith('albumart') || name.startsWith('art')) && (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png') || name.endsWith('.webp'));
    }).toList();

    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final usedAudio = <String>{};
    final usedArt = <String>{};
    for (final key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          final songMap = jsonDecode(songJson) as Map<String, dynamic>;
          final localFilePath = songMap['localFilePath'];
          if (localFilePath != null && localFilePath is String && localFilePath.isNotEmpty) {
            usedAudio.add(localFilePath);
          }
          final albumArtUrl = songMap['albumArtUrl'];
          if (albumArtUrl != null && albumArtUrl is String && albumArtUrl.isNotEmpty) {
            usedArt.add(albumArtUrl);
          }
        }
      }
    }
    final deadAudio = audioFiles.where((f) => !usedAudio.contains(p.basename(f.path))).toList();
    final deadArt = artFiles.where((f) => !usedArt.contains(p.basename(f.path))).toList();
    final allDead = [...deadAudio, ...deadArt];
    if (allDead.isEmpty) {
      setState(() => _clearingDeadFiles = false);
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('No dead audio or art files found.')),
      );
      return;
    }
    final selected = Set<File>.from(allDead);
    final navigator = Navigator.of(context); // Capture before async
    final result = await showDialog<bool>(
      context: navigator.context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Dead Files'),
          content: SizedBox(
            width: 400,
            height: 300,
            child: ListView(
              children: allDead.map((file) {
                final name = p.basename(file.path);
                final isAudio = deadAudio.contains(file);
                return CheckboxListTile(
                  value: selected.contains(file),
                  onChanged: (val) {
                    if (val == true) {
                      selected.add(file);
                    } else {
                      selected.remove(file);
                    }
                    (context as Element).markNeedsBuild();
                  },
                  title: Text(name),
                  subtitle: Text(isAudio ? 'Audio File' : 'Art File'),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => navigator.pop(false), child: const Text('Cancel')),
            TextButton(
              onPressed: () => navigator.pop(true),
              child: const Text('Delete Selected'),
            ),
          ],
        );
      },
    );
    if (result == true && selected.isNotEmpty) {
      int deleted = 0;
      for (final file in selected) {
        try {
          await file.delete();
          deleted++;
        } catch (_) {}
      }
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Deleted $deleted dead file${deleted == 1 ? '' : 's'}')),
        );
      }
      await _loadEntities();
    }
    setState(() => _clearingDeadFiles = false);
  }

  @override
  Widget build(BuildContext context) {
    final atRoot = _navStack.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage App Documents"),
        leading: _navStack.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _goBack,
              )
            : null,
        actions: [
          if (atRoot)
            IconButton(
              icon: _clearingDeadFiles ? const CircularProgressIndicator() : const Icon(Icons.cleaning_services),
              tooltip: 'Clear Dead Audio/Art Files',
              onPressed: _clearingDeadFiles ? null : _clearDeadFilesWithPrompt,
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Colors.red.shade900,
            padding: const EdgeInsets.all(12),
            width: double.infinity,
            child: const Text(
              'Warning: Deleting files or folders here may break the app or cause data loss. Only delete files if you know what you are doing.',
              style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _displayList.isEmpty
                    ? const Center(child: Text('No files or folders found.'))
                    : ListView.builder(
                        itemCount: _displayList.length,
                        itemBuilder: (context, i) {
                          final entity = _displayList[i];
                          if (entity is File) {
                            final name = p.basename(entity.path);
                            final isPlist = name.endsWith('.plist');
                            final isPrefs = entity.path.contains('shared_prefs') && name.endsWith('.xml');
                            return ListTile(
                              leading: const Icon(Icons.insert_drive_file),
                              title: Text(name),
                              subtitle: FutureBuilder<int>(
                                future: entity.length(),
                                builder: (context, snap) {
                                  if (snap.connectionState == ConnectionState.done && snap.hasData) {
                                    return Text('${(snap.data! / 1024).toStringAsFixed(1)} KB');
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
                              trailing: (isPlist || isPrefs)
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.delete, color: Colors.red),
                                    onPressed: () => _deleteEntity(entity),
                                  ),
                            );
                          }
                          if (entity is _GroupedFolderEntry) {
                            if (entity.label == 'Audio Files') {
                              return ListTile(
                                leading: Icon(Icons.library_music),
                                title: const Text('Audio Files'),
                                subtitle: const Text('Browse downloaded audio files'),
                                trailing: const Icon(Icons.arrow_forward_ios),
                                onTap: _openAudioFilesFolder,
                              );
                            }
                            return ListTile(
                              leading: Icon(entity.icon),
                              title: Text(entity.label),
                              subtitle: Text('${entity.files.length} files'),
                              trailing: const Icon(Icons.arrow_forward_ios),
                              onTap: () => _openGroupedFolder(
                                entity.label,
                                entity.files,
                                entity.icon,
                              ),
                            );
                          }
                          final isDir = entity is Directory;
                          return ListTile(
                            leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file),
                            title: Text(p.basename(entity.path)),
                            subtitle: isDir
                                ? const Text('Folder')
                                : FutureBuilder<int>(
                                    future: File(entity.path).length(),
                                    builder: (context, snap) {
                                      if (snap.connectionState == ConnectionState.done && snap.hasData) {
                                        return Text('${(snap.data! / 1024).toStringAsFixed(1)} KB');
                                      }
                                      return const SizedBox.shrink();
                                    },
                                  ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _deleteEntity(entity),
                            ),
                            onTap: isDir ? () => _navigateTo(entity) : null,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _GroupedFolderEntry {
  final String label;
  final IconData icon;
  final List<File> files;
  _GroupedFolderEntry(this.label, this.icon, this.files);
}

class _GroupedFolderScreen extends StatefulWidget {
  final String label;
  final List<File> files;
  final Future<void> Function(File) onDelete;
  const _GroupedFolderScreen({required this.label, required this.files, required this.onDelete});

  @override
  State<_GroupedFolderScreen> createState() => _GroupedFolderScreenState();
}

class _GroupedFolderScreenState extends State<_GroupedFolderScreen> {
  bool _clearing = false;

  Future<void> _clearDeadFiles() async {
    setState(() => _clearing = true);
    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture before async
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final usedFiles = <String>{};
    for (final key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          final songMap = jsonDecode(songJson) as Map<String, dynamic>;
          final localFilePath = songMap['localFilePath'];
          if (localFilePath != null && localFilePath is String && localFilePath.isNotEmpty) {
            usedFiles.add(localFilePath);
          }
        }
      }
    }
    int deleted = 0;
    for (final file in widget.files) {
      final name = p.basename(file.path);
      if (!usedFiles.contains(name)) {
        try {
          await file.delete();
          deleted++;
        } catch (_) {}
      }
    }
    setState(() => _clearing = false);
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text('Cleared $deleted dead file${deleted == 1 ? '' : 's'}')),
    );
    setState(() {}); // Refresh UI
  }

  @override
  Widget build(BuildContext context) {
    final isAudioFiles = widget.label == 'Audio Files';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.label),
        actions: [
          if (isAudioFiles)
            IconButton(
              icon: _clearing ? const CircularProgressIndicator() : const Icon(Icons.cleaning_services),
              tooltip: 'Clear Dead Files',
              onPressed: _clearing ? null : _clearDeadFiles,
            ),
        ],
      ),
      body: widget.files.isEmpty
          ? const Center(child: Text('No files found.'))
          : ListView.builder(
              itemCount: widget.files.length,
              itemBuilder: (context, i) {
                final file = widget.files[i];
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(p.basename(file.path)),
                  subtitle: FutureBuilder<int>(
                    future: file.length(),
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.done && snap.hasData) {
                        return Text('${(snap.data! / 1024).toStringAsFixed(1)} KB');
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => widget.onDelete(file),
                  ),
                );
              },
            ),
    );
  }
}

Future<String> getAppSandboxRoot() async {
  final docsDir = await getApplicationDocumentsDirectory();
  // Go up one level from Documents to the app root
  return p.dirname(docsDir.path);
}

Future<File> getPlistFile() async {
  final appRoot = await getAppSandboxRoot();
  return File(p.join(appRoot, 'Library', 'Preferences', 'com.LTunes.plist'));
}

Future<Directory> getDownloadsDir() async {
  final docsDir = await getApplicationDocumentsDirectory();
  return Directory(p.join(docsDir.path, 'ltunes_downloads'));
} 
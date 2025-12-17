import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // Required for jsonDecode
import 'dart:math'; // Required for log and pow
import '../models/song.dart'; // Required for Song.fromJson
import 'package:fl_chart/fl_chart.dart'; // For charts
import '../screens/playlists_list_screen.dart' show robustArtwork;

class ListeningStatsScreen extends StatefulWidget {
  const ListeningStatsScreen({super.key});

  @override
  State<ListeningStatsScreen> createState() => _ListeningStatsScreenState();
}

class _ListeningStatsScreenState extends State<ListeningStatsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Listening Stats'),
        elevation: 0,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _getListeningStats(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          } else if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading stats',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            );
          } else if (!snapshot.hasData) {
            return const Center(
              child: Text('No stats available'),
            );
          }
          final stats = snapshot.data!;
          final List<Song> topSongs = stats['topSongs'] as List<Song>;
          final List<Map<String, dynamic>> topAlbums =
              stats['topAlbums'] as List<Map<String, dynamic>>;
          final List<MapEntry<String, int>> topArtists =
              stats['topArtists'] as List<MapEntry<String, int>>;
          final Map<String, int> dailyCounts =
              stats['dailyCounts'] as Map<String, int>? ?? {};

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Daily Listening Chart
                if (dailyCounts.isNotEmpty &&
                    dailyCounts.values.any((count) => count > 0)) ...[
                  Text(
                    'Daily Listening (last 7 days):',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 250,
                    child: BarChart(
                      BarChartData(
                        alignment: BarChartAlignment.spaceAround,
                        maxY: _calculateMaxY(dailyCounts.values),
                        minY: 0,
                        barTouchData: BarTouchData(
                          enabled: true,
                          touchTooltipData: BarTouchTooltipData(
                            tooltipBorder: BorderSide(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            getTooltipItem: (group, groupIndex, rod, rodIndex) {
                              final keys = dailyCounts.keys.toList();
                              final date = keys[group.x];
                              final count = rod.toY.toInt();
                              return BarTooltipItem(
                                '$date\n$count plays',
                                TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                  fontWeight: FontWeight.bold,
                                ),
                              );
                            },
                          ),
                        ),
                        titlesData: FlTitlesData(
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 40,
                              interval:
                                  _calculateYAxisInterval(dailyCounts.values),
                              getTitlesWidget: (double value, TitleMeta meta) {
                                return Text(
                                  value.toInt().toString(),
                                  style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.onSurface,
                                    fontSize: 12,
                                  ),
                                );
                              },
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              getTitlesWidget: (double value, TitleMeta meta) {
                                final keys = dailyCounts.keys.toList();
                                if (value.toInt() < 0 ||
                                    value.toInt() >= keys.length) {
                                  return const SizedBox();
                                }
                                final dateStr = keys[value.toInt()];
                                // Format date as MM/DD
                                final parts = dateStr.split('-');
                                if (parts.length >= 3) {
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Text(
                                      '${parts[1]}/${parts[2]}',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
                                        fontSize: 11,
                                      ),
                                    ),
                                  );
                                }
                                return const SizedBox();
                              },
                              reservedSize: 40,
                            ),
                          ),
                          rightTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          topTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border(
                            bottom: BorderSide(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            left: BorderSide(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                        gridData: FlGridData(
                          show: true,
                          horizontalInterval:
                              _calculateGridInterval(dailyCounts.values),
                          getDrawingHorizontalLine: (value) {
                            return FlLine(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outline
                                  .withValues(alpha: 0.3),
                              strokeWidth: 1,
                            );
                          },
                          drawVerticalLine: false,
                        ),
                        barGroups: [
                          for (int i = 0; i < dailyCounts.length; i++)
                            BarChartGroupData(
                              x: i,
                              barRods: [
                                BarChartRodData(
                                  toY: dailyCounts.values
                                      .elementAt(i)
                                      .toDouble(),
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 20,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                )
                              ],
                            )
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // No data message
                if (dailyCounts.isEmpty ||
                    !dailyCounts.values.any((count) => count > 0))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16.0),
                    child: Text(
                      'No listening data available for the last 7 days.',
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),

                // Top Songs
                Text(
                  'Most Played Songs:',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                ...topSongs.map((song) => Card(
                      margin: const EdgeInsets.only(bottom: 8.0),
                      child: ListTile(
                        leading: robustArtwork(
                          song.albumArtUrl,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                        ),
                        title: Text(song.title),
                        subtitle: Text(song.artist),
                        trailing: Text('${song.playCount} plays'),
                        dense: true,
                      ),
                    )),
                const SizedBox(height: 16),

                // Top Artists
                Text(
                  'Most Played Artists:',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                ...topArtists.map((entry) => Card(
                      margin: const EdgeInsets.only(bottom: 8.0),
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(
                            Icons.person,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(entry.key),
                        trailing: Text('${entry.value} plays'),
                        dense: true,
                      ),
                    )),
              ],
            ),
          );
        },
      ),
    );
  }

  double _calculateMaxY(Iterable<int> values) {
    if (values.isEmpty) return 1.0;
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    if (maxValue == 0) return 1.0;
    if (maxValue <= 3) return 3.0;
    if (maxValue <= 6) return 6.0;
    if (maxValue <= 10) return 10.0;
    if (maxValue <= 20) return 20.0;
    if (maxValue <= 50) return 50.0;
    // For larger values, round up to the nearest multiple of 10
    return (maxValue / 10.0).ceil() * 10.0;
  }

  double _calculateYAxisInterval(Iterable<int> values) {
    final maxY = _calculateMaxY(values);
    if (maxY <= 6) return 1.0;
    if (maxY <= 20) return 2.0;
    if (maxY <= 50) return 5.0;
    return 10.0;
  }

  double _calculateGridInterval(Iterable<int> values) {
    final maxY = _calculateMaxY(values);
    if (maxY <= 6) return 1.0;
    if (maxY <= 20) return 2.0;
    if (maxY <= 50) return 5.0;
    return 10.0;
  }

  Future<Map<String, dynamic>> _getListeningStats() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();

    // Songs
    final List<Song> allSongs = [];
    final now = DateTime.now();
    for (final key in keys) {
      if (key.startsWith('song_')) {
        final songJson = prefs.getString(key);
        if (songJson != null) {
          try {
            final songMap = jsonDecode(songJson) as Map<String, dynamic>;
            final song = Song.fromJson(songMap);
            allSongs.add(song);
          } catch (_) {}
        }
      }
    }
    allSongs.sort((a, b) => b.playCount.compareTo(a.playCount));
    final topSongs = allSongs.take(3).toList();

    // Albums
    final List<Map<String, dynamic>> allAlbums = [];
    for (final key in keys) {
      if (key.startsWith('album_')) {
        final albumJson = prefs.getString(key);
        if (albumJson != null) {
          try {
            final albumMap = jsonDecode(albumJson) as Map<String, dynamic>;
            allAlbums.add(albumMap);
          } catch (_) {}
        }
      }
    }
    allAlbums.sort((a, b) =>
        (b['playCount'] as int? ?? 0).compareTo(a['playCount'] as int? ?? 0));
    final topAlbums = allAlbums.take(3).toList();

    // Artists
    final artistPlayCountsJson = prefs.getString('artist_play_counts');
    Map<String, int> artistPlayCounts = {};
    if (artistPlayCountsJson != null) {
      try {
        artistPlayCounts =
            Map<String, int>.from(jsonDecode(artistPlayCountsJson));
      } catch (_) {}
    }
    final topArtists = artistPlayCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Daily play counts (actual)
    final dailyPlayCountsJson = prefs.getString('daily_play_counts');
    Map<String, int> dailyCounts = {};
    if (dailyPlayCountsJson != null) {
      try {
        dailyCounts = Map<String, int>.from(jsonDecode(dailyPlayCountsJson));
      } catch (_) {}
    }

    // Filter to last 7 days and sort by date
    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    dailyCounts = Map.fromEntries(
      dailyCounts.entries.where((entry) {
        try {
          final date = DateTime.parse(entry.key);
          return date.isAfter(sevenDaysAgo) ||
              date.isAtSameMomentAs(sevenDaysAgo);
        } catch (_) {
          return false;
        }
      }).toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );

    return {
      'topSongs': topSongs,
      'topAlbums': topAlbums,
      'topArtists': topArtists.take(3).toList(),
      'dailyCounts': dailyCounts,
    };
  }
}

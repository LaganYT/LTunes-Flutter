import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  @override
  _RadioScreenState createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  late Future<List<dynamic>> _stationsFuture;

  @override
  void initState() {
    super.initState();
    _stationsFuture = fetchRadioStations();
  }

  Future<List<dynamic>> fetchRadioStations() async {
    final url = Uri.parse('https://ltn-api.vercel.app/api/radio');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      } else {
        throw Exception('Failed to load radio stations');
      }
    } catch (e) {
      throw Exception('Error fetching radio stations: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio'),
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _stationsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error: ${snapshot.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            );
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('No radio stations found.'));
          }

          final stations = snapshot.data!;
          return ListView.builder(
            itemCount: stations.length,
            itemBuilder: (context, index) {
              final station = stations[index];
              return ListTile(
                leading: station['favicon'] != null && station['favicon'].isNotEmpty
                    ? Image.network(
                        station['favicon'],
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            const Icon(Icons.radio, size: 50),
                      )
                    : const Icon(Icons.radio, size: 50),
                title: Text(
                  station['name'] ?? 'Unknown Station',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  station['country'] ?? 'Unknown Country',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  // Play the radio station
                  final url = station['url_resolved'];
                  if (url != null && url.isNotEmpty) {
                    // Implement playback logic here
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Playing ${station['name']}')),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Stream URL not available')),
                    );
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}

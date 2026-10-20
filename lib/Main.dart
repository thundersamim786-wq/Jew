import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'sourcing_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const UltimateStreamApp());
}

// ============================================================================
// DATA MODEL & GLOBAL WATCHLIST
// ============================================================================
class MovieMetadata {
  final int id;
  final String title;
  final String releaseYear;
  final double rating;
  final String posterUrl;
  final String description;
  final String mediaType;

  MovieMetadata({
    required this.id,
    required this.title,
    required this.releaseYear,
    required this.rating,
    required this.posterUrl,
    required this.description,
    required this.mediaType,
  });
}

final ValueNotifier<List<MovieMetadata>> globalWatchlist = ValueNotifier([]);

// ============================================================================
// MAIN APP NAVIGATION
// ============================================================================
class UltimateStreamApp extends StatelessWidget {
  const UltimateStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cinematic VOD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0E12),
        primaryColor: const Color(0xFFE50914),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE50914),
          brightness: Brightness.dark,
        ),
      ),
      home: const MainTabNavigator(),
    );
  }
}

class MainTabNavigator extends StatefulWidget {
  const MainTabNavigator({super.key});

  @override
  State<MainTabNavigator> createState() => _MainTabNavigatorState();
}

class _MainTabNavigatorState extends State<MainTabNavigator> {
  int _tab = 0;
  final List<Widget> _screens = [const CatalogScreen(), const WatchlistScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: _screens),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF16181F),
        selectedItemColor: const Color(0xFFE50914),
        unselectedItemColor: Colors.white54,
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.movie_creation_outlined),
            label: 'Discover',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bookmark_border),
            label: 'Watchlist',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// DISCOVER TAB (LIVE TMDB DATA ONLY)
// ============================================================================
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<MovieMetadata> _movies = [];
  bool _isLoading = false;
  Timer? _debounce;

  final String _tmdbApiKey = "8b14746045cf2ecf234924551fef6867";

  Future<void> _searchTitles(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) {
      if (mounted) setState(() => _movies = []);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final uri = Uri.parse(
        'https://api.themoviedb.org/3/search/multi?api_key=$_tmdbApiKey&query=${Uri.encodeComponent(clean)}&include_adult=false',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final List results = data['results'] ?? [];
        final List<MovieMetadata> items = [];

        for (final doc in results) {
          final type = doc['media_type'] ?? 'movie';
          if (type != 'movie' && type != 'tv') continue;

          final title = doc['title'] ?? doc['name'] ?? 'Untitled';
          final date = doc['release_date'] ?? doc['first_air_date'] ?? '';
          final posterPath = doc['poster_path'];

          items.add(
            MovieMetadata(
              id: doc['id'],
              title: title,
              releaseYear: date.length >= 4 ? date.substring(0, 4) : 'N/A',
              rating: (doc['vote_average'] as num?)?.toDouble() ?? 0.0,
              posterUrl: posterPath != null
                  ? 'https://image.tmdb.org/t/p/w500$posterPath'
                  : 'https://via.placeholder.com/400x600/16181F/FFFFFF?text=No+Poster',
              description: doc['overview'] ?? 'No overview available.',
              mediaType: type,
            ),
          );
        }
        if (mounted) setState(() => _movies = items);
      }
    } catch (e) {
      debugPrint("Live TMDb search error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF16181F),
        title: const Text(
          'Cinematic Library',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (val) {
                _debounce?.cancel();
                _debounce = Timer(
                  const Duration(milliseconds: 500),
                  () => _searchTitles(val),
                );
              },
              decoration: InputDecoration(
                hintText: 'Search movies, anime, series...',
                prefixIcon: const Icon(Icons.search, color: Color(0xFFE50914)),
                filled: true,
                fillColor: const Color(0xFF16181F),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_isLoading)
            const LinearProgressIndicator(
              color: Color(0xFFE50914),
              minHeight: 2,
            ),
          Expanded(
            child: _movies.isEmpty && !_isLoading
                ? const Center(
                    child: Text(
                      'Search above to fetch live titles from TMDb.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 0.62,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: _movies.length,
                    itemBuilder: (ctx, i) {
                      final movie = _movies[i];
                      return GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SourcingPlayerScreen(
                              tmdbId: movie.id,
                              title: movie.title,
                              mediaType: movie.mediaType,
                              tmdbApiKey: _tmdbApiKey,
                            ),
                          ),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF16181F),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Stack(
                                  children: [
                                    Image.network(
                                      movie.posterUrl,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      height: double.infinity,
                                    ),
                                    Positioned(
                                      top: 6,
                                      right: 6,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.8),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.star,
                                              color: Colors.amber,
                                              size: 12,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              movie.rating > 0
                                                  ? movie.rating
                                                      .toStringAsFixed(1)
                                                  : 'NR',
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      movie.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      '${movie.releaseYear} • ${movie.mediaType.toUpperCase()}',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// WATCHLIST SCREEN
// ============================================================================
class WatchlistScreen extends StatelessWidget {
  const WatchlistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF16181F),
        title: const Text(
          'My Watchlist',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ValueListenableBuilder<List<MovieMetadata>>(
        valueListenable: globalWatchlist,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return const Center(
              child: Text(
                'Your watchlist is empty.',
                style: TextStyle(color: Colors.white54),
              ),
            );
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (ctx, i) {
              final item = list[i];
              return ListTile(
                leading: Image.network(
                  item.posterUrl,
                  width: 40,
                  fit: BoxFit.cover,
                ),
                title: Text(item.title),
                subtitle: Text(
                  '${item.releaseYear} • Rating: ★ ${item.rating}',
                ),
                trailing: const Icon(
                  Icons.play_arrow,
                  color: Color(0xFFE50914),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SourcingPlayerScreen(
                      tmdbId: item.id,
                      title: item.title,
                      mediaType: item.mediaType,
                      tmdbApiKey: "8b14746045cf2ecf234924551fef6867",
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

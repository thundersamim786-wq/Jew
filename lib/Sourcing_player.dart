import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

class SourcingPlayerScreen extends StatefulWidget {
  final int tmdbId;
  final String title;
  final String mediaType; 
  final String tmdbApiKey;

  const SourcingPlayerScreen({
    super.key,
    required this.tmdbId,
    required this.title,
    required this.mediaType,
    required this.tmdbApiKey,
  });

  @override
  State<SourcingPlayerScreen> createState() => _SourcingPlayerScreenState();
}

class _SourcingPlayerScreenState extends State<SourcingPlayerScreen> {
  HeadlessInAppWebView? _headlessWebView;
  VideoPlayerController? _videoController;
  
  bool _isSearchingSource = true;
  String? _masterManifestUrl;
  late String _embedUrl;
  bool _showControls = true;

  int _selectedSeason = 1;
  int _selectedEpisode = 1;
  int _totalSeasons = 1;
  List<int> _episodesInSeason = [];
  bool _isLoadingTvMetadata = false;

  Map<String, String> _availableQualities = {}; 
  String _currentQualityLabel = "Auto";
  Map<String, String> _customHeaders = {};

  @override
  void initState() {
    super.initState();
    _prepareMediaPlayback();
  }
}
extension _MetadataSetupExtension on _SourcingPlayerScreenState {
  Future<void> _prepareMediaPlayback() async {
    if (widget.mediaType == 'tv') {
      await _fetchTvShowMetadata();
    }
    _updateEmbedUrlAndBootScraper();
  }

  Future<void> _fetchTvShowMetadata() async {
    if (widget.tmdbApiKey == "YOUR_TMDB_API_KEY_HERE") return;
    setState(() => _isLoadingTvMetadata = true);
    try {
      final tvUri = Uri.parse('https://themoviedb.org{widget.tmdbId}?api_key=${widget.tmdbApiKey}');
      final tvRes = await http.get(tvUri);
      if (tvRes.statusCode == 200) {
        final tvData = json.decode(tvRes.body);
        _totalSeasons = tvData['number_of_seasons'] ?? 1;
      }
      await _fetchEpisodesForSeason(_selectedSeason);
    } catch (e) {
      debugPrint("Metadata indexing error: $e");
    } finally {
      setState(() => _isLoadingTvMetadata = false);
    }
  }

  Future<void> _fetchEpisodesForSeason(int seasonNumber) async {
    try {
      final seasonUri = Uri.parse('https://themoviedb.org{widget.tmdbId}/season/$seasonNumber?api_key=${widget.tmdbApiKey}');
      final seasonRes = await http.get(seasonUri);
      if (seasonRes.statusCode == 200) {
        final seasonData = json.decode(seasonRes.body);
        final List episodesList = seasonData['episodes'] ?? [];
        setState(() {
          _episodesInSeason = List.generate(episodesList.length, (index) => index + 1);
        });
      }
    } catch (e) {
      debugPrint("Error structural collection routing: $e");
    }
  }
}
extension _EngineScraperExtension on _SourcingPlayerScreenState {
  void _updateEmbedUrlAndBootScraper() {
    _headlessWebView?.dispose();
    _headlessWebView = null;
    _revertOrientationToPortrait();
    
    _videoController?.removeListener(_videoPlaybackListener);
    _videoController?.dispose();
    _videoController = null;

    setState(() {
      _isSearchingSource = true;
      _masterManifestUrl = null;
      _availableQualities.clear();
      _currentQualityLabel = "Auto";
      _showControls = true;
    });

    if (widget.mediaType == 'tv') {
      _embedUrl = "https://vidsrc.to{widget.tmdbId}/$_selectedSeason/$_selectedEpisode";
    } else {
      _embedUrl = "https://vidsrc.to{widget.tmdbId}";
    }

    _bootScraperEngine();
  }

  void _bootScraperEngine() {
    _headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_embedUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
      ),
      shouldInterceptFetchRequest: (controller, fetchRequest) async {
        _analyzeNetworkPayload(fetchRequest.url?.toString());
        return fetchRequest;
      },
      shouldInterceptAjaxRequest: (controller, ajaxRequest) async {
        _analyzeNetworkPayload(ajaxRequest.url?.toString());
        return ajaxRequest;
      },
    );
    _headlessWebView?.run();
  }
}
extension _ManifestProcessingExtension on _SourcingPlayerScreenState {
  void _analyzeNetworkPayload(String? url) {
    if (url == null || !_isSearchingSource) return;

    if (url.contains('.m3u8') || url.contains('.mp4') || url.contains('master.txt')) {
      _isSearchingSource = false;
      _masterManifestUrl = url;
      _customHeaders = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': _embedUrl,
      };

      _parseHlsManifestAndInitialize(url);
      _headlessWebView?.dispose();
      _headlessWebView = null;
    }
  }

  Future<void> _parseHlsManifestAndInitialize(String manifestUrl) async {
    try {
      final res = await http.get(Uri.parse(manifestUrl), headers: _customHeaders);
      if (res.statusCode == 200 && res.body.contains("#EXT-X-STREAM-INF")) {
        final lines = res.body.split('\n');
        Map<String, String> qualitiesMap = {"Auto": manifestUrl};
        String? currentInfo;
        final baseUri = Uri.parse(manifestUrl);

        for (var line in lines) {
          line = line.trim();
          if (line.startsWith("#EXT-X-STREAM-INF")) {
            currentInfo = line;
          } else if (line.isNotEmpty && !line.startsWith("#") && currentInfo != null) {
            String fullUrl = line.startsWith("http") ? line : baseUri.resolve(line).toString();
            String label = "Alternative";
            if (currentInfo.contains("RESOLUTION=")) {
              final match = RegExp(r'RESOLUTION=(\d+x\d+)').firstMatch(currentInfo);
              if (match != null) {
                label = "${match.group(1)!.split('x')}p";
              }
            }
            qualitiesMap[label] = fullUrl;
            currentInfo = null;
          }
        }
        if (qualitiesMap.length > 1) _availableQualities = qualitiesMap;
      }
    } catch (e) {
      debugPrint("HLS parsing skipped: $e");
    }
    _initializeVideoPlayer(_masterManifestUrl!, "Auto");
  }
}
extension _VideoPlaybackLifecycleExtension on _SourcingPlayerScreenState {
  void _initializeVideoPlayer(String targetStreamUrl, String qualityLabel) {
    _videoController?.removeListener(_videoPlaybackListener);
    _videoController?.dispose();
    setState(() => _currentQualityLabel = qualityLabel);

    _videoController = VideoPlayerController.networkUrl(
      Uri.parse(targetStreamUrl),
      httpHeaders: _customHeaders,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false, mixWithOthers: false),
    )..initialize().then((_) {
        setState(() {});
        _lockOrientationToLandscape(); 
        _videoController?.addListener(_videoPlaybackListener);
        _videoController?.play();
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _videoController!.value.isPlaying) setState(() => _showControls = false);
        });
      });
  }

  void _lockOrientationToLandscape() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  void _revertOrientationToPortrait() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  void _videoPlaybackListener() async {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    setState(() {});
    if (_videoController!.value.position >= _videoController!.value.duration && _videoController!.value.duration != Duration.zero && !_videoController!.value.isPlaying) {
      _videoController?.removeListener(_videoPlaybackListener);
      if (widget.mediaType == 'tv') _handleAutoAdvanceRoute();
    }
  }

  void _handleAutoAdvanceRoute() async {
    if (_selectedEpisode < _episodesInSeason.length) {
      setState(() => _selectedEpisode++);
      _updateEmbedUrlAndBootScraper();
    } else if (_selectedSeason < _totalSeasons) {
      setState(() { _selectedSeason++; _selectedEpisode = 1; _isLoadingTvMetadata = true; });
      await _fetchEpisodesForSeason(_selectedSeason);
      setState(() => _isLoadingTvMetadata = false);
      _updateEmbedUrlAndBootScraper();
    } else {
      _revertOrientationToPortrait();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Collection finished.")));
    }
  }

  void _seekRelative(int seconds) {
    if (_videoController == null) return;
    _videoController!.seekTo(_videoController!.value.position + Duration(seconds: seconds));
  }
}
extension _InterfaceLayoutUiExtension on _SourcingPlayerScreenState {
  void _showQualityPickerSheet() {
    if (_availableQualities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Multi-quality feeds unavailable.")));
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16181F),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: _availableQualities.keys.map((label) => ListTile(
            leading: Icon(Icons.check, color: _currentQualityLabel == label ? Colors.red : Colors.transparent),
            title: Text(label, style: const TextStyle(color: Colors.white)),
            onTap: () { Navigator.pop(context); _initializeVideoPlayer(_availableQualities[label]!, label); },
          )).toList(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _headlessWebView?.dispose();
    _revertOrientationToPortrait(); 
    _videoController?.removeListener(_videoPlaybackListener);
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: isLandscape ? null : AppBar(title: Text(widget.title), backgroundColor: const Color(0xFF16181F)),
      body: Column(
        children: [
          Expanded(
            flex: isLandscape ? 1 : 3,
            child: Center(
              child: _isSearchingSource
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const CircularProgressIndicator(color: Colors.red),
                      const SizedBox(height: 16),
                      Text(widget.mediaType == 'tv' ? "Resolving S$_selectedSeason E$_selectedEpisode..." : "Bypassing firewalls...", style: const TextStyle(color: Colors.white70))
                    ])
                  : (_videoController != null && _videoController!.value.isInitialized)
                      ? GestureDetector(
                          onTap: () => setState(() => _showControls = !_showControls),
                          child: Stack(alignment: Alignment.center, children: [
                            AspectRatio(aspectRatio: _videoController!.value.aspectRatio, child: VideoPlayer(_videoController!)),
                            AnimatedOpacity(
                              opacity: _showControls ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 250),
                              child: IgnorePointer(
                                ignoring: !_showControls,
                                child: Container(
                                  color: Colors.black54,
                                  child: Column(mainAxisAlignment: MainAxisAlignment.between, children: [
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                                        TextButton.icon(icon: const Icon(Icons.settings, color: Colors.white, size: 18), label: Text(_currentQualityLabel, style: const TextStyle(color: Colors.white)), style: TextButton.styleFrom(backgroundColor: Colors.white12), onPressed: _showQualityPickerSheet)
                                      ]),
                                    ),
                                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                      IconButton(icon: const Icon(Icons.replay_10, size: 40, color: Colors.white), onPressed: () => _seekRelative(-10)),
                                      const SizedBox(width: 32),
                                      CircleAvatar(radius: 28, backgroundColor: Colors.red, child: IconButton(icon: Icon(_videoController!.value.isPlaying ? Icons.pause : Icons.play_arrow, size: 32, color: Colors.white), onPressed: () { setState(() { _videoController!.value.isPlaying ? _videoController!.pause() : _videoController!.play(); }); })),
                                      const SizedBox(width: 32),
                                      IconButton(icon: const Icon(Icons.forward_10, size: 40, color: Colors.white), onPressed: () => _seekRelative(10)),
                                    ]),
                                    Padding(padding: const EdgeInsets.all(16.0), child: VideoProgressIndicator(_videoController!, allowScrubbing: true, colors: const VideoProgressColors(playedColor: Colors.red, bufferedColor: Colors.white30, backgroundColor: Colors.white12))),
                                  ]),
                                ),
                              ),
                            )
                          ]),
                        )
                      : const CircularProgressIndicator(),
            ),
          ),
          if (widget.mediaType == 'tv' && !isLandscape)
            Expanded(
              flex: 2,
              child: Container(
                color: const Color(0xFF0D0E12),
                padding: const EdgeInsets.all(16.0),
                child: _isLoadingTvMetadata
                    ? const Center(child: CircularProgressIndicator())
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.between, children: [
                          const Text("Select Episode Source", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                          Text("Playing: S$_selectedSeason E$_selectedEpisode", style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600))
                        ]),
                        const SizedBox(height: 16),
                        Row(children: [
                          Expanded(child: DropdownButtonFormField<int>(value: _selectedSeason, decoration: const InputDecoration(labelText: 'Season', border: OutlineInputBorder(), filled: true, fillColor: Color(0xFF16181F)), items: List.generate(_totalSeasons, (i) => i + 1).map((s) => DropdownMenuItem(value: s, child: Text('Season $s'))).toList(), onChanged: (val) async { if (val != null && val != _selectedSeason) { _selectedSeason = val; setState(() => _isLoadingTvMetadata = true); await _fetchEpisodesForSeason(_selectedSeason); setState(() => _isLoadingTvMetadata = false); _updateEmbedUrlAndBootScraper(); } })),
                          const SizedBox(width: 16),
                          Expanded(child: DropdownButtonFormField<int>(value: _selectedEpisode, decoration: const InputDecoration(labelText: 'Episode', border: OutlineInputBorder(), filled: true, fillColor: Color(0xFF16181F)), items: _episodesInSeason.map((e) => DropdownMenuItem(value: e, child: Text('Episode $e'))).toList(), onChanged: (val) { if (val != null && val != _selectedEpisode) { setState(() => _selectedEpisode = val); _updateEmbedUrlAndBootScraper(); } })),
                        ]),
                      ]),
              ),
            ),
        ],
      ),
    );
  }


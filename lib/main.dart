import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pmpml_data.dart';
import 'journey_screen.dart';
import 'voice_service.dart';
import 'background_service_helper.dart';
import 'transit_service.dart';
import 'emergency_service.dart';

// void main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//
//   // Start the Android foreground service so the process survives
//   // being backgrounded or the screen turning off.
//   await initBackgroundService();
//
//   SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
//   SystemChrome.setSystemUIOverlayStyle(
//     const SystemUiOverlayStyle(
//       statusBarColor: Colors.transparent,
//       statusBarIconBrightness: Brightness.light,
//     ),
//   );
//   runApp(const PMPMLApp());
// }
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Foreground service
  await initBackgroundService();

  // Pre-load all stop names from SQLite into memory cache
  // so voice matching and autocomplete work synchronously
  await PMPMLData.preload();

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const PMPMLApp());
}

class PMPMLApp extends StatelessWidget {
  const PMPMLApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PMPML Guide',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A3D62),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});


  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _pulseController;
  late AnimationController _slideController;
  late AnimationController _wakeRingController;
  late Animation<double> _pulseAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _wakeRingAnimation;

  final VoiceService _voiceService = VoiceService();
  EmergencyService? _emergencyService;
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _destController = TextEditingController();

  String? _selectedSource;
  String? _selectedDest;
  bool _isListeningSource = false;
  bool _isListeningDest = false;
  bool _isSearching = false;
  List<String> _sourceSuggestions = [];
  List<String> _destSuggestions = [];
  bool _showSourceSuggestions = false;
  bool _showDestSuggestions = false;
  bool _isNightMode = false;   // ← add this line

  // Wake word state
  bool _botActive = false;            // true after "hey busbot" is heard
  Timer? _deactivateTimer;            // auto-sleep after 30 s of no command

  final FocusNode _sourceFocus = FocusNode();
  final FocusNode _destFocus = FocusNode();

  // ─────────────────────────────────────────────
  // LIFECYCLE
  // ─────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    _wakeRingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOut));

    _wakeRingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _wakeRingController, curve: Curves.easeOut),
    );

    _sourceFocus.addListener(() {
      if (!_sourceFocus.hasFocus) {
        Future.delayed(
          const Duration(milliseconds: 200),
              () => setState(() => _showSourceSuggestions = false),
        );
      }
    });

    _destFocus.addListener(() {
      if (!_destFocus.hasFocus) {
        Future.delayed(
          const Duration(milliseconds: 200),
              () => setState(() => _showDestSuggestions = false),
        );
      }
    });

    _initVoice();
  }

  Future<void> _initVoice() async {
    await _voiceService.initialize();

    // 👇 Immediately activate bot (NO wake word needed)
    setState(() => _botActive = true);

    updateServiceNotification('BusBot active — listening...');

    await _voiceService.startWakeWordListening(
      onWakeWordDetected: () {}, // not needed
      onActiveCommand: _handleVoiceCommand,
    );

    _voiceService.activateFullListening(); // 👈 IMPORTANT
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _slideController.dispose();
    _wakeRingController.dispose();
    _sourceController.dispose();
    _destController.dispose();
    _sourceFocus.dispose();
    _destFocus.dispose();
    _deactivateTimer?.cancel();
    _emergencyService?.stopMonitoring();
    _voiceService.dispose();
    super.dispose();
  }

  // Keep the background service's notification in sync when app is paused.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      updateServiceNotification(
        _botActive
            ? 'BusBot active — say a command'
            : 'Sleeping — say "Hey BusBot" to wake',
      );
    }
  }

  // ─────────────────────────────────────────────
  // WAKE WORD DETECTED
  // ─────────────────────────────────────────────
  void _onWakeWordDetected() async {
    setState(() => _botActive = true);
    _wakeRingController.forward(from: 0);
    updateServiceNotification('BusBot active — say a command');

    await _voiceService.speak(
      "BusBot activated. Say a stop name, or say Swargate to Baner start journey.",
    );

    _voiceService.activateFullListening();

    // Auto-sleep after 30 seconds of silence
    _deactivateTimer?.cancel();
    _deactivateTimer = Timer(const Duration(seconds: 30), _autoSleep);
  }

  void _autoSleep() async {
    if (!mounted) return;
    setState(() => _botActive = false);
    updateServiceNotification('Sleeping — say "Hey BusBot" to wake');
    _voiceService.deactivateToWakeWord();
  }

  // ─────────────────────────────────────────────
  // ACTIVE COMMAND HANDLER
  // ─────────────────────────────────────────────
  void _handleVoiceCommand(String command) async {
    print('🗣 Command: $command');

    // Reset sleep timer on every command
    _deactivateTimer?.cancel();
    _deactivateTimer = Timer(const Duration(seconds: 30), _autoSleep);

    // ── "sleep" / "stop" / "goodbye" ──────────────
    if (command.contains('sleep') ||
        command.contains('stop listening') ||
        command.contains('goodbye') ||
        command.contains('go to sleep')) {
      await _voiceService.speak("Going to sleep. Say Hey BusBot to wake me.");
      _autoSleep();
      return;
    }
    // ── "night mode" ──────────────────────────────
    // if (command.contains('night mode')) {
    //   await _voiceService.speak("Night mode activated. Alerting emergency contacts.");
    //   await _emergencyService?.sendManualAlert(); // 👈 we'll add this method
    //   return;
    // }
    if (command.contains('night mode on') ||
        (command.contains('night mode') && !command.contains('off'))) {
      _emergencyService?.enableNightMode();
      setState(() => _isNightMode = true);
      await _voiceService.speak(
        "Night mode on. I will now send SMS alerts to your emergency contacts "
            "at every key stop and when you arrive.",
      );
      return;
    }

    if (command.contains('night mode off') ||
        command.contains('disable night mode') ||
        command.contains('turn off night mode')) {
      _emergencyService?.disableNightMode();
      setState(() => _isNightMode = false);
      await _voiceService.speak("Night mode off. SMS alerts paused.");
      return;
    }
    if (command.contains('test sms')) {
      print('🧪 Running SMS debug test...');
      await _emergencyService?.debugTestSms();
      await _voiceService.speak("Check logs for SMS debug info.");
      return;
    }
    // ── Pattern: "X to Y [start/find/go/journey]" ─
    final cleanCommand = command.toLowerCase().trim();

// More flexible pattern
    final toPattern = RegExp(r'(.+?)\s+to\s+(.+)');
    final toMatch = toPattern.firstMatch(cleanCommand);

    if (toMatch != null) {
      final rawSource = toMatch.group(1)!.trim();
      final rawDest = toMatch.group(2)!.trim();

      final matchedSource = _findBestMatch(rawSource);
      final matchedDest = _findBestMatch(rawDest);

      if (matchedSource != null && matchedDest != null) {
        setState(() {
          _selectedSource = matchedSource;
          _selectedDest = matchedDest;
          _sourceController.text = matchedSource;
          _destController.text = matchedDest;
        });

        await _voiceService.speak(
          "Source $matchedSource, destination $matchedDest.",
        );

        // ✅ ONLY start journey if action words present
        final actionWords = [
          'find',
          'search',
          'route',
          'journey',
          'go',
          'start',
          'navigate'
        ];

        if (actionWords.any((word) => command.contains(word))) {
          if (_selectedSource != null && _selectedDest != null) {
            await _voiceService.speak("Searching route...");
            _searchRoute();
          } else {
            await _voiceService.speak(
              "Please say both source and destination first.",
            );
          }
          return;
        }

        return;
      }

      if (matchedSource != null && matchedDest == null) {
        setState(() {
          _selectedSource = matchedSource;
          _sourceController.text = matchedSource;
        });

        await _voiceService.speak(
          "Source set to $matchedSource. Could not find destination.",
        );
        return;
      }
    }

    // ── Single stop name ──────────────────────────
    final singleMatch = _findBestMatch(command);
    if (singleMatch != null) {
      setState(() {
        if (_selectedSource == null) {
          _selectedSource = singleMatch;
          _sourceController.text = singleMatch;
        } else if (_selectedDest == null) {
          _selectedDest = singleMatch;
          _destController.text = singleMatch;
        }
      });
      await _voiceService.speak("$singleMatch selected");
      return;
    }

    // ── Action words ──────────────────────────────
    final actionWords = [
      'find',
      'search',
      'route',
      'journey',
      'go',
      'start',
      'navigate'
    ];

    if (actionWords.any((word) => command.contains(word))) {
      await _voiceService.speak("Searching route...");
      _searchRoute();
      return;
    }

    // ── Clear ─────────────────────────────────────
    if (command.contains('clear') || command.contains('reset')) {
      setState(() {
        _selectedSource = null;
        _selectedDest = null;
        _sourceController.clear();
        _destController.clear();
      });
      await _voiceService.speak("Cleared. Please say source and destination.");
    }
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────
  // String? _findBestMatch(String query) {
  //   if (query.isEmpty) return null;
  //   final allStops = PMPMLData.allStops;
  //   final q = query.toLowerCase().trim();
  //   for (final stop in allStops) {
  //     if (stop.toLowerCase() == q) return stop;
  //   }
  //   for (final stop in allStops) {
  //     if (stop.toLowerCase().contains(q)) return stop;
  //   }
  //   for (final stop in allStops) {
  //     if (q.contains(stop.toLowerCase())) return stop;
  //   }
  //   return null;
  // }
  String? _findBestMatch(String query) {
    return PMPMLData.findBestMatchSync(query);
  }
  //
  // void _filterSuggestions(String query, bool isSource) {
  //   final allStops = PMPMLData.allStops;
  //   final filtered = allStops
  //       .where((s) => s.toLowerCase().contains(query.toLowerCase()))
  //       .take(5)
  //       .toList();
  //   setState(() {
  //     if (isSource) {
  //       _sourceSuggestions = filtered;
  //       _showSourceSuggestions = filtered.isNotEmpty && query.isNotEmpty;
  //     } else {
  //       _destSuggestions = filtered;
  //       _showDestSuggestions = filtered.isNotEmpty && query.isNotEmpty;
  //     }
  //   });
  // }
  void _filterSuggestions(String query, bool isSource) {
    final filtered = PMPMLData.getSuggestions(query, limit: 5);
    setState(() {
      if (isSource) {
        _sourceSuggestions = filtered;
        _showSourceSuggestions = filtered.isNotEmpty && query.isNotEmpty;
      } else {
        _destSuggestions = filtered;
        _showDestSuggestions = filtered.isNotEmpty && query.isNotEmpty;
      }
    });
  }

  Future<void> _listenForVoice(bool isSource) async {
    // If bot is sleeping, activate first
    if (!_botActive) {
      _onWakeWordDetected();
      return;
    }

    setState(() {
      if (isSource) _isListeningSource = true;
      else _isListeningDest = true;
    });

    await _voiceService.speak(
      isSource ? "Please say your source stop" : "Please say your destination stop",
    );

    final result = await _voiceService.listen();

    setState(() {
      if (isSource) _isListeningSource = false;
      else _isListeningDest = false;
    });

    if (result != null) {
      final match = _findBestMatch(result);
      setState(() {
        if (isSource) {
          _selectedSource = match;
          _sourceController.text = match ?? result;
        } else {
          _selectedDest = match;
          _destController.text = match ?? result;
        }
      });
      await _voiceService.speak(
        match != null
            ? (isSource ? "Source set to $match" : "Destination set to $match")
            : "Could not find stop: $result.",
      );
    }
  }

  // void _searchRoute() async {
  //   if (_selectedSource == null || _selectedDest == null) {
  //     await _voiceService.speak(
  //         "Please select both source and destination first.");
  //     return;
  //   }
  //
  //   if (_selectedSource == _selectedDest) {
  //     await _voiceService.speak(
  //         "Source and destination cannot be the same.");
  //     return;
  //   }
  //
  //   setState(() => _isSearching = true);
  //
  //   final routes = await TransitService.fetchRoutes(
  //     _selectedSource!,
  //     _selectedDest!,
  //   );
  //
  //   setState(() => _isSearching = false);
  //
  //   if (routes.isEmpty) {
  //     await _voiceService.speak("No routes found.");
  //     return;
  //   }
  //
  //   final best = routes.first;
  //
  //   // 🎤 Speak result
  //   await _voiceService.speak(best.voiceSummary);
  //
  //   // Debug
  //   print("ROUTE: ${best.summary}");
  //   for (var step in best.steps) {
  //     print("${step.travelMode}: ${step.instruction}");
  //   }
  // }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────
  Future<void> _searchRoute() async {
    if (_selectedSource == null || _selectedDest == null) {
      await _voiceService.speak(
        "Please select both source and destination first.",
      );
      return;
    }

    if (_selectedSource == _selectedDest) {
      await _voiceService.speak(
        "Source and destination cannot be the same.",
      );
      return;
    }

    setState(() => _isSearching = true);

    // 🔥 USING INBUILT PMPML DATA (NO API)
    setState(() => _isSearching = true);
    final routes = await PMPMLData.findRoutes(_selectedSource!, _selectedDest!);
    setState(() => _isSearching = false);

    setState(() => _isSearching = false);

    if (routes.isEmpty) {
      await _voiceService.speak(
        "No direct bus route found between $_selectedSource and $_selectedDest.",
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No routes found between these stops'),
            backgroundColor: Color(0xFFE74C3C),
          ),
        );
      }
      return;
    }

    final best = routes.first;

    await _voiceService.speak(
      "Found ${routes.length} route${routes.length > 1 ? 's' : ''}. "
          "Best route is bus number ${best.busNumber} with ${best.stops
          .length} stops. "
          "Crowd level is ${best.crowdLevel}.",
    );

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              JourneyScreen(
                source: _selectedSource!,
                destination: _selectedDest!,
                routes: routes,
                voiceService: _voiceService,
              ),
        ),
      );
    }
    // Start emergency monitoring once journey begins
    _emergencyService?.stopMonitoring(); // stop any previous session
    // _emergencyService = EmergencyService(
    //   emergencyContacts: ['7499687384', '8788537995'], // 👈 replace with real numbers
    //   routeStops: best.stops.map((s) => RouteStop(
    //     name: s.name,
    //     latitude: s.latitude,
    //     longitude: s.longitude,
    //   )).toList(),
    //   userName: 'User',
    //   busNumber: best.busNumber,
    //   destination: _selectedDest!,
    // );
    //   _emergencyService = EmergencyService(
    //     emergencyContacts: ['917499687384', '918788537995'], // 👈 your real numbers
    //     routeStops: best.journeyStops.map((name) => RouteStop(name: name)).toList(),
    //     userName: 'User',
    //     busNumber: best.busNumber,
    //     destination: _selectedDest!,
    //   );
    //   await _emergencyService!.startMonitoring();
    //   await _emergencyService!.startMonitoring();
    // }
    _emergencyService = EmergencyService(
      emergencyContacts: ['917499687384', '918788537995'],
      routeStops: best.journeyStops
          .map((name) => RouteStop(name: name))
          .toList(),
      userName: 'User',
      busNumber: best.busNumber,
      destination: _selectedDest!,
      nightMode: _isNightMode, // ← ADD THIS LINE — passes current night mode state
    );
    await _emergencyService!.startMonitoring();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A3D62), Color(0xFF1A5276), Color(0xFF0E6655)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: SlideTransition(
              position: _slideAnimation,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 16),
                  _buildWakeBadge(),
                  const SizedBox(height: 12),
                  _buildNightModeToggle(),   // ← add this
                  const SizedBox(height: 24),
                  _buildSearchCard(),
                  const SizedBox(height: 24),
                  _buildQuickStops(),
                  const SizedBox(height: 24),
                  _buildFeatureCards(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Prominent banner showing sleep/active state with animated ring on activation.
  Widget _buildWakeBadge() {
    return GestureDetector(
      onTap: _botActive ? _autoSleep : _onWakeWordDetected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          color: _botActive
              ? const Color(0xFF58D68D).withOpacity(0.18)
              : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _botActive
                ? const Color(0xFF58D68D)
                : Colors.white.withOpacity(0.2),
            width: _botActive ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // Animated ring on wake
            ScaleTransition(
              scale: _botActive
                  ? _wakeRingAnimation
                  : const AlwaysStoppedAnimation(1.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _botActive
                      ? const Color(0xFF58D68D).withOpacity(0.25)
                      : Colors.white.withOpacity(0.08),
                  border: Border.all(
                    color: _botActive
                        ? const Color(0xFF58D68D)
                        : Colors.white30,
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  _botActive ? Icons.mic : Icons.mic_off,
                  color: _botActive ? const Color(0xFF58D68D) : Colors.white38,
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _botActive ? 'BusBot is listening' : 'BusBot is sleeping',
                    style: TextStyle(
                      color: _botActive
                          ? const Color(0xFF58D68D)
                          : Colors.white60,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _botActive
                        ? 'Say a command or tap to sleep'
                        : 'Say "Hey BusBot" or tap to wake',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _botActive ? Icons.nightlight_round : Icons.record_voice_over,
              color: _botActive ? Colors.white38 : const Color(0xFF58D68D),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        ScaleTransition(
          scale: _pulseAnimation,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.directions_bus, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PMPML Guide',
              style: TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              'Pune Mahanagar Parivahan',
              style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13),
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          onPressed: () => _voiceService.speak(
            "Say Hey BusBot to activate me. Then say a route like Swargate to Baner start journey.",
          ),
          icon: const Icon(Icons.help_outline, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildSearchCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Plan Your Journey',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Say: "Hey BusBot" → "Swargate to Baner start journey"',
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
          ),
          const SizedBox(height: 20),
          _buildStopInput(
            controller: _sourceController,
            focusNode: _sourceFocus,
            label: 'From (Source Stop)',
            icon: Icons.trip_origin,
            iconColor: const Color(0xFF58D68D),
            isListening: _isListeningSource,
            onVoice: () => _listenForVoice(true),
            onChanged: (v) {
              _selectedSource = null;
              _filterSuggestions(v, true);
            },
            suggestions: _sourceSuggestions,
            showSuggestions: _showSourceSuggestions,
            onSuggestionTap: (s) {
              setState(() {
                _selectedSource = s;
                _sourceController.text = s;
                _showSourceSuggestions = false;
              });
              _sourceFocus.unfocus();
              _voiceService.speak("Source set to $s");
            },
          ),
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: () {
                final tmp = _sourceController.text;
                _sourceController.text = _destController.text;
                _destController.text = tmp;
                final tmpSel = _selectedSource;
                setState(() {
                  _selectedSource = _selectedDest;
                  _selectedDest = tmpSel;
                });
              },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white30),
                ),
                child: const Icon(Icons.swap_vert, color: Colors.white, size: 20),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildStopInput(
            controller: _destController,
            focusNode: _destFocus,
            label: 'To (Destination Stop)',
            icon: Icons.location_on,
            iconColor: const Color(0xFFE74C3C),
            isListening: _isListeningDest,
            onVoice: () => _listenForVoice(false),
            onChanged: (v) {
              _selectedDest = null;
              _filterSuggestions(v, false);
            },
            suggestions: _destSuggestions,
            showSuggestions: _showDestSuggestions,
            onSuggestionTap: (s) {
              setState(() {
                _selectedDest = s;
                _destController.text = s;
                _showDestSuggestions = false;
              });
              _destFocus.unfocus();
              _voiceService.speak("Destination set to $s");
            },
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: _isSearching ? null : _searchRoute,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF58D68D),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: _isSearching
                  ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Finding Route...',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              )
                  : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search, size: 22),
                  SizedBox(width: 8),
                  Text('Find Best Route',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStopInput({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    required Color iconColor,
    required bool isListening,
    required VoidCallback onVoice,
    required ValueChanged<String> onChanged,
    required List<String> suggestions,
    required bool showSuggestions,
    required Function(String) onSuggestionTap,
  }) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isListening
                  ? const Color(0xFF58D68D)
                  : Colors.white.withOpacity(0.2),
              width: isListening ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  style: const TextStyle(color: Colors.white),
                  onChanged: onChanged,
                  decoration: InputDecoration(
                    hintText: label,
                    hintStyle:
                    TextStyle(color: Colors.white.withOpacity(0.5)),
                    border: InputBorder.none,
                    contentPadding:
                    const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              GestureDetector(
                onTap: onVoice,
                child: Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isListening
                        ? const Color(0xFF58D68D)
                        : Colors.white.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isListening ? Icons.mic : Icons.mic_none,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (showSuggestions)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1A3A5C),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              children: suggestions
                  .map(
                    (s) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.directions_bus,
                      color: Colors.white54, size: 16),
                  title: Text(s,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14)),
                  onTap: () => onSuggestionTap(s),
                ),
              )
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildQuickStops() {
    final popularStops = [
      'Swargate',
      'Shivajinagar',
      'Pune Station',
      'Hinjewadi',
      'Kothrud',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Popular Stops',
          style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: popularStops
              .map(
                (stop) => GestureDetector(
              onTap: () {
                if (_selectedSource == null) {
                  setState(() {
                    _selectedSource = stop;
                    _sourceController.text = stop;
                  });
                  _voiceService.speak("Source set to $stop");
                } else if (_selectedDest == null) {
                  setState(() {
                    _selectedDest = stop;
                    _destController.text = stop;
                  });
                  _voiceService.speak("Destination set to $stop");
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(stop,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13)),
              ),
            ),
          )
              .toList(),
        ),
      ],
    );
  }
  Widget _buildNightModeToggle() {
    return GestureDetector(
      onTap: () async {
        if (_isNightMode) {
          _emergencyService?.disableNightMode();
          setState(() => _isNightMode = false);
          await _voiceService.speak("Night mode off.");
        } else {
          _emergencyService?.enableNightMode();
          setState(() => _isNightMode = true);
          await _voiceService.speak(
            "Night mode on. SMS alerts will be sent to emergency contacts.",
          );
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
        decoration: BoxDecoration(
          color: _isNightMode
              ? const Color(0xFF1A237E).withOpacity(0.4)
              : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isNightMode
                ? const Color(0xFF7986CB)
                : Colors.white.withOpacity(0.15),
            width: _isNightMode ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              _isNightMode ? Icons.nightlight : Icons.nightlight_outlined,
              color: _isNightMode ? const Color(0xFF7986CB) : Colors.white38,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isNightMode ? 'Night Mode ON' : 'Night Mode OFF',
                    style: TextStyle(
                      color: _isNightMode
                          ? const Color(0xFF7986CB)
                          : Colors.white60,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    _isNightMode
                        ? 'SMS alerts active — contacts will be notified'
                        : 'Tap or say "night mode on" to enable SMS alerts',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _isNightMode,
              onChanged: (val) async {
                if (val) {
                  _emergencyService?.enableNightMode();
                  setState(() => _isNightMode = true);
                  await _voiceService.speak("Night mode on.");
                } else {
                  _emergencyService?.disableNightMode();
                  setState(() => _isNightMode = false);
                  await _voiceService.speak("Night mode off.");
                }
              },
              activeColor: const Color(0xFF7986CB),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureCards() {
    return Column(
      children: [
        Row(
          children: [
            _featureCard(Icons.record_voice_over, 'Voice Guided',
                'Hands-free navigation'),
            const SizedBox(width: 12),
            _featureCard(
                Icons.vibration, 'Wake Alert', 'Vibrates at destination'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _featureCard(Icons.people, 'Crowd Meter', 'Live crowd levels'),
            const SizedBox(width: 12),
            _featureCard(Icons.route, 'Smart Route', 'Fastest bus found'),
          ],
        ),
      ],
    );
  }

  Widget _featureCard(IconData icon, String title, String subtitle) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF58D68D), size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

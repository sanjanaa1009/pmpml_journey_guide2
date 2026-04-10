import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math';
import 'pmpml_data.dart';
import 'voice_service.dart';
import 'emergency_service.dart';

class JourneyScreen extends StatefulWidget {
  final String source;
  final String destination;
  final List<BusRoute> routes;
  final VoiceService voiceService;
  final EmergencyService? emergencyService;

  const JourneyScreen({
    super.key,
    required this.source,
    required this.destination,
    required this.routes,
    required this.voiceService,
    this.emergencyService,
  });

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen>
    with TickerProviderStateMixin {
  late BusRoute _selectedRoute;
  int _currentStopIndex = 0;
  bool _journeyStarted = false;
  bool _journeyCompleted = false;
  Timer? _journeyTimer;
  late AnimationController _busController;
  late AnimationController _alertController;
  late Animation<double> _busAnimation;
  late Animation<double> _alertAnimation;
  bool _showArrivalAlert = false;
  int _selectedRouteIndex = 0;
  bool _autoNavigatingHome = false;  // set true after voice countdown

  @override
  void initState() {
    super.initState();
    _selectedRoute = widget.routes.first;

    _busController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    _alertController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _busAnimation = Tween<double>(begin: -4, end: 4).animate(
      CurvedAnimation(parent: _busController, curve: Curves.easeInOut),
    );

    _alertAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _alertController, curve: Curves.elasticOut),
    );

    // ── FIX: Switch directly to active mode so "start" is heard immediately
    // Do NOT call startWakeWordListening again — it resets mode to wakeWord.
    // The native STT is already running from HomeScreen.
    widget.voiceService.activateFullListening();

    // Register the journey-specific command handler by swapping the callback
    // through a small shim. We re-use startWakeWordListening only to update
    // the onActiveCommand pointer, then immediately force active mode again.
    widget.voiceService.startWakeWordListening(
      onWakeWordDetected: () {
        widget.voiceService.activateFullListening();
        widget.voiceService.speak("I'm listening. Say start journey.");
      },
      onActiveCommand: _handleJourneyCommand,
    );
    // Force active — override the wakeWord mode set by startWakeWordListening
    widget.voiceService.activateFullListening();

    // Announce and tell user to say "start journey"
    Future.delayed(const Duration(milliseconds: 300), () async {
      await widget.voiceService.speak(
        "Route found! Bus number ${_selectedRoute.busNumber}. "
            "${_selectedRoute.stopsCount} stops to ${widget.destination}. "
            "Estimated time: ${_selectedRoute.estimatedMinutes} minutes. "
            "Crowd level: ${_selectedRoute.crowdLevel.label}. "
            "Say start journey to begin tracking.",
      );
      // After speaking, make sure we're still in active mode
      widget.voiceService.activateFullListening();
    });
  }

  @override
  void dispose() {
    _journeyTimer?.cancel();
    _busController.dispose();
    _alertController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // VOICE COMMAND HANDLER (Journey screen)
  // ─────────────────────────────────────────────
  void _handleJourneyCommand(String command) async {
    final cmd = command.toLowerCase().trim();
    print('🎤 Journey command: $cmd');

    // ── Switch bus (check FIRST before anything else) ──────────────────────
    // Matches: "switch to bus ac1", "take ac1", "bus 50", "second bus", etc.
    for (int i = 0; i < widget.routes.length; i++) {
      final busNo = widget.routes[i].busNumber.toLowerCase();
      if (cmd.contains(busNo)) {
        if (i == _selectedRouteIndex) {
          await widget.voiceService.speak("Already on bus ${widget.routes[i].busNumber}.");
        } else {
          await _switchRoute(i);
        }
        return;
      }
    }

    // "second bus" / "first bus" ordinals
    const ordinals = ['first', 'second', 'third', 'fourth', 'fifth'];
    for (int i = 0; i < ordinals.length && i < widget.routes.length; i++) {
      if (cmd.contains(ordinals[i])) {
        await _switchRoute(i);
        return;
      }
    }

    // "switch bus" / "change bus" with no specific number — list options
    if ((cmd.contains('switch') || cmd.contains('change')) && cmd.contains('bus')) {
      if (widget.routes.length <= 1) {
        await widget.voiceService.speak("Only one route available.");
        return;
      }
      final busList = widget.routes
          .map((r) => "bus ${r.busNumber}, ${r.stopsCount} stops")
          .join(". ");
      await widget.voiceService.speak(
        "Available: $busList. Say the bus number to switch.",
      );
      return;
    }

    // ── Start journey ───────────────────────────────────────────────────────
    if (!_journeyStarted &&
        (cmd == 'start' ||
            cmd == 'go' ||
            cmd.contains('start journey') ||
            cmd.contains('begin journey') ||
            cmd.contains('lets go') ||
            cmd.contains("let's go"))) {
      _startJourney();
      return;
    }

    // ── Status ──────────────────────────────────────────────────────────────
    if (cmd.contains('status') || cmd.contains('where am i') || cmd.contains('where are')) {
      if (_journeyStarted) {
        final stop = _selectedRoute.journeyStops[_currentStopIndex];
        final remaining = _selectedRoute.journeyStops.length - 1 - _currentStopIndex;
        await widget.voiceService.speak(
          "Currently at $stop. $remaining stops remaining to ${widget.destination}.",
        );
      } else {
        await widget.voiceService.speak("Journey not started. Say start journey.");
      }
      return;
    }

    // ── Cancel auto-go-home or pause journey ────────────────────────────────
    if (cmd.contains('cancel') || cmd.contains('stay') || cmd.contains('pause')) {
      if (_journeyCompleted) {
        _autoNavigatingHome = true;
        setState(() => _showArrivalAlert = false);
        _alertController.reverse();
        await widget.voiceService.speak("Okay, staying. Tap Back to Home when ready.");
        return;
      }
      _journeyTimer?.cancel();
      await widget.voiceService.speak("Journey paused.");
      return;
    }

    // ── Go back ─────────────────────────────────────────────────────────────
    if (cmd.contains('go back') || cmd.contains('go home') || cmd == 'back' || cmd == 'home') {
      _journeyTimer?.cancel();
      if (mounted) Navigator.pop(context);
      return;
    }
  }

  // ─────────────────────────────────────────────
  // SWITCH ROUTE
  // ─────────────────────────────────────────────
  Future<void> _switchRoute(int index) async {
    if (index < 0 || index >= widget.routes.length) return;
    final route = widget.routes[index];

    _journeyTimer?.cancel();
    _journeyTimer = null;

    setState(() {
      _selectedRouteIndex = index;
      _selectedRoute      = route;
      _currentStopIndex   = 0;
      _journeyStarted     = false;
      _journeyCompleted   = false;
      _showArrivalAlert   = false;
    });

    _alertController.reset();

    // Re-register handler and force active mode so next command is heard
    widget.voiceService.startWakeWordListening(
      onWakeWordDetected: () => widget.voiceService.activateFullListening(),
      onActiveCommand: _handleJourneyCommand,
    );
    widget.voiceService.activateFullListening();

    await widget.voiceService.speak(
      "Switched to bus ${route.busNumber}. "
          "${route.stopsCount} stops to ${widget.destination}, "
          "about ${route.estimatedMinutes} minutes. "
          "Say start journey to begin.",
    );

    // Stay active after TTS finishes
    widget.voiceService.activateFullListening();
  }

  // ─────────────────────────────────────────────
  // START JOURNEY
  // ─────────────────────────────────────────────
  void _startJourney() async {
    if (_journeyStarted) return;

    setState(() {
      _journeyStarted   = true;
      _currentStopIndex = 0;
    });

    await widget.voiceService.speak(
      "Journey started on bus ${_selectedRoute.busNumber}. "
          "I will alert you at every stop and when you are near ${widget.destination}.",
    );

    // Capture the route at start time — if user switches, timer self-cancels
    final startedOnRoute = _selectedRoute;

    _journeyTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      if (!mounted) { timer.cancel(); return; }

      // If route was switched, this timer is stale — kill it
      if (!_journeyStarted || _selectedRoute != startedOnRoute) {
        timer.cancel();
        return;
      }

      final journeyStops   = startedOnRoute.journeyStops;
      final totalStops     = journeyStops.length;
      final stopsRemaining = totalStops - 1 - _currentStopIndex;

      if (_currentStopIndex < totalStops - 1) {
        setState(() => _currentStopIndex++);

        // Recalculate stopsRemaining AFTER incrementing
        final remaining = totalStops - 1 - _currentStopIndex;
        final currentStop = journeyStops[_currentStopIndex];
        await widget.voiceService.speak("Approaching $currentStop");
        await widget.emergencyService?.onStopReached(_currentStopIndex, currentStop);

        if (remaining == 2) {
          await widget.voiceService.speak(
            "Heads up! ${widget.destination} is just 2 stops away. Get ready.",
          );
          _vibratePattern(PatternType.gentle);
        }

        if (remaining == 1) {
          await widget.voiceService.speak(
            "Next stop is your destination: ${widget.destination}. Move to the exit now.",
          );
          _vibratePattern(PatternType.strong);
        }
      } else {
        timer.cancel();
        setState(() => _journeyCompleted = true);
        _vibratePattern(PatternType.arrival);
        _showArrivalBanner();
        await widget.emergencyService?.onArrived();
        await widget.voiceService.speak(
          "You have arrived at ${widget.destination}. Thank you for using PMPML Guide. Have a great day!",
        );
      }
    });
  }

  // ─────────────────────────────────────────────
  // VIBRATION PATTERNS — native Android Vibrator
  // ─────────────────────────────────────────────
  static const _vibrateChannel = MethodChannel('com.pmpml.busbot/vibrate');

  Future<void> _vibratePattern(PatternType type) async {
    try {
      switch (type) {
        case PatternType.gentle:
          await _vibrateChannel.invokeMethod('gentle');
          break;
        case PatternType.strong:
          await _vibrateChannel.invokeMethod('strong');
          break;
        case PatternType.arrival:
          await _vibrateChannel.invokeMethod('arrival');
          break;
      }
    } catch (e) {
      // Fallback to haptic if channel unavailable (emulator/iOS)
      await HapticFeedback.heavyImpact();
    }
  }

  void _showArrivalBanner() {
    setState(() => _showArrivalAlert = true);
    _alertController.forward();

    // Auto-dismiss overlay and go home after voice countdown
    _voiceCountdownAndGoHome();
  }

  Future<void> _voiceCountdownAndGoHome() async {
    // Wait for TTS arrival message to finish (it runs in parallel in the timer)
    await Future.delayed(const Duration(seconds: 1));

    await widget.voiceService.speak(
      "You have reached ${widget.destination}. "
          "Exiting journey in 5 seconds. Say cancel to stay.",
    );

    // 5-second window to say "cancel"
    // Switch to active so "cancel" voice command is heard
    widget.voiceService.activateFullListening();

    await Future.delayed(const Duration(seconds: 5));

    // If still mounted and not cancelled, auto-dismiss and go back
    if (mounted && !_autoNavigatingHome) {
      _autoNavigatingHome = true;
      setState(() => _showArrivalAlert = false);
      _alertController.reverse();
      await widget.voiceService.speak("Returning to home screen. Goodbye!");
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) Navigator.pop(context);
    }
  }

  Color _crowdColor(CrowdLevel level) {
    switch (level) {
      case CrowdLevel.low:        return const Color(0xFF58D68D);
      case CrowdLevel.moderate:   return const Color(0xFFF4D03F);
      case CrowdLevel.high:       return const Color(0xFFE67E22);
      case CrowdLevel.veryHigh:   return const Color(0xFFE74C3C);
    }
  }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────
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
          child: Stack(
            children: [
              Column(
                children: [
                  _buildAppBar(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _buildRouteHeader(),
                          const SizedBox(height: 16),
                          if (widget.routes.length > 1) _buildRouteTabs(),
                          if (widget.routes.length > 1) const SizedBox(height: 16),
                          _buildBusInfoCard(),
                          const SizedBox(height: 16),
                          _buildCrowdCard(),
                          const SizedBox(height: 16),
                          _buildJourneyTimeline(),
                          const SizedBox(height: 16),
                          if (!_journeyStarted && !_journeyCompleted)
                            _buildStartButton(),
                          if (_journeyCompleted)
                            _buildCompletedCard(),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (_showArrivalAlert) _buildArrivalOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              _journeyTimer?.cancel();
              Navigator.pop(context);
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Journey Details',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          // Mic status indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF58D68D).withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF58D68D).withOpacity(0.4)),
            ),
            child: const Row(
              children: [
                Icon(Icons.mic, color: Color(0xFF58D68D), size: 14),
                SizedBox(width: 4),
                Text(
                  'Listening',
                  style: TextStyle(color: Color(0xFF58D68D), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () {
              widget.voiceService.speak(
                "You are on bus ${_selectedRoute.busNumber}. "
                    "${_journeyStarted ? 'Currently at ${_selectedRoute.journeyStops[_currentStopIndex]}. ' : ''}"
                    "${_selectedRoute.stopsCount - _currentStopIndex} stops remaining to ${widget.destination}.",
              );
            },
            icon: const Icon(Icons.volume_up, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.source,
                  style: const TextStyle(
                    color: Color(0xFF58D68D),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Icon(Icons.arrow_downward, color: Colors.white54, size: 18),
                Text(
                  widget.destination,
                  style: const TextStyle(
                    color: Color(0xFFE74C3C),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF58D68D).withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF58D68D).withOpacity(0.4)),
            ),
            child: Column(
              children: [
                Text(
                  '~${_selectedRoute.estimatedMinutes} min',
                  style: const TextStyle(
                    color: Color(0xFF58D68D),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '${_selectedRoute.stopsCount} stops',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteTabs() {
    return SizedBox(
      height: 42,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: widget.routes.length,
        itemBuilder: (context, index) {
          final route = widget.routes[index];
          final isSelected = _selectedRouteIndex == index;
          return GestureDetector(
            onTap: () {
              _switchRoute(index);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF58D68D)
                    : Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? const Color(0xFF58D68D) : Colors.white24,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.directions_bus,
                    color: isSelected ? Colors.white : Colors.white54,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    route.busNumber,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBusInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _busAnimation,
            builder: (context, child) {
              return Transform.translate(
                offset: Offset(_busAnimation.value, 0),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A3D62),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.directions_bus,
                    color: Color(0xFF58D68D),
                    size: 32,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Bus #${_selectedRoute.busNumber}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _selectedRoute.busType == 'AC'
                            ? const Color(0xFF3498DB).withOpacity(0.3)
                            : _selectedRoute.busType == 'Electric'
                            ? const Color(0xFF58D68D).withOpacity(0.3)
                            : Colors.white12,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _selectedRoute.busType,
                        style: TextStyle(
                          color: _selectedRoute.busType == 'AC'
                              ? const Color(0xFF3498DB)
                              : _selectedRoute.busType == 'Electric'
                              ? const Color(0xFF58D68D)
                              : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _journeyStarted
                      ? 'Currently at: ${_selectedRoute.journeyStops[_currentStopIndex]}'
                      : 'Board at: ${widget.source}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                if (_journeyStarted && !_journeyCompleted) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: _currentStopIndex /
                        (_selectedRoute.journeyStops.length - 1),
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF58D68D),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_selectedRoute.journeyStops.length - 1 - _currentStopIndex} stops remaining',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCrowdCard() {
    final level = _selectedRoute.crowdLevel;
    final color = _crowdColor(level);
    final percentage = level.index == 0
        ? 25
        : level.index == 1
        ? 50
        : level.index == 2
        ? 75
        : 95;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Crowd Level',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                children: [
                  Text(level.emoji, style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 6),
                  Text(
                    level.label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Stack(
            children: [
              Container(
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(seconds: 1),
                height: 10,
                width: (MediaQuery.of(context).size.width - 64) * percentage / 100,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                  boxShadow: [
                    BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _crowdDot('Low', const Color(0xFF58D68D), level == CrowdLevel.low),
              _crowdDot('Moderate', const Color(0xFFF4D03F), level == CrowdLevel.moderate),
              _crowdDot('High', const Color(0xFFE67E22), level == CrowdLevel.high),
              _crowdDot('Very High', const Color(0xFFE74C3C), level == CrowdLevel.veryHigh),
            ],
          ),
        ],
      ),
    );
  }

  Widget _crowdDot(String label, Color color, bool active) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? color : color.withOpacity(0.3),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: active ? color : Colors.white38,
            fontSize: 10,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildJourneyTimeline() {
    final stops = _selectedRoute.journeyStops;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Stop Timeline',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${stops.length} stops',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...List.generate(stops.length, (i) {
            final isSource = i == 0;
            final isDest = i == stops.length - 1;
            final isPassed = _journeyStarted && i < _currentStopIndex;
            final isCurrent = _journeyStarted && i == _currentStopIndex;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 32,
                  child: Column(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? const Color(0xFF58D68D)
                              : isPassed
                              ? Colors.white30
                              : isSource
                              ? const Color(0xFF58D68D)
                              : isDest
                              ? const Color(0xFFE74C3C)
                              : Colors.white.withOpacity(0.12),
                          shape: BoxShape.circle,
                          boxShadow: isCurrent
                              ? [
                            const BoxShadow(
                              color: Color(0xFF58D68D),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ]
                              : null,
                        ),
                        child: Icon(
                          isCurrent
                              ? Icons.directions_bus
                              : isPassed
                              ? Icons.check
                              : isSource
                              ? Icons.trip_origin
                              : isDest
                              ? Icons.location_on
                              : Icons.circle,
                          color: Colors.white,
                          size: isCurrent ? 12 : 10,
                        ),
                      ),
                      if (i < stops.length - 1)
                        Container(
                          width: 2,
                          height: 28,
                          color: isPassed
                              ? Colors.white30
                              : Colors.white.withOpacity(0.12),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      stops[i],
                      style: TextStyle(
                        color: isCurrent
                            ? const Color(0xFF58D68D)
                            : isPassed
                            ? Colors.white38
                            : isDest
                            ? const Color(0xFFE74C3C)
                            : Colors.white,
                        fontWeight: isCurrent || isSource || isDest
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                if (isCurrent)
                  const Icon(Icons.chevron_left, color: Color(0xFF58D68D), size: 18),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStartButton() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 58,
          child: ElevatedButton(
            onPressed: _startJourney,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF58D68D),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              elevation: 8,
              shadowColor: const Color(0xFF58D68D).withOpacity(0.5),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.play_arrow_rounded, size: 28),
                SizedBox(width: 10),
                Text(
                  'Start Journey',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'or say "start journey"',
          style: TextStyle(
            color: Colors.white.withOpacity(0.45),
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildCompletedCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF58D68D).withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF58D68D).withOpacity(0.4)),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF58D68D), size: 48),
          const SizedBox(height: 10),
          const Text(
            'Journey Completed!',
            style: TextStyle(
              color: Color(0xFF58D68D),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'You have arrived at ${widget.destination}',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF58D68D),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Back to Home'),
          ),
        ],
      ),
    );
  }

  Widget _buildArrivalOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          setState(() => _showArrivalAlert = false);
          _alertController.reverse();
        },
        child: Container(
          color: Colors.black.withOpacity(0.7),
          child: Center(
            child: ScaleTransition(
              scale: _alertAnimation,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A3D62),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF58D68D), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF58D68D).withOpacity(0.3),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🚨', style: TextStyle(fontSize: 48)),
                    const SizedBox(height: 12),
                    const Text(
                      'DESTINATION REACHED!',
                      style: TextStyle(
                        color: Color(0xFF58D68D),
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.destination,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Bus #${_selectedRoute.busNumber} | Please exit now',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () {
                        setState(() => _showArrivalAlert = false);
                        _alertController.reverse();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF58D68D),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Got it!',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Auto-returning home in 5s\nor say "cancel" to stay',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Vibration pattern types
enum PatternType { gentle, strong, arrival }
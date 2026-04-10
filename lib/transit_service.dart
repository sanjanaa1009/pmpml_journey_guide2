import 'dart:convert';
import 'package:http/http.dart' as http;

/// ──────────────────────────────────────────────────────────────────────────
///  TransitService
///
///  Fetches real transit routes (including PMPML bus routes) between two
///  Pune stops using the Google Maps Directions API with mode=transit.
///
///  SETUP:
///    1. Enable "Directions API" in Google Cloud Console.
///    2. Put your key in the .env or pass it at app start.
///       NEVER hard-code in production — use flutter_dotenv or similar.
///    3. For production, proxy through your backend to protect the key.
/// ──────────────────────────────────────────────────────────────────────────

const String _kGoogleApiKey = ''; // ← replace

class TransitStep {
  final String instruction;
  final String? busName;        // e.g. "PMPML 50"
  final String? departureStop;
  final String? arrivalStop;
  final List<String> intermediateStops;
  final int durationMinutes;
  final String travelMode;      // "TRANSIT", "WALKING"

  const TransitStep({
    required this.instruction,
    this.busName,
    this.departureStop,
    this.arrivalStop,
    this.intermediateStops = const [],
    required this.durationMinutes,
    required this.travelMode,
  });
}

class TransitRoute {
  final String summary;
  final int totalMinutes;
  final List<TransitStep> steps;
  final String? mainBusLine;
  final int transitStopsCount;

  const TransitRoute({
    required this.summary,
    required this.totalMinutes,
    required this.steps,
    this.mainBusLine,
    required this.transitStopsCount,
  });

  /// Human-readable voice summary
  String get voiceSummary {
    final bus = mainBusLine ?? 'transit';
    return 'Take $bus for $transitStopsCount stops. '
        'Total journey: $totalMinutes minutes.';
  }
}

class TransitService {
  static const _baseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  /// Fetch real transit routes between [origin] and [destination] in Pune.
  /// Both can be stop names (e.g. "Swargate, Pune") or lat,lng strings.
  static Future<List<TransitRoute>> fetchRoutes(
      String origin,
      String destination,
      ) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'origin': '$origin, Pune, Maharashtra, India',
      'destination': '$destination, Pune, Maharashtra, India',
      'mode': 'transit',
      'transit_mode': 'bus',
      'alternatives': 'true',
      'language': 'en',
      'region': 'in',
      'key': _kGoogleApiKey,
    });

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') {
        print('Directions API: ${data['status']} — ${data['error_message'] ?? ''}');
        return [];
      }

      final routes = (data['routes'] as List)
          .map((r) => _parseRoute(r as Map<String, dynamic>))
          .whereType<TransitRoute>()
          .toList();

      // Sort shortest first
      routes.sort((a, b) => a.totalMinutes.compareTo(b.totalMinutes));
      return routes;
    } catch (e) {
      print('TransitService error: $e');
      return [];
    }
  }

  static TransitRoute? _parseRoute(Map<String, dynamic> route) {
    try {
      final legs = route['legs'] as List;
      if (legs.isEmpty) return null;
      final leg = legs.first as Map<String, dynamic>;

      final totalSeconds = leg['duration']['value'] as int;
      final totalMinutes = (totalSeconds / 60).round();
      final summary = route['summary'] as String? ?? '';

      final steps = <TransitStep>[];
      String? mainBus;
      int transitStops = 0;

      for (final s in (leg['steps'] as List)) {
        final step = s as Map<String, dynamic>;
        final mode = step['travel_mode'] as String;
        final durationSec = step['duration']['value'] as int;
        final durationMin = (durationSec / 60).round();
        final html = step['html_instructions'] as String? ?? '';
        // Strip HTML tags for voice
        final instruction = html
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        if (mode == 'TRANSIT') {
          final td = step['transit_details'] as Map<String, dynamic>?;
          final busName = td?['line']?['short_name'] as String? ??
              td?['line']?['name'] as String?;
          final depStop = td?['departure_stop']?['name'] as String?;
          final arrStop = td?['arrival_stop']?['name'] as String?;
          final numStops = td?['num_stops'] as int? ?? 0;

          // Build intermediate stops list from stop count
          // (full intermediate list requires Places/Stop details API)
          transitStops += numStops;
          if (mainBus == null) mainBus = busName;

          steps.add(TransitStep(
            instruction: instruction,
            busName: busName,
            departureStop: depStop,
            arrivalStop: arrStop,
            intermediateStops: [], // populated if you call Stop Details API
            durationMinutes: durationMin,
            travelMode: mode,
          ));
        } else {
          steps.add(TransitStep(
            instruction: instruction,
            durationMinutes: durationMin,
            travelMode: mode,
          ));
        }
      }

      return TransitRoute(
        summary: summary,
        totalMinutes: totalMinutes,
        steps: steps,
        mainBusLine: mainBus,
        transitStopsCount: transitStops,
      );
    } catch (e) {
      print('Route parse error: $e');
      return null;
    }
  }
}

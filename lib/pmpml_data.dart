import 'dart:math';
import 'database_helper.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  CrowdLevel  (unchanged — journey_screen.dart depends on this)
// ─────────────────────────────────────────────────────────────────────────────
enum CrowdLevel { low, moderate, high, veryHigh }

extension CrowdLevelExt on CrowdLevel {
  String get label {
    switch (this) {
      case CrowdLevel.low:      return 'Low';
      case CrowdLevel.moderate: return 'Moderate';
      case CrowdLevel.high:     return 'High';
      case CrowdLevel.veryHigh: return 'Very High';
    }
  }

  String get emoji {
    switch (this) {
      case CrowdLevel.low:      return '🟢';
      case CrowdLevel.moderate: return '🟡';
      case CrowdLevel.high:     return '🟠';
      case CrowdLevel.veryHigh: return '🔴';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  BusStop
// ─────────────────────────────────────────────────────────────────────────────
class BusStop {
  final int    id;
  final String name;
  final String nameMarathi;
  final String area;
  final double lat;
  final double lng;

  const BusStop({
    required this.id,
    required this.name,
    required this.nameMarathi,
    required this.area,
    required this.lat,
    required this.lng,
  });

  factory BusStop.fromMap(Map<String, dynamic> m) => BusStop(
    id:           m['id'] as int,
    name:         m['name'] as String,
    nameMarathi:  (m['name_marathi'] as String?) ?? '',
    area:         (m['area'] as String?) ?? '',
    lat:          (m['lat'] as num?)?.toDouble() ?? 0.0,
    lng:          (m['lng'] as num?)?.toDouble() ?? 0.0,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  BusRoute  (drop-in replacement — same fields as before + extras)
// ─────────────────────────────────────────────────────────────────────────────
class BusRoute {
  final String     busNumber;
  final List<String> stops;        // stop names in journey order
  final int        sourceIndex;
  final int        destIndex;
  final CrowdLevel crowdLevel;
  final int        estimatedMinutes;
  final String     busType;        // CNG / Electric
  final bool       isAC;
  final bool       isElectric;
  final bool       isRainbowBRT;
  final String     firstBus;
  final String     lastBus;
  final int        frequencyMinutes;

  BusRoute({
    required this.busNumber,
    required this.stops,
    required this.sourceIndex,
    required this.destIndex,
    required this.crowdLevel,
    required this.estimatedMinutes,
    required this.busType,
    this.isAC          = false,
    this.isElectric    = false,
    this.isRainbowBRT  = false,
    this.firstBus      = '05:30',
    this.lastBus       = '23:30',
    this.frequencyMinutes = 15,
  });

  int get stopsCount => (destIndex - sourceIndex).abs();

  List<String> get journeyStops {
    if (sourceIndex <= destIndex) {
      return stops.sublist(sourceIndex, destIndex + 1);
    } else {
      return stops.sublist(destIndex, sourceIndex + 1).reversed.toList();
    }
  }

  /// Short label for bus type badge
  String get busTypeBadge {
    if (isAC && isElectric) return 'AC EV';
    if (isAC)       return 'AC';
    if (isElectric) return 'Electric';
    if (isRainbowBRT) return 'Rainbow';
    return 'CNG';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  PMPMLData  — SQLite-backed, async
// ─────────────────────────────────────────────────────────────────────────────
class PMPMLData {

  // ── In-memory cache populated on first call ─────────────────────────────
  static List<String>? _stopNamesCache;

  /// All stop names (for autocomplete / voice matching).
  /// Call once at startup and cache the result.
  static Future<List<String>> getAllStopNames() async {
    if (_stopNamesCache != null) return _stopNamesCache!;
    final db   = await DatabaseHelper.database;
    final rows = await db.query('stops', columns: ['name'], orderBy: 'name');
    _stopNamesCache = rows.map((r) => r['name'] as String).toList();
    return _stopNamesCache!;
  }

  /// Synchronous getter — returns cache or empty list if not yet loaded.
  /// Always call [getAllStopNames()] first (e.g. in main.dart initState).
  static List<String> get allStops => _stopNamesCache ?? [];

  /// Pre-load stop names into cache. Call this in main() or HomeScreen.initState().
  static Future<void> preload() async {
    await getAllStopNames();
  }

  // ── Route search ─────────────────────────────────────────────────────────
  /// Find all routes that serve both [source] and [destination].
  /// Returns routes sorted by fewest stops first.
  static Future<List<BusRoute>> findRoutes(
      String source,
      String destination,
      ) async {
    final db  = await DatabaseHelper.database;
    final rng = Random();

    // Find stop IDs
    final srcRow = await db.query('stops',
        where: 'LOWER(name) = LOWER(?)', whereArgs: [source], limit: 1);
    final dstRow = await db.query('stops',
        where: 'LOWER(name) = LOWER(?)', whereArgs: [destination], limit: 1);

    if (srcRow.isEmpty || dstRow.isEmpty) return [];

    final srcId = srcRow.first['id'] as int;
    final dstId = dstRow.first['id'] as int;

    // Find routes that contain BOTH stops
    final sql = '''
      SELECT DISTINCT rs1.route_id,
             rs1.stop_sequence AS src_seq,
             rs2.stop_sequence AS dst_seq
      FROM route_stops rs1
      JOIN route_stops rs2 ON rs1.route_id = rs2.route_id
      WHERE rs1.stop_id = ?
        AND rs2.stop_id = ?
        AND rs1.stop_sequence != rs2.stop_sequence
    ''';
    final candidates = await db.rawQuery(sql, [srcId, dstId]);

    if (candidates.isEmpty) return [];

    final List<BusRoute> results = [];

    for (final row in candidates) {
      final routeId = row['route_id'] as int;
      final srcSeq  = row['src_seq']  as int;
      final dstSeq  = row['dst_seq']  as int;

      // Load route metadata
      final rMeta = await db.query('routes', where: 'id = ?', whereArgs: [routeId], limit: 1);
      if (rMeta.isEmpty) continue;
      final meta = rMeta.first;

      // Load ALL stops for this route in order
      final stopRows = await db.rawQuery('''
        SELECT s.name FROM route_stops rs
        JOIN stops s ON s.id = rs.stop_id
        WHERE rs.route_id = ?
        ORDER BY rs.stop_sequence
      ''', [routeId]);

      final stopNames = stopRows.map((r) => r['name'] as String).toList();

      final stopsCount    = (dstSeq - srcSeq).abs();
      final crowd         = CrowdLevel.values[rng.nextInt(4)];
      final minutes       = (stopsCount * 4) + rng.nextInt(8) + 3;
      final busType       = meta['bus_type']  as String? ?? 'CNG';
      final isAC          = (meta['is_ac']          as int? ?? 0) == 1;
      final isElectric    = (meta['is_electric']    as int? ?? 0) == 1;
      final isRainbow     = (meta['is_rainbow_brt'] as int? ?? 0) == 1;
      final firstBus      = meta['first_bus']  as String? ?? '05:30';
      final lastBus       = meta['last_bus']   as String? ?? '23:30';
      final freq          = meta['frequency_minutes'] as int? ?? 15;

      results.add(BusRoute(
        busNumber:        meta['bus_number'] as String,
        stops:            stopNames,
        sourceIndex:      srcSeq,
        destIndex:        dstSeq,
        crowdLevel:       crowd,
        estimatedMinutes: minutes,
        busType:          busType,
        isAC:             isAC,
        isElectric:       isElectric,
        isRainbowBRT:     isRainbow,
        firstBus:         firstBus,
        lastBus:          lastBus,
        frequencyMinutes: freq,
      ));
    }

    // Sort by fewest stops
    results.sort((a, b) => a.stopsCount.compareTo(b.stopsCount));
    return results;
  }

  // ── Stop search (for voice matching) ────────────────────────────────────
  /// Find best matching stop name for a voice-recognised string.
  static Future<String?> findBestMatch(String query) async {
    final stops = await getAllStopNames();
    final q     = query.toLowerCase().trim();
    if (q.isEmpty) return null;

    // 1. Exact match
    for (final s in stops) {
      if (s.toLowerCase() == q) return s;
    }
    // 2. Stop name contains query
    for (final s in stops) {
      if (s.toLowerCase().contains(q)) return s;
    }
    // 3. Query contains stop name
    for (final s in stops) {
      if (q.contains(s.toLowerCase())) return s;
    }
    return null;
  }

  /// Synchronous best-match (uses cache — call preload() first).
  static String? findBestMatchSync(String query) {
    final stops = allStops;
    final q     = query.toLowerCase().trim();
    if (q.isEmpty || stops.isEmpty) return null;

    for (final s in stops) {
      if (s.toLowerCase() == q) return s;
    }
    for (final s in stops) {
      if (s.toLowerCase().contains(q)) return s;
    }
    for (final s in stops) {
      if (q.contains(s.toLowerCase())) return s;
    }
    return null;
  }

  // ── Fuzzy suggestions for text field autocomplete ────────────────────────
  static List<String> getSuggestions(String query, {int limit = 6}) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase();
    return allStops
        .where((s) => s.toLowerCase().contains(q))
        .take(limit)
        .toList();
  }
}
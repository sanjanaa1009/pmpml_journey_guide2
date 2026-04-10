import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Opens (and on first run, copies from assets) the PMPML SQLite database.
class DatabaseHelper {
  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbDir  = await getDatabasesPath();
    final dbPath = join(dbDir, 'pmpml.db');

    // Copy from assets if not already on disk
    if (!await File(dbPath).exists()) {
      final data = await rootBundle.load('assets/pmpml.db');
      final bytes = data.buffer.asUint8List();
      await File(dbPath).writeAsBytes(bytes, flush: true);
    }

    return openDatabase(dbPath, readOnly: true);
  }
}
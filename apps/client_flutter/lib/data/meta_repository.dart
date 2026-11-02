import 'package:sqlite3/sqlite3.dart';

import 'database.dart';

/// 键值配置（主题、字号、device_id 等），避免引入 shared_preferences。
class MetaRepository {
  MetaRepository(this._db);

  final AppDatabase _db;

  Database get _raw => _db.raw;

  String? get(String key) {
    final rows = _raw.select('SELECT value FROM app_meta WHERE key = ?', <Object?>[key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  void set(String key, String value) {
    _raw.execute(
      'INSERT INTO app_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      <Object?>[key, value],
    );
  }

  int? getInt(String key) => int.tryParse(get(key) ?? '');

  bool getBool(String key, {bool fallback = false}) {
    final value = get(key);
    if (value == null) return fallback;
    return value == '1' || value.toLowerCase() == 'true';
  }
}

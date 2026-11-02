/// 领域模型：与数据库行一一对应的不可变对象。
library;

class Entry {
  const Entry({
    required this.id,
    required this.title,
    required this.bodyMd,
    required this.entryDate,
    required this.createdAt,
    required this.updatedAt,
    required this.rev,
    required this.pinned,
    required this.deviceId,
    this.deletedAt,
  });

  final String id;
  final String title;
  final String bodyMd;

  /// 日记归属日（当天 00:00 本地时间）
  final DateTime entryDate;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 同步预留：每次写入 +1
  final int rev;
  final bool pinned;
  final String deviceId;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  bool get isBlank => title.trim().isEmpty && bodyMd.trim().isEmpty;

  Entry copyWith({
    String? title,
    String? bodyMd,
    DateTime? entryDate,
    DateTime? updatedAt,
    int? rev,
    bool? pinned,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return Entry(
      id: id,
      title: title ?? this.title,
      bodyMd: bodyMd ?? this.bodyMd,
      entryDate: entryDate ?? this.entryDate,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rev: rev ?? this.rev,
      pinned: pinned ?? this.pinned,
      deviceId: deviceId,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }

  factory Entry.fromMap(Map<String, Object?> map) {
    return Entry(
      id: map['id']! as String,
      title: (map['title'] as String?) ?? '',
      bodyMd: (map['body_md'] as String?) ?? '',
      entryDate: DateTime.fromMillisecondsSinceEpoch(map['entry_date']! as int),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
      rev: (map['rev'] as int?) ?? 1,
      pinned: ((map['pinned'] as int?) ?? 0) != 0,
      deviceId: (map['device_id'] as String?) ?? '',
      deletedAt: map['deleted_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['deleted_at']! as int),
    );
  }
}

class Attachment {
  const Attachment({
    required this.id,
    required this.entryId,
    required this.sha256,
    required this.filename,
    required this.mime,
    required this.sizeBytes,
    required this.createdAt,
  });

  final String id;
  final String entryId;
  final String sha256;
  final String filename;
  final String mime;
  final int sizeBytes;
  final DateTime createdAt;

  /// 正文中的相对引用：`assets/<sha256>.<ext>`
  String get relativeRef => 'assets/$sha256${_extOf(filename)}';

  factory Attachment.fromMap(Map<String, Object?> map) {
    return Attachment(
      id: map['id']! as String,
      entryId: map['entry_id']! as String,
      sha256: map['sha256']! as String,
      filename: (map['filename'] as String?) ?? '',
      mime: (map['mime'] as String?) ?? 'application/octet-stream',
      sizeBytes: (map['size_bytes'] as int?) ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
    );
  }

  static String _extOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0 || dot == filename.length - 1) return '';
    final ext = filename.substring(dot + 1).toLowerCase();
    if (ext.length > 8) return '';
    final valid = RegExp(r'^[a-z0-9]+$').hasMatch(ext);
    return valid ? '.$ext' : '';
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/app_logger.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mdiary_log_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('日志写入失败信息与堆栈', () {
    final file = File('${dir.path}/logs/error.log');
    AppLogger(file).log('FlutterError', StateError('boom'), StackTrace.current);

    expect(file.existsSync(), isTrue);
    final content = file.readAsStringSync();
    expect(content, contains('FlutterError'));
    expect(content, contains('boom'));
    expect(content, contains('app_logger_test.dart'));
  });

  test('超过 1MB 轮转为 .old，且新日志继续写', () {
    final file = File('${dir.path}/error.log')
      ..writeAsStringSync('x' * (AppLogger.maxBytes + 16));
    AppLogger(file).log('Uncaught', 'second');

    final backup = File('${file.path}.old');
    expect(backup.existsSync(), isTrue);
    expect(backup.lengthSync(), greaterThan(AppLogger.maxBytes));
    expect(file.readAsStringSync(), contains('second'));
  });

  test('根目录为空时回退到系统临时目录，保证能落盘', () {
    final file = resolveLogFile('');
    expect(file.path, contains('error.log'));
    AppLogger(file).log('Startup', 'no root');
    expect(file.existsSync(), isTrue);
    file.deleteSync();
  });
}

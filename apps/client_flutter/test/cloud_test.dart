@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/secret_store.dart';
import 'package:mdiary/rag/answer.dart';
import 'package:mdiary/rag/cloud_client.dart';
import 'package:mdiary/rag/rag_settings.dart';

/// 2.0.3：云端开关、API Key 加密、云端问答/摘要客户端。
void main() {
  test('API Key 加密：DPAPI 往返，密文不含明文', () {
    const plain = 'sk-test-1234567890';
    final cipher = SecretStore.protect(plain);
    expect(cipher, isNotEmpty);
    expect(cipher.contains(plain), isFalse);
    expect(cipher, startsWith('dpapi:'));
    expect(SecretStore.unprotect(cipher), plain);
    expect(SecretStore.unprotect('dpapi:not-base64'), isNull);
    expect(SecretStore.unprotect(''), isNull);
  });

  test('云端开关与字段：默认关闭，Key 加密存储', () {
    const settings = RagSettings();
    expect(settings.cloudEnabled, isFalse);
    expect(settings.hasCloudKey, isFalse);

    final enabled = settings.copyWith(
      cloudEnabled: true,
      cloudModel: 'gpt-4o-mini',
      cloudBaseUrl: 'https://api.openai.com/v1',
      cloudApiKeyCipher: SecretStore.protect('sk-abc'),
    );
    final json = const JsonEncoder.withIndent('  ').convert(enabled.toJson());
    expect(json.contains('sk-abc'), isFalse, reason: '落盘不能是明文');
    final reloaded = RagSettings.fromJson(
      jsonDecode(json) as Map<String, Object?>,
    );
    expect(reloaded.cloudEnabled, isTrue);
    expect(SecretStore.unprotect(reloaded.cloudApiKeyCipher), 'sk-abc');
  });

  group('云端客户端（本地假服务）', () {
    late HttpServer server;
    late CloudConfig config;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path.endsWith('/models')) {
          request.response.statusCode = 200;
          request.response.write('{"data":[]}');
          await request.response.close();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final payload = jsonDecode(body) as Map<String, dynamic>;
        final response = request.response;
        if (payload['stream'] == true) {
          response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          for (final part in <String>['你', '好', '世界']) {
            response.write(
              'data: ${jsonEncode(<String, Object>{
                    'choices': <Object>[
                      <String, Object>{
                        'delta': <String, String>{'content': part},
                      },
                    ],
                  })}\n\n',
            );
          }
          response.write('data: [DONE]\n\n');
        } else {
          response.headers.contentType = ContentType.json;
          final content = jsonEncode(<String, Object>{
            'summary': '云端摘要',
            'tags': <String>['工作'],
          });
          response.write(
            jsonEncode(<String, Object>{
              'choices': <Object>[
                <String, Object>{
                  'message': <String, String>{'content': content},
                },
              ],
            }),
          );
        }
        await response.close();
      });
      config = CloudConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
        apiKey: 'sk-test',
      );
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('流式问答拼接分片', () async {
      final answerer = CloudAnswerer(config);
      expect(await answerer.isAvailable(), isTrue);
      final chunks = await answerer
          .streamAnswer(
            question: '去年做了什么？',
            sources: <AnswerSource>[
              AnswerSource(
                label: '杭州',
                date: DateTime(2026, 11, 1),
                text: '去了西湖。',
                kind: 'entry',
              ),
            ],
          )
          .toList();
      expect(chunks.join(), '你好世界');
    });

    test('非流式摘要解析 JSON', () async {
      final summarizer = CloudSummarizer(config);
      final result = await summarizer.summarize(
        title: '报销',
        date: DateTime(2026, 11, 3),
        body: '住宿费 380 元。',
        tags: const <String>[],
      );
      expect(result.summary, '云端摘要');
      expect(result.tags, <String>['工作']);
    });
  });
}

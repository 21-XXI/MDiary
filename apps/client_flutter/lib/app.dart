import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'features/home_page.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';

/// 全局 SnackBar 出口：拖拽导入这类没有页面上下文的操作也能给用户反馈。
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class MDiaryApp extends StatelessWidget {
  const MDiaryApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return MaterialApp(
            title: 'MDiary',
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: rootMessengerKey,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: state.themeMode,
            home: const HomePage(),
          );
        },
      ),
    );
  }
}

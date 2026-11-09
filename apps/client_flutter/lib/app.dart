import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'features/home_page.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';

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
          final fontFamily = state.uiFont.isEmpty ? null : state.uiFont;
          return MaterialApp(
            title: 'MDiary',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(fontFamily: fontFamily),
            darkTheme: AppTheme.dark(fontFamily: fontFamily),
            themeMode: state.themeMode,
            home: const HomePage(),
          );
        },
      ),
    );
  }
}

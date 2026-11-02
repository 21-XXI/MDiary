import 'package:flutter/widgets.dart';

import 'app_state.dart';

/// 通过 InheritedNotifier 把 AppState 暴露给整棵树。
///
/// 单独成文件，避免 features -> app.dart -> features 的循环依赖。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载：请在 MDiaryApp 内使用');
    return scope!.notifier!;
  }
}

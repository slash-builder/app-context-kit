import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter/widgets.dart';

/// Makes the [AppContext] reachable from any widget below it: `AppContextScope.of(context)`.
///
/// The context object never changes during a run, so widgets that read it are not rebuilt by the scope (it notifies only
/// if a different context is swapped in, which happens in tests that relaunch).
class AppContextScope extends InheritedWidget {
  const AppContextScope({super.key, required this.ctx, required super.child});

  /// The context this scope makes available to the widgets below it.
  final AppContext ctx;

  /// The nearest context. Throws a [FlutterError] that says how to fix it when there is none.
  static AppContext of(BuildContext context) {
    final ctx = maybeOf(context);
    if (ctx == null) {
      throw FlutterError.fromParts([
        ErrorSummary('AppContextScope.of() called with a context that has no AppContextScope above it.'),
        ErrorHint('Start the app with AppContextKit.run(...), which mounts the scope, or wrap the widget in AppContextScope(ctx: ..., child: ...).'),
        context.describeElement('The context used was'),
      ]);
    }
    return ctx;
  }

  /// The nearest context, or null when there is no scope.
  static AppContext? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppContextScope>()?.ctx;

  @override
  bool updateShouldNotify(AppContextScope oldWidget) => !identical(ctx, oldWidget.ctx);
}

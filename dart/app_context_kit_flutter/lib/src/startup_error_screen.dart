import 'package:flutter/material.dart';

import 'startup_error.dart';

/// What [AppContextKit.run] shows instead of the app when it cannot start: the error code, what happened and what to do.
/// It is a complete (plain Material) app, because there is no app above it.
class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({super.key, required this.error, this.title = 'This app could not start'});

  /// What went wrong, with its code and what to do about it.
  final AppContextKitStartupError error;
  /// The heading shown above the message.
  final String title;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: title,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey), useMaterial3: true),
      home: StartupErrorBody(error: error, title: title),
    );
  }
}

/// The content of [StartupErrorScreen], for embedding in an app that has its own `MaterialApp`.
class StartupErrorBody extends StatelessWidget {
  const StartupErrorBody({super.key, required this.error, this.title = 'This app could not start'});

  /// What went wrong, with its code and what to do about it.
  final AppContextKitStartupError error;
  /// The heading shown above the message.
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.error_outline, color: theme.colorScheme.error, size: 32, semanticLabel: 'Error'),
                    const SizedBox(width: 12),
                    Expanded(child: Semantics(header: true, child: Text(title, style: theme.textTheme.headlineSmall))),
                  ]),
                  const SizedBox(height: 16),
                  SelectableText(error.message, key: const ValueKey('startup-error-message')),
                  const SizedBox(height: 16),
                  Text('What to do', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  SelectableText(error.hint, key: const ValueKey('startup-error-hint')),
                  const SizedBox(height: 16),
                  Semantics(
                    label: 'Error code ${error.code}',
                    child: ExcludeSemantics(
                      child: SelectableText('Error code: ${error.code}',
                          key: const ValueKey('startup-error-code'), style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

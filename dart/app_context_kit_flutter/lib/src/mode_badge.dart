import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter/material.dart';

/// A small chip that says the app is not running for real: "mock", "scratch" or "mock + scratch". Shows nothing at all in
/// real, unscratched mode, so it can sit in every app's chrome permanently.
class ModeBadge extends StatelessWidget {
  const ModeBadge({super.key, required this.isMock, required this.scratch});

  /// Reads `ctx.isMock` and `ctx.scratch`.
  ModeBadge.forContext(AppContext ctx, {Key? key}) : this(key: key, isMock: ctx.isMock, scratch: ctx.scratch);

  /// True in mock mode.
  final bool isMock;
  /// True when the app runs in a scratch directory.
  final bool scratch;

  /// The chip's text, or null when there is nothing to show.
  static String? labelFor({required bool isMock, required bool scratch}) {
    if (!isMock && !scratch) return null;
    return [if (isMock) 'mock', if (scratch) 'scratch'].join(' + ');
  }

  @override
  Widget build(BuildContext context) {
    final label = labelFor(isMock: isMock, scratch: scratch);
    if (label == null) return const SizedBox.shrink();
    final explanation = [
      if (isMock) 'Mock mode: Venue is an in-memory fake.',
      if (scratch) 'Scratch: files live in a throwaway folder, not your real data.',
    ].join(' ');
    return Tooltip(
      message: explanation,
      child: Semantics(
        label: 'Running in $label mode',
        excludeSemantics: true,
        child: Chip(
          label: Text(label),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

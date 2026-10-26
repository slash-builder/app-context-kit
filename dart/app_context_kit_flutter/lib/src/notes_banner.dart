import 'package:app_context_kit/app_context_kit.dart';
import 'package:flutter/material.dart';

/// Shows the context's notes that the person should see: warnings and errors, each with its own icon, a visible word
/// ("Warning", "Error") and its own colours, so no meaning rests on colour alone. Info notes (for example "Venue is off for
/// this app", which `open` records on every start) are hidden unless [showInfo] is true. With nothing to show it takes no space.
///
/// `AppContext.notes` is a plain list and does not notify; the banner reads it whenever it is built, so rebuild it (for
/// example from `setState`) after adding a note.
class NotesBanner extends StatefulWidget {
  const NotesBanner({super.key, required this.notes, this.showInfo = false, this.dismissible = false, this.onDismissed});

  /// Reads `ctx.notes`.
  NotesBanner.forContext(AppContext ctx, {Key? key, bool showInfo = false, bool dismissible = false, ValueChanged<AppNote>? onDismissed})
      : this(key: key, notes: ctx.notes, showInfo: showInfo, dismissible: dismissible, onDismissed: onDismissed);

  /// The notes to choose from. Only those [visibleOf] allows are shown.
  final List<AppNote> notes;

  /// Show [NoteSeverity.info] notes too. Default false.
  final bool showInfo;

  /// Give each note a dismiss button. A dismissed note stays hidden for the life of this widget's state.
  final bool dismissible;

  /// Called when a note is dismissed (the list is not edited).
  final ValueChanged<AppNote>? onDismissed;

  /// The notes this banner would show, in order.
  static List<AppNote> visibleOf(List<AppNote> notes, {bool showInfo = false}) =>
      [for (final n in notes) if (showInfo || n.severity != NoteSeverity.info) n];

  @override
  State<NotesBanner> createState() => _NotesBannerState();
}

class _NotesBannerState extends State<NotesBanner> {
  final _dismissed = Set<AppNote>.identity();

  @override
  Widget build(BuildContext context) {
    final shown = [for (final n in NotesBanner.visibleOf(widget.notes, showInfo: widget.showInfo)) if (!_dismissed.contains(n)) n];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final note in shown)
          _NoteTile(
            note: note,
            onDismiss: widget.dismissible
                ? () {
                    setState(() => _dismissed.add(note));
                    widget.onDismissed?.call(note);
                  }
                : null,
          ),
      ],
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note, this.onDismiss});

  final AppNote note;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (word, icon, background, foreground) = switch (note.severity) {
      NoteSeverity.error => ('Error', Icons.error, scheme.errorContainer, scheme.onErrorContainer),
      NoteSeverity.warning => ('Warning', Icons.warning_amber_rounded, scheme.tertiaryContainer, scheme.onTertiaryContainer),
      NoteSeverity.info => ('Note', Icons.info_outline, scheme.surfaceContainerHighest, scheme.onSurface),
    };
    return Semantics(
      container: true,
      liveRegion: note.severity != NoteSeverity.info,
      label: '$word: ${note.text}',
      child: Container(
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 20, color: foreground)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ExcludeSemantics(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '$word: ', style: const TextStyle(fontWeight: FontWeight.bold)),
                    TextSpan(text: note.text),
                  ]),
                  style: TextStyle(color: foreground),
                ),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                icon: Icon(Icons.close, color: foreground),
                tooltip: 'Dismiss $word',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lightweight rich text:
///   **bold**       → bold
///   *italic*       → italic
///   newlines kept verbatim
///
/// Deliberately not a full markdown parser. Phase 1 needs structure that
/// survives copy/paste and is renderable as `TextSpan`s without a dep.
class RichTextView extends StatelessWidget {
  const RichTextView(this.source, {super.key, this.style});

  final String source;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? Theme.of(context).textTheme.bodyMedium!;
    return RichText(
      text: TextSpan(style: base, children: _parse(source, base)),
    );
  }

  static List<TextSpan> _parse(String src, TextStyle base) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'(\*\*[^*]+\*\*|\*[^*]+\*)');
    int last = 0;
    for (final m in pattern.allMatches(src)) {
      if (m.start > last) {
        spans.add(TextSpan(text: src.substring(last, m.start)));
      }
      final raw = m.group(0)!;
      if (raw.startsWith('**')) {
        spans.add(TextSpan(
          text: raw.substring(2, raw.length - 2),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else {
        spans.add(TextSpan(
          text: raw.substring(1, raw.length - 1),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      }
      last = m.end;
    }
    if (last < src.length) {
      spans.add(TextSpan(text: src.substring(last)));
    }
    return spans;
  }
}

class RichTextEditor extends StatefulWidget {
  const RichTextEditor({
    super.key,
    required this.controller,
    this.minLines = 4,
    this.hint = 'Description…',
  });

  final TextEditingController controller;
  final int minLines;
  final String hint;

  @override
  State<RichTextEditor> createState() => _RichTextEditorState();
}

class _RichTextEditorState extends State<RichTextEditor> {
  void _wrap(String marker) {
    final c = widget.controller;
    final sel = c.selection;
    if (!sel.isValid) return;
    final text = c.text;
    if (sel.isCollapsed) {
      final insertion = '$marker$marker';
      final newText = text.replaceRange(sel.start, sel.end, insertion);
      c.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + marker.length),
      );
    } else {
      final picked = text.substring(sel.start, sel.end);
      final wrapped = '$marker$picked$marker';
      final newText = text.replaceRange(sel.start, sel.end, wrapped);
      c.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: sel.start + marker.length,
          extentOffset: sel.end + marker.length,
        ),
      );
    }
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _ToolbarButton(
              tooltip: 'Bold (wrap with **)',
              icon: Icons.format_bold,
              onTap: () => _wrap('**'),
            ),
            const SizedBox(width: 4),
            _ToolbarButton(
              tooltip: 'Italic (wrap with *)',
              icon: Icons.format_italic,
              onTap: () => _wrap('*'),
            ),
            const Spacer(),
            Text(
              'Markdown: **bold**, *italic*',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: widget.controller,
          minLines: widget.minLines,
          maxLines: 8,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(hintText: widget.hint),
        ),
      ],
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18),
        ),
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';

class MarkdownPreview extends StatelessWidget {
  const MarkdownPreview({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks) ...[
          _MarkdownBlockView(block: block),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _MarkdownBlockView extends StatelessWidget {
  const _MarkdownBlockView({required this.block});

  final _MarkdownBlock block;

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      _MarkdownHeading(:final level, :final text) => Text(
        text,
        style: switch (level) {
          1 => Theme.of(context).textTheme.headlineSmall,
          2 => Theme.of(context).textTheme.titleLarge,
          _ => Theme.of(context).textTheme.titleMedium,
        },
      ),
      _MarkdownParagraph(:final text) => SelectableText(text),
      _MarkdownList(:final items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('- '),
                  Expanded(child: SelectableText(item)),
                ],
              ),
            ),
        ],
      ),
      _MarkdownCode(:final code) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF09111F),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            code,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ),
    };
  }
}

sealed class _MarkdownBlock {
  const _MarkdownBlock();
}

class _MarkdownHeading extends _MarkdownBlock {
  const _MarkdownHeading({required this.level, required this.text});

  final int level;
  final String text;
}

class _MarkdownParagraph extends _MarkdownBlock {
  const _MarkdownParagraph({required this.text});

  final String text;
}

class _MarkdownList extends _MarkdownBlock {
  const _MarkdownList({required this.items});

  final List<String> items;
}

class _MarkdownCode extends _MarkdownBlock {
  const _MarkdownCode({required this.code});

  final String code;
}

List<_MarkdownBlock> _parseBlocks(String markdown) {
  final blocks = <_MarkdownBlock>[];
  final paragraph = <String>[];
  final listItems = <String>[];
  List<String>? codeLines;

  void flushParagraph() {
    if (paragraph.isEmpty) {
      return;
    }
    blocks.add(_MarkdownParagraph(text: paragraph.join(' ')));
    paragraph.clear();
  }

  void flushList() {
    if (listItems.isEmpty) {
      return;
    }
    blocks.add(_MarkdownList(items: List<String>.from(listItems)));
    listItems.clear();
  }

  for (final line in const LineSplitter().convert(markdown)) {
    if (line.trimLeft().startsWith('```')) {
      if (codeLines == null) {
        flushParagraph();
        flushList();
        codeLines = <String>[];
      } else {
        blocks.add(_MarkdownCode(code: codeLines.join('\n')));
        codeLines = null;
      }
      continue;
    }
    if (codeLines != null) {
      codeLines.add(line);
      continue;
    }
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      flushParagraph();
      flushList();
      continue;
    }
    if (trimmed.startsWith('# ')) {
      flushParagraph();
      flushList();
      blocks.add(_MarkdownHeading(level: 1, text: trimmed.substring(2)));
      continue;
    }
    if (trimmed.startsWith('## ')) {
      flushParagraph();
      flushList();
      blocks.add(_MarkdownHeading(level: 2, text: trimmed.substring(3)));
      continue;
    }
    if (trimmed.startsWith('### ')) {
      flushParagraph();
      flushList();
      blocks.add(_MarkdownHeading(level: 3, text: trimmed.substring(4)));
      continue;
    }
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      flushParagraph();
      listItems.add(trimmed.substring(2));
      continue;
    }
    flushList();
    paragraph.add(trimmed);
  }

  if (codeLines != null) {
    blocks.add(_MarkdownCode(code: codeLines.join('\n')));
  }
  flushParagraph();
  flushList();
  return blocks;
}

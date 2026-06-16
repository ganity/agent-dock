import 'dart:async';

typedef ShareAttachments = Future<void> Function(
  List<String> paths,
  String? text,
);

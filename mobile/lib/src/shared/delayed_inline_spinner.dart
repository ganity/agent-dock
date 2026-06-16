import 'dart:async';

import 'package:flutter/material.dart';

class DelayedInlineSpinner extends StatefulWidget {
  const DelayedInlineSpinner({
    super.key,
    required this.active,
    required this.spinnerKey,
    this.delay = const Duration(milliseconds: 300),
    this.dimension = 16,
    this.strokeWidth = 2,
    this.gap = 10,
  });

  final bool active;
  final Key spinnerKey;
  final Duration delay;
  final double dimension;
  final double strokeWidth;
  final double gap;

  @override
  State<DelayedInlineSpinner> createState() => _DelayedInlineSpinnerState();
}

class _DelayedInlineSpinnerState extends State<DelayedInlineSpinner> {
  Timer? _timer;
  bool _showSpinner = false;

  @override
  void initState() {
    super.initState();
    _syncSpinnerVisibility();
  }

  @override
  void didUpdateWidget(covariant DelayedInlineSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.delay != widget.delay) {
      _syncSpinnerVisibility();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncSpinnerVisibility() {
    _timer?.cancel();
    if (!widget.active) {
      if (_showSpinner) {
        setState(() {
          _showSpinner = false;
        });
      }
      return;
    }
    if (_showSpinner) {
      return;
    }
    _timer = Timer(widget.delay, () {
      if (!mounted || !widget.active) {
        return;
      }
      setState(() {
        _showSpinner = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSpinner) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          key: widget.spinnerKey,
          dimension: widget.dimension,
          child: CircularProgressIndicator(strokeWidth: widget.strokeWidth),
        ),
        SizedBox(width: widget.gap),
      ],
    );
  }
}

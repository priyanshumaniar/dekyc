import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Non-web fallback: there is no browser PDF viewer off the web, so we show a
/// simple placeholder. (The app's primary target is web, where the real
/// inline viewer in `doc_view_web.dart` is used.)
Widget buildPdfPreview(Uint8List bytes, String id, {double height = 480}) {
  return Builder(
    builder: (context) {
      final p = context.pal;
      return Container(
        height: 140,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: p.surface,
          border: Border.all(color: p.hairline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.picture_as_pdf_outlined, size: 40, color: p.muted),
            const SizedBox(height: 8),
            Text('PDF document — open in a web browser to view',
                style: TextStyle(color: p.muted)),
          ],
        ),
      );
    },
  );
}

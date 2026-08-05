import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../theme/app_theme.dart';
import '../external_link.dart';

/// Non-web PDF preview.
///
/// There is no embeddable browser PDF viewer off the web, so instead of a dead
/// grey box we write the already-decrypted bytes to the app's temporary
/// directory and hand them to the OS viewer. The bytes are in memory either
/// way — refusing to open them just meant a verifier on Windows/macOS/Android
/// could decrypt a bundle and then not read it.
///
/// The file lands in the app's own temp dir (not a shared location) and is
/// named per-document so repeat opens overwrite rather than accumulate.
Widget buildPdfPreview(Uint8List bytes, String id, {double height = 480}) =>
    _PdfFallback(bytes: bytes, id: id, height: height);

class _PdfFallback extends StatefulWidget {
  const _PdfFallback({
    required this.bytes,
    required this.id,
    required this.height,
  });

  final Uint8List bytes;
  final String id;
  final double height;

  @override
  State<_PdfFallback> createState() => _PdfFallbackState();
}

class _PdfFallbackState extends State<_PdfFallback> {
  bool _opening = false;

  Future<void> _open() async {
    setState(() => _opening = true);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/dekyc_${widget.id}.pdf');
      await file.writeAsBytes(widget.bytes, flush: true);
      if (!mounted) return;
      await ExternalLink.open(context, file.uri.toString());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open the PDF: $e')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final kb = (widget.bytes.length / 1024).toStringAsFixed(0);
    return Container(
      // Honour the caller's height instead of hardcoding one, so this sits in
      // the same slot as the web viewer it substitutes for.
      height: widget.height.clamp(160.0, 240.0),
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
          Text('PDF · $kb KB · decrypted',
              style: TextStyle(color: p.muted, fontSize: 13)),
          const SizedBox(height: 4),
          Text('Inline preview is web-only on this platform.',
              style: TextStyle(color: p.muted, fontSize: 11.5)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _opening ? null : _open,
            icon: _opening
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.open_in_new, size: 18),
            label: Text(_opening ? 'Opening…' : 'Open in system viewer'),
          ),
        ],
      ),
    );
  }
}

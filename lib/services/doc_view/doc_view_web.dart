import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// View types already registered this session, so a rebuild doesn't try to
/// register the same factory twice (which throws).
final Set<String> _registered = <String>{};

/// Inline PDF preview on the web: wrap the decrypted bytes in a Blob, mint an
/// object URL, and render the browser's native PDF viewer inside an `<iframe>`
/// via a Flutter platform view. No third-party PDF engine needed.
///
/// [id] should be stable for a given document so the view factory is registered
/// once; we fold in the byte length so different content gets a fresh viewer.
Widget buildPdfPreview(Uint8List bytes, String id, {double height = 480}) {
  final viewType = 'dekyc-pdf-$id-${bytes.length}';

  if (!_registered.contains(viewType)) {
    final blob = web.Blob(
      <web.BlobPart>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'application/pdf'),
    );
    final url = web.URL.createObjectURL(blob);

    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final iframe =
          web.document.createElement('iframe') as web.HTMLIFrameElement
            ..src = url
            ..width = '100%'
            ..height = '100%'
            // Don't leak the dApp URL (which can carry wallet/route state) to
            // the framed document context.
            ..referrerPolicy = 'no-referrer';
      iframe.style.setProperty('border', 'none');
      return iframe;
    });
    _registered.add(viewType);
  }

  return SizedBox(
    height: height,
    child: HtmlElementView(viewType: viewType),
  );
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens external URLs (Etherscan, wallet deep links) with visible failure.
///
/// The pattern this replaces was `if (await canLaunchUrl(uri)) launchUrl(uri);`
/// with no `else` — so on any platform without a handler (a desktop browser
/// with no `metamask://` registration, a locked-down webview) the button was a
/// complete no-op: no navigation, no error, no state change. The user taps
/// "View on Etherscan", nothing happens, and there is nothing to report.
class ExternalLink {
  ExternalLink._();

  /// Launch [url], reporting failure to the user via a SnackBar.
  ///
  /// Returns true when the URL was handed to the platform. [context] must be
  /// mounted; callers awaiting this should re-check `mounted` afterwards.
  static Future<bool> open(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    if (uri == null) {
      messenger.showSnackBar(SnackBar(content: Text('Malformed link: $url')));
      return false;
    }

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(
          SnackBar(content: Text('Nothing on this device can open $url')),
        );
      }
      return ok;
    } catch (e) {
      // canLaunchUrl is deliberately not used as a gate: on several platforms
      // it returns false for perfectly launchable https URLs unless the scheme
      // is pre-declared, which is what made these buttons dead. Try to launch,
      // and surface whatever actually goes wrong.
      messenger.showSnackBar(SnackBar(content: Text('Could not open link: $e')));
      return false;
    }
  }
}

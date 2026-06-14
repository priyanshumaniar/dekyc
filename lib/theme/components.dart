import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// Reusable wallet-style UI pieces (MetaMask-inspired). All theme-aware via
/// `context.pal`.
class DeUI {
  DeUI._();

  static String shortAddress(String address) => address.length > 12
      ? '${address.substring(0, 7)}…${address.substring(address.length - 5)}'
      : address;

  /// Muted uppercase section label.
  static Widget sectionHeader(BuildContext context, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: context.pal.muted,
          letterSpacing: 1.1,
        ),
      );

  /// Soft dark card (the basic container of the design).
  static Widget card(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    VoidCallback? onTap,
    Color? color,
  }) {
    final p = context.pal;
    final body = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Theme.of(context).brightness == Brightness.light
            ? Border.all(color: p.hairline)
            : null,
      ),
      child: child,
    );
    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: body,
    );
  }

  /// Circular icon chip — the leading element of wallet-style list rows.
  static Widget iconChip(
    BuildContext context,
    IconData icon, {
    Color? color,
    double size = 40,
  }) {
    final p = context.pal;
    final c = color ?? p.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: size * 0.5, color: c),
    );
  }

  /// Wallet-style list row: circular icon, title, subtitle, trailing.
  static Widget row(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    Color? iconColor,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final p = context.pal;
    return card(
      context,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          iconChip(context, icon, color: iconColor),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14.5)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: p.muted, fontSize: 12.5, height: 1.35)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing,
          ] else if (onTap != null)
            Icon(Icons.chevron_right, color: p.muted, size: 20),
        ],
      ),
    );
  }

  /// Vertical action tile — the Buy/Swap/Send/Receive-style button.
  static Widget actionTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final p = context.pal;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Theme.of(context).brightness == Brightness.light
              ? Border.all(color: p.hairline)
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: p.accent),
            const SizedBox(height: 8),
            Text(label,
                style:
                    const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// Compact address pill with a copy affordance (the account chip).
  static Widget addressPill(
    BuildContext context,
    String address, {
    VoidCallback? onTap,
    bool copyable = true,
  }) {
    final p = context.pal;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: p.surfaceAlt,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: p.success, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(shortAddress(address),
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
            if (copyable) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: address));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Address copied')),
                  );
                },
                child: Icon(Icons.copy_rounded, size: 13, color: p.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Small colored status chip ("Confirmed", "Pending"...).
  static Widget statusChip(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }

  /// The DeKYC logo mark — rounded gradient square with a glyph.
  static Widget logoMark(BuildContext context, {double size = 64}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8B7CFF), Color(0xFF5B8CFF)],
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(Icons.fingerprint, color: Colors.white, size: size * 0.58),
    );
  }
}

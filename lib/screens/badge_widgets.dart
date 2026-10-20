import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/badge.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';

/// Whose point of view a badge row is drawn from.
enum BadgeSide {
  /// A list of badges someone HOLDS: each row names the issuer.
  held,

  /// A verifier's own registry: each row names the user it was issued to.
  issued,
}

/// Colour for a status chip.
Color badgeStatusColor(BuildContext context, BadgeStatus s) {
  final p = context.pal;
  return switch (s) {
    BadgeStatus.valid => p.success,
    BadgeStatus.expiringSoon => p.warning,
    BadgeStatus.expired => p.muted,
    BadgeStatus.revoked => p.danger,
  };
}

/// "Issued 6 Aug 2026 · Valid until 6 Aug 2027", worded for the status.
String badgeDatesLine(KycBadge b, {DateTime? now}) {
  final issued = 'Issued ${formatBadgeDate(b.issuedAt)}';
  return switch (b.statusAt(now ?? DateTime.now())) {
    BadgeStatus.revoked => '$issued · Revoked by the issuer',
    BadgeStatus.expired => '$issued · Expired ${formatBadgeDate(b.expiresAt)}',
    _ => '$issued · Valid until ${formatBadgeDate(b.expiresAt)}',
  };
}

/// One badge as a wallet-style row. Tapping copies the full address shown, so
/// a relying party can look the issuer up instead of trusting a short form.
class BadgeTile extends StatelessWidget {
  const BadgeTile({
    super.key,
    required this.badge,
    required this.side,
    this.me,
    this.trailingAction,
  });

  final KycBadge badge;
  final BadgeSide side;

  /// The connected wallet, so its own rows read "you".
  final String? me;

  /// Optional button under the row (e.g. Revoke).
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    final status = badge.status;
    final color = badgeStatusColor(context, status);
    final other = side == BadgeSide.held
        ? badge.issuer.hexEip55
        : badge.subject.hexEip55;
    final isMe =
        me != null && other.toLowerCase() == me!.trim().toLowerCase();
    final who = isMe ? 'you' : DeUI.shortAddress(other);
    final title =
        side == BadgeSide.held ? 'Issued by $who' : 'Issued to $who';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DeUI.row(
          context,
          icon: status == BadgeStatus.revoked
              ? Icons.block
              : Icons.verified_outlined,
          iconColor: color,
          title: title,
          subtitle: '${badgeDatesLine(badge)}\nBadge #${badge.tokenId}',
          trailing: DeUI.statusChip(context, badgeStatusLabel(status), color),
          onTap: () {
            Clipboard.setData(ClipboardData(text: other));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Copied $other')),
            );
          },
        ),
        if (trailingAction != null)
          Align(alignment: Alignment.centerRight, child: trailingAction),
      ],
    );
  }
}

/// A titled list of badges with an empty state and the trust caveat.
class BadgeListSection extends StatelessWidget {
  const BadgeListSection({
    super.key,
    required this.title,
    required this.badges,
    required this.side,
    required this.emptyText,
    this.me,
    this.actionFor,
  });

  final String title;
  final List<KycBadge> badges;
  final BadgeSide side;
  final String emptyText;
  final String? me;

  /// Optional per-row action (e.g. a Revoke button on a valid badge).
  final Widget? Function(KycBadge)? actionFor;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final counting = badges.where((b) => b.counts).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DeUI.sectionHeader(
          context,
          badges.isEmpty
              ? title
              : '$title  ($counting valid of ${badges.length})',
        ),
        const SizedBox(height: 8),
        if (badges.isEmpty)
          Text(emptyText, style: TextStyle(color: p.muted, fontSize: 13))
        else
          for (final b in badges) ...[
            BadgeTile(
              badge: b,
              side: side,
              me: me,
              trailingAction: actionFor?.call(b),
            ),
            const SizedBox(height: 8),
          ],
        if (side == BadgeSide.held && badges.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Anyone can issue a badge, so a badge is only as trustworthy as '
              'the organisation that issued it. Tap a row to copy the issuer '
              'address and check who it belongs to.',
              style: TextStyle(color: p.muted, fontSize: 12, height: 1.35),
            ),
          ),
      ],
    );
  }
}

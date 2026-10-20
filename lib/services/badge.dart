import 'package:web3dart/web3dart.dart' show EthereumAddress;

/// How a badge reads to a person today.
enum BadgeStatus { valid, expiringSoon, expired, revoked }

/// One soulbound "Verified" badge, as returned by the contract's
/// `badgeFor`, `badgesOf` and `badgesIssuedBy`.
///
/// Pure Dart (no Flutter, no RPC), so the decoding and the status rules are
/// unit-testable on their own.
class KycBadge {
  const KycBadge({
    required this.tokenId,
    required this.issuer,
    required this.subject,
    required this.issuedAt,
    required this.expiresAt,
    required this.revoked,
    required this.validOnChain,
  });

  final int tokenId;
  final EthereumAddress issuer;
  final EthereumAddress subject;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final bool revoked;

  /// The contract's own verdict at the block the row was read: unrevoked AND
  /// unexpired. This is what `validBadgeCount` counts.
  final bool validOnChain;

  /// A badge is "expiring soon" inside this window.
  static const Duration soonWindow = Duration(days: 30);

  /// Decodes one `BadgeView` tuple. web3dart hands a struct back as a
  /// `List<dynamic>` in field order:
  /// `(tokenId, issuer, subject, issuedAt, expiresAt, revoked, valid)`.
  ///
  /// Returns null for the all-zero row the contract uses for "no badge".
  static KycBadge? fromRow(List<dynamic> fields) {
    final tokenId = (fields[0] as BigInt).toInt();
    if (tokenId == 0) return null;
    return KycBadge(
      tokenId: tokenId,
      issuer: fields[1] as EthereumAddress,
      subject: fields[2] as EthereumAddress,
      issuedAt: _fromSeconds(fields[3] as BigInt),
      expiresAt: _fromSeconds(fields[4] as BigInt),
      revoked: fields[5] as bool,
      validOnChain: fields[6] as bool,
    );
  }

  /// Decodes a `BadgeView[]` result, dropping any all-zero rows.
  static List<KycBadge> fromRows(List<dynamic> rows) => [
        for (final row in rows)
          if (fromRow(row as List<dynamic>) case final KycBadge b) b,
      ];

  static DateTime _fromSeconds(BigInt s) =>
      DateTime.fromMillisecondsSinceEpoch(s.toInt() * 1000);

  /// Status for display. Revoked wins; then expiry by the local clock or the
  /// chain's verdict; then the "expiring soon" window.
  BadgeStatus statusAt(DateTime now) {
    if (revoked) return BadgeStatus.revoked;
    if (!validOnChain || !expiresAt.isAfter(now)) return BadgeStatus.expired;
    if (expiresAt.difference(now) <= soonWindow) {
      return BadgeStatus.expiringSoon;
    }
    return BadgeStatus.valid;
  }

  BadgeStatus get status => statusAt(DateTime.now());

  /// Whether this badge counts today (valid or expiring soon).
  bool get counts =>
      status == BadgeStatus.valid || status == BadgeStatus.expiringSoon;

  bool issuedBy(String address) =>
      issuer.hexEip55.toLowerCase() == address.trim().toLowerCase();
}

/// Newest first by issue date, so the latest verification is on top.
List<KycBadge> sortNewestFirst(List<KycBadge> rows) =>
    [...rows]..sort((a, b) => b.issuedAt.compareTo(a.issuedAt));

/// Short label for a status chip.
String badgeStatusLabel(BadgeStatus s) => switch (s) {
      BadgeStatus.valid => 'Valid',
      BadgeStatus.expiringSoon => 'Expiring soon',
      BadgeStatus.expired => 'Expired',
      BadgeStatus.revoked => 'Revoked',
    };

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "6 Aug 2027", in local time.
String formatBadgeDate(DateTime d) {
  final l = d.toLocal();
  return '${l.day} ${_months[l.month - 1]} ${l.year}';
}

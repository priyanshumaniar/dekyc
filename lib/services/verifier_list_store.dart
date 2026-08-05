import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Remembers which verifier addresses a user has added to their guest list.
///
/// ## Why this has to exist
///
/// `KYCRegistry` has no "list my verifiers" call — a Solidity mapping cannot be
/// enumerated — so the set of addresses a user has granted is not readable from
/// contract state. The obvious alternative, replaying `AccessGranted` logs, is
/// not available either: Alchemy's free tier caps `eth_getLogs` at a 10-block
/// range, which cannot reach a grant made more than ~2 minutes ago.
///
/// So the list of ADDRESSES is remembered here, on the device. The chain
/// remains the source of truth for STATUS — every row still reads
/// `accessExpiry` / `grantVersion` — this only remembers *who to ask about*.
/// Without it, navigating away from Manage Access silently dropped the list
/// while the grants themselves stayed live on-chain, which looked exactly like
/// access spontaneously disappearing.
///
/// Scoped per owner address, so switching accounts shows the right list.
class VerifierListStore {
  VerifierListStore._({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static final VerifierListStore instance = VerifierListStore._();

  @visibleForTesting
  factory VerifierListStore.forTesting(FlutterSecureStorage storage) =>
      VerifierListStore._(storage: storage);

  final FlutterSecureStorage _storage;

  /// Addresses are not secrets, but secure storage is already a dependency and
  /// behaves consistently across web/desktop/mobile.
  static String _keyFor(String owner) =>
      'dekyc.verifiers.v1.${owner.toLowerCase()}';

  /// The remembered verifier addresses for [owner], oldest first.
  Future<List<String>> load(String owner) async {
    try {
      final raw = await _storage.read(key: _keyFor(owner));
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<String>().toList();
    } catch (_) {
      // Storage unavailable — degrade to an empty list rather than blocking the
      // screen. The user can re-add addresses; nothing on-chain is affected.
      return [];
    }
  }

  Future<void> save(String owner, List<String> verifiers) async {
    try {
      await _storage.write(
        key: _keyFor(owner),
        value: jsonEncode(verifiers),
      );
    } catch (_) {/* best effort — the list is a convenience, not state of record */}
  }

  /// Add [verifier] to [owner]'s list if absent. Returns the updated list.
  Future<List<String>> add(String owner, String verifier) async {
    final list = await load(owner);
    final exists = list.any(
      (v) => v.toLowerCase() == verifier.toLowerCase(),
    );
    if (!exists) {
      list.add(verifier);
      await save(owner, list);
    }
    return list;
  }

  /// Remove [verifier] from [owner]'s list. Returns the updated list.
  ///
  /// This only forgets the address locally — it does NOT revoke anything.
  /// Callers must revoke on-chain separately.
  Future<List<String>> remove(String owner, String verifier) async {
    final list = await load(owner);
    list.removeWhere((v) => v.toLowerCase() == verifier.toLowerCase());
    await save(owner, list);
    return list;
  }
}

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web3dart/crypto.dart';

import '../config/chain_config.dart';
import 'wallet_service.dart';

/// The two actors of DeKYC. The role chosen at sign-in shapes the UI (what
/// the dashboard offers) and is embedded in the signed login message, so a
/// session proves BOTH wallet control and the declared role.
enum UserRole { individual, verifier }

extension UserRoleLabel on UserRole {
  String get label => this == UserRole.individual ? 'Individual' : 'Verifier';
}

/// An authenticated DeKYC session: a wallet address that proved key control
/// by signing a one-time challenge, bound to a role and an expiry.
class AuthSession {
  AuthSession({
    required this.address,
    required this.role,
    required this.nonce,
    required this.issuedAt,
    required this.expiresAt,
    required this.signature,
  });

  final String address;
  final UserRole role;
  final String nonce;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String signature;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
        'address': address,
        'role': role.name,
        'nonce': nonce,
        'issuedAt': issuedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'signature': signature,
      };

  static AuthSession fromJson(Map<String, dynamic> json) => AuthSession(
        address: json['address'] as String,
        role: UserRole.values.byName(json['role'] as String),
        nonce: json['nonce'] as String,
        issuedAt: DateTime.parse(json['issuedAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        signature: json['signature'] as String,
      );
}

/// Wallet-native authentication (Sign-In-with-Ethereum style).
///
/// Why this exists: merely *listing* an account via `eth_accounts` proves
/// nothing — any dapp UI can display an address. Signing a fresh nonce proves
/// the user actually controls the private key NOW. The signature is verified
/// client-side by ECDSA public-key recovery and must match the connected
/// address, then stored (secure storage) as the session credential.
///
/// Session security properties:
///  * expires after [sessionLifetime] (forces a periodic re-sign);
///  * bound to the wallet account — switching accounts in MetaMask instantly
///    invalidates it (listener below);
///  * tamper-evident at rest — on restore the stored signature is re-verified
///    against the reconstructed message; any edit to address/role/expiry in
///    storage breaks the signature and the session is discarded.
class AuthService extends ChangeNotifier {
  AuthService._() {
    // A session only proves control of the account that signed it. If the
    // wallet switches accounts (or disconnects), drop the session.
    WalletService.instance.addListener(_onWalletChanged);
  }
  static final AuthService instance = AuthService._();

  static const Duration sessionLifetime = Duration(hours: 24);
  static const String _storageKey = 'dekyc.session.v1';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  AuthSession? _session;
  AuthSession? get session => _session;
  UserRole? get role => _session?.role;
  bool get isAuthenticated => _session != null && !_session!.isExpired;

  void _onWalletChanged() {
    final s = _session;
    if (s == null) return;
    final current = WalletService.instance.address;
    if (current == null || current.toLowerCase() != s.address.toLowerCase()) {
      signOut(disconnectWallet: false);
    }
  }

  /// The exact text the wallet signs. Human-readable on purpose: the user can
  /// read in MetaMask what they are approving, including role and expiry.
  static String buildSignInMessage({
    required String address,
    required UserRole role,
    required String nonce,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) {
    return 'DeKYC wants you to sign in with your Ethereum account:\n'
        '$address\n'
        '\n'
        'Role: ${role.label}\n'
        'Network: ${ChainConfig.caip2} (Sepolia)\n'
        'Nonce: $nonce\n'
        'Issued At: ${issuedAt.toIso8601String()}\n'
        'Expires At: ${expiresAt.toIso8601String()}\n'
        '\n'
        'Signing is free, sends no transaction, and proves you control this '
        'wallet. The session stays on this device.';
  }

  /// Authenticate the connected wallet for [role]. Triggers ONE free
  /// `personal_sign` in the wallet. Throws [StateError] when no wallet is
  /// connected or the returned signature does not recover to the address.
  Future<AuthSession> signIn(UserRole role) async {
    final wallet = WalletService.instance;
    final address = wallet.address;
    if (address == null) {
      throw StateError('Connect a wallet before signing in.');
    }

    final nonce = _randomNonce();
    final issuedAt = DateTime.now().toUtc();
    final expiresAt = issuedAt.add(sessionLifetime);
    final message = buildSignInMessage(
      address: address,
      role: role,
      nonce: nonce,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );

    final signature = await wallet.signMessage(message);

    final recovered = recoverPersonalSigner(message, signature);
    if (recovered.toLowerCase() != address.toLowerCase()) {
      throw StateError(
        'Signature verification failed: the signature was not produced by '
        '$address. Sign-in rejected.',
      );
    }

    final session = AuthSession(
      address: address,
      role: role,
      nonce: nonce,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      signature: signature,
    );
    _session = session;
    await _storage.write(key: _storageKey, value: jsonEncode(session.toJson()));
    notifyListeners();
    return session;
  }

  /// Silently restore a previous session (no wallet popups). Returns true
  /// only when ALL hold: a session is stored, it has not expired, the wallet
  /// still exposes the same account, and the stored signature re-verifies
  /// against the reconstructed message (storage tamper check).
  Future<bool> restore() async {
    String? raw;
    try {
      // Cap the read: a storage backend that doesn't answer promptly must not
      // hold the splash screen hostage — treat it as "no stored session".
      raw = await _storage
          .read(key: _storageKey)
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      return false; // unavailable, timed out, or platform-unsupported
    }
    if (raw == null) return false;

    AuthSession stored;
    try {
      stored = AuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await _storage.delete(key: _storageKey);
      return false;
    }

    if (stored.isExpired) {
      await _storage.delete(key: _storageKey);
      return false;
    }

    // The wallet must still be on the account that signed the session.
    final walletRestored = await WalletService.instance.tryRestoreSession();
    final current = WalletService.instance.address;
    if (!walletRestored ||
        current == null ||
        current.toLowerCase() != stored.address.toLowerCase()) {
      return false; // keep the session; it may match after a manual connect
    }

    // Tamper check: re-verify the stored signature against the message.
    try {
      final message = buildSignInMessage(
        address: stored.address,
        role: stored.role,
        nonce: stored.nonce,
        issuedAt: stored.issuedAt,
        expiresAt: stored.expiresAt,
      );
      final recovered = recoverPersonalSigner(message, stored.signature);
      if (recovered.toLowerCase() != stored.address.toLowerCase()) {
        await _storage.delete(key: _storageKey);
        return false;
      }
    } catch (_) {
      await _storage.delete(key: _storageKey);
      return false;
    }

    _session = stored;
    notifyListeners();
    return true;
  }

  /// End the session. Also disconnects the wallet unless told otherwise
  /// (account-switch invalidation keeps the wallet connected).
  Future<void> signOut({bool disconnectWallet = true}) async {
    _session = null;
    try {
      await _storage.delete(key: _storageKey);
    } catch (_) {/* storage unavailable — in-memory session already gone */}
    if (disconnectWallet) {
      await WalletService.instance.disconnect();
    }
    notifyListeners();
  }

  /// Recover the address that produced [signatureHex] over [message] via
  /// EIP-191 `personal_sign` (prefix + keccak256 + ECDSA public-key recovery).
  /// Pure function — also exercised directly by unit tests.
  static String recoverPersonalSigner(String message, String signatureHex) {
    final messageBytes = utf8.encode(message);
    final prefix = 'Ethereum Signed Message:\n${messageBytes.length}';
    // EIP-191: 0x19 || "Ethereum Signed Message:\n" || len || message.
    final hash = keccak256(
      Uint8List.fromList([0x19, ...utf8.encode(prefix), ...messageBytes]),
    );

    final clean = signatureHex.startsWith('0x')
        ? signatureHex.substring(2)
        : signatureHex;
    final sig = hexToBytes(clean);
    if (sig.length != 65) {
      throw ArgumentError('Expected a 65-byte signature, got ${sig.length}.');
    }
    final r = bytesToUnsignedInt(sig.sublist(0, 32));
    final s = bytesToUnsignedInt(sig.sublist(32, 64));
    var v = sig[64];
    if (v < 27) v += 27; // some wallets return v as 0/1

    final publicKey = ecRecover(hash, MsgSignature(r, s, v));
    return '0x${bytesToHex(publicKeyToAddress(publicKey))}';
  }

  static String _randomNonce() {
    final rng = Random.secure();
    return List.generate(32, (_) => rng.nextInt(16).toRadixString(16)).join();
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../config/env.dart';

/// Pins encrypted KYC bundles to IPFS via Pinata and fetches them back.
///
/// Only ciphertext is ever uploaded — plaintext documents never leave the
/// device unencrypted. The returned CID is what gets stored on-chain.
///
/// Two pinning paths, in priority order:
///
///  1. `PINATA_PROXY_URL` — post ciphertext to the DeKYC pinning proxy (see
///     `proxy/`), which holds the Pinata JWT server-side. **Use this for any
///     web deployment.**
///  2. `PINATA_JWT` — pin directly. Convenient for local development.
///
/// SECURITY NOTE (web): Flutter bundles `.env` as an app asset, so on a
/// `flutter build web` deployment `PINATA_JWT` is downloadable by any visitor.
/// A pure client cannot keep an API secret — that is what path 1 exists for.
class IpfsService {
  IpfsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _pinEndpoint =
      'https://api.pinata.cloud/pinning/pinFileToIPFS';

  String get _jwt => Env.get('PINATA_JWT');

  String get _gatewayHost {
    final host = Env.get('PINATA_GATEWAY');
    return host.isNotEmpty ? host : 'gateway.pinata.cloud';
  }

  /// Upload [bytes] (already encrypted) to Pinata. Returns the IPFS CID.
  Future<String> uploadBytes(
    Uint8List bytes, {
    String filename = 'dekyc_bundle.enc',
  }) async {
    // Prefer the proxy: it holds the credential server-side, which is the only
    // way a web build can pin without publishing the JWT to every visitor.
    if (Env.has('PINATA_PROXY_URL')) {
      return _uploadViaProxy(bytes, Env.get('PINATA_PROXY_URL'));
    }

    if (!Env.has('PINATA_JWT')) {
      throw StateError(
        'Neither PINATA_PROXY_URL nor PINATA_JWT is set. Add one to your .env '
        'before uploading. See proxy/README.md.',
      );
    }

    final request = http.MultipartRequest('POST', Uri.parse(_pinEndpoint))
      ..headers['Authorization'] = 'Bearer $_jwt'
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      )
      ..fields['pinataMetadata'] = jsonEncode({'name': filename})
      ..fields['pinataOptions'] = jsonEncode({'cidVersion': 1});

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode != 200) {
      throw IpfsException(
        'Pinata upload failed (${response.statusCode}): ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final cid = body['IpfsHash'] as String?;
    if (cid == null || cid.isEmpty) {
      throw IpfsException('Pinata response missing IpfsHash: ${response.body}');
    }
    return cid;
  }

  /// Test seam for [_uploadViaProxy]. The production entry point picks the
  /// path from `.env`, which unit tests do not load.
  @visibleForTesting
  Future<String> uploadViaProxyForTest(Uint8List bytes, String proxyUrl) =>
      _uploadViaProxy(bytes, proxyUrl);

  /// Pin through the DeKYC proxy (see `proxy/`), which holds the Pinata JWT.
  /// The app sends only the ciphertext and never sees the credential.
  Future<String> _uploadViaProxy(Uint8List bytes, String proxyUrl) async {
    final uri = Uri.tryParse(proxyUrl);
    if (uri == null || !uri.hasScheme) {
      throw IpfsException('PINATA_PROXY_URL is not a valid URL: "$proxyUrl"');
    }

    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/octet-stream'},
      body: bytes,
    );
    if (response.statusCode != 200) {
      throw IpfsException(
        'Pinning proxy failed (${response.statusCode}): ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final cid = body['IpfsHash'] as String?;
    if (cid == null || cid.isEmpty) {
      throw IpfsException('Proxy response missing IpfsHash: ${response.body}');
    }
    return cid;
  }

  /// Download the raw (encrypted) bytes for [cid] from the gateway.
  Future<Uint8List> downloadBytes(String cid) async {
    final url = gatewayUrl(cid); // validates the CID first
    final response = await _client.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw IpfsException(
        'IPFS fetch failed (${response.statusCode}) for $cid',
      );
    }
    return response.bodyBytes;
  }

  /// Whether [cid] is a syntactically valid IPFS CID. The CID is read from
  /// on-chain data set by another wallet, so it is untrusted input. CIDs use
  /// only base32/base36/base58 alphabets — all strictly alphanumeric — so
  /// requiring `[A-Za-z0-9]` with a bounded length rejects any `/`, `.`,
  /// whitespace or control character that could enable path-traversal or
  /// URL-injection when interpolated into a gateway URL.
  static final RegExp _cidPattern = RegExp(r'^[A-Za-z0-9]{8,100}$');
  static bool isValidCid(String cid) => _cidPattern.hasMatch(cid);

  /// Public gateway URL for a CID. Throws if [cid] is not a valid CID.
  String gatewayUrl(String cid) {
    if (!isValidCid(cid)) {
      throw IpfsException('Refusing to fetch a malformed CID: "$cid"');
    }
    return 'https://$_gatewayHost/ipfs/$cid';
  }

  void dispose() => _client.close();
}

class IpfsException implements Exception {
  IpfsException(this.message);
  final String message;
  @override
  String toString() => 'IpfsException: $message';
}

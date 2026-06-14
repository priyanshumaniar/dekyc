import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Pins encrypted KYC bundles to IPFS via Pinata and fetches them back.
///
/// Only ciphertext is ever uploaded — plaintext documents never leave the
/// device unencrypted. The returned CID is what gets stored on-chain.
///
/// SECURITY NOTE (web): [PINATA_JWT] is read from `.env`, which Flutter bundles
/// as an app asset — on the web build it is therefore downloadable by any
/// visitor. There is no way to keep an API secret on a pure client. For
/// production, pin through a thin backend proxy that holds the JWT and issues
/// short-lived, scoped upload tokens; never ship the master JWT to the browser.
class IpfsService {
  IpfsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _pinEndpoint =
      'https://api.pinata.cloud/pinning/pinFileToIPFS';

  String get _jwt => dotenv.maybeGet('PINATA_JWT') ?? '';

  String get _gatewayHost =>
      dotenv.maybeGet('PINATA_GATEWAY')?.trim().isNotEmpty == true
          ? dotenv.get('PINATA_GATEWAY').trim()
          : 'gateway.pinata.cloud';

  /// Upload [bytes] (already encrypted) to Pinata. Returns the IPFS CID.
  Future<String> uploadBytes(
    Uint8List bytes, {
    String filename = 'dekyc_bundle.enc',
  }) async {
    if (_jwt.isEmpty || _jwt == 'YOUR_PINATA_JWT') {
      throw StateError(
        'PINATA_JWT is not set. Add it to your .env before uploading.',
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

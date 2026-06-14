import 'dart:js_interop';
import 'dart:typed_data';

/// Web AES-256-GCM backed by the browser's native SubtleCrypto
/// (`window.crypto.subtle`). Unlike the pure-Dart PointyCastle path, this runs
/// natively and asynchronously, so encrypting a multi-MB KYC bundle does NOT
/// block Flutter's single web UI thread (which previously froze the page).
///
/// Output layout matches the PointyCastle path exactly — WebCrypto appends the
/// 16-byte GCM tag to the ciphertext — so blobs are cross-platform compatible.
///
/// Requires a secure context (https or localhost), which is always true here.
Future<Uint8List> aesGcmEncrypt(
  Uint8List key,
  Uint8List nonce,
  Uint8List plaintext,
) async {
  final cryptoKey = await _importKey(key);
  final result = await _crypto.subtle
      .encrypt(
        _GcmParams(name: 'AES-GCM'.toJS, iv: nonce.toJS, tagLength: 128.toJS),
        cryptoKey,
        plaintext.toJS,
      )
      .toDart;
  return (result as JSArrayBuffer).toDart.asUint8List();
}

/// Decrypts `ciphertext || tag`. The returned promise rejects (throws) when the
/// GCM tag is invalid — wrong key or tampered ciphertext.
Future<Uint8List> aesGcmDecrypt(
  Uint8List key,
  Uint8List nonce,
  Uint8List ciphertextAndTag,
) async {
  final cryptoKey = await _importKey(key);
  final result = await _crypto.subtle
      .decrypt(
        _GcmParams(name: 'AES-GCM'.toJS, iv: nonce.toJS, tagLength: 128.toJS),
        cryptoKey,
        ciphertextAndTag.toJS,
      )
      .toDart;
  return (result as JSArrayBuffer).toDart.asUint8List();
}

/// Import a raw 32-byte AES key as a non-extractable CryptoKey.
Future<JSObject> _importKey(Uint8List key) async {
  final imported = await _crypto.subtle
      .importKey(
        'raw'.toJS,
        key.toJS,
        'AES-GCM'.toJS,
        false.toJS,
        <JSString>['encrypt'.toJS, 'decrypt'.toJS].toJS,
      )
      .toDart;
  return imported as JSObject;
}

@JS('crypto')
external _Crypto get _crypto;

extension type _Crypto._(JSObject _) implements JSObject {
  external _SubtleCrypto get subtle;
}

extension type _SubtleCrypto._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> importKey(
    JSString format,
    JSUint8Array keyData,
    JSString algorithm,
    JSBoolean extractable,
    JSArray<JSString> keyUsages,
  );
  external JSPromise<JSAny?> encrypt(
    _GcmParams algorithm,
    JSObject key,
    JSUint8Array data,
  );
  external JSPromise<JSAny?> decrypt(
    _GcmParams algorithm,
    JSObject key,
    JSUint8Array data,
  );
}

extension type _GcmParams._(JSObject _) implements JSObject {
  external factory _GcmParams({
    required JSString name,
    required JSUint8Array iv,
    required JSNumber tagLength,
  });
}

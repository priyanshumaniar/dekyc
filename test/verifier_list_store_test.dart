import 'package:de_kyc/services/verifier_list_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory stand-in for secure storage.
class _FakeStorage implements FlutterSecureStorage {
  _FakeStorage({this.failing = false});

  final Map<String, String> data = {};
  final bool failing;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failing) throw Exception('storage unavailable');
    return data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failing) throw Exception('storage unavailable');
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const alice = '0x1111111111111111111111111111111111111111';
  const bob = '0x2222222222222222222222222222222222222222';
  const bank = '0xAAAA111111111111111111111111111111111111';
  const exchange = '0xBBBB222222222222222222222222222222222222';

  test('a saved list survives being reloaded', () async {
    // The whole point: leaving Manage Access and coming back must not lose the
    // row while the grant is still live on-chain.
    final storage = _FakeStorage();
    final store = VerifierListStore.forTesting(storage);

    await store.add(alice, bank);
    await store.add(alice, exchange);

    // A brand-new store over the same backing storage == a fresh screen mount.
    final reopened = VerifierListStore.forTesting(storage);
    expect(await reopened.load(alice), equals([bank, exchange]));
  });

  test('adding the same address twice does not duplicate it', () async {
    final store = VerifierListStore.forTesting(_FakeStorage());
    await store.add(alice, bank);
    await store.add(alice, bank);
    expect(await store.load(alice), equals([bank]));
  });

  test('duplicate detection ignores checksum casing', () async {
    final store = VerifierListStore.forTesting(_FakeStorage());
    await store.add(alice, bank);
    await store.add(alice, bank.toLowerCase());
    expect((await store.load(alice)).length, equals(1));
  });

  test('lists are scoped per owner', () async {
    final storage = _FakeStorage();
    final store = VerifierListStore.forTesting(storage);
    await store.add(alice, bank);
    await store.add(bob, exchange);

    expect(await store.load(alice), equals([bank]));
    expect(await store.load(bob), equals([exchange]));
  });

  test('the owner key is case-insensitive', () async {
    final store = VerifierListStore.forTesting(_FakeStorage());
    await store.add(alice.toUpperCase().replaceFirst('0X', '0x'), bank);
    expect(await store.load(alice), equals([bank]));
  });

  test('remove drops only the named address', () async {
    final store = VerifierListStore.forTesting(_FakeStorage());
    await store.add(alice, bank);
    await store.add(alice, exchange);
    await store.remove(alice, bank);
    expect(await store.load(alice), equals([exchange]));
  });

  test('an unknown owner reads as empty, not an error', () async {
    final store = VerifierListStore.forTesting(_FakeStorage());
    expect(await store.load(bob), isEmpty);
  });

  test('storage failures degrade to empty instead of throwing', () async {
    // The list is a convenience; a storage outage must not break the screen.
    final store = VerifierListStore.forTesting(_FakeStorage(failing: true));
    expect(await store.load(alice), isEmpty);
    await store.add(alice, bank); // must not throw
    expect(await store.load(alice), isEmpty);
  });

  test('corrupt stored data reads as empty rather than crashing', () async {
    final storage = _FakeStorage();
    storage.data['dekyc.verifiers.v1.${alice.toLowerCase()}'] = 'not json';
    final store = VerifierListStore.forTesting(storage);
    expect(await store.load(alice), isEmpty);
  });
}

import 'package:web3dart/web3dart.dart' show EthereumAddress;

import 'kyc_contract_service.dart' show VerifierGrant;

/// The rows Manage Access shows, and the rule for combining two sources.
///
/// The chain is authoritative for STATUS but is not the whole list: an address
/// the user has typed and not yet granted has no on-chain row at all. Replacing
/// the list with the chain's outright therefore made a freshly-added row vanish
/// a second after it appeared — and then persisted that removal to the cache.
///
/// This is pure so the invariant can be tested without a chain or a widget.
class GuestList {
  const GuestList({required this.rows, required this.pending});

  /// Display order: on-chain rows first, then not-yet-granted additions.
  final List<String> rows;

  /// Addresses still absent from the chain.
  final Set<String> pending;

  /// Merge [chain] rows over [pending] additions.
  ///
  /// A pending address that now appears on-chain is promoted (dropped from
  /// [pending]) rather than listed twice. All comparisons are on the canonical
  /// EIP-55 form, because `grantsOf` returns checksummed addresses while a user
  /// may paste any casing — without normalising, a lowercase paste would sit
  /// beside its own chain row as a duplicate and never resolve its status.
  factory GuestList.merge({
    required List<VerifierGrant> chain,
    required Iterable<String> pending,
  }) {
    final onChain = <String>[];
    final onChainSet = <String>{};
    for (final g in chain) {
      final a = canon(g.address);
      if (onChainSet.add(a)) onChain.add(a);
    }

    final stillPending = <String>{};
    final extras = <String>[];
    for (final raw in pending) {
      final a = canon(raw);
      if (onChainSet.contains(a)) continue; // promoted
      if (stillPending.add(a)) extras.add(a);
    }

    return GuestList(
      rows: [...onChain, ...extras],
      pending: stillPending,
    );
  }

  /// Canonical (EIP-55 checksummed) form of [address].
  static String canon(String address) =>
      EthereumAddress.fromHex(address.trim()).hexEip55;
}

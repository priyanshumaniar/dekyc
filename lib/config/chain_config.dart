import 'env.dart';

/// Network configuration. DeKYC targets the Sepolia testnet ONLY.
class ChainConfig {
  ChainConfig._();

  /// Sepolia chain id.
  static const int chainId = 11155111;

  /// CAIP-2 identifier used by WalletConnect/Reown.
  static const String caip2 = 'eip155:11155111';

  /// Human-readable name.
  static const String networkName = 'Sepolia';

  /// Block explorer base URL.
  static const String explorerBaseUrl = 'https://sepolia.etherscan.io';

  /// RPC endpoint, read from .env at runtime. Empty when unset.
  static String get rpcUrl => Env.get('SEPOLIA_RPC_URL');

  /// Whether an RPC endpoint is configured at all. Screens use this to explain
  /// why on-chain reads are unavailable instead of failing obscurely.
  static bool get hasRpc => Env.has('SEPOLIA_RPC_URL');

  /// Etherscan transaction link helper.
  static String txUrl(String txHash) => '$explorerBaseUrl/tx/$txHash';

  /// Etherscan address link helper.
  static String addressUrl(String address) =>
      '$explorerBaseUrl/address/$address';
}

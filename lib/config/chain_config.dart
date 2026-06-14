import 'package:flutter_dotenv/flutter_dotenv.dart';

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

  /// RPC endpoint, read from .env at runtime.
  static String get rpcUrl =>
      dotenv.maybeGet('SEPOLIA_RPC_URL') ?? '';

  /// Etherscan transaction link helper.
  static String txUrl(String txHash) => '$explorerBaseUrl/tx/$txHash';

  /// Etherscan address link helper.
  static String addressUrl(String address) =>
      '$explorerBaseUrl/address/$address';
}

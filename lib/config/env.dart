import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Safe accessor for `.env` values.
///
/// `dotenv.maybeGet` is a misnomer: it reads `dotenv.env`, and that getter
/// throws `NotInitializedError` when `dotenv.load` has not completed. So the
/// two situations the app is explicitly written to tolerate — a `.env` that
/// is missing at startup (`main.dart` catches the load failure and carries on)
/// and unit tests, which never load one — would instead turn every config read
/// into a crash, rather than the "this value is not set" errors the screens
/// are designed to surface.
///
/// Every read of a `.env` value goes through here.
class Env {
  Env._();

  /// The value for [key], or an empty string when absent or `.env` never
  /// loaded. Callers decide what a missing value means.
  static String get(String key) {
    if (!dotenv.isInitialized) return '';
    return dotenv.maybeGet(key)?.trim() ?? '';
  }

  /// Whether [key] has a usable value — non-empty and not still the
  /// `.env.example` placeholder.
  static bool has(String key) {
    final v = get(key);
    return v.isNotEmpty && !v.startsWith('YOUR_');
  }
}

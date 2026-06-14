import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// DeKYC design system v2 — blockchain-wallet aesthetic (MetaMask-inspired).
///
/// Dark-first (default), with a full light variant. Near-black canvas, soft
/// dark cards, one violet accent, pill buttons, circular icon chips and big
/// hero type. Screens read colors via `context.pal` so every widget adapts to
/// the active brightness automatically.
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.hairline,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.danger,
    required this.warning,
  });

  final Color bg; // scaffold canvas
  final Color surface; // cards
  final Color surfaceAlt; // elevated tiles / inputs
  final Color hairline; // borders, dividers
  final Color text; // primary text
  final Color muted; // secondary text
  final Color accent; // the one brand color
  final Color onAccent; // text/icon on accent
  final Color success;
  final Color danger;
  final Color warning;
}

class AppTheme {
  AppTheme._();

  static const Palette darkPal = Palette(
    bg: Color(0xFF0A0A0C),
    surface: Color(0xFF161619),
    surfaceAlt: Color(0xFF202025),
    hairline: Color(0xFF2A2A30),
    text: Color(0xFFFFFFFF),
    muted: Color(0xFF9DA0A8),
    accent: Color(0xFF8B7CFF),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF4CC38A),
    danger: Color(0xFFFF6B6B),
    warning: Color(0xFFFFB155),
  );

  static const Palette lightPal = Palette(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF5F5F8),
    surfaceAlt: Color(0xFFECEDF2),
    hairline: Color(0xFFE3E3E9),
    text: Color(0xFF131316),
    muted: Color(0xFF6F7177),
    accent: Color(0xFF6C5BF0),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF18914F),
    danger: Color(0xFFD64545),
    warning: Color(0xFFB97324),
  );

  static const double radius = 16;

  static ThemeData get dark => _build(darkPal, Brightness.dark);
  static ThemeData get light => _build(lightPal, Brightness.light);

  static ThemeData _build(Palette p, Brightness b) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: b,
      scaffoldBackgroundColor: p.bg,
      colorScheme: ColorScheme(
        brightness: b,
        primary: p.accent,
        onPrimary: p.onAccent,
        secondary: p.accent,
        onSecondary: p.onAccent,
        surface: p.bg,
        onSurface: p.text,
        error: p.danger,
        onError: Colors.white,
      ),
    );

    final pill =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(28));

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: p.text),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: p.text,
        displayColor: p.text,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          disabledBackgroundColor: p.surfaceAlt,
          disabledForegroundColor: p.muted,
          minimumSize: const Size.fromHeight(52),
          shape: pill,
          textStyle:
              const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          backgroundColor: p.surface,
          side: BorderSide(color: p.hairline),
          minimumSize: const Size.fromHeight(52),
          shape: pill,
          textStyle:
              const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: p.accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: p.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: p.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: p.accent, width: 1.4),
        ),
        labelStyle: TextStyle(color: p.muted),
        hintStyle: TextStyle(color: p.muted),
        prefixIconColor: p.muted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: base.cardTheme.copyWith(
        color: p.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: b == Brightness.light
              ? BorderSide(color: p.hairline)
              : BorderSide.none,
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(color: p.hairline, thickness: 1),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceAlt,
        contentTextStyle: TextStyle(color: p.text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(color: p.muted, fontSize: 14, height: 1.5),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
      listTileTheme: ListTileThemeData(iconColor: p.text, textColor: p.text),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(p.onAccent),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accent : p.surfaceAlt,
        ),
        trackOutlineColor: WidgetStatePropertyAll(p.hairline),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: p.surface,
        side: BorderSide(color: p.hairline),
        labelStyle: TextStyle(color: p.text, fontSize: 13),
        shape: StadiumBorder(side: BorderSide(color: p.hairline)),
      ),
    );
  }
}

/// Read the active palette anywhere: `context.pal.muted`.
extension PaletteX on BuildContext {
  Palette get pal => Theme.of(this).brightness == Brightness.dark
      ? AppTheme.darkPal
      : AppTheme.lightPal;
}

/// App-wide theme mode (default dark), persisted across launches.
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const String _storageKey = 'dekyc.theme.v1';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;
  bool get isDark => _mode != ThemeMode.light;

  /// Restore the saved preference. Best-effort and time-capped — theme must
  /// never block startup.
  Future<void> load() async {
    try {
      final v = await const FlutterSecureStorage()
          .read(key: _storageKey)
          .timeout(const Duration(seconds: 3));
      if (v == 'light') _mode = ThemeMode.light;
      if (v == 'dark') _mode = ThemeMode.dark;
      notifyListeners();
    } catch (_) {/* keep default dark */}
  }

  Future<void> toggle() async {
    _mode = isDark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    try {
      await const FlutterSecureStorage()
          .write(key: _storageKey, value: isDark ? 'dark' : 'light');
    } catch (_) {/* preference just won't persist */}
  }
}

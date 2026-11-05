import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

export 'package:core_sdk/core_sdk.dart' show TruckPalette, TruckColors, Gap, SectionCard, AttentionTile;

/// Motyw TruckMaps w jednym miejscu: paleta marki, typografia, zaokrąglenia, karty, przyciski,
/// pola, jasny i ciemny tryb. Ekrany biorą kolory z `Theme.of(context)` i [TruckColors].
abstract final class TruckTheme {
  static const radius = 12.0;
  static const smallRadius = 10.0;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(seedColor: TruckPalette.brand, brightness: brightness);
    final scheme = base.copyWith(
      primary: dark ? const Color(0xFF8CC4F0) : TruckPalette.brand,
      onPrimary: dark ? const Color(0xFF00324F) : Colors.white,
      secondary: dark ? const Color(0xFFF7C566) : const Color(0xFF8A5A00),
      secondaryContainer: dark ? const Color(0xFF5A3D00) : const Color(0xFFFFE2A8),
      onSecondaryContainer: dark ? const Color(0xFFFFE2A8) : const Color(0xFF2B1A00),
      surface: dark ? const Color(0xFF111418) : const Color(0xFFF7F8FA),
      background: dark ? const Color(0xFF111418) : const Color(0xFFF7F8FA),
      surfaceVariant: dark ? const Color(0xFF262B32) : const Color(0xFFE6EAF0),
      outlineVariant: dark ? const Color(0xFF3A414A) : const Color(0xFFD5DBE3),
    );
    final cardColor = dark ? const Color(0xFF1A1F25) : Colors.white;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    final small = RoundedRectangleBorder(borderRadius: BorderRadius.circular(smallRadius));
    const buttonPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    // Rozmiary (englishLike) razem z kolorami – sam `copyWith` bez rozmiarów dałby tekst 14 px.
    final typography = Typography.material2021();
    final text = typography.englishLike
        .merge(dark ? typography.white : typography.black)
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
    final textTheme = text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      visualDensity: VisualDensity.standard,
      extensions: [dark ? TruckColors.dark : TruckColors.light],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      cardTheme: CardTheme(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape.copyWith(side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(shape: small, iconColor: scheme.onSurfaceVariant),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(padding: buttonPadding, shape: small)),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(padding: buttonPadding, shape: small, side: BorderSide(color: scheme.outline)),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: small)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: small)),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(shape: MaterialStatePropertyAll(small)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(shape: small, side: BorderSide(color: scheme.outlineVariant)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1A1F25) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(smallRadius)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(smallRadius),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(smallRadius),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      dialogTheme: DialogTheme(shape: shape, surfaceTintColor: Colors.transparent),
      popupMenuTheme: PopupMenuThemeData(shape: small, surfaceTintColor: Colors.transparent),
      bottomSheetTheme: const BottomSheetThemeData(
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      ),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: small),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: dark ? const Color(0xFF161A1F) : const Color(0xFFEEF2F6),
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: small,
        tileHeight: 48,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      tabBarTheme: TabBarTheme(dividerColor: scheme.outlineVariant),
    );
  }
}

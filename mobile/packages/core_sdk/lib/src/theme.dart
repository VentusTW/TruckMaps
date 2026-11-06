import 'package:flutter/material.dart';

/// Paleta TruckMaps – jedyne miejsce z kolorami na stałe. Ekrany i moduły biorą kolory
/// z motywu ([ColorScheme], [TruckColors]); te stałe są dla miejsc bez motywu (mapa,
/// ciemny układ nawigacji, ocena trasy, która musi wyglądać tak samo w obu trybach).
/// Kolory interfejsu – według projektu Stitch (`docs/design/stitch/STYL.md`).
abstract final class TruckPalette {
  /// Kolor marki: głęboki granat (primary).
  static const brand = Color(0xFF00288E);

  /// Aktywna pozycja menu, piny pojazdów (primaryContainer).
  static const brandContainer = Color(0xFF1E40AF);

  /// Akcent: bursztyn znaków ostrzegawczych.
  static const accent = Color(0xFFE8A317);

  // Ocena trasy (zielony → czerwony) – czytelna na mapie jasnej i ciemnej.
  static const ratingGreen = Color(0xFF3B7D23);
  static const ratingLime = Color(0xFF97C459);
  static const ratingYellow = Color(0xFFF5C518);
  static const ratingOrange = Color(0xFFF08C00);
  static const ratingRed = Color(0xFFD62828);
  static const ratingUnknown = Color(0xFF888780);

  /// Ograniczenie objęte zezwoleniem na przejazd.
  static const permitted = Color(0xFF1E6FD9);

  // Punkty trasy na mapie.
  static const start = Color(0xFF185FA5);
  static const end = Color(0xFFA32D2D);
  static const via = Color(0xFF5F5E5A);
  static const pickup = Color(0xFFF08C00);

  // Nawigacja – ciemne półprzezroczyste panele nad mapą.
  static const navPanel = Color(0xE01B232B);
  static const navAccent = Color(0xFF5FB3F6);
  static const navOnRoute = Color(0xE03B6D11);
  static const navOffRoute = Color(0xE0E65100);
  static const navAlarm = Color(0xF0D62828);
  static const navAlarmDark = Color(0xE6600000);
  static const navLate = Color(0xFFFF6B6B);
  static const navOnTime = Color(0xFF7BD389);
  static const camera = Color(0xFFF08C00);
  static const driverReport = Color(0xFFE5B800);

  // Tabliczki numerów dróg (europejska, wojewódzka, krajowa).
  static const roadEuropean = Color(0xFF2E7D32);
  static const roadRegional = Color(0xFFF5C518);
  static const roadNational = Color(0xFFC62828);

  /// Kolejne przystanki (np. plan załadunku – palety według miejsca rozładunku).
  static const series = [
    Color(0xFF1E6FD9),
    Color(0xFFF08C00),
    Color(0xFF3B7D23),
    Color(0xFF8E44AD),
    Color(0xFF00897B),
    Color(0xFF8D6E63),
  ];
}

/// Kolory znaczeniowe zależne od trybu (jasny / ciemny): stan pojazdu, terminy, sukces,
/// oraz odcienie powierzchni z projektu, których [ColorScheme] tej wersji Fluttera nie ma.
@immutable
class TruckColors extends ThemeExtension<TruckColors> {
  const TruckColors({
    required this.success,
    required this.warning,
    required this.amber,
    required this.info,
    required this.reported,
    required this.inUse,
    required this.mint,
    required this.onMint,
    required this.card,
    required this.surfaceLow,
    required this.surfaceHigh,
  });

  static const light = TruckColors(
    success: Color(0xFF00563A),
    warning: Color(0xFFB45F06),
    amber: Color(0xFFD97706),
    info: Color(0xFF1E40AF),
    reported: Color(0xFFB7791F),
    inUse: Color(0xFF1E40AF),
    mint: Color(0xFF85F8C4),
    onMint: Color(0xFF00563A),
    card: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFEFF4FF),
    surfaceHigh: Color(0xFFDCE9FF),
  );

  static const dark = TruckColors(
    success: Color(0xFF68DBA9),
    warning: Color(0xFFFFB74D),
    amber: Color(0xFFF59E0B),
    info: Color(0xFFB8C4FF),
    reported: Color(0xFFFFD54F),
    inUse: Color(0xFFB8C4FF),
    mint: Color(0xFF00563A),
    onMint: Color(0xFF85F8C4),
    card: Color(0xFF102339),
    surfaceLow: Color(0xFF162B44),
    surfaceHigh: Color(0xFF213854),
  );

  /// Zrobione, w porządku.
  final Color success;

  /// Termin zbliża się, wymaga uwagi.
  final Color warning;

  /// Bursztyn z DESIGN.md (#D97706) – tylko elementy graficzne: paski, kropki, ikony
  /// (tekst ostrzeżeń zostaje w [warning] ze względu na kontrast).
  final Color amber;
  final Color info;

  /// Zgłoszona usterka.
  final Color reported;

  /// Pojazd w użyciu / podpięty.
  final Color inUse;

  /// Miętowe tło chipów „w porządku / w trasie” i ciemnozielony tekst na nim.
  final Color mint;
  final Color onMint;

  /// Tło kart (najjaśniejsza powierzchnia).
  final Color card;

  /// Pola w kartach, wyszukiwarka, kwadraty ikon, przyciski drugorzędne.
  final Color surfaceLow;

  /// Tor paska postępu, najechanie myszą.
  final Color surfaceHigh;

  /// Kolory z motywu; motyw bez rozszerzenia (np. w testach modułu) – jasne albo ciemne domyślne.
  static TruckColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<TruckColors>() ?? (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  TruckColors copyWith({
    Color? success,
    Color? warning,
    Color? amber,
    Color? info,
    Color? reported,
    Color? inUse,
    Color? mint,
    Color? onMint,
    Color? card,
    Color? surfaceLow,
    Color? surfaceHigh,
  }) =>
      TruckColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        amber: amber ?? this.amber,
        info: info ?? this.info,
        reported: reported ?? this.reported,
        inUse: inUse ?? this.inUse,
        mint: mint ?? this.mint,
        onMint: onMint ?? this.onMint,
        card: card ?? this.card,
        surfaceLow: surfaceLow ?? this.surfaceLow,
        surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      );

  @override
  TruckColors lerp(TruckColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return TruckColors(
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      amber: mix(amber, other.amber),
      info: mix(info, other.info),
      reported: mix(reported, other.reported),
      inUse: mix(inUse, other.inUse),
      mint: mix(mint, other.mint),
      onMint: mix(onMint, other.onMint),
      card: mix(card, other.card),
      surfaceLow: mix(surfaceLow, other.surfaceLow),
      surfaceHigh: mix(surfaceHigh, other.surfaceHigh),
    );
  }
}

/// Odstępy w całej aplikacji (siatka 4 px).
abstract final class Gap {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Gradienty kafelków i wyróżnień – wygląd mniej płaski.
abstract final class TruckGradients {
  /// Delikatny: od tła karty (lewy górny róg) do odcienia [color] (prawy dolny).
  static LinearGradient tile(BuildContext context, Color color, {double strength = 0.12}) {
    final card = TruckColors.of(context).card;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [card, Color.alphaBlend(color.withOpacity(strength), card)],
    );
  }

  /// Pełny: jaśniejszy i ciemniejszy odcień [color] (banery, aktywne pozycje).
  static LinearGradient strong(Color color) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(color, Colors.white, 0.12)!, Color.lerp(color, Colors.black, 0.18)!],
      );

  /// Marka: granat → błękit (nagłówek pulpitu, wybrana pozycja menu) – taki sam w obu trybach.
  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [TruckPalette.brand, TruckPalette.brandContainer, Color(0xFF3755C3)],
  );

  /// Wypełnienie paska postępu: od jaśniejszego do pełnego koloru.
  static LinearGradient bar(Color color) => LinearGradient(colors: [Color.lerp(color, Colors.white, 0.35)!, color]);
}

/// Czcionki dołączone do pakietu (licencja OFL, pliki w `core_sdk/fonts`) – bez pobierania z sieci.
abstract final class TruckFonts {
  /// Tekst, etykiety, liczby.
  static const body = 'packages/core_sdk/Inter';

  /// Nagłówki.
  static const headline = 'packages/core_sdk/PlusJakartaSans';
}

/// Motyw TruckMaps w jednym miejscu: kolory z projektu Stitch, czcionki, typografia, zaokrąglenia,
/// karty bez obramowań z delikatnym cieniem; jasny i ciemny tryb z tych samych kolorów.
abstract final class TruckTheme {
  /// Karty.
  static const radius = 8.0;

  /// Przyciski, pola, pozycje menu.
  static const smallRadius = 4.0;

  /// Okna dialogowe i duże sekcje pulpitu (`rounded-xl` = 12 px).
  static const dialogRadius = 12.0;

  /// Szerokość menu bocznego na komputerze.
  static const sideMenuWidth = 288.0;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF00288E),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFF1E40AF),
    onPrimaryContainer: Color(0xFFFFFFFF),
    secondary: Color(0xFF565E74),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFDAE2FD),
    onSecondaryContainer: Color(0xFF131B2E),
    tertiary: Color(0xFF003D28),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFF00563A),
    onTertiaryContainer: Color(0xFF85F8C4),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    background: Color(0xFFF8F9FF),
    onBackground: Color(0xFF0B1C30),
    surface: Color(0xFFF8F9FF),
    onSurface: Color(0xFF0B1C30),
    surfaceVariant: Color(0xFFD3E4FE),
    onSurfaceVariant: Color(0xFF444653),
    outline: Color(0xFF757684),
    outlineVariant: Color(0xFFC4C5D5),
    inverseSurface: Color(0xFF213145),
    onInverseSurface: Color(0xFFEAF1FF),
    inversePrimary: Color(0xFFB8C4FF),
    surfaceTint: Color(0xFF00288E),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  /// Ciemny: tło z koloru tekstu jasnego trybu, tekst z najjaśniejszych powierzchni.
  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFB8C4FF),
    onPrimary: Color(0xFF00288E),
    primaryContainer: Color(0xFF1E40AF),
    onPrimaryContainer: Color(0xFFDDE1FF),
    secondary: Color(0xFFBEC6E0),
    onSecondary: Color(0xFF283044),
    secondaryContainer: Color(0xFF3E4759),
    onSecondaryContainer: Color(0xFFDAE2FD),
    tertiary: Color(0xFF68DBA9),
    onTertiary: Color(0xFF003D28),
    tertiaryContainer: Color(0xFF00563A),
    onTertiaryContainer: Color(0xFF85F8C4),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    background: Color(0xFF0B1C30),
    onBackground: Color(0xFFD3E4FE),
    surface: Color(0xFF0B1C30),
    onSurface: Color(0xFFD3E4FE),
    surfaceVariant: Color(0xFF213854),
    onSurfaceVariant: Color(0xFFC4C5D5),
    outline: Color(0xFF8E909F),
    outlineVariant: Color(0xFF444653),
    inverseSurface: Color(0xFFD3E4FE),
    onInverseSurface: Color(0xFF0B1C30),
    inversePrimary: Color(0xFF00288E),
    surfaceTint: Color(0xFFB8C4FF),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  /// Skala typografii z projektu: nagłówki Plus Jakarta Sans, reszta Inter.
  static TextTheme textTheme(Color color) {
    TextStyle head(double size, double line, FontWeight weight, {double spacing = 0}) => TextStyle(
        fontFamily: TruckFonts.headline,
        fontSize: size,
        height: line / size,
        fontWeight: weight,
        letterSpacing: spacing,
        color: color);
    TextStyle body(double size, double line, FontWeight weight, {double spacing = 0}) => TextStyle(
        fontFamily: TruckFonts.body,
        fontSize: size,
        height: line / size,
        fontWeight: weight,
        letterSpacing: spacing,
        color: color);
    return TextTheme(
      displayLarge: head(48, 56, FontWeight.w700, spacing: -0.5),
      displayMedium: head(40, 48, FontWeight.w700, spacing: -0.4),
      displaySmall: head(36, 44, FontWeight.w700, spacing: -0.3),
      headlineLarge: head(36, 44, FontWeight.w700, spacing: -0.3),
      headlineMedium: head(28, 36, FontWeight.w600, spacing: -0.2),
      headlineSmall: head(24, 32, FontWeight.w600, spacing: -0.2),
      titleLarge: head(20, 26, FontWeight.w600),
      titleMedium: head(17, 24, FontWeight.w600),
      titleSmall: body(14, 20, FontWeight.w600),
      bodyLarge: body(16, 24, FontWeight.w400),
      bodyMedium: body(14, 22, FontWeight.w400),
      bodySmall: body(12, 18, FontWeight.w400),
      labelLarge: body(14, 20, FontWeight.w600),
      labelMedium: body(12, 16, FontWeight.w600),
      labelSmall: body(11, 14, FontWeight.w700, spacing: 0.44),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = dark ? _darkScheme : _lightScheme;
    final colors = dark ? TruckColors.dark : TruckColors.light;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    final small = RoundedRectangleBorder(borderRadius: BorderRadius.circular(smallRadius));
    const buttonPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    final text = textTheme(scheme.onSurface);
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(smallRadius),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: TruckFonts.body,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      textTheme: text,
      visualDensity: VisualDensity.standard,
      extensions: [colors],
      appBarTheme: AppBarTheme(
        backgroundColor: colors.card,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        shadowColor: Colors.black26,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      // Karty bez obramowań, z delikatnym cieniem.
      cardTheme: CardTheme(
        color: colors.card,
        surfaceTintColor: Colors.transparent,
        // Wyraźny, granatowy cień – kafelki „unoszą się” nad tłem.
        shadowColor: dark ? Colors.black : TruckPalette.brand.withOpacity(0.35),
        elevation: 3,
        margin: EdgeInsets.zero,
        shape: shape,
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(shape: small, iconColor: scheme.onSurfaceVariant),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: buttonPadding,
          shape: small,
          elevation: 2,
          shadowColor: TruckPalette.brand.withOpacity(0.5),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(padding: buttonPadding, shape: small, side: BorderSide(color: scheme.outline)),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: small)),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: small, elevation: 2, shadowColor: TruckPalette.brand.withOpacity(0.4)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(style: ButtonStyle(shape: MaterialStatePropertyAll(small))),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: shape,
      ),
      // Chipy w pełni zaokrąglone.
      chipTheme: ChipThemeData(
        elevation: 1,
        pressElevation: 3,
        shadowColor: TruckPalette.brand.withOpacity(0.3),
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: colors.surfaceLow,
        labelStyle: text.labelMedium,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceLow,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(borderSide: BorderSide(color: scheme.primary, width: 2)),
      ),
      dialogTheme: DialogTheme(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(dialogRadius)),
        surfaceTintColor: Colors.transparent, backgroundColor: colors.card),
      popupMenuTheme: PopupMenuThemeData(shape: small, surfaceTintColor: Colors.transparent, color: colors.card),
      bottomSheetTheme: BottomSheetThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: colors.card,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      ),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: small),
      drawerTheme:
          DrawerThemeData(backgroundColor: colors.card, surfaceTintColor: Colors.transparent, width: sideMenuWidth),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: colors.card,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: small,
        tileHeight: 48,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary, linearTrackColor: colors.surfaceHigh),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withOpacity(0.6), space: 1),
      tabBarTheme: TabBarTheme(dividerColor: scheme.outlineVariant),
    );
  }
}

/// Sekcja karty (pojazdu, pulpitu): nagłówek z ikoną, opcjonalne akcje i treść.
/// Wspólna dla rdzenia i modułów – wszystkie sekcje wyglądają tak samo.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.action,
    this.accent,
    this.padding = const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
  });

  final String title;
  final IconData icon;
  final Widget child;

  /// Przycisk w nagłówku (np. „Zmień”, „Wszystkie”).
  final Widget? action;

  /// Kolor ikony nagłówka (np. ostrzeżenie); domyślnie kolor marki.
  final Color? accent;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(
          decoration: BoxDecoration(
            gradient: TruckGradients.tile(context, accent ?? theme.colorScheme.primary, strength: 0.10),
          ),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
          margin: const EdgeInsets.only(bottom: Gap.m),
          child: Row(children: [
            IconSquare(icon: icon, color: accent ?? theme.colorScheme.primary, size: 32),
            const SizedBox(width: Gap.m),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            if (action != null) action!,
          ]),
        ),
        Padding(padding: padding, child: child),
      ]),
    );
  }
}

/// Pozycja „wymaga uwagi” (termin, usterka): kolor według pilności.
class AttentionTile extends StatelessWidget {
  const AttentionTile({
    super.key,
    required this.title,
    this.subtitle,
    this.overdue = false,
    this.icon,
    this.onTap,
    this.tag,
  });

  final String title;
  final String? subtitle;

  /// Po terminie / pilne – kolor błędu; inaczej ostrzeżenie.
  final bool overdue;
  final IconData? icon;
  final VoidCallback? onTap;

  /// Krótka etykieta nad tytułem (np. „Pilne”), w kolorze pilności.
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = overdue ? theme.colorScheme.error : TruckColors.of(context).warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(TruckTheme.radius),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              Color.alphaBlend(color.withOpacity(0.16), TruckColors.of(context).card),
              Color.alphaBlend(color.withOpacity(0.04), TruckColors.of(context).card),
            ]),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(TruckTheme.radius),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(Gap.m),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                IconSquare(
                  icon: icon ?? (overdue ? Icons.error_outline : Icons.schedule),
                  color: color,
                  background: color.withOpacity(0.16),
                ),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (tag != null) ...[TagLabel(tag!, color: color), const SizedBox(height: Gap.xs)],
                    Text(title, style: theme.textTheme.titleSmall),
                    if (subtitle != null)
                      Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface)),
                  ]),
                ),
                if (onTap != null) Icon(Icons.chevron_right, color: color),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Etykieta kategorii: pełne kolorowe tło, biały tekst wielkimi literami (np. „PILNE”, „ALERT”).
class TagLabel extends StatelessWidget {
  const TagLabel(this.text, {super.key, this.color});

  final String text;

  /// Tło; domyślnie kolor marki.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? Theme.of(context).colorScheme.primaryContainer;
    final fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : Colors.black;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(2)),
      child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
    );
  }
}

/// Ikona w zaokrąglonym kwadracie (karty KPI, pozycje list).
class IconSquare extends StatelessWidget {
  const IconSquare({super.key, required this.icon, this.color, this.background, this.size = 40});

  final IconData icon;
  final Color? color;
  final Color? background;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        gradient: background != null
            ? null
            : LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [
                Color.alphaBlend(fg.withOpacity(0.24), TruckColors.of(context).card),
                Color.alphaBlend(fg.withOpacity(0.08), TruckColors.of(context).card),
              ]),
        borderRadius: BorderRadius.circular(TruckTheme.radius),
      ),
      child: Icon(icon, color: fg, size: size * 0.55),
    );
  }
}

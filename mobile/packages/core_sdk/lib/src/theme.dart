import 'package:flutter/material.dart';

/// Paleta TruckMaps – jedyne miejsce z kolorami na stałe. Ekrany i moduły biorą kolory
/// z motywu ([ColorScheme], [TruckColors]); te stałe są dla miejsc bez motywu (mapa,
/// ciemny układ nawigacji, ocena trasy, która musi wyglądać tak samo w obu trybach).
abstract final class TruckPalette {
  /// Kolor marki: głęboki granat drogowy.
  static const brand = Color(0xFF14507A);

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

/// Kolory znaczeniowe zależne od trybu (jasny / ciemny): stan pojazdu, terminy, sukces.
@immutable
class TruckColors extends ThemeExtension<TruckColors> {
  const TruckColors({
    required this.success,
    required this.warning,
    required this.info,
    required this.reported,
    required this.inUse,
  });

  static const light = TruckColors(
    success: Color(0xFF2E7D32),
    warning: Color(0xFFB45F06),
    info: Color(0xFF1565C0),
    reported: Color(0xFFB7791F),
    inUse: Color(0xFF1565C0),
  );

  static const dark = TruckColors(
    success: Color(0xFF81C784),
    warning: Color(0xFFFFB74D),
    info: Color(0xFF64B5F6),
    reported: Color(0xFFFFD54F),
    inUse: Color(0xFF4FC3F7),
  );

  /// Zrobione, w porządku.
  final Color success;

  /// Termin zbliża się, wymaga uwagi.
  final Color warning;
  final Color info;

  /// Zgłoszona usterka.
  final Color reported;

  /// Pojazd w użyciu / podpięty.
  final Color inUse;

  /// Kolory z motywu; motyw bez rozszerzenia (np. w testach modułu) – jasne albo ciemne domyślne.
  static TruckColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<TruckColors>() ?? (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  TruckColors copyWith({Color? success, Color? warning, Color? info, Color? reported, Color? inUse}) => TruckColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        info: info ?? this.info,
        reported: reported ?? this.reported,
        inUse: inUse ?? this.inUse,
      );

  @override
  TruckColors lerp(TruckColors? other, double t) {
    if (other == null) return this;
    return TruckColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      reported: Color.lerp(reported, other.reported, t)!,
      inUse: Color.lerp(inUse, other.inUse, t)!,
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
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.s),
          child: Row(children: [
            Icon(icon, size: 20, color: accent ?? theme.colorScheme.primary),
            const SizedBox(width: Gap.s),
            Expanded(child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
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
  });

  final String title;
  final String? subtitle;

  /// Po terminie / pilne – kolor błędu; inaczej ostrzeżenie.
  final bool overdue;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = overdue ? Theme.of(context).colorScheme.error : TruckColors.of(context).warning;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon ?? (overdue ? Icons.error_outline : Icons.schedule), color: color),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(color: color)),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:flutter_gen/gen_l10n/admin_localizations.dart';
import 'package:intl/intl.dart';

export 'package:flutter_gen/gen_l10n/admin_localizations.dart';

/// Teksty programu w języku użytkownika: `context.l.sectionCompanies`.
extension L10nContext on BuildContext {
  AdminLocalizations get l => AdminLocalizations.of(this);
}

extension Formats on AdminLocalizations {
  /// Data i godzina w czasie lokalnym, np. "30.10.2026 12:00".
  String when(DateTime moment) =>
      '${DateFormat.yMd(localeName).format(moment.toLocal())} ${DateFormat.Hm(localeName).format(moment.toLocal())}';

  String adminRole(String? role) => role == 'full' ? roleFull : roleSupport;

  String scope(String scope) => switch (scope) {
        'company' => scopeCompany,
        'bases' => scopeBases,
        _ => scope,
      };

  /// Kody z serwera (role, rodzaje zgłoszeń, stany wydań) w języku użytkownika.
  String code(String code) => switch (code) {
        'owner' => roleOwner,
        'dispatcher' => roleDispatcher,
        'driver' => roleDriver,
        'gate' => kindGate,
        'ramp' => kindRamp,
        'office' => kindOffice,
        'waiting_area' => kindWaitingArea,
        'hours' => kindHours,
        'height_limit' => kindHeightLimit,
        'weight_limit' => kindWeightLimit,
        'no_trucks' => kindNoTrucks,
        'road_closed' => kindRoadClosed,
        'narrow' => kindNarrow,
        'other' => kindOther,
        'app' => releaseApp,
        'module' => releaseModule,
        'data' => releaseData,
        'active' => statusActive,
        'paused' => statusPaused,
        'withdrawn' => statusWithdrawn,
        _ => code,
      };
}

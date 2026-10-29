import 'package:flutter/widgets.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:intl/intl.dart';

export 'package:flutter_gen/gen_l10n/app_localizations.dart';

/// Teksty aplikacji w języku użytkownika: `context.l.menuRoute`.
extension L10nContext on BuildContext {
  AppLocalizations get l => AppLocalizations.of(this);
}

/// Liczby, daty i waluty według języka (separator dziesiętny, nazwy dni, symbol waluty).
extension Formats on AppLocalizations {
  /// Liczba bez zbędnych zer, np. "4,05" / "4.05", "40".
  String number(num value, {int decimals = 2}) => NumberFormat('0.${'#' * decimals}', localeName).format(value);

  /// Kilometry z jednym miejscem po przecinku, np. "12,3".
  String km(double value) => NumberFormat('0.0', localeName).format(value);

  /// Dzień tygodnia, data i godzina, np. "niedz. 1 lis 22:00" / "Sun, Nov 1 22:00".
  String when(DateTime moment) =>
      '${DateFormat.MMMEd(localeName).format(moment)} ${DateFormat.Hm(localeName).format(moment)}';

  /// Kwota szacunkowa: w walucie kraju języka z symbolem ("≈ 433 zł"), w innej – z kodem ("≈ 433 PLN").
  String money(double amount, String currency) {
    if (NumberFormat.simpleCurrency(locale: localeName).currencyName == currency) {
      return '≈ ${NumberFormat.simpleCurrency(locale: localeName, name: currency, decimalDigits: 0).format(amount)}';
    }
    return '≈ ${NumberFormat.decimalPattern(localeName).format(amount.round())} $currency';
  }

  /// Ocena trasy dla pojazdu.
  String level(String? level) => switch (level) {
        'green' => levelGreen,
        'lime' => levelLime,
        'yellow' => levelYellow,
        'orange' => levelOrange,
        'red' => levelRed,
        _ => noRating,
      };
}

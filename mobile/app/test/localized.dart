import 'package:flutter/material.dart';
import 'package:truckmaps_app/src/l10n.dart';

/// Aplikacja testowa z tłumaczeniami (domyślnie po polsku – teksty w testach są polskie).
Widget localized(Widget home, {Locale locale = const Locale('pl')}) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    );

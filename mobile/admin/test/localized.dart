import 'package:flutter/material.dart';
import 'package:truckmaps_admin/src/l10n.dart';

/// Program testowy z tłumaczeniami (domyślnie po polsku – teksty w testach są polskie).
Widget localized(Widget home, {Locale locale = const Locale('pl')}) => MaterialApp(
      locale: locale,
      supportedLocales: AdminLocalizations.supportedLocales,
      localizationsDelegates: AdminLocalizations.localizationsDelegates,
      home: home,
    );

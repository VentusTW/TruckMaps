import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';

/// Kraje z kalendarzem zakazów ruchu ciężarówek na serwerze.
const banCountries = ['PL', 'DE', 'CZ', 'SK', 'LT'];

/// Zakazy ruchu w kraju na najbliższe 30 dni: daty i godziny, których dróg dotyczą, kogo,
/// święta regionalne i wyjątki (`GET /api/timebans/{kraj}`).
class CountryBansScreen extends StatefulWidget {
  const CountryBansScreen({super.key, required this.api, this.country = 'PL', this.standalone = true});

  final CoreApi api;
  final String country;

  /// Osobny ekran (z planera) – z paskiem tytułu; w menu – bez.
  final bool standalone;

  @override
  State<CountryBansScreen> createState() => _CountryBansScreenState();
}

class _CountryBansScreenState extends State<CountryBansScreen> {
  late String _country = widget.country;
  late Future<dynamic> _bans = _load();

  Future<dynamic> _load() => widget.api.get('/api/timebans/$_country?days=30');

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final body = ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final country in banCountries)
          ChoiceChip(
            label: Text(country),
            selected: country == _country,
            onSelected: (_) => setState(() {
              _country = country;
              _bans = _load();
            }),
          ),
      ]),
      const SizedBox(height: 12),
      FutureBuilder<dynamic>(
        future: _bans,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${snapshot.error}'),
              TextButton(onPressed: () => setState(() => _bans = _load()), child: Text(l.retry)),
            ]);
          }
          if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
          final bans = snapshot.data;
          if (bans is! Map<String, dynamic> || bans['name'] is! String) return Text(l.bansUnknown);
          final days = (bans['days'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
          final regional = (bans['regional'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
          final dayFormat = DateFormat.MMMEd(l.localeName);
          String hour(String value) => DateFormat.Hm(l.localeName).format(DateTime.parse(value));
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.bansTitle(bans['name'] as String), style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(l.bansVehicles, style: theme.textTheme.labelLarge),
            Text(bans['vehicles'] as String),
            const SizedBox(height: 12),
            Text(l.bansNext30, style: theme.textTheme.titleSmall),
            if (bans['known'] != true) Text(l.bansUnknown) else if (days.isEmpty) Text(l.bansNone),
            for (final day in days)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Text('⛔', style: TextStyle(fontSize: 18)),
                title: Text(
                    '${dayFormat.format(DateTime.parse(day['day'] as String))} · ${hour(day['starts_at'] as String)}–${hour(day['ends_at'] as String)}'),
                subtitle: Text([
                  day['title'] as String,
                  day['roads'] as String,
                  if (day['verified'] != true) l.bansCheck,
                ].join(' · ')),
              ),
            if (regional.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l.bansRegional, style: theme.textTheme.titleSmall),
              for (final holiday in regional)
                Text(l.bansRegionalLine(dayFormat.format(DateTime.parse(holiday['day'] as String)),
                    holiday['name'] as String, (holiday['regions'] as List<dynamic>).join(', '))),
            ],
            const SizedBox(height: 12),
            Text(l.bansExceptions, style: theme.textTheme.titleSmall),
            Text(bans['exceptions'] as String),
            const SizedBox(height: 12),
            Text(l.bansHint, style: theme.textTheme.bodySmall),
          ]);
        },
      ),
    ]);
    return widget.standalone ? Scaffold(appBar: AppBar(title: Text(l.menuBans)), body: body) : body;
  }
}

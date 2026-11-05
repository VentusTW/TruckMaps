import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'texts.dart';

const _base = '/api/m/drivers';

/// Kategorie prawa jazdy w kolejności z serwera.
const licenseCategories = ['B', 'BE', 'C1', 'C1E', 'C', 'CE', 'D1', 'D1E', 'D', 'DE'];

/// Terminy kierowcy w formularzu (kolejność jak na karcie).
const driverDateFields = [
  'license_until',
  'code95_until',
  'medical_until',
  'psych_until',
  'card_until',
  'card_downloaded_on',
  'card_download_until',
  'adr_until',
  'attestation_until',
];

/// Rodzaje pojazdów, którym przydziela się kierowcę (bez naczep i przyczep).
const drivableKinds = {'combination', 'rigid', 'tractor', 'van', 'bus'};

const _managers = {'owner', 'dispatcher'};

InputDecoration _field(String label, {String? hint}) =>
    InputDecoration(labelText: label, helperText: hint, border: const OutlineInputBorder(), isDense: true);

DateTime? _day(Object? value) => value == null ? null : DateTime.tryParse('$value');

String _iso(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

Color _stateColor(ThemeData theme, String state) => switch (state) {
      'overdue' => theme.colorScheme.error,
      'soon' => (theme.extension<TruckColors>() ?? TruckColors.light).warning,
      _ => theme.colorScheme.primary,
    };

Widget _error(BuildContext context, Object? error, VoidCallback retry) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$error'),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: retry, child: Text(DriversTexts.of(context).retry)),
      ]),
    );

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Kartoteka kierowców (właściciel i dyspozytorzy) albo własna karta kierowcy.
class DriversScreen extends StatefulWidget {
  const DriversScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<DriversScreen> createState() => _DriversScreenState();
}

class _DriversScreenState extends State<DriversScreen> {
  late Future<List<dynamic>> _data = _load();

  Future<List<dynamic>> _load() => Future.wait([widget.api.get('$_base/drivers'), widget.api.get('/api/companies')]);

  void _reload() {
    final data = _load();
    setState(() {
      _data = data;
    });
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push<dynamic>(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    return FutureBuilder<List<dynamic>>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _error(context, snapshot.error, _reload);
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final drivers = (snapshot.data![0] as List<dynamic>).cast<Map<String, dynamic>>();
        final companies = (snapshot.data![1] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .where((c) => _managers.contains(c['role']))
            .toList();
        return Scaffold(
          body: drivers.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(companies.isEmpty ? t.noManagedCompany : t.empty),
                )
              : RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
                    for (final d in drivers) _tile(t, d),
                  ]),
                ),
          floatingActionButton: companies.isEmpty
              ? null
              : FloatingActionButton.extended(
                  key: const Key('drivers-add'),
                  onPressed: () => _push(DriverFormScreen(api: widget.api, companies: companies)),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text(t.add),
                ),
        );
      },
    );
  }

  Widget _tile(DriversTexts t, Map<String, dynamic> d) {
    final theme = Theme.of(context);
    final dues = (d['dues'] as List<dynamic>).cast<Map<String, dynamic>>();
    final overdue = dues.where((x) => x['state'] == 'overdue').length;
    final soon = dues.where((x) => x['state'] == 'soon').length;
    final vehicles = (d['vehicles'] as List<dynamic>).map((v) => '${(v as Map)['name']}').join(', ');
    final categories = (d['license_categories'] as List<dynamic>).join(', ');
    return Card(
      child: ListTile(
        leading: Icon(d['has_account'] == true ? Icons.person : Icons.person_outline),
        title: Text('${d['name']}'),
        subtitle: Text([
          if (categories.isNotEmpty) categories,
          if (vehicles.isNotEmpty) vehicles,
          if (overdue + soon > 0) t.dueSummary(overdue, soon),
        ].join('\n')),
        trailing: overdue + soon > 0
            ? Icon(Icons.warning_amber, color: _stateColor(theme, overdue > 0 ? 'overdue' : 'soon'))
            : null,
        onTap: () => _push(DriverScreen(api: widget.api, driverId: '${d['id']}')),
      ),
    );
  }
}

/// Karta kierowcy: dane, terminy, pojazdy; przejazdy; historia.
class DriverScreen extends StatefulWidget {
  const DriverScreen({super.key, required this.api, required this.driverId});

  final CoreApi api;
  final String driverId;

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  late Future<dynamic> _driver = _load();

  String get _url => '$_base/drivers/${widget.driverId}';

  Future<dynamic> _load() => widget.api.get(_url);

  void _reload() {
    final driver = _load();
    setState(() {
      _driver = driver;
    });
  }

  void _show(Map<String, dynamic> driver) {
    setState(() {
      _driver = Future.value(driver);
    });
  }

  Future<void> _edit(Map<String, dynamic> driver) async {
    final saved = await Navigator.of(context).push<dynamic>(MaterialPageRoute(
      builder: (_) => DriverFormScreen(api: widget.api, companies: const [], driver: driver),
    ));
    if (saved is Map<String, dynamic> && mounted) _show(saved);
  }

  Future<void> _delete() async {
    final t = DriversTexts.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.deleteTitle),
        content: Text(t.deleteHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.api.delete(_url);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) _snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    return FutureBuilder<dynamic>(
      future: _driver,
      builder: (context, snapshot) {
        final driver = snapshot.data as Map<String, dynamic>?;
        final canEdit = driver?['can_edit'] == true;
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(driver == null ? t.editTitle : '${driver['name']}'),
              actions: [
                if (canEdit) IconButton(key: const Key('driver-edit'), icon: const Icon(Icons.edit), onPressed: () => _edit(driver!)),
                if (canEdit) IconButton(key: const Key('driver-delete'), icon: const Icon(Icons.delete_outline), onPressed: _delete),
              ],
              bottom: TabBar(tabs: [Tab(text: t.tabCard), Tab(text: t.tabTrips), Tab(text: t.tabHistory)]),
            ),
            body: snapshot.hasError
                ? _error(context, snapshot.error, _reload)
                : driver == null
                    ? const Center(child: CircularProgressIndicator())
                    : TabBarView(children: [
                        _DriverCard(api: widget.api, driver: driver, onChanged: _show),
                        DriverStatsView(api: widget.api, driverId: widget.driverId),
                        DriverHistoryView(api: widget.api, driverId: widget.driverId),
                      ]),
          ),
        );
      },
    );
  }
}

class _DriverCard extends StatelessWidget {
  const _DriverCard({required this.api, required this.driver, required this.onChanged});

  final CoreApi api;
  final Map<String, dynamic> driver;
  final ValueChanged<Map<String, dynamic>> onChanged;

  String get _url => '$_base/drivers/${driver['id']}';

  Future<void> _cardDownload(BuildContext context) async {
    final t = DriversTexts.of(context);
    try {
      onChanged(await api.post('$_url/card-download', null) as Map<String, dynamic>);
      if (context.mounted) _snack(context, t.cardDownloaded);
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }

  Future<void> _release(BuildContext context, String vehicleId) async {
    try {
      onChanged(await api.post('$_url/release', {'vehicle_id': vehicleId}) as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }

  Future<void> _assign(BuildContext context) async {
    final t = DriversTexts.of(context);
    try {
      final all = (await api.get('/api/vehicles') as List<dynamic>).cast<Map<String, dynamic>>();
      final assigned = {for (final v in driver['vehicles'] as List<dynamic>) (v as Map)['vehicle_id']};
      final vehicles = all
          .where((v) =>
              v['company_id'] == driver['company_id'] && drivableKinds.contains(v['kind']) && !assigned.contains(v['id']))
          .toList();
      if (!context.mounted) return;
      final chosen = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(t.chooseVehicle),
          children: [
            if (vehicles.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(t.noCompanyVehicles)),
            for (final v in vehicles)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, v),
                child: ListTile(
                  title: Text('${v['name']}'),
                  subtitle: Text([
                    if (v['plate'] != null) '${v['plate']}',
                    if (v['assigned_driver_name'] != null) '${v['assigned_driver_name']}',
                  ].join(' · ')),
                ),
              ),
          ],
        ),
      );
      if (chosen == null || !context.mounted) return;
      final check = await api.get('$_url/check?vehicle_id=${chosen['id']}') as Map<String, dynamic>;
      final warnings = (check['warnings'] as List<dynamic>).cast<String>();
      if (warnings.isNotEmpty && context.mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t.warningsTitle),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (check['required_category'] != null) Text(t.needs('${check['required_category']}')),
              for (final w in warnings) Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $w')),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.assignAnyway)),
            ],
          ),
        );
        if (go != true) return;
      }
      final result = await api.post('$_url/assign', {'vehicle_id': chosen['id']}) as Map<String, dynamic>;
      onChanged(result['driver'] as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    final theme = Theme.of(context);
    final canEdit = driver['can_edit'] == true;
    final dues = {for (final d in (driver['dues'] as List<dynamic>).cast<Map<String, dynamic>>()) d['field']: d};
    final vehicles = (driver['vehicles'] as List<dynamic>).cast<Map<String, dynamic>>();
    String? text(String key) => '${driver[key] ?? ''}'.isEmpty ? null : '${driver[key]}';
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final (label, key) in [(t.phone, 'phone'), (t.email, 'email'), (t.notes, 'notes')])
        if (text(key) != null) ListTile(dense: true, title: Text(label), subtitle: Text(text(key)!)),
      if (_day(driver['hired_on']) != null)
        ListTile(dense: true, title: Text(t.hiredOn), subtitle: Text(t.date(_day(driver['hired_on'])!))),
      ListTile(
        dense: true,
        title: Text(t.account),
        subtitle: Text(driver['has_account'] == true ? '${driver['member_name']}' : t.noAccount),
      ),
      ListTile(
        dense: true,
        title: Text(t.categories),
        subtitle: Text((driver['license_categories'] as List<dynamic>).join(', ').isEmpty
            ? '–'
            : (driver['license_categories'] as List<dynamic>).join(', ')),
      ),
      const Divider(),
      Text(t.qualifications, style: theme.textTheme.titleMedium),
      for (final field in driverDateFields)
        if (_day(driver[field]) != null)
          ListTile(
            dense: true,
            title: Text(t.field(field)),
            subtitle: Text(t.date(_day(driver[field])!)),
            trailing: dues[field] == null
                ? null
                : Text(t.dueState('${dues[field]!['state']}'),
                    style: TextStyle(color: _stateColor(theme, '${dues[field]!['state']}'))),
          ),
      if (driver['adr_tank'] == true) ListTile(dense: true, title: Text(t.adrTank)),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const Key('driver-card-download'),
          onPressed: () => _cardDownload(context),
          icon: const Icon(Icons.sd_card_outlined),
          label: Text(t.cardDownload),
        ),
      ),
      const Divider(),
      Text(t.vehicles, style: theme.textTheme.titleMedium),
      if (vehicles.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.noVehicles)),
      for (final v in vehicles)
        ListTile(
          leading: const Icon(Icons.local_shipping_outlined),
          title: Text([v['name'], if (v['plate'] != null) v['plate']].join(' · ')),
          subtitle: Text(t.since(DateTime.parse('${v['since']}'))),
          trailing: canEdit
              ? TextButton(onPressed: () => _release(context, '${v['vehicle_id']}'), child: Text(t.release))
              : null,
        ),
      if (canEdit)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('driver-assign'),
            onPressed: () => _assign(context),
            icon: const Icon(Icons.add_link),
            label: Text(t.assign),
          ),
        ),
    ]);
  }
}

/// Dodanie albo zmiana karty kierowcy. Zwraca zapisaną kartę.
class DriverFormScreen extends StatefulWidget {
  const DriverFormScreen({super.key, required this.api, required this.companies, this.driver});

  final CoreApi api;

  /// Firmy, w których użytkownik prowadzi kartotekę (przy dodawaniu).
  final List<Map<String, dynamic>> companies;
  final Map<String, dynamic>? driver;

  @override
  State<DriverFormScreen> createState() => _DriverFormScreenState();
}

class _DriverFormScreenState extends State<DriverFormScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<String, dynamic> _d = widget.driver ?? {};
  late final _name = TextEditingController(text: '${_d['name'] ?? ''}');
  late final _phone = TextEditingController(text: '${_d['phone'] ?? ''}');
  late final _email = TextEditingController(text: '${_d['email'] ?? ''}');
  late final _notes = TextEditingController(text: '${_d['notes'] ?? ''}');
  late String? _company = _d['company_id'] as String? ??
      (widget.companies.isEmpty ? null : '${widget.companies.first['id']}');
  late String? _member = _d['member_id'] as String?;
  late final Set<String> _categories = {...(_d['license_categories'] as List<dynamic>? ?? []).cast<String>()};
  late bool _adrTank = _d['adr_tank'] == true;
  late final Map<String, DateTime?> _dates = {
    for (final f in [...driverDateFields, 'hired_on']) f: _day(_d[f]),
  };
  Future<List<dynamic>>? _candidates;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  void _loadCandidates() {
    if (_company == null) return;
    _candidates = widget.api.get('$_base/candidates?company_id=$_company').then((v) => v as List<dynamic>);
  }

  Future<void> _pickDate(String field) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dates[field] ?? now,
      firstDate: DateTime(now.year - 50),
      lastDate: DateTime(now.year + 20),
    );
    if (picked != null) {
      setState(() {
        _dates[field] = picked;
      });
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    String? text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final body = {
      'name': _name.text.trim(),
      'phone': text(_phone),
      'email': text(_email),
      'notes': text(_notes),
      'member_id': _member,
      'license_categories': [for (final c in licenseCategories) if (_categories.contains(c)) c],
      'adr_tank': _adrTank,
      for (final e in _dates.entries) e.key: e.value == null ? null : _iso(e.value!),
    };
    setState(() {
      _saving = true;
    });
    try {
      final saved = widget.driver == null
          ? await widget.api.post('$_base/drivers', {...body, 'company_id': _company})
          : await widget.api.put('$_base/drivers/${widget.driver!['id']}', body);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Widget _date(DriversTexts t, String field) {
    final value = _dates[field];
    final hint = t.fieldHint(field);
    return ListTile(
      key: Key('driver-date-$field'),
      contentPadding: EdgeInsets.zero,
      title: Text(field == 'hired_on' ? t.hiredOn : t.field(field)),
      subtitle: Text([value == null ? '–' : t.date(value), if (hint.isNotEmpty) hint].join(' · ')),
      onTap: () => _pickDate(field),
      trailing: value == null
          ? const Icon(Icons.event)
          : IconButton(
              tooltip: t.clear,
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() {
                _dates[field] = null;
              }),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.driver == null ? t.add : t.editTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (widget.driver == null && widget.companies.length > 1) ...[
            DropdownButtonFormField<String>(
              value: _company,
              decoration: _field(t.company),
              items: [
                for (final c in widget.companies) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')),
              ],
              onChanged: (value) => setState(() {
                _company = value;
                _member = null;
                _loadCandidates();
              }),
            ),
            const SizedBox(height: 12),
          ],
          TextFormField(
            key: const Key('driver-name'),
            controller: _name,
            decoration: _field(t.name),
            validator: (v) => (v ?? '').trim().length < 2 ? t.nameRequired : null,
          ),
          const SizedBox(height: 12),
          TextFormField(controller: _phone, decoration: _field(t.phone), keyboardType: TextInputType.phone),
          const SizedBox(height: 12),
          TextFormField(controller: _email, decoration: _field(t.email), keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 12),
          FutureBuilder<List<dynamic>>(
            future: _candidates,
            builder: (context, snapshot) {
              final candidates = (snapshot.data ?? []).cast<Map<String, dynamic>>();
              final items = [
                DropdownMenuItem<String?>(value: null, child: Text(t.noAccount)),
                if (_member != null && !candidates.any((c) => c['member_id'] == _member))
                  DropdownMenuItem<String?>(value: _member, child: Text('${_d['member_name'] ?? t.hasAccount}')),
                for (final c in candidates)
                  DropdownMenuItem<String?>(value: '${c['member_id']}', child: Text('${c['name']}')),
              ];
              return DropdownButtonFormField<String?>(
                key: const Key('driver-account'),
                value: _member,
                decoration: _field(t.account),
                items: items,
                onChanged: (value) => setState(() {
                  _member = value;
                }),
              );
            },
          ),
          const SizedBox(height: 12),
          _date(t, 'hired_on'),
          const SizedBox(height: 8),
          Text(t.categories, style: Theme.of(context).textTheme.titleSmall),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in licenseCategories)
              FilterChip(
                key: Key('driver-category-$c'),
                label: Text(c),
                selected: _categories.contains(c),
                onSelected: (on) => setState(() {
                  on ? _categories.add(c) : _categories.remove(c);
                }),
              ),
          ]),
          const SizedBox(height: 8),
          Text(t.qualifications, style: Theme.of(context).textTheme.titleSmall),
          for (final f in driverDateFields) _date(t, f),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.adrTank),
            value: _adrTank,
            onChanged: (v) => setState(() {
              _adrTank = v;
            }),
          ),
          const SizedBox(height: 12),
          TextFormField(controller: _notes, decoration: _field(t.notes), maxLines: 3),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('driver-save'),
            onPressed: _saving ? null : _save,
            child: Text(t.save),
          ),
        ]),
      ),
    );
  }
}

/// Przejazdy kierowcy: sumy, miesiące, pojazdy, ostatnie przejazdy.
class DriverStatsView extends StatefulWidget {
  const DriverStatsView({super.key, required this.api, required this.driverId});

  final CoreApi api;
  final String driverId;

  @override
  State<DriverStatsView> createState() => _DriverStatsViewState();
}

class _DriverStatsViewState extends State<DriverStatsView> {
  int _months = 12;
  late Future<dynamic> _stats = _load();

  Future<dynamic> _load() => widget.api.get('$_base/drivers/${widget.driverId}/stats?months=$_months');

  void _reload() {
    final stats = _load();
    setState(() {
      _stats = stats;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    final theme = Theme.of(context);
    return FutureBuilder<dynamic>(
      future: _stats,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _error(context, snapshot.error, _reload);
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final s = snapshot.data as Map<String, dynamic>;
        final months = (s['months'] as List<dynamic>).cast<Map<String, dynamic>>();
        final vehicles = (s['by_vehicle'] as List<dynamic>).cast<Map<String, dynamic>>();
        final recent = (s['recent'] as List<dynamic>).cast<Map<String, dynamic>>();
        Widget tile(String label, String value) => SizedBox(
              width: 150,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: theme.textTheme.bodySmall),
                    Text(value, style: theme.textTheme.titleMedium),
                  ]),
                ),
              ),
            );
        return ListView(padding: const EdgeInsets.all(16), children: [
          SegmentedButton<int>(
            segments: [for (final m in [3, 12, 36]) ButtonSegment(value: m, label: Text(t.months(m)))],
            selected: {_months},
            onSelectionChanged: (v) {
              _months = v.first;
              _reload();
            },
          ),
          const SizedBox(height: 12),
          if (s['trips'] == 0) Text(t.noTrips),
          if (s['trips'] != 0) ...[
            Wrap(spacing: 4, runSpacing: 4, children: [
              tile(t.trips, '${s['trips']}'),
              tile(t.distance, t.km(s['distance_km'] as num)),
              tile(t.hours, '${s['hours']}'),
              tile(t.emptyKm, t.km(s['empty_km'] as num)),
              tile(t.idleHours, '${s['idle_hours']}'),
              tile(t.vehiclesUsed, '${s['vehicles']}'),
            ]),
            const SizedBox(height: 12),
            Text(t.byMonth, style: theme.textTheme.titleMedium),
            for (final m in months)
              ListTile(
                dense: true,
                title: Text('${m['month']}'),
                subtitle: Text(t.tripLine(m['trips'] as int, m['distance_km'] as num, m['hours'] as num)),
              ),
            Text(t.byVehicle, style: theme.textTheme.titleMedium),
            for (final v in vehicles)
              ListTile(
                dense: true,
                title: Text('${v['name']}'),
                subtitle: Text('${v['trips']} · ${t.km(v['distance_km'] as num)}'),
              ),
            Text(t.recent, style: theme.textTheme.titleMedium),
            for (final r in recent)
              ListTile(
                dense: true,
                title: Text('${t.date(DateTime.parse('${r['started_at']}'))} · ${r['vehicle_name']}'),
                subtitle: Text([t.km(r['distance_km'] as num), if (r['loaded'] == false) t.emptyTrip].join(' · ')),
              ),
          ],
        ]);
      },
    );
  }
}

/// Historia przydziałów do pojazdów i zmian w kartotece.
class DriverHistoryView extends StatelessWidget {
  const DriverHistoryView({super.key, required this.api, required this.driverId});

  final CoreApi api;
  final String driverId;

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    final theme = Theme.of(context);
    final url = '$_base/drivers/$driverId';
    return FutureBuilder<List<dynamic>>(
      future: Future.wait([api.get('$url/assignments'), api.get('$url/history')]),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text('${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final assignments = (snapshot.data![0] as List<dynamic>).cast<Map<String, dynamic>>();
        final changes = (snapshot.data![1] as List<dynamic>).cast<Map<String, dynamic>>();
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text(t.assignments, style: theme.textTheme.titleMedium),
          if (assignments.isEmpty) Text(t.noHistory),
          for (final a in assignments)
            ListTile(
              dense: true,
              leading: Icon(a['ended_at'] == null ? Icons.link : Icons.link_off),
              title: Text('${a['vehicle_name']}'),
              subtitle: Text(t.period(DateTime.parse('${a['started_at']}'), _day(a['ended_at']))),
            ),
          const Divider(),
          Text(t.changes, style: theme.textTheme.titleMedium),
          if (changes.isEmpty) Text(t.noHistory),
          for (final c in changes)
            ListTile(
              dense: true,
              title: Text(t.action('${c['action']}')),
              subtitle: Text([
                t.by('${c['by_name']}', DateTime.parse('${c['at']}')),
                for (final e in (c['changes'] as Map<String, dynamic>).entries)
                  '${t.changeField(e.key)}: ${(e.value as List<dynamic>)[0] ?? '–'} → ${(e.value as List<dynamic>)[1] ?? '–'}',
              ].join('\n')),
            ),
        ]);
      },
    );
  }
}

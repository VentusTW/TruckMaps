import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import 'drivers_data.dart';

const _categories = ['B', 'C', 'C+E', 'D', 'D+E'];
const _dates = [
  'license_until',
  'code95_until',
  'medical_until',
  'psych_until',
  'card_until',
  'card_download_until',
  'adr_until',
  'hired_on',
];

/// Edycja profilu kierowcy według projektu Stitch. Pola kartoteki modułu Kierowcy zapisuje
/// `PUT /api/m/drivers/drivers/{id}`; pól, których kartoteka jeszcze nie ma (PESEL, adres,
/// kontakt ICE, umowa, załączniki…) – „W budowie”.
class DriverEditScreen extends StatefulWidget {
  const DriverEditScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.driverId,
    required this.onOpen,
    required this.onDone,
  });

  final CoreApi api;
  final String? companyId;
  final String driverId;
  final ValueChanged<String> onOpen;

  /// Po zapisie albo anulowaniu (`true` – zapisano).
  final ValueChanged<bool> onDone;

  @override
  State<DriverEditScreen> createState() => _DriverEditScreenState();
}

class _DriverEditScreenState extends State<DriverEditScreen> {
  DriversData? _data;
  Map<String, dynamic>? _driver;
  Object? _error;
  bool _saving = false;
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _notes = TextEditingController();
  final Map<String, DateTime?> _day = {};
  final Set<String> _cats = {};
  bool _adrTank = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_first, _last, _phone, _email, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final company = widget.companyId;
    if (company == null) return;
    try {
      final data = await DriversData.load(widget.api, company);
      final d = data.byId(widget.driverId);
      if (!mounted) return;
      setState(() {
        _data = data;
        _driver = d;
        if (d != null) _fill(d);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _fill(Map<String, dynamic> d) {
    final parts = '${d['name'] ?? ''}'.trim().split(RegExp(r'\s+'));
    _first.text = parts.isEmpty ? '' : parts.first;
    _last.text = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    _phone.text = '${d['phone'] ?? ''}';
    _email.text = '${d['email'] ?? ''}';
    _notes.text = '${d['notes'] ?? ''}';
    for (final f in _dates) {
      _day[f] = parseDay(d[f]);
    }
    _cats
      ..clear()
      ..addAll([for (final c in d['license_categories'] as List? ?? const []) '$c']);
    _adrTank = d['adr_tank'] == true;
  }

  bool get _editable => _data?.module == true && _driver?['can_edit'] != false;

  Future<void> _save({bool stay = false}) async {
    final l = context.l;
    final d = _driver;
    if (d == null) return;
    if (!_editable) return widget.onOpen(l.drvSave);
    final name = '${_first.text.trim()} ${_last.text.trim()}'.trim();
    if (_first.text.trim().isEmpty || _last.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.drvNameRequired)));
      return;
    }
    String? day(String f) => _day[f] == null ? null : DateFormat('yyyy-MM-dd').format(_day[f]!);
    String? text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    setState(() => _saving = true);
    try {
      await widget.api.put('/api/m/drivers/drivers/${Uri.encodeComponent(widget.driverId)}', {
        'name': name,
        'phone': text(_phone),
        'email': text(_email),
        'notes': text(_notes),
        'member_id': d['member_id'],
        'license_categories': [
          for (final c in _categories)
            if (_cats.contains(c)) c
        ],
        for (final f in _dates) f: day(f),
        'card_downloaded_on': d['card_downloaded_on'],
        'attestation_until': d['attestation_until'],
        'adr_tank': _adrTank,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.drvSaved)));
      if (!stay) widget.onDone(true);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final d = _driver;
    if (d == null) {
      if (_error != null) return Center(child: Text('$_error'));
      if (_data != null) return Center(child: UiEmpty(l.drvNotFound));
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: (context, size) {
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final wide = size.maxWidth - 2 * pad >= 900;
      return Column(children: [
        Expanded(
          child: ListView(padding: EdgeInsets.fromLTRB(pad, pad, pad, Gap.l), children: [
            _head(context, d),
            const SizedBox(height: 20),
            _tiles(context, d, wide),
            const SizedBox(height: 20),
            _personal(context, wide),
            const SizedBox(height: 20),
            _qualifications(context, wide),
            const SizedBox(height: 20),
            _tachograph(context, wide),
            const SizedBox(height: 20),
            _employment(context, d, wide),
            const SizedBox(height: 20),
            _files(context),
          ]),
        ),
        _footer(context, pad),
      ]);
    });
  }

  // ------------------------------------------------------------------ nagłówek

  Widget _head(BuildContext context, Map<String, dynamic> d) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final downloaded = parseDay(d['card_downloaded_on']);
    final data = _data!;
    return Wrap(
      spacing: Gap.l,
      runSpacing: Gap.m,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(spacing: Gap.m, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${d['name']}', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          UiTag(data.driving(d) ? l.drvActiveDriving : l.drvActive, tone: 'ok'),
          Text(l.drvId('${d['id']}'.split('-').first.toUpperCase()),
              style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
            decoration:
                BoxDecoration(color: colors.surfaceHigh, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.sync_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: Gap.s),
              Text(l.drvLastSync(downloaded == null ? '–' : DateFormat.yMd(l.localeName).format(downloaded)),
                  style: theme.textTheme.labelMedium),
            ]),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                backgroundColor: colors.card,
                foregroundColor: scheme.onSurface,
                side: BorderSide(color: colors.surfaceHigh)),
            onPressed: () => widget.onOpen(l.drvChanges),
            icon: const Icon(Icons.history_outlined, size: 18),
            label: Text(l.drvChanges),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
            onPressed: () => widget.onOpen(l.drvRoadCard),
            icon: const Icon(Icons.badge_outlined, size: 18),
            label: Text(l.drvRoadCard),
          ),
        ]),
      ],
    );
  }

  Widget _tiles(BuildContext context, Map<String, dynamic> d, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final format = DateFormat.yMd(l.localeName);
    final today = DateTime.now();
    final vehicle = _data!.vehicleOf(d);
    final download = parseDay(d['card_download_until']);
    final medical = parseDay(d['medical_until']);
    final psych = parseDay(d['psych_until']);
    final healthOk = medical != null && psych != null && medical.isAfter(today) && psych.isAfter(today);
    Widget tile(String label, String value, String note, IconData icon, {Color? iconColor, Widget? noteWidget}) =>
        UiPanel(
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.5)),
                const SizedBox(height: Gap.xs),
                Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                noteWidget ?? Text(note, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
            IconSquare(icon: icon, size: 36, color: iconColor),
          ]),
        );
    String day(String f) => parseDay(d[f]) == null ? '–' : format.format(parseDay(d[f])!);
    final tiles = [
      tile(l.drvCode95, day('code95_until'), healthOk ? l.drvHealthOk : l.drvHealthCheck, Icons.verified_user_outlined,
          iconColor: healthOk ? scheme.tertiaryContainer : scheme.error),
      tile(
          l.drvCard,
          day('card_until'),
          download == null
              ? '–'
              : l.drvRemoteRead(l.number(download.difference(DateTime(today.year, today.month, today.day)).inDays)),
          Icons.sim_card_outlined),
      tile(l.drvTractorTile, '${vehicle?['plate'] ?? vehicle?['name'] ?? '–'}', '${vehicle?['name'] ?? ''}',
          Icons.local_shipping_outlined),
      tile(l.drvDelegation, '–', '', Icons.event_outlined,
          noteWidget: WipTag(what: l.drvDelegation, onOpen: widget.onOpen)),
    ];
    if (!wide) {
      return Column(children: [for (final t in tiles) Padding(padding: const EdgeInsets.only(bottom: 12), child: t)]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (i, t) in tiles.indexed) ...[if (i > 0) const SizedBox(width: 20), Expanded(child: t)],
    ]);
  }

  // ------------------------------------------------------------------ sekcje

  Widget _section(BuildContext context, int n, String title, String subtitle, IconData icon, List<Widget> children,
      {Widget? badge}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
                color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Icon(icon, size: 18, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$n. $title', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          if (badge != null) badge,
        ]),
        const SizedBox(height: 20),
        ...children,
      ]),
    );
  }

  /// Pola w rzędach: na komputerze po [columns] w rzędzie.
  Widget _grid(bool wide, List<Widget> fields, {int columns = 3}) {
    final n = wide ? columns : 1;
    final rows = <Widget>[];
    for (var i = 0; i < fields.length; i += n) {
      final chunk = fields.sublist(i, (i + n).clamp(0, fields.length));
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (j, f) in chunk.indexed) ...[if (j > 0) const SizedBox(width: Gap.l), Expanded(child: f)],
          for (var k = chunk.length; k < n; k++) ...[const SizedBox(width: Gap.l), const Expanded(child: SizedBox())],
        ]),
      ));
    }
    return Column(children: rows);
  }

  Widget _label(BuildContext context, String text, {bool required = false}) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Text('${text.toUpperCase()}${required ? ' *' : ''}',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 0.4)),
      );

  Widget _text(BuildContext context, String label, TextEditingController c,
          {bool required = false, IconData? icon, int lines = 1, Key? key}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(context, label, required: required),
        TextField(
          key: key,
          controller: c,
          enabled: _editable,
          minLines: lines,
          maxLines: lines,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(isDense: true, suffixIcon: icon == null ? null : Icon(icon, size: 18)),
        ),
      ]);

  /// Pole, którego kartoteka jeszcze nie ma – wyłączone, ze znacznikiem „W budowie”.
  Widget _wip(BuildContext context, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(context, label),
        InputDecorator(
          isEmpty: true,
          decoration: const InputDecoration(isDense: true, enabled: false),
          child: Align(alignment: Alignment.centerLeft, child: WipTag(what: label, onOpen: widget.onOpen)),
        ),
      ]);

  Widget _date(BuildContext context, String label, String field, {bool required = false}) {
    final l = context.l;
    final value = _day[field];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(context, label, required: required),
      InkWell(
        key: Key('drv-date-$field'),
        onTap: !_editable
            ? null
            : () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(1950),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _day[field] = picked);
              },
        child: InputDecorator(
          isEmpty: value == null,
          decoration: InputDecoration(
            isDense: true,
            enabled: _editable,
            suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
          ),
          child: Text(value == null ? '' : DateFormat.yMd(l.localeName).format(value),
              style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    ]);
  }

  Widget _personal(BuildContext context, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final photo = Container(
      width: wide ? 200 : double.infinity,
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(children: [
        Container(
          width: 96,
          height: 96,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Text(initials('${_first.text} ${_last.text}'),
              style: theme.textTheme.headlineSmall?.copyWith(color: scheme.onPrimaryContainer)),
        ),
        const SizedBox(height: Gap.s),
        Text(l.drvPhoto, style: theme.textTheme.labelMedium),
        const SizedBox(height: Gap.xs),
        WipTag(what: l.drvPhoto, onOpen: widget.onOpen),
      ]),
    );
    final fields = _grid(wide, [
      _text(context, l.drvFirstName, _first, required: true, key: const Key('drv-first')),
      _text(context, l.drvLastName, _last, required: true, key: const Key('drv-last')),
      _wip(context, l.drvCitizenship),
      _wip(context, l.drvPesel),
      _wip(context, l.drvBirth),
      _text(context, l.drvWorkPhone, _phone, required: true, icon: Icons.call_outlined, key: const Key('drv-phone')),
      _text(context, l.drvEmail, _email, key: const Key('drv-email')),
      _wip(context, l.drvLanguages),
      _wip(context, l.drvAddress),
    ]);
    return _section(
      context,
      1,
      l.drvSecPersonal,
      l.drvSecPersonalSub,
      Icons.person_outline,
      badge: UiTag(l.drvMainRecord, tone: 'info'),
      [
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            photo,
            const SizedBox(width: 20),
            Expanded(child: fields),
          ])
        else ...[
          photo,
          const SizedBox(height: Gap.l),
          fields,
        ],
        const SizedBox(height: Gap.s),
        Container(
          padding: const EdgeInsets.all(Gap.l),
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.medical_services_outlined, size: 16, color: scheme.error),
              const SizedBox(width: Gap.s),
              Text(l.drvIceTitle.toUpperCase(), style: theme.textTheme.labelMedium?.copyWith(color: scheme.error)),
            ]),
            const SizedBox(height: Gap.m),
            _grid(wide, [_wip(context, l.drvIceName), _wip(context, l.drvIceRelation), _wip(context, l.drvIcePhone)]),
          ]),
        ),
      ],
    );
  }

  Widget _qualifications(BuildContext context, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final categories = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(context, l.drvCategories),
      Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
        for (final c in _categories)
          InkWell(
            key: Key('drv-cat-$c'),
            onTap: !_editable ? null : () => setState(() => _cats.contains(c) ? _cats.remove(c) : _cats.add(c)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 6),
              decoration: BoxDecoration(
                color: _cats.contains(c) ? scheme.primaryContainer : colors.surfaceLow,
                borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
              ),
              child: Text(c,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: _cats.contains(c) ? scheme.onPrimaryContainer : scheme.outline)),
            ),
          ),
      ]),
    ]);
    final adrType = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(context, l.drvAdrCert),
      DropdownButtonFormField<bool>(
        key: const Key('drv-adr-tank'),
        value: _adrTank,
        isDense: true,
        style: theme.textTheme.bodyMedium,
        decoration: const InputDecoration(isDense: true),
        items: [
          DropdownMenuItem(value: false, child: Text(l.drvAdrBasic)),
          DropdownMenuItem(value: true, child: Text(l.drvAdrTank)),
        ],
        onChanged: !_editable ? null : (v) => setState(() => _adrTank = v ?? false),
      ),
    ]);
    return _section(
      context,
      2,
      l.drvSecQual,
      l.drvSecQualSub,
      Icons.verified_outlined,
      badge: WipTag(what: l.drvCepik, onOpen: widget.onOpen),
      [
        _grid(
            wide,
            [
              _wip(context, l.drvLicenseNo),
              categories,
              _date(context, l.drvLicenseUntil, 'license_until'),
              _wip(context, l.drvLicenseCountry),
            ],
            columns: 4),
        Container(
          padding: const EdgeInsets.all(Gap.l),
          margin: const EdgeInsets.only(bottom: Gap.m),
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.drvCode95Box, style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
            const SizedBox(height: Gap.m),
            _grid(wide, [
              _date(context, l.drvCode95Until2, 'code95_until'),
              _date(context, l.driverFieldMedical, 'medical_until'),
              _date(context, l.driverFieldPsych, 'psych_until'),
            ]),
          ]),
        ),
        _grid(wide, [adrType, _wip(context, l.drvAdrNo), _date(context, l.drvAdrUntil, 'adr_until')]),
      ],
    );
  }

  Widget _tachograph(BuildContext context, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    return _section(
      context,
      3,
      l.drvSecTacho,
      l.drvSecTachoSub,
      Icons.credit_card_outlined,
      [
        _grid(wide, [
          _wip(context, l.drvCardNo),
          _date(context, l.drvCardUntil2, 'card_until', required: true),
          _wip(context, l.drvCardCountry),
          _date(context, l.drvNextRead, 'card_download_until'),
          _wip(context, l.drvReader),
          _wip(context, l.drvCrew),
        ]),
        Container(
          padding: const EdgeInsets.all(Gap.l),
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Row(children: [
            Icon(Icons.timer_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: Gap.s),
            Expanded(child: Text(l.drvWorkTime, style: theme.textTheme.labelLarge)),
            WipTag(what: l.drvWorkTime, onOpen: widget.onOpen),
          ]),
        ),
      ],
    );
  }

  Widget _employment(BuildContext context, Map<String, dynamic> d, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final vehicle = _data!.vehicleOf(d);
    return _section(
      context,
      4,
      l.drvSecJob,
      l.drvSecJobSub,
      Icons.work_outline,
      [
        _grid(wide, [
          _wip(context, l.drvContract),
          _wip(context, l.drvBase),
          _wip(context, l.drvRotation),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label(context, l.drvTractorTile),
            InputDecorator(
              decoration: const InputDecoration(isDense: true, enabled: false),
              child: Text(vehicle == null ? '–' : '${vehicle['plate'] ?? ''} (${vehicle['name']})',
                  style: theme.textTheme.bodyMedium),
            ),
          ]),
          _date(context, l.drvHired, 'hired_on'),
          _wip(context, l.drvSalary),
        ]),
        _text(context, l.drvNotes, _notes, lines: 3, key: const Key('drv-notes')),
        const SizedBox(height: Gap.m),
        UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: Gap.s),
            Expanded(child: Text(l.drvMobilityNote, style: theme.textTheme.bodySmall)),
          ]),
        ),
      ],
    );
  }

  Widget _files(BuildContext context) {
    final l = context.l;
    return _section(
      context,
      5,
      l.drvSecFiles,
      l.drvSecFilesSub,
      Icons.folder_outlined,
      badge: WipTag(what: l.drvSecFiles, onOpen: widget.onOpen),
      [UiEmpty(l.drvFilesNone)],
    );
  }

  Widget _footer(BuildContext context, double pad) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: pad, vertical: Gap.m),
      decoration: BoxDecoration(color: colors.card, boxShadow: TruckTheme.softShadow),
      child: Wrap(
        spacing: Gap.m,
        runSpacing: Gap.s,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: _editable ? scheme.tertiaryContainer : scheme.outline, shape: BoxShape.circle)),
            const SizedBox(width: Gap.s),
            Text(_editable ? l.drvFormOk : l.drvNoModule, style: theme.textTheme.bodySmall),
          ]),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            OutlinedButton(
              key: const Key('drv-cancel'),
              style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
              onPressed: () => widget.onDone(false),
              child: Text(l.drvCancel),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
              onPressed: () => _save(stay: true),
              icon: const Icon(Icons.drafts_outlined, size: 18),
              label: Text(l.drvDraft),
            ),
            FilledButton.icon(
              key: const Key('drv-save'),
              style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(l.drvSave),
            ),
          ]),
        ],
      ),
    );
  }
}

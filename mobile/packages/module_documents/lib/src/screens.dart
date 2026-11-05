import 'dart:convert';
import 'dart:typed_data';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'texts.dart';

const _base = '/api/m/documents';
const _managers = {'owner', 'dispatcher'};

/// Otwiera adres w przeglądarce systemu (PDF pod krótkim linkiem z serwera).
typedef LinkOpener = Future<bool> Function(Uri link);

/// Obraz logo (`null` – anulowano).
typedef ImagePickerFn = Future<Uint8List?> Function();

Future<bool> openLink(Uri link) => launchUrl(link, mode: LaunchMode.externalApplication);

Future<Uint8List?> pickLogo() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, maxHeight: 1600);
  return file?.readAsBytes();
}

List<Map<String, dynamic>> _list(dynamic data) => (data as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

Widget _error(BuildContext context, Object? error, VoidCallback retry) => Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$error', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: retry, child: Text(DocumentsTexts.of(context).retry)),
        ]),
      ),
    );

String _day(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

/// Wybór rodzaju dokumentu (`null` – anulowano).
Future<String?> chooseKind(BuildContext context, CoreApi api) async {
  final kinds = _list(await api.get('$_base/kinds'));
  if (!context.mounted) return null;
  final t = DocumentsTexts.of(context);
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(title: Text(t.chooseKind, style: Theme.of(context).textTheme.titleMedium)),
        for (final k in kinds)
          ListTile(
            key: Key('kind-${k['id']}'),
            leading: const Icon(Icons.description_outlined),
            title: Text('${k['name']}'),
            onTap: () => Navigator.of(context).pop('${k['id']}'),
          ),
      ]),
    ),
  );
}

/// Dokumenty firmy: lista, nowy dokument, dane firmy i wzory (właściciel, dyspozytorzy).
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, required this.api, this.linkOpener = openLink, this.imagePicker = pickLogo});

  final CoreApi api;
  final LinkOpener linkOpener;
  final ImagePickerFn imagePicker;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  late Future<List<Map<String, dynamic>>> _companies = _loadCompanies();
  Future<List<Map<String, dynamic>>>? _documents;
  Map<String, String> _kindNames = {};
  String? _companyId;

  Future<List<Map<String, dynamic>>> _loadCompanies() async {
    final results = await Future.wait([widget.api.get('/api/companies'), widget.api.get('$_base/kinds')]);
    _kindNames = {for (final k in _list(results[1])) '${k['id']}': '${k['name']}'};
    final companies = _list(results[0]);
    _companyId ??= companies.isEmpty ? null : '${companies.first['id']}';
    if (_companyId != null) _documents = _loadDocuments();
    return companies;
  }

  Future<List<Map<String, dynamic>>> _loadDocuments() async =>
      _list(await widget.api.get('$_base/documents?company_id=${Uri.encodeQueryComponent(_companyId!)}'));

  void _reload() {
    final documents = _loadDocuments();
    setState(() {
      _documents = documents;
    });
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push<dynamic>(MaterialPageRoute(builder: (_) => screen));
    if (mounted && _companyId != null) _reload();
  }

  Future<void> _new() async {
    final kind = await chooseKind(context, widget.api);
    if (kind == null || !mounted) return;
    await _push(DocumentFormScreen(api: widget.api, companyId: _companyId!, kind: kind, linkOpener: widget.linkOpener));
  }

  Future<void> _templates() async {
    final kind = await chooseKind(context, widget.api);
    if (kind == null || !mounted) return;
    await _push(TemplateScreen(api: widget.api, companyId: _companyId!, kind: kind));
  }

  @override
  Widget build(BuildContext context) {
    final t = DocumentsTexts.of(context);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _companies,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _error(context, snapshot.error, () => setState(() => _companies = _loadCompanies()));
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final companies = snapshot.data!;
        if (companies.isEmpty) return Padding(padding: const EdgeInsets.all(16), child: Text(t.noCompany));
        final company = companies.firstWhere((c) => '${c['id']}' == _companyId, orElse: () => companies.first);
        final manager = _managers.contains(company['role']);
        return Scaffold(
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            if (companies.length > 1)
              DropdownButtonFormField<String>(
                value: _companyId,
                decoration: InputDecoration(labelText: t.company),
                items: [
                  for (final c in companies) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}')),
                ],
                onChanged: (id) {
                  _companyId = id;
                  _reload();
                },
              ),
            if (manager)
              Wrap(spacing: 8, children: [
                TextButton.icon(
                  key: const Key('documents-profile'),
                  onPressed: () => _push(
                      CompanyProfileScreen(api: widget.api, companyId: _companyId!, imagePicker: widget.imagePicker)),
                  icon: const Icon(Icons.business_outlined),
                  label: Text(t.profile),
                ),
                TextButton.icon(
                  key: const Key('documents-templates'),
                  onPressed: _templates,
                  icon: const Icon(Icons.tune),
                  label: Text(t.templates),
                ),
              ]),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _documents,
              builder: (context, docs) {
                if (docs.hasError) return _error(context, docs.error, _reload);
                if (!docs.hasData) return const LinearProgressIndicator();
                if (docs.data!.isEmpty) {
                  return Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(t.empty));
                }
                return Column(children: [
                  for (final d in docs.data!)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text('${d['number']}'),
                        subtitle: Text([
                          _kindNames['${d['kind']}'] ?? '${d['kind']}',
                          '${d['created_by_name']}',
                          if (DateTime.tryParse('${d['created_at']}') case final at?) _day(at.toLocal()),
                        ].join(' · ')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _push(DocumentFormScreen(
                          api: widget.api,
                          companyId: _companyId!,
                          kind: '${d['kind']}',
                          document: d,
                          linkOpener: widget.linkOpener,
                        )),
                      ),
                    ),
                ]);
              },
            ),
          ]),
          floatingActionButton: FloatingActionButton.extended(
            key: const Key('documents-add'),
            onPressed: _new,
            icon: const Icon(Icons.note_add_outlined),
            label: Text(t.add),
          ),
        );
      },
    );
  }
}

/// Formularz dokumentu: pola wg wzoru firmy, podpowiedzi z danych systemu, zapis, PDF.
class DocumentFormScreen extends StatefulWidget {
  const DocumentFormScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.kind,
    this.document,
    this.vehicleId,
    this.linkOpener = openLink,
  });

  final CoreApi api;
  final String companyId;
  final String kind;

  /// Zapisany dokument (poprawka); `null` – nowy.
  final Map<String, dynamic>? document;
  final String? vehicleId;
  final LinkOpener linkOpener;

  @override
  State<DocumentFormScreen> createState() => _DocumentFormScreenState();
}

class _DocumentFormScreenState extends State<DocumentFormScreen> {
  late final Future<void> _ready = _load();
  List<Map<String, dynamic>> _fields = [];
  List<Map<String, dynamic>> _vehicles = [];
  final _text = <String, TextEditingController>{};
  final _rows = <String, List<Map<String, TextEditingController>>>{};
  Map<String, String> _sources = {};
  List<String> _warnings = [];
  Map<String, dynamic>? _document;
  String? _vehicleId;
  DateTime _from = DateTime.now();
  DateTime _to = DateTime.now();
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _document = widget.document;
    _vehicleId = widget.document?['vehicle_id'] as String? ?? widget.vehicleId;
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    for (final rows in _rows.values) {
      for (final row in rows) {
        for (final c in row.values) {
          c.dispose();
        }
      }
    }
    super.dispose();
  }

  String get _company => Uri.encodeQueryComponent(widget.companyId);

  Future<void> _load() async {
    final results = await Future.wait([
      widget.api.get('$_base/templates/${widget.kind}?company_id=$_company'),
      widget.api.get('/api/vehicles'),
    ]);
    final template = results[0] as Map<String, dynamic>;
    _fields = _list(template['fields']);
    _vehicles = [
      for (final v in _list(results[1]))
        if (v['company_id'] == widget.companyId) v,
    ];
    final data = (_document?['data'] as Map<String, dynamic>?) ?? const {};
    for (final f in _fields) {
      final key = '${f['key']}';
      if (f['type'] == 'rows') {
        _rows[key] = [for (final row in _list(data[key])) _rowControllers(f, row)];
      } else {
        _text[key] = TextEditingController(text: data[key] == null ? '' : '${data[key]}');
      }
    }
    if (_document == null && _vehicleId != null) await _fill(quiet: true);
  }

  Map<String, TextEditingController> _rowControllers(Map<String, dynamic> field, Map<String, dynamic> row) => {
        for (final c in _list(field['columns'])) '${c['key']}': TextEditingController(text: '${row[c['key']] ?? ''}'),
      };

  Map<String, dynamic> _data() {
    final data = <String, dynamic>{};
    _text.forEach((key, c) {
      if (c.text.trim().isNotEmpty) data[key] = c.text.trim();
    });
    _rows.forEach((key, rows) {
      final values = [
        for (final row in rows)
          {
            for (final e in row.entries)
              if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
          },
      ].where((row) => row.isNotEmpty).toList();
      if (values.isNotEmpty) data[key] = values;
    });
    return data;
  }

  Future<void> _fill({bool quiet = false}) async {
    final t = DocumentsTexts.of(context);
    setState(() => _busy = true);
    try {
      final result = await widget.api.post('$_base/prefill', {
        'kind': widget.kind,
        'company_id': widget.companyId,
        if (_vehicleId != null) 'vehicle_id': _vehicleId,
        if (widget.kind == 'road_card') ...{'date_from': _day(_from), 'date_to': _day(_to)},
      }) as Map<String, dynamic>;
      final data = result['data'] as Map<String, dynamic>;
      setState(() {
        for (final f in _fields) {
          final key = '${f['key']}';
          if (!data.containsKey(key)) continue;
          if (f['type'] == 'rows') {
            _rows[key] = [for (final row in _list(data[key])) _rowControllers(f, row)];
          } else {
            _text[key]?.text = '${data[key]}';
          }
        }
        _sources = (result['sources'] as Map<String, dynamic>).map((k, v) => MapEntry(k, '$v'));
        _warnings = (result['warnings'] as List<dynamic>).map((w) => '$w').toList();
        _message = quiet ? null : t.filled;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final t = DocumentsTexts.of(context);
    setState(() => _busy = true);
    try {
      final body = {'data': _data(), 'vehicle_id': _vehicleId};
      final saved = _document == null
          ? await widget.api.post('$_base/documents', {...body, 'kind': widget.kind, 'company_id': widget.companyId})
          : await widget.api.put('$_base/documents/${_document!['id']}', body);
      setState(() {
        _document = saved as Map<String, dynamic>;
        _message = t.saved;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pdf() async {
    final t = DocumentsTexts.of(context);
    try {
      final link = await widget.api.post('$_base/documents/${_document!['id']}/link', {}) as Map<String, dynamic>;
      final opened = await widget.linkOpener(widget.api.uri('${link['path']}'));
      if (!opened && mounted) setState(() => _message = t.pdfFailed);
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    }
  }

  Future<void> _delete() async {
    final t = DocumentsTexts.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.deleteTitle),
        content: Text('${_document!['number']}'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.delete)),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await widget.api.delete('$_base/documents/${_document!['id']}');
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    }
  }

  Future<void> _pickDay(TextEditingController controller) async {
    final current = DateTime.tryParse(controller.text) ?? DateTime.now();
    final day = await showDatePicker(
        context: context, initialDate: current, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (day != null) controller.text = _day(day);
  }

  Widget _field(DocumentsTexts t, Map<String, dynamic> f) {
    final key = '${f['key']}';
    final type = '${f['type']}';
    final source = _sources[key];
    final helper = source == null ? null : t.source(source);
    if (type == 'rows') return _table(t, f, helper);
    final controller = _text[key]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key('field-$key'),
        controller: controller,
        minLines: type == 'multiline' ? 2 : 1,
        maxLines: type == 'multiline' ? 6 : 1,
        keyboardType: type == 'number' ? const TextInputType.numberWithOptions(decimal: true) : null,
        decoration: InputDecoration(
          labelText: '${f['label']}',
          helperText: helper,
          suffixIcon: type == 'date'
              ? IconButton(tooltip: t.pickDate, icon: const Icon(Icons.event), onPressed: () => _pickDay(controller))
              : null,
        ),
      ),
    );
  }

  Widget _table(DocumentsTexts t, Map<String, dynamic> f, String? helper) {
    final key = '${f['key']}';
    final rows = _rows[key]!;
    final columns = _list(f['columns']);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${f['label']}', style: Theme.of(context).textTheme.titleSmall),
          if (helper != null) Text(helper, style: Theme.of(context).textTheme.bodySmall),
          for (final (i, row) in rows.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final c in columns)
                      SizedBox(
                        width: 160,
                        child: TextField(
                          controller: row['${c['key']}'],
                          decoration: InputDecoration(labelText: '${c['label']}', isDense: true),
                        ),
                      ),
                  ]),
                ),
                IconButton(
                  tooltip: t.removeRow,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => rows.removeAt(i)),
                ),
              ]),
            ),
          TextButton.icon(
            key: Key('add-row-$key'),
            onPressed: () => setState(() => rows.add(_rowControllers(f, const {}))),
            icon: const Icon(Icons.add),
            label: Text(t.addRow),
          ),
        ]),
      ),
    );
  }

  Future<void> _pickPeriod(bool start) async {
    final day = await showDatePicker(
        context: context, initialDate: start ? _from : _to, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (day == null) return;
    setState(() {
      if (start) {
        _from = day;
        if (_to.isBefore(day)) _to = day;
      } else {
        _to = day;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = DocumentsTexts.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_document == null ? t.add : '${_document!['number']}'),
        actions: [
          if (_document != null) ...[
            IconButton(
                key: const Key('document-pdf'),
                tooltip: t.pdf,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: _pdf),
            IconButton(tooltip: t.delete, icon: const Icon(Icons.delete_outline), onPressed: _delete),
          ],
        ],
      ),
      body: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _error(context, snapshot.error, () => Navigator.of(context).pop());
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            DropdownButtonFormField<String?>(
              key: const Key('document-vehicle'),
              value: _vehicles.any((v) => v['id'] == _vehicleId) ? _vehicleId : null,
              decoration: InputDecoration(labelText: t.vehicle),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text(t.noVehicle)),
                for (final v in _vehicles)
                  DropdownMenuItem<String?>(
                    value: '${v['id']}',
                    child: Text([v['name'], if (v['plate'] != null) v['plate']].join(' · ')),
                  ),
              ],
              onChanged: (id) => setState(() => _vehicleId = id),
            ),
            if (widget.kind == 'road_card')
              Wrap(spacing: 8, children: [
                ActionChip(
                    avatar: const Icon(Icons.event, size: 18),
                    label: Text('${t.periodFrom}: ${_day(_from)}'),
                    onPressed: () => _pickPeriod(true)),
                ActionChip(
                    avatar: const Icon(Icons.event, size: 18),
                    label: Text('${t.periodTo}: ${_day(_to)}'),
                    onPressed: () => _pickPeriod(false)),
              ]),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('document-fill'),
                onPressed: _busy ? null : _fill,
                icon: const Icon(Icons.auto_fix_high),
                label: Text(t.fill),
              ),
            ),
            for (final w in _warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(w, style: TextStyle(color: TruckColors.of(context).warning)),
              ),
            if (_message != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_message!)),
            for (final f in _fields) _field(t, f),
          ]);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('document-save'),
        onPressed: _busy ? null : _save,
        icon: const Icon(Icons.save_outlined),
        label: Text(t.save),
      ),
    );
  }
}

/// Dane firmy do dokumentów (adres, licencja, polisa OCP…) i logo.
class CompanyProfileScreen extends StatefulWidget {
  const CompanyProfileScreen({super.key, required this.api, required this.companyId, this.imagePicker = pickLogo});

  final CoreApi api;
  final String companyId;
  final ImagePickerFn imagePicker;

  @override
  State<CompanyProfileScreen> createState() => _CompanyProfileScreenState();
}

class _CompanyProfileScreenState extends State<CompanyProfileScreen> {
  late final Future<void> _ready = _load();
  final _fields = {for (final key in DocumentsTexts.profileFields) key: TextEditingController()};
  Uint8List? _logo;
  String? _message;
  bool _busy = false;

  String get _path => '$_base/profile?company_id=${Uri.encodeQueryComponent(widget.companyId)}';

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map<String, dynamic> profile) {
    _fields.forEach((key, c) => c.text = '${profile[key] ?? ''}');
    final logo = profile['logo'];
    _logo = logo is String ? base64Decode(logo) : null;
  }

  Future<void> _load() async => _apply(await widget.api.get(_path) as Map<String, dynamic>);

  Future<void> _run(Future<dynamic> Function() request, {String? done}) async {
    setState(() => _busy = true);
    try {
      final profile = await request() as Map<String, dynamic>;
      setState(() {
        _apply(profile);
        _message = done;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickLogo() async {
    final bytes = await widget.imagePicker();
    if (bytes == null || !mounted) return;
    final logoPath = _path.replaceFirst('/profile?', '/profile/logo?');
    await _run(() => widget.api.put(logoPath, {'image': base64Encode(bytes)}));
  }

  @override
  Widget build(BuildContext context) {
    final t = DocumentsTexts.of(context);
    final logoPath = _path.replaceFirst('/profile?', '/profile/logo?');
    return Scaffold(
      appBar: AppBar(title: Text(t.profile)),
      body: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _error(context, snapshot.error, () => Navigator.of(context).pop());
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            SectionCard(
              title: t.logo,
              icon: Icons.image_outlined,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.logoHint, style: Theme.of(context).textTheme.bodySmall),
                if (_logo != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Image.memory(_logo!, key: const Key('profile-logo'), height: 64),
                  ),
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                    key: const Key('profile-logo-pick'),
                    onPressed: _busy ? null : _pickLogo,
                    icon: const Icon(Icons.upload_outlined),
                    label: Text(t.logoChange),
                  ),
                  if (_logo != null)
                    TextButton.icon(
                      onPressed: _busy ? null : () => _run(() => widget.api.delete(logoPath)),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(t.logoRemove),
                    ),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            if (_message != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_message!)),
            for (final e in _fields.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  key: Key('profile-${e.key}'),
                  controller: e.value,
                  decoration: InputDecoration(labelText: t.profileField(e.key)),
                ),
              ),
          ]);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('profile-save'),
        onPressed: _busy
            ? null
            : () => _run(() => widget.api.put(_path, {for (final e in _fields.entries) e.key: e.value.text.trim()}),
                done: t.saved),
        icon: const Icon(Icons.save_outlined),
        label: Text(t.save),
      ),
    );
  }
}

/// Wzór dokumentu firmy: nazwy pól, wartości domyślne, ukryte pola, pola firmy, warunki.
class TemplateScreen extends StatefulWidget {
  const TemplateScreen({super.key, required this.api, required this.companyId, required this.kind});

  final CoreApi api;
  final String companyId;
  final String kind;

  @override
  State<TemplateScreen> createState() => _TemplateScreenState();
}

class _TemplateScreenState extends State<TemplateScreen> {
  // Tytuł (nazwa rodzaju) w pasku – po wczytaniu.
  late final Future<void> _ready = _load().then((_) {
    if (mounted) setState(() {});
  });
  List<Map<String, dynamic>> _kindFields = [];
  String _title = '';
  Map<String, String> _labels = {};
  Map<String, String> _defaults = {};
  Set<String> _hidden = {};
  List<Map<String, dynamic>> _extra = [];
  final _terms = TextEditingController();
  String? _message;
  bool _busy = false;

  String get _path => '$_base/templates/${widget.kind}?company_id=${Uri.encodeQueryComponent(widget.companyId)}';

  @override
  void dispose() {
    _terms.dispose();
    super.dispose();
  }

  void _apply(Map<String, dynamic> template) {
    _labels = (template['labels'] as Map<String, dynamic>).map((k, v) => MapEntry(k, '$v'));
    _defaults = (template['defaults'] as Map<String, dynamic>).map((k, v) => MapEntry(k, '$v'));
    _hidden = {for (final h in template['hidden'] as List<dynamic>) '$h'};
    _extra = [for (final x in _list(template['extra_fields'])) Map<String, dynamic>.of(x)];
    _terms.text = '${template['terms'] ?? ''}';
  }

  Future<void> _load() async {
    final results = await Future.wait([widget.api.get('$_base/kinds'), widget.api.get(_path)]);
    final kind = _list(results[0]).firstWhere((k) => k['id'] == widget.kind);
    _title = '${kind['name']}';
    _kindFields = _list(kind['fields']);
    _apply(results[1] as Map<String, dynamic>);
  }

  Future<void> _save() async {
    final t = DocumentsTexts.of(context);
    setState(() => _busy = true);
    try {
      final saved = await widget.api.put(_path, {
        'labels': _labels,
        'defaults': _defaults,
        'hidden': _hidden.toList(),
        'extra_fields': _extra,
        'terms': _terms.text,
      }) as Map<String, dynamic>;
      setState(() {
        _apply(saved);
        _message = t.saved;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Okno pola: nazwa, wartość domyślna; pole firmy – także rodzaj i szerokość.
  Future<void> _edit({Map<String, dynamic>? base, Map<String, dynamic>? extra}) async {
    final t = DocumentsTexts.of(context);
    final key = '${(base ?? extra)?['key'] ?? ''}';
    final custom = base == null;
    final label = TextEditingController(text: custom ? '${extra?['label'] ?? ''}' : (_labels[key] ?? ''));
    final initial = TextEditingController(text: _defaults[key] ?? '');
    var type = '${extra?['type'] ?? 'text'}';
    var width = (extra?['width'] as num?)?.toDouble() ?? 1.0;
    final rows = base?['type'] == 'rows';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(custom ? (extra == null ? t.addField : t.editField) : '${base['label']}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                key: const Key('template-field-label'),
                controller: label,
                decoration: InputDecoration(labelText: t.fieldLabel, hintText: custom ? null : '${base['label']}'),
              ),
              if (!rows)
                TextField(
                  key: const Key('template-field-default'),
                  controller: initial,
                  decoration: InputDecoration(labelText: t.fieldDefault),
                ),
              if (custom) ...[
                DropdownButtonFormField<String>(
                  value: type,
                  decoration: InputDecoration(labelText: t.fieldType),
                  items: [
                    for (final v in ['text', 'multiline', 'number', 'date'])
                      DropdownMenuItem(value: v, child: Text(t.type(v))),
                  ],
                  onChanged: (v) => setDialog(() => type = v ?? type),
                ),
                DropdownButtonFormField<double>(
                  value: width,
                  decoration: InputDecoration(labelText: t.fieldWidth),
                  items: [
                    for (final v in [1.0, 0.5, 0.25]) DropdownMenuItem(value: v, child: Text(t.width(v))),
                  ],
                  onChanged: (v) => setDialog(() => width = v ?? width),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.cancel)),
            FilledButton(
              key: const Key('template-field-ok'),
              onPressed: () {
                if (custom && label.text.trim().isEmpty) return;
                Navigator.of(context).pop(true);
              },
              child: Text(t.save),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() {
      if (custom) {
        final field = {'key': key, 'label': label.text.trim(), 'type': type, 'width': width};
        if (extra == null) {
          _extra.add(field);
        } else {
          _extra[_extra.indexOf(extra)] = field;
        }
      } else if (label.text.trim().isEmpty) {
        _labels.remove(key);
      } else {
        _labels[key] = label.text.trim();
      }
      // Nowe pole firmy dostaje klucz na serwerze – wartość domyślną zapisujemy po nim.
      if (key.isNotEmpty) {
        if (initial.text.trim().isEmpty) {
          _defaults.remove(key);
        } else {
          _defaults[key] = initial.text.trim();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = DocumentsTexts.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_title.isEmpty ? t.templates : _title)),
      body: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _error(context, snapshot.error, () => Navigator.of(context).pop());
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            Text(t.templateHint, style: Theme.of(context).textTheme.bodySmall),
            if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
            const SizedBox(height: 8),
            SectionCard(
              title: t.templateFields,
              icon: Icons.list_alt,
              child: Column(children: [
                for (final f in _kindFields)
                  SwitchListTile(
                    key: Key('template-${f['key']}'),
                    contentPadding: EdgeInsets.zero,
                    value: !_hidden.contains(f['key']),
                    title: Text(_labels['${f['key']}'] ?? '${f['label']}'),
                    subtitle: Text([
                      if (_labels.containsKey(f['key'])) '${f['label']}',
                      if (_defaults['${f['key']}'] case final d?) '${t.fieldDefault}: $d',
                    ].join(' · ')),
                    secondary: IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(base: f)),
                    onChanged: (on) => setState(() => on ? _hidden.remove(f['key']) : _hidden.add('${f['key']}')),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: t.customFields,
              icon: Icons.playlist_add,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final x in _extra)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${x['label']}'),
                    subtitle: Text([
                      t.type('${x['type']}'),
                      t.width((x['width'] as num).toDouble()),
                      if (_defaults['${x['key']}'] case final d?) '${t.fieldDefault}: $d',
                    ].join(' · ')),
                    onTap: () => _edit(extra: x),
                    trailing: IconButton(
                      tooltip: t.delete,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => _extra.remove(x)),
                    ),
                  ),
                TextButton.icon(
                  key: const Key('template-add-field'),
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: Text(t.addField),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('template-terms'),
              controller: _terms,
              minLines: 3,
              maxLines: 10,
              decoration: InputDecoration(labelText: t.terms, alignLabelWithHint: true),
            ),
          ]);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('template-save'),
        onPressed: _busy ? null : _save,
        icon: const Icon(Icons.save_outlined),
        label: Text(t.save),
      ),
    );
  }
}

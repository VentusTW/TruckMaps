import 'dart:convert';
import 'dart:io';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';

/// Pole wpisu: tekst, liczba albo data (`yyyy-MM-dd`).
enum RecordFieldType { text, number, date }

class RecordField {
  const RecordField(this.key, this.label, {this.type = RecordFieldType.text, this.required = false});

  final String key;
  final String label;
  final RecordFieldType type;
  final bool required;
}

/// Wpisy przy kierowcy, pojeździe, zleceniu albo firmie (`/api/companies/{id}/records`).
class RecordsApi {
  const RecordsApi(this.api, this.companyId);

  final CoreApi api;
  final String companyId;

  String get _base => '/api/companies/${Uri.encodeComponent(companyId)}';

  Future<List<Map<String, dynamic>>> list({String? entityType, String? entityId, String? kind}) async {
    final query = Uri(queryParameters: {
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (kind != null) 'kind': kind,
    }).query;
    return (await api.get('$_base/records?$query') as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> add(String entityType, String entityId, String kind, Map<String, dynamic> data) async =>
      await api.post('$_base/records', {'entity_type': entityType, 'entity_id': entityId, 'kind': kind, 'data': data})
          as Map<String, dynamic>;

  Future<void> update(String id, Map<String, dynamic> data) => api.put('$_base/records/$id', {'data': data});

  Future<void> delete(String id) => api.delete('$_base/records/$id');

  Future<Map<String, dynamic>> settings() async => await api.get('$_base/settings') as Map<String, dynamic>;

  Future<void> putSetting(String key, Object? value) => api.put('$_base/settings/$key', value);

  Future<List<Map<String, dynamic>>> files(String entityType, String entityId) async =>
      (await api.get('$_base/files?entity_type=$entityType&entity_id=${Uri.encodeQueryComponent(entityId)}')
              as List<dynamic>)
          .cast<Map<String, dynamic>>();

  Future<void> addFile(String entityType, String entityId, String kind, String name, String type, List<int> bytes) =>
      api.post('$_base/files', {
        'entity_type': entityType,
        'entity_id': entityId,
        'kind': kind,
        'name': name,
        'content_type': type,
        'data': base64Encode(bytes),
      });

  Future<void> deleteFile(String id) => api.delete('$_base/files/$id');

  /// Plik z serwera do pliku tymczasowego i otwarcie w programie systemu.
  Future<bool> openFile(Map<String, dynamic> file) async {
    if (kIsWeb) return launchUrl(api.uri('$_base/files/${file['id']}'));
    final bytes = await api.getBytes('$_base/files/${file['id']}');
    final path = '${Directory.systemTemp.path}${Platform.pathSeparator}truckmaps-${file['id']}-${file['name']}';
    await File(path).writeAsBytes(bytes);
    return launchUrl(Uri.file(path));
  }
}

String _fmtDate(AppLocalizations l, dynamic v) {
  final d = v == null ? null : DateTime.tryParse('$v');
  return d == null ? '' : DateFormat.yMd(l.localeName).format(d);
}

/// Jedna linia opisu wpisu z wartości pól (daty po polsku).
String recordSummary(AppLocalizations l, List<RecordField> fields, Map<String, dynamic> data) => [
      for (final f in fields)
        if ('${data[f.key] ?? ''}'.isNotEmpty)
          f.type == RecordFieldType.date ? _fmtDate(l, data[f.key]) : '${data[f.key]}',
    ].join(' · ');

/// Formularz wpisu (dodanie albo zmiana); `null` – anulowano.
Future<Map<String, dynamic>?> editRecord(BuildContext context, String title, List<RecordField> fields,
    [Map<String, dynamic> initial = const {}]) async {
  final l = context.l;
  final controllers = {for (final f in fields) f.key: TextEditingController(text: '${initial[f.key] ?? ''}')};
  final form = GlobalKey<FormState>();
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final f in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextFormField(
                    key: Key('record-${f.key}'),
                    controller: controllers[f.key],
                    readOnly: f.type == RecordFieldType.date,
                    keyboardType: f.type == RecordFieldType.number ? TextInputType.number : null,
                    decoration: InputDecoration(
                      labelText: f.label,
                      border: const OutlineInputBorder(),
                      suffixIcon: f.type == RecordFieldType.date ? const Icon(Icons.event_outlined) : null,
                    ),
                    validator: (v) => f.required && (v ?? '').trim().isEmpty ? l.recordRequired : null,
                    onTap: f.type != RecordFieldType.date
                        ? null
                        : () async {
                            final current = DateTime.tryParse(controllers[f.key]!.text) ?? DateTime.now();
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: current,
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) controllers[f.key]!.text = DateFormat('yyyy-MM-dd').format(picked);
                          },
                  ),
                ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          key: const Key('record-save'),
          onPressed: () {
            if (!form.currentState!.validate()) return;
            Navigator.pop(context, {
              for (final f in fields)
                if (controllers[f.key]!.text.trim().isNotEmpty)
                  f.key: f.type == RecordFieldType.number
                      ? num.tryParse(controllers[f.key]!.text.trim().replaceAll(',', '.')) ??
                          controllers[f.key]!.text.trim()
                      : controllers[f.key]!.text.trim(),
            });
          },
          child: Text(l.save),
        ),
      ],
    ),
  );
  for (final c in controllers.values) {
    c.dispose();
  }
  return result;
}

/// Lista wpisów jednego rodzaju z dodawaniem, zmianą i usuwaniem (np. urlopy kierowcy,
/// opony pojazdu, części w magazynie). Bez firmy – informacja zamiast listy.
class RecordsList extends StatefulWidget {
  const RecordsList({
    super.key,
    required this.api,
    required this.companyId,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.title,
    required this.fields,
    this.empty,
    this.onChanged,
    this.dense = false,
  });

  final CoreApi api;
  final String? companyId;
  final String entityType;
  final String entityId;
  final String kind;
  final String title;
  final List<RecordField> fields;
  final String? empty;
  final ValueChanged<List<Map<String, dynamic>>>? onChanged;
  final bool dense;

  @override
  State<RecordsList> createState() => _RecordsListState();
}

class _RecordsListState extends State<RecordsList> {
  List<Map<String, dynamic>>? _items;
  String? _error;

  RecordsApi? get _records => widget.companyId == null ? null : RecordsApi(widget.api, widget.companyId!);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = _records;
    if (records == null) return;
    try {
      final items = await records.list(entityType: widget.entityType, entityId: widget.entityId, kind: widget.kind);
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
      widget.onChanged?.call(items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _edit([Map<String, dynamic>? item]) async {
    final records = _records;
    if (records == null) return;
    final data = await editRecord(context, widget.title, widget.fields, (item?['data'] as Map<String, dynamic>?) ?? {});
    if (data == null) return;
    try {
      if (item == null) {
        await records.add(widget.entityType, widget.entityId, widget.kind, data);
      } else {
        await records.update('${item['id']}', data);
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    try {
      await _records?.delete('${item['id']}');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    if (widget.companyId == null) {
      return Text(l.recordNeedsCompany, style: theme.textTheme.bodySmall);
    }
    final items = _items;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      if (items == null)
        const LinearProgressIndicator()
      else if (items.isEmpty)
        Text(widget.empty ?? l.recordEmpty, style: theme.textTheme.bodySmall)
      else
        for (final item in items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(recordSummary(l, widget.fields, (item['data'] as Map<String, dynamic>?) ?? {})),
            onTap: () => _edit(item),
            trailing: IconButton(
              tooltip: l.recordDelete,
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _delete(item),
            ),
          ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: Key('record-add-${widget.kind}'),
          onPressed: () => _edit(),
          icon: const Icon(Icons.add, size: 18),
          label: Text(l.recordAdd),
        ),
      ),
    ]);
  }
}

/// Zdjęcia i skany dokumentów przy kierowcy, pojeździe albo zleceniu.
class FilesList extends StatefulWidget {
  const FilesList({
    super.key,
    required this.api,
    required this.companyId,
    required this.entityType,
    required this.entityId,
    this.kind = 'document',
    this.picker,
  });

  final CoreApi api;
  final String? companyId;
  final String entityType;
  final String entityId;
  final String kind;

  /// Wybór pliku (testy podmieniają): nazwa, typ i zawartość; `null` – anulowano.
  final Future<(String, String, List<int>)?> Function()? picker;

  @override
  State<FilesList> createState() => _FilesListState();
}

Future<(String, String, List<int>)?> pickImageFile() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2400, imageQuality: 85);
  if (file == null) return null;
  final name = file.name;
  final lower = name.toLowerCase();
  final type = lower.endsWith('.png') ? 'image/png' : (lower.endsWith('.pdf') ? 'application/pdf' : 'image/jpeg');
  return (name, type, await file.readAsBytes());
}

class _FilesListState extends State<FilesList> {
  List<Map<String, dynamic>>? _files;
  String? _error;

  RecordsApi? get _records => widget.companyId == null ? null : RecordsApi(widget.api, widget.companyId!);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = _records;
    if (records == null) return;
    try {
      final files = await records.files(widget.entityType, widget.entityId);
      if (mounted) {
        setState(() => _files = [
              for (final f in files)
                if (f['kind'] == widget.kind) f
            ]);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _add() async {
    final records = _records;
    if (records == null) return;
    final picked = await (widget.picker ?? pickImageFile)();
    if (picked == null) return;
    final (name, type, bytes) = picked;
    try {
      await records.addFile(widget.entityType, widget.entityId, widget.kind, name, type, bytes);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    if (widget.companyId == null) return Text(l.recordNeedsCompany, style: theme.textTheme.bodySmall);
    final files = _files;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      if (files == null)
        const LinearProgressIndicator()
      else if (files.isEmpty)
        Text(l.filesEmpty, style: theme.textTheme.bodySmall)
      else
        for (final f in files)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading:
                Icon('${f['content_type']}'.startsWith('image/') ? Icons.image_outlined : Icons.description_outlined),
            title: Text('${f['name']}'),
            subtitle: Text('${((f['size'] as num) / 1024).ceil()} kB'),
            onTap: () => _records?.openFile(f),
            trailing: IconButton(
              tooltip: l.recordDelete,
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () async {
                await _records?.deleteFile('${f['id']}');
                await _load();
              },
            ),
          ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: Key('file-add-${widget.kind}'),
          onPressed: _add,
          icon: const Icon(Icons.upload_file_outlined, size: 18),
          label: Text(l.filesAdd),
        ),
      ),
    ]);
  }
}

/// Okno z listą wpisów (dla przycisków, które otwierają wpisy zamiast osobnego ekranu).
Future<void> showRecords(BuildContext context,
        {required CoreApi api,
        required String? companyId,
        required String entityType,
        required String entityId,
        required String kind,
        required String title,
        required List<RecordField> fields}) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: RecordsList(
              api: api,
              companyId: companyId,
              entityType: entityType,
              entityId: entityId,
              kind: kind,
              title: title,
              fields: fields,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).closeButtonLabel)),
        ],
      ),
    );

/// Okno z plikami (zdjęcie, skany).
Future<void> showFiles(BuildContext context,
        {required CoreApi api,
        required String? companyId,
        required String entityType,
        required String entityId,
        required String title,
        String kind = 'document'}) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: FilesList(api: api, companyId: companyId, entityType: entityType, entityId: entityId, kind: kind),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).closeButtonLabel)),
        ],
      ),
    );

/// Okno z jedną liczbą (np. liczba stanowisk, cel w godzinach, budżet); `null` – anulowano.
Future<num?> askNumber(BuildContext context, String title, {num? current, String? suffix}) async {
  final l = context.l;
  final controller = TextEditingController(text: current == null ? '' : '$current');
  final value = await showDialog<num>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('ask-number'),
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(border: const OutlineInputBorder(), suffixText: suffix),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: () => Navigator.pop(context, num.tryParse(controller.text.trim().replaceAll(',', '.'))),
          child: Text(l.save),
        ),
      ],
    ),
  );
  controller.dispose();
  return value;
}

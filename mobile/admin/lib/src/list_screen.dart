import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'company_dialog.dart';
import 'l10n.dart';
import 'sections.dart';

const pageSize = 50;

/// Lista z serwera z wyszukiwaniem, filtrami i stronami (`{"total": n, "items": [...]}`).
class ListScreen extends StatefulWidget {
  const ListScreen({super.key, required this.api, required this.section, this.fullAdmin = false, this.onRequested});

  final CoreApi api;
  final Section section;

  /// Pełny administrator może poprosić właściciela firmy o dostęp do zmian.
  final bool fullAdmin;
  final VoidCallback? onRequested;

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  final _search = TextEditingController();
  final _filters = <String, String>{};
  Timer? _debounce;
  int _offset = 0;
  late Future<dynamic> _page = _load();

  Section get _section => widget.section;

  Future<dynamic> _load() {
    final query = {
      'limit': '$pageSize',
      'offset': '$_offset',
      if (_section.search case final param? when _search.text.trim().isNotEmpty) param: _search.text.trim(),
      ..._filters,
    };
    return widget.api.get(Uri(path: _section.path, queryParameters: query).toString());
  }

  void _reload({bool first = false}) {
    if (first) _offset = 0;
    final page = _load();
    setState(() {
      _page = page;
    });
  }

  void _searchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _reload(first: true));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(_section.title(l), style: Theme.of(context).textTheme.titleLarge),
          if (_section.search != null)
            SizedBox(
              width: 280,
              child: TextField(
                controller: _search,
                onChanged: _searchChanged,
                onSubmitted: (_) => _reload(first: true),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  labelText: _section.search == 'q' ? l.search : l.searchSubject,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          for (final filter in _section.filters) _filter(l, filter),
          IconButton(tooltip: l.refresh, onPressed: _reload, icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: FutureBuilder<dynamic>(
            future: _page,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Column(children: [
                  Text('${snapshot.error}'),
                  TextButton(onPressed: _reload, child: Text(l.retry)),
                ]);
              }
              if (!snapshot.hasData) {
                return const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator());
              }
              return _table(l, snapshot.data as Map<String, dynamic>);
            },
          ),
        ),
      ]),
    );
  }

  Widget _filter(AdminLocalizations l, Filter filter) => SizedBox(
        width: 220,
        child: DropdownButtonFormField<String?>(
          value: _filters[filter.param],
          isDense: true,
          decoration: InputDecoration(labelText: filter.label(l), border: const OutlineInputBorder(), isDense: true),
          items: [
            DropdownMenuItem(value: null, child: Text(l.filterAll)),
            for (final value in filter.values)
              DropdownMenuItem(
                value: value,
                child: Text(filter.flag ? (value == 'true' ? l.yes : l.no) : l.code(value)),
              ),
          ],
          onChanged: (value) {
            value == null ? _filters.remove(filter.param) : _filters[filter.param] = value;
            _reload(first: true);
          },
        ),
      );

  Widget _table(AdminLocalizations l, Map<String, dynamic> page) {
    final items = (page['items'] as List<dynamic>).cast<Map<String, dynamic>>();
    final total = page['total'] as int;
    final companies = _section.id == 'companies';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (page['grant_all'] == true)
        Text(l.grantAllLicenses, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      Expanded(
        child: items.isEmpty
            ? Text(l.empty)
            : SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    showCheckboxColumn: false,
                    columns: [for (final c in _section.columns) DataColumn(label: Text(c.label(l)))],
                    rows: [
                      for (final item in items)
                        DataRow(
                          onSelectChanged: companies
                              ? (_) => showDialog<void>(
                                    context: context,
                                    builder: (_) => CompanyDialog(
                                      api: widget.api,
                                      companyId: '${item['id']}',
                                      canRequest: widget.fullAdmin,
                                      onRequested: widget.onRequested,
                                    ),
                                  )
                              : null,
                          cells: [for (final c in _section.columns) DataCell(Text(_value(l, c, item[c.key])))],
                        ),
                    ],
                  ),
                ),
              ),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Text(total == 0 ? '' : l.pageRange(_offset + 1, _offset + items.length, total)),
        IconButton(
          tooltip: l.previous,
          onPressed: _offset == 0
              ? null
              : () {
                  _offset = (_offset - pageSize).clamp(0, total);
                  _reload();
                },
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: l.next,
          onPressed: _offset + items.length >= total
              ? null
              : () {
                  _offset += pageSize;
                  _reload();
                },
          icon: const Icon(Icons.chevron_right),
        ),
      ]),
    ]);
  }
}

String _value(AdminLocalizations l, Col column, Object? value) {
  if (value == null || value == '') return '—';
  return switch (column.format) {
    Format.text => '$value',
    Format.code => l.code('$value'),
    Format.date => l.when(DateTime.parse('$value')),
    Format.flag => value == true ? l.yes : l.no,
    Format.list => (value as List<dynamic>).join(', '),
    Format.changes => (value as Map<String, dynamic>)
        .entries
        .map((e) => '${e.key}: ${(e.value as List<dynamic>).map((v) => v ?? '—').join(' → ')}')
        .join('; '),
  };
}

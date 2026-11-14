import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import '../records/records.dart';

/// Pola części w magazynie (wpisy `part` firmy).
List<RecordField> partFields(AppLocalizations l) => [
      RecordField('name', l.partName, required: true),
      RecordField('number', l.partNumber),
      RecordField('qty', l.partQty, type: RecordFieldType.number),
      RecordField('min_qty', l.partMinQty, type: RecordFieldType.number),
      RecordField('price', l.partPrice, type: RecordFieldType.number),
      RecordField('location', l.partLocation),
    ];

/// Pola zapotrzebowania z warsztatu (wpisy `part_request` firmy).
List<RecordField> partRequestFields(AppLocalizations l) => [
      RecordField('name', l.partName, required: true),
      RecordField('qty', l.partQty, type: RecordFieldType.number),
      RecordField('order', l.partOrder),
      RecordField('note', l.partNote),
    ];

/// Części poniżej stanu minimalnego.
List<Map<String, dynamic>> lowStock(List<Map<String, dynamic>> parts) => [
      for (final p in parts)
        if ((p['data'] as Map?)?['min_qty'] is num &&
            (((p['data'] as Map)['qty'] as num?) ?? 0) < ((p['data'] as Map)['min_qty'] as num))
          p,
    ];

/// Części i magazyn warsztatu: stany, ceny, miejsca, braki poniżej minimum i zapotrzebowanie.
class PartsScreen extends StatefulWidget {
  const PartsScreen({super.key, required this.api, required this.companyId});

  final CoreApi api;
  final String? companyId;

  @override
  State<PartsScreen> createState() => _PartsScreenState();
}

class _PartsScreenState extends State<PartsScreen> {
  List<Map<String, dynamic>> _parts = const [];

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final low = lowStock(_parts);
    final value = _parts.fold<num>(0, (a, p) {
      final d = (p['data'] as Map?) ?? const {};
      return a + ((d['qty'] as num?) ?? 0) * ((d['price'] as num?) ?? 0);
    });
    return ListView(padding: const EdgeInsets.all(Gap.l), children: [
      Text(l.partsTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
      Text(l.partsSubtitle, style: theme.textTheme.bodyMedium),
      const SizedBox(height: Gap.l),
      Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
        UiTag(l.partsCount(_parts.length), tone: 'info', uppercase: false),
        UiTag(l.partsValue(l.number(value, decimals: 2)), tone: 'info', uppercase: false),
        UiTag(l.partsLow(low.length), tone: low.isEmpty ? 'tertiary' : 'error', uppercase: false),
      ]),
      if (low.isNotEmpty) ...[
        const SizedBox(height: Gap.m),
        UiPanel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.partsLowTitle, style: theme.textTheme.titleMedium),
            for (final p in low)
              Text(
                  '• ${(p['data'] as Map)['name']}: ${(p['data'] as Map)['qty'] ?? 0} / ${(p['data'] as Map)['min_qty']}'),
          ]),
        ),
      ],
      const SizedBox(height: Gap.l),
      UiPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.partsStock, style: theme.textTheme.titleMedium),
          const SizedBox(height: Gap.s),
          RecordsList(
            api: widget.api,
            companyId: widget.companyId,
            entityType: 'company',
            entityId: widget.companyId ?? '-',
            kind: 'part',
            title: l.partsStock,
            fields: partFields(l),
            onChanged: (items) => setState(() => _parts = items),
          ),
        ]),
      ),
      const SizedBox(height: Gap.l),
      UiPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.partsRequests, style: theme.textTheme.titleMedium),
          const SizedBox(height: Gap.s),
          RecordsList(
            api: widget.api,
            companyId: widget.companyId,
            entityType: 'company',
            entityId: widget.companyId ?? '-',
            kind: 'part_request',
            title: l.partsRequests,
            fields: partRequestFields(l),
          ),
        ]),
      ),
    ]);
  }
}

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../planner/route.dart';

/// Rodzaje zgłoszeń (te same co na serwerze): punkty dostawy i problemy na drodze.
const deliveryKinds = ['gate', 'ramp', 'office', 'waiting_area', 'hours'];
const roadKinds = ['height_limit', 'weight_limit', 'no_trucks', 'road_closed', 'narrow', 'other'];

/// Rodzaje, które potrzebują tekstu (godziny przyjęć, uwaga) albo wartości ze znaku.
const _needsNote = {'hours', 'other'};
const _needsValue = {'height_limit', 'weight_limit'};

String reportLabel(AppLocalizations l, String kind) => switch (kind) {
      'gate' => l.reportGate,
      'ramp' => l.reportRamp,
      'office' => l.reportOffice,
      'waiting_area' => l.reportWaitingArea,
      'hours' => l.reportHours,
      'height_limit' => l.reportHeightLimit,
      'weight_limit' => l.reportWeightLimit,
      'no_trucks' => l.reportNoTrucks,
      'road_closed' => l.reportRoadClosed,
      'narrow' => l.reportNarrow,
      _ => l.reportOther,
    };

IconData reportIcon(String kind) => switch (kind) {
      'gate' => Icons.fence,
      'ramp' => Icons.local_shipping_outlined,
      'office' => Icons.badge_outlined,
      'waiting_area' => Icons.local_parking,
      'hours' => Icons.schedule,
      'height_limit' => Icons.height,
      'weight_limit' => Icons.scale_outlined,
      'no_trucks' => Icons.do_not_disturb_on_outlined,
      'road_closed' => Icons.block,
      'narrow' => Icons.compress,
      _ => Icons.campaign_outlined,
    };

/// Zgłoszenie w danym miejscu: dotknięcie rodzaju wysyła je od razu; godziny przyjęć,
/// uwaga i ograniczenia ze znaku pytają najpierw o tekst / wartość.
/// Zwraca zapisane zgłoszenie (albo `null`, gdy kierowca zamknął okno).
Future<DriverReport?> showReportSheet(BuildContext context, CoreApi api, LatLng point, {bool deliveryFirst = false}) =>
    showModalBottomSheet<DriverReport>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ReportSheet(api: api, point: point, deliveryFirst: deliveryFirst),
    );

class ReportSheet extends StatefulWidget {
  const ReportSheet({super.key, required this.api, required this.point, this.deliveryFirst = false});

  final CoreApi api;
  final LatLng point;
  final bool deliveryFirst;

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  final _text = TextEditingController();
  String? _kind;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _choose(String kind) {
    if (_needsNote.contains(kind) || _needsValue.contains(kind)) {
      setState(() {
        _kind = kind;
        _error = null;
        _text.clear();
      });
    } else {
      _send(kind);
    }
  }

  Future<void> _send(String kind) async {
    final text = _text.text.trim();
    final value = double.tryParse(text.replaceAll(',', '.'));
    if (_needsValue.contains(kind) && value == null) return setState(() => _error = context.l.reportValueHint);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = await widget.api.post('/api/reports', {
        'kind': kind,
        'lat': widget.point.latitude,
        'lon': widget.point.longitude,
        if (_needsNote.contains(kind)) 'note': text,
        if (_needsValue.contains(kind)) 'value': value,
      });
      if (mounted) Navigator.of(context).pop(DriverReport.fromJson(body as Map<String, dynamic>));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final groups = widget.deliveryFirst
        ? [(l.reportDeliveryTitle, deliveryKinds), (l.reportRoadTitle, roadKinds)]
        : [(l.reportRoadTitle, roadKinds), (l.reportDeliveryTitle, deliveryKinds)];
    final kind = _kind;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.reportTitle, style: theme.textTheme.titleMedium),
        Text(l.reportHint, style: theme.textTheme.bodySmall),
        if (kind == null)
          for (final (title, kinds) in groups) ...[
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in kinds)
                ActionChip(
                  avatar: Icon(reportIcon(k), size: 18),
                  label: Text(reportLabel(l, k)),
                  onPressed: _busy ? null : () => _choose(k),
                ),
            ]),
          ]
        else ...[
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: _needsValue.contains(kind)
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            maxLength: _needsNote.contains(kind) ? 300 : 6,
            decoration: InputDecoration(
              labelText: reportLabel(l, kind),
              hintText: switch (kind) {
                'hours' => l.reportHoursHint,
                'height_limit' => l.reportHeightHint,
                'weight_limit' => l.reportWeightHint,
                _ => l.reportNoteHint,
              },
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _send(kind),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: _busy ? null : () => setState(() => _kind = null), child: Text(l.back)),
            const SizedBox(width: 8),
            FilledButton(onPressed: _busy ? null : () => _send(kind), child: Text(l.reportSend)),
          ]),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ]),
    );
  }
}

/// Głos „nadal aktualne / nieaktualne”; zwraca zgłoszenie po zmianie.
Future<DriverReport> voteReport(CoreApi api, DriverReport report, {required bool up}) async =>
    DriverReport.fromJson(await api.post('/api/reports/${report.id}/vote', {'up': up}) as Map<String, dynamic>);

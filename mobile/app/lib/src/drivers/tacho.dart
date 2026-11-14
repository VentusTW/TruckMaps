import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';

/// Wybór pliku .DDD: nazwa i zawartość; `null` – anulowano.
typedef DddPicker = Future<(String, List<int>)?> Function(String label);

/// Okno wyboru pliku z tachografu (Windows/macOS/Linux; na telefonie może być niedostępne).
Future<(String, List<int>)?> pickDddFile(String label) async {
  final file = await FileSelectorPlatform.instance.openFile(acceptedTypeGroups: [
    XTypeGroup(label: label, extensions: const ['ddd', 'DDD', 'c1b', 'C1B', 'v1b', 'V1B', 'tgd', 'TGD', 'esm']),
  ]);
  if (file == null) return null;
  return (file.name, await file.readAsBytes());
}

/// Pliki z tachografu w module Kierowcy (`/api/m/drivers/tacho…`).
class TachoApi {
  const TachoApi(this.api);

  final CoreApi api;

  Future<TachoData> driver(String driverId, {int days = 28}) async =>
      TachoData.fromJson(await api.get('/api/m/drivers/drivers/${Uri.encodeComponent(driverId)}/tacho?days=$days')
          as Map<String, dynamic>);

  Future<Map<String, dynamic>> vehicle(String vehicleId) async =>
      await api.get('/api/m/drivers/tacho/vehicles/${Uri.encodeComponent(vehicleId)}') as Map<String, dynamic>;

  Future<Map<String, dynamic>> upload(String companyId, String name, List<int> bytes,
          {String? driverId, String? vehicleId}) async =>
      await api.post('/api/m/drivers/tacho/upload', {
        'company_id': companyId,
        'name': name,
        'data': base64Encode(bytes),
        if (driverId != null) 'driver_id': driverId,
        if (vehicleId != null) 'vehicle_id': vehicleId,
      }) as Map<String, dynamic>;
}

class TachoSegment {
  TachoSegment(this.start, this.end, this.activity, {this.manual = false});

  factory TachoSegment.fromJson(Map<String, dynamic> j) => TachoSegment(
      DateTime.parse('${j['start']}').toLocal(), DateTime.parse('${j['end']}').toLocal(), '${j['activity']}',
      manual: j['manual'] == true);

  final DateTime start;
  final DateTime end;
  final String activity;
  final bool manual;
}

/// Jeden dzień (czas lokalny) – odcinki przycięte do doby i sumy minut według aktywności.
class TachoDay {
  TachoDay(this.day);

  final DateTime day;
  final List<TachoSegment> segments = [];
  final Map<String, int> minutes = {};
}

class TachoData {
  TachoData(this.json);

  factory TachoData.fromJson(Map<String, dynamic> json) => TachoData(json);

  final Map<String, dynamic> json;

  List<TachoSegment> get segments => [for (final s in uiMaps(json['segments'])) TachoSegment.fromJson(s)];
  List<Map<String, dynamic>> get violations => uiMaps(json['violations']);
  List<Map<String, dynamic>> get places => uiMaps(json['places']);
  List<Map<String, dynamic>> get downloads => uiMaps(json['downloads']);
  Map<String, dynamic> get counters => (json['counters'] as Map?)?.cast<String, dynamic>() ?? const {};
  int get days => (json['days'] as num?)?.toInt() ?? 28;
  bool get empty => segments.isEmpty;

  num counter(String key) => counters[key] as num? ?? 0;
  DateTime? moment(String key) => DateTime.tryParse('${counters[key]}')?.toLocal();

  /// Dni od najnowszego, odcinki podzielone o północy czasu lokalnego.
  List<TachoDay> byDay() {
    final result = <DateTime, TachoDay>{};
    for (final s in segments) {
      var start = s.start;
      while (start.isBefore(s.end)) {
        final day = DateTime(start.year, start.month, start.day);
        final next = DateTime(day.year, day.month, day.day + 1);
        final end = s.end.isBefore(next) ? s.end : next;
        final item = result.putIfAbsent(day, () => TachoDay(day));
        item.segments.add(TachoSegment(start, end, s.activity, manual: s.manual));
        item.minutes.update(s.activity, (m) => m + end.difference(start).inMinutes,
            ifAbsent: () => end.difference(start).inMinutes);
        start = end;
      }
    }
    return result.values.toList()..sort((a, b) => b.day.compareTo(a.day));
  }
}

/// "8:05" z minut.
String hoursMinutes(num minutes) {
  final total = minutes.round();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

Color activityColor(BuildContext context, String activity) {
  final scheme = Theme.of(context).colorScheme;
  final colors = TruckColors.of(context);
  return switch (activity) {
    'driving' => scheme.primary,
    'work' => colors.warning,
    'available' => colors.info.withOpacity(0.55),
    'rest' => colors.success.withOpacity(0.35),
    _ => scheme.outlineVariant,
  };
}

String activityLabel(AppLocalizations l, String activity) => switch (activity) {
      'driving' => l.tachoActDriving,
      'work' => l.tachoActWork,
      'available' => l.tachoActAvailable,
      'rest' => l.tachoActRest,
      _ => l.tachoActUnknown,
    };

String severityLabel(AppLocalizations l, String severity) => switch (severity) {
      'very_serious' => l.tachoSevVerySerious,
      'serious' => l.tachoSevSerious,
      _ => l.tachoSevMinor,
    };

String severityTone(String severity) => switch (severity) {
      'very_serious' => 'critical',
      'serious' => 'error',
      _ => 'info',
    };

String violationText(AppLocalizations l, Map<String, dynamic> v) {
  final value = hoursMinutes(v['value'] as num? ?? 0);
  final limit = hoursMinutes(v['limit'] as num? ?? 0);
  return switch ('${v['kind']}') {
    'daily_driving' => l.tachoVDailyDriving(value, limit),
    'weekly_driving' => l.tachoVWeeklyDriving(value, limit),
    'fortnight_driving' => l.tachoVFortnight(value, limit),
    'break' => l.tachoVBreak(value, limit),
    'daily_rest' => l.tachoVDailyRest(value, limit),
    'weekly_rest' => l.tachoVWeeklyRest(value, limit),
    _ => l.tachoVWeeklyLate(value),
  };
}

/// Przycisk „Wczytaj plik .DDD” – karta kierowcy (`driverId`) albo tachograf pojazdu (`vehicleId`).
class TachoUploadButton extends StatefulWidget {
  const TachoUploadButton({
    super.key,
    required this.api,
    required this.companyId,
    this.driverId,
    this.vehicleId,
    this.onDone,
    this.picker,
    this.compact = false,
  });

  final CoreApi api;
  final String? companyId;
  final String? driverId;
  final String? vehicleId;
  final VoidCallback? onDone;
  final DddPicker? picker;
  final bool compact;

  @override
  State<TachoUploadButton> createState() => _TachoUploadButtonState();
}

class _TachoUploadButtonState extends State<TachoUploadButton> {
  bool _busy = false;

  Future<void> _upload() async {
    final l = context.l;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final company = widget.companyId;
    if (company == null) return;
    (String, List<int>)? picked;
    try {
      picked = await (widget.picker ?? pickDddFile)(l.tachoFileType);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(l.tachoPickFailed)));
      return;
    }
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      final result = await TachoApi(widget.api)
          .upload(company, picked.$1, picked.$2, driverId: widget.driverId, vehicleId: widget.vehicleId);
      final unmatched = (result['unmatched_cards'] as List? ?? const []).join(', ');
      messenger?.showSnackBar(SnackBar(
          content: Text([
        l.tachoUploaded(picked.$1, (result['activities'] as num? ?? 0).toInt()),
        if (unmatched.isNotEmpty) l.tachoUnmatched(unmatched),
      ].join('\n'))));
      widget.onDone?.call();
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final icon = _busy
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.upload_file_outlined, size: 18);
    final onPressed = widget.companyId == null || _busy ? null : _upload;
    if (widget.compact) {
      return TextButton.icon(
          key: const Key('tacho-upload'), onPressed: onPressed, icon: icon, label: Text(l.tachoUpload));
    }
    return OutlinedButton.icon(
        key: const Key('tacho-upload'), onPressed: onPressed, icon: icon, label: Text(l.tachoUpload));
  }
}

/// Kafelki liczników 561/2006: jazda ciągła, dzienna, odpoczynek dobowy, tydzień, dwa tygodnie,
/// odpoczynek tygodniowy.
class TachoCounters extends StatelessWidget {
  const TachoCounters({super.key, required this.data, required this.wide});

  final TachoData? data;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final d = data;
    final stamp = DateFormat('d.MM HH:mm', l.localeName);
    (String, String, double?) driving(String value, String limit) {
      if (d == null || d.empty) return ('–', '', null);
      final used = d.counter(value);
      final max = d.counter(limit);
      return (
        '${hoursMinutes(used)} / ${hoursMinutes(max)}',
        l.tachoLeft(hoursMinutes((max - used).clamp(0, max))),
        max == 0 ? 0 : used / max,
      );
    }

    (String, String, double?) due(String key) {
      final when = d?.moment(key);
      if (d == null || d.empty || when == null) return ('–', '', null);
      return (stamp.format(when), l.tachoDue, null);
    }

    final daily = driving('daily_driving', 'daily_limit');
    final tiles = [
      (l.drvTachoContinuous, driving('continuous_driving', 'continuous_limit')),
      (
        l.drvTachoDaily,
        d == null || d.empty ? daily : (daily.$1, l.tachoExtLeft(d.counter('extensions_left').toInt()), daily.$3)
      ),
      (l.drvTachoRest, due('daily_rest_due')),
      (l.drvTachoWeek, driving('weekly_driving', 'weekly_limit')),
      (l.drvTachoTwoWeeks, driving('fortnight_driving', 'fortnight_limit')),
      (l.drvTachoHome, due('weekly_rest_due')),
    ];
    return LayoutBuilder(builder: (context, size) {
      final columns = wide ? 6 : (size.maxWidth >= 500 ? 3 : 2);
      final width = (size.maxWidth - Gap.m * (columns - 1)) / columns;
      return Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
        for (final (i, (label, (value, sub, share))) in tiles.indexed)
          Builder(builder: (context) {
            final alarm = (share ?? 0) >= 0.9;
            return Container(
              key: Key('tacho-tile-$i'),
              width: width,
              padding: const EdgeInsets.all(Gap.m),
              decoration: BoxDecoration(
                color: alarm ? scheme.errorContainer.withOpacity(0.35) : colors.surfaceLow,
                borderRadius: BorderRadius.circular(TruckTheme.radius),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.toUpperCase(),
                    maxLines: 2,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: alarm ? scheme.error : scheme.onSurfaceVariant, letterSpacing: 0.4)),
                const SizedBox(height: Gap.s),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (sub.isNotEmpty)
                  Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.s),
                TruckProgressBar(value: share ?? 0, height: 5, color: alarm ? scheme.error : scheme.primary),
              ]),
            );
          }),
      ]);
    });
  }
}

/// Oś doby 0–24 h z kolorami aktywności.
class TachoDayBar extends StatelessWidget {
  const TachoDayBar({super.key, required this.day, this.height = 14});

  final TachoDay day;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = [for (final s in day.segments) activityColor(context, s.activity)];
    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          color: TruckColors.of(context).surfaceHigh, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
      child: CustomPaint(painter: _DayPainter(day, colors), size: Size.infinite),
    );
  }
}

class _DayPainter extends CustomPainter {
  _DayPainter(this.day, this.colors);

  final TachoDay day;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    const minutes = 24 * 60;
    for (final (i, s) in day.segments.indexed) {
      final from = s.start.difference(day.day).inMinutes / minutes;
      final to = s.end.difference(day.day).inMinutes / minutes;
      final top = s.activity == 'driving' ? 0.0 : size.height * 0.3;
      canvas.drawRect(Rect.fromLTRB(from * size.width, top, to * size.width, size.height), Paint()..color = colors[i]);
    }
  }

  @override
  bool shouldRepaint(_DayPainter old) => old.day != day;
}

/// Lista dni z osią aktywności i sumą jazdy / pracy; miejsca rozpoczęcia i zakończenia pracy.
class TachoDays extends StatelessWidget {
  const TachoDays({super.key, required this.data, this.limit});

  final TachoData data;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final format = DateFormat.MMMEd(l.localeName);
    final time = DateFormat.Hm(l.localeName);
    final days = data.byDay();
    final places = data.places;
    final shown = limit == null ? days : days.take(limit!).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: Gap.m, runSpacing: Gap.xs, children: [
        for (final a in const ['driving', 'work', 'available', 'rest', 'unknown'])
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, color: activityColor(context, a)),
            const SizedBox(width: Gap.xs),
            Text(activityLabel(l, a), style: theme.textTheme.labelSmall),
          ]),
      ]),
      const SizedBox(height: Gap.s),
      for (final day in shown)
        Padding(
          key: Key('tacho-day-${DateFormat('yyyy-MM-dd').format(day.day)}'),
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(format.format(day.day), style: theme.textTheme.labelLarge)),
              Text(l.tachoDaySummary(hoursMinutes(day.minutes['driving'] ?? 0), hoursMinutes(day.minutes['work'] ?? 0)),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: Gap.xs),
            TachoDayBar(day: day),
            for (final p in places)
              if (DateTime.tryParse('${p['at']}')?.toLocal() case final at?
                  when at.year == day.day.year && at.month == day.day.month && at.day == day.day.day)
                Text(
                    '${time.format(at)} ${p['entry'] == 'begin' ? l.tachoPlaceBegin : l.tachoPlaceEnd}'
                    '${'${p['country'] ?? ''}'.isEmpty ? '' : ' • ${p['country']}'} • ${p['odometer']} km',
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
          ]),
        ),
    ]);
  }
}

/// Naruszenia 561/2006 od najnowszych, z wagą.
class TachoViolations extends StatelessWidget {
  const TachoViolations({super.key, required this.data});

  final TachoData data;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final items = data.violations.reversed.toList();
    if (items.isEmpty) return UiEmpty(l.tachoViolationsNone(data.days));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final v in items)
        UiBox(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
          child: Row(children: [
            Icon(Icons.gavel_outlined, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(violationText(l, v), style: theme.textTheme.bodySmall),
                if (DateTime.tryParse('${v['start']}') case final start?)
                  Text(l.when(start.toLocal()),
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
              ]),
            ),
            UiTag(severityLabel(l, '${v['severity']}'), tone: severityTone('${v['severity']}'), uppercase: false),
          ]),
        ),
    ]);
  }
}

/// Okno z wszystkimi dniami z pliku.
Future<void> showTachoDays(BuildContext context, TachoData data) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l.tachoDays),
        content: SizedBox(width: 640, child: SingleChildScrollView(child: TachoDays(data: data))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.tachoClose))],
      ),
    );

/// Skrót w karcie kierowcy (edycja): liczniki tekstem, liczba naruszeń, wczytanie pliku.
class TachoSummary extends StatefulWidget {
  const TachoSummary({super.key, required this.api, required this.companyId, required this.driverId, this.picker});

  final CoreApi api;
  final String? companyId;
  final String driverId;
  final DddPicker? picker;

  @override
  State<TachoSummary> createState() => _TachoSummaryState();
}

class _TachoSummaryState extends State<TachoSummary> {
  TachoData? _data;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await TachoApi(widget.api).driver(widget.driverId);
      if (mounted) setState(() => _data = data);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final d = _data;
    final String text;
    if (_failed) {
      text = l.drvNoModule;
    } else if (d == null) {
      text = '…';
    } else if (d.empty) {
      text = l.tachoNoData;
    } else {
      text = [
        '${l.drvTachoDaily}: ${hoursMinutes(d.counter('daily_driving'))} / ${hoursMinutes(d.counter('daily_limit'))}',
        '${l.drvTachoWeek}: ${hoursMinutes(d.counter('weekly_driving'))} / ${hoursMinutes(d.counter('weekly_limit'))}',
        l.tachoViolationCount(d.violations.length),
      ].join(' • ');
    }
    return Row(children: [
      Expanded(child: Text(text, key: const Key('tacho-summary'), style: theme.textTheme.bodySmall)),
      if (!_failed)
        TachoUploadButton(
          api: widget.api,
          companyId: widget.companyId,
          driverId: widget.driverId,
          picker: widget.picker,
          compact: true,
          onDone: _load,
        ),
    ]);
  }
}

/// Znacznik w karcie pojazdu: data ostatniego pobrania danych z tachografu i wczytanie pliku VU.
class VehicleTachoTag extends StatefulWidget {
  const VehicleTachoTag({super.key, required this.api, required this.companyId, required this.vehicleId, this.picker});

  final CoreApi api;
  final String? companyId;
  final String vehicleId;
  final DddPicker? picker;

  @override
  State<VehicleTachoTag> createState() => _VehicleTachoTagState();
}

class _VehicleTachoTagState extends State<VehicleTachoTag> {
  Map<String, dynamic>? _info;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await TachoApi(widget.api).vehicle(widget.vehicleId);
      if (mounted) setState(() => _info = info);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (_failed) return UiTag(l.tachoNeverVu, tone: null, uppercase: false);
    final last = DateTime.tryParse('${_info?['last_download']}')?.toLocal();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      UiTag(last == null ? l.tachoNeverVu : l.tachoLastVu(DateFormat.yMd(l.localeName).format(last)),
          tone: last == null ? 'error' : 'ok', uppercase: false),
      TachoUploadButton(
        api: widget.api,
        companyId: widget.companyId,
        vehicleId: widget.vehicleId,
        picker: widget.picker,
        compact: true,
        onDone: _load,
      ),
    ]);
  }
}

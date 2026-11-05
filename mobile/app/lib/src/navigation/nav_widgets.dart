import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../planner/route.dart';
import '../reports/report_sheet.dart';
import 'guidance.dart';
import 'route_events.dart';

/// Półprzezroczyste ciemne karty ekranu nawigacji.
const navPanelColor = TruckPalette.navPanel;
const navAccent = TruckPalette.navAccent;
const _white = TextStyle(color: Colors.white);
const _dim = TextStyle(color: Colors.white70);

class NavPanel extends StatelessWidget {
  const NavPanel({super.key, required this.child, this.padding = const EdgeInsets.all(12), this.color});

  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color ?? navPanelColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
        ),
        child: Padding(padding: padding, child: DefaultTextStyle.merge(style: _white, child: child)),
      );
}

/// Okrągły przycisk na mapie („+”, „POI”, głos, tryb nocny).
class RoundButton extends StatelessWidget {
  const RoundButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.size = 52});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: navPanelColor,
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(dimension: size, child: Icon(icon, color: Colors.white, size: size * 0.5)),
          ),
        ),
      );
}

/// Strzałka do rodzaju manewru Valhalli.
IconData maneuverIcon(int type) => switch (type) {
      >= 1 && <= 3 => Icons.navigation_outlined,
      >= 4 && <= 6 => Icons.sports_score,
      9 => Icons.turn_slight_right,
      10 => Icons.turn_right,
      11 => Icons.turn_sharp_right,
      12 => Icons.u_turn_right,
      13 => Icons.u_turn_left,
      14 => Icons.turn_sharp_left,
      15 => Icons.turn_left,
      16 => Icons.turn_slight_left,
      18 || 20 => Icons.ramp_right,
      19 || 21 => Icons.ramp_left,
      23 => Icons.fork_right,
      24 => Icons.fork_left,
      25 => Icons.merge,
      26 || 27 => Icons.roundabout_right,
      28 || 29 => Icons.directions_boat_outlined,
      _ => Icons.straight,
    };

IconData laneIcon(String direction) => switch (direction) {
      'left' => Icons.turn_left,
      'slight_left' => Icons.turn_slight_left,
      'sharp_left' => Icons.turn_sharp_left,
      'right' => Icons.turn_right,
      'slight_right' => Icons.turn_slight_right,
      'sharp_right' => Icons.turn_sharp_right,
      'reverse' => Icons.u_turn_left,
      'merge_left' || 'merge_right' => Icons.merge,
      _ => Icons.straight,
    };

/// Tarcza numeru drogi w kolorach znaków: autostrady i ekspresowe – czerwone (PL, CZ),
/// europejskie – zielone, wojewódzkie i Bundesstraßen – żółte.
class RoadShield extends StatelessWidget {
  const RoadShield(this.ref, {super.key});

  final String ref;

  @override
  Widget build(BuildContext context) {
    final upper = ref.toUpperCase();
    final (background, foreground) = switch (upper) {
      _ when upper.startsWith('E') => (TruckPalette.roadEuropean, Colors.white),
      _ when upper.startsWith('DW') || upper.startsWith('B') => (TruckPalette.roadRegional, Colors.black),
      _ => (TruckPalette.roadNational, Colors.white),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(upper, style: TextStyle(color: foreground, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

/// Karta manewru: strzałka (rondo z numerem zjazdu), odległość, tarcza drogi, ulica,
/// kierunek z tablicy i pasy ruchu.
class ManeuverPanel extends StatelessWidget {
  const ManeuverPanel({super.key, required this.next});

  final NextManeuver next;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final m = next.maneuver;
    final ref = roadRef(m), street = streetName(m);
    return NavPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(clipBehavior: Clip.none, children: [
            Icon(maneuverIcon(m.type), color: Colors.white, size: 56),
            if (m.roundaboutExit case final exit?)
              Positioned(
                right: -4,
                bottom: -2,
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: navAccent,
                  child: Text('$exit',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Guidance.display(l, next.distanceM),
                  style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (m.exitNumber case final exit?) _Tag(l.navExit(exit)),
                if (m.roundaboutExit case final exit?) _Tag(l.navRoundaboutExit(exit)),
                if (ref != null) RoadShield(ref),
                if (street != null) Text(street, style: const TextStyle(color: Colors.white, fontSize: 17)),
              ]),
              if (m.toward.isNotEmpty)
                Text(l.navToward(m.toward.take(3).join(', ')),
                    style: _dim, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (ref == null && street == null && m.toward.isEmpty)
                Text(m.instruction, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ]),
          ),
        ]),
        if (m.lanes.length > 1) ...[
          const SizedBox(height: 8),
          LaneRow(lanes: m.lanes),
        ],
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
        child:
            Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), child: Text(text, style: _white)),
      );
}

/// Pasy ruchu: pas do jazdy jasny, pozostałe przygaszone.
class LaneRow extends StatelessWidget {
  const LaneRow({super.key, required this.lanes});

  final List<Lane> lanes;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (i, lane) in lanes.indexed) ...[
          if (i > 0) Container(width: 1, height: 30, color: Colors.white24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final direction in lane.directions)
                Icon(laneIcon(direction), size: 26, color: lane.active ? Colors.white : Colors.white30),
            ]),
          ),
        ],
      ]);
}

/// „Pigułka” z następną ulicą (manewr po bieżącym).
class NextStreetPill extends StatelessWidget {
  const NextStreetPill({super.key, required this.maneuver});

  final Maneuver maneuver;

  @override
  Widget build(BuildContext context) {
    final name = streetName(maneuver) ?? roadRef(maneuver) ?? maneuver.instruction;
    return NavPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(maneuverIcon(maneuver.type), size: 18, color: Colors.white70),
        const SizedBox(width: 6),
        Flexible(child: Text(context.l.navThen(name), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

String eventLabel(AppLocalizations l, NavEvent e) => switch (e.kind) {
      'level_crossing' => l.eventLevelCrossing,
      'speed_camera' when e.speedKmh != null => l.eventSpeedCameraLimit(e.speedKmh!.round()),
      'speed_camera' => l.eventSpeedCamera,
      'traffic_signals' => l.eventTrafficSignals,
      'average_speed' when e.speedKmh != null => l.eventAverageSpeedLimit(e.speedKmh!.round()),
      'average_speed' => l.eventAverageSpeed,
      'no_overtaking' => l.eventNoOvertaking,
      'via' => l.eventVia(e.index ?? 1),
      'destination' => l.eventDestination,
      final kind when kind.startsWith('report:') => reportLabel(l, kind.substring(7)),
      _ => e.message ?? l.eventBan,
    };

IconData eventIcon(NavEvent e) => switch (e.kind) {
      'level_crossing' => Icons.train_outlined,
      'speed_camera' => Icons.photo_camera_outlined,
      'traffic_signals' => Icons.traffic_outlined,
      'average_speed' => Icons.av_timer,
      'no_overtaking' => Icons.do_not_disturb_alt,
      'via' => Icons.place_outlined,
      'destination' => Icons.sports_score,
      'ban' => Icons.block,
      'red' || 'orange' => Icons.warning_amber_rounded,
      final kind when kind.startsWith('report:') => reportIcon(kind.substring(7)),
      _ => Icons.info_outline,
    };

Color eventColor(NavEvent e) => switch (e.kind) {
      'red' || 'ban' => levelColor('red'),
      'orange' => levelColor('orange'),
      'speed_camera' || 'average_speed' => TruckPalette.camera,
      'via' || 'destination' => navAccent,
      final kind when kind.startsWith('report:') => TruckPalette.driverReport,
      _ => Colors.white,
    };

/// Lista nadchodzących zdarzeń z odległościami („2 km · Przejazd kolejowy”).
class UpcomingList extends StatelessWidget {
  const UpcomingList({super.key, required this.events, required this.alongM});

  final List<NavEvent> events;
  final double alongM;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return NavPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final e in events)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Icon(eventIcon(e), size: 18, color: eventColor(e)),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: Text(e.covers(alongM) ? l.navNow : Guidance.display(l, e.alongM - alongM),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Expanded(child: Text(eventLabel(l, e), overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ]),
    );
  }
}

/// Znak ograniczenia prędkości, zapowiedź zmiany („50 za 100 m”) i prędkość z GPS
/// (na czerwono przy przekroczeniu).
class SpeedPanel extends StatelessWidget {
  const SpeedPanel({super.key, this.limit, this.change, this.speedKmh});

  final SpeedLimit? limit;
  final (int, double)? change;
  final double? speedKmh;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final over = overLimit(speedKmh, limit?.kmh);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (change case (final kmh, final distance))
        NavPanel(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(l.navSpeedChange(kmh, Guidance.display(l, distance))),
        ),
      const SizedBox(height: 6),
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (limit != null)
          Tooltip(
            message: limit!.posted == null || limit!.posted! > limit!.kmh ? l.navSpeedTruckLimit : l.navSpeedLimit,
            child: Container(
              width: 58,
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: TruckPalette.ratingRed, width: 6),
              ),
              child: Text('${limit!.kmh}',
                  style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w800)),
            ),
          ),
        if (speedKmh != null) ...[
          const SizedBox(width: 8),
          NavPanel(
            color: over ? TruckPalette.navAlarm : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${speedKmh!.round()}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Text(l.navKmh, style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ]),
          ),
        ],
      ]),
    ]);
  }
}

/// Pasek postępu całej trasy: przejechana część i znaczniki zdarzeń.
class RouteProgress extends StatelessWidget {
  const RouteProgress({super.key, required this.alongM, required this.lengthM, required this.events});

  final double alongM;
  final double lengthM;
  final List<NavEvent> events;

  @override
  Widget build(BuildContext context) {
    final done = lengthM <= 0 ? 0.0 : (alongM / lengthM).clamp(0.0, 1.0);
    return LayoutBuilder(builder: (context, size) {
      final width = size.maxWidth;
      return SizedBox(
        height: 14,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(top: 5, bottom: 5, child: Container(color: Colors.white24)),
          Positioned(left: 0, top: 5, bottom: 5, width: width * done, child: Container(color: navAccent)),
          for (final e in events)
            if (e.kind != 'traffic_signals' && lengthM > 0)
              Positioned(
                left: (width * (e.alongM / lengthM).clamp(0.0, 1.0)) - 3,
                top: 1,
                child: Container(width: 6, height: 12, color: eventColor(e)),
              ),
        ]),
      );
    });
  }
}

/// Pionowy pasek trasy z boku: najbliższe [aheadM] metrów, pojazd na dole, zdarzenia
/// z odległościami (punkty pośrednie, fotoradary, sygnalizacja, zgłoszenia).
class RouteStrip extends StatelessWidget {
  const RouteStrip({super.key, required this.events, required this.alongM, this.aheadM = 10000, this.height = 260});

  final List<NavEvent> events;
  final double alongM;
  final double aheadM;
  final double height;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final shown = [
      for (final e in upcoming(events, alongM, withinM: aheadM, signals: true))
        if (e.alongM >= alongM) e,
    ].take(8).toList();
    double top(double along) => height - 24 - (along - alongM) / aheadM * (height - 40);
    return NavPanel(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: SizedBox(
        width: 76,
        height: height,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(left: 10, top: 0, bottom: 12, child: Container(width: 4, color: Colors.white38)),
          for (final e in shown)
            Positioned(
              left: 0,
              top: top(e.alongM) - 10,
              child: Row(children: [
                Icon(eventIcon(e), size: 22, color: eventColor(e)),
                const SizedBox(width: 2),
                Text(Guidance.display(l, e.alongM - alongM), style: const TextStyle(fontSize: 11)),
              ]),
            ),
          const Positioned(left: 2, bottom: 0, child: Icon(Icons.navigation, size: 20, color: navAccent)),
        ]),
      ),
    );
  }
}

/// Dolna karta: godzina przyjazdu (zielona; czerwona przy spóźnieniu), km i czas do celu,
/// najbliższy punkt pośredni i pasek postępu.
class BottomPanel extends StatelessWidget {
  const BottomPanel({
    super.key,
    required this.arrival,
    required this.remainingM,
    required this.remainingMin,
    required this.progress,
    required this.onEnd,
    this.late = false,
    this.nextVia,
  });

  final DateTime arrival;
  final double remainingM;
  final double remainingMin;
  final Widget progress;
  final VoidCallback onEnd;
  final bool late;

  /// (numer, liczba punktów, minuty, metry) – najbliższy punkt pośredni.
  final (int, int, double, double)? nextVia;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final time = TimeOfDay.fromDateTime(arrival).format(context);
    return NavPanel(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(time,
                style: TextStyle(
                  color: late ? TruckPalette.navLate : TruckPalette.navOnTime,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                )),
          ),
          Text(l.km(remainingM / 1000), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          Text(navDuration(l, remainingMin), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          IconButton(
            tooltip: l.navEnd,
            onPressed: onEnd,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ]),
        if (late) Text(l.navLate, style: const TextStyle(color: TruckPalette.navLate)),
        if (nextVia case (final index, final count, final minutes, final meters))
          Text(l.navNextVia(index, count, navDuration(l, minutes), l.km(meters / 1000)), style: _dim),
        const SizedBox(height: 6),
        progress,
      ]),
    );
  }
}

String navDuration(AppLocalizations l, double minutes) {
  final total = minutes.round();
  return total < 60 ? l.navMinutes(total) : l.navHours(total ~/ 60, total % 60);
}

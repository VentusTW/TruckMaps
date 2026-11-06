import 'package:flutter/material.dart';

import 'theme.dart';

/// Znaczenie koloru elementu: w porządku, uwaga, błąd, informacja, neutralny.
enum StatusTone { ok, warning, error, info, neutral }

({Color fg, Color bg}) _toneColors(BuildContext context, StatusTone tone) {
  final scheme = Theme.of(context).colorScheme;
  final colors = TruckColors.of(context);
  return switch (tone) {
    StatusTone.ok => (fg: colors.onMint, bg: colors.mint),
    StatusTone.warning => (fg: colors.warning, bg: Color.alphaBlend(colors.warning.withOpacity(0.16), colors.card)),
    StatusTone.error => (fg: scheme.onErrorContainer, bg: scheme.errorContainer),
    StatusTone.info => (fg: scheme.onSecondaryContainer, bg: scheme.secondaryContainer),
    StatusTone.neutral => (fg: scheme.onSurfaceVariant, bg: colors.surfaceLow),
  };
}

/// Kolor linii stanu / ikony dla danego znaczenia.
Color toneColor(BuildContext context, StatusTone tone) {
  final scheme = Theme.of(context).colorScheme;
  final colors = TruckColors.of(context);
  return switch (tone) {
    StatusTone.ok => colors.success,
    StatusTone.warning => colors.warning,
    StatusTone.error => scheme.error,
    StatusTone.info => scheme.primary,
    StatusTone.neutral => scheme.onSurfaceVariant,
  };
}

/// Etykieta sekcji: małe, pogrubione WIELKIE LITERY w kolorze pomocniczym.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(color: color ?? theme.colorScheme.secondary),
    );
  }
}

/// Duża liczba z jednostką obok (mniejszą, w kolorze pomocniczym).
class BigNumber extends StatelessWidget {
  const BigNumber({super.key, required this.value, this.unit, this.size = 28, this.color});

  final String value;
  final String? unit;
  final double size;

  /// Kolor liczby; domyślnie kolor tekstu.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: value,
          style: TextStyle(
            fontFamily: TruckFonts.headline,
            fontSize: size,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.02 * size,
            color: color ?? theme.colorScheme.onSurface,
          ),
        ),
        if (unit != null)
          TextSpan(text: ' $unit', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.secondary)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Karta KPI: etykieta → duża liczba z jednostką → linia stanu; ikona w kwadracie w rogu.
class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.unit,
    this.status,
    this.tone = StatusTone.neutral,
    this.onTap,
    this.progress,
  });

  final String label;
  final String value;
  final String? unit;
  final IconData icon;

  /// Pasek pod liczbą (0–1, np. udział we flocie), w kolorze [tone].
  final double? progress;

  /// Linia pod liczbą (np. „2 po terminie”), w kolorze [tone].
  final String? status;
  final StatusTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = toneColor(context, tone);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SectionLabel(label),
                const SizedBox(height: Gap.s),
                BigNumber(
                  value: value,
                  unit: unit,
                  color: tone == StatusTone.ok || tone == StatusTone.error ? color : null,
                ),
                if (progress != null) ...[
                  const SizedBox(height: Gap.s),
                  TruckProgressBar(
                      value: progress!,
                      height: 6,
                      color: tone == StatusTone.neutral ? Theme.of(context).colorScheme.primaryContainer : color),
                ],
                if (status != null) ...[
                  const SizedBox(height: Gap.xs),
                  Text(status!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: color)),
                ],
              ]),
            ),
            const SizedBox(width: Gap.s),
            IconSquare(icon: icon, color: tone == StatusTone.neutral ? theme.colorScheme.primary : color),
          ]),
        ),
      ),
    );
  }
}

/// Chip stanu: zaokrąglony, z kropką; „w porządku” – miętowe tło i ciemnozielony tekst.
/// [pulse] – kropka pulsuje (tylko dla stanów na żywo; animacja trwa bez końca).
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.tone = StatusTone.ok,
    this.icon,
    this.pulse = false,
    this.uppercase = true,
  });

  final String label;
  final StatusTone tone;

  /// Ikona zamiast kropki.
  final IconData? icon;
  final bool pulse;

  /// Krótki stan – wielkimi literami; dłuższe zdanie – zwykłym tekstem.
  final bool uppercase;

  @override
  Widget build(BuildContext context) {
    final c = _toneColors(context, tone);
    final dot = Container(width: 8, height: 8, decoration: BoxDecoration(color: c.fg, shape: BoxShape.circle));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: ShapeDecoration(color: c.bg, shape: const StadiumBorder()),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) Icon(icon, size: 14, color: c.fg) else pulse ? _Pulse(child: dot) : dot,
        const SizedBox(width: 6),
        Flexible(
          child: Text(uppercase ? label.toUpperCase() : label,
              maxLines: uppercase ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: (uppercase ? Theme.of(context).textTheme.labelSmall : Theme.of(context).textTheme.labelMedium)
                  ?.copyWith(color: c.fg)),
        ),
      ]),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: Tween(begin: 1.0, end: 0.35).animate(_controller), child: widget.child);
}

/// Pasek postępu: tor jasny, wypełnienie w kolorze marki, zaokrąglony.
class TruckProgressBar extends StatelessWidget {
  const TruckProgressBar({super.key, required this.value, this.height = 8, this.color});

  /// 0–1; poza zakresem – przycięte.
  final double value;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: height,
          color: color ?? Theme.of(context).colorScheme.primary,
          backgroundColor: TruckColors.of(context).surfaceHigh,
        ),
      );
}

/// Kafelek wartości: etykieta i ikona, liczba z jednostką, podpis, opcjonalny pasek postępu.
class ValueTile extends StatelessWidget {
  const ValueTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.icon,
    this.caption,
    this.progress,
    this.tone = StatusTone.neutral,
  });

  final String label;
  final String value;
  final String? unit;
  final IconData? icon;
  final String? caption;
  final double? progress;

  /// Kolor podpisu i paska.
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone == StatusTone.neutral ? null : toneColor(context, tone);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: SectionLabel(label, color: theme.colorScheme.onSurface)),
            if (icon != null) Icon(icon, size: 20, color: color ?? theme.colorScheme.primary),
          ]),
          const SizedBox(height: Gap.s),
          BigNumber(value: value, unit: unit, size: 24),
          if (caption != null) ...[
            const SizedBox(height: Gap.xs),
            Text(caption!,
                style: theme.textTheme.bodySmall?.copyWith(color: color ?? theme.colorScheme.onSurfaceVariant)),
          ],
          if (progress != null) ...[
            const SizedBox(height: Gap.s),
            TruckProgressBar(value: progress!, color: color),
          ],
        ]),
      ),
    );
  }
}

/// Baner alarmowy: pełne tło błędu, biały tekst, strzałka w prawo, gdy można go otworzyć.
class AlertBanner extends StatelessWidget {
  const AlertBanner(
      {super.key, required this.title, this.subtitle, this.icon = Icons.warning_amber_rounded, this.onTap});

  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = scheme.onError;
    return Material(
      color: scheme.error,
      borderRadius: BorderRadius.circular(TruckTheme.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Row(children: [
            IconSquare(icon: icon, color: fg, background: fg.withOpacity(0.16)),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleMedium?.copyWith(color: fg)),
                if (subtitle != null) Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
              ]),
            ),
            if (onTap != null) Icon(Icons.chevron_right, color: fg),
          ]),
        ),
      ),
    );
  }
}

/// Pozycja listy w karcie: ikona w kwadracie, tytuł, opis i element po prawej (strzałka, przycisk).
class IconListTile extends StatelessWidget {
  const IconListTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.tone = StatusTone.info,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Kolor ikony.
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Row(children: [
            IconSquare(icon: icon, color: toneColor(context, tone)),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleSmall),
                if (subtitle != null)
                  Text(subtitle!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
            if (trailing != null) trailing! else if (onTap != null) const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Rodzaje zabudowy w grupach wg przewożonego towaru (te same co na serwerze – `BODY_GROUPS`).
const bodyGroups = <String, List<String>>{
  'general': ['curtain', 'mega', 'box', 'jumbo', 'double_deck', 'sliding_roof'],
  'temperature': ['reefer', 'isotherm', 'multitemp'],
  'flat': ['flatbed', 'stake', 'coil'],
  'heavy': ['lowloader', 'extendable', 'modular'],
  'timber': ['timber'],
  'bulk': ['tipper', 'walking_floor', 'silo', 'hopper'],
  'liquid': ['tanker', 'tanker_food', 'tanker_chem', 'tanker_gas', 'tanker_fuel'],
  'containers': ['container', 'swap_body'],
  'special': ['car_transporter', 'livestock', 'glass', 'beverage'],
};

/// Zbiorniki: bez miejsc paletowych, badanie TDT.
const tankBodies = {'tanker', 'tanker_food', 'tanker_chem', 'tanker_gas', 'tanker_fuel', 'silo'};

/// Chłodnie i izotermy: świadectwo ATP.
const atpBodies = {'reefer', 'isotherm', 'multitemp'};

const _groupIcons = <String, IconData>{
  'general': Icons.inventory_2_outlined,
  'temperature': Icons.ac_unit_outlined,
  'flat': Icons.view_stream_outlined,
  'heavy': Icons.construction_outlined,
  'timber': Icons.forest_outlined,
  'bulk': Icons.landslide_outlined,
  'liquid': Icons.water_drop_outlined,
  'containers': Icons.all_inbox_outlined,
  'special': Icons.star_outline,
};

String bodyGroupLabel(AppLocalizations l, String group) => switch (group) {
      'general' => l.bodyGroupGeneral,
      'temperature' => l.bodyGroupTemperature,
      'flat' => l.bodyGroupFlat,
      'heavy' => l.bodyGroupHeavy,
      'timber' => l.bodyGroupTimber,
      'bulk' => l.bodyGroupBulk,
      'liquid' => l.bodyGroupLiquid,
      'containers' => l.bodyGroupContainers,
      'special' => l.bodyGroupSpecial,
      _ => group,
    };

/// Nazwa rodzaju zabudowy; `none` – kreska.
String bodyLabel(AppLocalizations l, String body) => switch (body) {
      'curtain' => l.bodyCurtain,
      'mega' => l.bodyMega,
      'box' => l.bodyBox,
      'jumbo' => l.bodyJumbo,
      'double_deck' => l.bodyDoubleDeck,
      'sliding_roof' => l.bodySlidingRoof,
      'reefer' => l.bodyReefer,
      'isotherm' => l.bodyIsotherm,
      'multitemp' => l.bodyMultitemp,
      'flatbed' => l.bodyFlatbed,
      'stake' => l.bodyStake,
      'coil' => l.bodyCoil,
      'lowloader' => l.bodyLowloader,
      'extendable' => l.bodyExtendable,
      'modular' => l.bodyModular,
      'timber' => l.bodyTimber,
      'tipper' => l.bodyTipper,
      'walking_floor' => l.bodyWalkingFloor,
      'silo' => l.bodySilo,
      'hopper' => l.bodyHopper,
      'tanker' => l.bodyTanker,
      'tanker_food' => l.bodyTankerFood,
      'tanker_chem' => l.bodyTankerChem,
      'tanker_gas' => l.bodyTankerGas,
      'tanker_fuel' => l.bodyTankerFuel,
      'container' => l.bodyContainer,
      'swap_body' => l.bodySwapBody,
      'car_transporter' => l.bodyCarTransporter,
      'livestock' => l.bodyLivestock,
      'glass' => l.bodyGlass,
      'beverage' => l.bodyBeverage,
      _ => '–',
    };

String? bodyDescription(AppLocalizations l, String body) => switch (body) {
      'curtain' => l.bodyDescCurtain,
      'mega' => l.bodyDescMega,
      'coil' => l.bodyDescCoil,
      'lowloader' => l.bodyDescLowloader,
      'walking_floor' => l.bodyDescWalkingFloor,
      'silo' => l.bodyDescSilo,
      'tipper' => l.bodyDescTipper,
      'stake' => l.bodyDescStake,
      _ => null,
    };

/// Okno wyboru rodzaju zabudowy: grupy, filtr, wyszukiwarka. [none] – pozycja „brak” (ciągnik).
Future<String?> pickBody(BuildContext context, AppLocalizations l, String? selected, {bool none = false}) =>
    showGroupedPicker<String>(
      context,
      texts: PickerTexts(title: l.bodyPickerTitle, search: l.bodyPickerSearch, empty: l.pickerEmpty, all: l.pickerAll),
      selected: selected,
      groups: [
        for (final MapEntry(key: group, value: bodies) in bodyGroups.entries)
          PickerGroup(
            bodyGroupLabel(l, group),
            [for (final b in bodies) PickerOption(b, bodyLabel(l, b), subtitle: bodyDescription(l, b))],
            icon: _groupIcons[group],
          ),
        if (none) PickerGroup('–', [PickerOption('none', l.trailerNone)]),
      ],
    );

/// Pole „Rodzaj zabudowy”: nazwa wybranej, kliknięcie otwiera [pickBody].
class BodyField extends StatelessWidget {
  const BodyField({super.key, required this.label, required this.value, required this.onChanged, this.none = false});

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool none;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return PickerField(
      key: key ?? const Key('body-field'),
      label: label,
      value: value == 'none' ? l.trailerNone : bodyLabel(l, value),
      icon: _groupIcons[bodyGroups.entries.where((e) => e.value.contains(value)).firstOrNull?.key],
      onTap: () async {
        final picked = await pickBody(context, l, value, none: none);
        if (picked != null) onChanged(picked);
      },
    );
  }
}

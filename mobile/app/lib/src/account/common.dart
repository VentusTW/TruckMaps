import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Role w firmie (te same co na serwerze), od najwyższej.
const roles = ['owner', 'dispatcher', 'mechanic', 'driver'];

String roleLabel(AppLocalizations l, String? role) => switch (role) {
      'owner' => l.roleOwner,
      'dispatcher' => l.roleDispatcher,
      'mechanic' => l.roleMechanic,
      _ => l.roleDriver,
    };

/// Rodzaje firmy (te same co na serwerze).
const companyKinds = ['carrier', 'forwarder', 'passenger'];

String companyKindLabel(AppLocalizations l, String? kind) => switch (kind) {
      'forwarder' => l.companyKindForwarder,
      'passenger' => l.companyKindPassenger,
      _ => l.companyKindCarrier,
    };

String companyKindHint(AppLocalizations l, String? kind) => switch (kind) {
      'forwarder' => l.companyKindForwarderHint,
      'passenger' => l.companyKindPassengerHint,
      _ => l.companyKindCarrierHint,
    };

/// Role w firmie danego rodzaju: spedycja nie ma floty, więc ani kierowców, ani mechaników.
List<String> rolesFor(String? companyKind) => companyKind == 'forwarder' ? const ['owner', 'dispatcher'] : roles;

/// Jakie pojazdy może mieć firma (jak na serwerze): spedycja – żadnych, transport osób –
/// autobusy i przyczepy, przewoźnik towarów – wszystkie poza autobusami.
bool companyAllows(String? companyKind, String vehicleKind) => switch (companyKind) {
      'forwarder' => false,
      'passenger' => vehicleKind == 'bus' || vehicleKind == 'trailer',
      _ => vehicleKind != 'bus',
    };

/// Bazy, pojazdy firmy i zapraszanie kierowców: właściciel i dyspozytorzy (jak na serwerze).
bool managesCompany(String? role) => role == 'owner' || role == 'dispatcher';

/// Kwota wpisana po polsku albo po angielsku ("4,5" / "4.5"); puste pole = brak.
double? parseAmount(String text) => double.tryParse(text.trim().replaceAll(',', '.'));

/// Waluty do wyboru z serwera (`/api/currencies`); bez połączenia – pusta lista.
Future<List<String>> loadCurrencies(CoreApi api) async {
  try {
    final data = await api.get('/api/currencies') as Map<String, dynamic>;
    return [for (final c in data['currencies'] as List<dynamic>) (c as Map<String, dynamic>)['code'] as String];
  } catch (_) {
    return const [];
  }
}

void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));

/// Pytanie przed nieodwracalnym krokiem (usunięcie, opuszczenie firmy).
Future<bool> confirm(BuildContext context, {required String title, required String question, String? action}) async {
  final l = context.l;
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(question),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action ?? l.delete)),
      ],
    ),
  );
  return sure == true;
}

InputDecoration field(String label, {String? hint, String? suffix}) =>
    InputDecoration(labelText: label, hintText: hint, suffixText: suffix, border: const OutlineInputBorder(), isDense: true);

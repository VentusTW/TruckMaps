import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart' show uiMaps;
import '../l10n.dart';

/// Waluty do wyboru przy przychodzie zlecenia (kursy EBC przelicza serwer).
const revenueCurrencies = ['PLN', 'EUR', 'CZK', 'HUF', 'RON', 'SEK', 'DKK', 'NOK', 'CHF', 'GBP'];

/// Liczba z pola tekstowego (przecinek albo kropka, spacje ignorowane); `null` – puste lub błędne.
double? parseAmount(String text) {
  final cleaned = text.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');
  if (cleaned.isEmpty) return null;
  final value = double.tryParse(cleaned);
  return value == null || value < 0 ? null : value;
}

String _revenuePath(String companyId, String assignmentId) =>
    '/api/companies/${Uri.encodeComponent(companyId)}/route-assignments/${Uri.encodeComponent(assignmentId)}/revenue';

/// Zapis przychodu zlecenia (kwota albo stawka za km).
Future<Map<String, dynamic>> saveRevenue(CoreApi api, String companyId, String assignmentId,
    {double? amount, double? ratePerKm, String currency = 'PLN'}) async {
  final saved = await api.put(_revenuePath(companyId, assignmentId), {
    if (amount != null) 'amount': amount,
    if (ratePerKm != null) 'rate_per_km': ratePerKm,
    'currency': currency,
  });
  return Map<String, dynamic>.from(saved as Map);
}

/// Podsumowanie przychodów (`/api/companies/{id}/revenue/summary`); `null` – brak dostępu lub błąd.
Future<Map<String, dynamic>?> loadRevenueSummary(CoreApi api, String? companyId, {int months = 6}) async {
  if (companyId == null) return null;
  try {
    final r = await api.get('/api/companies/${Uri.encodeComponent(companyId)}/revenue/summary?months=$months');
    return r is Map && r.containsKey('total') ? Map<String, dynamic>.from(r) : null;
  } catch (_) {
    return null;
  }
}

/// Tankowania z kart paliwowych (`/api/companies/{id}/fuel-cards/summary`) w PLN według pojazdu
/// (`null` – tankowania bez rozpoznanego pojazdu); `null` – brak importu albo funkcji.
Future<Map<String?, double>?> loadFuelCardCost(CoreApi api, String? companyId, {int months = 6}) async {
  if (companyId == null) return null;
  try {
    final r = await api.get('/api/companies/${Uri.encodeComponent(companyId)}/fuel-cards/summary?months=$months');
    if (r is! Map || ((r['count'] as num?) ?? 0) == 0) return null;
    return {
      for (final v in uiMaps(r['vehicles']))
        v['vehicle_id'] as String?: (((v['amount'] as Map?)?['PLN'] as num?) ?? 0).toDouble(),
    };
  } catch (_) {
    return null;
  }
}

/// Pola kwoty, waluty i stawki za km – w okienku wysyłki trasy i w edycji przychodu.
class RevenueFields extends StatelessWidget {
  const RevenueFields({
    super.key,
    required this.amount,
    required this.rate,
    required this.currency,
    required this.onCurrency,
  });

  final TextEditingController amount;
  final TextEditingController rate;
  final String currency;
  final ValueChanged<String> onCurrency;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    const number = TextInputType.numberWithOptions(decimal: true);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: TextField(
            key: const Key('revenue-amount'),
            controller: amount,
            keyboardType: number,
            decoration: InputDecoration(labelText: l.revAmount, border: const OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 110,
          child: DropdownButtonFormField<String>(
            key: const Key('revenue-currency'),
            value: currency,
            decoration: InputDecoration(labelText: l.revCurrency, border: const OutlineInputBorder()),
            items: [for (final c in revenueCurrencies) DropdownMenuItem(value: c, child: Text(c))],
            onChanged: (c) => onCurrency(c ?? currency),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      TextField(
        key: const Key('revenue-rate'),
        controller: rate,
        keyboardType: number,
        decoration: InputDecoration(labelText: l.revRatePerKm, border: const OutlineInputBorder()),
      ),
    ]);
  }
}

/// Okienko przychodu jednego zlecenia: zapis, usunięcie. Zwraca `true`, gdy coś zmieniono.
Future<bool> editRevenue(BuildContext context, CoreApi api, String companyId, Map<String, dynamic> order) async {
  final l = context.l;
  final messenger = ScaffoldMessenger.maybeOf(context);
  String fmt(dynamic v) => v is num ? '$v'.replaceAll('.', ',') : '';
  final amount = TextEditingController(text: order['rate_per_km'] == null ? fmt(order['amount']) : '');
  final rate = TextEditingController(text: fmt(order['rate_per_km']));
  var currency = '${order['currency'] ?? 'PLN'}';
  if (!revenueCurrencies.contains(currency)) currency = 'PLN';
  String? error;
  final had = order['amount'] != null;
  final result = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(l.revEdit),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${order['label'] ?? ''}'),
            if (order['distance_km'] is num) Text('${(order['distance_km'] as num).round()} km'),
            const SizedBox(height: 12),
            RevenueFields(
                amount: amount, rate: rate, currency: currency, onCurrency: (c) => setState(() => currency = c)),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ]),
        ),
        actions: [
          if (had)
            TextButton(
              key: const Key('revenue-remove'),
              onPressed: () => Navigator.pop(context, 'delete'),
              child: Text(l.revRemove),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          FilledButton(
            key: const Key('revenue-save'),
            onPressed: () {
              if (parseAmount(amount.text) == null && parseAmount(rate.text) == null) {
                setState(() => error = l.revInvalid);
                return;
              }
              Navigator.pop(context, 'save');
            },
            child: Text(l.save),
          ),
        ],
      ),
    ),
  );
  final value = parseAmount(amount.text), perKm = parseAmount(rate.text);
  if (result == null) return false;
  final id = '${order['assignment_id']}';
  try {
    if (result == 'delete') {
      await api.delete(_revenuePath(companyId, id));
    } else {
      await saveRevenue(api, companyId, id, amount: value, ratePerKm: value == null ? perKm : null, currency: currency);
    }
    return true;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}

/// Lista zleceń transportowych z okresu z przychodami – stuknięcie otwiera edycję.
class RevenueOrdersDialog extends StatefulWidget {
  const RevenueOrdersDialog({super.key, required this.api, required this.companyId, this.months = 6});

  final CoreApi api;
  final String companyId;
  final int months;

  @override
  State<RevenueOrdersDialog> createState() => _RevenueOrdersDialogState();
}

class _RevenueOrdersDialogState extends State<RevenueOrdersDialog> {
  Map<String, dynamic>? _summary;
  bool _loaded = false, _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await loadRevenueSummary(widget.api, widget.companyId, months: widget.months);
    if (mounted) {
      setState(() {
        _summary = s;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final orders = uiMaps(_summary?['orders']);
    return AlertDialog(
      title: Text(l.revTitle),
      content: SizedBox(
        width: 560,
        height: 420,
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : _summary == null
                ? Center(child: Text(l.revNoAccess, textAlign: TextAlign.center))
                : orders.isEmpty
                    ? Center(child: Text(l.revNone, textAlign: TextAlign.center))
                    : ListView(children: [
                        for (final o in orders)
                          ListTile(
                            key: Key('revenue-order-${o['assignment_id']}'),
                            leading: const Icon(Icons.local_shipping_outlined),
                            title: Text('${o['label']}'),
                            subtitle: Text([
                              if (o['plate'] != null) '${o['plate']}',
                              if (o['distance_km'] is num) '${(o['distance_km'] as num).round()} km',
                              if (DateTime.tryParse('${o['created_at']}') case final d?)
                                DateFormat.yMd(l.localeName).format(d.toLocal()),
                            ].join(' · ')),
                            trailing: Text(
                              o['amount'] is num
                                  ? '${l.number(o['amount'] as num, decimals: 2)} ${o['currency']}'
                                  : l.revMissing,
                              style: o['amount'] is num
                                  ? theme.textTheme.titleSmall
                                  : theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                            ),
                            onTap: () async {
                              if (await editRevenue(context, widget.api, widget.companyId, o)) {
                                _changed = true;
                                await _load();
                              }
                            },
                          ),
                      ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, _changed), child: Text(l.revClose)),
      ],
    );
  }
}

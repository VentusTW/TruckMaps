import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

/// Firma: dane i dostęp do zmian udzielony przez właściciela (zakres, termin, stan).
class CompanyDialog extends StatelessWidget {
  const CompanyDialog({super.key, required this.api, required this.companyId});

  final CoreApi api;
  final String companyId;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      content: SizedBox(
        width: 520,
        child: FutureBuilder<dynamic>(
          future: api.get('/api/admin/companies/$companyId'),
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text('${snapshot.error}');
            if (!snapshot.hasData) return const LinearProgressIndicator();
            final company = snapshot.data as Map<String, dynamic>;
            final grants = (company['grants'] as List<dynamic>).cast<Map<String, dynamic>>();
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${company['name']}', style: Theme.of(context).textTheme.titleLarge),
              SelectableText([
                if (company['tax_id'] != null) '${l.colTaxId}: ${company['tax_id']}',
                '${l.colCurrency}: ${company['cost_currency']}',
                'id: ${company['id']}',
              ].join('\n')),
              const SizedBox(height: 16),
              Text(l.companyGrants, style: Theme.of(context).textTheme.titleSmall),
              if (grants.isEmpty) Text(l.companyNoGrants),
              for (final grant in grants) _grant(l, grant),
            ]);
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.close))],
    );
  }

  Widget _grant(AdminLocalizations l, Map<String, dynamic> grant) {
    final scopes = (grant['scopes'] as List<dynamic>).map((s) => l.scope('$s')).join(', ');
    final until = l.when(DateTime.parse('${grant['expires_at']}'));
    final active = grant['active'] == true;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: active,
      leading: Icon(active ? Icons.lock_open : Icons.lock_outline),
      title: Text(active ? l.grantActive(scopes, until) : l.grantInactive(scopes, until)),
      subtitle: '${grant['note']}'.isEmpty ? null : Text('${grant['note']}'),
    );
  }
}

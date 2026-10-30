import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import 'common.dart';

/// Pierwsze logowanie bez firmy: założenie firmy, dołączenie kodem albo praca na własną rękę.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.api, required this.onDone, required this.onLogout});

  final CoreApi api;

  /// Po wyborze (firma założona, dołączenie, „sam”) – ekran główny wczytuje konto od nowa.
  final VoidCallback onDone;
  final VoidCallback onLogout;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _open(Widget form) async {
    final done = await Navigator.of(context).push<dynamic>(MaterialPageRoute(builder: (_) => form));
    if (done != null && mounted) widget.onDone();
  }

  Future<void> _alone() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.put('/api/me/settings', {'onboarded': true});
      widget.onDone();
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
    Widget choice(IconData icon, String title, String hint, VoidCallback onTap) => Card(
          child: ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(hint),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : onTap,
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(l.onboardingTitle),
        actions: [TextButton.icon(onPressed: widget.onLogout, icon: const Icon(Icons.logout), label: Text(l.logout))],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
            Text(l.onboardingQuestion, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            choice(Icons.business_outlined, l.onboardingCompany, l.onboardingCompanyHint,
                () => _open(CompanyCreateScreen(api: widget.api))),
            choice(Icons.vpn_key_outlined, l.onboardingJoin, l.onboardingJoinHint,
                () => _open(JoinCompanyScreen(api: widget.api))),
            choice(Icons.person_outline, l.onboardingAlone, l.onboardingAloneHint, _alone),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Nowa firma; zakładający zostaje jej właścicielem. Zwraca firmę z serwera.
class CompanyCreateScreen extends StatefulWidget {
  const CompanyCreateScreen({super.key, required this.api, this.currency = 'EUR'});

  final CoreApi api;

  /// Waluta podpowiadana na start (np. waluta wybrana w koncie).
  final String currency;

  @override
  State<CompanyCreateScreen> createState() => _CompanyCreateScreenState();
}

class _CompanyCreateScreenState extends State<CompanyCreateScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _taxId = TextEditingController();
  late String _currency = widget.currency;
  List<String> _currencies = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    loadCurrencies(widget.api).then((list) {
      if (mounted) setState(() => _currencies = list);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _taxId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final taxId = _taxId.text.trim();
    try {
      final saved = await widget.api.post('/api/companies', {
        'name': _name.text.trim(),
        'tax_id': taxId.isEmpty ? null : taxId,
        'cost_currency': _currency,
      });
      if (mounted) Navigator.of(context).pop(saved);
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
    return Scaffold(
      appBar: AppBar(title: Text(l.companyCreateTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(l.companyCreateHint, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          TextFormField(
            controller: _name,
            maxLength: 200,
            decoration: field(l.companyName, hint: l.companyNameHint),
            validator: (text) => (text ?? '').trim().length < 2 ? l.companyNameRequired : null,
          ),
          TextFormField(controller: _taxId, maxLength: 30, decoration: field(l.companyTaxId)),
          DropdownButtonFormField<String>(
            value: _currency,
            decoration: field(l.companyCurrency),
            items: [
              for (final code in _currencies.contains(_currency) ? _currencies : [_currency, ..._currencies])
                DropdownMenuItem(value: code, child: Text(code)),
            ],
            onChanged: (value) => setState(() => _currency = value ?? _currency),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.business_outlined),
            label: Text(_busy ? l.saving : l.companyCreate),
          ),
        ]),
      ),
    );
  }
}

/// Dołączenie do firmy kodem zaproszenia (rola jest w kodzie). Zwraca firmę z serwera.
class JoinCompanyScreen extends StatefulWidget {
  const JoinCompanyScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<JoinCompanyScreen> createState() => _JoinCompanyScreenState();
}

class _JoinCompanyScreenState extends State<JoinCompanyScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final joined = await widget.api.post('/api/invites/${Uri.encodeComponent(_code.text.trim())}/accept', {});
      if (mounted) Navigator.of(context).pop(joined);
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
    return Scaffold(
      appBar: AppBar(title: Text(l.joinTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(l.joinHint, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          TextFormField(
            controller: _code,
            maxLength: 16,
            textCapitalization: TextCapitalization.characters,
            decoration: field(l.joinCode, hint: 'ABCD2345'),
            validator: (text) => (text ?? '').trim().isEmpty ? l.joinCodeRequired : null,
            onFieldSubmitted: (_) => _join(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _join,
            icon: const Icon(Icons.login),
            label: Text(_busy ? l.saving : l.join),
          ),
        ]),
      ),
    );
  }
}

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import 'common.dart';
import 'onboarding.dart';
import 'password.dart';

/// Konto: imię widoczne w firmach, język aplikacji, domyślna waluta kosztów, firmy i wylogowanie.
class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.api,
    required this.settings,
    required this.onChanged,
    required this.onLanguage,
    required this.onLogout,
  });

  final CoreApi api;

  /// Ustawienia z `/api/me/settings`.
  final Map<String, dynamic> settings;

  /// Po zmianie ustawień albo firm – ekran główny wczytuje konto od nowa.
  final VoidCallback onChanged;

  /// Wybrany język aplikacji; `null` = język telefonu.
  final ValueChanged<String?> onLanguage;
  final VoidCallback onLogout;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.settings['display_name'] as String? ?? '');
  late String? _currency = widget.settings['currency'] as String?;
  late String? _language = widget.settings['language'] as String?;
  List<String> _currencies = const [];
  bool _busy = false;

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
    super.dispose();
  }

  /// Zapis jednego ustawienia; serwer zmienia tylko podane pola.
  Future<bool> _put(Map<String, dynamic> change) async {
    setState(() => _busy = true);
    try {
      await widget.api.put('/api/me/settings', change);
      widget.onChanged();
      return true;
    } catch (error) {
      if (mounted) showError(context, error);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveName() async {
    if (!_form.currentState!.validate()) return;
    if (await _put({'display_name': _name.text.trim()}) && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.accountSaved)));
    }
  }

  Future<void> _changeLanguage(String? language) async {
    final previous = _language;
    setState(() => _language = language);
    if (await _put({'language': language})) {
      widget.onLanguage(language);
    } else if (mounted) {
      setState(() => _language = previous);
    }
  }

  Future<void> _changeCurrency(String? currency) async {
    final previous = _currency;
    setState(() => _currency = currency);
    if (!await _put({'currency': currency}) && mounted) setState(() => _currency = previous);
  }

  Future<void> _open(Widget form) async {
    final done = await Navigator.of(context).push<dynamic>(MaterialPageRoute(builder: (_) => form));
    if (done != null && mounted) widget.onChanged();
  }

  Future<void> _changePassword() async {
    final changed = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => ChangePasswordScreen(api: widget.api)));
    if (changed == true && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.passwordChanged)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final currencies = [
      ..._currencies,
      if (_currency != null && !_currencies.contains(_currency)) _currency!,
    ];
    return Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text(l.accountProfile, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextFormField(
              controller: _name,
              maxLength: 200,
              decoration: field(l.accountName, hint: l.accountNameHint),
              validator: (text) => (text ?? '').trim().isEmpty ? l.accountNameRequired : null,
              onFieldSubmitted: (_) => _saveName(),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(onPressed: _busy ? null : _saveName, child: Text(l.save)),
        ]),
        DropdownButtonFormField<String?>(
          value: _language,
          decoration: field(l.accountLanguage),
          items: [
            DropdownMenuItem(value: null, child: Text(l.accountLanguageDevice)),
            for (final locale in AppLocalizations.supportedLocales)
              DropdownMenuItem(
                value: locale.languageCode,
                child: Text(lookupAppLocalizations(locale).languageName),
              ),
          ],
          onChanged: _busy ? null : _changeLanguage,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String?>(
          value: _currency,
          decoration: field(l.accountCurrency),
          items: [
            DropdownMenuItem(value: null, child: Text(l.accountCurrencyAuto)),
            for (final code in currencies) DropdownMenuItem(value: code, child: Text(code)),
          ],
          onChanged: _busy ? null : _changeCurrency,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 16),
          child: Text(l.accountCurrencyHint, style: theme.textTheme.bodySmall),
        ),
        Text(l.accountCompanies, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: () => _open(CompanyCreateScreen(api: widget.api, currency: _currency ?? 'EUR')),
            icon: const Icon(Icons.business_outlined),
            label: Text(l.companyCreate),
          ),
          OutlinedButton.icon(
            onPressed: () => _open(JoinCompanyScreen(api: widget.api)),
            icon: const Icon(Icons.vpn_key_outlined),
            label: Text(l.onboardingJoin),
          ),
        ]),
        const SizedBox(height: 24),
        Text(l.accountSecurity, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _changePassword,
            icon: const Icon(Icons.lock_reset),
            label: Text(l.passwordChangeTitle),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.tonalIcon(onPressed: widget.onLogout, icon: const Icon(Icons.logout), label: Text(l.logout)),
      ]),
    );
  }
}

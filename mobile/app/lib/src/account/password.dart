import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../auth.dart';
import '../l10n.dart';
import 'common.dart';

/// Te same zasady co na serwerze (i w Zitadelu): 8 znaków, wielka i mała litera, cyfra, symbol.
String? passwordProblem(AppLocalizations l, String? text) {
  final password = text ?? '';
  final strong = password.length >= 8 &&
      RegExp('[A-Z]').hasMatch(password) &&
      RegExp('[a-z]').hasMatch(password) &&
      RegExp(r'\d').hasMatch(password) &&
      RegExp('[^A-Za-z0-9]').hasMatch(password);
  return strong ? null : l.passwordRules;
}

final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// „Nie pamiętasz hasła?”: adres e-mail → serwer prosi dostawcę logowania o link do ustawienia
/// nowego hasła. Hasło nigdy nie idzie e-mailem; odpowiedź nie zdradza, czy konto istnieje.
class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key, required this.login});

  final BrowserLogin login;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();
  bool _busy = false;
  String? _sent;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await widget.login
          .requestPasswordReset(_address.text.trim(), language: Localizations.localeOf(context).languageCode);
      if (mounted) setState(() => _sent = sent);
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
      appBar: AppBar(title: Text(l.passwordResetTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(l.passwordResetHint),
          const SizedBox(height: 16),
          TextFormField(
            controller: _address,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: field(l.passwordResetEmail),
            validator: (text) => _email.hasMatch((text ?? '').trim()) ? null : l.passwordResetEmailInvalid,
            onFieldSubmitted: (_) => _send(),
          ),
          const SizedBox(height: 16),
          if (_sent != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_sent!, style: TextStyle(color: theme.colorScheme.primary)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.mail_outline),
            label: Text(_busy ? l.saving : l.passwordResetSend),
          ),
        ]),
      ),
    );
  }
}

/// Zmiana hasła w ustawieniach konta: obecne hasło i dwa razy nowe.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.post('/api/me/password', {'current_password': _current.text, 'new_password': _new.text});
      if (mounted) Navigator.of(context).pop(true);
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
    Widget secret(TextEditingController controller, String label, String? Function(String?) validator) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextFormField(
            controller: controller,
            obscureText: true,
            decoration: field(label),
            validator: validator,
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(l.passwordChangeTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          secret(_current, l.passwordCurrent, (text) => (text ?? '').isEmpty ? l.passwordCurrentRequired : null),
          secret(_new, l.passwordNew, (text) => passwordProblem(l, text)),
          secret(_repeat, l.passwordRepeat, (text) => text == _new.text ? null : l.passwordMismatch),
          Text(l.passwordRules, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.lock_reset),
            label: Text(_busy ? l.saving : l.passwordChange),
          ),
        ]),
      ),
    );
  }
}

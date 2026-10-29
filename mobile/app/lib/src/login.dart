import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'auth.dart';
import 'l10n.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.serverUrl, required this.login, required this.onLoggedIn});

  final String serverUrl;
  final BrowserLogin login;
  final ValueChanged<Session> onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final l = context.l;
      widget.onLoggedIn(await widget.login.login(donePage: l.loginBrowserDone, failedPage: l.loginFailed));
    } on LoginFailure catch (failure) {
      if (mounted) setState(() => _error = _describe(failure));
    } catch (error) {
      if (mounted) setState(() => _error = context.l.loginFailedWithReason('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(LoginFailure failure) {
    final l = context.l;
    return switch (failure.problem) {
      LoginProblem.browser => l.loginBrowserFailed,
      LoginProblem.timeout => l.loginTimeout,
      LoginProblem.failed => failure.detail == null ? l.loginFailed : l.loginFailedWithReason(failure.detail!),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(Icons.local_shipping_outlined, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('TruckMaps', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(l.loginTagline, textAlign: TextAlign.center),
              const SizedBox(height: 32),
              if (kIsWeb)
                Text(l.loginWebLater)
              else
                FilledButton.icon(
                  onPressed: _busy ? null : _login,
                  icon: _busy
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login),
                  label: Text(_busy ? l.loginPending : l.loginWithEmail),
                ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              Text(l.loginServer(widget.serverUrl), textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ]),
          ),
        ),
      ),
    );
  }
}

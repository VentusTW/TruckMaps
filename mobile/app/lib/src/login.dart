import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'auth.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.serverUrl, required this.onLoggedIn});

  final String serverUrl;
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
      widget.onLoggedIn(await BrowserLogin(widget.serverUrl).login());
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              const Text('Trasa dopasowana do twojej ciężarówki.', textAlign: TextAlign.center),
              const SizedBox(height: 32),
              if (kIsWeb)
                const Text('Logowanie w wersji przeglądarkowej będzie później – użyj aplikacji na komputer albo telefon.')
              else
                FilledButton.icon(
                  onPressed: _busy ? null : _login,
                  icon: _busy
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login),
                  label: Text(_busy ? 'Dokończ logowanie w przeglądarce…' : 'Zaloguj się e-mailem'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              Text('Serwer: ${widget.serverUrl}', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ]),
          ),
        ),
      ),
    );
  }
}

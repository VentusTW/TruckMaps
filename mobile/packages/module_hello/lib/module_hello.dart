/// Moduł testowy Hello: pokazuje, jak pakiet modułu dodaje ekran do powłoki
/// i woła własne API (`/api/m/hello/...` – dostęp sprawdza serwer).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

class HelloModule extends TruckMapsModule {
  @override
  String get id => 'hello';

  @override
  String get name => 'Hello (moduł testowy)';

  @override
  String get description => 'Wzór modułu: powitanie z serwera i koszt trasy z gniazda kosztów.';

  @override
  List<ModuleEntry> entries(ModuleContext context) => [
        ModuleEntry(
          title: 'Powitanie',
          icon: Icons.waving_hand_outlined,
          builder: (_) => GreetingScreen(api: context.api),
        ),
      ];
}

class GreetingScreen extends StatelessWidget {
  const GreetingScreen({super.key, required this.api});

  final CoreApi api;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<dynamic>(
      future: api.get('/api/m/hello/greeting'),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final greeting = snapshot.data as Map<String, dynamic>;
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${greeting['message']}', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('Rdzeń ${greeting['core_version']}'),
          ]),
        );
      },
    );
  }
}

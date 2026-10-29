# mobile

Aplikacja Flutter (Android, iOS, Windows, panel webowy) – faza 2.

- `app/` – powłoka (rdzeń): logowanie, pojazdy, menu modułów, ekran „Kup moduł”
- `packages/core_sdk/` – kontrakty dla pakietów modułów (`TruckMapsModule`, `ModuleRegistry`, `CoreApi`)
- `packages/module_<id>/` – ekrany jednego modułu (wzór: `module_hello`)

Uruchomienie na komputerze (serwer TruckMaps pod http://localhost:8000):

```
cd mobile/app
flutter run -d windows
```

Inny serwer: `flutter run -d windows --dart-define=TRUCKMAPS_SERVER=http://adres:8000`.
Logowanie otwiera przeglądarkę; po zalogowaniu serwer wraca do aplikacji na adres
127.0.0.1 z jednorazowym kodem, który aplikacja wymienia na token.

Nowy moduł: pakiet `packages/module_<id>` z klasą `TruckMapsModule` (to samo `id` co moduł
na serwerze), dopisany do `app/pubspec.yaml` i do listy w `app/lib/main.dart`. Moduł importuje
tylko `core_sdk` – nie powłokę ani inne moduły.

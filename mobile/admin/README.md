# TruckMaps – program administracyjny

Osobny program dla administratorów projektu (nie dla klientów): wgląd w konta, firmy, członków,
zaproszenia, bazy, pojazdy, zgłoszenia, wydania, licencje i dziennik działań administratorów.

- Logowanie przez Zitadela w przeglądarce (pakiet `app_auth`), sesja osobno od aplikacji.
- Dostęp tylko dla kont nadanych na serwerze: `python -m truckmaps.core.admin add <sub> --role full|support`.
- Serwer wymaga drugiego składnika logowania (`TRUCKMAPS_ADMIN_REQUIRE_MFA`, domyślnie włączone).
- Każde wywołanie `/api/admin` trafia do dziennika (kto, co, kiedy, IP, urządzenie, wynik).

Uruchomienie: `flutter run -d windows --dart-define=TRUCKMAPS_SERVER=http://localhost:8000`.
Wersja w przeglądarce – po logowaniu web (punkt planu w Fazie 2).

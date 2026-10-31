# module_service

Moduł Serwis w aplikacji TruckMaps (serwer: `backend/modules/service`).

- **Zgłoszenie usterki** – każdy, kto widzi pojazd (kierowca, dyspozytor, właściciel, mechanik):
  pojazd, opis, „może jechać” albo „stoi” (pojazd stojący jest od razu „w naprawie”).
- **Zlecenie** – mechanik, dyspozytor albo właściciel: przyjmuje, rozpoczyna naprawę (pojazd
  „w naprawie”), zamyka protokołem (czynności, części z ilością i ceną, czas pracy, przebieg,
  uwagi) albo odrzuca z powodem.
- **Historia** – zamknięte zlecenia pojazdu z protokołami.

Teksty po polsku i po angielsku (`lib/src/texts.dart`, funkcja `pick` z `core_sdk`).

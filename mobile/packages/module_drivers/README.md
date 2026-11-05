# module_drivers

Moduł Kierowcy w aplikacji TruckMaps (serwer: `backend/modules/drivers`).

- **Kartoteka** – właściciel i dyspozytorzy: dodawanie, zmiana i usuwanie kierowców (z kontem
  w firmie albo tylko wpis); kierowca z kontem widzi swoją kartę.
- **Kwalifikacje i terminy** – kategorie prawa jazdy, prawo jazdy, kod 95, badania lekarskie
  i psychologiczne, karta kierowcy, pobranie danych z karty (co 28 dni, przycisk „pobrano dziś”),
  ADR (z cysternami), świadectwo kierowcy; stan „wkrótce” / „po terminie”.
- **Pojazdy** – przydział i zwolnienie; przed przydziałem ostrzeżenia o uprawnieniach
  (kategoria vs rodzaj i DMC zestawu, ADR, przeterminowane badania).
- **Przejazdy** – sumy, miesiące, pojazdy, ostatnie przejazdy; **Historia** – przydziały od–do
  i zmiany w kartotece (kto, kiedy, co).

Teksty po polsku i po angielsku (`lib/src/texts.dart`, funkcja `pick` z `core_sdk`).

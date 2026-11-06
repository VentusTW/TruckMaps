# module_documents

Moduł Dokumenty w aplikacji TruckMaps (serwer: `backend/modules/documents`).

- **Lista dokumentów firmy** – numer, rodzaj, autor; nowy dokument po wyborze rodzaju
  (CMR, zlecenie transportowe, karta drogowa), także z karty pojazdu („Nowy dokument”).
- **Formularz** – pola wg wzoru firmy, „Wypełnij z danych” (firma, pojazd z naczepą, kierowca,
  przejazdy w okresie – karta drogowa) z opisem źródła przy polu, tabele (towar, przystanki,
  przejazdy), zapis, PDF pod krótkim linkiem w przeglądarce, usunięcie.
- **Dane firmy i logo** (właściciel, dyspozytorzy) – adres, NIP, licencja, polisa OCP, konto…;
  logo z galerii, drukowane w nagłówku dokumentów.
- **Wzory** (właściciel, dyspozytorzy) – zmiana nazw pól, wartości domyślne, ukrywanie pól,
  pola firmy (tekst, tekst wielowierszowy, liczba, data; szerokość na wydruku), warunki na końcu.

Teksty po polsku i po angielsku (`lib/src/texts.dart`); etykiety pól dokumentów – z serwera.

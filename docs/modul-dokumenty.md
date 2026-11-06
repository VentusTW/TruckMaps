# Moduł „Dokumenty” – propozycja i stan

Katalog dokumentów i mapowanie pól: `docs/dokumenty-transportowe.md`.

## Założenia

- Osobny pakiet `truckmaps-module-documents` (`backend/modules/documents`), id `documents`,
  API pod `/api/m/documents`, licencja jak każdy moduł. Korzysta tylko z `truckmaps.sdk`.
- Bez zależności od innych modułów. Dane z modułów Plan załadunku i Kierowcy oraz trasa
  z planera trafiają do dokumentu przez aplikację (pola `route`, `cargo`, `driver`
  w żądaniu autouzupełnienia). Gdy moduł Kierowcy zechce podawać dane osobowe kierowcy
  (nr prawa jazdy, data urodzenia), dojdzie gniazdo rozszerzeń w SDK – bez importów.
- Darmowo: PDF generuje własny, mały zapis PDF (czcionka standardowa Helvetica,
  kodowanie środkowoeuropejskie – polskie znaki bez dołączania plików czcionek),
  do tego strona HTML do druku jak protokół naprawy w module Serwis.
- Wszystkie etykiety pól i komunikaty w `locales/{pl,en}.json` modułu.

## Rdzeń (SDK) – drobne rozszerzenia

- `Fleet.company(db, company_id) -> CompanyInfo` (nazwa, NIP, rodzaj firmy).
- `DrivingInfo.trailer_plate`, `DrivingInfo.odometer_km` – nr rejestracyjny podpiętej
  naczepy i stan licznika (CMR, zlecenie, karta drogowa).

## Dane modułu (migracje w gałęzi `documents`)

| Tabela | Zawartość |
| --- | --- |
| `document_profiles` | profil firmy do dokumentów (JSON): pełna nazwa, adres, kraj, NIP/VAT UE, REGON, KRS, EORI, nr licencji, polisa OCP, konto, osoba upoważniona, telefon, e-mail, miejsce wystawiania; logo (JPEG) |
| `document_templates` | edytowalny wzór firmy dla rodzaju dokumentu: zmienione nazwy pól, wartości domyślne, pola ukryte, pola dodane przez firmę (`x_…`: tekst, tekst wielowierszowy, liczba, data; szerokość na wydruku), warunki na końcu dokumentu |
| `documents` | wystawione dokumenty: rodzaj, numer (`CMR/2026/11/0001`), pojazd, dane pól (JSON), autor, daty |

## API

| Metoda | Ścieżka | Opis |
| --- | --- | --- |
| GET | `/kinds` | rodzaje dokumentów z polami (etykiety w języku użytkownika), podstawą prawną |
| GET/PUT | `/profile?company_id=` | profil firmy z podglądem logo (zapis: właściciel, dyspozytor) |
| GET/PUT/DELETE | `/profile/logo?company_id=` | logo – PNG/JPEG z aplikacji, zapis jako JPEG (do 800×300 px) |
| GET/PUT | `/templates/{kind}?company_id=` | wzór firmy i pola formularza wg niego (zapis: właściciel, dyspozytor) |
| POST | `/prefill` | autouzupełnianie: firma + profil + szablon + pojazd (+ naczepa, kierowca, licznik) + trasa + ładunek + przejazdy (karta drogowa); zwraca wartości i źródło każdego pola |
| GET/POST | `/documents` | lista i wystawienie (numer nadaje serwer) |
| GET/PUT/DELETE | `/documents/{id}` | odczyt, poprawka, usunięcie (autor albo obsługa firmy) |
| GET | `/documents/{id}/pdf` · `/html` | eksport PDF / strona do druku |
| POST | `/documents/{id}/link` | krótki link (PDF) do otwarcia w przeglądarce telefonu |

Uprawnienia: dokumenty widzą członkowie firmy; profil i szablony zmieniają właściciel
i dyspozytor; dokument poprawia lub usuwa jego autor albo obsługa firmy.

## Etapy

1. **Zrobione:** CMR, zlecenie transportowe, karta drogowa – wzory firmy (nazwy pól, pola
   firmy, ukrywanie, wartości domyślne, warunki), logo, autouzupełnianie, numeracja, PDF/HTML,
   testy (`backend/modules/documents/tests`).
2. **Zrobione:** aplikacja – pakiet `mobile/packages/module_documents`: lista, formularz
   z podpowiedziami (źródło przy polu), „Nowy dokument” z karty pojazdu, dane firmy i logo,
   edytor wzorów, PDF przez krótki link. Do zrobienia: „Dokument” z planera (trasa i plan
   załadunku przekazywane do `/prefill` – API je przyjmuje, w aplikacji brak przycisku).
3. Kolejne szablony: POD / protokół załadunku z podpisem na ekranie, protokół szkody,
   zaświadczenie o działalności (wzór 2009/959/UE), polecenie wyjazdu z dietami,
   dokument przewozowy ADR, lista „pakiet w kabinie”, dane do IMI / SENT (do przepisania
   w portalu, numer referencyjny wraca do dokumentu).
4. Książka kontrahentów (nadawcy, odbiorcy, zleceniodawcy) i podpowiedzi z poprzednich
   dokumentów.
5. e-CMR / eFTI (rozporządzenie (UE) 2020/1056 – platformy eFTI, organy kontrolne mają przyjmować dane elektroniczne) – po wyborze darmowego, otwartego standardu wymiany (UN/CEFACT eCMR) – osobny
   moduł.

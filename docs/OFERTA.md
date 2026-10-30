# Oferta: typy kont, moduły i plany (propozycja do akceptacji)

**Plany i ceny są na razie poglądowe** – ustala je i zmienia administrator (program
administracyjny: plany, ceny, promocje czasowe dla grup). Ceny orientacyjne netto, w euro
jak w `PLAN.md` (w PLN po kursie, zaokrąglone „ładnie”).
Nic tu nie jest jeszcze wdrożone poza rdzeniem i kontami firm z rolami; płatności przyjdą
później (zob. „Najpierw bezkosztowo”).

## 1. Typy kont przy zakładaniu konta na stronie projektu

| Typ konta | Dla kogo | Co dostaje na start |
|---|---|---|
| **Przedsiębiorca** (przewoźnik) | właściciel firmy transportowej | firma, role (właściciel, dyspozytor, kierowca), flota, kierowcy; opcjonalnie spedycja |
| **Spedytor** | biuro spedycyjne, spedytor na własny rachunek | osobna firma rodzaju „spedycja” o ograniczonych możliwościach, **tylko towary**: zlecenia, przewoźnicy i ich kierowcy / pojazdy; bez własnej floty |
| **Transport osób** | przewoźnik osób: autobusy, busy, wycieczki, przewozy regularne i okazjonalne | firma, flota autobusów i busów (miejsca siedzące / stojące), kierowcy; później kursy, rozkłady, listy pasażerów |
| **Kierowca** | kierowca zatrudniony albo jeżdżący na swoim | wyznaczanie tras i jeden pojazd; kolejne pojazdy po wykupieniu; do firmy dołącza kodem zaproszenia |

Typ konta to tylko punkt startu: każde konto może później dokupić inne moduły albo
zmienić plan (np. kierowca zakłada firmę, przewoźnik dodaje spedycję).

## 2. Moduły kont (każdy osobno, jak pozostałe moduły)

| # | Moduł | Co daje | Wymaga (w cenie) |
|---|---|---|---|
| K1 | **Firma** | dane firmy, stawki, bazy, członkowie i role, zaproszenia, konta biurowe (właściciel, dyspozytor, spedytor) | – |
| K2 | **Flota** | pojazdy, naczepy i przyczepy firmy, przydział do kierowców, terminy (rozszerza się w M13) | K1 (pakiet) |
| K3 | **Kierowcy** | kierowcy firmy, przydział do pojazdów i zleceń, ich dostęp do modułów kierowcy (M1–M5) | K1 (pakiet) |
| K4 | **Spedycja** | zlecenia (tylko towary), baza przewoźników, przypisanie zlecenia do przewoźnika / pojazdu, statusy (rozszerza się w M7–M10, M14) | K1 (pakiet) |
| K5 | **Transport osób** | kursy i przejazdy okazjonalne, przydział autobusu / busa i kierowcy, liczba pasażerów vs miejsca w pojeździe; później rozkłady, listy pasażerów, zamówienia od klientów (szkoły, biura podróży) | K1 (pakiet); flota (K2) i kierowcy (K3) w planach |

Dzisiejsze ekrany „Firma” i „Członkowie” to zalążek K1; pojazdy firmy – zalążek K2.

**Limit podstawowy (Przedsiębiorca i Spedytor):** 2 konta biurowe, do 5 kierowców i do 5
pojazdów + 5 naczep / przyczep. Ponad limit – dodatki (niżej) albo wyższy plan.

## 3. Plany

### Kierowca

| Plan | Cena | Co zawiera |
|---|---|---|
| **Start** | 0 € | planer trasy pod wymiary, nawigacja z alarmem, 1 pojazd, zgłoszenia, dołączenie do firmy |
| **Plus** | €4,99/mies. | Start + Parkingi i POI (M3) + Czas pracy (M2) |
| **Pro** | €9,99/mies. | Pakiet Kierowca (M1–M5): mapy offline, czas pracy, parkingi, koszty i myto, ADR |
| **Na dni** | tokeny | 1 token = 1 dzień planu Pro (dla jeżdżących okazjonalnie) |

Kierowca w firmie z planem Flota lub wyższym ma Plus w cenie planu firmy.

### Przedsiębiorca

| Plan | Cena | Konta biurowe | Kierowcy | Pojazdy / naczepy | Co zawiera |
|---|---|---|---|---|---|
| **Mała flota** | €29/mies. | 2 | 5 | 5 / 5 | K1 + K2 + K3 |
| **Flota** | €59/mies. | 3 | 10 | 10 / 10 | + terminy i statystyki (M13), raporty (M11), kierowcy z Plus |
| **Flota Pro** | €99/mies. | 5 | 25 | 25 / 25 | + koszty i myto (M4), dokumenty (M14), kierowcy z Pro |
| **Przewoźnik + spedycja** | +€20/mies. do dowolnego planu | – | – | – | + K4 Spedycja |

### Spedytor

| Plan | Cena | Konta biurowe | Kierowcy / pojazdy przewoźników | Co zawiera |
|---|---|---|---|---|
| **Spedytor Start** | €19/mies. | 2 | 5 / 5 | K1 + K4 |
| **Spedytor** | €39/mies. | 4 | 15 / 15 | + dokumenty (M14), raporty (M11) |
| **Spedytor Pro** | €69/mies. | 8 | 50 / 50 | + planer zleceń (M7), integracje giełd (M8, gdy będą umowy) |

### Transport osób

| Plan | Cena | Konta biurowe | Kierowcy | Autobusy / busy | Co zawiera |
|---|---|---|---|---|---|
| **Przewozy Start** | €29/mies. | 2 | 5 | 5 | K1 + K2 + K3 + K5 |
| **Przewozy** | €59/mies. | 3 | 10 | 10 | + terminy (M13), raporty (M11), kierowcy z Plus |
| **Przewozy Pro** | €99/mies. | 5 | 25 | 25 | + koszty i myto (M4), dokumenty (M14), kierowcy z Pro |

### Dodatki (do każdego planu firmowego)

| Dodatek | Miesięcznie | Tokenami |
|---|---|---|
| +1 konto biurowe | €5 | – |
| +1 kierowca | €3 | – |
| +1 pojazd z naczepą | €4 | 1 token = pojazd na 1 dzień (sezonowe szczyty) |
| dokument (CMR, zlecenie) ponad pakiet | – | 1 token |
| oferta na giełdzie TruckMaps (M9) | – | 1–3 tokeny |

## 4. Sposób płatności – użytkownik wybiera i zmienia sam

1. **Miesięcznie** – bez zobowiązań, rezygnacja od kolejnego miesiąca.
2. **Rocznie** – 2 miesiące gratis (~17% taniej), płatne z góry.
3. **Tokeny** (przedpłata) – paczki np. 10 / 50 / 200 tokenów, im większa, tym taniej
   (np. €1,00 / €0,90 / €0,75 za token); ważne 12 miesięcy; zużywane na dni planu Pro,
   dodatkowe pojazdy na dni, dokumenty, oferty.
4. **Mix (polecany)** – subskrypcja (miesięczna lub roczna) z miesięczną pulą tokenów w cenie
   (np. Flota: 20 tokenów/mies., niewykorzystane przechodzą na następny miesiąc); szczyty
   i rzadkie rzeczy z tokenów, bez zmiany planu.

**Zmiany w trakcie:**
- wyższy plan / dodatek – od razu, dopłata proporcjonalnie do końca okresu;
- niższy plan – od kolejnego okresu; dane ponad limit nie znikają, tylko są „tylko do odczytu”;
- zmiana sposobu płatności (miesięcznie ↔ rocznie ↔ tokeny) – od kolejnego okresu;
- 30 dni próbnych planu **Flota** / **Spedytor** / **Przewozy** dla nowych firm, bez karty.

## 5. Co to oznacza technicznie (po akceptacji)

- Rejestracja na stronie: wybór typu konta → po pierwszym logowaniu ekran startowy dopasowany
  do typu (dzisiejszy wybór „mam firmę / dołączam kodem / sam” + „spedytor”).
- K1–K4 jako osobne moduły w `backend/modules/` i `mobile/packages/`, przez SDK rdzenia;
  ekrany Firma i Członkowie przechodzą z rdzenia do K1.
- Licencje w rdzeniu: plan firmy (nie tylko użytkownika), limity (konta biurowe, kierowcy,
  pojazdy, naczepy) sprawdzane na serwerze, tokeny jako „pozostało N użyć” z historią.
- Płatności (Stripe / Przelewy24, faktury KSeF) – dopiero, gdy będą pierwsi płacący
  (prowizje operatorów to jedyny koszt, bez opłat stałych).

## Do decyzji

1. Czy typy kont i podział na moduły K1–K4 są dobre?
2. Ceny i limity planów (szczególnie Mała flota €29 i Spedytor Start €19).
3. Czy tokeny jako waluta wewnętrzna (jedna dla wszystkich modułów), czy osobne pule?
4. Czy darmowy plan Kierowca Start zostaje bez limitu czasu?

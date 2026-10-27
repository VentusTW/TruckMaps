# TruckMaps – plan działania

Nawigacja i planowanie pracy dla kierowców ciężarówek oraz przewoźników.
Zakres startowy: Polska + kraje sąsiednie → Europa → świat.
Model: **darmowy rdzeń + płatne, niezależne moduły** (subskrypcja B2C w sklepach, licencje B2B przez panel floty).

---

## 1. Zasady architektury

### 1.1 Modularny monolit, nie mikroserwisy
Jedna aplikacja backendowa, jedna baza, jeden deploy – bo budujesz sam. Granice między modułami są jednak twarde i pilnowane automatycznie, więc w przyszłości każdy moduł da się wydzielić do osobnej usługi bez przepisywania.

### 1.2 Reguła niezależności
1. **Moduł importuje wyłącznie `truckmaps.sdk`** – nigdy innego modułu ani wnętrza rdzenia.
2. **Moduły nie rozmawiają ze sobą bezpośrednio.** Komunikują się tylko przez:
   - **punkty rozszerzeń** (interfejsy zdefiniowane w rdzeniu, które moduł może dostarczać),
   - **zdarzenia** (wersjonowane schematy zdefiniowane w rdzeniu, np. `route.calculated.v1`).
3. **Każdy moduł ma własne:** tabele w osobnym schemacie bazy (`m_tolls.*`), migracje, endpointy (`/api/m/<id>/…`), testy, ekrany w aplikacji.
4. **Wyłączenie modułu nigdy nie psuje rdzenia ani innych modułów.** Gdy brak dostawcy dla punktu rozszerzenia, rdzeń używa prostej implementacji domyślnej.
5. **Rdzeń nic nie wie o konkretnych modułach** – tylko o kontraktach.

Pilnowanie automatyczne:
- `import-linter` w CI – zakazuje importów moduł→moduł i moduł→wnętrze rdzenia.
- Macierz testów w CI: *sam rdzeń*, *rdzeń + każdy moduł osobno*, *wszystko włączone*.

### 1.3 Punkty rozszerzeń w rdzeniu

| Punkt rozszerzenia | Implementacja domyślna (rdzeń) | Kto dostarcza lepszą |
|---|---|---|
| `RoutingConstraintProvider` – dodatkowe ograniczenia trasy | wymiary/masa/naciski z profilu pojazdu | ADR, Ponadgabaryty |
| `CostProvider` – koszt odcinka/trasy | €/km + €/dzień z profilu kosztów | Opłaty drogowe i koszty |
| `DriverHoursPolicy` – ile i kiedy kierowca może jechać | uproszczona: 9 h jazdy/dzień, 45 min przerwy po 4,5 h | Czas pracy kierowcy (pełne 561/2006, pakiet mobilności) |
| `OfferSource` – źródło ofert frachtowych | ręczne wpisanie oferty | Integracje giełd, Własna giełda |
| `PoiProvider` – punkty na mapie | brak | Parkingi i POI |
| `MapLayerProvider` – dodatkowe warstwy w aplikacji | trasa + kolory ryzyka | dowolny moduł |

Przykład: Planer zleceń używa `CostProvider`, `DriverHoursPolicy` i `OfferSource`. Działa sam (ręczne oferty, prosty koszt, uproszczony czas pracy), a gdy klient dokupi Opłaty, Czas pracy czy Giełdy – automatycznie liczy dokładniej. **Planer nie zna tych modułów**, zna tylko kontrakty rdzenia.

### 1.4 Zdarzenia (definiowane w rdzeniu)

| Zdarzenie | Publikuje | Przykładowi odbiorcy |
|---|---|---|
| `route.calculated.v1` | rdzeń | Opłaty, Raporty |
| `vehicle.position.updated.v1` *(tylko za zgodą)* | rdzeń | Dopasowanie ofert, Panel floty |
| `vehicle.availability.predicted.v1` | rdzeń | Dopasowanie ofert, Planer |
| `offer.published.v1` / `offer.taken.v1` | dostawcy `OfferSource` | Planer, Dopasowanie |
| `trip.completed.v1` | rdzeń | Raporty |

Na start: szyna zdarzeń w procesie (+ tabela outbox w PostgreSQL). Później bez zmian w modułach: Redis Streams / NATS.

### 1.5 Interfejs modułu (backend)

```python
# backend/modules/tolls/module.py
from truckmaps.sdk import Module, CoreContext


class TollsModule(Module):
    id = "tolls"
    version = "1.0.0"
    requires_core = ">=1.0,<2.0"

    def register(self, ctx: CoreContext) -> None:
        ctx.costs.register_provider(TollCostProvider(ctx), priority=100)
        ctx.api.include_router(router, prefix="/m/tolls")
        ctx.events.subscribe("route.calculated.v1", on_route_calculated)
```

- Moduły ładowane przez *entry points* Pythona – instalacja paczki = moduł dostępny.
- Każde wywołanie przechodzi przez **sprawdzenie uprawnień** (`ctx.licensing.require("tolls")`) – moduł zainstalowany ≠ moduł kupiony.

### 1.6 Aplikacja (Flutter)
- **Powłoka** (rdzeń) + **pakiet Flutter na każdy moduł**.
- Moduł rejestruje w powłoce: ekrany, pozycje menu, warstwy mapy, ustawienia.
- Serwer zwraca listę uprawnień użytkownika → powłoka pokazuje moduł albo ekran „Kup moduł”.
- Ten sam kod Flutter dla Androida, iOS i **panelu webowego** (Flutter Web) – jeden język, jedna osoba.
- B2C: zakupy w Google Play / App Store. B2B: licencje kupowane w panelu floty, kierowca tylko się loguje.

### 1.7 Struktura repozytorium

```
TruckMaps/
├── backend/
│   ├── src/truckmaps/sdk/  # JEDYNE publiczne API dla modułów (kontrakty, zdarzenia)
│   ├── src/truckmaps/core/ # wnętrze rdzenia – moduły nie mogą stąd importować
│   │   ├── accounts/       # użytkownicy, firmy, floty
│   │   ├── licensing/      # uprawnienia do modułów, subskrypcje
│   │   ├── vehicles/       # profile pojazdów i kosztów
│   │   ├── routing/        # klient silnika routingu, macierze odległości
│   │   ├── restrictions/   # baza ograniczeń, ocena segmentów (zielony/żółty/czerwony)
│   │   ├── location/       # pozycje (za zgodą), przewidywana dostępność
│   │   ├── notifications/  # push, e-mail
│   │   └── events/         # szyna zdarzeń + outbox
│   ├── modules/<id>/       # każdy moduł = osobna paczka Pythona (src/truckmaps_<id>/)
│   └── tests/
├── data_pipeline/          # import OSM, parsery DATEX II / GDDKiA / plików rządowych
├── mobile/
│   ├── app/                # powłoka Flutter
│   └── packages/
│       ├── core_sdk/
│       └── module_<id>/
├── infra/                  # docker-compose: PostGIS, Valhalla, Redis; konfiguracja serwerów
└── docs/
```

### 1.8 Technologie

| Warstwa | Wybór |
|---|---|
| Backend | Python 3.12+, FastAPI, SQLAlchemy 2, Alembic, Pydantic |
| Baza | PostgreSQL + PostGIS (+ H3 do wyszukiwania w obszarach) |
| Routing | Valhalla (profil `truck`) w Dockerze |
| Dane | osmium/pyosmium, lxml (DATEX II), pdfplumber, geopandas |
| Optymalizacja | Google OR-Tools, NumPy |
| Mapa | MapLibre (aplikacja + web), kafelki Planetiler → PMTiles na Cloudflare R2 |
| Aplikacja | Flutter (Android, iOS, Web) |
| Infrastruktura | Hetzner (serwery dedykowane), Docker, GitHub Actions |
| Monitoring | Sentry, Prometheus + Grafana |

---

## 2. Rdzeń (darmowy, zawsze włączony)

Rdzeń musi dawać realną wartość za darmo – to on przyciąga użytkowników. **Alarm bezpieczeństwa (czerwona trasa) nigdy nie jest płatny.**

- Konto, firma, flota, licencje modułów
- Profil pojazdu: długość, szerokość, wysokość, masa całkowita, naciski osi, typ naczepy
- Profil kosztów: €/km, €/dzień (wykorzystywany przez moduły)
- Wyznaczanie trasy z ograniczeniami (wysokość, masa, długość, szerokość, naciski, zakazy dla ciężarówek)
- Ocena trasy: 🟢 bez problemów / 🟡 zwężenia, ostre zakręty, mały zapas / 🔴 nieprzejezdna
- Nawigacja podstawowa z **korytarzem danych w telefonie** i **migającym czerwonym alarmem** przy wjeździe na nieprzejezdną drogę (działa bez zasięgu)
- Mapa online dla Polski i sąsiadów
- Zgłoszenia od kierowców („tu jest ograniczenie 3,8 m”)
- Lokalizacja i przewidywana dostępność pojazdu – **tylko za zgodą**, z poziomami udostępniania
- Punkty rozszerzeń i zdarzenia (patrz 1.3 i 1.4)

---

## 3. Moduły płatne

Ceny orientacyjne, do weryfikacji na rynku.

| # | Moduł | Co daje | Używa z rdzenia | Dostarcza | Cena (orient.) |
|---|---|---|---|---|---|
| M1 | **Nawigacja Pro** | mapy offline całej Europy, asystent pasa ruchu, Android Auto / CarPlay | routing, mapa | `MapLayerProvider` | €3,99/mies. |
| M2 | **Czas pracy kierowcy** | pełne 561/2006, pauzy, odpoczynki, pakiet mobilności, kabotaż | trasa, pojazd | `DriverHoursPolicy` | €2,99/mies. |
| M3 | **Parkingi i POI** | parkingi dla TIR (bezpieczne, zajętość), MOP, AdBlue, myjnie, serwisy | mapa | `PoiProvider`, `MapLayerProvider` | €1,99/mies. |
| M4 | **Opłaty drogowe i koszty** | myto w krajach UE, paliwo (Weekly Oil Bulletin), pełny koszt trasy | trasa, profil kosztów | `CostProvider` | €2,99/mies. |
| M5 | **ADR i ponadgabaryty** | kategorie tuneli ADR, zakazy dla ładunków niebezpiecznych, przejazdy nienormatywne | routing | `RoutingConstraintProvider` | €2,99/mies. |
| — | *Pakiet Kierowca* (M1–M5) | | | | *€9,99/mies.* |
| M6 | **Panel floty** (web) | flota na mapie (za zgodą), kierowcy, licencje, raporty | konta, lokalizacja | — | €5/pojazd/mies. |
| M7 | **Planer zleceń** | 2–6 kursów do przodu, zysk/dzień, ryzyko regionów | koszty, czas pracy, `OfferSource` | — | €30–60/pojazd/mies. |
| M8 | **Integracje giełd** | oferty z Trans.eu, TimoCom, Teleroute (wymaga umów) | — | `OfferSource` | w cenie M7 lub osobno |
| M9 | **Giełda TruckMaps** | zleceniodawcy wystawiają oferty, przewoźnicy przyjmują | konta | `OfferSource` | prowizja 1–3% / opłata za ofertę |
| M10 | **Dopasowanie ofert** | oferty wysyłane do pasujących, wolnych pojazdów, rozdzielanie sugestii | dostępność, `OfferSource`, powiadomienia | — | w cenie M7 / prowizja |
| M11 | **Raporty i analityka** | zarobki, puste km, statystyki rynku, prognoza vs wynik | zdarzenia | — | €2–5/mies. |

Każdy moduł działa z samym rdzeniem. Przykłady:
- M7 bez M8/M9 – planuje na ofertach wpisanych ręcznie.
- M10 bez M9 – dopasowuje oferty z dowolnego aktywnego `OfferSource` (choćby z M8).
- M4 bez M7 – liczy koszt każdej zwykłej trasy.

---

## 4. Plan działania (jedna osoba)

Czasy orientacyjne. Łącznie: **pierwszy przychód po ~10–12 miesiącach**, pełna platforma po ~30 miesiącach.

### Faza 0 – Przygotowanie (miesiąc 1)
- [x] Repozytorium git, struktura katalogów (1.7), CI (lint, testy, `import-linter`)
- [x] `docker-compose`: PostGIS, Valhalla (Redis dojdzie, gdy szyna zdarzeń wyjdzie poza proces)
- [ ] Decyzja o formie działalności (JDG vs sp. z o.o., IP Box) – z księgowym
- [ ] Konta Google Play i Apple Developer
- [ ] Przegląd licencji danych: OSM (ODbL), GDDKiA, KPD, dane.gov.pl
- [ ] **Pierwszy kontakt z giełdami** (Trans.eu, TimoCom) – negocjacje trwają miesiącami
- [ ] 3–5 znajomych kierowców jako testerzy

**Gotowe, gdy:** `docker compose up` uruchamia pustą usługę z działającym CI.

### Faza 1 – Rdzeń backend (miesiące 2–4)
- [x] `truckmaps.sdk`: klasa `Module`, `CoreContext`, punkty rozszerzeń, schematy zdarzeń
- [x] Ładowanie modułów (entry points) + automatyczne sprawdzanie licencji na routerach modułów
- [ ] Konta, firmy, profile pojazdów i kosztów, logowanie (JWT)
- [ ] Import OSM (PL + DE, CZ, SK, LT) → Valhalla, aktualizacja co tydzień
- [ ] Baza ograniczeń w PostGIS + API trasy z parametrami pojazdu
- [ ] Ocena segmentów: krzywizna zakrętów vs promień skrętu, zwężenia, zapas wysokości → zielony/żółty/czerwony
- [ ] Generowanie korytarza danych dla telefonu
- [x] **Moduł testowy „hello”** udowadniający, że system modułów działa

**Gotowe, gdy:** API zwraca kolorowaną trasę Poznań → Berlin dla zestawu 40 t / 4 m, a testy przechodzą w macierzy „rdzeń” / „rdzeń + hello”.

### Faza 2 – Rdzeń aplikacja (miesiące 5–8)
- [ ] Powłoka Flutter, `core_sdk`, rejestracja modułów, ekran „Kup moduł”
- [ ] Mapa MapLibre, profil pojazdu, wyszukiwanie adresów
- [ ] Planowanie trasy z kolorami ryzyka
- [ ] Nawigacja: GPS, dopasowanie do drogi, komunikaty głosowe, przeliczanie trasy
- [ ] **Alarm czerwony** (miganie, dźwięk, wibracja) liczony lokalnie z korytarza
- [ ] Zgłoszenia od kierowców
- [ ] Zgody na lokalizację, polityka prywatności, regulamin (z prawnikiem)

**Gotowe, gdy:** testerzy przejadą realne trasy, a alarm zadziała na znanym niskim wiadukcie.

### Faza 3 – Dane rządowe i beta (miesiące 9–10)
- [ ] Parsery: GDDKiA, KPD (DATEX II), dane.gov.pl
- [ ] Łączenie źródeł z OSM, rozwiązywanie konfliktów, data aktualności każdego ograniczenia
- [ ] Monitoring, kopie zapasowe, drugi serwer
- [ ] **Publiczna beta w Polsce** (Google Play, potem App Store)

### Faza 4 – Pierwsze moduły płatne + Europa (miesiące 11–14)
- [ ] M2 Czas pracy kierowcy
- [ ] M3 Parkingi i POI
- [ ] M4 Opłaty drogowe i koszty
- [ ] Subskrypcje w sklepach, *Pakiet Kierowca*
- [ ] Rozszerzenie danych na całą UE (krajowe punkty dostępowe, DATEX II), tłumaczenia na 5–10 języków

**Kamień milowy:** pierwszy przychód, cel 140+ płacących (próg rentowności).

### Faza 5 – Panel floty, B2B (miesiące 15–16)
- [ ] M6 Panel floty (Flutter Web): flota, kierowcy, licencje, faktury
- [ ] Sprzedaż licencji B2B poza sklepami
- [ ] M11 Raporty (wersja podstawowa)

### Faza 6 – Planer zleceń (miesiące 17–22)
- [ ] M7 Planer: filtrowanie, ocena kursu, przeszukiwanie z przycinaniem na 2–6 kroków, zysk/dzień, ryzyko regionów
- [ ] M8 Integracja pierwszej giełdy (wg podpisanej umowy)
- [ ] Zbieranie statystyk rynku → wartość oczekiwana regionów

### Faza 7 – Giełda i dopasowanie (miesiące 23–28)
- [ ] M9 Giełda TruckMaps: konta zleceniodawców, oferty, prowizje
- [ ] M10 Dopasowanie: przewidywana dostępność, przydział globalny, limity powiadomień, sprawiedliwość
- [ ] Ocena skutków dla ochrony danych (DPIA), konsultacja z prawnikiem od konkurencji (art. 101 TFUE)

### Faza 8 – Rozwój (od miesiąca 29)
- [ ] M1 Nawigacja Pro: mapy offline Europy, Android Auto, CarPlay
- [ ] M5 ADR i ponadgabaryty
- [ ] Prognozy stawek (uczenie maszynowe), optymalizacja całej floty
- [ ] Kolejne kontynenty

---

## 5. Kolejność modułów – uzasadnienie

1. **Czas pracy, Parkingi, Opłaty** najpierw – małe, szybkie do zrobienia, od razu przydatne każdemu kierowcy → pierwszy przychód.
2. **Panel floty** – otwiera sprzedaż B2B (wyższe ceny, bez prowizji sklepów).
3. **Planer i giełdy** – największa wartość, ale zależą od umów z giełdami, które trwają długo.
4. **Giełda własna i dopasowanie** – potencjalnie główne źródło przychodu, ale wymagają dużej bazy przewoźników.
5. **Nawigacja Pro** na końcu – mapy offline Europy, CarPlay i Android Auto są pracochłonne, a rdzeń już działa bez nich.

---

## 6. Ryzyka

| Ryzyko | Ograniczenie |
|---|---|
| Niekompletne dane o ograniczeniach | wiele źródeł, zgłoszenia kierowców, żółty kolor przy braku danych, regulamin „aplikacja pomocnicza” |
| Brak umów z giełdami | M7 działa na ręcznych ofertach, M9 jako własne źródło ofert |
| Budowa w pojedynkę trwa długo | ścisła kolejność faz, beta jak najwcześniej, rdzeń najpierw dla PL + sąsiadów |
| Moduły zaczną od siebie zależeć | `import-linter` i macierz testów w CI od pierwszego dnia |
| RODO, lokalizacja | zgody opt-in, poziomy udostępniania, DPIA przed fazą 7 |

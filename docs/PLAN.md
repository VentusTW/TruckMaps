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
- **Punkty dostawy**: wjazd dla ciężarówek pod adresem (brama, rampa, portiernia, godziny przyjęć, miejsce do zawracania). Cel trasy ustawia się od razu przy rampie, nie przy adresie biurowca. Dane z OSM (`amenity=loading_dock`, `entrance=service`, bramy) + zgłoszenia kierowców. W rdzeniu, za darmo: każdy kierowca dokłada dane, z których korzystają następni – to własna baza, której nie ma konkurencja
- Lokalizacja i przewidywana dostępność pojazdu – **tylko za zgodą**, z poziomami udostępniania
- Punkty rozszerzeń i zdarzenia (patrz 1.3 i 1.4)

---

## 3. Moduły płatne

Ceny orientacyjne, do weryfikacji na rynku.

| # | Moduł | Co daje | Używa z rdzenia | Dostarcza | Cena (orient.) |
|---|---|---|---|---|---|
| M1 | **Nawigacja Pro** | mapy offline całej Europy, asystent pasa ruchu, Android Auto / CarPlay | routing, mapa | `MapLayerProvider` | €3,99/mies. |
| M2 | **Czas pracy kierowcy** | pełne 561/2006, pakiet mobilności, kabotaż; rozkład przerw wg preferencji (45 lub 15+30, pora noclegu), pauza tygodniowa poza kabiną, przerwa przed korkiem/wypadkiem (zdarzenia DATEX II) | trasa, pojazd | `DriverHoursPolicy` | €2,99/mies. |
| M3 | **Parkingi i POI** | parkingi dla TIR (OSM, unijny standard SSTPA, dane krajowe o zajętości), propozycje 2–3 parkingów pod przerwę, filtry (ogrodzony, prysznic…), MOP, AdBlue, myjnie, serwisy; później prognoza zajętości i rozkładanie kierowców między parkingi | mapa | `PoiProvider`, `MapLayerProvider` | €1,99/mies. |
| M4 | **Opłaty drogowe i koszty** | szacowany koszt trasy z rozbiciem: paliwo (spalanie z profilu × ceny ON z Weekly Oil Bulletin KE, per kraj), AdBlue, myto per kraj (e-TOLL, Toll Collect z klasą CO₂, ASFINAG, HU-GO…), winiety, mosty/tunele/promy; €/km dla planera | trasa, profil kosztów | `CostProvider` | €2,99/mies. |
| M5 | **ADR i ponadgabaryty** | kategorie tuneli ADR, zakazy dla ładunków niebezpiecznych, przejazdy nienormatywne | routing | `RoutingConstraintProvider` | €2,99/mies. |
| — | *Pakiet Kierowca* (M1–M5) | | | | *€9,99/mies.* |
| M6 | **Panel floty** (web) | flota na mapie (za zgodą), kierowcy, licencje, raporty | konta, lokalizacja | — | €5/pojazd/mies. |
| M7 | **Planer zleceń** | przy każdej ofercie ≈ opłacalność (stawka − koszty trasy ciężarówki), 2–6 kursów do przodu, zysk/dzień, ryzyko regionów | koszty, czas pracy, `OfferSource` | — | €30–60/pojazd/mies. |
| M8 | **Integracje giełd** | oferty z Trans.eu, TimoCom, Teleroute (wymaga umów) | — | `OfferSource` | w cenie M7 lub osobno |
| M9 | **Giełda TruckMaps** | zleceniodawcy wystawiają oferty, przewoźnicy przyjmują | konta | `OfferSource` | prowizja 1–3% / opłata za ofertę |
| M10 | **Dopasowanie ofert** | oferty wysyłane do pasujących, wolnych pojazdów, rozdzielanie sugestii | dostępność, `OfferSource`, powiadomienia | — | w cenie M7 / prowizja |
| M11 | **Raporty i analityka** | zarobki, puste km, statystyki rynku, prognoza vs wynik | zdarzenia | — | €2–5/mies. |
| M12 | **Plan załadunku** | opis ładunku (palety, masy, piętrowanie) → LDM, czy mieści się w pojeździe, rozmieszczenie palet (2D, potem 3D), rozkład masy i naciski osi, mocowanie wg EN 12195-1 (liczba i ułożenie pasów, maty, ściana czołowa, naczepy XL), kolejność przy wielu rozładunkach | profil pojazdu | — | do ustalenia |
| M13 | **Flota: statystyki i terminy** | statystyki dla każdego pojazdu / naczepy / kierowcy; kalendarz terminów z przypomnieniami (przeglądy, tachografy, szkolenia, badania, uprawnienia, zezwolenia, ubezpieczenia) | panel floty, profile pojazdów | — | do ustalenia (za pojazd) |
| M14 | **Dokumenty** | generowanie dokumentów z danych, które już są w systemie: zlecenie transportowe, CMR / e-CMR, protokół załadunku i mocowania, rozliczenie delegacji kierowcy, raporty czasu pracy, dane do deklaracji delegowania, eksport do faktur (KSeF) | oferty, pojazdy, trasy | — | do ustalenia |

Każdy moduł działa z samym rdzeniem. Przykłady:
- M7 bez M8/M9 – planuje na ofertach wpisanych ręcznie.
- M10 bez M9 – dopasowuje oferty z dowolnego aktywnego `OfferSource` (choćby z M8).
- M4 bez M7 – liczy koszt każdej zwykłej trasy.

> **Podział wstępny.** To, co jest w darmowym rdzeniu, a co w płatnych modułach i pakietach (oraz ceny), zostanie ustalone później. Architektura na to pozwala: przeniesienie funkcji między rdzeniem a modułem nie wymaga zmian w pozostałych modułach.

### Zasady zakupu modułów

Każda opcja poza rdzeniem jest osobno płatna i dodawana przez użytkownika. Moduły mają być możliwie niezależne, a gdy jeden korzysta z innego:

1. **Zależność twarda** (moduł bez drugiego nie ma sensu) → zakup daje od razu dostęp do modułu wymaganego, a cena jest odpowiednio wyższa (pakiet). Klient nigdy nie kupuje modułu, który bez dokupienia czegoś nie działa.
2. **Zależność miękka** (moduł działa sam, ale z drugim lepiej) → **przed zakupem** jasna informacja, np. „Planer działa na ofertach wpisanych ręcznie; z modułem Integracje giełd dostaje oferty automatycznie”.
3. **Elastyczne płatności jako atut projektu:** przy każdym płatnym module użytkownik sam wybiera model – za użycie (rozliczane zbiorczo), pakiet z góry, subskrypcja miesięczna, roczna z rabatem – i może go zmienić od kolejnego okresu. Licencje w rdzeniu obsługują więc uprawnienia „ważne do dnia X” i „pozostało N użyć”.
4. Każdy moduł deklaruje to w swoich metadanych (`requires` – twarde, `enhanced_by` – miękkie); ekran zakupu i licencje czytają je automatycznie, więc reguły nie da się pominąć.

| Moduł | Wymaga (w cenie) | Działa lepiej z (informacja przed zakupem) |
|---|---|---|
| M7 Planer zleceń | – | M8/M9 (oferty automatycznie), M4 (prawdziwe koszty), M2 (prawdziwy czas pracy) |
| M10 Dopasowanie ofert | źródło ofert: M8 lub M9 → sprzedawany w pakiecie z M8 | M2, M4 |
| M5 ADR | – | M4 (myto dla ADR) |
| M12 Plan załadunku | – | M8/M9 (opis ładunku z oferty), M7 (propozycje doładunków) |
| M13 Flota: statystyki i terminy | M6 Panel floty (w pakiecie) | moduł Tachograf (pobrania danych zaliczane automatycznie), M4 (koszty), M11 (raporty) |
| M14 Dokumenty | – | M9 (dane zlecenia z giełdy), M12 (protokół mocowania), moduł Tachograf + M2 (delegacje, czas pracy), M13 (dane pojazdów i kierowców) |
| pozostałe | – | – |

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
- [x] Konta i logowanie (Zitadel, e-mail z kodem), profile pojazdów
- [x] Firmy i floty: firma z rolami (właściciel, dyspozytor, kierowca), jednorazowe kody zaproszeń ważne 7 dni (link /planer?zaproszenie=KOD), pojazdy firmy widoczne dla wszystkich członków, zmieniane przez właściciela i dyspozytorów; po usunięciu firmy pojazdy wracają do osób, które je dodały. Przynależność we własnej bazie, nie w organizacjach Zitadela: kierowca z własnym kontem dołącza bez przenoszenia konta i może należeć do kilku firm
- [x] Profile kosztów: stawki €/km i €/h jazdy w pojeździe, domyślne w firmie (brakującą stawkę pojazdu bierze z firmy); przy trasie i alternatywach „≈ koszt, szacunkowo” liczony przez gniazdo `COST_PROVIDER` (moduł M4 podmieni je na paliwo i myto per kraj); bez stawek koszt nie jest zgadywany
- [ ] Zmiana waluty: waluta konta / firmy (PLN, EUR, CZK, HUF, RON…), stawki wpisywane w swojej walucie, koszty i oferty pokazywane w wybranej walucie; przeliczanie po kursach EBC (darmowe, codziennie) z datą kursu, kwoty w obcej walucie (myto, paliwo za granicą) z przeliczeniem obok; wewnętrznie kwota + kod waluty, nie same euro
- [x] Import OSM Polski → Valhalla
- [x] Kraje sąsiednie (DE, CZ, SK, LT): mapy łączone narzędziem osmium (najnowsza wersja obiektów przy granicach), dane tras budowane etapami z ponawianiem w wolumenie Dockera i podmieniane bez przerwy w działaniu; ograniczenia (1,4 mln) i parkingi (9,9 tys.) dla 5 krajów; wyszukiwarka: zrzut Photon dla Europy, wybór krajów w Pythonie (9 min zamiast godzin w Photon)
- [x] `pobieraj.exe`: pobieranie dużych danych poza sesją (wznawianie, ponawianie, kilka połączeń naraz, MD5, pomijanie niezmienionych plików, `infra/data/pobrane.json`)
- [x] Aktualizacja co tydzień (`infra/update_data.ps1`, harmonogram Windows): mapy przez dzienne pliki zmian (MB zamiast GB), kontrola tras i wyszukiwarki testowej przed podmianą, kopia poprzednich danych i powrót jednym poleceniem (`infra/rollback.ps1`)
- [x] API trasy z parametrami pojazdu (/api/routes) + planer na mapie (/planer)
- [x] Baza ograniczeń (import z OSM: wysokość, masa, nacisk osi, szerokość, długość, zakazy dla ciężarówek; ok. 160 tys. dla PL)
- [x] Ocena segmentów: krzywizna zakrętów vs długość pojazdu, wąskie drogi, zapas wysokości/szerokości/długości, masa i naciski, zakazy → zielony/żółty/czerwony z ostrzeżeniami; czerwony miga w planerze
- [x] Pięć poziomów: czerwony (nie przejedzie), pomarańczowy (osiedlówki dla pojazdów > 12 m, zapas < 10 cm, zakręt < 0,6 × długość), żółty, jasnozielony (ronda), zielony
- [x] Planowanie po zielonych drogach: pomarańczowe i czerwone miejsca (poza okolicą startu, celu i punktów pośrednich) są wykluczane i trasa liczona ponownie, max 3 razy; objazd do 1,25 × długość + 3 km. Sprawdzone na Tarnów (ul. Tuchowska) → Tuchów: zestaw omija Aleję Tarnowskich / Tuwima / Ostrogskich (+1,9 km)
- [x] DMC w profilu pojazdu (masa rzeczywista ≤ DMC): ograniczenia DMC z OSM (maxweightrating), zakazy dla ciężarówek tylko przy DMC > 3,5 t; później podstawa myta
- [x] Busy i dostawczaki do 3,5 t DMC: trasa jak dla samochodu (Valhalla `auto` z wysokością i szerokością), bez zakazów dla ciężarówek; ograniczenia masy i długości dalej sprawdza ocena trasy i omija jako nieprzejezdne; szablon „Bus 3,5 t” w planerze
- [x] Punkty niedostępne dla pojazdu (start, cel, pośrednie): najbliższe miejsce na drodze dostępnej dla pojazdu (Valhalla /locate, próg 40 m), komunikat przy punkcie pośrednim; przy starcie i celu – też przy trudnym dojeździe – najbliższe parkingi dla ciężarówek i MOP-y z OSM (do 20 km), „jedź tutaj”
- [x] Ręczna zmiana trasy: punkty pośrednie, przeciąganie A / B / punktów pośrednich, przełącznik „Omijaj trudne drogi”
- [x] Znaki i pomiary: wartość ze znaku jest dopuszczalna (4,0 m pod znakiem 4,0 m jedzie); sam zmierzony prześwit bez znaku z zapasem < 20 cm (szerokość < 30 cm) – pomarańczowy i omijany; ograniczenia na trasie i ominięte miejsca jako znaki z wartością na mapie
- [ ] Dostroić progi oceny na trasach testowych z kierowcami (zakręty, wąskie drogi, punkty przy trasie)
- [x] Korytarz danych dla telefonu (`POST /api/corridor`): ograniczenia w pasie 500 m wokół trasy ocenione dla pojazdu, przebiegi dróg jako polilinie 1e-6, odpowiedź kompresowana; sprawdzanie pozycji bez sieci (`check_position`: na trasie – spokój, poza trasą na drodze czerwonej – alarm), ta sama logika w JS w planerze („Symulacja jazdy”) jako wzór dla aplikacji
- [x] **Moduł testowy „hello”** udowadniający, że system modułów działa

**Gotowe, gdy:** API zwraca kolorowaną trasę Poznań → Berlin dla zestawu 40 t / 4 m, a testy przechodzą w macierzy „rdzeń” / „rdzeń + hello”.

### Faza 2 – Rdzeń aplikacja (miesiące 5–8)
- [ ] Powłoka Flutter, `core_sdk`, rejestracja modułów, ekran „Kup moduł”
- [x] Mapa MapLibre, profil pojazdu
- [x] Wyszukiwanie adresów (Photon, dane OSM co tydzień): pola Skąd / Dokąd z podpowiedziami, adres klikniętego punktu
- [x] Punkty pośrednie z adresu albo GPS, współrzędne GPS w każdym polu adresu; bazy firmy (nazwa + adres, zarządzają właściciel i dyspozytorzy) podpowiadane po wpisaniu „baza” lub nazwy bazy
- [x] Gdy trasy nie da się wyznaczyć: okno z wyjaśnieniem, który odcinek blokuje które ograniczenie (np. nacisk osi 10 t na DK73 w Tarnowie), nieaktualna trasa znika z mapy
- [x] Start albo cel w strefie bez wjazdu dla pojazdu (np. stare miasto za wiaduktem 2 m): trasa od / do najbliższego dozwolonego miejsca (tuż za ostatnim albo przed pierwszym ograniczeniem, do 5 km), z informacją o odległości; przesuwany tylko ten koniec, który przeszkadza
- [ ] Numery domów tylko na ostatnich kilkuset metrach dojazdu do celu i odjazdu ze startu (pomoc przy nieregularnej numeracji); źródła: OSM `addr:housenumber`, w PL punkty adresowe z rejestru państwowego (GUGiK, dane otwarte)
- [ ] Planowanie trasy z kolorami ryzyka
- [ ] Nawigacja: GPS, dopasowanie do drogi, komunikaty głosowe, przeliczanie trasy
- [ ] **Alarm czerwony** (miganie, dźwięk, wibracja) liczony lokalnie z korytarza
  - planowanie nigdy nie prowadzi przez miejsce nieprzejezdne dla pojazdu (omijane bez limitu objazdu); czerwony pojawia się dopiero w nawigacji, gdy kierowca zjedzie z trasy w taką drogę
- [ ] Zgłoszenia od kierowców
- [ ] Punkty dostawy: wyświetlanie przy celu, zgłaszanie bramy/rampy/godzin przyjęć jednym dotknięciem, cel trasy przy rampie
- [ ] Ekrany konta osobno od planera (dziś wszystko jest w jednym panelu strony testowej): przy rejestracji wybór „mam firmę” (założenie firmy) albo „dołączam kodem”; ustawienia konta, firmy, członków, pojazdów i kosztów w osobnych ekranach
- [ ] Aktualizacje z możliwością powrotu:
  - po zalogowaniu aplikacja sprawdza wersje: aplikacji, modułów i danych (mapy offline, korytarz, baza ograniczeń); gdy są nowsze – pyta, czy pobrać (z rozmiarem i listą zmian), domyślnie przez Wi-Fi; nigdy w trakcie jazdy
  - poprzednia działająca wersja zostaje na urządzeniu (aplikacja: kanał z poprzednim wydaniem, dane: poprzedni pakiet obok nowego); nowa staje się „dobra” dopiero po udanym uruchomieniu i pierwszej trasie
  - „Wróć do poprzedniej wersji” w ustawieniach oraz samoczynny powrót, gdy nowa wersja nie startuje albo kilka razy z rzędu ulega awarii; zgłoszenie błędu z numerem wersji
  - serwer: wydania stopniowo (najpierw część użytkowników), możliwość wstrzymania wydania i wskazania poprzedniego jako aktualnego; API zgodne wstecz z co najmniej jedną poprzednią wersją aplikacji
  - dane serwera (trasy, wyszukiwarka) – podmiana tylko po sprawdzeniu nowych danych (zestaw tras testowych), poprzednie dane trzymane do następnej aktualizacji, by wrócić jednym poleceniem
- [ ] Zgody na lokalizację, polityka prywatności, regulamin (z prawnikiem)

**Gotowe, gdy:** testerzy przejadą realne trasy, a alarm zadziała na znanym niskim wiadukcie.

### Faza 3 – Dane rządowe i beta (miesiące 9–10)
- [ ] Parsery: GDDKiA, KPD (DATEX II), dane.gov.pl
- [ ] Łączenie źródeł z OSM, rozwiązywanie konfliktów, data aktualności każdego ograniczenia
- [ ] Monitoring, kopie zapasowe, drugi serwer
- [ ] **Publiczna beta w Polsce** (Google Play, potem App Store)

### Faza 4 – Pierwsze moduły płatne + Europa (miesiące 11–14)
- [ ] M2 Czas pracy kierowcy: limity 561/2006, rozkład przerw wg preferencji, pauza tygodniowa poza kabiną
- [ ] Zdarzenia drogowe z krajowych punktów dostępowych (DATEX II) → propozycja przerwy przed korkiem lub wypadkiem
- [ ] Święta i zakazy ruchu w czasie, według danych państw:
  - kalendarz świąt per kraj i region (np. święta landów w DE, kantonów w CH), z oficjalnych źródeł i bibliotek świąt
  - zakazy dla ciężarówek: weekendowe, świąteczne, wakacyjne (np. soboty w lecie w DE, AT, FR), nocne (AT, CH), z progami DMC, wyjątkami (ładunki szybko psujące się, transport kombinowany) i godzinami
  - ograniczenia czasowe z OSM (`hgv:conditional`, `maxweight:conditional`, `access:conditional`) i z krajowych DATEX II
  - przy planowaniu liczona godzina wjazdu na każdy odcinek i do każdego kraju: ostrzeżenie „zakaz od sob. 15:00 do niedz. 22:00 w DE”, propozycja zmiany godziny wyjazdu, objazdu lub parkingu przed zakazem
  - to samo przy ofertach w planerze zleceń (M7) i przy rozkładzie przerw (M2)
  - podział między rdzeń a moduły do ustalenia; bezpieczeństwo i legalność przejazdu najlepiej za darmo
- [ ] M3 Parkingi i POI: wyszukiwanie, filtry, propozycje pod przerwę, zgłoszenia „pełny / są miejsca”
- [ ] M4 Opłaty drogowe i koszty:
  - profil pojazdu: klasa Euro, klasa CO₂ (DE), spalanie l/100 km (pusty/ładowny), AdBlue jako % spalania, własne ceny paliwa (opcjonalnie)
  - ceny ON per kraj z Weekly Oil Bulletin (KE, co tydzień, darmowe), kursy walut z EBC
  - km płatnych dróg per kraj z Valhalli (`trace_attributes`: toll, kraj, klasa drogi) × oficjalne taryfy (tabele z cenników operatorów, aktualizowane ręcznie)
  - wynik: rozbicie paliwo / AdBlue / myto per kraj / razem, €/km; dostarcza `CostProvider`, więc planer zleceń liczy zysk na prawdziwych kosztach
  - **każda kwota oznaczona jako szacunkowa**: znak „≈” i podpis „szacunkowo” przy każdym koszcie (ekran trasy, planer, raporty, eksport), data aktualizacji cennika i cen paliwa, link do oficjalnego kalkulatora operatora myta; to samo w regulaminie
- [ ] Subskrypcje w sklepach, *Pakiet Kierowca*
- [ ] Rozszerzenie danych na całą UE (krajowe punkty dostępowe, DATEX II), tłumaczenia na 5–10 języków

**Kamień milowy:** pierwszy przychód, cel 140+ płacących (próg rentowności).

### Faza 5 – Panel floty, B2B (miesiące 15–16)
- [ ] M6 Panel floty (Flutter Web): flota, kierowcy, licencje, faktury
- [ ] M13 Flota: statystyki i terminy
  - **statystyki** dla każdego pojazdu, naczepy i kierowcy: km, puste km (%), wykorzystanie, ≈ koszty i przychód na km, zysk, przestoje, naruszenia czasu pracy (z modułu Tachograf), porównania w czasie
  - **pojazd / naczepa:** badanie techniczne (co rok), sprawdzenie okresowe tachografu (co 2 lata), pobranie danych z tachografu (co 90 dni), świadectwo ADR pojazdu, ATP chłodni, dozór UDT (HDS, windy), OC / AC / OCP, leasing, serwis wg przebiegu
  - **kierowca:** prawo jazdy, kwalifikacja wstępna i szkolenie okresowe (kod 95, co 5 lat), badania lekarskie i psychologiczne, karta kierowcy (co 5 lat), pobranie danych z karty (co 28 dni), zaświadczenie ADR, świadectwo kierowcy (spoza UE), deklaracje delegowania (IMI) przy kursach zagranicznych
  - **firma:** licencja wspólnotowa i wypisy dla pojazdów, certyfikat kompetencji zawodowych, zabezpieczenie finansowe, zezwolenia (np. CEMT), winiety
  - przypomnienia 30 / 14 / 7 dni przed terminem (push, e-mail), lista „do zrobienia w tym miesiącu”, skany dokumentów
  - **RODO:** przy badaniach lekarskich przechowujemy tylko datę ważności, nie treść orzeczeń (dane o zdrowiu); dostęp do danych kierowców tylko dla uprawnionych w firmie
  - okresy i wymagania różnią się między krajami – tabela terminów konfigurowalna per kraj, z wartościami domyślnymi dla PL
- [ ] M14 Dokumenty (PDF + dane do systemów zewnętrznych, wypełniane z tego, co już jest w TruckMaps):
  - **zlecenie transportowe** / potwierdzenie przyjęcia zlecenia (z giełdy lub wpisane ręcznie)
  - **CMR** (list przewozowy) do wydruku, a docelowo **e-CMR / eFTI** – UE (rozporządzenie 2020/1056) wprowadza elektroniczne dokumenty przewozowe akceptowane przez służby kontrolne
  - **protokół załadunku i mocowania** (z M12): rozmieszczenie palet, pasy, naciski osi – przydatny przy kontroli i reklamacji
  - **rozliczenie delegacji kierowcy**: kraje i czas pobytu z tras i tachografu → diety, ryczałty za noclegi (stawki per kraj)
  - **raporty czasu pracy** i naruszeń dla kierowcy i firmy
  - **dane do deklaracji delegowania** (portal IMI) przy kursach zagranicznych – przygotowanie danych, wysyłka przez przewoźnika
  - **eksport do faktur**: dane zlecenia → program do faktur z KSeF (Fakturownia, inFakt, wFirma)
  - szablony z logo firmy, język dokumentu wg kraju (PL, EN, DE…), archiwum dokumentów przy zleceniu
  - zastrzeżenie: dokumenty generowane na podstawie danych użytkownika – za treść odpowiada przewoźnik
- [ ] Sprzedaż licencji B2B poza sklepami
- [ ] M11 Raporty (wersja podstawowa)

### Faza 6 – Planer zleceń (miesiące 17–22)
- [ ] M7 Planer: filtrowanie, ocena kursu, przeszukiwanie z przycinaniem na 2–6 kroków, zysk/dzień, ryzyko regionów
- [ ] Opłacalność każdej oferty (także pojedynczej, poza planem wielu kursów):
  - koszty liczone na **trasie wyznaczonej dla tego pojazdu** (ciężarówka może jechać inaczej niż osobówka, więc inne myto i km): dojazd na pusto do załadunku + kurs z ładunkiem
  - ≈ paliwo + AdBlue + myto per kraj + promy (z `CostProvider`; bez M4 – prosta stawka €/km z profilu) + czas kierowcy (€/dzień)
  - wynik przy ofercie: ≈ zysk, €/km, €/dzień i ocena: opłaca się / na granicy / nie opłaca się (progi ustawia przewoźnik)
  - wszystkie kwoty oznaczone jako szacunkowe (zasada z M4)
- [ ] M8 Integracja pierwszej giełdy (wg podpisanej umowy)
- [ ] Zbieranie statystyk rynku → wartość oczekiwana regionów

### Faza 7 – Giełda i dopasowanie (miesiące 23–28)
- [ ] M9 Giełda TruckMaps: konta zleceniodawców, oferty, opłaty za korzystanie z platformy
- [ ] **Ustrukturyzowany opis ładunku w ofercie od pierwszej wersji** (typ palety EUR/przemysłowa/półpaleta/inna, liczba, kg na paletę, wysokość, piętrowanie, delikatny, ADR, temperatura) – żeby później nie przerabiać ofert pod plan załadunku i doładunki
- [ ] M10 Dopasowanie: przewidywana dostępność, przydział globalny, limity powiadomień, sprawiedliwość
- [ ] Ocena skutków dla ochrony danych (DPIA), konsultacja z prawnikiem od konkurencji (art. 101 TFUE)

**Wymagania prawne giełdy (do potwierdzenia u prawnika od prawa transportowego przed startem):**

- [ ] **Model platformy, nie pośrednika:** TruckMaps nie jest stroną umowy przewozu, nie bierze marży od przewozu, nie odpowiada za jego wykonanie; umowę zawierają zleceniodawca i przewoźnik bezpośrednio. Inaczej w PL potrzebna jest licencja na pośrednictwo przy przewozie rzeczy (GITD, zabezpieczenie ok. 50 000 €, certyfikat kompetencji), a w innych krajach UE osobne krajowe zezwolenia (np. ES, IT, FR)
- [ ] **Opłaty – użytkownik sam wybiera model:**
  - za każdą ofertę – rozliczane zbiorczo raz w miesiącu (jedna płatność, nie mikropłatność za każdą ofertę – stała opłata operatora płatności zjadłaby zysk)
  - pakiet ofert z góry (np. 10 / 50 / 200, im większy, tym taniej za ofertę), ważny np. 12 miesięcy
  - subskrypcja miesięczna (limit ofert lub bez limitu)
  - subskrypcja roczna (ok. 2 miesiące gratis)
  - kalkulator przy wyborze: „przy Twojej liczbie ofert taniej wychodzi …”; zmiana modelu w każdej chwili od kolejnego okresu
  - wszystkie warianty to opłata za korzystanie z platformy, niezależna od wartości frachtu (bezpieczny model prawny); prowizja od frachtu tylko po opinii prawnika
- [ ] **Bez przyjmowania pieniędzy za fracht:** rozliczenie bezpośrednio między stronami albo przez licencjonowanego operatora (np. Stripe Connect) – inaczej usługi płatnicze wymagające licencji KNF (PSD2)
- [ ] **Regulamin** usług drogą elektroniczną; zapis, że TruckMaps nie jest przewoźnikiem ani spedytorem
- [ ] **DSA (akt o usługach cyfrowych UE):** punkt kontaktowy, zgłaszanie i usuwanie nielegalnych treści (fałszywe oferty), przejrzyste zasady moderacji, uzasadnianie blokad
- [ ] **RODO:** dane osób kontaktowych w ofertach, umowy powierzenia
- [ ] **Weryfikacja firm przy rejestracji:** NIP / VAT UE (VIES), licencja przewoźnika, polisa OCP; oceny i opinie o kontrahentach, zgłaszanie podejrzanych ofert (ochrona przed wyłudzeniami ładunków)

### Faza 8 – Rozwój (od miesiąca 29)
- [ ] M1 Nawigacja Pro: mapy offline Europy, Android Auto, CarPlay
- [ ] M5 ADR i ponadgabaryty
- [ ] M12 Plan załadunku:
  - LDM, masa, sprawdzenie z profilem pojazdu (np. 13,6 m = 33 palety EUR / 26 przemysłowych)
  - rozmieszczenie palet (widok z góry, później 3D), kolejność przy wielu rozładunkach (ostatni rozładunek z przodu)
  - rozkład masy i naciski osi / siodła z ostrzeżeniami („przesuń 4 palety do tyłu”)
  - mocowanie wg EN 12195-1: liczba i rodzaj pasów, siła napięcia, maty antypoślizgowe, blokowanie o ścianę czołową, naczepy XL
  - doładunki: wolne LDM i ładowność → planer proponuje pasujące mniejsze oferty po drodze
  - zastrzeżenie: pomoc, nie certyfikat – odpowiedzialność za zabezpieczenie po stronie ładującego i kierowcy
- [ ] Prognozy stawek (uczenie maszynowe), optymalizacja całej floty
- [ ] Kolejne kontynenty
- [ ] **Kierunek rozwoju: przewóz osób (autokary, wycieczki)** – osobny pakiet na tej samej architekturze:
  - profil pojazdu „autokar / bus” → trasy wg wymiarów (wiadukty, wąskie ulice, zakręty), jak dla ciężarówek
  - czas pracy kierowcy wg 561/2006, z wyjątkiem dla przewozów okazjonalnych (zasada 12 dni)
  - parkingi dla autokarów przy atrakcjach i w miastach, punkty odbioru grup
  - giełda zleceń przewozów osób (zapytanie klienta → oferty przewoźników) i powroty bez pustych przebiegów
  - flota, terminy, dokumenty jak w M13/M14 + listy pasażerów, ubezpieczenie NNW
  - klienci: szkoły, firmy, biura podróży, parafie, gminy; w PL przewoźnik potrzebuje licencji na przewóz osób – platforma działa jako pośrednik technologiczny, nie przewoźnik
  - rynek: w Europie m.in. Driven Connect (UK), Busfinder.com (AT), bus-angebot.com / Omniplus On (DE); w PL brak wyraźnego lidera

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

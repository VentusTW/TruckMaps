# TruckMaps

Nawigacja i planowanie pracy dla kierowców ciężarówek: trasy dopasowane do wymiarów i masy pojazdu, ostrzeżenia o zwężeniach i nieprzejezdnych drogach, a w kolejnych modułach planowanie zleceń i giełda.

Plan i architektura: [docs/PLAN.md](docs/PLAN.md).

## Uruchomienie (Windows, Python 3.12, Docker Desktop)

Jednorazowo:

```powershell
py -3.12 -m venv .venv
.venv\Scripts\pip install -e "backend[dev]" -e backend/modules/hello
copy infra\.env.example infra\.env
docker compose -f infra/docker-compose.yml up -d --wait
.venv\Scripts\python infra\zitadel\bootstrap.py
Add-Content .env "TRUCKMAPS_DATABASE_URL=postgresql+psycopg://truckmaps:truckmaps_dev@127.0.0.1:5432/truckmaps"
.venv\Scripts\alembic -c backend\alembic.ini upgrade heads
powershell -ExecutionPolicy Bypass -File packaging\windows\build_pobieraj.ps1
dist\pobieraj.exe mapy
powershell -ExecutionPolicy Bypass -File infra\build_routing.ps1
.venv\Scripts\pip install -e "backend[pipeline]"
.venv\Scripts\python data_pipeline\import_restrictions.py infra\data\valhalla\region.osm.pbf
.venv\Scripts\python data_pipeline\import_parkings.py infra\data\valhalla\region.osm.pbf
```

- `bootstrap.py` tworzy w Zitadelu projekt i aplikację logowania, konto techniczne serwera (reset i zmiana hasła), kieruje maile do Mailpit (po polsku) i zapisuje konfigurację do `.env`.
- Adres bazy: `127.0.0.1`, nie `localhost` – pod `localhost` Windows najpierw próbuje IPv6 i połączenie wisi. Hasło jak w `infra/.env`.
- `alembic ... upgrade heads` (rdzeń i moduły z tabelami) tworzy i aktualizuje tabele TruckMaps (uruchamiaj po każdej aktualizacji kodu).
- `pobieraj.exe mapy` pobiera mapy Polski, Niemiec, Czech, Słowacji i Litwy (ok. 8 GB) do `infra/data/osm` – patrz „Pobieranie dużych danych” niżej.
- `build_routing.ps1` łączy je w jedną mapę `infra/data/valhalla/region.osm.pbf` (przy granicach mapy krajów nachodzą na siebie) i buduje z niej dane tras Valhalli. Dotychczasowe dane działają aż do podmiany na końcu, więc można go uruchamiać przy działającym planerze.
- `import_restrictions.py` wczytuje z połączonej mapy ograniczenia dla ciężarówek (wysokość, masa, nacisk osi, szerokość, długość, zakazy) i drogi w strefach przemysłowych. Uruchamiaj po każdej nowej mapie.
- `import_parkings.py` wczytuje parkingi dla ciężarówek i MOP-y (ok. 2 min). Planer podpowiada je, gdy do startu lub celu nie da się dojechać albo dojazd jest trudny.

Na co dzień:

```powershell
docker compose -f infra/docker-compose.yml --profile routing up -d --wait
.venv\Scripts\python -m truckmaps.core
```

| Adres | Co to jest |
|---|---|
| http://localhost:8000/ | strona powitalna z logowaniem (testowa, do czasu aplikacji Flutter) |
| http://localhost:8000/planer | planer trasy: profil pojazdu (ciężarówka albo bus do 3,5 t – bez zakazów dla ciężarówek), punkty A i B klikane na mapie, trasa w kolorach (zielony / żółty / czerwony migający) z listą ostrzeżeń; panel „Firma i flota” (członkowie, role, kody zaproszeń, pojazdy firmy, domyślne stawki kosztów); szacunkowy koszt trasy ze stawek €/km i €/h; adresy, punkty pośrednie i współrzędne GPS (np. `50.0131, 21.0214`) w polach Skąd / Dokąd / Punkt pośredni, bazy firmy po wpisaniu „baza”; znaki ograniczeń na mapie, okno z wyjaśnieniem, gdy trasy nie da się wyznaczyć; „Korytarz dla telefonu” i „Symulacja jazdy” (alarm bez zasięgu) |
| http://localhost:8000/docs | dokumentacja API; token do „Authorize” jest na stronie powitalnej po zalogowaniu |
| http://localhost:8000/api/me | zalogowany użytkownik |
| http://localhost:8025 | Mailpit – maile wysłane przez Zitadela (kody, potwierdzenia) |
| http://localhost:8080/ui/console | konsola Zitadela; administrator: `admin@truckmaps.localhost`, hasło z `infra/.env` |

Logowanie: e-mail i hasło (albo klucz dostępu), adres trzeba potwierdzić kodem z maila. Wszystko działa lokalnie i bez opłat; SMS i logowanie z Apple są odłożone.

Konfiguracja przez zmienne środowiskowe (albo plik `.env` w katalogu, z którego startuje serwer):

| Zmienna | Znaczenie |
|---|---|
| `TRUCKMAPS_MODULES` | brak lub `*` – wszystkie zainstalowane, pusta – sam rdzeń, `hello,tolls` – wybrane |
| `TRUCKMAPS_DEV_GRANT_ALL` | `true` – każdy ma każdy moduł (domyślnie przy `python -m truckmaps.core`) |
| `TRUCKMAPS_LICENSES` | `sub1:hello,tolls;sub2:hello` – licencje przypisane do identyfikatora użytkownika z `/api/me` |
| `TRUCKMAPS_OIDC_ISSUER`, `TRUCKMAPS_OIDC_CLIENT_ID`, `TRUCKMAPS_OIDC_PROJECT_ID` | logowanie (zapisuje je `bootstrap.py`) |
| `TRUCKMAPS_ZITADEL_TOKEN` | konto techniczne w Zitadelu: link do nowego hasła i zmiana hasła (zapisuje `bootstrap.py`) |
| `TRUCKMAPS_DEV_LOGIN` | `true` – testowa strona logowania pod `/` (domyślnie przy `python -m truckmaps.core`) |
| `TRUCKMAPS_DATABASE_URL` | baza PostgreSQL TruckMaps; bez niej profile pojazdów i trasy zwracają 503 |
| `TRUCKMAPS_VALHALLA_URL` | serwer tras, domyślnie `http://127.0.0.1:8002` |
| `TRUCKMAPS_PHOTON_URL` | wyszukiwarka adresów, domyślnie `http://127.0.0.1:2322` |

Token do testów API bez przeglądarki (konto techniczne w lokalnym Zitadelu):

```powershell
$token = .venv\Scripts\python infra\zitadel\test_token.py
curl.exe -s http://127.0.0.1:8000/api/vehicles -H "Authorization: Bearer $token"
```

## Plik exe (Windows)

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\build_exe.ps1
```

Wynik: `dist\TruckMaps-Server.exe` (jeden plik, nie wymaga Pythona). Uruchamiaj go z katalogu projektu, żeby wczytał `.env`; wtedy otwiera stronę powitalną z logowaniem, w innym wypadku `/docs`; opcje: `--port 8080`, `--host 0.0.0.0`, `--no-browser`. Do exe trafiają rdzeń i wszystkie moduły z `backend/modules`. Bez exe to samo daje `.venv\Scripts\python -m truckmaps.core`.

## Sprawdzanie

```powershell
.venv\Scripts\ruff check .
.venv\Scripts\ruff format --check .
.venv\Scripts\lint-imports
.venv\Scripts\pytest backend/tests backend/modules/hello/tests
```

CI (`.github/workflows/ci.yml`) uruchamia testy osobno dla samego rdzenia, dla rdzenia z każdym modułem z osobna i dla wszystkich modułów razem.

## Wyszukiwarka adresów: Photon

Pola „Skąd / Dokąd” w planerze korzystają z Photon (darmowa wyszukiwarka na danych OSM). Jednorazowo trzeba pobrać zrzut dla Europy (ok. 13 GB – nie dla każdego kraju jest osobny) i zaimportować z niego wybrane kraje (`-Countries`, domyślnie `pl,de,cz,sk,lt`):

```powershell
powershell -ExecutionPolicy Bypass -File infra\photon_import.ps1
docker compose -f infra/docker-compose.yml --profile search up -d photon
```

Zrzut najlepiej pobrać wcześniej przez `dist\pobieraj.exe photon`. Skrypt wybiera kraje w Pythonie (ok. 10 min), importuje je do Photon w wolumenie Dockera (ok. 40 min dla 5 krajów, 45 mln obiektów), a bazę podmienia dopiero na końcu (ok. 2 min przerwy), więc wyszukiwarka działa w trakcie. Baza (14 GB) jest w wolumenie `truckmaps-photon-data`, nie w katalogu Windows – stamtąd pierwsze zapytania trwały do 20 s, z wolumenu 30–300 ms. Dodanie kraju to ponowny import bez pobierania. Dane są publikowane co tydzień (parametr `-Release`, np. `261025`). Bez Photon planer działa, tylko punkty trzeba klikać na mapie.

## Routing: Valhalla

Valhalla jest w profilu `routing` i korzysta z danych tras w `infra/data/valhalla`. Kontener sam nie pobiera map, bo w tej sieci nie ufa certyfikatom HTTPS – mapy pobiera `dist\pobieraj.exe mapy`, a łączy i buduje `infra\build_routing.ps1`:

- łączenie narzędziem `osmium` (kontener `infra/osmium`); Geofabrik publikuje kraje z różnych dni, więc przy granicach zostaje najnowsza wersja każdego obiektu,
- budowa w wolumenie Dockera `truckmaps-valhalla-build` etapami (`infra/valhalla_build.sh`): przy dużej mapie Valhalla losowo pada w kodzie LuaJIT, więc powtarzany jest tylko etap, który padł; po nieudanej budowie wolumen zostaje i wystarczy uruchomić skrypt ponownie,
- na końcu podmiana katalogów – planer działa na starych danych do tej chwili. 5 krajów: ok. 1,5 h, 25 GB w wolumenie w trakcie.

## Cotygodniowa aktualizacja danych

```powershell
powershell -ExecutionPolicy Bypass -File infra\update_data.ps1             # teraz (-Force: przebuduj bez nowych danych)
powershell -ExecutionPolicy Bypass -File infra\schedule_update.ps1         # co tydzień, niedziela 03:00 (-Remove: wyłącz)
powershell -ExecutionPolicy Bypass -File infra\rollback.ps1 wszystko       # powrót do poprzednich danych
```

`update_data.ps1` po kolei:

1. pobiera tylko to, co się zmieniło (`pobieraj`: pliki zmian map, nowy zrzut wyszukiwarki),
2. przy nowych mapach buduje dane tras i **sprawdza je przed podmianą**: nowe dane na chwilę na porcie 8003, trasy testowe z `infra/testy_danych.json` muszą istnieć, a ich długość nie może się zmienić o więcej niż 15% względem obecnych (np. zgubiony most albo przejście graniczne). Złe dane nie wchodzą,
3. wczytuje ograniczenia i parkingi, wcześniej kopiując obecne do schematu `kopia`; przy błędzie albo spadku liczby wpisów o ponad 10% przywraca kopię,
4. przy nowym zrzucie importuje wyszukiwarkę i sprawdza zapytania testowe (nowa baza na porcie 2323) przed podmianą.

Poprzednie dane zostają do następnej aktualizacji (`infra/data/valhalla-previous`, schemat `kopia`, wolumen `truckmaps-photon-previous`), więc `rollback.ps1 trasy|ograniczenia|wyszukiwarka|wszystko` wraca do nich, a ponowne uruchomienie – z powrotem do nowszych. Trasy testowe sprawdza też ręcznie `.venv\Scripts\python tools\dane\sprawdz.py trasy --nowe http://127.0.0.1:8002`. Wynik ostatniej aktualizacji: `infra/data/aktualizacja.json`, dziennik: `infra/data/aktualizacja.log`.

## Pobieranie dużych danych: pobieraj.exe

Mapy i zrzut wyszukiwarki mają kilkanaście GB. `pobieraj.exe` pobiera je w zwykłym oknie konsoli, niezależnie od innych programów – można go zostawić na noc:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\build_pobieraj.ps1   # raz: buduje dist\pobieraj.exe
dist\pobieraj.exe                  # mapy (pl de cz sk lt) i zrzut wyszukiwarki
dist\pobieraj.exe mapy pl de at    # wybrane kraje (kody: pl, de, cz, sk, lt, at, hu, ...)
dist\pobieraj.exe photon           # najnowszy zrzut Photon dla Europy (~13 GB)
dist\pobieraj.exe url ADRES --do KATALOG
dist\pobieraj.exe stan             # co jest pobrane i z której wersji serwera
```

- Przerwane pobieranie (zerwane połączenie, zamknięte okno, restart) wznawia się od miejsca przerwania – wystarczy uruchomić ponownie.
- Serwer zrzutów Photon zwalnia pojedyncze połączenie (~0,3 MB/s), więc pobieranie idzie 8 połączeniami naraz (`--polaczenia`); Geofabrik – jednym, z ponowieniami.
- **Mapy aktualizują się plikami zmian:** gdy mapa kraju jest już na dysku, `pobieraj` czyta z jej nagłówka numer ostatniej zmiany, pobiera tylko brakujące dzienne pliki zmian z Geofabrik (kilka MB na dzień zamiast całej mapy, np. 4,6 GB dla Niemiec) i nakłada je narzędziem `osmium` (kontener `infra/osmium`, potrzebny Docker). Całą mapę pobiera tylko przy pierwszym razie, po przerwie dłuższej niż 60 dni albo bez Dockera.
- Każdy plik jest sprawdzany (MD5, a gdy serwer go nie publikuje – rozmiar; mapa po nałożeniu zmian – numer zmiany w nagłówku). Pliki, których serwer nie zmienił, są pomijane.
- Wynik: `infra/data/pobrane.json` (plik, wersja serwera, data, sposób sprawdzenia) i dziennik `infra/data/pobieraj.log`.
- Pobiera przez `curl.exe` z Windows (w tej sieci Python i kontenery nie ufają certyfikatom). Bez exe: `.venv\Scripts\python tools\pobieraj\pobieraj.py ...`.

Test trasy dla ciężarówki 4 m / 40 t:

```powershell
curl.exe -s http://127.0.0.1:8002/route -H "Content-Type: application/json" -d '{\"locations\":[{\"lat\":52.4064,\"lon\":16.9252},{\"lat\":52.2297,\"lon\":21.0122}],\"costing\":\"truck\",\"costing_options\":{\"truck\":{\"height\":4.0,\"weight\":40,\"length\":16.5}}}'
```

## Wydania (aktualizacje aplikacji)

Aplikacja po zalogowaniu pyta serwer o nowsze wersje. Wydaniami zarządza polecenie (z katalogu
głównego, baza z `.env`):

```
python -m truckmaps.core.releases add --platform windows 0.2.0 --url https://…/truckmaps-0.2.0.zip --size 52428800 --notes "pl=Konto i firmy" --notes "en=Accounts and companies" --rollout 10
python -m truckmaps.core.releases rollout --platform windows 0.2.0 50   # więcej użytkowników
python -m truckmaps.core.releases pause --platform windows 0.2.0        # wstrzymanie (resume – wznowienie)
python -m truckmaps.core.releases withdraw --platform windows 0.2.0     # wycofanie: kto ma, wraca do poprzedniej
python -m truckmaps.core.releases list
```

Moduły i pakiety danych: `--kind module|data --name <id>` (bez `--platform` = każda platforma).

## Nowy moduł

1. Skopiuj `backend/modules/hello` jako `backend/modules/<id>` i zmień nazwę pakietu na `truckmaps_<id>`.
2. W `pyproject.toml` ustaw nazwę paczki i entry point `<id> = "truckmaps_<id>.module:<Klasa>"` (nazwa entry pointu = `Module.id`).
3. Dopisz `truckmaps_<id>` w `.importlinter` (4 miejsca) – inaczej nie przejdzie `test_architecture.py`.
4. Dopisz `<id>` do macierzy `test-module` w CI.
5. Importuj wyłącznie z `truckmaps.sdk`. Brakuje czegoś w SDK – dodaj to do SDK, nie importuj z `truckmaps.core`.

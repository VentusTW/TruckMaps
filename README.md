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
```

`bootstrap.py` tworzy w Zitadelu projekt i aplikację logowania, kieruje maile do Mailpit i zapisuje konfigurację do `.env`.

Na co dzień:

```powershell
docker compose -f infra/docker-compose.yml up -d --wait
.venv\Scripts\python -m truckmaps.core
```

| Adres | Co to jest |
|---|---|
| http://localhost:8000/ | strona powitalna z logowaniem (testowa, do czasu aplikacji Flutter) |
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
| `TRUCKMAPS_DEV_LOGIN` | `true` – testowa strona logowania pod `/` (domyślnie przy `python -m truckmaps.core`) |

## Plik exe (Windows)

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\build_exe.ps1
```

Wynik: `dist\TruckMaps-Server.exe` (jeden plik, ok. 18 MB, nie wymaga Pythona). Po uruchomieniu otwiera przeglądarkę na `/docs`; opcje: `--port 8080`, `--host 0.0.0.0`, `--no-browser`. Do exe trafiają rdzeń i wszystkie moduły z `backend/modules`. Bez exe to samo daje `.venv\Scripts\python -m truckmaps.core`.

## Sprawdzanie

```powershell
.venv\Scripts\ruff check .
.venv\Scripts\ruff format --check .
.venv\Scripts\lint-imports
.venv\Scripts\pytest backend/tests backend/modules/hello/tests
```

CI (`.github/workflows/ci.yml`) uruchamia testy osobno dla samego rdzenia, dla rdzenia z każdym modułem z osobna i dla wszystkich modułów razem.

## Routing: Valhalla

Valhalla jest w profilu `routing`, bo nie startuje razem z resztą:

```powershell
docker compose -f infra/docker-compose.yml --profile routing up -d
```

Pierwszy start Valhalli pobiera mapę Polski i buduje kafelki routingu (ok. 1 h, ok. 8 GB RAM). Test trasy dla ciężarówki 4 m / 40 t:

```powershell
curl.exe -s http://127.0.0.1:8002/route -H "Content-Type: application/json" -d '{\"locations\":[{\"lat\":52.4064,\"lon\":16.9252},{\"lat\":52.2297,\"lon\":21.0122}],\"costing\":\"truck\",\"costing_options\":{\"truck\":{\"height\":4.0,\"weight\":40,\"length\":16.5}}}'
```

## Nowy moduł

1. Skopiuj `backend/modules/hello` jako `backend/modules/<id>` i zmień nazwę pakietu na `truckmaps_<id>`.
2. W `pyproject.toml` ustaw nazwę paczki i entry point `<id> = "truckmaps_<id>.module:<Klasa>"` (nazwa entry pointu = `Module.id`).
3. Dopisz `truckmaps_<id>` w `.importlinter` (4 miejsca) – inaczej nie przejdzie `test_architecture.py`.
4. Dopisz `<id>` do macierzy `test-module` w CI.
5. Importuj wyłącznie z `truckmaps.sdk`. Brakuje czegoś w SDK – dodaj to do SDK, nie importuj z `truckmaps.core`.

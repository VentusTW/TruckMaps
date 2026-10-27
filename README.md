# TruckMaps

Nawigacja i planowanie pracy dla kierowców ciężarówek: trasy dopasowane do wymiarów i masy pojazdu, ostrzeżenia o zwężeniach i nieprzejezdnych drogach, a w kolejnych modułach planowanie zleceń i giełda.

Plan i architektura: [docs/PLAN.md](docs/PLAN.md).

## Uruchomienie (Windows, Python 3.12)

```powershell
py -3.12 -m venv .venv
.venv\Scripts\pip install -e "backend[dev]" -e backend/modules/hello
$env:TRUCKMAPS_DEV_GRANT_ALL = "true"
.venv\Scripts\uvicorn truckmaps.core.app:create_app --factory --reload
```

- http://127.0.0.1:8000/docs – dokumentacja API
- http://127.0.0.1:8000/api/modules – stan modułów
- http://127.0.0.1:8000/api/m/hello/greeting – moduł testowy

Konfiguracja przez zmienne środowiskowe:

| Zmienna | Znaczenie |
|---|---|
| `TRUCKMAPS_MODULES` | brak lub `*` – wszystkie zainstalowane, pusta – sam rdzeń, `hello,tolls` – wybrane |
| `TRUCKMAPS_DEV_GRANT_ALL` | `true` – każde konto ma każdy moduł (tylko do rozwoju) |
| `TRUCKMAPS_LICENSES` | `konto1:hello,tolls;konto2:hello` – konto podawane w nagłówku `X-Account-Id` |

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

## Usługi: PostGIS i Valhalla

Wymaga Dockera.

```powershell
copy infra\.env.example infra\.env
docker compose -f infra/docker-compose.yml up -d
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

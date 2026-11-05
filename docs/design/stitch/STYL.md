# Styl z Google Stitch – tokeny do motywu Fluttera

Źródło: projekt Stitch 16111799433374123803 (ekrany: panel dyspozytora, karta pojazdu kierowcy – `kierowca-pojazd.png`).
Nazwa „MapsTrucker” z projektu nie jest przenoszona – aplikacja to TruckMaps.

## Kolory (Material 3, jasny)

| Rola | Hex | Użycie |
|---|---|---|
| primary | `#00288E` | przyciski, aktywne elementy, paski postępu |
| primaryContainer | `#1E40AF` | aktywna pozycja menu, piny pojazdów |
| onPrimary | `#FFFFFF` | |
| secondary | `#565E74` | etykiety, teksty pomocnicze |
| secondaryContainer | `#DAE2FD` | |
| tertiary | `#003D28` | wartości „OK” |
| tertiaryContainer | `#00563A` | status „w trasie / sprawny” (kropki, teksty) |
| tertiaryFixed | `#85F8C4` | miętowe chipy statusu („ZALICZONA”, „W trasie”) |
| error | `#BA1A1A` | awarie, alerty, „wymaga uwagi” |
| errorContainer | `#FFDAD6` | tło alertów |
| surface / background | `#F8F9FF` | tło aplikacji |
| surfaceContainerLowest | `#FFFFFF` | karty |
| surfaceContainerLow | `#EFF4FF` | pola w kartach, wyszukiwarka, przyciski drugorzędne |
| surfaceContainer | `#E5EEFF` | |
| surfaceContainerHigh | `#DCE9FF` | hover, tło mapy, tor paska postępu |
| surfaceContainerHighest | `#D3E4FE` | |
| onSurface | `#0B1C30` | tekst główny |
| onSurfaceVariant | `#444653` | ikony, tekst drugorzędny |
| outline / outlineVariant | `#757684` / `#C4C5D5` | separatory |

## Typografia

- Nagłówki: **Plus Jakarta Sans** 600/700 (na zrzucie widać szeryf, bo czcionka się nie wczytała – docelowo bezszeryfowa).
- Tekst, etykiety, liczby: **Inter** 400–700.
- Etykiety sekcji: 11 px, 700, WIELKIE LITERY, odstęp liter 0.04em (`label-sm`).
- Duże liczby (KPI): 28 px, 700, odstęp −0.02em, jednostka obok mniejsza w kolorze secondary.

| Token | Rozmiar / linia | Waga |
|---|---|---|
| headline-xl | 36/44 | 700 |
| headline-lg | 28/36 | 600 |
| headline-md | 20/26 | 600 |
| headline-sm | 17/24 | 600 |
| body-lg / md / sm | 16/24, 14/22, 12/18 | 400 |
| label-lg / md / sm | 14/20, 12/16, 11/14 | 600, 600, 700 |
| numeric-data | 14/20 | 500 |

## Kształty i odstępy

- Promienie: karty 8 px (`xl`), przyciski/pola 4 px (`lg`), chipy pełne.
- Cień kart: bardzo delikatny (`0 1px 8px rgba(0,0,0,.04)`), bez obramowań.
- Odstępy: 4 / 8 / 12 / 16 / 20 / 32 px; margines ekranu 16 px (telefon), 24 px (komputer).

## Wzorce elementów

- **Karta KPI**: etykieta wielkimi literami → duża liczba + jednostka → linia statusu (zielona/czerwona) + ikona w kwadracie 40 px w rogu.
- **Chip statusu**: miętowe tło + ciemnozielony tekst, kropka pulsująca.
- **Pasek postępu**: tor `surfaceContainerHigh`, wypełnienie `primary`, wysokość 8–10 px, zaokrąglony.
- **Baner awarii**: pełne tło `error`, biały tekst, strzałka w prawo.
- **Menu boczne (komputer)**: szer. 288 px, białe, aktywna pozycja `primaryContainer` + biały tekst.
- **Nawigacja dolna (telefon)**: 4 zakładki – Trasa, Tachograf, e-CMR, Pojazd.

## Uwaga o danych

Kafelki CAN (prędkość, paliwo, AdBlue), TPMS, temperatura chłodni, Eco-Score wymagają integracji telematycznej,
której system nie ma – pokazywać je tylko przy dostępnych danych. Wartości na makietach są przykładowe.

## Ekrany (7) – układ i źródło danych

Tokeny we wszystkich ekranach są identyczne (powyżej). „✔” = dane są w TruckMaps, „✚” = nowa funkcja, „⚡” = wymaga telematyki.

### Komputer – dyspozytor (menu boczne 288 px + górny pasek z wyszukiwarką, oddziałem, alertami, użytkownikiem)

1. **Główny panel / mapa na żywo** – pasek 5 KPI (flota w trasie ⚡, dostępne ✔, w serwisie ✔, spalanie ⚡, punktualność ✚);
   filtry-chipy (wszystkie / typ / w trasie / na bazie / wymaga uwagi); mapa 8/12 z pinami pojazdów (kolor = status) i legendą;
   alerty (3 karty); panel 4/12: karta wybranego pojazdu (zestaw ✔, ładunek ✔ z planu załadunku, trasa + postęp ✔/⚡,
   tachograf ✚, telemetria ⚡, przyciski „Wyślij instrukcję” ✔ skrzynka, „Zlecenie CMR” ✚); „kierowcy blisko pauzy” ✚.
2. **Zarządzanie taborem** – nagłówek ze ścieżką + akcje (eksport, naczepy, dodaj pojazd ✔); segmenty kategorii z licznikami;
   chipy stanu; tabela (pojazd+rejestracja, typ, status+trasa, przebieg, termin przeglądu ✔, kierowca ✔ moduł Kierowcy, akcje);
   paginacja; boczny panel: podsumowanie techniczne, „terminy w 30 dniach” ✔ (przeglądy, OC, tachograf), stanowiska warsztatowe ✚.
3. **Zlecenia i załadunek** – przełącznik Tablica (kanban: Planowane / Rampa & załadunek / W trasie) ↔ Oś czasu (Gantt) ✚;
   4 KPI; karty zleceń (nr, skąd→dokąd, ładunek, pojazd, kierowca, postęp załadunku);
   prawy panel: **weryfikacja masy i nacisków na osie ✔** (moduł załadunku), dokumenty/e-CMR ✚ (sesja „Wzory dokumentów”),
   ostrzeżenia drogowe ✔ (zakazy / przegląd trasy).

### Telefon – kierowca (górny pasek: logo, pojazd, status kierowcy; dolna nawigacja 4 zakładki)

4. **Trasa** – karta zlecenia (skąd→dokąd, ciągnik, naczepa); komunikat dyspozytora ✔ skrzynka; następny punkt + mini-mapa;
   postęp trasy (przejechane / ETA / do celu ✔); ostrzeżenie drogowe ✔; ładunek i DMC ✔;
   duży przycisk „Uruchom nawigację” ✔; „Zgłoś opóźnienie” ✚, „Zadzwoń do dyspozytora” ✔.
5. **Tachograf** – baner statusu; karta „wymagana pauza” z sugerowanym parkingiem; okrągły wskaźnik jazdy ciągłej (4h30);
   paski dzienny / tygodniowy / dwutygodniowy (561/2006) ✚ – liczone z ręcznego trybu lub ⚡; przyciski trybu (pauza, praca, odpoczynek);
   rekomendowany parking ✔/✚ (POI z OSM); karta kierowcy ⚡.
6. **e-CMR** – chłodnia ⚡; konfiguracja ładunku ✔; naciski osi ✔ (z planu, nie z czujników); karta e-CMR z QR i podpisem odbiorcy ✚;
   zdjęcia zabezpieczenia / plomby ✚.
7. **Pojazd** – karta zestawu + codzienna kontrola (walkaround) ✚; kafle paliwo / AdBlue / spalanie / TPMS ⚡; schemat kół ⚡;
   czerwony przycisk „Zgłoś usterkę” ✚; przypomnienie serwisu ✔; dokumenty pojazdu ✔/✚; telefon do mechanika ✔.

## Kolejność wdrożenia (propozycja)

1. Motyw (kolory, czcionki Inter + Plus Jakarta Sans jako zasoby aplikacji – bez pobierania z sieci, kształty) w `core_sdk` na bazie PR #23.
2. Wspólne komponenty: karta KPI, chip statusu, pasek postępu, kafelek wartości, baner alarmowy, kafel listy z ikoną.
3. Układy: komputer – menu boczne + górny pasek; telefon – dolna nawigacja dla roli kierowcy.
4. Ekrany z danymi ✔, potem funkcje ✚; kafle ⚡ ukryte do czasu integracji telematyki.

## Ekran „Plan załadunku” (projekt dyspozytora, wdrożony w module `module_load`)

- Komputer: formularz ładunku i rozmieszczenie (widok z góry / z boku) po lewej 8/12, wynik po prawej 4/12, zastrzeżenie na dole.
  Telefon: jedna kolumna w tej samej kolejności.
- ✔ Stan załadunku (LDM, zajęta długość z paskiem), masa towaru / ładowność, naciski na osie z paskami
  (≥ 90 % – bursztyn, przekroczenie – czerwień) i chipem „W normie / Przekroczenie”, środek ciężkości, pasy (EN 12195-1),
  maty i ściana czołowa, ostrzeżenia, wymiary przestrzeni, zastrzeżenie odpowiedzialności (art. 61 PRD, CMR, PN-EN 12195-1).
- ⚡ Naciski z czujników EBS, „GPS online” – wymagają telematyki; naciski liczone z planu, nie z czujników.
- ✚ Widok 3D, bilans sił cx/cy, lista sprzętu VDI 2700 z atestami, certyfikat EN 12642 XL, eksport PDF/VDI, „Zatwierdź plan” –
  nowe funkcje, do osobnej decyzji.

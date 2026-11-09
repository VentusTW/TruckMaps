# Kalkulacja cen na stronie (koszty + 30%)

Źródło prawdy dla cen: `website/assets/js/pricing.js`. Strona przelicza wszystko sama:

```
cena miesięczna = zaokrąglenie w górę do „,99” ( suma kosztów planu × 1,30 × kurs )
```

Ceny netto. Kurs EUR→PLN: 4,30 (stała `RATES` – do aktualizacji). Wersja PL pokazuje PLN, wersja EN – EUR.

## 1. Koszty stałe firmy (szacunek, EUR / mies., rok 2 działalności)

| Pozycja | EUR / mies. | Uwagi |
|---|---:|---|
| Serwery Hetzner: 2 × dedykowany (routing Valhalla + PostGIS), zapas, kopie | 260 | AX102 ≈ 110 €, drugi do testów/zapasu, Storage Box |
| Pobieranie map offline i kafelków (ruch, CDN) | 120 | rośnie z liczbą kierowców Pro |
| Domena, poczta, monitoring, certyfikaty, sklepy (konta deweloperskie) | 35 | Apple 99 $/rok, Google jednorazowo |
| Dane i licencje (myto, ceny paliw, parkingi, DATEX) | 300 | dziś większość darmowa; zapas na płatne źródła myta |
| Wsparcie klienta (0,5 etatu) | 1 600 | e-mail, telefon, wdrożenia flot |
| Rozwój i utrzymanie programu (wycena własnej pracy) | 3 500 | aktualizacje danych co tydzień, poprawki, nowe moduły |
| Sprzedaż i marketing | 900 | reklamy, targi, materiały |
| Księgowość, KSeF, prawnik (regulamin, RODO), ubezpieczenie OC | 450 | |
| **Razem** | **≈ 7 165** | |

Do tego koszty zmienne: prowizje operatorów płatności ≈ 1,5–3% (strona), sklepy Google/Apple 15% (zakupy w aplikacji).

## 2. Podział na plany

Koszty stałe rozłożone na planowaną liczbę płatnych planów (rok 2: ~400 kierowców, ~50 firm,
~30 biur spedycji, ~25 stanowisk dyspozytorskich – razem ≈ 7 200 € kosztów) według obciążenia (liczba pojazdów, kont, użycie
modułów). Każdy plan ma w `pricing.js` siedem składników (EUR / mies.):
infrastruktura, dane i licencje, wsparcie, rozwój, sprzedaż i marketing, płatności/księgowość,
pula tokenów w cenie planu (liczba tokenów × koszt tokena 0,45 €).

| Plan | Koszt € | +30% € | Cena € / mies. | Cena zł / mies. | zł / mies. przy płatności półrocznej (−8%) | zł / mies. przy płatności rocznej (−15%) |
|---|---:|---:|---:|---:|---:|---:|
| Kierowca Plus | 3,60 | 4,68 | 4,99 | 20,99 | 19,31 | 17,84 |
| Kierowca Pro | 7,00 | 9,10 | 9,99 | 39,99 | 36,79 | 33,99 |
| Mała flota | 24,00 | 31,20 | 31,99 | 134,99 | 124,19 | 114,74 |
| Flota (10 tokenów/mies.) | 50,50 | 65,65 | 65,99 | 282,99 | 260,35 | 240,54 |
| Flota Pro (20 tokenów/mies.) | 127,00 | 165,10 | 165,99 | 709,99 | 653,19 | 603,49 |
| Flota Biznes (50 tokenów/mies.) | 260,50 | 338,65 | 338,99 | 1 456,99 | 1 340,43 | 1 238,44 |
| Spedytor Solo | 12,00 | 15,60 | 15,99 | 67,99 | 62,55 | 57,79 |
| Spedytor Start | 18,00 | 23,40 | 23,99 | 100,99 | 92,91 | 85,84 |
| Spedytor | 36,00 | 46,80 | 46,99 | 201,99 | 185,83 | 171,69 |
| Spedytor Pro | 79,00 | 102,70 | 102,99 | 441,99 | 406,63 | 375,69 |
| Dyspozytor Start | 16,00 | 20,80 | 20,99 | 89,99 | 82,79 | 76,49 |
| Dyspozytor | 31,00 | 40,30 | 40,99 | 173,99 | 160,07 | 147,89 |
| Dyspozytor Pro | 62,00 | 80,60 | 80,99 | 346,99 | 319,23 | 294,94 |
| Centrum dyspozytorskie | 130,00 | 169,00 | 169,99 | 726,99 | 668,83 | 617,94 |

Kierowca Start (0 zł) to koszt marketingu – mieści się w pozycji „Sprzedaż i marketing”.

## 3. Upusty

- **Subskrypcja:** miesięcznie 0%, półrocznie 8%, rocznie 15% (płatne z góry). Nawet przy 15%
  cena zostaje powyżej kosztu (1,30 × 0,85 = 1,105).
- **Tokeny:** koszt tokena 0,45 € → cena bazowa 0,585 € (2,52 zł). Upust rośnie z liczbą:
  10+ 0%, 25+ 4%, 50+ 8%, 100+ 12%, 250+ 16%, 500+ 20%. **Pułap 20%** – wyżej cena tokena
  spadłaby poniżej kosztu.

| Pakiet | Upust | Cena € | Cena zł | zł / token |
|---:|---:|---:|---:|---:|
| 10 | 0% | 5,85 | 25,16 | 2,52 |
| 25 | 4% | 14,04 | 60,38 | 2,42 |
| 50 | 8% | 26,91 | 115,72 | 2,31 |
| 100 | 12% | 51,48 | 221,37 | 2,21 |
| 250 | 16% | 122,85 | 528,26 | 2,11 |
| 500 | 20% | 234,00 | 1 006,20 | 2,01 |
| 1000 | 20% | 468,00 | 2 012,40 | 2,01 |

Pakiety tokenów liczone co do grosza (bez zaokrąglania do „,99”), żeby cena za token zgadzała się z tabelą progów.

## 4. Do decyzji / do zrobienia

- Dane kontaktowe na stronie są wymyślone (`CONTACT` w `website/assets/js/app.js`).
- Rejestracja zapisuje wniosek tylko w przeglądarce – podpiąć serwer (konto w Zitadel, plan,
  termin wpłaty) i automatyczne usuwanie nieopłaconych kont po 10 dniach.
- Płatności online (Przelewy24 / Stripe) – gdy będą pierwsi płacący (zob. OFERTA.md).
- Ceny w `OFERTA.md` są starsze (poglądowe) – po akceptacji ujednolicić z tym dokumentem.

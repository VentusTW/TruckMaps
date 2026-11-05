# Dokumenty w transporcie drogowym towarów – katalog i mapowanie pól

Stan prawny i dane systemu: listopad 2026. Katalog opisuje dokumenty używane w krajowym
i międzynarodowym (UE/PL) przewozie drogowym rzeczy, ich podstawę prawną, wymagane pola
oraz to, skąd TruckMaps może je wypełnić. Nie jest poradą prawną – przed użyciem wzoru
w obrocie sprawdź aktualny tekst przepisu.

**Źródła wzorów.** Wzory budujemy sami na podstawie treści aktów prawnych i konwencji
(teksty urzędowe nie są chronione prawem autorskim – art. 4 pkt 2 ustawy o prawie
autorskim) oraz formularzy urzędowych publikowanych przez organy (Komisja Europejska,
UNECE, ministerstwa, PIP, KAS, GDDKiA). Nie kopiujemy układów graficznych formularzy
komercyjnych (bloczki CMR drukarni, wzory IRU, szablony giełd transportowych) – jedynie
numerację i znaczenie pól wynikające z konwencji.

Legenda źródła danych:

| Skrót | Skąd | Uwagi |
| --- | --- | --- |
| **FIRMA** | `companies` (nazwa, NIP, rodzaj), `company_bases` (bazy z adresem w `label`) | brak w rdzeniu: adres rejestrowy, KRS/REGON, EORI, nr licencji, IBAN – w profilu dokumentów modułu |
| **PROFIL** | profil dokumentów firmy w module Dokumenty (`document_profiles`) | adres, licencja / zezwolenie na wykonywanie zawodu przewoźnika, EORI, konto, osoba upoważniona, polisa OCP |
| **POJAZD** | `vehicle_profiles` przez SDK (`VehicleInfo`, `DrivingInfo`, `CargoInfo`) | nr rejestracyjny ciągnika i przyczepy/naczepy, rodzaj, DMC, masa własna, osie, wymiary, ADR, przebieg, VIN, ważności (przegląd, OCP, ADR, ATP, tachograf) |
| **KIEROWCA** | członkowie firmy (`MemberInfo`), przydział (`assigned_driver`); moduł Kierowcy (osobny pakiet) | imię i nazwisko z konta; kategorie, ADR, karta kierowcy – tylko w module Kierowcy (moduł Dokumenty nie może go importować – dane przez gniazdo rozszerzeń w przyszłości) |
| **TRASA** | planer w aplikacji (punkty, odległość, czas, kraje na trasie – `route_analysis`) | trasa nie jest zapisywana na serwerze – aplikacja przekazuje punkty przy autouzupełnianiu |
| **PRZEJAZDY** | `vehicle_trips` przez `fleet.trips` | początek, koniec, km, koszt – do karty drogowej i rozliczeń |
| **ŁADUNEK** | moduł Plan załadunku (wynik `/plan`: pozycje, sztuki, masa, LDM, pasy) | moduł niezależny – aplikacja przekazuje wynik planu do dokumentu |
| **ZEZWOLENIA** | `vehicle_permits` (nr, wydawca, ważność, limity, zasięg) | do dokumentów przejazdu nienormatywnego |
| **KOSZTY** | moduł Koszty / stawki firmy i pojazdu (`cost_per_km`, waluta), ceny paliwa | szacunki do zlecenia i rozliczenia |
| **RĘCZNIE** | użytkownik | dane kontrahentów, towaru, cena – docelowo książka kontrahentów w module |

Stopień automatyzacji: **A** – w pełni z systemu, **P** – podpowiedź do potwierdzenia,
**R** – ręcznie.

---

## 1. Międzynarodowy list przewozowy CMR

- **Do czego:** dowód zawarcia umowy przewozu drogowego rzeczy za wynagrodzeniem, gdy
  miejsce załadunku i dostawy są w różnych państwach (co najmniej jedno – strona
  konwencji). Trzy oryginały (nadawca, odbiorca, przewoźnik) + kopie.
- **Podstawa prawna:** Konwencja o umowie międzynarodowej przewozu drogowego towarów
  (CMR), Genewa 19.05.1956 (Dz.U. 1962 nr 49 poz. 238), art. 4–9; Protokół dodatkowy
  dotyczący elektronicznego listu przewozowego (e-CMR), Genewa 20.02.2008 (PL – ratyfikacja
  2023). W kraju przewoźnik może użyć CMR jako listu przewozowego wg art. 38–39 Prawa
  przewozowego.
- **Wzór:** treść pól z art. 6 konwencji; układ 24 pól (numeracja przyjęta w praktyce
  i we wzorze UNECE/IRU) odtwarzamy własnym układem graficznym.

| Pole (art. 6) | Treść | Źródło | St. |
| --- | --- | --- | --- |
| 1 | Nadawca (nazwa, adres, kraj) | RĘCZNIE / FIRMA, gdy firma jest nadawcą (spedycja) | P |
| 2 | Odbiorca | RĘCZNIE | R |
| 3 | Miejsce przeznaczenia (miejscowość, kraj) | TRASA – ostatni punkt | P |
| 4 | Miejsce i data załadowania | TRASA – pierwszy punkt + data wyjazdu | P |
| 5 | Załączone dokumenty | RĘCZNIE (faktura, WZ, świadectwo pochodzenia, e-DD…) | R |
| 6–9 | Cechy i numery, liczba sztuk, sposób opakowania, rodzaj towaru | ŁADUNEK (sztuki, rodzaj palet, etykiety pozycji) | P |
| 10 | Nr statystyczny (kod CN/HS) | RĘCZNIE | R |
| 11 | Waga brutto [kg] | ŁADUNEK – masa planu | A |
| 12 | Objętość [m³] | ŁADUNEK – LDM/wymiary (szacunek) | P |
| 9/ADR | Towar niebezpieczny: UN, nazwa, klasa, grupa pakowania, kod tunelowy | RĘCZNIE; POJAZD.hazmat → ostrzeżenie | R |
| 13 | Instrukcje nadawcy (celne, ubezpieczenie) | RĘCZNIE / szablon firmy | P |
| 14 | Postanowienia odnośnie przewoźnego (franco / niefranco) | szablon firmy | P |
| 15 | Zapłata za przewóz (przewoźne, opłaty) | KOSZTY (szacunek trasy) / RĘCZNIE | P |
| 16 | Przewoźnik (nazwa, adres, kraj) | FIRMA + PROFIL | A |
| 17 | Kolejni przewoźnicy | RĘCZNIE | R |
| 18 | Zastrzeżenia i uwagi przewoźnika | RĘCZNIE (przy załadunku) | R |
| 19 | Postanowienia specjalne | szablon firmy | P |
| 20 | Do zapłacenia przez (nadawca / odbiorca) | RĘCZNIE | R |
| 21 | Wystawiono w (miejsce, data) | PROFIL (miejscowość) + dzisiejsza data | A |
| 22–24 | Podpis i stempel nadawcy / przewoźnika / odbiorcy, data i godzina przyjęcia | podpis w aplikacji (POD) | P |
| – | Nr rejestracyjny ciągnika / naczepy | POJAZD (+ podpięta naczepa) | A |
| – | Za pobraniem (art. 21) | RĘCZNIE | R |

## 2. Krajowy list przewozowy

- **Do czego:** dowód umowy przewozu w kraju (nadawca → przewoźnik).
- **Podstawa:** ustawa z 15.11.1984 Prawo przewozowe (art. 38–39), rozporządzenie
  w sprawie ogólnych warunków przewozu rzeczy (nadawca wystawia list na żądanie
  przewoźnika; w praktyce często dokument WZ albo CMR).
- **Pola:** nadawca, odbiorca, przewoźnik, miejsce nadania i przeznaczenia, data, rodzaj
  i ilość towaru, masa, sposób opakowania, dokumenty, nr pojazdu, wartość deklarowana,
  przewoźne – mapowanie jak w CMR (poz. 1–4, 6–11, 16, 21).

## 3. Zlecenie transportowe (umowa przewozu / spedycji)

- **Do czego:** zawarcie umowy z przewoźnikiem przez zleceniodawcę lub spedytora – trasa,
  terminy, stawka, warunki. Najczęściej używany dokument handlowy branży.
- **Podstawa:** Kodeks cywilny art. 774–793 (przewóz), 794–804 (spedycja); Prawo przewozowe;
  konwencja CMR (przewóz międzynarodowy); ustawa o przeciwdziałaniu nadmiernym opóźnieniom
  w transakcjach handlowych (termin płatności max 60 dni między przedsiębiorcami);
  art. 6 ust. 1 pkt 2 rozporządzenia (UE) 2020/1054 (pakiet mobilności – planowanie,
  by kierowca mógł zachować normy czasu pracy). Wzór własny (brak urzędowego).
- **Pola:**

| Pole | Źródło | St. |
| --- | --- | --- |
| Numer zlecenia, data wystawienia | numeracja modułu (`ZT/2026/11/0001`) | A |
| Zleceniodawca (nazwa, adres, NIP, osoba kontaktowa) | FIRMA + PROFIL (gdy firma zleca) albo RĘCZNIE | P |
| Przewoźnik (nazwa, adres, NIP, licencja) | FIRMA + PROFIL (gdy firma jest przewoźnikiem) / RĘCZNIE | P |
| Pojazd – nr rej. ciągnika i naczepy, rodzaj zabudowy | POJAZD | A |
| Kierowca, telefon | KIEROWCA (przydzielony do pojazdu) | P |
| Miejsca i terminy załadunku / rozładunku (okna czasowe) | TRASA (punkty + ETA) | P |
| Towar: rodzaj, masa, palety / LDM, wymiary, ADR, temperatura | ŁADUNEK / RĘCZNIE | P |
| Odległość, czas przejazdu | TRASA | A |
| Fracht (kwota, waluta), termin płatności | KOSZTY (szacunek) / RĘCZNIE | P |
| Warunki: wymagane dokumenty, OCP (suma gwarancyjna), wymiana palet, kary, przestoje | szablon firmy + PROFIL (polisa OCP) | P |
| Podpisy | RĘCZNIE | R |

## 4. Karta drogowa

- **Do czego:** ewidencja pracy pojazdu i przebiegu (km, paliwo, kierowca, trasa) –
  podstawa rozliczenia paliwa i kosztów.
- **Podstawa:** obowiązkowy wzór uchylono (rozporządzenie MI z 2001 r. wygasło), ale
  ewidencja przebiegu jest wymagana do rozliczeń: ustawa o PIT/CIT (koszty eksploatacji),
  ustawa o VAT art. 86a ust. 6–7 (ewidencja przebiegu przy pełnym odliczeniu VAT
  w pojazdach do 3,5 t); w transporcie – praktyka kontroli paliwa i dowód wykonania
  przewozu. Wzór własny.
- **Pola:**

| Pole | Źródło | St. |
| --- | --- | --- |
| Nr karty, okres (od–do) | numeracja modułu, RĘCZNIE / domyślnie bieżący dzień | A |
| Firma | FIRMA + PROFIL | A |
| Pojazd: nr rej., marka/nazwa, naczepa | POJAZD | A |
| Kierowca | KIEROWCA (przydzielony) | P |
| Stan licznika – wyjazd / powrót | POJAZD.odometer_km (wyjazd); powrót = wyjazd + suma km przejazdów | P |
| Wiersze przejazdów: data/godz. wyjazdu i powrotu, trasa, km, ładowny/pusty | PRZEJAZDY | A |
| Paliwo: stan przy wyjeździe, tankowania (litry, miejsce), stan przy powrocie | RĘCZNIE; norma zużycia z POJAZD (ładowny/pusty) | P |
| Zużycie normatywne vs faktyczne | POJAZD.consumption_* × km | A |
| Podpisy kierowcy i wydającego | RĘCZNIE | R |

## 5. Potwierdzenie dostawy (POD) i protokół załadunku / rozładunku

- **Do czego:** potwierdzenie wydania/odbioru towaru: data, godzina, liczba sztuk, stan,
  zastrzeżenia, podpis; podstawa do faktury za fracht. Protokół załadunku – stan, liczba
  i rozmieszczenie ładunku, mocowanie, plomba.
- **Podstawa:** CMR art. 8–9 (sprawdzenie przy przyjęciu), art. 30 (zastrzeżenia przy
  odbiorze); Prawo przewozowe art. 74–76; rozporządzenie o mocowaniu – dyrektywa
  2014/47/UE (kontrola drogowa, załącznik III – wytyczne mocowania), EN 12195-1.
- **Pola:** nr dokumentu przewozowego, pojazd (A), kierowca (P), miejsce i czas
  przyjazdu/wyjazdu (TRASA/nawigacja – P), liczba sztuk i masa (ŁADUNEK – A), schemat
  rozmieszczenia i liczba pasów (ŁADUNEK – A), nr plomby, temperatura, zastrzeżenia,
  zdjęcia, podpis odbiorcy na ekranie (R), czasy oczekiwania – przestój (P, z nawigacji).

## 6. Protokół szkody / reklamacji

- **Do czego:** ustalenie ubytku, uszkodzenia lub opóźnienia przy odbiorze; podstawa
  reklamacji wobec przewoźnika i zgłoszenia do ubezpieczyciela OCP.
- **Podstawa:** CMR art. 30 (zastrzeżenia – szkody widoczne od razu, niewidoczne 7 dni,
  opóźnienie 21 dni), art. 32 (przedawnienie 1 rok); Prawo przewozowe art. 74–75
  (protokół szkody), art. 75 – reklamacja; Kodeks cywilny art. 788.
- **Pola:** nr listu przewozowego i zlecenia (A z dokumentów modułu), strony (FIRMA, R),
  pojazd i kierowca (A/P), data i miejsce stwierdzenia, opis szkody, ilość, wartość,
  przyczyna, zdjęcia, plomba (stan), obecni przy sporządzeniu, roszczenie (kwota), polisa
  OCP przewoźnika (PROFIL – A), podpisy.

## 7. Dokumenty ADR

### 7a. Dokument przewozowy ADR (dział 5.4.1 ADR)
- **Podstawa:** Umowa europejska ADR (tekst 2025, w PL – oświadczenie rządowe, Dz.U.);
  ustawa z 19.08.2011 o przewozie towarów niebezpiecznych. Może być częścią CMR.
- **Pola (5.4.1.1.1):** numer UN poprzedzony „UN”, prawidłowa nazwa przewozowa, wzory
  nalepek (klasa), grupa pakowania, kod ograniczeń przewozu przez tunele, liczba i opis
  sztuk przesyłki, całkowita ilość każdego towaru, nadawca i odbiorca, oświadczenie wg
  umów szczególnych, „1.1.3.6” – punkty (obliczenie zwolnienia). Źródło: RĘCZNIE
  (katalog UN docelowo), nadawca/odbiorca jak CMR, kod tunelowy → planer (ograniczenia
  tunelowe na trasie – A ostrzeżenie).

### 7b. Instrukcje pisemne (5.4.3 ADR)
- **Wzór urzędowy UNECE** – 4 strony, w języku zrozumiałym dla załogi; tekst ADR jest
  publiczny (UNECE udostępnia wersje językowe). Treść stała; system wybiera wersję
  językową wg języka kierowcy. Brak pól do wypełnienia – A.

### 7c. Zaświadczenie ADR kierowcy i świadectwo dopuszczenia pojazdu (8.2, 9.1.3)
- Dokumenty wydawane przez urząd (wzory w ADR) – system tylko przechowuje daty ważności
  (POJAZD.adr_until, moduł Kierowcy) i przypomina; nie generujemy ich.

## 8. Zaświadczenie o działalności kierowcy (urlopowe, AETR)

- **Do czego:** usprawiedliwienie braku zapisów na karcie/tachografie (urlop, choroba,
  prowadzenie pojazdu wyłączonego z rozporządzenia 561/2006) – obecnie wymagane tylko
  wtedy, gdy kierowca jedzie pojazdem objętym umową AETR poza UE albo gdy przepisy kraju
  tego wymagają; w UE zastąpione ręcznym wpisem w tachografie (art. 34 ust. 3
  rozporządzenia 165/2014).
- **Podstawa:** decyzja Komisji 2009/959/UE (wzór formularza – publiczny, Dz.Urz. UE L 330
  z 16.12.2009); umowa AETR.
- **Pola:** przedsiębiorstwo (nazwa, adres, tel., e-mail – FIRMA+PROFIL – A), osoba
  podpisująca (PROFIL – P), kierowca: imię i nazwisko, data urodzenia, nr prawa jazdy,
  data rozpoczęcia pracy (moduł Kierowcy – P/R), okres od–do (R), przyczyna (14 pól
  wyboru: choroba, urlop, odpoczynek, inny pojazd wyłączony…) (R), miejsce, data, podpisy.

## 9. Polecenie wyjazdu służbowego (delegacja) i rozliczenie kosztów podróży

- **Do czego:** skierowanie kierowcy w podróż służbową i rozliczenie diet, noclegów,
  ryczałtów. Uwaga: dla kierowców w transporcie międzynarodowym od 2.02.2022 (pakiet
  mobilności) przejazdy nie są podróżą służbową – zamiast diet stosuje się wynagrodzenie
  wg przepisów o delegowaniu (art. 21a ustawy o czasie pracy kierowców); w kraju i dla
  przewozów dwustronnych diety nadal dotyczą.
- **Podstawa:** Kodeks pracy art. 77⁵; rozporządzenie MRPiPS z 29.01.2013 w sprawie
  należności z tytułu podróży służbowej (diety, ryczałty, stawki zagraniczne);
  ustawa o czasie pracy kierowców art. 21a.
- **Pola:** pracodawca (A), pracownik (KIEROWCA – P), cel, miejsce, środek transportu
  (POJAZD – A), termin od–do (PRZEJAZDY – P), kraje i godziny przekroczenia granic
  (TRASA – P z analizy krajów na trasie), diety (A – obliczenie wg stawek z
  rozporządzenia), noclegi, ryczałty, zaliczki, podpisy.

## 10. Oświadczenie o delegowaniu kierowcy (IMI)

- **Do czego:** zgłoszenie delegowania kierowcy do państwa UE (kabotaż, przewozy
  cross-trade) przed rozpoczęciem delegowania.
- **Podstawa:** dyrektywa (UE) 2020/1057 art. 1 ust. 11; rozporządzenie wykonawcze
  Komisji (UE) 2021/2179 (interfejs IMI). Składa się elektronicznie w portalu publicznym
  IMI (postingdeclaration.eu) – system nie wysyła, przygotowuje dane i kopię do kabiny.
- **Pola:** przewoźnik: nazwa, adres, nr licencji wspólnotowej, VAT, osoba kontaktowa
  w kraju delegowania (FIRMA+PROFIL – A), kierowca: imię, nazwisko, data urodzenia,
  adres, nr prawa jazdy, data rozpoczęcia umowy, prawo właściwe (moduł Kierowcy – P/R),
  państwo delegowania, okres (TRASA – P: kraje na trasie), rodzaj przewozu (kabotaż /
  cross-trade – R), nr rej. pojazdów (POJAZD – A).
- **Dokumenty w kabinie:** kopia oświadczenia, dowód przewozu w państwie przyjmującym
  (CMR – A z modułu), zapisy tachografu.

## 11. SENT – zgłoszenie przewozu towarów wrażliwych

- **Do czego:** monitorowanie przewozu paliw, olejów, alkoholu skażonego, suszu
  tytoniowego, broni itp. Zgłoszenie w PUESC (platforma KAS) przed wyjazdem,
  geolokalizator lub aplikacja mobilna KAS.
- **Podstawa:** ustawa z 9.03.2017 o systemie monitorowania drogowego i kolejowego
  przewozu towarów (SENT).
- **Pola:** podmiot wysyłający i odbierający (NIP, adres – FIRMA/R), przewoźnik (A),
  miejsce załadunku/dostawy (TRASA – P), przewidywana data rozpoczęcia i czas przewozu
  (TRASA – A), nr rej. ciągnika i naczepy (A), towar: kod CN, ilość, masa brutto
  (ŁADUNEK – P), nr lokalizatora / dane kierowcy, numer referencyjny zgłoszenia (R –
  wpis zwrotny z PUESC). System nie wysyła zgłoszenia (wymaga uwierzytelnienia w PUESC) –
  przygotowuje dane do przepisania i pamięta numer referencyjny.

## 12. e-DD (elektroniczny dokument dostawy) – EMCS PL2

- **Do czego:** przemieszczanie wyrobów akcyzowych (paliwa, alkohol, wyroby tytoniowe)
  w procedurze zawieszenia poboru akcyzy lub z zapłaconą akcyzą.
- **Podstawa:** ustawa z 6.12.2008 o podatku akcyzowym; dyrektywa Rady (UE) 2020/262;
  system EMCS PL2 (PUESC).
- **Pola:** numer ARC (R), wysyłający/odbiorca (akcyzowe numery – R), miejsce wysyłki
  i dostawy (TRASA – P), środek transportu (POJAZD – A), wyroby (CN, ilość – R). System
  przechowuje tylko numer ARC i drukuje go w CMR (pole 5).

## 13. Zezwolenie na przejazd pojazdu nienormatywnego

- **Do czego:** przejazd pojazdem przekraczającym normy (masa, naciski, wymiary).
  Kategorie I–VII; I–VI wydaje starosta/GDDKiA, VII – GDDKiA dla trasy.
- **Podstawa:** ustawa Prawo o ruchu drogowym art. 64–64i; rozporządzenie MI w sprawie
  wzoru zezwoleń na przejazd pojazdu nienormatywnego (wzory urzędowe – publiczne).
- **Pola wniosku (kat. VII):** wnioskodawca (FIRMA+PROFIL – A), pojazd: rodzaj, nr rej.,
  wymiary, masa całkowita, naciski osi i rozstawy (POJAZD – A; naciski z ŁADUNKU – A),
  ładunek (R), trasa przejazdu – drogi i miejscowości (TRASA – P), okres i liczba
  przejazdów (R), pilotaż (R). Wydane zezwolenie zapisuje się w ZEZWOLENIA – planer
  uwzględnia je w ocenie trasy (już działa).
- **Inne zezwolenia:** wjazd do stref (ograniczenia tonażu w miastach), zezwolenia
  w czasie zakazów świątecznych – jak wyżej, rejestr ZEZWOLENIA.

## 14. Zezwolenia na wykonywanie przewozów międzynarodowych

- Licencja wspólnotowa i wypis (rozporządzenie 1072/2009, wzór urzędowy), zezwolenia
  dwustronne/EKMT do państw spoza UE (UA, TR, MA…) – wydaje GITD/ministerstwo.
  System: rejestr numerów i ważności w PROFILU, druk numeru licencji w CMR i zleceniu (A),
  przypomnienie o wygaśnięciu.

## 15. Świadectwo kierowcy (spoza UE)

- Rozporządzenie 1072/2009 art. 5 – dla kierowców obywateli państw trzecich; wydaje GITD.
  System przechowuje ważność (moduł Kierowcy – `attestation_until`).

## 16. Dokumenty kontroli drogowej – „pakiet w kabinie”

Lista kontrolna do wydruku / ekranu (A z danych POJAZD, KIEROWCA, PROFIL): prawo jazdy,
karta kierowcy, kwalifikacja (kod 95), badania; dowody rejestracyjne i ważne przeglądy
(POJAZD.inspection_until), polisa OC i OCP (POJAZD.insurance_until / ocp_until), wypis
licencji, świadectwo ADR pojazdu (adr_until), ATP (atp_until), zezwolenia (ZEZWOLENIA),
CMR, wydruki tachografu (ostatnie 28 dni – dane z karty), oświadczenie IMI.
**Podstawa:** ustawa o transporcie drogowym art. 87; Prawo o ruchu drogowym art. 38.

## 17. Inne dokumenty pomocnicze

| Dokument | Podstawa | Autouzupełnianie |
| --- | --- | --- |
| Dowód wymiany palet (karta paletowa) | umowa stron, regulamin EPAL (bez wzoru urzędowego) | ŁADUNEK – liczba i typ palet (A), strony (P) |
| Protokół przekazania pojazdu kierowcy (stan, wyposażenie, licznik, paliwo) | Kodeks pracy art. 124 (mienie powierzone) | POJAZD (A), KIEROWCA (P), przebieg (A) |
| Raport usterek / przegląd przed jazdą | ustawa o czasie pracy kierowców art. 6 (czynności), dyrektywa 2014/45/UE | moduł Serwis (zgłoszenia) |
| Oświadczenie o mocowaniu ładunku | dyrektywa 2014/47/UE, EN 12195-1 | ŁADUNEK – liczba pasów, metoda (A) |
| Ewidencja czasu pracy kierowcy | ustawa o czasie pracy kierowców art. 25 | PRZEJAZDY (P), dane tachografu (R) |
| Dokument WZ / specyfikacja wysyłki | ustawa o rachunkowości (dowód magazynowy) | ŁADUNEK (P) |
| Deklaracja T1/T2 (tranzyt), karnet TIR | Konwencja TIR 1975, NCTS | numery – R; pojazd (A) |
| Faktura za fracht | ustawa o VAT art. 106e | z ZLECENIA (A) – poza zakresem modułu, eksport danych |

---

## Wnioski dla systemu

1. Rdzeń nie ma adresu firmy ani danych osobowych kierowców potrzebnych w dokumentach
   (adres, data urodzenia, nr prawa jazdy) – trzymamy je w module Dokumenty (profil firmy)
   albo dostarcza je moduł Kierowcy przez gniazdo rozszerzeń (bez importu między modułami).
2. Trasa i plan załadunku żyją w aplikacji – przy tworzeniu dokumentu aplikacja przekazuje
   punkty trasy i wynik planu, a serwer scala je z danymi pojazdu i firmy.
3. SENT, e-DD i IMI wymagają uwierzytelnienia w portalach publicznych – system
   przygotowuje dane i przechowuje numery referencyjne, nie wysyła zgłoszeń.
4. Najwięcej pracy oszczędzają: CMR, zlecenie transportowe, karta drogowa, POD – od nich
   zaczynamy (zob. `docs/modul-dokumenty.md`).

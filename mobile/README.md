# mobile

Aplikacja Flutter (Android, iOS, Windows, panel webowy) – faza 2.

- `app/` – powłoka (rdzeń): logowanie, pojazdy, menu modułów, ekran „Kup moduł”
- `packages/core_sdk/` – kontrakty dla pakietów modułów (`TruckMapsModule`, `ModuleRegistry`, `CoreApi`)
- `packages/module_<id>/` – ekrany jednego modułu (wzór: `module_hello`)

Uruchomienie na komputerze (serwer TruckMaps pod http://localhost:8000):

```
cd mobile/app
flutter run -d windows
```

Inny serwer: `flutter run -d windows --dart-define=TRUCKMAPS_SERVER=http://adres:8000`.
Logowanie otwiera przeglądarkę; po zalogowaniu serwer wraca do aplikacji na adres
127.0.0.1 z jednorazowym kodem, który aplikacja wymienia na token.

Sesja (token odświeżania) zostaje w magazynie systemu – Menedżer poświadczeń (Windows),
Keystore (Android), Keychain (iOS) – więc po ponownym uruchomieniu aplikacja nie pyta
o logowanie; token dostępu odświeża się sam (`POST /auth/app/refresh`).

## Języki

Aplikacja jest wielojęzyczna: teksty są w `app/lib/l10n/app_<język>.arb` (polski
`app_pl.arb` jest wzorcem z opisami), kod tłumaczeń generuje się sam przy `flutter run`
i `flutter test` (albo `flutter gen-l10n`). Aplikacja bierze język systemu; języka bez
tłumaczenia – polski. Ten sam język idzie do serwera (`Accept-Language`), więc ostrzeżenia
na trasie, zakazy i błędy też są w nim.

Nowy język: skopiuj `app_pl.arb` jako `app_<kod>.arb`, przetłumacz wartości (bez kluczy
i `{parametrów}`), a na serwerze to samo z `backend/src/truckmaps/core/locales/pl.json`.
Teksty w kodzie zawsze przez `context.l.<klucz>`; liczby, daty i kwoty przez
`l.number`, `l.km`, `l.when`, `l.money` (separator dziesiętny i nazwy dni według języka).
Moduły: `name(locale)`, `description(locale)` i `pick(locale, {...})` z `core_sdk`.

## Telefon z Androidem (USB)

Telefon w trybie debugowania USB, serwer i Zitadel na komputerze. `adb reverse` sprawia,
że `localhost` w telefonie to komputer – logowanie działa tak samo jak na komputerze
(przeglądarka telefonu wraca do aplikacji na 127.0.0.1):

```
adb reverse tcp:8000 tcp:8000
adb reverse tcp:8080 tcp:8080
flutter run -d <telefon>
```

Budowanie na Androida (`flutter build apk`) pobiera biblioteki przez Gradle (Java). Antywirus
skanujący połączenia HTTPS (np. Avast) podstawia własny certyfikat, któremu Java nie ufa –
błąd `PKIX path building failed`. Trzeba dodać certyfikat antywirusa do magazynu Javy
(`keytool -importcert` do `cacerts` JDK z Android Studio) albo wyłączyć skanowanie HTTPS dla Javy.

```powershell
$c = Get-ChildItem Cert:\LocalMachine\Root | ? Subject -match 'Avast Web/Mail Shield Root'
[IO.File]::WriteAllBytes("$env:TEMPvast.cer", $c.Export('Cert'))
& "C:\Program Files\Android\Android Studio\jbrin\keytool.exe" -importcert -noprompt -cacerts `
  -alias avast-web-mail-shield -file "$env:TEMPvast.cer" -storepass changeit
```

Po aktualizacji Android Studio (nowy JDK) trzeba to powtórzyć.

Emulator bez `adb reverse`: `--dart-define=TRUCKMAPS_SERVER=http://10.0.2.2:8000` – ale
logowanie przez Zitadela pod `localhost:8080` wymaga i tak `adb reverse tcp:8080 tcp:8080`.

## Konto, firma i role

Pierwsze logowanie bez firmy pyta: „Mam firmę” (zakładasz firmę – nazwa, NIP/VAT, waluta – i
zostajesz właścicielem), „Dołączam kodem” (kod zaproszenia; rola jest w kodzie) albo „Sam, bez
firmy” (wybór zapisany na serwerze, nie pyta ponownie; firmę założysz później w „Konto”).

Menu zależy od roli w wybranej firmie:

| Ekran | Właściciel | Dyspozytor | Kierowca | Bez firmy |
|---|---|---|---|---|
| Trasa, Pojazdy, Moduły, Konto | ✓ | ✓ | ✓ | ✓ |
| Firma – dane i stawki | zmienia | widzi | widzi | – |
| Firma – bazy | zmienia | zmienia | widzi | – |
| Członkowie i zaproszenia | role, usuwanie, zaprasza każdego | zaprasza kierowców | – | – |

Kilka firm → przełącznik na górze ekranu „Firma”. Ostatniego właściciela nie da się
zdegradować ani usunąć. „Konto”: imię wyświetlane (widoczne w firmach), język aplikacji
(„jak w telefonie” albo wybrany), waluta kosztów w planerze, wylogowanie.

## Aktualizacje

Po zalogowaniu aplikacja wysyła swoją wersję (`appVersion` w `lib/src/updates.dart`, ta sama co
`version` w `pubspec.yaml` – pilnuje tego test) do `POST /api/updates/check`. Gdy jest nowsza
(albo zainstalowaną wycofano), pyta o pobranie: wersja, rozmiar, lista zmian w języku aplikacji.
Pyta tylko na ekranie głównym, nigdy przy otwartej nawigacji. „Pobierz” otwiera plik w
przeglądarce; pobieranie w aplikacji i powrót do poprzedniej wersji – w kolejnym kroku.

Wydania dodaje się na serwerze (zob. README w katalogu głównym, „Wydania”).

## Nawigacja

Ekran „Trasa” → „Jedź – nawigacja z alarmem”. Aplikacja pobiera korytarz danych
(`POST /api/corridor`) i dalej sprawdza pozycję bez sieci: na trasie – pasek „zostało X km”,
poza trasą na drodze nieprzejezdnej dla pojazdu – czerwony, migający ekran, dźwięk i wibracja,
poza trasą na innej drodze – po kilku pozycjach nowa trasa od miejsca, w którym jest pojazd.
Bez GPS (komputer) pozycję ustawia dotknięcie mapy albo „Jedź 60 km/h” (symulacja).

Manewry i głos: trasa z serwera ma manewry z komunikatami Valhalli w języku aplikacji.
Na górze ekranu – strzałka, odległość i napis następnego manewru; głos mówi zapowiedź
ok. 1 km i 300 m przed manewrem (na dłuższych odcinkach), komunikat tuż przed nim
i „jedź prosto przez …” przed długim odcinkiem. Każdy komunikat raz; przy alarmie
czerwonym głos milknie. Przycisk 🔊 w pasku wycisza głos. Mowa to syntezator systemu,
bez sieci i bez dodatkowych pakietów: Android – `TextToSpeech` (kanał `truckmaps/speech`
w `MainActivity.kt`), Windows – głosy systemu (System.Speech, np. Paulina dla polskiego);
iOS jeszcze bez głosu. Brak głosu w danym języku → syntezator mówi domyślnym.

## Zgłoszenia kierowców

Przytrzymanie mapy w planerze (albo „Zgłoś” w nawigacji – miejsce pojazdu) otwiera okno
zgłoszenia: brama, rampa, biuro, miejsce oczekiwania, godziny przyjęć, ograniczenie ze
znaku, zakaz dla ciężarówek, droga zamknięta, wąsko. Jedno dotknięcie wysyła zgłoszenie;
godziny przyjęć i ograniczenia pytają najpierw o tekst / wartość. Po wyznaczeniu trasy
planer pokazuje punkty dostawy przy celu („Jedź tutaj” – cel przy rampie) i zgłoszenia na
trasie, z przyciskami „nadal aktualne” / „nieaktualne”.

Nowy moduł: pakiet `packages/module_<id>` z klasą `TruckMapsModule` (to samo `id` co moduł
na serwerze), dopisany do `app/pubspec.yaml` i do listy w `app/lib/main.dart`. Moduł importuje
tylko `core_sdk` – nie powłokę ani inne moduły.

#ifndef RUNNER_APP_LINKS_H_
#define RUNNER_APP_LINKS_H_

#include <windows.h>

#include <string>

// Linki truckmaps:// na Windows (powrót z logowania w przeglądarce, zob. app_auth.dart).
// Przeglądarka uruchamia TruckMaps.exe z linkiem w wierszu poleceń; gdy aplikacja już działa,
// nowa kopia oddaje link przez WM_COPYDATA i kończy się, a okno przekazuje go do Darta
// kanałem truckmaps/links.
namespace app_links {

// Znacznik WM_COPYDATA z linkiem ('TMLK').
constexpr ULONG_PTR kCopyDataId = 0x544D4C4B;

// Pierwszy argument wiersza poleceń zaczynający się od truckmaps: (UTF-8); pusty – brak.
std::string LinkFromCommandLine();

// Rejestruje schemat truckmaps:// dla bieżącego użytkownika (HKCU, bez uprawnień
// administratora), wskazując ten plik exe.
void RegisterScheme();

// Oddaje link działającemu oknu TruckMaps; true – oddano (ta kopia ma się zamknąć).
bool ForwardToRunningInstance(const std::string& link);

}  // namespace app_links

#endif  // RUNNER_APP_LINKS_H_

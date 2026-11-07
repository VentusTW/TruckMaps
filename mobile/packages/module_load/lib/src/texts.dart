import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// Teksty modułu Plan załadunku w języku użytkownika (brak tłumaczenia – polski).
class LoadTexts {
  LoadTexts(this.locale);

  factory LoadTexts.of(BuildContext context) => LoadTexts(Localizations.localeOf(context));

  final Locale locale;

  String _t(String pl, String en) => pick(locale, {'pl': pl, 'en': en});

  String get moduleName => _t('Plan załadunku', 'Load plan');
  String get moduleDescription => _t(
      'LDM i masa ładunku, czy się zmieści, rozmieszczenie palet z kolejnością rozładunków, środek ciężkości i liczba pasów.',
      'Loading metres and weight, whether it fits, pallet layout by unloading order, centre of gravity and number of straps.');
  String get menu => _t('Zlecenia i załadunek', 'Orders & loading');
  String get openPlan => _t('Ułóż ładunek', 'Arrange cargo');
  String get sectionHint => _t(
      'Czy ładunek się zmieści, rozmieszczenie palet, naciski osi i mocowanie – dla tego pojazdu.',
      'Whether the cargo fits, pallet layout, axle loads and securing – for this vehicle.');
  String get vehicle => _t('Pojazd (przestrzeń ładunkowa)', 'Vehicle (cargo space)');
  String get noVehicles => _t('Brak pojazdów z przestrzenią ładunkową.', 'No vehicles with a cargo space.');
  String get items => _t('Ładunek', 'Load');
  String get addItem => _t('Dodaj pozycję', 'Add item');
  String kind(String value) => switch (value) {
        'euro' => _t('Paleta EUR 1,2 × 0,8', 'EUR pallet 1.2 × 0.8'),
        'industrial' => _t('Paleta przemysłowa 1,2 × 1,0', 'Industrial pallet 1.2 × 1.0'),
        'half' => _t('Półpaleta 0,8 × 0,6', 'Half pallet 0.8 × 0.6'),
        _ => _t('Inny wymiar', 'Other size'),
      };
  String get count => _t('Sztuk', 'Pieces');
  String get weight => _t('Masa sztuki', 'Weight each');
  String get stack => _t('W stosie', 'Stacked');
  String get stop => _t('Rozładunek nr', 'Unloading no.');
  String get length => _t('Długość', 'Length');
  String get width => _t('Szerokość', 'Width');
  String get deckLength => _t('Długość przestrzeni (puste – z profilu)', 'Cargo space length (empty – from profile)');
  String get frontWall => _t('Oparty o ścianę czołową', 'Against the front wall');
  String get mats => _t('Maty antypoślizgowe', 'Anti-slip mats');
  String get calculate => _t('Policz plan', 'Calculate plan');
  String get numberInvalid => _t('Wpisz liczbę.', 'Enter a number.');
  String cog(String metres) =>
      _t('Środek ciężkości: $metres m od ściany czołowej', 'Centre of gravity: $metres m from the front wall');
  String get front => _t('Przód (ściana czołowa)', 'Front (front wall)');
  String get height => _t('Wysokość sztuki', 'Height each');
  String get topView => _t('Z góry', 'Top view');
  String get sideView => _t('Z boku', 'Side view');
  String get moveView => _t('Przesuń obraz', 'Move view');
  String get moveItems => _t('Przesuń towar', 'Move goods');
  String get moveViewHint =>
      _t('Przeciągnij, żeby przesunąć obraz; dwa palce – przybliżenie.', 'Drag to move the view; two fingers to zoom.');
  String get moveItemsHint => _t(
      'Przeciągnij paletę: z góry – wzdłuż i w poprzek, z boku – wzdłuż. Po puszczeniu naciski i normy są liczone od nowa.',
      'Drag a pallet: top view – along and across, side view – along. When released, axle loads and limits are recalculated.');
  String get rearrange => _t('Ułóż automatycznie', 'Arrange automatically');
  String get heightHint => _t(
      'Wysokość bez podanej wartości – szacunkowa (1,2 m na sztukę). Naciski – typowa geometria pojazdu i masa własna z profilu.',
      'Heights not entered are estimated (1.2 m per piece). Axle loads use typical vehicle geometry and the tare weight from the profile.');
  String axle(String name) => switch (name) {
        'kingpin' => _t('Siodło', 'Fifth wheel'),
        'trailer_axles' => _t('Osie naczepy', 'Trailer axles'),
        'front_axle' => _t('Oś przednia', 'Front axle'),
        'rear_axles' => _t('Osie tylne', 'Rear axles'),
        'drawbar_front' => _t('Przednia oś przyczepy', 'Trailer front axle'),
        _ => name,
      };
  String tonnes(double kg) => '${NumberFormat('0.0', locale.toLanguageTag()).format(kg / 1000)} t';
  String get disclaimer => _t(
      'Szacunek pomocniczy, nie certyfikat. Za rozmieszczenie i zabezpieczenie ładunku odpowiadają ładujący i kierowca.',
      'A helping estimate, not a certificate. The loader and the driver are responsible for placing and securing the load.');

  String get resultHint => _t('Policz plan – tu pojawią się stan załadunku, naciski na osie i mocowanie.',
      'Calculate the plan – load status, axle loads and securing will appear here.');
  String get axleOver => _t('Przekroczenie', 'Over limit');
  String get layoutTitle => _t('Rozmieszczenie ładunku', 'Load layout');
  String deckDims(String length, String width, String height) => _t(
      'Długość: $length · szerokość: $width · wysokość: $height', 'Length: $length · width: $width · height: $height');
  String get disclaimerLaw => _t(
      'Rozmieszczenie i zabezpieczenie ładunku zgodnie z art. 61 ustawy Prawo o ruchu drogowym, Konwencją CMR i normą PN-EN 12195-1 – na odpowiedzialność kierowcy oraz załadowcy / nadawcy.',
      'Placing and securing the load in line with art. 61 of the Polish Road Traffic Act, the CMR Convention and EN 12195-1 is the responsibility of the driver and the loader / consignor.');

  String number(num value) => NumberFormat.decimalPattern(locale.toLanguageTag()).format(value);
  String fixed(num value, [int digits = 1]) => NumberFormat('0.${'0' * digits}', locale.toLanguageTag()).format(value);
  String metres(num value) => '${fixed(value, 2)} m';

  // ---- Zlecenia i załadunek (ekran według makiety)
  String get screenTitle => _t('Zlecenia i załadunek', 'Orders & loading');
  String get reference => _t('Nr zlecenia', 'Order no.');
  String get bodyCode => _t('Certyfikat nadwozia (EN 12642)', 'Body certificate (EN 12642)');
  String body(String code) => switch (code) {
        'L' => _t('EN 12642 kod L', 'EN 12642 code L'),
        'XL' => _t('EN 12642 kod XL', 'EN 12642 code XL'),
        _ => _t('Brak / nieznany', 'None / unknown'),
      };
  String get noTrailer => _t('Pojazd z własną przestrzenią ładunkową', 'Vehicle with its own cargo space');
  String get kpiPlaces => _t('Status załadunku', 'Load status');
  String placesShare(String pct) => _t('($pct% miejsc)', '($pct% of places)');
  String get kpiWeight => _t('Masa towaru', 'Cargo weight');
  String get kpiFriction => _t('Współczynnik tarcia μ', 'Friction coefficient μ');
  String friction(String mu, bool mats) =>
      mats ? _t('μ = $mu (maty)', 'μ = $mu (mats)') : _t('μ = $mu (bez mat)', 'μ = $mu (no mats)');
  String get forcesButton => _t('Przelicz siły bezwładności (EN 12195)', 'Recalculate inertia forces (EN 12195)');
  String get exportButton => _t('Eksportuj plan PDF/VDI', 'Export plan PDF/VDI');
  String get approveButton => _t('Zatwierdź plan załadunku', 'Approve load plan');
  String get approved => _t('Plan zatwierdzony', 'Plan approved');
  String get approveBlocked => _t(
      'Zatwierdzenie wymaga planu bez przekroczeń, spełnionych norm i potwierdzonego sprzętu z listy VDI 2700.',
      'Approval needs a plan within limits, met standards and the VDI 2700 equipment confirmed.');
  String get exportFailed => _t('Nie udało się otworzyć PDF.', 'Could not open the PDF.');
  String get orderItems => _t('Ładunek zlecenia', 'Order cargo');

  String get simTitle => _t('Symulator załadunku 3D', 'Load simulator 3D');
  String get normsAllOk => _t('Wszystkie normy spełnione', 'All standards met');
  String get normsSomeFail => _t('Normy do sprawdzenia', 'Standards to check');
  String mode(String value) => switch (value) {
        'stacked' => _t('Sztaplowane (2L – piętrowo)', 'Stacked (2L – double deck)'),
        'bulk' => _t('Bezpaletowe i gabaryty', 'Non-palletised & oversize'),
        _ => _t('Standard EPAL (1L)', 'Standard EPAL (1L)'),
      };
  String view(String value) => switch (value) {
        'top' => _t('Rzut z góry', 'Top view'),
        'section' => _t('Przekrój', 'Section'),
        'edit' => _t('Edycja ułożenia', 'Edit layout'),
        _ => _t('Izometria 3D', 'Isometric 3D'),
      };
  String overlayStraps(int count) => _t('Pasy mocujące ($count)', 'Lashing straps ($count)');
  String get overlayVectors => _t('Wektory sił (CoG)', 'Force vectors (CoG)');
  String get legendTitle => _t('Struktura i typ ładunku', 'Cargo structure and type');
  String units(int count) => _t('$count jedn.', '$count units');
  String group(String value) => switch (value) {
        'heavy' => _t('Ciężkie', 'Heavy'),
        'medium' => _t('Średnie', 'Medium'),
        'light' => _t('Lekkie', 'Light'),
        _ => _t('Luzem / gabaryty', 'Loose / oversize'),
      };
  String groupLine(String name, String range, int count) =>
      _t('$name ($range) • $count szt.', '$name ($range) • $count pcs');
  String freeSlots(int count) => _t('Wolne miejsca paletowe • $count', 'Free pallet places • $count');
  String get simHint => _t('Wpisz ładunek zlecenia i policz plan – tu pojawi się symulacja załadunku.',
      'Enter the order cargo and calculate the plan – the load simulation will appear here.');
  String get usableHeight => _t('Wysokość użytkowa', 'Usable height');
  String get loadingMetres => _t('Metry ładowne', 'Loading metres');
  String get cogBalanced => _t('Środek ciężkości: zbalansowany', 'Centre of gravity: balanced');
  String get cogCheck => _t('Środek ciężkości: do korekty', 'Centre of gravity: needs correction');
  String get cogShort => _t('Środek ciężkości', 'Centre of gravity');

  String get axleDistribution => _t('Rozkład nacisków na osie', 'Axle load distribution');
  String get axleIntro => _t('Szacunek z typowej geometrii ciągnika i naczepy oraz mas z profilu pojazdu.',
      'Estimate from typical tractor and trailer geometry and the weights in the vehicle profile.');
  String get tractorFront => _t('Oś 1 (kierowana ciągnika)', 'Axle 1 (tractor steer)');
  String get tractorDrive => _t('Oś 2 (napędowa ciągnika)', 'Axle 2 (tractor drive)');
  String driveShare(String pct) => _t(
      'Na osi napędowej $pct% masy zestawu (min. 25%)', '$pct% of the combination weight on the drive axle (min. 25%)');
  String get gvw => _t('Masa całkowita (DMC)', 'Gross weight (GCW)');
  String get gvwLimit => _t('Dopuszczalny limit', 'Permitted limit');
  String get withinLimits => _t('W normie', 'Within limits');

  String get forcesTitle => _t('Bilans sił EN 12195-1:2010', 'Force balance EN 12195-1:2010');
  String get longitudinal => _t('Kierunek wzdłużny (cx)', 'Longitudinal (cx)');
  String get lateral => _t('Kierunek poprzeczny (cy)', 'Lateral (cy)');
  String braking(String kn) => _t('Hamowanie: $kn kN', 'Braking: $kn kN');
  String cornering(String kn) => _t('Zakręt: $kn kN', 'Cornering: $kn kN');
  String frictionForce(String mu) => _t('Siła tarcia (μ = $mu)', 'Friction force (μ = $mu)');
  String get restForward => _t('Pozostała siła do skompensowania', 'Force left to restrain');
  String get wallCapacity => _t('Zdolność ryglowania ściany przedniej', 'Front wall blocking capacity');
  String get wallUnknown => _t('nieznana', 'unknown');
  String get tension => _t('Wymagana siła napinania pasów (STF)', 'Required strap pre-tension (STF)');
  String tensionValue(String daN, int straps) => _t('$daN daN ($straps pasów)', '$daN daN ($straps straps)');
  String get forcesOk => _t('Obliczenia spełniają kryteria stabilności i ochrony przed poślizgiem oraz przewróceniem.',
      'The calculation meets the criteria for stability and protection against sliding and tipping.');
  String get forcesFail => _t(
      'Mocowanie przez docisk nie wystarcza – dodaj maty antypoślizgowe, blokowanie albo belki rozporowe.',
      'Top-over lashing is not enough – add anti-slip mats, blocking or shoring beams.');

  String get gearTitle =>
      _t('Zestawienie sprzętu i zabezpieczeń (checklista VDI 2700)', 'Equipment and securing (VDI 2700 checklist)');
  // ---- Rodzaje towaru
  String get cargoType => _t('Rodzaj towaru', 'Cargo type');
  String get cargoPickerTitle => _t('Rodzaj towaru', 'Cargo type');
  String get cargoSearch => _t('Szukaj: np. siano, krąg stalowy, beczka…', 'Search: e.g. hay, steel coil, drum…');
  String get pickerEmpty => _t('Nic nie znaleziono.', 'Nothing found.');
  String get pickerAll => _t('Wszystkie', 'All');
  String get addCustomCargo => _t('Dodaj własny rodzaj', 'Add a custom type');
  String get customCargoTitle => _t('Własny rodzaj towaru', 'Custom cargo type');
  String get customName => _t('Nazwa', 'Name');
  String get customGroup => _t('Grupa', 'Group');
  String get customShape => _t('Kształt', 'Shape');
  String get customMu => _t('Tarcie o podłogę μ (bez maty)', 'Friction on the floor μ (no mat)');
  String get customSecuring => _t('Mocowanie', 'Securing');
  String get customStack => _t('Najwyżej w stosie', 'Max. per stack');
  String get customWeight => _t('Masa sztuki', 'Weight each');
  String get customHint => _t(
      'Typowe μ wg EN 12195-1: drewno – sklejka 0,45, stal – drewno 0,2–0,3, beton – drewno 0,55, mata gumowa 0,6.',
      'Typical μ per EN 12195-1: timber – plywood 0.45, steel – timber 0.2–0.3, concrete – timber 0.55, rubber mat 0.6.');
  String get save => _t('Zapisz', 'Save');
  String get cancel => _t('Anuluj', 'Cancel');
  String get delete => _t('Usuń', 'Delete');
  String deleteCargo(String name) => _t('Usunąć własny rodzaj „$name”?', 'Delete the custom type “$name”?');
  String get customBadge => _t('własny', 'custom');
  String shape(String value) => switch (value) {
        'pallet' => _t('Paleta / jednostka paletowa', 'Pallet / pallet unit'),
        'box' => _t('Skrzynia / paczka', 'Box / package'),
        'drum' => _t('Beczka (stojąca)', 'Drum (upright)'),
        'roll' => _t('Rola / krąg stojący', 'Reel / upright coil'),
        'coil' => _t('Krąg / rola leżąca wzdłuż', 'Coil / reel lying lengthwise'),
        'bale' => _t('Bela prostokątna', 'Square bale'),
        'bale_round' => _t('Bela okrągła (leżąca w poprzek)', 'Round bale (lying across)'),
        'bag' => _t('Worek / big bag', 'Sack / big bag'),
        'long' => _t('Dłużyca (pręty, rury, kłody)', 'Long goods (bars, pipes, logs)'),
        'vehicle' => _t('Pojazd / maszyna', 'Vehicle / machine'),
        _ => _t('Luzem (sypki, płynny)', 'Bulk (solid, liquid)'),
      };
  String securingName(String value) => switch (value) {
        'direct' => _t('Bezpośrednie (łańcuchy, odciągi)', 'Direct (chains, lashings)'),
        'none' => _t('Zabudowa (bez pasów – sypkie, płynne)', 'Body (no straps – bulk, liquid)'),
        _ => _t('Pasy dociskowe', 'Top-over straps'),
      };
  String cargoDetails(String dims, String weight, String mu) =>
      _t('$dims · $weight · μ $mu', '$dims · $weight · μ $mu');

  // ---- Wyposażenie użytkownika
  String get myEquipment => _t('Moje wyposażenie', 'My equipment');
  String get myEquipmentTitle => _t('Moje wyposażenie do mocowania', 'My securing equipment');
  String get useEquipment => _t('Uwzględniaj w planie – dobierz rozwiązanie do tego, co mam',
      'Use in the plan – find a solution with what I have');
  String get equipmentHint => _t(
      'Wpisz, ile sztuk masz w pojeździe. Plan spróbuje ułożyć i zabezpieczyć ładunek tylko tym sprzętem (np. zaproponuje maty zamiast brakujących pasów), a jeśli się nie da – powie, czego brakuje.',
      'Enter how many pieces you carry. The plan will try to place and secure the load with this equipment only (e.g. propose mats instead of missing straps) and, if it cannot, tell you what is missing.');
  String equipmentOn(int kinds) =>
      _t('Uwzględniam moje wyposażenie ($kinds rodz.)', 'Using my equipment ($kinds types)');
  String get equipmentOff => _t('Bez ograniczeń sprzętu', 'No equipment limits');
  String get colHave => _t('Masz', 'You have');
  String statusShort(int count) => _t('Brakuje $count', '$count missing');

  // ---- Ręczne układanie: kolizje i piętrowanie
  String get overlapReverted => _t('Towar nie może nachodzić na inny – wrócił na poprzednie miejsce.',
      'Cargo cannot overlap other cargo – it went back to its previous place.');
  String get stackTitle => _t('Postawić na innym towarze?', 'Place on top of other cargo?');
  String stackQuestion(String top, String bottom, int pieces, String height) => _t(
      '„$top” zostanie postawiony na „$bottom” (stos: $pieces szt., $height m). Czy na pewno można stawiać na tym towarze (wytrzymałość opakowania, równa powierzchnia, zabezpieczenie górnej warstwy)?',
      '“$top” will be placed on “$bottom” (stack: $pieces pcs, $height m). Is it really safe to stack on this cargo (packaging strength, flat top, securing of the upper layer)?');
  String get stackYes => _t('Tak, postaw', 'Yes, stack it');
  String stackLimit(String name, int limit) => limit <= 1
      ? _t('Na „$name” nie można stawiać innego towaru – wrócił na poprzednie miejsce.',
          'Nothing may be stacked on “$name” – the cargo went back to its previous place.')
      : _t('„$name”: najwyżej $limit w stosie – towar wrócił na poprzednie miejsce.',
          '“$name”: at most $limit per stack – the cargo went back to its previous place.');
  String stackTooHigh(String name, String height) => _t(
      'Stos na „$name” byłby wyższy niż przestrzeń ładunkowa ($height m) – towar wrócił na poprzednie miejsce.',
      'A stack on “$name” would be higher than the cargo space ($height m) – the cargo went back to its previous place.');
  String stackFootprint(String name) => _t(
      'Towar jest większy niż „$name” pod nim – nie można go postawić, wrócił na poprzednie miejsce.',
      'The cargo is larger than “$name” below it – it cannot be stacked and went back to its previous place.');

  String get gearHoverHint => _t(
      'Najedź na pozycję (na ekranie dotykowym – stuknij nazwę), żeby zobaczyć ją na rysunku.',
      'Hover over an item (on a touch screen – tap its name) to see it on the drawing.');
  String get moveViewHintDesktop => _t('Rysunek mieści się w całości – kółko myszy przewija stronę.',
      'The whole drawing fits – the mouse wheel scrolls the page.');
  String get gearVerified => _t('Komplet sprzętowy zweryfikowany', 'Equipment set verified');
  String get gearPending => _t('Potwierdź założony sprzęt', 'Confirm the fitted equipment');
  String get colNo => _t('Lp.', 'No.');
  String get colItem => _t('Typ środka mocującego', 'Securing device');
  String get colSpec => _t('Specyfikacja techniczna', 'Specification');
  String get colRequired => _t('Wymagane (EN 12195)', 'Required (EN 12195)');
  String get colInstalled => _t('Założone', 'Fitted');
  String get colStatus => _t('Stan', 'Status');
  String gear(String id) => switch (id) {
        'straps' => _t('Pasy transportowe dociskowe 50 mm', 'Top-over lashing straps 50 mm'),
        'edges' => _t('Narożniki ochronne', 'Edge protectors'),
        'beams' => _t('Belki rozporowe (Shoring Beam)', 'Shoring beams'),
        'mats' => _t('Maty antypoślizgowe', 'Anti-slip mats'),
        'airbags' => _t('Poduszki powietrzne sztauerskie', 'Dunnage airbags'),
        'chains' => _t('Łańcuchy / odciągi (mocowanie bezpośrednie)', 'Chains / lashings (direct)'),
        'chocks' => _t('Kliny (podkłady klinowe)', 'Wedges (chocks)'),
        'net' => _t('Siatka zabezpieczająca', 'Cargo net'),
        'stakes' => _t('Kłonice (słupki boczne)', 'Stakes (side posts)'),
        _ => id,
      };
  String gearSpec(String id, int strapDaN) => switch (id) {
        'straps' => _t('LC 2500 daN / STF $strapDaN daN, napinacz z długą dźwignią',
            'LC 2500 daN / STF $strapDaN daN, long-lever ratchet'),
        'edges' => _t('Tworzywo wzmocnione, na górne krawędzie pod każdy pas',
            'Reinforced plastic, on the top edges under every strap'),
        'beams' => _t('Profil ryglujący między burtami – za każdym rozładunkiem i przy luce z przodu',
            'Locking bar between the side walls – after each unloading stop and at a front gap'),
        'mats' => _t('Grubość 8 mm, μ = 0,6 – pod każdą sztuką', '8 mm thick, μ = 0.6 – under every piece'),
        'airbags' => _t('Wypełnienie luk w poprzek rzędu (od 15 cm)', 'Fills gaps across a row (from 15 cm)'),
        _ => '',
      };
  String gearSpecMore(String id) => switch (id) {
        'chains' => _t('Łańcuch 8 mm kl. 8, LC 5000 daN – 4 odciągi na sztukę (ukośnie, ok. 45°)',
            'Chain 8 mm grade 8, LC 5,000 daN – 4 lashings per piece (diagonal, approx. 45°)'),
        'chocks' =>
          _t('Po 2 na krąg, rolę, beczkę leżącą lub koło pojazdu', 'Two per coil, reel, lying drum or vehicle wheel'),
        'net' => _t('Siatka na bele i ładunek luźny – 1 na ok. 4 m długości',
            'Net over bales and loose cargo – 1 per approx. 4 m'),
        'stakes' => _t('Po obu stronach dłużycy, co ok. 3 m', 'On both sides of long goods, approx. every 3 m'),
        _ => '',
      };
  String pieces(int count) => _t('$count szt.', '$count pcs');
  String get statusConfirmed => _t('Potwierdzone', 'Confirmed');
  String get statusMissing => _t('Do założenia', 'To fit');
  String get statusNotNeeded => _t('Niepotrzebne', 'Not needed');

  String get normsTitle => _t('Normy prawne i atesty pojazdu', 'Legal standards and vehicle certificates');
  String normsCount(int ok, int total) => _t('$ok/$total zgodne', '$ok/$total met');
  String normTitle(String id) => switch (id) {
        'en12642' => _t('PN-EN 12642 – nadwozie', 'EN 12642 – vehicle body'),
        'en12195' => _t('PN-EN 12195-1:2010', 'EN 12195-1:2010'),
        'vdi2700' => _t('VDI 2700', 'VDI 2700'),
        _ => _t('Art. 61 Prawa o ruchu drogowym', 'Art. 61 Polish Road Traffic Act'),
      };
  String normText(String id) => switch (id) {
        'en12642' => _t(
            'Ściana przednia kodu L przenosi 40% ładowności (najwyżej 5000 daN), kodu XL – 50%. Bez kodu nadwozia ściany nie liczymy jako atestowanej.',
            'A code L front wall takes 40% of the payload (max. 5,000 daN), code XL – 50%. Without a body code the wall is not counted as certified.'),
        'en12195' => _t('Bilans sił: 0,8 g wzdłużnie, 0,5 g na boki i do tyłu, tarcie i docisk pasów.',
            'Force balance: 0.8 g forwards, 0.5 g sideways and backwards, friction and strap pre-tension.'),
        'vdi2700' => _t('Pasy, narożniki, maty, belki i poduszki według listy; brak nakładania i wystawania ładunku.',
            'Straps, edge protectors, mats, beams and airbags per the list; no overlapping or overhanging cargo.'),
        _ => _t('Dopuszczalne naciski osi, masa całkowita i ładowność zachowane.',
            'Permitted axle loads, gross weight and payload respected.'),
      };
  String get normOk => _t('Spełnione', 'Met');
  String get normCheck => _t('Do sprawdzenia', 'To check');
  String get disclaimerFull => _t('Nota prawna i zastrzeżenie odpowiedzialności', 'Legal note and disclaimer');
  String get disclaimerLong => _t(
      'Prezentowane obliczenia, symulacja, rozkład mas, wektory sił oraz dobór zabezpieczeń mają charakter wyłącznie poglądowy i pomocniczy (uproszczone wzory, typowa geometria pojazdu). Twórcy i operatorzy TruckMaps nie odpowiadają za stan faktyczny załadunku, uszkodzenia towaru ani pojazdu, przekroczenia nacisków i DMC ani za sankcje nałożone przez organy kontroli.',
      'The calculations, simulation, weight distribution, force vectors and choice of securing shown here are illustrative and supporting only (simplified formulas, typical vehicle geometry). The makers and operators of TruckMaps are not liable for the actual state of the load, damage to goods or the vehicle, exceeded axle loads or gross weight, or penalties imposed by inspection authorities.');
}

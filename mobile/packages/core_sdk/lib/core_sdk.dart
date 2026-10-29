/// Jedyne publiczne API powłoki TruckMaps dla pakietów modułów.
///
/// Moduł (pakiet `module_<id>`) implementuje [TruckMapsModule] i rejestruje w powłoce
/// swoje ekrany. Serwer mówi, do których modułów konto ma dostęp – powłoka pokazuje
/// moduł albo ekran „Kup moduł”. Moduły nie importują powłoki ani siebie nawzajem.
library;

export 'src/api.dart';
export 'src/module.dart';
export 'src/registry.dart';

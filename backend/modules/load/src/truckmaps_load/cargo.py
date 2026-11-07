# ruff: noqa: E501 – katalog w tabeli, jedna pozycja w wierszu
"""Rodzaje towaru: wymiary, tarcie o podłogę (EN 12195-1, zał. B), sposób mocowania, piętrowanie,
pasujące zabudowy i dodatkowy sprzęt. Wartości typowe – użytkownik może je zmienić w pozycji
albo zdefiniować własny rodzaj."""

from dataclasses import dataclass
from typing import Literal

from truckmaps.sdk.fleet import BODY_GROUP, BODY_GROUPS

Shape = Literal[
    "pallet", "box", "drum", "bag", "bale", "bale_round", "coil", "roll", "long", "vehicle", "bulk"
]  # fmt: skip
"""Kształt na rysunku: ``coil`` – walec leżący wzdłuż, ``bale_round`` – walec leżący w poprzek,
``drum``/``roll`` – walec stojący, pozostałe – prostopadłościan."""
Securing = Literal["top", "direct", "none"]
"""``top`` – pasy dociskowe, ``direct`` – mocowanie bezpośrednie (łańcuchy / pasy do ładunku),
``none`` – ładunek w zamkniętej zabudowie (sypki, płynny), bez pasów."""
Gear = Literal["chains", "chocks", "net", "stakes"]

DECK = ("general", "temperature", "flat", "heavy", "containers")
"""Zabudowy z podłogą na ładunek w sztukach – domyślne dla towaru ogólnego."""
GROUPS = (
    "pallets", "packages", "agri", "steel", "timber", "building", "paper", "machines", "food",
    "chemicals", "glass", "bulk", "other",
)  # fmt: skip
"""Grupy rodzajów towaru (kolejność w wyborze)."""


@dataclass(frozen=True)
class CargoType:
    id: str
    group: str
    shape: Shape
    length_m: float
    width_m: float
    height_m: float
    weight_kg: float
    mu: float
    """Tarcie o podłogę bez maty."""
    securing: Securing = "top"
    stack: int = 1
    """Ile sztuk najwyżej w stosie."""
    bodies: tuple[str, ...] = DECK
    """Grupy zabudów (``BODY_GROUPS``) albo konkretne rodzaje zabudowy, którymi się go wozi."""
    gear: tuple[Gear, ...] = ()
    kind: str = "custom"
    """Pozycja planu: ``euro`` / ``industrial`` / ``half`` – palety standardowe, inaczej wymiary."""
    adr: bool = False
    name: str = ""
    """Nazwa własnego rodzaju (wbudowane – z tłumaczeń)."""
    custom: bool = False

    def allows(self, body: str) -> bool:
        """Czy ten towar wozi się taką zabudową (nieznana zabudowa – tak)."""
        return not body or body in self.bodies or BODY_GROUP.get(body, "") in self.bodies


def _t(*args, **kw) -> CargoType:
    return CargoType(*args, **kw)


BULK = ("bulk",)
CATALOG: tuple[CargoType, ...] = (
    # Palety i jednostki paletowe.
    _t("pallet_euro", "pallets", "pallet", 1.2, 0.8, 1.2, 500, 0.3, stack=2, kind="euro"),
    _t("pallet_industrial", "pallets", "pallet", 1.2, 1.0, 1.2, 600, 0.3, stack=2, kind="industrial"),
    _t("pallet_half", "pallets", "pallet", 0.8, 0.6, 1.0, 250, 0.3, stack=2, kind="half"),
    _t("pallet_quarter", "pallets", "pallet", 0.6, 0.4, 0.8, 120, 0.3, stack=2),
    _t("pallet_plastic", "pallets", "pallet", 1.2, 0.8, 1.2, 450, 0.2, stack=2),
    _t("pallet_cage", "pallets", "pallet", 1.24, 0.835, 0.97, 600, 0.3, stack=3),
    _t("pallet_sacks", "pallets", "pallet", 1.2, 0.8, 1.2, 1000, 0.3),
    _t("pallet_chilled", "pallets", "pallet", 1.2, 0.8, 1.6, 600, 0.3, bodies=("temperature",)),
    _t("pallet_frozen", "pallets", "pallet", 1.2, 0.8, 1.6, 700, 0.3, bodies=("temperature",)),
    # Opakowania jednostkowe.
    _t("cartons", "packages", "box", 0.6, 0.4, 0.4, 15, 0.4, stack=5),
    _t("crate", "packages", "box", 1.2, 1.0, 1.0, 400, 0.45, stack=2),
    _t("drum", "packages", "drum", 0.6, 0.6, 0.9, 220, 0.3, gear=("chocks",)),
    _t("ibc", "packages", "box", 1.2, 1.0, 1.15, 1100, 0.3, stack=2),
    _t("big_bag", "packages", "bag", 0.9, 0.9, 1.2, 1000, 0.4),
    _t("furniture", "packages", "box", 2.0, 1.0, 1.0, 120, 0.4, stack=2),
    _t("household_goods", "packages", "box", 1.0, 1.0, 1.0, 150, 0.4, stack=2),
    # Rolnicze.
    _t("hay_round", "agri", "bale_round", 1.5, 1.2, 1.5, 300, 0.4, stack=3, gear=("net", "chocks"),
       bodies=("general", "flat", "heavy")),  # fmt: skip
    _t("hay_square", "agri", "bale", 2.4, 1.2, 0.9, 450, 0.4, stack=3, gear=("net",),
       bodies=("general", "flat", "heavy")),  # fmt: skip
    _t("straw_square", "agri", "bale", 2.4, 1.2, 0.9, 350, 0.4, stack=3, gear=("net",),
       bodies=("general", "flat", "heavy")),  # fmt: skip
    _t("silage_bale", "agri", "bale_round", 1.25, 1.2, 1.25, 700, 0.3, stack=2, gear=("chocks",),
       bodies=("general", "flat", "heavy")),  # fmt: skip
    _t("fruit_bins", "agri", "box", 1.2, 1.0, 0.75, 300, 0.45, stack=4),
    _t("vegetables_sacks", "agri", "bag", 0.8, 0.5, 0.3, 25, 0.4, stack=6),
    # Stal i metale.
    _t("coil_eye_horizontal", "steel", "coil", 1.5, 1.8, 1.8, 15_000, 0.2, securing="direct",
       gear=("chains", "chocks"), bodies=("coil", "flatbed", "lowloader", "extendable")),  # fmt: skip
    _t("coil_eye_vertical", "steel", "roll", 1.5, 1.5, 1.2, 8_000, 0.3, securing="direct",
       gear=("chains",), bodies=("general", "flat", "heavy")),  # fmt: skip
    _t("sheet_bundle", "steel", "box", 3.0, 1.5, 0.3, 5_000, 0.2, stack=3, bodies=("general", "flat", "heavy")),
    _t("bars", "steel", "long", 12.0, 0.5, 0.4, 3_000, 0.2, stack=3, gear=("stakes",),
       bodies=("flat", "heavy", "curtain", "mega", "sliding_roof")),  # fmt: skip
    _t("pipes", "steel", "long", 12.0, 1.0, 0.5, 2_500, 0.2, stack=3, gear=("stakes",),
       bodies=("flat", "heavy", "curtain", "mega", "sliding_roof")),  # fmt: skip
    _t("steel_beams", "steel", "long", 12.0, 0.6, 0.4, 4_000, 0.2, stack=2, gear=("stakes",),
       bodies=("flat", "heavy", "curtain", "sliding_roof")),  # fmt: skip
    _t("wire_rod", "steel", "coil", 1.2, 1.2, 1.2, 2_000, 0.2, securing="direct", gear=("chains", "chocks"),
       bodies=("coil", "flat", "heavy", "curtain", "mega")),  # fmt: skip
    # Drewno.
    _t("lumber", "timber", "box", 4.0, 1.2, 1.0, 1_500, 0.45, stack=3),
    _t("logs", "timber", "long", 5.0, 2.4, 2.0, 8_000, 0.45, gear=("stakes",), bodies=("timber", "stake")),
    _t("panels", "timber", "box", 2.5, 1.25, 1.0, 2_000, 0.4, stack=2),
    _t("firewood", "timber", "pallet", 1.2, 0.8, 1.6, 700, 0.45),
    # Budowlane.
    _t("bricks", "building", "pallet", 1.2, 0.8, 1.0, 1_100, 0.3),
    _t("cement_bags", "building", "pallet", 1.2, 0.8, 1.0, 1_500, 0.3),
    _t("paving", "building", "pallet", 1.2, 1.0, 0.8, 1_300, 0.3),
    _t("precast", "building", "box", 6.0, 1.2, 0.4, 6_000, 0.55, securing="direct", gear=("chains",),
       bodies=("flat", "heavy")),  # fmt: skip
    _t("insulation", "building", "box", 1.2, 1.0, 1.2, 150, 0.4, stack=2),
    _t("tiles", "building", "pallet", 1.2, 0.8, 0.9, 1_200, 0.3),
    # Papier.
    _t("paper_roll_vertical", "paper", "roll", 1.2, 1.2, 1.4, 1_500, 0.4, stack=2),
    _t("paper_roll_horizontal", "paper", "coil", 1.6, 1.2, 1.2, 1_500, 0.4, gear=("chocks",)),
    _t("paper_bales", "paper", "bale", 1.1, 0.8, 0.8, 500, 0.4, stack=3),
    # Maszyny i pojazdy.
    _t("machine", "machines", "box", 3.0, 2.0, 2.0, 8_000, 0.3, securing="direct", gear=("chains",),
       bodies=("flat", "heavy", "curtain", "mega", "box", "sliding_roof")),  # fmt: skip
    _t("car", "machines", "vehicle", 4.5, 1.8, 1.5, 1_400, 0.4, securing="direct", gear=("chocks",),
       bodies=("car_transporter", "flatbed", "lowloader", "curtain", "mega")),  # fmt: skip
    _t("forklift", "machines", "vehicle", 3.0, 1.2, 2.2, 4_000, 0.3, securing="direct",
       gear=("chains", "chocks"), bodies=("flat", "heavy", "curtain", "mega")),  # fmt: skip
    _t("excavator", "machines", "vehicle", 7.0, 2.5, 3.0, 20_000, 0.3, securing="direct",
       gear=("chains", "chocks"), bodies=("lowloader", "extendable", "modular")),  # fmt: skip
    _t("tractor_agri", "machines", "vehicle", 4.5, 2.4, 2.8, 6_000, 0.3, securing="direct",
       gear=("chains", "chocks"), bodies=("lowloader", "flatbed", "extendable")),  # fmt: skip
    # Spożywcze i napoje.
    _t("beverage_crates", "food", "pallet", 1.2, 0.8, 1.6, 900, 0.3, bodies=(*DECK, "beverage")),
    _t("kegs", "food", "drum", 0.4, 0.4, 0.6, 60, 0.3, stack=3, bodies=(*DECK, "beverage")),
    _t("meat_hanging", "food", "box", 1.0, 0.8, 2.2, 500, 0.3, bodies=("temperature",)),
    _t("fresh_produce", "food", "pallet", 1.2, 0.8, 1.8, 500, 0.3, bodies=("temperature", "general")),
    # Chemia i ADR.
    _t("adr_pallet", "chemicals", "pallet", 1.2, 0.8, 1.2, 700, 0.3, adr=True),
    _t("gas_cylinders", "chemicals", "box", 1.2, 0.8, 1.6, 700, 0.3, adr=True),
    _t("adr_drums", "chemicals", "drum", 0.6, 0.6, 0.9, 220, 0.3, gear=("chocks",), adr=True),
    _t("ibc_adr", "chemicals", "box", 1.2, 1.0, 1.15, 1_100, 0.3, adr=True),
    # Szkło.
    _t("glass_rack", "glass", "box", 3.2, 1.2, 3.0, 2_000, 0.3, securing="direct", gear=("chains",),
       bodies=("glass", "flatbed", "lowloader")),  # fmt: skip
    _t("windows", "glass", "box", 2.5, 1.2, 2.2, 800, 0.3, bodies=("general", "glass")),
    # Sypkie i płynne (w zabudowie, bez pasów).
    _t("sand_gravel", "bulk", "bulk", 6.0, 2.4, 0.8, 20_000, 0.6, securing="none", bodies=("tipper",)),
    _t("grain", "bulk", "bulk", 6.0, 2.4, 1.2, 20_000, 0.6, securing="none",
       bodies=("tipper", "walking_floor", "hopper", "silo")),  # fmt: skip
    _t("wood_chips", "bulk", "bulk", 6.0, 2.4, 2.0, 15_000, 0.6, securing="none",
       bodies=("walking_floor", "tipper")),  # fmt: skip
    _t("powder", "bulk", "bulk", 6.0, 2.4, 1.0, 25_000, 0.6, securing="none", bodies=("silo",)),
    _t("liquid", "bulk", "bulk", 6.0, 2.4, 1.2, 25_000, 0.6, securing="none", bodies=("liquid",)),
    _t("liquid_food", "bulk", "bulk", 6.0, 2.4, 1.2, 25_000, 0.6, securing="none",
       bodies=("tanker_food",)),  # fmt: skip
    # Inne.
    _t("general_cargo", "other", "box", 1.0, 1.0, 1.0, 300, 0.3),
    _t("animals", "other", "box", 2.4, 2.4, 1.0, 1_000, 0.3, securing="none", bodies=("livestock",)),
)  # fmt: skip
BUILT_IN = {c.id: c for c in CATALOG}

assert all(c.group in GROUPS for c in CATALOG)
assert all(b in BODY_GROUPS or b in BODY_GROUP for c in CATALOG for b in c.bodies), (
    "nieznana zabudowa w katalogu towarów"
)


def for_kind(kind: str) -> CargoType | None:
    """Pozycja bez rodzaju towaru – paleta standardowa wg ``kind``."""
    return {"euro": BUILT_IN["pallet_euro"], "industrial": BUILT_IN["pallet_industrial"],
            "half": BUILT_IN["pallet_half"]}.get(kind)  # fmt: skip

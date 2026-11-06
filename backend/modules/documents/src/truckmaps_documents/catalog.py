"""Rodzaje dokumentów i ich pola (układ wzoru – własny, treść pól z przepisów).

Etykiety pól są w tłumaczeniach modułu: ``documents.field.<pole>``, kolumny tabel
``documents.col.<kolumna>``, rodzaje ``documents.kind.<rodzaj>``, podstawa prawna
``documents.basis.<rodzaj>``.
"""

from dataclasses import dataclass, field
from typing import Literal

FieldType = Literal["text", "multiline", "date", "number", "rows"]


@dataclass(frozen=True)
class Field:
    key: str
    type: FieldType = "text"
    width: float = 1.0
    """Część szerokości wiersza w wydruku (0,5 – pół strony)."""
    box: str = ""
    """Numer pola we wzorze (np. pole 16 listu CMR)."""
    columns: tuple[str, ...] = ()
    """Kolumny tabeli (pole ``rows``)."""
    label: str = ""
    """Etykieta z szablonu firmy (zmieniona albo pole dodane przez firmę)."""


@dataclass(frozen=True)
class Kind:
    id: str
    prefix: str
    """Przedrostek numeru: ``CMR/2026/11/0001``."""
    fields: tuple[Field, ...]
    signatures: tuple[str, ...] = field(default=())
    """Miejsca na podpisy na końcu dokumentu (klucze ``documents.sign.<…>``)."""

    def get(self, key: str) -> Field | None:
        return next((f for f in self.fields if f.key == key), None)


GOODS = ("marks", "packages", "packing", "nature", "statistical_number", "gross_kg", "volume_m3")

CMR = Kind(
    id="cmr",
    prefix="CMR",
    fields=(
        Field("sender", "multiline", 0.5, "1"),
        Field("carrier", "multiline", 0.5, "16"),
        Field("consignee", "multiline", 0.5, "2"),
        Field("successive_carriers", "multiline", 0.5, "17"),
        Field("delivery_place", "multiline", 0.5, "3"),
        Field("carrier_reservations", "multiline", 0.5, "18"),
        Field("loading_place_date", "multiline", 0.5, "4"),
        Field("special_agreements", "multiline", 0.5, "19"),
        Field("attached_documents", "multiline", 1.0, "5"),
        Field("goods", "rows", 1.0, "6–12", GOODS),
        Field("dangerous_goods", "multiline", 1.0, "ADR"),
        Field("sender_instructions", "multiline", 0.5, "13"),
        Field("charges", "multiline", 0.5, "15"),
        Field("payment_terms", "text", 0.5, "14"),
        Field("to_be_paid_by", "text", 0.5, "20"),
        Field("cash_on_delivery", "text", 0.5, ""),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("issued_place", "text", 0.5, "21"),
        Field("issued_date", "date", 0.5, "21"),
    ),
    signatures=("sender", "carrier", "consignee"),
)

ORDER = Kind(
    id="transport_order",
    prefix="ZT",
    fields=(
        Field("principal", "multiline", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("vehicle_type", "text", 0.5),
        Field("driver_name", "text", 0.5),
        Field("driver_phone", "text", 0.5),
        Field("stops", "rows", 1.0, "", ("stop_type", "place", "date_time", "reference")),
        Field("goods", "rows", 1.0, "", ("nature", "packages", "packing", "gross_kg", "ldm")),
        Field("dangerous_goods", "text", 0.5),
        Field("temperature", "text", 0.5),
        Field("distance_km", "number", 0.25),
        Field("duration_h", "number", 0.25),
        Field("freight", "text", 0.25),
        Field("payment_days", "number", 0.25),
        Field("required_documents", "multiline", 0.5),
        Field("insurance", "multiline", 0.5),
        Field("contact_person", "text", 0.5),
        Field("issued_date", "date", 0.5),
        Field("terms", "multiline", 1.0),
    ),
    signatures=("principal", "carrier"),
)

ROAD_CARD = Kind(
    id="road_card",
    prefix="KD",
    fields=(
        Field("company", "multiline", 0.5),
        Field("vehicle", "multiline", 0.5),
        Field("period_from", "date", 0.25),
        Field("period_to", "date", 0.25),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("driver_name", "text", 0.5),
        Field("odometer_start", "number", 0.25),
        Field("odometer_end", "number", 0.25),
        Field("trips", "rows", 1.0, "", ("date", "departure", "arrival", "route", "km", "loaded")),
        Field("total_km", "number", 0.25),
        Field("fuel_start", "number", 0.25),
        Field("fuel_added", "number", 0.25),
        Field("fuel_end", "number", 0.25),
        Field("notes", "multiline", 1.0),
    ),
    signatures=("driver", "issuer"),
)

KINDS: dict[str, Kind] = {k.id: k for k in (CMR, ORDER, ROAD_CARD)}

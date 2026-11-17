"""Rodzaje dokumentów i ich pola (układ wzoru – własny, treść pól z przepisów).

Etykiety pól są w tłumaczeniach modułu: ``documents.field.<pole>``, kolumny tabel
``documents.col.<kolumna>``, rodzaje ``documents.kind.<rodzaj>``, podstawa prawna
``documents.basis.<rodzaj>``.
"""

from dataclasses import dataclass, field
from typing import Literal

FieldType = Literal["text", "multiline", "date", "number", "rows", "signature"]
"""``signature`` – podpis złożony na ekranie (JPEG w base64)."""


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

POD = Kind(
    id="pod",
    prefix="POD",
    fields=(
        Field("document_ref", "text", 0.5),
        Field("received_at", "text", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("consignee", "multiline", 0.5),
        Field("delivery_place", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("arrival", "text", 0.25),
        Field("unloaded_at", "text", 0.25),
        Field("goods", "rows", 1.0, "", ("nature", "packages", "packing", "gross_kg")),
        Field("seal_number", "text", 0.25),
        Field("temperature", "text", 0.25),
        Field("waiting_time", "text", 0.5),
        Field("reservations", "multiline", 1.0),
        Field("received_by", "text", 1.0),
        Field("consignee_signature", "signature", 0.5),
        Field("driver_signature", "signature", 0.5),
    ),
)

DAMAGE = Kind(
    id="damage_report",
    prefix="PS",
    fields=(
        Field("document_ref", "text", 0.5),
        Field("found_at", "text", 0.25),
        Field("seal_number", "text", 0.25),
        Field("found_place", "text", 1.0),
        Field("carrier", "multiline", 0.5),
        Field("sender", "multiline", 0.5),
        Field("consignee", "multiline", 0.5),
        Field("insurance", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("goods", "rows", 1.0, "", ("nature", "packages", "packing", "gross_kg", "damaged")),
        Field("damage_type", "text", 0.5),
        Field("damage_value", "text", 0.5),
        Field("damage_description", "multiline", 1.0),
        Field("damage_cause", "multiline", 1.0),
        Field("witnesses", "multiline", 0.5),
        Field("notes", "multiline", 0.5),
        Field("driver_signature", "signature", 0.5),
        Field("consignee_signature", "signature", 0.5),
    ),
)

LOADING = Kind(
    id="loading_report",
    prefix="PZ",
    fields=(
        Field("document_ref", "text", 0.5),
        Field("loaded_at", "text", 0.25),
        Field("seal_number", "text", 0.25),
        Field("loading_place", "text", 1.0),
        Field("sender", "multiline", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("goods", "rows", 1.0, "", ("nature", "packages", "packing", "gross_kg")),
        Field("total_kg", "number", 0.25),
        Field("ldm", "number", 0.25),
        Field("temperature", "text", 0.5),
        Field("dangerous_goods", "text", 1.0),
        Field("arrangement", "multiline", 1.0),
        Field("securing", "multiline", 0.5),
        Field("goods_condition", "multiline", 0.5),
        Field("carrier_reservations", "multiline", 1.0),
        Field("sender_signature", "signature", 0.5),
        Field("driver_signature", "signature", 0.5),
    ),
)

POSTING = Kind(
    id="posting_declaration",
    prefix="DEL",
    fields=(
        Field("carrier", "multiline", 0.5),
        Field("contact_person", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("driver_birth_date", "date", 0.25),
        Field("driver_licence_number", "text", 0.25),
        Field("driver_address", "multiline", 0.5),
        Field("driver_id_document", "text", 0.5),
        Field("contract_start", "date", 0.25),
        Field("applicable_law", "text", 0.25),
        Field("host_country", "text", 0.25),
        Field("transport_type", "text", 0.25),
        Field("period_from", "date", 0.25),
        Field("period_to", "date", 0.25),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("notes", "multiline", 1.0),
        Field("issued_place", "text", 0.5),
        Field("issued_date", "date", 0.5),
    ),
    signatures=("carrier_rep",),
)

DRIVER_ACTIVITY = Kind(
    id="driver_activity",
    prefix="ZDK",
    fields=(
        Field("company", "multiline", 1.0, "1–5"),
        Field("signer_name", "text", 0.5, "6"),
        Field("signer_position", "text", 0.5, "7"),
        Field("driver_name", "text", 0.5, "8"),
        Field("driver_birth_date", "date", 0.25, "9"),
        Field("driver_licence_number", "text", 0.25, "10"),
        Field("work_start", "date", 0.5, "11"),
        Field("period_from", "text", 0.25, "12"),
        Field("period_to", "text", 0.25, "13"),
        Field("reasons", "rows", 1.0, "14–19", ("mark", "reason")),
        Field("issued_place", "text", 0.5, "20"),
        Field("issued_date", "date", 0.5, "20"),
        Field("driver_statement", "multiline", 1.0, "21–22"),
    ),
    signatures=("carrier_rep", "driver"),
)

BUSINESS_TRIP = Kind(
    id="business_trip",
    prefix="PWS",
    fields=(
        Field("employer", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("purpose", "text", 1.0),
        Field("destination", "multiline", 1.0),
        Field("transport", "text", 0.5),
        Field("period_from", "date", 0.25),
        Field("period_to", "date", 0.25),
        Field("countries", "rows", 1.0, "", ("country", "entered", "left", "hours")),
        Field("per_diems", "rows", 1.0, "", ("country", "days", "rate", "currency", "amount")),
        Field("per_diem_total", "text", 0.5),
        Field("accommodation", "text", 0.25),
        Field("lump_sums", "text", 0.25),
        Field("other_costs", "text", 0.25),
        Field("advance", "text", 0.25),
        Field("settlement", "text", 0.5),
        Field("notes", "multiline", 1.0),
        Field("issued_date", "date", 0.5),
    ),
    signatures=("issuer", "driver"),
)

WORKING_TIME = Kind(
    id="working_time",
    prefix="ECP",
    fields=(
        Field("company", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("period_from", "date", 0.25),
        Field("period_to", "date", 0.25),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field(
            "days",
            "rows",
            1.0,
            "",
            ("date", "start", "end", "driving_h", "other_work_h", "availability_h", "km"),
        ),
        Field("total_driving_h", "number", 0.25),
        Field("total_km", "number", 0.25),
        Field("notes", "multiline", 1.0),
    ),
    signatures=("driver", "issuer"),
)

CABIN_CHECKLIST = Kind(
    id="cabin_checklist",
    prefix="LK",
    fields=(
        Field("check_date", "date", 0.25),
        Field("vehicle", "text", 0.25),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("driver_name", "text", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("checklist", "rows", 1.0, "", ("mark", "document", "valid_until", "status")),
        Field("notes", "multiline", 1.0),
    ),
    signatures=("driver",),
)

CONSIGNMENT_NOTE = Kind(
    id="consignment_note",
    prefix="LP",
    fields=(
        Field("sender", "multiline", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("consignee", "multiline", 0.5),
        Field("delivery_place", "multiline", 0.5),
        Field("loading_place_date", "multiline", 0.5),
        Field("attached_documents", "multiline", 0.5),
        Field("goods", "rows", 1.0, "", ("marks", "packages", "packing", "nature", "gross_kg")),
        Field("declared_value", "text", 0.5),
        Field("charges", "text", 0.5),
        Field("cash_on_delivery", "text", 0.5),
        Field("to_be_paid_by", "text", 0.5),
        Field("sender_instructions", "multiline", 1.0),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("issued_place", "text", 0.25),
        Field("issued_date", "date", 0.25),
    ),
    signatures=("sender", "carrier", "consignee"),
)

VEHICLE_HANDOVER = Kind(
    id="vehicle_handover",
    prefix="PP",
    fields=(
        Field("handover_at", "text", 0.5),
        Field("handover_place", "text", 0.5),
        Field("company", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("vehicle", "text", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("odometer", "number", 0.25),
        Field("fuel_level", "text", 0.25),
        Field("adblue_level", "text", 0.25),
        Field("tyres", "text", 0.25),
        Field("equipment", "rows", 1.0, "", ("item", "count", "state")),
        Field("condition", "multiline", 1.0),
        Field("notes", "multiline", 1.0),
        Field("driver_signature", "signature", 0.5),
    ),
    signatures=("issuer",),
)

PALLET_NOTE = Kind(
    id="pallet_note",
    prefix="KP",
    fields=(
        Field("document_ref", "text", 0.5),
        Field("exchange_at", "text", 0.5),
        Field("exchange_place", "text", 1.0),
        Field("carrier", "multiline", 0.5),
        Field("counterparty", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field(
            "pallets",
            "rows",
            1.0,
            "",
            ("pallet_type", "delivered", "returned", "balance", "quality"),
        ),
        Field("notes", "multiline", 1.0),
        Field("counterparty_signature", "signature", 0.5),
        Field("driver_signature", "signature", 0.5),
    ),
)

SECURING = Kind(
    id="securing_declaration",
    prefix="OM",
    fields=(
        Field("document_ref", "text", 0.5),
        Field("loaded_at", "text", 0.5),
        Field("loading_place", "text", 1.0),
        Field("sender", "multiline", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("goods", "rows", 1.0, "", ("nature", "packages", "packing", "gross_kg")),
        Field("total_kg", "number", 0.25),
        Field("body_standard", "text", 0.25),
        Field("securing_method", "text", 0.5),
        Field("lashings", "text", 0.5),
        Field("securing_aids", "text", 0.5),
        Field("statement", "multiline", 1.0),
        Field("sender_signature", "signature", 0.5),
        Field("driver_signature", "signature", 0.5),
    ),
)

ADR_DOCUMENT = Kind(
    id="adr_document",
    prefix="ADR",
    fields=(
        Field("sender", "multiline", 0.5),
        Field("consignee", "multiline", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("loading_place_date", "multiline", 0.5),
        Field("delivery_place", "multiline", 1.0),
        Field(
            "dangerous_rows",
            "rows",
            1.0,
            "5.4.1.1.1",
            (
                "un_number",
                "shipping_name",
                "class_labels",
                "packing_group",
                "tunnel_code",
                "packages",
                "quantity",
                "transport_category",
            ),
        ),
        Field("dangerous_goods", "multiline", 1.0),
        Field("points_1136", "text", 0.5, "1.1.3.6"),
        Field("special_provisions", "multiline", 0.5),
        Field("written_instructions", "multiline", 1.0, "5.4.3"),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("issued_place", "text", 0.25),
        Field("issued_date", "date", 0.25),
    ),
    signatures=("sender", "carrier"),
)

SENT_DATA = Kind(
    id="sent_data",
    prefix="SENT",
    fields=(
        Field("reference_number", "text", 0.5),
        Field("locator_number", "text", 0.5),
        Field("sender", "multiline", 0.5),
        Field("consignee", "multiline", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("driver_name", "text", 0.5),
        Field("loading_place", "text", 0.5),
        Field("delivery_place", "text", 0.5),
        Field("start_at", "text", 0.25),
        Field("duration_h", "number", 0.25),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("goods", "rows", 1.0, "", ("cn_code", "nature", "packages", "gross_kg")),
        Field("notes", "multiline", 1.0),
    ),
)

EDD_DATA = Kind(
    id="edd_data",
    prefix="EDD",
    fields=(
        Field("arc_number", "text", 0.5),
        Field("dispatch_date", "date", 0.5),
        Field("sender", "multiline", 0.5),
        Field("consignee", "multiline", 0.5),
        Field("loading_place", "text", 0.5),
        Field("delivery_place", "text", 0.5),
        Field("carrier", "multiline", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("goods", "rows", 1.0, "", ("cn_code", "nature", "quantity", "unit")),
        Field("notes", "multiline", 1.0),
    ),
)

OVERSIZE_PERMIT = Kind(
    id="oversize_permit_data",
    prefix="ZN",
    fields=(
        Field("applicant", "multiline", 0.5),
        Field("permit_category", "text", 0.25),
        Field("trips_count", "number", 0.25),
        Field("vehicle_type", "text", 0.5),
        Field("tractor_plate", "text", 0.25),
        Field("trailer_plate", "text", 0.25),
        Field("length_m", "number", 0.25),
        Field("width_m", "number", 0.25),
        Field("height_m", "number", 0.25),
        Field("total_weight_t", "number", 0.25),
        Field("axle_loads", "text", 0.5),
        Field("cargo_description", "multiline", 1.0),
        Field("route_description", "multiline", 1.0),
        Field("period_from", "date", 0.25),
        Field("period_to", "date", 0.25),
        Field("escort", "text", 0.5),
        Field("notes", "multiline", 1.0),
    ),
)

KINDS: dict[str, Kind] = {
    k.id: k
    for k in (
        CMR,
        ORDER,
        ROAD_CARD,
        POD,
        POSTING,
        DAMAGE,
        LOADING,
        CONSIGNMENT_NOTE,
        DRIVER_ACTIVITY,
        BUSINESS_TRIP,
        WORKING_TIME,
        CABIN_CHECKLIST,
        VEHICLE_HANDOVER,
        PALLET_NOTE,
        SECURING,
        ADR_DOCUMENT,
        SENT_DATA,
        EDD_DATA,
        OVERSIZE_PERMIT,
    )
}

PERIOD_KINDS = frozenset(
    {"road_card", "posting_declaration", "driver_activity", "business_trip", "working_time"}
)
"""Rodzaje z okresem „od–do” (aplikacja wysyła ``date_from`` / ``date_to``)."""

TRIP_KINDS = frozenset({"road_card", "business_trip", "working_time"})
"""Rodzaje wypełniane z przejazdów pojazdu w okresie."""

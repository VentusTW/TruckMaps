"""Profile pojazdów: wymiary i masy, według których liczona jest trasa.

Pojazd jest prywatny (widzi go tylko właściciel) albo należy do firmy – wtedy widzą
go wszyscy jej członkowie, a zmieniają właściciel firmy i dyspozytorzy.

Każdy pojazd jest osobny; do ciągnika podpina się naczepę, do samochodu ciężarowego,
autobusu i dostawczego – przyczepę. Trasę liczy się dla pojazdu razem z podpiętą częścią.
"""

import base64
import binascii
import uuid
from datetime import UTC, date, datetime, timedelta
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import JSON, DateTime, ForeignKey, String, func, or_, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.companies import (
    MANAGES_VEHICLES,
    SERVICES_VEHICLES,
    Company,
    CompanyBase,
    CompanyKind,
    CompanyMember,
    company_ids,
)
from truckmaps.core.costs import CostRates
from truckmaps.core.currency import UserSettings
from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.core.registration import (
    RegistrationError,
    decode_text,
    read_image,
    vehicle_data,
    vehicle_data_from_text,
)
from truckmaps.sdk import Principal

# Znaki i zakazy "dla samochodów ciężarowych" dotyczą pojazdów o DMC powyżej 3,5 t.
HGV_MIN_GVW_T = 3.5

FREE_PRIVATE_VEHICLES = 1
"""Pojazdy prywatne bez modułu ``vehicles_plus`` (konto bez planu: trasy i jeden pojazd)."""
VEHICLES_PLUS = "vehicles_plus"

IN_USE_HOURS = 14
"""Jak długo pojazd jest „w użyciu” po starcie nawigacji, jeśli kierowca go nie zwolni."""
KINGPIN_OVERLAP_M = 3.1
"""Ciągnik z naczepą: o tyle zestaw jest krótszy od sumy długości (naczepa nad ciągnikiem)."""


class VehicleKind(StrEnum):
    COMBINATION = "combination"
    """Zestaw zapisany jako całość (dawne wpisy) – wymiary i masy całości, bez łączenia."""
    RIGID = "rigid"
    """Samochód ciężarowy (solówka)."""
    TRACTOR = "tractor"
    """Ciągnik siodłowy."""
    VAN = "van"
    """Samochód dostawczy (towary)."""
    BUS = "bus"
    """Autobus / bus do przewozu osób – z liczbą miejsc."""
    SEMITRAILER = "semitrailer"
    TRAILER = "trailer"


DRIVABLE = {
    VehicleKind.COMBINATION,
    VehicleKind.RIGID,
    VehicleKind.TRACTOR,
    VehicleKind.VAN,
    VehicleKind.BUS,
}
"""Rodzaje, dla których liczy się trasę; naczepy i przyczepy to wyposażenie floty."""
TOWED = {VehicleKind.SEMITRAILER, VehicleKind.TRAILER}
COMPANY_VEHICLES = {
    CompanyKind.CARRIER: set(VehicleKind) - {VehicleKind.BUS},
    CompanyKind.PASSENGER: {VehicleKind.BUS, VehicleKind.TRAILER},
    CompanyKind.FORWARDER: set(),
}
"""Jakie pojazdy może mieć firma danego rodzaju (spedycja – żadnych)."""
COUPLES = {
    VehicleKind.TRACTOR: VehicleKind.SEMITRAILER,
    VehicleKind.RIGID: VehicleKind.TRAILER,
    VehicleKind.BUS: VehicleKind.TRAILER,
    VehicleKind.VAN: VehicleKind.TRAILER,
}
"""Co do czego można podpiąć – ciągnika z solówką czy autobusem już nie."""


class EmissionClass(StrEnum):
    """Klasa emisji spalin – myto, strefy czystego transportu, przetargi."""

    EURO3 = "euro3"
    EURO4 = "euro4"
    EURO5 = "euro5"
    EURO6 = "euro6"
    ELECTRIC = "electric"


class FuelType(StrEnum):
    """Napęd – jednostka spalania: ON w litrach, LNG / CNG / wodór w kg, prąd w kWh."""

    DIESEL = "diesel"
    LNG = "lng"
    CNG = "cng"
    ELECTRIC = "electric"
    HYDROGEN = "hydrogen"


BODY_KINDS = {
    VehicleKind.COMBINATION,
    VehicleKind.RIGID,
    VehicleKind.VAN,
    VehicleKind.SEMITRAILER,
    VehicleKind.TRAILER,
}
"""Rodzaje z zabudową (plandeka, chłodnia, cysterna…); ciągnik i autobus jej nie mają."""
TACHOGRAPH_KINDS = {
    VehicleKind.COMBINATION,
    VehicleKind.RIGID,
    VehicleKind.TRACTOR,
    VehicleKind.BUS,
}
"""Rodzaje z tachografem (dostawczy do 3,5 t go nie ma)."""


class TrailerType(StrEnum):
    NONE = "none"
    CURTAIN = "curtain"
    BOX = "box"
    REEFER = "reefer"
    TANKER = "tanker"
    FLATBED = "flatbed"
    CONTAINER = "container"
    LOWLOADER = "lowloader"


def _now() -> datetime:
    return datetime.now(UTC)


class VehicleProfile(Base):
    __tablename__ = "vehicle_profiles"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_subject: Mapped[str] = mapped_column(String(255), index=True)
    """Kto dodał pojazd; przy usunięciu firmy pojazd wraca do niego."""
    kind: Mapped[str] = mapped_column(String(20), default=VehicleKind.COMBINATION)
    tank_volume_m3: Mapped[float | None]
    """Pojemność cysterny (zabudowa ``tanker``)."""
    seats: Mapped[int | None]
    """Autobus: miejsca siedzące (bez kierowcy)."""
    standing_places: Mapped[int | None]
    vin: Mapped[str | None] = mapped_column(String(17))
    production_year: Mapped[int | None]
    emission_class: Mapped[str | None] = mapped_column(String(10))
    co2_class: Mapped[int | None]
    """Klasa emisji CO₂ (1–5) – myto w Niemczech (Toll Collect) od 12.2023."""
    fuel_type: Mapped[str | None] = mapped_column(String(10))
    consumption_empty: Mapped[float | None]
    consumption_loaded: Mapped[float | None]
    """Spalanie na 100 km bez ładunku i z pełnym ładunkiem (jednostka według napędu)."""
    adblue_percent: Mapped[float | None]
    fuel_price: Mapped[float | None]
    adblue_price: Mapped[float | None]
    """Własne ceny (w walucie stawek); brak = ceny z modułu kosztów (M4)."""
    pallet_places: Mapped[int | None]
    last_inspection: Mapped[date | None]
    """Ostatni przegląd techniczny."""
    inspection_until: Mapped[date | None]
    tachograph_until: Mapped[date | None]
    """Legalizacja (sprawdzenie okresowe) tachografu ważna do."""
    insurance_until: Mapped[date | None]
    ac_until: Mapped[date | None]
    """Autocasco ważne do."""
    ocp_until: Mapped[date | None]
    """OC przewoźnika (OCP) ważne do – pojazdy z silnikiem."""
    udt_until: Mapped[date | None]
    """Dozór UDT urządzeń (HDS, winda załadowcza) ważny do."""
    odometer_km: Mapped[int | None]
    """Ostatni wpisany stan licznika."""
    service_due_km: Mapped[int | None]
    """Następny serwis przy tym stanie licznika."""
    reminders_sent: Mapped[dict | None] = mapped_column(JSON)
    """Terminy już przypomniane w skrzynce: pole → data albo przebieg serwisu."""
    tdt_until: Mapped[date | None]
    """Badanie zbiornika cysterny (TDT / UDT) ważne do."""
    adr_until: Mapped[date | None]
    """Świadectwo dopuszczenia pojazdu do przewozu ADR ważne do."""
    atp_until: Mapped[date | None]
    """Świadectwo ATP chłodni (przewóz żywności) ważne do."""
    tachograph_download_until: Mapped[date | None]
    """Pobranie danych z tachografu pojazdu – co najmniej co 90 dni."""
    leasing_until: Mapped[date | None]
    trailer_id: Mapped[str | None] = mapped_column(String(36))
    """Podpięta naczepa (do ciągnika) albo przyczepa (do samochodu, autobusu, dostawczego)."""
    in_repair: Mapped[bool] = mapped_column(default=False, server_default="false")
    """W naprawie (moduł Serwis) – niedostępny do jazdy."""
    repair_reported: Mapped[bool] = mapped_column(default=False, server_default="false")
    """Zgłoszona usterka (moduł Serwis), pojazd jeszcze jeździ – do zamknięcia zlecenia."""
    in_use_by: Mapped[str | None] = mapped_column(String(255))
    assigned_driver: Mapped[str | None] = mapped_column(String(255))
    assigned_driver_label: Mapped[str | None] = mapped_column(String(200))
    """Nazwa kierowcy z kartoteki (moduł Kierowcy) – także kierowcy bez konta."""
    """Kierowca przydzielony do pojazdu firmy (konto członka firmy)."""
    fifth_wheel_m: Mapped[float | None]
    """Ciągnik: siodło od przodu ciągnika (z dokumentów)."""
    kingpin_m: Mapped[float | None]
    """Naczepa: sworzeń od przodu naczepy."""
    axles_m: Mapped[float | None]
    """Naczepa / przyczepa: środek zespołu osi od przodu."""
    wheelbase_m: Mapped[float | None]
    """Pojazd z silnikiem: rozstaw osi – od osi przedniej do środka osi tylnych."""
    in_use_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    """Kierowca jedzie nim (nawigacja) – do zwolnienia albo do tej chwili."""
    company_id: Mapped[str | None] = mapped_column(
        ForeignKey("companies.id", ondelete="SET NULL"), index=True
    )
    base_id: Mapped[str | None] = mapped_column(
        ForeignKey("company_bases.id", ondelete="SET NULL"), index=True
    )
    """Baza operacyjna firmy, do której należy pojazd."""
    name: Mapped[str] = mapped_column(String(100))
    plate: Mapped[str | None] = mapped_column(String(15))
    height_m: Mapped[float]
    width_m: Mapped[float]
    length_m: Mapped[float]
    weight_t: Mapped[float]
    gvw_t: Mapped[float]
    tare_t: Mapped[float | None]
    """Masa własna (pusty pojazd); ładowność = DMC − masa własna."""
    axle_load_t: Mapped[float]
    axle_count: Mapped[int]
    trailer_type: Mapped[str] = mapped_column(String(20))
    hazmat: Mapped[bool] = mapped_column(default=False)
    cost_per_km: Mapped[float | None]
    cost_per_hour: Mapped[float | None]
    cost_currency: Mapped[str] = mapped_column(String(3), default="EUR")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class VehicleIn(BaseModel):
    """Parametry pojazdu. Zakresy obejmują zestawy nienormatywne, ale odrzucają oczywiste błędy."""

    name: str = Field(min_length=1, max_length=100, examples=["Zestaw 40 t"])
    kind: VehicleKind = VehicleKind.COMBINATION
    height_m: float = Field(ge=1.5, le=6.0, description="Wysokość całkowita [m]", examples=[4.0])
    width_m: float = Field(ge=1.5, le=4.5, description="Szerokość [m]", examples=[2.55])
    length_m: float = Field(ge=3.0, le=40.0, description="Długość całkowita [m]", examples=[16.5])
    weight_t: float | None = Field(
        default=None,
        ge=1.0,
        le=150.0,
        description="Masa rzeczywista [t]; brak = równa DMC (formularz w aplikacji jej nie pyta)",
        examples=[40],
    )
    gvw_t: float | None = Field(
        default=None,
        ge=1.0,
        le=150.0,
        description="Dopuszczalna masa całkowita – DMC [t]; brak = równa masie rzeczywistej",
        examples=[40],
    )
    tare_t: float | None = Field(
        default=None, ge=0.3, le=150.0, description="Masa własna – pusty pojazd [t]", examples=[7.5]
    )
    axle_load_t: float = Field(
        ge=1.0, le=20.0, description="Największy nacisk osi [t]", examples=[11.5]
    )
    axle_count: int = Field(ge=1, le=20, examples=[5])
    trailer_type: TrailerType = TrailerType.CURTAIN
    hazmat: bool = Field(default=False, description="Przewóz towarów niebezpiecznych (ADR)")
    tank_volume_m3: float | None = Field(
        default=None, gt=0, le=100, description="Pojemność cysterny [m³]", examples=[32]
    )
    seats: int | None = Field(
        default=None, ge=1, le=120, description="Autobus: miejsca siedzące (bez kierowcy)"
    )
    standing_places: int | None = Field(
        default=None, ge=0, le=200, description="Autobus: miejsca stojące"
    )

    @model_validator(mode="after")
    def gvw_not_below_weight(self) -> "VehicleIn":
        if self.kind in DRIVABLE and self.axle_count < 2:
            raise ValueError(t("error.vehicle_axles"))
        if self.trailer_type != TrailerType.TANKER:
            self.tank_volume_m3 = None
        if self.kind != VehicleKind.BUS:
            self.seats = self.standing_places = None
        elif self.seats is None:
            raise ValueError(t("error.bus_seats"))
        if self.gvw_t is None and self.weight_t is None:
            raise ValueError(t("error.vehicle_gvw_required"))
        if self.weight_t is None:
            self.weight_t = self.gvw_t
        if self.tare_t is not None and self.tare_t > (self.gvw_t or self.weight_t):
            raise ValueError(t("error.tare_above_gvw"))
        if self.gvw_t is None:
            self.gvw_t = self.weight_t
        elif self.weight_t > self.gvw_t:
            raise ValueError(t("error.weight_above_gvw"))
        return self

    @property
    def is_hgv(self) -> bool:
        """Samochód ciężarowy w rozumieniu znaków i OSM (hgv): DMC powyżej 3,5 t."""
        return (self.gvw_t or self.weight_t) > HGV_MIN_GVW_T


class ServiceDates(BaseModel):
    """Terminy przeglądów i badań – zmieniają je też mechanicy firmy."""

    last_inspection: date | None = Field(default=None, description="Ostatni przegląd techniczny")
    inspection_until: date | None = Field(default=None, description="Przegląd techniczny ważny do")
    tachograph_until: date | None = Field(default=None, description="Legalizacja tachografu do")
    insurance_until: date | None = Field(default=None, description="Ubezpieczenie OC ważne do")
    ac_until: date | None = Field(default=None, description="Autocasco ważne do")
    ocp_until: date | None = Field(default=None, description="OC przewoźnika (OCP) ważne do")
    udt_until: date | None = Field(default=None, description="Dozór UDT (HDS, winda) ważny do")
    odometer_km: int | None = Field(
        default=None, ge=0, le=10_000_000, description="Stan licznika (pojazdy z silnikiem)"
    )
    service_due_km: int | None = Field(
        default=None, ge=0, le=10_000_000, description="Następny serwis przy stanie licznika"
    )
    tdt_until: date | None = Field(default=None, description="Badanie TDT / UDT cysterny do")
    adr_until: date | None = Field(default=None, description="Świadectwo ADR pojazdu do")
    atp_until: date | None = Field(default=None, description="Świadectwo ATP chłodni do")
    tachograph_download_until: date | None = Field(
        default=None, description="Najbliższe pobranie danych z tachografu (co 90 dni)"
    )
    leasing_until: date | None = Field(default=None, description="Koniec umowy leasingu")


class VehicleData(VehicleIn, ServiceDates, CostRates):
    company_id: str | None = Field(
        default=None, description="Firma, do której należy pojazd; brak = pojazd prywatny"
    )
    base_id: str | None = Field(default=None, description="Baza operacyjna tej samej firmy")
    plate: str | None = Field(
        default=None, max_length=15, description="Tablica rejestracyjna", examples=["KTA 12345"]
    )

    vin: str | None = Field(default=None, max_length=17, description="Numer VIN")
    production_year: int | None = Field(default=None, ge=1950, le=2100)
    emission_class: EmissionClass | None = Field(
        default=None, description="Klasa emisji spalin (pojazdy z silnikiem)"
    )
    pallet_places: int | None = Field(
        default=None, ge=1, le=80, description="Miejsca paletowe (EUR) w zabudowie"
    )
    co2_class: int | None = Field(
        default=None, ge=1, le=5, description="Klasa emisji CO₂ (myto w Niemczech)"
    )
    fuel_type: FuelType | None = Field(default=None, description="Napęd (pojazdy z silnikiem)")
    consumption_empty: float | None = Field(
        default=None, gt=0, le=500, description="Spalanie bez ładunku na 100 km (l, kg albo kWh)"
    )
    consumption_loaded: float | None = Field(
        default=None, gt=0, le=500, description="Spalanie z pełnym ładunkiem na 100 km"
    )
    adblue_percent: float | None = Field(
        default=None, ge=0, le=15, description="AdBlue jako % spalania ON"
    )
    fuel_price: float | None = Field(
        default=None, gt=0, le=1000, description="Własna cena paliwa za jednostkę (waluta stawek)"
    )
    adblue_price: float | None = Field(
        default=None, gt=0, le=1000, description="Własna cena AdBlue za litr (waluta stawek)"
    )
    fifth_wheel_m: float | None = Field(
        default=None, gt=0, le=6, description="Ciągnik: siodło od przodu ciągnika [m]"
    )
    kingpin_m: float | None = Field(
        default=None, gt=0, le=4, description="Naczepa: sworzeń od przodu naczepy [m]"
    )
    axles_m: float | None = Field(
        default=None, gt=0, le=20, description="Naczepa / przyczepa: środek osi od przodu [m]"
    )
    wheelbase_m: float | None = Field(
        default=None, gt=0, le=10, description="Rozstaw osi: przednia – środek tylnych [m]"
    )

    @field_validator("plate")
    @classmethod
    def _plate(cls, value: str | None) -> str | None:
        """Wielkie litery i pojedyncze spacje, jak na tablicy; pusta = brak."""
        return " ".join((value or "").upper().split()) or None

    @field_validator("vin", mode="before")
    @classmethod
    def _vin(cls, value: str | None) -> str | None:
        """Wielkie litery, bez spacji (VIN przepisany z dowodu bywa z odstępami)."""
        return "".join((value or "").upper().split()) or None

    @model_validator(mode="after")
    def _only_what_the_kind_has(self) -> "VehicleData":
        """Każdy rodzaj ma swoje cechy: pola, które go nie dotyczą, nie są zapisywane."""
        motor = self.kind not in TOWED
        if self.kind not in BODY_KINDS:
            self.trailer_type = TrailerType.NONE
        if self.kind not in BODY_KINDS or self.trailer_type == TrailerType.TANKER:
            self.pallet_places = None
        if not motor:
            self.emission_class = self.co2_class = self.fuel_type = None
            self.consumption_empty = self.consumption_loaded = None
            self.adblue_percent = self.fuel_price = self.adblue_price = None
            self.cost_per_km = self.cost_per_hour = None
            self.ocp_until = self.odometer_km = self.service_due_km = None
        if self.fuel_type not in (None, FuelType.DIESEL):
            self.adblue_percent = self.adblue_price = None
        if (
            self.consumption_empty is not None
            and self.consumption_loaded is not None
            and self.consumption_loaded < self.consumption_empty
        ):
            raise ValueError(t("error.consumption_loaded_below_empty"))
        if self.kind not in TACHOGRAPH_KINDS:
            self.tachograph_until = self.tachograph_download_until = None
        if self.trailer_type != TrailerType.REEFER:
            self.atp_until = None
        if self.kind != VehicleKind.TRACTOR:
            self.fifth_wheel_m = None
        if self.kind != VehicleKind.SEMITRAILER:
            self.kingpin_m = None
        if self.kind not in TOWED:
            self.axles_m = None
        if not motor:
            self.wheelbase_m = None
        if self.kingpin_m and self.axles_m and self.axles_m <= self.kingpin_m:
            raise ValueError(t("error.axles_before_kingpin"))
        if self.axles_m and self.axles_m > self.length_m:
            raise ValueError(t("error.axles_beyond_length"))
        if self.trailer_type != TrailerType.TANKER:
            self.tdt_until = None
        if not self.hazmat:
            self.adr_until = None
        return self


class VehicleOut(VehicleData):
    model_config = ConfigDict(from_attributes=True)

    id: str
    can_edit: bool = True
    """Czy zalogowany użytkownik może zmienić lub usunąć pojazd."""
    can_service: bool = True
    """Czy może zmienić terminy przeglądów (także mechanik firmy)."""
    trailer_id: str | None = None
    trailer_name: str | None = None
    base_name: str | None = None
    """Nazwa bazy operacyjnej pojazdu."""
    coupled_to_id: str | None = None
    """Naczepa / przyczepa: do którego pojazdu jest podpięta."""
    coupled_to_name: str | None = None
    in_use: bool = False
    driver_name: str | None = None
    """Kto teraz jedzie pojazdem (nawigacja)."""
    assigned_member_id: str | None = None
    """Przydzielony kierowca – członek firmy (id członka, nie konto)."""
    assigned_driver_name: str | None = None
    assigned_to_me: bool = False
    """Pojazd przydzielony zalogowanemu – planer wybiera go domyślnie."""
    in_repair: bool = False
    repair_reported: bool = False
    """Pojazd: kierowca nim jedzie; naczepa / przyczepa: jest podpięta albo jej pojazd jedzie."""


class RegistrationIn(BaseModel):
    """Dowód rejestracyjny: tekst kodu Aztec (PL), zdjęcie (Base64) albo tekst dowodu (UE)."""

    code: str | None = Field(default=None, max_length=20_000)
    text: str | None = Field(
        default=None, max_length=20_000, description="Tekst rozpoznany ze zdjęcia dowodu"
    )
    image: str | None = Field(default=None, max_length=15_000_000)


class DriverIn(BaseModel):
    member_id: str | None = Field(description="Członek firmy; brak = bez przydziału")


class CouplingIn(BaseModel):
    trailer_id: str | None = Field(description="Naczepa / przyczepa do podpięcia; brak = odpięcie")


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/vehicles", tags=["vehicles"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.get("")
    def list_vehicles(user: User, db: Db) -> list[VehicleOut]:
        roles = company_ids(db, user)
        query = select(VehicleProfile).where(
            or_(
                (VehicleProfile.owner_subject == user.subject)
                & VehicleProfile.company_id.is_(None),
                VehicleProfile.company_id.in_(roles),
            )
        )
        return vehicle_outs(db, list(db.scalars(query.order_by(VehicleProfile.name))), roles, user)

    def check_private_limit(request: Request, db: Session, user: Principal) -> None:
        """Konto bez planu: jeden pojazd prywatny; kolejne po wykupieniu ``vehicles_plus``."""
        if request.app.state.licensing.is_granted(user, VEHICLES_PLUS):
            return
        private = db.scalar(
            select(func.count()).where(
                VehicleProfile.owner_subject == user.subject, VehicleProfile.company_id.is_(None)
            )
        )
        if private >= FREE_PRIVATE_VEHICLES:
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.vehicle_limit"))

    @router.post("", status_code=status.HTTP_201_CREATED)
    def create_vehicle(data: VehicleData, user: User, db: Db, request: Request) -> VehicleOut:
        roles = company_ids(db, user)
        _check_target(db, data, roles)
        if data.company_id is None:
            check_private_limit(request, db, user)
        vehicle = VehicleProfile(owner_subject=user.subject, **data.model_dump())
        db.add(vehicle)
        db.commit()
        return vehicle_outs(db, [vehicle], roles, user)[0]

    @router.post("/registration")
    def registration(data: RegistrationIn, user: User) -> dict:
        """Dane pojazdu z kodu Aztec dowodu rejestracyjnego – nic nie jest zapisywane."""
        try:
            if data.text:
                return vehicle_data_from_text(data.text)
            code = data.code
            if code and ("\n" in code.strip() or not code.strip().isascii()):
                # Wklejony tekst dowodu (kraj UE), nie kod Aztec.
                return vehicle_data_from_text(code)
            if not code and data.image:
                code = read_image(base64.b64decode(data.image.split(",")[-1]))
            if not code:
                raise RegistrationError(t("registration.no_code"))
            return vehicle_data(decode_text(code))
        except (RegistrationError, binascii.Error) as error:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error

    @router.get("/{vehicle_id}")
    def get_vehicle(vehicle_id: str, user: User, db: Db) -> VehicleOut:
        return vehicle_outs(db, [load_owned(db, vehicle_id, user)], company_ids(db, user), user)[0]

    @router.put("/{vehicle_id}")
    def update_vehicle(
        vehicle_id: str, data: VehicleData, user: User, db: Db, request: Request
    ) -> VehicleOut:
        roles = company_ids(db, user)
        vehicle = load_owned(db, vehicle_id, user, edit=True)
        _check_target(db, data, roles)
        if data.company_id is None and vehicle.company_id is not None:
            check_private_limit(request, db, user)
        for field, value in data.model_dump().items():
            setattr(vehicle, field, value)
        _drop_broken_couplings(db, vehicle)
        db.commit()
        return vehicle_outs(db, [vehicle], roles, user)[0]

    @router.put("/{vehicle_id}/driver")
    def assign_driver(
        vehicle_id: str, data: DriverIn, user: User, db: Db, request: Request
    ) -> VehicleOut:
        """Przydział kierowcy do pojazdu firmy (właściciel i dyspozytorzy)."""
        roles = company_ids(db, user)
        vehicle = load_owned(db, vehicle_id, user, edit=True)
        if vehicle.company_id is None or VehicleKind(vehicle.kind) not in DRIVABLE:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("error.driver_not_here"))
        member = db.get(CompanyMember, data.member_id) if data.member_id else None
        if data.member_id and (member is None or member.company_id != vehicle.company_id):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("error.member_not_found"))
        subject = member.subject if member else None
        if subject != vehicle.assigned_driver:
            for handler in request.app.state.modules.driver_handlers:
                handler(db, vehicle.id, subject, user)
        vehicle.assigned_driver = subject
        vehicle.assigned_driver_label = None
        db.commit()
        return vehicle_outs(db, [vehicle], roles, user)[0]

    @router.put("/{vehicle_id}/trailer")
    def couple(vehicle_id: str, data: CouplingIn, user: User, db: Db) -> VehicleOut:
        """Podpięcie naczepy / przyczepy albo odpięcie (może to zrobić także kierowca)."""
        roles = company_ids(db, user)
        vehicle = load_owned(db, vehicle_id, user)
        if data.trailer_id is not None:
            trailer = load_owned(db, data.trailer_id, user)
            if COUPLES.get(VehicleKind(vehicle.kind)) != trailer.kind:
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_CONTENT, t("error.vehicle_coupling_kind")
                )
            holder = db.scalar(
                select(VehicleProfile).where(
                    VehicleProfile.trailer_id == trailer.id, VehicleProfile.id != vehicle.id
                )
            )
            if holder is not None:
                raise HTTPException(
                    status.HTTP_409_CONFLICT, t("error.trailer_in_use", vehicle=holder.name)
                )
        vehicle.trailer_id = data.trailer_id
        db.commit()
        return vehicle_outs(db, [vehicle], roles, user)[0]

    @router.put("/{vehicle_id}/service")
    def service(vehicle_id: str, data: ServiceDates, user: User, db: Db) -> VehicleOut:
        """Terminy przeglądów i badań – właściciel, dyspozytor albo mechanik firmy."""
        roles = company_ids(db, user)
        vehicle = load_owned(db, vehicle_id, user)
        if not _can_service(vehicle, roles, user):
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.vehicles_service_forbidden"))
        current = VehicleData.model_validate(vehicle, from_attributes=True)
        # Pola, których klient nie wysłał (np. starsza wersja aplikacji), zostają bez zmian.
        sent = data.model_dump(exclude_unset=True)
        cleaned = VehicleData.model_validate(current.model_dump() | sent)
        for field in ServiceDates.model_fields:
            setattr(vehicle, field, getattr(cleaned, field))
        db.commit()
        return vehicle_outs(db, [vehicle], roles, user)[0]

    @router.post("/{vehicle_id}/release")
    def release(vehicle_id: str, user: User, db: Db) -> VehicleOut:
        """Koniec jazdy: pojazd przestaje być „w użyciu”."""
        roles = company_ids(db, user)
        vehicle = load_owned(db, vehicle_id, user)
        if vehicle.in_use_by not in (None, user.subject) and not _can_edit(vehicle, roles, user):
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.vehicles_edit_forbidden"))
        vehicle.in_use_by = vehicle.in_use_until = None
        db.commit()
        return vehicle_outs(db, [vehicle], roles, user)[0]

    @router.delete("/{vehicle_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_vehicle(vehicle_id: str, user: User, db: Db) -> Response:
        vehicle = load_owned(db, vehicle_id, user, edit=True)
        for holder in db.scalars(
            select(VehicleProfile).where(VehicleProfile.trailer_id == vehicle.id)
        ):
            holder.trailer_id = None
        db.delete(vehicle)
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router


def _drop_broken_couplings(db: Session, vehicle: VehicleProfile) -> None:
    """Po zmianie rodzaju połączenie, które przestało pasować, zostaje rozpięte."""
    if vehicle.trailer_id is not None:
        trailer = db.get(VehicleProfile, vehicle.trailer_id)
        if trailer is None or COUPLES.get(VehicleKind(vehicle.kind)) != trailer.kind:
            vehicle.trailer_id = None
    for holder in db.scalars(select(VehicleProfile).where(VehicleProfile.trailer_id == vehicle.id)):
        if COUPLES.get(VehicleKind(holder.kind)) != vehicle.kind:
            holder.trailer_id = None


def _aware(moment: datetime | None) -> datetime | None:
    # SQLite (testy) zwraca daty bez strefy czasowej.
    return moment if moment is None or moment.tzinfo else moment.replace(tzinfo=UTC)


def _driven(vehicle: VehicleProfile) -> bool:
    until = _aware(vehicle.in_use_until)
    return until is not None and until > _now()


def mark_in_use(vehicle: VehicleProfile, user: Principal) -> None:
    """Start nawigacji: pojazd „w użyciu” do zwolnienia albo przez ``IN_USE_HOURS``."""
    vehicle.in_use_by = user.subject
    vehicle.in_use_until = _now() + timedelta(hours=IN_USE_HOURS)


def load_drivable(db: Session, vehicle_id: str, user: Principal) -> VehicleProfile:
    """Pojazd do wyznaczenia trasy – naczepa ani przyczepa sama nie jedzie.

    Z podpiętą naczepą / przyczepą zwraca profil całego zestawu (nowy obiekt, nie w bazie):
    największa wysokość i szerokość, suma długości (ciągnik z naczepą – minus część pod naczepą),
    suma mas i osi, największy nacisk osi, zabudowa i ADR z naczepy, stawki z pojazdu.
    """
    vehicle = load_owned(db, vehicle_id, user)
    if VehicleKind(vehicle.kind) not in DRIVABLE:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("error.vehicle_not_drivable"))
    trailer = db.get(VehicleProfile, vehicle.trailer_id) if vehicle.trailer_id else None
    if trailer is None:
        return vehicle
    columns = {c.key: getattr(vehicle, c.key) for c in VehicleProfile.__table__.columns}
    return VehicleProfile(
        **columns
        | {
            "height_m": max(vehicle.height_m, trailer.height_m),
            "width_m": max(vehicle.width_m, trailer.width_m),
            "length_m": combination_length(vehicle, trailer),
            "weight_t": vehicle.weight_t + trailer.weight_t,
            "gvw_t": vehicle.gvw_t + trailer.gvw_t,
            "axle_load_t": max(vehicle.axle_load_t, trailer.axle_load_t),
            "axle_count": vehicle.axle_count + trailer.axle_count,
            "trailer_type": trailer.trailer_type,
            "hazmat": vehicle.hazmat or trailer.hazmat,
            "tank_volume_m3": trailer.tank_volume_m3,
            "kind": VehicleKind.COMBINATION,
            "pallet_places": trailer.pallet_places,
        }
    )


def combination_length(vehicle: VehicleProfile, trailer: VehicleProfile) -> float:
    """Długość zestawu: z dokumentów (siodło ciągnika i sworzeń naczepy), inaczej typowa
    część naczepy nad ciągnikiem; przyczepa – suma długości (dyszel w długości przyczepy)."""
    if trailer.kind != VehicleKind.SEMITRAILER:
        return vehicle.length_m + trailer.length_m
    if vehicle.fifth_wheel_m and trailer.kingpin_m:
        exact = vehicle.fifth_wheel_m + trailer.length_m - trailer.kingpin_m
        return round(max(vehicle.length_m, exact), 2)
    return max(vehicle.length_m, vehicle.length_m + trailer.length_m - KINGPIN_OVERLAP_M)


def person_names(db: Session, subjects: set[str], company_id: str | None = None) -> dict[str, str]:
    """Imiona do pokazania: z firmy, inaczej z ustawień konta, inaczej końcówka konta."""
    subjects = {s for s in subjects if s}
    if not subjects:
        return {}
    names: dict[str, str] = {}
    if company_id:
        members = select(CompanyMember).where(
            CompanyMember.company_id == company_id, CompanyMember.subject.in_(subjects)
        )
        names |= {m.subject: m.display_name for m in db.scalars(members)}
    missing = subjects - names.keys()
    if missing:
        settings = select(UserSettings).where(UserSettings.subject.in_(missing))
        names |= {s.subject: s.display_name for s in db.scalars(settings) if s.display_name}
    return names | {s: t("account.user_fallback", id=s[-6:]) for s in subjects - names.keys()}


def _can_service(vehicle: VehicleProfile, roles: dict, user: Principal) -> bool:
    if vehicle.company_id is None:
        return vehicle.owner_subject == user.subject
    return roles.get(vehicle.company_id) in SERVICES_VEHICLES


def _can_edit(vehicle: VehicleProfile, roles: dict, user: Principal) -> bool:
    if vehicle.company_id is None:
        return vehicle.owner_subject == user.subject
    return roles.get(vehicle.company_id) in MANAGES_VEHICLES


def _check_target(db: Session, data: "VehicleData", roles: dict) -> None:
    """Pojazd można zapisać w firmie tylko jako jej właściciel albo dyspozytor
    i tylko taki, jaki ma firma tego rodzaju (spedycja – żadnych, autobusy – transport osób)."""
    company_id = data.company_id
    if data.base_id is not None:
        base = db.get(CompanyBase, data.base_id)
        if base is None or base.company_id != company_id:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("error.base_not_found"))
    if company_id is None:
        return
    if company_id not in roles:
        raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.company_not_found"))
    if roles[company_id] not in MANAGES_VEHICLES:
        raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.vehicles_add_forbidden"))
    kind = CompanyKind(db.get(Company, company_id).kind)
    if data.kind not in COMPANY_VEHICLES[kind]:
        key = (
            "error.forwarder_no_fleet"
            if kind == CompanyKind.FORWARDER
            else "error.company_vehicle_kind"
        )
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t(key))


def vehicle_outs(
    db: Session, vehicles: list[VehicleProfile], roles: dict, user: Principal
) -> list[VehicleOut]:
    """Pojazdy z prawem do zmiany, połączeniami i stanem „w użyciu”."""
    ids = [v.id for v in vehicles]
    trailer_ids = [v.trailer_id for v in vehicles if v.trailer_id]
    holders = {
        h.trailer_id: h
        for h in db.scalars(select(VehicleProfile).where(VehicleProfile.trailer_id.in_(ids)))
    }
    trailers = {
        t.id: t
        for t in db.scalars(select(VehicleProfile).where(VehicleProfile.id.in_(trailer_ids)))
    }
    base_ids = {v.base_id for v in vehicles if v.base_id}
    bases = {
        b.id: b.name for b in db.scalars(select(CompanyBase).where(CompanyBase.id.in_(base_ids)))
    }
    names: dict[tuple[str | None, str], str] = {}
    assigned = {(v.company_id, v.assigned_driver) for v in vehicles if v.assigned_driver}
    members: dict[tuple[str | None, str], str] = {}
    if assigned:
        query = select(CompanyMember).where(
            CompanyMember.subject.in_({s for _, s in assigned}),
            CompanyMember.company_id.in_({c for c, _ in assigned}),
        )
        members = {(m.company_id, m.subject): m.id for m in db.scalars(query)}
    for company_id in {v.company_id for v in vehicles}:
        people = {
            s for v in vehicles if v.company_id == company_id
            for s in (v.assigned_driver, v.in_use_by if _driven(v) else None) if s
        }  # fmt: skip
        names |= {(company_id, s): n for s, n in person_names(db, people, company_id).items()}
    outs = []
    for v in vehicles:
        holder, trailer = holders.get(v.id), trailers.get(v.trailer_id)
        out = VehicleOut.model_validate(v)
        driving = v.in_use_by if _driven(v) else None
        outs.append(
            out.model_copy(
                update={
                    "can_edit": _can_edit(v, roles, user),
                    "can_service": _can_service(v, roles, user),
                    "trailer_name": trailer.name if trailer else None,
                    "base_name": bases.get(v.base_id) if v.base_id else None,
                    "coupled_to_id": holder.id if holder else None,
                    "coupled_to_name": holder.name if holder else None,
                    "in_use": _driven(v) or holder is not None,
                    "driver_name": names.get((v.company_id, driving)) if driving else None,
                    "assigned_member_id": members.get((v.company_id, v.assigned_driver)),
                    "assigned_driver_name": names.get((v.company_id, v.assigned_driver))
                    or v.assigned_driver_label
                    if v.assigned_driver
                    else v.assigned_driver_label,
                    "assigned_to_me": v.assigned_driver is not None
                    and v.assigned_driver == user.subject,
                }
            )
        )
    return outs


def load_owned(
    db: Session, vehicle_id: str, user: Principal, *, edit: bool = False
) -> VehicleProfile:
    """Pojazd prywatny użytkownika albo pojazd jego firmy; obcy wygląda jak nieistniejący (404).

    ``edit=True`` wymaga prawa do zmiany: kierowca firmy jeździ jej pojazdami, ale ich nie zmienia.
    """
    vehicle = db.get(VehicleProfile, vehicle_id)
    roles = company_ids(db, user)
    visible = vehicle is not None and (
        vehicle.company_id in roles
        or (vehicle.company_id is None and vehicle.owner_subject == user.subject)
    )
    if not visible:
        raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.vehicle_not_found"))
    if edit and not _can_edit(vehicle, roles, user):
        raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.vehicles_edit_forbidden"))
    return vehicle

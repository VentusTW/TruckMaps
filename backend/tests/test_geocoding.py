import httpx
import pytest
from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.geocoding import GeocodingUnavailable, PhotonGeocoder, Place, format_label
from truckmaps.sdk import Principal

OSK = {
    "type": "Feature",
    "geometry": {"type": "Point", "coordinates": [20.9135, 50.0286]},
    "properties": {
        "name": "OSK MIŚ",
        "street": "Chemiczna",
        "housenumber": "5",
        "postcode": "33-101",
        "city": "Tarnów",
        "osm_value": "driving_school",
        "type": "house",
    },
}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if token != "user-anna":
            raise InvalidToken(token)
        return Principal(subject="anna")


class FakeGeocoder:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.calls: list[tuple] = []

    def search(self, query, limit=5, near=None):
        if self.error:
            raise self.error
        self.calls.append((query, limit, near))
        return [Place(label="OSK MIŚ, Chemiczna 5, 33-101 Tarnów", lat=50.0286, lon=20.9135)]

    def reverse(self, lat, lon):
        return Place(label="Chemiczna 5, 33-101 Tarnów", lat=lat, lon=lon)


def client_with(geocoder) -> TestClient:
    app = create_app(Settings(), modules=[], token_verifier=FakeVerifier(), geocoder=geocoder)
    return TestClient(app)


AUTH = {"Authorization": "Bearer user-anna"}


@pytest.mark.parametrize(
    ("props", "label"),
    [
        (OSK["properties"], "OSK MIŚ, Chemiczna 5, 33-101 Tarnów"),
        ({"street": "Tuchowska", "housenumber": "12", "city": "Tarnów"}, "Tuchowska 12, Tarnów"),
        ({"name": "Tuchowska", "street": "Tuchowska", "city": "Tarnów"}, "Tuchowska, Tarnów"),
        ({"name": "Tuchów", "city": "Tuchów", "state": "małopolskie"}, "Tuchów, małopolskie"),
    ],
)
def test_format_label(props, label):
    assert format_label(props) == label


def test_photon_geocoder_parses_features_and_passes_location():
    seen = {}

    def photon(request: httpx.Request) -> httpx.Response:
        seen.update(dict(request.url.params), path=request.url.path)
        return httpx.Response(200, json={"features": [OSK]})

    geocoder = PhotonGeocoder(
        "http://photon.test", http=httpx.Client(transport=httpx.MockTransport(photon))
    )
    (place,) = geocoder.search("osk miś tarnów", near=(50.0, 20.9))

    assert seen["path"] == "/api"
    assert (seen["q"], seen["lang"], seen["lat"], seen["lon"]) == (
        "osk miś tarnów",
        "pl",
        "50.0",
        "20.9",
    )
    assert place == Place(
        label="OSK MIŚ, Chemiczna 5, 33-101 Tarnów", lat=50.0286, lon=20.9135, kind="house"
    )


def test_photon_search_removes_duplicate_street_segments():
    street = {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [21.05, 49.89]},
        "properties": {"name": "Rynek", "street": "Rynek", "postcode": "33-170", "city": "Tuchów"},
    }

    def photon(request: httpx.Request) -> httpx.Response:
        assert request.url.params["limit"] == "6"
        return httpx.Response(200, json={"features": [street, street, OSK, street]})

    geocoder = PhotonGeocoder(
        "http://photon.test", http=httpx.Client(transport=httpx.MockTransport(photon))
    )

    labels = [p.label for p in geocoder.search("rynek", limit=2)]

    assert labels == ["Rynek, 33-170 Tuchów", "OSK MIŚ, Chemiczna 5, 33-101 Tarnów"]


def test_photon_unavailable_raises():
    def broken(request):
        raise httpx.ConnectError("refused")

    geocoder = PhotonGeocoder(
        "http://photon.test", http=httpx.Client(transport=httpx.MockTransport(broken))
    )
    with pytest.raises(GeocodingUnavailable):
        geocoder.reverse(50.0, 20.9)


def test_search_endpoint_requires_login_and_returns_places():
    geocoder = FakeGeocoder()
    with client_with(geocoder) as client:
        assert client.get("/api/geocode", params={"q": "osk"}).status_code == 401
        response = client.get(
            "/api/geocode", params={"q": "osk miś", "lat": 50.0, "lon": 20.9}, headers=AUTH
        )
        reverse = client.get(
            "/api/geocode/reverse", params={"lat": 50.0, "lon": 20.9}, headers=AUTH
        )

    assert response.json()[0]["label"] == "OSK MIŚ, Chemiczna 5, 33-101 Tarnów"
    assert geocoder.calls == [("osk miś", 6, (50.0, 20.9))]
    assert reverse.json()["label"] == "Chemiczna 5, 33-101 Tarnów"


def test_search_endpoint_reports_unavailable_geocoder():
    with client_with(FakeGeocoder(error=GeocodingUnavailable("down"))) as client:
        response = client.get("/api/geocode", params={"q": "osk"}, headers=AUTH)

    assert response.status_code == 503

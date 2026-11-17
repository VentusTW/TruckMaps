import pytest
from truckmaps_load.axles import TractorSetup, combination, rigid, split, status

# Typowa naczepa 13,6 m: sworzeń 1,6 m od ściany, środek osi 9,52 m, 7 t masy własnej.
KINGPIN, AXLES, TRAILER_TARE = 1.6, 9.52, 7_000


def semi(loads, **extra):
    return combination(loads, KINGPIN, AXLES, TRAILER_TARE, 24_000, **extra)


def loads_of(axles):
    return {a.id: a.load_kg for a in axles}


def test_moment_split_keeps_the_total():
    front, rear = split([(10_000, 2.0), (6_000, 8.0)], 1.0, 9.0)
    assert front + rear == pytest.approx(16_000)
    assert rear == pytest.approx((10_000 * 1 + 6_000 * 7) / 8)


def test_same_numbers_as_axle_plan_example():
    # Axle Plan, ustawienia domyślne: masy własne 5,8 / 3,7 / 5,2 t, a = 1,7 m, b = 7,7 m,
    # d = 3,1 m, e = 0,5 m; 20 t ładunku → 6,7 / 9,1 / 19,0 t, zespół 34,7 t, napędowa 26 %.
    tractor = TractorSetup(
        steer_to_kingpin_m=3.1, kingpin_to_drive_m=0.5, tare_kg=7_500,
        front_share=(5_800 - 2_000 * 0.5 / 3.6) / 7_500,
    )  # fmt: skip
    out = combination([(20_000, 7.0)], 1.7, 9.4, 7_200, 24_000, tractor, 2_000 / 7_200)
    assert [round(a.load_kg / 100) / 10 for a in out.axles] == [6.7, 9.1, 19.0]
    assert (out.gross_kg, round(out.drive_share * 100)) == (34_700, 26)
    assert [a.status for a in out.axles] == ["ok", "ok", "ok"] and out.problems == []
    assert [a.x_m for a in out.axles] == [-1.4, 2.2, 9.4]


def test_even_load_is_within_limits():
    out = semi([(700, 0.6 + 0.4 * i) for i in range(33)])  # 23,1 t na całej długości
    assert out.problems == [] and out.cog_m == pytest.approx(7.0, abs=0.01)
    assert all(a.status in ("ok", "warn") for a in out.axles)
    assert out.tractor_kg < 18_000 and out.gross_kg < 40_000


def test_load_at_the_front_overloads_the_drive_axle():
    out = semi([(24_000, 2.0)])
    assert "over_drive" in out.problems and "tractor" in out.problems
    drive = out.axles[1]
    assert drive.status == "over" and drive.ratio > 1


def test_load_at_the_back_lifts_the_tractor():
    out = semi([(12_000, 12.8)])
    assert "cargo_back" in out.problems and "drive_share" in out.problems
    assert loads_of(out.axles)["drive"] < out.axles[1].min_kg


def test_overload_of_trailer_axles_and_gross_weight():
    out = semi([(30_000, 9.0)])
    assert {"over_trailer", "gross"} <= set(out.problems)
    assert out.axles[2].status == "over"


def test_warning_colour_above_90_percent():
    assert (status(6_700, 7_500), status(6_800, 7_500), status(7_600, 7_500)) == (
        "ok",
        "warn",
        "over",
    )


def test_rigid_load_behind_rear_axle_unloads_the_steer_axle():
    # Solo: oś przednia 1,2 m przed skrzynią, tylna 4,0 m za jej początkiem, 10 t masy własnej.
    def truck(loads):
        return rigid(loads, -1.2, 4.0, 10_000, 7_500, 11_500, 18_000)

    even = truck([(6_000, 3.6)])
    assert even.problems == [] and [a.id for a in even.axles] == ["front", "rear"]
    back = truck([(6_000, 7.0)])
    assert {"steer_low", "cargo_back", "over_rear"} <= set(back.problems)
    front = truck([(8_500, 0.5)])
    assert "over_front" in front.problems and "gross" in front.problems

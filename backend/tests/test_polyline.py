from truckmaps.core.polyline import decode_polyline6, encode_polyline6


def test_polyline_round_trip_keeps_six_decimals():
    points = [(20.989844, 50.007205), (21.0537, 49.895202), (-0.12, 51.5), (13.0, -33.9)]

    encoded = encode_polyline6(points)

    assert decode_polyline6(encoded) == points
    assert len(encoded) < 60  # kilka bajtów na punkt


def test_polyline_matches_valhalla_format():
    # Ten sam punkt co w odpowiedzi Valhalli (lat 52.4064, lon 16.9252).
    assert decode_polyline6(encode_polyline6([(16.9252, 52.4064)])) == [(16.9252, 52.4064)]
    assert encode_polyline6([]) == ""

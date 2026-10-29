#!/usr/bin/env bash
# Budowa danych tras Valhalli etapami, z ponawianiem etapu, ktory padnie.
# Uruchamia go infra/build_routing.ps1 w kontenerze valhalla-scripted, z wolumenem w /custom_files
# zawierajacym region.osm.pbf.
#
# Dlaczego nie skrypt obrazu: przy mapie 5 krajow valhalla_build_tiles losowo pada w kodzie
# LuaJIT (segfault przy parsowaniu relacji, uszkodzony kafelek przy "enhance"); ten sam plik
# raz przechodzi, raz nie. Skrypt obrazu zaczyna wtedy cala godzine od nowa - tu powtarzamy
# tylko etap, ktory padl.
set -u
cd /custom_files
CONFIG=valhalla.json
PBF=region.osm.pbf
TRIES=3

# Mapa z /out (katalog Windows) do wolumenu; inna mapa niz ostatnio = czysty wolumen.
if [[ "$(stat -c %s "$PBF" 2>/dev/null)" != "$(stat -c %s /out/$PBF)" ]]; then
    echo "== kopiowanie mapy do wolumenu"
    rm -rf /custom_files/*
    cp /out/$PBF . || exit 1
fi

valhalla_build_config \
    --mjolnir-tile-dir /custom_files/valhalla_tiles \
    --mjolnir-tile-extract /custom_files/valhalla_tiles.tar \
    --mjolnir-admin /custom_files/admins.sqlite \
    --mjolnir-timezone /custom_files/timezones.sqlite \
    --mjolnir-concurrency "$(nproc)" > "$CONFIG" || exit 1

if [[ ! -s admins.sqlite ]]; then
    echo "== granice administracyjne"
    valhalla_build_admins --config "$CONFIG" "$PBF" || exit 1
fi
if [[ ! -s timezones.sqlite ]]; then
    echo "== strefy czasowe"
    valhalla_build_timezones > timezones.sqlite || exit 1
fi

# Etapy w grupach: kazda grupa zaczyna od danych zapisanych przez poprzednia, wiec da sie ja
# powtorzyc. "build".."cleanup" razem: "enhance" zmienia kafelki w miejscu, wiec po bledzie
# trzeba je zbudowac od nowa.
stages() {
    local start=$1 end=$2
    for attempt in $(seq 1 $TRIES); do
        echo "== etapy ${start}..${end} (proba ${attempt}/${TRIES}) $(date +%H:%M)"
        if valhalla_build_tiles -c "$CONFIG" -s "$start" -e "$end" "$PBF"; then
            return 0
        fi
        echo "== etapy ${start}..${end} nie powiodly sie"
    done
    exit 1
}

stages initialize parseways
stages parserelations parserelations
stages parseareaways parseareaways
stages parsenodes parsenodes
stages buildareas constructedges
stages build cleanup

echo "== archiwum kafelkow $(date +%H:%M)"
valhalla_build_extract -c "$CONFIG" -v --overwrite || exit 1
rm -rf valhalla_tiles
# Do serwera tras wystarcza archiwum kafelkow, konfiguracja i bazy granic / stref czasowych.
echo "== kopiowanie wyniku $(date +%H:%M)"
cp valhalla_tiles.tar "$CONFIG" admins.sqlite timezones.sqlite /out/ || exit 1
echo "== gotowe $(date +%H:%M)"

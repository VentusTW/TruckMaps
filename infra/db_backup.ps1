# Kopia i przywracanie tabel z danymi z OSM (ograniczenia, parkingi) w schemacie "kopia".
# Dolaczany przez infra\update_data.ps1 i infra\rollback.ps1 (". infra\db_backup.ps1").
# Schemat osobny od "public", zeby alembic nie traktowal kopii jak tabel do usuniecia.

$BackupTables = @("road_restrictions", "truck_parkings")

function Invoke-Sql([string]$Sql) {
    $result = "SET client_min_messages = warning; $Sql" |
        docker exec -i truckmaps-postgis-1 psql -U truckmaps -d truckmaps -v ON_ERROR_STOP=1 -q -t -A
    if ($LASTEXITCODE -ne 0) { throw "Blad SQL" }
    return $result
}

function Count-Rows([string]$Table) {
    return [int](Invoke-Sql "SELECT count(*) FROM public.$Table;")
}

function Backup-Tables {
    # Zwraca liczby wpisow przed aktualizacja.
    $counts = @{}
    foreach ($table in $BackupTables) {
        Invoke-Sql "CREATE SCHEMA IF NOT EXISTS kopia; DROP TABLE IF EXISTS kopia.$table; CREATE TABLE kopia.$table AS TABLE public.$table;" | Out-Null
        $counts[$table] = Count-Rows $table
    }
    return $counts
}

function Restore-Tables {
    # Zamiana: kopia -> public, a dotychczasowe dane -> kopia (mozna wrocic ponownie).
    foreach ($table in $BackupTables) {
        Invoke-Sql @"
BEGIN;
CREATE TEMP TABLE swap AS TABLE public.$table;
TRUNCATE public.$table;
INSERT INTO public.$table SELECT * FROM kopia.$table;
TRUNCATE kopia.$table;
INSERT INTO kopia.$table SELECT * FROM swap;
COMMIT;
"@ | Out-Null
        Write-Host "   ${table}: przywrocono ($(Count-Rows $table) wpisow)"
    }
}

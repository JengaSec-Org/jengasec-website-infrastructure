<#
  Export the website database from Neon — run at HOME (or anywhere off campus).

  The campus network blocks outgoing PostgreSQL (port 5432), so the export has
  to happen on a network that allows it: home Wi-Fi or a phone hotspot.

  What it makes, in the folder you run it from (or -OutDir):
    jengasec-neon-<date>.sql       the whole database: tables, data, sequences
    jengasec-neon-<date>.counts    rows per table, so the import can prove nothing was lost
    jengasec-neon-<date>.sha256    checksum, so the import can prove the file arrived intact

  Usage (PowerShell):
    powershell -ExecutionPolicy Bypass -File .\export-from-neon.ps1
  It asks for the Neon URL; paste it from Render -> jengasec -> Environment ->
  JENGASEC_DB_URL. The URL is never written to disk or shown on screen.

  Needs pg_dump and psql version 17 or newer (scripts/cutover/README.md, step 1).

  THE .sql FILE HOLDS EVERY PARTICIPANT'S PERSONAL DATA. Keep it on your own
  laptop or an encrypted USB stick, and delete it once the import is verified.
#>
param(
    [string]$OutDir = "."
)

$ErrorActionPreference = "Stop"

function Find-PgTool([string]$name) {
    $cmd = Get-Command "$name.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # The PostgreSQL installer does not add itself to PATH; look where it installs.
    $found = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\$name.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Directory.Parent.Name -replace '\D', '') } -Descending |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "$name.exe not found. Install the PostgreSQL 17 command line tools first - see scripts/cutover/README.md, step 1."
}

$pgDump = Find-PgTool "pg_dump"
$psql = Find-PgTool "psql"
Write-Host "Using $pgDump"

# ── The connection, without it ever touching the command line ───────────────
$secure = Read-Host "Paste the Neon URL (Render -> Environment -> JENGASEC_DB_URL)" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$url = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim().Trim('"').Trim("'")
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

if ($url -notmatch '^postgres(ql)?://') { throw "That does not look like a PostgreSQL URL (it should start with postgresql://)." }

# pg_dump through Neon's connection pooler can fail part-way; the direct
# endpoint is the same host name without "-pooler".
$uri = [Uri]($url -replace '-pooler\.', '.')
$userInfo = $uri.UserInfo.Split(':', 2)

$env:PGHOST = $uri.Host
$env:PGPORT = $(if ($uri.Port -gt 0) { "$($uri.Port)" } else { "5432" })
$env:PGDATABASE = $uri.AbsolutePath.TrimStart('/')
$env:PGUSER = [Uri]::UnescapeDataString($userInfo[0])
$env:PGPASSWORD = [Uri]::UnescapeDataString($userInfo[1])
$env:PGSSLMODE = "require"
$env:PGCONNECT_TIMEOUT = "15"

try {
    # ── Can we reach it, and is our pg_dump new enough? ─────────────────────
    Write-Host "Connecting to $($env:PGHOST) ..."
    $serverNum = & $psql -XAtq -c "SHOW server_version_num"
    if ($LASTEXITCODE -ne 0) { throw "Could not connect. On campus? Port 5432 is blocked there - use home Wi-Fi or a hotspot." }
    $serverMajor = [int]([int]$serverNum / 10000)
    $dumpMajor = [int]((& $pgDump --version) -replace '^\D*(\d+).*$', '$1')
    if ($dumpMajor -lt $serverMajor) {
        throw "Neon runs PostgreSQL $serverMajor but this pg_dump is $dumpMajor. Install the PostgreSQL $serverMajor command line tools."
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmm"
    $base = Join-Path (Resolve-Path $OutDir) "jengasec-neon-$stamp"

    # ── The dump ────────────────────────────────────────────────────────────
    # Plain SQL rather than pg_dump's own format: any psql can load it, so the
    # database VM does not need the same version of the tools as this laptop.
    # No owners or grants: the import assigns everything to jengasec_web.
    Write-Host "Exporting ..."
    & $pgDump --format=plain --schema=public --no-owner --no-privileges `
        --no-publications --no-subscriptions --file "$base.sql"
    if ($LASTEXITCODE -ne 0) { throw "pg_dump failed - the message above says why." }

    # ── Row counts, read in the same breath as the dump ─────────────────────
    $countSql = @'
SELECT table_name || ',' || (xpath('/row/c/text()',
         query_to_xml(format('SELECT count(*) AS c FROM public.%I', table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
'@
    & $psql -XAtq -o "$base.counts" -c $countSql
    if ($LASTEXITCODE -ne 0) { throw "Could not count rows." }

    # ── Checksum, in the format `sha256sum -c` reads on Linux ───────────────
    $hash = (Get-FileHash "$base.sql" -Algorithm SHA256).Hash.ToLower()
    $name = Split-Path "$base.sql" -Leaf
    [IO.File]::WriteAllText("$base.sha256", "$hash  $name`n")

    $tables = (Get-Content "$base.counts" | Where-Object { $_ }).Count
    $rows = (Get-Content "$base.counts" | Where-Object { $_ } | ForEach-Object { [long]($_.Split(',')[1]) } | Measure-Object -Sum).Sum
    $size = "{0:N1} MB" -f ((Get-Item "$base.sql").Length / 1MB)

    Write-Host ""
    Write-Host "Done - PostgreSQL $serverMajor, $tables tables, $rows rows, $size" -ForegroundColor Green
    Write-Host "  $base.sql"
    Write-Host "  $base.counts"
    Write-Host "  $base.sha256"
    Write-Host ""
    Write-Host "Copy ALL THREE files to the database VM (scripts/cutover/README.md, step 4)."
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

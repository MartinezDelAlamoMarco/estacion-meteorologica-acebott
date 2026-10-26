#Requires -Version 5.1
<#
  Instalador del servidor de la estación meteorológica

  Lo hicimos porque montar el servidor a mano tiene muchos pasos y es muy
  fácil saltarse uno (a nosotros nos pasó varias veces). En una sola
  ejecución:
    - configura SQL Server (TCP/IP en el 1433 y autenticación mixta)
    - crea la base de datos, la tabla y el usuario de la API
    - instala la API de Node.js como servicio de Windows con NSSM
    - instala el túnel de ngrok como servicio
    - y al final manda una lectura de prueba por local y por ngrok

  No lo lances directamente: haz doble clic en INSTALAR.bat, que pide
  permisos de administrador. Puedes ejecutarlo todas las veces que quieras,
  lo que ya está hecho no lo repite.
#>

$ErrorActionPreference = 'Stop'
$Dir         = $PSScriptRoot
$Puerto      = 3000
$PuertoSql   = 1433
$ServicioApi = 'EstacionMeteo'
$DbName      = 'EstacionMeteo'
$DbUser      = 'estacion_app'

# ===== CONFIGURACIÓN (si se dejan vacías, el script las pregunta) =====
$DbPassword = ''
$ApiKey     = ''
$NgrokToken = ''   # vacío = usa el del ngrok que ya tengas configurado
# =====================================================================

$Logs = Join-Path $Dir 'logs'
$Bin  = Join-Path $Dir 'bin'

# ---------- utilidades ----------
function Paso($n, $t) { Write-Host "`n[$n/8] $t" -ForegroundColor Cyan }
function Ok($t)       { Write-Host "    OK  $t" -ForegroundColor Green }
function Info($t)     { Write-Host "    ..  $t" -ForegroundColor Gray }
function Fallo($t, $ayuda) {
  Write-Host "`n    ERROR: $t" -ForegroundColor Red
  if ($ayuda) { Write-Host "    -> $ayuda" -ForegroundColor Yellow }
  Write-Host "`n    Registro completo en: $Logs\instalacion.log" -ForegroundColor Gray
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}
function Refrescar-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Escribir-Utf8($ruta, $texto) {
  [IO.File]::WriteAllText($ruta, $texto, (New-Object Text.UTF8Encoding($false)))
}
# Ejecuta un programa externo sin que sus avisos por stderr corten el script
function Ejecutar([string]$Exe, [string[]]$Argumentos) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out  = & $Exe @Argumentos 2>&1 | Out-String
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $old }
  return @{ Code = $code; Out = $out }
}
function Sql-Exec($connStr, $query) {
  $c = New-Object System.Data.SqlClient.SqlConnection $connStr
  try {
    $c.Open()
    $cmd = $c.CreateCommand()
    $cmd.CommandText = $query
    $cmd.CommandTimeout = 60
    return $cmd.ExecuteScalar()
  } finally { $c.Dispose() }
}

# ---------- comprobaciones iniciales ----------
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) { Fallo 'Hay que ejecutarlo como administrador.' 'Haz doble clic en INSTALAR.bat (ya pide los permisos él solo).' }

New-Item -ItemType Directory -Force $Logs, $Bin | Out-Null
try { Start-Transcript -Path (Join-Path $Logs 'instalacion.log') -Append | Out-Null } catch {}

Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '  Instalador - Estación meteorológica ACEBOTT' -ForegroundColor Cyan
Write-Host "  Carpeta: $Dir" -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

foreach ($f in 'server.js', 'package.json') {
  if (-not (Test-Path (Join-Path $Dir $f))) {
    Fallo "No encuentro $f en $Dir" 'El script tiene que estar en la misma carpeta que server.js y package.json.'
  }
}

# Reutilizar datos de una instalación anterior
$CfgPath = Join-Path $Dir 'config.json'
if (Test-Path $CfgPath) {
  try {
    $prev = Get-Content $CfgPath -Raw | ConvertFrom-Json
    if (-not $DbPassword) { $DbPassword = $prev.dbPassword }
    if (-not $ApiKey)     { $ApiKey     = $prev.apiKey }
    Info 'Usando la contraseña y la clave de la instalación anterior (config.json)'
  } catch {}
}
if (-not $DbPassword) {
  Write-Host "`nContraseña para el usuario '$DbUser' de SQL Server" -ForegroundColor Yellow
  Write-Host '(mínimo 8 caracteres con mayúsculas, minúsculas, números y algún símbolo)' -ForegroundColor Yellow
  $DbPassword = Read-Host 'Contraseña'
}
if (-not $ApiKey) {
  Write-Host "`nClave de la API (la misma que pondrás en API_KEY del ESP32)" -ForegroundColor Yellow
  $ApiKey = Read-Host 'Clave'
}
if (-not $DbPassword -or -not $ApiKey) { Fallo 'Falta la contraseña o la clave.' }
$DbPassword = [string]$DbPassword
$ApiKey     = [string]$ApiKey

# =================================================================
Paso 1 'Node.js'
Refrescar-Path
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fallo 'Node.js no está instalado y no hay winget para instalarlo.' 'Instala Node.js LTS desde nodejs.org y vuelve a ejecutarlo.'
  }
  Info 'Instalando Node.js LTS (puede tardar un par de minutos)...'
  Ejecutar 'winget' @('install', '--id', 'OpenJS.NodeJS.LTS', '-e', '--silent',
                      '--accept-source-agreements', '--accept-package-agreements') | Out-Null
  Refrescar-Path
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Fallo 'No se pudo instalar Node.js.' 'Instálalo a mano desde nodejs.org y vuelve a ejecutarlo.'
  }
}
$NodeExe = (Get-Command node).Source
Ok "Node $(& $NodeExe -v) ($NodeExe)"

# =================================================================
Paso 2 'SQL Server: TCP/IP en el puerto 1433 y modo mixto'
$instKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
if (-not (Test-Path $instKey)) {
  Fallo 'No encuentro SQL Server instalado.' 'Instala SQL Server (vale la edición Express) y vuelve a ejecutarlo.'
}
$inst     = Get-ItemProperty $instKey
$nombres  = @($inst.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object Name)
$Instancia = if ($nombres -contains 'SQLEXPRESS') { 'SQLEXPRESS' } else { $nombres[0] }
$InstId    = $inst.$Instancia
$SqlServicio = if ($Instancia -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$Instancia" }
$SqlLocal    = if ($Instancia -eq 'MSSQLSERVER') { '.' } else { ".\$Instancia" }
Info "Instancia: $Instancia ($InstId), servicio $SqlServicio"

$base  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$InstId\MSSQLServer"
$tcp   = "$base\SuperSocketNetLib\Tcp"
$ipall = "$tcp\IPAll"
$cambios = $false

if ((Get-ItemProperty $tcp).Enabled -ne 1) {
  Set-ItemProperty $tcp -Name Enabled -Value 1; $cambios = $true; Info 'TCP/IP activado'
}
$p = Get-ItemProperty $ipall
if ("$($p.TcpPort)" -ne "$PuertoSql" -or "$($p.TcpDynamicPorts)" -ne '') {
  Set-ItemProperty $ipall -Name TcpPort -Value "$PuertoSql"
  Set-ItemProperty $ipall -Name TcpDynamicPorts -Value ''
  $cambios = $true; Info "Puerto fijo $PuertoSql"
}
if ((Get-ItemProperty $base).LoginMode -ne 2) {
  Set-ItemProperty $base -Name LoginMode -Value 2; $cambios = $true; Info 'Modo mixto activado'
}

# Parar la API (si ya existía) antes de tocar SQL Server
if (Get-Service $ServicioApi -ErrorAction SilentlyContinue) {
  Stop-Service $ServicioApi -Force -ErrorAction SilentlyContinue
}
Set-Service $SqlServicio -StartupType Automatic
if ($cambios) {
  Info 'Reiniciando SQL Server para aplicar los cambios...'
  Restart-Service $SqlServicio -Force
} elseif ((Get-Service $SqlServicio).Status -ne 'Running') {
  Start-Service $SqlServicio
}
Ok 'SQL Server configurado'

# =================================================================
Paso 3 'Base de datos, tabla y usuario de la API'
$admConn = "Server=$SqlLocal;Database=master;Integrated Security=True;Connect Timeout=5"
$dbConn  = "Server=$SqlLocal;Database=$DbName;Integrated Security=True;Connect Timeout=5"
$listo = $false
for ($i = 0; $i -lt 20 -and -not $listo; $i++) {
  try { Sql-Exec $admConn 'SELECT 1' | Out-Null; $listo = $true } catch { Start-Sleep 2 }
}
if (-not $listo) {
  Fallo 'No puedo entrar en SQL Server con tu usuario de Windows.' 'Ejecuta el instalador con el usuario de Windows que instaló SQL Server (tiene que ser sysadmin).'
}
$pw = $DbPassword.Replace("'", "''")
try {
  Sql-Exec $admConn "IF DB_ID('$DbName') IS NULL CREATE DATABASE [$DbName];" | Out-Null
  Sql-Exec $admConn @"
IF SUSER_ID('$DbUser') IS NULL
BEGIN
  CREATE LOGIN [$DbUser] WITH PASSWORD = N'$pw', CHECK_POLICY = ON, DEFAULT_DATABASE = [$DbName];
END
ELSE
BEGIN
  ALTER LOGIN [$DbUser] WITH PASSWORD = N'$pw';
  ALTER LOGIN [$DbUser] ENABLE;
END
"@ | Out-Null
  Sql-Exec $dbConn @"
IF OBJECT_ID('dbo.Lecturas') IS NULL
CREATE TABLE dbo.Lecturas (
    Id           INT IDENTITY(1,1) PRIMARY KEY,
    Fecha        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    Temperatura  DECIMAL(4,1) NOT NULL,
    Humedad      DECIMAL(4,1) NOT NULL
);
"@ | Out-Null
  # Columnas del resto de sensores (se añaden solo si faltan)
  Sql-Exec $dbConn @"
IF COL_LENGTH('dbo.Lecturas', 'Lluvia')    IS NULL ALTER TABLE dbo.Lecturas ADD Lluvia    INT          NULL;
IF COL_LENGTH('dbo.Lecturas', 'Vibracion') IS NULL ALTER TABLE dbo.Lecturas ADD Vibracion BIT          NULL;
IF COL_LENGTH('dbo.Lecturas', 'UV')        IS NULL ALTER TABLE dbo.Lecturas ADD UV        INT          NULL;
IF COL_LENGTH('dbo.Lecturas', 'Presion')   IS NULL ALTER TABLE dbo.Lecturas ADD Presion   DECIMAL(8,2) NULL;
IF COL_LENGTH('dbo.Lecturas', 'Luz')       IS NULL ALTER TABLE dbo.Lecturas ADD Luz       INT          NULL;
IF COL_LENGTH('dbo.Lecturas', 'Viento')    IS NULL ALTER TABLE dbo.Lecturas ADD Viento    DECIMAL(5,1) NULL;
IF COL_LENGTH('dbo.Lecturas', 'PM25')      IS NULL ALTER TABLE dbo.Lecturas ADD PM25      INT          NULL;
"@ | Out-Null
  Sql-Exec $dbConn @"
IF USER_ID('$DbUser') IS NULL CREATE USER [$DbUser] FOR LOGIN [$DbUser];
ALTER ROLE db_datareader ADD MEMBER [$DbUser];
ALTER ROLE db_datawriter ADD MEMBER [$DbUser];
"@ | Out-Null
} catch {
  Fallo "Error de SQL: $($_.Exception.Message)" 'Si habla de la contraseña (password policy), usa una más larga con mayúsculas, números y símbolos: borra config.json y vuelve a ejecutarlo.'
}
Ok "Base de datos '$DbName', tabla dbo.Lecturas y usuario '$DbUser' listos"

# Probar el login de la API exactamente como lo hará Node (TCP 1433 + usuario SQL)
# Cadena de conexión a mano (la contraseña va entre comillas simples, duplicando las que tenga)
$pwConn  = ([string]$DbPassword).Replace("'", "''")
$appConn = "Server=127.0.0.1,$PuertoSql;Database=$DbName;User Id=$DbUser;Password='$pwConn';Connect Timeout=5"
$okLogin = $false; $errLogin = ''
for ($i = 0; $i -lt 10 -and -not $okLogin; $i++) {
  try { $n = Sql-Exec $appConn 'SELECT COUNT(*) FROM dbo.Lecturas'; $okLogin = $true }
  catch { $errLogin = $_.Exception.Message; Start-Sleep 2 }
}
if (-not $okLogin) {
  Fallo "El usuario '$DbUser' no puede conectar por TCP $PuertoSql`: $errLogin" "Puede que otra instancia de SQL Server esté usando el puerto $PuertoSql."
}
Ok "Login de '$DbUser' por TCP $PuertoSql correcto ($n lecturas guardadas)"

# =================================================================
Paso 4 'Configuración y dependencias de la API'
$cfg = [ordered]@{
  dbServer   = 'localhost'
  dbPort     = $PuertoSql
  dbName     = $DbName
  dbUser     = $DbUser
  dbPassword = $DbPassword
  apiKey     = $ApiKey
  puerto     = $Puerto
}
Escribir-Utf8 $CfgPath ($cfg | ConvertTo-Json)
Ok 'config.json generado'

# Cerrar lo que esté ocupando el puerto (p. ej. un "node server.js" abierto a mano)
Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
    if ($_ -le 4) { Fallo "El puerto $Puerto lo está usando el sistema." 'Cambia $Puerto al principio de instalar.ps1.' }
    $proc = Get-Process -Id $_ -ErrorAction SilentlyContinue
    if ($proc) { Info "Cerrando $($proc.ProcessName) (PID $($proc.Id)), que ocupaba el puerto $Puerto"; Stop-Process -Id $proc.Id -Force }
  }

Info 'npm install...'
Push-Location $Dir
$r = Ejecutar 'npm.cmd' @('install', '--omit=dev', '--no-fund', '--no-audit')
Pop-Location
if ($r.Code -ne 0) { Fallo "npm install ha fallado:`n$($r.Out)" '¿Tiene Internet el servidor?' }
Ok 'Dependencias instaladas (express, mssql)'

# =================================================================
Paso 5 'Firewall'
if (-not (Get-NetFirewallRule -DisplayName 'Estacion meteo' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName 'Estacion meteo' -Direction Inbound -Protocol TCP `
    -LocalPort $Puerto -Action Allow | Out-Null
}
Ok "Puerto $Puerto abierto (para que la estación pueda enviar también por red local)"

# =================================================================
Paso 6 "Servicio de Windows '$ServicioApi' (la API)"
$Nssm = Join-Path $Bin 'nssm.exe'
if (-not (Test-Path $Nssm)) {
  $c = Get-Command nssm -ErrorAction SilentlyContinue
  if ($c) { Copy-Item $c.Source $Nssm }
}
if (-not (Test-Path $Nssm)) {
  Info 'Descargando NSSM...'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP 'nssm.zip'
    $tmp = Join-Path $env:TEMP 'nssm'
    Invoke-WebRequest 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive $zip $tmp -Force
    Copy-Item (Join-Path $tmp 'nssm-2.24\win64\nssm.exe') $Nssm
  } catch {
    Info 'nssm.cc no responde, probando con winget...'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Ejecutar 'winget' @('install', '--id', 'NSSM.NSSM', '-e', '--silent',
                          '--accept-source-agreements', '--accept-package-agreements') | Out-Null
      Refrescar-Path
      $c = Get-Command nssm -ErrorAction SilentlyContinue
      if ($c) { Copy-Item $c.Source $Nssm }
    }
  }
}
if (-not (Test-Path $Nssm)) {
  Fallo 'No se pudo conseguir NSSM.' "Descarga nssm-2.24.zip de nssm.cc, copia win64\nssm.exe a $Bin y vuelve a ejecutarlo."
}

if (Get-Service $ServicioApi -ErrorAction SilentlyContinue) {
  Info 'Reinstalando el servicio anterior...'
  Ejecutar $Nssm @('stop', $ServicioApi) | Out-Null
  Ejecutar $Nssm @('remove', $ServicioApi, 'confirm') | Out-Null
  Start-Sleep 2
}
$ordenes = @(
  @('install', $ServicioApi, $NodeExe, 'server.js'),
  @('set', $ServicioApi, 'AppDirectory', $Dir),
  @('set', $ServicioApi, 'DisplayName', 'Estacion meteorologica - API'),
  @('set', $ServicioApi, 'Start', 'SERVICE_AUTO_START'),
  @('set', $ServicioApi, 'DependOnService', $SqlServicio),
  @('set', $ServicioApi, 'AppStdout', (Join-Path $Logs 'api.log')),
  @('set', $ServicioApi, 'AppStderr', (Join-Path $Logs 'api-error.log')),
  @('set', $ServicioApi, 'AppRotateFiles', '1'),
  @('set', $ServicioApi, 'AppRotateBytes', '1048576'),
  @('set', $ServicioApi, 'AppExit', 'Default', 'Restart'),
  @('set', $ServicioApi, 'AppRestartDelay', '5000')
)
foreach ($o in $ordenes) {
  $r = Ejecutar $Nssm $o
  if ($r.Code -ne 0) { Fallo "nssm $($o -join ' ') ha fallado:`n$($r.Out)" }
}
Start-Service $ServicioApi

$okApi = $false
for ($i = 0; $i -lt 15 -and -not $okApi; $i++) {
  Start-Sleep 2
  try { Invoke-RestMethod "http://127.0.0.1:$Puerto/api/ultimas" -TimeoutSec 5 | Out-Null; $okApi = $true } catch {}
}
if (-not $okApi) {
  $e = Get-Content (Join-Path $Logs 'api-error.log') -Tail 15 -ErrorAction SilentlyContinue | Out-String
  Fallo "La API no responde en el puerto $Puerto. Últimos errores:`n$e"
}
Ok "API funcionando como servicio en http://127.0.0.1:$Puerto"

# =================================================================
Paso 7 'Túnel de ngrok como servicio'
Refrescar-Path
$Ngrok = Join-Path $Bin 'ngrok.exe'
$NgrokSrc = $null
$c = Get-Command ngrok -ErrorAction SilentlyContinue
if ($c -and $c.Source -like '*.exe') { $NgrokSrc = $c.Source }
if (-not $NgrokSrc) {
  foreach ($cand in @('C:\ngrok\ngrok.exe',
                      (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ngrok.exe'),
                      (Join-Path $env:USERPROFILE 'Downloads\ngrok.exe'),
                      (Join-Path $env:USERPROFILE 'Desktop\ngrok.exe'),
                      $Ngrok)) {
    if (Test-Path $cand) { $NgrokSrc = $cand; break }
  }
}
if (-not $NgrokSrc) { Fallo 'No encuentro ngrok.exe.' "Copia ngrok.exe a $Bin y vuelve a ejecutarlo." }

# Parar cualquier ngrok anterior (servicio o abierto a mano): no puede haber dos con el mismo dominio
if (Get-Service ngrok -ErrorAction SilentlyContinue) {
  Ejecutar $NgrokSrc @('service', 'stop') | Out-Null
  Ejecutar $NgrokSrc @('service', 'uninstall') | Out-Null
}
Get-Process ngrok -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2

# Copia propia de ngrok.exe dentro del proyecto (el servicio la usará siempre desde aquí)
if ((Resolve-Path $NgrokSrc).Path -ne $Ngrok) { Copy-Item $NgrokSrc $Ngrok -Force }

# Authtoken: el del ngrok ya configurado en este usuario
if (-not $NgrokToken) {
  $cands = @()
  $r = Ejecutar $Ngrok @('config', 'check')
  if ($r.Out -match '([A-Za-z]:\\[^\r\n"]*?ngrok\.yml)') { $cands += $Matches[1] }
  $cands += (Join-Path $env:LOCALAPPDATA 'ngrok\ngrok.yml'),
            (Join-Path $env:USERPROFILE 'AppData\Local\ngrok\ngrok.yml'),
            (Join-Path $env:USERPROFILE '.ngrok2\ngrok.yml'),
            (Join-Path $env:USERPROFILE '.config\ngrok\ngrok.yml'),
            (Join-Path $Dir 'ngrok.yml')
  foreach ($f in $cands) {
    if (Test-Path $f) {
      $m = Select-String -Path $f -Pattern '^\s*authtoken:\s*"?([A-Za-z0-9_\-]+)"?' | Select-Object -First 1
      if ($m -and $m.Matches[0].Groups[1].Value -notmatch 'TU_AUTHTOKEN') {
        $NgrokToken = $m.Matches[0].Groups[1].Value
        Info "Authtoken leído de $f"
        break
      }
    }
  }
}
if (-not $NgrokToken) {
  Write-Host "`nNo encuentro tu authtoken de ngrok (dashboard.ngrok.com > Your Authtoken)" -ForegroundColor Yellow
  $NgrokToken = Read-Host 'Authtoken'
}
if (-not $NgrokToken) { Fallo 'Falta el authtoken de ngrok.' }

$Yml = Join-Path $Dir 'ngrok.yml'
Escribir-Utf8 $Yml @"
version: "3"
agent:
  authtoken: $NgrokToken
tunnels:
  estacion:
    proto: http
    addr: 127.0.0.1:$Puerto
    schemes: [https, http]
"@

$r = Ejecutar $Ngrok @('service', 'install', '--config', $Yml)
if ($r.Code -ne 0) { Fallo "ngrok service install ha fallado:`n$($r.Out)" }
$r = Ejecutar $Ngrok @('service', 'start')
if ($r.Code -ne 0) { Fallo "ngrok service start ha fallado:`n$($r.Out)" }
try { Set-Service ngrok -StartupType Automatic } catch {}

$UrlPublica = $null
for ($i = 0; $i -lt 15 -and -not $UrlPublica; $i++) {
  Start-Sleep 2
  try {
    $t = Invoke-RestMethod 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 3
    $UrlPublica = ($t.tunnels | Where-Object { $_.public_url -like 'https*' } | Select-Object -First 1).public_url
  } catch {}
}
if (-not $UrlPublica) {
  Fallo 'El túnel de ngrok no ha arrancado.' 'Revisa el authtoken y que no haya un ngrok abierto en OTRO equipo con la misma cuenta (ciérralo y vuelve a ejecutarlo).'
}
Ok "Túnel activo: $UrlPublica"

# =================================================================
Paso 8 'Prueba completa (como si fuera la estación)'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$body = '{"temperatura":-99.9,"humedad":-99.9}'
$hdr  = @{ 'X-API-Key' = $ApiKey; 'ngrok-skip-browser-warning' = '1' }

try {
  Invoke-RestMethod "http://127.0.0.1:$Puerto/api/lecturas" -Method Post -ContentType 'application/json' -Headers $hdr -Body $body | Out-Null
  Ok 'La API guarda datos en SQL Server'
} catch { Fallo "La API no guarda datos: $($_.Exception.Message)" "Mira $Logs\api-error.log" }

$okNgrok = $false; $errNgrok = ''
for ($i = 0; $i -lt 3 -and -not $okNgrok; $i++) {
  try {
    Invoke-RestMethod "$UrlPublica/api/lecturas" -Method Post -ContentType 'application/json' -Headers $hdr -Body $body | Out-Null
    $okNgrok = $true
  } catch { $errNgrok = $_.Exception.Message; Start-Sleep 3 }
}
if (-not $okNgrok) { Fallo "La petición por Internet (ngrok) falla: $errNgrok" }
Ok 'Una petición desde Internet llega por ngrok y se guarda'

try { Sql-Exec $dbConn 'DELETE FROM dbo.Lecturas WHERE Temperatura = -99.9 AND Humedad = -99.9' | Out-Null; Info 'Lecturas de prueba borradas' } catch {}

# =================================================================
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  ForEach-Object IPAddress

Write-Host "`n==================== TODO LISTO ====================" -ForegroundColor Green
Write-Host " Web (desde cualquier sitio):  $UrlPublica"
Write-Host ''
Write-Host ' URL para poner en el ESP32:' -ForegroundColor Yellow
Write-Host "   Por Internet (ngrok):  $UrlPublica/api/lecturas"
foreach ($ip in $ips) {
  Write-Host "   Por red local:         http://$ip`:$Puerto/api/lecturas  (con http.begin(URL), sin client)"
}
Write-Host ''
Write-Host " API_KEY del ESP32:  la clave que has escrito (guardada en config.json)"
Write-Host " Logs de la API:     $Logs"
Write-Host " Los servicios '$ServicioApi' y 'ngrok' arrancan solos con Windows."
Write-Host '====================================================' -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}

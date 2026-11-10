<#
Codex Windows Sandbox: diagnóstico + reparación limitada.

Solo añade SYSTEM:WRITE_DAC a la carpeta estándar .codex\.sandbox-bin si:
- setup_error.json confirma helper_sandbox_lock_failed, .sandbox-bin y error 5;
- SYSTEM tiene Modify pero no WRITE_DAC;
- la DACL está protegida y canónica, el propietario es el usuario actual;
- no hay ACE de denegación relevante, junction/reparse point ni Codex abierto;
- PowerShell está elevado y el usuario escribe REPARAR.

No reinicia servicios/app, no repite UAC, no cambia propietario, no reemplaza
ACL, no activa herencia, no concede Full Control, no edita config.toml y no
sube ningún diagnóstico. Crea informe local y copia SDDL antes del único cambio.

Referencias: PR #59745; issues #59038, #60057, #60192.
#>

if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Se necesita PowerShell 7 o superior (pwsh).' }
$ErrorActionPreference = 'Continue'
$Now = Get-Date
$Desktop = [Environment]::GetFolderPath('Desktop')
if (-not (Test-Path -LiteralPath $Desktop -PathType Container)) { throw 'No se encontró el Escritorio.' }
$Tag = Get-Date -Format 'yyyyMMdd_HHmmss'
$ReportPath = Join-Path $Desktop "Codex_Sandbox_Diagnostico_$Tag.md"
$BackupPath = Join-Path $Desktop "Codex_SandboxBin_ACL_Backup_$Tag.sddl.txt"
$Report = [System.Collections.Generic.List[string]]::new()

function AddLine([string]$Text) { [void]$Report.Add($Text) }
function GetSid($Ref) {
    try {
        if ($Ref -is [System.Security.Principal.SecurityIdentifier]) { return $Ref.Value }
        return $Ref.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { return [string]$Ref.Value }
}
function SafeText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if ($env:USERPROFILE) { $Text = $Text.Replace($env:USERPROFILE,'%USERPROFILE%') }
    if ($CodexHome) { $Text = $Text.Replace($CodexHome,'%CODEX_HOME%') }
    $Text = [regex]::Replace($Text,'(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b','[EMAIL_REDACTED]')
    $Text = [regex]::Replace($Text,'(?i)\b(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|Bearer\s+[A-Za-z0-9._~-]{16,})\b','[TOKEN_REDACTED]')
    $Text = $Text -replace '[\r\n\t]+',' '
    if ($Text.Length -gt 450) { $Text = $Text.Substring(0,450)+'...' }
    return $Text.Trim()
}
function HasFlag($Rights,$Flag) { return (([int]$Rights -band [int]$Flag) -eq [int]$Flag) }

$DefaultHome = Join-Path $env:USERPROFILE '.codex'
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { $DefaultHome }
$IsDefaultHome = [string]::Equals([IO.Path]::GetFullPath($CodexHome).TrimEnd('\'),[IO.Path]::GetFullPath($DefaultHome).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
$Bin = Join-Path $CodexHome '.sandbox-bin'
$Sandbox = Join-Path $CodexHome '.sandbox'
$ErrorFile = Join-Path $Sandbox 'setup_error.json'
$LogFile = Join-Path $Sandbox 'sandbox.log'
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = ([Security.Principal.WindowsPrincipal]::new($Identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

AddLine '# Codex Windows Sandbox: diagnóstico y reparación limitada'
AddLine "- Fecha local: $($Now.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
AddLine "- PowerShell: $($PSVersionTable.PSVersion); sesión elevada: $IsAdmin"

try {
    $OS = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $Build = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    AddLine "- Windows: $($OS.Caption); build $($OS.BuildNumber).$($Build.UBR); $($OS.OSArchitecture)"
} catch { AddLine '- Datos de Windows: no disponibles.' }

try {
    $Pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Pkg) { AddLine "- Codex AppX: $($Pkg.Version); estado $($Pkg.Status); arquitectura $($Pkg.Architecture)" }
    else { AddLine '- Codex AppX: paquete no encontrado para este usuario.' }
} catch { AddLine '- Codex AppX: consulta no disponible.' }

$Processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(Codex|ChatGPT)$' })
AddLine "- Procesos Codex/ChatGPT activos: $($Processes.Count)"
try {
    $Svc = Get-CimInstance Win32_Service -Filter "Name='CodexSandboxService.OpenAI.Codex'" -ErrorAction SilentlyContinue
    if ($Svc) { AddLine "- Servicio sandbox: $($Svc.State); inicio=$($Svc.StartMode); PID=$($Svc.ProcessId)" }
    else { AddLine '- Servicio sandbox Codex: no encontrado.' }
} catch { AddLine '- Servicio sandbox Codex: consulta no disponible.' }

$Mode = 'NO DETERMINADO'
$Config = Join-Path $CodexHome 'config.toml'
if (Test-Path -LiteralPath $Config -PathType Leaf) {
    try {
        $Section = ''
        foreach ($L in Get-Content -LiteralPath $Config) {
            if ($L -match '^\s*\[([^\]]+)\]\s*$') { $Section = $Matches[1].ToLowerInvariant(); continue }
            if ($Section -eq 'windows' -and $L -match '^\s*sandbox\s*=\s*["'']([^"'']+)["'']') { $Mode = $Matches[1] }
        }
    } catch { $Mode = 'NO SE PUDO LEER' }
}
AddLine "- CODEX_HOME estándar (%USERPROFILE%\.codex): $IsDefaultHome; config.toml: $(Test-Path -LiteralPath $Config -PathType Leaf); windows.sandbox=$Mode"

$Code = ''; $Message = ''; $ExactError = $false
if (Test-Path -LiteralPath $ErrorFile -PathType Leaf) {
    try {
        $E = Get-Content -LiteralPath $ErrorFile -Raw | ConvertFrom-Json
        $Code = [string]$E.code; $Message = [string]$E.message
        $ExactError = ($Code -eq 'helper_sandbox_lock_failed' -and $Message -match '(?i)\.sandbox-bin' -and ($Message -match '(?i)NtCreateFile' -or $Message -match '(?i)os error\s*5|error\s*5'))
        AddLine "- setup_error.json: presente; code=$Code; evidencia exacta .sandbox-bin + error 5=$ExactError"
    } catch { AddLine '- setup_error.json: existe, pero no se pudo interpretar.' }
} else { AddLine '- setup_error.json: no encontrado.' }

$BinExists = Test-Path -LiteralPath $Bin -PathType Container
$HomeReparse = $false; $BinReparse = $false; $Acl = $null
$OwnerCurrent = $false; $Protected = $false; $Canonical = $false
$SystemModify = $false; $SystemWDAC = $false; $SystemDeny = $false; $BroadDeny = $false; $AnyDeny = $false
if (Test-Path -LiteralPath $CodexHome -PathType Container) {
    $HomeReparse = ((Get-Item -LiteralPath $CodexHome -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}
if ($BinExists) {
    try {
        $BinItem = Get-Item -LiteralPath $Bin -Force
        $BinReparse = (($BinItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        $Acl = Get-Acl -LiteralPath $Bin -ErrorAction Stop
        $OwnerSid = GetSid ([Security.Principal.NTAccount]::new($Acl.Owner))
        $OwnerCurrent = ($OwnerSid -eq $Identity.User.Value)
        $Protected = [bool]$Acl.AreAccessRulesProtected
        $Canonical = [bool]$Acl.AreAccessRulesCanonical
        foreach ($Rule in $Acl.Access) {
            $Sid = GetSid $Rule.IdentityReference
            $Rights = [Security.AccessControl.FileSystemRights]$Rule.FileSystemRights
            if ($Sid -eq 'S-1-5-18' -and $Rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) {
                if (HasFlag $Rights ([Security.AccessControl.FileSystemRights]::Modify)) { $SystemModify = $true }
                if (HasFlag $Rights ([Security.AccessControl.FileSystemRights]::ChangePermissions)) { $SystemWDAC = $true }
            }
            if ($Rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny) {
                $AnyDeny = $true
            }
            if ($Rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny -and (HasFlag $Rights ([Security.AccessControl.FileSystemRights]::ChangePermissions))) {
                if ($Sid -eq 'S-1-5-18') { $SystemDeny = $true }
                if ($Sid -in @('S-1-1-0','S-1-5-11','S-1-5-32-544')) { $BroadDeny = $true }
            }
        }
        AddLine "- .sandbox-bin: existe; reparse/junction=$BinReparse; propietario usuario actual=$OwnerCurrent; DACL protegida=$Protected; canónica=$Canonical"
        AddLine "- ACL SYSTEM: Modify=$SystemModify; WRITE_DAC=$SystemWDAC; denegación SYSTEM=$SystemDeny; denegación amplia=$BroadDeny"
        foreach ($Rule in $Acl.Access) {
            if ((GetSid $Rule.IdentityReference) -eq 'S-1-5-18') {
                AddLine "- ACE SYSTEM: $($Rule.AccessControlType); $($Rule.FileSystemRights); heredada=$($Rule.IsInherited)"
            }
        }
    } catch { AddLine "- ACL .sandbox-bin: error de lectura ($(SafeText $_.Exception.Message))." }
} else { AddLine '- .sandbox-bin: no existe como directorio.' }
AddLine "- CODEX_HOME reparse/junction=$HomeReparse"

AddLine '## Extractos filtrados de sandbox.log'
if (Test-Path -LiteralPath $LogFile -PathType Leaf) {
    try {
        $Hits = @(Get-Content -LiteralPath $LogFile -Tail 1500 | Where-Object { $_ -match '(?i)helper_sandbox_lock_failed|NtCreateFile|Access is denied|ERROR_NONE_MAPPED|0x534|WRITE_DAC|WFP setup|setup provisioning binary completed' } | Select-Object -Last 30)
        if ($Hits.Count -eq 0) { AddLine '- Sin coincidencias en las últimas 1500 líneas.' }
        foreach ($Hit in $Hits) { AddLine "- $(SafeText $Hit)" }
    } catch { AddLine '- No se pudo leer sandbox.log.' }
} else { AddLine '- sandbox.log no encontrado.' }

# Repair gate: this is intentionally stricter than the public workaround.
$Block = [System.Collections.Generic.List[string]]::new()
if (-not $ExactError) { [void]$Block.Add('setup_error.json no confirma el fallo exacto helper_sandbox_lock_failed/.sandbox-bin/error 5') }
if (-not $BinExists -or $null -eq $Acl) { [void]$Block.Add('.sandbox-bin no existe o no se pudo leer su ACL') }
if (-not $SystemModify) { [void]$Block.Add('SYSTEM no tiene Modify') }
if ($SystemWDAC) { [void]$Block.Add('SYSTEM ya tiene WRITE_DAC') }
if (-not $Protected -or -not $Canonical) { [void]$Block.Add('DACL no protegida o no canónica') }
if (-not $OwnerCurrent) { [void]$Block.Add('el propietario no es el usuario actual') }
if ($SystemDeny -or $BroadDeny -or $AnyDeny) { [void]$Block.Add('hay ACE de denegación en la DACL; se requiere revisión manual') }
if (-not $IsDefaultHome) { [void]$Block.Add('CODEX_HOME es personalizado') }
if ($HomeReparse -or $BinReparse) { [void]$Block.Add('se detectó un junction/reparse point') }
if ($Processes.Count -gt 0) { [void]$Block.Add('Codex/ChatGPT sigue abierto') }
if (-not $IsAdmin) { [void]$Block.Add('PowerShell no está elevado; no se solicitará UAC') }

$Repair = 'BLOQUEADA; SOLO DIAGNÓSTICO'
$RepairDetail = ''
if ($Block.Count -eq 0) {
    AddLine '## Reparación propuesta'
    AddLine '- El estado coincide con SYSTEM:Modify sin WRITE_DAC en la .sandbox-bin estándar.'
    AddLine '- Se propone añadir únicamente SYSTEM:WRITE_DAC a esa carpeta; no se concede Full Control ni permisos heredables.'
    AddLine '- Es un workaround puntual reportado, no una reparación oficial universal. #60057 y #60192 documentan casos donde la recuperación fue incompleta o temporal.'
    $Confirm = Read-Host 'Para aplicar SOLO SYSTEM:WRITE_DAC en .sandbox-bin, escribe REPARAR. Cualquier otra respuesta cancela'
    if ($Confirm -ceq 'REPARAR') {
        try {
            $SDDL = $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
            [IO.File]::WriteAllText($BackupPath,$SDDL,[Text.UTF8Encoding]::new($false))
            $Icacls = Join-Path $env:WINDIR 'System32\icacls.exe'
            $Native = @(& $Icacls $Bin '/grant' '*S-1-5-18:(WDAC)' 2>&1 | ForEach-Object { [string]$_ })
            $Exit = $LASTEXITCODE
            foreach ($N in $Native) { AddLine "- icacls: $(SafeText $N)" }
            $After = Get-Acl -LiteralPath $Bin
            $AfterHasWDAC = $false
            foreach ($R in $After.Access) {
                if ((GetSid $R.IdentityReference) -eq 'S-1-5-18' -and $R.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and (HasFlag ([Security.AccessControl.FileSystemRights]$R.FileSystemRights) ([Security.AccessControl.FileSystemRights]::ChangePermissions))) { $AfterHasWDAC = $true }
            }
            if ($Exit -eq 0 -and $AfterHasWDAC) { $Repair = 'APLICADA Y VERIFICADA EN ACL'; $RepairDetail = 'SYSTEM:WRITE_DAC aparece en la ACL posterior.' }
            else { $Repair = 'NO VERIFICADA'; $RepairDetail = "icacls exit=$Exit; no se confirmó la ACE posterior. No se hicieron más cambios." }
        } catch { $Repair = 'ERROR'; $RepairDetail = SafeText $_.Exception.Message }
    } else { $Repair = 'CANCELADA'; $RepairDetail = 'No se modificó la ACL.' }
} else {
    $RepairDetail = 'No se aplicó ningún cambio: ' + ($Block -join '; ')
    foreach ($Reason in $Block) { AddLine "- Reparación bloqueada: $Reason" }
}

AddLine '## Resultado'
AddLine "- Reparación: $Repair"
AddLine "- Detalle: $RepairDetail"
AddLine "- Backup ACL SDDL: $(if (Test-Path -LiteralPath $BackupPath) { [IO.Path]::GetFileName($BackupPath) } else { 'no creado' })"
AddLine '- No se reinició Codex/Windows, no se repitió el asistente UAC y no se ejecutó ningún comando en el sandbox.'
AddLine '- No se leyó .sandbox-secrets ni se subió ningún diagnóstico.'
AddLine '- Esta corrección no confirma que la versión instalada incluya PR #59745 ni soluciona errores WFP/SID u otros bloqueos posteriores.'
AddLine '- Si el error persiste, no concedas Full Control, no cambies el propietario, no habilites herencia y no borres/renombres carpetas.'
AddLine ''
AddLine 'Referencias: https://github.com/openai/codex/pull/59745 | https://github.com/openai/codex/issues/59038 | https://github.com/openai/codex/issues/60057 | https://github.com/openai/codex/issues/60192'
[IO.File]::WriteAllText($ReportPath,($Report -join [Environment]::NewLine),[Text.UTF8Encoding]::new($false))

Write-Host "Diagnóstico guardado: $ReportPath" -ForegroundColor Green
Write-Host "Estado de reparación: $Repair" -ForegroundColor Yellow
if (Test-Path -LiteralPath $BackupPath) { Write-Host "Copia ACL: $BackupPath" -ForegroundColor Green }
Write-Host 'No se modificó ninguna otra ACL ni configuración.'
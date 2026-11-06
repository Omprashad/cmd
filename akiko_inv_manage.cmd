@echo off
setlocal
set "INV_SOURCE=%~f0"
if /i "%~1"=="collect" set "INV_MODE=collect"
if /i "%~1"=="uninstall" set "INV_MODE=uninstall"
if not defined INV_MODE set "INV_MODE=install"
if /i "%INV_MODE%"=="collect" goto run
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%INV_SOURCE%' -ArgumentList '%INV_MODE%' -Verb RunAs"
    exit /b
)
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$r=[IO.File]::ReadAllText($env:INV_SOURCE);$p=[regex]::Split($r,'(?m)^::INVENTORY_PAYLOAD\r?\n',2);if($p.Count -lt 2){Write-Error 'Marker missing';exit 2};$t=Join-Path $env:TEMP ('inv_'+[guid]::NewGuid().ToString('N')+'.ps1');[IO.File]::WriteAllText($t,$p[1],[Text.UTF8Encoding]::new($false));try{if($env:INV_MODE -eq 'collect'){& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $t -Mode collect}else{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $t -Mode $env:INV_MODE}}finally{Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue}"
set "RC=%errorlevel%"
if /i not "%INV_MODE%"=="collect" pause
exit /b %RC%
::INVENTORY_PAYLOAD
param([string]$Mode = '')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CFG = @{
    WebAppUrl        = 'https://script.google.com/macros/s/AKfycbxD-r3YwRQ-BLqhExVylf1XsKVIe1wHaf6VQlzYFh6jXus224dPFn_ogTBJMui70mCPTw/exec'
    Token            = '588a66c8-dee2-48f0-b8fe-5089fab7fee5af0063f6-7257-405c-b037-21839e31f740'
    HomeUrl          = 'https://sites.google.com/view/akikoglobal/home'
    InstallDir       = 'C:\ProgramData\CompanyInventory'
    TaskName         = 'CompanyInventoryStandalone'
    CacheDir         = Join-Path $env:LOCALAPPDATA 'CompanyInventoryStandalone'
    RosterMaxAgeDays = 30
    OpenHomeDaily    = $true
    OnlineTimeoutSec = 6
}

if (-not $Mode) {
    if ($env:INV_MODE) { $Mode = $env:INV_MODE.ToLowerInvariant() }
    elseif ($Source -and $Source.StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase)) { $Mode = 'collect' }
    else { $Mode = 'install' }
}
$Source = if ($env:INV_SOURCE) { $env:INV_SOURCE } else { $PSCommandPath }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Mode -eq 'install' -and -not $isAdmin) { throw 'Install requires administrator privileges.' }
if ($Mode -eq 'uninstall' -and -not $isAdmin) { throw 'Uninstall requires administrator privileges.' }

$script:warnings = New-Object 'System.Collections.Generic.List[string]'
function Warn($m){ Write-Host $m -ForegroundColor Yellow; $script:warnings.Add($m) | Out-Null }
function Info($m){ Write-Host $m -ForegroundColor Cyan }
function Good($m){ Write-Host $m -ForegroundColor Green }

function Invoke-WebApi {
    param($Body, [int]$Timeout = 60)
    $Body.token = $CFG.Token
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Uri $CFG.WebAppUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $Timeout -MaximumRedirection 10
}

# ===== DPAPI-backed local cache =====
Add-Type -AssemblyName System.Security
function Protect-Local([byte[]]$data){
    return [System.Security.Cryptography.ProtectedData]::Protect($data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}
function Unprotect-Local([byte[]]$data){
    return [System.Security.Cryptography.ProtectedData]::Unprotect($data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}
function Save-RosterCache {
    param([string[]]$Hashes, [string]$Pepper, [string]$At)
    New-Item -ItemType Directory -Force -Path $CFG.CacheDir | Out-Null
    $obj = @{ version = 1; at = $At; pepper = $Pepper; hashes = $Hashes }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 4 -Compress))
    [IO.File]::WriteAllBytes((Join-Path $CFG.CacheDir 'roster.bin'), (Protect-Local $bytes))
}
function Read-RosterCache {
    $p = Join-Path $CFG.CacheDir 'roster.bin'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $bytes = Unprotect-Local ([IO.File]::ReadAllBytes($p))
        $obj = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        if (-not $obj.hashes -or -not $obj.pepper) { return $null }
        return $obj
    } catch { return $null }
}
function Get-RosterHash {
    param([string]$Code, [string]$Dob, [string]$Pepper)
    $h = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $h.Key = [Text.Encoding]::UTF8.GetBytes($Pepper)
        $b = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Code + '|' + $Dob))
        return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $h.Dispose() }
}
function Save-Pending {
    param($Payload)
    $dir = Join-Path $CFG.CacheDir 'Pending'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $json = $Payload | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    [IO.File]::WriteAllBytes((Join-Path $dir ($Payload.eventId + '.bin')), (Protect-Local $bytes))
}
function Send-Pending {
    $dir = Join-Path $CFG.CacheDir 'Pending'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.bin' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -First 20)
    foreach ($f in $files) {
        try {
            $bytes = Unprotect-Local ([IO.File]::ReadAllBytes($f.FullName))
            $payload = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            Send-Payload -Payload $payload | Out-Null
            Remove-Item -LiteralPath $f.FullName -Force
            Good ('Uploaded queued check-in: ' + $payload.eventId)
        } catch {
            Warn ('Queued check-in still pending: ' + $_.Exception.Message)
            break
        }
    }
}
# ====================================

function Test-Credential {
    param([string]$Code, [string]$Dob)
    try {
        $r = Invoke-WebApi -Body @{action='validate'; employeeCode=$Code; dob=$Dob} -Timeout $CFG.OnlineTimeoutSec
        if ($r.ok -ne $true) { return @{ Ok=$false; Online=$true; Message=('Server: ' + $r.error) } }
        if ($r.valid -ne $true) { return @{ Ok=$false; Online=$true; Message='Employee ID / DOB not in the active list.' } }
        if ($r.roster -and $r.pepper) {
            Save-RosterCache -Hashes $r.roster -Pepper $r.pepper -At $r.rosterAt
        }
        return @{ Ok=$true; Online=$true; Message='' }
    } catch {
        $cache = Read-RosterCache
        if (-not $cache) {
            return @{ Ok=$false; Online=$false; Message='No network and no local cache. Connect to the internet once to activate this PC.' }
        }
        try {
            $age = ([DateTime]::UtcNow - [DateTime]::Parse($cache.at)).TotalDays
        } catch { $age = 9999 }
        if ($age -gt $CFG.RosterMaxAgeDays) {
            return @{ Ok=$false; Online=$false; Message=('Offline cache is ' + [math]::Round($age,0) + ' days old (limit ' + $CFG.RosterMaxAgeDays + '). Connect to the internet.') }
        }
        $h = Get-RosterHash -Code $Code -Dob $Dob -Pepper $cache.pepper
        if (@($cache.hashes) -contains $h) { return @{ Ok=$true; Online=$false; Message='' } }
        return @{ Ok=$false; Online=$false; Message='ID / DOB not in the local cache. Connect to the internet or contact IT.' }
    }
}

function Get-ValidatedEmployeeLocked {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" WindowState="Maximized" Topmost="True"
        ResizeMode="NoResize" ShowInTaskbar="False" Background="#0B1E2E"
        FocusManager.FocusedElement="{Binding ElementName=TxtCode}">
  <Grid Margin="40">
    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
      <TextBlock Text="COMPANY SYSTEM INVENTORY" Foreground="#7FC8F8" FontSize="42" FontWeight="Bold" HorizontalAlignment="Center"/>
      <TextBlock Text="Enter your Employee ID and Date of Birth to continue. This window will not close until both are correct." Foreground="#B8D8F0" FontSize="18" Margin="0,25,0,0" TextWrapping="Wrap" MaxWidth="900" TextAlignment="Center"/>
      <TextBlock Text="EMPLOYEE ID" Foreground="#7FC8F8" FontSize="20" FontWeight="Bold" Margin="0,40,0,8" HorizontalAlignment="Center"/>
      <TextBox Name="TxtCode" FontSize="32" Width="420" Padding="12" MaxLength="40" HorizontalContentAlignment="Center" CharacterCasing="Upper"/>
      <TextBlock Text="DATE OF BIRTH (DDMMYYYY)" Foreground="#7FC8F8" FontSize="20" FontWeight="Bold" Margin="0,25,0,8" HorizontalAlignment="Center"/>
      <TextBox Name="TxtDob" FontSize="32" Width="420" Padding="12" MaxLength="12" HorizontalContentAlignment="Center"/>
      <Button Name="Ok" Content="Validate" Width="260" Height="64" Margin="0,35,0,0" FontSize="22"/>
      <TextBlock Name="Err" Foreground="#FF6B6B" FontSize="18" Margin="0,25,0,0" HorizontalAlignment="Center" TextWrapping="Wrap" MaxWidth="900" TextAlignment="Center"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $TxtCode = $w.FindName('TxtCode'); $TxtDob = $w.FindName('TxtDob')
    $Ok = $w.FindName('Ok'); $Err = $w.FindName('Err')
    $script:_allowClose = $false; $script:_code = $null; $script:_dob = $null

    $Timer = New-Object System.Windows.Threading.DispatcherTimer
    $Timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Timer.Add_Tick({
        if ($script:_allowClose) { return }
        try {
            if (-not $w.Topmost) { $w.Topmost = $true }
            if ($w.WindowState -ne 'Maximized') { $w.WindowState = 'Maximized' }
            if (-not $w.IsActive) { $w.Activate() | Out-Null }
        } catch {}
    })
    $Timer.Start()

    $w.Add_Closing({ param($s,$e) if (-not $script:_allowClose) { $e.Cancel = $true } })
    $w.Add_StateChanged({ if ($w.WindowState -ne 'Maximized') { $w.WindowState = 'Maximized' } })
    $w.Add_Deactivated({ try { $w.Topmost = $false; $w.Topmost = $true; if (-not $script:_allowClose) { $w.Activate() | Out-Null } } catch {} })
    $w.Add_PreviewKeyDown({
        param($s,$e)
        if ($e.Key -eq 'Escape') { $e.Handled = $true; return }
        if ($e.Key -eq 'F4' -and [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) { $e.Handled = $true; return }
    })

    $doValidate = {
        $Err.Foreground = '#FF6B6B'; $Err.Text = ''
        $code = $TxtCode.Text.Trim().ToUpperInvariant()
        $dob = ($TxtDob.Text -replace '[^0-9]', '')
        if ($code -notmatch '^[A-Z0-9_-]{2,40}$') { $Err.Text = 'Employee ID format invalid.'; return }
        if ($dob -notmatch '^\d{8}$') { $Err.Text = 'DOB must be 8 digits (DDMMYYYY).'; return }
        $Ok.IsEnabled = $false; $Ok.Content = 'Validating...'
        $r = Test-Credential -Code $code -Dob $dob
        if ($r.Ok) {
            $script:_code = $code; $script:_dob = $dob
            $script:_allowClose = $true; $Timer.Stop(); $w.Close()
        } else {
            $Err.Text = $r.Message
            $Ok.IsEnabled = $true; $Ok.Content = 'Validate'
        }
    }
    $Ok.Add_Click($doValidate)
    $TxtCode.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Return') { $TxtDob.Focus() | Out-Null } })
    $TxtDob.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Return') { & $doValidate } })
    $w.ShowDialog() | Out-Null
    if ($script:_code) { return @{ Code=$script:_code; Dob=$script:_dob } }
    return $null
}

function Read-Cim($class) { try { @(Get-CimInstance -ClassName $class -ErrorAction Stop) } catch { $script:warnings.Add($class + ': ' + $_.Exception.Message) | Out-Null; @() } }
function Bound-Json($items, $label) {
    $arr = @($items)
    while ($arr.Count -gt 0 -and (ConvertTo-Json -InputObject $arr -Depth 8 -Compress).Length -gt 40000) {
        $script:warnings.Add($label + ': truncated') | Out-Null
        if ($arr.Count -eq 1) { $arr = @() } else { $arr = @($arr[0..($arr.Count-2)]) }
    }
    return ,$arr
}

if (-not ('WSqlite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WSqlite {
  [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_open(string f, out IntPtr db);
  [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_close(IntPtr db);
  [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_prepare_v2(IntPtr db, string sql, int n, out IntPtr st, IntPtr tail);
  [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_step(IntPtr st);
  [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr sqlite3_column_text(IntPtr st, int i);
  [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)] public static extern long sqlite3_column_int64(IntPtr st, int i);
  [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int sqlite3_finalize(IntPtr st);
}
'@
}

function Get-ChromiumHistoryRows {
    param([string]$Root, [DateTime]$Cutoff)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Root)) { return $out }
    $profiles = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'History') })
    foreach ($p in $profiles) {
        $hist = Join-Path $p.FullName 'History'
        $tmp = Join-Path $env:TEMP ('hist_' + [guid]::NewGuid().ToString('N') + '.db')
        try {
            Copy-Item -LiteralPath $hist -Destination $tmp -Force -ErrorAction Stop
            foreach ($sfx in @('-wal','-shm')) { $s = $hist + $sfx; if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination ($tmp + $sfx) -Force -ErrorAction SilentlyContinue } }
        } catch { continue }
        $db = [IntPtr]::Zero
        try {
            if (([WSqlite]::sqlite3_open($tmp, [ref]$db)) -ne 0) { continue }
            $st = [IntPtr]::Zero
            $sql = "SELECT u.url, v.visit_time FROM visits v JOIN urls u ON v.url = u.id WHERE v.visit_time > 0"
            if (([WSqlite]::sqlite3_prepare_v2($db, $sql, -1, [ref]$st, [IntPtr]::Zero)) -ne 0) { continue }
            try {
                while (([WSqlite]::sqlite3_step($st)) -eq 100) {
                    $ptr = [WSqlite]::sqlite3_column_text($st, 0)
                    if ($ptr -eq [IntPtr]::Zero) { continue }
                    $url = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($ptr)
                    $vt = [WSqlite]::sqlite3_column_int64($st, 1)
                    if ($vt -le 0) { continue }
                    $dt = $null
                    try { $dt = [DateTime]::FromFileTimeUtc([long]($vt * 10)) } catch { continue }
                    if ($dt -lt $Cutoff) { continue }
                    $out.Add([pscustomobject]@{ Url = $url; When = $dt }) | Out-Null
                }
            } finally { [WSqlite]::sqlite3_finalize($st) | Out-Null }
        } finally {
            if ($db -ne [IntPtr]::Zero) { [WSqlite]::sqlite3_close($db) | Out-Null }
            foreach ($f in @($tmp, $tmp+'-wal', $tmp+'-shm')) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
    return $out
}

function Get-BrowserActivity {
    $since = [DateTime]::UtcNow.AddDays(-7)
    $all = New-Object System.Collections.Generic.List[object]
    try { Get-ChromiumHistoryRows -Root (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') -Cutoff $since | ForEach-Object { $all.Add($_) } } catch { $script:warnings.Add('Chrome: ' + $_.Exception.Message) | Out-Null }
    try { Get-ChromiumHistoryRows -Root (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') -Cutoff $since | ForEach-Object { $all.Add($_) } } catch { $script:warnings.Add('Edge: ' + $_.Exception.Message) | Out-Null }
    $groups = @{}
    foreach ($row in $all) {
        $u = $null
        if (-not [Uri]::TryCreate($row.Url, [UriKind]::Absolute, [ref]$u)) { continue }
        $h = $u.Host.ToLowerInvariant(); if (-not $h) { continue }
        $k = "$h|$($row.When.ToString('yyyy-MM-dd'))"
        if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.Generic.List[datetime] }
        $groups[$k].Add($row.When) | Out-Null
    }
    $byDay = New-Object System.Collections.Generic.List[object]
    foreach ($k in $groups.Keys) {
        $parts = $k.Split('|'); $times = @($groups[$k] | Sort-Object)
        if ($times.Count -eq 0) { continue }
        $active = 0.0
        for ($i = 1; $i -lt $times.Count; $i++) { $g = ($times[$i] - $times[$i-1]).TotalMinutes; if ($g -gt 0 -and $g -le 30) { $active += $g } }
        $byDay.Add([pscustomobject]@{ host=$parts[0]; day=$parts[1]; visits=$times.Count; activeMinutes=[math]::Round($active,0); spanMinutes=[math]::Round(($times[-1]-$times[0]).TotalMinutes,0); first=$times[0].ToString('o'); last=$times[-1].ToString('o') }) | Out-Null
    }
    $byDay = @($byDay | Sort-Object -Property activeMinutes -Descending | Select-Object -First 150)
    $hostMap = @{}
    foreach ($r in $byDay) {
        if (-not $hostMap.ContainsKey($r.host)) { $hostMap[$r.host] = [pscustomobject]@{ host=$r.host; visits=0; activeMinutes=0; days=0 } }
        $hostMap[$r.host].visits += $r.visits; $hostMap[$r.host].activeMinutes += $r.activeMinutes; $hostMap[$r.host].days += 1
    }
    $byHost = @($hostMap.Values | Sort-Object -Property activeMinutes -Descending | Select-Object -First 60)
    return @{ period = @{ from=$since.ToString('o'); to=[DateTime]::UtcNow.ToString('o') }; byHost = (Bound-Json $byHost 'Hosts'); byDay = (Bound-Json $byDay 'Days') }
}

function Get-InventoryPayload {
    param([string]$Employee, [string]$Dob)
    $product = Read-Cim 'Win32_ComputerSystemProduct' | Select-Object -First 1
    $uuid = ([string]$product.UUID).Trim().ToUpperInvariant()
    if ($uuid -notmatch '^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$' -or $uuid -match '^[0-]+$' -or $uuid -match '^[F-]+$') { throw 'Hardware UUID missing or invalid.' }
    $cs = Read-Cim 'Win32_ComputerSystem' | Select-Object -First 1
    $bios = Read-Cim 'Win32_BIOS' | Select-Object -First 1
    $os = Read-Cim 'Win32_OperatingSystem' | Select-Object -First 1
    $cpu = @(Read-Cim 'Win32_Processor' | ForEach-Object { $_.Name }) -join '; '
    $disks = @(Read-Cim 'Win32_DiskDrive' | Select-Object Model,SerialNumber,InterfaceType,@{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}})
    $volumes = @(Read-Cim 'Win32_LogicalDisk' | Where-Object { $_.DriveType -eq 3 } | Select-Object DeviceID,FileSystem,@{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}},@{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}})
    $network = @(Read-Cim 'Win32_NetworkAdapterConfiguration' | Where-Object { $_.IPEnabled } | Select-Object Description,MACAddress,IPAddress,DefaultIPGateway,DHCPEnabled)
    $devices = @()
    try { $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Class -in @('Mouse','Keyboard','MEDIA','AudioEndpoint','Monitor','Battery','HIDClass') } | ForEach-Object {
        $serial = ''
        try { $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_SerialNumber' -ErrorAction Stop; $serial = [string]$p.Data } catch {}
        [pscustomobject]@{ class=$_.Class; name=$_.FriendlyName; status=[string]$_.Status; instanceId=$_.InstanceId; reportedSerial=$serial }
    }) } catch { $script:warnings.Add('PnP: ' + $_.Exception.Message) | Out-Null }
    $software = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Select-Object DisplayName,DisplayVersion,Publisher | Sort-Object DisplayName,DisplayVersion -Unique)
    $shares = @()
    try { $shares = @(Get-CimInstance Win32_Share -ErrorAction Stop | Select-Object Name,Path,Description,@{n='Kind';e={ switch ($_.Type) { 0 {'Disk'} 1 {'Print'} 2 {'Device'} 3 {'IPC'} 2147483648 {'Admin Disk'} 2147483649 {'Admin Print'} default {'Other'} } }}) } catch { $script:warnings.Add('Shares: ' + $_.Exception.Message) | Out-Null }
    $accounts = @()
    try { $accounts = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction Stop | Select-Object Name,Domain,SID,Disabled,Lockout) } catch { $script:warnings.Add('Accounts: ' + $_.Exception.Message) | Out-Null }
    $profiles = @(Read-Cim 'Win32_UserProfile' | Where-Object { !$_.Special } | Select-Object SID,LocalPath,Loaded)
    $accounts = Bound-Json $accounts 'Accounts'; $profiles = Bound-Json $profiles 'Profiles'
    $users = @{ localAccounts=$accounts; profiles=$profiles; consoleUser=$cs.UserName }
    if ((($users | ConvertTo-Json -Depth 6 -Compress).Length -gt 40000)) { $users = @{ localAccounts=@($accounts | Select-Object -First 30); profiles=@($profiles | Select-Object -First 30); consoleUser=$cs.UserName }; $script:warnings.Add('Accounts limited') | Out-Null }
    $devices = Bound-Json $devices 'Devices'; $software = Bound-Json $software 'Software'; $shares = Bound-Json $shares 'Shares'
    $licenses = @()
    try {
        $states = @{ 0='Unlicensed'; 1='Licensed'; 2='Initial grace'; 3='Additional grace'; 4='Non-genuine grace'; 5='Notification'; 6='Extended grace' }
        $licenses = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | Select-Object Name,Description,@{n='Status';e={ $states[[int]$_.LicenseStatus] }},PartialProductKey)
    } catch { $script:warnings.Add('Activation: ' + $_.Exception.Message) | Out-Null }
    $bootUtc = ''; if ($os.LastBootUpTime) { $bootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o') }
    $powerEvents = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ID=@(12,13,41,1074,6005,6006,6008); StartTime=(Get-Date).AddDays(-7) } -MaxEvents 301 -ErrorAction Stop)
        if ($events.Count -gt 300) { $script:warnings.Add('Power limited') | Out-Null }
        $allowed = @('Microsoft-Windows-Kernel-General:12','Microsoft-Windows-Kernel-General:13','Microsoft-Windows-Kernel-Power:41','User32:1074','EventLog:6005','EventLog:6006','EventLog:6008')
        $powerEvents = @($events | Where-Object { ($_.ProviderName + ':' + $_.Id) -in $allowed } | Select-Object -First 300 | ForEach-Object { [pscustomobject]@{ at=$_.TimeCreated.ToUniversalTime().ToString('o'); id=$_.Id; provider=$_.ProviderName; record=[string]$_.RecordId } })
    } catch { $script:warnings.Add('Power: ' + $_.Exception.Message) | Out-Null }
    $externalIp = ''
    try { $externalIp = [string](Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 10).ip } catch { }
    $browserActivity = @{}
    try { $browserActivity = Get-BrowserActivity } catch { $script:warnings.Add('Browser: ' + $_.Exception.Message) | Out-Null }
    return @{
        action = 'inventory'; eventId = [guid]::NewGuid().ToString(); collectedAt = [DateTime]::UtcNow.ToString('o')
        uuid = $uuid; biosSerial = ([string]$bios.SerialNumber).Trim(); employeeCode = $Employee; dob = $Dob
        computerName = $env:COMPUTERNAME; windowsUser = ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        manufacturer = $cs.Manufacturer; model = $cs.Model; os = $os.Caption; osVersion = $os.Version
        cpu = $cpu; ramGB = [math]::Round($cs.TotalPhysicalMemory/1GB, 2)
        disks = @{ physical=$disks; volumes=$volumes }; network = $network; externalIp = $externalIp
        peripherals = $devices; software = $software; shares = $shares; browserActivity = $browserActivity
        users = $users; licenses = $licenses; bootUtc = $bootUtc; powerEvents = $powerEvents
        warnings = @($script:warnings | Select-Object -Unique)
    }
}

function Send-Payload { param($Payload) $r = Invoke-WebApi -Body $Payload -Timeout 90; if ($r.ok -ne $true) { throw ('Server: ' + $r.error) }; return $r }

# ===== Wallpaper =====
if (-not ('CompanyWallpaper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CompanyWallpaper {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
}
function Normalize-ImageUrl([string]$u) {
    if ($u -match '^https?://(www\.)?github\.com/([^/]+)/([^/]+)/blob/([^?#]+)') {
        return "https://raw.githubusercontent.com/$($Matches[2])/$($Matches[3])/$($Matches[4])"
    }
    return $u
}
function Test-ImageMagic([byte[]]$b) {
    if ($b.Length -lt 12) { return $false }
    if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return $true }          # JPEG
    if ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return $true } # PNG
    if ($b[0] -eq 0x42 -and $b[1] -eq 0x4D) { return $true }                               # BMP
    if ($b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46) { return $true }          # GIF
    return $false
}
function Set-WallpaperForCurrentUser {
    param([string]$Url)
    $url = Normalize-ImageUrl $Url
    if ($url -notmatch '^https://') { throw 'Wallpaper URL must start with https://' }
    $tmp = Join-Path $env:TEMP ('wp_' + [guid]::NewGuid().ToString('N') + '.bin')
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 60 -UserAgent 'Mozilla/5.0'
        $bytes = [IO.File]::ReadAllBytes($tmp)
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if (-not (Test-ImageMagic $bytes)) {
        $preview = [Text.Encoding]::UTF8.GetString($bytes[0..([Math]::Min(200, $bytes.Length-1))])
        throw ('URL did not return an image (first bytes: ' + ($preview -replace '\s+', ' ') + '). Use a direct image URL, not a GitHub blob page.')
    }
    $dir = Join-Path $env:LOCALAPPDATA 'CompanyInventoryStandalone'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ext = [IO.Path]::GetExtension(([Uri]$url).AbsolutePath)
    if (-not $ext -or $ext.Length -gt 5) { $ext = '.jpg' }
    $img = Join-Path $dir ('wallpaper' + $ext)
    [IO.File]::WriteAllBytes($img, $bytes)
    Add-Type -AssemblyName System.Drawing
    $ms = New-Object IO.MemoryStream(,$bytes)
    try {
        $probe = [System.Drawing.Image]::FromStream($ms)
        $probe.Dispose()
    } catch {
        throw ('Downloaded file is not a decodable image: ' + $_.Exception.Message)
    } finally { $ms.Dispose() }
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value '0'
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper      -Value $img
    $rc = [CompanyWallpaper]::SystemParametersInfo(20, 0, $img, 3)
    if ($rc -eq 0) { throw 'SystemParametersInfo failed (policy may block wallpaper changes)' }
}

function Invoke-PendingCommands {
    param([string]$Uuid, [string]$Employee, [string]$Dob)
    try {
        $r = Invoke-WebApi -Body @{ action='getCommands'; uuid=$Uuid; employeeCode=$Employee; dob=$Dob } -Timeout 30
        if ($r.ok -ne $true) { return }
        foreach ($c in @($r.commands)) {
            if (-not $c) { continue }
            $status = 'Failed'; $msg = ''
            try {
                switch ([string]$c.command) {
                    'SetWallpaper' {
                        Set-WallpaperForCurrentUser -Url ([string]$c.argument)
                        $status = 'Done'; $msg = 'Wallpaper applied'
                    }
                    default { $msg = 'Unsupported command: ' + $c.command }
                }
            } catch { $msg = $_.Exception.Message }
            try {
                Invoke-WebApi -Body @{
                    action='commandResult'; commandId=[string]$c.commandId;
                    uuid=$Uuid; employeeCode=$Employee; dob=$Dob;
                    status=$status; message=$msg
                } -Timeout 30 | Out-Null
            } catch {}
        }
    } catch {}
}
# ====================================

function Open-HomePage {
    param([switch]$OncePerDay)
    $url = $CFG.HomeUrl; if (-not $url) { return }
    if ($OncePerDay) {
        $flag = Join-Path $CFG.CacheDir 'lastHome.txt'
        $today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        if ((Test-Path $flag) -and ((Get-Content $flag -Raw).Trim() -eq $today)) { return }
        New-Item -ItemType Directory -Force -Path (Split-Path $flag) | Out-Null
        Set-Content -LiteralPath $flag -Value $today -Encoding ASCII
    }
    $chromePaths = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe','HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
        try { $v = (Get-Item $k -ErrorAction Stop).GetValue(''); if ($v) { $chromePaths += ([string]$v).Trim('"') } } catch {}
    }
    $chrome = $chromePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    try { if ($chrome) { Start-Process -FilePath $chrome -ArgumentList $url } else { Start-Process $url } }
    catch { try { Start-Process $url } catch { Warn 'Browser launch failed: ' + $url } }
}

function Invoke-CollectOnce {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $result = Get-ValidatedEmployeeLocked
        if (-not $result) { return }
        try {
            $payload = Get-InventoryPayload -Employee $result.Code -Dob $result.Dob
        } catch { Warn ('Collection failed: ' + $_.Exception.Message); return }

        $sent = $false
        try {
            Send-Payload -Payload $payload | Out-Null
            $sent = $true
            Good ('Inventory submitted. UUID: ' + $payload.uuid)
        } catch {
            if ($_.Exception.Message -match 'active list') {
                Remove-Item -LiteralPath (Join-Path $CFG.CacheDir 'roster.bin') -Force -ErrorAction SilentlyContinue
                Warn 'Server rejected the credential (roster changed). Cache cleared; please re-enter.'
                continue
            }
            Save-Pending -Payload $payload
            Warn ('Offline: check-in saved locally and will upload on next online logon.')
        }

        if ($sent) {
            Send-Pending
            try { Invoke-PendingCommands -Uuid $payload.uuid -Employee $result.Code -Dob $result.Dob } catch {}
        }
        if ($CFG.OpenHomeDaily) { Open-HomePage -OncePerDay }
        return
    }
}

function Write-AkikoCommand {
    param([string]$Dir)
    $body = @"
@echo off
if /i "%~1"=="hide" (
    attrib +h +s "$Dir\CompanyInventory.cmd" 2>nul
    attrib +h +s "$Dir\Agent.ps1" 2>nul
    attrib +h +s "$Dir\akiko.cmd" 2>nul
    echo Hidden again.
    exit /b 0
)
echo.
echo   CompanyInventory Agent
echo   ======================
echo   Folder: $Dir
echo   Files:  CompanyInventory.cmd, Agent.ps1 (both hidden)
echo   Task:   $CFG.TaskName  (runs hidden at every logon)
echo.
attrib -h -s "$Dir\CompanyInventory.cmd" 2>nul
attrib -h -s "$Dir\Agent.ps1" 2>nul
attrib -h -s "$Dir\akiko.cmd" 2>nul
echo   Attributes cleared. Files now visible in Explorer.
echo   To hide again: akiko hide
echo.
"@
    $path = Join-Path $Dir 'akiko.cmd'
    [IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($false))
    return $path
}

function Install-Agent {
    Info 'Installing CompanyInventory...'
    $self = $Source
    if (-not $self -or -not (Test-Path -LiteralPath $self)) { throw 'Cannot find source .cmd.' }
    if (-not $self.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase)) { throw 'Install must run from the .cmd file.' }

    $dir = $CFG.InstallDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cmdDest = Join-Path $dir 'CompanyInventory.cmd'
    if ((Resolve-Path -LiteralPath $self).Path -ne (Resolve-Path -LiteralPath $cmdDest -ErrorAction SilentlyContinue).Path) {
        Copy-Item -LiteralPath $self -Destination $cmdDest -Force
    }
    $cmdContent = [IO.File]::ReadAllText($cmdDest)
    $parts = [regex]::Split($cmdContent, '(?m)^::INVENTORY_PAYLOAD\r?\n', 2)
    if ($parts.Count -lt 2) { throw 'Marker not found in .cmd' }
    $agentPath = Join-Path $dir 'Agent.ps1'
    [IO.File]::WriteAllText($agentPath, $parts[1], [Text.UTF8Encoding]::new($false))
    $akikoPath = Write-AkikoCommand -Dir $dir

    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn 'ACL restriction incomplete.' }
    & attrib.exe +h +s $cmdDest 2>$null
    & attrib.exe +h +s $agentPath 2>$null
    & attrib.exe +h +s $akikoPath 2>$null

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$dir*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$dir", 'Machine')
        Info 'Install dir added to system PATH (active after next sign-in).'
    }

    $existing = Get-ScheduledTask -TaskName $CFG.TaskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $CFG.TaskName -Confirm:$false }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $agentPath + '" -Mode collect') -WorkingDirectory $dir
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(20)) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $CFG.TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Company inventory agent.' -Force | Out-Null
    Good 'Scheduled task registered (hidden PowerShell, runs for every user at logon).'
    Info 'Reveal command: akiko  (available in cmd after next sign-in)'

    Info 'Running first inventory collection...'
    Invoke-CollectOnce
    Good 'Install complete.'
}

switch ($Mode) {
    'install'   { Install-Agent }
    'collect'   { Invoke-CollectOnce }
    'uninstall' {
        Unregister-ScheduledTask -TaskName $CFG.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($machinePath -like "*$($CFG.InstallDir)*") {
            $newPath = ($machinePath -split ';' | Where-Object { $_ -and $_ -ne $CFG.InstallDir }) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
        }
        foreach ($f in @('CompanyInventory.cmd','Agent.ps1','akiko.cmd')) {
            & attrib.exe -h -s -r (Join-Path $CFG.InstallDir $f) 2>$null
        }
        Remove-Item -LiteralPath $CFG.InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Good 'Uninstalled.'
    }
    default { Write-Host ('Unknown mode: ' + $Mode); exit 2 }
}

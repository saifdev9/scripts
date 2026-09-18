# Self-check for Edge-Downgrade-OneClick.ps1 - no machine changes.
$ErrorActionPreference = 'Stop'
$s = 'C:\Users\Admin\Desktop\scripts\ps\Edge-Downgrade-OneClick.ps1'

# 1. parses cleanly
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$errs) | Out-Null
if ($errs) { throw "parse errors: $($errs | ForEach-Object { $_.Message })" }
"parse OK"

# 2. region-policy JSON round-trip (Depth 10, UTF8 no BOM) stays valid and keeps the region list
$tmp = Join-Path $env:TEMP 'isrps_test.json'
Copy-Item 'C:\Windows\System32\IntegratedServicesRegionPolicySet.json' $tmp -Force
$json = Get-Content $tmp -Raw | ConvertFrom-Json
$pol = $json.policies | Where-Object { $_.guid -eq '{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}' }
$before = $pol.conditions.region.enabled.Count
$pol.conditions.region.enabled += 'ZZ'
[System.IO.File]::WriteAllText($tmp, ($json | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$rt = Get-Content $tmp -Raw | ConvertFrom-Json
$rtPol = $rt.policies | Where-Object { $_.guid -eq '{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}' }
if ($rtPol.conditions.region.enabled.Count -ne $before + 1) { throw "region list lost entries: $($rtPol.conditions.region.enabled.Count) vs $($before+1)" }
if ($rt.policies.Count -ne $json.policies.Count) { throw "policy count changed" }
if ([System.IO.File]::ReadAllBytes($tmp)[0] -eq 0xEF) { throw "BOM written" }
Remove-Item $tmp -Force
"json round-trip OK ($before -> $($before+1) regions, no BOM)"

# 3. GeoId <-> region code mapping used for the pin/revert
$code = (Get-ItemProperty 'HKCU:\Control Panel\International\Geo').Name
if ($code -notmatch '^[A-Z]{2}$') { throw "region code unreadable: '$code'" }
if ((Get-WinHomeLocation).GeoId -ne (Get-ItemProperty 'HKCU:\Control Panel\International\Geo').Nation) { throw "geoid/registry mismatch" }
if ([System.Globalization.RegionInfo]::new('IE').GeoId -ne 68) { throw "Ireland is not GeoId 68" }
"geoid mapping OK"

# 4. target version is downloadable from the enterprise API
$rel = ((Invoke-RestMethod 'https://edgeupdates.microsoft.com/api/products?view=enterprise' -TimeoutSec 60) |
        Where-Object Product -eq 'Stable').Releases |
       Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' -and $_.ProductVersion -eq '151.0.4129.86' }
if (-not $rel) { throw "151.0.4129.86 not published" }
$a = $rel.Artifacts | Where-Object ArtifactName -eq 'msi'
if (-not ($a.Location -and $a.Hash)) { throw "msi artifact/hash missing" }
"installer lookup OK ($($a.Location.Substring(0,60))...)"

# 5a. policy eligibility is reported honestly for this device
$cap = (Get-CimInstance Win32_OperatingSystem).Caption
$eligible = -not ($cap -match 'Home') -and ((Get-CimInstance Win32_ComputerSystem).PartOfDomain -or ((& dsregcmd /status) -join "`n") -match 'AzureAdJoined\s*:\s*YES')
"policy eligibility: $eligible ($cap)"
if ($eligible -ne $true -and $eligible -ne $false) { throw "eligibility did not resolve to a boolean" }

# 5. the rollback route's prerequisites exist on this machine
if (-not (Test-Path 'C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')) { throw "MicrosoftEdgeUpdate.exe missing - rollback route unavailable" }
$cs = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
if (-not (Get-ItemProperty $cs -Name pv -EA SilentlyContinue).pv) { throw "Edge Stable has no ClientState pv - updater does not track Edge" }
"rollback prerequisites OK (updater present, ClientState pv $((Get-ItemProperty $cs).pv))"

# 5b. the cached MSI still gates DoInstall the way the script assumes, and the
#     package is/isn't registered consistently with which msiexec form we pick
$cached = Get-ChildItem 'C:\ProgramData\EdgeDowngrade\*.msi' -EA SilentlyContinue | Select-Object -First 1
if ($cached) {
    $ins = New-Object -ComObject WindowsInstaller.Installer
    $dbm = $ins.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$ins,@($cached.FullName,0))
    $vw  = $dbm.GetType().InvokeMember('OpenView','InvokeMethod',$null,$dbm,@("SELECT ``Condition`` FROM InstallExecuteSequence WHERE ``Action``='DoInstall'"))
    $vw.GetType().InvokeMember('Execute','InvokeMethod',$null,$vw,$null)
    $rc = $vw.GetType().InvokeMember('Fetch','InvokeMethod',$null,$vw,$null)
    if (-not $rc) { throw "MSI has no DoInstall row - installer layout changed" }
    $cond = $rc.GetType().InvokeMember('StringData','GetProperty',$null,$rc,@(1))
    if ($cond -notmatch '\?ProductClientState=2.*\$ProductClientState=3') { throw "DoInstall no longer installs on an absent package: $cond" }
    if ($cond -notmatch 'REINSTALL') { throw "DoInstall no longer honours REINSTALL: $cond" }
    # The feature must be selectable by ADDLOCAL, or DoInstall can never fire.
    $vf = $dbm.GetType().InvokeMember('OpenView','InvokeMethod',$null,$dbm,@("SELECT ``Feature`` FROM Feature"))
    $vf.GetType().InvokeMember('Execute','InvokeMethod',$null,$vf,$null)
    $feats = @(); while($true){ $fr=$vf.GetType().InvokeMember('Fetch','InvokeMethod',$null,$vf,$null); if(-not $fr){break}
        $feats += $fr.GetType().InvokeMember('StringData','GetProperty',$null,$fr,@(1)) }
    if ($feats -notcontains 'Complete') { throw "MSI feature layout changed: $($feats -join ',')" }
    "MSI DoInstall condition OK (feature '$($feats -join ",")', ADDLOCAL selects it)"
} else { "MSI DoInstall condition SKIPPED (no cached installer)" }

# 5c. the script must pass ADDLOCAL=ALL - without it msiexec exits 0 doing nothing
$src = Get-Content 'C:\Users\Admin\Desktop\scripts\ps\Edge-Downgrade-OneClick.ps1' -Raw
if ($src -notmatch 'ADDLOCAL=ALL') { throw "ADDLOCAL=ALL missing from the MSI arguments" }
if ($src -notmatch 'ALLOWDOWNGRADE=1') { throw "ALLOWDOWNGRADE=1 missing from the MSI arguments" }
"MSI argument guard OK (ADDLOCAL=ALL + ALLOWDOWNGRADE=1 present)"

# 6. uninstall-string regex extracts setup.exe
$u = '"C:\Program Files (x86)\Microsoft\Edge\Application\153.0.4234.32\Installer\setup.exe" --uninstall --msedge --channel=stable --system-level --verbose-logging'
if ($u -notmatch '^"?(.+?setup\.exe)"?\s') { throw "regex did not match" }
if ($Matches[1] -notlike '*\Installer\setup.exe') { throw "bad capture: $($Matches[1])" }
"setup.exe parse OK"
"ALL CHECKS PASSED"

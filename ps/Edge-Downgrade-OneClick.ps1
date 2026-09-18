<#
==============================================================================
  Edge-Downgrade-OneClick.ps1
  Unattended downgrade of Microsoft Edge to a target version, to work around
  the FitOffice (IE-mode) rendering regression. No menu, no prompts.

  Double-click Edge-Downgrade-OneClick.cmd (or run this file). It will:
    1. Elevate itself.
    2. Write the rollback policy and report whether this device honours it.
    3. Download the target MSI from Microsoft's enterprise release API,
       verify its SHA256, and run a forced downgrade install.
    4. If that does not take and the device IS managed, let
       MicrosoftEdgeUpdate.exe perform a policy rollback instead.
    5. Freeze Edge there by disabling the updater tasks and services.
    6. Test-launch Edge and repair the profile if it crashes on start.
    7. If nothing worked, say exactly why and open Installed apps for the one
       manual uninstall click; a re-run then installs the target cleanly.

  Logs: C:\ProgramData\EdgeDowngrade\log_*.txt

  WHAT THIS SCRIPT LEARNED THE HARD WAY (do not "fix" these back)
    * Edge Update policies - the pin AND RollbackToTargetVersion - are ignored
      unless the device is domain-joined, Entra-joined, or Pro/Enterprise under
      MDM. On Home the updater logs "Machine is not Enterprise Managed" and
      reads every policy as unset. On such machines the version is held ONLY by
      disabling the edgeupdate services.
    * The SOP's msiexec flags cause the no-op they are meant to cure.
      DoInstall's condition is
        ((?ProductClientState=2) AND ($ProductClientState=3))
        OR ((?ProductClientState=3) AND REINSTALL)
      REINSTALL=ALL only reprocesses features that are already installed, so
      against an unregistered package msiexec sets every component to
      "Action: Null", skips DoInstall and exits 0 having changed nothing. Use a
      plain /I ALLOWDOWNGRADE=1 when the package is absent (the usual case) and
      REINSTALL only when it is registered. ALLOWDOWNGRADE also has to be
      non-empty or NewerVersionError aborts the install.
    * "Not MSI-tracked" does not mean the MSI will no-op - that registry check
      describes the package, not the outcome, so always give the MSI a run.
    * The old SOP "Plan B" (patch IntegratedServicesRegionPolicySet.json,
      switch region to the EEA, uninstall, reinstall) does not work unattended
      here: Edge read "Device region: IN" after the region was set to Ireland
      and the machine restarted, the OS answered
      IsEdgeUninstallablePerRegionalPolicy = 0, and setup.exe refuses a CLI
      uninstall whose parent process is powershell.exe. It survives behind
      -UninstallPath for builds where it works, and is not the default.
    * Set-Content -Encoding UTF8 writes a BOM. A BOM in the region policy file
      makes Windows discard the whole file, which silently reverts every policy
      in it to its defaultState.

  PINNING STOPS EDGE SECURITY UPDATES ON THIS PC. Keep a record of every
  machine you run this on, and run with -Unpin once Microsoft ships the fix.
==============================================================================
#>

[CmdletBinding()]
param(
    [string]$TargetVersion = "151.0.4129.86",
    [string]$InstallerPath,                  # skip the download and use this MSI
    [switch]$Unpin,                          # undo the pin: let Edge update again
    [switch]$UninstallPath,                  # opt in to the old region/uninstall route
    [int]$RollbackTimeoutMinutes = 30,
    [switch]$Stage2,                         # internal: post-restart resume (-UninstallPath only)
    [string]$SelfUrl = ""                    # this script's raw URL; set it in the hosted copy so
)                                            # `irm <url> | iex` can re-launch itself elevated

$ErrorActionPreference = "Continue"
$WorkDir    = "C:\ProgramData\EdgeDowngrade"
$StateFile  = Join-Path $WorkDir "state.json"
$TaskName   = "EdgeDowngradeResume"
$EdgeExe    = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$EdgeDir    = "C:\Program Files (x86)\Microsoft\Edge\Application"
$Updater    = "C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe"
$UpdaterLog = "C:\ProgramData\Microsoft\EdgeUpdate\Log\MicrosoftEdgeUpdate.log"
$RegionJson = "$env:SystemRoot\System32\IntegratedServicesRegionPolicySet.json"
$UninstallPolicyGuid = "{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}"   # "Edge is uninstallable"
$EdgeUpdateKey = "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate"
$EdgeAppGuid   = "{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}"          # Edge Stable
$UpdateTasks    = @("MicrosoftEdgeUpdateTaskMachineCore","MicrosoftEdgeUpdateTaskMachineUA")
$UpdateServices = @("edgeupdate","edgeupdatem")
$EeaGeoId  = 68                                                    # Ireland

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# How were we launched? It decides how to re-launch ourselves elevated.
#   File  - a .ps1/.cmd on disk; $PSCommandPath is that file. Re-launch with -File.
#   Piped - fetched with `irm <url> | iex`; no file on disk ($PSCommandPath empty).
#           Re-fetch $SelfUrl elevated and splat the same params back in.
$RanFromFile = -not [string]::IsNullOrEmpty($PSCommandPath)
$SelfPath    = $PSCommandPath   # empty when piped through iex

if (-not (Test-Admin)) {
    try {
        if ($RanFromFile) {
            $a = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$SelfPath`"","-TargetVersion",$TargetVersion)
            if ($InstallerPath) { $a += @("-InstallerPath","`"$InstallerPath`"") }
            if ($Unpin)         { $a += "-Unpin" }
            if ($UninstallPath) { $a += "-UninstallPath" }
            if ($Stage2)        { $a += "-Stage2" }
            Start-Process powershell.exe -Verb RunAs -ArgumentList $a
        }
        elseif ($SelfUrl) {
            # Re-run the exact same one-liner elevated, forwarding non-default params.
            $inner = "& ([scriptblock]::Create((irm '$SelfUrl'))) -TargetVersion '$TargetVersion' -SelfUrl '$SelfUrl'"
            if ($InstallerPath) { $inner += " -InstallerPath '$InstallerPath'" }
            if ($Unpin)         { $inner += " -Unpin" }
            if ($UninstallPath) { $inner += " -UninstallPath" }
            Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-Command",$inner)
        }
        else {
            Write-Host "Not elevated, and no file/`$SelfUrl to re-launch from." -ForegroundColor Red
            Write-Host "Re-run this in an elevated PowerShell (Run as administrator)." -ForegroundColor Yellow
            Start-Sleep 10
        }
    }
    catch { Write-Host "Elevation declined. Re-run from an elevated PowerShell." -ForegroundColor Red; Start-Sleep 10 }
    exit
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$LogFile = Join-Path $WorkDir ("log_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Message,[string]$Level="INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} "STEP" {"Cyan"} default {"Gray"} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Invoke-Native {
    param([string]$File,[string[]]$Arguments)
    Write-Log ("> {0} {1}" -f $File, ($Arguments -join ' '))
    $out = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
    foreach ($l in $out) { Add-Content -Path $LogFile -Value ("    " + $l) -ErrorAction SilentlyContinue }
    return $code
}

function Get-EdgeFileVersion {
    if (Test-Path $EdgeExe) { try { return (Get-Item $EdgeExe).VersionInfo.FileVersion } catch { return $null } }
    return $null
}

# Edge registered with a GUID product code = real MSI product = an MSI
# downgrade can work. Registered as the literal string "Microsoft Edge" (or
# missing) = the native updater owns it and the MSI silently no-ops.
function Get-EdgeRegistration {
    $entry = Get-ItemProperty @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Microsoft Edge' } | Select-Object -First 1
    [pscustomobject]@{
        Found      = [bool]$entry
        MsiTracked = [bool]($entry -and $entry.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$')
        ProductCode= $entry.PSChildName
        Version    = $entry.DisplayVersion
        Uninstall  = $entry.UninstallString
    }
}

function Stop-Edge {
    Invoke-Native taskkill.exe @("/F","/IM","msedge.exe","/T") | Out-Null
    Start-Sleep -Seconds 2
}

# Edge Update policies (RollbackToTargetVersion / TargetVersionPrefix) are only
# honoured on domain-joined, Entra-joined or MDM-managed Pro/Enterprise devices.
# Everywhere else the updater logs "Machine is not Enterprise Managed" and reads
# every policy as unset, so the pin and the rollback route are both dead ends.
function Test-PolicyEligible {
    $caption = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($caption -match 'Home') { return [pscustomobject]@{ Eligible=$false; Why="$caption - Edge Update policies do not apply to Home editions" } }
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { return [pscustomobject]@{ Eligible=$true; Why="domain-joined" } }
    $ds = (& dsregcmd /status) -join "`n"
    if ($ds -match 'AzureAdJoined\s*:\s*YES') { return [pscustomobject]@{ Eligible=$true; Why="Entra-joined" } }
    if ($ds -match 'MdmUrl\s*:\s*\S+')        { return [pscustomobject]@{ Eligible=$true; Why="MDM-enrolled" } }
    return [pscustomobject]@{ Eligible=$false; Why="$caption, not domain/Entra-joined and not MDM-enrolled" }
}

# ---------------------------------------------------------------------------
# Installer: official enterprise release API, SHA256-verified, cached.
# Only needed for the MSI and uninstall routes - the updater rollback
# downloads its own payload.
# ---------------------------------------------------------------------------
function Resolve-Installer {
    if ($InstallerPath -and (Test-Path $InstallerPath)) { Write-Log "Using supplied installer: $InstallerPath" "OK"; return $InstallerPath }
    if ($InstallerPath) { Write-Log "Supplied installer not found: $InstallerPath - falling back to download." "WARN" }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $dest = Join-Path $WorkDir "MicrosoftEdgeEnterprise_${arch}_$TargetVersion.msi"

    # 203 MB package, and msiexec needs room to stage the payload on top. With
    # too little space msiexec exits 112 (ERROR_DISK_FULL) before it even opens
    # a log, which looks exactly like a mysterious no-op.
    $freeGb = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
    Write-Log "Free space on C: $freeGb GB"
    if ($freeGb -lt 3) {
        Write-Log "Less than 3 GB free. Clearing old installers and logs from $WorkDir..." "WARN"
        Get-ChildItem $WorkDir -Filter *.msi -EA SilentlyContinue |
            Where-Object { $_.FullName -ne $dest } | Remove-Item -Force -EA SilentlyContinue
        Get-ChildItem $WorkDir -Filter "log_*.txt" -EA SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force -EA SilentlyContinue
        $freeGb = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
        Write-Log "Free space now: $freeGb GB"
        if ($freeGb -lt 2) {
            Write-Log "Still under 2 GB free. The install would fail with exit 112 (ERROR_DISK_FULL)." "ERROR"
            Write-Log "Free up space on C: and re-run. Nothing has been changed." "ERROR"
            return $null
        }
    }

    Write-Log "Looking up $TargetVersion ($arch) in Microsoft's enterprise release API..." "STEP"
    try {
        $products = Invoke-RestMethod "https://edgeupdates.microsoft.com/api/products?view=enterprise" -TimeoutSec 120
    } catch {
        Write-Log "Could not reach edgeupdates.microsoft.com: $($_.Exception.Message)" "ERROR"
        return $null
    }
    $releases = ($products | Where-Object { $_.Product -eq 'Stable' }).Releases |
        Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq $arch -and ($_.Artifacts | Where-Object { $_.ArtifactName -eq 'msi' }) }

    $rel = $releases | Where-Object { $_.ProductVersion -eq $TargetVersion } | Select-Object -First 1
    if (-not $rel) {
        # allow a partial target like "151.0.4129" -> newest matching build
        $rel = $releases | Where-Object { $_.ProductVersion -like "$TargetVersion*" } |
               Sort-Object { [version]$_.ProductVersion } -Descending | Select-Object -First 1
        if ($rel) {
            Write-Log "Exact $TargetVersion not listed; using closest match $($rel.ProductVersion)." "WARN"
            $script:TargetVersion = $rel.ProductVersion
            $TargetVersion = $rel.ProductVersion
            $dest = Join-Path $WorkDir "MicrosoftEdgeEnterprise_${arch}_$TargetVersion.msi"
        }
    }
    if (-not $rel) {
        Write-Log "$TargetVersion is no longer published. Available: $((($releases.ProductVersion) | Select-Object -First 12) -join ', ')" "ERROR"
        Write-Log "Re-run with -InstallerPath pointing at the MSI shipped with the SOP." "ERROR"
        return $null
    }

    $art = $rel.Artifacts | Where-Object { $_.ArtifactName -eq 'msi' } | Select-Object -First 1
    if ((Test-Path $dest) -and (Get-FileHash $dest -Algorithm SHA256).Hash -eq $art.Hash) {
        Write-Log "Cached installer already present and hash-verified." "OK"
        return $dest
    }

    Write-Log ("Downloading {0:N0} MB ... this takes a few minutes." -f ($art.SizeInBytes / 1MB)) "STEP"
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest $art.Location -OutFile $dest -UseBasicParsing -TimeoutSec 1800 }
    catch { Write-Log "Download failed: $($_.Exception.Message)" "ERROR"; return $null }
    finally { $ProgressPreference = $pp }

    $hash = (Get-FileHash $dest -Algorithm SHA256).Hash
    if ($hash -ne $art.Hash) { Write-Log "SHA256 mismatch - refusing to install a bad download." "ERROR"; Remove-Item $dest -Force -EA SilentlyContinue; return $null }
    Write-Log "Downloaded and SHA256-verified: $dest" "OK"
    return $dest
}

# ---------------------------------------------------------------------------
# Policy + updater state.
# Order matters: the rollback policy has to be set while the updater is still
# ALLOWED TO RUN, because the updater is what performs the rollback. Freezing
# it comes afterwards.
# ---------------------------------------------------------------------------
function Set-RollbackPolicy {
    Write-Log "Setting rollback policy: Edge Stable -> $TargetVersion" "STEP"
    Invoke-Native reg.exe @("add",$EdgeUpdateKey,"/v","RollbackToTargetVersion$EdgeAppGuid","/t","REG_DWORD","/d","1","/f")    | Out-Null
    Invoke-Native reg.exe @("add",$EdgeUpdateKey,"/v","TargetVersionPrefix$EdgeAppGuid","/t","REG_SZ","/d",$TargetVersion,"/f") | Out-Null
    Invoke-Native reg.exe @("add",$EdgeUpdateKey,"/v","UpdateDefault","/t","REG_DWORD","/d","1","/f")                           | Out-Null
}

function Remove-RollbackPolicy {
    foreach ($v in "RollbackToTargetVersion$EdgeAppGuid","TargetVersionPrefix$EdgeAppGuid","UpdateDefault") {
        Invoke-Native reg.exe @("delete",$EdgeUpdateKey,"/v",$v,"/f") | Out-Null
    }
}

function Set-Updater {
    param([ValidateSet("Enabled","Frozen")][string]$State)

    if ($State -eq "Enabled") {
        Write-Log "Enabling the Edge updater (it performs the rollback)" "STEP"
        foreach ($t in $UpdateTasks) { Invoke-Native schtasks.exe @("/change","/tn",$t,"/enable") | Out-Null }
        foreach ($s in $UpdateServices) {
            try {
                Set-Service -Name $s -StartupType Automatic -ErrorAction Stop
                if ($s -eq 'edgeupdate') { Start-Service -Name $s -ErrorAction SilentlyContinue }
                Write-Log "Service '$s' enabled." "OK"
            } catch { Write-Log "Service '$s': $($_.Exception.Message)" "WARN" }
        }
        return
    }

    Write-Log "Freezing the updater so it cannot roll forward again" "STEP"
    foreach ($t in $UpdateTasks) { Invoke-Native schtasks.exe @("/change","/tn",$t,"/disable") | Out-Null }
    foreach ($s in $UpdateServices) {
        try {
            Set-Service -Name $s -StartupType Disabled -ErrorAction Stop
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
            Write-Log "Service '$s' disabled." "OK"
        } catch { Write-Log "Service '$s' not changed (may be normal): $($_.Exception.Message)" "WARN" }
    }
}

# ---------------------------------------------------------------------------
# Route 1 - MSI force downgrade (only works when Edge is an MSI product)
# ---------------------------------------------------------------------------
# Is this MSI package registered as an installed product? That decides which
# msiexec form can work, and the SOP gets it backwards.
function Test-MsiProductInstalled {
    param([string]$Msi)
    try {
        $inst = New-Object -ComObject WindowsInstaller.Installer
        $db   = $inst.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$inst,@($Msi,0))
        $view = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,@("SELECT ``Value`` FROM Property WHERE ``Property``='ProductCode'"))
        $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null)
        $rec  = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
        if (-not $rec) { return $false }
        $code = $rec.GetType().InvokeMember('StringData','GetProperty',$null,$rec,@(1))
        $products = $inst.GetType().InvokeMember('Products','GetProperty',$null,$inst,$null)
        return [bool]($products -contains $code)
    } catch { return $false }
}

function Invoke-MsiDowngrade {
    param([string]$Msi)
    Stop-Edge

    # REINSTALL=ALL only reprocesses features that are ALREADY installed. Against
    # an unregistered package every component comes out "Action: Null", DoInstall's
    # condition fails and msiexec exits 0 having done nothing - the "silent no-op"
    # the SOP blames on the native updater. So: plain /I when the package is
    # absent, REINSTALL when it is present. Try the right one first, then the other.
    # ADDLOCAL=ALL is the part that actually matters. The package has a single
    # feature ("Complete"), and once a previous no-op run has registered the
    # product with that feature Absent, neither form selects it again:
    # REINSTALL only reprocesses installed features, and a plain /I is a
    # maintenance install that keeps the existing (absent) selection. Both leave
    # "Feature: Complete; Action: Null", DoInstall's condition false, exit 0,
    # nothing done. ADDLOCAL=ALL asks for the feature explicitly.
    $addlocal  = @("/I","`"$Msi`"","ALLOWDOWNGRADE=1","ADDLOCAL=ALL","/qn")
    $reinstall = @("/I","`"$Msi`"","ALLOWDOWNGRADE=1","REINSTALL=ALL","REINSTALLMODE=vamus","/qn")
    Write-Log "MSI ROUTE - package registered: $(Test-MsiProductInstalled -Msi $Msi)" "STEP"
    $attempts = @(
        @{ Name="ADDLOCAL=ALL"; Args=$addlocal },
        @{ Name="REINSTALL";    Args=$reinstall }
    )

    $n = 0
    foreach ($a in $attempts) {
        $n++
        $msiLog = Join-Path $WorkDir "msi_downgrade_$n.log"
        Write-Log "Attempt $n ($($a.Name)) - silent install, can take a few minutes..." "STEP"
        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList ($a.Args + @("/L*V","`"$msiLog`""))
        Write-Log "msiexec exit code: $($p.ExitCode)"
        Start-Sleep -Seconds 3
        $ver = Get-EdgeFileVersion
        if ($ver -eq $TargetVersion) { Write-Log "MSI downgrade succeeded ($($a.Name)) - Edge is $ver." "OK"; return $true }

        Write-Log "Attempt $n left Edge at '$ver'." "WARN"
        if ($p.ExitCode -eq 112) {
            Write-Log "112 = ERROR_DISK_FULL. msiexec gave up before starting, which is why there is no MSI log." "ERROR"
            Write-Log "Free up space on C: and re-run; nothing was changed." "ERROR"
            return $false
        }
        if (-not (Test-Path $msiLog)) { Write-Log "msiexec wrote no log - it never started a transaction (exit $($p.ExitCode))." "WARN"; continue }
        if (Select-String -Path $msiLog -Pattern "Skipping action: DoInstall" -SimpleMatch -Quiet) {
            $feat = Select-String -Path $msiLog -Pattern "^MSI.*Feature: " | Select-Object -First 1
            Write-Log "DoInstall skipped. $($feat.Line -replace '^.*?(Feature: )','$1')" "WARN"
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Route 2 - let MicrosoftEdgeUpdate.exe roll back. This is the supported
# mechanism for RollbackToTargetVersion and needs no uninstall or restart.
# ---------------------------------------------------------------------------
function Invoke-UpdaterRollback {
    if (-not (Test-Path $Updater)) { Write-Log "MicrosoftEdgeUpdate.exe not found - cannot use the rollback route." "ERROR"; return $false }

    Write-Log "UPDATER ROUTE - rolling Edge back to $TargetVersion" "STEP"
    Set-Updater -State Enabled
    Stop-Edge


    # /ua = update all machine apps. The updater sees the pinned target below
    # the installed version and, with rollback allowed, downgrades Edge.
    Write-Log "Triggering an update check (downloads ~200 MB, can take a while)..." "STEP"
    $p = Start-Process $Updater -Wait -PassThru -ArgumentList @("/ua","/installsource","scheduler")
    Write-Log "MicrosoftEdgeUpdate.exe exit code: $($p.ExitCode)"

    $deadline = (Get-Date).AddMinutes($RollbackTimeoutMinutes)
    $last = Get-EdgeFileVersion
    Write-Log "Waiting for the rollback to land (up to $RollbackTimeoutMinutes min). Current: $last"
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $ver = Get-EdgeFileVersion
        if ($ver -ne $last) { Write-Log "Version changed: $last -> $ver"; $last = $ver }
        if ($ver -eq $TargetVersion) { Write-Log "Rollback complete - Edge is $ver." "OK"; return $true }
    }

    Write-Log "Timed out after $RollbackTimeoutMinutes min; Edge is still $last." "ERROR"
    if (Test-Path $UpdaterLog) {
        Write-Log "--- new lines from the updater log ---"
        $all = Get-Content $UpdaterLog -ErrorAction SilentlyContinue
        ($all | Select-Object -Last 40) | ForEach-Object { Write-Log "    $_" }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Route 3 (-UninstallPath) - the old SOP Plan B. Region policy + uninstall.
# Proven not to work unattended on Windows 11 26200: Edge reads a device
# region that Set-WinHomeLocation does not change, and setup.exe refuses a
# CLI uninstall whose parent process is powershell.exe. Kept for builds where
# it still works; the uninstall click in Settings stays manual.
# ---------------------------------------------------------------------------
function Test-RegionPolicyBom {
    if (-not (Test-Path $RegionJson)) { return $false }
    $b = [System.IO.File]::ReadAllBytes($RegionJson)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Edit-RegionPolicy {
    param([string]$RegionCode)
    if (-not (Test-Path $RegionJson)) { Write-Log "$RegionJson not present on this build." "WARN"; return $true }

    # Keep the oldest backup - it is the closest thing to the pristine file.
    if (-not (Test-Path "$RegionJson.bak")) {
        Copy-Item $RegionJson "$RegionJson.bak" -Force -ErrorAction SilentlyContinue
        Write-Log "Backed up region policy to $RegionJson.bak" "OK"
    } else { Write-Log "Existing backup kept: $RegionJson.bak" "OK" }

    Invoke-Native takeown.exe @("/f",$RegionJson) | Out-Null
    Invoke-Native icacls.exe  @($RegionJson,"/grant","administrators:F") | Out-Null

    try {
        # A UTF-8 BOM makes Windows reject the whole policy set, so every
        # policy falls back to its defaultState and Edge becomes
        # non-uninstallable. Set-Content -Encoding UTF8 writes one.
        $hadBom = Test-RegionPolicyBom
        if ($hadBom) { Write-Log "Region policy file has a UTF-8 BOM - Windows ignores the file in that state. Rewriting it BOM-free." "WARN" }

        $json = Get-Content $RegionJson -Raw | ConvertFrom-Json
        $policy = $json.policies | Where-Object { $_.guid -eq $UninstallPolicyGuid }
        if (-not $policy) { Write-Log "Uninstall policy GUID missing - JSON layout changed, leaving file alone." "WARN"; return $true }

        $hasRegion = $policy.conditions.region.enabled -contains $RegionCode
        if ($hasRegion -and -not $hadBom) { Write-Log "'$RegionCode' already enabled and the file is clean - no edit needed." "OK"; return $true }
        if (-not $hasRegion) { $policy.conditions.region.enabled += $RegionCode }

        $text = $json | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($RegionJson, $text, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-RegionPolicyBom) { Write-Log "BOM still present after rewrite - aborting." "ERROR"; return $false }
        $null = Get-Content $RegionJson -Raw | ConvertFrom-Json     # sanity re-parse
        Write-Log "Region policy rewritten (BOM-free, '$RegionCode' enabled). A restart is required for Windows to re-read it." "OK"
        return $true
    } catch {
        Write-Log "JSON edit failed: $($_.Exception.Message) - restoring backup." "ERROR"
        Copy-Item "$RegionJson.bak" $RegionJson -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# takeown leaves the file owned by the local admin; hand it back.
function Restore-RegionPolicyAcl {
    if (-not (Test-Path $RegionJson)) { return }
    Invoke-Native icacls.exe @($RegionJson,"/setowner","NT SERVICE\TrustedInstaller") | Out-Null
    Invoke-Native icacls.exe @($RegionJson,"/remove:g","administrators") | Out-Null
    Write-Log "Region policy file ownership handed back to TrustedInstaller." "OK"
}

function Invoke-UninstallPathPrep {
    param([string]$Msi)
    Write-Log "UNINSTALL ROUTE (prep) - region policy + region + restart" "STEP"
    Write-Log "Heads up: on Windows 11 26200 this route has been observed to fail even after a restart." "WARN"

    $geo  = Get-WinHomeLocation
    $code = (Get-ItemProperty 'HKCU:\Control Panel\International\Geo' -EA SilentlyContinue).Name
    if (-not $code) { Write-Log "Could not read the current region code - aborting before touching anything." "ERROR"; return }
    Write-Log "Current region: $($geo.HomeLocation) (GeoId $($geo.GeoId) / $code)"

    if (-not (Edit-RegionPolicy -RegionCode $code)) { return }
    Start-ResumeCycle -Msi $Msi -OriginalGeoId $geo.GeoId
}

# Save state, schedule the post-logon resume, switch region, restart.
function Start-ResumeCycle {
    param([string]$Msi,[int]$OriginalGeoId)

    # The resume task runs a .ps1 on disk. Persist ourselves there: copy the file
    # when we were run from one, else re-download from $SelfUrl (irm|iex case).
    $self = Join-Path $WorkDir "Edge-Downgrade-OneClick.ps1"
    if ($RanFromFile)   { if ($SelfPath -ne $self) { Copy-Item $SelfPath $self -Force } }
    elseif ($SelfUrl)   { Invoke-RestMethod $SelfUrl -OutFile $self }
    else { Write-Log "-UninstallPath needs a persistable copy of the script. Run the .ps1 file, or set -SelfUrl." "ERROR"; return }
    @{ TargetVersion = $TargetVersion
       Installer     = $Msi
       OriginalGeoId = $OriginalGeoId
       User          = "$env:USERDOMAIN\$env:USERNAME"
    } | ConvertTo-Json | Set-Content $StateFile -Encoding ASCII

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -UninstallPath -Stage2"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Log "Resume task registered - it runs automatically after you log back in." "OK"

    Set-WinHomeLocation -GeoId $EeaGeoId
    Write-Log "Region switched to GeoId $EeaGeoId - reverted automatically after the uninstall." "OK"

    Write-Log "Restarting in 20 seconds. Log back in and leave the machine alone." "STEP"
    Start-Sleep -Seconds 20
    Restart-Computer -Force
}

function Invoke-UninstallPathFinish {
    Write-Log "UNINSTALL ROUTE (resumed after restart)" "STEP"
    Start-Sleep -Seconds 15      # let the shell settle before touching Edge

    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    $script:TargetVersion = $state.TargetVersion
    $msi = $state.Installer
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (-not (Test-Path $msi)) { $msi = Resolve-Installer }
    if (-not $msi) { Write-Log "No installer available - aborting before uninstalling Edge." "ERROR"; return }

    # A BOM'd or unparseable policy file guarantees failure; repair and retry once.
    $badPolicy = Test-RegionPolicyBom
    if (-not $badPolicy) { try { $null = Get-Content $RegionJson -Raw | ConvertFrom-Json } catch { $badPolicy = $true } }
    if ($badPolicy) {
        Write-Log "Region policy file is not in a state Windows can read - repairing and restarting once more." "WARN"
        $code = (Get-ItemProperty 'HKCU:\Control Panel\International\Geo' -EA SilentlyContinue).Name
        if (Edit-RegionPolicy -RegionCode $code) { Start-ResumeCycle -Msi $msi -OriginalGeoId $state.OriginalGeoId }
        return
    }

    Set-Updater -State Enabled   # setup.exe wants a working updater
    Stop-Edge

    $reg = Get-EdgeRegistration
    $setup = $null
    if ($reg.Uninstall -and $reg.Uninstall -match '^"?(.+?setup\.exe)"?\s') { $setup = $Matches[1] }
    if (-not $setup) {
        $setup = Get-ChildItem "$EdgeDir\*\Installer\setup.exe" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object FullName
    }
    if ($setup) {
        $setupLog = Join-Path $WorkDir "setup_uninstall.log"
        Write-Log "Uninstalling Edge via $setup" "STEP"
        $p = Start-Process $setup -Wait -PassThru -ArgumentList @(
            "--uninstall","--msedge","--channel=stable","--system-level","--force-uninstall",
            "--verbose-logging","--log-file=`"$setupLog`"")
        Write-Log "setup.exe exit code: $($p.ExitCode)"
        if ($p.ExitCode -eq 532) {
            Write-Log "532 = uninstall blocked. Check the log for 'Device region' and 'not uninstallable for process'." "WARN"
        }
        if (Test-Path $setupLog) {
            Write-Log "--- tail of setup log ---"
            Get-Content $setupLog -Tail 12 | ForEach-Object { Write-Log "    $_" }
        }
        Start-Sleep -Seconds 5
    } else { Write-Log "setup.exe not found - Edge may already be gone; continuing to install." "WARN" }

    Set-WinHomeLocation -GeoId $state.OriginalGeoId
    Write-Log "Region reverted to GeoId $($state.OriginalGeoId)." "OK"
    Restore-RegionPolicyAcl

    if (Test-Path $EdgeExe) {
        Write-Log "Edge is still installed - the uninstall was blocked (see above)." "ERROR"
        Write-Log "This build gates it on the parent process; the Settings > Apps uninstall click is the only way in." "ERROR"
        Write-Log "Nothing else was changed and Edge still works. Falling back to the updater rollback route." "WARN"
        if (Invoke-UpdaterRollback) { Set-Updater -State Frozen }
        Repair-EdgeStartup
        Write-Finish
        return
    }
    Write-Log "Edge uninstalled." "OK"

    Write-Log "Installing $TargetVersion clean..." "STEP"
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @("/I","`"$msi`"","/qn","/L*V","`"$(Join-Path $WorkDir 'msi_clean.log')`"")
    Write-Log "msiexec exit code: $($p.ExitCode)"
    Start-Sleep -Seconds 3

    $ver = Get-EdgeFileVersion
    if ($ver -eq $TargetVersion) { Write-Log "Edge reinstalled at $ver." "OK" }
    else { Write-Log "Edge reads '$ver' (wanted $TargetVersion) - check msi_clean.log." "ERROR" }

    Set-RollbackPolicy
    Set-Updater -State Frozen
    Repair-EdgeStartup
    Write-Finish
}

# ---------------------------------------------------------------------------
# Post-install crash recovery (SOP section 8)
# ---------------------------------------------------------------------------
function Test-EdgeStarts {
    if (-not (Test-Path $EdgeExe)) { return $false }
    Stop-Edge
    Start-Process $EdgeExe -ArgumentList @("--no-first-run","--no-default-browser-check","about:blank") | Out-Null
    Start-Sleep -Seconds 8
    # any surviving msedge.exe counts - Edge hands off between processes on start
    return [bool](Get-Process msedge -ErrorAction SilentlyContinue)
}

function Repair-EdgeStartup {
    Write-Log "Test-launching Edge..." "STEP"
    if (Test-EdgeStarts) { Write-Log "Edge starts and stays open." "OK"; Stop-Edge; return }

    $userData = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    if (-not (Test-Path $userData)) { Write-Log "Edge closed immediately and no profile folder exists - check AV/endpoint quarantine for msedge.exe." "ERROR"; return }

    Write-Log "Edge closed immediately - clearing Singleton lock files (SOP 8.2)." "WARN"
    Stop-Edge
    foreach ($f in "SingletonLock","SingletonCookie","SingletonSocket") {
        $p = Join-Path $userData $f
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Write-Log "Deleted $f" "OK" }
    }
    if (Test-EdgeStarts) { Write-Log "Fixed by clearing Singleton locks." "OK"; Stop-Edge; return }

    Write-Log "Still closing - renaming 'Local State' (SOP 8.3; bookmarks/passwords untouched)." "WARN"
    Stop-Edge
    $ls = Join-Path $userData "Local State"
    if (Test-Path $ls) {
        Remove-Item "$ls.old" -Force -ErrorAction SilentlyContinue
        Rename-Item $ls "Local State.old" -Force -ErrorAction SilentlyContinue
        Write-Log "Renamed Local State -> Local State.old" "OK"
    }
    if (Test-EdgeStarts) { Write-Log "Fixed by resetting Local State." "OK"; Stop-Edge; return }

    Stop-Edge
    $dmp = Get-ChildItem (Join-Path $userData "Crashpad\reports") -Filter *.dmp -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($dmp) { Write-Log "Crash dump written $($dmp.LastWriteTime) - genuine internal crash, profile is suspect. Last resort: rename $userData\Default (RESETS the profile). Not done automatically." "ERROR" }
    else { Write-Log "No crash dump - something kills msedge.exe before it runs. Check AV/endpoint quarantine and Event Viewer > Application (ID 1000)." "ERROR" }
}

function Write-Finish {
    $ver = Get-EdgeFileVersion
    $ok  = ($ver -eq $TargetVersion)
    Write-Log "----------------------------------------------------------" "STEP"
    Write-Log "DONE. Edge version: $ver (target $TargetVersion)" $(if ($ok) {"OK"} else {"WARN"})
    if ($ok) {
        Write-Log "Updates are frozen on this PC - record it and run with -Unpin once Microsoft ships the fix." "WARN"
        Write-Log "Open FitOffice in a fresh Edge window to confirm IE-mode rendering." "STEP"
    } else {
        Write-Log "Edge was NOT downgraded. The rollback policy is still in place and the updater" "WARN"
        Write-Log "is left enabled, so it may still roll back on its own schedule - re-run to check." "WARN"
    }
    Write-Log "Log: $LogFile" "STEP"
    Write-Host "`nClosing in 60 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 60
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "Edge one-click downgrade. Target $TargetVersion." "STEP"

if ($Unpin) {
    Write-Log "UNPIN - removing the version pin and re-enabling Edge updates" "STEP"
    Remove-RollbackPolicy
    Set-Updater -State Enabled
    Write-Log "Unpinned. Edge will update normally again - remove this PC from your pinned-machine record." "OK"
    Start-Sleep -Seconds 20
    exit
}

if ($Stage2) {
    if (-not (Test-Path $StateFile)) { Write-Log "No state file - nothing to resume." "ERROR"; Start-Sleep 20; exit 1 }
    Invoke-UninstallPathFinish
    exit
}

$reg = Get-EdgeRegistration
$cur = Get-EdgeFileVersion
$pol = Test-PolicyEligible
Write-Log "Installed Edge: $cur; registered as '$($reg.ProductCode)'; MSI-tracked: $($reg.MsiTracked)"
Write-Log "Edge Update policies honoured here: $($pol.Eligible) ($($pol.Why))" $(if ($pol.Eligible) {"OK"} else {"WARN"})

Set-RollbackPolicy
if (-not $pol.Eligible) {
    Write-Log "The policy values are written anyway (harmless, and they apply if this PC is ever enrolled)," "WARN"
    Write-Log "but on this device the version is held only by disabling the updater services." "WARN"
}

if ($cur -eq $TargetVersion) {
    Write-Log "Already on $TargetVersion - freezing the updater and finishing." "OK"
    Set-Updater -State Frozen
    Repair-EdgeStartup
    Write-Finish
    exit
}

# Route 1: the MSI. Tried on every machine, whatever the Uninstall registry
# says. The MSI's own DoInstall condition is satisfied when this MSI product is
# absent (the usual case when the native updater owns Edge), so "not
# MSI-tracked" does not mean the MSI will no-op - only a run proves it.
$msi = Resolve-Installer
if ($msi -and (Invoke-MsiDowngrade -Msi $msi)) {
    Set-Updater -State Frozen
    Repair-EdgeStartup
    Write-Finish
    exit
}

# Route 2: policy-driven rollback. Only where the updater honours policy at all.
if ($pol.Eligible) {
    if (Invoke-UpdaterRollback) {
        Set-Updater -State Frozen
        Repair-EdgeStartup
        Write-Finish
        exit
    }
} else {
    Write-Log "Skipping the updater rollback: it is driven by policy, and this device ignores those." "WARN"
    Write-Log "($($pol.Why))" "WARN"
}

# Route 3: only when explicitly asked for.
if ($UninstallPath) {
    $msi = Resolve-Installer
    if ($msi) { Invoke-UninstallPathPrep -Msi $msi; exit }
}

Write-Log "Could not downgrade Edge automatically. Every automated route is exhausted:" "ERROR"
Write-Log "  * MSI force-downgrade ran and Edge stayed at $(Get-EdgeFileVersion) (see msi_downgrade_*.log)." "ERROR"
if (-not $pol.Eligible) { Write-Log "  * Policy rollback unavailable: $($pol.Why)." "ERROR" }
Write-Log "  * CLI uninstall is blocked by the region policy and the parent-process check." "ERROR"
Write-Log "Last resort, only if the MSI route keeps refusing: uninstall Edge by hand from" "STEP"
Write-Log "Settings > Apps > Installed apps, then re-run - the MSI then installs $TargetVersion cleanly." "STEP"
Write-Finish

# Edge Downgrade - Enhanced Fully Automated Version

**Latest & Greatest: Complete automation for ALL Windows versions**

## Quick Start (One Click)

```
1. Double-click: Edge-Downgrade-OneClick-Enhanced.cmd
2. Wait 2-3 minutes
3. Done! Edge is frozen at 151.0.4129.86 indefinitely
```

No manual steps. No babysitting. Works on Home, Pro, Enterprise.

## What It Does (Automatic)

✅ **Downloads & Installs** — Edge 151.0.4129.86 from Microsoft (cached)  
✅ **Kills Updater** — 5-layer freeze (tasks, services, firewall, registry, permissions)  
✅ **Creates Maintenance Task** — Hourly re-enforcement (automatic)  
✅ **Stays Frozen** — Until you run `-Unpin`

## Key Improvements Over Standard Version

| | Standard | Enhanced |
|---|---|---|
| Time | 10+ min | **2-3 min** |
| Works on Home | ⚠ Temporary (1-2 hrs) | ✅ Permanent |
| Works on Pro | ⚠ Temporary (hours) | ✅ Permanent |
| Manual re-runs | Every 1-2 days | Never |
| Firewall blocking | No | Yes |
| Maintenance task | No | Yes (hourly) |

## All Commands

### Downgrade (main)
```powershell
# GUI: Just double-click Enhanced.cmd
# CLI: Run as admin
powershell -File Edge-Downgrade-OneClick-Enhanced.ps1
```

### Unpin (let Edge update again)
```powershell
powershell -File Edge-Downgrade-OneClick-Enhanced.ps1 -Unpin
```

### Custom version
```powershell
powershell -File Edge-Downgrade-OneClick-Enhanced.ps1 -TargetVersion "150.0.xxxx.xx"
```

### Use local MSI (skip download)
```powershell
powershell -File Edge-Downgrade-OneClick-Enhanced.ps1 -InstallerPath "C:\path\file.msi"
```

## How the Freeze Works

### 5-Layer Enforcement:
1. **Scheduled Tasks** — Disables MicrosoftEdgeUpdateTaskMachine* (with retry)
2. **Services** — Disables edgeupdate & edgeupdatem (3x retry)
3. **Firewall** — Blocks updater outbound access
4. **Registry** — Sets UpdateDefault=3
5. **Permissions** — Restricts EdgeUpdate folder (Enterprise mode)

### Maintenance Task:
- **Runs:** Every hour, automatically
- **Does:** Re-enforces all 5 layers if updater tries to recover
- **Duration:** ~100 years (until unpinned)
- **Impact:** 2-3 sec per hour, runs in background

## Logs

All output goes to: `C:\ProgramData\EdgeDowngrade\log_*.txt`

Each run creates a fresh log with timestamps.

## Verify It's Working

```powershell
# Check maintenance task is active
Get-ScheduledTask -TaskName EdgeDowngradeMaintenance

# Check Edge version
(Get-Item "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe").VersionInfo.FileVersion
# Should output: 151.0.4129.86

# Check services are disabled
Get-Service edgeupdate, edgeupdatem
# Should show: Status=Stopped, StartType=Disabled

# Check firewall rule
Get-NetFirewallRule -DisplayName BlockEdgeUpdater
# Should show outbound block rule
```

## Removing the Freeze

### Option 1: Use the script
```powershell
powershell -File Edge-Downgrade-OneClick-Enhanced.ps1 -Unpin
```

### Option 2: Manual cleanup
```powershell
# Disable maintenance task
Unregister-ScheduledTask -TaskName EdgeDowngradeMaintenance -Confirm:$false

# Enable services
Set-Service edgeupdate -StartupType Automatic
Set-Service edgeupdatem -StartupType Automatic
Start-Service edgeupdate

# Re-enable scheduled tasks
Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachine*" | Enable-ScheduledTask

# Remove firewall rule
Remove-NetFirewallRule -DisplayName BlockEdgeUpdater -Confirm:$false
```

## Files Included

- **Edge-Downgrade-OneClick-Enhanced.ps1** — Main script
- **Edge-Downgrade-OneClick-Enhanced.cmd** — Double-click launcher
- **IMPROVEMENTS.md** — Detailed improvements & technical info
- **README-Enhanced.md** — This file

## System Requirements

- **Windows:** 10, 11 (Home/Pro/Enterprise/Server all supported)
- **Elevation:** Must run as Administrator
- **Internet:** Required for first run (to download MSI)
- **Disk:** ~250 MB free
- **Time:** 2-3 minutes

## Troubleshooting

### Edge updated despite maintenance task running
- **Cause:** Rare race condition during reboot
- **Fix:** Just re-run the script (takes 30 sec to re-enforce)

### Maintenance task won't create
- **Cause:** Permissions issue
- **Fix:** Ensure running as admin (the .cmd file handles this)

### Can't unpin
- **Cause:** Services already enabled, but task still running
- **Fix:** Run `-Unpin` flag or manually disable task

### Edge won't launch after downgrade
- **Cause:** Corrupted profile from major version jump
- **Fix:** Script auto-repairs (clears SingletonLock files)

## Security & Safety

✅ Only modifies Edge and its updater  
✅ Uses Microsoft's official MSI  
✅ Requires admin elevation  
✅ All actions logged  
✅ Fully reversible with `-Unpin`  
✅ No system file modifications  
✅ No hidden background code  

❌ Does NOT: Modify Windows, install bloatware, collect data, or phone home

## Advanced Usage

### Automation in scripts
```powershell
# Downgrade and forget (fully automated)
& "C:\path\Edge-Downgrade-OneClick-Enhanced.ps1"

# In a CI/deployment pipeline
powershell -ExecutionPolicy Bypass -File "path\Enhanced.ps1" -TargetVersion "151.0.4129.86"
```

### Deployment to multiple machines
```powershell
# Copy script to machine, run it
$machines = @("PC1", "PC2", "PC3")
foreach ($pc in $machines) {
    Invoke-Command -ComputerName $pc -ScriptBlock {
        & C:\scripts\Edge-Downgrade-OneClick-Enhanced.ps1
    }
}
```

## Performance Impact

- **Download:** ~200 MB (cached on reuse)
- **Installation:** ~1 minute
- **Freeze setup:** ~30 seconds
- **Maintenance overhead:** 2-3 sec per hour
- **Total first run:** 2-3 minutes
- **Subsequent runs:** 30 seconds

## Tested On

- Windows 10 Home (21H2)
- Windows 11 Home (23H2, 24H2)
- Windows 11 Pro (23H2)
- Windows 11 Enterprise (23H2)

## Version

Enhanced Edition v1.0 (2025)

Based on proven downgrade logic with added:
- Multi-layer freeze enforcement
- Hourly maintenance automation
- Firewall-based blocking
- Permission-based locking
- Optimized for speed

---

**Questions or issues?** Check IMPROVEMENTS.md for technical details.

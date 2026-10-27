# powershell.exe
# -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\CustomScripts\Sleep\custom_sleep.ps1"

# === Smart Sleep for Streamer (Voicemeeter + OBS) v5.0 ===

# 1. Get physical idle time & Foreground Window
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class IdleChecker {
    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    public static uint GetIdleTimeSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(lii);
        GetLastInputInfo(ref lii);
        return ((uint)Environment.TickCount - lii.dwTime) / 1000;
    }
    
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    public static string GetForegroundProcessName() {
        IntPtr hwnd = GetForegroundWindow();
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try {
            return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.ToLower();
        } catch { return ""; }
    }
}
"@

# === SETTINGS ===
 $targetMinutes = 15          # How many minutes of physical inactivity AND clear state before sleep
 $targetSeconds = $targetMinutes * 60
 $enableLogging = $true       # Set to $false to completely disable log file creation

# Log and State file paths
 $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
 $logFile = Join-Path -Path $scriptDir -ChildPath "sleep_log.txt"
 $stateFile = Join-Path -Path $scriptDir -ChildPath "sleep_state.json"

# Список процессов, которые считаются "просмотром видео", если они на переднем плане
 $mediaProcesses = @("msedge", "chrome", "firefox", "opera", "vlc", "mpc-hc64", "mpc-hc", "potplayermini64", "potplayer")
# ==================

# Logging function
function Write-Log ($message) {
    if ($enableLogging) {
        Add-Content -Path $logFile -Value $message -Encoding UTF8
    }
}

function Reset-SleepState {
    # Очищаем состояние, если появилось любое препятствие
    $state = @{ LastClearTime = $null }
    $state | ConvertTo-Json | Set-Content $stateFile -ErrorAction SilentlyContinue
}

# Загружаем текущее состояние
 $state = @{ LastClearTime = $null }
if (Test-Path $stateFile) {
    try { $state = Get-Content $stateFile -Raw | ConvertFrom-Json } catch {}
}

 $idleSeconds = [IdleChecker]::GetIdleTimeSeconds()
 $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
 $now = Get-Date

# 1. Проверка физического бездействия
if ($idleSeconds -lt $targetSeconds) {
    Reset-SleepState
    Write-Log "[$time] User is active (Idle: $idleSeconds sec). Exiting."
    exit
}

Write-Log "[$time] Idle: $idleSeconds sec. Starting blocker checks..."

# 2. Проверка OBS
if (Get-Process -Name "obs64" -ErrorAction SilentlyContinue) {
    Reset-SleepState
    Write-Log "[$time] CANCEL: OBS is running."
    exit
}

# 3. Проверка powercfg (Process requests)
 $tempFile = "$env:TEMP\pwr_requests.txt"
powercfg -requests | Out-File -FilePath $tempFile -Encoding Unicode
 $requests = Get-Content $tempFile -Encoding Unicode

if ($requests -match "\[PROCESS\]") {
    Reset-SleepState
    Write-Log "[$time] CANCEL: Active [PROCESS] request. Details:"
    Write-Log $requests
    exit
}

# 4. Проверка драйверов
 $driverLines = $requests | Select-String "\[DRIVER\]"
if ($driverLines) {
    $safeDrivers = @("Virtual Audio", "USB Audio") 
    $forceSleep = $true
    $driversToOverride = @()

    foreach ($line in $driverLines) {
        $isWhitelisted = $false
        
        if ($line -notmatch "\(") {
            $isWhitelisted = $true
            if ($line -match "\[DRIVER\]\s+(.+)") {
                $driversToOverride += $matches[1].Trim()
            }
        }
        else {
            foreach ($safe in $safeDrivers) {
                if ($line -like "*$safe*") {
                    $isWhitelisted = $true
                    if ($line -match "\((.+)\)") {
                        $driversToOverride += $matches[1].Trim()
                    }
                    break
                }
            }
        }
        
        if (-not $isWhitelisted) {
            $forceSleep = $false
            Reset-SleepState
            Write-Log "[$time] CANCEL: Unknown hardware driver blocking: $line"
            break
        }
    }

    if (-not $forceSleep) { exit }

    Write-Log "[$time] Safe audio drivers found. Applying override..."
    foreach ($drv in $driversToOverride) {
        Write-Log "[$time] Overriding: $drv"
        powercfg -requestsoverride DRIVER "$drv" SYSTEM
    }
}

# 5. Эвристика активного окна (защита от кривых плееров)
# Если на переднем плане браузер или плеер, предполагаем, что человек смотрит видео
 $fgProcess = [IdleChecker]::GetForegroundProcessName()
if ($mediaProcesses -contains $fgProcess) {
    Reset-SleepState
    Write-Log "[$time] CANCEL: Media application in foreground ($fgProcess). Assuming video playback."
    exit
}

# ==========================================
# 6. ЛОГИКА 15 МИНУТ НЕПРЕРЫВНОГО "ЧИСТОГО" БЕЗДЕЙСТВИЯ
# ==========================================

# Если мы дошли сюда, значит преград НЕТ.
if ([string]::IsNullOrWhiteSpace($state.LastClearTime)) {
    # Записываем время, когда исчезла последняя преграда
    $state.LastClearTime = $now.ToString("o")
    $state | ConvertTo-Json | Set-Content $stateFile -ErrorAction SilentlyContinue
    Write-Log "[$time] No blockers detected. Starting 15-min continuous clear countdown."
    exit
}

# Если преград нет какое-то время, проверяем, прошло ли 15 минут
try {
    $clearTime = [datetime]::Parse($state.LastClearTime)
    $clearMinutes = ($now - $clearTime).TotalMinutes

    if ($clearMinutes -lt $targetMinutes) {
        $remaining = [math]::Round($targetMinutes - $clearMinutes, 1)
        Write-Log "[$time] No blockers, but continuous clear state is only $([math]::Round($clearMinutes, 1)) mins. Need $remaining more. Exiting."
        exit
    }
} catch {
    # Если файл состояния поврежден, начинаем отсчет заново
    Reset-SleepState
    Write-Log "[$time] State file corrupted, resetting."
    exit
}

# ==========================================
# РЕЗУЛЬТАТ: УСЛОВИЯ ВЫПОЛНЕНЫ — УХОД В СОН
# ==========================================
Write-Log "[$time] SUCCESS: 15 mins idle + 15 mins no blockers. Sending PC to sleep!"

# Очищаем файл состояния перед сном
Remove-Item $stateFile -Force -ErrorAction SilentlyContinue

Start-Process -FilePath "rundll32.exe" -ArgumentList "powrprof.dll,SetSuspendState 0,1,0" -WindowStyle Hidden

Start-Sleep -Seconds 3
powercfg -requestsoverride
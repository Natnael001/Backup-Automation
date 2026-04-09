param (
    [string]$ServerNumber = "139"
)

# --------------------------
# Configuration
# --------------------------
$SERVER_NAME = "localhost"
$SQL_USER = "sa"
$SQL_PASSWORD = "123456"

$FINAL_BACKUP_DIR = "C:\BACKUP"
$FINAL_ARCHIVE_DIR = $FINAL_BACKUP_DIR

$MAINTENANCE_PLAN_NAME = "BACKUP.Subplan_1" 

$NETWORK_SHARE = "\\196.191.244.144\daily backup"
$NETWORK_USER = "administrator"
$NETWORK_PASS = "YCPrgjKfR1bI7qkaV9VCpOVqoyQ1XL"
$NETWORK_IP = "196.191.244.144"

# --------------------------
# Log folder Setup
# --------------------------
if ($PSScriptRoot) { $ScriptRoot = $PSScriptRoot } else {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $ScriptRoot) { $ScriptRoot = Get-Location }
}

$LogDir = Join-Path $ScriptRoot "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir "backup_process_server_$ServerNumber.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $LogMessage = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) - $Level - $Message"
    switch ($Level) {
        "ERROR" { Write-Host $LogMessage -ForegroundColor Red }
        "WARNING" { Write-Host $LogMessage -ForegroundColor Yellow }
        default { Write-Host $LogMessage }
    }
    Add-Content -Path $LogFile -Value $LogMessage
}



# --------------------------
# Logic Functions
# --------------------------
function Invoke-SqlMaintenancePlan {
    param(
        [string]$JobName,
        [int]$TimeoutMinutes = 60,
        [int]$IdleSeconds = 120
    )

    # --- Safe pre‑cleanup: move old .bak files to orphaned folder ---
    $orphanDir = Join-Path $FINAL_BACKUP_DIR "orphaned_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $existingBak = Get-ChildItem -Path $FINAL_BACKUP_DIR -Filter "*.bak" -File -ErrorAction SilentlyContinue
    if ($existingBak) {
        New-Item -ItemType Directory -Path $orphanDir -Force | Out-Null
        $existingBak | Move-Item -Destination $orphanDir -Force
        Write-Log "Moved $($existingBak.Count) old .bak file(s) to $orphanDir"
    }

    # --- Delete orphaned folders older than 7 days ---
    $cutoff = (Get-Date).AddDays(-7)
    Get-ChildItem -Path $FINAL_BACKUP_DIR -Directory -Filter "orphaned_*" | Where-Object { $_.CreationTime -lt $cutoff } | Remove-Item -Recurse -Force

    # --- SQL job start ---
    $connString = "Server=$SERVER_NAME;User Id=$SQL_USER;Password=$SQL_PASSWORD;Encrypt=False;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        Write-Log "Starting SQL Maintenance Plan Job: $JobName"
        
        $cmd.CommandText = "EXEC msdb.dbo.sp_start_job @job_name = '$JobName'"
        $cmd.ExecuteNonQuery() | Out-Null

        Write-Log "Job started. Monitoring backup folder: $FINAL_BACKUP_DIR"
        
        $startTime = Get-Date
        $timeoutTime = $startTime.AddMinutes($TimeoutMinutes)
        $lastWriteTime = $null
        $idleTime = 0

        while ((Get-Date) -lt $timeoutTime) {
            # Get all .bak files, sorted by last write time (most recent first)
            $bakFiles = Get-ChildItem -Path $FINAL_BACKUP_DIR -Filter "*.bak" -File | Sort-Object LastWriteTime -Descending
            $currentWriteTime = if ($bakFiles) { $bakFiles[0].LastWriteTime } else { $null }

            if ($currentWriteTime) {
                if ($lastWriteTime -eq $null -or $currentWriteTime -gt $lastWriteTime) {
                    # New or updated file detected
                    $idleTime = 0
                    Write-Log "Detected activity: $($bakFiles.Count) .bak file(s), latest modified at $currentWriteTime"
                } else {
                    # No new modification
                    $idleTime += 5  # loop sleeps 5 seconds
                    if ($idleTime -ge $IdleSeconds) {
                        Write-Log "No file modifications for $IdleSeconds seconds. Job completed."
                        break
                    }
                }
                $lastWriteTime = $currentWriteTime
            } else {
                # No .bak files yet
                Write-Log "No .bak files found yet..."
                $idleTime = 0
            }

            Start-Sleep -Seconds 5
        }

        $finalBakFiles = Get-ChildItem -Path $FINAL_BACKUP_DIR -Filter "*.bak" -File
        if ($finalBakFiles.Count -eq 0) {
            Write-Log "No backup files were created within $TimeoutMinutes minutes." "ERROR"
            return $false
        }

        Write-Log "Backup completed: $($finalBakFiles.Count) .bak file(s) created."
        return $true

    } catch {
        Write-Log "SQL Error: $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        $conn.Close()
    }
}



function Archive-BackupsRar {
    param([string]$SourceDir, [string]$TargetDir)
    
    $bakFiles = Get-ChildItem -Path $SourceDir -Filter "*.bak" -File | Select-Object -ExpandProperty FullName
    if ($bakFiles.Count -eq 0) { return $null }

    $rarName = Join-Path $TargetDir "$((Get-Date).ToString('HH00')).rar"
    $rarCmd = "C:\Program Files\WinRAR\rar.exe" 
    
    # Create a temporary list file to avoid command-line length limits
    $listFile = Join-Path $SourceDir "backup_list.txt"
    $bakFiles | Out-File -FilePath $listFile -Encoding UTF8

    try {
        # The '@' tells WinRAR to read the file list from the text file
        $cmdArgs = @("a", "-ep", "-m1", "`"$rarName`"", "@$listFile")
        $process = Start-Process -FilePath $rarCmd -ArgumentList $cmdArgs -Wait -NoNewWindow -PassThru
        
        # Cleanup the list file
        if (Test-Path $listFile) { Remove-Item $listFile -Force }

        if ($process.ExitCode -eq 0) { return $rarName }
    } catch { 
        if (Test-Path $listFile) { Remove-Item $listFile -Force }
        return $null 
    }
    return $null
}


function Copy-ToNetwork {
    param([string]$LocalPath, [string]$ServerNum)
    $dateStr = (Get-Date).ToString("MM-dd-yyyy")
    $destDir = Join-Path $NETWORK_SHARE "$ServerNum\$dateStr"
    $destPath = Join-Path $destDir (Split-Path $LocalPath -Leaf)
    try {
        net use "`"$NETWORK_SHARE`"" /user:$NETWORK_USER $NETWORK_PASS /persistent:no 2>&1 | Out-Null
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -Path $LocalPath -Destination $destPath -Force
        return (Test-Path $destPath)
    } catch { return $false } finally {
        net use "`"$NETWORK_SHARE`"" /delete 2>&1 | Out-Null
    }
}

# --------------------------
# Main Execution with JSON Report
# --------------------------
$ReportData = [ordered]@{
    "Date"          = (Get-Date).ToString("MM-dd-yyyy")
    "status"        = "failure"
    "message"       = ""
    "archive"       = $null
    "networkcopy"   = "failed"
    "Backup"        = $null
    "server_ip" = $ServerNumber
}

try {
    Write-Log ("=" * 60)
    Write-Log "STARTING BACKUP PROCESS - Server $ServerNumber"
    
    # 1. SQL Job
    if (Invoke-SqlMaintenancePlan -JobName $MAINTENANCE_PLAN_NAME) {
        Write-Log "SQL Maintenance Plan completed successfully."
        
        # 2. Archive
        $archive = Archive-BackupsRar -SourceDir $FINAL_BACKUP_DIR -TargetDir $FINAL_ARCHIVE_DIR
        if ($archive) {
            $ReportData["archive"] = $archive
            Write-Log "Archive created: $archive"
            
            # 3. Cleanup .bak
            Get-ChildItem $FINAL_BACKUP_DIR -Filter "*.bak" | Remove-Item -Force

            # 4. Network Copy
            if (Copy-ToNetwork -LocalPath $archive -ServerNum $ServerNumber) {
                $ReportData["networkcopy"] = "success"
                $ReportData["status"] = "success"
                $ReportData["message"] = "Backup and archive completed successfully."
                $hourStr = (Split-Path $archive -Leaf) -replace '\.rar$', ''
                $ReportData["Backup"] = "$hourStr's Backup archived successfully on $NETWORK_IP"
                
                Remove-Item $archive -Force
                Write-Log "Job Finished: Archive copied to network and local files cleaned."
            } else {
                $ReportData["message"] = "Network copy failed. Archive remains local."
                Write-Log $ReportData["message"] "WARNING"
            }
        } else {
            $ReportData["message"] = "No .bak files found to archive."
            throw $ReportData["message"]
        }
    } else {
        $ReportData["message"] = "SQL Maintenance Plan failed."
        throw $ReportData["message"]
    }

} catch {
    $ReportData["message"] = "CRITICAL ERROR: $($_.Exception.Message)"
    Write-Log $ReportData["message"] "ERROR"
} finally {
    # Generate JSON Report File
    $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $reportFile = Join-Path $LogDir "report_server_${ServerNumber}_${timestamp}.json"
    $ReportData | ConvertTo-Json -Depth 3 | Set-Content -Path $reportFile
    
    Write-Log "Report saved to: $reportFile"
    if ($ReportData["status"] -eq "success") { exit 0 } else { exit 1 }
}
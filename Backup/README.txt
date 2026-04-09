.SYNOPSIS
    SQL Server Backup, Archive, and Network Copy Script
.DESCRIPTION
    This script triggers a SQL Server Maintenance Plan job (e.g., BACKUP.Subplan_1) 
    to perform high‑speed database backups. It then:
      1. Monitors the backup folder (C:\BACKUP) for newly created .bak files.
      2. Detects job completion by tracking file modification times (idle timeout).
      3. Compresses all .bak files into a single .rar archive using WinRAR.
      4. Copies the archive to a configured network share (single destination).
      5. Cleans up local .bak files (after archive) and the .rar (after successful copy).
    All activity is logged, and a JSON report is saved for monitoring (e.g., n8n).
    The script is designed for hourly backups and handles large databases reliably.
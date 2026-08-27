[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,

    [Parameter(Mandatory = $true)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Force) {
    throw '恢复会覆盖清单中的正式文件，请显式指定 -Force。'
}

$resolvedBackupPath = [IO.Path]::GetFullPath($BackupPath)
$manifestPath = Join-Path $resolvedBackupPath 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "找不到备份清单：$manifestPath"
}
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if ($manifest.Toolkit -cne 'codex-openrouter-toolkit' -or
    [int]$manifest.SchemaVersion -ne 1) {
    throw '备份清单不属于受支持的 Codex OpenRouter Toolkit。'
}

foreach ($entry in @($manifest.Files)) {
    $target = [IO.Path]::GetFullPath([string]$entry.Target)
    if (-not $PSCmdlet.ShouldProcess($target, '恢复安装前备份')) {
        continue
    }
    if ([bool]$entry.Existed) {
        $backupFile = [IO.Path]::GetFullPath([string]$entry.BackupFile)
        if (-not $backupFile.StartsWith(
                $resolvedBackupPath + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "备份文件超出备份目录：$backupFile"
        }
        if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
            throw "备份文件缺失：$backupFile"
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $parent -Force)
        }
        Copy-Item -LiteralPath $backupFile -Destination $target -Force
    }
    elseif (Test-Path -LiteralPath $target -PathType Leaf) {
        Remove-Item -LiteralPath $target -Force
    }
}

$profileEntry = @($manifest.Files | Where-Object Name -eq 'profile' | Select-Object -First 1)
if ($profileEntry.Count -eq 1 -and
    (Test-Path -LiteralPath ([string]$profileEntry[0].Target) -PathType Leaf)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        [string]$profileEntry[0].Target,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        throw "恢复后的 PowerShell Profile 有 $($parseErrors.Count) 个语法错误。"
    }
}

[pscustomobject]@{
    Restored = $true
    BackupPath = $resolvedBackupPath
    RestoredFiles = @($manifest.Files).Count
}

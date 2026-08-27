Set-StrictMode -Version Latest

function Test-ToolkitPotentialSecret {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value -cmatch '\Ask-(?:or-)?[A-Za-z0-9._-]{8,}\z'
}

function Test-ToolkitPathEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    return [IO.Path]::GetFullPath($Left).TrimEnd('\', '/') -ceq
        [IO.Path]::GetFullPath($Right).TrimEnd('\', '/') -or
        [IO.Path]::GetFullPath($Left).TrimEnd('\', '/').Equals(
            [IO.Path]::GetFullPath($Right).TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase
        )
}

function Test-ToolkitModelId {
    param(
        [AllowNull()]
        [string]$Value
    )

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value.Length -le 256 -and
        $Value -cmatch '\A[A-Za-z0-9._:@/+~\-]+\z' -and
        -not (Test-ToolkitPotentialSecret -Value $Value)
}

function Assert-ToolkitModelId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [string]$Name = '模型 ID'
    )

    if (-not (Test-ToolkitModelId -Value $Value)) {
        throw "$Name 无效：请检查字符、长度，并确认没有误填 API Key。"
    }
}

function Assert-ToolkitReasoningEffort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [string]$Name = '推理强度'
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 32 -or
        $Value -cnotmatch '\A[A-Za-z0-9._-]+\z' -or
        (Test-ToolkitPotentialSecret -Value $Value)) {
        throw "$Name 无效：请检查字符、长度，并确认没有误填 API Key。"
    }
}

function Test-ToolkitApiKeyFormat {
    param(
        [AllowNull()]
        [string]$Value
    )

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value.Length -le 512 -and
        $Value -cmatch '\Ask-or-[A-Za-z0-9._-]{16,500}\z'
}

function Publish-ToolkitEnvironmentChange {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { return }
    $nativeType = 'CodexOpenRouterToolkit.EnvironmentBroadcast' -as [type]
    if ($null -eq $nativeType) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexOpenRouterToolkit {
    public static class EnvironmentBroadcast {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result);
    }
}
'@
        $nativeType = 'CodexOpenRouterToolkit.EnvironmentBroadcast' -as [type]
    }

    $broadcastResult = [UIntPtr]::Zero
    $sendResult = $nativeType::SendMessageTimeout(
        [IntPtr]0xFFFF,
        0x001A,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        1000,
        [ref]$broadcastResult
    )
    if ($sendResult -eq [IntPtr]::Zero) {
        Write-Warning '环境变量已更新，但 Windows Shell 刷新通知未被全部接收。请重新登录 Windows 后再试。'
    }
}

function ConvertTo-ToolkitTomlString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $builder = [Text.StringBuilder]::new($Value.Length + 8)
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            8 { [void]$builder.Append('\b') }
            9 { [void]$builder.Append('\t') }
            10 { [void]$builder.Append('\n') }
            12 { [void]$builder.Append('\f') }
            13 { [void]$builder.Append('\r') }
            34 { [void]$builder.Append('\"') }
            92 { [void]$builder.Append('\\') }
            default {
                if ([int]$character -lt 0x20 -or [int]$character -eq 0x7F) {
                    [void]$builder.AppendFormat('\u{0:X4}', [int]$character)
                }
                else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Read-ToolkitFileBytesLocked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 100MB
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open(
        $resolvedPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.Length -gt $MaximumBytes) {
            throw "文件超过 $MaximumBytes 字节限制：$resolvedPath"
        }
        if ($stream.Length -gt [int]::MaxValue) {
            throw "文件过大，无法安全读入内存：$resolvedPath"
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $readCount = $stream.Read(
                $bytes,
                $offset,
                $bytes.Length - $offset
            )
            if ($readCount -le 0) { break }
            $offset += $readCount
        }
        if ($offset -ne $bytes.Length -or $stream.Length -ne $bytes.Length) {
            throw "文件读取期间长度发生变化：$resolvedPath"
        }
        return ,$bytes
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ToolkitFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 100MB
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "快照目标必须是普通文件：$resolvedPath"
    }
    $itemBefore = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if (($itemBefore.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "快照目标不能是重解析点：$resolvedPath"
    }
    if ([long]$itemBefore.Length -gt $MaximumBytes) {
        throw "快照目标超过 $MaximumBytes 字节限制：$resolvedPath"
    }
    $aclBefore = if ($IsWindows) {
        Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    }
    else { $null }
    $bytes = Read-ToolkitFileBytesLocked `
        -Path $resolvedPath `
        -MaximumBytes $MaximumBytes
    $itemAfter = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if (($itemAfter.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $itemAfter.CreationTimeUtc -ne $itemBefore.CreationTimeUtc -or
        $itemAfter.LastWriteTimeUtc -ne $itemBefore.LastWriteTimeUtc -or
        $itemAfter.Length -ne $itemBefore.Length -or
        $itemAfter.Length -gt $MaximumBytes -or
        $itemAfter.Length -ne $bytes.LongLength) {
        throw "文件在一致快照期间发生变化：$resolvedPath"
    }
    $aclAfter = if ($IsWindows) {
        Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    }
    else { $null }
    if ($IsWindows -and
        (-not (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $aclBefore `
                -ActualAcl $aclAfter) -or
            -not (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $aclBefore `
                -DestinationAcl $aclAfter))) {
        throw "文件 ACL 在一致快照期间发生变化：$resolvedPath"
    }

    $sha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
    [pscustomobject]@{
        Path = $resolvedPath
        Bytes = $bytes
        Length = [long]$bytes.LongLength
        Sha256 = $sha256
        CreationTimeUtc = [DateTime]$itemAfter.CreationTimeUtc
        LastWriteTimeUtc = [DateTime]$itemAfter.LastWriteTimeUtc
        Acl = $aclAfter
        MaximumBytes = $MaximumBytes
        AclSddl = if ($IsWindows) {
            Get-ToolkitFileAclPolicySddl -Acl $aclAfter
        }
        else { $null }
    }
}

function Test-ToolkitFileMatchesSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    try {
        $maximumBytes = if ($null -ne
            $Snapshot.PSObject.Properties['MaximumBytes']) {
            [long]$Snapshot.MaximumBytes
        }
        elseif ($null -ne $Snapshot.PSObject.Properties['Bytes'] -and
            $null -ne $Snapshot.Bytes) {
            [Math]::Max(1, [long]$Snapshot.Bytes.LongLength)
        }
        else { 100MB }
        $current = Get-ToolkitFileSnapshot `
            -Path $Path `
            -MaximumBytes $maximumBytes
    }
    catch {
        return $false
    }
    if ($current.CreationTimeUtc -ne [DateTime]$Snapshot.CreationTimeUtc -or
        $current.LastWriteTimeUtc -ne [DateTime]$Snapshot.LastWriteTimeUtc -or
        -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            [byte[]]$current.Bytes,
            [byte[]]$Snapshot.Bytes
        )) {
        return $false
    }
    if ($IsWindows -and $null -ne $Snapshot.Acl) {
        return (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $Snapshot.Acl `
                -ActualAcl $current.Acl) -and
            (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $Snapshot.Acl `
                -DestinationAcl $current.Acl)
    }
    return $true
}

function Import-ToolkitPowerShellDataFileLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 25MB,

        [object]$ExpectedSnapshot
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $snapshot = if ($null -ne $ExpectedSnapshot) {
        $ExpectedSnapshot
    }
    else {
        Get-ToolkitFileSnapshot `
            -Path $resolvedPath `
            -MaximumBytes $MaximumBytes
    }
    if ($null -eq $snapshot.PSObject.Properties['Bytes'] -or
        $null -eq $snapshot.Bytes -or
        [long]$snapshot.Bytes.LongLength -gt $MaximumBytes -or
        -not (Test-ToolkitPathEqual `
            -Left ([string]$snapshot.Path) `
            -Right $resolvedPath)) {
        throw "PowerShell 数据文件快照无效或超过 $MaximumBytes 字节限制：$resolvedPath"
    }

    $guardStream = [IO.File]::Open(
        $resolvedPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($guardStream.Length -gt $MaximumBytes -or
            -not (Test-ToolkitFileMatchesSnapshot `
                -Path $resolvedPath `
                -Snapshot $snapshot)) {
            throw "PowerShell 数据文件在锁定解析前发生变化：$resolvedPath"
        }
        $data = Microsoft.PowerShell.Utility\Import-PowerShellDataFile `
            -LiteralPath $resolvedPath `
            -ErrorAction Stop
        if (-not (Test-ToolkitFileMatchesSnapshot `
                -Path $resolvedPath `
                -Snapshot $snapshot)) {
            throw "PowerShell 数据文件在锁定解析期间发生变化：$resolvedPath"
        }
        return [pscustomobject]@{
            Data = $data
            Snapshot = $snapshot
        }
    }
    finally {
        $guardStream.Dispose()
    }
}

function Remove-ToolkitFileIfSnapshotMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "CAS 删除冲突，目标已不存在或不再是普通文件：$resolvedPath"
    }
    $parent = Split-Path -Parent $resolvedPath
    $quarantinePath = Join-Path $parent (
        '.{0}.delete-{1}-{2}' -f
            [IO.Path]::GetFileName($resolvedPath),
            $PID,
            [Guid]::NewGuid().ToString('N')
    )
    [IO.File]::Move($resolvedPath, $quarantinePath)
    $retainQuarantine = $true
    try {
        if (-not (Test-ToolkitFileMatchesSnapshot `
                -Path $quarantinePath `
                -Snapshot $Snapshot)) {
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                [IO.File]::Move($quarantinePath, $resolvedPath)
                $retainQuarantine = $false
            }
            $location = if ($retainQuarantine) {
                "外部候选已隔离保留：$quarantinePath"
            }
            else {
                "外部目标已原位恢复：$resolvedPath"
            }
            throw "CAS 删除冲突，目标已被外部修改。$location"
        }
        if (Test-Path -LiteralPath $resolvedPath) {
            Remove-Item -LiteralPath $quarantinePath -Force -ErrorAction Stop
            $retainQuarantine = $false
            throw "CAS 删除冲突，原路径被外部重新创建，外部对象已保留：$resolvedPath"
        }
        Remove-Item -LiteralPath $quarantinePath -Force -ErrorAction Stop
        $retainQuarantine = $false
    }
    catch {
        if ($retainQuarantine) {
            throw "$($_.Exception.Message) 隔离文件已保留：$quarantinePath"
        }
        throw
    }
}

function Write-ToolkitBytesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [switch]$PreserveLastWriteTime,

        [DateTime]$TargetLastWriteTimeUtc,

        [AllowEmptyCollection()]
        [byte[]]$ExpectedCurrentBytes,

        [object]$ExpectedCurrentAcl,

        [DateTime]$ExpectedCurrentLastWriteTimeUtc,

        [object]$DesiredAcl,

        [switch]$RequireNewTarget,

        [switch]$RequireExistingTarget,

        [switch]$DisableRecovery,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 100MB,

        [switch]$PassThru
    )

    if ($Bytes.LongLength -gt $MaximumBytes) {
        throw "原子写入内容超过 $MaximumBytes 字节限制：$Path"
    }
    if ($PSBoundParameters.ContainsKey('ExpectedCurrentBytes') -and
        $null -ne $ExpectedCurrentBytes -and
        $ExpectedCurrentBytes.LongLength -gt $MaximumBytes) {
        throw "原子写入预期内容超过 $MaximumBytes 字节限制：$Path"
    }

    if ($RequireNewTarget -and $RequireExistingTarget) {
        throw 'RequireNewTarget 与 RequireExistingTarget 不能同时指定。'
    }
    $hasTargetLastWriteTime =
        $PSBoundParameters.ContainsKey('TargetLastWriteTimeUtc')
    if ($PreserveLastWriteTime -and $hasTargetLastWriteTime) {
        throw 'PreserveLastWriteTime 与 TargetLastWriteTimeUtc 不能同时指定。'
    }
    if ($hasTargetLastWriteTime -and
        $TargetLastWriteTimeUtc.Kind -ne [DateTimeKind]::Utc) {
        throw 'TargetLastWriteTimeUtc 必须是 UTC 时间。'
    }
    $hasExpectedCurrentBytes =
        $PSBoundParameters.ContainsKey('ExpectedCurrentBytes')
    $hasExpectedCurrentAcl =
        $PSBoundParameters.ContainsKey('ExpectedCurrentAcl')
    $hasExpectedCurrentLastWriteTime =
        $PSBoundParameters.ContainsKey('ExpectedCurrentLastWriteTimeUtc')
    $hasDesiredAcl = $PSBoundParameters.ContainsKey('DesiredAcl')
    if ($hasExpectedCurrentAcl -and -not $hasExpectedCurrentBytes) {
        throw 'ExpectedCurrentAcl 需要同时指定 ExpectedCurrentBytes。'
    }
    if ($hasExpectedCurrentLastWriteTime -and -not $hasExpectedCurrentBytes) {
        throw 'ExpectedCurrentLastWriteTimeUtc 需要同时指定 ExpectedCurrentBytes。'
    }
    if ($hasExpectedCurrentLastWriteTime -and
        $ExpectedCurrentLastWriteTimeUtc.Kind -ne [DateTimeKind]::Utc) {
        throw 'ExpectedCurrentLastWriteTimeUtc 必须是 UTC 时间。'
    }
    if ($hasDesiredAcl -and -not $IsWindows) {
        throw 'DesiredAcl 仅支持 Windows。'
    }
    if ($hasDesiredAcl) {
        [void](Assert-ToolkitSupportedFileAcl -Acl $DesiredAcl)
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop)
    }

    $targetExisted = Test-Path -LiteralPath $resolvedPath -PathType Leaf
    if ((Test-Path -LiteralPath $resolvedPath) -and -not $targetExisted) {
        throw "原子写入目标必须是普通文件：$resolvedPath"
    }
    if ($RequireNewTarget -and $targetExisted) {
        throw "原子写入目标已被并发创建：$resolvedPath"
    }
    if ($RequireExistingTarget -and -not $targetExisted) {
        throw "原子写入目标在提交前已不存在：$resolvedPath"
    }
    $lastWriteTime = $null
    $targetCreationTime = $null
    $targetInitialBytes = $null
    $targetAcl = $null
    if ($targetExisted) {
        $targetItem = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
        if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "原子写入目标不能是重解析点：$resolvedPath"
        }
        $initialAclBeforeRead = if ($IsWindows) {
            Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
        }
        else { $null }
        $targetInitialBytes = Read-ToolkitFileBytesLocked `
            -Path $resolvedPath `
            -MaximumBytes $MaximumBytes
        $targetItem = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
        $lastWriteTime = $targetItem.LastWriteTimeUtc
        $targetCreationTime = $targetItem.CreationTimeUtc
        if ($IsWindows) {
            $targetAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
            if (-not (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $initialAclBeforeRead `
                    -ActualAcl $targetAcl) -or
                -not (Test-ToolkitEffectiveFileAclEquivalent `
                    -SourceAcl $initialAclBeforeRead `
                    -DestinationAcl $targetAcl)) {
                throw "原子写入目标 ACL 在初始快照期间发生变化：$resolvedPath"
            }
        }
        if ($hasExpectedCurrentBytes -and
            -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $ExpectedCurrentBytes,
                $targetInitialBytes
            )) {
            throw "原子写入 CAS 冲突，目标内容不再符合预期：$resolvedPath"
        }
        if ($hasExpectedCurrentLastWriteTime -and
            $lastWriteTime -ne $ExpectedCurrentLastWriteTimeUtc) {
            throw "原子写入 CAS 冲突，目标 LastWriteTimeUtc 不再符合预期：$resolvedPath"
        }
        if ($IsWindows -and $hasExpectedCurrentAcl -and
            (-not (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $ExpectedCurrentAcl `
                    -ActualAcl $targetAcl) -or
                -not (Test-ToolkitEffectiveFileAclEquivalent `
                    -SourceAcl $ExpectedCurrentAcl `
                    -DestinationAcl $targetAcl))) {
            throw "原子写入 CAS 冲突，目标 ACL 不再符合预期：$resolvedPath"
        }
    }
    elseif ($hasExpectedCurrentBytes) {
        throw "原子写入 CAS 冲突，预期目标已不存在：$resolvedPath"
    }

    $temporaryPath = Join-Path $parent (
        ".{0}.tmp-{1}-{2}" -f
            [IO.Path]::GetFileName($resolvedPath),
            $PID,
            [Guid]::NewGuid().ToString('N')
    )
    $rollbackPath = Join-Path $parent (
        ".{0}.rollback-{1}-{2}" -f
            [IO.Path]::GetFileName($resolvedPath),
            $PID,
            [Guid]::NewGuid().ToString('N')
    )
    $discardPath = Join-Path $parent (
        ".{0}.discard-{1}-{2}" -f
            [IO.Path]::GetFileName($resolvedPath),
            $PID,
            [Guid]::NewGuid().ToString('N')
    )
    $committed = $false
    $retainRollback = $false
    $retainDiscard = $false
    $stagingStream = $null
    $rollbackRecoveryBytes = $null
    $rollbackRecoveryAcl = $null
    $gateAcl = $null
    $gateApplied = $false
    $activeCommittedAcl = $null
    $committedLastWriteTime = $null
    $activeCommittedLastWriteTime = $null
    try {
        $stagingStream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )

        if ($IsWindows) {
            $stagingTemplateAcl = Get-Acl `
                -LiteralPath $temporaryPath `
                -ErrorAction Stop
            $stagingAcl = New-ToolkitPrivateFileAcl `
                -TemplateAcl $stagingTemplateAcl

            # PowerShell 7.4 / .NET 8 rejects path-based ACL writes once the
            # absolute path reaches the legacy MAX_PATH boundary. The file is
            # still held with FileShare.None, so using the extended-length
            # spelling preserves the same exclusive staging-file identity.
            $stagingAclPath = $temporaryPath
            if ($temporaryPath.Length -ge 260 -and
                -not $temporaryPath.StartsWith('\\?\')) {
                if ($temporaryPath.StartsWith('\\')) {
                    $stagingAclPath = '\\?\UNC\' + $temporaryPath.Substring(2)
                }
                else {
                    $stagingAclPath = '\\?\' + $temporaryPath
                }
            }
            Set-Acl `
                -LiteralPath $stagingAclPath `
                -AclObject $stagingAcl `
                -ErrorAction Stop
            $verifiedStagingAcl = Get-Acl `
                -LiteralPath $temporaryPath `
                -ErrorAction Stop
            if (-not (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $stagingAcl `
                    -ActualAcl $verifiedStagingAcl) -or
                -not (Test-ToolkitEffectiveFileAclEquivalent `
                    -SourceAcl $stagingAcl `
                    -DestinationAcl $verifiedStagingAcl)) {
                throw "私有暂存文件 ACL 复读校验失败：$resolvedPath"
            }
        }

        $stagingStream.SetLength(0)
        if ($Bytes.Length -gt 0) {
            $stagingStream.Write($Bytes, 0, $Bytes.Length)
        }
        $stagingStream.Flush($true)
        $stagingStream.Position = 0
        $stagedBytes = [byte[]]::new($Bytes.Length)
        $stagedOffset = 0
        while ($stagedOffset -lt $stagedBytes.Length) {
            $readCount = $stagingStream.Read(
                $stagedBytes,
                $stagedOffset,
                $stagedBytes.Length - $stagedOffset
            )
            if ($readCount -le 0) { break }
            $stagedOffset += $readCount
        }
        if ($stagedOffset -ne $Bytes.Length -or
            $stagingStream.Length -ne $Bytes.Length) {
            throw "暂存文件长度复读校验失败：$resolvedPath"
        }
        $stagedBytesMatch =
            [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $Bytes,
                $stagedBytes
            )
        $stagedBytes = $null
        if (-not $stagedBytesMatch) {
            throw "暂存文件复读校验失败：$resolvedPath"
        }
        $stagingStream.Dispose()
        $stagingStream = $null

        if ($targetExisted) {
            if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                throw "原子写入目标在提交期间已不存在：$resolvedPath"
            }
            $preCommitItem = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
            if (($preCommitItem.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "原子写入目标在提交期间变成重解析点：$resolvedPath"
            }
            $preCommitAclBeforeRead = if ($IsWindows) {
                Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
            }
            else { $null }
            $preCommitBytes = Read-ToolkitFileBytesLocked `
                -Path $resolvedPath `
                -MaximumBytes $MaximumBytes
            $preCommitItem = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
            $preCommitBytesMatch =
                [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                    $targetInitialBytes,
                    $preCommitBytes
                )
            $preCommitBytes = $null
            if ($preCommitItem.CreationTimeUtc -ne $targetCreationTime -or
                $preCommitItem.LastWriteTimeUtc -ne $lastWriteTime -or
                -not $preCommitBytesMatch) {
                throw "原子写入目标在提交前已被外部修改：$resolvedPath"
            }
            if ($IsWindows) {
                $preCommitAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
                if (-not (Test-ToolkitAclPolicyEquivalent `
                        -ExpectedAcl $preCommitAclBeforeRead `
                        -ActualAcl $preCommitAcl) -or
                    -not (Test-ToolkitEffectiveFileAclEquivalent `
                        -SourceAcl $preCommitAclBeforeRead `
                        -DestinationAcl $preCommitAcl) -or
                    -not (Test-ToolkitAclPolicyEquivalent `
                        -ExpectedAcl $targetAcl `
                        -ActualAcl $preCommitAcl) -or
                    -not (Test-ToolkitEffectiveFileAclEquivalent `
                        -SourceAcl $targetAcl `
                        -DestinationAcl $preCommitAcl)) {
                    throw "原子写入目标 ACL 在提交前已被外部修改：$resolvedPath"
                }
                if ($hasDesiredAcl) {
                    $gateAcl = New-ToolkitPrivateFileAcl `
                        -TemplateAcl $preCommitAcl
                    $gateApplied = $true
                    Set-ToolkitFileSystemAclPolicy `
                        -Path $resolvedPath `
                        -ExpectedAcl $gateAcl
                    $gatedAcl = Get-Acl `
                        -LiteralPath $resolvedPath `
                        -ErrorAction Stop
                    if (-not (Test-ToolkitAclPolicyEquivalent `
                            -ExpectedAcl $gateAcl `
                            -ActualAcl $gatedAcl) -or
                        -not (Test-ToolkitEffectiveFileAclEquivalent `
                            -SourceAcl $gateAcl `
                            -DestinationAcl $gatedAcl)) {
                        throw "原子写入私有提交门 ACL 复读校验失败：$resolvedPath"
                    }
                    $gatedBytes = Read-ToolkitFileBytesLocked `
                        -Path $resolvedPath `
                        -MaximumBytes $MaximumBytes
                    $gatedItem = Get-Item `
                        -LiteralPath $resolvedPath `
                        -Force `
                        -ErrorAction Stop
                    $gatedBytesMatch =
                        [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                            $targetInitialBytes,
                            $gatedBytes
                        )
                    $gatedBytes = $null
                    if (($gatedItem.Attributes -band
                            [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        $gatedItem.CreationTimeUtc -ne $targetCreationTime -or
                        $gatedItem.LastWriteTimeUtc -ne $lastWriteTime -or
                        -not $gatedBytesMatch) {
                        throw "原子写入目标在私有提交门建立期间发生变化：$resolvedPath"
                    }
                    $activeCommittedAcl = $gateAcl
                }
                else {
                    $activeCommittedAcl = $targetAcl
                }
            }
            [IO.File]::Replace($temporaryPath, $resolvedPath, $rollbackPath, $false)
            $committed = $true
            if (-not (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
                throw "原子写入未生成原内容快照：$rollbackPath"
            }
            $rollbackRecoveryBytes = Read-ToolkitFileBytesLocked `
                -Path $rollbackPath `
                -MaximumBytes $MaximumBytes
            $rollbackRecoveryBytesMatch =
                [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                    $targetInitialBytes,
                    $rollbackRecoveryBytes
                )
            $rollbackRecoveryBytes = $null
            if (-not $rollbackRecoveryBytesMatch) {
                $retainRollback = $true
                throw "原内容快照与初始内容不一致：$rollbackPath"
            }
            if ($IsWindows -and $activeCommittedAcl) {
                $rollbackRecoveryAcl = Get-Acl `
                    -LiteralPath $rollbackPath `
                    -ErrorAction Stop
                if (-not (Test-ToolkitAclPolicyEquivalent `
                        -ExpectedAcl $activeCommittedAcl `
                        -ActualAcl $rollbackRecoveryAcl) -or
                    -not (Test-ToolkitEffectiveFileAclEquivalent `
                        -SourceAcl $activeCommittedAcl `
                        -DestinationAcl $rollbackRecoveryAcl)) {
                    $retainRollback = $true
                    throw "原内容快照 ACL 与初始策略不一致：$rollbackPath"
                }
            }
        }
        else {
            if (Test-Path -LiteralPath $resolvedPath) {
                throw "原子写入目标在提交期间被并发创建：$resolvedPath"
            }
            [IO.File]::Move($temporaryPath, $resolvedPath)
            $committed = $true
            if ($IsWindows) {
                $activeCommittedAcl = $stagingAcl
            }
        }

        $writtenBytes = Read-ToolkitFileBytesLocked `
            -Path $resolvedPath `
            -MaximumBytes $MaximumBytes
        $writtenBytesMatch =
            [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $Bytes,
                $writtenBytes
            )
        $writtenBytes = $null
        if (-not $writtenBytesMatch) {
            throw "正式文件复读校验失败：$resolvedPath"
        }
        if ($activeCommittedAcl) {
            $writtenAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
            $aclPolicyMatches = Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $activeCommittedAcl `
                -ActualAcl $writtenAcl
            $aclAccessMatches = Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $activeCommittedAcl `
                -DestinationAcl $writtenAcl
            if (-not $aclPolicyMatches -or -not $aclAccessMatches) {
                Set-ToolkitFileSystemAclPolicy `
                    -Path $resolvedPath `
                    -ExpectedAcl $activeCommittedAcl
                $writtenAcl = Get-Acl `
                    -LiteralPath $resolvedPath `
                    -ErrorAction Stop
            }
            if (-not (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $activeCommittedAcl `
                    -ActualAcl $writtenAcl) -or
                -not (Test-ToolkitEffectiveFileAclEquivalent `
                    -SourceAcl $activeCommittedAcl `
                    -DestinationAcl $writtenAcl)) {
                throw "正式文件 ACL 复读校验失败：$resolvedPath"
            }
        }
        elseif ($IsWindows) {
            $writtenAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
            if (-not (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $stagingAcl `
                    -ActualAcl $writtenAcl) -or
                -not (Test-ToolkitEffectiveFileAclEquivalent `
                    -SourceAcl $stagingAcl `
                    -DestinationAcl $writtenAcl)) {
                throw "新建正式文件的私有 ACL 复读校验失败：$resolvedPath"
            }
        }
        $activeCommittedLastWriteTime =
            (Get-Item -LiteralPath $resolvedPath -ErrorAction Stop).
                LastWriteTimeUtc
        $committedLastWriteTime = if ($hasTargetLastWriteTime) {
            $TargetLastWriteTimeUtc
        }
        elseif ($PreserveLastWriteTime -and $null -ne $lastWriteTime) {
            $lastWriteTime
        }
        else {
            $null
        }
        if ($null -ne $committedLastWriteTime) {
            [IO.File]::SetLastWriteTimeUtc(
                $resolvedPath,
                $committedLastWriteTime
            )
            $verifiedLastWriteTime =
                (Get-Item -LiteralPath $resolvedPath -ErrorAction Stop).
                    LastWriteTimeUtc
            $activeCommittedLastWriteTime = $verifiedLastWriteTime
            if ($verifiedLastWriteTime -ne $committedLastWriteTime) {
                throw "正式文件 LastWriteTimeUtc 复读校验失败：$resolvedPath"
            }
        }
        if ($hasDesiredAcl) {
            if (-not $targetExisted) {
                $gateAcl = $stagingAcl
                $gateApplied = $true
            }
            Set-ToolkitFileSystemAclPolicy `
                -Path $resolvedPath `
                -ExpectedAcl $DesiredAcl
            $desiredAclActual = Get-Acl `
                -LiteralPath $resolvedPath `
                -ErrorAction Stop
            if (-not (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $DesiredAcl `
                    -ActualAcl $desiredAclActual) -or
                -not (Test-ToolkitEffectiveFileAclEquivalent `
                    -SourceAcl $DesiredAcl `
                    -DestinationAcl $desiredAclActual)) {
                throw "正式文件目标 ACL 复读校验失败：$resolvedPath"
            }
            $activeCommittedAcl = $DesiredAcl
            $gateApplied = $false
        }
        $committedSnapshot = Get-ToolkitFileSnapshot `
            -Path $resolvedPath `
            -MaximumBytes $MaximumBytes
        if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $Bytes,
                $committedSnapshot.Bytes
            )) {
            throw "正式文件最终快照内容不一致：$resolvedPath"
        }
        if ($null -ne $committedLastWriteTime -and
            $committedSnapshot.LastWriteTimeUtc -ne $committedLastWriteTime) {
            throw "正式文件最终快照时间不一致：$resolvedPath"
        }
        if ($IsWindows -and $null -ne $activeCommittedAcl -and
            (-not (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $activeCommittedAcl `
                    -ActualAcl $committedSnapshot.Acl) -or
                -not (Test-ToolkitEffectiveFileAclEquivalent `
                    -SourceAcl $activeCommittedAcl `
                    -DestinationAcl $committedSnapshot.Acl))) {
            throw "正式文件最终快照 ACL 不一致：$resolvedPath"
        }
        if ($PassThru) { return $committedSnapshot }
    }
    catch {
        $primaryError = $_
        if ($gateApplied) {
            try {
                if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    throw "私有提交门恢复失败，目标已不存在或不再是普通文件：$resolvedPath"
                }
                $gateRecoveryItem = Get-Item `
                    -LiteralPath $resolvedPath `
                    -Force `
                    -ErrorAction Stop
                if (($gateRecoveryItem.Attributes -band
                        [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "私有提交门恢复失败，目标变成重解析点：$resolvedPath"
                }
                $gateRecoveryExpectedBytes = if ($committed) {
                    $Bytes
                }
                else {
                    $targetInitialBytes
                }
                $gateRecoveryBytes = Read-ToolkitFileBytesLocked `
                    -Path $resolvedPath `
                    -MaximumBytes $MaximumBytes
                $gateRecoveryBytesMatch =
                    [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                        $gateRecoveryExpectedBytes,
                        $gateRecoveryBytes
                    )
                $gateRecoveryBytes = $null
                if (-not $gateRecoveryBytesMatch) {
                    throw "私有提交门恢复 CAS 冲突，目标内容已被外部修改：$resolvedPath"
                }
                $gateRecoveryExpectedTime = if ($committed -and
                    $null -ne $activeCommittedLastWriteTime) {
                    $activeCommittedLastWriteTime
                }
                elseif (-not $committed -and $targetExisted) {
                    $lastWriteTime
                }
                else { $null }
                if ($null -ne $gateRecoveryExpectedTime -and
                    $gateRecoveryItem.LastWriteTimeUtc -ne
                        $gateRecoveryExpectedTime) {
                    throw "私有提交门恢复 CAS 冲突，目标时间已被外部修改：$resolvedPath"
                }
                if ($committed) {
                    Set-ToolkitFileSystemAclPolicy `
                        -Path $resolvedPath `
                        -ExpectedAcl $gateAcl
                    $activeCommittedAcl = $gateAcl
                }
                elseif ($targetExisted) {
                    $gateRecoveryAcl = Get-Acl `
                        -LiteralPath $resolvedPath `
                        -ErrorAction Stop
                    $alreadyOriginal =
                        (Test-ToolkitAclPolicyEquivalent `
                            -ExpectedAcl $targetAcl `
                            -ActualAcl $gateRecoveryAcl) -and
                        (Test-ToolkitEffectiveFileAclEquivalent `
                            -SourceAcl $targetAcl `
                            -DestinationAcl $gateRecoveryAcl)
                    if (-not $alreadyOriginal -and
                        (-not (Test-ToolkitAclPolicyEquivalent `
                            -ExpectedAcl $gateAcl `
                            -ActualAcl $gateRecoveryAcl) -or
                            -not (Test-ToolkitEffectiveFileAclEquivalent `
                            -SourceAcl $gateAcl `
                            -DestinationAcl $gateRecoveryAcl))) {
                        Set-ToolkitFileSystemAclPolicy `
                            -Path $resolvedPath `
                            -ExpectedAcl $gateAcl
                    }
                    if (-not $alreadyOriginal) {
                        Set-ToolkitFileSystemAclPolicy `
                            -Path $resolvedPath `
                            -ExpectedAcl $targetAcl
                    }
                    $gateApplied = $false
                }
                else {
                    throw "私有提交门状态无效：$resolvedPath"
                }
            }
            catch {
                throw "$($primaryError.Exception.Message) 私有提交门恢复失败：$($_.Exception.Message)"
            }
        }
        if ($committed -and $DisableRecovery) {
            $retainRollback = $targetExisted
            $snapshotMessage = if ($retainRollback -and
                (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
                "恢复用快照已保留：$rollbackPath"
            }
            else {
                '没有可保留的恢复快照。'
            }
            throw "$($primaryError.Exception.Message) 自动恢复已禁用。$snapshotMessage"
        }
        if ($committed) {
            try {
                if ($targetExisted) {
                    if (-not (Test-Path `
                            -LiteralPath $resolvedPath `
                            -PathType Leaf)) {
                        throw "自动回滚 CAS 冲突，正式目标已不存在或不再是普通文件：$resolvedPath"
                    }
                    $rollbackCandidateBytes = Read-ToolkitFileBytesLocked `
                        -Path $resolvedPath `
                        -MaximumBytes $MaximumBytes
                    $rollbackCandidateBytesMatch =
                        [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                            $Bytes,
                            $rollbackCandidateBytes
                        )
                    $rollbackCandidateBytes = $null
                    if (-not $rollbackCandidateBytesMatch) {
                        throw "自动回滚 CAS 冲突，正式目标已被外部修改：$resolvedPath"
                    }
                    $rollbackParameters = @{
                        Path = $resolvedPath
                        Bytes = $targetInitialBytes
                        TargetLastWriteTimeUtc = $lastWriteTime
                        ExpectedCurrentBytes = $Bytes
                        RequireExistingTarget = $true
                        DisableRecovery = $true
                        MaximumBytes = $MaximumBytes
                    }
                    if ($IsWindows -and $activeCommittedAcl) {
                        $rollbackCandidateAcl = Get-Acl `
                            -LiteralPath $resolvedPath `
                            -ErrorAction Stop
                        if (-not (Test-ToolkitAclPolicyEquivalent `
                                -ExpectedAcl $activeCommittedAcl `
                                -ActualAcl $rollbackCandidateAcl) -or
                            -not (Test-ToolkitEffectiveFileAclEquivalent `
                                -SourceAcl $activeCommittedAcl `
                                -DestinationAcl $rollbackCandidateAcl)) {
                            throw "自动回滚 CAS 冲突，正式目标 ACL 已被外部修改：$resolvedPath"
                        }
                        $rollbackParameters.ExpectedCurrentAcl =
                            $activeCommittedAcl
                    }
                    if ($null -ne $activeCommittedLastWriteTime) {
                        $rollbackParameters.ExpectedCurrentLastWriteTimeUtc =
                            $activeCommittedLastWriteTime
                    }
                    if ($IsWindows -and $targetAcl) {
                        $rollbackParameters.DesiredAcl = $targetAcl
                    }
                    Write-ToolkitBytesAtomic @rollbackParameters
                    $rolledBackBytes = Read-ToolkitFileBytesLocked `
                        -Path $resolvedPath `
                        -MaximumBytes $MaximumBytes
                    $rolledBackBytesMatch =
                        [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                            $targetInitialBytes,
                            $rolledBackBytes
                        )
                    $rolledBackBytes = $null
                    if (-not $rolledBackBytesMatch) {
                        throw "原子写入回滚后内容复读校验失败：$resolvedPath"
                    }
                    if ($IsWindows -and $targetAcl) {
                        $rolledBackAcl = Get-Acl `
                            -LiteralPath $resolvedPath `
                            -ErrorAction Stop
                        if (-not (Test-ToolkitAclPolicyEquivalent `
                                -ExpectedAcl $targetAcl `
                                -ActualAcl $rolledBackAcl) -or
                            -not (Test-ToolkitEffectiveFileAclEquivalent `
                                -SourceAcl $targetAcl `
                                -DestinationAcl $rolledBackAcl)) {
                            throw "原子写入回滚后 ACL 复读校验失败：$resolvedPath"
                        }
                    }
                    $rolledBackLastWriteTime =
                        (Get-Item -LiteralPath $resolvedPath -ErrorAction Stop).
                            LastWriteTimeUtc
                    if ($rolledBackLastWriteTime -ne $lastWriteTime) {
                        throw "原子写入回滚后 LastWriteTimeUtc 复读校验失败：$resolvedPath"
                    }
                }
                elseif (Test-Path -LiteralPath $resolvedPath) {
                    if (-not (Test-Path `
                            -LiteralPath $resolvedPath `
                            -PathType Leaf)) {
                        throw "自动清理 CAS 冲突，新建目标已被替换为非文件对象：$resolvedPath"
                    }
                    [IO.File]::Move($resolvedPath, $discardPath)
                    $retainDiscard = $true
                    $discardMatchesCommittedBytes =
                        [Collections.StructuralComparisons]::
                            StructuralEqualityComparer.Equals(
                                $Bytes,
                                (Read-ToolkitFileBytesLocked `
                                    -Path $discardPath `
                                    -MaximumBytes $MaximumBytes)
                            )
                    $discardMatchesCommittedTime = $true
                    if ($null -ne $activeCommittedLastWriteTime) {
                        $discardMatchesCommittedTime =
                            (Get-Item `
                                -LiteralPath $discardPath `
                                -ErrorAction Stop).LastWriteTimeUtc -eq
                            $activeCommittedLastWriteTime
                    }
                    $discardMatchesCommittedAcl = $true
                    if ($IsWindows) {
                        $discardAcl = Get-Acl `
                            -LiteralPath $discardPath `
                            -ErrorAction Stop
                        $discardMatchesCommittedAcl =
                            (Test-ToolkitAclPolicyEquivalent `
                                -ExpectedAcl $activeCommittedAcl `
                                -ActualAcl $discardAcl) -and
                            (Test-ToolkitEffectiveFileAclEquivalent `
                                -SourceAcl $activeCommittedAcl `
                                -DestinationAcl $discardAcl)
                    }
                    if (-not $discardMatchesCommittedBytes -or
                        -not $discardMatchesCommittedTime -or
                        -not $discardMatchesCommittedAcl) {
                        if (-not (Test-Path -LiteralPath $resolvedPath)) {
                            [IO.File]::Move($discardPath, $resolvedPath)
                            $retainDiscard = $false
                        }
                        $discardRecoveryMessage = if ($retainDiscard) {
                            "外部候选已保留：$discardPath"
                        }
                        else {
                            "外部目标已原位恢复：$resolvedPath"
                        }
                        throw "自动清理 CAS 冲突，新建目标已被外部修改。$discardRecoveryMessage"
                    }
                    try {
                        Remove-Item `
                            -LiteralPath $discardPath `
                            -Force `
                            -ErrorAction Stop
                        $retainDiscard = $false
                    }
                    catch {
                        $retainDiscard = $true
                        throw "新建目标的隔离副本无法删除，已保留：$discardPath。$($_.Exception.Message)"
                    }
                }
            }
            catch {
                $retainRollback = $targetExisted
                $recoveryMessage = if (-not $targetExisted -and
                    (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    "新建目标可能仍含暂存内容：$resolvedPath"
                }
                elseif ($retainRollback -and
                    (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
                    "原内容快照已保留：$rollbackPath"
                }
                else {
                    '未生成可保留的原内容快照。'
                }
                throw "$($primaryError.Exception.Message) 回滚也未完成：$($_.Exception.Message) $recoveryMessage"
            }
        }
        throw $primaryError
    }
    finally {
        if ($null -ne $stagingStream) {
            try { $stagingStream.Dispose() } catch { }
            $stagingStream = $null
        }
        $cleanupPaths = @($temporaryPath)
        if (-not $retainDiscard) { $cleanupPaths += $discardPath }
        if (-not $retainRollback) { $cleanupPaths += $rollbackPath }
        $cleanupIssues = [Collections.Generic.List[string]]::new()
        foreach ($cleanupPath in $cleanupPaths) {
            if (Test-Path -LiteralPath $cleanupPath -PathType Leaf) {
                try {
                    Remove-Item `
                        -LiteralPath $cleanupPath `
                        -Force `
                        -ErrorAction Stop
                }
                catch {
                    $cleanupIssues.Add(
                        "$cleanupPath（可能仍含暂存内容；清理错误：" +
                        "$($_.Exception.Message)）"
                    )
                }
            }
        }
        if ($cleanupIssues.Count -gt 0) {
            Write-Warning (
                '原子写入的临时文件清理未完整完成：' +
                ($cleanupIssues -join '；')
            )
        }
    }
}

function Write-ToolkitUtf8FileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [switch]$PreserveLastWriteTime,

        [DateTime]$TargetLastWriteTimeUtc,

        [AllowEmptyCollection()]
        [byte[]]$ExpectedCurrentBytes,

        [object]$ExpectedCurrentAcl,

        [DateTime]$ExpectedCurrentLastWriteTimeUtc,

        [object]$DesiredAcl,

        [switch]$RequireNewTarget,

        [switch]$RequireExistingTarget,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 100MB,

        [switch]$PassThru
    )

    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($Content.Length -gt $MaximumBytes) {
        throw "UTF-8 内容超过 $MaximumBytes 字节限制：$Path"
    }
    $encodedLength = $utf8.GetByteCount($Content)
    if ($encodedLength -gt $MaximumBytes) {
        throw "UTF-8 内容超过 $MaximumBytes 字节限制：$Path"
    }
    $bytes = $utf8.GetBytes($Content)
    $writeParameters = @{
        Path = $Path
        Bytes = $bytes
        PreserveLastWriteTime = $PreserveLastWriteTime
        MaximumBytes = $MaximumBytes
    }
    if ($PSBoundParameters.ContainsKey('TargetLastWriteTimeUtc')) {
        $writeParameters.TargetLastWriteTimeUtc = $TargetLastWriteTimeUtc
    }
    foreach ($parameterName in @(
            'ExpectedCurrentBytes',
            'ExpectedCurrentAcl',
            'ExpectedCurrentLastWriteTimeUtc',
            'DesiredAcl'
        )) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            $writeParameters[$parameterName] =
                $PSBoundParameters[$parameterName]
        }
    }
    if ($RequireNewTarget) { $writeParameters.RequireNewTarget = $true }
    if ($RequireExistingTarget) {
        $writeParameters.RequireExistingTarget = $true
    }
    if ($PassThru) { $writeParameters.PassThru = $true }
    Write-ToolkitBytesAtomic @writeParameters
}

function Get-ToolkitRawSecurityDescriptor {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Acl
    )

    try {
        $binary = $Acl.GetSecurityDescriptorBinaryForm()
        return [Security.AccessControl.RawSecurityDescriptor]::new($binary, 0)
    }
    catch {
        throw "ACL 安全描述符无法读取。$($_.Exception.Message)"
    }
}

function Assert-ToolkitSupportedFileAcl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Acl
    )

    $raw = Get-ToolkitRawSecurityDescriptor -Acl $Acl
    $hasSystemAcl = ($raw.ControlFlags -band
        [Security.AccessControl.ControlFlags]::SystemAclPresent) -ne 0
    if ($hasSystemAcl -or $null -ne $raw.SystemAcl) {
        throw '工具包不处理 SACL，已拒绝继续以避免审计策略丢失。'
    }

    $hasDiscretionaryAcl = ($raw.ControlFlags -band
        [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -ne 0
    if (-not $hasDiscretionaryAcl -or $null -eq $raw.DiscretionaryAcl) {
        throw '工具包不处理 null DACL，已拒绝继续。'
    }
    $canonicalProperty = $Acl.PSObject.Properties['AreAccessRulesCanonical']
    if ($null -eq $canonicalProperty -or
        -not [bool]$canonicalProperty.Value) {
        throw '工具包不处理非规范 DACL，已拒绝继续。'
    }
    try {
        $owner = $Acl.GetOwner(
            [Security.Principal.SecurityIdentifier]
        )
        $group = $Acl.GetGroup(
            [Security.Principal.SecurityIdentifier]
        )
    }
    catch {
        throw "ACL 缺少可读取的 Owner 或 Group。$($_.Exception.Message)"
    }
    if ($null -eq $owner -or $null -eq $group) {
        throw 'ACL 缺少 Owner 或 Group。'
    }

    foreach ($ace in $raw.DiscretionaryAcl) {
        $isOrdinaryType = $ace.AceType -eq
                [Security.AccessControl.AceType]::AccessAllowed -or
            $ace.AceType -eq [Security.AccessControl.AceType]::AccessDenied
        $opaque = $ace.GetOpaque()
        $isOrdinaryAce = $ace -is [Security.AccessControl.CommonAce] -and
            -not $ace.IsCallback -and
            ($null -eq $opaque -or $opaque.Length -eq 0)
        if (-not $isOrdinaryType -or -not $isOrdinaryAce) {
            throw "ACL 包含无法无损处理的 ACE 类型：$($ace.AceType)。"
        }
    }
    return $raw
}

function Get-ToolkitFileAclPolicySddl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Acl
    )

    [void](Assert-ToolkitSupportedFileAcl -Acl $Acl)
    $sections = [Security.AccessControl.AccessControlSections]::Owner -bor
        [Security.AccessControl.AccessControlSections]::Group -bor
        [Security.AccessControl.AccessControlSections]::Access
    return $Acl.GetSecurityDescriptorSddlForm($sections)
}

function New-ToolkitFileAclFromSddl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sddl
    )

    if ([string]::IsNullOrWhiteSpace($Sddl) -or $Sddl.Length -gt 32768) {
        throw '文件 ACL SDDL 无效。'
    }
    try {
        $raw = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
        $hasSystemAcl = ($raw.ControlFlags -band
            [Security.AccessControl.ControlFlags]::SystemAclPresent) -ne 0
        if ($hasSystemAcl -or $null -ne $raw.SystemAcl) {
            throw '文件 ACL SDDL 含 SACL，工具包不会静默丢弃审计策略。'
        }

        $expectedAcl = [Security.AccessControl.FileSecurity]::new()
        $sections = [Security.AccessControl.AccessControlSections]::Owner -bor
            [Security.AccessControl.AccessControlSections]::Group -bor
            [Security.AccessControl.AccessControlSections]::Access
        $expectedAcl.SetSecurityDescriptorSddlForm($Sddl, $sections)
        [void](Assert-ToolkitSupportedFileAcl -Acl $expectedAcl)
        return $expectedAcl
    }
    catch {
        throw "文件 ACL SDDL 无法安全解析。$($_.Exception.Message)"
    }
}

function New-ToolkitPrivateFileAcl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TemplateAcl
    )

    if (-not $IsWindows) { return $null }

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $currentSid) {
        throw '无法读取当前进程用户 SID。'
    }
    $privateAcl = [Security.AccessControl.FileSecurity]::new()
    $privateAcl.SetOwner($currentSid)
    $privateAcl.SetGroup($TemplateAcl.GetGroup(
            [Security.Principal.SecurityIdentifier]
        ))
    $privateAcl.SetAccessRuleProtection($true, $false)
    $privateAcl.SetAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $currentSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
    )
    [void](Assert-ToolkitSupportedFileAcl -Acl $privateAcl)
    return $privateAcl
}

function New-ToolkitPrivateDirectoryAcl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TemplateAcl
    )

    if (-not $IsWindows) { return $null }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $currentSid) {
        throw '无法读取当前进程用户 SID。'
    }
    $privateAcl = [Security.AccessControl.DirectorySecurity]::new()
    $privateAcl.SetOwner($currentSid)
    $privateAcl.SetGroup($TemplateAcl.GetGroup(
            [Security.Principal.SecurityIdentifier]
        ))
    $privateAcl.SetAccessRuleProtection($true, $false)
    $privateAcl.SetAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $currentSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags](
                [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            ),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
    )
    [void](Assert-ToolkitSupportedFileAcl -Acl $privateAcl)
    return $privateAcl
}

function Get-ToolkitPrivateAclForPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $IsWindows) { return $null }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "私有 ACL 目标不能是重解析点：$resolvedPath"
    }
    $templateAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    if ($item.PSIsContainer) {
        return New-ToolkitPrivateDirectoryAcl -TemplateAcl $templateAcl
    }
    return New-ToolkitPrivateFileAcl -TemplateAcl $templateAcl
}

function Assert-ToolkitPrivateFileSystemAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $IsWindows) { return }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $expectedAcl = Get-ToolkitPrivateAclForPath -Path $resolvedPath
    $actualAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    if (-not (Test-ToolkitAclPolicyEquivalent `
            -ExpectedAcl $expectedAcl `
            -ActualAcl $actualAcl) -or
        -not (Test-ToolkitEffectiveFileAclEquivalent `
            -SourceAcl $expectedAcl `
            -DestinationAcl $actualAcl)) {
        throw "私有 ACL 复读校验失败：$resolvedPath"
    }
}

function Set-ToolkitPrivateFileSystemAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $IsWindows) { return }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $privateAcl = Get-ToolkitPrivateAclForPath -Path $resolvedPath
    Set-ToolkitFileSystemAclPolicy `
        -Path $resolvedPath `
        -ExpectedAcl $privateAcl
    Assert-ToolkitPrivateFileSystemAcl -Path $resolvedPath
}

function Get-ToolkitSafeDirectoryTreePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [ValidateRange(1, 100000)]
        [int]$MaximumEntries = 4096
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "目录树根不存在：$resolvedRoot"
    }
    $result = [Collections.Generic.List[string]]::new()
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($resolvedRoot)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        $directoryItem = Get-Item `
            -LiteralPath $directory `
            -Force `
            -ErrorAction Stop
        if (($directoryItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "目录树包含重解析点：$directory"
        }
        if ($result.Count -ge $MaximumEntries) {
            throw "目录树项目数量超过 $MaximumEntries 项限制：$resolvedRoot"
        }
        $result.Add($directory)
        foreach ($childPath in [IO.Directory]::EnumerateFileSystemEntries(
                $directory
            )) {
            $child = Get-Item `
                -LiteralPath $childPath `
                -Force `
                -ErrorAction Stop
            if (($child.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "目录树包含重解析点：$($child.FullName)"
            }
            if ($child.PSIsContainer) {
                if (($result.Count + $queue.Count) -ge $MaximumEntries) {
                    throw "目录树项目数量超过 $MaximumEntries 项限制：$resolvedRoot"
                }
                $queue.Enqueue($child.FullName)
            }
            else {
                if (($result.Count + $queue.Count) -ge $MaximumEntries) {
                    throw "目录树项目数量超过 $MaximumEntries 项限制：$resolvedRoot"
                }
                $result.Add($child.FullName)
            }
        }
    }
    return @($result)
}

function Set-ToolkitPrivateDirectoryTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    if (-not $IsWindows) { return }
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    Set-ToolkitPrivateFileSystemAcl -Path $resolvedRoot
    foreach ($path in @(Get-ToolkitSafeDirectoryTreePaths -Root $resolvedRoot)) {
        if (-not (Test-ToolkitPathEqual -Left $path -Right $resolvedRoot)) {
            Set-ToolkitPrivateFileSystemAcl -Path $path
        }
    }
    Assert-ToolkitPrivateDirectoryTree -Root $resolvedRoot
}

function Assert-ToolkitPrivateDirectoryTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    if (-not $IsWindows) { return }
    foreach ($path in @(Get-ToolkitSafeDirectoryTreePaths -Root $Root)) {
        Assert-ToolkitPrivateFileSystemAcl -Path $path
    }
}

function Assert-ToolkitCurrentUserOnlyDirectoryTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    if (-not $IsWindows) { return }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($path in @(Get-ToolkitSafeDirectoryTreePaths -Root $Root)) {
        $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
        $raw = Assert-ToolkitSupportedFileAcl -Acl $acl
        if ($raw.Owner -ne $currentSid -or
            $null -eq $raw.DiscretionaryAcl -or
            $raw.DiscretionaryAcl.Count -ne 1) {
            throw "目录树项目未保持当前用户独占访问：$path"
        }
        $ace = $raw.DiscretionaryAcl[0]
        if ($ace.SecurityIdentifier -ne $currentSid -or
            $ace.AceQualifier -ne
                [Security.AccessControl.AceQualifier]::AccessAllowed -or
            [uint32]$ace.AccessMask -ne [uint32][int](
                [Security.AccessControl.FileSystemRights]::FullControl
            )) {
            throw "目录树项目未保持当前用户独占访问：$path"
        }
    }
}

function Get-ToolkitDirectoryStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [ValidateRange(1, 104857600)]
        [long]$MaximumFileBytes = 100MB,

        [ValidateRange(1, 100000)]
        [int]$MaximumEntries = 4096,

        [ValidateRange(1, 536870912)]
        [long]$MaximumTotalBytes = 100MB
    )

    $resolvedRoot = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($Root)
    )
    $prefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    $entries = [Collections.Generic.List[object]]::new()
    $totalBytes = 0L
    foreach ($path in @(Get-ToolkitSafeDirectoryTreePaths `
                -Root $resolvedRoot `
                -MaximumEntries $MaximumEntries |
                Sort-Object)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $relativePath = if (Test-ToolkitPathEqual `
                -Left $path `
                -Right $resolvedRoot) {
            '.'
        }
        else {
            $path.Substring($prefix.Length)
        }
        if ($item.PSIsContainer) {
            $entries.Add([pscustomobject]@{
                Type = 'directory'
                RelativePath = $relativePath
                Length = $null
                Sha256 = $null
                LastWriteTimeUtc = $null
                AclSddl = if ($IsWindows) {
                    Get-ToolkitFileAclPolicySddl -Acl (Get-Acl `
                        -LiteralPath $path `
                        -ErrorAction Stop)
                }
                else { $null }
            })
            continue
        }
        $snapshot = Get-ToolkitFileSnapshot `
            -Path $path `
            -MaximumBytes $MaximumFileBytes
        $totalBytes += [long]$snapshot.Length
        if ($totalBytes -gt $MaximumTotalBytes) {
            throw "目录树文件总大小超过 $MaximumTotalBytes 字节限制：$resolvedRoot"
        }
        $entries.Add([pscustomobject]@{
            Type = 'file'
            RelativePath = $relativePath
            Length = $snapshot.Length
            Sha256 = $snapshot.Sha256
            LastWriteTimeUtc = $snapshot.LastWriteTimeUtc.ToString('o')
            AclSddl = $snapshot.AclSddl
        })
    }
    [pscustomobject]@{
        Entries = @($entries)
        Token = (@($entries) | ConvertTo-Json -Depth 5 -Compress)
        MaximumFileBytes = $MaximumFileBytes
        MaximumEntries = $MaximumEntries
        MaximumTotalBytes = $MaximumTotalBytes
    }
}

function Assert-ToolkitDirectorySnapshotContainsFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$DirectorySnapshot,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [object]$FileSnapshot,

        [string]$Label = '目录快照文件'
    )

    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    $matches = @($DirectorySnapshot.Entries | Where-Object {
            [string]$_.Type -ceq 'file' -and
            [string]::Equals(
                [string]$_.RelativePath,
                $RelativePath,
                $comparison
            )
        })
    if ($matches.Count -ne 1) {
        throw "$Label 未在目录快照中唯一出现：$RelativePath"
    }
    $entry = $matches[0]
    if ([long]$entry.Length -ne [long]$FileSnapshot.Length -or
        [string]$entry.Sha256 -cne [string]$FileSnapshot.Sha256 -or
        [string]$entry.LastWriteTimeUtc -cne
            ([DateTime]$FileSnapshot.LastWriteTimeUtc).ToString('o')) {
        throw "$Label 与锁定解析快照不一致：$RelativePath"
    }
}

function Test-ToolkitDirectoryMatchesSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    try {
        $maximumFileBytes = if ($null -ne
            $Snapshot.PSObject.Properties['MaximumFileBytes']) {
            [long]$Snapshot.MaximumFileBytes
        }
        else { 100MB }
        $maximumEntries = if ($null -ne
            $Snapshot.PSObject.Properties['MaximumEntries']) {
            [int]$Snapshot.MaximumEntries
        }
        else { 4096 }
        $maximumTotalBytes = if ($null -ne
            $Snapshot.PSObject.Properties['MaximumTotalBytes']) {
            [long]$Snapshot.MaximumTotalBytes
        }
        else { 100MB }
        $current = Get-ToolkitDirectoryStateSnapshot `
            -Root $Root `
            -MaximumFileBytes $maximumFileBytes `
            -MaximumEntries $maximumEntries `
            -MaximumTotalBytes $maximumTotalBytes
        return [string]$current.Token -ceq [string]$Snapshot.Token
    }
    catch {
        return $false
    }
}

function Move-ToolkitDirectoryIfSnapshotMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [switch]$AllowInheritedPrivateChildren,

        [Collections.IDictionary]$State
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedDestination = [IO.Path]::GetFullPath($Destination)
    if ($null -eq $State) {
        $State = [ordered]@{}
    }
    $State.Clear()
    $State['SourcePath'] = $resolvedPath
    $State['DestinationPath'] = $resolvedDestination
    $State['MoveOccurred'] = $false
    $State['CurrentLocation'] = $resolvedPath
    $State['SnapshotMatched'] = $false
    $State['Validated'] = $false
    $State['Reverted'] = $false
    $State['Disposition'] = 'NoMove'
    try {
        if (Test-Path -LiteralPath $resolvedDestination) {
            throw "目录 CAS 移动目标已存在：$resolvedDestination"
        }
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            throw "目录 CAS 移动源已不存在或不再是目录：$resolvedPath"
        }
        if ($AllowInheritedPrivateChildren) {
            Assert-ToolkitCurrentUserOnlyDirectoryTree -Root $resolvedPath
        }
        else {
            Assert-ToolkitPrivateDirectoryTree -Root $resolvedPath
        }
        $State['Disposition'] = 'UnknownAfterMoveAttempt'
        [IO.Directory]::Move($resolvedPath, $resolvedDestination)
        $State['MoveOccurred'] = $true
        $State['CurrentLocation'] = $resolvedDestination
        if (-not (Test-ToolkitDirectoryMatchesSnapshot `
                -Root $resolvedDestination `
                -Snapshot $Snapshot)) {
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                [IO.Directory]::Move($resolvedDestination, $resolvedPath)
                $State['CurrentLocation'] = $resolvedPath
                $State['Reverted'] = $true
                $State['Disposition'] = 'RevertedToSource'
                throw "目录 CAS 移动冲突，外部修改已原位保留：$resolvedPath"
            }
            throw "目录 CAS 移动冲突，外部候选已隔离保留：$resolvedDestination"
        }
        $State['SnapshotMatched'] = $true
        if ($AllowInheritedPrivateChildren) {
            Assert-ToolkitCurrentUserOnlyDirectoryTree -Root $resolvedDestination
        }
        else {
            Assert-ToolkitPrivateDirectoryTree -Root $resolvedDestination
        }
        $State['Validated'] = $true
        $State['Disposition'] = 'AtDestinationValidated'
    }
    catch {
        $moveError = $_
        try {
            $State['Error'] = $moveError.Exception.Message
        }
        catch {
        }
        try {
            $moveError.Exception.Data['CodexToolkitDirectoryMoveState'] = $State
        }
        catch {
        }
        throw $moveError
    }
}

function Remove-ToolkitDirectoryIfSnapshotMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [switch]$AllowInheritedPrivateChildren
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    $quarantine = Join-Path $parent (
        '.{0}.delete-{1}-{2}' -f
            [IO.Path]::GetFileName($resolvedPath),
            $PID,
            [Guid]::NewGuid().ToString('N')
    )
    $moveState = [ordered]@{ Disposition = 'NoMove' }
    try {
        Move-ToolkitDirectoryIfSnapshotMatches `
            -Path $resolvedPath `
            -Destination $quarantine `
            -Snapshot $Snapshot `
            -AllowInheritedPrivateChildren:$AllowInheritedPrivateChildren `
            -State $moveState
    }
    catch {
        if ([string]$moveState['Disposition'] -notin @(
                'NoMove',
                'RevertedToSource'
            ) -and
            (Test-ToolkitPathEqual `
                -Left ([string]$moveState['CurrentLocation']) `
                -Right $quarantine)) {
            throw "目录 CAS 删除未完成，移动候选已隔离保留：$quarantine。$($_.Exception.Message)"
        }
        throw
    }
    $retainQuarantine = $true
    try {
        if ($AllowInheritedPrivateChildren) {
            Assert-ToolkitCurrentUserOnlyDirectoryTree -Root $quarantine
        }
        else {
            Assert-ToolkitPrivateDirectoryTree -Root $quarantine
        }
        if (Test-Path -LiteralPath $resolvedPath) {
            Remove-Item `
                -LiteralPath $quarantine `
                -Recurse `
                -Force `
                -ErrorAction Stop
            $retainQuarantine = $false
            throw "目录 CAS 删除冲突，原路径被外部重新创建，外部对象已保留：$resolvedPath"
        }
        Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction Stop
        $retainQuarantine = $false
    }
    catch {
        if ($retainQuarantine) {
            throw "私有目录隔离副本无法清理，已保留：$quarantine。$($_.Exception.Message)"
        }
        throw
    }
}

function Get-ToolkitAclRuleSignatures {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Acl,

        [bool]$IncludeExplicit = $true,

        [bool]$IncludeInherited = $true
    )

    $raw = Assert-ToolkitSupportedFileAcl -Acl $Acl
    $signatures = [Collections.Generic.List[string]]::new()
    foreach ($ace in $raw.DiscretionaryAcl) {
        $isInherited = ($ace.AceFlags -band
            [Security.AccessControl.AceFlags]::Inherited) -ne 0
        if (($isInherited -and -not $IncludeInherited) -or
            (-not $isInherited -and -not $IncludeExplicit)) {
            continue
        }
        $accessMask = [uint32](([int64]$ace.AccessMask) -band 0xFFFFFFFFL)
        $signatures.Add(('{0}|{1}|{2}|{3}' -f
                [int]$ace.AceType,
                [int]$ace.AceFlags,
                $accessMask.ToString('X8'),
                $ace.SecurityIdentifier.Value))
    }
    return @($signatures)
}

function Test-ToolkitStringSequenceEqual {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Left,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) { return $false }
    }
    return $true
}

function Test-ToolkitEffectiveFileAclEquivalent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceAcl,

        [Parameter(Mandatory = $true)]
        [object]$DestinationAcl
    )

    try {
        [void](Assert-ToolkitSupportedFileAcl -Acl $SourceAcl)
        [void](Assert-ToolkitSupportedFileAcl -Acl $DestinationAcl)
    }
    catch {
        return $false
    }

    if (-not (Test-ToolkitAclPrincipalEquivalent `
            -ExpectedAcl $SourceAcl `
            -ActualAcl $DestinationAcl)) {
        return $false
    }

    $sourceRules = @(Get-ToolkitAclRuleSignatures -Acl $SourceAcl)
    $destinationRules = @(Get-ToolkitAclRuleSignatures -Acl $DestinationAcl)
    return Test-ToolkitStringSequenceEqual `
        -Left $sourceRules `
        -Right $destinationRules
}

function Test-ToolkitAclPrincipalEquivalent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExpectedAcl,

        [Parameter(Mandatory = $true)]
        [object]$ActualAcl
    )

    $expectedOwner = $ExpectedAcl.GetOwner(
        [Security.Principal.SecurityIdentifier]
    ).Value
    $actualOwner = $ActualAcl.GetOwner(
        [Security.Principal.SecurityIdentifier]
    ).Value
    if ($expectedOwner -cne $actualOwner) { return $false }

    $expectedGroup = $ExpectedAcl.GetGroup(
        [Security.Principal.SecurityIdentifier]
    ).Value
    $actualGroup = $ActualAcl.GetGroup(
        [Security.Principal.SecurityIdentifier]
    ).Value
    return $expectedGroup -ceq $actualGroup
}

function Test-ToolkitAclPolicyEquivalent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExpectedAcl,

        [Parameter(Mandatory = $true)]
        [object]$ActualAcl
    )

    try {
        [void](Assert-ToolkitSupportedFileAcl -Acl $ExpectedAcl)
        [void](Assert-ToolkitSupportedFileAcl -Acl $ActualAcl)
    }
    catch {
        return $false
    }

    if (-not (Test-ToolkitAclPrincipalEquivalent `
            -ExpectedAcl $ExpectedAcl `
            -ActualAcl $ActualAcl) -or
        $ExpectedAcl.AreAccessRulesProtected -ne
            $ActualAcl.AreAccessRulesProtected) {
        return $false
    }

    $includeInherited = [bool]$ExpectedAcl.AreAccessRulesProtected
    $expectedRules = @(Get-ToolkitAclRuleSignatures `
            -Acl $ExpectedAcl `
            -IncludeExplicit $true `
            -IncludeInherited $includeInherited)
    $actualRules = @(Get-ToolkitAclRuleSignatures `
            -Acl $ActualAcl `
            -IncludeExplicit $true `
            -IncludeInherited $includeInherited)
    return Test-ToolkitStringSequenceEqual `
        -Left $expectedRules `
        -Right $actualRules
}

function Add-ToolkitAclAccessRules {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TargetAcl,

        [Parameter(Mandatory = $true)]
        [object]$SourceAcl,

        [bool]$IncludeInherited = $true
    )

    [void](Assert-ToolkitSupportedFileAcl -Acl $SourceAcl)
    $sourceRules = @($SourceAcl.GetAccessRules(
            $true,
            $IncludeInherited,
            [Security.Principal.SecurityIdentifier]
        ))
    foreach ($accessType in @(
            [Security.AccessControl.AccessControlType]::Deny,
            [Security.AccessControl.AccessControlType]::Allow
        )) {
        foreach ($rule in @($sourceRules |
                Where-Object AccessControlType -eq $accessType |
                Sort-Object {
                    '{0}|{1}|{2}|{3}' -f
                        $_.IdentityReference.Value,
                        [int64]$_.FileSystemRights,
                        [int]$_.InheritanceFlags,
                        [int]$_.PropagationFlags
                })) {
            $copiedRule = [Security.AccessControl.FileSystemAccessRule]::new(
                $rule.IdentityReference,
                $rule.FileSystemRights,
                $rule.InheritanceFlags,
                $rule.PropagationFlags,
                $rule.AccessControlType
            )
            [void]$TargetAcl.AddAccessRule($copiedRule)
        }
    }
}

function Read-ToolkitProcessOutputLimited {
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Process]$Process,

        [ValidateRange(1, 60000)]
        [int]$TimeoutMilliseconds,

        [ValidateRange(1, 1048576)]
        [int]$MaximumStandardOutputBytes,

        [ValidateRange(1, 1048576)]
        [int]$MaximumStandardErrorBytes,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $standardOutput = [Text.StringBuilder]::new()
    $standardError = [Text.StringBuilder]::new()
    $outputBuffer = [char[]]::new(4096)
    $errorBuffer = [char[]]::new(4096)
    $outputTask = $Process.StandardOutput.ReadAsync(
        $outputBuffer,
        0,
        $outputBuffer.Length
    )
    $errorTask = $Process.StandardError.ReadAsync(
        $errorBuffer,
        0,
        $errorBuffer.Length
    )
    $outputComplete = $false
    $errorComplete = $false
    $outputBytes = 0L
    $errorBytes = 0L
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $outputComplete -or -not $errorComplete) {
            $madeProgress = $false
            if (-not $outputComplete -and $outputTask.IsCompleted) {
                $readCount = $outputTask.GetAwaiter().GetResult()
                if ($readCount -eq 0) {
                    $outputComplete = $true
                }
                else {
                    $chunk = [string]::new($outputBuffer, 0, $readCount)
                    $outputBytes += [Text.Encoding]::UTF8.GetByteCount($chunk)
                    if ($outputBytes -gt $MaximumStandardOutputBytes) {
                        throw "$Context 的标准输出长度超出限制。"
                    }
                    [void]$standardOutput.Append($chunk)
                    $outputTask = $Process.StandardOutput.ReadAsync(
                        $outputBuffer,
                        0,
                        $outputBuffer.Length
                    )
                }
                $madeProgress = $true
            }
            if (-not $errorComplete -and $errorTask.IsCompleted) {
                $readCount = $errorTask.GetAwaiter().GetResult()
                if ($readCount -eq 0) {
                    $errorComplete = $true
                }
                else {
                    $chunk = [string]::new($errorBuffer, 0, $readCount)
                    $errorBytes += [Text.Encoding]::UTF8.GetByteCount($chunk)
                    if ($errorBytes -gt $MaximumStandardErrorBytes) {
                        throw "$Context 的标准错误输出长度超出限制。"
                    }
                    [void]$standardError.Append($chunk)
                    $errorTask = $Process.StandardError.ReadAsync(
                        $errorBuffer,
                        0,
                        $errorBuffer.Length
                    )
                }
                $madeProgress = $true
            }
            if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                throw "$Context 超过 $([Math]::Ceiling(
                        $TimeoutMilliseconds / 1000
                    )) 秒。"
            }
            if (-not $madeProgress) {
                [Threading.Thread]::Sleep(10)
            }
        }

        $remaining = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $Process.WaitForExit($remaining)) {
            throw "$Context 超过 $([Math]::Ceiling(
                    $TimeoutMilliseconds / 1000
                )) 秒。"
        }
        return [pscustomobject]@{
            StandardOutput = $standardOutput.ToString()
            StandardError = $standardError.ToString()
        }
    }
    catch {
        $operationError = $_
        $cleanupError = $null
        try {
            if (-not $Process.HasExited) {
                $Process.Kill($true)
                if (-not $Process.WaitForExit(5000)) {
                    $cleanupError = "$Context 的进程树在终止请求后 5 秒内仍未退出。"
                }
            }
        }
        catch {
            $cleanupError = "$Context 的进程树无法安全终止：$($_.Exception.Message)"
        }
        if (-not [string]::IsNullOrWhiteSpace($cleanupError)) {
            throw [InvalidOperationException]::new(
                "$($operationError.Exception.Message) $cleanupError",
                $operationError.Exception
            )
        }
        throw $operationError
    }
    finally {
        $stopwatch.Stop()
    }
}

function Enable-ToolkitFileSystemAclInheritance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $IsWindows) { return }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "ACL 继承目标不存在：$resolvedPath"
    }

    $systemDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::System
    )
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        throw '无法定位 Windows System32 目录。'
    }
    $icaclsPath = Join-Path $systemDirectory 'icacls.exe'
    if (-not (Test-Path -LiteralPath $icaclsPath -PathType Leaf)) {
        throw "找不到受信的 Windows ACL 工具：$icaclsPath"
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $icaclsPath
    $startInfo.WorkingDirectory = $systemDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add($resolvedPath)
    [void]$startInfo.ArgumentList.Add('/inheritance:e')

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Windows ACL 继承工具未启动。'
        }
        $output = Read-ToolkitProcessOutputLimited `
            -Process $process `
            -TimeoutMilliseconds 10000 `
            -MaximumStandardOutputBytes 65536 `
            -MaximumStandardErrorBytes 65536 `
            -Context 'Windows ACL 继承调整'
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        $detail = $output.StandardError.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = $output.StandardOutput.Trim()
        }
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "退出码 $exitCode"
        }
        throw "Windows ACL 继承调整失败：$resolvedPath。$detail"
    }

    $verifiedAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    if ($verifiedAcl.AreAccessRulesProtected) {
        throw "Windows ACL 继承调整未生效：$resolvedPath"
    }
}

function New-ToolkitFileSystemAclPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExpectedAcl,

        [Parameter(Mandatory = $true)]
        [object]$ActualAcl,

        [Parameter(Mandatory = $true)]
        [bool]$IsContainer
    )

    $expectedRaw = Assert-ToolkitSupportedFileAcl -Acl $ExpectedAcl
    $actualRaw = Assert-ToolkitSupportedFileAcl -Acl $ActualAcl
    $aces = [Collections.Generic.List[Security.AccessControl.GenericAce]]::new()
    foreach ($ace in $expectedRaw.DiscretionaryAcl) {
        $isInherited = ($ace.AceFlags -band
            [Security.AccessControl.AceFlags]::Inherited) -ne 0
        if ($ExpectedAcl.AreAccessRulesProtected -or -not $isInherited) {
            $aceBytes = [byte[]]::new($ace.BinaryLength)
            $ace.GetBinaryForm($aceBytes, 0)
            $aces.Add([Security.AccessControl.GenericAce]::CreateFromBinaryForm(
                    $aceBytes,
                    0
                ))
        }
    }
    if (-not $ExpectedAcl.AreAccessRulesProtected) {
        foreach ($ace in $actualRaw.DiscretionaryAcl) {
            $isInherited = ($ace.AceFlags -band
                [Security.AccessControl.AceFlags]::Inherited) -ne 0
            if ($isInherited) {
                $aceBytes = [byte[]]::new($ace.BinaryLength)
                $ace.GetBinaryForm($aceBytes, 0)
                $aces.Add([Security.AccessControl.GenericAce]::CreateFromBinaryForm(
                        $aceBytes,
                        0
                    ))
            }
        }
    }

    $revision = [Math]::Max(
        [int]$expectedRaw.DiscretionaryAcl.Revision,
        [int]$actualRaw.DiscretionaryAcl.Revision
    )
    $newDacl = [Security.AccessControl.RawAcl]::new($revision, $aces.Count)
    foreach ($ace in $aces) {
        $newDacl.InsertAce($newDacl.Count, $ace)
    }
    $controlFlags = [Security.AccessControl.ControlFlags]::SelfRelative -bor
        [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent
    if ($ExpectedAcl.AreAccessRulesProtected) {
        $controlFlags = $controlFlags -bor
            [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected
    }
    $newRaw = [Security.AccessControl.RawSecurityDescriptor]::new(
        $controlFlags,
        $expectedRaw.Owner,
        $expectedRaw.Group,
        $null,
        $newDacl
    )
    $binary = [byte[]]::new($newRaw.BinaryLength)
    $newRaw.GetBinaryForm($binary, 0)
    $policyAcl = if ($IsContainer) {
        [Security.AccessControl.DirectorySecurity]::new()
    }
    else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $policyAcl.SetSecurityDescriptorBinaryForm($binary)
    [void](Assert-ToolkitSupportedFileAcl -Acl $policyAcl)
    return $policyAcl
}

function Set-ToolkitFileSystemAclPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$ExpectedAcl
    )

    if (-not $IsWindows) { return }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "ACL 目标不存在：$resolvedPath"
    }

    [void](Assert-ToolkitSupportedFileAcl -Acl $ExpectedAcl)
    $actualAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    [void](Assert-ToolkitSupportedFileAcl -Acl $actualAcl)
    if (Test-ToolkitAclPolicyEquivalent `
            -ExpectedAcl $ExpectedAcl `
            -ActualAcl $actualAcl) {
        return
    }

    if (-not $ExpectedAcl.AreAccessRulesProtected -and
        $actualAcl.AreAccessRulesProtected) {
        Enable-ToolkitFileSystemAclInheritance -Path $resolvedPath
        $actualAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    }

    $actualAcl = New-ToolkitFileSystemAclPolicy `
        -ExpectedAcl $ExpectedAcl `
        -ActualAcl $actualAcl `
        -IsContainer (Test-Path -LiteralPath $resolvedPath -PathType Container)

    try {
        Set-Acl `
            -LiteralPath $resolvedPath `
            -AclObject $actualAcl `
            -ErrorAction Stop
    }
    catch {
        throw "文件系统 ACL 写入失败：$resolvedPath。$($_.Exception.Message)"
    }
    $verifiedAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
    if (-not (Test-ToolkitAclPolicyEquivalent `
            -ExpectedAcl $ExpectedAcl `
            -ActualAcl $verifiedAcl)) {
        throw "文件系统 ACL 策略复读校验失败：$resolvedPath"
    }
}

function Set-ToolkitFileAclFromSddl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Sddl
    )

    if (-not $IsWindows) { return }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "ACL 目标需要是普通文件：$resolvedPath"
    }
    $expectedAcl = New-ToolkitFileAclFromSddl -Sddl $Sddl

    Set-ToolkitFileSystemAclPolicy `
        -Path $resolvedPath `
        -ExpectedAcl $expectedAcl
}

function Copy-ToolkitFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 100MB
    )

    $resolvedSource = [IO.Path]::GetFullPath($Source)
    $resolvedDestination = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
        throw "找不到待复制的普通文件：$resolvedSource"
    }
    $destinationExisted = Test-Path -LiteralPath $resolvedDestination -PathType Leaf
    if ((Test-Path -LiteralPath $resolvedDestination) -and
        -not $destinationExisted) {
        throw "复制目标必须是普通文件：$resolvedDestination"
    }

    $sourceSnapshot = Get-ToolkitFileSnapshot `
        -Path $resolvedSource `
        -MaximumBytes $MaximumBytes
    if ($destinationExisted) {
        Write-ToolkitBytesAtomic `
            -Path $resolvedDestination `
            -Bytes $sourceSnapshot.Bytes `
            -TargetLastWriteTimeUtc $sourceSnapshot.LastWriteTimeUtc `
            -MaximumBytes $MaximumBytes `
            -RequireExistingTarget
        return
    }

    Write-ToolkitBytesAtomic `
        -Path $resolvedDestination `
        -Bytes $sourceSnapshot.Bytes `
        -TargetLastWriteTimeUtc $sourceSnapshot.LastWriteTimeUtc `
        -MaximumBytes $MaximumBytes `
        -RequireNewTarget
}

function New-ToolkitTomlCodeMask {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $characters = $Content.ToCharArray()
    $mask = $Content.ToCharArray()
    $state = 'normal'
    $index = 0
    while ($index -lt $characters.Length) {
        $character = $characters[$index]
        $isNewLine = $character -eq "`r" -or $character -eq "`n"
        switch ($state) {
            'normal' {
                if ($character -eq '#') {
                    $mask[$index] = ' '
                    $state = 'comment'
                }
                elseif ($character -eq '"') {
                    $isTriple = $index + 2 -lt $characters.Length -and
                        $characters[$index + 1] -eq '"' -and
                        $characters[$index + 2] -eq '"'
                    $mask[$index] = ' '
                    if ($isTriple) {
                        $mask[$index + 1] = ' '
                        $mask[$index + 2] = ' '
                        $index += 2
                        $state = 'multi-basic'
                    }
                    else {
                        $state = 'basic'
                    }
                }
                elseif ($character -eq "'") {
                    $isTriple = $index + 2 -lt $characters.Length -and
                        $characters[$index + 1] -eq "'" -and
                        $characters[$index + 2] -eq "'"
                    $mask[$index] = ' '
                    if ($isTriple) {
                        $mask[$index + 1] = ' '
                        $mask[$index + 2] = ' '
                        $index += 2
                        $state = 'multi-literal'
                    }
                    else {
                        $state = 'literal'
                    }
                }
            }
            'comment' {
                if ($isNewLine) {
                    $state = 'normal'
                }
                else {
                    $mask[$index] = ' '
                }
            }
            'basic' {
                if ($isNewLine) {
                    throw 'TOML 基本字符串跨越了物理行。'
                }
                if (-not $isNewLine) { $mask[$index] = ' ' }
                if ($character -eq '\') {
                    if ($index + 1 -lt $characters.Length) {
                        $index++
                        if ($characters[$index] -ne "`r" -and
                            $characters[$index] -ne "`n") {
                            $mask[$index] = ' '
                        }
                    }
                }
                elseif ($character -eq '"') {
                    $state = 'normal'
                }
            }
            'literal' {
                if ($isNewLine) {
                    throw 'TOML 字面字符串跨越了物理行。'
                }
                if (-not $isNewLine) { $mask[$index] = ' ' }
                if ($character -eq "'") { $state = 'normal' }
            }
            'multi-basic' {
                if (-not $isNewLine) { $mask[$index] = ' ' }
                if ($character -eq '\') {
                    if ($index + 1 -lt $characters.Length) {
                        $index++
                        if ($characters[$index] -ne "`r" -and
                            $characters[$index] -ne "`n") {
                            $mask[$index] = ' '
                        }
                    }
                }
                elseif ($character -eq '"') {
                    $quoteRun = 1
                    while ($index + $quoteRun -lt $characters.Length -and
                        $characters[$index + $quoteRun] -eq '"') {
                        $quoteRun++
                    }
                    if ($quoteRun -ge 3) {
                        if ($quoteRun -gt 5) {
                            throw 'TOML 多行基本字符串的结束引号数量无效。'
                        }
                        for ($offset = 1; $offset -lt $quoteRun; $offset++) {
                            $mask[$index + $offset] = ' '
                        }
                        $index += $quoteRun - 1
                        $state = 'normal'
                    }
                }
            }
            'multi-literal' {
                if (-not $isNewLine) { $mask[$index] = ' ' }
                if ($character -eq "'") {
                    $quoteRun = 1
                    while ($index + $quoteRun -lt $characters.Length -and
                        $characters[$index + $quoteRun] -eq "'") {
                        $quoteRun++
                    }
                    if ($quoteRun -ge 3) {
                        if ($quoteRun -gt 5) {
                            throw 'TOML 多行字面字符串的结束引号数量无效。'
                        }
                        for ($offset = 1; $offset -lt $quoteRun; $offset++) {
                            $mask[$index + $offset] = ' '
                        }
                        $index += $quoteRun - 1
                        $state = 'normal'
                    }
                }
            }
        }
        $index++
    }

    if ($state -in @('basic', 'literal', 'multi-basic', 'multi-literal')) {
        throw 'TOML 中存在未闭合的字符串。'
    }
    return -join $mask
}

function ConvertFrom-ToolkitTomlDottedKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $rawSegments = [Collections.Generic.List[string]]::new()
    $builder = [Text.StringBuilder]::new()
    $quote = [char]0
    $escaped = $false
    foreach ($character in $Value.Trim().ToCharArray()) {
        if ($quote -ne [char]0) {
            [void]$builder.Append($character)
            if ($quote -eq '"' -and $escaped) {
                $escaped = $false
            }
            elseif ($quote -eq '"' -and $character -eq '\') {
                $escaped = $true
            }
            elseif ($character -eq $quote) {
                $quote = [char]0
            }
        }
        elseif ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            [void]$builder.Append($character)
        }
        elseif ($character -eq '.') {
            $rawSegment = $builder.ToString().Trim()
            if ([string]::IsNullOrWhiteSpace($rawSegment)) {
                throw 'TOML 表名包含空段。'
            }
            $rawSegments.Add($rawSegment)
            [void]$builder.Clear()
        }
        else {
            [void]$builder.Append($character)
        }
    }
    if ($quote -ne [char]0 -or $escaped) {
        throw 'TOML 表名包含未闭合的引号。'
    }
    $lastRawSegment = $builder.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($lastRawSegment)) {
        throw 'TOML 表名包含空段。'
    }
    $rawSegments.Add($lastRawSegment)

    $segments = [Collections.Generic.List[string]]::new()
    foreach ($rawSegment in $rawSegments) {
        if ($rawSegment.StartsWith('"')) {
            $match = [regex]::Match(
                $rawSegment,
                '\A"((?:\\.|[^"\\])*)"\z'
            )
            if (-not $match.Success) {
                throw 'TOML 表名中的基本引号键格式无效。'
            }
            $encoded = $match.Groups[1].Value
            $decodedBuilder = [Text.StringBuilder]::new()
            $position = 0
            while ($position -lt $encoded.Length) {
                $character = $encoded[$position]
                if ($character -ne '\') {
                    if ([int]$character -lt 0x20 -and $character -ne "`t") {
                        throw 'TOML 表名中的基本引号键含有无效控制字符。'
                    }
                    [void]$decodedBuilder.Append($character)
                    $position++
                    continue
                }
                $position++
                if ($position -ge $encoded.Length) {
                    throw 'TOML 表名中的基本引号键转义无效。'
                }
                $escape = $encoded[$position]
                switch ($escape) {
                    'b' { [void]$decodedBuilder.Append([char]0x08); $position++ }
                    't' { [void]$decodedBuilder.Append("`t"); $position++ }
                    'n' { [void]$decodedBuilder.Append("`n"); $position++ }
                    'f' { [void]$decodedBuilder.Append([char]0x0C); $position++ }
                    'r' { [void]$decodedBuilder.Append("`r"); $position++ }
                    '"' { [void]$decodedBuilder.Append('"'); $position++ }
                    '\' { [void]$decodedBuilder.Append('\'); $position++ }
                    { $_ -ceq 'u' -or $_ -ceq 'U' } {
                        $hexLength = if ($escape -ceq 'u') { 4 } else { 8 }
                        if ($position + $hexLength -ge $encoded.Length) {
                            throw 'TOML 表名中的 Unicode 转义长度无效。'
                        }
                        $hex = $encoded.Substring($position + 1, $hexLength)
                        if ($hex -cnotmatch "\A[0-9A-Fa-f]{$hexLength}\z") {
                            throw 'TOML 表名中的 Unicode 转义格式无效。'
                        }
                        $codePoint = [Convert]::ToInt32($hex, 16)
                        if ($codePoint -gt 0x10FFFF -or
                            ($codePoint -ge 0xD800 -and $codePoint -le 0xDFFF)) {
                            throw 'TOML 表名中的 Unicode 转义码点无效。'
                        }
                        [void]$decodedBuilder.Append([char]::ConvertFromUtf32($codePoint))
                        $position += $hexLength + 1
                    }
                    default {
                        throw 'TOML 表名中的基本引号键转义无效。'
                    }
                }
            }
            $segments.Add($decodedBuilder.ToString())
        }
        elseif ($rawSegment.StartsWith("'")) {
            $match = [regex]::Match($rawSegment, "\A'([^']*)'\z")
            if (-not $match.Success) {
                throw 'TOML 表名中的字面引号键格式无效。'
            }
            $segments.Add($match.Groups[1].Value)
        }
        else {
            if ($rawSegment -cnotmatch '\A[A-Za-z0-9_-]+\z') {
                throw "TOML 表名包含无效的裸键：$rawSegment"
            }
            $segments.Add($rawSegment)
        }
    }
    return @($segments)
}

function Get-ToolkitTomlTableHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $mask = New-ToolkitTomlCodeMask -Content $Content
    $headers = [Collections.Generic.List[object]]::new()
    $lineStart = 0
    $squareDepth = 0
    $curlyDepth = 0
    while ($lineStart -lt $Content.Length) {
        $newlineIndex = $Content.IndexOf("`n", $lineStart)
        $lineContentEnd = if ($newlineIndex -lt 0) {
            $Content.Length
        }
        elseif ($newlineIndex -gt $lineStart -and
            $Content[$newlineIndex - 1] -eq "`r") {
            $newlineIndex - 1
        }
        else {
            $newlineIndex
        }
        $lineEnd = if ($newlineIndex -lt 0) {
            $Content.Length
        }
        else {
            $newlineIndex + 1
        }
        $maskedCodeLine = $mask.Substring(
            $lineStart,
            $lineContentEnd - $lineStart
        )
        $isHeaderCandidate = $squareDepth -eq 0 -and
            $curlyDepth -eq 0 -and
            $maskedCodeLine -cmatch
                '\A[ \t]*\[\[?[^\r\n\]]*\]\]?[ \t]*\z'
        if (-not $isHeaderCandidate) {
            foreach ($character in $maskedCodeLine.ToCharArray()) {
                switch ($character) {
                    '[' { $squareDepth++ }
                    ']' {
                        $squareDepth--
                        if ($squareDepth -lt 0) {
                            throw 'TOML 中的方括号层级无效。'
                        }
                    }
                    '{' { $curlyDepth++ }
                    '}' {
                        $curlyDepth--
                        if ($curlyDepth -lt 0) {
                            throw 'TOML 中的花括号层级无效。'
                        }
                    }
                }
            }
            if ($newlineIndex -lt 0) { break }
            $lineStart = $newlineIndex + 1
            continue
        }

        $maskedLine = $mask.Substring($lineStart, $lineEnd - $lineStart)
        $originalLine = $Content.Substring($lineStart, $lineEnd - $lineStart)
        $headerStart = $maskedLine.IndexOf('[', [StringComparison]::Ordinal)
        if ($headerStart -lt 0) {
            if ($newlineIndex -lt 0) { break }
            $lineStart = $newlineIndex + 1
            continue
        }
        $isArray = $maskedLine.Substring($headerStart).StartsWith(
            '[[',
            [StringComparison]::Ordinal
        )
        $openLength = if ($isArray) { 2 } else { 1 }
        $closeToken = if ($isArray) { ']]' } else { ']' }
        $closeIndex = $maskedLine.IndexOf(
            $closeToken,
            $headerStart + $openLength,
            [StringComparison]::Ordinal
        )
        if ($closeIndex -lt $headerStart + $openLength) {
            if ($newlineIndex -lt 0) { break }
            $lineStart = $newlineIndex + 1
            continue
        }
        $keyText = $originalLine.Substring(
            $headerStart + $openLength,
            $closeIndex - $headerStart - $openLength
        )
        $headers.Add([pscustomobject]@{
            Index = $lineStart
            Length = $lineEnd - $lineStart
            EndIndex = $lineEnd
            Segments = @(ConvertFrom-ToolkitTomlDottedKey -Value $keyText)
            Text = $originalLine.Substring(
                $headerStart,
                $closeIndex - $headerStart + $closeToken.Length
            )
            IsArray = $isArray
        })
        if ($newlineIndex -lt 0) { break }
        $lineStart = $newlineIndex + 1
    }
    if ($squareDepth -ne 0 -or $curlyDepth -ne 0) {
        throw 'TOML 中的数组或 inline table 未闭合。'
    }
    return @($headers)
}

function ConvertFrom-ToolkitTomlStringLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('"""') -or $trimmed.StartsWith("'''")) {
        throw "工具包管理的 TOML 键 $Key 使用了多行值，无法安全修改。"
    }
    $basicMatch = [regex]::Match(
        $trimmed,
        '^"((?:\\.|[^"\\])*)"[ \t]*(?:#.*)?$'
    )
    if ($basicMatch.Success) {
        try {
            $decodedSegments = @(ConvertFrom-ToolkitTomlDottedKey `
                -Value ('"' + $basicMatch.Groups[1].Value + '"'))
            if ($decodedSegments.Count -ne 1) {
                throw '字符串解码产生了多个键段。'
            }
            return [string]$decodedSegments[0]
        }
        catch {
            throw "TOML 键 $Key 的字符串转义无法解析。"
        }
    }
    $literalMatch = [regex]::Match($trimmed, "^'([^']*)'[ \t]*(?:#.*)?$")
    if ($literalMatch.Success) {
        return $literalMatch.Groups[1].Value
    }
    throw "工具包管理的 TOML 键 $Key 需要使用单行字符串值。"
}

function Get-ToolkitTomlAssignmentsInRegion {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $mask = New-ToolkitTomlCodeMask -Content $Content
    $assignments = [Collections.Generic.List[object]]::new()
    $lineStart = 0
    $squareDepth = 0
    $curlyDepth = 0
    while ($lineStart -lt $Content.Length) {
        $newlineIndex = $Content.IndexOf("`n", $lineStart)
        $lineContentEnd = if ($newlineIndex -lt 0) {
            $Content.Length
        }
        elseif ($newlineIndex -gt $lineStart -and
            $Content[$newlineIndex - 1] -eq "`r") {
            $newlineIndex - 1
        }
        else {
            $newlineIndex
        }
        $lineEnd = if ($newlineIndex -lt 0) {
            $Content.Length
        }
        else {
            $newlineIndex + 1
        }
        $maskedLine = $mask.Substring($lineStart, $lineContentEnd - $lineStart)
        $equalsOffset = if ($squareDepth -eq 0 -and $curlyDepth -eq 0) {
            $maskedLine.IndexOf('=', [StringComparison]::Ordinal)
        }
        else {
            -1
        }
        if ($equalsOffset -ge 0) {
            $equalsIndex = $lineStart + $equalsOffset
            $rawKey = $Content.Substring($lineStart, $equalsOffset).Trim()
            if (-not [string]::IsNullOrWhiteSpace($rawKey)) {
                $segments = @(ConvertFrom-ToolkitTomlDottedKey -Value $rawKey)
                if ($segments.Count -gt 0) {
                    $assignments.Add([pscustomobject]@{
                        Key = if ($segments.Count -eq 1) {
                            [string]$segments[0]
                        }
                        else {
                            $null
                        }
                        Segments = @($segments)
                        EqualsIndex = $equalsIndex
                        LineStart = $lineStart
                        LineContentEnd = $lineContentEnd
                        LineEnd = $lineEnd
                    })
                }
            }
        }
        $scanStart = if ($equalsOffset -ge 0) { $equalsOffset + 1 } else { 0 }
        for ($scanOffset = $scanStart; $scanOffset -lt $maskedLine.Length; $scanOffset++) {
            switch ($maskedLine[$scanOffset]) {
                '[' { $squareDepth++ }
                ']' {
                    $squareDepth--
                    if ($squareDepth -lt 0) {
                        throw 'TOML 区域中的方括号层级无效。'
                    }
                }
                '{' { $curlyDepth++ }
                '}' {
                    $curlyDepth--
                    if ($curlyDepth -lt 0) {
                        throw 'TOML 区域中的花括号层级无效。'
                    }
                }
            }
        }
        if ($newlineIndex -lt 0) { break }
        $lineStart = $newlineIndex + 1
    }
    if ($squareDepth -ne 0 -or $curlyDepth -ne 0) {
        throw 'TOML 区域中的数组或 inline table 未闭合。'
    }
    return @($assignments)
}

function Get-ToolkitTopLevelTomlValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $headers = @(Get-ToolkitTomlTableHeaders -Content $Content)
    $topLength = if ($headers.Count -gt 0) { $headers[0].Index } else { $Content.Length }
    $topLevel = $Content.Substring(0, $topLength)
    $matches = @(Get-ToolkitTomlAssignmentsInRegion -Content $topLevel |
        Where-Object { $_.Segments.Count -eq 1 -and $_.Key -ceq $Key })
    if ($matches.Count -gt 1) {
        throw "TOML 顶层键 $Key 重复出现。"
    }
    if ($matches.Count -eq 0) { return $null }

    $assignment = $matches[0]
    $value = $topLevel.Substring(
        $assignment.EqualsIndex + 1,
        $assignment.LineContentEnd - $assignment.EqualsIndex - 1
    )
    return ConvertFrom-ToolkitTomlStringLiteral -Value $value -Key $Key
}

function Remove-ToolkitTomlKeysFromRegion {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string[]]$Keys,

        [int]$StartIndex = 0,

        [int]$EndIndex = -1,

        [string]$Context = 'TOML'
    )

    if ($EndIndex -lt 0) { $EndIndex = $Content.Length }
    $region = $Content.Substring($StartIndex, $EndIndex - $StartIndex)
    $assignments = @(Get-ToolkitTomlAssignmentsInRegion -Content $region)
    $ranges = [Collections.Generic.List[object]]::new()
    foreach ($key in $Keys) {
        $matches = @($assignments | Where-Object {
            $_.Segments.Count -eq 1 -and $_.Key -ceq $key
        })
        if ($matches.Count -gt 1) {
            throw "$Context 中的键 $key 重复出现。"
        }
        if ($matches.Count -eq 0) { continue }
        $assignment = $matches[0]
        $rawValue = $region.Substring(
            $assignment.EqualsIndex + 1,
            $assignment.LineContentEnd - $assignment.EqualsIndex - 1
        ).TrimStart()
        if ($rawValue.StartsWith('"""') -or $rawValue.StartsWith("'''")) {
            throw "$Context 中的键 $key 使用了多行值，无法安全修改。"
        }
        [void](ConvertFrom-ToolkitTomlStringLiteral -Value $rawValue -Key $key)
        $ranges.Add([pscustomobject]@{
            Start = $assignment.LineStart
            End = $assignment.LineEnd
        })
    }

    foreach ($range in @($ranges | Sort-Object Start -Descending)) {
        $region = $region.Remove($range.Start, $range.End - $range.Start)
    }
    return $Content.Substring(0, $StartIndex) + $region + $Content.Substring($EndIndex)
}

function Remove-ToolkitTopLevelTomlKeys {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string[]]$Keys
    )

    $headers = @(Get-ToolkitTomlTableHeaders -Content $Content)
    $endIndex = if ($headers.Count -gt 0) { $headers[0].Index } else { $Content.Length }
    $conflictingHeader = @($headers | Where-Object {
        $_.Segments.Count -gt 0 -and
        $Keys -ccontains [string]$_.Segments[0]
    } | Select-Object -First 1)
    if ($conflictingHeader.Count -gt 0) {
        throw (
            'TOML 受管顶层键已被表命名空间占用，无法安全修改：' +
            [string]$conflictingHeader[0].Segments[0]
        )
    }
    $topLevel = $Content.Substring(0, $endIndex)
    $conflictingAssignment = @(Get-ToolkitTomlAssignmentsInRegion `
            -Content $topLevel | Where-Object {
            $_.Segments.Count -gt 1 -and
            $Keys -ccontains [string]$_.Segments[0]
        } | Select-Object -First 1)
    if ($conflictingAssignment.Count -gt 0) {
        throw (
            'TOML 受管顶层键已被 dotted key 命名空间占用，无法安全修改：' +
            [string]$conflictingAssignment[0].Segments[0]
        )
    }
    return Remove-ToolkitTomlKeysFromRegion `
        -Content $Content `
        -Keys $Keys `
        -StartIndex 0 `
        -EndIndex $endIndex `
        -Context 'TOML 顶层配置'
}

function Test-ToolkitTomlSegmentsEqual {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Actual,

        [Parameter(Mandatory = $true)]
        [string[]]$Expected
    )

    if ($Actual.Count -ne $Expected.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$Actual[$index] -cne $Expected[$index]) { return $false }
    }
    return $true
}

function Merge-ToolkitOpenRouterProvider {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $headers = @(Get-ToolkitTomlTableHeaders -Content $Content)
    $topLevelEnd = if ($headers.Count -gt 0) {
        ($headers | Sort-Object Index | Select-Object -First 1).Index
    }
    else {
        $Content.Length
    }
    $topAssignments = @(Get-ToolkitTomlAssignmentsInRegion `
        -Content $Content.Substring(0, $topLevelEnd))
    $conflictingTopAssignments = @($topAssignments | Where-Object {
        ($_.Segments.Count -eq 1 -and
            [string]$_.Segments[0] -ceq 'model_providers') -or
        ($_.Segments.Count -ge 2 -and
            [string]$_.Segments[0] -ceq 'model_providers' -and
            [string]$_.Segments[1] -ceq 'openrouter')
    })
    if ($conflictingTopAssignments.Count -gt 0) {
        throw 'OpenRouter provider 已通过顶层 inline table 或 dotted key 声明，无法安全合并。'
    }

    $conflictingArrayHeaders = @($headers | Where-Object {
        $_.IsArray -and
        [string]$_.Segments[0] -ceq 'model_providers' -and
        (($_.Segments.Count -eq 1) -or
            ($_.Segments.Count -ge 2 -and
                [string]$_.Segments[1] -ceq 'openrouter'))
    })
    if ($conflictingArrayHeaders.Count -gt 0) {
        throw 'OpenRouter provider 不能使用 TOML array table。'
    }
    $providerHeaders = @($headers | Where-Object {
        -not $_.IsArray -and (Test-ToolkitTomlSegmentsEqual `
            -Actual @($_.Segments) `
            -Expected @('model_providers', 'openrouter'))
    })
    if ($providerHeaders.Count -gt 1) {
        throw 'OpenRouter provider 表重复出现。'
    }
    $authHeaders = @($headers | Where-Object {
        -not $_.IsArray -and (Test-ToolkitTomlSegmentsEqual `
            -Actual @($_.Segments) `
            -Expected @('model_providers', 'openrouter', 'auth'))
    })
    if ($authHeaders.Count -gt 1) {
        throw 'OpenRouter provider auth 表重复出现。'
    }
    $authTreeHeaders = @($headers | Where-Object {
        -not $_.IsArray -and
        $_.Segments.Count -ge 3 -and
        [string]$_.Segments[0] -ceq 'model_providers' -and
        [string]$_.Segments[1] -ceq 'openrouter' -and
        [string]$_.Segments[2] -ceq 'auth'
    })
    if ($authTreeHeaders.Count -gt 0) {
        $orderedHeaders = @($headers | Sort-Object Index)
        $ranges = [Collections.Generic.List[object]]::new()
        foreach ($authTreeHeader in $authTreeHeaders) {
            $authPosition = [Array]::IndexOf($orderedHeaders, $authTreeHeader)
            $authEnd = if ($authPosition + 1 -lt $orderedHeaders.Count) {
                $orderedHeaders[$authPosition + 1].Index
            }
            else {
                $Content.Length
            }
            $ranges.Add([pscustomobject]@{
                Start = $authTreeHeader.Index
                End = $authEnd
            })
        }
        $withoutPersistentAuth = $Content
        foreach ($range in @($ranges | Sort-Object Start -Descending)) {
            $withoutPersistentAuth = $withoutPersistentAuth.Remove(
                $range.Start,
                $range.End - $range.Start
            )
        }
        return Merge-ToolkitOpenRouterProvider -Content $withoutPersistentAuth
    }

    $modelProvidersHeaders = @($headers | Where-Object {
        -not $_.IsArray -and (Test-ToolkitTomlSegmentsEqual `
            -Actual @($_.Segments) `
            -Expected @('model_providers'))
    })
    if ($modelProvidersHeaders.Count -gt 1) {
        throw 'model_providers 表重复出现。'
    }
    if ($modelProvidersHeaders.Count -eq 1) {
        $orderedHeaders = @($headers | Sort-Object Index)
        $parentPosition = [Array]::IndexOf(
            $orderedHeaders,
            $modelProvidersHeaders[0]
        )
        $parentEnd = if ($parentPosition + 1 -lt $orderedHeaders.Count) {
            $orderedHeaders[$parentPosition + 1].Index
        }
        else {
            $Content.Length
        }
        $parentRegion = $Content.Substring(
            $modelProvidersHeaders[0].EndIndex,
            $parentEnd - $modelProvidersHeaders[0].EndIndex
        )
        $parentAssignments = @(Get-ToolkitTomlAssignmentsInRegion `
            -Content $parentRegion)
        if (@($parentAssignments | Where-Object {
                $_.Segments.Count -ge 1 -and
                [string]$_.Segments[0] -ceq 'openrouter'
            }).Count -gt 0) {
            throw 'OpenRouter provider 已在 model_providers 表中通过 inline table 或 dotted key 声明。'
        }
    }

    if ($providerHeaders.Count -eq 1) {
        $orderedHeaders = @($headers | Sort-Object Index)
        $providerPosition = [Array]::IndexOf($orderedHeaders, $providerHeaders[0])
        $providerEnd = if ($providerPosition + 1 -lt $orderedHeaders.Count) {
            $orderedHeaders[$providerPosition + 1].Index
        }
        else {
            $Content.Length
        }
        $providerRegion = $Content.Substring(
            $providerHeaders[0].EndIndex,
            $providerEnd - $providerHeaders[0].EndIndex
        )
        $inlineAuthAssignments = @(
            Get-ToolkitTomlAssignmentsInRegion -Content $providerRegion |
                Where-Object {
                    $_.Segments.Count -ge 1 -and
                    [string]$_.Segments[0] -ceq 'auth'
                }
        )
        if ($inlineAuthAssignments.Count -gt 0) {
            throw 'OpenRouter provider 中存在 inline 或 dotted auth 配置，请先手动移除。'
        }
    }

    $managedLines = [Collections.Generic.List[string]]::new()
    $managedLines.Add('name = "OpenRouter"')
    $managedLines.Add('base_url = "https://openrouter.ai/api/v1"')
    $managedLines.Add('env_key = "OPENROUTER_API_KEY"')
    $managedLines.Add('wire_api = "responses"')
    $managedBlock = ($managedLines -join "`r`n") + "`r`n"

    if ($providerHeaders.Count -eq 0) {
        $providerBlock = "[model_providers.openrouter]`r`n$managedBlock`r`n"
        $childHeaders = @($headers | Where-Object {
            -not $_.IsArray -and
            $_.Segments.Count -gt 2 -and
            [string]$_.Segments[0] -ceq 'model_providers' -and
            [string]$_.Segments[1] -ceq 'openrouter'
        })
        if ($childHeaders.Count -gt 0) {
            $insertAt = ($childHeaders | Sort-Object Index | Select-Object -First 1).Index
            return $Content.Insert($insertAt, $providerBlock)
        }
        $prefix = $Content.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($prefix)) { return $providerBlock.TrimEnd() + "`r`n" }
        return $prefix + "`r`n`r`n" + $providerBlock
    }

    $providerHeader = $providerHeaders[0]
    $orderedHeaders = @($headers | Sort-Object Index)
    $providerPosition = [Array]::IndexOf($orderedHeaders, $providerHeader)
    $providerEnd = if ($providerPosition + 1 -lt $orderedHeaders.Count) {
        $orderedHeaders[$providerPosition + 1].Index
    }
    else {
        $Content.Length
    }
    $updated = Remove-ToolkitTomlKeysFromRegion `
        -Content $Content `
        -Keys @('name', 'base_url', 'env_key', 'wire_api') `
        -StartIndex $providerHeader.EndIndex `
        -EndIndex $providerEnd `
        -Context 'OpenRouter provider 表'

    $headersAfterRemoval = @(Get-ToolkitTomlTableHeaders -Content $updated)
    $providerAfterRemoval = @($headersAfterRemoval | Where-Object {
        -not $_.IsArray -and (Test-ToolkitTomlSegmentsEqual `
            -Actual @($_.Segments) `
            -Expected @('model_providers', 'openrouter'))
    })[0]
    return $updated.Insert($providerAfterRemoval.EndIndex, $managedBlock)
}

function Enter-ToolkitMutex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScopePath,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 30
    )

    $normalized = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($ScopePath)
    ).ToUpperInvariant()
    $hashBytes = [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($normalized)
    )
    $hash = [Convert]::ToHexString($hashBytes).Substring(0, 24)
    $mutex = [Threading.Mutex]::new($false, "Local\CodexOpenRouterToolkit-$hash")
    try {
        $acquired = $false
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "等待工具包文件锁超时：$ScopePath"
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Remove-ToolkitPowerShellCommentBlock {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$StartMarker,

        [Parameter(Mandatory = $true)]
        [string]$EndMarker,

        [string]$Context = 'PowerShell Profile'
    )

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        throw "$Context 有 $(@($parseErrors).Count) 个 PowerShell 语法错误。"
    }
    $commentTokens = @($tokens | Where-Object {
        $_.Kind -eq [Management.Automation.Language.TokenKind]::Comment
    })
    $startTokens = @($commentTokens | Where-Object {
        $lineStart = $Content.LastIndexOf(
            "`n",
            [Math]::Max(0, $_.Extent.StartOffset - 1)
        )
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
        $prefix = $Content.Substring(
            $lineStart,
            $_.Extent.StartOffset - $lineStart
        )
        $_.Text.Trim() -ceq $StartMarker -and $prefix -cmatch '\A[ \t]*\z'
    })
    $endTokens = @($commentTokens | Where-Object {
        $lineStart = $Content.LastIndexOf(
            "`n",
            [Math]::Max(0, $_.Extent.StartOffset - 1)
        )
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
        $prefix = $Content.Substring(
            $lineStart,
            $_.Extent.StartOffset - $lineStart
        )
        $_.Text.Trim() -ceq $EndMarker -and $prefix -cmatch '\A[ \t]*\z'
    })
    if ($startTokens.Count -eq 0 -and $endTokens.Count -eq 0) {
        return $Content
    }
    if ($startTokens.Count -ne 1 -or $endTokens.Count -ne 1) {
        throw "$Context 中的受管区块标记数量无效。"
    }
    $startOffset = $startTokens[0].Extent.StartOffset
    $endOffset = $endTokens[0].Extent.EndOffset
    if ($startOffset -ge $endTokens[0].Extent.StartOffset) {
        throw "$Context 中的受管区块标记顺序无效。"
    }
    $removeStart = $Content.LastIndexOf("`n", [Math]::Max(0, $startOffset - 1))
    if ($removeStart -lt 0) { $removeStart = 0 } else { $removeStart++ }
    $nextNewline = $Content.IndexOf("`n", $endOffset)
    $removeEnd = if ($nextNewline -lt 0) {
        $Content.Length
    }
    else {
        $nextNewline + 1
    }
    return $Content.Remove($removeStart, $removeEnd - $removeStart)
}

function Exit-ToolkitMutex {
    param(
        [AllowNull()]
        [Threading.Mutex]$Mutex
    )

    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() }
    catch [Threading.AbandonedMutexException] { }
    finally { $Mutex.Dispose() }
}

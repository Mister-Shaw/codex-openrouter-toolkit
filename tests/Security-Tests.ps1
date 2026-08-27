[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceManifest = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.psd1'
$commonPath = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.Common.ps1'
$installerPath = Join-Path `
    $repositoryRoot `
    'scripts\Install-CodexOpenRouter.ps1'
$uninstallerPath = Join-Path `
    $repositoryRoot `
    'scripts\Uninstall-CodexOpenRouter.ps1'
$restorePath = Join-Path `
    $repositoryRoot `
    'scripts\Restore-CodexOpenRouterBackup.ps1'
$modernFixture = Join-Path $PSScriptRoot 'fixtures\catalog-modern.json'
$securityTempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "codex-openrouter-security-tests-$([Guid]::NewGuid().ToString('N'))"

function Assert-SecurityTrue {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "SECURITY ASSERTION FAILED: $Message"
    }
}

function Assert-SecurityEqual {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -cne $Expected) {
        throw "SECURITY ASSERTION FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-SecurityThrows {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "SECURITY ASSERTION FAILED: expected failure: $Message"
    }
}

function Write-SecurityText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-SecurityAclStub {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Principal.SecurityIdentifier]$Owner,

        [Parameter(Mandatory = $true)]
        [Security.Principal.SecurityIdentifier]$Group,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rules
    )

    $rawDacl = [Security.AccessControl.RawAcl]::new(2, $Rules.Count)
    foreach ($rule in $Rules) {
        $aceFlags = [Security.AccessControl.AceFlags]::None
        if (($rule.InheritanceFlags -band
                [Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0) {
            $aceFlags = $aceFlags -bor
                [Security.AccessControl.AceFlags]::ContainerInherit
        }
        if (($rule.InheritanceFlags -band
                [Security.AccessControl.InheritanceFlags]::ObjectInherit) -ne 0) {
            $aceFlags = $aceFlags -bor
                [Security.AccessControl.AceFlags]::ObjectInherit
        }
        if (($rule.PropagationFlags -band
                [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
            $aceFlags = $aceFlags -bor
                [Security.AccessControl.AceFlags]::InheritOnly
        }
        if (($rule.PropagationFlags -band
                [Security.AccessControl.PropagationFlags]::NoPropagateInherit) -ne 0) {
            $aceFlags = $aceFlags -bor
                [Security.AccessControl.AceFlags]::NoPropagateInherit
        }
        $qualifier = if ($rule.AccessControlType -eq
            [Security.AccessControl.AccessControlType]::Deny) {
            [Security.AccessControl.AceQualifier]::AccessDenied
        }
        else {
            [Security.AccessControl.AceQualifier]::AccessAllowed
        }
        $ace = [Security.AccessControl.CommonAce]::new(
            $aceFlags,
            $qualifier,
            [int]$rule.FileSystemRights,
            [Security.Principal.SecurityIdentifier]$rule.IdentityReference,
            $false,
            $null
        )
        $rawDacl.InsertAce($rawDacl.Count, $ace)
    }
    $controlFlags = [Security.AccessControl.ControlFlags]::SelfRelative -bor
        [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent -bor
        [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        $controlFlags,
        $Owner,
        $Group,
        $null,
        $rawDacl
    )
    $descriptorBytes = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($descriptorBytes, 0)
    $stub = [pscustomobject]@{
        OwnerIdentity = $Owner
        GroupIdentity = $Group
        AccessRules = @($Rules)
        BinaryDescriptor = $descriptorBytes
        AreAccessRulesCanonical = $true
        AreAccessRulesProtected = $true
    }
    Add-Member `
        -InputObject $stub `
        -MemberType ScriptMethod `
        -Name GetSecurityDescriptorBinaryForm `
        -Value { return $this.BinaryDescriptor }
    Add-Member -InputObject $stub -MemberType ScriptMethod -Name GetOwner -Value {
        param([type]$TargetType)
        return $this.OwnerIdentity
    }
    Add-Member -InputObject $stub -MemberType ScriptMethod -Name GetGroup -Value {
        param([type]$TargetType)
        return $this.GroupIdentity
    }
    Add-Member `
        -InputObject $stub `
        -MemberType ScriptMethod `
        -Name GetAccessRules `
        -Value {
            param(
                [bool]$IncludeExplicit,
                [bool]$IncludeInherited,
                [type]$TargetType
            )
            return @($this.AccessRules)
        }
    return $stub
}

try {
    [void](New-Item -ItemType Directory -Path $securityTempRoot -Force)
    . $commonPath
    Import-Module -Name $sourceManifest -Force

    $installerSource = [IO.File]::ReadAllText($installerPath)
    $uninstallerSource = [IO.File]::ReadAllText($uninstallerPath)
    $restoreSource = [IO.File]::ReadAllText($restorePath)
    Assert-SecurityTrue `
        -Condition ($installerSource.Contains('-PassThruMutation') -and
            $installerSource.Contains(
                '$initializeResult.Mutation.PostState.Snapshot'
            ) -and
            $installerSource.Contains(
                '$catalogResult.Mutation.PostState.Snapshot'
            )) `
        -Message 'installer consumes runtime commit snapshots without resampling'
    Assert-SecurityTrue `
        -Condition ($uninstallerSource.Contains('-PassThruMutations') -and
            $uninstallerSource.Contains('$switchResult.Mutations') -and
            $uninstallerSource.Contains('$transactionProduct.PostState')) `
        -Message 'uninstaller consumes switch mutation states including deletion'
    $restoreFileCopyStart = $restoreSource.IndexOf(
        'function Copy-RestoreFileAtomic'
    )
    $restoreDirectoryCopyStart = $restoreSource.IndexOf(
        'function Copy-RestoreDirectoryContents'
    )
    $restoreFileCopySource = $restoreSource.Substring(
        $restoreFileCopyStart,
        $restoreDirectoryCopyStart - $restoreFileCopyStart
    )
    Assert-SecurityTrue `
        -Condition ($restoreFileCopySource.Contains(
                'Write-ToolkitBytesAtomic @writeParameters'
            ) -and
            -not $restoreFileCopySource.Contains(
                'Assert-RestoreLastWriteTimeUtc'
            )) `
        -Message 'restore file helper returns the atomic commit snapshot directly'

    $securityVolumeRoot = [IO.Path]::GetPathRoot($securityTempRoot)
    Assert-SecurityThrows `
        -Message 'restore rejects an explicit volume-root CodexHome' `
        -Action {
        & $restorePath `
            -BackupPath (Join-Path $securityTempRoot 'missing-backup') `
            -CodexHome $securityVolumeRoot `
            -ProfilePath (Join-Path $securityTempRoot 'root-guard-profile.ps1') `
            -Force | Out-Null
    }
    $originalCodexHomeEnvironment = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $securityVolumeRoot
        Assert-SecurityThrows `
            -Message 'restore rejects an environment volume-root CODEX_HOME' `
            -Action {
            & $restorePath `
                -BackupPath (Join-Path $securityTempRoot 'missing-backup') `
                -ProfilePath (Join-Path `
                    $securityTempRoot `
                    'root-guard-profile.ps1') `
                -Force | Out-Null
        }
    }
    finally {
        $env:CODEX_HOME = $originalCodexHomeEnvironment
    }

    $syntheticKey = 'sk-' + 'or-' + ('a' * 24)
    Assert-SecurityTrue `
        -Condition (Test-ToolkitApiKeyFormat -Value $syntheticKey) `
        -Message 'generic sk-or key format accepted'
    Assert-SecurityTrue `
        -Condition (-not (Test-ToolkitModelId -Value $syntheticKey)) `
        -Message 'API-key-shaped value rejected as model ID'
    Assert-SecurityThrows -Message 'API-key-shaped reasoning effort rejected' -Action {
        Assert-ToolkitReasoningEffort -Value ('sk-' + 'or-' + ('b' * 10))
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-ToolkitApiKeyFormat -Value 'sk-or-short')) `
        -Message 'short key format rejected'
    Assert-SecurityTrue `
        -Condition (-not (Test-ToolkitApiKeyFormat -Value ($syntheticKey + "`n"))) `
        -Message 'key control character rejected'

    $atomicPath = Join-Path $securityTempRoot 'atomic\empty.txt'
    Write-ToolkitUtf8FileAtomic -Path $atomicPath -Content ''
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $atomicPath).Length `
        -Expected ([long]0) `
        -Message 'empty atomic write'
    Write-ToolkitUtf8FileAtomic -Path $atomicPath -Content 'replacement'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($atomicPath)) `
        -Expected 'replacement' `
        -Message 'existing atomic replacement'
    $timestampCopySource = Join-Path `
        $securityTempRoot `
        'atomic\timestamp-copy-source.txt'
    $timestampCopyTarget = Join-Path `
        $securityTempRoot `
        'atomic\timestamp-copy-target.txt'
    Write-SecurityText -Path $timestampCopySource -Content 'timestamp-source'
    $timestampCopyExpected = [DateTime]::UtcNow.AddDays(-10)
    [IO.File]::SetLastWriteTimeUtc(
        $timestampCopySource,
        $timestampCopyExpected
    )
    Copy-ToolkitFileAtomic `
        -Source $timestampCopySource `
        -Destination $timestampCopyTarget
    Assert-SecurityEqual `
        -Actual (Get-Item `
            -LiteralPath $timestampCopyTarget).LastWriteTimeUtc `
        -Expected $timestampCopyExpected `
        -Message 'atomic copy preserves source LastWriteTimeUtc'

    $boundedReadPath = Join-Path `
        $securityTempRoot `
        'atomic\bounded-read.bin'
    $boundedReadStream = [IO.File]::Open(
        $boundedReadPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try { $boundedReadStream.SetLength(1025) }
    finally { $boundedReadStream.Dispose() }
    Assert-SecurityThrows `
        -Message 'locked byte reader enforces its in-stream size limit' `
        -Action {
        Read-ToolkitFileBytesLocked `
            -Path $boundedReadPath `
            -MaximumBytes 1024 | Out-Null
    }
    Assert-SecurityThrows `
        -Message 'consistent snapshot rejects an oversized file' `
        -Action {
        Get-ToolkitFileSnapshot `
            -Path $boundedReadPath `
            -MaximumBytes 1024 | Out-Null
    }
    $boundedWritePath = Join-Path `
        $securityTempRoot `
        'atomic\bounded-write.bin'
    Assert-SecurityThrows `
        -Message 'atomic writer rejects oversized source bytes before publish' `
        -Action {
        Write-ToolkitBytesAtomic `
            -Path $boundedWritePath `
            -Bytes ([byte[]]::new(1025)) `
            -MaximumBytes 1024
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $boundedWritePath)) `
        -Message 'oversized atomic write publishes no target'

    $utf8BoundaryPath = Join-Path `
        $securityTempRoot `
        'atomic\utf8-boundary.txt'
    Write-ToolkitUtf8FileAtomic `
        -Path $utf8BoundaryPath `
        -Content 'é' `
        -MaximumBytes 2
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($utf8BoundaryPath)) `
        -Expected 'é' `
        -Message 'UTF-8 writer accepts exact multibyte boundary'
    $utf8OversizePath = Join-Path `
        $securityTempRoot `
        'atomic\utf8-oversize.txt'
    Assert-SecurityThrows `
        -Message 'UTF-8 writer rejects multibyte content before publish' `
        -Action {
        Write-ToolkitUtf8FileAtomic `
            -Path $utf8OversizePath `
            -Content 'é' `
            -MaximumBytes 1
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $utf8OversizePath)) `
        -Message 'oversized UTF-8 write publishes no target'

    $snapshotGrowthPath = Join-Path `
        $securityTempRoot `
        'atomic\snapshot-growth.bin'
    [IO.File]::Copy($boundedReadPath, $snapshotGrowthPath)
    $global:CodexToolkitSnapshotGrowthPath = $snapshotGrowthPath
    function Get-Item {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [switch]$Force
        )

        $item = Microsoft.PowerShell.Management\Get-Item `
            -LiteralPath $LiteralPath `
            -Force:$Force `
            -ErrorAction Stop
        if (Test-ToolkitPathEqual `
                -Left $LiteralPath `
                -Right $global:CodexToolkitSnapshotGrowthPath) {
            return [pscustomobject]@{
                Attributes = $item.Attributes
                CreationTimeUtc = $item.CreationTimeUtc
                LastWriteTimeUtc = $item.LastWriteTimeUtc
                Length = 1L
            }
        }
        return $item
    }
    try {
        Assert-SecurityThrows `
            -Message 'locked stream rechecks limit after a stale small preflight' `
            -Action {
            Get-ToolkitFileSnapshot `
                -Path $snapshotGrowthPath `
                -MaximumBytes 1024 | Out-Null
        }
    }
    finally {
        Remove-Item Function:\Get-Item -Force -ErrorAction SilentlyContinue
        Remove-Variable `
            -Name CodexToolkitSnapshotGrowthPath `
            -Scope Global `
            -ErrorAction SilentlyContinue
    }

    $boundedTreeRoot = Join-Path $securityTempRoot 'bounded-tree'
    [void](New-Item -ItemType Directory -Path $boundedTreeRoot)
    Write-SecurityText -Path (Join-Path $boundedTreeRoot 'one') -Content 'a'
    Write-SecurityText -Path (Join-Path $boundedTreeRoot 'two') -Content 'b'
    Assert-SecurityThrows `
        -Message 'directory snapshot enforces aggregate entry limit' `
        -Action {
        Get-ToolkitDirectoryStateSnapshot `
            -Root $boundedTreeRoot `
            -MaximumFileBytes 1024 `
            -MaximumEntries 2 `
            -MaximumTotalBytes 1024 | Out-Null
    }
    Assert-SecurityThrows `
        -Message 'directory snapshot enforces aggregate byte limit' `
        -Action {
        Get-ToolkitDirectoryStateSnapshot `
            -Root $boundedTreeRoot `
            -MaximumFileBytes 1024 `
            -MaximumEntries 10 `
            -MaximumTotalBytes 1 | Out-Null
    }
    if ($IsWindows) {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User

        $directoryMoveSource = Join-Path `
            $securityTempRoot `
            'directory-move-state\source'
        $directoryMoveDestination = Join-Path `
            $securityTempRoot `
            'directory-move-state\destination'
        [void](New-Item -ItemType Directory -Path $directoryMoveSource -Force)
        Write-SecurityText `
            -Path (Join-Path $directoryMoveSource 'original.txt') `
            -Content 'original-directory-state'
        Set-ToolkitPrivateDirectoryTree -Root $directoryMoveSource
        $directoryMoveSnapshot = Get-ToolkitDirectoryStateSnapshot `
            -Root $directoryMoveSource `
            -MaximumFileBytes 1024 `
            -MaximumEntries 16 `
            -MaximumTotalBytes 4096
        $directoryMoveState = [ordered]@{}
        $script:originalDirectorySnapshotMatcher =
            ${function:Test-ToolkitDirectoryMatchesSnapshot}
        function Test-ToolkitDirectoryMatchesSnapshot {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [Parameter(Mandatory = $true)][object]$Snapshot
            )

            Write-SecurityText `
                -Path (Join-Path $Root 'destination-tamper.txt') `
                -Content 'destination-tampered'
            [void](New-Item `
                -ItemType Directory `
                -Path $directoryMoveSource `
                -Force)
            Write-SecurityText `
                -Path (Join-Path $directoryMoveSource 'external.txt') `
                -Content 'external-source-recreated'
            return $false
        }
        $directoryMoveError = $null
        try {
            Move-ToolkitDirectoryIfSnapshotMatches `
                -Path $directoryMoveSource `
                -Destination $directoryMoveDestination `
                -Snapshot $directoryMoveSnapshot `
                -State $directoryMoveState
        }
        catch {
            $directoryMoveError = $_
        }
        finally {
            Set-Item `
                -LiteralPath Function:\Test-ToolkitDirectoryMatchesSnapshot `
                -Value $script:originalDirectorySnapshotMatcher
        }
        Assert-SecurityTrue `
            -Condition ($null -ne $directoryMoveError) `
            -Message 'directory move conflict is reported'
        Assert-SecurityTrue `
            -Condition ([bool]$directoryMoveState['MoveOccurred']) `
            -Message 'directory move state records a completed filesystem move'
        Assert-SecurityTrue `
            -Condition (-not [bool]$directoryMoveState['Validated']) `
            -Message 'directory move state remains unvalidated after conflict'
        Assert-SecurityEqual `
            -Actual ([string]$directoryMoveState['CurrentLocation']) `
            -Expected ([IO.Path]::GetFullPath($directoryMoveDestination)) `
            -Message 'directory move state retains the moved candidate location'
        Assert-SecurityTrue `
            -Condition (Test-Path `
                -LiteralPath (Join-Path $directoryMoveSource 'external.txt') `
                -PathType Leaf) `
            -Message 'directory move preserves the recreated source object'
        Assert-SecurityTrue `
            -Condition (Test-Path `
                -LiteralPath (Join-Path `
                    $directoryMoveDestination `
                    'destination-tamper.txt') `
                -PathType Leaf) `
            -Message 'directory move preserves the isolated destination candidate'
        Assert-SecurityTrue `
            -Condition ($directoryMoveError.Exception.Data.Contains(
                'CodexToolkitDirectoryMoveState'
            )) `
            -Message 'directory move exception carries its fail-closed state'

        $lockedDataPath = Join-Path `
            $securityTempRoot `
            'locked-data-file\module.psd1'
        Write-SecurityText `
            -Path $lockedDataPath `
            -Content "@{ RootModule = 'safe.psm1'; GUID = 'be74dba0-28ed-4ba3-adff-f0fc0d107b39' }"
        $lockedDataSnapshot = Get-ToolkitFileSnapshot `
            -Path $lockedDataPath `
            -MaximumBytes 4096
        $global:CodexToolkitLockedDataPath = $lockedDataPath
        $global:CodexToolkitLockedDataMutationAttempted = $false
        $global:CodexToolkitLockedDataMutationBlocked = $false
        function Get-Item {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [switch]$Force
            )

            if (-not $global:CodexToolkitLockedDataMutationAttempted -and
                (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $global:CodexToolkitLockedDataPath)) {
                $global:CodexToolkitLockedDataMutationAttempted = $true
                try {
                    [IO.File]::WriteAllText(
                        $LiteralPath,
                        "@{ RootModule = 'tampered.psm1' }",
                        [Text.UTF8Encoding]::new($false)
                    )
                }
                catch [IO.IOException] {
                    $global:CodexToolkitLockedDataMutationBlocked = $true
                    throw
                }
            }
            Microsoft.PowerShell.Management\Get-Item `
                -LiteralPath $LiteralPath `
                -Force:$Force `
                -ErrorAction Stop
        }
        try {
            Assert-SecurityThrows `
                -Message 'locked data-file parser rejects a replacement attempt' `
                -Action {
                Import-ToolkitPowerShellDataFileLocked `
                    -Path $lockedDataPath `
                    -MaximumBytes 4096 `
                    -ExpectedSnapshot $lockedDataSnapshot | Out-Null
            }
        }
        finally {
            Remove-Item Function:\Get-Item -Force -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition $global:CodexToolkitLockedDataMutationAttempted `
            -Message 'locked data-file replacement fixture was reached'
        Assert-SecurityTrue `
            -Condition $global:CodexToolkitLockedDataMutationBlocked `
            -Message 'locked data-file guard denies concurrent replacement writes'
        Assert-SecurityTrue `
            -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $lockedDataSnapshot.Bytes,
                [IO.File]::ReadAllBytes($lockedDataPath)
            )) `
            -Message 'locked data-file parser preserves verified source bytes'
        Remove-Variable `
            -Name CodexToolkitLockedDataPath, `
                CodexToolkitLockedDataMutationAttempted, `
                CodexToolkitLockedDataMutationBlocked `
            -Scope Global `
            -ErrorAction SilentlyContinue

        $exclusiveStagingPath = Join-Path `
            $securityTempRoot `
            'atomic\exclusive-staging.txt'
        $script:exclusiveStagingObserved = $false
        $script:exclusiveStagingLockHeld = $false
        $script:exclusiveStagingLength = -1L
        function Set-Acl {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [Parameter(Mandatory = $true)][object]$AclObject
            )

            $isExclusiveStaging = (Test-ToolkitPathEqual `
                    -Left (Split-Path -Parent $LiteralPath) `
                    -Right (Split-Path -Parent $exclusiveStagingPath)) -and
                [IO.Path]::GetFileName($LiteralPath) -like
                    '.exclusive-staging.txt.tmp-*'
            if ($isExclusiveStaging) {
                $script:exclusiveStagingObserved = $true
                $script:exclusiveStagingLength = `
                    ([IO.FileInfo]::new($LiteralPath)).Length
                $probeStream = $null
                try {
                    $probeStream = [IO.File]::Open(
                        $LiteralPath,
                        [IO.FileMode]::Open,
                        [IO.FileAccess]::Read,
                        [IO.FileShare]::ReadWrite
                    )
                }
                catch [IO.IOException] {
                    $script:exclusiveStagingLockHeld = $true
                }
                finally {
                    if ($null -ne $probeStream) { $probeStream.Dispose() }
                }
            }
            Microsoft.PowerShell.Security\Set-Acl `
                -LiteralPath $LiteralPath `
                -AclObject $AclObject `
                -ErrorAction Stop
        }
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $exclusiveStagingPath `
                -Content 'exclusive-payload'
        }
        finally {
            Remove-Item Function:\Set-Acl -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition $script:exclusiveStagingObserved `
            -Message 'private staging ACL is applied before content'
        Assert-SecurityTrue `
            -Condition $script:exclusiveStagingLockHeld `
            -Message 'private staging remains exclusively locked during ACL setup'
        Assert-SecurityEqual `
            -Actual $script:exclusiveStagingLength `
            -Expected 0 `
            -Message 'private staging contains no source bytes during ACL setup'

        $timestampRollbackPath = Join-Path `
            $securityTempRoot `
            'atomic\timestamp-rollback.txt'
        Write-SecurityText -Path $timestampRollbackPath -Content 'time-before'
        $timestampRollbackExpected = [DateTime]::UtcNow.AddDays(-4)
        [IO.File]::SetLastWriteTimeUtc(
            $timestampRollbackPath,
            $timestampRollbackExpected
        )
        Assert-SecurityThrows `
            -Message 'invalid committed timestamp triggers atomic rollback' `
            -Action {
            Write-ToolkitUtf8FileAtomic `
                -Path $timestampRollbackPath `
                -Content 'time-after' `
                -TargetLastWriteTimeUtc ([DateTime]::new(
                    1000,
                    1,
                    1,
                    0,
                    0,
                    0,
                    [DateTimeKind]::Utc
                ))
        }
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($timestampRollbackPath)) `
            -Expected 'time-before' `
            -Message 'timestamp failure restores original bytes'
        Assert-SecurityEqual `
            -Actual (Get-Item `
                -LiteralPath $timestampRollbackPath).LastWriteTimeUtc `
            -Expected $timestampRollbackExpected `
            -Message 'timestamp failure restores original LastWriteTimeUtc'

        $casExistingPath = Join-Path `
            $securityTempRoot `
            'atomic\cas-existing.txt'
        Write-SecurityText -Path $casExistingPath -Content 'cas-original'
        $script:casExistingInjected = $false
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            if (-not $script:casExistingInjected -and
                (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $casExistingPath) -and
                [IO.File]::ReadAllText($LiteralPath) -ceq 'cas-committed') {
                $script:casExistingInjected = $true
                [IO.File]::WriteAllText(
                    $LiteralPath,
                    'cas-external',
                    [Text.UTF8Encoding]::new($false)
                )
                throw 'forced external write after commit'
            }
            Microsoft.PowerShell.Security\Get-Acl `
                -LiteralPath $LiteralPath `
                -ErrorAction Stop
        }
        $casExistingError = $null
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $casExistingPath `
                -Content 'cas-committed'
        }
        catch {
            $casExistingError = $_.Exception.Message
        }
        finally {
            Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
        }
        $casExistingRollbacks = @(Get-ChildItem `
            -LiteralPath (Split-Path -Parent $casExistingPath) `
            -Filter '.cas-existing.txt.rollback-*' `
            -File)
        Assert-SecurityTrue `
            -Condition $script:casExistingInjected `
            -Message 'existing-target post-commit external write injected'
        Assert-SecurityTrue `
            -Condition ($casExistingError.Contains('CAS 冲突') -and
                $casExistingError.Contains('原内容快照已保留')) `
            -Message 'existing-target CAS conflict retains trusted recovery'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($casExistingPath)) `
            -Expected 'cas-external' `
            -Message 'existing-target CAS conflict preserves external bytes'
        Assert-SecurityEqual `
            -Actual $casExistingRollbacks.Count `
            -Expected 1 `
            -Message 'existing-target CAS conflict retains one recovery snapshot'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($casExistingRollbacks[0].FullName)) `
            -Expected 'cas-original' `
            -Message 'retained CAS snapshot contains original bytes'
        Remove-Item -LiteralPath $casExistingRollbacks[0].FullName -Force

        $casNewPath = Join-Path $securityTempRoot 'atomic\cas-new.txt'
        $script:casNewInjected = $false
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            if (-not $script:casNewInjected -and
                (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $casNewPath) -and
                [IO.File]::ReadAllText($LiteralPath) -ceq 'cas-new-committed') {
                $script:casNewInjected = $true
                [IO.File]::WriteAllText(
                    $LiteralPath,
                    'cas-new-external',
                    [Text.UTF8Encoding]::new($false)
                )
                throw 'forced external replacement of new target'
            }
            Microsoft.PowerShell.Security\Get-Acl `
                -LiteralPath $LiteralPath `
                -ErrorAction Stop
        }
        $casNewError = $null
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $casNewPath `
                -Content 'cas-new-committed'
        }
        catch {
            $casNewError = $_.Exception.Message
        }
        finally {
            Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition $script:casNewInjected `
            -Message 'new-target post-commit external write injected'
        Assert-SecurityTrue `
            -Condition ($casNewError.Contains('CAS 冲突') -and
                $casNewError.Contains($casNewPath)) `
            -Message 'new-target CAS conflict reports retained external target'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($casNewPath)) `
            -Expected 'cas-new-external' `
            -Message 'new-target CAS conflict does not delete external bytes'

        $deleteRecreatedPath = Join-Path `
            $securityTempRoot `
            'atomic\delete-recreated.txt'
        Write-SecurityText -Path $deleteRecreatedPath -Content 'transaction-product'
        $deleteRecreatedSnapshot = Get-ToolkitFileSnapshot `
            -Path $deleteRecreatedPath
        $script:deleteRecreatedInjected = $false
        $script:originalSnapshotMatcher =
            ${function:Test-ToolkitFileMatchesSnapshot}
        function Test-ToolkitFileMatchesSnapshot {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][object]$Snapshot
            )

            if (-not $script:deleteRecreatedInjected -and
                $Path -like '*.delete-*') {
                $script:deleteRecreatedInjected = $true
                [IO.File]::WriteAllText(
                    $deleteRecreatedPath,
                    'external-recreated',
                    [Text.UTF8Encoding]::new($false)
                )
            }
            & $script:originalSnapshotMatcher -Path $Path -Snapshot $Snapshot
        }
        $deleteRecreatedError = $null
        try {
            Remove-ToolkitFileIfSnapshotMatches `
                -Path $deleteRecreatedPath `
                -Snapshot $deleteRecreatedSnapshot
        }
        catch {
            $deleteRecreatedError = $_.Exception.Message
        }
        finally {
            Set-Item `
                -LiteralPath Function:\Test-ToolkitFileMatchesSnapshot `
                -Value $script:originalSnapshotMatcher
        }
        Assert-SecurityTrue `
            -Condition $script:deleteRecreatedInjected `
            -Message 'CAS delete recreates original path during quarantine validation'
        Assert-SecurityTrue `
            -Condition ($deleteRecreatedError.Contains('CAS 删除冲突') -and
                $deleteRecreatedError.Contains('外部对象已保留')) `
            -Message 'CAS delete reports original-path recreation'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($deleteRecreatedPath)) `
            -Expected 'external-recreated' `
            -Message 'CAS delete preserves recreated external file'

        $gatePath = Join-Path $securityTempRoot 'atomic\private-gate.txt'
        Write-SecurityText -Path $gatePath -Content 'gate-before'
        $gateDesiredAcl = Get-Acl -LiteralPath $gatePath
        $script:gateObservedPrivate = $false
        $script:originalAclPolicySetter =
            ${function:Set-ToolkitFileSystemAclPolicy}
        function Set-ToolkitFileSystemAclPolicy {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][object]$ExpectedAcl
            )

            if ((Test-ToolkitPathEqual -Left $Path -Right $gatePath) -and
                [IO.File]::ReadAllText($Path) -ceq 'gate-sensitive') {
                $actualGateAcl = Microsoft.PowerShell.Security\Get-Acl `
                    -LiteralPath $Path
                $privateGateAcl = New-ToolkitPrivateFileAcl `
                    -TemplateAcl $actualGateAcl
                $script:gateObservedPrivate =
                    (Test-ToolkitAclPolicyEquivalent `
                        -ExpectedAcl $privateGateAcl `
                        -ActualAcl $actualGateAcl) -and
                    (Test-ToolkitEffectiveFileAclEquivalent `
                        -SourceAcl $privateGateAcl `
                        -DestinationAcl $actualGateAcl)
            }
            & $script:originalAclPolicySetter `
                -Path $Path `
                -ExpectedAcl $ExpectedAcl
        }
        try {
            Write-ToolkitBytesAtomic `
                -Path $gatePath `
                -Bytes ([Text.UTF8Encoding]::new($false).GetBytes(
                    'gate-sensitive'
                )) `
                -DesiredAcl $gateDesiredAcl `
                -RequireExistingTarget
        }
        finally {
            Set-Item `
                -LiteralPath Function:\Set-ToolkitFileSystemAclPolicy `
                -Value $script:originalAclPolicySetter
        }
        Assert-SecurityTrue `
            -Condition $script:gateObservedPrivate `
            -Message 'sensitive committed bytes remain behind private ACL gate'

        $privateTreeRoot = Join-Path $securityTempRoot 'private-tree'
        [void](New-Item -ItemType Directory -Path $privateTreeRoot)
        Set-ToolkitPrivateDirectoryTree -Root $privateTreeRoot
        $privateTreeChild = Join-Path $privateTreeRoot 'child'
        [void](New-Item -ItemType Directory -Path $privateTreeChild)
        Write-SecurityText `
            -Path (Join-Path $privateTreeChild 'payload.txt') `
            -Content 'private-tree-payload'
        Set-ToolkitPrivateDirectoryTree -Root $privateTreeRoot
        Assert-ToolkitPrivateDirectoryTree -Root $privateTreeRoot
        foreach ($privateTreePath in @(
                Get-ToolkitSafeDirectoryTreePaths -Root $privateTreeRoot
            )) {
            $privateTreeAcl = Get-Acl -LiteralPath $privateTreePath
            Assert-SecurityTrue `
                -Condition $privateTreeAcl.AreAccessRulesProtected `
                -Message 'private tree item has protected DACL'
            Assert-SecurityEqual `
                -Actual ($privateTreeAcl.GetOwner(
                    [Security.Principal.SecurityIdentifier]
                ).Value) `
                -Expected $currentSid.Value `
                -Message 'private tree item owner is current user'
        }

        $snapshotAclRacePath = Join-Path `
            $securityTempRoot `
            'atomic\snapshot-acl-race.txt'
        Write-SecurityText -Path $snapshotAclRacePath -Content 'snapshot-race'
        $snapshotAclBefore = Get-Acl -LiteralPath $snapshotAclRacePath
        $snapshotAclAfter = New-ToolkitPrivateFileAcl `
            -TemplateAcl $snapshotAclBefore
        $script:snapshotAclReadCount = 0
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $snapshotAclRacePath) {
                $script:snapshotAclReadCount++
                if ($script:snapshotAclReadCount -eq 1) {
                    return $snapshotAclBefore
                }
                return $snapshotAclAfter
            }
            Microsoft.PowerShell.Security\Get-Acl `
                -LiteralPath $LiteralPath `
                -ErrorAction Stop
        }
        try {
            Assert-SecurityThrows `
                -Message 'ACL mutation invalidates consistent snapshot' `
                -Action {
                Get-ToolkitFileSnapshot -Path $snapshotAclRacePath | Out-Null
            }
        }
        finally {
            Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition ($script:snapshotAclReadCount -ge 2) `
            -Message 'consistent snapshot reads ACL before and after locked bytes'
        $sourceCanarySid = [Security.Principal.SecurityIdentifier]::new(
            'S-1-5-11'
        )
        $targetCanarySid = [Security.Principal.SecurityIdentifier]::new(
            'S-1-5-18'
        )
        $aclSourceParent = Join-Path $securityTempRoot 'acl-source-parent'
        $aclCopyParent = Join-Path $securityTempRoot 'acl-target-parent'
        [void](New-Item -ItemType Directory -Path $aclSourceParent -Force)
        [void](New-Item -ItemType Directory -Path $aclCopyParent -Force)
        foreach ($parentFixture in @(
                [pscustomobject]@{
                    Path = $aclSourceParent
                    Canary = $sourceCanarySid
                    Rights = 'ReadAndExecute'
                },
                [pscustomobject]@{
                    Path = $aclCopyParent
                    Canary = $targetCanarySid
                    Rights = 'Read'
                }
            )) {
            $parentAcl = Get-Acl -LiteralPath $parentFixture.Path
            $parentAcl.SetAccessRuleProtection($true, $false)
            $currentParentRule = [Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
            $canaryParentRule = [Security.AccessControl.FileSystemAccessRule]::new(
                $parentFixture.Canary,
                $parentFixture.Rights,
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
            [void]$parentAcl.AddAccessRule($currentParentRule)
            [void]$parentAcl.AddAccessRule($canaryParentRule)
            Set-Acl -LiteralPath $parentFixture.Path -AclObject $parentAcl
        }

        $aclSourcePath = Join-Path $aclSourceParent 'acl-source.txt'
        $aclCopyPath = Join-Path $aclCopyParent 'acl-copy.txt'
        Write-SecurityText -Path $aclSourcePath -Content 'acl-cross-parent'
        $sourceAcl = Get-Acl -LiteralPath $aclSourcePath
        $sourceInheritedRules = @($sourceAcl.GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier]
            ) | Where-Object IsInherited)
        Assert-SecurityTrue `
            -Condition (-not $sourceAcl.AreAccessRulesProtected) `
            -Message 'cross-parent source inherits its ACL'
        Assert-SecurityTrue `
            -Condition ($sourceInheritedRules.Count -gt 0) `
            -Message 'cross-parent source has inherited access rules'

        $aclTemplateProbePath = Join-Path $aclCopyParent 'acl-template-probe.txt'
        Write-SecurityText -Path $aclTemplateProbePath -Content ''
        $aclTemplateProbe = Get-Acl -LiteralPath $aclTemplateProbePath
        Remove-Item -LiteralPath $aclTemplateProbePath -Force

        Copy-ToolkitFileAtomic -Source $aclSourcePath -Destination $aclCopyPath
        $copiedAcl = Get-Acl -LiteralPath $aclCopyPath
        $copiedRules = @($copiedAcl.GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier]
            ))
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($aclCopyPath)) `
            -Expected 'acl-cross-parent' `
            -Message 'cross-parent ACL copy preserves bytes'
        Assert-SecurityTrue `
            -Condition $copiedAcl.AreAccessRulesProtected `
            -Message 'new backup copy uses a protected private DACL'
        Assert-SecurityTrue `
            -Condition $copiedAcl.AreAccessRulesCanonical `
            -Message 'new backup copy has canonical access rules'
        Assert-SecurityEqual `
            -Actual @($copiedRules | Where-Object IsInherited).Count `
            -Expected 0 `
            -Message 'new backup copy contains no inherited access rules'
        Assert-SecurityEqual `
            -Actual $copiedAcl.GetOwner(
                [Security.Principal.SecurityIdentifier]
            ).Value `
            -Expected $currentSid.Value `
            -Message 'new backup copy owner is the current process SID'
        Assert-SecurityEqual `
            -Actual $copiedAcl.GetGroup(
                [Security.Principal.SecurityIdentifier]
            ).Value `
            -Expected $aclTemplateProbe.GetGroup(
                [Security.Principal.SecurityIdentifier]
            ).Value `
            -Message 'new backup copy preserves safe staging group SID'
        $privateRules = @($copiedRules | Where-Object {
                $_.IdentityReference.Value -ceq $currentSid.Value -and
                $_.AccessControlType -eq
                    [Security.AccessControl.AccessControlType]::Allow -and
                ([int]$_.FileSystemRights -band
                    [int][Security.AccessControl.FileSystemRights]::FullControl) -eq
                    [int][Security.AccessControl.FileSystemRights]::FullControl
            })
        Assert-SecurityEqual `
            -Actual $privateRules.Count `
            -Expected 1 `
            -Message 'new backup copy grants current user FullControl'
        Assert-SecurityEqual `
            -Actual @($copiedRules | Where-Object {
                    $_.IdentityReference.Value -cne $currentSid.Value
                }).Count `
            -Expected 0 `
            -Message 'new backup copy grants no other DACL principal'
        Assert-SecurityEqual `
            -Actual @($copiedRules | Where-Object {
                    $_.IdentityReference.Value -ceq $sourceCanarySid.Value
                }).Count `
            -Expected 0 `
            -Message 'source parent canary is absent from private backup DACL'
        Assert-SecurityEqual `
            -Actual @($copiedRules | Where-Object {
                    $_.IdentityReference.Value -ceq $targetCanarySid.Value
                }).Count `
            -Expected 0 `
            -Message 'target parent canary does not leak into backup ACL'

        $treeRootExplicitSid = [Security.Principal.SecurityIdentifier]::new(
            'S-1-5-19'
        )
        $treeNestedCanarySid = [Security.Principal.SecurityIdentifier]::new(
            'S-1-5-20'
        )
        $treeSourceRoot = Join-Path $aclSourceParent 'tree-source'
        $treeSourceNested = Join-Path $treeSourceRoot 'nested'
        $treeSourceFile = Join-Path $treeSourceNested 'payload.txt'
        [void](New-Item -ItemType Directory -Path $treeSourceNested -Force)

        $treeSourceRootAcl = Get-Acl -LiteralPath $treeSourceRoot
        $treeRootExplicitRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $treeRootExplicitSid,
            'ReadAndExecute',
            'ContainerInherit,ObjectInherit',
            'None',
            'Allow'
        )
        [void]$treeSourceRootAcl.AddAccessRule($treeRootExplicitRule)
        Set-Acl -LiteralPath $treeSourceRoot -AclObject $treeSourceRootAcl

        $treeSourceNestedAcl = Get-Acl -LiteralPath $treeSourceNested
        $treeSourceNestedAcl.SetAccessRuleProtection($true, $false)
        $treeNestedOwnerRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $currentSid,
            'FullControl',
            'ContainerInherit,ObjectInherit',
            'None',
            'Allow'
        )
        $treeNestedCanaryRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $treeNestedCanarySid,
            'Read',
            'ContainerInherit,ObjectInherit',
            'None',
            'Allow'
        )
        [void]$treeSourceNestedAcl.AddAccessRule($treeNestedOwnerRule)
        [void]$treeSourceNestedAcl.AddAccessRule($treeNestedCanaryRule)
        Set-Acl -LiteralPath $treeSourceNested -AclObject $treeSourceNestedAcl
        Write-SecurityText -Path $treeSourceFile -Content 'tree-acl-payload'

        $treeTargetRoot = Join-Path $aclCopyParent 'tree-target'
        $treeTargetNested = Join-Path $treeTargetRoot 'nested'
        $treeTargetFile = Join-Path $treeTargetNested 'payload.txt'
        [void](New-Item -ItemType Directory -Path $treeTargetNested -Force)
        Write-SecurityText -Path $treeTargetFile -Content 'tree-acl-payload'

        $treeSourceRootExpected = Get-Acl -LiteralPath $treeSourceRoot
        $treeSourceNestedExpected = Get-Acl -LiteralPath $treeSourceNested
        $treeSourceFileExpected = Get-Acl -LiteralPath $treeSourceFile
        Set-ToolkitFileSystemAclPolicy `
            -Path $treeTargetRoot `
            -ExpectedAcl $treeSourceRootExpected
        Set-ToolkitFileSystemAclPolicy `
            -Path $treeTargetNested `
            -ExpectedAcl $treeSourceNestedExpected
        Set-ToolkitFileSystemAclPolicy `
            -Path $treeTargetFile `
            -ExpectedAcl $treeSourceFileExpected

        $treeTargetRootAcl = Get-Acl -LiteralPath $treeTargetRoot
        $treeTargetNestedAcl = Get-Acl -LiteralPath $treeTargetNested
        $treeTargetFileAcl = Get-Acl -LiteralPath $treeTargetFile
        foreach ($treePolicyPair in @(
                [pscustomobject]@{
                    Expected = $treeSourceRootExpected
                    Actual = $treeTargetRootAcl
                    Name = 'root directory'
                },
                [pscustomobject]@{
                    Expected = $treeSourceNestedExpected
                    Actual = $treeTargetNestedAcl
                    Name = 'nested directory'
                },
                [pscustomobject]@{
                    Expected = $treeSourceFileExpected
                    Actual = $treeTargetFileAcl
                    Name = 'nested file'
                }
            )) {
            Assert-SecurityTrue `
                -Condition (Test-ToolkitAclPolicyEquivalent `
                    -ExpectedAcl $treePolicyPair.Expected `
                    -ActualAcl $treePolicyPair.Actual) `
                -Message "directory-tree ACL policy restores $($treePolicyPair.Name)"
        }
        Assert-SecurityTrue `
            -Condition (-not $treeTargetRootAcl.AreAccessRulesProtected) `
            -Message 'directory-tree root remains inheritance-enabled'
        Assert-SecurityTrue `
            -Condition $treeTargetNestedAcl.AreAccessRulesProtected `
            -Message 'directory-tree nested directory remains protected'
        Assert-SecurityTrue `
            -Condition (-not $treeTargetFileAcl.AreAccessRulesProtected) `
            -Message 'directory-tree file remains inheritance-enabled'

        $treeRootRules = @($treeTargetRootAcl.GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier]
            ))
        Assert-SecurityTrue `
            -Condition (@($treeRootRules | Where-Object {
                    $_.IdentityReference.Value -ceq $treeRootExplicitSid.Value -and
                    -not $_.IsInherited
                }).Count -gt 0) `
            -Message 'directory-tree root keeps its explicit rule'
        Assert-SecurityTrue `
            -Condition (@($treeRootRules | Where-Object {
                    $_.IdentityReference.Value -ceq $targetCanarySid.Value -and
                    $_.IsInherited
                }).Count -gt 0) `
            -Message 'directory-tree root inherits from the target parent'
        Assert-SecurityEqual `
            -Actual @($treeRootRules | Where-Object {
                    $_.IdentityReference.Value -ceq $sourceCanarySid.Value
                }).Count `
            -Expected 0 `
            -Message 'directory-tree root drops source-parent inherited rules'

        $treeNestedRules = @($treeTargetNestedAcl.GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier]
            ))
        Assert-SecurityTrue `
            -Condition (@($treeNestedRules | Where-Object {
                    $_.IdentityReference.Value -ceq $treeNestedCanarySid.Value -and
                    -not $_.IsInherited
                }).Count -gt 0) `
            -Message 'protected nested directory keeps its explicit canary rule'
        Assert-SecurityEqual `
            -Actual @($treeNestedRules | Where-Object {
                    $_.IdentityReference.Value -ceq $targetCanarySid.Value
                }).Count `
            -Expected 0 `
            -Message 'protected nested directory excludes target-parent rules'

        $treeFileRules = @($treeTargetFileAcl.GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier]
            ))
        Assert-SecurityTrue `
            -Condition (@($treeFileRules | Where-Object {
                    $_.IdentityReference.Value -ceq $treeNestedCanarySid.Value -and
                    $_.IsInherited
                }).Count -gt 0) `
            -Message 'nested file inherits from the restored protected directory'
        Assert-SecurityEqual `
            -Actual @($treeFileRules | Where-Object {
                    $_.IdentityReference.Value -ceq $targetCanarySid.Value
                }).Count `
            -Expected 0 `
            -Message 'nested file excludes unrelated target-parent rules'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $treeSourceFileExpected `
                -DestinationAcl $treeTargetFileAcl) `
            -Message 'nested file restores effective source access rules'

        $ownerIdentity = $sourceAcl.GetOwner(
            [Security.Principal.SecurityIdentifier]
        )
        $groupIdentity = $sourceAcl.GetGroup(
            [Security.Principal.SecurityIdentifier]
        )
        $ownerSid = $ownerIdentity.Value
        $groupSid = $groupIdentity.Value
        $readDataRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $ownerIdentity,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $writeDataRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $ownerIdentity,
            [Security.AccessControl.FileSystemRights]::WriteData,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $combinedRights = [Security.AccessControl.FileSystemRights](
            [int][Security.AccessControl.FileSystemRights]::ReadData -bor
            [int][Security.AccessControl.FileSystemRights]::WriteData
        )
        $combinedRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $ownerIdentity,
            $combinedRights,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $splitAcl = New-SecurityAclStub `
            -Owner $ownerIdentity `
            -Group $groupIdentity `
            -Rules @($readDataRule, $writeDataRule)
        $reorderedSplitAcl = New-SecurityAclStub `
            -Owner $ownerIdentity `
            -Group $groupIdentity `
            -Rules @($writeDataRule, $readDataRule)
        $mergedAcl = New-SecurityAclStub `
            -Owner $ownerIdentity `
            -Group $groupIdentity `
            -Rules @($combinedRule)
        $reducedAcl = New-SecurityAclStub `
            -Owner $ownerIdentity `
            -Group $groupIdentity `
            -Rules @($readDataRule)
        Assert-SecurityTrue `
            -Condition (-not (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $splitAcl `
                -DestinationAcl $mergedAcl)) `
            -Message 'ACL comparator rejects split versus merged access masks'
        Assert-SecurityTrue `
            -Condition (-not (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $splitAcl `
                -DestinationAcl $reorderedSplitAcl)) `
            -Message 'ACL comparator preserves DACL ACE order'
        Assert-SecurityTrue `
            -Condition (-not (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $splitAcl `
                -DestinationAcl $reducedAcl)) `
            -Message 'ACL comparator rejects a missing rights bit'

        $unsupportedAclSddls = @(
            [pscustomobject]@{
                Name = 'conditional callback ACE'
                Sddl = ('O:{0}G:{1}D:P' +
                    '(XA;;FR;;;WD;(@User.Title == "Manager"))' -f
                    $ownerSid,
                    $groupSid)
            },
            [pscustomobject]@{
                Name = 'object ACE'
                Sddl = ('O:{0}G:{1}D:P' +
                    '(OA;;FR;00112233-4455-6677-8899-AABBCCDDEEFF;;WD)' -f
                    $ownerSid,
                    $groupSid)
            },
            [pscustomobject]@{
                Name = 'null DACL'
                Sddl = ('O:{0}G:{1}D:NO_ACCESS_CONTROL' -f
                    $ownerSid,
                    $groupSid)
            },
            [pscustomobject]@{
                Name = 'noncanonical DACL'
                Sddl = ('O:{0}G:{1}D:P(A;;FR;;;WD)(D;;FW;;;WD)' -f
                    $ownerSid,
                    $groupSid)
            },
            [pscustomobject]@{
                Name = 'SACL metadata'
                Sddl = ('O:{0}G:{1}D:P(A;;FA;;;{0})S:(AU;SA;FR;;;WD)' -f
                    $ownerSid,
                    $groupSid)
            }
        )
        foreach ($unsupportedAcl in $unsupportedAclSddls) {
            Assert-SecurityThrows `
                -Message "ACL parser rejects $($unsupportedAcl.Name)" `
                -Action {
                    [void](New-ToolkitFileAclFromSddl `
                            -Sddl $unsupportedAcl.Sddl)
                }
        }

        $policyCanarySid = [Security.Principal.SecurityIdentifier]::new(
            'S-1-5-19'
        )
        $policyFilePath = Join-Path `
            $aclSourceParent `
            'policy restore & literal file.txt'
        Write-SecurityText -Path $policyFilePath -Content 'policy-file'
        $expectedFilePolicy = Get-Acl -LiteralPath $policyFilePath
        $fileCanaryRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $policyCanarySid,
            'ReadData',
            'Allow'
        )
        [void]$expectedFilePolicy.AddAccessRule($fileCanaryRule)
        Set-Acl -LiteralPath $policyFilePath -AclObject $expectedFilePolicy
        $expectedFilePolicy = Get-Acl -LiteralPath $policyFilePath
        $expectedFileSddl = $expectedFilePolicy.Sddl

        $protectedFilePolicy = Get-Acl -LiteralPath $policyFilePath
        $protectedFilePolicy.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($protectedFilePolicy.GetAccessRules(
                    $true,
                    $false,
                    [Security.Principal.SecurityIdentifier]
                ))) {
            [void]$protectedFilePolicy.RemoveAccessRuleSpecific($rule)
        }
        $protectedFilePolicy.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid,
                'FullControl',
                'Allow'
            )
        ) | Out-Null
        Set-Acl -LiteralPath $policyFilePath -AclObject $protectedFilePolicy
        Assert-SecurityTrue `
            -Condition (Get-Acl `
                -LiteralPath $policyFilePath).AreAccessRulesProtected `
            -Message 'file ACL fixture starts protected'

        Set-ToolkitFileAclFromSddl `
            -Path $policyFilePath `
            -Sddl $expectedFileSddl
        $restoredFilePolicy = Get-Acl -LiteralPath $policyFilePath
        Assert-SecurityTrue `
            -Condition (-not $restoredFilePolicy.AreAccessRulesProtected) `
            -Message 'file ACL restore re-enables inheritance'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $expectedFilePolicy `
                -ActualAcl $restoredFilePolicy) `
            -Message 'file ACL restore preserves unprotected policy'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $expectedFilePolicy `
                -DestinationAcl $restoredFilePolicy) `
            -Message 'file ACL restore preserves effective rights'
        Assert-SecurityEqual `
            -Actual @($restoredFilePolicy.GetAccessRules(
                    $true,
                    $false,
                    [Security.Principal.SecurityIdentifier]
                ) | Where-Object {
                    $_.IdentityReference.Value -ceq $policyCanarySid.Value
                }).Count `
            -Expected 1 `
            -Message 'file ACL restore preserves explicit canary rule'

        $policyDirectoryPath = Join-Path `
            $aclSourceParent `
            'policy restore & literal directory'
        [void](New-Item -ItemType Directory -Path $policyDirectoryPath)
        $expectedDirectoryPolicy = Get-Acl -LiteralPath $policyDirectoryPath
        $directoryCanaryRule = `
            [Security.AccessControl.FileSystemAccessRule]::new(
                $policyCanarySid,
                'ReadAndExecute',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
        [void]$expectedDirectoryPolicy.AddAccessRule($directoryCanaryRule)
        Set-Acl `
            -LiteralPath $policyDirectoryPath `
            -AclObject $expectedDirectoryPolicy
        $expectedDirectoryPolicy = Get-Acl -LiteralPath $policyDirectoryPath

        $protectedDirectoryPolicy = Get-Acl -LiteralPath $policyDirectoryPath
        $protectedDirectoryPolicy.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($protectedDirectoryPolicy.GetAccessRules(
                    $true,
                    $false,
                    [Security.Principal.SecurityIdentifier]
                ))) {
            [void]$protectedDirectoryPolicy.RemoveAccessRuleSpecific($rule)
        }
        $protectedDirectoryPolicy.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
        ) | Out-Null
        Set-Acl `
            -LiteralPath $policyDirectoryPath `
            -AclObject $protectedDirectoryPolicy
        Assert-SecurityTrue `
            -Condition (Get-Acl `
                -LiteralPath $policyDirectoryPath).AreAccessRulesProtected `
            -Message 'directory ACL fixture starts protected'

        Set-ToolkitFileSystemAclPolicy `
            -Path $policyDirectoryPath `
            -ExpectedAcl $expectedDirectoryPolicy
        $restoredDirectoryPolicy = Get-Acl -LiteralPath $policyDirectoryPath
        Assert-SecurityTrue `
            -Condition (-not $restoredDirectoryPolicy.AreAccessRulesProtected) `
            -Message 'directory ACL restore re-enables inheritance'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $expectedDirectoryPolicy `
                -ActualAcl $restoredDirectoryPolicy) `
            -Message 'directory ACL restore preserves unprotected policy'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $expectedDirectoryPolicy `
                -DestinationAcl $restoredDirectoryPolicy) `
            -Message 'directory ACL restore preserves effective rights'
        $restoredDirectoryCanaryRules = @(
            $restoredDirectoryPolicy.GetAccessRules(
                $true,
                $false,
                [Security.Principal.SecurityIdentifier]
            ) | Where-Object {
                $_.IdentityReference.Value -ceq $policyCanarySid.Value
            }
        )
        Assert-SecurityEqual `
            -Actual $restoredDirectoryCanaryRules.Count `
            -Expected 1 `
            -Message 'directory ACL restore preserves explicit canary rule'
        Assert-SecurityEqual `
            -Actual ([int]$restoredDirectoryCanaryRules[0].InheritanceFlags) `
            -Expected ([int][Security.AccessControl.InheritanceFlags](
                'ContainerInherit,ObjectInherit'
            )) `
            -Message 'directory ACL restore preserves inheritance flags'

        $failedAclCopyPath = Join-Path `
            $securityTempRoot `
            'atomic\failed-acl-copy.txt'
        $failedAclCopyError = $null
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $failedAclCopyPath) {
                throw "forced destination ACL reread failure: $LiteralPath"
            }
            Microsoft.PowerShell.Security\Get-Acl `
                -LiteralPath $LiteralPath `
                -ErrorAction Stop
        }
        function Remove-Item {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [switch]$Force
            )

            if ((Test-ToolkitPathEqual `
                    -Left (Split-Path -Parent $LiteralPath) `
                    -Right (Split-Path -Parent $failedAclCopyPath)) -and
                [IO.Path]::GetFileName($LiteralPath) -like
                    '.failed-acl-copy.txt.discard-*') {
                throw 'forced failed-copy cleanup failure'
            }
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath $LiteralPath `
                -Force:$Force `
                -ErrorAction Stop
        }
        try {
            Copy-ToolkitFileAtomic `
                -Source $atomicPath `
                -Destination $failedAclCopyPath
        }
        catch {
            $failedAclCopyError = $_.Exception.Message
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Get-Acl `
                -Force `
                -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Remove-Item `
                -Force `
                -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition (-not [string]::IsNullOrWhiteSpace($failedAclCopyError)) `
            -Message 'ACL copy cleanup double failure is reported'
        $failedAclCopyDiscards = @(Get-ChildItem `
            -LiteralPath (Split-Path -Parent $failedAclCopyPath) `
            -Filter '.failed-acl-copy.txt.discard-*' `
            -File)
        Assert-SecurityTrue `
            -Condition $failedAclCopyError.Contains('隔离副本无法删除') `
            -Message 'ACL copy cleanup failure reports residual content risk'
        Assert-SecurityTrue `
            -Condition ($failedAclCopyDiscards.Count -eq 1 -and
                $failedAclCopyError.Contains($failedAclCopyDiscards[0].FullName)) `
            -Message 'ACL copy cleanup failure reports residual path'
        Assert-SecurityTrue `
            -Condition (-not (Test-Path -LiteralPath $failedAclCopyPath)) `
            -Message 'failed ACL copy leaves no ambiguous formal target'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($failedAclCopyDiscards[0].FullName)) `
            -Expected 'replacement' `
            -Message 'failed ACL copy residual remains isolated for manual cleanup'
        Remove-Item -LiteralPath $failedAclCopyDiscards[0].FullName -Force

        $protectedAclPath = Join-Path $securityTempRoot 'atomic\protected-acl.txt'
        Write-SecurityText -Path $protectedAclPath -Content 'before'
        $protectedAcl = Get-Acl -LiteralPath $protectedAclPath
        $protectedAcl.SetAccessRuleProtection($true, $false)
        $currentUserRule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl',
            'Allow'
        )
        $protectedAcl.SetAccessRule($currentUserRule)
        Set-Acl -LiteralPath $protectedAclPath -AclObject $protectedAcl
        $protectedExpectedAcl = Get-Acl -LiteralPath $protectedAclPath
        $protectedSddl = (Get-Acl -LiteralPath $protectedAclPath).Sddl
        Write-ToolkitUtf8FileAtomic -Path $protectedAclPath -Content 'after'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($protectedAclPath)) `
            -Expected 'after' `
            -Message 'protected ACL atomic replacement writes content'
        $protectedWrittenAcl = Get-Acl -LiteralPath $protectedAclPath
        Assert-SecurityTrue `
            -Condition (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $protectedExpectedAcl `
                -ActualAcl $protectedWrittenAcl) `
            -Message 'protected ACL atomic replacement preserves policy'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $protectedExpectedAcl `
                -DestinationAcl $protectedWrittenAcl) `
            -Message 'protected ACL atomic replacement preserves access rules'

        $semanticAclPath = Join-Path $securityTempRoot 'atomic\semantic-acl.txt'
        Write-SecurityText -Path $semanticAclPath -Content 'before'
        $semanticActualAcl = Get-Acl -LiteralPath $semanticAclPath
        $semanticExpectedSddl = if ($semanticActualAcl.Sddl.Contains('D:AI')) {
            $semanticActualAcl.Sddl.Replace('D:AI', 'D:')
        }
        elseif ($semanticActualAcl.Sddl.Contains('D:PAI')) {
            $semanticActualAcl.Sddl.Replace('D:PAI', 'D:P')
        }
        elseif ($semanticActualAcl.Sddl.Contains('D:P')) {
            $semanticActualAcl.Sddl.Replace('D:P', 'D:PAI')
        }
        else {
            throw 'Unable to build a semantic ACL metadata variant.'
        }
        $script:semanticExpectedAcl = [Security.AccessControl.FileSecurity]::new()
        $script:semanticExpectedAcl.SetSecurityDescriptorSddlForm(
            $semanticExpectedSddl
        )
        Assert-SecurityTrue `
            -Condition ($script:semanticExpectedAcl.Sddl -cne
                $semanticActualAcl.Sddl) `
            -Message 'semantic ACL fixture has distinct SDDL text'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $script:semanticExpectedAcl `
                -ActualAcl $semanticActualAcl) `
            -Message 'semantic ACL fixture has equivalent policy'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $script:semanticExpectedAcl `
                -DestinationAcl $semanticActualAcl) `
            -Message 'semantic ACL fixture has equivalent access rules'
        $script:semanticAclReadCount = 0
        $script:semanticSetAclCalled = $false
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            $script:semanticAclReadCount++
            if ($script:semanticAclReadCount -eq 1) {
                return $script:semanticExpectedAcl
            }
            return Microsoft.PowerShell.Security\Get-Acl `
                -LiteralPath $LiteralPath `
                -ErrorAction Stop
        }
        function Set-Acl {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [Parameter(Mandatory = $true)][object]$AclObject
            )

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $semanticAclPath) {
                $script:semanticSetAclCalled = $true
                throw 'SEMANTIC_EQUIVALENT_ACL_WAS_REWRITTEN'
            }
            Microsoft.PowerShell.Security\Set-Acl `
                -LiteralPath $LiteralPath `
                -AclObject $AclObject `
                -ErrorAction Stop
        }
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $semanticAclPath `
                -Content 'semantic-after'
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Get-Acl `
                -Force `
                -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Set-Acl `
                -Force `
                -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition (-not $script:semanticSetAclCalled) `
            -Message 'semantic-equivalent ACL avoids a redundant write'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($semanticAclPath)) `
            -Expected 'semantic-after' `
            -Message 'semantic-equivalent ACL keeps the atomic write'

        $aclNoopPath = Join-Path $securityTempRoot 'atomic\acl-noop.txt'
        Write-SecurityText -Path $aclNoopPath -Content 'before'
        $script:aclNoopExpected = Get-Acl -LiteralPath $aclNoopPath
        $script:aclNoopDifferent = [Security.AccessControl.FileSecurity]::new()
        $script:aclNoopDifferent.SetOwner(
            $script:aclNoopExpected.GetOwner(
                [Security.Principal.SecurityIdentifier]
            )
        )
        $script:aclNoopDifferent.SetGroup(
            $script:aclNoopExpected.GetGroup(
                [Security.Principal.SecurityIdentifier]
            )
        )
        $script:aclNoopDifferent.SetAccessRuleProtection(
            $script:aclNoopExpected.AreAccessRulesProtected,
            $false
        )
        $differentRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $currentSid,
            'ReadAndExecute',
            'Allow'
        )
        [void]$script:aclNoopDifferent.AddAccessRule($differentRule)
        $script:aclNoopDifferentBytes = `
            $script:aclNoopDifferent.GetSecurityDescriptorBinaryForm()
        $script:aclNoopReadCount = 0
        $script:aclNoopSetCount = 0
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            $isAclNoopTarget = Test-ToolkitPathEqual `
                -Left $LiteralPath `
                -Right $aclNoopPath
            $isAclNoopRollback = (Test-ToolkitPathEqual `
                    -Left (Split-Path -Parent $LiteralPath) `
                    -Right (Split-Path -Parent $aclNoopPath)) -and
                [IO.Path]::GetFileName($LiteralPath) -like
                    '.acl-noop.txt.rollback-*'
            if ($isAclNoopTarget -or $isAclNoopRollback) {
                $script:aclNoopReadCount++
                if ($isAclNoopTarget -and
                    $script:aclNoopReadCount -ge 6 -and
                    $script:aclNoopReadCount -le 8) {
                    $differentAclCopy = `
                        [Security.AccessControl.FileSecurity]::new()
                    $differentAclCopy.SetSecurityDescriptorBinaryForm(
                        $script:aclNoopDifferentBytes
                    )
                    return $differentAclCopy
                }
            }
            return Microsoft.PowerShell.Security\Get-Acl `
                -LiteralPath $LiteralPath `
                -ErrorAction Stop
        }
        function Set-Acl {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [Parameter(Mandatory = $true)][object]$AclObject
            )

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $aclNoopPath) {
                $script:aclNoopSetCount++
                if ($script:aclNoopSetCount -eq 1) { return }
            }
            Microsoft.PowerShell.Security\Set-Acl `
                -LiteralPath $LiteralPath `
                -AclObject $AclObject `
                -ErrorAction Stop
        }
        $aclNoopError = $null
        try {
            Write-ToolkitUtf8FileAtomic -Path $aclNoopPath -Content 'after'
        }
        catch {
            $aclNoopError = $_.Exception.Message
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Get-Acl `
                -Force `
                -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Set-Acl `
                -Force `
                -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition (-not [string]::IsNullOrWhiteSpace($aclNoopError)) `
            -Message 'silent ACL write failure is detected by reread'
        Assert-SecurityTrue `
            -Condition ($aclNoopError.Contains('ACL') -and
                $aclNoopError.Contains('复读校验失败')) `
            -Message 'silent ACL write failure reports reread mismatch'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($aclNoopPath)) `
            -Expected 'before' `
            -Message 'silent ACL write failure rolls content back'

        $rollbackFailurePath = Join-Path `
            $securityTempRoot `
            'atomic\rollback-failure.txt'
        Write-SecurityText -Path $rollbackFailurePath -Content 'before'
        $atomicInitialAcl = Microsoft.PowerShell.Security\Get-Acl `
            -LiteralPath $rollbackFailurePath
        $script:atomicExpectedAcl = New-ToolkitPrivateFileAcl `
            -TemplateAcl $atomicInitialAcl
        $script:atomicDifferentAcl = `
            [Security.AccessControl.FileSecurity]::new()
        $script:atomicDifferentAcl.SetOwner(
            $script:atomicExpectedAcl.GetOwner(
                [Security.Principal.SecurityIdentifier]
            )
        )
        $script:atomicDifferentAcl.SetGroup(
            $script:atomicExpectedAcl.GetGroup(
                [Security.Principal.SecurityIdentifier]
            )
        )
        $script:atomicDifferentAcl.SetAccessRuleProtection($true, $false)
        $atomicDifferentRule = `
            [Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid,
                'ReadAndExecute',
                'Allow'
            )
        [void]$script:atomicDifferentAcl.AddAccessRule($atomicDifferentRule)
        $script:atomicAclCallCount = 0
        $script:atomicRollbackLock = $null
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $rollbackFailurePath) {
                $script:atomicAclCallCount++
                if ($script:atomicAclCallCount -le 4) {
                    return $script:atomicExpectedAcl
                }
                return $script:atomicDifferentAcl
            }
            return Microsoft.PowerShell.Security\Get-Acl `
                -LiteralPath $LiteralPath `
                -ErrorAction Stop
        }
        function Set-Acl {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [Parameter(Mandatory = $true)][object]$AclObject
            )

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $rollbackFailurePath) {
                $script:atomicRollbackLock = [IO.File]::Open(
                    $LiteralPath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::Read
                )
                throw 'forced post-commit ACL failure'
            }
            Microsoft.PowerShell.Security\Set-Acl `
                -LiteralPath $LiteralPath `
                -AclObject $AclObject `
                -ErrorAction Stop
        }
        $atomicRollbackError = $null
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $rollbackFailurePath `
                -Content 'after'
        }
        catch {
            $atomicRollbackError = $_.Exception.Message
        }
        finally {
            Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
            Remove-Item Function:\Set-Acl -ErrorAction SilentlyContinue
            if ($script:atomicRollbackLock) {
                $script:atomicRollbackLock.Dispose()
                $script:atomicRollbackLock = $null
            }
        }
        $retainedRollbacks = @(Get-ChildItem `
            -LiteralPath (Split-Path -Parent $rollbackFailurePath) `
            -Filter '.rollback-failure.txt.rollback-*' `
            -File)
        Assert-SecurityTrue `
            -Condition (-not [string]::IsNullOrWhiteSpace($atomicRollbackError)) `
            -Message 'forced atomic rollback failure reported'
        Assert-SecurityTrue `
            -Condition $atomicRollbackError.Contains('原内容快照已保留') `
            -Message 'atomic rollback failure reports retained snapshot'
        Assert-SecurityTrue `
            -Condition $atomicRollbackError.Contains('CAS 冲突') `
            -Message 'ACL divergence prevents destructive automatic rollback'
        Assert-SecurityEqual `
            -Actual $retainedRollbacks.Count `
            -Expected 1 `
            -Message 'CAS conflict retains the trusted original recovery snapshot'
        $originalRollbacks = @($retainedRollbacks | Where-Object {
                [IO.File]::ReadAllText($_.FullName) -ceq 'before'
            })
        Assert-SecurityEqual `
            -Actual $originalRollbacks.Count `
            -Expected 1 `
            -Message 'retained atomic rollback contains original bytes'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($rollbackFailurePath)) `
            -Expected 'after' `
            -Message 'CAS conflict does not overwrite the committed target'
        foreach ($retainedRollback in $retainedRollbacks) {
            Remove-Item -LiteralPath $retainedRollback.FullName -Force
        }

        $rollbackTamperPath = Join-Path `
            $securityTempRoot `
            'atomic\rollback-tamper.txt'
        Write-SecurityText -Path $rollbackTamperPath -Content 'before'
        $script:rollbackTampered = $false
        function Read-ToolkitFileBytesLocked {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [long]$MaximumBytes = 100MB
            )

            $isTamperRollback = (Test-ToolkitPathEqual `
                    -Left (Split-Path -Parent $Path) `
                    -Right (Split-Path -Parent $rollbackTamperPath)) -and
                [IO.Path]::GetFileName($Path) -like
                    '.rollback-tamper.txt.rollback-*'
            if ($isTamperRollback -and -not $script:rollbackTampered) {
                $script:rollbackTampered = $true
                [IO.File]::WriteAllText(
                    $Path,
                    'tampered-rollback',
                    [Text.UTF8Encoding]::new($false)
                )
            }
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.Length -gt $MaximumBytes) {
                throw "mock file exceeds limit: $Path"
            }
            return ,([IO.File]::ReadAllBytes($Path))
        }
        $rollbackTamperError = $null
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $rollbackTamperPath `
                -Content 'after'
        }
        catch {
            $rollbackTamperError = $_.Exception.Message
        }
        finally {
            Remove-Item `
                -LiteralPath Function:\Read-ToolkitFileBytesLocked `
                -Force `
                -ErrorAction SilentlyContinue
            . $commonPath
        }
        $tamperedRollbacks = @(Get-ChildItem `
            -LiteralPath (Split-Path -Parent $rollbackTamperPath) `
            -Filter '.rollback-tamper.txt.rollback-*' `
            -File)
        Assert-SecurityTrue `
            -Condition $script:rollbackTampered `
            -Message 'rollback tamper hook reached the outer snapshot'
        Assert-SecurityTrue `
            -Condition $rollbackTamperError.Contains(
                '原内容快照与初始内容不一致'
            ) `
            -Message 'tampered rollback snapshot is rejected'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($rollbackTamperPath)) `
            -Expected 'before' `
            -Message 'tampered rollback never becomes the formal target'
        Assert-SecurityEqual `
            -Actual $tamperedRollbacks.Count `
            -Expected 1 `
            -Message 'tampered rollback is retained for diagnosis'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($tamperedRollbacks[0].FullName)) `
            -Expected 'tampered-rollback' `
            -Message 'retained rollback contains the untrusted injected bytes'
        Remove-Item -LiteralPath $tamperedRollbacks[0].FullName -Force

        $cleanupFailurePath = Join-Path `
            $securityTempRoot `
            'atomic\cleanup-failure.txt'
        Write-SecurityText -Path $cleanupFailurePath -Content 'sensitive-before'
        $cleanupWarnings = @()
        function Remove-Item {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [switch]$Force
            )

            if ($LiteralPath -like '*.rollback-*') {
                throw 'forced rollback artifact cleanup failure'
            }
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath $LiteralPath `
                -Force:$Force `
                -ErrorAction Stop
        }
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $cleanupFailurePath `
                -Content 'after' `
                -WarningVariable cleanupWarnings `
                -WarningAction SilentlyContinue
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Remove-Item `
                -Force `
                -ErrorAction SilentlyContinue
        }
        $cleanupArtifacts = @(Get-ChildItem `
            -LiteralPath (Split-Path -Parent $cleanupFailurePath) `
            -Filter '.cleanup-failure.txt.rollback-*' `
            -File)
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($cleanupFailurePath)) `
            -Expected 'after' `
            -Message 'cleanup warning leaves committed target intact'
        Assert-SecurityEqual `
            -Actual $cleanupArtifacts.Count `
            -Expected 1 `
            -Message 'forced cleanup failure leaves one reported artifact'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($cleanupArtifacts[0].FullName)) `
            -Expected 'sensitive-before' `
            -Message 'undeletable rollback artifact remains available for manual cleanup'
        Assert-SecurityTrue `
            -Condition (($cleanupWarnings | Out-String).Contains(
                $cleanupArtifacts[0].FullName
            )) `
            -Message 'cleanup warning reports residual artifact path'
        Remove-Item -LiteralPath $cleanupArtifacts[0].FullName -Force
    }

    $mutexScope = Join-Path $securityTempRoot 'mutex-scope'
    [void](New-Item -ItemType Directory -Path $mutexScope -Force)
    $heldMutex = Enter-ToolkitMutex -ScopePath $mutexScope
    try {
        $mutexStartInfo = [Diagnostics.ProcessStartInfo]::new()
        $mutexStartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $mutexStartInfo.UseShellExecute = $false
        $mutexStartInfo.CreateNoWindow = $true
        $mutexStartInfo.RedirectStandardOutput = $true
        $mutexStartInfo.RedirectStandardError = $true
        [void]$mutexStartInfo.ArgumentList.Add('-NoProfile')
        [void]$mutexStartInfo.ArgumentList.Add('-Command')
        $escapedCommonPath = $commonPath.Replace("'", "''")
        $escapedMutexScope = (
            $mutexScope + [IO.Path]::DirectorySeparatorChar
        ).Replace("'", "''")
        [void]$mutexStartInfo.ArgumentList.Add(
            ". '$escapedCommonPath'; try { " +
            "`$m = Enter-ToolkitMutex -ScopePath '$escapedMutexScope' " +
            "-TimeoutSeconds 1; 'ACQUIRED'; Exit-ToolkitMutex -Mutex `$m " +
            "} catch { 'BLOCKED' }"
        )
        $mutexProcess = [Diagnostics.Process]::new()
        $mutexProcess.StartInfo = $mutexStartInfo
        [void]$mutexProcess.Start()
        $mutexOutput = $mutexProcess.StandardOutput.ReadToEnd()
        $mutexError = $mutexProcess.StandardError.ReadToEnd()
        $mutexProcess.WaitForExit()
        $mutexProcess.Dispose()
        Assert-SecurityEqual `
            -Actual $mutexOutput.Trim() `
            -Expected 'BLOCKED' `
            -Message "mutex normalizes trailing separator; stderr=$mutexError"
    }
    finally {
        Exit-ToolkitMutex -Mutex $heldMutex
    }

    $newLine = "`r`n"
    $complexToml = @(
        "model = 'old/model'",
        'model_reasoning_effort = "high"',
        'notes = """',
        '[model_providers.openrouter]',
        'model = "inside-string"',
        '"""',
        '[[products]]',
        'name = "fixture"',
        '[model_providers."openrouter"] # retained ] comment',
        'name = "Old name"',
        'base_url = "https://old.invalid"',
        'wire_api = "chat"',
        'custom_setting = "preserve-me"',
        '[model_providers.openrouter.auth]',
        'command = "powershell"',
        'args = ["-NoProfile"]'
    ) -join $newLine
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue -Content $complexToml -Key 'model') `
        -Expected 'old/model' `
        -Message 'literal top-level TOML value'
    $mergedToml = Merge-ToolkitOpenRouterProvider -Content $complexToml
    $mergedAgain = Merge-ToolkitOpenRouterProvider -Content $mergedToml
    Assert-SecurityEqual `
        -Actual $mergedAgain `
        -Expected $mergedToml `
        -Message 'provider merge idempotence'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains('custom_setting = "preserve-me"') `
        -Message 'custom provider field preserved'
    Assert-SecurityTrue `
        -Condition (-not $mergedToml.Contains('[model_providers.openrouter.auth]')) `
        -Message 'persistent command auth table removed'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains('env_key = "OPENROUTER_API_KEY"') `
        -Message 'persistent provider uses env key'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains('# retained ] comment') `
        -Message 'table header comment bracket preserved'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains("notes = `"`"`"$newLine[model_providers.openrouter]") `
        -Message 'table-looking multiline content preserved'
    Assert-SecurityThrows -Message 'invalid mixed quoted table key rejected' -Action {
        Get-ToolkitTomlTableHeaders `
            -Content ('[model_"providers".openrouter]' + $newLine) | Out-Null
    }
    foreach ($providerConflict in @(
            'model_providers.openrouter = { name = "conflict" }',
            ("[model_providers]$newLine" +
                'openrouter = { name = "conflict" }'),
            '[[model_providers]]',
            '[[model_providers.openrouter]]'
        )) {
        Assert-SecurityThrows `
            -Message "alternate provider declaration rejected: $providerConflict" `
            -Action {
            Merge-ToolkitOpenRouterProvider -Content $providerConflict | Out-Null
        }
    }
    Assert-SecurityThrows -Message 'inline persistent auth rejected' -Action {
        Merge-ToolkitOpenRouterProvider -Content (
            "[model_providers.openrouter]$newLine" +
            'auth = { command = "powershell" }'
        ) | Out-Null
    }

    $quotedTopLevel = (
        '"mo\U00000064el" = "old/model"' + $newLine +
        "'model_provider' = 'openai'" + $newLine
    )
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue `
            -Content $quotedTopLevel `
            -Key 'model') `
        -Expected 'old/model' `
        -Message 'Unicode escaped quoted top-level key decoded'
    $quotedTopLevel = Remove-ToolkitTopLevelTomlKeys `
        -Content $quotedTopLevel `
        -Keys @('model', 'model_provider')
    Assert-SecurityTrue `
        -Condition ([string]::IsNullOrWhiteSpace($quotedTopLevel)) `
        -Message 'quoted managed top-level keys removed semantically'

    $managedNamespaceKeys = @(
        'model',
        'model_provider',
        'model_reasoning_effort',
        'model_catalog_json'
    )
    $managedNamespaceShapes = [ordered]@{
        dotted = '{0}.child = "conflict"'
        table = '[{0}]' + $newLine + 'child = "conflict"'
        array = '[[{0}]]' + $newLine + 'child = "conflict"'
    }
    $managedNamespaceCaseCount = 0
    foreach ($managedNamespaceKey in $managedNamespaceKeys) {
        foreach ($managedNamespaceShape in $managedNamespaceShapes.GetEnumerator()) {
            $managedNamespaceCaseCount++
            $namespaceConfigPath = Join-Path `
                $securityTempRoot `
                ("toml-namespace-{0}-{1}.toml" -f
                    $managedNamespaceKey,
                    $managedNamespaceShape.Key)
            $namespaceContent = [string]::Format(
                [string]$managedNamespaceShape.Value,
                $managedNamespaceKey
            ) + $newLine
            Write-SecurityText `
                -Path $namespaceConfigPath `
                -Content $namespaceContent
            $namespaceBefore = [IO.File]::ReadAllBytes($namespaceConfigPath)
            Assert-SecurityThrows `
                -Message ("managed TOML namespace rejected: {0}/{1}" -f
                    $managedNamespaceKey,
                    $managedNamespaceShape.Key) `
                -Action {
                Set-CodexDesktopModelConfig `
                    -Model 'gpt-5.6-sol' `
                    -Provider openai `
                    -ReasoningEffort high `
                    -ConfigPath $namespaceConfigPath `
                    -SkipBackup | Out-Null
            }
            Assert-SecurityTrue `
                -Condition ([Collections.StructuralComparisons]::
                    StructuralEqualityComparer.Equals(
                        $namespaceBefore,
                        [IO.File]::ReadAllBytes($namespaceConfigPath)
                    )) `
                -Message ("rejected TOML namespace remains byte-identical: {0}/{1}" -f
                    $managedNamespaceKey,
                    $managedNamespaceShape.Key)
        }
    }
    Assert-SecurityEqual `
        -Actual $managedNamespaceCaseCount `
        -Expected 12 `
        -Message 'all managed TOML namespace conflict combinations covered'

    $fourQuoteToml = 'notes = """' + $newLine +
        'value""""' + $newLine +
        'model = "safe/model"' + $newLine
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue `
            -Content $fourQuoteToml `
            -Key 'model') `
        -Expected 'safe/model' `
        -Message 'four-quote multiline TOML closing delimiter'

    $nestedArrayToml = @(
        'matrix = [',
        '  [1, 2],',
        '  [3, 4]',
        ']',
        '[custom]',
        'keep = true'
    ) -join $newLine
    $nestedArrayMerged = Merge-ToolkitOpenRouterProvider `
        -Content $nestedArrayToml
    Assert-SecurityTrue `
        -Condition $nestedArrayMerged.Contains('  [1, 2],') `
        -Message 'nested multiline array is not parsed as table header'
    Assert-SecurityTrue `
        -Condition $nestedArrayMerged.Contains("[custom]$newLine" + 'keep = true') `
        -Message 'table after nested multiline array remains intact'

    $catalogPath = Join-Path $securityTempRoot 'config-tests\catalog.json'
    $configPath = Join-Path $securityTempRoot 'config-tests\config.toml'
    [void](New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $catalogPath) `
        -Force)
    Copy-Item -LiteralPath $modernFixture -Destination $catalogPath -Force
    [void](Set-OpenRouterAgentInstructions -Path $catalogPath)
    Write-SecurityText -Path $configPath -Content ($complexToml + $newLine)
    Set-CodexDesktopModelConfig `
        -Model 'anthropic/claude-opus-5' `
        -Provider openrouter `
        -ReasoningEffort high `
        -ModelCatalogPath $catalogPath `
        -ConfigPath $configPath `
        -SkipBackup | Out-Null
    $switchedToml = [IO.File]::ReadAllText($configPath)
    Assert-SecurityTrue `
        -Condition $switchedToml.Contains('model = "anthropic/claude-opus-5"') `
        -Message 'safe OpenRouter model write'
    Assert-SecurityTrue `
        -Condition $switchedToml.Contains('custom_setting = "preserve-me"') `
        -Message 'switch keeps custom provider field'

    $beforeInjection = [IO.File]::ReadAllBytes($configPath)
    Assert-SecurityThrows -Message 'model TOML injection rejected' -Action {
        Set-CodexDesktopModelConfig `
            -Model ("safe`"$newLine" + 'model_provider = "leak"') `
            -Provider openai `
            -ReasoningEffort high `
            -ConfigPath $configPath `
            -SkipBackup | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $beforeInjection,
            [IO.File]::ReadAllBytes($configPath)
        )) `
        -Message 'injection failure leaves config unchanged'

    $duplicateConfig = Join-Path $securityTempRoot 'config-tests\duplicate.toml'
    Write-SecurityText `
        -Path $duplicateConfig `
        -Content ("model = `"one`"$newLine" + "model = `"two`"$newLine")
    $duplicateBefore = [IO.File]::ReadAllBytes($duplicateConfig)
    Assert-SecurityThrows -Message 'duplicate managed key rejected' -Action {
        Set-CodexDesktopModelConfig `
            -Model 'gpt-safe' `
            -Provider openai `
            -ReasoningEffort high `
            -ConfigPath $duplicateConfig `
            -SkipBackup | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $duplicateBefore,
            [IO.File]::ReadAllBytes($duplicateConfig)
        )) `
        -Message 'duplicate-key failure leaves config unchanged'

    $multiValueConfig = Join-Path $securityTempRoot 'config-tests\multivalue.toml'
    Write-SecurityText `
        -Path $multiValueConfig `
        -Content ('model = """' + $newLine + 'unsafe' + $newLine + '"""' + $newLine)
    Assert-SecurityThrows -Message 'multiline managed value rejected' -Action {
        Set-CodexDesktopModelConfig `
            -Model 'gpt-safe' `
            -Provider openai `
            -ReasoningEffort high `
            -ConfigPath $multiValueConfig `
            -SkipBackup | Out-Null
    }

    $malformedCatalogs = @(
        [pscustomobject]@{
            Name = 'messages-string'
            Data = [pscustomobject]@{
                models = @([pscustomobject]@{
                    slug = 'valid/model'
                    model_messages = 'invalid'
                })
            }
        },
        [pscustomobject]@{
            Name = 'missing-slug'
            Data = [pscustomobject]@{
                models = @([pscustomobject]@{ base_instructions = 'prompt' })
            }
        },
        [pscustomobject]@{
            Name = 'scalar-model-object'
            Data = [pscustomobject]@{
                models = [pscustomobject]@{
                    slug = 'valid/model'
                    base_instructions = 'prompt'
                }
            }
        },
        [pscustomobject]@{
            Name = 'standard-data-shape'
            Data = [pscustomobject]@{
                data = @([pscustomobject]@{ id = 'valid/model' })
            }
        }
    )
    foreach ($case in $malformedCatalogs) {
        $casePath = Join-Path $securityTempRoot "catalog-$($case.Name).json"
        Write-SecurityText `
            -Path $casePath `
            -Content ($case.Data | ConvertTo-Json -Depth 20)
        Assert-SecurityTrue `
            -Condition (-not (Test-CodexModelCatalog `
                -Path $casePath `
                -MinimumModelCount 1)) `
            -Message "malformed catalog rejected: $($case.Name)"
    }

    $escapedSecretCatalog = Join-Path `
        $securityTempRoot `
        'catalog-escaped-secret.json'
    $escapedSecretText = '{"models":[{"slug":"valid/model","base_instructions":"prompt","diagnostic":"sk-or-\u0078xxxxxxxxxxxx"}]}'
    Write-SecurityText -Path $escapedSecretCatalog -Content $escapedSecretText
    Assert-SecurityTrue `
        -Condition (-not (Test-CodexModelCatalog `
            -Path $escapedSecretCatalog `
            -MinimumModelCount 1)) `
        -Message 'Unicode escaped secret-like catalog value rejected'
    $escapedSecretBefore = [IO.File]::ReadAllBytes($escapedSecretCatalog)
    Assert-SecurityThrows -Message 'secret-like catalog prompt rewrite rejected' -Action {
        Set-OpenRouterAgentInstructions -Path $escapedSecretCatalog | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $escapedSecretBefore,
            [IO.File]::ReadAllBytes($escapedSecretCatalog)
        )) `
        -Message 'rejected catalog remains byte-identical'
    $escapedSecretNameCatalog = Join-Path `
        $securityTempRoot `
        'catalog-escaped-secret-name.json'
    $escapedSecretNameText = '{"models":[{"slug":"valid/model","base_instructions":"prompt","sk-or-\u0078xxxxxxxxxxxx":"diagnostic"}]}'
    Write-SecurityText `
        -Path $escapedSecretNameCatalog `
        -Content $escapedSecretNameText
    Assert-SecurityTrue `
        -Condition (-not (Test-CodexModelCatalog `
            -Path $escapedSecretNameCatalog `
            -MinimumModelCount 1)) `
        -Message 'Unicode escaped secret-like property name rejected'

    $timestampCatalog = Join-Path $securityTempRoot 'timestamp-catalog.json'
    Copy-Item -LiteralPath $modernFixture -Destination $timestampCatalog
    $oldTimestamp = [DateTime]::UtcNow.AddDays(-3)
    [IO.File]::SetLastWriteTimeUtc($timestampCatalog, $oldTimestamp)
    [void](Set-OpenRouterAgentInstructions `
        -Path $timestampCatalog `
        -PreserveLastWriteTime)
    $actualTimestamp = (Get-Item -LiteralPath $timestampCatalog).LastWriteTimeUtc
    Assert-SecurityTrue `
        -Condition ([Math]::Abs(($actualTimestamp - $oldTimestamp).TotalSeconds) -lt 2) `
        -Message 'prompt rewrite preserves catalog freshness timestamp'

    $unexpectedUriRejected = $false
    $module = Get-Module CodexOpenRouter
    try {
        & $module {
            param($Key)
            Invoke-OpenRouterCatalogDownload `
                -Uri 'https://example.invalid/api/v1/models' `
                -ClientVersion '1.2.3' `
                -ApiKey $Key
        } $syntheticKey
    }
    catch {
        $unexpectedUriRejected = $true
    }
    Assert-SecurityTrue `
        -Condition $unexpectedUriRejected `
        -Message 'catalog downloader rejects unexpected host before network access'

    $outputLimitRejected = $false
    $module = Get-Module CodexOpenRouter
    try {
        & $module {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            [void]$startInfo.ArgumentList.Add('-NoProfile')
            [void]$startInfo.ArgumentList.Add('-Command')
            [void]$startInfo.ArgumentList.Add(
                "[Console]::Out.Write('x' * 50000)"
            )
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            try {
                Read-CodexProcessOutputLimited `
                    -Process $process `
                    -TimeoutMilliseconds 10000 `
                    -MaximumStandardOutputBytes 1024 `
                    -MaximumStandardErrorBytes 1024 `
                    -Context 'security output limit' | Out-Null
            }
            finally {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    $process.WaitForExit()
                }
                $process.Dispose()
            }
        }
    }
    catch {
        $outputLimitRejected = $true
    }
    Assert-SecurityTrue `
        -Condition $outputLimitRejected `
        -Message 'streaming process output limit enforced'

    $originalPathEnvironment = $env:PATH
    $shadowRoot = Join-Path $securityTempRoot 'path-shadow'
    [void](New-Item -ItemType Directory -Path $shadowRoot -Force)
    Write-SecurityText `
        -Path (Join-Path $shadowRoot 'codex.exe') `
        -Content 'untrusted fixture'
    try {
        $env:PATH = $shadowRoot + [IO.Path]::PathSeparator + $originalPathEnvironment
        $selectedCli = $null
        try { $selectedCli = Get-CodexCliPath } catch { }
        if ($selectedCli) {
            Assert-SecurityTrue `
                -Condition (-not ([IO.Path]::GetFullPath($selectedCli).StartsWith(
                    [IO.Path]::GetFullPath($shadowRoot),
                    [StringComparison]::OrdinalIgnoreCase
                ))) `
                -Message 'PATH shadow ignored by trusted CLI discovery'
        }
    }
    finally {
        $env:PATH = $originalPathEnvironment
    }

    $invalidInstallHome = Join-Path $securityTempRoot 'invalid-install\.codex'
    $invalidInstallProfile = Join-Path $securityTempRoot 'invalid-install\profile.ps1'
    Assert-SecurityThrows -Message 'installer model injection rejected before mutation' -Action {
        & $installerPath `
            -CodexHome $invalidInstallHome `
            -ProfilePath $invalidInstallProfile `
            -OpenRouterModel ("safe`"$newLine" + 'model_provider = "leak"') `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $invalidInstallHome)) `
        -Message 'invalid installer input creates no CodexHome'

    $secretModelInstallHome = Join-Path `
        $securityTempRoot `
        'secret-model-install\.codex'
    $secretModelInstallProfile = Join-Path `
        $securityTempRoot `
        'secret-model-install\profile.ps1'
    $secretModelError = $null
    try {
        & $installerPath `
            -CodexHome $secretModelInstallHome `
            -ProfilePath $secretModelInstallProfile `
            -OpenRouterModel $syntheticKey `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    catch {
        $secretModelError = $_.Exception.Message
    }
    Assert-SecurityTrue `
        -Condition (-not [string]::IsNullOrWhiteSpace($secretModelError)) `
        -Message 'installer rejects API-key-shaped model before mutation'
    Assert-SecurityTrue `
        -Condition (-not $secretModelError.Contains($syntheticKey)) `
        -Message 'model validation error does not echo API-key-shaped input'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $secretModelInstallHome)) `
        -Message 'API-key-shaped model creates no CodexHome'

    $oversizedConfigHome = Join-Path `
        $securityTempRoot `
        'oversized-config-install\.codex'
    $oversizedConfigProfile = Join-Path `
        $securityTempRoot `
        'oversized-config-install\profile.ps1'
    $oversizedConfigPath = Join-Path $oversizedConfigHome 'config.toml'
    Write-SecurityText `
        -Path $oversizedConfigProfile `
        -Content 'function Keep-Oversized-Profile { 1 }'
    [void][IO.Directory]::CreateDirectory($oversizedConfigHome)
    $oversizedConfigStream = [IO.File]::Open(
        $oversizedConfigPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try { $oversizedConfigStream.SetLength((5MB) + 1) }
    finally { $oversizedConfigStream.Dispose() }
    $oversizedProfileBytes = [IO.File]::ReadAllBytes($oversizedConfigProfile)
    Assert-SecurityThrows `
        -Message 'installer rejects config larger than five MiB before mutation' `
        -Action {
        & $installerPath `
            -CodexHome $oversizedConfigHome `
            -ProfilePath $oversizedConfigProfile `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path `
                $oversizedConfigHome `
                'codex-openrouter-toolkit'))) `
        -Message 'oversized config creates no active install root'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $oversizedProfileBytes,
            [IO.File]::ReadAllBytes($oversizedConfigProfile)
        )) `
        -Message 'oversized config rejection preserves profile'

    $configRaceHome = Join-Path `
        $securityTempRoot `
        'config-freeze-race\.codex'
    $configRaceProfile = Join-Path `
        $securityTempRoot `
        'config-freeze-race\profile.ps1'
    $configRacePath = Join-Path $configRaceHome 'config.toml'
    $configRaceBackupRoot = Join-Path `
        $configRaceHome `
        'codex-openrouter-toolkit-backups'
    Write-SecurityText -Path $configRaceProfile -Content 'function Keep-Race { 1 }'
    Write-SecurityText `
        -Path $configRacePath `
        -Content ("model = `"gpt-before-race`"$newLine" +
            "model_reasoning_effort = `"low`"$newLine")
    $global:CodexToolkitConfigRaceBackupRoot = $configRaceBackupRoot
    $global:CodexToolkitConfigRacePath = $configRacePath
    $global:CodexToolkitConfigRaceInjected = $false
    function New-Item {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$ItemType,
            [Parameter(Mandatory = $true)][string]$Path,
            [switch]$Force
        )

        $result = Microsoft.PowerShell.Management\New-Item `
            -ItemType $ItemType `
            -Path $Path `
            -Force:$Force `
            -ErrorAction Stop
        if (-not $global:CodexToolkitConfigRaceInjected -and
            (Test-ToolkitPathEqual `
                -Left $Path `
                -Right $global:CodexToolkitConfigRaceBackupRoot)) {
            $global:CodexToolkitConfigRaceInjected = $true
            [IO.File]::WriteAllText(
                $global:CodexToolkitConfigRacePath,
                "model = `"external-race`"$newLine",
                [Text.UTF8Encoding]::new($false)
            )
        }
        return $result
    }
    $configRaceError = $null
    try {
        & $installerPath `
            -CodexHome $configRaceHome `
            -ProfilePath $configRaceProfile `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    catch {
        $configRaceError = $_.Exception.Message
    }
    finally {
        Remove-Item Function:\New-Item -Force -ErrorAction SilentlyContinue
        $configRaceInjected = [bool]$global:CodexToolkitConfigRaceInjected
        Remove-Variable `
            -Name CodexToolkitConfigRaceBackupRoot `
            -Scope Global `
            -ErrorAction SilentlyContinue
        Remove-Variable `
            -Name CodexToolkitConfigRacePath `
            -Scope Global `
            -ErrorAction SilentlyContinue
        Remove-Variable `
            -Name CodexToolkitConfigRaceInjected `
            -Scope Global `
            -ErrorAction SilentlyContinue
    }
    Assert-SecurityTrue `
        -Condition $configRaceInjected `
        -Message 'config race fixture mutates after the frozen snapshot'
    Assert-SecurityTrue `
        -Condition ($configRaceError.Contains('冻结快照')) `
        -Message 'installer rejects config changed after its frozen snapshot'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($configRacePath).Trim()) `
        -Expected 'model = "external-race"' `
        -Message 'config freeze CAS preserves concurrent external content'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path `
                $configRaceHome `
                'codex-openrouter-toolkit'))) `
        -Message 'config freeze conflict publishes no active install root'

    $rollbackHome = Join-Path $securityTempRoot 'rollback-install\.codex'
    $rollbackProfile = Join-Path $securityTempRoot 'rollback-install\profile.ps1'
    $rollbackConfig = Join-Path $rollbackHome 'config.toml'
    Write-SecurityText -Path $rollbackProfile -Content 'function Broken {'
    Write-SecurityText -Path $rollbackConfig -Content ''
    $rollbackProfileTimestamp = [DateTime]::UtcNow.AddDays(-8)
    $rollbackConfigTimestamp = [DateTime]::UtcNow.AddDays(-7)
    [IO.File]::SetLastWriteTimeUtc(
        $rollbackProfile,
        $rollbackProfileTimestamp
    )
    [IO.File]::SetLastWriteTimeUtc(
        $rollbackConfig,
        $rollbackConfigTimestamp
    )
    $rollbackProfileBefore = [IO.File]::ReadAllBytes($rollbackProfile)
    Assert-SecurityThrows -Message 'first install failure rolls back' -Action {
        & $installerPath `
            -CodexHome $rollbackHome `
            -ProfilePath $rollbackProfile `
            -OpenAIModel 'gpt-original' `
            -OpenAIReasoningEffort low `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path $rollbackHome 'codex-openrouter-toolkit'))) `
        -Message 'failed first install leaves no active install root'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $rollbackProfileBefore,
            [IO.File]::ReadAllBytes($rollbackProfile)
        )) `
        -Message 'failed first install restores profile bytes'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $rollbackConfig).Length `
        -Expected ([long]0) `
        -Message 'failed first install restores empty config'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $rollbackProfile).LastWriteTimeUtc `
        -Expected $rollbackProfileTimestamp `
        -Message 'failed first install restores profile LastWriteTimeUtc'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $rollbackConfig).LastWriteTimeUtc `
        -Expected $rollbackConfigTimestamp `
        -Message 'failed first install restores config LastWriteTimeUtc'

    $partialInstallHome = Join-Path `
        $securityTempRoot `
        'partial-install-copy\.codex'
    $partialInstallProfile = Join-Path `
        $securityTempRoot `
        'partial-install-copy\profile.ps1'
    Write-SecurityText -Path $partialInstallProfile -Content ''
    $global:CodexToolkitStagedExternalInjected = $false
    function Get-Acl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string]$LiteralPath
        )

        $fullPath = [IO.Path]::GetFullPath($LiteralPath)
        $settingsSuffix = [IO.Path]::DirectorySeparatorChar +
            'new-install' + [IO.Path]::DirectorySeparatorChar +
            'settings.json'
        if (-not $global:CodexToolkitStagedExternalInjected -and
            $fullPath.EndsWith(
                $settingsSuffix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            [IO.File]::WriteAllText(
                (Join-Path (Split-Path -Parent $fullPath) 'external.txt'),
                'external-preserved',
                [Text.UTF8Encoding]::new($false)
            )
            $global:CodexToolkitStagedExternalInjected = $true
        }
        Microsoft.PowerShell.Security\Get-Acl `
            -LiteralPath $LiteralPath `
            -ErrorAction Stop
    }
    try {
        Assert-SecurityThrows `
            -Message 'staged external file blocks active install publication' `
            -Action {
            & $installerPath `
                -CodexHome $partialInstallHome `
                -ProfilePath $partialInstallProfile `
                -SkipCatalogRefresh `
                -SkipProfileReload | Out-Null
        }
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item `
            Function:\Get-Acl `
            -Force `
            -ErrorAction SilentlyContinue
        $stagedExternalInjected =
            [bool]$global:CodexToolkitStagedExternalInjected
        Remove-Variable `
            -Name CodexToolkitStagedExternalInjected `
            -Scope Global `
            -ErrorAction SilentlyContinue
    }
    Assert-SecurityTrue `
        -Condition $stagedExternalInjected `
        -Message 'external file was injected into staged install tree'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath (Join-Path `
            $partialInstallHome `
            'codex-openrouter-toolkit'))) `
        -Message 'unexpected staged file prevents active install publication'
    $preservedExternalFiles = @(Get-ChildItem `
        -LiteralPath (Join-Path `
            $partialInstallHome `
            'codex-openrouter-toolkit-backups') `
        -Filter external.txt `
        -File `
        -Recurse `
        -Force)
    Assert-SecurityEqual `
        -Actual $preservedExternalFiles.Count `
        -Expected 1 `
        -Message 'unexpected staged file is preserved outside active install'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($preservedExternalFiles[0].FullName)) `
        -Expected 'external-preserved' `
        -Message 'unexpected staged file content remains unchanged'

    $upgradeHome = Join-Path $securityTempRoot 'upgrade-install\.codex'
    $upgradeProfile = Join-Path $securityTempRoot 'upgrade-install\profile.ps1'
    $upgradeConfig = Join-Path $upgradeHome 'config.toml'
    $upgradeCatalog = Join-Path $upgradeHome 'openrouter-model-catalog.json'
    Write-SecurityText -Path $upgradeProfile -Content ''
    $restoreProfileSddl = $null
    $restoreProfileExpectedAcl = $null
    if ($IsWindows) {
        $restoreProfileAcl = Get-Acl -LiteralPath $upgradeProfile
        $restoreProfileAcl.SetAccessRuleProtection($true, $false)
        $restoreProfileRule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl',
            'Allow'
        )
        $restoreProfileAcl.SetAccessRule($restoreProfileRule)
        Set-Acl -LiteralPath $upgradeProfile -AclObject $restoreProfileAcl
        $restoreProfileExpectedAcl = Get-Acl -LiteralPath $upgradeProfile
        $restoreProfileSddl = $restoreProfileExpectedAcl.Sddl
    }
    Write-SecurityText `
        -Path $upgradeConfig `
        -Content ("model = `"gpt-original`"$newLine" +
            "model_reasoning_effort = `"low`"$newLine")
    Copy-Item -LiteralPath $modernFixture -Destination $upgradeCatalog
    $restoreProfileTimestamp = [DateTime]::UtcNow.AddDays(-6)
    $restoreConfigTimestamp = [DateTime]::UtcNow.AddDays(-5)
    $restoreCatalogTimestamp = [DateTime]::UtcNow.AddDays(-4)
    [IO.File]::SetLastWriteTimeUtc(
        $upgradeProfile,
        $restoreProfileTimestamp
    )
    [IO.File]::SetLastWriteTimeUtc(
        $upgradeConfig,
        $restoreConfigTimestamp
    )
    [IO.File]::SetLastWriteTimeUtc(
        $upgradeCatalog,
        $restoreCatalogTimestamp
    )
    $firstInstall = & $installerPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -OpenAIModel 'gpt-original' `
        -OpenAIReasoningEffort low `
        -OpenRouterModel 'anthropic/custom-model' `
        -OpenRouterReasoningEffort medium `
        -CatalogMaximumAgeHours 48 `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $firstManifest = [IO.File]::ReadAllText(
        (Join-Path $firstInstall.BackupPath 'manifest.json')
    ) | ConvertFrom-Json
    Assert-SecurityEqual -Actual ([int]$firstManifest.SchemaVersion) -Expected 3 -Message 'schema 3 install backup'
    Assert-SecurityEqual -Actual @($firstManifest.Files).Count -Expected 5 -Message 'five managed backup entries'
    $emptyProfileEntry = @($firstManifest.Files | Where-Object Name -eq 'profile')[0]
    Assert-SecurityTrue `
        -Condition ([string]$emptyProfileEntry.Sha256 -cmatch '^[A-F0-9]{64}$') `
        -Message 'empty profile backup hash recorded'
    Assert-SecurityEqual `
        -Actual (([DateTime]$emptyProfileEntry.LastWriteTimeUtc).ToUniversalTime()) `
        -Expected $restoreProfileTimestamp `
        -Message 'profile backup records original LastWriteTimeUtc'
    if ($IsWindows) {
        Assert-SecurityEqual `
            -Actual ([string]$emptyProfileEntry.AclSddl) `
            -Expected $restoreProfileSddl `
            -Message 'profile backup records original ACL policy'
    }
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath (Join-Path $firstInstall.BackupPath 'profile.bak')).Length `
        -Expected ([long]0) `
        -Message 'empty profile backup retained'
    Assert-SecurityEqual `
        -Actual ((Get-Item `
            -LiteralPath (Join-Path `
                $firstInstall.BackupPath `
                'profile.bak')).LastWriteTimeUtc) `
        -Expected $restoreProfileTimestamp `
        -Message 'backup file preserves source LastWriteTimeUtc'

    $secondInstall = & $installerPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $upgradedSettingsPath = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit\settings.json'
    $upgradedSettings = [IO.File]::ReadAllText($upgradedSettingsPath) | ConvertFrom-Json
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenAIModel) -Expected 'gpt-original' -Message 'upgrade preserves OpenAI model'
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenAIReasoningEffort) -Expected 'low' -Message 'upgrade preserves OpenAI effort'
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenRouterModel) -Expected 'anthropic/custom-model' -Message 'upgrade preserves OpenRouter model'
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenRouterReasoningEffort) -Expected 'medium' -Message 'upgrade preserves OpenRouter effort'
    Assert-SecurityEqual -Actual ([int]$upgradedSettings.CatalogMaximumAgeHours) -Expected 48 -Message 'upgrade preserves catalog age'
    $secondManifest = [IO.File]::ReadAllText(
        (Join-Path $secondInstall.BackupPath 'manifest.json')
    ) | ConvertFrom-Json
    Assert-SecurityTrue `
        -Condition (@($secondManifest.PreviousInstallFiles).Count -gt 0) `
        -Message 'upgrade backup persists previous install inventory'

    $existingRestoreHome = Join-Path `
        $securityTempRoot `
        'existing-install-restore\.codex'
    $existingRestoreProfile = Join-Path `
        $securityTempRoot `
        'existing-install-restore\profile.ps1'
    Write-SecurityText -Path $existingRestoreProfile -Content ''
    $existingFirstInstall = & $installerPath `
        -CodexHome $existingRestoreHome `
        -ProfilePath $existingRestoreProfile `
        -OpenRouterModel 'anthropic/pre-upgrade' `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $existingSecondInstall = & $installerPath `
        -CodexHome $existingRestoreHome `
        -ProfilePath $existingRestoreProfile `
        -OpenRouterModel 'anthropic/post-upgrade' `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $existingSettingsPath = Join-Path `
        $existingRestoreHome `
        'codex-openrouter-toolkit\settings.json'
    $global:CodexToolkitRestoreExternalInjected = $false
    function Set-Acl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [Parameter(Mandatory = $true)][object]$AclObject
        )

        Microsoft.PowerShell.Security\Set-Acl `
            -LiteralPath $LiteralPath `
            -AclObject $AclObject `
            -ErrorAction Stop
        if ($global:CodexToolkitRestoreExternalInjected) { return }
        $probePath = Split-Path -Parent ([IO.Path]::GetFullPath($LiteralPath))
        while (-not [string]::IsNullOrWhiteSpace($probePath)) {
            if ([IO.Path]::GetFileName($probePath) -ceq
                'staged-previous-install') {
                $global:CodexToolkitRestoreExternalInjected = $true
                [IO.File]::WriteAllText(
                    (Join-Path $probePath 'external.txt'),
                    'preserve-external-staging',
                    [Text.UTF8Encoding]::new($false)
                )
                break
            }
            $parentPath = Split-Path -Parent $probePath
            if ([string]::IsNullOrWhiteSpace($parentPath) -or
                $parentPath -ceq $probePath) {
                break
            }
            $probePath = $parentPath
        }
    }
    $existingExternalRestoreError = $null
    try {
        & $restorePath `
            -BackupPath $existingSecondInstall.BackupPath `
            -CodexHome $existingRestoreHome `
            -ProfilePath $existingRestoreProfile `
            -Force | Out-Null
    }
    catch {
        $existingExternalRestoreError = $_.Exception.Message
    }
    finally {
        Remove-Item Function:\Set-Acl -Force -ErrorAction SilentlyContinue
        $existingRestoreExternalInjected =
            [bool]$global:CodexToolkitRestoreExternalInjected
        Remove-Variable `
            -Name CodexToolkitRestoreExternalInjected `
            -Scope Global `
            -ErrorAction SilentlyContinue
    }
    Assert-SecurityTrue `
        -Condition $existingRestoreExternalInjected `
        -Message 'restore staging external-file fixture was injected'
    Assert-SecurityTrue `
        -Condition (-not [string]::IsNullOrWhiteSpace(
            $existingExternalRestoreError
        )) `
        -Message 'restore rejects an external staging addition'
    $existingPostConflictSettings =
        [IO.File]::ReadAllText($existingSettingsPath) | ConvertFrom-Json
    Assert-SecurityEqual `
        -Actual ([string]$existingPostConflictSettings.OpenRouterModel) `
        -Expected 'anthropic/post-upgrade' `
        -Message 'precommit staging conflict preserves active upgraded install'
    $retainedExternalStagingFiles = @(Get-ChildItem `
        -LiteralPath $existingRestoreHome `
        -Filter 'external.txt' `
        -File `
        -Recurse `
        -Force)
    Assert-SecurityEqual `
        -Actual $retainedExternalStagingFiles.Count `
        -Expected 1 `
        -Message 'external staging file is retained and never adopted for deletion'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText(
            $retainedExternalStagingFiles[0].FullName
        )) `
        -Expected 'preserve-external-staging' `
        -Message 'retained external staging content remains intact'

    $existingRestoreResult = & $restorePath `
        -BackupPath $existingSecondInstall.BackupPath `
        -CodexHome $existingRestoreHome `
        -ProfilePath $existingRestoreProfile `
        -Force
    Assert-SecurityTrue `
        -Condition $existingRestoreResult.Restored `
        -Message 'existing-install schema 3 restore succeeds'
    $existingRestoredSettings =
        [IO.File]::ReadAllText($existingSettingsPath) | ConvertFrom-Json
    Assert-SecurityEqual `
        -Actual ([string]$existingRestoredSettings.OpenRouterModel) `
        -Expected 'anthropic/pre-upgrade' `
        -Message 'existing-install restore publishes the frozen previous install'
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    & $uninstallerPath `
        -CodexHome $existingRestoreHome `
        -ProfilePath $existingRestoreProfile `
        -KeepCurrentProvider | Out-Null

    $compatibilityBackupRoot = Split-Path -Parent $firstInstall.BackupPath
    $schemaTwoBackup = Join-Path `
        $compatibilityBackupRoot `
        'schema-two-compatibility-fixture'
    Copy-Item `
        -LiteralPath $firstInstall.BackupPath `
        -Destination $schemaTwoBackup `
        -Recurse
    $schemaTwoManifestPath = Join-Path $schemaTwoBackup 'manifest.json'
    $schemaTwoManifest = [IO.File]::ReadAllText($schemaTwoManifestPath) |
        ConvertFrom-Json
    $schemaTwoManifest.SchemaVersion = 2
    foreach ($schemaTwoEntry in @($schemaTwoManifest.Files)) {
        $schemaTwoEntry.PSObject.Properties.Remove('LastWriteTimeUtc')
    }
    Write-SecurityText `
        -Path $schemaTwoManifestPath `
        -Content ($schemaTwoManifest | ConvertTo-Json -Depth 10)
    $schemaTwoWhatIf = & $restorePath `
        -BackupPath $schemaTwoBackup `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -Force `
        -WhatIf
    Assert-SecurityTrue `
        -Condition (-not $schemaTwoWhatIf.Restored) `
        -Message 'schema 2 backup remains readable'

    $schemaOneBackup = Join-Path `
        $compatibilityBackupRoot `
        'schema-one-compatibility-fixture'
    Copy-Item `
        -LiteralPath $firstInstall.BackupPath `
        -Destination $schemaOneBackup `
        -Recurse
    $schemaOneManifestPath = Join-Path $schemaOneBackup 'manifest.json'
    $schemaOneManifest = [IO.File]::ReadAllText($schemaOneManifestPath) |
        ConvertFrom-Json
    $schemaOneManifest.SchemaVersion = 1
    foreach ($schemaOneEntry in @($schemaOneManifest.Files)) {
        $schemaOneBackupFile = if ([bool]$schemaOneEntry.Existed) {
            Join-Path `
                $schemaOneBackup `
                ([string]$schemaOneEntry.BackupRelativePath)
        }
        else {
            $null
        }
        foreach ($schemaOneRemovedProperty in @(
                'BackupRelativePath',
                'Sha256',
                'AclSddl',
                'LastWriteTimeUtc'
            )) {
            $schemaOneEntry.PSObject.Properties.Remove(
                $schemaOneRemovedProperty
            )
        }
        Add-Member `
            -InputObject $schemaOneEntry `
            -MemberType NoteProperty `
            -Name BackupFile `
            -Value $schemaOneBackupFile
    }
    Write-SecurityText `
        -Path $schemaOneManifestPath `
        -Content ($schemaOneManifest | ConvertTo-Json -Depth 10)
    $schemaOneWhatIf = & $restorePath `
        -BackupPath $schemaOneBackup `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -Force `
        -WhatIf
    Assert-SecurityTrue `
        -Condition (-not $schemaOneWhatIf.Restored) `
        -Message 'schema 1 backup remains readable'

    $oversizedManifestBackup = Join-Path `
        $compatibilityBackupRoot `
        'oversized-manifest-fixture'
    Copy-Item `
        -LiteralPath $firstInstall.BackupPath `
        -Destination $oversizedManifestBackup `
        -Recurse
    $oversizedManifestPath = Join-Path `
        $oversizedManifestBackup `
        'manifest.json'
    $upgradeSettingsBeforeOversizedManifest =
        [IO.File]::ReadAllBytes($upgradedSettingsPath)
    $oversizedManifestStream = [IO.File]::Open(
        $oversizedManifestPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try { $oversizedManifestStream.SetLength((5MB) + 1) }
    finally { $oversizedManifestStream.Dispose() }
    Assert-SecurityThrows `
        -Message 'restore rejects manifest larger than five MiB before mutation' `
        -Action {
        & $restorePath `
            -BackupPath $oversizedManifestBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $upgradeSettingsBeforeOversizedManifest,
            [IO.File]::ReadAllBytes($upgradedSettingsPath)
        )) `
        -Message 'oversized restore manifest preserves active install settings'

    $excessInventoryBackup = Join-Path `
        $compatibilityBackupRoot `
        'excess-inventory-fixture'
    Copy-Item `
        -LiteralPath $secondInstall.BackupPath `
        -Destination $excessInventoryBackup `
        -Recurse
    $excessInventoryManifestPath = Join-Path `
        $excessInventoryBackup `
        'manifest.json'
    $excessInventoryManifest = [IO.File]::ReadAllText(
        $excessInventoryManifestPath
    ) | ConvertFrom-Json
    $excessInventoryEntries = [Collections.Generic.List[object]]::new()
    foreach ($inventoryIndex in 0..1024) {
        $excessInventoryEntries.Add([pscustomobject]@{
            RelativePath = "CodexOpenRouter\inventory-$inventoryIndex.bin"
            Length = 0
            Sha256 = 'A' * 64
        })
    }
    $excessInventoryManifest.PreviousInstallFiles = @(
        $excessInventoryEntries
    )
    Write-SecurityText `
        -Path $excessInventoryManifestPath `
        -Content ($excessInventoryManifest | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows `
        -Message 'restore rejects more than 1024 previous-install entries' `
        -Action {
        & $restorePath `
            -BackupPath $excessInventoryBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $upgradeSettingsBeforeOversizedManifest,
            [IO.File]::ReadAllBytes($upgradedSettingsPath)
        )) `
        -Message 'excess previous-install inventory preserves active settings'

    $previousModuleInBackup = Join-Path `
        $secondInstall.BackupPath `
        'previous-install\CodexOpenRouter\CodexOpenRouter.psm1'
    $previousModuleBytes = [IO.File]::ReadAllBytes($previousModuleInBackup)
    [IO.File]::WriteAllText(
        $previousModuleInBackup,
        ([IO.File]::ReadAllText($previousModuleInBackup) +
            "$newLine# tampered previous install"),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-SecurityThrows -Message 'tampered previous install inventory rejected' -Action {
        & $restorePath `
            -BackupPath $secondInstall.BackupPath `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($previousModuleInBackup, $previousModuleBytes)

    $installedManifest = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit\CodexOpenRouter\CodexOpenRouter.psd1'
    Import-Module -Name $installedManifest -Force
    [void](Get-CodexOpenRouterSettings -SettingsPath $upgradedSettingsPath)
    $validSettingsText = [IO.File]::ReadAllText($upgradedSettingsPath)
    $tamperedSettings = $validSettingsText | ConvertFrom-Json
    $tamperedSettings.ConfigPath = Join-Path $securityTempRoot 'outside-config.toml'
    Write-SecurityText `
        -Path $upgradedSettingsPath `
        -Content ($tamperedSettings | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'module rejects tampered fixed settings path' -Action {
        Get-CodexOpenRouterSettings -SettingsPath $upgradedSettingsPath | Out-Null
    }
    Write-SecurityText -Path $upgradedSettingsPath -Content $validSettingsText

    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    $partialRestoreInstallRoot = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit'
    $heldActiveInstall = Join-Path `
        $upgradeHome `
        'held-active-install-for-partial-copy-test'
    Move-Item `
        -LiteralPath $partialRestoreInstallRoot `
        -Destination $heldActiveInstall
    $partialRestoreError = $null
    function Set-Acl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [Parameter(Mandatory = $true)][object]$AclObject
        )

        $resolvedAclPath = [IO.Path]::GetFullPath($LiteralPath)
        $stagedInstallSegment =
            [IO.Path]::DirectorySeparatorChar +
            'staged-previous-install' +
            [IO.Path]::DirectorySeparatorChar
        if ($resolvedAclPath.Contains(
                $stagedInstallSegment,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            [IO.Path]::GetFileName($resolvedAclPath) -like '*.tmp-*') {
            throw 'forced previous-install copy failure'
        }
        Microsoft.PowerShell.Security\Set-Acl `
            -LiteralPath $LiteralPath `
            -AclObject $AclObject `
            -ErrorAction Stop
    }
    try {
        & $restorePath `
            -BackupPath $secondInstall.BackupPath `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    catch {
        $partialRestoreError = $_.Exception.Message
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item `
            -LiteralPath Function:\Set-Acl `
            -Force `
            -ErrorAction SilentlyContinue
    }
    Assert-SecurityTrue `
        -Condition (-not [string]::IsNullOrWhiteSpace($partialRestoreError)) `
        -Message 'partial previous-install copy failure is reported'
    Assert-SecurityTrue `
        -Condition $partialRestoreError.Contains('已还原事务前状态') `
        -Message 'partial previous-install copy reports completed rollback'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $partialRestoreInstallRoot)) `
        -Message 'partial previous-install directory is removed during rollback'
    Move-Item `
        -LiteralPath $heldActiveInstall `
        -Destination $partialRestoreInstallRoot

    $victimPath = Join-Path $securityTempRoot 'victim.ps1'
    Write-SecurityText -Path $victimPath -Content 'victim-safe'
    $maliciousBackup = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit-backups\malicious-fixture'
    Copy-Item `
        -LiteralPath $secondInstall.BackupPath `
        -Destination $maliciousBackup `
        -Recurse
    $maliciousManifestPath = Join-Path $maliciousBackup 'manifest.json'
    $maliciousManifest = [IO.File]::ReadAllText($maliciousManifestPath) |
        ConvertFrom-Json
    $maliciousProfileEntry = @(
        $maliciousManifest.Files | Where-Object Name -eq 'profile'
    )[0]
    $validLastWriteTimeUtc = $maliciousProfileEntry.LastWriteTimeUtc
    $maliciousProfileEntry.LastWriteTimeUtc = 'not-a-utc-timestamp'
    Write-SecurityText `
        -Path $maliciousManifestPath `
        -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'restore rejects malformed UTC timestamp metadata' -Action {
        & $restorePath `
            -BackupPath $maliciousBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    $maliciousProfileEntry.LastWriteTimeUtc =
        '2026-08-27T12:00:00.0000000'
    Write-SecurityText `
        -Path $maliciousManifestPath `
        -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'restore rejects timestamp without UTC marker' -Action {
        & $restorePath `
            -BackupPath $maliciousBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    $maliciousProfileEntry.PSObject.Properties.Remove('LastWriteTimeUtc')
    Write-SecurityText `
        -Path $maliciousManifestPath `
        -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'schema 3 requires timestamp field' -Action {
        & $restorePath `
            -BackupPath $maliciousBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    Add-Member `
        -InputObject $maliciousProfileEntry `
        -MemberType NoteProperty `
        -Name LastWriteTimeUtc `
        -Value $validLastWriteTimeUtc
    $nonexistentTimestampEntry = @(
        $maliciousManifest.Files | Where-Object { -not [bool]$_.Existed }
    )[0]
    Assert-SecurityTrue `
        -Condition ($null -ne $nonexistentTimestampEntry) `
        -Message 'schema 3 fixture includes a non-existing managed file'
    $nonexistentTimestampEntry.LastWriteTimeUtc = [DateTime]::UtcNow
    Write-SecurityText `
        -Path $maliciousManifestPath `
        -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows `
        -Message 'schema 3 rejects timestamp for Existed=false entry' `
        -Action {
        & $restorePath `
            -BackupPath $maliciousBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    $nonexistentTimestampEntry.LastWriteTimeUtc = $null
    $maliciousProfileEntry.LastWriteTimeUtc = $validLastWriteTimeUtc
    if ($IsWindows) {
        $validAclSddl = [string]$maliciousProfileEntry.AclSddl
        $maliciousProfileEntry.AclSddl = 'invalid-sddl'
        Write-SecurityText `
            -Path $maliciousManifestPath `
            -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
        Assert-SecurityThrows -Message 'restore rejects malformed ACL metadata' -Action {
            & $restorePath `
                -BackupPath $maliciousBackup `
                -CodexHome $upgradeHome `
                -ProfilePath $upgradeProfile `
                -Force | Out-Null
        }
        $maliciousProfileEntry.AclSddl = $null
        Write-SecurityText `
            -Path $maliciousManifestPath `
            -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
        Assert-SecurityThrows `
            -Message 'Windows schema 3 rejects null ACL metadata' `
            -Action {
                & $restorePath `
                    -BackupPath $maliciousBackup `
                    -CodexHome $upgradeHome `
                    -ProfilePath $upgradeProfile `
                    -Force | Out-Null
            }
        $maliciousProfileEntry.AclSddl = 'D:P(A;;FA;;;SY)'
        Write-SecurityText `
            -Path $maliciousManifestPath `
            -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
        Assert-SecurityThrows `
            -Message 'restore rejects ACL metadata without owner or group' `
            -Action {
                & $restorePath `
                    -BackupPath $maliciousBackup `
                    -CodexHome $upgradeHome `
                    -ProfilePath $upgradeProfile `
                    -Force | Out-Null
            }
        $maliciousProfileEntry.AclSddl = $validAclSddl
    }
    $maliciousProfileEntry.Target = $victimPath
    Write-SecurityText `
        -Path $maliciousManifestPath `
        -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'restore rejects arbitrary manifest target' -Action {
        & $restorePath `
            -BackupPath $maliciousBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($victimPath)) `
        -Expected 'victim-safe' `
        -Message 'malicious restore leaves unrelated file unchanged'

    $configBeforeWhatIf = [IO.File]::ReadAllBytes($upgradeConfig)
    $whatIfResult = & $restorePath `
        -BackupPath $firstInstall.BackupPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -Force `
        -WhatIf
    Assert-SecurityTrue -Condition (-not $whatIfResult.Restored) -Message 'restore WhatIf reports no restore'
    Assert-SecurityEqual -Actual ([int]$whatIfResult.RestoredFiles) -Expected 0 -Message 'restore WhatIf file count'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $configBeforeWhatIf,
            [IO.File]::ReadAllBytes($upgradeConfig)
        )) `
        -Message 'restore WhatIf leaves config unchanged'

    $restoreRollbackProfileBytes = [IO.File]::ReadAllBytes($upgradeProfile)
    $restoreRollbackProfileTimestamp =
        (Get-Item -LiteralPath $upgradeProfile).LastWriteTimeUtc
    $global:CodexToolkitRestoreCommitFailureInjected = $false
    $global:CodexToolkitRestoredProfileItemCount = 0
    function Get-Item {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [switch]$Force
        )

        $item = Microsoft.PowerShell.Management\Get-Item `
            -LiteralPath $LiteralPath `
            -Force:$Force `
            -ErrorAction Stop
        if (
            (Test-ToolkitPathEqual `
                -Left $LiteralPath `
                -Right $upgradeProfile) -and
            $item.Length -eq 0
        ) {
            $global:CodexToolkitRestoredProfileItemCount++
        }
        if (-not $global:CodexToolkitRestoreCommitFailureInjected -and
            $global:CodexToolkitRestoredProfileItemCount -ge 5) {
            $global:CodexToolkitRestoreCommitFailureInjected = $true
            throw 'forced failure after restore commit'
        }
        return $item
    }
    $restoreCommitFailure = $null
    try {
        & $restorePath `
            -BackupPath $firstInstall.BackupPath `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    catch {
        $restoreCommitFailure = $_.Exception.Message
    }
    finally {
        Remove-Item `
            Function:\Get-Item `
            -Force `
            -ErrorAction SilentlyContinue
        Remove-Variable `
            -Name CodexToolkitRestoredProfileItemCount `
            -Scope Global `
            -ErrorAction SilentlyContinue
        $restoreCommitFailureInjected =
            [bool]$global:CodexToolkitRestoreCommitFailureInjected
        Remove-Variable `
            -Name CodexToolkitRestoreCommitFailureInjected `
            -Scope Global `
            -ErrorAction SilentlyContinue
    }
    Assert-SecurityTrue `
        -Condition $restoreCommitFailureInjected `
        -Message ("restore failure injected after formal file commit; result=$restoreCommitFailure")
    Assert-SecurityTrue `
        -Condition $restoreCommitFailure.Contains('已还原事务前状态') `
        -Message 'post-commit restore failure completes rollback'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $restoreRollbackProfileBytes,
            [IO.File]::ReadAllBytes($upgradeProfile)
        )) `
        -Message 'post-commit restore rollback restores current profile bytes'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $upgradeProfile).LastWriteTimeUtc `
        -Expected $restoreRollbackProfileTimestamp `
        -Message 'post-commit restore rollback restores current profile timestamp'

    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $upgradeProfile -Force
    $restoreResult = & $restorePath `
        -BackupPath $firstInstall.BackupPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -Force
    Assert-SecurityTrue -Condition $restoreResult.Restored -Message 'schema 3 restore succeeds'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path $upgradeHome 'codex-openrouter-toolkit'))) `
        -Message 'first-install restore removes active install root'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $upgradeProfile).Length `
        -Expected ([long]0) `
        -Message 'first-install restore recovers empty profile'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $upgradeProfile).LastWriteTimeUtc `
        -Expected $restoreProfileTimestamp `
        -Message 'formal restore recovers profile LastWriteTimeUtc'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $upgradeConfig).LastWriteTimeUtc `
        -Expected $restoreConfigTimestamp `
        -Message 'formal restore recovers config LastWriteTimeUtc'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $upgradeCatalog).LastWriteTimeUtc `
        -Expected $restoreCatalogTimestamp `
        -Message 'formal restore recovers stale catalog LastWriteTimeUtc'
    if ($IsWindows) {
        $restoredProfileAcl = Get-Acl -LiteralPath $upgradeProfile
        Assert-SecurityTrue `
            -Condition (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $restoreProfileExpectedAcl `
                -ActualAcl $restoredProfileAcl) `
            -Message 'restore of missing profile preserves ACL policy'
        Assert-SecurityTrue `
            -Condition (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $restoreProfileExpectedAcl `
                -DestinationAcl $restoredProfileAcl) `
            -Message 'restore of missing profile preserves effective access rules'
    }

    $ownershipHome = Join-Path $securityTempRoot 'restore-ownership\.codex'
    $ownershipProfile = Join-Path `
        $securityTempRoot `
        'restore-ownership\profile.ps1'
    Write-SecurityText -Path $ownershipProfile -Content ''
    $ownershipInstall = & $installerPath `
        -CodexHome $ownershipHome `
        -ProfilePath $ownershipProfile `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $ownershipInstallRoot = Join-Path `
        $ownershipHome `
        'codex-openrouter-toolkit'
    $heldOwnershipInstall = Join-Path `
        $ownershipHome `
        'held-valid-install'
    Move-Item `
        -LiteralPath $ownershipInstallRoot `
        -Destination $heldOwnershipInstall
    [void](New-Item -ItemType Directory -Path $ownershipInstallRoot)
    $ownershipCanary = Join-Path $ownershipInstallRoot 'unrelated-canary.txt'
    Write-SecurityText -Path $ownershipCanary -Content 'keep-me'
    Assert-SecurityThrows -Message 'restore refuses unrelated install directory' -Action {
        & $restorePath `
            -BackupPath $ownershipInstall.BackupPath `
            -CodexHome $ownershipHome `
            -ProfilePath $ownershipProfile `
            -Force | Out-Null
    }
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($ownershipCanary)) `
        -Expected 'keep-me' `
        -Message 'restore ownership failure preserves unrelated canary'
    Remove-Item -LiteralPath $ownershipInstallRoot -Recurse -Force
    Move-Item `
        -LiteralPath $heldOwnershipInstall `
        -Destination $ownershipInstallRoot

    $uninstallRollbackProfileBytes =
        [IO.File]::ReadAllBytes($ownershipProfile)
    $uninstallRollbackProfileTimestamp = [DateTime]::UtcNow.AddDays(-3)
    [IO.File]::SetLastWriteTimeUtc(
        $ownershipProfile,
        $uninstallRollbackProfileTimestamp
    )
    $global:CodexToolkitUninstallMoveFailureInjected = $false
    function Remove-Module {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0)][string]$Name,
            [switch]$Force
        )

        if (-not $global:CodexToolkitUninstallMoveFailureInjected -and
            $Name -ceq 'CodexOpenRouter') {
            $global:CodexToolkitUninstallMoveFailureInjected = $true
            throw 'forced uninstall commit failure'
        }
        Microsoft.PowerShell.Core\Remove-Module `
            -Name $Name `
            -Force:$Force `
            -ErrorAction SilentlyContinue
    }
    try {
        Assert-SecurityThrows `
            -Message 'uninstall failure triggers timestamp-preserving rollback' `
            -Action {
            & $uninstallerPath `
                -CodexHome $ownershipHome `
                -ProfilePath $ownershipProfile `
                -KeepCurrentProvider | Out-Null
        }
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item `
            Function:\Remove-Module `
            -ErrorAction SilentlyContinue
        $uninstallMoveFailureInjected =
            [bool]$global:CodexToolkitUninstallMoveFailureInjected
        Remove-Variable `
            -Name CodexToolkitUninstallMoveFailureInjected `
            -Scope Global `
            -ErrorAction SilentlyContinue
    }
    Assert-SecurityTrue `
        -Condition $uninstallMoveFailureInjected `
        -Message 'uninstall failure injected after profile mutation'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $uninstallRollbackProfileBytes,
            [IO.File]::ReadAllBytes($ownershipProfile)
        )) `
        -Message 'failed uninstall restores profile bytes'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $ownershipProfile).LastWriteTimeUtc `
        -Expected $uninstallRollbackProfileTimestamp `
        -Message 'failed uninstall restores profile LastWriteTimeUtc'
    $failedUninstallRecovery = @(Get-ChildItem `
        -LiteralPath (Join-Path `
            $ownershipHome `
            'codex-openrouter-toolkit-uninstalled') `
        -Directory | Sort-Object LastWriteTimeUtc -Descending)[0]
    $failedUninstallManifest = [IO.File]::ReadAllText(
        (Join-Path $failedUninstallRecovery.FullName 'recovery.json')
    ) | ConvertFrom-Json
    Assert-SecurityEqual `
        -Actual ([int]$failedUninstallManifest.SchemaVersion) `
        -Expected 2 `
        -Message 'uninstall recovery manifest uses schema 2'
    $failedUninstallProfileEntry = @(
        $failedUninstallManifest.Files | Where-Object Name -eq 'profile'
    )[0]
    Assert-SecurityEqual `
        -Actual (([DateTime]$failedUninstallProfileEntry.LastWriteTimeUtc).
            ToUniversalTime()) `
        -Expected $uninstallRollbackProfileTimestamp `
        -Message 'uninstall recovery manifest records profile timestamp'
    & $uninstallerPath `
        -CodexHome $ownershipHome `
        -ProfilePath $ownershipProfile `
        -KeepCurrentProvider | Out-Null

    $profileSafetyHome = Join-Path $securityTempRoot 'profile-safety\.codex'
    $profileSafetyPath = Join-Path `
        $securityTempRoot `
        'profile-safety\profile.ps1'
    $profileHereString = @'
$embeddedMarkers = @"
# >>> codex-openrouter-toolkit >>>
keep-this-here-string-data
# <<< codex-openrouter-toolkit <<<
"@
'@
    Write-SecurityText -Path $profileSafetyPath -Content $profileHereString
    $profileSafetyInstall = & $installerPath `
        -CodexHome $profileSafetyHome `
        -ProfilePath $profileSafetyPath `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $installedProfileContent = [IO.File]::ReadAllText($profileSafetyPath)
    $withoutManagedBlock = Remove-ToolkitPowerShellCommentBlock `
        -Content $installedProfileContent `
        -StartMarker '# >>> codex-openrouter-toolkit >>>' `
        -EndMarker '# <<< codex-openrouter-toolkit <<<'
    Assert-SecurityEqual `
        -Actual $withoutManagedBlock.Trim() `
        -Expected $profileHereString.Trim() `
        -Message 'installer preserves marker text inside here-string'
    $profileSafetySettingsPath = Join-Path `
        $profileSafetyHome `
        'codex-openrouter-toolkit\settings.json'
    $profileSafetySettings = [IO.File]::ReadAllText(
        $profileSafetySettingsPath
    ) | ConvertFrom-Json
    $profileSafetySettings.OpenAIModel = "invalid`nmodel"
    $profileSafetySettings.OpenAIReasoningEffort = 'invalid-effort'
    $profileSafetySettings.OpenRouterModel = "invalid`nmodel"
    $profileSafetySettings.OpenRouterReasoningEffort = 'invalid-effort'
    $profileSafetySettings.CatalogMaximumAgeHours = 0
    Write-SecurityText `
        -Path $profileSafetySettingsPath `
        -Content ($profileSafetySettings | ConvertTo-Json -Depth 10)
    $isolatedUninstallerRoot = Join-Path `
        $securityTempRoot `
        'keep-provider-uninstaller'
    $isolatedUninstallerScripts = Join-Path $isolatedUninstallerRoot 'scripts'
    $isolatedUninstallerCommonRoot = Join-Path `
        $isolatedUninstallerRoot `
        'src\CodexOpenRouter'
    [void](New-Item `
        -ItemType Directory `
        -Path $isolatedUninstallerScripts `
        -Force)
    [void](New-Item `
        -ItemType Directory `
        -Path $isolatedUninstallerCommonRoot `
        -Force)
    $isolatedUninstallerPath = Join-Path `
        $isolatedUninstallerScripts `
        'Uninstall-CodexOpenRouter.ps1'
    Copy-Item `
        -LiteralPath $uninstallerPath `
        -Destination $isolatedUninstallerPath
    Copy-Item `
        -LiteralPath $commonPath `
        -Destination (Join-Path `
            $isolatedUninstallerCommonRoot `
            'CodexOpenRouter.Common.ps1')
    & $isolatedUninstallerPath `
        -CodexHome $profileSafetyHome `
        -ProfilePath $profileSafetyPath `
        -KeepCurrentProvider | Out-Null
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath (Join-Path `
            $profileSafetyHome `
            'codex-openrouter-toolkit'))) `
        -Message 'KeepCurrentProvider uninstalls without a source module tree'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($profileSafetyPath)).Trim() `
        -Expected $profileHereString.Trim() `
        -Message 'uninstaller preserves marker text inside here-string'

    $oversizedUninstallHome = Join-Path `
        $securityTempRoot `
        'oversized-uninstall-settings\.codex'
    $oversizedUninstallProfile = Join-Path `
        $securityTempRoot `
        'oversized-uninstall-settings\profile.ps1'
    Write-SecurityText `
        -Path $oversizedUninstallProfile `
        -Content 'function Keep-Oversized-Uninstall { 1 }'
    $oversizedUninstallInstall = & $installerPath `
        -CodexHome $oversizedUninstallHome `
        -ProfilePath $oversizedUninstallProfile `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $oversizedUninstallSettingsPath =
        [string]$oversizedUninstallInstall.SettingsPath
    $oversizedUninstallSettingsBytes =
        [IO.File]::ReadAllBytes($oversizedUninstallSettingsPath)
    $oversizedUninstallProfileBytes =
        [IO.File]::ReadAllBytes($oversizedUninstallProfile)
    $oversizedUninstallStream = [IO.File]::Open(
        $oversizedUninstallSettingsPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try { $oversizedUninstallStream.SetLength((5MB) + 1) }
    finally { $oversizedUninstallStream.Dispose() }
    Assert-SecurityThrows `
        -Message 'uninstaller rejects settings larger than five MiB' `
        -Action {
        & $uninstallerPath `
            -CodexHome $oversizedUninstallHome `
            -ProfilePath $oversizedUninstallProfile `
            -KeepCurrentProvider | Out-Null
    }
    Assert-SecurityTrue `
        -Condition (Test-Path `
            -LiteralPath (Join-Path `
                $oversizedUninstallHome `
                'codex-openrouter-toolkit') `
            -PathType Container) `
        -Message 'oversized uninstall settings preserve active install root'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $oversizedUninstallProfileBytes,
            [IO.File]::ReadAllBytes($oversizedUninstallProfile)
        )) `
        -Message 'oversized uninstall settings preserve profile'
    [IO.File]::WriteAllBytes(
        $oversizedUninstallSettingsPath,
        $oversizedUninstallSettingsBytes
    )
    & $uninstallerPath `
        -CodexHome $oversizedUninstallHome `
        -ProfilePath $oversizedUninstallProfile `
        -KeepCurrentProvider | Out-Null

    $tamperHome = Join-Path $securityTempRoot 'uninstall-tamper\.codex'
    $tamperProfile = Join-Path $securityTempRoot 'uninstall-tamper\profile.ps1'
    Write-SecurityText -Path $tamperProfile -Content 'function Keep-Me { 1 }'
    $tamperInstall = & $installerPath `
        -CodexHome $tamperHome `
        -ProfilePath $tamperProfile `
        -OpenAIModel 'gpt-original' `
        -OpenAIReasoningEffort low `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $tamperSettingsPath = [string]$tamperInstall.SettingsPath
    $tamperSettingsOriginal = [IO.File]::ReadAllText($tamperSettingsPath)
    $tamperSettingsObject = $tamperSettingsOriginal | ConvertFrom-Json
    $tamperSettingsObject.ProfilePath = $victimPath
    Write-SecurityText `
        -Path $tamperSettingsPath `
        -Content ($tamperSettingsObject | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'uninstaller rejects settings profile tamper' -Action {
        & $uninstallerPath `
            -CodexHome $tamperHome `
            -ProfilePath $tamperProfile `
            -KeepCurrentProvider | Out-Null
    }
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($victimPath)) `
        -Expected 'victim-safe' `
        -Message 'uninstaller profile tamper leaves victim unchanged'
    Write-SecurityText -Path $tamperSettingsPath -Content $tamperSettingsOriginal
    & $uninstallerPath `
        -CodexHome $tamperHome `
        -ProfilePath $tamperProfile `
        -KeepCurrentProvider | Out-Null

    $switchHome = Join-Path $securityTempRoot 'switch-rollback\.codex'
    $switchProfile = Join-Path $securityTempRoot 'switch-rollback\profile.ps1'
    Write-SecurityText -Path $switchProfile -Content ''
    $switchInstall = & $installerPath `
        -CodexHome $switchHome `
        -ProfilePath $switchProfile `
        -OpenAIModel 'gpt-original' `
        -OpenAIReasoningEffort low `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $switchSettings = [IO.File]::ReadAllText($switchInstall.SettingsPath) |
        ConvertFrom-Json
    $switchCatalog = [string]$switchSettings.CatalogPath
    Copy-Item -LiteralPath $modernFixture -Destination $switchCatalog -Force
    Import-Module -Name $switchInstall.ModulePath -Force
    [void](Set-OpenRouterAgentInstructions -Path $switchCatalog)
    Set-CodexDesktopModelConfig `
        -Model 'anthropic/claude-opus-5' `
        -Provider openrouter `
        -ReasoningEffort high `
        -ModelCatalogPath $switchCatalog `
        -ConfigPath ([string]$switchSettings.ConfigPath) `
        -SkipBackup | Out-Null
    Write-SecurityText `
        -Path ([string]$switchSettings.OpenAICachePath) `
        -Content '{"models":[{"slug":"gpt-original","base_instructions":"prompt"}]}'
    $switchConfigBefore = [IO.File]::ReadAllBytes([string]$switchSettings.ConfigPath)
    if (Test-Path -LiteralPath ([string]$switchSettings.ActiveCachePath)) {
        Remove-Item -LiteralPath ([string]$switchSettings.ActiveCachePath) -Force -Recurse
    }
    [void](New-Item `
        -ItemType Directory `
        -Path ([string]$switchSettings.ActiveCachePath) `
        -Force)
    Assert-SecurityThrows -Message 'OpenAI switch failure triggers rollback' -Action {
        Switch-CodexDesktopProvider -Provider openai -NoRestart
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $switchConfigBefore,
            [IO.File]::ReadAllBytes([string]$switchSettings.ConfigPath)
        )) `
        -Message 'failed provider switch restores config bytes'
    Remove-Item `
        -LiteralPath ([string]$switchSettings.ActiveCachePath) `
        -Recurse `
        -Force
    & $uninstallerPath `
        -CodexHome $switchHome `
        -ProfilePath $switchProfile `
        -KeepCurrentProvider | Out-Null

    $cacheHome = Join-Path $securityTempRoot 'uninstall-cache\.codex'
    $cacheProfile = Join-Path $securityTempRoot 'uninstall-cache\profile.ps1'
    $cacheConfig = Join-Path $cacheHome 'config.toml'
    Write-SecurityText -Path $cacheProfile -Content ''
    Write-SecurityText `
        -Path $cacheConfig `
        -Content ("model = `"gpt-original`"$newLine" +
            "model_reasoning_effort = `"low`"$newLine")
    $cacheInstall = & $installerPath `
        -CodexHome $cacheHome `
        -ProfilePath $cacheProfile `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $cacheSettings = [IO.File]::ReadAllText($cacheInstall.SettingsPath) |
        ConvertFrom-Json
    Copy-Item `
        -LiteralPath $modernFixture `
        -Destination ([string]$cacheSettings.CatalogPath) `
        -Force
    Import-Module -Name $cacheInstall.ModulePath -Force
    [void](Set-OpenRouterAgentInstructions -Path ([string]$cacheSettings.CatalogPath))
    Set-CodexDesktopModelConfig `
        -Model 'anthropic/claude-opus-5' `
        -Provider openrouter `
        -ReasoningEffort high `
        -ModelCatalogPath ([string]$cacheSettings.CatalogPath) `
        -ConfigPath ([string]$cacheSettings.ConfigPath) `
        -SkipBackup | Out-Null
    Write-SecurityText `
        -Path ([string]$cacheSettings.ActiveCachePath) `
        -Content '{"models":[{"slug":"anthropic/claude-opus-5","base_instructions":"prompt"}]}'
    $expectedOpenAICache = '{"models":[{"slug":"gpt-original","base_instructions":"prompt"}]}'
    Write-SecurityText `
        -Path ([string]$cacheSettings.OpenAICachePath) `
        -Content $expectedOpenAICache
    & $uninstallerPath `
        -CodexHome $cacheHome `
        -ProfilePath $cacheProfile | Out-Null
    $uninstalledConfig = [IO.File]::ReadAllText([string]$cacheSettings.ConfigPath)
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue `
            -Content $uninstalledConfig `
            -Key 'model') `
        -Expected 'gpt-original' `
        -Message 'uninstall restores OpenAI model config'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText([string]$cacheSettings.ActiveCachePath)) `
        -Expected $expectedOpenAICache `
        -Message 'uninstall restores OpenAI cache'

    Write-Host 'Security tests passed: TOML, catalog, key format, trusted CLI, install, restore, switch rollback, settings tamper, and uninstall cache checks succeeded.'
}
finally {
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedSecurityTemp = [IO.Path]::GetFullPath($securityTempRoot)
    if ($resolvedSecurityTemp.StartsWith(
            $systemTemp,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Test-Path -LiteralPath $resolvedSecurityTemp -PathType Container)) {
        [IO.Directory]::Delete($resolvedSecurityTemp, $true)
    }
}

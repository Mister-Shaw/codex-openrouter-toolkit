Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot
$script:DefaultSettingsPath = Join-Path $script:ToolkitRoot 'settings.json'
$script:DefaultPromptPath = Join-Path $script:ModuleRoot 'lightweight-agent-prompt.txt'
$script:CommonPath = Join-Path $script:ModuleRoot 'CodexOpenRouter.Common.ps1'

if (-not (Test-Path -LiteralPath $script:CommonPath -PathType Leaf)) {
    throw "找不到工具包公共组件：$script:CommonPath"
}
. $script:CommonPath

$script:MaximumCodexConfigBytes = 5MB
$script:MaximumCodexCacheBytes = 50MB
$script:MaximumCodexCatalogBytes = 50MB
$script:MaximumToolkitSettingsBytes = 1MB
$script:MaximumAgentPromptBytes = 4KB

function Get-CodexManagedFileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $exists = Test-Path -LiteralPath $resolvedPath -PathType Leaf
    if ((Test-Path -LiteralPath $resolvedPath) -and -not $exists) {
        throw "受管路径必须是普通文件：$resolvedPath"
    }
    if (-not $exists) {
        return [pscustomobject]@{
            Path = $resolvedPath
            Existed = $false
            Snapshot = $null
        }
    }

    $item = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "受管文件不能是重解析点：$resolvedPath"
    }
    if ($item.Length -gt $MaximumBytes) {
        throw "受管文件超过 $MaximumBytes 字节限制：$resolvedPath"
    }
    $snapshot = Get-ToolkitFileSnapshot `
        -Path $resolvedPath `
        -MaximumBytes $MaximumBytes
    if ([long]$snapshot.Length -gt $MaximumBytes) {
        throw "受管文件超过 $MaximumBytes 字节限制：$resolvedPath"
    }
    return [pscustomobject]@{
        Path = $resolvedPath
        Existed = $true
        Snapshot = $snapshot
    }
}

function ConvertFrom-CodexManagedTextState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    if (-not [bool]$State.Existed) { return '' }
    $memory = [IO.MemoryStream]::new([byte[]]$State.Snapshot.Bytes, $false)
    $reader = [IO.StreamReader]::new(
        $memory,
        [Text.UTF8Encoding]::new($false, $true),
        $true
    )
    try { return $reader.ReadToEnd() }
    finally {
        $reader.Dispose()
        $memory.Dispose()
    }
}

function Test-CodexManagedFileStateMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    if (-not [bool]$State.Existed) {
        return -not (Test-Path -LiteralPath ([string]$State.Path))
    }
    return Test-ToolkitFileMatchesSnapshot `
        -Path ([string]$State.Path) `
        -Snapshot $State.Snapshot
}

function Test-CodexManagedFilePayloadMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExpectedState,

        [Parameter(Mandatory = $true)]
        [object]$ActualState
    )

    if ([bool]$ExpectedState.Existed -ne [bool]$ActualState.Existed) {
        return $false
    }
    if (-not [bool]$ExpectedState.Existed) { return $true }
    $expected = $ExpectedState.Snapshot
    $actual = $ActualState.Snapshot
    if ($expected.LastWriteTimeUtc -ne $actual.LastWriteTimeUtc -or
        -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            [byte[]]$expected.Bytes,
            [byte[]]$actual.Bytes
        )) {
        return $false
    }
    if ($IsWindows -and $null -ne $expected.Acl) {
        return (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $expected.Acl `
                -ActualAcl $actual.Acl) -and
            (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $expected.Acl `
                -DestinationAcl $actual.Acl)
    }
    return $true
}

function Write-CodexManagedFileState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExpectedState,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes,

        [DateTime]$TargetLastWriteTimeUtc,

        [object]$DesiredAcl
    )

    if ($Bytes.LongLength -gt $MaximumBytes) {
        throw "待写入内容超过 $MaximumBytes 字节限制：$($ExpectedState.Path)"
    }
    $parameters = @{
        Path = [string]$ExpectedState.Path
        Bytes = $Bytes
        PassThru = $true
    }
    if ([bool]$ExpectedState.Existed) {
        $parameters.RequireExistingTarget = $true
        $parameters.ExpectedCurrentBytes = [byte[]]$ExpectedState.Snapshot.Bytes
        $parameters.ExpectedCurrentLastWriteTimeUtc =
            [DateTime]$ExpectedState.Snapshot.LastWriteTimeUtc
        if ($IsWindows -and $null -ne $ExpectedState.Snapshot.Acl) {
            $parameters.ExpectedCurrentAcl = $ExpectedState.Snapshot.Acl
        }
    }
    else {
        $parameters.RequireNewTarget = $true
    }
    if ($PSBoundParameters.ContainsKey('TargetLastWriteTimeUtc')) {
        $parameters.TargetLastWriteTimeUtc = $TargetLastWriteTimeUtc
    }
    if ($PSBoundParameters.ContainsKey('DesiredAcl') -and $IsWindows) {
        $parameters.DesiredAcl = $DesiredAcl
    }
    $committedSnapshot = Write-ToolkitBytesAtomic @parameters
    if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $Bytes,
            [byte[]]$committedSnapshot.Bytes
        )) {
        throw "受管文件写入后内容复读失败：$($ExpectedState.Path)"
    }
    return [pscustomobject]@{
        Path = [string]$ExpectedState.Path
        Existed = $true
        Snapshot = $committedSnapshot
    }
}

function New-CodexFileMutation {
    param(
        [Parameter(Mandatory = $true)] [object]$InitialState,
        [Parameter(Mandatory = $true)] [object]$PostState,
        [ValidateRange(1, 104857600)] [long]$MaximumBytes
    )
    [pscustomobject]@{
        Path = [string]$InitialState.Path
        InitialState = $InitialState
        PostState = $PostState
        MaximumBytes = $MaximumBytes
    }
}

function New-CodexManagedOperationResult {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$InitialState,
        [Parameter(Mandatory = $true)] [object]$State,
        [ValidateRange(1, 104857600)] [long]$MaximumBytes
    )

    $mutation = if (Test-CodexManagedFilePayloadMatches `
            -ExpectedState $InitialState `
            -ActualState $State) {
        $null
    }
    else {
        New-CodexFileMutation `
            -InitialState $InitialState `
            -PostState $State `
            -MaximumBytes $MaximumBytes
    }
    return [pscustomobject]@{
        Path = $Path
        State = $State
        Mutation = $mutation
    }
}

function Restore-CodexFileMutations {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Mutations
    )

    $errors = [Collections.Generic.List[string]]::new()
    for ($index = $Mutations.Count - 1; $index -ge 0; $index--) {
        $mutation = $Mutations[$index]
        try {
            if (-not (Test-CodexManagedFileStateMatches `
                    -State $mutation.PostState)) {
                throw "回滚 CAS 冲突，外部修改已保留：$($mutation.Path)"
            }
            if ([bool]$mutation.InitialState.Existed) {
                $initial = $mutation.InitialState.Snapshot
                $restoreParameters = @{
                    ExpectedState = $mutation.PostState
                    Bytes = [byte[]]$initial.Bytes
                    MaximumBytes = [long]$mutation.MaximumBytes
                    TargetLastWriteTimeUtc = [DateTime]$initial.LastWriteTimeUtc
                }
                if ($IsWindows -and $null -ne $initial.Acl) {
                    $restoreParameters.DesiredAcl = $initial.Acl
                }
                $restoredState = Write-CodexManagedFileState @restoreParameters
                if (-not (Test-CodexManagedFilePayloadMatches `
                        -ExpectedState $mutation.InitialState `
                        -ActualState $restoredState)) {
                    throw "回滚复读校验失败：$($mutation.Path)"
                }
            }
            elseif ([bool]$mutation.PostState.Existed) {
                Remove-ToolkitFileIfSnapshotMatches `
                    -Path ([string]$mutation.Path) `
                    -Snapshot $mutation.PostState.Snapshot
                if (Test-Path -LiteralPath ([string]$mutation.Path)) {
                    throw "回滚删除后目标仍存在：$($mutation.Path)"
                }
            }
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
    }
    if ($errors.Count -gt 0) {
        throw ($errors -join '；')
    }
}

function Get-DefaultCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    return [IO.Path]::GetFullPath((Join-Path $userProfile '.codex'))
}

function Write-Utf8FileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    Write-ToolkitUtf8FileAtomic -Path $Path -Content $Content
}

function Get-TopLevelTomlValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    return Get-ToolkitTopLevelTomlValue -Content $Content -Key $Key
}

function Get-DefaultAgentInstruction {
    $promptState = Get-CodexManagedFileState `
        -Path $script:DefaultPromptPath `
        -MaximumBytes $script:MaximumAgentPromptBytes
    if (-not [bool]$promptState.Existed) {
        throw "找不到轻量 Agent 提示文件：$script:DefaultPromptPath"
    }

    $instruction = (ConvertFrom-CodexManagedTextState -State $promptState).Trim()
    if ([string]::IsNullOrWhiteSpace($instruction)) {
        throw '轻量 Agent 提示不能为空。空提示可能触发客户端内置提示。'
    }

    return $instruction
}

function Get-CodexOpenRouterSettings {
    [CmdletBinding()]
    param(
        [string]$SettingsPath = $script:DefaultSettingsPath
    )

    $resolvedPath = [IO.Path]::GetFullPath($SettingsPath)
    $settingsState = Get-CodexManagedFileState `
        -Path $resolvedPath `
        -MaximumBytes $script:MaximumToolkitSettingsBytes
    if (-not [bool]$settingsState.Existed) {
        throw "找不到工具包设置：$resolvedPath。请先运行安装脚本。"
    }

    try {
        $settings = ConvertFrom-CodexManagedTextState -State $settingsState |
            ConvertFrom-Json
    }
    catch {
        throw "工具包设置无法解析：$resolvedPath。$($_.Exception.Message)"
    }

    $schemaProperty = $settings.PSObject.Properties['SchemaVersion']
    if ($null -eq $schemaProperty -or [int]$schemaProperty.Value -notin @(1, 2)) {
        throw '工具包设置的 SchemaVersion 不受支持。'
    }
    if ([int]$schemaProperty.Value -eq 2) {
        $toolkitProperty = $settings.PSObject.Properties['Toolkit']
        if ($null -eq $toolkitProperty -or
            [string]$toolkitProperty.Value -cne 'codex-openrouter-toolkit') {
            throw '工具包设置缺少有效的 Toolkit 标识。'
        }
    }

    $installRoot = Split-Path -Parent $resolvedPath
    if ([IO.Path]::GetFileName($installRoot) -cne 'codex-openrouter-toolkit') {
        throw 'settings.json 必须位于固定的工具包安装目录中。'
    }
    $derivedCodexHome = Split-Path -Parent $installRoot
    $requiredStrings = @(
        'CodexHome',
        'ProfilePath',
        'ConfigPath',
        'CatalogPath',
        'ActiveCachePath',
        'OpenAICachePath',
        'OpenAIModel',
        'OpenAIReasoningEffort',
        'OpenRouterModel',
        'OpenRouterReasoningEffort'
    )
    foreach ($name in $requiredStrings) {
        $property = $settings.PSObject.Properties[$name]
        if ($null -eq $property -or
            [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "工具包设置缺少有效字段：$name"
        }
    }

    if (-not (Test-ToolkitPathEqual `
            -Left ([string]$settings.CodexHome) `
            -Right $derivedCodexHome)) {
        throw '工具包设置中的 CodexHome 与安装位置不一致。'
    }
    $fixedPaths = @{
        ConfigPath = Join-Path $derivedCodexHome 'config.toml'
        CatalogPath = Join-Path $derivedCodexHome 'openrouter-model-catalog.json'
        ActiveCachePath = Join-Path $derivedCodexHome 'models_cache.json'
        OpenAICachePath = Join-Path $derivedCodexHome 'models_cache.openai.json'
    }
    foreach ($name in $fixedPaths.Keys) {
        if (-not (Test-ToolkitPathEqual `
                -Left ([string]$settings.$name) `
                -Right ([string]$fixedPaths[$name]))) {
            throw "工具包设置中的 $name 超出固定路径。"
        }
    }
    try { [void][IO.Path]::GetFullPath([string]$settings.ProfilePath) }
    catch { throw '工具包设置中的 ProfilePath 无效。' }

    Assert-ToolkitModelId -Value ([string]$settings.OpenAIModel) -Name 'OpenAI 模型 ID'
    Assert-ToolkitModelId -Value ([string]$settings.OpenRouterModel) -Name 'OpenRouter 模型 ID'
    Assert-ToolkitReasoningEffort `
        -Value ([string]$settings.OpenAIReasoningEffort) `
        -Name 'OpenAI 推理强度'
    Assert-ToolkitReasoningEffort `
        -Value ([string]$settings.OpenRouterReasoningEffort) `
        -Name 'OpenRouter 推理强度'
    $ageProperty = $settings.PSObject.Properties['CatalogMaximumAgeHours']
    if ($null -eq $ageProperty -or
        [int]$ageProperty.Value -lt 1 -or
        [int]$ageProperty.Value -gt 8760) {
        throw '工具包设置中的 CatalogMaximumAgeHours 超出范围。'
    }

    return $settings
}

function Get-OpenRouterApiKeyInfo {
    $processValue = [Environment]::GetEnvironmentVariable(
        'OPENROUTER_API_KEY',
        [EnvironmentVariableTarget]::Process
    )
    $userValue = [Environment]::GetEnvironmentVariable(
        'OPENROUTER_API_KEY',
        [EnvironmentVariableTarget]::User
    )
    $processOverride = [Environment]::GetEnvironmentVariable(
        'CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE',
        [EnvironmentVariableTarget]::Process
    ) -ceq '1'
    $hasMismatch = -not [string]::IsNullOrWhiteSpace($processValue) -and
        -not [string]::IsNullOrWhiteSpace($userValue) -and
        $processValue -cne $userValue

    if ($processOverride -and -not [string]::IsNullOrWhiteSpace($processValue)) {
        $value = $processValue
        $source = 'ProcessOverride'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($userValue)) {
        $value = $userValue
        $source = 'User'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($processValue)) {
        $value = $processValue
        $source = 'Process'
    }
    else {
        $value = $null
        $source = 'None'
    }

    return [pscustomobject]@{
        Value = $value
        Source = $source
        ProcessUserMismatch = $hasMismatch
    }
}

function Get-OpenRouterApiKey {
    return (Get-OpenRouterApiKeyInfo).Value
}

function Resolve-OpenRouterDesktopApiKey {
    param(
        [AllowNull()] [string]$UserValue,
        [AllowNull()] [string]$ProcessValue,
        [bool]$ProcessOverride
    )

    if (-not (Test-ToolkitApiKeyFormat -Value $UserValue)) {
        throw 'cxor 需要有效的 User 范围 OPENROUTER_API_KEY。Process 范围无法作为 Windows 打包桌面应用的可靠启动凭据。'
    }
    if ($ProcessOverride -and
        -not [string]::IsNullOrWhiteSpace($ProcessValue) -and
        $ProcessValue -cne $UserValue) {
        throw 'Process override 与 User 范围的 OpenRouter Key 不一致。请先用 User 范围同步密钥再运行 cxor。'
    }
    return $UserValue
}

function Get-OpenRouterDesktopApiKey {
    $userValue = [Environment]::GetEnvironmentVariable(
        'OPENROUTER_API_KEY',
        [EnvironmentVariableTarget]::User
    )
    $processValue = [Environment]::GetEnvironmentVariable(
        'OPENROUTER_API_KEY',
        [EnvironmentVariableTarget]::Process
    )
    $processOverride = [Environment]::GetEnvironmentVariable(
        'CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE',
        [EnvironmentVariableTarget]::Process
    ) -ceq '1'
    return Resolve-OpenRouterDesktopApiKey `
        -UserValue $userValue `
        -ProcessValue $processValue `
        -ProcessOverride $processOverride
}

function Test-OpenRouterApiKey {
    $apiKey = Get-OpenRouterApiKey
    return Test-ToolkitApiKeyFormat -Value $apiKey
}

function Test-CodexObjectContainsSensitiveValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [int]$Depth = 0
    )

    if ($Depth -gt 100) { return $true }
    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [string]) {
        return $InputObject -cmatch 'sk-or-[A-Za-z0-9._-]{8,}'
    }
    if ($InputObject -is [ValueType]) { return $false }
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ((Test-CodexObjectContainsSensitiveValue `
                    -InputObject ([string]$key) `
                    -Depth ($Depth + 1)) -or
                (Test-CodexObjectContainsSensitiveValue `
                    -InputObject $InputObject[$key] `
                    -Depth ($Depth + 1))) {
                return $true
            }
        }
        return $false
    }
    if ($InputObject -is [Collections.IEnumerable]) {
        foreach ($item in $InputObject) {
            if (Test-CodexObjectContainsSensitiveValue `
                    -InputObject $item `
                    -Depth ($Depth + 1)) {
                return $true
            }
        }
        return $false
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        if ((Test-CodexObjectContainsSensitiveValue `
                -InputObject ([string]$property.Name) `
                -Depth ($Depth + 1)) -or
            (Test-CodexObjectContainsSensitiveValue `
                -InputObject $property.Value `
                -Depth ($Depth + 1))) {
            return $true
        }
    }
    return $false
}

function Test-CodexModelCatalogText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CatalogText,

        [string]$RequiredModel,

        [ValidateRange(1, 100000)]
        [int]$MinimumModelCount = 20,

        [ValidateRange(1, 100000)]
        [int]$MaximumModelCount = 5000
    )

    try {
        if (-not [string]::IsNullOrWhiteSpace($RequiredModel) -and
            -not (Test-ToolkitModelId -Value $RequiredModel)) {
            return $false
        }
        if ($CatalogText -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
            return $false
        }
        $catalog = $CatalogText | ConvertFrom-Json
        if (Test-CodexObjectContainsSensitiveValue -InputObject $catalog) {
            return $false
        }
        $modelsProperty = $catalog.PSObject.Properties['models']
        if ($null -eq $modelsProperty -or $null -eq $modelsProperty.Value -or
            $modelsProperty.Value -isnot [Collections.IList]) {
            return $false
        }
        $models = @($modelsProperty.Value)
        if ($models.Count -lt $MinimumModelCount -or
            $models.Count -gt $MaximumModelCount) {
            return $false
        }
        $slugs = @($models | ForEach-Object {
            $slugProperty = $_.PSObject.Properties['slug']
            if ($null -eq $slugProperty -or $slugProperty.Value -isnot [string]) {
                return $null
            }
            return [string]$slugProperty.Value
        })
        if ($slugs.Count -ne $models.Count -or
            @($slugs | Where-Object {
                -not (Test-ToolkitModelId -Value $_)
            }).Count -gt 0) {
            return $false
        }
        if (@($slugs | Sort-Object -Unique).Count -ne $slugs.Count) {
            return $false
        }
        foreach ($model in $models) {
            if ($model -is [string] -or $null -eq $model.PSObject) {
                return $false
            }
            $baseProperty = $model.PSObject.Properties['base_instructions']
            $hasLegacyPrompt = $null -ne $baseProperty
            if ($hasLegacyPrompt -and $baseProperty.Value -isnot [string]) {
                return $false
            }
            $messagesProperty = $model.PSObject.Properties['model_messages']
            $hasCurrentPrompt =
                $null -ne $messagesProperty -and
                $null -ne $messagesProperty.Value
            if ($hasCurrentPrompt -and
                $messagesProperty.Value -isnot [pscustomobject] -and
                $messagesProperty.Value -isnot [Collections.IDictionary]) {
                return $false
            }
            if ($hasCurrentPrompt) {
                $instructionProperty =
                    $messagesProperty.Value.PSObject.Properties['instructions_template']
                if ($null -ne $instructionProperty -and
                    $instructionProperty.Value -isnot [string]) {
                    return $false
                }
            }
            if (-not $hasLegacyPrompt -and -not $hasCurrentPrompt) {
                return $false
            }
            $displayProperty = $model.PSObject.Properties['display_name']
            if ($null -ne $displayProperty -and
                ($displayProperty.Value -isnot [string] -or
                ([string]$displayProperty.Value).Length -gt 512)) {
                return $false
            }
        }
        if ([string]::IsNullOrWhiteSpace($RequiredModel)) {
            return $true
        }

        return [bool]($models |
            Where-Object { $_.slug -eq $RequiredModel } |
            Select-Object -First 1)
    }
    catch {
        return $false
    }
}

function Test-CodexModelCatalogState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [string]$RequiredModel,

        [ValidateRange(1, 100000)]
        [int]$MinimumModelCount = 20,

        [ValidateRange(1, 100000)]
        [int]$MaximumModelCount = 5000
    )

    if (-not [bool]$State.Existed -or
        [long]$State.Snapshot.Length -gt $script:MaximumCodexCatalogBytes) {
        return $false
    }
    try { $catalogText = ConvertFrom-CodexManagedTextState -State $State }
    catch { return $false }
    return Test-CodexModelCatalogText `
        -CatalogText $catalogText `
        -RequiredModel $RequiredModel `
        -MinimumModelCount $MinimumModelCount `
        -MaximumModelCount $MaximumModelCount
}

function Test-CodexModelCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$RequiredModel,

        [ValidateRange(1, 100000)]
        [int]$MinimumModelCount = 20,

        [ValidateRange(1, 100000)]
        [int]$MaximumModelCount = 5000
    )

    try {
        $catalogState = Get-CodexManagedFileState `
            -Path $Path `
            -MaximumBytes $script:MaximumCodexCatalogBytes
        return (Test-CodexModelCatalogState `
                -State $catalogState `
                -RequiredModel $RequiredModel `
                -MinimumModelCount $MinimumModelCount `
                -MaximumModelCount $MaximumModelCount) -and
            (Test-CodexManagedFileStateMatches -State $catalogState)
    }
    catch {
        return $false
    }
}

function Test-ModelAgentInstruction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Model,

        [Parameter(Mandatory = $true)]
        [string]$Instruction
    )

    $targetCount = 0
    $baseProperty = $Model.PSObject.Properties['base_instructions']
    if ($null -ne $baseProperty) {
        $targetCount++
        if ($baseProperty.Value -cne $Instruction) {
            return $false
        }
    }

    $messagesProperty = $Model.PSObject.Properties['model_messages']
    if ($null -ne $messagesProperty -and $null -ne $messagesProperty.Value) {
        if ($messagesProperty.Value -isnot [pscustomobject] -and
            $messagesProperty.Value -isnot [Collections.IDictionary]) {
            return $false
        }
        $targetCount++
        $instructionProperty =
            $messagesProperty.Value.PSObject.Properties['instructions_template']
        if ($null -eq $instructionProperty -or
            $instructionProperty.Value -cne $Instruction) {
            return $false
        }
    }

    return $targetCount -gt 0
}

function Set-OpenRouterAgentInstructions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Instruction = (Get-DefaultAgentInstruction),

        [switch]$PreserveLastWriteTime,

        [Parameter(DontShow = $true)]
        [switch]$PassThruMutation,

        [Parameter(DontShow = $true)]
        [object]$ExpectedCatalogState
    )

    if ([string]::IsNullOrWhiteSpace($Instruction)) {
        throw '轻量 Agent 提示不能为空。'
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($utf8.GetByteCount($Instruction) -gt $script:MaximumAgentPromptBytes) {
        throw "轻量 Agent 提示超过 $($script:MaximumAgentPromptBytes) 字节限制。"
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $catalogState = if ($null -ne $ExpectedCatalogState) {
        $ExpectedCatalogState
    }
    else {
        Get-CodexManagedFileState `
            -Path $resolvedPath `
            -MaximumBytes $script:MaximumCodexCatalogBytes
    }
    if (-not (Test-ToolkitPathEqual `
            -Left ([string]$catalogState.Path) `
            -Right $resolvedPath)) {
        throw '模型目录快照路径与写入目标不一致。'
    }
    if (-not [bool]$catalogState.Existed) {
        throw "找不到 OpenRouter 模型目录：$resolvedPath"
    }
    if (-not (Test-CodexModelCatalogState `
            -State $catalogState `
            -MinimumModelCount 1)) {
        throw 'OpenRouter 模型目录结构未通过安全校验。'
    }
    if (-not (Test-CodexManagedFileStateMatches -State $catalogState)) {
        throw 'OpenRouter 模型目录在校验期间发生变化。'
    }

    $catalog = ConvertFrom-CodexManagedTextState -State $catalogState |
        ConvertFrom-Json
    $models = @($catalog.models)
    if ($models.Count -eq 0) {
        throw 'OpenRouter 模型目录中没有可用模型。'
    }

    $instructionTargetCount = 0L
    foreach ($model in $models) {
        $targetCount = 0
        if ($null -ne $model.PSObject.Properties['base_instructions']) {
            $targetCount++
        }
        $messagesProperty = $model.PSObject.Properties['model_messages']
        if ($null -ne $messagesProperty -and $null -ne $messagesProperty.Value) {
            if ($messagesProperty.Value -isnot [pscustomobject] -and
                $messagesProperty.Value -isnot [Collections.IDictionary]) {
                throw "模型目录结构不受支持：$($model.slug)"
            }
            $targetCount++
        }
        if ($targetCount -eq 0) {
            throw "模型目录结构不受支持：$($model.slug)"
        }
        $instructionTargetCount += $targetCount
    }
    $escapedInstruction = ConvertTo-Json -InputObject $Instruction -Compress
    $estimatedMaximumBytes = [long]$catalogState.Snapshot.Length +
        ($instructionTargetCount * [long]$utf8.GetByteCount($escapedInstruction))
    if ($estimatedMaximumBytes -gt $script:MaximumCodexCatalogBytes) {
        throw '应用轻量 Agent 提示后的模型目录可能超过大小限制。'
    }

    $changed = $false
    foreach ($model in $models) {
        $targetCount = 0
        $baseProperty = $model.PSObject.Properties['base_instructions']
        if ($null -ne $baseProperty) {
            $targetCount++
            if ($baseProperty.Value -cne $Instruction) {
                $baseProperty.Value = $Instruction
                $changed = $true
            }
        }

        $messagesProperty = $model.PSObject.Properties['model_messages']
        if ($null -ne $messagesProperty -and $null -ne $messagesProperty.Value) {
            $targetCount++
            $instructionProperty =
                $messagesProperty.Value.PSObject.Properties['instructions_template']
            if ($null -eq $instructionProperty) {
                $messagesProperty.Value | Add-Member `
                    -NotePropertyName 'instructions_template' `
                    -NotePropertyValue $Instruction
                $changed = $true
            }
            elseif ($instructionProperty.Value -cne $Instruction) {
                $instructionProperty.Value = $Instruction
                $changed = $true
            }
        }

        if ($targetCount -eq 0) {
            throw "模型目录结构不受支持：$($model.slug)"
        }
    }

    $matchingModels = @($models | Where-Object {
        Test-ModelAgentInstruction -Model $_ -Instruction $Instruction
    }).Count
    if ($matchingModels -ne $models.Count) {
        throw "轻量 Agent 提示校验失败：$matchingModels/$($models.Count)"
    }
    if (-not $changed) {
        if (-not (Test-CodexManagedFileStateMatches -State $catalogState)) {
            throw 'OpenRouter 模型目录在提示校验期间发生变化。'
        }
        if ($PassThruMutation) {
            return New-CodexManagedOperationResult `
                -Path $resolvedPath `
                -InitialState $catalogState `
                -State $catalogState `
                -MaximumBytes $script:MaximumCodexCatalogBytes
        }
        return $false
    }

    $serialized = $catalog | ConvertTo-Json -Depth 100 -Compress
    $writtenCatalog = $serialized | ConvertFrom-Json
    if ($serialized -cmatch 'sk-or-[A-Za-z0-9._-]{8,}' -or
        (Test-CodexObjectContainsSensitiveValue -InputObject $writtenCatalog)) {
        throw '写入后的模型目录包含疑似密钥，已拒绝保存。'
    }
    $writtenModels = @($writtenCatalog.models)
    $writtenMatches = @($writtenModels | Where-Object {
        Test-ModelAgentInstruction -Model $_ -Instruction $Instruction
    }).Count
    if ($writtenModels.Count -ne $models.Count -or
        $writtenMatches -ne $models.Count) {
        throw "写入后的轻量 Agent 提示校验失败：$writtenMatches/$($models.Count)"
    }
    if ($utf8.GetByteCount($serialized) -gt $script:MaximumCodexCatalogBytes) {
        throw '应用轻量 Agent 提示后的模型目录超过大小限制。'
    }
    $serializedBytes = $utf8.GetBytes($serialized)
    $writeParameters = @{
        ExpectedState = $catalogState
        Bytes = $serializedBytes
        MaximumBytes = $script:MaximumCodexCatalogBytes
    }
    if ($PreserveLastWriteTime) {
        $writeParameters.TargetLastWriteTimeUtc =
            [DateTime]$catalogState.Snapshot.LastWriteTimeUtc
    }
    $postState = Write-CodexManagedFileState @writeParameters

    if ($PassThruMutation) {
        return New-CodexManagedOperationResult `
            -Path $resolvedPath `
            -InitialState $catalogState `
            -State $postState `
            -MaximumBytes $script:MaximumCodexCatalogBytes
    }
    return $true
}

function Get-CodexCliPath {
    [CmdletBinding()]
    param()

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $binRoot = Join-Path $localAppData 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot -PathType Container) {
        $bundledCandidates = @(Get-ChildItem -LiteralPath $binRoot `
            -Recurse `
            -Filter 'codex.exe' `
            -File `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        foreach ($bundled in $bundledCandidates) {
            try {
                $resolvedCandidate = [IO.Path]::GetFullPath($bundled.FullName)
                $resolvedRoot = [IO.Path]::GetFullPath($binRoot).TrimEnd('\') + '\'
                if (-not $resolvedCandidate.StartsWith(
                        $resolvedRoot,
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    continue
                }
                $signature = Get-AuthenticodeSignature `
                    -LiteralPath $resolvedCandidate `
                    -ErrorAction Stop
                if ($signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
                    $null -ne $signature.SignerCertificate -and
                    $signature.SignerCertificate.Subject -like '*OpenAI OpCo, LLC*') {
                    return $resolvedCandidate
                }
            }
            catch {
                continue
            }
        }
    }

    throw '找不到签名有效的 Codex Desktop 内置 CLI。请更新或重新安装 Codex Desktop。'
}

function Stop-CodexProcessBounded {
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Process]$Process,

        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 5000
    )

    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
        }
    }
    catch {
        throw "无法结束子进程树：$($_.Exception.Message)"
    }
    if (-not $Process.HasExited -and
        -not $Process.WaitForExit($TimeoutMilliseconds)) {
        throw "等待子进程结束超过 $TimeoutMilliseconds 毫秒。"
    }
}

function Read-CodexProcessOutputLimited {
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Process]$Process,

        [ValidateRange(1, 600000)]
        [int]$TimeoutMilliseconds,

        [ValidateRange(1, 104857600)]
        [int]$MaximumStandardOutputBytes,

        [ValidateRange(1, 104857600)]
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
    $parentExitedAt = $null
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
                throw "$Context 超过 $([Math]::Ceiling($TimeoutMilliseconds / 1000)) 秒。"
            }
            if (-not $madeProgress) {
                if ($Process.HasExited) {
                    if ($null -eq $parentExitedAt) {
                        $parentExitedAt = $stopwatch.ElapsedMilliseconds
                    }
                    elseif (($stopwatch.ElapsedMilliseconds - $parentExitedAt) -ge 500) {
                        throw "$Context 的父进程已退出，但输出管道仍被后代占用。"
                    }
                }
                [Threading.Thread]::Sleep(10)
            }
        }

        $remaining = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $Process.WaitForExit($remaining)) {
            throw "$Context 超过 $([Math]::Ceiling($TimeoutMilliseconds / 1000)) 秒。"
        }
        return [pscustomobject]@{
            StandardOutput = $standardOutput.ToString()
            StandardError = $standardError.ToString()
        }
    }
    catch {
        $terminationError = $null
        try { Stop-CodexProcessBounded -Process $Process }
        catch { $terminationError = $_.Exception.Message }
        try { $Process.StandardOutput.Dispose() } catch { }
        try { $Process.StandardError.Dispose() } catch { }
        if ($terminationError) {
            Write-Warning "子进程有界清理未完成：$terminationError"
        }
        throw
    }
    finally {
        $stopwatch.Stop()
    }
}

function Get-TrustedCodexClientVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexPath
    )

    $process = $null
    $processStarted = $false
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $CodexPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        [void]$startInfo.Environment.Remove('OPENROUTER_API_KEY')
        [void]$startInfo.Environment.Remove('CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE')
        [void]$startInfo.ArgumentList.Add('--version')
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $processStarted = $process.Start()
        if (-not $processStarted) { throw 'Codex 版本探测进程未启动。' }
        $output = Read-CodexProcessOutputLimited `
            -Process $process `
            -TimeoutMilliseconds 15000 `
            -MaximumStandardOutputBytes 4096 `
            -MaximumStandardErrorBytes 65536 `
            -Context 'Codex 版本探测'
        $stdout = $output.StandardOutput
        $stderr = $output.StandardError
        if ($process.ExitCode -ne 0) {
            throw "Codex 版本探测失败：$(Protect-SensitiveText -Text $stderr)"
        }
        $versionMatch = [regex]::Match($stdout, '\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?')
        if (-not $versionMatch.Success) {
            throw "无法识别 Codex 版本：$(Protect-SensitiveText -Text $stdout)"
        }
        return $versionMatch.Value
    }
    finally {
        if ($processStarted -and $process -and -not $process.HasExited) {
            try { Stop-CodexProcessBounded -Process $process }
            catch { Write-Warning 'Codex 版本探测进程未在限定时间内结束。' }
        }
        if ($process) { $process.Dispose() }
    }
}

function Protect-SensitiveText {
    param(
        [AllowNull()]
        [string]$Text,

        [ValidateRange(64, 20000)]
        [int]$MaximumLength = 2000
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $protected = [regex]::Replace(
        $Text,
        'sk-or-[A-Za-z0-9._-]{8,}',
        '<redacted-openrouter-key>'
    )
    if ($protected.Length -gt $MaximumLength) {
        return $protected.Substring(0, $MaximumLength) + '…'
    }
    return $protected
}

function Invoke-OpenRouterCatalogDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$ClientVersion,

        [Parameter(Mandatory = $true)]
        [string]$ApiKey,

        [ValidateRange(1, 100)]
        [int]$MaximumSizeMegabytes = 25,

        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 45
    )

    if ($Uri.Scheme -cne 'https' -or
        $Uri.Host -cne 'openrouter.ai') {
        throw "拒绝访问非预期目录地址：$Uri"
    }
    if (-not (Test-ToolkitApiKeyFormat -Value $ApiKey)) {
        throw 'OpenRouter API Key 格式未通过校验。'
    }

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($TimeoutSeconds)
    )
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        $Uri
    )
    [void]$request.Headers.UserAgent.ParseAdd("Codex/$ClientVersion")
    $request.Headers.Authorization =
        [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $ApiKey)
    $response = $null
    $stream = $null
    $memory = $null
    try {
        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token
        ).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ge 300 -and $statusCode -lt 400) {
            throw "OpenRouter 目录地址返回了未接受的重定向：$statusCode"
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "OpenRouter 目录请求失败：HTTP $statusCode"
        }
        $mediaType = [string]$response.Content.Headers.ContentType.MediaType
        if ([string]::IsNullOrWhiteSpace($mediaType) -or
            ($mediaType -cne 'application/json' -and
            -not $mediaType.EndsWith('+json', [StringComparison]::OrdinalIgnoreCase))) {
            throw "OpenRouter 目录响应的 Content-Type 不受支持：$mediaType"
        }

        $maximumBytes = $MaximumSizeMegabytes * 1MB
        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and $contentLength -gt $maximumBytes) {
            throw "OpenRouter 目录响应超过 $MaximumSizeMegabytes MB 限制。"
        }

        $stream = $response.Content.ReadAsStreamAsync(
            $cancellation.Token
        ).GetAwaiter().GetResult()
        $memory = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(81920)
        while (($read = $stream.ReadAsync(
                    $buffer,
                    0,
                    $buffer.Length,
                    $cancellation.Token
                ).GetAwaiter().GetResult()) -gt 0) {
            if ($memory.Length + $read -gt $maximumBytes) {
                throw "OpenRouter 目录响应超过 $MaximumSizeMegabytes MB 限制。"
            }
            $memory.Write($buffer, 0, $read)
        }
        $content = [Text.UTF8Encoding]::new($false, $true).GetString(
            $memory.ToArray()
        )
        if ($content.Contains($ApiKey) -or
            $content -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
            throw 'OpenRouter 目录响应包含疑似密钥，已拒绝保存。'
        }
        return $content
    }
    finally {
        if ($memory) { $memory.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $cancellation.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Initialize-CodexOpenRouterConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path (Get-DefaultCodexHome) 'config.toml'),

        [Parameter(DontShow = $true)]
        [switch]$PassThruMutation
    )

    $resolvedPath = [IO.Path]::GetFullPath($ConfigPath)
    $mutex = Enter-ToolkitMutex -ScopePath (Split-Path -Parent $resolvedPath)
    try {
        $configState = Get-CodexManagedFileState `
            -Path $resolvedPath `
            -MaximumBytes $script:MaximumCodexConfigBytes
        $content = ConvertFrom-CodexManagedTextState -State $configState
        $content = Merge-ToolkitOpenRouterProvider -Content $content
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            $content.TrimEnd() + "`r`n"
        )
        $postState = Write-CodexManagedFileState `
            -ExpectedState $configState `
            -Bytes $bytes `
            -MaximumBytes $script:MaximumCodexConfigBytes
        if ($PassThruMutation) {
            return [pscustomobject]@{
                Path = $resolvedPath
                State = $postState
                Mutation = New-CodexFileMutation `
                    -InitialState $configState `
                    -PostState $postState `
                    -MaximumBytes $script:MaximumCodexConfigBytes
            }
        }
        return $resolvedPath
    }
    finally {
        Exit-ToolkitMutex -Mutex $mutex
    }
}

function Update-OpenRouterModelCatalog {
    [CmdletBinding()]
    param(
        [string]$CatalogPath,

        [string]$RequiredModel,

        [ValidateRange(1, 8760)]
        [int]$MaximumAgeHours = 24,

        [switch]$Force,

        [Parameter(DontShow = $true)]
        [switch]$PassThruMutation
    )

    if ([string]::IsNullOrWhiteSpace($CatalogPath) -or
        [string]::IsNullOrWhiteSpace($RequiredModel)) {
        $settings = Get-CodexOpenRouterSettings
        if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
            $CatalogPath = [string]$settings.CatalogPath
        }
        if ([string]::IsNullOrWhiteSpace($RequiredModel)) {
            $RequiredModel = [string]$settings.OpenRouterModel
        }
        if (-not $PSBoundParameters.ContainsKey('MaximumAgeHours')) {
            $MaximumAgeHours = [int]$settings.CatalogMaximumAgeHours
        }
    }
    $resolvedCatalogPath = [IO.Path]::GetFullPath($CatalogPath)
    $mutex = Enter-ToolkitMutex -ScopePath (Split-Path -Parent $resolvedCatalogPath)
    try {
        $parameters = @{
            CatalogPath = $resolvedCatalogPath
            RequiredModel = $RequiredModel
            MaximumAgeHours = $MaximumAgeHours
        }
        if ($Force) { $parameters.Force = $true }
        $parameters.PassThruMutation = $true
        $result = Update-OpenRouterModelCatalogCore @parameters
        if ($PassThruMutation) { return $result }
        return $result.Path
    }
    finally {
        Exit-ToolkitMutex -Mutex $mutex
    }
}

function Update-OpenRouterModelCatalogCore {
    [CmdletBinding()]
    param(
        [string]$CatalogPath,

        [string]$RequiredModel,

        [ValidateRange(1, 8760)]
        [int]$MaximumAgeHours = 24,

        [switch]$Force,

        [Parameter(DontShow = $true)]
        [switch]$PassThruMutation
    )

    if ([string]::IsNullOrWhiteSpace($CatalogPath) -or
        [string]::IsNullOrWhiteSpace($RequiredModel)) {
        $settings = Get-CodexOpenRouterSettings
        if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
            $CatalogPath = [string]$settings.CatalogPath
        }
        if ([string]::IsNullOrWhiteSpace($RequiredModel)) {
            $RequiredModel = [string]$settings.OpenRouterModel
        }
        if (-not $PSBoundParameters.ContainsKey('MaximumAgeHours')) {
            $MaximumAgeHours = [int]$settings.CatalogMaximumAgeHours
        }
    }
    Assert-ToolkitModelId -Value $RequiredModel -Name 'OpenRouter 默认模型 ID'

    $resolvedCatalogPath = [IO.Path]::GetFullPath($CatalogPath)
    $catalogParent = Split-Path -Parent $resolvedCatalogPath
    if (-not (Test-Path -LiteralPath $catalogParent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $catalogParent -Force -ErrorAction Stop)
    }
    $temporaryCatalogPath = Join-Path $catalogParent (
        ".{0}.refresh-{1}-{2}" -f
            [IO.Path]::GetFileName($resolvedCatalogPath),
            $PID,
            [Guid]::NewGuid().ToString('N')
    )

    $catalogInitialState = Get-CodexManagedFileState `
        -Path $resolvedCatalogPath `
        -MaximumBytes $script:MaximumCodexCatalogBytes
    $existingCatalogIsValid = (Test-CodexModelCatalogState `
            -State $catalogInitialState `
            -RequiredModel $RequiredModel) -and
        (Test-CodexManagedFileStateMatches -State $catalogInitialState)
    $catalogCommitState = $catalogInitialState
    if ($existingCatalogIsValid) {
        $catalogAge = [DateTime]::UtcNow -
            [DateTime]$catalogInitialState.Snapshot.LastWriteTimeUtc
        $promptResult = Set-OpenRouterAgentInstructions `
            -Path $resolvedCatalogPath `
            -PreserveLastWriteTime `
            -PassThruMutation `
            -ExpectedCatalogState $catalogInitialState
        $catalogCommitState = $promptResult.State
        $timestampIsPlausible = $catalogAge -ge [TimeSpan]::FromMinutes(-5)
        if (-not $timestampIsPlausible) {
            Write-Warning '模型目录时间戳位于未来，将执行安全刷新。'
        }
        elseif (-not $Force -and
            $catalogAge -lt [TimeSpan]::FromHours($MaximumAgeHours)) {
            return New-CodexManagedOperationResult `
                -Path $resolvedCatalogPath `
                -InitialState $catalogInitialState `
                -State $catalogCommitState `
                -MaximumBytes $script:MaximumCodexCatalogBytes
        }
        Write-Host "OpenRouter 模型目录正在更新，当前目录年龄为 $([Math]::Round($catalogAge.TotalHours, 1)) 小时。"
    }
    $keyInfo = Get-OpenRouterApiKeyInfo
    $apiKey = [string]$keyInfo.Value
    if (-not (Test-ToolkitApiKeyFormat -Value $apiKey)) {
        throw '当前 PowerShell 无法读取有效的 OPENROUTER_API_KEY。请先运行密钥设置脚本。'
    }
    if ($keyInfo.ProcessUserMismatch) {
        Write-Warning "Process 与 User 范围的 OpenRouter Key 不一致；本次采用 $($keyInfo.Source) 来源。"
    }

    $codexPath = Get-CodexCliPath
    try {
        $clientVersion = Get-TrustedCodexClientVersion -CodexPath $codexPath
    }
    catch {
        if ($existingCatalogIsValid -and
            (Test-CodexModelCatalogState `
                -State $catalogCommitState `
                -RequiredModel $RequiredModel) -and
            (Test-CodexManagedFileStateMatches -State $catalogCommitState)) {
            Write-Warning "Codex 版本探测失败，继续使用上一次的有效目录：$(Protect-SensitiveText -Text $_.Exception.Message)"
            return New-CodexManagedOperationResult `
                -Path $resolvedCatalogPath `
                -InitialState $catalogInitialState `
                -State $catalogCommitState `
                -MaximumBytes $script:MaximumCodexCatalogBytes
        }
        throw
    }

    $escapedVersion = [Uri]::EscapeDataString($clientVersion)
    $catalogUri = "https://openrouter.ai/api/v1/models?client_version=$escapedVersion"
    $downloadError = $null
    $standardSchemaReceived = $false
    foreach ($downloadAttempt in 1..3) {
        try {
            $catalogContent = Invoke-OpenRouterCatalogDownload `
                -Uri $catalogUri `
                -ClientVersion $clientVersion `
                -ApiKey $apiKey
            $downloaded = $catalogContent | ConvertFrom-Json
            if ($null -eq $downloaded.PSObject.Properties['models'] -and
                $null -ne $downloaded.PSObject.Properties['data']) {
                $standardSchemaReceived = $true
                $downloadError = 'OpenRouter 返回标准 data 目录，将改用 Codex 兼容刷新。'
                break
            }
            Write-ToolkitUtf8FileAtomic `
                -Path $temporaryCatalogPath `
                -Content $catalogContent
            [void](Set-OpenRouterAgentInstructions -Path $temporaryCatalogPath)
            $temporaryCatalogState = Get-CodexManagedFileState `
                -Path $temporaryCatalogPath `
                -MaximumBytes $script:MaximumCodexCatalogBytes
            if (-not (Test-CodexModelCatalogState `
                    -State $temporaryCatalogState `
                    -RequiredModel $RequiredModel)) {
                throw 'OpenRouter 返回的模型目录未通过完整性校验。'
            }
            $publishedState = Write-CodexManagedFileState `
                -ExpectedState $catalogCommitState `
                -Bytes ([byte[]]$temporaryCatalogState.Snapshot.Bytes) `
                -MaximumBytes $script:MaximumCodexCatalogBytes
            $modelCount = @(
                ((ConvertFrom-CodexManagedTextState -State $publishedState) |
                    ConvertFrom-Json).models
            ).Count
            Write-Host "OpenRouter 模型目录已更新：$modelCount 个模型。"
            return New-CodexManagedOperationResult `
                -Path $resolvedCatalogPath `
                -InitialState $catalogInitialState `
                -State $publishedState `
                -MaximumBytes $script:MaximumCodexCatalogBytes
        }
        catch {
            $downloadError = Protect-SensitiveText -Text $_.Exception.Message
            if ($downloadAttempt -lt 3) {
                Write-Warning "第 $downloadAttempt 次目录下载未完成，正在重试。"
                Start-Sleep -Seconds 1
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryCatalogPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryCatalogPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($standardSchemaReceived) {
        Write-Warning 'OpenRouter API 返回标准模型清单，正在使用受信 Codex CLI 获取桌面端目录。'
    }
    else {
        Write-Warning "HTTPS 目录下载未完成，正在使用受信 Codex CLI 刷新：$downloadError"
    }

    $isolatedHome = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "codex-openrouter-catalog-$PID-$([Guid]::NewGuid().ToString('N'))"
    $systemDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::System
    )
    $authPowerShell = if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        $null
    }
    else {
        Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
    }
    if ([string]::IsNullOrWhiteSpace($authPowerShell) -or
        -not (Test-Path -LiteralPath $authPowerShell -PathType Leaf)) {
        throw '找不到 Windows PowerShell，无法建立隔离的 command-auth 配置。'
    }
    [void](New-Item -ItemType Directory -Path $isolatedHome -ErrorAction Stop)
    try {
        Set-ToolkitPrivateDirectoryTree -Root $isolatedHome
        if (@(Get-ChildItem `
                    -LiteralPath $isolatedHome `
                    -Force `
                    -ErrorAction Stop).Count -ne 0) {
            throw '新建的隔离目录在权限收紧前已出现内容，已拒绝继续。'
        }
        $argumentLiterals = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Write-Output $env:OPENROUTER_API_KEY'
    ) | ForEach-Object { ConvertTo-ToolkitTomlString -Value $_ }
    $isolatedConfig = @(
        "model = $(ConvertTo-ToolkitTomlString -Value $RequiredModel)",
        'model_provider = "openrouter"',
        '',
        '[model_providers.openrouter]',
        'name = "OpenRouter"',
        'base_url = "https://openrouter.ai/api/v1"',
        'wire_api = "responses"',
        '',
        '[model_providers.openrouter.auth]',
        "command = $(ConvertTo-ToolkitTomlString -Value $authPowerShell)",
        "args = [$($argumentLiterals -join ', ')]"
    ) -join "`r`n"
    if ((Get-ToolkitTopLevelTomlValue -Content $isolatedConfig -Key 'model') -cne
        $RequiredModel) {
        throw '隔离配置中的模型 ID 校验失败。'
    }
    Write-Utf8FileAtomic `
        -Path (Join-Path $isolatedHome 'config.toml') `
        -Content ($isolatedConfig + "`r`n")

        $lastError = $null
        $publishedState = $null
        foreach ($attempt in 1..3) {
            $process = $null
            $processStarted = $false
            try {
                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = $codexPath
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.Environment['CODEX_HOME'] = $isolatedHome
                $startInfo.Environment['OPENROUTER_API_KEY'] = $apiKey
                [void]$startInfo.Environment.Remove('CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE')
                foreach ($argument in @('debug', 'models')) {
                    [void]$startInfo.ArgumentList.Add($argument)
                }

                $process = [Diagnostics.Process]::new()
                $process.StartInfo = $startInfo
                $processStarted = $process.Start()
                if (-not $processStarted) { throw '刷新进程未启动。' }
                $output = Read-CodexProcessOutputLimited `
                    -Process $process `
                    -TimeoutMilliseconds 60000 `
                    -MaximumStandardOutputBytes 25MB `
                    -MaximumStandardErrorBytes 1MB `
                    -Context '刷新进程'
                $stdout = $output.StandardOutput
                $stderr = $output.StandardError
                if ($stdout.Contains($apiKey) -or $stderr.Contains($apiKey) -or
                    $stdout -cmatch 'sk-or-[A-Za-z0-9._-]{8,}' -or
                    $stderr -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
                    throw '刷新进程输出包含疑似密钥，已拒绝保存。'
                }
                if ($process.ExitCode -ne 0) {
                    throw "退出码 $($process.ExitCode)：$(Protect-SensitiveText -Text $stderr)"
                }

                $catalogJson = $stdout
                $isolatedCachePath = Join-Path $isolatedHome 'models_cache.json'
                $isolatedCacheState = Get-CodexManagedFileState `
                    -Path $isolatedCachePath `
                    -MaximumBytes 25MB
                if ([bool]$isolatedCacheState.Existed) {
                    $remoteCacheText = ConvertFrom-CodexManagedTextState `
                        -State $isolatedCacheState
                    if ($remoteCacheText.Contains($apiKey) -or
                        $remoteCacheText -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
                        throw 'Codex 模型缓存包含疑似密钥，已拒绝保存。'
                    }
                    $remoteCache = $remoteCacheText | ConvertFrom-Json
                    $catalogJson = [pscustomobject]@{
                        models = @($remoteCache.models)
                    } | ConvertTo-Json -Depth 100 -Compress
                }

                Write-Utf8FileAtomic -Path $temporaryCatalogPath -Content $catalogJson
                [void](Set-OpenRouterAgentInstructions -Path $temporaryCatalogPath)
                $temporaryCatalogState = Get-CodexManagedFileState `
                    -Path $temporaryCatalogPath `
                    -MaximumBytes $script:MaximumCodexCatalogBytes
                if (-not (Test-CodexModelCatalogState `
                        -State $temporaryCatalogState `
                        -RequiredModel $RequiredModel)) {
                    throw '兼容刷新返回的模型目录不完整。'
                }
                $publishedState = Write-CodexManagedFileState `
                    -ExpectedState $catalogCommitState `
                    -Bytes ([byte[]]$temporaryCatalogState.Snapshot.Bytes) `
                    -MaximumBytes $script:MaximumCodexCatalogBytes
                $lastError = $null
                break
            }
            catch {
                $lastError = Protect-SensitiveText -Text $_.Exception.Message
                if ($attempt -lt 3) {
                    Write-Warning "第 $attempt 次兼容刷新未完成，正在重试。"
                    Start-Sleep -Seconds 1
                }
            }
            finally {
                if ($processStarted -and $process -and -not $process.HasExited) {
                    try { Stop-CodexProcessBounded -Process $process }
                    catch { Write-Warning '目录刷新进程未在限定时间内结束。' }
                }
                if ($process) { $process.Dispose() }
                if (Test-Path -LiteralPath $temporaryCatalogPath -PathType Leaf) {
                    Remove-Item -LiteralPath $temporaryCatalogPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if ($lastError) {
            if ($existingCatalogIsValid -and
                (Test-CodexModelCatalogState `
                    -State $catalogCommitState `
                    -RequiredModel $RequiredModel) -and
                (Test-CodexManagedFileStateMatches -State $catalogCommitState)) {
                Write-Warning "目录刷新失败，继续使用上一次的有效目录：$lastError"
                return New-CodexManagedOperationResult `
                    -Path $resolvedCatalogPath `
                    -InitialState $catalogInitialState `
                    -State $catalogCommitState `
                    -MaximumBytes $script:MaximumCodexCatalogBytes
            }
            throw "OpenRouter 模型目录刷新失败：$lastError"
        }
        if ($null -eq $publishedState) {
            throw '兼容刷新未返回已提交的模型目录快照。'
        }
        $modelCount = @(
            ((ConvertFrom-CodexManagedTextState -State $publishedState) |
                ConvertFrom-Json).models
        ).Count
        Write-Host "OpenRouter 模型目录已通过 Codex 兼容流程更新：$modelCount 个模型。"
        return New-CodexManagedOperationResult `
            -Path $resolvedCatalogPath `
            -InitialState $catalogInitialState `
            -State $publishedState `
            -MaximumBytes $script:MaximumCodexCatalogBytes
    }
    finally {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        $resolvedIsolatedHome = [IO.Path]::GetFullPath($isolatedHome)
        if (-not $resolvedIsolatedHome.StartsWith(
                $tempRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            Write-Warning "隔离目录路径超出系统临时目录，已拒绝清理：$resolvedIsolatedHome"
        }
        elseif (Test-Path -LiteralPath $resolvedIsolatedHome) {
            try {
                $isolatedSnapshot = Get-ToolkitDirectoryStateSnapshot `
                    -Root $resolvedIsolatedHome
                Remove-ToolkitDirectoryIfSnapshotMatches `
                    -Path $resolvedIsolatedHome `
                    -Snapshot $isolatedSnapshot `
                    -AllowInheritedPrivateChildren
            }
            catch {
                Write-Warning (
                    "隔离目录未能安全清理，可能仍含目录刷新认证材料；" +
                    "请核对后手动删除：$resolvedIsolatedHome。" +
                    (Protect-SensitiveText -Text $_.Exception.Message)
                )
            }
        }
    }
}

function Set-CodexDesktopModelConfigCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Model,

        [ValidateSet('openai', 'openrouter')]
        [string]$Provider = 'openai',

        [Parameter(Mandatory = $true)]
        [string]$ReasoningEffort,

        [string]$ModelCatalogPath,

        [string]$ConfigPath = (Join-Path (Get-DefaultCodexHome) 'config.toml'),

        [switch]$SkipBackup,

        [object]$ExpectedConfigState,

        [object]$ExpectedCatalogState
    )

    Assert-ToolkitModelId -Value $Model
    Assert-ToolkitReasoningEffort -Value $ReasoningEffort
    $resolvedConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $configState = if ($null -ne $ExpectedConfigState) {
        $ExpectedConfigState
    }
    else {
        Get-CodexManagedFileState `
            -Path $resolvedConfigPath `
            -MaximumBytes $script:MaximumCodexConfigBytes
    }
    if (-not (Test-ToolkitPathEqual `
            -Left ([string]$configState.Path) `
            -Right $resolvedConfigPath)) {
        throw '配置快照路径与写入目标不一致。'
    }

    $catalogState = $null
    if ($Provider -eq 'openrouter') {
        $resolvedCatalogPath = [IO.Path]::GetFullPath($ModelCatalogPath)
        $catalogState = if ($null -ne $ExpectedCatalogState) {
            $ExpectedCatalogState
        }
        else {
            Get-CodexManagedFileState `
                -Path $resolvedCatalogPath `
                -MaximumBytes $script:MaximumCodexCatalogBytes
        }
        if (-not [bool]$catalogState.Existed -or
            -not (Test-ToolkitPathEqual `
                -Left ([string]$catalogState.Path) `
                -Right $resolvedCatalogPath) -or
            -not (Test-CodexModelCatalogState `
                -State $catalogState `
                -RequiredModel $Model `
                -MinimumModelCount 1) -or
            -not (Test-CodexManagedFileStateMatches -State $catalogState)) {
            throw 'OpenRouter 模型目录尚未准备完成，或默认模型不在一致目录快照中。'
        }
    }

    $content = ConvertFrom-CodexManagedTextState -State $configState
    $content = Remove-ToolkitTopLevelTomlKeys `
        -Content $content `
        -Keys @('model', 'model_provider', 'model_reasoning_effort', 'model_catalog_json')
    if ($Provider -eq 'openrouter') {
        $content = Merge-ToolkitOpenRouterProvider -Content $content
    }
    $settings = [Collections.Generic.List[string]]::new()
    $settings.Add("model = $(ConvertTo-ToolkitTomlString -Value $Model)")
    $settings.Add(
        "model_reasoning_effort = $(ConvertTo-ToolkitTomlString -Value $ReasoningEffort)"
    )
    if ($Provider -eq 'openrouter') {
        $settings.Add('model_provider = "openrouter"')
        $settings.Add(
            "model_catalog_json = $(ConvertTo-ToolkitTomlString -Value $resolvedCatalogPath)"
        )
    }

    $blocks = [Collections.Generic.List[string]]::new()
    $blocks.Add(($settings -join "`r`n"))
    if (-not [string]::IsNullOrWhiteSpace($content)) {
        $blocks.Add($content.Trim())
    }

    $backupPath = $null
    if (-not $SkipBackup -and [bool]$configState.Existed) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $backupPath = "$resolvedConfigPath.bak-desktop-switch-$timestamp-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        $backupState = Get-CodexManagedFileState `
            -Path $backupPath `
            -MaximumBytes $script:MaximumCodexConfigBytes
        $backupParameters = @{
            ExpectedState = $backupState
            Bytes = [byte[]]$configState.Snapshot.Bytes
            MaximumBytes = $script:MaximumCodexConfigBytes
            TargetLastWriteTimeUtc = [DateTime]$configState.Snapshot.LastWriteTimeUtc
        }
        if ($IsWindows -and $null -ne $configState.Snapshot.Acl) {
            $backupParameters.DesiredAcl = $configState.Snapshot.Acl
        }
        [void](Write-CodexManagedFileState @backupParameters)
    }

    $newBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        (($blocks -join "`r`n`r`n") + "`r`n")
    )
    if ($null -ne $catalogState -and
        -not (Test-CodexManagedFileStateMatches -State $catalogState)) {
        throw 'OpenRouter 模型目录在配置提交前发生变化。'
    }
    $postState = Write-CodexManagedFileState `
        -ExpectedState $configState `
        -Bytes $newBytes `
        -MaximumBytes $script:MaximumCodexConfigBytes
    return [pscustomobject]@{
        BackupPath = $backupPath
        InitialState = $configState
        PostState = $postState
    }
}

function Set-CodexDesktopModelConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Model,
        [ValidateSet('openai', 'openrouter')] [string]$Provider = 'openai',
        [Parameter(Mandatory = $true)] [string]$ReasoningEffort,
        [string]$ModelCatalogPath,
        [string]$ConfigPath = (Join-Path (Get-DefaultCodexHome) 'config.toml'),
        [switch]$SkipBackup
    )

    $resolvedConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $mutex = Enter-ToolkitMutex -ScopePath (Split-Path -Parent $resolvedConfigPath)
    try {
        $configState = Get-CodexManagedFileState `
            -Path $resolvedConfigPath `
            -MaximumBytes $script:MaximumCodexConfigBytes
        $parameters = @{
            Model = $Model
            Provider = $Provider
            ReasoningEffort = $ReasoningEffort
            ModelCatalogPath = $ModelCatalogPath
            ConfigPath = $resolvedConfigPath
            SkipBackup = $SkipBackup
            ExpectedConfigState = $configState
        }
        $result = Set-CodexDesktopModelConfigCore @parameters
        return $result.BackupPath
    }
    finally {
        Exit-ToolkitMutex -Mutex $mutex
    }
}

function Get-CodexCacheModelsFromState {
    param(
        [Parameter(Mandatory = $true)] [object]$State
    )

    if (-not [bool]$State.Existed) { return $null }
    $text = ConvertFrom-CodexManagedTextState -State $State
    if ($text -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
        throw '模型缓存包含疑似密钥。'
    }
    $cache = $text | ConvertFrom-Json
    if (Test-CodexObjectContainsSensitiveValue -InputObject $cache) {
        throw '模型缓存包含疑似密钥。'
    }
    $modelsProperty = $cache.PSObject.Properties['models']
    if ($null -eq $modelsProperty -or
        $modelsProperty.Value -isnot [Collections.IList]) {
        throw '模型缓存缺少 models 数组。'
    }
    $models = @($modelsProperty.Value)
    if ($models.Count -lt 1 -or $models.Count -gt 10000) {
        throw '模型缓存数量超出范围。'
    }
    foreach ($model in $models) {
        $slug = $model.PSObject.Properties['slug']
        if ($null -eq $slug -or $slug.Value -isnot [string] -or
            -not (Test-ToolkitModelId -Value ([string]$slug.Value))) {
            throw '模型缓存包含无效 slug。'
        }
    }
    return ,$models
}

function Save-CodexDefaultModelCache {
    param(
        [Parameter(Mandatory = $true)] [string]$ActiveCachePath,
        [Parameter(Mandatory = $true)] [string]$OpenAICachePath,
        [Parameter(Mandatory = $true)] [string]$OpenAIModel,
        [Parameter(Mandatory = $true)] [string]$OpenRouterModel,
        [object]$ExpectedActiveState,
        [object]$ExpectedOpenAIState
    )

    $activeState = if ($null -ne $ExpectedActiveState) {
        $ExpectedActiveState
    }
    else {
        Get-CodexManagedFileState `
            -Path $ActiveCachePath `
            -MaximumBytes $script:MaximumCodexCacheBytes
    }
    if (-not [bool]$activeState.Existed) { return $null }
    try { $models = @(Get-CodexCacheModelsFromState -State $activeState) }
    catch {
        Write-Warning '当前 Codex 默认模型缓存无法安全备份，将由桌面端重新生成。'
        return $null
    }
    $hasOpenAIModel = [bool]($models |
        Where-Object { $_.slug -eq $OpenAIModel } |
        Select-Object -First 1)
    $hasOpenRouterModel = [bool]($models |
        Where-Object { $_.slug -eq $OpenRouterModel } |
        Select-Object -First 1)
    if ($hasOpenAIModel -and -not $hasOpenRouterModel) {
        if (-not (Test-CodexManagedFileStateMatches -State $activeState)) {
            throw '默认模型缓存在备份前发生变化。'
        }
        $openAIState = if ($null -ne $ExpectedOpenAIState) {
            $ExpectedOpenAIState
        }
        else {
            Get-CodexManagedFileState `
                -Path $OpenAICachePath `
                -MaximumBytes $script:MaximumCodexCacheBytes
        }
        $postState = Write-CodexManagedFileState `
            -ExpectedState $openAIState `
            -Bytes ([byte[]]$activeState.Snapshot.Bytes) `
            -MaximumBytes $script:MaximumCodexCacheBytes `
            -TargetLastWriteTimeUtc ([DateTime]$activeState.Snapshot.LastWriteTimeUtc)
        return New-CodexFileMutation `
            -InitialState $openAIState `
            -PostState $postState `
            -MaximumBytes $script:MaximumCodexCacheBytes
    }
    return $null
}

function Restore-CodexDefaultModelCache {
    param(
        [Parameter(Mandatory = $true)] [string]$ActiveCachePath,
        [Parameter(Mandatory = $true)] [string]$OpenAICachePath,
        [Parameter(Mandatory = $true)] [string]$OpenAIModel,
        [Parameter(Mandatory = $true)] [string]$OpenRouterModel,
        [object]$ExpectedActiveState,
        [object]$ExpectedOpenAIState
    )

    $activeState = if ($null -ne $ExpectedActiveState) {
        $ExpectedActiveState
    }
    else {
        Get-CodexManagedFileState `
            -Path $ActiveCachePath `
            -MaximumBytes $script:MaximumCodexCacheBytes
    }
    $openAIState = if ($null -ne $ExpectedOpenAIState) {
        $ExpectedOpenAIState
    }
    else {
        Get-CodexManagedFileState `
            -Path $OpenAICachePath `
            -MaximumBytes $script:MaximumCodexCacheBytes
    }

    $savedModels = $null
    if ([bool]$openAIState.Existed) {
        try { $savedModels = @(Get-CodexCacheModelsFromState -State $openAIState) }
        catch { Write-Warning '保存的 OpenAI 模型缓存无效，将尝试让桌面端重建。' }
    }
    $savedHasOpenAI = $false
    $savedHasOpenRouter = $false
    if ($null -ne $savedModels) {
        $savedHasOpenAI = [bool]($savedModels |
            Where-Object { $_.slug -eq $OpenAIModel } |
            Select-Object -First 1)
        $savedHasOpenRouter = [bool]($savedModels |
            Where-Object { $_.slug -eq $OpenRouterModel } |
            Select-Object -First 1)
    }
    if ($savedHasOpenAI -and -not $savedHasOpenRouter) {
        if (-not (Test-CodexManagedFileStateMatches -State $openAIState)) {
            throw '保存的 OpenAI 模型缓存在恢复前发生变化。'
        }
        $postState = Write-CodexManagedFileState `
            -ExpectedState $activeState `
            -Bytes ([byte[]]$openAIState.Snapshot.Bytes) `
            -MaximumBytes $script:MaximumCodexCacheBytes `
            -TargetLastWriteTimeUtc ([DateTime]$openAIState.Snapshot.LastWriteTimeUtc)
        return New-CodexFileMutation `
            -InitialState $activeState `
            -PostState $postState `
            -MaximumBytes $script:MaximumCodexCacheBytes
    }

    if ([bool]$activeState.Existed) {
        $activeModels = $null
        try { $activeModels = @(Get-CodexCacheModelsFromState -State $activeState) }
        catch { return $null }
        $activeIsOpenRouter = [bool]($activeModels |
            Where-Object { $_.slug -eq $OpenRouterModel } |
            Select-Object -First 1)
        if ($activeIsOpenRouter) {
            Remove-ToolkitFileIfSnapshotMatches `
                -Path ([string]$activeState.Path) `
                -Snapshot $activeState.Snapshot
            $postState = [pscustomobject]@{
                Path = [string]$activeState.Path
                Existed = $false
                Snapshot = $null
            }
            return New-CodexFileMutation `
                -InitialState $activeState `
                -PostState $postState `
                -MaximumBytes $script:MaximumCodexCacheBytes
        }
    }
    return $null
}

function Resolve-CodexDesktopAppFromInventory {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Packages,
        [Parameter(Mandatory = $true)] [scriptblock]$ManifestResolver
    )

    $orderedPackages = @($Packages |
        Where-Object {
            [string]$_.PackageFamilyName -cmatch
                '^OpenAI\.Codex_[A-Za-z0-9]+$' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation)
        } |
        Sort-Object -Property @{
            Expression = {
                try { [version]$_.Version }
                catch { [version]'0.0' }
            }
            Descending = $true
        })
    if ($orderedPackages.Count -eq 0) {
        throw '找不到具有有效安装位置的 Codex Desktop 程序包。'
    }

    foreach ($package in $orderedPackages) {
        try {
            $manifest = & $ManifestResolver $package
            $applications = @($manifest.Package.Applications.Application)
            $validApplications = @($applications | Where-Object {
                [string]$_.Id -cmatch '^[A-Za-z0-9._-]+$'
            })
            $chatApplications = @($validApplications | Where-Object {
                try {
                    [IO.Path]::GetFileName([string]$_.Executable) -ceq 'ChatGPT.exe'
                }
                catch { $false }
            })
            $application = if ($chatApplications.Count -eq 1) {
                $chatApplications[0]
            }
            elseif ($chatApplications.Count -eq 0 -and
                $validApplications.Count -eq 1) {
                $validApplications[0]
            }
            else { $null }
            if ($null -eq $application) { continue }

            $familyName = [string]$package.PackageFamilyName
            $installLocations = @($orderedPackages |
                Where-Object { [string]$_.PackageFamilyName -ceq $familyName } |
                ForEach-Object {
                    $root = [IO.Path]::GetFullPath([string]$_.InstallLocation)
                    $root.TrimEnd(
                        [IO.Path]::DirectorySeparatorChar,
                        [IO.Path]::AltDirectorySeparatorChar
                    ) + [IO.Path]::DirectorySeparatorChar
                } |
                Sort-Object -Unique)
            if ($installLocations.Count -eq 0) { continue }
            return [pscustomobject]@{
                PackageFamilyName = $familyName
                ApplicationId = [string]$application.Id
                AppUserModelId = "$familyName!$([string]$application.Id)"
                InstallLocations = $installLocations
            }
        }
        catch {
            continue
        }
    }
    throw '无法从 Codex Desktop 包清单确定唯一的启动入口。'
}

function Resolve-CodexDesktopApp {
    [CmdletBinding()]
    param()

    $packages = @(Get-AppxPackage `
        -Name 'OpenAI.Codex' `
        -ErrorAction SilentlyContinue)
    return Resolve-CodexDesktopAppFromInventory `
        -Packages $packages `
        -ManifestResolver {
            param($Package)
            Get-AppxPackageManifest -Package $Package -ErrorAction Stop
        }
}

function Resolve-CodexDesktopProcessSet {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Processes,
        [Parameter(Mandatory = $true)] [string[]]$InstallLocations,
        [Parameter(Mandatory = $true)] [int]$CurrentSessionId
    )

    $trustedRoots = @($InstallLocations | ForEach-Object {
        $root = [IO.Path]::GetFullPath($_)
        $root.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
    } | Sort-Object -Unique)
    if ($trustedRoots.Count -eq 0) {
        throw 'Codex Desktop 程序包缺少可验证的安装根目录。'
    }

    $matched = [Collections.Generic.List[object]]::new()
    foreach ($process in $Processes) {
        try { $sessionId = [int]$process.SessionId }
        catch { throw '无法验证 ChatGPT 进程所属会话，已停止自动重启。' }
        if ($sessionId -ne $CurrentSessionId) { continue }
        try {
            $rawPath = [string]$process.Path
            if ([string]::IsNullOrWhiteSpace($rawPath) -or
                -not [IO.Path]::IsPathFullyQualified($rawPath)) {
                throw 'path unavailable'
            }
            $processPath = [IO.Path]::GetFullPath($rawPath)
        }
        catch {
            throw '无法验证当前会话中 ChatGPT 进程的可执行文件路径，已停止自动重启。'
        }
        $insideTrustedRoot = [bool]($trustedRoots | Where-Object {
            $processPath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ([IO.Path]::GetFileName($processPath) -ceq 'ChatGPT.exe' -and
            $insideTrustedRoot) {
            $matched.Add($process)
        }
    }
    return @($matched)
}

function Get-CodexDesktopProcesses {
    param(
        [Parameter(Mandatory = $true)] [object]$AppInfo
    )

    $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    $processes = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
    return Resolve-CodexDesktopProcessSet `
        -Processes $processes `
        -InstallLocations ([string[]]$AppInfo.InstallLocations) `
        -CurrentSessionId $sessionId
}

function Stop-CodexDesktopApp {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Processes
    )

    foreach ($process in $Processes) {
        try {
            if (-not $process.HasExited) { [void]$process.CloseMainWindow() }
        }
        catch { throw "无法请求 Codex Desktop 安全退出：$($_.Exception.Message)" }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    foreach ($process in $Processes) {
        try {
            if ($process.HasExited) { continue }
            $remaining = [Math]::Max(
                0,
                [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            )
            if ($remaining -gt 0) { [void]$process.WaitForExit($remaining) }
        }
        catch { }
    }
    $remainingProcesses = @($Processes | Where-Object {
        try { -not $_.HasExited }
        catch { $false }
    })
    if ($remainingProcesses.Count -gt 0) {
        Write-Warning 'Codex Desktop 未在限定时间内退出，将结束已验证的残留进程；未保存的输入可能丢失。'
        foreach ($process in $remainingProcesses) {
            Stop-CodexProcessBounded `
                -Process $process `
                -TimeoutMilliseconds 5000
        }
    }
}

function New-CodexDesktopActivationStartInfo {
    param(
        [Parameter(Mandatory = $true)] [object]$AppInfo,
        [AllowNull()] [string]$ApiKey
    )

    if ([string]$AppInfo.AppUserModelId -cnotmatch
        '^OpenAI\.Codex_[A-Za-z0-9]+![A-Za-z0-9._-]+$') {
        throw 'Codex Desktop AUMID 格式无效。'
    }
    if (-not [string]::IsNullOrWhiteSpace($ApiKey) -and
        -not (Test-ToolkitApiKeyFormat -Value $ApiKey)) {
        throw 'Codex Desktop 启动凭据格式无效。'
    }
    $windowsDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Windows
    )
    $explorerPath = if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $null
    }
    else { Join-Path $windowsDirectory 'explorer.exe' }
    if ([string]::IsNullOrWhiteSpace($explorerPath) -or
        -not (Test-Path -LiteralPath $explorerPath -PathType Leaf)) {
        throw '找不到受信的 Windows Explorer，请手动启动 Codex Desktop。'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $explorerPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    [void]$startInfo.Environment.Remove('OPENROUTER_API_KEY')
    [void]$startInfo.Environment.Remove('CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE')
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $startInfo.Environment['OPENROUTER_API_KEY'] = $ApiKey
    }
    [void]$startInfo.ArgumentList.Add(
        "shell:AppsFolder\$([string]$AppInfo.AppUserModelId)"
    )
    return $startInfo
}

function Start-CodexDesktopApp {
    param(
        [Parameter(Mandatory = $true)] [object]$AppInfo,
        [AllowNull()] [string]$ApiKey
    )

    $startInfo = New-CodexDesktopActivationStartInfo `
        -AppInfo $AppInfo `
        -ApiKey $ApiKey
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Windows 启动代理未能启动。'
        }
    }
    finally {
        $process.Dispose()
    }
}

function Restart-CodexDesktopApp {
    [CmdletBinding()]
    param()

    $appInfo = Resolve-CodexDesktopApp
    $processes = @(Get-CodexDesktopProcesses -AppInfo $appInfo)
    Stop-CodexDesktopApp -Processes $processes
    $userKey = [Environment]::GetEnvironmentVariable(
        'OPENROUTER_API_KEY',
        [EnvironmentVariableTarget]::User
    )
    if (-not (Test-ToolkitApiKeyFormat -Value $userKey)) { $userKey = $null }
    Start-CodexDesktopApp -AppInfo $appInfo -ApiKey $userKey
}

function Switch-CodexDesktopProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('openai', 'openrouter')]
        [string]$Provider,

        [switch]$NoRestart,

        [switch]$ForceRefresh,

        [string]$SettingsPath = $script:DefaultSettingsPath,

        [Parameter(DontShow = $true)]
        [switch]$PassThruMutations
    )

    $settings = Get-CodexOpenRouterSettings -SettingsPath $SettingsPath
    $lockedCodexHome = [string]$settings.CodexHome
    $mutex = Enter-ToolkitMutex -ScopePath $lockedCodexHome
    $backupPath = $null
    $displayName = $null
    $desktopApiKey = $null
    $appInfo = $null
    $activationPlanned = $false
    $configurationCommitted = $false
    $transactionStarted = $false
    $rollbackCompleted = $false
    $switchError = $null
    $rollbackError = $null
    $activationError = $null
    $mutations = [Collections.Generic.List[object]]::new()
    try {
        try {
            $settings = Get-CodexOpenRouterSettings -SettingsPath $SettingsPath
            if (-not (Test-ToolkitPathEqual `
                    -Left ([string]$settings.CodexHome) `
                    -Right $lockedCodexHome)) {
                throw '工具包设置在获取文件锁后发生了 CodexHome 变化。'
            }
            $catalogPath = [string]$settings.CatalogPath
            if ($Provider -eq 'openrouter') {
                $desktopApiKey = Get-OpenRouterDesktopApiKey
            }

            if (-not $NoRestart) {
                $appInfo = Resolve-CodexDesktopApp
                $desktopProcesses = @(Get-CodexDesktopProcesses -AppInfo $appInfo)
                $activationPlanned = $true
                Stop-CodexDesktopApp -Processes $desktopProcesses
            }

            if ($Provider -eq 'openrouter') {
                $catalogParameters = @{
                    CatalogPath = $catalogPath
                    RequiredModel = [string]$settings.OpenRouterModel
                    MaximumAgeHours = [int]$settings.CatalogMaximumAgeHours
                }
                if ($ForceRefresh) { $catalogParameters.Force = $true }
                $catalogPath = Update-OpenRouterModelCatalog @catalogParameters
            }

            $configState = Get-CodexManagedFileState `
                -Path ([string]$settings.ConfigPath) `
                -MaximumBytes $script:MaximumCodexConfigBytes
            $activeCacheState = Get-CodexManagedFileState `
                -Path ([string]$settings.ActiveCachePath) `
                -MaximumBytes $script:MaximumCodexCacheBytes
            $openAICacheState = Get-CodexManagedFileState `
                -Path ([string]$settings.OpenAICachePath) `
                -MaximumBytes $script:MaximumCodexCacheBytes
            $catalogState = if ($Provider -eq 'openrouter') {
                Get-CodexManagedFileState `
                    -Path $catalogPath `
                    -MaximumBytes $script:MaximumCodexCatalogBytes
            }
            else { $null }
            $transactionStarted = $true

            if ($Provider -eq 'openrouter') {
                $cacheMutation = Save-CodexDefaultModelCache `
                    -ActiveCachePath ([string]$settings.ActiveCachePath) `
                    -OpenAICachePath ([string]$settings.OpenAICachePath) `
                    -OpenAIModel ([string]$settings.OpenAIModel) `
                    -OpenRouterModel ([string]$settings.OpenRouterModel) `
                    -ExpectedActiveState $activeCacheState `
                    -ExpectedOpenAIState $openAICacheState
                if ($null -ne $cacheMutation) { $mutations.Add($cacheMutation) }
                $configResult = Set-CodexDesktopModelConfigCore `
                    -Model ([string]$settings.OpenRouterModel) `
                    -Provider 'openrouter' `
                    -ReasoningEffort ([string]$settings.OpenRouterReasoningEffort) `
                    -ModelCatalogPath $catalogPath `
                    -ConfigPath ([string]$settings.ConfigPath) `
                    -ExpectedConfigState $configState `
                    -ExpectedCatalogState $catalogState
                $backupPath = $configResult.BackupPath
                $mutations.Add((New-CodexFileMutation `
                        -InitialState $configResult.InitialState `
                        -PostState $configResult.PostState `
                        -MaximumBytes $script:MaximumCodexConfigBytes))
                $displayName = 'OpenRouter'
            }
            else {
                $configResult = Set-CodexDesktopModelConfigCore `
                    -Model ([string]$settings.OpenAIModel) `
                    -Provider 'openai' `
                    -ReasoningEffort ([string]$settings.OpenAIReasoningEffort) `
                    -ConfigPath ([string]$settings.ConfigPath) `
                    -ExpectedConfigState $configState
                $backupPath = $configResult.BackupPath
                $mutations.Add((New-CodexFileMutation `
                        -InitialState $configResult.InitialState `
                        -PostState $configResult.PostState `
                        -MaximumBytes $script:MaximumCodexConfigBytes))
                $cacheMutation = Restore-CodexDefaultModelCache `
                    -ActiveCachePath ([string]$settings.ActiveCachePath) `
                    -OpenAICachePath ([string]$settings.OpenAICachePath) `
                    -OpenAIModel ([string]$settings.OpenAIModel) `
                    -OpenRouterModel ([string]$settings.OpenRouterModel) `
                    -ExpectedActiveState $activeCacheState `
                    -ExpectedOpenAIState $openAICacheState
                if ($null -ne $cacheMutation) { $mutations.Add($cacheMutation) }
                $displayName = 'Codex 默认'
            }
            $configurationCommitted = $true
        }
        catch {
            $switchError = $_
            if ($transactionStarted) {
                try {
                    Restore-CodexFileMutations -Mutations @($mutations)
                    $rollbackCompleted = $true
                }
                catch { $rollbackError = $_ }
            }
        }
    }
    finally {
        if ($activationPlanned) {
            try {
                $activationKey = if ($Provider -eq 'openrouter') {
                    $desktopApiKey
                }
                else { $null }
                Start-CodexDesktopApp `
                    -AppInfo $appInfo `
                    -ApiKey $activationKey
            }
            catch { $activationError = $_ }
        }
        Exit-ToolkitMutex -Mutex $mutex
    }

    if ($null -ne $switchError) {
        $stateMessage = if ($null -ne $rollbackError) {
            "文件回滚未完整完成：$($rollbackError.Exception.Message)"
        }
        elseif ($rollbackCompleted) { '配置更改已回滚。' }
        else { '配置更改尚未提交。' }
        $activationMessage = if ($null -ne $activationError) {
            " Codex Desktop 自动启动失败：$($activationError.Exception.Message)"
        }
        else { '' }
        throw "$($switchError.Exception.Message) $stateMessage$activationMessage"
    }
    if ($null -ne $activationError) {
        $commitMessage = if ($configurationCommitted) {
            '供应商配置已提交'
        }
        else { '供应商配置状态未确定' }
        throw "$commitMessage，Codex Desktop 自动启动失败：$($activationError.Exception.Message)。请手动启动应用。"
    }
    Write-Host "已切换桌面端供应商：$displayName"
    if ($backupPath) { Write-Host "配置备份：$backupPath" }
    if (-not $NoRestart) { Write-Host 'Codex Desktop 已提交启动请求。' }
    if ($PassThruMutations) {
        return [pscustomobject]@{
            Provider = $Provider
            BackupPath = $backupPath
            Mutations = @($mutations)
        }
    }
}

function Get-CodexOpenRouterStatus {
    [CmdletBinding()]
    param()

    $settings = Get-CodexOpenRouterSettings
    $configPath = [string]$settings.ConfigPath
    $catalogPath = [string]$settings.CatalogPath
    $configReadError = $null
    $provider = $null
    $model = $null
    try {
        $configState = Get-CodexManagedFileState `
            -Path $configPath `
            -MaximumBytes $script:MaximumCodexConfigBytes
        if (-not (Test-CodexManagedFileStateMatches -State $configState)) {
            throw '配置文件在状态读取期间发生变化。'
        }
        $configContent = ConvertFrom-CodexManagedTextState -State $configState
        $provider = Get-TopLevelTomlValue `
            -Content $configContent `
            -Key 'model_provider'
        $model = Get-TopLevelTomlValue -Content $configContent -Key 'model'
    }
    catch {
        $configReadError = Protect-SensitiveText -Text $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($provider) -and
        [string]::IsNullOrWhiteSpace($configReadError)) {
        $provider = 'openai'
    }
    $catalogValid = $false
    $catalogReadError = $null
    $modelCount = 0
    $promptConsistent = $false
    $catalogLastWriteTimeUtc = $null
    $catalogAgeHours = $null
    try {
        $catalogState = Get-CodexManagedFileState `
            -Path $catalogPath `
            -MaximumBytes $script:MaximumCodexCatalogBytes
        if (-not (Test-CodexManagedFileStateMatches -State $catalogState)) {
            throw '模型目录在状态读取期间发生变化。'
        }
        $catalogValid = Test-CodexModelCatalogState `
            -State $catalogState `
            -RequiredModel ([string]$settings.OpenRouterModel)
        if ([bool]$catalogState.Existed) {
            $catalogLastWriteTimeUtc =
                [DateTime]$catalogState.Snapshot.LastWriteTimeUtc
            $catalogAgeHours = [Math]::Round(
                ([DateTime]::UtcNow - $catalogLastWriteTimeUtc).TotalHours,
                2
            )
        }
        if ($catalogValid) {
            $catalog = ConvertFrom-CodexManagedTextState -State $catalogState |
                ConvertFrom-Json
            $models = @($catalog.models)
            $instruction = Get-DefaultAgentInstruction
            $modelCount = $models.Count
            $promptConsistent = @($models | Where-Object {
                Test-ModelAgentInstruction -Model $_ -Instruction $instruction
            }).Count -eq $models.Count
        }
    }
    catch {
        $catalogValid = $false
        $catalogReadError = Protect-SensitiveText -Text $_.Exception.Message
    }
    $cliPath = $null
    try {
        $cliPath = Get-CodexCliPath
    }
    catch {
        $cliPath = $null
    }
    $keyInfo = Get-OpenRouterApiKeyInfo
    $catalogApiKeyAvailable = Test-ToolkitApiKeyFormat `
        -Value ([string]$keyInfo.Value)
    $desktopApiKeyAvailable = $false
    $desktopApiKeyError = $null
    try {
        [void](Get-OpenRouterDesktopApiKey)
        $desktopApiKeyAvailable = $true
    }
    catch {
        $desktopApiKeyError = Protect-SensitiveText -Text $_.Exception.Message
    }

    [pscustomobject]@{
        Provider = $provider
        Model = $model
        ApiKeyAvailable = $desktopApiKeyAvailable
        CatalogApiKeyAvailable = $catalogApiKeyAvailable
        DesktopApiKeyAvailable = $desktopApiKeyAvailable
        DesktopApiKeyError = $desktopApiKeyError
        ApiKeySource = [string]$keyInfo.Source
        ApiKeyProcessUserMismatch = [bool]$keyInfo.ProcessUserMismatch
        CodexCliPath = $cliPath
        ConfigPath = $configPath
        CatalogPath = $catalogPath
        CatalogValid = $catalogValid
        CatalogModelCount = $modelCount
        CatalogLastWriteTimeUtc = $catalogLastWriteTimeUtc
        CatalogAgeHours = $catalogAgeHours
        ConfigReadError = $configReadError
        CatalogReadError = $catalogReadError
        LightweightPromptConsistent = $promptConsistent
    }
}

function cx {
    [CmdletBinding()]
    param(
        [switch]$NoRestart
    )

    Switch-CodexDesktopProvider -Provider 'openai' -NoRestart:$NoRestart
}

function cxor {
    [CmdletBinding()]
    param(
        [switch]$NoRestart,

        [switch]$ForceRefresh
    )

    Switch-CodexDesktopProvider `
        -Provider 'openrouter' `
        -NoRestart:$NoRestart `
        -ForceRefresh:$ForceRefresh
}

Export-ModuleMember -Function @(
    'cx',
    'cxor',
    'Get-CodexCliPath',
    'Get-CodexOpenRouterStatus',
    'Get-CodexOpenRouterSettings',
    'Initialize-CodexOpenRouterConfig',
    'Restart-CodexDesktopApp',
    'Set-CodexDesktopModelConfig',
    'Set-OpenRouterAgentInstructions',
    'Switch-CodexDesktopProvider',
    'Test-CodexModelCatalog',
    'Test-OpenRouterApiKey',
    'Update-OpenRouterModelCatalog'
)

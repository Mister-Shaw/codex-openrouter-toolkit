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
    if (-not (Test-Path -LiteralPath $script:DefaultPromptPath -PathType Leaf)) {
        throw "找不到轻量 Agent 提示文件：$script:DefaultPromptPath"
    }

    $instruction = [IO.File]::ReadAllText($script:DefaultPromptPath).Trim()
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
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "找不到工具包设置：$resolvedPath。请先运行安装脚本。"
    }

    try {
        $settings = [IO.File]::ReadAllText($resolvedPath) | ConvertFrom-Json
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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($RequiredModel) -and
            -not (Test-ToolkitModelId -Value $RequiredModel)) {
            return $false
        }
        $catalogText = [IO.File]::ReadAllText($Path)
        if ($catalogText -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
            return $false
        }
        $catalog = $catalogText | ConvertFrom-Json
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

        [switch]$PreserveLastWriteTime
    )

    if ([string]::IsNullOrWhiteSpace($Instruction)) {
        throw '轻量 Agent 提示不能为空。'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到 OpenRouter 模型目录：$Path"
    }
    if (-not (Test-CodexModelCatalog -Path $Path -MinimumModelCount 1)) {
        throw 'OpenRouter 模型目录结构未通过安全校验。'
    }

    $catalog = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $models = @($catalog.models)
    if ($models.Count -eq 0) {
        throw 'OpenRouter 模型目录中没有可用模型。'
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
        return $false
    }

    $resolvedPath = [IO.Path]::GetFullPath($Path)
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
    Write-ToolkitUtf8FileAtomic `
        -Path $resolvedPath `
        -Content $serialized `
        -PreserveLastWriteTime:$PreserveLastWriteTime

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
        if (-not $Process.HasExited) {
            try { $Process.Kill($true); $Process.WaitForExit() } catch { }
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
            try { $process.Kill($true); $process.WaitForExit() } catch { }
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
        [string]$ConfigPath = (Join-Path (Get-DefaultCodexHome) 'config.toml')
    )

    $resolvedPath = [IO.Path]::GetFullPath($ConfigPath)
    $content = if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        [IO.File]::ReadAllText($resolvedPath)
    }
    else {
        ''
    }

    $content = Merge-ToolkitOpenRouterProvider -Content $content
    Write-Utf8FileAtomic -Path $resolvedPath -Content ($content.TrimEnd() + "`r`n")
    return $resolvedPath
}

function Update-OpenRouterModelCatalog {
    [CmdletBinding()]
    param(
        [string]$CatalogPath,

        [string]$RequiredModel,

        [ValidateRange(1, 8760)]
        [int]$MaximumAgeHours = 24,

        [switch]$Force
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

    $existingCatalogIsValid = Test-CodexModelCatalog `
        -Path $resolvedCatalogPath `
        -RequiredModel $RequiredModel
    if ($existingCatalogIsValid) {
        $catalogItem = Get-Item -LiteralPath $resolvedCatalogPath -ErrorAction Stop
        $catalogAge = [DateTime]::UtcNow - $catalogItem.LastWriteTimeUtc
        [void](Set-OpenRouterAgentInstructions `
            -Path $resolvedCatalogPath `
            -PreserveLastWriteTime)
        $timestampIsPlausible = $catalogAge -ge [TimeSpan]::FromMinutes(-5)
        if (-not $timestampIsPlausible) {
            Write-Warning '模型目录时间戳位于未来，将执行安全刷新。'
        }
        elseif (-not $Force -and
            $catalogAge -lt [TimeSpan]::FromHours($MaximumAgeHours)) {
            return $resolvedCatalogPath
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
        if ($existingCatalogIsValid) {
            Write-Warning "Codex 版本探测失败，继续使用上一次的有效目录：$(Protect-SensitiveText -Text $_.Exception.Message)"
            return $resolvedCatalogPath
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
            if (-not (Test-CodexModelCatalog `
                    -Path $temporaryCatalogPath `
                    -RequiredModel $RequiredModel)) {
                throw 'OpenRouter 返回的模型目录未通过完整性校验。'
            }
            Write-ToolkitBytesAtomic `
                -Path $resolvedCatalogPath `
                -Bytes ([IO.File]::ReadAllBytes($temporaryCatalogPath))
            $modelCount = @(
                ([IO.File]::ReadAllText($resolvedCatalogPath) |
                    ConvertFrom-Json).models
            ).Count
            Write-Host "OpenRouter 模型目录已更新：$modelCount 个模型。"
            return $resolvedCatalogPath
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
    $systemRoot = [string]$env:SystemRoot
    $authPowerShell = if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $null
    }
    else {
        Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    if ([string]::IsNullOrWhiteSpace($authPowerShell) -or
        -not (Test-Path -LiteralPath $authPowerShell -PathType Leaf)) {
        throw '找不到 Windows PowerShell，无法建立隔离的 command-auth 配置。'
    }
    [void](New-Item -ItemType Directory -Path $isolatedHome -ErrorAction Stop)
    try {
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
                if (Test-Path -LiteralPath $isolatedCachePath -PathType Leaf) {
                    $cacheItem = Get-Item -LiteralPath $isolatedCachePath -ErrorAction Stop
                    if ($cacheItem.Length -gt 25MB) {
                        throw 'Codex 模型缓存长度超出限制。'
                    }
                    $remoteCacheText = [IO.File]::ReadAllText($isolatedCachePath)
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
                if (-not (Test-CodexModelCatalog `
                        -Path $temporaryCatalogPath `
                        -RequiredModel $RequiredModel)) {
                    throw '兼容刷新返回的模型目录不完整。'
                }
                Write-ToolkitBytesAtomic `
                    -Path $resolvedCatalogPath `
                    -Bytes ([IO.File]::ReadAllBytes($temporaryCatalogPath))
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
                    try { $process.Kill($true); $process.WaitForExit() } catch { }
                }
                if ($process) { $process.Dispose() }
                if (Test-Path -LiteralPath $temporaryCatalogPath -PathType Leaf) {
                    Remove-Item -LiteralPath $temporaryCatalogPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if ($lastError) {
            if ($existingCatalogIsValid) {
                Write-Warning "目录刷新失败，继续使用上一次的有效目录：$lastError"
                return $resolvedCatalogPath
            }
            throw "OpenRouter 模型目录刷新失败：$lastError"
        }
        $modelCount = @(
            ([IO.File]::ReadAllText($resolvedCatalogPath) | ConvertFrom-Json).models
        ).Count
        Write-Host "OpenRouter 模型目录已通过 Codex 兼容流程更新：$modelCount 个模型。"
        return $resolvedCatalogPath
    }
    finally {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedIsolatedHome = [IO.Path]::GetFullPath($isolatedHome)
        if ($resolvedIsolatedHome.StartsWith(
                $tempRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            (Test-Path -LiteralPath $resolvedIsolatedHome -PathType Container)) {
            try { [IO.Directory]::Delete($resolvedIsolatedHome, $true) }
            catch { Write-Warning '隔离目录未能立即清理，可在稍后手动删除临时目录。' }
        }
    }
}

function Set-CodexDesktopModelConfig {
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

        [switch]$SkipBackup
    )

    Assert-ToolkitModelId -Value $Model
    Assert-ToolkitReasoningEffort -Value $ReasoningEffort
    if ($Provider -eq 'openrouter' -and
        -not (Test-CodexModelCatalog `
            -Path $ModelCatalogPath `
            -RequiredModel $Model `
            -MinimumModelCount 1)) {
        throw 'OpenRouter 模型目录尚未准备完成，或默认模型不在目录中。'
    }

    $resolvedConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $content = if (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf) {
        [IO.File]::ReadAllText($resolvedConfigPath)
    }
    else {
        ''
    }
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
        $resolvedCatalogPath = [IO.Path]::GetFullPath($ModelCatalogPath)
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
    if (-not $SkipBackup -and
        (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $backupPath = "$resolvedConfigPath.bak-desktop-switch-$timestamp"
        Copy-ToolkitFileAtomic `
            -Source $resolvedConfigPath `
            -Destination $backupPath
    }

    Write-ToolkitUtf8FileAtomic `
        -Path $resolvedConfigPath `
        -Content (($blocks -join "`r`n`r`n") + "`r`n")
    return $backupPath
}

function Save-CodexDefaultModelCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActiveCachePath,

        [Parameter(Mandatory = $true)]
        [string]$OpenAICachePath,

        [Parameter(Mandatory = $true)]
        [string]$OpenAIModel,

        [Parameter(Mandatory = $true)]
        [string]$OpenRouterModel
    )

    if (-not (Test-Path -LiteralPath $ActiveCachePath -PathType Leaf)) {
        return
    }
    try {
        $models = @(
            ([IO.File]::ReadAllText($ActiveCachePath) | ConvertFrom-Json).models
        )
    }
    catch {
        Write-Warning '当前 Codex 默认模型缓存无法备份，将由桌面端重新生成。'
        return
    }
    $hasOpenAIModel = [bool]($models |
        Where-Object { $_.slug -eq $OpenAIModel } |
        Select-Object -First 1)
    $hasOpenRouterModel = [bool]($models |
        Where-Object { $_.slug -eq $OpenRouterModel } |
        Select-Object -First 1)
    if ($hasOpenAIModel -and -not $hasOpenRouterModel) {
        Copy-ToolkitFileAtomic `
            -Source $ActiveCachePath `
            -Destination $OpenAICachePath
    }
}

function Restore-CodexDefaultModelCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActiveCachePath,

        [Parameter(Mandatory = $true)]
        [string]$OpenAICachePath
    )

    if (Test-Path -LiteralPath $OpenAICachePath -PathType Leaf) {
        Copy-ToolkitFileAtomic `
            -Source $OpenAICachePath `
            -Destination $ActiveCachePath
    }
}

function Get-ToolkitFileSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    $snapshots = [Collections.Generic.List[object]]::new()
    foreach ($path in @($Paths | Sort-Object -Unique)) {
        $resolvedPath = [IO.Path]::GetFullPath($path)
        $exists = Test-Path -LiteralPath $resolvedPath -PathType Leaf
        $snapshots.Add([pscustomobject]@{
            Path = $resolvedPath
            Existed = $exists
            Bytes = if ($exists) { [IO.File]::ReadAllBytes($resolvedPath) } else { $null }
            LastWriteTimeUtc = if ($exists) {
                (Get-Item -LiteralPath $resolvedPath -ErrorAction Stop).LastWriteTimeUtc
            }
            else {
                $null
            }
        })
    }
    return @($snapshots)
}

function Restore-ToolkitFileSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Snapshots
    )

    foreach ($snapshot in $Snapshots) {
        if ([bool]$snapshot.Existed) {
            Write-ToolkitBytesAtomic `
                -Path ([string]$snapshot.Path) `
                -Bytes ([byte[]]$snapshot.Bytes)
            [IO.File]::SetLastWriteTimeUtc(
                [string]$snapshot.Path,
                [DateTime]$snapshot.LastWriteTimeUtc
            )
        }
        elseif (Test-Path -LiteralPath ([string]$snapshot.Path) -PathType Leaf) {
            Remove-Item -LiteralPath ([string]$snapshot.Path) -Force -ErrorAction Stop
        }
    }
}

function Restart-CodexDesktopApp {
    [CmdletBinding()]
    param()

    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
    $installLocations = @($packages | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation)) {
            [IO.Path]::GetFullPath([string]$_.InstallLocation).TrimEnd('\') + '\'
        }
    } | Sort-Object -Unique)
    if ($installLocations.Count -eq 0) {
        throw '找不到 Codex Desktop 的已安装程序包。请手动重启应用。'
    }

    $startApps = @(Get-StartApps -ErrorAction Stop)
    $startApp = $startApps |
        Where-Object { $_.AppID -match '^OpenAI\.Codex_.*!App$' } |
        Select-Object -First 1
    if (-not $startApp) {
        $startApp = $startApps |
            Where-Object {
                $_.Name -match '^(Codex|ChatGPT)$' -and
                $_.AppID -match '^OpenAI\.'
            } |
            Select-Object -First 1
    }
    if (-not $startApp) {
        throw '找不到 Codex Desktop 的 Windows 启动入口。请手动重启应用。'
    }

    $escapedAppId = $startApp.AppID.Replace("'", "''")
    $restartScript = @"
Start-Sleep -Seconds 10
Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\$escapedAppId'
"@
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($restartScript)
    )
    $powerShellPath = (Get-Process -Id $PID).Path
    Start-Process `
        -FilePath $powerShellPath `
        -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encodedCommand) `
        -WindowStyle Hidden `
        -ErrorAction Stop

    $processes = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
        try {
            $processPath = [IO.Path]::GetFullPath($_.Path)
            [IO.Path]::GetFileName($processPath) -ceq 'ChatGPT.exe' -and
                [bool]($installLocations | Where-Object {
                    $processPath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
        }
        catch {
            $false
        }
    })
    foreach ($process in $processes) {
        [void]$process.CloseMainWindow()
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ($processes.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $processes = @($processes | Where-Object {
            try { -not $_.HasExited } catch { $false }
        })
    }
    if ($processes.Count -gt 0) {
        Write-Warning 'Codex Desktop 未能及时退出，将结束残留进程；未保存的输入可能丢失。'
        $processes | Stop-Process -Force -ErrorAction Stop
    }
}

function Switch-CodexDesktopProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('openai', 'openrouter')]
        [string]$Provider,

        [switch]$NoRestart,

        [switch]$ForceRefresh,

        [string]$SettingsPath = $script:DefaultSettingsPath
    )

    $settings = Get-CodexOpenRouterSettings -SettingsPath $SettingsPath
    $lockedCodexHome = [string]$settings.CodexHome
    $mutex = Enter-ToolkitMutex -ScopePath $lockedCodexHome
    $backupPath = $null
    $displayName = $null
    try {
        $settings = Get-CodexOpenRouterSettings -SettingsPath $SettingsPath
        if (-not (Test-ToolkitPathEqual `
                -Left ([string]$settings.CodexHome) `
                -Right $lockedCodexHome)) {
            throw '工具包设置在获取文件锁后发生了 CodexHome 变化。'
        }
        $catalogPath = [string]$settings.CatalogPath
        if ($Provider -eq 'openrouter') {
            if (-not (Test-OpenRouterApiKey)) {
                throw '当前 PowerShell 无法读取有效的 OPENROUTER_API_KEY。请先运行密钥设置脚本。'
            }
            $catalogParameters = @{
                CatalogPath = $catalogPath
                RequiredModel = [string]$settings.OpenRouterModel
                MaximumAgeHours = [int]$settings.CatalogMaximumAgeHours
            }
            if ($ForceRefresh) { $catalogParameters.Force = $true }
            $catalogPath = Update-OpenRouterModelCatalog @catalogParameters
        }

        $snapshots = Get-ToolkitFileSnapshots -Paths @(
            [string]$settings.ConfigPath,
            [string]$settings.ActiveCachePath,
            [string]$settings.OpenAICachePath
        )
        try {
            if ($Provider -eq 'openrouter') {
                Save-CodexDefaultModelCache `
                    -ActiveCachePath ([string]$settings.ActiveCachePath) `
                    -OpenAICachePath ([string]$settings.OpenAICachePath) `
                    -OpenAIModel ([string]$settings.OpenAIModel) `
                    -OpenRouterModel ([string]$settings.OpenRouterModel)
                $backupPath = Set-CodexDesktopModelConfig `
                    -Model ([string]$settings.OpenRouterModel) `
                    -Provider 'openrouter' `
                    -ReasoningEffort ([string]$settings.OpenRouterReasoningEffort) `
                    -ModelCatalogPath $catalogPath `
                    -ConfigPath ([string]$settings.ConfigPath)
                $displayName = 'OpenRouter'
            }
            else {
                $backupPath = Set-CodexDesktopModelConfig `
                    -Model ([string]$settings.OpenAIModel) `
                    -Provider 'openai' `
                    -ReasoningEffort ([string]$settings.OpenAIReasoningEffort) `
                    -ConfigPath ([string]$settings.ConfigPath)
                Restore-CodexDefaultModelCache `
                    -ActiveCachePath ([string]$settings.ActiveCachePath) `
                    -OpenAICachePath ([string]$settings.OpenAICachePath)
                $displayName = 'Codex 默认'
            }
        }
        catch {
            $primaryError = $_
            try { Restore-ToolkitFileSnapshots -Snapshots $snapshots }
            catch {
                throw "$($primaryError.Exception.Message) 文件回滚也未完成：$($_.Exception.Message)"
            }
            throw $primaryError
        }
    }
    finally {
        Exit-ToolkitMutex -Mutex $mutex
    }

    Write-Host "已切换桌面端供应商：$displayName"
    if ($backupPath) { Write-Host "配置备份：$backupPath" }
    if (-not $NoRestart) {
        Write-Host '正在重新启动 Codex Desktop。'
        Restart-CodexDesktopApp
    }
}

function Get-CodexOpenRouterStatus {
    [CmdletBinding()]
    param()

    $settings = Get-CodexOpenRouterSettings
    $configPath = [string]$settings.ConfigPath
    $catalogPath = [string]$settings.CatalogPath
    $configContent = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        [IO.File]::ReadAllText($configPath)
    }
    else {
        ''
    }
    $provider = Get-TopLevelTomlValue -Content $configContent -Key 'model_provider'
    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = 'openai'
    }
    $model = Get-TopLevelTomlValue -Content $configContent -Key 'model'
    $catalogValid = Test-CodexModelCatalog `
        -Path $catalogPath `
        -RequiredModel ([string]$settings.OpenRouterModel)
    $modelCount = 0
    $promptConsistent = $false
    $catalogLastWriteTimeUtc = $null
    $catalogAgeHours = $null
    if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
        $catalogLastWriteTimeUtc =
            (Get-Item -LiteralPath $catalogPath -ErrorAction Stop).LastWriteTimeUtc
        $catalogAgeHours = [Math]::Round(
            ([DateTime]::UtcNow - $catalogLastWriteTimeUtc).TotalHours,
            2
        )
    }
    if ($catalogValid) {
        $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
        $models = @($catalog.models)
        $instruction = Get-DefaultAgentInstruction
        $modelCount = $models.Count
        $promptConsistent = @($models | Where-Object {
            Test-ModelAgentInstruction -Model $_ -Instruction $instruction
        }).Count -eq $models.Count
    }
    $cliPath = $null
    try {
        $cliPath = Get-CodexCliPath
    }
    catch {
        $cliPath = $null
    }
    $keyInfo = Get-OpenRouterApiKeyInfo

    [pscustomobject]@{
        Provider = $provider
        Model = $model
        ApiKeyAvailable = Test-ToolkitApiKeyFormat -Value ([string]$keyInfo.Value)
        ApiKeySource = [string]$keyInfo.Source
        ApiKeyProcessUserMismatch = [bool]$keyInfo.ProcessUserMismatch
        CodexCliPath = $cliPath
        ConfigPath = $configPath
        CatalogPath = $catalogPath
        CatalogValid = $catalogValid
        CatalogModelCount = $modelCount
        CatalogLastWriteTimeUtc = $catalogLastWriteTimeUtc
        CatalogAgeHours = $catalogAgeHours
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

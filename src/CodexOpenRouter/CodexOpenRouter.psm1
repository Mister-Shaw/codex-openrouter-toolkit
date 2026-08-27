Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot
$script:DefaultSettingsPath = Join-Path $script:ToolkitRoot 'settings.json'
$script:DefaultPromptPath = Join-Path $script:ModuleRoot 'lightweight-agent-prompt.txt'

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

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop)
    }

    $temporaryPath = "$resolvedPath.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $Content,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $resolvedPath `
            -Force `
            -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Get-TopLevelTomlValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $firstTable = [regex]::Match($Content, '(?m)^[ \t]*\[')
    $topLevel = if ($firstTable.Success) {
        $Content.Substring(0, $firstTable.Index)
    }
    else {
        $Content
    }

    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Key) +
        '[ \t]*=[ \t]*"([^"]*)"[ \t]*(?:#.*)?$'
    $match = [regex]::Match($topLevel, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
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
        return [IO.File]::ReadAllText($resolvedPath) | ConvertFrom-Json
    }
    catch {
        throw "工具包设置无法解析：$resolvedPath。$($_.Exception.Message)"
    }
}

function Get-OpenRouterApiKey {
    $targets = @(
        [EnvironmentVariableTarget]::Process,
        [EnvironmentVariableTarget]::User
    )

    foreach ($target in $targets) {
        $value = [Environment]::GetEnvironmentVariable(
            'OPENROUTER_API_KEY',
            $target
        )
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Test-OpenRouterApiKey {
    $apiKey = Get-OpenRouterApiKey
    return -not [string]::IsNullOrWhiteSpace($apiKey) -and
        $apiKey -cmatch '^sk-or-v1-[A-Za-z0-9_-]{16,}$'
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
        $catalog = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $models = @($catalog.models)
        if ($models.Count -lt $MinimumModelCount -or
            $models.Count -gt $MaximumModelCount) {
            return $false
        }
        $slugs = @($models | ForEach-Object { [string]$_.slug })
        if (@($slugs | Where-Object {
                [string]::IsNullOrWhiteSpace($_) -or
                $_ -notmatch '^[A-Za-z0-9._:@/+~\-]+$'
            }).Count -gt 0) {
            return $false
        }
        if (@($slugs | Sort-Object -Unique).Count -ne $slugs.Count) {
            return $false
        }
        foreach ($model in $models) {
            $hasLegacyPrompt =
                $null -ne $model.PSObject.Properties['base_instructions']
            $messagesProperty = $model.PSObject.Properties['model_messages']
            $hasCurrentPrompt =
                $null -ne $messagesProperty -and
                $null -ne $messagesProperty.Value
            if (-not $hasLegacyPrompt -and -not $hasCurrentPrompt) {
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

        [string]$Instruction = (Get-DefaultAgentInstruction)
    )

    if ([string]::IsNullOrWhiteSpace($Instruction)) {
        throw '轻量 Agent 提示不能为空。'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到 OpenRouter 模型目录：$Path"
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
    $temporaryPath = "$resolvedPath.instructions-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            ($catalog | ConvertTo-Json -Depth 100 -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        $writtenCatalog = [IO.File]::ReadAllText($temporaryPath) |
            ConvertFrom-Json
        $writtenModels = @($writtenCatalog.models)
        $writtenMatches = @($writtenModels | Where-Object {
            Test-ModelAgentInstruction -Model $_ -Instruction $Instruction
        }).Count
        if ($writtenModels.Count -ne $models.Count -or
            $writtenMatches -ne $models.Count) {
            throw "写入后的轻量 Agent 提示校验失败：$writtenMatches/$($models.Count)"
        }

        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $resolvedPath `
            -Force `
            -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    return $true
}

function Get-CodexCliPath {
    [CmdletBinding()]
    param()

    $command = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $binRoot = Join-Path $localAppData 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot -PathType Container) {
        $bundled = Get-ChildItem -LiteralPath $binRoot `
            -Recurse `
            -Filter 'codex.exe' `
            -File `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($bundled) {
            return $bundled.FullName
        }
    }

    throw '找不到 Codex CLI。请确认 Codex Desktop 已安装并至少启动过一次。'
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
        'sk-or-v1-[A-Za-z0-9_-]{8,}',
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

        [ValidateRange(1, 100)]
        [int]$MaximumSizeMegabytes = 25
    )

    if ($Uri.Scheme -cne 'https' -or
        $Uri.Host -cne 'openrouter.ai') {
        throw "拒绝访问非预期目录地址：$Uri"
    }

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        $Uri
    )
    [void]$request.Headers.UserAgent.ParseAdd("Codex/$ClientVersion")
    $response = $null
    $stream = $null
    $memory = $null
    try {
        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ge 300 -and $statusCode -lt 400) {
            throw "OpenRouter 目录地址返回了未接受的重定向：$statusCode"
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "OpenRouter 目录请求失败：HTTP $statusCode"
        }

        $maximumBytes = $MaximumSizeMegabytes * 1MB
        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and $contentLength -gt $maximumBytes) {
            throw "OpenRouter 目录响应超过 $MaximumSizeMegabytes MB 限制。"
        }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $memory = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(81920)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt $maximumBytes) {
                throw "OpenRouter 目录响应超过 $MaximumSizeMegabytes MB 限制。"
            }
            $memory.Write($buffer, 0, $read)
        }
        return [Text.Encoding]::UTF8.GetString($memory.ToArray())
    }
    finally {
        if ($memory) { $memory.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
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

    $authPattern = '(?ms)^[ \t]*\[model_providers\.openrouter\.auth\][ \t]*(?:\r?\n|$).*?(?=^[ \t]*\[|\z)'
    $content = [regex]::Replace($content, $authPattern, '')

    $providerBlock = @'
[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
'@
    $providerPattern = '(?ms)^[ \t]*\[model_providers\.openrouter\][ \t]*(?:\r?\n|$).*?(?=^[ \t]*\[|\z)'
    if ([regex]::IsMatch($content, $providerPattern)) {
        $content = [regex]::Replace(
            $content,
            $providerPattern,
            { param($match) $providerBlock + "`r`n`r`n" }
        )
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`n" + $providerBlock + "`r`n"
    }

    Write-Utf8FileAtomic -Path $resolvedPath -Content ($content.Trim() + "`r`n")
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

    $resolvedCatalogPath = [IO.Path]::GetFullPath($CatalogPath)
    $catalogParent = Split-Path -Parent $resolvedCatalogPath
    if (-not (Test-Path -LiteralPath $catalogParent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $catalogParent -Force -ErrorAction Stop)
    }

    $existingCatalogIsValid = Test-CodexModelCatalog `
        -Path $resolvedCatalogPath `
        -RequiredModel $RequiredModel
    if ($existingCatalogIsValid) {
        $catalogAge = [DateTime]::UtcNow -
            (Get-Item -LiteralPath $resolvedCatalogPath -ErrorAction Stop).LastWriteTimeUtc
        [void](Set-OpenRouterAgentInstructions -Path $resolvedCatalogPath)
        if (-not $Force -and
            $catalogAge -lt [TimeSpan]::FromHours($MaximumAgeHours)) {
            return $resolvedCatalogPath
        }

        Write-Host "OpenRouter 模型目录正在更新，当前目录年龄为 $([Math]::Round($catalogAge.TotalHours, 1)) 小时。"
    }

    $apiKey = Get-OpenRouterApiKey
    if (-not (Test-OpenRouterApiKey)) {
        throw '当前 PowerShell 无法读取 OPENROUTER_API_KEY。请先运行密钥设置脚本。'
    }
    $env:OPENROUTER_API_KEY = $apiKey

    $codexPath = Get-CodexCliPath
    $temporaryCatalogPath = "$resolvedCatalogPath.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    $versionText = (& $codexPath --version 2>$null | Out-String).Trim()
    $versionMatch = [regex]::Match($versionText, '\d+\.\d+\.\d+')
    if (-not $versionMatch.Success) {
        if ($existingCatalogIsValid) {
            Write-Warning '无法识别 Codex 版本，继续使用上一次的有效目录。'
            return $resolvedCatalogPath
        }
        throw "无法从版本信息中识别 Codex 版本：$versionText"
    }

    $clientVersion = $versionMatch.Value
    $catalogUri = "https://openrouter.ai/api/v1/models?client_version=$clientVersion"
    $downloadError = $null
    foreach ($downloadAttempt in 1..3) {
        try {
            $catalogContent = Invoke-OpenRouterCatalogDownload `
                -Uri $catalogUri `
                -ClientVersion $clientVersion
            [IO.File]::WriteAllText(
                $temporaryCatalogPath,
                $catalogContent,
                [Text.UTF8Encoding]::new($false)
            )
            [void](Set-OpenRouterAgentInstructions -Path $temporaryCatalogPath)
            if (-not (Test-CodexModelCatalog `
                    -Path $temporaryCatalogPath `
                    -RequiredModel $RequiredModel)) {
                throw 'OpenRouter 返回的模型目录未通过完整性校验。'
            }

            Move-Item `
                -LiteralPath $temporaryCatalogPath `
                -Destination $resolvedCatalogPath `
                -Force `
                -ErrorAction Stop
            $modelCount = @(
                ([IO.File]::ReadAllText($resolvedCatalogPath) |
                    ConvertFrom-Json).models
            ).Count
            Write-Host "OpenRouter 模型目录已更新：$modelCount 个模型。"
            return $resolvedCatalogPath
        }
        catch {
            $downloadError = $_
            if ($downloadAttempt -lt 3) {
                Write-Warning "第 $downloadAttempt 次目录下载未完成，正在重试。"
                Start-Sleep -Seconds 1
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryCatalogPath) {
                Remove-Item `
                    -LiteralPath $temporaryCatalogPath `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }

    if ($existingCatalogIsValid) {
        Write-Warning "目录更新失败，继续使用上一次的有效目录：$downloadError"
        return $resolvedCatalogPath
    }

    Write-Warning '公开目录下载失败，正在尝试 Codex 兼容刷新流程。'
    $isolatedHome = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "codex-openrouter-catalog-$PID-$([Guid]::NewGuid().ToString('N'))"
    [void](New-Item -ItemType Directory -Path $isolatedHome -ErrorAction Stop)

    $isolatedConfig = @'
model = "__MODEL__"
model_provider = "openrouter"

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
'@
    $isolatedConfig = $isolatedConfig.
        Replace('__MODEL__', $RequiredModel)
    Write-Utf8FileAtomic `
        -Path (Join-Path $isolatedHome 'config.toml') `
        -Content $isolatedConfig

    try {
        $lastError = $null
        foreach ($attempt in 1..3) {
            $process = $null
            try {
                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = $codexPath
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.Environment['CODEX_HOME'] = $isolatedHome
                $startInfo.Environment['OPENROUTER_API_KEY'] = $apiKey
                foreach ($argument in @('debug', 'models')) {
                    [void]$startInfo.ArgumentList.Add($argument)
                }

                $process = [Diagnostics.Process]::new()
                $process.StartInfo = $startInfo
                [void]$process.Start()
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(60000)) {
                    $process.Kill($true)
                    $process.WaitForExit()
                    throw '刷新进程超过 60 秒。'
                }

                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                if ($process.ExitCode -ne 0) {
                    $safeError = Protect-SensitiveText -Text $stderr
                    throw "退出码 $($process.ExitCode)：$safeError"
                }

                $catalogJson = $stdout
                $isolatedCachePath = Join-Path $isolatedHome 'models_cache.json'
                if (Test-Path -LiteralPath $isolatedCachePath -PathType Leaf) {
                    $remoteCache = [IO.File]::ReadAllText($isolatedCachePath) |
                        ConvertFrom-Json
                    $catalogJson = [pscustomobject]@{
                        models = @($remoteCache.models)
                    } | ConvertTo-Json -Depth 100 -Compress
                }

                Write-Utf8FileAtomic `
                    -Path $temporaryCatalogPath `
                    -Content $catalogJson
                [void](Set-OpenRouterAgentInstructions -Path $temporaryCatalogPath)
                if (-not (Test-CodexModelCatalog `
                        -Path $temporaryCatalogPath `
                        -RequiredModel $RequiredModel)) {
                    throw '兼容刷新返回的模型目录不完整。'
                }

                Move-Item `
                    -LiteralPath $temporaryCatalogPath `
                    -Destination $resolvedCatalogPath `
                    -Force `
                    -ErrorAction Stop
                $lastError = $null
                break
            }
            catch {
                $lastError = $_
                if ($attempt -lt 3) {
                    Write-Warning "第 $attempt 次兼容刷新未完成，正在重试。"
                    Start-Sleep -Seconds 1
                }
            }
            finally {
                if ($process -and -not $process.HasExited) {
                    $process.Kill($true)
                    $process.WaitForExit()
                }
                if ($process) {
                    $process.Dispose()
                }
                if (Test-Path -LiteralPath $temporaryCatalogPath) {
                    Remove-Item `
                        -LiteralPath $temporaryCatalogPath `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            }
        }

        if ($lastError) {
            throw "OpenRouter 模型目录刷新失败：$lastError"
        }
        return $resolvedCatalogPath
    }
    finally {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $resolvedIsolatedHome = [IO.Path]::GetFullPath($isolatedHome)
        if ($resolvedIsolatedHome.StartsWith(
                $tempRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            (Test-Path -LiteralPath $resolvedIsolatedHome -PathType Container)) {
            [IO.Directory]::Delete($resolvedIsolatedHome, $true)
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

    if ($Model -notmatch '^[A-Za-z0-9._:@/+~\-]+$') {
        throw "模型 ID 包含不支持的字符：$Model"
    }
    if ($ReasoningEffort -notmatch '^[A-Za-z0-9._-]+$') {
        throw "推理强度包含不支持的字符：$ReasoningEffort"
    }
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
    $firstTable = [regex]::Match($content, '(?m)^[ \t]*\[')
    if ($firstTable.Success) {
        $topLevel = $content.Substring(0, $firstTable.Index)
        $tables = $content.Substring($firstTable.Index)
    }
    else {
        $topLevel = $content
        $tables = ''
    }

    $topLevel = [regex]::Replace(
        $topLevel,
        '(?m)^[ \t]*(model|model_provider|model_reasoning_effort|model_catalog_json)[ \t]*=.*(?:\r?\n|$)',
        ''
    ).Trim()
    $settings = [Collections.Generic.List[string]]::new()
    $settings.Add("model = `"$Model`"")
    $settings.Add("model_reasoning_effort = `"$ReasoningEffort`"")
    if ($Provider -eq 'openrouter') {
        $settings.Add('model_provider = "openrouter"')
        $escapedCatalogPath = $ModelCatalogPath.Replace('\', '\\').Replace('"', '\"')
        $settings.Add("model_catalog_json = `"$escapedCatalogPath`"")
    }

    $blocks = [Collections.Generic.List[string]]::new()
    $blocks.Add(($settings -join "`r`n"))
    if (-not [string]::IsNullOrWhiteSpace($topLevel)) {
        $blocks.Add($topLevel)
    }
    if (-not [string]::IsNullOrWhiteSpace($tables)) {
        $blocks.Add($tables.Trim())
    }

    $backupPath = $null
    if (-not $SkipBackup -and
        (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $backupPath = "$resolvedConfigPath.bak-desktop-switch-$timestamp"
        Copy-Item `
            -LiteralPath $resolvedConfigPath `
            -Destination $backupPath `
            -ErrorAction Stop
    }

    Write-Utf8FileAtomic `
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
        $hasOpenAIModel = [bool]($models |
            Where-Object { $_.slug -eq $OpenAIModel } |
            Select-Object -First 1)
        $hasOpenRouterModel = [bool]($models |
            Where-Object { $_.slug -eq $OpenRouterModel } |
            Select-Object -First 1)
        if ($hasOpenAIModel -and -not $hasOpenRouterModel) {
            Copy-Item `
                -LiteralPath $ActiveCachePath `
                -Destination $OpenAICachePath `
                -Force `
                -ErrorAction Stop
        }
    }
    catch {
        Write-Warning '当前 Codex 默认模型缓存无法备份，将由桌面端重新生成。'
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
        Copy-Item `
            -LiteralPath $OpenAICachePath `
            -Destination $ActiveCachePath `
            -Force `
            -ErrorAction Stop
    }
}

function Restart-CodexDesktopApp {
    [CmdletBinding()]
    param()

    $startApps = @(Get-StartApps)
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
Start-Sleep -Seconds 2
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

    $processes = @(Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        [void]$process.CloseMainWindow()
    }
    if ($processes.Count -gt 0) {
        Start-Sleep -Milliseconds 750
    }
    $remaining = @(Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue)
    if ($remaining.Count -gt 0) {
        Write-Warning 'Codex Desktop 未能及时退出，将结束残留进程；未保存的输入可能丢失。'
        $remaining | Stop-Process -Force -ErrorAction Stop
    }
}

function Switch-CodexDesktopProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('openai', 'openrouter')]
        [string]$Provider,

        [switch]$NoRestart,

        [switch]$ForceRefresh
    )

    $settings = Get-CodexOpenRouterSettings
    $catalogPath = [string]$settings.CatalogPath
    if ($Provider -eq 'openrouter') {
        if (-not (Test-OpenRouterApiKey)) {
            throw '当前 PowerShell 无法读取 OPENROUTER_API_KEY。请先运行密钥设置脚本。'
        }

        Initialize-CodexOpenRouterConfig `
            -ConfigPath ([string]$settings.ConfigPath) | Out-Null
        Save-CodexDefaultModelCache `
            -ActiveCachePath ([string]$settings.ActiveCachePath) `
            -OpenAICachePath ([string]$settings.OpenAICachePath) `
            -OpenAIModel ([string]$settings.OpenAIModel) `
            -OpenRouterModel ([string]$settings.OpenRouterModel)
        $catalogParameters = @{
            CatalogPath = $catalogPath
            RequiredModel = [string]$settings.OpenRouterModel
            MaximumAgeHours = [int]$settings.CatalogMaximumAgeHours
        }
        if ($ForceRefresh) {
            $catalogParameters.Force = $true
        }
        $catalogPath = Update-OpenRouterModelCatalog @catalogParameters
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

    Write-Host "已切换桌面端供应商：$displayName"
    if ($backupPath) {
        Write-Host "配置备份：$backupPath"
    }
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

    [pscustomobject]@{
        Provider = $provider
        Model = $model
        ApiKeyAvailable = Test-OpenRouterApiKey
        CodexCliPath = $cliPath
        ConfigPath = $configPath
        CatalogPath = $catalogPath
        CatalogValid = $catalogValid
        CatalogModelCount = $modelCount
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

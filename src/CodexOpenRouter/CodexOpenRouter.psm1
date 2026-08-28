Set-StrictMode -Version Latest

$script:MaximumConfigBytes = 5MB
$script:MaximumCatalogBytes = 50MB
$script:ManagedBlockBegin = '# BEGIN CodexOpenRouter managed provider'
$script:ManagedBlockEnd = '# END CodexOpenRouter managed provider'
$script:EmptyInstructions = ''
$script:FeaturedModels = @(
    [pscustomobject]@{ Slug = '~openai/gpt-latest'; DisplayName = 'GPT Latest' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.6-sol-pro'; DisplayName = 'GPT-5.6 Sol Pro' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.6-sol'; DisplayName = 'GPT-5.6 Sol' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.6-terra'; DisplayName = 'GPT-5.6 Terra' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.3-codex'; DisplayName = 'GPT-5.3 Codex' }
    [pscustomobject]@{ Slug = '~anthropic/claude-opus-latest'; DisplayName = 'Claude Opus Latest' }
    [pscustomobject]@{ Slug = 'anthropic/claude-opus-5'; DisplayName = 'Claude Opus 5' }
    [pscustomobject]@{ Slug = '~anthropic/claude-sonnet-latest'; DisplayName = 'Claude Sonnet Latest' }
    [pscustomobject]@{ Slug = 'anthropic/claude-sonnet-5'; DisplayName = 'Claude Sonnet 5' }
)

function Assert-CxRuntime {
    if (-not $IsWindows) {
        throw 'CodexOpenRouter 仅支持 Windows。'
    }
    if ($PSVersionTable.PSEdition -ne 'Core' -or
        $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'CodexOpenRouter 需要 PowerShell 7.4 或更高版本。'
    }
}

function Get-CxCodexHome {
    $configured = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            throw '无法确定当前用户目录。'
        }
        $configured = Join-Path $userProfile '.codex'
    }
    if (-not [IO.Path]::IsPathFullyQualified($configured)) {
        throw '用户级 CODEX_HOME 必须是绝对路径。'
    }
    return [IO.Path]::GetFullPath($configured)
}

function Get-CxPaths {
    $codexHome = Get-CxCodexHome
    [pscustomobject]@{
        CodexHome = $codexHome
        ConfigPath = Join-Path $codexHome 'config.toml'
        CatalogPath = Join-Path $codexHome 'openrouter-model-catalog.json'
    }
}

function ConvertTo-CxTomlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        switch ($code) {
            8 { [void]$builder.Append('\b') }
            9 { [void]$builder.Append('\t') }
            10 { [void]$builder.Append('\n') }
            12 { [void]$builder.Append('\f') }
            13 { [void]$builder.Append('\r') }
            34 { [void]$builder.Append('\"') }
            92 { [void]$builder.Append('\\') }
            default {
                if ($code -lt 32 -or $code -eq 127) {
                    [void]$builder.Append(('\u{0:X4}' -f $code))
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

function New-CxTomlCodeMask {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

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
                    else { $state = 'basic' }
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
                    else { $state = 'literal' }
                }
            }
            'comment' {
                if ($isNewLine) { $state = 'normal' }
                else { $mask[$index] = ' ' }
            }
            'basic' {
                if ($isNewLine) { throw 'TOML 基本字符串跨越了物理行。' }
                $mask[$index] = ' '
                if ($character -eq '\') {
                    if ($index + 1 -lt $characters.Length) {
                        $index++
                        if ($characters[$index] -ne "`r" -and
                            $characters[$index] -ne "`n") {
                            $mask[$index] = ' '
                        }
                    }
                }
                elseif ($character -eq '"') { $state = 'normal' }
            }
            'literal' {
                if ($isNewLine) { throw 'TOML 字面字符串跨越了物理行。' }
                $mask[$index] = ' '
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
                        if ($quoteRun -gt 5) { throw 'TOML 多行基本字符串的结束引号数量无效。' }
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
                        if ($quoteRun -gt 5) { throw 'TOML 多行字面字符串的结束引号数量无效。' }
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

function Get-CxAuthPowerShell {
    $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        throw '无法确定 Windows 系统目录。'
    }
    $path = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '找不到 Windows PowerShell，无法读取 OpenRouter 密钥。'
    }
    return [IO.Path]::GetFullPath($path)
}

function New-CxProviderBlock {
    param(
        [Parameter(Mandatory)][string]$AuthCommand,
        [switch]$ReadProcessEnvironment
    )

    $tokenCommand = if ($ReadProcessEnvironment) {
        '[Console]::Out.Write($env:OPENROUTER_API_KEY)'
    }
    else {
        "[Console]::Out.Write([Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY',[EnvironmentVariableTarget]::User))"
    }
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $tokenCommand) |
        ForEach-Object { ConvertTo-CxTomlString $_ }
    return @(
        $script:ManagedBlockBegin
        '[model_providers.openrouter]'
        'name = "OpenRouter"'
        'base_url = "https://openrouter.ai/api/v1"'
        'wire_api = "responses"'
        ''
        '[model_providers.openrouter.auth]'
        "command = $(ConvertTo-CxTomlString $AuthCommand)"
        "args = [$($args -join ', ')]"
        'timeout_ms = 5000'
        'refresh_interval_ms = 0'
        $script:ManagedBlockEnd
    ) -join "`r`n"
}

function Update-CxConfigContent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][ValidateSet('Default', 'OpenRouter')][string]$Mode,
        [string]$CatalogPath,
        [string]$AuthCommand,
        [string]$Model = '~openai/gpt-latest'
    )

    if ($Mode -eq 'OpenRouter' -and
        ([string]::IsNullOrWhiteSpace($CatalogPath) -or
         [string]::IsNullOrWhiteSpace($AuthCommand) -or
         $Model -notmatch '^[^\s\x00-\x1F]{1,256}$')) {
        throw 'OpenRouter 配置缺少有效的模型、目录或认证命令。'
    }

    $mask = New-CxTomlCodeMask $Content
    $matches = [regex]::Matches($Content, '.*?(?:\r\n|\n|\r|$)', 'Singleline') |
        Where-Object { $_.Length -gt 0 }
    $kept = [Collections.Generic.List[string]]::new()
    $inRoot = $true
    $inProviderParent = $false
    $skipProvider = $false
    $providersKey = '(?:model_providers|"model_providers"|''model_providers'')'
    $openRouterKey = '(?:openrouter|"openrouter"|''openrouter'')'

    foreach ($match in $matches) {
        $line = $match.Value
        $code = $mask.Substring($match.Index, $match.Length)
        $trimmed = $line.Trim()
        if ($trimmed -ceq $script:ManagedBlockBegin -or
            $trimmed -ceq $script:ManagedBlockEnd) {
            continue
        }

        $isArrayHeader = $code -match '^\s*\[\['
        $isHeader = $code -match '^\s*\[[^\[\]]+\]\s*$'
        $isOpenRouterHeader = $line -match (
            '^\s*\[\s*' + $providersKey + '\s*\.\s*' +
            $openRouterKey +
            '(?:\s*\.|\s*\])'
        )
        if ($isArrayHeader -and $line -match (
                '^\s*\[\[\s*' + $providersKey + '\s*\.\s*' + $openRouterKey
            )) {
            throw 'OpenRouter provider 不能声明为 TOML 数组表。'
        }
        if ($isHeader -or $isArrayHeader) {
            $inRoot = $false
            $inProviderParent = $isHeader -and
                $line -match ('^\s*\[\s*' + $providersKey + '\s*\]\s*(?:#.*)?$')
            if ($isOpenRouterHeader) {
                $skipProvider = $true
                continue
            }
            $skipProvider = $false
            $kept.Add($line)
            continue
        }
        if ($skipProvider) { continue }

        if ($inRoot -and $code -match '=' -and $line -match (
                '^\s*(?:model|model_provider|model_reasoning_effort|model_catalog_json|' +
                '"(?:model|model_provider|model_reasoning_effort|model_catalog_json)"|' +
                '''(?:model|model_provider|model_reasoning_effort|model_catalog_json)'')\s*='
            )) {
            continue
        }
        if ($inRoot -and $code -match '=' -and
            $line -match ('^\s*' + $providersKey + '\s*=')) {
            throw '不支持 inline model_providers；请改为标准 TOML 表。'
        }
        if ($inRoot -and $code -match '=' -and $line -match (
                '^\s*' + $providersKey + '\s*\.\s*' +
                $openRouterKey +
                '(?:\s*\.|\s*=)'
            )) {
            continue
        }
        if ($inProviderParent -and $code -match '=' -and
            $line -match '^\s*(?:openrouter|"openrouter"|''openrouter'')(?:\s*\.|\s*=)') {
            continue
        }
        $kept.Add($line)
    }

    $preserved = (-join $kept).Trim()
    $blocks = [Collections.Generic.List[string]]::new()
    if ($Mode -eq 'OpenRouter') {
        $blocks.Add((@(
            "model = $(ConvertTo-CxTomlString $Model)"
            'model_provider = "openrouter"'
            "model_catalog_json = $(ConvertTo-CxTomlString ([IO.Path]::GetFullPath($CatalogPath)))"
        ) -join "`r`n"))
    }
    if (-not [string]::IsNullOrWhiteSpace($preserved)) { $blocks.Add($preserved) }
    if ($Mode -eq 'OpenRouter') {
        $blocks.Add((New-CxProviderBlock -AuthCommand $AuthCommand))
    }
    if ($blocks.Count -eq 0) { return '' }
    return ($blocks -join "`r`n`r`n") + "`r`n"
}

function Read-CxTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "路径不是普通文件：$Path"
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝读取重解析点：$Path"
    }
    if ($item.Length -gt $MaximumBytes) { throw "文件超过大小限制：$Path" }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { return $text.Substring(1) }
    return $text
}

function Write-CxTextFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($resolved)
    if ([string]::IsNullOrWhiteSpace($directory)) { throw '目标文件缺少父目录。' }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
    }
    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝写入重解析目录：$directory"
    }
    if ((Test-Path -LiteralPath $resolved) -and
        -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "目标不是普通文件：$resolved"
    }
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        $targetItem = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "拒绝替换重解析点：$resolved"
        }
    }
    $temporary = Join-Path $directory ('.cx-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $resolved, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CxFileFingerprint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 104857600)][long]$MaximumBytes = 5MB
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt $MaximumBytes) {
        throw "文件无法安全计算摘要：$Path"
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-CxConfigChange {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Default', 'OpenRouter')][string]$Mode,
        [string]$CatalogPath,
        [string]$AuthCommand,
        [string]$Model = '~openai/gpt-latest'
    )

    $fingerprintBefore = Get-CxFileFingerprint $Path
    $content = Read-CxTextFile -Path $Path -MaximumBytes $script:MaximumConfigBytes
    $fingerprintAfter = Get-CxFileFingerprint $Path
    if ($fingerprintBefore -cne $fingerprintAfter) {
        throw 'config.toml 在读取期间被其他程序修改，已取消切换。'
    }
    [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($Path)
        OriginalFingerprint = $fingerprintAfter
        OriginalContent = $content
        Content = Update-CxConfigContent -Content $content -Mode $Mode `
            -CatalogPath $CatalogPath -AuthCommand $AuthCommand -Model $Model
    }
}

function Commit-CxConfigChange {
    param([Parameter(Mandatory)][object]$Change)

    $fingerprintBefore = Get-CxFileFingerprint $Change.Path
    $current = Read-CxTextFile -Path $Change.Path -MaximumBytes $script:MaximumConfigBytes
    $fingerprintAfter = Get-CxFileFingerprint $Change.Path
    if ($fingerprintBefore -cne $Change.OriginalFingerprint -or
        $fingerprintAfter -cne $Change.OriginalFingerprint -or
        $current -cne [string]$Change.OriginalContent) {
        throw 'config.toml 在切换期间被其他程序修改，已取消写入。'
    }
    if ($current -cne [string]$Change.Content) {
        Write-CxTextFileAtomic -Path $Change.Path -Content ([string]$Change.Content)
    }
}

function Test-CxApiKey {
    param([AllowNull()][string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -cmatch '\Ask-or-[A-Za-z0-9._-]{16,}\z'
}

function Protect-CxText {
    param([AllowNull()][string]$Text, [AllowNull()][string]$ApiKey)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $protected = $Text
    if (-not [string]::IsNullOrEmpty($ApiKey)) {
        $protected = $protected.Replace($ApiKey, '<redacted>')
    }
    return [regex]::Replace($protected, 'sk-or-[A-Za-z0-9._-]{8,}', '<redacted>')
}

function Set-CxUserApiKey {
    $secure = Read-Host 'OpenRouter API Key' -AsSecureString
    $pointer = [IntPtr]::Zero
    $plain = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if (-not (Test-CxApiKey $plain)) {
            throw 'OpenRouter API Key 格式无效。'
        }
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $plain, 'User')
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $plain, 'Process')
        return $plain
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        $secure.Dispose()
    }
}

function Get-CxUserApiKey {
    param([switch]$Prompt)

    $key = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
    if (Test-CxApiKey $key) {
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $key, 'Process')
        return $key
    }
    if ($Prompt) { return Set-CxUserApiKey }
    throw '尚未设置有效的用户级 OPENROUTER_API_KEY。请运行 cxor -SetKey。'
}

function Get-CxCodexCliPath {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $binRoot = Join-Path $localAppData 'OpenAI\Codex\bin'
    if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
        throw '找不到 Codex Desktop 内置 CLI。请安装或更新 Codex Desktop。'
    }
    $root = [IO.Path]::GetFullPath($binRoot).TrimEnd('\') + '\'
    $candidates = @(Get-ChildItem -LiteralPath $binRoot -Recurse -File `
        -Filter 'codex.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($candidate in $candidates) {
        try {
            $path = [IO.Path]::GetFullPath($candidate.FullName)
            if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            if ($signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
                $null -ne $signature.SignerCertificate -and
                $signature.SignerCertificate.Subject -like '*OpenAI OpCo, LLC*') {
                return $path
            }
        }
        catch { continue }
    }
    throw '找不到由 OpenAI 有效签名的 Codex Desktop 内置 CLI。'
}

function Invoke-CxProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][hashtable]$Environment,
        [ValidateRange(1000, 300000)][int]$TimeoutMilliseconds = 90000
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add($argument) }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Codex CLI 未能启动。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit(5000)
            throw 'Codex CLI 刷新模型目录超时。'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt $script:MaximumCatalogBytes -or
            [Text.Encoding]::UTF8.GetByteCount($stderr) -gt 1MB) {
            throw 'Codex CLI 输出超过大小限制。'
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; StandardOutput = $stdout; StandardError = $stderr }
    }
    finally { $process.Dispose() }
}

function Get-CxCodexClientVersion {
    param([Parameter(Mandatory)][string]$CliPath)

    $result = Invoke-CxProcess -FilePath $CliPath -ArgumentList @('--version') `
        -Environment @{} -TimeoutMilliseconds 10000
    if ($result.ExitCode -ne 0) {
        throw "Codex CLI 版本查询返回退出码 $($result.ExitCode)：$($result.StandardError)"
    }
    $match = [regex]::Match(
        [string]$result.StandardOutput,
        '(?m)^\s*codex-cli\s+(?<version>\d+\.\d+\.\d+)(?:[-+][^\s]+)?\s*$'
    )
    if (-not $match.Success) {
        throw 'Codex CLI 未返回可识别的三段版本号。'
    }
    return $match.Groups['version'].Value
}

function New-CxOpenRouterCatalogRequest {
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ClientVersion
    )

    if (-not (Test-CxApiKey $ApiKey)) { throw 'OpenRouter API Key 格式无效。' }
    if ($ClientVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Codex CLI 客户端版本无效。'
    }
    $encodedVersion = [Uri]::EscapeDataString($ClientVersion)
    $uri = [Uri]::new(
        "https://openrouter.ai/api/v1/models?client_version=$encodedVersion"
    )
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $uri)
    try {
        $request.Headers.Authorization =
            [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $ApiKey)
        if (-not $request.Headers.TryAddWithoutValidation('originator', 'Codex Desktop')) {
            throw '无法设置 OpenRouter 模型目录请求头。'
        }
        return $request
    }
    catch {
        $request.Dispose()
        throw
    }
}

function Invoke-CxOpenRouterCatalogRequest {
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ClientVersion
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $client = $null
    $request = $null
    $response = $null
    try {
        $handler.AllowAutoRedirect = $false
        $handler.AutomaticDecompression =
            [Net.DecompressionMethods]::GZip -bor
            [Net.DecompressionMethods]::Deflate -bor
            [Net.DecompressionMethods]::Brotli
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $client.MaxResponseContentBufferSize = $script:MaximumCatalogBytes
        $request = New-CxOpenRouterCatalogRequest -ApiKey $ApiKey `
            -ClientVersion $ClientVersion
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw "OpenRouter 模型目录请求返回 HTTP $statusCode。"
        }
        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and $contentLength -gt $script:MaximumCatalogBytes) {
            throw 'OpenRouter 模型目录响应超过大小限制。'
        }
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ($bytes.Length -gt $script:MaximumCatalogBytes) {
            throw 'OpenRouter 模型目录响应超过大小限制。'
        }
        try { $content = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
        catch { throw 'OpenRouter 模型目录响应不是有效 UTF-8。' }
        if ($content.Contains($ApiKey)) {
            throw 'OpenRouter 模型目录响应包含 API Key。'
        }
        return $content
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        else { $handler.Dispose() }
    }
}

function Set-CxObjectProperty {
    param([Parameter(Mandatory)][object]$Object, [Parameter(Mandatory)][string]$Name, [AllowNull()]$Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $property.Value = $Value }
}

function Convert-CxCatalogPrompt {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$AllModels
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw '模型目录内容为空。'
    }
    if ([Text.Encoding]::UTF8.GetByteCount($Content) -gt $script:MaximumCatalogBytes) {
        throw '模型目录超过大小限制。'
    }
    if ($Content -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
        throw '模型目录包含疑似密钥。'
    }
    try { $catalog = $Content | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "模型目录不是有效 JSON：$($_.Exception.Message)" }
    $modelsProperty = $catalog.PSObject.Properties['models']
    if ($null -eq $modelsProperty -or $modelsProperty.Value -isnot [array]) {
        throw '模型目录缺少 models 数组。'
    }
    $models = @($modelsProperty.Value)
    if ($models.Count -lt 1 -or $models.Count -gt 5000) {
        throw '模型目录的模型数量无效。'
    }
    $slugs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($model in $models) {
        if ($null -eq $model) { throw '模型目录包含空模型。' }
        $slugProperty = $model.PSObject.Properties['slug']
        $slug = if ($null -eq $slugProperty) { '' } else { [string]$slugProperty.Value }
        if ($slug -notmatch '^[^\s\x00-\x1F]{1,256}$') { throw '模型目录包含无效 slug。' }
        if (-not $slugs.Add($slug)) { throw "模型目录包含重复 slug：$slug" }

        Set-CxObjectProperty -Object $model -Name 'base_instructions' -Value $script:EmptyInstructions
        $messagesProperty = $model.PSObject.Properties['model_messages']
        if ($null -eq $messagesProperty -or $null -eq $messagesProperty.Value -or
            $messagesProperty.Value -isnot [pscustomobject]) {
            $messages = [pscustomobject]@{}
            Set-CxObjectProperty -Object $model -Name 'model_messages' -Value $messages
        }
        else { $messages = $messagesProperty.Value }
        Set-CxObjectProperty -Object $messages -Name 'instructions_template' -Value $script:EmptyInstructions
    }

    if ($AllModels) {
        foreach ($model in $models) {
            Set-CxObjectProperty -Object $model -Name 'visibility' -Value 'list'
        }
    }
    else {
        $featuredBySlug = @{}
        for ($index = 0; $index -lt $script:FeaturedModels.Count; $index++) {
            $definition = $script:FeaturedModels[$index]
            $featuredBySlug[[string]$definition.Slug] = [pscustomobject]@{
                DisplayName = [string]$definition.DisplayName
                Priority = $index + 1
            }
        }

        $featured = [Collections.Generic.List[object]]::new()
        $hidden = [Collections.Generic.List[object]]::new()
        foreach ($model in $models) {
            $slug = [string]$model.slug
            if ($featuredBySlug.ContainsKey($slug)) {
                $definition = $featuredBySlug[$slug]
                Set-CxObjectProperty -Object $model -Name 'display_name' -Value $definition.DisplayName
                Set-CxObjectProperty -Object $model -Name 'priority' -Value $definition.Priority
                Set-CxObjectProperty -Object $model -Name 'visibility' -Value 'list'
                $featured.Add($model)
            }
            else {
                Set-CxObjectProperty -Object $model -Name 'visibility' -Value 'hide'
                $hidden.Add($model)
            }
        }

        $orderedModels = @(
            foreach ($definition in $script:FeaturedModels) {
                foreach ($model in $featured) {
                    if ([string]$model.slug -ieq [string]$definition.Slug) { $model }
                }
            }
            foreach ($model in $hidden) { $model }
        )
        $modelsProperty.Value = $orderedModels
        $models = $orderedModels
    }

    $json = $catalog | ConvertTo-Json -Depth 100 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:MaximumCatalogBytes -or
        $json -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
        throw '改写后的模型目录无效。'
    }
    $verified = $json | ConvertFrom-Json -ErrorAction Stop
    $verifiedModels = @($verified.models)
    $invalidModels = @($verifiedModels | Where-Object {
        $baseProperty = $_.PSObject.Properties['base_instructions']
        $messagesProperty = $_.PSObject.Properties['model_messages']
        $templateProperty = if ($null -eq $messagesProperty -or
            $null -eq $messagesProperty.Value) {
            $null
        }
        else {
            $messagesProperty.Value.PSObject.Properties['instructions_template']
        }
        $null -eq $baseProperty -or
        $baseProperty.Value -isnot [string] -or
        $baseProperty.Value -cne $script:EmptyInstructions -or
        $null -eq $templateProperty -or
        $templateProperty.Value -isnot [string] -or
        $templateProperty.Value -cne $script:EmptyInstructions
    })
    if ($verifiedModels.Count -ne $models.Count -or $invalidModels.Count -ne 0) {
        throw '模型基础指令清空校验失败。'
    }
    return $json
}

function Resolve-CxCatalogCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [switch]$AllModels,
        [AllowNull()][string]$ApiKey,
        [AllowEmptyString()][string]$StandardError = ''
    )

    $failures = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $Candidates) {
        $labelProperty = if ($null -eq $candidate) {
            $null
        }
        else { $candidate.PSObject.Properties['Label'] }
        $label = if ($null -eq $labelProperty -or
            [string]::IsNullOrWhiteSpace([string]$labelProperty.Value)) {
            '未命名候选'
        }
        else { [string]$labelProperty.Value }
        $contentProperty = if ($null -eq $candidate) {
            $null
        }
        else { $candidate.PSObject.Properties['Content'] }
        $candidateContent = if ($null -eq $contentProperty -or
            $null -eq $contentProperty.Value) {
            ''
        }
        else { [string]$contentProperty.Value }

        if ([string]::IsNullOrWhiteSpace($candidateContent)) {
            $failureProperty = if ($null -eq $candidate) {
                $null
            }
            else { $candidate.PSObject.Properties['Failure'] }
            $failure = if ($null -eq $failureProperty -or
                [string]::IsNullOrWhiteSpace([string]$failureProperty.Value)) {
                '空或不存在'
            }
            else {
                Protect-CxText ([string]$failureProperty.Value) $ApiKey
            }
            if ($failure.Length -gt 300) { $failure = $failure.Substring(0, 300) + '…' }
            $failures.Add("$label：$failure")
            continue
        }
        try {
            $converted = Convert-CxCatalogPrompt -Content $candidateContent `
                -AllModels:$AllModels
            $convertedModels = @(($converted | ConvertFrom-Json -ErrorAction Stop).models)
            if (@($convertedModels | Where-Object {
                        $_.slug -ceq '~openai/gpt-latest'
                    }).Count -ne 1) {
                throw '缺少官方默认入口 ~openai/gpt-latest。'
            }
            $previousProperty = $candidate.PSObject.Properties['IsPrevious']
            return [pscustomobject]@{
                Content = $converted
                Models = $convertedModels
                Source = $label
                UsedPreviousCatalog = $null -ne $previousProperty -and
                    [bool]$previousProperty.Value
            }
        }
        catch {
            $safeMessage = Protect-CxText $_.Exception.Message $ApiKey
            if ($safeMessage.Length -gt 300) {
                $safeMessage = $safeMessage.Substring(0, 300) + '…'
            }
            $failures.Add("$label：$safeMessage")
        }
    }

    $candidateDetail = if ($failures.Count -eq 0) {
        '没有候选来源'
    }
    else { $failures -join '；' }
    $safeError = Protect-CxText $StandardError $ApiKey
    if ($safeError.Length -gt 1000) { $safeError = $safeError.Substring(0, 1000) + '…' }
    $errorDetail = if ([string]::IsNullOrWhiteSpace($safeError)) { '无' } else { $safeError.Trim() }
    throw "OpenRouter 与 Codex CLI 未返回可用模型目录。候选检查：$candidateDetail。Codex CLI stderr：$errorDetail"
}

function Sync-CxOpenRouterCatalog {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$AuthCommand,
        [switch]$AllModels
    )

    $temporaryHome = ''
    try {
        $candidates = [Collections.Generic.List[object]]::new()
        $directContent = ''
        $directFailure = ''
        try {
            $clientVersion = Get-CxCodexClientVersion -CliPath $CliPath
            $directContent = Invoke-CxOpenRouterCatalogRequest -ApiKey $ApiKey `
                -ClientVersion $clientVersion
        }
        catch { $directFailure = Protect-CxText $_.Exception.Message $ApiKey }
        $directCandidate = [pscustomobject]@{
            Label = 'OpenRouter Codex API'
            Content = $directContent
            Failure = $directFailure
            IsPrevious = $false
        }
        $candidates.Add($directCandidate)

        $resolvedCatalog = $null
        if (-not [string]::IsNullOrWhiteSpace($directContent)) {
            try {
                $resolvedCatalog = Resolve-CxCatalogCandidate `
                    -Candidates @($directCandidate) -AllModels:$AllModels -ApiKey $ApiKey
            }
            catch { $directFailure = Protect-CxText $_.Exception.Message $ApiKey }
        }

        if ($null -eq $resolvedCatalog) {
            $catalogDirectory = [IO.Path]::GetDirectoryName(
                [IO.Path]::GetFullPath($CatalogPath)
            )
            if ([string]::IsNullOrWhiteSpace($catalogDirectory) -or
                -not (Test-Path -LiteralPath $catalogDirectory -PathType Container)) {
                throw 'OpenRouter 模型目录的父目录不存在。'
            }
            $temporaryHome = Join-Path $catalogDirectory (
                '.cxor-' + [Guid]::NewGuid().ToString('N')
            )
            [void](New-Item -ItemType Directory -Path $temporaryHome -ErrorAction Stop)

            $provider = New-CxProviderBlock -AuthCommand $AuthCommand `
                -ReadProcessEnvironment
            $temporaryConfig = @(
                'model = "~openai/gpt-latest"'
                'model_provider = "openrouter"'
                ''
                $provider
                ''
            ) -join "`r`n"
            Write-CxTextFileAtomic -Path (Join-Path $temporaryHome 'config.toml') `
                -Content $temporaryConfig

            $result = Invoke-CxProcess -FilePath $CliPath `
                -ArgumentList @('debug', 'models') -Environment @{
                    CODEX_HOME = $temporaryHome
                    OPENROUTER_API_KEY = $ApiKey
                }
            $standardOutput = [string]$result.StandardOutput
            $standardError = [string]$result.StandardError
            if ($standardOutput.Contains($ApiKey) -or $standardError.Contains($ApiKey)) {
                throw 'Codex CLI 输出包含 API Key。'
            }
            $cliDiagnostic = if ($result.ExitCode -eq 0) {
                $standardError
            }
            else {
                "Codex CLI 返回退出码 $($result.ExitCode)：$standardError"
            }

            $candidates.Add([pscustomobject]@{
                    Label = 'Codex CLI stdout'
                    Content = $standardOutput
                    Failure = if ($result.ExitCode -eq 0) {
                        ''
                    }
                    else { "Codex CLI 返回退出码 $($result.ExitCode)" }
                    IsPrevious = $false
                })

            $seenCachePaths = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            $cachePaths = [Collections.Generic.List[string]]::new()
            foreach ($cacheName in @('models_cache.openrouter.json', 'models_cache.json')) {
                $cachePath = [IO.Path]::GetFullPath((Join-Path $temporaryHome $cacheName))
                if ($seenCachePaths.Add($cachePath)) { $cachePaths.Add($cachePath) }
            }
            foreach ($cacheFile in @(Get-ChildItem -LiteralPath $temporaryHome -File `
                        -Filter 'models_cache*.json' -ErrorAction SilentlyContinue |
                    Sort-Object Name)) {
                $cachePath = [IO.Path]::GetFullPath($cacheFile.FullName)
                if ($seenCachePaths.Add($cachePath)) { $cachePaths.Add($cachePath) }
            }
            foreach ($cachePath in $cachePaths) {
                $candidates.Add([pscustomobject]@{
                        Label = "临时缓存 $([IO.Path]::GetFileName($cachePath))"
                        Content = Read-CxTextFile -Path $cachePath `
                            -MaximumBytes $script:MaximumCatalogBytes
                        IsPrevious = $false
                    })
            }
            $candidates.Add([pscustomobject]@{
                    Label = '上次有效 OpenRouter 目录'
                    Content = Read-CxTextFile -Path $CatalogPath `
                        -MaximumBytes $script:MaximumCatalogBytes
                    IsPrevious = $true
                })

            $resolvedCatalog = Resolve-CxCatalogCandidate -Candidates @($candidates) `
                -AllModels:$AllModels -ApiKey $ApiKey -StandardError $cliDiagnostic
        }
        $catalog = [string]$resolvedCatalog.Content
        $writtenModels = @($resolvedCatalog.Models)
        Write-CxTextFileAtomic -Path $CatalogPath -Content ($catalog + "`r`n")
        return [pscustomobject]@{
            Path = [IO.Path]::GetFullPath($CatalogPath)
            ModelCount = $writtenModels.Count
            VisibleModelCount = @($writtenModels | Where-Object {
                $_.PSObject.Properties['visibility'] -and $_.visibility -ceq 'list'
            }).Count
            DefaultModel = '~openai/gpt-latest'
            CatalogSource = [string]$resolvedCatalog.Source
            UsedPreviousCatalog = [bool]$resolvedCatalog.UsedPreviousCatalog
        }
    }
    catch {
        throw "OpenRouter 模型目录同步失败：$(Protect-CxText $_.Exception.Message $ApiKey)"
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryHome)) {
            $resolvedTemp = [IO.Path]::GetFullPath($temporaryHome)
            $catalogRoot = [IO.Path]::GetFullPath(
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CatalogPath))
            ).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if ($resolvedTemp.StartsWith(
                    $catalogRoot,
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                [IO.Path]::GetFileName($resolvedTemp) -match '^\.cxor-[0-9a-f]{32}$' -and
                (Test-Path -LiteralPath $resolvedTemp -PathType Container)) {
                Remove-Item -LiteralPath $resolvedTemp -Recurse -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}

function Resolve-CxDesktopApp {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
        Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending)
    foreach ($package in $packages) {
        try {
            $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
            $applications = @($manifest.Package.Applications.Application | Where-Object {
                [string]$_.Id -match '^[A-Za-z0-9._-]+$' -and
                [IO.Path]::GetFileName([string]$_.Executable) -ceq 'ChatGPT.exe'
            })
            if ($applications.Count -ne 1) { continue }
            $family = [string]$package.PackageFamilyName
            if ($family -notmatch '^OpenAI\.Codex_[A-Za-z0-9]+$') { continue }
            $roots = @($packages | Where-Object {
                    [string]$_.PackageFamilyName -ceq $family
                } | ForEach-Object {
                    [IO.Path]::GetFullPath([string]$_.InstallLocation).TrimEnd('\') + '\'
                } | Sort-Object -Unique)
            return [pscustomobject]@{
                AppUserModelId = "$family!$([string]$applications[0].Id)"
                InstallRoots = $roots
            }
        }
        catch { continue }
    }
    throw '找不到 Codex Desktop 启动入口。'
}

function Get-CxDesktopProcesses {
    param([Parameter(Mandatory)][object]$App)
    $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    $matched = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $sessionId) { continue }
            $path = [IO.Path]::GetFullPath([string]$process.Path)
            $insidePackage = @($App.InstallRoots | Where-Object {
                    $path.StartsWith([string]$_, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
            if ([IO.Path]::GetFileName($path) -ceq 'ChatGPT.exe' -and $insidePackage) {
                $matched.Add($process)
            }
        }
        catch { throw '无法验证当前 Codex Desktop 进程，已取消切换。' }
    }
    return @($matched)
}

function Stop-CxDesktopApp {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes)
    foreach ($process in $Processes) {
        if (-not $process.HasExited) { [void]$process.CloseMainWindow() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    foreach ($process in $Processes) {
        if ($process.HasExited) { continue }
        $remaining = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remaining -gt 0) { [void]$process.WaitForExit($remaining) }
        if (-not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { throw 'Codex Desktop 未能停止。' }
        }
    }
}

function Start-CxDesktopApp {
    param([Parameter(Mandatory)][object]$App)
    if ([string]$App.AppUserModelId -notmatch '^OpenAI\.Codex_[A-Za-z0-9]+![A-Za-z0-9._-]+$') {
        throw 'Codex Desktop AUMID 无效。'
    }
    $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $explorer = Join-Path $windows 'explorer.exe'
    if (-not (Test-Path -LiteralPath $explorer -PathType Leaf)) { throw '找不到 Windows Explorer。' }
    $process = Start-Process -FilePath $explorer -ArgumentList "shell:AppsFolder\$($App.AppUserModelId)" -PassThru
    if ($null -eq $process) { throw 'Codex Desktop 未能启动。' }
}

function Enter-CxMutex {
    param([Parameter(Mandatory)][string]$ScopePath)
    $bytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ScopePath).ToUpperInvariant())
    $name = 'Local\CodexOpenRouter-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $mutex = [Threading.Mutex]::new($false, $name)
    try {
        try { $acquired = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '等待另一个 cx/cxor 操作超时。' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-CxMutex {
    param([AllowNull()][Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Invoke-CxMode {
    param(
        [Parameter(Mandatory)][ValidateSet('Default', 'OpenRouter')][string]$Mode,
        [switch]$SetKey,
        [switch]$AllModels
    )

    Assert-CxRuntime
    $paths = Get-CxPaths
    $mutex = Enter-CxMutex $paths.ConfigPath
    try {
        if (-not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
            throw 'CodexOpenRouter 已被卸载或替换；请重新打开 PowerShell。'
        }
        $app = Resolve-CxDesktopApp
        $catalogResult = $null
        if ($Mode -eq 'OpenRouter') {
            $key = if ($SetKey) { Set-CxUserApiKey } else { Get-CxUserApiKey -Prompt }
            $authCommand = Get-CxAuthPowerShell
            $cli = Get-CxCodexCliPath
            $catalogResult = Sync-CxOpenRouterCatalog -CliPath $cli -ApiKey $key `
                -CatalogPath $paths.CatalogPath -AuthCommand $authCommand `
                -AllModels:$AllModels
            if ($catalogResult.UsedPreviousCatalog) {
                Write-Warning 'OpenRouter 与 Codex CLI 未返回可用的新目录，已使用上次有效 OpenRouter 目录。'
            }
            $change = Get-CxConfigChange -Path $paths.ConfigPath -Mode OpenRouter `
                -CatalogPath $paths.CatalogPath -AuthCommand $authCommand `
                -Model $catalogResult.DefaultModel
        }
        else {
            $change = Get-CxConfigChange -Path $paths.ConfigPath -Mode Default
        }

        $processes = @(Get-CxDesktopProcesses $app)
        try { Stop-CxDesktopApp $processes }
        catch {
            try { Start-CxDesktopApp $app } catch { }
            throw
        }
        $committed = $false
        try {
            Commit-CxConfigChange $change
            $committed = $true
            Start-CxDesktopApp $app
        }
        catch {
            if (-not $committed) {
                try { Start-CxDesktopApp $app } catch { }
                throw
            }
            throw "配置已更新，但 Codex Desktop 未能自动启动；请手动启动。$($_.Exception.Message)"
        }

        if ($Mode -eq 'OpenRouter') {
            Write-Host (
                "cxor：已同步 $($catalogResult.ModelCount) 个模型，" +
                "选择器显示 $($catalogResult.VisibleModelCount) 个模型，并请求打开 OpenRouter Codex。"
            )
        }
        else { Write-Host 'cx：已请求打开默认 Codex。' }
    }
    finally { Exit-CxMutex $mutex }
}

function cx {
    [CmdletBinding()]
    param()
    Invoke-CxMode -Mode Default
}

function cxor {
    [CmdletBinding()]
    param(
        [switch]$SetKey,
        [switch]$AllModels
    )
    Invoke-CxMode -Mode OpenRouter -SetKey:$SetKey -AllModels:$AllModels
}

Export-ModuleMember -Function @('cx', 'cxor')

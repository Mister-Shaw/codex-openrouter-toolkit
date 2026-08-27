[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Process', 'User')]
    [string]$Scope = 'User',

    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$commonHelperPath = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.Common.ps1'
if (-not (Test-Path -LiteralPath $commonHelperPath -PathType Leaf)) {
    throw "找不到共同安全 helper：$commonHelperPath"
}
. $commonHelperPath

function Remove-KeyEnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [EnvironmentVariableTarget]$Target
    )

    $method = [Environment].GetMethod(
        'SetEnvironmentVariable',
        [type[]]@([string], [string], [EnvironmentVariableTarget])
    )
    $arguments = [object[]]::new(3)
    $arguments[0] = $Name
    $arguments[1] = $null
    $arguments[2] = $Target
    try {
        [void]$method.Invoke($null, $arguments)
    }
    catch {
        $message = if ($_.Exception.InnerException) {
            $_.Exception.InnerException.Message
        }
        else {
            $_.Exception.Message
        }
        throw "无法删除环境变量 $Name（$Target）：$message"
    }
}

$apiKeyName = 'OPENROUTER_API_KEY'
$processOverrideMarker = 'CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE'
$processTarget = [EnvironmentVariableTarget]::Process
$target = if ($Scope -ceq 'Process') {
    $processTarget
}
else {
    [EnvironmentVariableTarget]::User
}

if ($Remove) {
    if (-not $PSCmdlet.ShouldProcess("$apiKeyName ($Scope)", '删除环境变量')) {
        return
    }

    Remove-KeyEnvironmentVariable -Name $apiKeyName -Target $target
    if ($Scope -ceq 'Process') {
        Remove-KeyEnvironmentVariable `
            -Name $processOverrideMarker `
            -Target $processTarget
    }
    else {
        $hasExplicitProcessOverride =
            [Environment]::GetEnvironmentVariable(
                $processOverrideMarker,
                $processTarget
            ) -ceq '1'
        if (-not $hasExplicitProcessOverride) {
            Remove-KeyEnvironmentVariable `
                -Name $apiKeyName `
                -Target $processTarget
            Remove-KeyEnvironmentVariable `
                -Name $processOverrideMarker `
                -Target $processTarget
        }
    }

    Write-Host "$apiKeyName 已从 $Scope 范围移除；密钥内容未输出。"
    return
}

if (-not $PSCmdlet.ShouldProcess("$apiKeyName ($Scope)", '保存环境变量')) {
    return
}

$secureKey = $null
$plainKey = $null
$pointer = [IntPtr]::Zero
try {
    $secureKey = Read-Host `
        '请输入 OpenRouter API Key（输入内容不会显示）' `
        -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)

    if (-not (Test-ToolkitApiKeyFormat -Value $plainKey)) {
        throw 'Key 格式未通过校验。请确认它以 sk-or- 开头，仅含字母、数字、点、下划线或连字符，且没有空格或控制字符。'
    }

    [Environment]::SetEnvironmentVariable($apiKeyName, $plainKey, $target)
    if ($Scope -ceq 'User') {
        [Environment]::SetEnvironmentVariable(
            $apiKeyName,
            $plainKey,
            $processTarget
        )
        Remove-KeyEnvironmentVariable `
            -Name $processOverrideMarker `
            -Target $processTarget
    }
    else {
        [Environment]::SetEnvironmentVariable(
            $processOverrideMarker,
            '1',
            $processTarget
        )
    }

    Write-Host "$apiKeyName 已保存到 $Scope 范围；密钥内容未输出。"
}
finally {
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    if ($null -ne $secureKey -and $secureKey -is [IDisposable]) {
        $secureKey.Dispose()
    }
    $plainKey = $null
}

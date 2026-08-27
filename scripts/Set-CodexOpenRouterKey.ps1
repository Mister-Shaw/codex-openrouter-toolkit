[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Process', 'User')]
    [string]$Scope = 'User',

    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = if ($Scope -ceq 'Process') {
    [EnvironmentVariableTarget]::Process
}
else {
    [EnvironmentVariableTarget]::User
}

if ($Remove) {
    if ($PSCmdlet.ShouldProcess("OPENROUTER_API_KEY ($Scope)", '删除环境变量')) {
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $null, $target)
        if ($Scope -ceq 'User') {
            [Environment]::SetEnvironmentVariable(
                'OPENROUTER_API_KEY',
                $null,
                [EnvironmentVariableTarget]::Process
            )
        }
        Write-Host "OPENROUTER_API_KEY 已从 $Scope 范围移除。"
    }
    return
}

$secureKey = Read-Host '请输入 OpenRouter API Key（输入内容不会显示）' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try {
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ($plainKey -cnotmatch '^sk-or-v1-[A-Za-z0-9_-]{16,}$') {
        throw 'Key 格式未通过校验。请确认它以 sk-or-v1- 开头，且没有空格或控制字符。'
    }

    if ($PSCmdlet.ShouldProcess("OPENROUTER_API_KEY ($Scope)", '保存环境变量')) {
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $plainKey, $target)
        if ($Scope -ceq 'User') {
            [Environment]::SetEnvironmentVariable(
                'OPENROUTER_API_KEY',
                $plainKey,
                [EnvironmentVariableTarget]::Process
            )
        }
        Write-Host "OPENROUTER_API_KEY 已保存到 $Scope 范围；密钥内容未输出。"
    }
}
finally {
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $plainKey = $null
}

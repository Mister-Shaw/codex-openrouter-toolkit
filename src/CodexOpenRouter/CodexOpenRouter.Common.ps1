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

function Write-ToolkitBytesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [switch]$PreserveLastWriteTime
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop)
    }

    $targetExisted = Test-Path -LiteralPath $resolvedPath -PathType Leaf
    $lastWriteTime = if ($targetExisted) {
        (Get-Item -LiteralPath $resolvedPath -ErrorAction Stop).LastWriteTimeUtc
    }
    else {
        $null
    }
    $targetAcl = if ($targetExisted -and $IsWindows) {
        try { Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop }
        catch { $null }
    }
    else {
        $null
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
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        $stagedBytes = [IO.File]::ReadAllBytes($temporaryPath)
        if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $Bytes,
                $stagedBytes
            )) {
            throw "暂存文件复读校验失败：$resolvedPath"
        }

        if ($targetExisted) {
            [IO.File]::Replace($temporaryPath, $resolvedPath, $rollbackPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $resolvedPath)
        }
        $committed = $true

        $writtenBytes = [IO.File]::ReadAllBytes($resolvedPath)
        if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $Bytes,
                $writtenBytes
            )) {
            throw "正式文件复读校验失败：$resolvedPath"
        }
        if ($targetAcl) {
            $writtenAcl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
            if ($writtenAcl.Sddl -cne $targetAcl.Sddl) {
                Set-Acl `
                    -LiteralPath $resolvedPath `
                    -AclObject $targetAcl `
                    -ErrorAction Stop
            }
        }
        if ($PreserveLastWriteTime -and $null -ne $lastWriteTime) {
            [IO.File]::SetLastWriteTimeUtc($resolvedPath, $lastWriteTime)
        }
    }
    catch {
        $primaryError = $_
        if ($committed) {
            try {
                if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) {
                    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
                        [IO.File]::Replace(
                            $rollbackPath,
                            $resolvedPath,
                            $discardPath,
                            $true
                        )
                    }
                    else {
                        [IO.File]::Move($rollbackPath, $resolvedPath)
                    }
                }
                elseif (-not $targetExisted -and
                    (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
                }
            }
            catch {
                $retainRollback = $targetExisted
                $recoveryMessage = if ($retainRollback -and
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
        $cleanupPaths = @($temporaryPath, $discardPath)
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

        [switch]$PreserveLastWriteTime
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    Write-ToolkitBytesAtomic `
        -Path $Path `
        -Bytes $bytes `
        -PreserveLastWriteTime:$PreserveLastWriteTime
}

function Copy-ToolkitFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $resolvedSource = [IO.Path]::GetFullPath($Source)
    $resolvedDestination = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
        throw "找不到待复制的普通文件：$resolvedSource"
    }
    $destinationExisted = Test-Path -LiteralPath $resolvedDestination -PathType Leaf
    $sourceAcl = if ($IsWindows -and -not $destinationExisted) {
        Get-Acl -LiteralPath $resolvedSource -ErrorAction Stop
    }
    else {
        $null
    }
    Write-ToolkitBytesAtomic `
        -Path $resolvedDestination `
        -Bytes ([IO.File]::ReadAllBytes($resolvedSource))
    if ($sourceAcl) {
        try {
            Set-Acl `
                -LiteralPath $resolvedDestination `
                -AclObject $sourceAcl `
                -ErrorAction Stop
            $copiedAcl = Get-Acl `
                -LiteralPath $resolvedDestination `
                -ErrorAction Stop
            if ($copiedAcl.Sddl -cne $sourceAcl.Sddl) {
                throw 'ACL 复读校验不一致。'
            }
        }
        catch {
            $aclError = $_.Exception.Message
            try {
                Remove-Item `
                    -LiteralPath $resolvedDestination `
                    -Force `
                    -ErrorAction Stop
            }
            catch {
                throw "复制文件的 ACL 无法保留，失败副本也无法删除：" +
                    "$resolvedDestination。该文件可能仍含来源内容；" +
                    "ACL 错误：$aclError；清理错误：$($_.Exception.Message)"
            }
            throw "复制文件的 ACL 无法保留，失败副本已删除：" +
                "$resolvedDestination。$aclError"
        }
    }
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

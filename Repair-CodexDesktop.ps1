#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE 'Apps\CodexDesktop'),
    [string]$BackupRoot = (Join-Path $env:USERPROFILE 'CodexDesktopAutofixBackup'),
    [switch]$NoLaunch,
    [switch]$RestartExisting,
    [switch]$GpuSafe,
    [switch]$NoShortcuts,
    [switch]$NoAdminShortcuts,
    [switch]$NoAdminLaunchers,
    [switch]$KeepCodexPermissions,
    [switch]$NoStateSync,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Convert-ToTomlLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Remove-TomlSection {
    param(
        [string[]]$Lines,
        [string]$Section
    )

    $sectionPattern = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $sectionPattern) {
            $start = $i
            break
        }
    }
    if ($start -lt 0) {
        return $Lines
    }

    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[[^\]]+\]\s*$') {
            $end = $i
            break
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -lt $start -or $i -ge $end) {
            [void]$result.Add($Lines[$i])
        }
    }
    return $result.ToArray()
}

function Set-TomlTopLevelKey {
    param(
        [string[]]$Lines,
        [string]$Key,
        [string]$Value
    )

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $firstSection = $Lines.Count
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[[^\]]+\]\s*$') {
            $firstSection = $i
            break
        }
    }

    for ($i = 0; $i -lt $firstSection; $i++) {
        if ($Lines[$i] -match $keyPattern) {
            $Lines[$i] = "$Key = $Value"
            return $Lines
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    [void]$result.Add("$Key = $Value")
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        [void]$result.Add($Lines[$i])
    }
    return $result.ToArray()
}

function Set-TomlSectionKey {
    param(
        [string[]]$Lines,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $sectionPattern = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $sectionPattern) {
            $start = $i
            break
        }
    }

    if ($start -lt 0) {
        $result = New-Object System.Collections.Generic.List[string]
        foreach ($line in $Lines) {
            [void]$result.Add($line)
        }
        if ($result.Count -gt 0 -and $result[$result.Count - 1].Trim() -ne '') {
            [void]$result.Add('')
        }
        [void]$result.Add("[$Section]")
        [void]$result.Add("$Key = $Value")
        return $result.ToArray()
    }

    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[[^\]]+\]\s*$') {
            $end = $i
            break
        }
    }

    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($Lines[$i] -match $keyPattern) {
            $Lines[$i] = "$Key = $Value"
            return $Lines
        }
    }

    $list = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -eq $end) {
            [void]$list.Add("$Key = $Value")
        }
        [void]$list.Add($Lines[$i])
    }
    if ($end -eq $Lines.Count) {
        [void]$list.Add("$Key = $Value")
    }
    return $list.ToArray()
}

function Remove-TomlSectionKey {
    param(
        [string[]]$Lines,
        [string]$Section,
        [string]$Key
    )

    $sectionPattern = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $sectionPattern) {
            $start = $i
            break
        }
    }
    if ($start -lt 0) {
        return $Lines
    }

    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[[^\]]+\]\s*$') {
            $end = $i
            break
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -gt $start -and $i -lt $end -and $Lines[$i] -match $keyPattern) {
            continue
        }
        [void]$result.Add($Lines[$i])
    }
    return $result.ToArray()
}

function Set-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Invoke-SelfTest {
    Write-Step 'Running TOML helper self-test'
    $sample = @(
        'model = "gpt-5.5"',
        '[marketplaces.openai-bundled]',
        'source_type = "local"',
        'source = "old"',
        '',
        '[marketplaces.openai-primary-runtime]',
        'source = "keep"',
        '',
        '[desktop]',
        'runCodexInWindowsSubsystemForLinux = true',
        'integratedTerminalShell = "wsl"',
        '',
        '[mcp_servers.node_repl.env]',
        "CODEX_HOME = 'old'",
        "SKY_CUA_NATIVE_PIPE_DIRECTORY = '\\.\pipe\old'"
    )

    $lines = Remove-TomlSection -Lines $sample -Section 'marketplaces.openai-bundled'
    $lines = Set-TomlTopLevelKey -Lines $lines -Key 'approval_policy' -Value '"never"'
    $lines = Set-TomlTopLevelKey -Lines $lines -Key 'sandbox_mode' -Value '"danger-full-access"'
    $lines = Set-TomlTopLevelKey -Lines $lines -Key 'default_permissions' -Value '":danger-full-access"'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'desktop' -Key 'runCodexInWindowsSubsystemForLinux' -Value 'false'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'desktop' -Key 'integratedTerminalShell' -Value '"powershell"'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'windows' -Key 'sandbox' -Value '"unelevated"'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'CODEX_HOME' -Value (Convert-ToTomlLiteral 'C:\Users\test\Apps\CodexDesktop\data\CodexHome')
    $lines = Remove-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'SKY_CUA_NATIVE_PIPE_DIRECTORY'
    $text = $lines -join "`n"

    $checks = @(
        @{ Name = 'bundled section removed'; Pass = ($text -notmatch '\[marketplaces\.openai-bundled\]') },
        @{ Name = 'primary runtime preserved'; Pass = ($text -match '\[marketplaces\.openai-primary-runtime\]') },
        @{ Name = 'approval bypass set'; Pass = ($text -match 'approval_policy = "never"') },
        @{ Name = 'danger full access set'; Pass = ($text -match 'sandbox_mode = "danger-full-access"') },
        @{ Name = 'default permission profile set'; Pass = ($text -match 'default_permissions = ":danger-full-access"') },
        @{ Name = 'wsl disabled'; Pass = ($text -match 'runCodexInWindowsSubsystemForLinux = false') },
        @{ Name = 'powershell terminal set'; Pass = ($text -match 'integratedTerminalShell = "powershell"') },
        @{ Name = 'windows sandbox updater avoided'; Pass = ($text -match '\[windows\]' -and $text -match 'sandbox = "unelevated"') },
        @{ Name = 'stale pipe removed'; Pass = ($text -notmatch 'SKY_CUA_NATIVE_PIPE_DIRECTORY') }
    )

    foreach ($check in $checks) {
        if (-not $check.Pass) {
            throw "Self-test failed: $($check.Name)"
        }
    }
    Write-Ok 'Self-test passed'
}

function New-Directory {
    param([string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'create directory')) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Set-Utf8NoBomContent {
    param(
        [string]$Path,
        [AllowNull()][object]$Value
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($null -eq $Value) {
        [System.IO.File]::WriteAllText($Path, '', $utf8NoBom)
        return
    }

    if ($Value -is [string]) {
        [System.IO.File]::WriteAllLines($Path, [string[]]@($Value), $utf8NoBom)
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        [void]$lines.Add([string]$item)
    }
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines.ToArray(), $utf8NoBom)
}

function Copy-IfExists {
    param(
        [string]$Source,
        [string]$Destination
    )
    if (Test-Path -LiteralPath $Source) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function Export-RegKeyIfExists {
    param(
        [string]$Key,
        [string]$Destination
    )
    $null = & reg.exe query $Key 2>$null
    if ($LASTEXITCODE -eq 0) {
        $null = & reg.exe export $Key $Destination /y
    }
}

function Get-LatestCodexPackage {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
    if (-not $packages -or $packages.Count -eq 0) {
        throw 'OpenAI.Codex MSIX package was not found for the current user. Install Codex Desktop first.'
    }

    $package = $packages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $package.InstallLocation) {
        throw 'OpenAI.Codex package has no InstallLocation.'
    }

    $sourceApp = Join-Path $package.InstallLocation 'app'
    $sourceExe = Join-Path $sourceApp 'Codex.exe'
    $sourceAsar = Join-Path $sourceApp 'resources\app.asar'
    if (-not (Test-Path -LiteralPath $sourceExe) -or -not (Test-Path -LiteralPath $sourceAsar)) {
        throw "OpenAI.Codex package payload is incomplete: $sourceApp"
    }

    [pscustomobject]@{
        Package = $package
        SourceApp = $sourceApp
        Version = [string]$package.Version
    }
}

function Invoke-RobocopyMirror {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Directory -Path $Destination
    Write-Step "Copying app payload to $Destination"
    if ($PSCmdlet.ShouldProcess($Destination, "robocopy mirror from $Source")) {
        & robocopy.exe $Source $Destination /MIR /R:2 /W:1 /NFL /NDL /NP /NJH /NJS
        $code = $LASTEXITCODE
        if ($code -gt 7) {
            throw "robocopy failed with exit code $code"
        }
    }
}

function New-Backup {
    param(
        [string]$Root,
        [string]$OldCodexHome,
        [string]$NewCodexHome
    )

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backup = Join-Path $Root $stamp
    New-Directory -Path $backup

    if ($PSCmdlet.ShouldProcess($backup, 'write local backup files')) {
        Export-RegKeyIfExists -Key 'HKCU\Environment' -Destination (Join-Path $backup 'HKCU-Environment.reg')
        Export-RegKeyIfExists -Key 'HKCU\Software\Classes\codex' -Destination (Join-Path $backup 'HKCU-Classes-codex.reg')
        Export-RegKeyIfExists -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\OpenAI.Codex_2p2nqsd0c76g0' -Destination (Join-Path $backup 'HKCU-BackgroundAccess-OpenAI.Codex.reg')

        foreach ($file in @('config.toml', 'chrome-native-hosts-v2.json', '.codex-global-state.json', '.codex-global-state.json.bak')) {
            Copy-IfExists -Source (Join-Path $OldCodexHome $file) -Destination (Join-Path $backup "old-$file")
            Copy-IfExists -Source (Join-Path $NewCodexHome $file) -Destination (Join-Path $backup "isolated-$file")
        }

        $envSnapshot = [pscustomobject]@{
            CreatedAt = (Get-Date).ToString('o')
            User = $env:USERNAME
            InstallRoot = $InstallRoot
            CODEX_HOME = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
            CODEX_CLI_PATH = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
            CODEX_SQLITE_HOME = [Environment]::GetEnvironmentVariable('CODEX_SQLITE_HOME', 'User')
            UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        }
        Set-Utf8NoBomContent -Path (Join-Path $backup 'user-env-snapshot.json') -Value ($envSnapshot | ConvertTo-Json -Depth 4)
    }

    return $backup
}

function Get-RelativePathCompat {
    param(
        [string]$BasePath,
        [string]$Path
    )

    try {
        $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
        $pathFull = [System.IO.Path]::GetFullPath($Path)
        $baseUri = New-Object System.Uri($baseFull)
        $pathUri = New-Object System.Uri($pathFull)
        return ([System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()) -replace '/', '\')
    } catch {
        return (($Path -replace '^[A-Za-z]:\\?', '') -replace '[:*?"<>|]', '_')
    }
}

function Test-SameFileContent {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not (Test-Path -LiteralPath $Left) -or -not (Test-Path -LiteralPath $Right)) {
        return $false
    }

    try {
        $leftInfo = Get-Item -LiteralPath $Left
        $rightInfo = Get-Item -LiteralPath $Right
        if ($leftInfo.Length -ne $rightInfo.Length) {
            return $false
        }
        return ((Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash)
    } catch {
        return $false
    }
}

function Copy-ConflictSnapshot {
    param(
        [string]$Source,
        [string]$SourceRoot,
        [string]$ConflictRoot,
        [string]$Tag
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return
    }

    $relative = Get-RelativePathCompat -BasePath $SourceRoot -Path $Source
    $destination = Join-Path (Join-Path $ConflictRoot $Tag) $relative
    $destinationDir = Split-Path -Parent $destination
    New-Directory -Path $destinationDir

    if ($PSCmdlet.ShouldProcess($destination, "write conflict copy from $Source")) {
        Copy-Item -LiteralPath $Source -Destination $destination -Force
    }
}

function Copy-StateFileWithConflict {
    param(
        [string]$Source,
        [string]$SourceRoot,
        [string]$Destination,
        [string]$DestinationRoot,
        [string]$ConflictRoot,
        [string]$SourceTag
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return
    }

    $destinationDir = Split-Path -Parent $Destination
    New-Directory -Path $destinationDir

    if (-not (Test-Path -LiteralPath $Destination)) {
        if ($PSCmdlet.ShouldProcess($Destination, "copy state file from $Source")) {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
        }
        return
    }

    if (Test-SameFileContent -Left $Source -Right $Destination) {
        return
    }

    $sourceInfo = Get-Item -LiteralPath $Source
    $destinationInfo = Get-Item -LiteralPath $Destination
    if ($sourceInfo.LastWriteTimeUtc -gt $destinationInfo.LastWriteTimeUtc) {
        Copy-ConflictSnapshot -Source $Destination -SourceRoot $DestinationRoot -ConflictRoot $ConflictRoot -Tag 'isolated-overwritten'
        if ($PSCmdlet.ShouldProcess($Destination, "replace older state file with $Source")) {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
        }
    } else {
        Copy-ConflictSnapshot -Source $Source -SourceRoot $SourceRoot -ConflictRoot $ConflictRoot -Tag $SourceTag
    }
}

function Merge-JsonlStateFile {
    param(
        [string]$Source,
        [string]$SourceRoot,
        [string]$Destination,
        [string]$DestinationRoot,
        [string]$ConflictRoot,
        [string]$SourceTag
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return
    }

    $destinationDir = Split-Path -Parent $Destination
    New-Directory -Path $destinationDir

    if (-not (Test-Path -LiteralPath $Destination)) {
        if ($PSCmdlet.ShouldProcess($Destination, "copy JSONL history from $Source")) {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
        }
        return
    }

    try {
        $destinationLines = @(Get-Content -LiteralPath $Destination -ErrorAction Stop)
        $sourceLines = @(Get-Content -LiteralPath $Source -ErrorAction Stop)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($line in $destinationLines) {
            if ($null -ne $line -and $line.Trim() -ne '') {
                [void]$seen.Add($line)
            }
        }

        $merged = New-Object System.Collections.Generic.List[string]
        foreach ($line in $destinationLines) {
            [void]$merged.Add($line)
        }

        $added = 0
        foreach ($line in $sourceLines) {
            if ($null -eq $line -or $line.Trim() -eq '') {
                continue
            }
            if ($seen.Add($line)) {
                [void]$merged.Add($line)
                $added++
            }
        }

        if ($added -gt 0) {
            Copy-ConflictSnapshot -Source $Destination -SourceRoot $DestinationRoot -ConflictRoot $ConflictRoot -Tag 'isolated-before-jsonl-merge'
            if ($PSCmdlet.ShouldProcess($Destination, "merge $added JSONL history lines from $Source")) {
                Set-Utf8NoBomContent -Path $Destination -Value $merged.ToArray()
            }
        }
    } catch {
        Write-WarnLine "Could not merge JSONL state ${Source}: $($_.Exception.Message)"
        Copy-StateFileWithConflict -Source $Source -SourceRoot $SourceRoot -Destination $Destination -DestinationRoot $DestinationRoot -ConflictRoot $ConflictRoot -SourceTag $SourceTag
    }
}

function Sync-StateDirectory {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$RelativeDirectory,
        [string]$ConflictRoot,
        [string]$SourceTag
    )

    $sourceDirectory = Join-Path $SourceRoot $RelativeDirectory
    if (-not (Test-Path -LiteralPath $sourceDirectory)) {
        return
    }

    $files = @(Get-ChildItem -LiteralPath $sourceDirectory -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        $relative = Get-RelativePathCompat -BasePath $SourceRoot -Path $file.FullName
        $destination = Join-Path $DestinationRoot $relative
        if ($file.Extension -ieq '.jsonl') {
            Merge-JsonlStateFile -Source $file.FullName -SourceRoot $SourceRoot -Destination $destination -DestinationRoot $DestinationRoot -ConflictRoot $ConflictRoot -SourceTag $SourceTag
        } else {
            Copy-StateFileWithConflict -Source $file.FullName -SourceRoot $SourceRoot -Destination $destination -DestinationRoot $DestinationRoot -ConflictRoot $ConflictRoot -SourceTag $SourceTag
        }
    }
}

function Get-SqliteSetInfo {
    param(
        [string]$Root,
        [string]$DatabaseName,
        [string]$Tag
    )

    $main = Join-Path $Root $DatabaseName
    if (-not (Test-Path -LiteralPath $main)) {
        return $null
    }

    $paths = @($main, "$main-wal", "$main-shm") | Where-Object { Test-Path -LiteralPath $_ }
    $items = @($paths | ForEach-Object { Get-Item -LiteralPath $_ })
    $mainItem = Get-Item -LiteralPath $main
    $latest = ($items | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
    $totalBytes = ($items | Measure-Object -Property Length -Sum).Sum

    [pscustomobject]@{
        Root = $Root
        DatabaseName = $DatabaseName
        Tag = $Tag
        Paths = $paths
        MainLatest = $mainItem.LastWriteTimeUtc
        Latest = $latest
        TotalBytes = [int64]$totalBytes
    }
}

function Get-SqliteSetSignature {
    param(
        [string]$Root,
        [string]$DatabaseName
    )

    $main = Join-Path $Root $DatabaseName
    $paths = @($main, "$main-wal", "$main-shm")
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$parts.Add("$([System.IO.Path]::GetFileName($path)):missing")
            continue
        }
        try {
            $item = Get-Item -LiteralPath $path
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            [void]$parts.Add("$([System.IO.Path]::GetFileName($path)):$($item.Length):$hash")
        } catch {
            [void]$parts.Add("$([System.IO.Path]::GetFileName($path)):unreadable")
        }
    }
    return ($parts -join '|')
}

function Copy-SqliteSetToConflict {
    param(
        [string]$Root,
        [string]$DatabaseName,
        [string]$ConflictRoot,
        [string]$Tag
    )

    $main = Join-Path $Root $DatabaseName
    foreach ($path in @($main, "$main-wal", "$main-shm")) {
        if (Test-Path -LiteralPath $path) {
            Copy-ConflictSnapshot -Source $path -SourceRoot $Root -ConflictRoot $ConflictRoot -Tag $Tag
        }
    }
}

function Copy-SqliteSet {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$DatabaseName
    )

    $sourceMain = Join-Path $SourceRoot $DatabaseName
    $destinationMain = Join-Path $DestinationRoot $DatabaseName
    New-Directory -Path $DestinationRoot

    foreach ($source in @($sourceMain, "$sourceMain-wal", "$sourceMain-shm")) {
        $destination = Join-Path $DestinationRoot ([System.IO.Path]::GetFileName($source))
        if (Test-Path -LiteralPath $source) {
            if ($PSCmdlet.ShouldProcess($destination, "copy SQLite state file from $source")) {
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
        } elseif (Test-Path -LiteralPath $destination) {
            if ($PSCmdlet.ShouldProcess($destination, 'remove stale SQLite sidecar')) {
                Remove-Item -LiteralPath $destination -Force
            }
        }
    }
}

function Ensure-WinSqliteType {
    if ('CodexDesktopAutofix.WinSqlite3' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexDesktopAutofix {
    public static class WinSqlite3 {
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr zVfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr pzTail);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_step(IntPtr stmt);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_count(IntPtr stmt);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_column_name(IntPtr stmt, int iCol);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_type(IntPtr stmt, int iCol);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_column_text(IntPtr stmt, int iCol);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern long sqlite3_column_int64(IntPtr stmt, int iCol);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern double sqlite3_column_double(IntPtr stmt, int iCol);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_finalize(IntPtr stmt);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_close(IntPtr db);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_errmsg(IntPtr db);

        public static string PtrToStringUtf8(IntPtr ptr) {
            if (ptr == IntPtr.Zero) {
                return null;
            }
            int len = 0;
            while (Marshal.ReadByte(ptr, len) != 0) {
                len++;
            }
            if (len == 0) {
                return String.Empty;
            }
            byte[] buffer = new byte[len];
            Marshal.Copy(ptr, buffer, 0, len);
            return Encoding.UTF8.GetString(buffer);
        }
    }
}
'@
}

function Invoke-WinSqliteQuery {
    param(
        [string]$DatabasePath,
        [string]$Sql
    )

    Ensure-WinSqliteType

    $sqlite = [CodexDesktopAutofix.WinSqlite3]
    $ok = 0
    $row = 100
    $done = 101
    $openReadOnly = 1
    $openUri = 64

    $db = [IntPtr]::Zero
    $stmt = [IntPtr]::Zero
    $databaseBytes = [System.Text.Encoding]::UTF8.GetBytes($DatabasePath + [char]0)
    $rc = $sqlite::sqlite3_open_v2($databaseBytes, [ref]$db, ($openReadOnly -bor $openUri), [IntPtr]::Zero)
    if ($rc -ne $ok) {
        $message = if ($db -ne [IntPtr]::Zero) { $sqlite::PtrToStringUtf8($sqlite::sqlite3_errmsg($db)) } else { "code $rc" }
        if ($db -ne [IntPtr]::Zero) {
            [void]$sqlite::sqlite3_close($db)
        }
        throw "sqlite open failed for ${DatabasePath}: $message"
    }

    try {
        $sqlBytes = [System.Text.Encoding]::UTF8.GetBytes($Sql + [char]0)
        $rc = $sqlite::sqlite3_prepare_v2($db, $sqlBytes, -1, [ref]$stmt, [IntPtr]::Zero)
        if ($rc -ne $ok) {
            $message = $sqlite::PtrToStringUtf8($sqlite::sqlite3_errmsg($db))
            throw "sqlite prepare failed for ${DatabasePath}: $message"
        }

        $columns = @()
        for ($i = 0; $i -lt $sqlite::sqlite3_column_count($stmt); $i++) {
            $columns += $sqlite::PtrToStringUtf8($sqlite::sqlite3_column_name($stmt, $i))
        }

        $items = New-Object System.Collections.Generic.List[object]
        while ($true) {
            $rc = $sqlite::sqlite3_step($stmt)
            if ($rc -eq $done) {
                break
            }
            if ($rc -ne $row) {
                $message = $sqlite::PtrToStringUtf8($sqlite::sqlite3_errmsg($db))
                throw "sqlite step failed for ${DatabasePath}: $message"
            }

            $object = [ordered]@{}
            for ($i = 0; $i -lt $columns.Count; $i++) {
                $type = $sqlite::sqlite3_column_type($stmt, $i)
                $value = $null
                switch ($type) {
                    1 { $value = $sqlite::sqlite3_column_int64($stmt, $i) }
                    2 { $value = $sqlite::sqlite3_column_double($stmt, $i) }
                    3 { $value = $sqlite::PtrToStringUtf8($sqlite::sqlite3_column_text($stmt, $i)) }
                    default { $value = $null }
                }
                $object[$columns[$i]] = $value
            }
            [void]$items.Add([pscustomobject]$object)
        }

        return $items.ToArray()
    } finally {
        if ($stmt -ne [IntPtr]::Zero) {
            [void]$sqlite::sqlite3_finalize($stmt)
        }
        if ($db -ne [IntPtr]::Zero) {
            [void]$sqlite::sqlite3_close($db)
        }
    }
}

function ConvertTo-SessionIndexName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'Untitled chat'
    }

    $clean = $Value.Trim() -replace '[\r\n\x85\u2028\u2029]+', ' '
    $clean = $clean -replace '\s{2,}', ' '
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return 'Untitled chat'
    }
    return $clean
}

function Get-ExistingSessionIndexNames {
    param([string]$IndexPath)

    $names = @{}
    if (-not (Test-Path -LiteralPath $IndexPath)) {
        return $names
    }

    foreach ($line in @(Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($null -eq $line) {
            continue
        }
        $cleanLine = $line.TrimStart([char]0xfeff)
        if ($cleanLine.Trim() -eq '') {
            continue
        }
        try {
            $item = $cleanLine | ConvertFrom-Json
            if ($item.id -and $item.thread_name) {
                $names[[string]$item.id] = [string]$item.thread_name
            }
        } catch {
            continue
        }
    }

    return $names
}

function Rebuild-SessionIndexFromSqlite {
    param(
        [string]$CodexHome,
        [string]$ConflictRoot
    )

    $database = Join-Path $CodexHome 'state_5.sqlite'
    $indexPath = Join-Path $CodexHome 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $database)) {
        return
    }

    try {
        $existingNames = Get-ExistingSessionIndexNames -IndexPath $indexPath
        $query = @'
select
  id,
  coalesce(nullif(title, ''), nullif(preview, ''), nullif(first_user_message, ''), 'Untitled chat') as thread_name,
  coalesce(
    strftime('%Y-%m-%dT%H:%M:%fZ',
      case
        when updated_at_ms is not null then updated_at_ms / 1000.0
        when updated_at is not null then updated_at
        when created_at_ms is not null then created_at_ms / 1000.0
        else created_at
      end,
      'unixepoch'
    ),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  ) as updated_at
from threads
where coalesce(archived, 0) = 0
order by coalesce(updated_at_ms, updated_at * 1000, created_at_ms, created_at * 1000) desc
'@
        $threads = @(Invoke-WinSqliteQuery -DatabasePath $database -Sql $query)
        if ($threads.Count -eq 0) {
            return
        }

        $lines = New-Object System.Collections.Generic.List[string]
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($thread in $threads) {
            $id = [string]$thread.id
            if ([string]::IsNullOrWhiteSpace($id) -or -not $seen.Add($id)) {
                continue
            }

            $name = if ($existingNames.ContainsKey($id)) { $existingNames[$id] } else { [string]$thread.thread_name }
            $item = [pscustomobject]@{
                id = $id
                thread_name = ConvertTo-SessionIndexName -Value $name
                updated_at = [string]$thread.updated_at
            }
            [void]$lines.Add(($item | ConvertTo-Json -Compress))
        }

        if ($lines.Count -eq 0) {
            return
        }

        if (Test-Path -LiteralPath $indexPath) {
            Copy-ConflictSnapshot -Source $indexPath -SourceRoot $CodexHome -ConflictRoot $ConflictRoot -Tag 'isolated-before-session-index-rebuild'
        }

        if ($PSCmdlet.ShouldProcess($indexPath, "rebuild session_index.jsonl from $database")) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllLines($indexPath, [string[]]$lines.ToArray(), $utf8NoBom)
            Write-Ok "Rebuilt session_index.jsonl from SQLite ($($lines.Count) chats)"
        }
    } catch {
        Write-WarnLine "Could not rebuild session_index.jsonl from SQLite: $($_.Exception.Message)"
    }
}

function Sync-SqliteStateDatabase {
    param(
        [object[]]$SourceRoots,
        [string]$DestinationRoot,
        [string]$DatabaseName,
        [string]$ConflictRoot
    )

    $candidateInfos = New-Object System.Collections.Generic.List[object]
    foreach ($source in $SourceRoots) {
        $info = Get-SqliteSetInfo -Root $source.Root -DatabaseName $DatabaseName -Tag $source.Tag
        if ($null -ne $info) {
            [void]$candidateInfos.Add($info)
        }
    }

    $destinationInfo = Get-SqliteSetInfo -Root $DestinationRoot -DatabaseName $DatabaseName -Tag 'isolated'
    if ($null -ne $destinationInfo) {
        [void]$candidateInfos.Add($destinationInfo)
    }

    if ($candidateInfos.Count -eq 0) {
        return
    }

    if ($DatabaseName -eq 'state_5.sqlite') {
        # WAL/SHM mtimes can be advanced by another Codex surface and are not a
        # reliable signal for the canonical chat index. Prefer the active main
        # database file so recent isolated Desktop chats are not hidden.
        $winner = $candidateInfos | Sort-Object MainLatest, TotalBytes -Descending | Select-Object -First 1
    } else {
        $winner = $candidateInfos | Sort-Object Latest, TotalBytes -Descending | Select-Object -First 1
    }
    $destinationSignature = Get-SqliteSetSignature -Root $DestinationRoot -DatabaseName $DatabaseName

    foreach ($candidate in $candidateInfos) {
        if ($candidate.Root -eq $winner.Root) {
            continue
        }
        $candidateSignature = Get-SqliteSetSignature -Root $candidate.Root -DatabaseName $DatabaseName
        if ($candidateSignature -ne $destinationSignature) {
            Copy-SqliteSetToConflict -Root $candidate.Root -DatabaseName $DatabaseName -ConflictRoot $ConflictRoot -Tag "$($candidate.Tag)-sqlite-conflict"
        }
    }

    if ($winner.Root -ne $DestinationRoot) {
        $winnerSignature = Get-SqliteSetSignature -Root $winner.Root -DatabaseName $DatabaseName
        if ($winnerSignature -ne $destinationSignature) {
            if ($null -ne $destinationInfo) {
                Copy-SqliteSetToConflict -Root $DestinationRoot -DatabaseName $DatabaseName -ConflictRoot $ConflictRoot -Tag 'isolated-sqlite-overwritten'
            }
            Copy-SqliteSet -SourceRoot $winner.Root -DestinationRoot $DestinationRoot -DatabaseName $DatabaseName
        }
    }
}

function Sync-CodexState {
    param(
        [string]$OldCodexHome,
        [string]$NewCodexHome,
        [string]$Backup
    )

    if ($NoStateSync) {
        Write-WarnLine 'Skipping history/SQLite sync because -NoStateSync was provided'
        return
    }

    $conflictRoot = Join-Path $Backup 'conflicts'
    Write-Step 'Syncing Codex history and SQLite state into isolated Codex home'

    $sourceRoots = @(
        [pscustomobject]@{ Root = $OldCodexHome; Tag = 'legacy-home' },
        [pscustomobject]@{ Root = (Join-Path $OldCodexHome 'sqlite'); Tag = 'legacy-sqlite-dir' }
    ) | Where-Object { Test-Path -LiteralPath $_.Root }

    foreach ($source in $sourceRoots) {
        foreach ($file in @('history.jsonl', 'session_index.jsonl')) {
            Merge-JsonlStateFile -Source (Join-Path $source.Root $file) -SourceRoot $source.Root -Destination (Join-Path $NewCodexHome $file) -DestinationRoot $NewCodexHome -ConflictRoot $conflictRoot -SourceTag $source.Tag
        }

        foreach ($file in @('external_agent_session_imports.json')) {
            Copy-StateFileWithConflict -Source (Join-Path $source.Root $file) -SourceRoot $source.Root -Destination (Join-Path $NewCodexHome $file) -DestinationRoot $NewCodexHome -ConflictRoot $conflictRoot -SourceTag $source.Tag
        }

        foreach ($directory in @('sessions', 'attachments', 'memories')) {
            Sync-StateDirectory -SourceRoot $source.Root -DestinationRoot $NewCodexHome -RelativeDirectory $directory -ConflictRoot $conflictRoot -SourceTag $source.Tag
        }
    }

    foreach ($database in @('state_5.sqlite', 'goals_1.sqlite', 'memories_1.sqlite', 'logs_2.sqlite')) {
        Sync-SqliteStateDatabase -SourceRoots $sourceRoots -DestinationRoot $NewCodexHome -DatabaseName $database -ConflictRoot $conflictRoot
    }

    Rebuild-SessionIndexFromSqlite -CodexHome $NewCodexHome -ConflictRoot $conflictRoot
    Write-Ok 'History/SQLite sync completed'
}

function Initialize-CodexHome {
    param(
        [string]$OldCodexHome,
        [string]$NewCodexHome
    )

    New-Directory -Path $NewCodexHome
    New-Directory -Path (Join-Path $NewCodexHome 'tmp')
    New-Directory -Path (Join-Path $NewCodexHome 'sqlite')

    foreach ($file in @('auth.json', 'config.toml', 'AGENTS.md', 'installation_id')) {
        $src = Join-Path $OldCodexHome $file
        $dst = Join-Path $NewCodexHome $file
        if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
            if ($PSCmdlet.ShouldProcess($dst, "copy $file from existing Codex home")) {
                Copy-Item -LiteralPath $src -Destination $dst -Force
            }
        }
    }

    $configPath = Join-Path $NewCodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath)) {
        if ($PSCmdlet.ShouldProcess($configPath, 'create minimal config.toml')) {
            Set-Utf8NoBomContent -Path $configPath -Value @(
                'approvals_reviewer = "user"',
                '',
                '[desktop]',
                'runCodexInWindowsSubsystemForLinux = false',
                'integratedTerminalShell = "powershell"'
            )
        }
    }
}

function Repair-CodexConfig {
    param(
        [string]$ConfigPath,
        [string]$InstallRoot,
        [string]$PackageVersion
    )

    $appDir = Join-Path $InstallRoot 'app'
    $resourcesDir = Join-Path $appDir 'resources'
    $codexHome = Join-Path $InstallRoot 'data\CodexHome'
    $nodeDir = Join-Path $resourcesDir 'cua_node\bin'
    $nodeModules = Join-Path $nodeDir 'node_modules'

    $lines = @()
    if (Test-Path -LiteralPath $ConfigPath) {
        $lines = @(Get-Content -LiteralPath $ConfigPath)
    }

    $backup = "$ConfigPath.before_autofix_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if ((Test-Path -LiteralPath $ConfigPath) -and $PSCmdlet.ShouldProcess($backup, 'backup config.toml')) {
        Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
    }

    $lines = Remove-TomlSection -Lines $lines -Section 'marketplaces.openai-bundled'
    $lines = Set-TomlTopLevelKey -Lines $lines -Key 'notify' -Value ("[ {0}, ""turn-ended"" ]" -f (Convert-ToTomlLiteral (Join-Path $nodeModules '@oai\sky\bin\windows\codex-computer-use.exe')))
    $lines = Set-TomlTopLevelKey -Lines $lines -Key 'approvals_reviewer' -Value '"user"'
    if (-not $KeepCodexPermissions) {
        $lines = Set-TomlTopLevelKey -Lines $lines -Key 'approval_policy' -Value '"never"'
        $lines = Set-TomlTopLevelKey -Lines $lines -Key 'sandbox_mode' -Value '"danger-full-access"'
        $lines = Set-TomlTopLevelKey -Lines $lines -Key 'default_permissions' -Value '":danger-full-access"'
        $lines = Set-TomlSectionKey -Lines $lines -Section 'windows' -Key 'sandbox' -Value '"unelevated"'
    }
    $lines = Set-TomlSectionKey -Lines $lines -Section 'desktop' -Key 'runCodexInWindowsSubsystemForLinux' -Value 'false'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'desktop' -Key 'integratedTerminalShell' -Value '"powershell"'

    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl' -Key 'args' -Value '[]'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl' -Key 'command' -Value (Convert-ToTomlLiteral (Join-Path $nodeDir 'node_repl.exe'))
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl' -Key 'startup_timeout_sec' -Value '120'

    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'NODE_REPL_NODE_MODULE_DIRS' -Value (Convert-ToTomlLiteral $nodeModules)
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'NODE_REPL_NODE_PATH' -Value (Convert-ToTomlLiteral (Join-Path $nodeDir 'node.exe'))
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'NODE_REPL_TRUSTED_CODE_PATHS' -Value (Convert-ToTomlLiteral $codexHome)
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'CODEX_HOME' -Value (Convert-ToTomlLiteral $codexHome)
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'CODEX_CLI_PATH' -Value (Convert-ToTomlLiteral (Join-Path $resourcesDir 'codex.exe'))
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'BROWSER_USE_CODEX_APP_VERSION' -Value ('"{0}"' -f $PackageVersion)
    $lines = Remove-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'SKY_CUA_NATIVE_PIPE_DIRECTORY'

    if ($PSCmdlet.ShouldProcess($ConfigPath, 'write repaired config.toml')) {
        Set-Utf8NoBomContent -Path $ConfigPath -Value $lines
    }
}

function Repair-CodexPermissionState {
    param([string[]]$StatePaths)

    if ($KeepCodexPermissions) {
        Write-WarnLine 'Keeping existing Codex permission state because -KeepCodexPermissions was provided'
        return
    }

    foreach ($statePath in $StatePaths | Select-Object -Unique) {
        $stateDir = Split-Path -Parent $statePath
        if (-not (Test-Path -LiteralPath $stateDir)) {
            continue
        }

        try {
            if (Test-Path -LiteralPath $statePath) {
                $json = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            } else {
                $json = [pscustomobject]@{}
            }

            $atomProp = $json.PSObject.Properties['electron-persisted-atom-state']
            if ($null -eq $atomProp) {
                Set-ObjectProperty -Object $json -Name 'electron-persisted-atom-state' -Value ([pscustomobject]@{})
            }
            $atom = $json.'electron-persisted-atom-state'

            $modeProp = $atom.PSObject.Properties['agent-mode-by-host-id']
            if ($null -eq $modeProp) {
                Set-ObjectProperty -Object $atom -Name 'agent-mode-by-host-id' -Value ([pscustomobject]@{})
            }
            Set-ObjectProperty -Object $atom.'agent-mode-by-host-id' -Name 'local' -Value 'full-access'
            Set-ObjectProperty -Object $atom -Name 'skip-full-access-confirm' -Value $true

            if ($atom.PSObject.Properties['preferred-non-full-access-agent-mode-by-host-id']) {
                $atom.PSObject.Properties.Remove('preferred-non-full-access-agent-mode-by-host-id')
            }

            $heartbeatProp = $atom.PSObject.Properties['heartbeat-thread-permissions-by-id']
            if ($null -ne $heartbeatProp -and $null -ne $heartbeatProp.Value) {
                foreach ($prop in $heartbeatProp.Value.PSObject.Properties) {
                    $permission = $prop.Value
                    if ($null -eq $permission) {
                        continue
                    }
                    Set-ObjectProperty -Object $permission -Name 'activePermissionProfile' -Value ([pscustomobject]@{ id = ':danger-full-access' })
                    Set-ObjectProperty -Object $permission -Name 'approvalPolicy' -Value 'never'
                    Set-ObjectProperty -Object $permission -Name 'approvalsReviewer' -Value 'user'
                    Set-ObjectProperty -Object $permission -Name 'sandboxPolicy' -Value ([pscustomobject]@{ type = 'dangerFullAccess' })
                }
            }

            if ($PSCmdlet.ShouldProcess($statePath, 'write full-access Codex permission state')) {
                Set-Utf8NoBomContent -Path $statePath -Value ($json | ConvertTo-Json -Depth 100)
            }
        } catch {
            Write-WarnLine "Could not repair Codex permission state ${statePath}: $($_.Exception.Message)"
        }
    }
}

function Convert-PathForRegexReplacement {
    param([string]$Path)
    return $Path.Replace('\', '\\').Replace('$', '$$')
}

function Update-JsonNode {
    param(
        [object]$Node,
        [hashtable]$Paths
    )

    if ($null -eq $Node) {
        return
    }

    if ($Node -is [System.Array]) {
        foreach ($item in $Node) {
            Update-JsonNode -Node $item -Paths $Paths
        }
        return
    }

    if ($Node -isnot [pscustomobject]) {
        return
    }

    foreach ($prop in @($Node.PSObject.Properties)) {
        $name = $prop.Name
        $value = $prop.Value
        if ($value -is [string]) {
            $newValue = $value
            switch -Regex ($name) {
                '^(codexCliPath|cliPath|CODEX_CLI_PATH)$' { $newValue = $Paths.CodexExe; break }
                '^(resourcesPath|CODEX_ELECTRON_RESOURCES_PATH)$' { $newValue = $Paths.Resources; break }
                '^(codexHome|CODEX_HOME)$' { $newValue = $Paths.CodexHome; break }
                '^(nodePath|NODE_REPL_NODE_PATH)$' { $newValue = $Paths.NodeExe; break }
                '^(nodeReplPath|NODE_REPL_PATH)$' { $newValue = $Paths.NodeRepl; break }
                '^(extensionHostPath|nativeHostPath)$' { $newValue = $Paths.ExtensionHost; break }
                default {
                    $newValue = $newValue -replace 'C:\\Program Files\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\resources', (Convert-PathForRegexReplacement $Paths.Resources)
                    $newValue = $newValue -replace 'C:\\Users\\[^\\]+\\AppData\\Local\\OpenAI\\Codex\\bin\\[^\\]+\\codex\.exe', (Convert-PathForRegexReplacement $Paths.CodexExe)
                    $newValue = $newValue -replace 'C:\\Users\\[^\\]+\\AppData\\Local\\OpenAI\\Codex\\bin\\[^\\]+\\node\.exe', (Convert-PathForRegexReplacement $Paths.NodeExe)
                    $newValue = $newValue -replace 'C:\\Users\\[^\\]+\\.codex\\plugins\\cache\\openai-bundled\\chrome\\[^\\]+\\extension-host\\windows\\x64\\extension-host\.exe', (Convert-PathForRegexReplacement $Paths.ExtensionHost)
                }
            }
            if ($newValue -ne $value) {
                $Node.$name = $newValue
            }
        } else {
            Update-JsonNode -Node $value -Paths $Paths
        }
    }
}

function Repair-NativeHostJson {
    param(
        [string[]]$PathsToRepair,
        [string]$InstallRoot
    )

    $resourcesDir = Join-Path $InstallRoot 'app\resources'
    $paths = @{
        CodexExe = Join-Path $resourcesDir 'codex.exe'
        Resources = $resourcesDir
        CodexHome = Join-Path $InstallRoot 'data\CodexHome'
        NodeExe = Join-Path $resourcesDir 'cua_node\bin\node.exe'
        NodeRepl = Join-Path $resourcesDir 'cua_node\bin\node_repl.exe'
        ExtensionHost = Join-Path $resourcesDir 'plugins\openai-bundled\plugins\chrome\extension-host\windows\x64\extension-host.exe'
    }

    foreach ($jsonPath in $PathsToRepair | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $jsonPath)) {
            continue
        }
        try {
            $raw = Get-Content -LiteralPath $jsonPath -Raw
            $json = $raw | ConvertFrom-Json
            Update-JsonNode -Node $json -Paths $paths
            if ($PSCmdlet.ShouldProcess($jsonPath, 'repair native host JSON paths')) {
                Set-Utf8NoBomContent -Path $jsonPath -Value ($json | ConvertTo-Json -Depth 32)
            }
        } catch {
            Write-WarnLine "Could not repair JSON ${jsonPath}: $($_.Exception.Message)"
        }
    }
}

function Write-LauncherFiles {
    param([string]$Root)

    $bin = Join-Path $Root 'bin'
    New-Directory -Path $bin

    if ($NoAdminLaunchers) {
        $desktopCmd = @'
@echo off
setlocal
call "%~dp0codex-env.cmd"
start "Codex Desktop Isolated" /D "%CODEX_APP%" "%CODEX_APP%\Codex.exe" --app="%CODEX_APP%\resources\app.asar" --user-data-dir="%CODEX_DATA%\CodexDesktopProfile" --no-first-run %*
'@
        $desktopSafeGpuCmd = @'
@echo off
setlocal
call "%~dp0codex-env.cmd"
start "Codex Desktop Isolated GPU Safe" /D "%CODEX_APP%" "%CODEX_APP%\Codex.exe" --app="%CODEX_APP%\resources\app.asar" --user-data-dir="%CODEX_DATA%\CodexDesktopProfile" --no-first-run --disable-gpu %*
'@
        $desktopVbs = @'
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
shell.Run """" & scriptDir & "\codex-desktop.cmd" & """", 0, False
'@
        $desktopSafeGpuVbs = @'
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
shell.Run """" & scriptDir & "\codex-desktop-safe-gpu.cmd" & """", 0, False
'@
    } else {
        $desktopCmd = @'
@echo off
setlocal
call "%~dp0codex-env.cmd"
if /I not "%CODEX_SKIP_ELEVATE%"=="1" (
  fltmc >nul 2>nul
  if errorlevel 1 (
    set "CODEX_SKIP_ELEVATE=1"
    set "CODEX_DESKTOP_CMD=%~f0"
    set "CODEX_DESKTOP_ARGS=%*"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$cmd=$env:CODEX_DESKTOP_CMD; $argLine=$env:CODEX_DESKTOP_ARGS; $argList='/c ""' + $cmd + '""'; if ($argLine) { $argList += ' ' + $argLine }; Start-Process -FilePath $env:ComSpec -ArgumentList $argList -WorkingDirectory (Split-Path -Parent $cmd) -Verb RunAs -WindowStyle Hidden"
    exit /b
  )
)
start "Codex Desktop Isolated" /D "%CODEX_APP%" "%CODEX_APP%\Codex.exe" --app="%CODEX_APP%\resources\app.asar" --user-data-dir="%CODEX_DATA%\CodexDesktopProfile" --no-first-run --do-not-de-elevate %*
'@
        $desktopSafeGpuCmd = @'
@echo off
setlocal
call "%~dp0codex-env.cmd"
if /I not "%CODEX_SKIP_ELEVATE%"=="1" (
  fltmc >nul 2>nul
  if errorlevel 1 (
    set "CODEX_SKIP_ELEVATE=1"
    set "CODEX_DESKTOP_CMD=%~f0"
    set "CODEX_DESKTOP_ARGS=%*"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$cmd=$env:CODEX_DESKTOP_CMD; $argLine=$env:CODEX_DESKTOP_ARGS; $argList='/c ""' + $cmd + '""'; if ($argLine) { $argList += ' ' + $argLine }; Start-Process -FilePath $env:ComSpec -ArgumentList $argList -WorkingDirectory (Split-Path -Parent $cmd) -Verb RunAs -WindowStyle Hidden"
    exit /b
  )
)
start "Codex Desktop Isolated GPU Safe" /D "%CODEX_APP%" "%CODEX_APP%\Codex.exe" --app="%CODEX_APP%\resources\app.asar" --user-data-dir="%CODEX_DATA%\CodexDesktopProfile" --no-first-run --disable-gpu --do-not-de-elevate %*
'@
        $desktopVbs = @'
Set app = CreateObject("Shell.Application")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
app.ShellExecute scriptDir & "\codex-desktop.cmd", "", scriptDir, "runas", 0
'@
        $desktopSafeGpuVbs = @'
Set app = CreateObject("Shell.Application")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
app.ShellExecute scriptDir & "\codex-desktop-safe-gpu.cmd", "", scriptDir, "runas", 0
'@
    }

    $files = @{
        'codex-env.cmd' = @'
@echo off
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "CODEX_APP=%ROOT%\app"
set "CODEX_DATA=%ROOT%\data"
if not exist "%CODEX_DATA%\Temp" mkdir "%CODEX_DATA%\Temp" >nul 2>nul
if not exist "%CODEX_DATA%\Home" mkdir "%CODEX_DATA%\Home" >nul 2>nul
if not exist "%CODEX_DATA%\CodexHome" mkdir "%CODEX_DATA%\CodexHome" >nul 2>nul
set "TEMP=%CODEX_DATA%\Temp"
set "TMP=%CODEX_DATA%\Temp"
set "HOME=%CODEX_DATA%\Home"
set "CODEX_HOME=%CODEX_DATA%\CodexHome"
set "CODEX_CLI_PATH=%CODEX_APP%\resources\codex.exe"
set "CODEX_CHROME_USER_DATA_DIR=%CODEX_DATA%\CodexDesktopProfile"
set "CODEX_ELECTRON_USER_DATA_PATH=%CODEX_DATA%\CodexDesktopProfile"
set "CODEX_ELECTRON_RESOURCES_PATH=%CODEX_APP%\resources"
set "CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH=%CODEX_APP%\resources"
set "XDG_CONFIG_HOME=%CODEX_HOME%\xdg-config"
set "XDG_CACHE_HOME=%CODEX_HOME%\xdg-cache"
set "XDG_DATA_HOME=%CODEX_HOME%\xdg-data"
set "PATH=%CODEX_APP%\resources;%CODEX_APP%\resources\cua_node\bin;%PATH%"
'@
        'codex-desktop.cmd' = $desktopCmd
        'codex-desktop-safe-gpu.cmd' = $desktopSafeGpuCmd
        'codex-cli.cmd' = @'
@echo off
call "%~dp0codex-env.cmd"
"%CODEX_CLI_PATH%" %*
'@
        'codex.cmd' = @'
@echo off
call "%~dp0codex-cli.cmd" %*
'@
        'codex-desktop.vbs' = $desktopVbs
        'codex-desktop-safe-gpu.vbs' = $desktopSafeGpuVbs
    }

    foreach ($entry in $files.GetEnumerator()) {
        $path = Join-Path $bin $entry.Key
        if ($PSCmdlet.ShouldProcess($path, 'write launcher')) {
            Set-Content -LiteralPath $path -Value $entry.Value -Encoding ASCII
        }
    }
}

function Add-ToUserPathFront {
    param([string]$PathToAdd)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($current) {
        $parts = @($current -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
    }

    $normalized = [System.IO.Path]::GetFullPath($PathToAdd).TrimEnd('\')
    $filtered = @($parts | Where-Object {
        try {
            [System.IO.Path]::GetFullPath($_).TrimEnd('\') -ine $normalized
        } catch {
            $_ -ine $PathToAdd
        }
    })
    $newPath = (@($PathToAdd) + $filtered) -join ';'
    if ($PSCmdlet.ShouldProcess('HKCU Environment Path', "prepend $PathToAdd")) {
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
}

function Set-IsolatedEnvironment {
    param([string]$Root)

    $codexHome = Join-Path $Root 'data\CodexHome'
    $codexExe = Join-Path $Root 'app\resources\codex.exe'
    $bin = Join-Path $Root 'bin'

    if ($PSCmdlet.ShouldProcess('HKCU Environment', 'set Codex isolated variables')) {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexHome, 'User')
        [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $codexExe, 'User')
        [Environment]::SetEnvironmentVariable('CODEX_SQLITE_HOME', $null, 'User')
        & cmd.exe /c 'reg delete HKCU\Environment /v CODEX_SQLITE_HOME /f >nul 2>nul'
    }
    Add-ToUserPathFront -PathToAdd $bin
}

function Send-EnvironmentBroadcast {
    if (-not $PSCmdlet.ShouldProcess('Windows shell', 'broadcast environment change')) {
        return
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CodexAutofixNativeMethods {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, IntPtr wParam, string lParam, int fuFlags, int uTimeout, out IntPtr lpdwResult);
}
'@
    $result = [IntPtr]::Zero
    [void][CodexAutofixNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
}

function New-CodexShortcuts {
    param([string]$Root)

    if ($NoShortcuts) {
        return
    }

    $bin = Join-Path $Root 'bin'
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) ''
    $shell = New-Object -ComObject WScript.Shell

    $targets = @(
        @{
            Path = Join-Path $desktop 'Codex Desktop (Isolated).lnk'
            Script = Join-Path $bin 'codex-desktop.vbs'
            Description = 'Codex Desktop isolated launcher'
        },
        @{
            Path = Join-Path $startMenu 'Codex Desktop (Isolated).lnk'
            Script = Join-Path $bin 'codex-desktop.vbs'
            Description = 'Codex Desktop isolated launcher'
        },
        @{
            Path = Join-Path $startMenu 'Codex Desktop (Isolated GPU Safe).lnk'
            Script = Join-Path $bin 'codex-desktop-safe-gpu.vbs'
            Description = 'Codex Desktop isolated launcher with GPU disabled'
        }
    )

    foreach ($target in $targets) {
        if ($PSCmdlet.ShouldProcess($target.Path, 'create shortcut')) {
            $shortcut = $shell.CreateShortcut($target.Path)
            $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $shortcut.Arguments = '"' + $target.Script + '"'
            $shortcut.WorkingDirectory = $bin
            $shortcut.Description = $target.Description
            $icon = Join-Path $Root 'app\resources\codex-tray.ico'
            if (Test-Path -LiteralPath $icon) {
                $shortcut.IconLocation = $icon
            }
            $shortcut.Save()
            if (-not $NoAdminShortcuts) {
                Set-ShortcutRunAsAdmin -ShortcutPath $target.Path
            }
        }
    }
}

function Set-ShortcutRunAsAdmin {
    param([string]$ShortcutPath)

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        return
    }

    if ($PSCmdlet.ShouldProcess($ShortcutPath, 'set Run as administrator flag')) {
        $bytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
        if ($bytes.Length -gt 0x15) {
            $bytes[0x15] = $bytes[0x15] -bor 0x20
            [System.IO.File]::WriteAllBytes($ShortcutPath, $bytes)
        }
    }
}

function Stop-IsolatedCodexProcesses {
    param(
        [string]$Root,
        [switch]$Force
    )

    if (-not $Force -and -not $RestartExisting) {
        return
    }

    $appRoot = Join-Path $Root 'app'
    $resourceRoot = Join-Path $appRoot 'resources'
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -eq 'Codex.exe' -and $_.ExecutablePath -like "$appRoot*") -or
        ($_.Name -eq 'codex.exe' -and $_.ExecutablePath -like "$resourceRoot*")
    })
    if ($processes.Count -eq 0) {
        return
    }

    $ids = @($processes | Select-Object -ExpandProperty ProcessId)
    if ($PSCmdlet.ShouldProcess(($ids -join ', '), 'stop isolated Codex Desktop processes')) {
        Stop-Process -Id $ids -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

function Get-CodexPermissionStatePaths {
    param(
        [string]$OldCodexHome,
        [string]$NewCodexHome
    )

    return @(
        (Join-Path $OldCodexHome '.codex-global-state.json'),
        (Join-Path $OldCodexHome '.codex-global-state.json.bak'),
        (Join-Path $NewCodexHome '.codex-global-state.json'),
        (Join-Path $NewCodexHome '.codex-global-state.json.bak')
    )
}

function Test-IsolatedCli {
    param([string]$Root)

    $cli = Join-Path $Root 'bin\codex-cli.cmd'
    if (-not (Test-Path -LiteralPath $cli)) {
        throw "Missing isolated CLI launcher: $cli"
    }

    $output = & $cli --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Isolated CLI failed: $output"
    }
    Write-Ok "Isolated CLI: $output"
}

function Test-FullAccessConfig {
    param([string]$Root)

    if ($KeepCodexPermissions) {
        return
    }

    $codexHome = Join-Path $Root 'data\CodexHome'
    $configPath = Join-Path $codexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Missing isolated config.toml: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw
    $checks = @(
        @{ Name = 'approval_policy'; Pass = ($config -match '(?m)^\s*approval_policy\s*=\s*"never"\s*$') },
        @{ Name = 'sandbox_mode'; Pass = ($config -match '(?m)^\s*sandbox_mode\s*=\s*"danger-full-access"\s*$') },
        @{ Name = 'default_permissions'; Pass = ($config -match '(?m)^\s*default_permissions\s*=\s*":danger-full-access"\s*$') },
        @{ Name = 'windows sandbox'; Pass = ($config -match '(?s)\[windows\].*?sandbox\s*=\s*"unelevated"') }
    )
    foreach ($check in $checks) {
        if (-not $check.Pass) {
            throw "Full-access config check failed: $($check.Name)"
        }
    }

    $statePath = Join-Path $codexHome '.codex-global-state.json'
    if (Test-Path -LiteralPath $statePath) {
        $json = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $atomProp = $json.PSObject.Properties['electron-persisted-atom-state']
        if ($null -eq $atomProp) {
            Write-WarnLine 'Codex global state has no electron persisted atom state; relying on pinned config.toml permissions'
        } else {
            $atom = $atomProp.Value
            $modeProp = $atom.PSObject.Properties['agent-mode-by-host-id']
            $skipProp = $atom.PSObject.Properties['skip-full-access-confirm']
            if ($null -eq $modeProp -or $modeProp.Value.local -ne 'full-access') {
                Write-WarnLine 'Codex global state does not report local=full-access; relying on pinned config.toml permissions'
            }
            if ($null -eq $skipProp -or $skipProp.Value -ne $true) {
                Write-WarnLine 'Codex global state does not report skip-full-access-confirm=true; relying on pinned config.toml permissions'
            }
        }
    }

    Write-Ok 'Full-access Codex config is pinned'
}

function Start-IsolatedCodex {
    param([string]$Root)

    if ($NoLaunch) {
        Write-WarnLine 'Skipping launch because -NoLaunch was provided'
        return
    }

    $launcher = if ($GpuSafe) {
        Join-Path $Root 'bin\codex-desktop-safe-gpu.cmd'
    } else {
        Join-Path $Root 'bin\codex-desktop.cmd'
    }

    if ($PSCmdlet.ShouldProcess($launcher, 'launch isolated Codex Desktop')) {
        Start-Process -FilePath $launcher -WindowStyle Hidden -WorkingDirectory (Join-Path $Root 'bin')
        Start-Sleep -Seconds 15
    }
}

function Test-IsolatedDesktop {
    param([string]$Root)

    if ($NoLaunch) {
        return
    }

    $appExe = Join-Path $Root 'app\Codex.exe'
    $resourceExe = Join-Path $Root 'app\resources\codex.exe'
    $main = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'Codex.exe' -and $_.ExecutablePath -eq $appExe -and $_.CommandLine -like '*--app=*'
    })
    $server = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'codex.exe' -and $_.ExecutablePath -eq $resourceExe -and $_.CommandLine -like '*app-server*'
    })

    if ($main.Count -eq 0) {
        throw "Isolated Codex Desktop process was not found at $appExe"
    }
    if ($server.Count -eq 0) {
        throw "Isolated Codex app-server process was not found at $resourceExe"
    }

    Write-Ok "Isolated Desktop PID: $($main[0].ProcessId)"
    Write-Ok "Isolated app-server PID: $($server[0].ProcessId)"
}

function Test-RecentLogs {
    param([string]$Root)

    if ($NoLaunch) {
        return
    }

    $logRoot = Join-Path $env:LOCALAPPDATA 'Codex\Logs'
    if (-not (Test-Path -LiteralPath $logRoot)) {
        Write-WarnLine "Codex log directory not found: $logRoot"
        return
    }

    $cutoff = (Get-Date).AddMinutes(-5)
    $logs = @(Get-ChildItem -Path $logRoot -Recurse -Filter 'codex-desktop-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cutoff } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 8)
    if ($logs.Count -eq 0) {
        Write-WarnLine 'No recent Codex Desktop logs found yet'
        return
    }

    $bad = @(
        'wsl.exe',
        'failed to initialize sqlite',
        'EBUSY',
        'Failed to list primary runtime archive',
        'Invalid request: missing field inputSchema',
        'marketplace ''openai-bundled'' is already added',
        'fatal_error_broadcasted'
    )
    $matches = @($logs | Select-String -Pattern $bad -SimpleMatch)
    if ($matches.Count -gt 0) {
        Write-WarnLine 'Recent logs still contain suspicious lines:'
        $matches | Select-Object -First 20 | ForEach-Object {
            Write-WarnLine "$($_.Path):$($_.LineNumber): $($_.Line.Trim())"
        }
        return
    }

    Write-Ok 'Recent Codex Desktop logs do not contain known failure patterns'
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$BackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
$appDir = Join-Path $InstallRoot 'app'
$dataDir = Join-Path $InstallRoot 'data'
$codexHome = Join-Path $dataDir 'CodexHome'
$oldCodexHome = Join-Path $env:USERPROFILE '.codex'

Write-Step "Install root: $InstallRoot"
$packageInfo = Get-LatestCodexPackage
Write-Ok "Found OpenAI.Codex package $($packageInfo.Version)"
Write-Step "MSIX app source: $($packageInfo.SourceApp)"

$backup = New-Backup -Root $BackupRoot -OldCodexHome $oldCodexHome -NewCodexHome $codexHome
Write-Ok "Backup: $backup"

New-Directory -Path $InstallRoot
New-Directory -Path $dataDir
New-Directory -Path (Join-Path $dataDir 'Temp')
New-Directory -Path (Join-Path $dataDir 'Home')
New-Directory -Path (Join-Path $dataDir 'CodexDesktopProfile')

Stop-IsolatedCodexProcesses -Root $InstallRoot
Invoke-RobocopyMirror -Source $packageInfo.SourceApp -Destination $appDir
Initialize-CodexHome -OldCodexHome $oldCodexHome -NewCodexHome $codexHome
Sync-CodexState -OldCodexHome $oldCodexHome -NewCodexHome $codexHome -Backup $backup
Repair-CodexConfig -ConfigPath (Join-Path $codexHome 'config.toml') -InstallRoot $InstallRoot -PackageVersion $packageInfo.Version
$permissionStatePaths = Get-CodexPermissionStatePaths -OldCodexHome $oldCodexHome -NewCodexHome $codexHome
Repair-CodexPermissionState -StatePaths $permissionStatePaths

$nativeHostPaths = @(
    (Join-Path $oldCodexHome 'chrome-native-hosts-v2.json'),
    (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'),
    (Join-Path $codexHome 'chrome-native-hosts-v2.json')
)
if ((Test-Path -LiteralPath (Join-Path $oldCodexHome 'chrome-native-hosts-v2.json')) -and -not (Test-Path -LiteralPath (Join-Path $codexHome 'chrome-native-hosts-v2.json'))) {
    if ($PSCmdlet.ShouldProcess((Join-Path $codexHome 'chrome-native-hosts-v2.json'), 'seed native host JSON into isolated Codex home')) {
        Copy-Item -LiteralPath (Join-Path $oldCodexHome 'chrome-native-hosts-v2.json') -Destination (Join-Path $codexHome 'chrome-native-hosts-v2.json') -Force
    }
}
Repair-NativeHostJson -PathsToRepair $nativeHostPaths -InstallRoot $InstallRoot

Write-LauncherFiles -Root $InstallRoot
Set-IsolatedEnvironment -Root $InstallRoot
Send-EnvironmentBroadcast
New-CodexShortcuts -Root $InstallRoot

if ($WhatIfPreference) {
    Write-Ok 'WhatIf completed; no changes were applied and runtime validation was skipped'
    return
}

Test-IsolatedCli -Root $InstallRoot
Test-FullAccessConfig -Root $InstallRoot
Start-IsolatedCodex -Root $InstallRoot
Test-IsolatedDesktop -Root $InstallRoot
if (-not $NoLaunch -and -not $KeepCodexPermissions) {
    Stop-IsolatedCodexProcesses -Root $InstallRoot -Force
    Repair-CodexPermissionState -StatePaths $permissionStatePaths
    Test-FullAccessConfig -Root $InstallRoot
    Start-IsolatedCodex -Root $InstallRoot
    Test-IsolatedDesktop -Root $InstallRoot
    Test-FullAccessConfig -Root $InstallRoot
}
Test-RecentLogs -Root $InstallRoot

Write-Ok 'Codex Desktop isolation repair completed'
Write-Host ''
Write-Host 'Use this shortcut now: Codex Desktop (Isolated)'
Write-Host "Install root: $InstallRoot"
Write-Host "Backup root:  $backup"

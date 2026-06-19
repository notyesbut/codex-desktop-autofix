#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE 'Apps\CodexDesktop'),
    [string]$BackupRoot = (Join-Path $env:USERPROFILE 'CodexDesktopAutofixBackup'),
    [switch]$NoLaunch,
    [switch]$RestartExisting,
    [switch]$GpuSafe,
    [switch]$NoShortcuts,
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
    $lines = Set-TomlSectionKey -Lines $lines -Section 'desktop' -Key 'runCodexInWindowsSubsystemForLinux' -Value 'false'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'desktop' -Key 'integratedTerminalShell' -Value '"powershell"'
    $lines = Set-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'CODEX_HOME' -Value (Convert-ToTomlLiteral 'C:\Users\test\Apps\CodexDesktop\data\CodexHome')
    $lines = Remove-TomlSectionKey -Lines $lines -Section 'mcp_servers.node_repl.env' -Key 'SKY_CUA_NATIVE_PIPE_DIRECTORY'
    $text = $lines -join "`n"

    $checks = @(
        @{ Name = 'bundled section removed'; Pass = ($text -notmatch '\[marketplaces\.openai-bundled\]') },
        @{ Name = 'primary runtime preserved'; Pass = ($text -match '\[marketplaces\.openai-primary-runtime\]') },
        @{ Name = 'wsl disabled'; Pass = ($text -match 'runCodexInWindowsSubsystemForLinux = false') },
        @{ Name = 'powershell terminal set'; Pass = ($text -match 'integratedTerminalShell = "powershell"') },
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
        $envSnapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'user-env-snapshot.json') -Encoding UTF8
    }

    return $backup
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
            Set-Content -LiteralPath $configPath -Value @(
                'approvals_reviewer = "user"',
                '',
                '[desktop]',
                'runCodexInWindowsSubsystemForLinux = false',
                'integratedTerminalShell = "powershell"'
            ) -Encoding UTF8
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
        Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
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
                $json | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
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
        'codex-desktop.cmd' = @'
@echo off
setlocal
call "%~dp0codex-env.cmd"
start "Codex Desktop Isolated" /D "%CODEX_APP%" "%CODEX_APP%\Codex.exe" --app="%CODEX_APP%\resources\app.asar" --user-data-dir="%CODEX_DATA%\CodexDesktopProfile" --no-first-run %*
'@
        'codex-desktop-safe-gpu.cmd' = @'
@echo off
setlocal
call "%~dp0codex-env.cmd"
start "Codex Desktop Isolated GPU Safe" /D "%CODEX_APP%" "%CODEX_APP%\Codex.exe" --app="%CODEX_APP%\resources\app.asar" --user-data-dir="%CODEX_DATA%\CodexDesktopProfile" --no-first-run --disable-gpu %*
'@
        'codex-cli.cmd' = @'
@echo off
call "%~dp0codex-env.cmd"
"%CODEX_CLI_PATH%" %*
'@
        'codex.cmd' = @'
@echo off
call "%~dp0codex-cli.cmd" %*
'@
        'codex-desktop.vbs' = @'
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
shell.Run """" & scriptDir & "\codex-desktop.cmd" & """", 0, False
'@
        'codex-desktop-safe-gpu.vbs' = @'
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
shell.Run """" & scriptDir & "\codex-desktop-safe-gpu.cmd" & """", 0, False
'@
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
        }
    }
}

function Stop-IsolatedCodexProcesses {
    param([string]$Root)

    if (-not $RestartExisting) {
        return
    }

    $appRoot = Join-Path $Root 'app'
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'Codex.exe' -and $_.ExecutablePath -like "$appRoot*"
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

Invoke-RobocopyMirror -Source $packageInfo.SourceApp -Destination $appDir
Initialize-CodexHome -OldCodexHome $oldCodexHome -NewCodexHome $codexHome
Repair-CodexConfig -ConfigPath (Join-Path $codexHome 'config.toml') -InstallRoot $InstallRoot -PackageVersion $packageInfo.Version

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
Stop-IsolatedCodexProcesses -Root $InstallRoot

if ($WhatIfPreference) {
    Write-Ok 'WhatIf completed; no changes were applied and runtime validation was skipped'
    return
}

Test-IsolatedCli -Root $InstallRoot
Start-IsolatedCodex -Root $InstallRoot
Test-IsolatedDesktop -Root $InstallRoot
Test-RecentLogs -Root $InstallRoot

Write-Ok 'Codex Desktop isolation repair completed'
Write-Host ''
Write-Host 'Use this shortcut now: Codex Desktop (Isolated)'
Write-Host "Install root: $InstallRoot"
Write-Host "Backup root:  $backup"

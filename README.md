# Codex Desktop Autofix

Repair helper for a broken Windows Codex Desktop install where the MSIX/Store
package, stale CLI paths, WSL app-server mode, or locked plugin cache prevents
Codex from starting correctly.

The script creates an isolated Codex Desktop copy under:

```text
%USERPROFILE%\Apps\CodexDesktop
```

It leaves the Microsoft Store/MSIX package installed as a rollback source, but
new launchers and `codex` CLI resolution use the isolated copy.

## Quick Start

```powershell
gh repo clone notyesbut/codex-desktop-autofix
cd codex-desktop-autofix
powershell -ExecutionPolicy Bypass -File .\Repair-CodexDesktop.ps1 -RestartExisting
```

No GitHub CLI:

```powershell
$url = 'https://raw.githubusercontent.com/notyesbut/codex-desktop-autofix/main/Repair-CodexDesktop.ps1'
$dst = Join-Path $env:TEMP 'Repair-CodexDesktop.ps1'
Invoke-WebRequest $url -OutFile $dst
powershell -ExecutionPolicy Bypass -File $dst -RestartExisting
```

Dry run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-CodexDesktop.ps1 -WhatIf
```

Repair without launching Codex:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-CodexDesktop.ps1 -NoLaunch
```

## What It Fixes

- Copies the current `OpenAI.Codex` MSIX app payload out of `WindowsApps`.
- Creates an isolated profile and Codex home under `Apps\CodexDesktop\data`.
- Sets user environment:
  - `CODEX_HOME=%USERPROFILE%\Apps\CodexDesktop\data\CodexHome`
  - `CODEX_CLI_PATH=%USERPROFILE%\Apps\CodexDesktop\app\resources\codex.exe`
  - removes `CODEX_SQLITE_HOME`
- Prepends `%USERPROFILE%\Apps\CodexDesktop\bin` to the user `PATH`.
- Disables WSL app-server mode in the isolated `config.toml`.
- Rewrites stale local runtime paths inside isolated config/native-host files.
- Creates Desktop and Start Menu shortcuts:
  - `Codex Desktop (Isolated)`
  - `Codex Desktop (Isolated GPU Safe)`
- Launches Codex with:

```text
Codex.exe --app=...\resources\app.asar --user-data-dir=...\data\CodexDesktopProfile
```

## Safety

The script does not upload anything. It only writes local files and HKCU user
environment variables.

Before changing files it creates a backup under:

```text
%USERPROFILE%\CodexDesktopAutofixBackup\<timestamp>
```

Backups may contain local Codex configuration. They are intentionally ignored
by this repository and should not be committed or shared.

The script avoids:

- deleting `%USERPROFILE%\.codex`
- deleting auth files
- printing token contents
- killing arbitrary `codex.exe` processes
- uninstalling the Microsoft Store/MSIX package

With `-RestartExisting`, it stops only processes already running from the
isolated `%USERPROFILE%\Apps\CodexDesktop\app` directory.

Do not paste or upload these files in GitHub issues:

- `%USERPROFILE%\.codex\auth.json`
- any copied `auth.json` under the isolated `CodexHome`
- raw `config.toml` if it contains provider keys, MCP env vars, private commands, or private paths
- raw `HKCU-Environment.reg`
- SQLite databases, session logs, transcripts, or `.codex-global-state.json`
- command output containing API keys, `GH_TOKEN`, `GITHUB_TOKEN`, `github_pat_`, `ghp_`, `sk-`, cookies, bearer tokens, or proxy credentials

## Rollback

Rollback is intentionally manual so the script does not delete useful state:

```powershell
reg import "$env:USERPROFILE\CodexDesktopAutofixBackup\<timestamp>\HKCU-Environment.reg"
```

Then remove the isolated directory if you no longer need it:

```powershell
Remove-Item "$env:USERPROFILE\Apps\CodexDesktop" -Recurse -Force
```

The original MSIX package remains installed unless you remove it yourself.

## Troubleshooting

Check the active CLI:

```powershell
where.exe codex
codex --version
```

The first `where.exe codex` result should be:

```text
%USERPROFILE%\Apps\CodexDesktop\bin\codex.cmd
```

Check the running Desktop process:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -in @('Codex.exe','codex.exe') } |
  Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine
```

The main `Codex.exe` and `app-server` `codex.exe` should both run from
`%USERPROFILE%\Apps\CodexDesktop`.

Run script self-tests:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-CodexDesktop.ps1 -SelfTest
```

## Notes

This is an unofficial repair helper. It works by isolating the app from stale
WindowsApps/WinGet/WSL configuration and letting Codex regenerate runtime state
inside a clean local profile.

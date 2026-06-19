# Codex Desktop Autofix

Repair helper for a broken Windows Codex Desktop install where the MSIX/Store
package, stale CLI paths, WSL app-server mode, or locked plugin cache prevents
Codex from starting correctly. It also pins Codex to full-access/no-approval
mode and avoids the Windows Agent sandbox updater path that can show:

```text
Couldn't update Agent sandbox
Retry the update to continue
```

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

Keep the existing Codex permission/sandbox profile instead of forcing
full-access/no-approval:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-CodexDesktop.ps1 -KeepCodexPermissions
```

Skip history and SQLite migration/sync:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-CodexDesktop.ps1 -NoStateSync
```

Disable self-elevating desktop launchers:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-CodexDesktop.ps1 -NoAdminLaunchers
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
- Pins Codex permissions unless `-KeepCodexPermissions` is used:
  - `approval_policy="never"`
  - `sandbox_mode="danger-full-access"`
  - `default_permissions=":danger-full-access"`
  - `[windows] sandbox="unelevated"` to avoid the Agent sandbox updater failure
- Updates persisted Codex Desktop state to skip the full-access confirmation.
- Imports legacy history/state into the isolated Codex home unless `-NoStateSync`
  is used:
  - merges `history.jsonl` and `session_index.jsonl` without duplicate lines
  - copies missing `sessions`, `attachments`, and `memories` files
  - treats SQLite state as atomic `.sqlite/.sqlite-wal/.sqlite-shm` sets
  - resolves conflicts deterministically: newer state wins, the losing copy is
    saved under the run backup's `conflicts` directory
  - rebuilds `session_index.jsonl` from `state_5.sqlite` after the merge so
    recovered chats are visible in the Desktop sidebar
- Writes repaired TOML/JSON/JSONL state files as UTF-8 without BOM so strict
  Codex parsers do not reject the first key/line.
- Rewrites stale local runtime paths inside isolated config/native-host files.
- Creates Desktop and Start Menu shortcuts:
  - `Codex Desktop (Isolated)`
  - `Codex Desktop (Isolated GPU Safe)`
- Makes Desktop launchers self-elevate through UAC unless
  `-NoAdminLaunchers` is used.
- Marks shortcuts to run as administrator unless `-NoAdminShortcuts` is used.
- Launches Codex with:

```text
Codex.exe --app=...\resources\app.asar --user-data-dir=...\data\CodexDesktopProfile
```

## Safety

The script does not upload anything. It only writes local files, HKCU user
environment variables, and local shortcuts.

By default it enables Codex full-access/no-approval mode, self-elevating
launchers, and administrator shortcuts because that is the failure mode this
helper targets. Use `-KeepCodexPermissions`, `-NoAdminLaunchers`, and/or
`-NoAdminShortcuts` if you do not want those settings changed.

Before changing files it creates a backup under:

```text
%USERPROFILE%\CodexDesktopAutofixBackup\<timestamp>
```

Backups may contain local Codex configuration, history, transcripts, memories,
and SQLite databases. They are intentionally ignored by this repository and
should not be committed or shared.

The isolated Codex home is the active target after repair. The script imports
legacy `%USERPROFILE%\.codex` state into it, but it does not destructively
overwrite the legacy home. If two copies differ, the chosen active copy is based
on modification time and the losing copy is preserved in `conflicts`.

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
- backup `conflicts` directories
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

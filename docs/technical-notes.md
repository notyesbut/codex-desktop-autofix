# Technical Notes

## Observed Failure Pattern

Broken installs can combine several independent problems:

- persistent `CODEX_CLI_PATH` pointing at stale WSL or old WinGet runtimes
- `CODEX_SQLITE_HOME` set to an invalid or empty value
- Desktop configured to launch the local app-server through WSL
- locked bundled plugin temp cache under `%USERPROFILE%\.codex\.tmp`
- stale native host JSON pointing at removed `WindowsApps` package versions

The repair path isolates the mutable runtime from Microsoft Store/MSIX launch
state without deleting the original package.

## Isolation Layout

```text
%USERPROFILE%\Apps\CodexDesktop
  app\                    copied MSIX app payload
  bin\                    stable launchers
  data\
    CodexHome\            isolated CODEX_HOME
    CodexDesktopProfile\  Electron user-data-dir
    Home\
    Temp\
```

## Validation Signals

Healthy startup should show:

- main `Codex.exe` from `Apps\CodexDesktop\app`
- app-server `codex.exe app-server` from `Apps\CodexDesktop\app\resources`
- `codex --version` resolving through `Apps\CodexDesktop\bin\codex.cmd`
- no recent log lines containing `wsl.exe`, `failed to initialize sqlite`,
  `EBUSY`, or `Invalid request: missing field inputSchema`

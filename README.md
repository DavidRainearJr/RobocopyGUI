# Robocopy GUI

A small Windows GUI for building and running common `robocopy` operations without typing the command by hand.

## Features

- Select source and destination folders with folder picker buttons.
- Choose common operation modes: Copy, Mirror, or Move.
- Preview operations with `robocopy /L` before changing files.
- Add common options with checkboxes.
- Add additional robocopy switches from a dropdown.
- Add raw advanced robocopy arguments manually.
- Save option settings.
- Save named operations with folder locations and settings.
- Write timestamped logs.
- Show hover tooltips for controls after a short delay.

## Requirements

- Windows
- `robocopy.exe`, included with modern Windows versions

## Quick Start

Download or clone this repository, then run:

```powershell
.\Robocopy-GUI.exe
```

You can also run the PowerShell source directly:

```powershell
.\Robocopy-GUI.ps1
```

If PowerShell blocks the script, run it with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Robocopy-GUI.ps1
```

## Operation Modes

Copy:
Copies files from the source to the destination. It does not delete files from the source or remove extra files from the destination.

Mirror:
Uses `robocopy /MIR`. The destination is made to match the source. Files and folders that exist only in the destination can be deleted.

Move:
Uses `robocopy /MOVE`. Files and folders are copied to the destination, then deleted from the source after successful copy.

## Recommended Workflow

1. Select a source folder.
2. Select a destination folder.
3. Choose Copy, Mirror, or Move.
4. Select any extra options you need.
5. Click Preview to review what robocopy will do.
6. If the preview looks correct, click Run.

## Saved Files

The app creates local files next to the executable or script:

- `RobocopyGui.settings.json` stores option choices.
- `RobocopyGui.operations.json` stores saved named operations.
- `logs\` stores robocopy log files.

These files are intentionally ignored by git because they may contain local folder paths.

## Safety Notes

- Always preview Mirror and Move operations before running them.
- Mirror can delete destination files that are not present in the source.
- Move can delete source files after they copy successfully.
- The app blocks identical or nested source and destination folders to avoid unsafe recursive operations.
- Review the generated robocopy command before running advanced arguments.

## Building the EXE

The included executable was built from `Robocopy-GUI.ps1` using `ps2exe`.

Example build command:

```powershell
Import-Module ps2exe
Invoke-ps2exe -inputFile .\Robocopy-GUI.ps1 -outputFile .\Robocopy-GUI.exe -noConsole -STA -DPIAware -winFormsDPIAware -longPaths -title "Robocopy GUI" -description "Robocopy GUI for common copy, mirror, and move operations" -product "Robocopy GUI" -company "Local" -version "1.0.0.0"
```

Keep `Robocopy-GUI.exe.config` next to `Robocopy-GUI.exe` if you move the executable.

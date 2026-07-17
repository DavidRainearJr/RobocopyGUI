<#
.SYNOPSIS
Windows GUI for building and running common robocopy operations.

.DESCRIPTION
Provides Copy, Mirror, and Move modes, common robocopy options, a dropdown for
additional options, an advanced arguments box, JSON settings/operation storage,
and timestamped logs.
#>

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if ($PSCommandPath) {
        $powerShellPath = (Get-Process -Id $PID).Path
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
        Start-Process -FilePath $powerShellPath -ArgumentList $arguments | Out-Null
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'

if ($PSScriptRoot) {
    $ScriptDirectory = $PSScriptRoot
} elseif ($PSCommandPath) {
    $ScriptDirectory = Split-Path -Parent $PSCommandPath
} else {
    $ScriptDirectory = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

$SettingsFile = Join-Path $ScriptDirectory 'RobocopyGui.settings.json'
$OperationsFile = Join-Path $ScriptDirectory 'RobocopyGui.operations.json'
$LogDirectory = Join-Path $ScriptDirectory 'logs'

$script:CurrentProcess = $null
$script:CurrentLogFile = $null
$script:LogPollTimer = $null
$script:LogReadOffset = [int64]0
$script:RunWasCancelled = $false
$script:RunCompletionHandled = $false
$script:LastProgressPercent = -1
$script:MaxOutputCharacters = 120000

$script:AdditionalOptionCatalog = @(
    [pscustomobject]@{
        Label = 'Copy security info (/COPY:DATS)'
        Arguments = @('/COPY:DATS')
        ExclusiveGroup = 'CopyMetadata'
        Description = 'Copies file data, attributes, timestamps, and NTFS permissions. Requires permission to read security data.'
    },
    [pscustomobject]@{
        Label = 'Copy all file info (/COPYALL)'
        Arguments = @('/COPYALL')
        ExclusiveGroup = 'CopyMetadata'
        Description = 'Copies all file metadata: data, attributes, timestamps, security, owner, and auditing.'
    },
    [pscustomobject]@{
        Label = 'Copy data only (/COPY:D)'
        Arguments = @('/COPY:D')
        ExclusiveGroup = 'CopyMetadata'
        Description = 'Copies file data only. Attributes, timestamps, and security metadata are not copied.'
    },
    [pscustomobject]@{
        Label = 'Delete destination extras (/PURGE)'
        Arguments = @('/PURGE')
        ExclusiveGroup = ''
        Description = 'Deletes destination files and folders that no longer exist in the source. This is destructive to the destination.'
    },
    [pscustomobject]@{
        Label = 'Exclude older source files (/XO)'
        Arguments = @('/XO')
        ExclusiveGroup = ''
        Description = 'Skips source files that are older than matching files already in the destination.'
    },
    [pscustomobject]@{
        Label = 'Exclude newer source files (/XN)'
        Arguments = @('/XN')
        ExclusiveGroup = ''
        Description = 'Skips source files that are newer than matching files already in the destination.'
    },
    [pscustomobject]@{
        Label = 'Exclude changed files (/XC)'
        Arguments = @('/XC')
        ExclusiveGroup = ''
        Description = 'Skips files that have the same timestamp but a different size.'
    },
    [pscustomobject]@{
        Label = 'Exclude destination extras (/XX)'
        Arguments = @('/XX')
        ExclusiveGroup = ''
        Description = 'Skips files and folders that exist only in the destination. This can prevent destination cleanup in mirror-like operations.'
    },
    [pscustomobject]@{
        Label = 'Exclude lonely source files (/XL)'
        Arguments = @('/XL')
        ExclusiveGroup = ''
        Description = 'Skips files and folders that exist only in the source.'
    },
    [pscustomobject]@{
        Label = 'Verbose output (/V)'
        Arguments = @('/V')
        ExclusiveGroup = ''
        Description = 'Shows skipped files in addition to copied files.'
    },
    [pscustomobject]@{
        Label = 'Show ETA (/ETA)'
        Arguments = @('/ETA')
        ExclusiveGroup = ''
        Description = 'Shows estimated time of arrival for copied files.'
    },
    [pscustomobject]@{
        Label = 'No file list (/NFL)'
        Arguments = @('/NFL')
        ExclusiveGroup = ''
        Description = 'Suppresses individual file names in robocopy output.'
    },
    [pscustomobject]@{
        Label = 'No directory list (/NDL)'
        Arguments = @('/NDL')
        ExclusiveGroup = ''
        Description = 'Suppresses directory names in robocopy output.'
    },
    [pscustomobject]@{
        Label = 'FAT time tolerance (/FFT)'
        Arguments = @('/FFT')
        ExclusiveGroup = ''
        Description = 'Uses a two-second timestamp tolerance. Useful when copying to or from non-NTFS storage.'
    },
    [pscustomobject]@{
        Label = 'Copy symbolic links as links (/SL)'
        Arguments = @('/SL')
        ExclusiveGroup = ''
        Description = 'Copies symbolic links as links instead of following them to copy their targets.'
    },
    [pscustomobject]@{
        Label = 'Create directory tree only (/CREATE)'
        Arguments = @('/CREATE')
        ExclusiveGroup = ''
        Description = 'Creates the folder structure and zero-length files without copying file contents.'
    },
    [pscustomobject]@{
        Label = 'Use unbuffered I/O (/J)'
        Arguments = @('/J')
        ExclusiveGroup = ''
        Description = 'Uses unbuffered I/O. This can help with very large files.'
    }
)

function Show-ErrorMessage {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Robocopy GUI', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Show-InfoMessage {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Robocopy GUI', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Show-ConfirmMessage {
    param(
        [string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    $result = [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Robocopy GUI', [System.Windows.Forms.MessageBoxButtons]::YesNo, $Icon)
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function ConvertTo-CommandLineArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument -eq '') {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $quoted = '"'
    $backslashCount = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }

        if ($character -eq '"') {
            $quoted += ('\' * (($backslashCount * 2) + 1))
            $quoted += '"'
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            $quoted += ('\' * $backslashCount)
            $backslashCount = 0
        }

        $quoted += $character
    }

    if ($backslashCount -gt 0) {
        $quoted += ('\' * ($backslashCount * 2))
    }

    $quoted += '"'
    return $quoted
}

function Join-CommandLineArguments {
    param(
        [string[]]$Arguments,
        [string]$AdvancedArguments
    )

    $commandLine = ($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $advanced = ($AdvancedArguments -replace "[`r`n]+", ' ').Trim()

    if (-not [string]::IsNullOrWhiteSpace($advanced)) {
        $commandLine = "$commandLine $advanced"
    }

    return $commandLine
}

function Split-PatternText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @($Text -split '[;,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Normalize-FolderPathForCompare {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path.Trim())
    if ($fullPath.Length -gt 3) {
        $fullPath = $fullPath.TrimEnd('\', '/')
    }

    return $fullPath.ToUpperInvariant()
}

function Test-IsNestedPath {
    param(
        [string]$ParentPath,
        [string]$ChildPath
    )

    $parent = Normalize-FolderPathForCompare $ParentPath
    $child = Normalize-FolderPathForCompare $ChildPath

    if ($parent -eq $child) {
        return $false
    }

    if (-not $parent.EndsWith('\')) {
        $parent = "$parent\"
    }

    return $child.StartsWith($parent, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SelectedMode {
    if ($rdoMirror.Checked) {
        return 'Mirror'
    }

    if ($rdoMove.Checked) {
        return 'Move'
    }

    return 'Copy'
}

function Set-SelectedMode {
    param([string]$Mode)

    switch ($Mode) {
        'Mirror' { $rdoMirror.Checked = $true }
        'Move' { $rdoMove.Checked = $true }
        default { $rdoCopy.Checked = $true }
    }
}

function Add-AdditionalOption {
    param([psobject]$Option)

    if ($null -eq $Option) {
        return
    }

    for ($index = $lstAdditional.Items.Count - 1; $index -ge 0; $index--) {
        $item = $lstAdditional.Items[$index]
        if ($item.Label -eq $Option.Label) {
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($Option.ExclusiveGroup) -and $item.ExclusiveGroup -eq $Option.ExclusiveGroup) {
            $lstAdditional.Items.RemoveAt($index)
        }
    }

    [void]$lstAdditional.Items.Add($Option)
}

function Get-SelectedAdditionalArguments {
    $arguments = New-Object System.Collections.Generic.List[string]

    foreach ($item in $lstAdditional.Items) {
        foreach ($argument in @($item.Arguments)) {
            [void]$arguments.Add([string]$argument)
        }
    }

    return @($arguments)
}

function Test-AdditionalOptionArgument {
    param([string]$Switch)

    foreach ($argument in Get-SelectedAdditionalArguments) {
        if ($argument -ieq $Switch) {
            return $true
        }
    }

    return $false
}

function Test-AdvancedArgumentSwitch {
    param([string[]]$SwitchNames)

    $advanced = $txtAdvanced.Text
    foreach ($switchName in $SwitchNames) {
        if ($advanced -match "(?i)(^|\s)/$switchName(:|\s|$)") {
            return $true
        }
    }

    return $false
}

function New-RobocopyArguments {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$LogFile,
        [bool]$ForcePreview
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $mode = Get-SelectedMode

    [void]$arguments.Add($Source)
    [void]$arguments.Add($Destination)

    switch ($mode) {
        'Mirror' {
            [void]$arguments.Add('/MIR')
        }
        'Move' {
            if ($chkIncludeEmpty.Checked) {
                [void]$arguments.Add('/E')
            } else {
                [void]$arguments.Add('/S')
            }

            [void]$arguments.Add('/MOVE')
        }
        default {
            if ($chkIncludeEmpty.Checked) {
                [void]$arguments.Add('/E')
            } else {
                [void]$arguments.Add('/S')
            }
        }
    }

    $hasCopyMetadataOption = $false
    foreach ($item in $lstAdditional.Items) {
        if ($item.ExclusiveGroup -eq 'CopyMetadata') {
            $hasCopyMetadataOption = $true
            break
        }
    }

    if (-not $hasCopyMetadataOption -and -not (Test-AdvancedArgumentSwitch @('COPY', 'COPYALL'))) {
        [void]$arguments.Add('/COPY:DAT')
    }

    if (-not (Test-AdvancedArgumentSwitch @('DCOPY'))) {
        [void]$arguments.Add('/DCOPY:DAT')
    }

    if ($ForcePreview -or $chkPreview.Checked) {
        [void]$arguments.Add('/L')
    }

    if ($chkExcludeJunctions.Checked) {
        [void]$arguments.Add('/XJ')
    }

    if ($chkRestartable.Checked) {
        [void]$arguments.Add('/Z')
    }

    if ($chkMultiThread.Checked) {
        [void]$arguments.Add("/MT:$([int]$numThreads.Value)")
    }

    if ($chkNoProgress.Checked) {
        [void]$arguments.Add('/NP')
    }

    if ($chkTee.Checked) {
        [void]$arguments.Add('/TEE')
    }

    [void]$arguments.Add("/R:$([int]$numRetries.Value)")
    [void]$arguments.Add("/W:$([int]$numWait.Value)")

    foreach ($argument in Get-SelectedAdditionalArguments) {
        [void]$arguments.Add($argument)
    }

    $excludeFiles = Split-PatternText $txtExcludeFiles.Text
    if ($excludeFiles.Count -gt 0) {
        [void]$arguments.Add('/XF')
        foreach ($pattern in $excludeFiles) {
            [void]$arguments.Add($pattern)
        }
    }

    $excludeFolders = Split-PatternText $txtExcludeFolders.Text
    if ($excludeFolders.Count -gt 0) {
        [void]$arguments.Add('/XD')
        foreach ($pattern in $excludeFolders) {
            [void]$arguments.Add($pattern)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        [void]$arguments.Add("/LOG:$LogFile")
    }

    return @($arguments)
}

function Update-CommandPreview {
    if ($null -eq $txtCommandPreview) {
        return
    }

    $source = $txtSource.Text.Trim()
    $destination = $txtDestination.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = '<source>'
    }

    if ([string]::IsNullOrWhiteSpace($destination)) {
        $destination = '<destination>'
    }

    $arguments = New-RobocopyArguments -Source $source -Destination $destination -LogFile '<auto log file>' -ForcePreview:$false
    $txtCommandPreview.Text = 'robocopy.exe ' + (Join-CommandLineArguments -Arguments $arguments -AdvancedArguments $txtAdvanced.Text)
}

function Test-RunInput {
    $source = $txtSource.Text.Trim()
    $destination = $txtDestination.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($source)) {
        Show-ErrorMessage 'Select a source folder.'
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($destination)) {
        Show-ErrorMessage 'Select a destination folder.'
        return $false
    }

    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Show-ErrorMessage "Source folder not found:`r`n$source"
        return $false
    }

    try {
        $normalizedSource = Normalize-FolderPathForCompare $source
        $normalizedDestination = Normalize-FolderPathForCompare $destination
    } catch {
        Show-ErrorMessage "One of the selected folder paths is invalid.`r`n`r`n$($_.Exception.Message)"
        return $false
    }

    if ($normalizedSource -eq $normalizedDestination) {
        Show-ErrorMessage 'Source and destination cannot be the same folder.'
        return $false
    }

    if ((Test-IsNestedPath -ParentPath $source -ChildPath $destination) -or (Test-IsNestedPath -ParentPath $destination -ChildPath $source)) {
        Show-ErrorMessage 'Source and destination cannot be nested inside each other. Choose separate folder trees.'
        return $false
    }

    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        $destinationParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($destination))
        if ([string]::IsNullOrWhiteSpace($destinationParent) -or -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            Show-ErrorMessage "Destination parent folder not found:`r`n$destinationParent"
            return $false
        }
    }

    return $true
}

function Test-DestinationDestructiveOperation {
    if ((Get-SelectedMode) -eq 'Mirror') {
        return $true
    }

    if (Test-AdditionalOptionArgument '/PURGE') {
        return $true
    }

    return Test-AdvancedArgumentSwitch @('MIR', 'PURGE')
}

function Test-SourceDestructiveOperation {
    if ((Get-SelectedMode) -eq 'Move') {
        return $true
    }

    return Test-AdvancedArgumentSwitch @('MOVE', 'MOV')
}

function Limit-OutputText {
    if ($null -eq $txtOutput -or $txtOutput.IsDisposed) {
        return
    }

    if ($txtOutput.TextLength -le $script:MaxOutputCharacters) {
        return
    }

    $text = $txtOutput.Text
    $removeCount = $text.Length - $script:MaxOutputCharacters
    $startIndex = $removeCount
    $newlineIndex = $text.IndexOf([Environment]::NewLine, $removeCount)

    if ($newlineIndex -ge 0 -and $newlineIndex -lt ($removeCount + 5000)) {
        $startIndex = $newlineIndex + [Environment]::NewLine.Length
    }

    $txtOutput.Text = "[older output trimmed]$([Environment]::NewLine)$($text.Substring($startIndex))"
    $txtOutput.SelectionStart = $txtOutput.TextLength
    $txtOutput.ScrollToCaret()
}

function Add-OutputText {
    param([string]$Text)

    if ($null -eq $txtOutput) {
        return
    }

    if ([string]::IsNullOrEmpty($Text) -or $txtOutput.IsDisposed -or $txtOutput.InvokeRequired) {
        return
    }

    $normalizedText = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", [Environment]::NewLine)
    $txtOutput.AppendText($normalizedText)
    Limit-OutputText
    $txtOutput.SelectionStart = $txtOutput.TextLength
    $txtOutput.ScrollToCaret()
}

function Add-OutputLine {
    param([string]$Line)

    Add-OutputText ($Line + [Environment]::NewLine)
}

function Set-RobocopyProgressStatus {
    param(
        [string]$Status,
        [int]$Percent = -1,
        [bool]$UseMarquee = $false
    )

    if ($null -eq $prgRobocopy -or $prgRobocopy.IsDisposed) {
        return
    }

    if ($UseMarquee) {
        $prgRobocopy.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $prgRobocopy.MarqueeAnimationSpeed = 30
        $prgRobocopy.Value = 0
    } else {
        $prgRobocopy.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $prgRobocopy.MarqueeAnimationSpeed = 0

        if ($Percent -ge 0) {
            $boundedPercent = [Math]::Max(0, [Math]::Min(100, $Percent))
            $prgRobocopy.Value = $boundedPercent
        } else {
            $prgRobocopy.Value = 0
        }
    }

    if ($null -ne $lblProgress -and -not $lblProgress.IsDisposed) {
        if ($Percent -ge 0) {
            $lblProgress.Text = "${Status}: $([Math]::Max(0, [Math]::Min(100, $Percent)))%"
        } else {
            $lblProgress.Text = $Status
        }
    }
}

function Update-RobocopyProgressFromText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    foreach ($match in [regex]::Matches($Text, '(?<!\d)(100(?:\.0)?|[1-9]?\d(?:\.\d)?)\s*%')) {
        $percentValue = [double]::Parse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        $percent = [int][Math]::Round($percentValue)

        if ($percent -ne $script:LastProgressPercent) {
            $script:LastProgressPercent = $percent
            Set-RobocopyProgressStatus -Status 'Current file progress' -Percent $percent
        }
    }
}

function Read-RobocopyLogUpdates {
    if ([string]::IsNullOrWhiteSpace($script:CurrentLogFile) -or -not (Test-Path -LiteralPath $script:CurrentLogFile -PathType Leaf)) {
        return
    }

    $stream = $null
    $reader = $null

    try {
        $stream = [System.IO.File]::Open($script:CurrentLogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)

        if ($script:LogReadOffset -gt $stream.Length) {
            $script:LogReadOffset = [int64]0
        }

        [void]$stream.Seek($script:LogReadOffset, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($stream, [System.Text.Encoding]::Default, $true)
        $text = $reader.ReadToEnd()
        $script:LogReadOffset = $stream.Position
    } catch {
        return
    } finally {
        if ($reader) {
            $reader.Dispose()
        } elseif ($stream) {
            $stream.Dispose()
        }
    }

    if (-not [string]::IsNullOrEmpty($text)) {
        Update-RobocopyProgressFromText $text
        Add-OutputText $text
    }
}

function Poll-RobocopyRun {
    Read-RobocopyLogUpdates

    if ($script:CurrentProcess -and $script:CurrentProcess.HasExited -and -not $script:RunCompletionHandled) {
        $script:RunCompletionHandled = $true
        $exitCode = $script:CurrentProcess.ExitCode
        Read-RobocopyLogUpdates
        Complete-RobocopyRun $exitCode
    }
}

function Set-RunState {
    param([bool]$IsRunning)

    $btnRun.Enabled = -not $IsRunning
    $btnPreview.Enabled = -not $IsRunning
    $btnCancel.Enabled = $IsRunning
    $btnSaveSettings.Enabled = -not $IsRunning
    $btnLoadSettings.Enabled = -not $IsRunning
    $btnSaveOperation.Enabled = -not $IsRunning
    $btnLoadOperation.Enabled = -not $IsRunning
}

function Complete-RobocopyRun {
    param([int]$ExitCode)

    if ($script:LogPollTimer) {
        $script:LogPollTimer.Stop()
    }

    Read-RobocopyLogUpdates

    if ($script:RunWasCancelled) {
        Add-OutputLine "Robocopy was cancelled. Exit code: $ExitCode"
        if ($script:LastProgressPercent -ge 0) {
            Set-RobocopyProgressStatus -Status 'Cancelled. Last file progress' -Percent $script:LastProgressPercent
        } else {
            Set-RobocopyProgressStatus -Status 'Cancelled'
        }
    } elseif ($ExitCode -le 7) {
        Add-OutputLine "Robocopy completed successfully. Exit code: $ExitCode"
        if ($script:LastProgressPercent -ge 0) {
            Set-RobocopyProgressStatus -Status 'Completed' -Percent 100
        } else {
            Set-RobocopyProgressStatus -Status 'Completed'
        }
    } else {
        Add-OutputLine "Robocopy failed. Exit code: $ExitCode"
        if ($script:LastProgressPercent -ge 0) {
            Set-RobocopyProgressStatus -Status "Failed. Last file progress" -Percent $script:LastProgressPercent
        } else {
            Set-RobocopyProgressStatus -Status "Failed. Exit code $ExitCode"
        }
    }

    if ($script:CurrentLogFile) {
        Add-OutputLine "Log file: $script:CurrentLogFile"
    }

    if ($script:CurrentProcess) {
        $script:CurrentProcess.Dispose()
        $script:CurrentProcess = $null
    }

    Set-RunState $false
}

function Start-RobocopyRun {
    param([bool]$ForcePreview)

    if (-not (Test-RunInput)) {
        return
    }

    $isPreview = $ForcePreview -or $chkPreview.Checked

    if (-not $isPreview -and (Test-DestinationDestructiveOperation)) {
        $message = "This operation can delete files or folders from the destination that are not present in the source.`r`n`r`nSource:`r`n$($txtSource.Text.Trim())`r`n`r`nDestination:`r`n$($txtDestination.Text.Trim())`r`n`r`nContinue?"
        if (-not (Show-ConfirmMessage $message)) {
            return
        }
    }

    if (-not $isPreview -and (Test-SourceDestructiveOperation)) {
        $message = "This operation can delete files or folders from the source after they are copied successfully.`r`n`r`nSource:`r`n$($txtSource.Text.Trim())`r`n`r`nDestination:`r`n$($txtDestination.Text.Trim())`r`n`r`nContinue?"
        if (-not (Show-ConfirmMessage $message)) {
            return
        }
    }

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $LogDirectory | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $mode = Get-SelectedMode
    $script:CurrentLogFile = Join-Path $LogDirectory "Robocopy-$mode-$timestamp.log"

    $arguments = New-RobocopyArguments -Source $txtSource.Text.Trim() -Destination $txtDestination.Text.Trim() -LogFile $script:CurrentLogFile -ForcePreview:$ForcePreview
    $argumentText = Join-CommandLineArguments -Arguments $arguments -AdvancedArguments $txtAdvanced.Text

    $txtOutput.Clear()
    Add-OutputLine "Starting robocopy at $(Get-Date)."
    Add-OutputLine "Mode: $mode"
    if ($isPreview) {
        Add-OutputLine 'Preview mode is enabled. No files should be copied or deleted.'
    }

    Add-OutputLine "Command: robocopy.exe $argumentText"
    Add-OutputLine ''

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = 'robocopy.exe'
    $processInfo.Arguments = $argumentText
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $false
    $processInfo.RedirectStandardError = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.EnableRaisingEvents = $false

    try {
        $script:LogReadOffset = [int64]0
        $script:RunWasCancelled = $false
        $script:RunCompletionHandled = $false
        $script:LastProgressPercent = -1

        Set-RunState $true
        if ($chkNoProgress.Checked) {
            Set-RobocopyProgressStatus -Status 'Running. Progress hidden by /NP' -UseMarquee:$true
        } else {
            Set-RobocopyProgressStatus -Status 'Starting. Waiting for progress'
        }

        $script:CurrentProcess = $process
        [void]$process.Start()
        if ($script:LogPollTimer) {
            $script:LogPollTimer.Start()
        }
    } catch {
        if ($script:LogPollTimer) {
            $script:LogPollTimer.Stop()
        }

        Set-RunState $false
        $script:CurrentProcess = $null
        Set-RobocopyProgressStatus -Status 'Could not start robocopy'
        $process.Dispose()
        Show-ErrorMessage "Could not start robocopy.`r`n`r`n$($_.Exception.Message)"
    }
}

function Get-CurrentSettings {
    param([bool]$IncludePaths)

    $additionalOptions = @()
    foreach ($item in $lstAdditional.Items) {
        $additionalOptions += $item.Label
    }

    $settings = [ordered]@{
        Version = 1
        Mode = Get-SelectedMode
        Preview = [bool]$chkPreview.Checked
        IncludeEmpty = [bool]$chkIncludeEmpty.Checked
        ExcludeJunctions = [bool]$chkExcludeJunctions.Checked
        Restartable = [bool]$chkRestartable.Checked
        MultiThread = [bool]$chkMultiThread.Checked
        Threads = [int]$numThreads.Value
        NoProgress = [bool]$chkNoProgress.Checked
        TeeOutput = [bool]$chkTee.Checked
        Retries = [int]$numRetries.Value
        WaitSeconds = [int]$numWait.Value
        ExcludeFiles = $txtExcludeFiles.Text
        ExcludeFolders = $txtExcludeFolders.Text
        AdditionalOptions = $additionalOptions
        AdvancedArguments = $txtAdvanced.Text
    }

    if ($IncludePaths) {
        $settings['Source'] = $txtSource.Text
        $settings['Destination'] = $txtDestination.Text
    }

    return [pscustomobject]$settings
}

function Set-CurrentSettings {
    param(
        [psobject]$Settings,
        [bool]$IncludePaths
    )

    if ($null -eq $Settings) {
        return
    }

    if ($IncludePaths) {
        if ($null -ne $Settings.Source) { $txtSource.Text = [string]$Settings.Source }
        if ($null -ne $Settings.Destination) { $txtDestination.Text = [string]$Settings.Destination }
    }

    if ($null -ne $Settings.Mode) { Set-SelectedMode ([string]$Settings.Mode) }
    if ($null -ne $Settings.Preview) { $chkPreview.Checked = [bool]$Settings.Preview }
    if ($null -ne $Settings.IncludeEmpty) { $chkIncludeEmpty.Checked = [bool]$Settings.IncludeEmpty }
    if ($null -ne $Settings.ExcludeJunctions) { $chkExcludeJunctions.Checked = [bool]$Settings.ExcludeJunctions }
    if ($null -ne $Settings.Restartable) { $chkRestartable.Checked = [bool]$Settings.Restartable }
    if ($null -ne $Settings.MultiThread) { $chkMultiThread.Checked = [bool]$Settings.MultiThread }
    if ($null -ne $Settings.Threads) { $numThreads.Value = [decimal]$Settings.Threads }
    if ($null -ne $Settings.NoProgress) { $chkNoProgress.Checked = [bool]$Settings.NoProgress }
    if ($null -ne $Settings.TeeOutput) { $chkTee.Checked = [bool]$Settings.TeeOutput }
    if ($null -ne $Settings.Retries) { $numRetries.Value = [decimal]$Settings.Retries }
    if ($null -ne $Settings.WaitSeconds) { $numWait.Value = [decimal]$Settings.WaitSeconds }
    if ($null -ne $Settings.ExcludeFiles) { $txtExcludeFiles.Text = [string]$Settings.ExcludeFiles }
    if ($null -ne $Settings.ExcludeFolders) { $txtExcludeFolders.Text = [string]$Settings.ExcludeFolders }
    if ($null -ne $Settings.AdvancedArguments) { $txtAdvanced.Text = [string]$Settings.AdvancedArguments }

    $lstAdditional.Items.Clear()
    foreach ($label in @($Settings.AdditionalOptions)) {
        $option = $script:AdditionalOptionCatalog | Where-Object { $_.Label -eq $label } | Select-Object -First 1
        if ($option) {
            Add-AdditionalOption $option
        }
    }

    $numThreads.Enabled = $chkMultiThread.Checked
    Update-CommandPreview
}

function Read-JsonFile {
    param(
        [string]$Path,
        [object]$DefaultValue
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $DefaultValue
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Show-ErrorMessage "Could not read JSON file:`r`n$Path`r`n`r`n$($_.Exception.Message)"
        return $DefaultValue
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Show-InputDialog {
    param(
        [string]$Title,
        [string]$Prompt,
        [string]$DefaultValue = ''
    )

    $inputForm = New-Object System.Windows.Forms.Form
    $inputForm.Text = $Title
    $inputForm.Size = New-Object System.Drawing.Size(420, 160)
    $inputForm.StartPosition = 'CenterParent'
    $inputForm.FormBorderStyle = 'FixedDialog'
    $inputForm.MaximizeBox = $false
    $inputForm.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size = New-Object System.Drawing.Size(380, 20)
    $inputForm.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(12, 38)
    $textBox.Size = New-Object System.Drawing.Size(380, 24)
    $textBox.Text = $DefaultValue
    $inputForm.Controls.Add($textBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(236, 78)
    $okButton.Size = New-Object System.Drawing.Size(75, 28)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $inputForm.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(317, 78)
    $cancelButton.Size = New-Object System.Drawing.Size(75, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $inputForm.Controls.Add($cancelButton)

    $inputForm.AcceptButton = $okButton
    $inputForm.CancelButton = $cancelButton

    $result = $inputForm.ShowDialog($form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text.Trim()
    }

    return $null
}

function Show-OperationPicker {
    param([object[]]$Operations)

    $pickerForm = New-Object System.Windows.Forms.Form
    $pickerForm.Text = 'Load Operation'
    $pickerForm.Size = New-Object System.Drawing.Size(480, 360)
    $pickerForm.StartPosition = 'CenterParent'
    $pickerForm.FormBorderStyle = 'FixedDialog'
    $pickerForm.MaximizeBox = $false
    $pickerForm.MinimizeBox = $false

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = New-Object System.Drawing.Point(12, 12)
    $listBox.Size = New-Object System.Drawing.Size(440, 250)
    $listBox.DisplayMember = 'Name'
    [void]$listBox.Items.AddRange($Operations)
    $pickerForm.Controls.Add($listBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'Load'
    $okButton.Location = New-Object System.Drawing.Point(296, 278)
    $okButton.Size = New-Object System.Drawing.Size(75, 28)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $pickerForm.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(377, 278)
    $cancelButton.Size = New-Object System.Drawing.Size(75, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $pickerForm.Controls.Add($cancelButton)

    $pickerForm.AcceptButton = $okButton
    $pickerForm.CancelButton = $cancelButton

    if ($listBox.Items.Count -gt 0) {
        $listBox.SelectedIndex = 0
    }

    $result = $pickerForm.ShowDialog($form)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $listBox.SelectedItem) {
        return $listBox.SelectedItem
    }

    return $null
}

function Save-SettingsFile {
    Write-JsonFile -Path $SettingsFile -Value (Get-CurrentSettings -IncludePaths:$false)
    Show-InfoMessage "Settings saved:`r`n$SettingsFile"
}

function Load-SettingsFile {
    $settings = Read-JsonFile -Path $SettingsFile -DefaultValue $null
    if ($null -eq $settings) {
        Show-InfoMessage "No settings file found:`r`n$SettingsFile"
        return
    }

    Set-CurrentSettings -Settings $settings -IncludePaths:$false
    Show-InfoMessage 'Settings loaded.'
}

function Save-OperationFile {
    $defaultName = if (-not [string]::IsNullOrWhiteSpace($txtSource.Text)) { Split-Path -Leaf $txtSource.Text.Trim() } else { 'New Operation' }
    $operationName = Show-InputDialog -Title 'Save Operation' -Prompt 'Operation name:' -DefaultValue $defaultName

    if ([string]::IsNullOrWhiteSpace($operationName)) {
        return
    }

    $data = Read-JsonFile -Path $OperationsFile -DefaultValue ([pscustomobject]@{ Version = 1; Operations = @() })
    $operations = @($data.Operations | Where-Object { $_.Name -ne $operationName })
    $operation = Get-CurrentSettings -IncludePaths:$true
    $operation | Add-Member -NotePropertyName Name -NotePropertyValue $operationName -Force
    $operation | Add-Member -NotePropertyName SavedAt -NotePropertyValue (Get-Date).ToString('s') -Force
    $operations += $operation

    $payload = [pscustomobject]@{
        Version = 1
        Operations = @($operations | Sort-Object Name)
    }

    Write-JsonFile -Path $OperationsFile -Value $payload
    Show-InfoMessage "Operation saved:`r`n$operationName"
}

function Load-OperationFile {
    $data = Read-JsonFile -Path $OperationsFile -DefaultValue ([pscustomobject]@{ Version = 1; Operations = @() })
    $operations = @($data.Operations)

    if ($operations.Count -eq 0) {
        Show-InfoMessage "No saved operations found:`r`n$OperationsFile"
        return
    }

    $operation = Show-OperationPicker -Operations $operations
    if ($null -eq $operation) {
        return
    }

    Set-CurrentSettings -Settings $operation -IncludePaths:$true
    Show-InfoMessage "Operation loaded:`r`n$($operation.Name)"
}

function Select-FolderForTextBox {
    param([System.Windows.Forms.TextBox]$TextBox)

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select folder'

    if (-not [string]::IsNullOrWhiteSpace($TextBox.Text) -and (Test-Path -LiteralPath $TextBox.Text -PathType Container)) {
        $dialog.SelectedPath = $TextBox.Text
    }

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextBox.Text = $dialog.SelectedPath
    }

    $dialog.Dispose()
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Robocopy GUI'
$form.Size = New-Object System.Drawing.Size(1080, 880)
$form.MinimumSize = New-Object System.Drawing.Size(1080, 880)
$form.StartPosition = 'CenterScreen'

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.InitialDelay = 500
$toolTip.ReshowDelay = 200
$toolTip.AutoPopDelay = 15000
$toolTip.ShowAlways = $true

$grpFolders = New-Object System.Windows.Forms.GroupBox
$grpFolders.Text = 'Folders'
$grpFolders.Location = New-Object System.Drawing.Point(10, 10)
$grpFolders.Size = New-Object System.Drawing.Size(1045, 115)
$form.Controls.Add($grpFolders)

$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = 'Source'
$lblSource.Location = New-Object System.Drawing.Point(15, 28)
$lblSource.Size = New-Object System.Drawing.Size(85, 20)
$grpFolders.Controls.Add($lblSource)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Location = New-Object System.Drawing.Point(100, 25)
$txtSource.Size = New-Object System.Drawing.Size(815, 24)
$grpFolders.Controls.Add($txtSource)

$btnBrowseSource = New-Object System.Windows.Forms.Button
$btnBrowseSource.Text = 'Browse'
$btnBrowseSource.Location = New-Object System.Drawing.Point(925, 23)
$btnBrowseSource.Size = New-Object System.Drawing.Size(95, 28)
$grpFolders.Controls.Add($btnBrowseSource)

$lblDestination = New-Object System.Windows.Forms.Label
$lblDestination.Text = 'Destination'
$lblDestination.Location = New-Object System.Drawing.Point(15, 68)
$lblDestination.Size = New-Object System.Drawing.Size(85, 20)
$grpFolders.Controls.Add($lblDestination)

$txtDestination = New-Object System.Windows.Forms.TextBox
$txtDestination.Location = New-Object System.Drawing.Point(100, 65)
$txtDestination.Size = New-Object System.Drawing.Size(815, 24)
$grpFolders.Controls.Add($txtDestination)

$btnBrowseDestination = New-Object System.Windows.Forms.Button
$btnBrowseDestination.Text = 'Browse'
$btnBrowseDestination.Location = New-Object System.Drawing.Point(925, 63)
$btnBrowseDestination.Size = New-Object System.Drawing.Size(95, 28)
$grpFolders.Controls.Add($btnBrowseDestination)

$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'Mode'
$grpMode.Location = New-Object System.Drawing.Point(10, 135)
$grpMode.Size = New-Object System.Drawing.Size(280, 130)
$form.Controls.Add($grpMode)

$rdoCopy = New-Object System.Windows.Forms.RadioButton
$rdoCopy.Text = 'Copy'
$rdoCopy.Location = New-Object System.Drawing.Point(15, 28)
$rdoCopy.Size = New-Object System.Drawing.Size(240, 24)
$rdoCopy.Checked = $true
$grpMode.Controls.Add($rdoCopy)

$rdoMirror = New-Object System.Windows.Forms.RadioButton
$rdoMirror.Text = 'Mirror'
$rdoMirror.Location = New-Object System.Drawing.Point(15, 60)
$rdoMirror.Size = New-Object System.Drawing.Size(240, 24)
$grpMode.Controls.Add($rdoMirror)

$rdoMove = New-Object System.Windows.Forms.RadioButton
$rdoMove.Text = 'Move'
$rdoMove.Location = New-Object System.Drawing.Point(15, 92)
$rdoMove.Size = New-Object System.Drawing.Size(240, 24)
$grpMode.Controls.Add($rdoMove)

$grpCommon = New-Object System.Windows.Forms.GroupBox
$grpCommon.Text = 'Common Options'
$grpCommon.Location = New-Object System.Drawing.Point(300, 135)
$grpCommon.Size = New-Object System.Drawing.Size(755, 130)
$form.Controls.Add($grpCommon)

$chkPreview = New-Object System.Windows.Forms.CheckBox
$chkPreview.Text = 'Preview only (/L)'
$chkPreview.Location = New-Object System.Drawing.Point(15, 25)
$chkPreview.Size = New-Object System.Drawing.Size(145, 24)
$grpCommon.Controls.Add($chkPreview)

$chkIncludeEmpty = New-Object System.Windows.Forms.CheckBox
$chkIncludeEmpty.Text = 'Include empty folders (/E)'
$chkIncludeEmpty.Location = New-Object System.Drawing.Point(170, 25)
$chkIncludeEmpty.Size = New-Object System.Drawing.Size(180, 24)
$chkIncludeEmpty.Checked = $true
$grpCommon.Controls.Add($chkIncludeEmpty)

$chkExcludeJunctions = New-Object System.Windows.Forms.CheckBox
$chkExcludeJunctions.Text = 'Exclude junctions (/XJ)'
$chkExcludeJunctions.Location = New-Object System.Drawing.Point(365, 25)
$chkExcludeJunctions.Size = New-Object System.Drawing.Size(165, 24)
$chkExcludeJunctions.Checked = $true
$grpCommon.Controls.Add($chkExcludeJunctions)

$chkRestartable = New-Object System.Windows.Forms.CheckBox
$chkRestartable.Text = 'Restartable (/Z)'
$chkRestartable.Location = New-Object System.Drawing.Point(545, 25)
$chkRestartable.Size = New-Object System.Drawing.Size(140, 24)
$grpCommon.Controls.Add($chkRestartable)

$chkMultiThread = New-Object System.Windows.Forms.CheckBox
$chkMultiThread.Text = 'Multi-thread (/MT)'
$chkMultiThread.Location = New-Object System.Drawing.Point(15, 60)
$chkMultiThread.Size = New-Object System.Drawing.Size(140, 24)
$chkMultiThread.Checked = $true
$grpCommon.Controls.Add($chkMultiThread)

$numThreads = New-Object System.Windows.Forms.NumericUpDown
$numThreads.Location = New-Object System.Drawing.Point(155, 60)
$numThreads.Size = New-Object System.Drawing.Size(65, 24)
$numThreads.Minimum = 1
$numThreads.Maximum = 128
$numThreads.Value = 8
$grpCommon.Controls.Add($numThreads)

$chkNoProgress = New-Object System.Windows.Forms.CheckBox
$chkNoProgress.Text = 'No progress (/NP)'
$chkNoProgress.Location = New-Object System.Drawing.Point(240, 60)
$chkNoProgress.Size = New-Object System.Drawing.Size(140, 24)
$chkNoProgress.Checked = $false
$grpCommon.Controls.Add($chkNoProgress)

$chkTee = New-Object System.Windows.Forms.CheckBox
$chkTee.Text = 'Tee output (/TEE)'
$chkTee.Location = New-Object System.Drawing.Point(395, 60)
$chkTee.Size = New-Object System.Drawing.Size(145, 24)
$chkTee.Checked = $true
$grpCommon.Controls.Add($chkTee)

$lblRetries = New-Object System.Windows.Forms.Label
$lblRetries.Text = 'Retries (/R)'
$lblRetries.Location = New-Object System.Drawing.Point(15, 98)
$lblRetries.Size = New-Object System.Drawing.Size(75, 20)
$grpCommon.Controls.Add($lblRetries)

$numRetries = New-Object System.Windows.Forms.NumericUpDown
$numRetries.Location = New-Object System.Drawing.Point(95, 95)
$numRetries.Size = New-Object System.Drawing.Size(65, 24)
$numRetries.Minimum = 0
$numRetries.Maximum = 999
$numRetries.Value = 3
$grpCommon.Controls.Add($numRetries)

$lblWait = New-Object System.Windows.Forms.Label
$lblWait.Text = 'Wait sec (/W)'
$lblWait.Location = New-Object System.Drawing.Point(185, 98)
$lblWait.Size = New-Object System.Drawing.Size(90, 20)
$grpCommon.Controls.Add($lblWait)

$numWait = New-Object System.Windows.Forms.NumericUpDown
$numWait.Location = New-Object System.Drawing.Point(280, 95)
$numWait.Size = New-Object System.Drawing.Size(65, 24)
$numWait.Minimum = 0
$numWait.Maximum = 999
$numWait.Value = 10
$grpCommon.Controls.Add($numWait)

$grpAdditional = New-Object System.Windows.Forms.GroupBox
$grpAdditional.Text = 'Additional Options'
$grpAdditional.Location = New-Object System.Drawing.Point(10, 275)
$grpAdditional.Size = New-Object System.Drawing.Size(1045, 175)
$form.Controls.Add($grpAdditional)

$cmbAdditional = New-Object System.Windows.Forms.ComboBox
$cmbAdditional.Location = New-Object System.Drawing.Point(15, 28)
$cmbAdditional.Size = New-Object System.Drawing.Size(360, 24)
$cmbAdditional.DropDownStyle = 'DropDownList'
$cmbAdditional.DisplayMember = 'Label'
[void]$cmbAdditional.Items.AddRange([object[]]$script:AdditionalOptionCatalog)
$cmbAdditional.SelectedIndex = 0
$grpAdditional.Controls.Add($cmbAdditional)

$btnAddAdditional = New-Object System.Windows.Forms.Button
$btnAddAdditional.Text = 'Add Option'
$btnAddAdditional.Location = New-Object System.Drawing.Point(385, 26)
$btnAddAdditional.Size = New-Object System.Drawing.Size(105, 28)
$grpAdditional.Controls.Add($btnAddAdditional)

$btnRemoveAdditional = New-Object System.Windows.Forms.Button
$btnRemoveAdditional.Text = 'Remove'
$btnRemoveAdditional.Location = New-Object System.Drawing.Point(500, 26)
$btnRemoveAdditional.Size = New-Object System.Drawing.Size(90, 28)
$grpAdditional.Controls.Add($btnRemoveAdditional)

$lblAdditionalDescription = New-Object System.Windows.Forms.Label
$lblAdditionalDescription.Location = New-Object System.Drawing.Point(610, 28)
$lblAdditionalDescription.Size = New-Object System.Drawing.Size(410, 44)
$lblAdditionalDescription.Text = $cmbAdditional.SelectedItem.Description
$grpAdditional.Controls.Add($lblAdditionalDescription)

$lstAdditional = New-Object System.Windows.Forms.ListBox
$lstAdditional.Location = New-Object System.Drawing.Point(15, 64)
$lstAdditional.Size = New-Object System.Drawing.Size(575, 95)
$lstAdditional.DisplayMember = 'Label'
$grpAdditional.Controls.Add($lstAdditional)

$lblExcludeFiles = New-Object System.Windows.Forms.Label
$lblExcludeFiles.Text = 'Exclude files (/XF)'
$lblExcludeFiles.Location = New-Object System.Drawing.Point(610, 82)
$lblExcludeFiles.Size = New-Object System.Drawing.Size(130, 20)
$grpAdditional.Controls.Add($lblExcludeFiles)

$txtExcludeFiles = New-Object System.Windows.Forms.TextBox
$txtExcludeFiles.Location = New-Object System.Drawing.Point(750, 79)
$txtExcludeFiles.Size = New-Object System.Drawing.Size(270, 24)
$grpAdditional.Controls.Add($txtExcludeFiles)

$lblExcludeFolders = New-Object System.Windows.Forms.Label
$lblExcludeFolders.Text = 'Exclude folders (/XD)'
$lblExcludeFolders.Location = New-Object System.Drawing.Point(610, 122)
$lblExcludeFolders.Size = New-Object System.Drawing.Size(130, 20)
$grpAdditional.Controls.Add($lblExcludeFolders)

$txtExcludeFolders = New-Object System.Windows.Forms.TextBox
$txtExcludeFolders.Location = New-Object System.Drawing.Point(750, 119)
$txtExcludeFolders.Size = New-Object System.Drawing.Size(270, 24)
$grpAdditional.Controls.Add($txtExcludeFolders)

$grpAdvanced = New-Object System.Windows.Forms.GroupBox
$grpAdvanced.Text = 'Advanced Arguments'
$grpAdvanced.Location = New-Object System.Drawing.Point(10, 460)
$grpAdvanced.Size = New-Object System.Drawing.Size(1045, 80)
$form.Controls.Add($grpAdvanced)

$txtAdvanced = New-Object System.Windows.Forms.TextBox
$txtAdvanced.Location = New-Object System.Drawing.Point(15, 28)
$txtAdvanced.Size = New-Object System.Drawing.Size(1005, 24)
$grpAdvanced.Controls.Add($txtAdvanced)

$grpCommand = New-Object System.Windows.Forms.GroupBox
$grpCommand.Text = 'Generated Command'
$grpCommand.Location = New-Object System.Drawing.Point(10, 550)
$grpCommand.Size = New-Object System.Drawing.Size(1045, 85)
$form.Controls.Add($grpCommand)

$txtCommandPreview = New-Object System.Windows.Forms.TextBox
$txtCommandPreview.Location = New-Object System.Drawing.Point(15, 25)
$txtCommandPreview.Size = New-Object System.Drawing.Size(1005, 45)
$txtCommandPreview.Multiline = $true
$txtCommandPreview.ReadOnly = $true
$txtCommandPreview.ScrollBars = 'Vertical'
$grpCommand.Controls.Add($txtCommandPreview)

$grpOutput = New-Object System.Windows.Forms.GroupBox
$grpOutput.Text = 'Output'
$grpOutput.Location = New-Object System.Drawing.Point(10, 645)
$grpOutput.Size = New-Object System.Drawing.Size(1045, 140)
$form.Controls.Add($grpOutput)

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = 'Progress: idle'
$lblProgress.Location = New-Object System.Drawing.Point(15, 26)
$lblProgress.Size = New-Object System.Drawing.Size(220, 20)
$grpOutput.Controls.Add($lblProgress)

$prgRobocopy = New-Object System.Windows.Forms.ProgressBar
$prgRobocopy.Location = New-Object System.Drawing.Point(245, 24)
$prgRobocopy.Size = New-Object System.Drawing.Size(775, 22)
$prgRobocopy.Minimum = 0
$prgRobocopy.Maximum = 100
$prgRobocopy.Value = 0
$prgRobocopy.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$grpOutput.Controls.Add($prgRobocopy)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = New-Object System.Drawing.Point(15, 55)
$txtOutput.Size = New-Object System.Drawing.Size(1005, 70)
$txtOutput.Multiline = $true
$txtOutput.ReadOnly = $true
$txtOutput.ScrollBars = 'Vertical'
$grpOutput.Controls.Add($txtOutput)

$btnSaveSettings = New-Object System.Windows.Forms.Button
$btnSaveSettings.Text = 'Save Settings'
$btnSaveSettings.Location = New-Object System.Drawing.Point(10, 800)
$btnSaveSettings.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($btnSaveSettings)

$btnLoadSettings = New-Object System.Windows.Forms.Button
$btnLoadSettings.Text = 'Load Settings'
$btnLoadSettings.Location = New-Object System.Drawing.Point(130, 800)
$btnLoadSettings.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($btnLoadSettings)

$btnSaveOperation = New-Object System.Windows.Forms.Button
$btnSaveOperation.Text = 'Save Operation'
$btnSaveOperation.Location = New-Object System.Drawing.Point(250, 800)
$btnSaveOperation.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnSaveOperation)

$btnLoadOperation = New-Object System.Windows.Forms.Button
$btnLoadOperation.Text = 'Load Operation'
$btnLoadOperation.Location = New-Object System.Drawing.Point(380, 800)
$btnLoadOperation.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnLoadOperation)

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = 'Open Logs'
$btnOpenLogs.Location = New-Object System.Drawing.Point(510, 800)
$btnOpenLogs.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnOpenLogs)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = 'Preview'
$btnPreview.Location = New-Object System.Drawing.Point(675, 800)
$btnPreview.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($btnPreview)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run'
$btnRun.Location = New-Object System.Drawing.Point(775, 800)
$btnRun.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($btnRun)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(875, 800)
$btnCancel.Size = New-Object System.Drawing.Size(90, 30)
$btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(975, 800)
$btnClose.Size = New-Object System.Drawing.Size(80, 30)
$form.Controls.Add($btnClose)

$toolTip.SetToolTip($txtSource, 'Folder robocopy reads from. Copy and Mirror do not change this folder. Move can delete from this folder after successful copy.')
$toolTip.SetToolTip($txtDestination, 'Folder robocopy writes to. Mirror and /PURGE can delete files here that are not in the source.')
$toolTip.SetToolTip($btnBrowseSource, 'Pick the source folder.')
$toolTip.SetToolTip($btnBrowseDestination, 'Pick the destination folder.')
$toolTip.SetToolTip($rdoCopy, 'Copies source files and folders to the destination. Does not delete source or destination extras.')
$toolTip.SetToolTip($rdoMirror, 'Uses /MIR. Makes destination match source and deletes destination extras.')
$toolTip.SetToolTip($rdoMove, 'Uses /MOVE. Copies files and folders, then deletes them from the source after successful copy.')
$toolTip.SetToolTip($chkPreview, 'Adds /L. Lists what would happen without copying, moving, or deleting files.')
$toolTip.SetToolTip($chkIncludeEmpty, 'Adds /E. Includes subfolders, including empty folders. If unchecked, /S copies subfolders but skips empty folders.')
$toolTip.SetToolTip($chkExcludeJunctions, 'Adds /XJ. Avoids following junction points that can cause unexpected recursion or extra copying.')
$toolTip.SetToolTip($chkRestartable, 'Adds /Z. Allows interrupted file copies to restart, at some performance cost.')
$toolTip.SetToolTip($chkMultiThread, 'Adds /MT:n. Copies with multiple threads. Higher values can improve speed but increase disk and network load.')
$toolTip.SetToolTip($numThreads, 'Thread count for /MT. Robocopy allows values from 1 to 128.')
$toolTip.SetToolTip($chkNoProgress, 'Adds /NP. Hides percentage progress and disables percentage updates in the GUI.')
$toolTip.SetToolTip($chkTee, 'Adds /TEE. Robocopy also writes to a console if available; the GUI reads live output from the log file.')
$toolTip.SetToolTip($numRetries, 'Retry count for failed copies. This script defaults to 3 instead of robocopy default 1,000,000.')
$toolTip.SetToolTip($numWait, 'Seconds to wait between retries. This script defaults to 10 instead of robocopy default 30.')
$toolTip.SetToolTip($cmbAdditional, $cmbAdditional.SelectedItem.Description)
$toolTip.SetToolTip($btnAddAdditional, 'Adds the selected dropdown option to this operation.')
$toolTip.SetToolTip($btnRemoveAdditional, 'Removes the selected additional option from this operation.')
$toolTip.SetToolTip($lstAdditional, 'Additional robocopy options currently selected for this operation.')
$toolTip.SetToolTip($txtExcludeFiles, 'Optional /XF patterns separated by commas, semicolons, or new lines. Example: *.tmp; thumbs.db')
$toolTip.SetToolTip($txtExcludeFolders, 'Optional /XD folder names or paths separated by commas, semicolons, or new lines. Example: node_modules; .git')
$toolTip.SetToolTip($txtAdvanced, 'Raw robocopy switches appended after generated options. Advanced options can override earlier generated switches.')
$toolTip.SetToolTip($txtCommandPreview, 'Generated command preview. Advanced arguments are appended at the end.')
$toolTip.SetToolTip($lblProgress, 'Shows robocopy current-file progress when /NP is not used. Robocopy does not expose total job progress.')
$toolTip.SetToolTip($prgRobocopy, 'Shows robocopy current-file progress when /NP is not used. Robocopy does not expose total job progress.')
$toolTip.SetToolTip($btnSaveSettings, 'Saves option choices only. Folder paths are not saved here.')
$toolTip.SetToolTip($btnLoadSettings, 'Loads option choices from RobocopyGui.settings.json.')
$toolTip.SetToolTip($btnSaveOperation, 'Saves source, destination, mode, options, and advanced arguments as a named operation.')
$toolTip.SetToolTip($btnLoadOperation, 'Loads a previously saved named operation.')
$toolTip.SetToolTip($btnOpenLogs, 'Opens the logs folder created next to this script.')
$toolTip.SetToolTip($btnPreview, 'Runs robocopy with /L to preview changes without copying, moving, or deleting.')
$toolTip.SetToolTip($btnRun, 'Runs the generated robocopy command.')
$toolTip.SetToolTip($btnCancel, 'Stops the running robocopy process.')
$toolTip.SetToolTip($btnClose, 'Closes the GUI.')

$script:LogPollTimer = New-Object System.Windows.Forms.Timer
$script:LogPollTimer.Interval = 500
$script:LogPollTimer.Add_Tick({ Poll-RobocopyRun })

$btnBrowseSource.Add_Click({ Select-FolderForTextBox $txtSource })
$btnBrowseDestination.Add_Click({ Select-FolderForTextBox $txtDestination })
$btnAddAdditional.Add_Click({ Add-AdditionalOption $cmbAdditional.SelectedItem; Update-CommandPreview })
$btnRemoveAdditional.Add_Click({ if ($lstAdditional.SelectedIndex -ge 0) { $lstAdditional.Items.RemoveAt($lstAdditional.SelectedIndex); Update-CommandPreview } })
$btnPreview.Add_Click({ Start-RobocopyRun -ForcePreview:$true })
$btnRun.Add_Click({ Start-RobocopyRun -ForcePreview:$false })
$btnCancel.Add_Click({
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $script:RunWasCancelled = $true
        Set-RobocopyProgressStatus -Status 'Cancelling robocopy'

        try {
            $script:CurrentProcess.Kill()
            Add-OutputLine 'Cancel requested. Robocopy process was terminated.'
        } catch {
            Add-OutputLine "Cancel failed: $($_.Exception.Message)"
        }
    }
})
$btnSaveSettings.Add_Click({ Save-SettingsFile })
$btnLoadSettings.Add_Click({ Load-SettingsFile })
$btnSaveOperation.Add_Click({ Save-OperationFile })
$btnLoadOperation.Add_Click({ Load-OperationFile })
$btnOpenLogs.Add_Click({
    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $LogDirectory | Out-Null
    }

    Start-Process -FilePath $LogDirectory | Out-Null
})
$btnClose.Add_Click({ $form.Close() })

$cmbAdditional.Add_SelectedIndexChanged({
    if ($cmbAdditional.SelectedItem) {
        $lblAdditionalDescription.Text = $cmbAdditional.SelectedItem.Description
        $toolTip.SetToolTip($cmbAdditional, $cmbAdditional.SelectedItem.Description)
    }
})

$lstAdditional.Add_SelectedIndexChanged({
    if ($lstAdditional.SelectedItem) {
        $lblAdditionalDescription.Text = $lstAdditional.SelectedItem.Description
        $toolTip.SetToolTip($lstAdditional, $lstAdditional.SelectedItem.Description)
    }
})

$txtSource.Add_TextChanged({ Update-CommandPreview })
$txtDestination.Add_TextChanged({ Update-CommandPreview })
$rdoCopy.Add_CheckedChanged({ Update-CommandPreview })
$rdoMirror.Add_CheckedChanged({ Update-CommandPreview })
$rdoMove.Add_CheckedChanged({ Update-CommandPreview })
$chkPreview.Add_CheckedChanged({ Update-CommandPreview })
$chkIncludeEmpty.Add_CheckedChanged({ Update-CommandPreview })
$chkExcludeJunctions.Add_CheckedChanged({ Update-CommandPreview })
$chkRestartable.Add_CheckedChanged({ Update-CommandPreview })
$chkMultiThread.Add_CheckedChanged({ $numThreads.Enabled = $chkMultiThread.Checked; Update-CommandPreview })
$numThreads.Add_ValueChanged({ Update-CommandPreview })
$chkNoProgress.Add_CheckedChanged({ Update-CommandPreview })
$chkTee.Add_CheckedChanged({ Update-CommandPreview })
$numRetries.Add_ValueChanged({ Update-CommandPreview })
$numWait.Add_ValueChanged({ Update-CommandPreview })
$txtExcludeFiles.Add_TextChanged({ Update-CommandPreview })
$txtExcludeFolders.Add_TextChanged({ Update-CommandPreview })
$txtAdvanced.Add_TextChanged({ Update-CommandPreview })

$form.Add_FormClosing({
    param($sender, $eventArgs)

    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $cancel = -not (Show-ConfirmMessage 'Robocopy is still running. Stop it and close the GUI?')
        if ($cancel) {
            $eventArgs.Cancel = $true
        } else {
            $script:RunWasCancelled = $true
            try {
                $script:CurrentProcess.Kill()
            } catch {
            }
        }
    }
})

$form.Add_FormClosed({
    if ($script:LogPollTimer) {
        $script:LogPollTimer.Stop()
        $script:LogPollTimer.Dispose()
        $script:LogPollTimer = $null
    }

    if ($script:CurrentProcess) {
        $script:CurrentProcess.Dispose()
        $script:CurrentProcess = $null
    }
})

Update-CommandPreview
[void]$form.ShowDialog()

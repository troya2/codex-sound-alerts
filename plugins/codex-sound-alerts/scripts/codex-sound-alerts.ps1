param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("approval", "start", "stop")]
    [string]$Action
)

$ErrorActionPreference = "Stop"
$ThresholdSeconds = 60
$ExternalHookTimeoutSeconds = 3

try {
    $PayloadText = [Console]::In.ReadToEnd()
    $Payload = if ($PayloadText) { $PayloadText | ConvertFrom-Json } else { $null }
} catch {
    exit 0
}

function Write-TestEvent {
    param([string]$Message)
    if (-not $env:CODEX_SOUND_ALERTS_TEST_LOG) {
        return
    }
    try {
        Add-Content -LiteralPath $env:CODEX_SOUND_ALERTS_TEST_LOG -Value $Message -Encoding UTF8
    } catch {
    }
}

function Send-ToastNotification {
    param(
        [string]$Title,
        [string]$Body
    )

    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

        $EscapedTitle = [Security.SecurityElement]::Escape($Title)
        $EscapedBody = [Security.SecurityElement]::Escape($Body)
        $Xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $Xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$EscapedTitle</text><text>$EscapedBody</text></binding></visual></toast>")
        $Toast = [Windows.UI.Notifications.ToastNotification]::new($Xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Codex Sound Alerts").Show($Toast)
    } catch {
        # Sound remains the fallback when Toast is unavailable or disabled.
    }
}

function Invoke-ExternalHook {
    param(
        [string]$EventName,
        [string]$Title,
        [string]$Message
    )

    $HookPath = $env:CODEX_SOUND_ALERTS_EXTERNAL_HOOK
    if (-not $HookPath -and $env:APPDATA) {
        $HookPath = Join-Path $env:APPDATA "codex-sound-alerts\external-hook.ps1"
    }
    if (-not $HookPath -or -not (Test-Path -LiteralPath $HookPath -PathType Leaf)) {
        return
    }

    $EventJson = @{
        version = 1
        event = $EventName
        title = $Title
        message = $Message
        occurred_at = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json -Compress

    if ($env:CODEX_SOUND_ALERTS_TEST_MODE -eq "1") {
        Write-TestEvent "external:$EventName"
    }

    $Job = $null
    try {
        $Job = Start-Job -ScriptBlock {
            param($Path, $Event, $Kind)
            $Event | & $Path $Kind *> $null
        } -ArgumentList $HookPath, $EventJson, $EventName
        if (-not (Wait-Job -Job $Job -Timeout $ExternalHookTimeoutSeconds)) {
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
        }
    } catch {
    } finally {
        if ($Job) {
            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
        }
    }
}

function Send-Alert {
    param([ValidateSet("approval", "complete")][string]$Kind)

    if ($Kind -eq "approval") {
        $EventName = "approval_required"
        $Title = "Codex needs attention"
        $Message = "Approval required."
    } else {
        $EventName = "task_completed"
        $Title = "Codex task finished"
        $Message = "A long-running task has ended."
    }

    if ($env:CODEX_SOUND_ALERTS_TEST_MODE -eq "1") {
        Write-TestEvent "sound:$Kind"
        if ($env:CODEX_SOUND_ALERTS_TEST_NOTIFICATION_FAILURE -ne "1") {
            Write-TestEvent "notification:$Kind"
        }
        Invoke-ExternalHook -EventName $EventName -Title $Title -Message $Message
        return
    }

    try {
        if ($Kind -eq "approval") {
            [System.Media.SystemSounds]::Exclamation.Play()
        } else {
            [System.Media.SystemSounds]::Asterisk.Play()
        }
    } catch {
    }

    if ($Kind -eq "approval") {
        Send-ToastNotification -Title "Codex needs attention" -Body "Approval required."
    } else {
        Send-ToastNotification -Title "Codex task finished" -Body "A long-running task has ended."
    }

    Invoke-ExternalHook -EventName $EventName -Title $Title -Message $Message
}

function Get-StatePath {
    if (-not $env:PLUGIN_DATA -or -not $Payload -or -not $Payload.session_id -or -not $Payload.turn_id) {
        return $null
    }

    $InputBytes = [Text.Encoding]::UTF8.GetBytes("$($Payload.session_id)`n$($Payload.turn_id)")
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Key = ([BitConverter]::ToString($Hasher.ComputeHash($InputBytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $Hasher.Dispose()
    }
    return Join-Path (Join-Path $env:PLUGIN_DATA "state") "$Key.started"
}

try {
    switch ($Action) {
        "approval" {
            Send-Alert -Kind "approval"
        }
        "start" {
            $StatePath = Get-StatePath
            if (-not $StatePath) { exit 0 }
            $StateDirectory = Split-Path -Parent $StatePath
            [IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
            Get-ChildItem -LiteralPath $StateDirectory -Filter "*.started" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $StatePath -PathType Leaf) { exit 0 }
            $TemporaryPath = "$StatePath.$PID"
            [IO.File]::WriteAllText($TemporaryPath, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString())
            Move-Item -LiteralPath $TemporaryPath -Destination $StatePath -Force
        }
        "stop" {
            $StatePath = Get-StatePath
            if (-not $StatePath -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { exit 0 }
            $StartedAtText = [IO.File]::ReadAllText($StatePath).Trim()
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
            $StartedAt = 0L
            if (-not [Int64]::TryParse($StartedAtText, [ref]$StartedAt)) { exit 0 }
            $Elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $StartedAt
            if ($Elapsed -ge $ThresholdSeconds) {
                Send-Alert -Kind "complete"
            }
        }
    }
} catch {
    # Alerts must never block Codex or alter an approval flow.
}

exit 0

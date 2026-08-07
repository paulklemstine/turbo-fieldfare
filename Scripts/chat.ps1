#!/usr/bin/env pwsh
# Minimal chat client for the TurboFieldfare local model server.
# PowerShell implementation -- no Python required.
#
# Usage:
#   chat.ps1 --ask "PROMPT"        single prompt, print reply
#   chat.ps1 --chat                interactive chat REPL
#   chat.ps1 --ask "PROMPT" --no-stream

param(
    [switch]$chat,
    [string]$ask,
    [string]$baseUrl = "http://127.0.0.1:8080/v1",
    [string]$model = "gemma-4-26b-a4b-it",
    [double]$temperature = 0.2,
    [int]$maxTokens = 4096,
    [string]$system,
    [switch]$noStream
)

$DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"

function Send-Messages {
    param([array]$messages)
    $body = @{
        model = $model
        messages = $messages
        temperature = $temperature
        max_completion_tokens = $maxTokens
        stream = -not $noStream
        stop = @("<end_of_turn>")
    } | ConvertTo-Json -Depth 10 -Compress
    $url = ($baseUrl.TrimEnd("/")) + "/chat/completions"
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        if ($noStream) {
            $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $bodyBytes
            $reply = $resp.choices[0].message.content
            Write-Output $reply
            return $reply
        } else {
            $resp = Invoke-WebRequest -Uri $url -Method Post -ContentType "application/json" -Body $bodyBytes -UseBasicParsing
            $text = ""
            $reasoning = ""
            foreach ($line in $resp.RawContentStream -ReadCount 0) {
                if ($null -eq $line) { continue }
                $line = $line.Trim()
                if (-not $line.StartsWith("data:")) { continue }
                $payload = $line.Substring(5).Trim()
                if ($payload == "[DONE]") { break }
                try { $chunk = $payload | ConvertFrom-Json } catch { continue }
                $delta = $chunk.choices[0].delta
                if ($null -eq $delta) { continue }
                if ($delta.content) { $text += $delta.content; Write-Host -NoNewline $delta.content }
                if ($delta.reasoning_content) { $reasoning += $delta.reasoning_content }
            }
            Write-Host ""
            if (-not $text -and $reasoning) { Write-Host $reasoning; return $reasoning }
            return $text
        }
    } catch {
        Write-Error "ERROR: cannot reach model server at $baseUrl ($($_.Exception.Message))"
        return $null
    }
}

# --- main ---
if (-not $chat -and $null -eq $ask) {
    Write-Output "Usage: chat.ps1 --chat | --ask 'PROMPT'"
    exit 1
}

$messages = @()
if ($system) { $messages += @{role = "system"; content = $system} }

if ($null -ne $ask) {
    $prompt = $ask
    if (-not $prompt -and !$input.MoveNext()) {
        $prompt = ($input -join "").Trim()
    }
    $messages += @{role = "user"; content = $prompt}
    $r = Send-Messages $messages
    if ($null -eq $r) { exit 1 }
    exit 0
}

# interactive
Write-Output "TurboFieldfare chat ($model). /quit to exit."
while ($true) {
    Write-Host -NoNewline "you> "
    try { $user = (Read-Host).Trim() }
    catch { break }
    if (-not $user) { continue }
    if ($user -in @("/quit", "/exit", "/q")) { break }
    if ($user -eq "/new") {
        $messages = $messages | Where-Object { $_.role -eq "system" }
        Write-Output "(history cleared)"
        continue
    }
    $messages += @{role = "user"; content = $user}
    Write-Host -NoNewline "gemma> "
    $reply = Send-Messages $messages
    if ($null -eq $reply) { $messages = $messages[0..($messages.Count-2)]; exit 1 }
    else { $messages += @{role = "assistant"; content = $reply} }
}

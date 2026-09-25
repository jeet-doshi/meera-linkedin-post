# LinkedIn post bot: Telegram notes -> score -> Google Search news -> one post in the voice.
# Run: powershell -ExecutionPolicy Bypass -File bot.ps1
# Test without Telegram: powershell -ExecutionPolicy Bypass -File bot.ps1 -Test "your rough note"
param([string]$Test)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$voice  = Get-Content (Join-Path $root $config.voice_file) -Raw -Encoding UTF8

$tgBase = "https://api.telegram.org/bot$($config.telegram_token)"

$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(75)   # getUpdates long-polls 50s; Gemini calls use their own shorter limit

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

# All HTTP goes through here so request and response are always UTF-8
# (PowerShell 5.1's Invoke-RestMethod mangles em dashes and non-ASCII text).
function Invoke-Json($url, $body, $headers, $timeoutSec = 70) {
    $req = New-Object System.Net.Http.HttpRequestMessage
    if ($null -ne $body) {
        $req.Method  = [System.Net.Http.HttpMethod]::Post
        $json        = $body | ConvertTo-Json -Depth 30 -Compress
        $req.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    } else {
        $req.Method = [System.Net.Http.HttpMethod]::Get
    }
    $req.RequestUri = $url
    if ($headers) { foreach ($k in $headers.Keys) { $req.Headers.Add($k, $headers[$k]) } }
    $cts   = New-Object System.Threading.CancellationTokenSource([TimeSpan]::FromSeconds($timeoutSec))
    $resp  = $http.SendAsync($req, $cts.Token).GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text  = [Text.Encoding]::UTF8.GetString($bytes)
    if (-not $resp.IsSuccessStatusCode) {
        $err = New-Object Exception ("HTTP {0}: {1}" -f [int]$resp.StatusCode, $text)
        $err.Data['status'] = [int]$resp.StatusCode
        throw $err
    }
    return $text | ConvertFrom-Json
}

# ---------------- Gemini ----------------

function Invoke-Gemini {
    param([string]$System, [string]$Prompt, [switch]$Search, [switch]$Json, [double]$Temperature = 0.7)
    $body = @{
        contents         = @(@{ role = 'user'; parts = @(@{ text = $Prompt }) })
        generationConfig = @{ temperature = $Temperature }
    }
    if ($System) { $body.systemInstruction = @{ parts = @(@{ text = $System }) } }
    if ($Search) { $body.tools = @(@{ google_search = @{} }) }
    if ($Json)   { $body.generationConfig.responseMimeType = 'application/json' }

    # Try the main model twice, then each fallback model, so a busy model doesn't fail the note.
    $models = @($config.gemini_model) + @($config.fallback_models)
    $lastError = $null
    foreach ($model in $models) {
        $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent"
        for ($attempt = 1; $attempt -le 1; $attempt++) {
            try {
                $r = Invoke-Json $url $body @{ 'x-goog-api-key' = $config.gemini_api_key } 45
                $parts = $r.candidates[0].content.parts | Where-Object { $_.text -and -not $_.thought }
                $text = ($parts | ForEach-Object { $_.text }) -join ''
                if (-not $text.Trim()) { throw "Gemini returned an empty response" }
                return $text.Trim()
            } catch {
                $lastError = $_
                $status = $_.Exception.Data['status']
                $retryable = ($null -eq $status) -or ($status -eq 429) -or ($status -ge 500)
                Log ("{0} attempt {1} failed (HTTP {2})" -f $model, $attempt, $status)
                if ($status -eq 404) { break }   # model not available to this key: try the next one
                if ($Search -and $status -eq 429) { throw }   # search quota is per-key, other models won't help
                if (-not $retryable) { throw }
                Start-Sleep -Seconds 1
            }
        }
    }
    throw $lastError
}

$evalSystem = @"
You are a strict LinkedIn editor for the author described in the VOICE BLUEPRINT below. You decide whether a raw note contains a thought worth turning into a LinkedIn post for this specific author and audience.

Score 0-10 using these criteria:
- Is there one clear, specific insight, observation, story, or opinion (not a vague topic)?
- Is it relevant to this author's audience and domain as defined in the blueprint?
- Does it carry tension, a non-obvious angle, or a claim worth defending?
- Can it be grounded in specifics (a number, a scene, a mechanism, a real-world event)?
- Would a thoughtful reader in this space stop scrolling for it?

Scoring anchors: 9-10 = distinct, specific, clearly on-brand; 8 = solid, post-worthy with light shaping; 5-7 = interesting but generic, thin, or off-brand; 0-4 = no real idea, too vague, or unrelated.
Notes may be messy, conversational, fragmented, or bullet points. Judge the underlying thought, not the writing quality.

Return JSON only: {"score": <integer 0-10>, "core_thought": "<the author's idea in one sentence>", "reason": "<one short sentence explaining the score>", "search_query": "<a concise news search query for the core thought>"}

VOICE BLUEPRINT:
$voice
"@

$newsSystem = @"
You are a news researcher. Use Google Search to find recent, credible news, reports, studies, regulatory updates, or industry developments directly relevant to the thought you are given. Prioritise the last 12 months and reputable sources.

Return a compact research brief in plain text:
- 3 to 6 findings, each with: what happened, the specific number/date/detail, and the source name.
- Only include facts you actually found. If nothing relevant turns up, say "No directly relevant news found." and stop.
No commentary, no post drafts.
"@

$writeSystem = @"
You are a ghostwriter producing exactly one LinkedIn post. The VOICE BLUEPRINT below is the single source of truth for tone, structure, hooks, storytelling, formatting, sentence rhythm, vocabulary, and hard constraints. Follow its LinkedIn rules (not the newsletter rules). Where anything below conflicts with the blueprint's style, the blueprint wins.

Rules:
1. Output ONLY the post text, ready to paste into LinkedIn. No title, no preamble ("Here's your post"), no explanation, no notes, no alternatives, no options, no versions, no hashtags, no markdown (no **bold**, no # headings), no surrounding quotes.
2. Exactly one post. Never offer a second angle.
3. Preserve the author's own thoughts, opinions, stories, and conclusions from the notes. Clean them up, order them, and sharpen them, but do not replace them with different ideas or reverse their stance.
4. Weave in the most relevant finding(s) from the NEWS BRIEF as supporting context where it strengthens the author's point. Use at most one or two. Mention the source naturally in prose if you use a fact. If the brief has nothing useful, write from the notes alone.
5. Never invent statistics, studies, quotes, dates, internal company data, or personal anecdotes. Numbers may only come from the notes or the news brief.
6. No generic AI or corporate LinkedIn language: no "In today's fast-paced world", "game-changer", "unlock", "leverage", "delve", "let that sink in", "here's the thing", "the truth is", engagement bait, or motivational filler, unless the blueprint itself uses it.

VOICE BLUEPRINT:
$voice
"@

function Get-JsonObject($text) {
    $t = $text.Trim()
    $t = $t -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    $start = $t.IndexOf('{'); $end = $t.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) { $t = $t.Substring($start, $end - $start + 1) }
    return $t | ConvertFrom-Json
}

function Clean-Post($text) {
    $t = $text.Trim()
    $t = $t -replace '^```\w*\s*', '' -replace '\s*```$', ''
    # Drop a stray preamble line like "Here's your post:" if the model slips.
    $t = $t -replace '^(?i)(here(''s| is)[^\n]*|sure[^\n]*|certainly[^\n]*):\s*\n+', ''
    $t = $t -replace '\*\*(.+?)\*\*', '$1'
    $t = $t -replace '(?m)^#+\s*', ''
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length - 2) }
    return $t.Trim()
}

function Process-Note($note) {
    $eval = Get-JsonObject (Invoke-Gemini -System $evalSystem -Prompt "RAW NOTE:`n$note" -Json -Temperature 0.2)
    $score = [int]$eval.score
    Log "Score $score/10 - $($eval.reason)"

    if ($score -lt [int]$config.min_score) {
        return "$score/10 - not post-worthy yet.`n$($eval.reason)"
    }

    $query = if ($eval.search_query) { $eval.search_query } else { $eval.core_thought }
    $today = Get-Date -Format 'yyyy-MM-dd'
    try {
        $news = Invoke-Gemini -System $newsSystem -Search -Temperature 0.3 -Prompt "Today is $today.`nThought: $($eval.core_thought)`nSuggested search: $query"
    } catch {
        Log "News lookup failed: $($_.Exception.Message)"
        $news = 'No directly relevant news found.'
    }

    $post = Invoke-Gemini -System $writeSystem -Temperature 0.8 -Prompt @"
AUTHOR'S RAW NOTES (preserve these thoughts):
$note

CORE THOUGHT: $($eval.core_thought)

NEWS BRIEF:
$news
"@
    return Clean-Post $post
}

# ---------------- Telegram ----------------

function Send-Telegram($chatId, $text) {
    # Telegram caps messages at 4096 chars; split on paragraph breaks if ever needed.
    $chunks = @(); $buf = ''
    foreach ($para in ($text -split "`n`n")) {
        if (($buf.Length + $para.Length + 2) -gt 4000 -and $buf) { $chunks += $buf; $buf = '' }
        $buf = if ($buf) { "$buf`n`n$para" } else { $para }
    }
    if ($buf) { $chunks += $buf }
    foreach ($c in $chunks) {
        Invoke-Json "$tgBase/sendMessage" @{ chat_id = $chatId; text = $c; disable_web_page_preview = $true } | Out-Null
    }
}

function Send-Typing($chatId) {
    try { Invoke-Json "$tgBase/sendChatAction" @{ chat_id = $chatId; action = 'typing' } | Out-Null } catch {}
}

if ($Test) {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    Process-Note $Test
    exit
}

$me = Invoke-Json "$tgBase/getMe"
Log "Bot @$($me.result.username) running with $($config.gemini_model). Press Ctrl+C to stop."
$allowed = @($config.allowed_chat_ids | ForEach-Object { [string]$_ })
$offset = 0

while ($true) {
    try {
        $updates = Invoke-Json "$tgBase/getUpdates?timeout=50&offset=$offset&allowed_updates=%5B%22message%22%5D"
    } catch {
        Log "Polling error: $($_.Exception.Message)"
        Start-Sleep -Seconds 5
        continue
    }

    foreach ($u in $updates.result) {
        $offset = [long]$u.update_id + 1
        $msg = $u.message
        if (-not $msg) { continue }
        $chatId = [string]$msg.chat.id

        if ($allowed.Count -gt 0 -and $allowed -notcontains $chatId) {
            Log "Ignored message from unlisted chat $chatId"
            continue
        }

        $text = if ($msg.text) { $msg.text } else { $msg.caption }
        if (-not $text) { Send-Telegram $chatId 'Send your rough notes as text.'; continue }
        if ($text -match '^/start') {
            Send-Telegram $chatId "Send rough notes. Each message is scored out of 10; $($config.min_score)+ gets one LinkedIn post."
            Log "Chat $chatId started the bot"
            continue
        }

        Log "Note from chat $chatId ($($text.Length) chars)"
        Send-Typing $chatId
        try {
            $reply = Process-Note $text
            Send-Telegram $chatId $reply
            Log "Replied to chat $chatId"
        } catch {
            Log "Error: $($_.Exception.Message)"
            try { Send-Telegram $chatId 'Something went wrong generating this one. Send it again.' } catch {}
        }
    }
}

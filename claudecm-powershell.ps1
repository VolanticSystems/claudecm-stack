function claudecm {
    $cmDir = "$env:USERPROFILE\.claudecm"
    $sessionsFile = "$cmDir\sessions.txt"
    $machineNameFile = "$cmDir\machine-name.txt"
    # TWO DISTINCT DESTINATIONS, and they are not interchangeable.
    #   $cmDir\backup        settings backups, rolling sessions.txt backups, the
    #                        pre-trim JSONL (spec 11.13 step 11) and the fork
    #                        predecessor (spec 11.6.1 step 4).
    #   $quarantineRoot      orphan quarantine and explicit user-initiated
    #                        quarantine (spec section 3, storage layout).
    # Named separately because they used to share the name $backupDir, one at
    # this scope and one assigned inside Do-OrphanScan. PowerShell makes the
    # inner assignment local so the behaviour was correct, but "which directory
    # does $backupDir mean here" depended on which function you were reading.
    # bash has always had these as two variables; this matches it.
    $quarantineRoot = "$env:USERPROFILE\documents\github\claude-conversation-backup"
    # Dangerous mode is OFF at the start of every run and is never persisted.
    # Set here rather than only inside the D handler so Show-List can read it
    # before anything has toggled it. See Get-PermissionArgs.
    $script:launchBypass = $false
    # Talk mode, the mirror of dangerous mode, same rules: off at the start of
    # every run, never persisted, readable by Show-List before anything toggles.
    $script:launchPlan = $false
    $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
    $cmvExe = "$env:APPDATA\npm\cmv.cmd"
    $env:CLAUDE_CODE_REMOTE_SEND_KEEPALIVES = "1"
    # Optional personal preference: uncomment to disable Claude Code's CLI
    # suggested-prompt hints (the "do you want to..." follow-ups). See README.
    # $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = "0"

    function Ensure-CleanupPeriodDays {
        $settingsPath = "$env:USERPROFILE\.claude\settings.json"
        if (-not (Test-Path $settingsPath)) { return }

        # Read first, on its own. An unreadable or non-JSON settings.json means
        # change nothing and claim nothing: announcing protection for a file we
        # could not even parse is a statement about nothing.
        $settings = $null; $current = $null
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $current = $settings.cleanupPeriodDays
        } catch { return }
        if ($null -eq $settings) { return }

        # 0 is not "keep forever", it disables persistence, so it falls through
        # to the rewrite along with any value under 1000 and with the key being
        # absent entirely.
        if ($current -and $current -ge 1000) { return }

        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backupDir = "$env:USERPROFILE\.claudecm\backup"
        if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
        Copy-Item $settingsPath "$backupDir\settings.json.$ts" -ErrorAction SilentlyContinue

        # 100000 preserves transcripts for ~274 years. NOT 0, which disables
        # persistence rather than extending it.
        try {
            $settings | Add-Member -NotePropertyName 'cleanupPeriodDays' -NotePropertyValue 100000 -Force
            $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsPath -Encoding UTF8 -ErrorAction Stop
        } catch { }

        # Read it back off DISK before saying anything. This message is the only
        # thing the user ever sees about their transcripts being safe, so it has
        # to be evidence that the write landed rather than the intention to
        # write. Getting it wrong is silent: they are told they are protected,
        # and a month later Claude Code deletes the transcripts anyway.
        $after = $null
        try { $after = (Get-Content $settingsPath -Raw | ConvertFrom-Json).cleanupPeriodDays } catch { }
        if ($after -and $after -ge 1000) {
            Write-Host "  Protected session transcripts from Claude Code's 30-day auto-delete." -ForegroundColor Cyan
        } else {
            Write-Host "  Warning: could not raise cleanupPeriodDays in settings.json." -ForegroundColor Yellow
            Write-Host "  Transcripts remain subject to Claude Code's 30-day auto-delete."
        }
    }
    Ensure-CleanupPeriodDays

    if (-not (Test-Path $cmDir)) { New-Item -ItemType Directory -Path $cmDir | Out-Null }
    if (-not (Test-Path $sessionsFile)) { New-Item -ItemType File -Path $sessionsFile | Out-Null }

    # Auto-backup sessions.txt on every launch (best-effort, silent).
    # Keeps a rolling history so a buggy or destructive operation can always be rolled back.
    # Retains the most recent 20 backups; older ones are pruned.
    try {
        $backupDir = "$cmDir\backup"
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        if ((Get-Item $sessionsFile -ErrorAction SilentlyContinue).Length -gt 0) {
            $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
            Copy-Item $sessionsFile "$backupDir\sessions.txt.$ts" -ErrorAction SilentlyContinue
            $oldBackups = @(Get-ChildItem "$backupDir\sessions.txt.*" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip 20)
            foreach ($b in $oldBackups) { Remove-Item $b.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {}

    # Machine name: prompt on first use
    if (-not (Test-Path $machineNameFile)) {
        Write-Host ""
        $mn = Read-Host "  Machine name for remote display (e.g. desktop, laptop)"
        if (-not $mn) { $mn = $env:COMPUTERNAME.ToLower() }
        $mn | Set-Content $machineNameFile
        Write-Host "  Saved: $mn"
    }
    $machineName = (Get-Content $machineNameFile -ErrorAction SilentlyContinue).Trim()
    if (-not $machineName) { $machineName = $env:COMPUTERNAME.ToLower() }

    function Get-SessionDisplayName($desc) {
        return "$machineName - $desc"
    }

    function Parse-SessionLine($line) {
        $parts = $line -split '\|', 4
        $tokens = ""; if ($parts.Count -ge 4) { $tokens = $parts[3] }
        return [PSCustomObject]@{ Guid=$parts[0]; Dir=$parts[1]; Desc=$parts[2]; Tokens=$tokens }
    }

    function Get-Sessions {
        $lines = Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' }
        $sessions = @()
        foreach ($line in $lines) {
            if ($line.Trim() -eq '[archived]') { break }
            $sessions += Parse-SessionLine $line
        }
        return ,$sessions
    }

    function Get-ArchivedSessions {
        $lines = Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' }
        $sessions = @()
        $inArchived = $false
        foreach ($line in $lines) {
            if ($line.Trim() -eq '[archived]') { $inArchived = $true; continue }
            if ($inArchived) { $sessions += Parse-SessionLine $line }
        }
        return ,$sessions
    }

    function Acquire-SessionsLock {
        # Returns a FileStream holding an exclusive lock on sessions.txt.lock.
        # Retries for up to 10 seconds. Returns $null on timeout.
        $lockPath = "$sessionsFile.lock"
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            try {
                $fs = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
                return $fs
            } catch {
                Start-Sleep -Milliseconds 200
            }
        }
        Write-Host "  [warning] Could not acquire sessions.txt lock after 10s; another ClaudeCM operation may be running. Proceeding without lock." -ForegroundColor Yellow
        return $null
    }

    function Release-SessionsLock($lock) {
        if ($lock) {
            try { $lock.Close(); $lock.Dispose() } catch {}
        }
    }

    function Write-SessionsAtomic($lines) {
        # Write to temp file, then atomic rename. Survives partial-write crashes.
        $tmp = "$sessionsFile.tmp"
        $lines | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $sessionsFile -Force
    }

    function Save-Sessions($sessions) {
        $lock = Acquire-SessionsLock
        try {
            $archived = Get-ArchivedSessions
            $lines = @($sessions | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
            if ($archived.Count -gt 0) {
                $lines += '[archived]'
                $lines += @($archived | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
            }
            Write-SessionsAtomic $lines
        } finally { Release-SessionsLock $lock }
    }

    function Save-ArchivedSessions($archivedSessions) {
        $lock = Acquire-SessionsLock
        try {
        $main = Get-Sessions
        $lines = @($main | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
        if ($archivedSessions.Count -gt 0) {
            $lines += '[archived]'
            $lines += @($archivedSessions | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
        }
        Write-SessionsAtomic $lines
        } finally { Release-SessionsLock $lock }
    }

    function Sync-SessionIndex($projectDir) {
        # Validates and repairs Claude Code's sessions-index.json for a project directory.
        # Removes entries for deleted JSONL files, adds entries for unindexed ones,
        # and creates the index from scratch if missing. Best-effort; never blocks on failure.
        try {
            $projKey = Get-ProjectKey $projectDir
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            if (-not (Test-Path $projDirClaude)) { return }

            $uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            $jsonlFiles = @(Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match $uuidPattern })
            if ($jsonlFiles.Count -eq 0) { return }

            $indexPath = Join-Path $projDirClaude "sessions-index.json"
            $existingEntries = @()
            $originalPath = $projectDir

            if (Test-Path $indexPath) {
                try {
                    $indexData = Get-Content $indexPath -Raw | ConvertFrom-Json
                    $existingEntries = @($indexData.entries)
                    if ($indexData.originalPath) { $originalPath = $indexData.originalPath }
                } catch { $existingEntries = @() }
            }

            # Build lookup of GUIDs on disk
            $diskGuids = @{}
            foreach ($f in $jsonlFiles) { $diskGuids[$f.BaseName] = $f }

            # Keep only entries whose files still exist; update their mtime
            $validEntries = @()
            foreach ($entry in $existingEntries) {
                if ($diskGuids.ContainsKey($entry.sessionId)) {
                    $f = $diskGuids[$entry.sessionId]
                    $entry.fileMtime = [long]($f.LastWriteTimeUtc - [datetime]'1970-01-01').TotalMilliseconds
                    $entry.modified = $f.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    $validEntries += $entry
                }
            }

            $indexedGuids = @{}
            foreach ($entry in $validEntries) { $indexedGuids[$entry.sessionId] = $true }

            # Add entries for unindexed files
            $sessions = Get-Sessions
            $newEntries = @()
            foreach ($guid in $diskGuids.Keys) {
                if (-not $indexedGuids.ContainsKey($guid)) {
                    $f = $diskGuids[$guid]
                    $mtime = [long]($f.LastWriteTimeUtc - [datetime]'1970-01-01').TotalMilliseconds
                    $created = $f.CreationTimeUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    $modified = $f.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    $sessMatch = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
                    $firstPrompt = ""; $projPath = $projectDir
                    if ($sessMatch) {
                        $firstPrompt = $sessMatch.Desc
                        $projPath = $sessMatch.Dir
                    }
                    $msgCount = 0
                    try { $msgCount = @(Get-Content $f.FullName).Count } catch {}
                    $newEntries += @{
                        sessionId = $guid
                        fullPath = $f.FullName
                        fileMtime = $mtime
                        firstPrompt = $firstPrompt
                        messageCount = $msgCount
                        created = $created
                        modified = $modified
                        gitBranch = ""
                        projectPath = $projPath
                        isSidechain = $false
                    }
                }
            }

            $allEntries = @($validEntries) + @($newEntries)
            $indexObj = @{ version = 1; entries = $allEntries; originalPath = $originalPath }
            $indexObj | ConvertTo-Json -Depth 10 | Set-Content $indexPath -Encoding UTF8
        } catch {
            # Best-effort: never block ClaudeCM operations on index sync failure
        }
    }

    function Get-ProjectKey($dir) {
        # Claude Code encoding: every non-alphanumeric char becomes a dash
        return ($dir -replace '[^a-zA-Z0-9]', '-')
    }

    function Format-Tokens($tokens) {
        if (-not $tokens -or $tokens -eq '') { return "--" }
        $t = [int]$tokens
        if ($t -ge 1000000) { return "{0:N1}M tok" -f ($t / 1000000) }
        if ($t -ge 1000) { return "{0:N0}K tok" -f ($t / 1000) }
        return "$t tok"
    }

    function Format-Size($bytes) {
        if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
        if ($bytes -ge 1KB) { return "{0:N0} KB" -f ($bytes / 1KB) }
        return "$bytes B"
    }

    function Format-DateShort($dt) {
        if ($dt.Year -lt (Get-Date).Year) { return $dt.ToString("MMM d, yyyy") }
        return $dt.ToString("MMM d")
    }

    function Get-SessionInfo($guid, $dir, $tokens) {
        $projKey = Get-ProjectKey $dir
        $projDir = "$env:USERPROFILE\.claude\projects\$projKey"
        $jsonl = "$projDir\$guid.jsonl"
        $tokStr = Format-Tokens $tokens

        if (Test-Path $jsonl) {
            $item = Get-Item $jsonl
            return [PSCustomObject]@{
                Size = Format-Size $item.Length
                Date = Format-DateShort $item.LastWriteTime
                Tokens = $tokStr
                Status = 'ok'
            }
        }

        # JSONL missing - try fallbacks for date
        $fallbackDate = $null
        $guidSubdir = "$projDir\$guid"
        $memoryDir = "$projDir\memory"
        if (Test-Path $guidSubdir) { $fallbackDate = (Get-Item $guidSubdir).LastWriteTime }
        elseif (Test-Path $memoryDir) { $fallbackDate = (Get-Item $memoryDir).LastWriteTime }
        else {
            $indexPath = "$projDir\sessions-index.json"
            if (Test-Path $indexPath) {
                try {
                    $idx = Get-Content $indexPath -Raw | ConvertFrom-Json
                    $entry = $idx.entries | Where-Object { $_.sessionId -eq $guid } | Select-Object -First 1
                    if ($entry -and $entry.created) { $fallbackDate = [DateTime]$entry.created }
                } catch {}
            }
        }

        $dateStr = "--"
        if ($fallbackDate) { $dateStr = (Format-DateShort $fallbackDate) + "*" }

        return [PSCustomObject]@{
            Size = "(missing)"
            Date = $dateStr
            Tokens = $tokStr
            Status = 'missing'
        }
    }

    function Build-RecoveryMetaPrompt($dir, $desc, $tokens, $lastDate) {
        $projKey = Get-ProjectKey $dir
        $projDir = "$env:USERPROFILE\.claude\projects\$projKey"
        $memoryDir = "$projDir\memory"
        $subagentsDir = "$projDir\$($script:lastGuid)\subagents"

        $memoryFiles = @()
        if (Test-Path $memoryDir) {
            $memoryFiles = Get-ChildItem "$memoryDir\*.md" -ErrorAction SilentlyContinue |
                ForEach-Object { "  * $($_.Name) ($([math]::Round($_.Length/1024)) KB, modified $($_.LastWriteTime.ToString('yyyy-MM-dd')))" }
        }
        $memoryList = if ($memoryFiles.Count -gt 0) { $memoryFiles -join "`n" } else { "  (none)" }

        $subagentCount = 0
        $subagentLatest = "unknown"
        if (Test-Path $subagentsDir) {
            $agents = @(Get-ChildItem "$subagentsDir\*.jsonl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            $subagentCount = $agents.Count
            if ($agents.Count -gt 0) { $subagentLatest = $agents[0].LastWriteTime.ToString('yyyy-MM-dd') }
        }

        $tokStr = if ($tokens) { "$tokens tokens" } else { "unknown token count" }
        $dateStr = if ($lastDate) { $lastDate } else { "unknown" }

        return @"
Context: a Claude Code session was deleted. You need to produce orientation text for a future Claude Code session that will read this text as its first input. Produce the text. That text goes directly into the next session. It is NOT a summary, NOT a description, NOT a report about what you did. It is the directives themselves.

Read these artifacts:
* Memory files in ${memoryDir}
* Subagent transcripts in ${subagentsDir} (2-3 most recent; total on disk: $subagentCount, latest dated $subagentLatest)
* The project code at $dir

Session metadata (for reference when you write):
* Session name: $desc
* Project path: $dir
* Last activity: $dateStr
* Conversation size when lost: $tokStr

Now replace every <PLACEHOLDER> below and OUTPUT the completed template. Start your output with "This is a recovery session." and end with "ask before assuming." Output nothing else. No preamble, no confirmation, no summary of what you did.

This is a recovery session. The previous conversation transcript for "$desc" was deleted. The project lives at $dir. Memory, subagent state, and source code all survived.

Read these files in this order:

<NUMBERED LIST. Format: "1. <filename>: <one-line description of what this file contains, based on what you read in it>". Use actual file paths from the memory directory.>

Then skim these subagent transcripts for context on in-flight work:

<BULLETED LIST using "*" not "-". Format: "* <filename>: <what this subagent was doing>". Use 2-3 of the most recently modified subagent transcripts. If there are zero subagent transcripts, replace this whole list with the single line: "No surviving subagent transcripts.">

Open questions or in-flight work visible from the artifacts:

<BULLETED LIST using "*" not "-". One line per item. If nothing specific is identifiable, replace this whole list with: "None identified from the artifacts.">

Read these in order. Do not run builds, tests, or git commands yet. Do not modify any files. After reading, report back with: (1) your understanding of project state as of the last captured activity, (2) what appears to have been in progress, (3) what you recommend doing next. Do not invent details. If something is unclear, ask before assuming.
"@
    }

    function Resolve-ResumeOrRecover($guid, $dir, $desc, $tokens) {
        $projKey = Get-ProjectKey $dir
        $jsonl = "$env:USERPROFILE\.claude\projects\$projKey\$guid.jsonl"
        if (Test-Path $jsonl) {
            return [PSCustomObject]@{ Action='normal'; Guid=$guid }
        }

        Write-Host ""
        Write-Host "  The conversation transcript for '$desc' has been lost." -ForegroundColor Yellow
        Write-Host "  Probably due to Claude Code's 30-day auto-cleanup."
        Write-Host "  Memory files and subagent state are intact."
        Write-Host ""
        Write-Host "  You have three options:"
        Write-Host "    1. Start a fresh Claude session in that directory"
        Write-Host "    2. Create a recovery-prompt.md file in the project directory, that you can prompt Claude to read and execute, with optional edits."
        Write-Host "    3. Cancel"
        Write-Host ""
        $choice = Read-Host "  > "

        switch ($choice) {
            '1' { return [PSCustomObject]@{ Action='fresh'; Guid=$null } }
            '3' { return [PSCustomObject]@{ Action='cancel'; Guid=$null } }
            '2' {
                if (-not (Test-Path $dir)) {
                    Write-Host "  Project directory not found: $dir" -ForegroundColor Red
                    return [PSCustomObject]@{ Action='cancel'; Guid=$null }
                }
                # Rotate existing recovery-prompt.md files: current -> .old, .old -> .old2, etc.
                $primaryPath = Join-Path $dir "recovery-prompt.md"
                if (Test-Path $primaryPath) {
                    # Find highest .oldN suffix
                    $existing = Get-ChildItem $dir -Filter "recovery-prompt.md.old*" -ErrorAction SilentlyContinue
                    $maxN = 1
                    foreach ($f in $existing) {
                        if ($f.Name -match 'recovery-prompt\.md\.old(\d+)$') {
                            $n = [int]$Matches[1]
                            if ($n -ge $maxN) { $maxN = $n + 1 }
                        }
                    }
                    # Shift .old -> .old(N+1), .old(N) -> .old(N+1), etc.
                    $toRotate = @($existing) | Sort-Object {
                        if ($_.Name -match 'recovery-prompt\.md\.old(\d+)$') { [int]$Matches[1] } else { 1 }
                    } -Descending
                    foreach ($f in $toRotate) {
                        $n = 1
                        if ($f.Name -match 'recovery-prompt\.md\.old(\d+)$') { $n = [int]$Matches[1] }
                        $newName = "recovery-prompt.md.old$($n + 1)"
                        try { Rename-Item $f.FullName $newName -Force -ErrorAction Stop } catch {}
                    }
                    try { Rename-Item $primaryPath "recovery-prompt.md.old" -Force -ErrorAction Stop } catch {}
                }

                Write-Host ""
                Write-Host "  Generating recovery prompt (this may take a minute)..." -ForegroundColor Cyan
                $script:lastGuid = $guid
                $info = Get-SessionInfo $guid $dir $tokens
                $metaPrompt = Build-RecoveryMetaPrompt $dir $desc $tokens $info.Date

                $origLoc = Get-Location
                try {
                    Set-Location $dir
                    $tmpFile = [System.IO.Path]::GetTempFileName()
                    $metaPrompt | Out-File -FilePath $tmpFile -Encoding UTF8
                    # --no-session-persistence: this is a throwaway call, and
                    # without the flag it writes a transcript into the project's
                    # own key dir, which ClaudeCM then sees as an orphan for ever
                    # and raises the picker over. Cleaning up afterwards was the
                    # old approach and it leaks: if the call dies or the JSON
                    # does not parse, $primerSessionId is never read and the file
                    # stays. Measured 2026-09-13: with the flag, `-p` still
                    # returns result and session_id and writes no .jsonl at all.
                    $primerJson = Get-Content $tmpFile -Raw | & $claudeExe -p --output-format json --no-session-persistence --dangerously-skip-permissions 2>$null
                    Remove-Item $tmpFile -ErrorAction SilentlyContinue
                    $primerData = $primerJson | ConvertFrom-Json
                    $recoveryPrompt = $primerData.result
                    # Belt and braces: older builds, or a future regression, may
                    # still write one. Deleting nothing costs nothing.
                    $primerSessionId = $primerData.session_id
                    if ($primerSessionId) {
                        $primerProjKey = Get-ProjectKey (Get-Location).Path
                        $primerJsonl = "$env:USERPROFILE\.claude\projects\$primerProjKey\$primerSessionId.jsonl"
                        if (Test-Path $primerJsonl) { Remove-Item $primerJsonl -Force -ErrorAction SilentlyContinue }
                        $primerSubdir = "$env:USERPROFILE\.claude\projects\$primerProjKey\$primerSessionId"
                        if (Test-Path $primerSubdir) { Remove-Item $primerSubdir -Recurse -Force -ErrorAction SilentlyContinue }
                        Sync-SessionIndex (Get-Location).Path
                    }
                    if (-not $recoveryPrompt) {
                        Write-Host "  Recovery prompt generation failed." -ForegroundColor Red
                        return [PSCustomObject]@{ Action='cancel'; Guid=$null }
                    }
                    $recoveryPrompt | Out-File -FilePath $primaryPath -Encoding UTF8
                    Write-Host ""
                    Write-Host "  Recovery prompt saved to:" -ForegroundColor Green
                    Write-Host "    $primaryPath"
                    Write-Host ""
                    Write-Host "  Edit it if you want, or just tell Claude to use it as the first message of the conversation."
                    Write-Host "  Opening a fresh Claude session in that directory now..." -ForegroundColor Cyan
                    Write-Host ""
                    return [PSCustomObject]@{ Action='fresh'; Guid=$null }
                } catch {
                    Write-Host "  Recovery prompt generation error: $_" -ForegroundColor Red
                    return [PSCustomObject]@{ Action='cancel'; Guid=$null }
                } finally {
                    Set-Location $origLoc
                }
            }
            default { return [PSCustomObject]@{ Action='cancel'; Guid=$null } }
        }
    }

    function Show-List($sessions, [int]$highlight = 0) {
        Write-Host ""
        Write-Host "  === Saved Sessions ==="
        Write-Host ""
        $maxDesc = 0
        foreach ($s in $sessions) { if ($s.Desc.Length -gt $maxDesc) { $maxDesc = $s.Desc.Length } }
        $maxDesc = [Math]::Max($maxDesc, 10)
        $numWidth = "$($sessions.Count)".Length
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            $info = Get-SessionInfo $sessions[$i].Guid $sessions[$i].Dir $sessions[$i].Tokens
            $num = "$($i+1).".PadRight($numWidth + 2)
            $desc = $sessions[$i].Desc.PadRight($maxDesc + 2)
            $sizeStr = $info.Size.PadLeft(9)
            $tokStr = $info.Tokens.PadLeft(10)
            $dateStr = $info.Date
            $pathStr = $sessions[$i].Dir
            $line = "  $num $desc $sizeStr  $tokStr   $dateStr`t$pathStr"
            if ($highlight -eq ($i + 1)) {
                Write-Host "  *** $num $desc $sizeStr  $tokStr   $dateStr`t$pathStr  [Selected] ***" -ForegroundColor Yellow
            } else {
                Write-Host $line
            }
        }
        Write-Host ""
        $archivedCount = (Get-ArchivedSessions).Count
        Write-Host "  E. Edit this list"
        if ($archivedCount -gt 0) { Write-Host "  V. View archived ($archivedCount)" }
        Write-Host "  M. Machine name ($machineName)"
        if ($script:launchBypass) {
            Write-Host "  D. DANGEROUS MODE IS ON: no classifier, no plan mode, no prompts" -ForegroundColor Yellow
        } else {
            Write-Host "  D. Dangerous mode off (press D to launch with all permission checks skipped)"
        }
        if ($script:launchPlan) {
            Write-Host "  T. TALK MODE IS ON: launches in plan mode, no file changes" -ForegroundColor Cyan
        } else {
            Write-Host "  T. Talk mode off (press T to launch in plan mode for a discussion)"
        }
    }

    function Do-OrphanScan($scanDir, $registeredGuid) {
        $sessions = (Get-Sessions) + (Get-ArchivedSessions)
        $projKey = Get-ProjectKey $scanDir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $allJsonl = @()
        if (Test-Path $projDirClaude) {
            $allJsonl = @(Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        }
        if ($allJsonl.Count -le 1) { return $null }
        # Check if any files are actually problematic (orphan or wrong directory)
        $hasProblems = $false
        foreach ($f in $allJsonl) {
            $guid = $f.BaseName
            $sessMatch = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
            if (-not $sessMatch) { $hasProblems = $true; break }
            if ("$($sessMatch.Dir)".TrimEnd('\','/') -ne "$scanDir".TrimEnd('\','/')) { $hasProblems = $true; break }
        }
        if (-not $hasProblems) { return $null }
        Write-Host ""
        Write-Host "  Multiple conversation files found ($($allJsonl.Count)):" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  #   Last Modified          Size     Session Name"
        Write-Host "  --- --------------------  --------  ---------------------------"
        for ($ci = 0; $ci -lt $allJsonl.Count; $ci++) {
            $f = $allJsonl[$ci]
            $guid = $f.BaseName
            $sizeBytes = $f.Length
            $sizeStr = ""
            if ($sizeBytes -ge 1MB) { $sizeStr = "{0:N1} MB" -f ($sizeBytes / 1MB) }
            elseif ($sizeBytes -ge 1KB) { $sizeStr = "{0:N0} KB" -f ($sizeBytes / 1KB) }
            else { $sizeStr = "$sizeBytes B" }
            $dateStr = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            $sessMatch = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
            $nameStr = "(orphan)"
            if ($sessMatch) {
                $nameStr = $sessMatch.Desc
                if ($sessMatch.Dir -ne $scanDir) { $nameStr += " (wrong directory)" }
            }
            $marker = ""
            if ($guid -eq $registeredGuid) { $marker = " *" }
            $sizeStr = $sizeStr.PadLeft(8)
            Write-Host ("  {0,-4} {1}  {2}  {3}{4}" -f "$($ci+1).", $dateStr, $sizeStr, $nameStr, $marker)
        }
        Write-Host ""
        Write-Host "  * = registered session for this directory"
        Write-Host ""
        Write-Host "  Actions: [number] to select, [q number] to quarantine to backup, [Enter] to continue with registered session"
        $orphanCmd = Read-Host "  >"
        if ($orphanCmd -match '^\d+$') {
            $idx = [int]$orphanCmd - 1
            if ($idx -ge 0 -and $idx -lt $allJsonl.Count) {
                return @{ Action='select'; Guid=$allJsonl[$idx].BaseName }
            } else { Write-Host "  Invalid number." }
        }
        elseif ($orphanCmd -match '^[qQ]\s*(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -ge 0 -and $idx -lt $allJsonl.Count) {
                $f = $allJsonl[$idx]
                $guid = $f.BaseName
                if ($guid -eq $registeredGuid) {
                    Write-Host "  Cannot quarantine the registered session." -ForegroundColor Red
                } else {
                    if (-not (Test-Path $quarantineRoot)) { New-Item -ItemType Directory -Path $quarantineRoot -Force | Out-Null }
                    $destSubdir = Join-Path $quarantineRoot (Split-Path $scanDir -Leaf)
                    if (-not (Test-Path $destSubdir)) { New-Item -ItemType Directory -Path $destSubdir -Force | Out-Null }
                    Move-Item $f.FullName (Join-Path $destSubdir $f.Name)
                    $guidDir = Join-Path $projDirClaude $guid
                    if (Test-Path $guidDir) { Move-Item $guidDir (Join-Path $destSubdir $guid) }
                    Sync-SessionIndex $scanDir
                    Write-Host "  Quarantined to backup: $(Split-Path $scanDir -Leaf)\$guid" -ForegroundColor Green
                }
            } else { Write-Host "  Invalid number." }
        }
        return $null
    }

    function Do-DeleteSession($guid, $dir) {
        # Destructive delete: removes JSONL, associated subdirectory, and sessions-index entry
        $projKey = Get-ProjectKey $dir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $jsonlFile = Join-Path $projDirClaude "$guid.jsonl"
        $guidDir = Join-Path $projDirClaude $guid
        if (Test-Path $jsonlFile) { Remove-Item $jsonlFile -Force }
        if (Test-Path $guidDir) { Remove-Item $guidDir -Recurse -Force }
        Sync-SessionIndex $dir
    }

    function Do-ViewArchived {
        while ($true) {
            $archived = Get-ArchivedSessions
            if ($archived.Count -eq 0) {
                Write-Host ""
                Write-Host "  No archived sessions."
                return
            }
            Write-Host ""
            Write-Host "  === Archived Sessions ==="
            Write-Host ""
            for ($i = 0; $i -lt $archived.Count; $i++) {
                $info = Get-SessionInfo $archived[$i].Guid $archived[$i].Dir $archived[$i].Tokens
                Write-Host "  $($i+1). $($archived[$i].Desc)  [$($archived[$i].Dir)]  $($info.Size)"
            }
            Write-Host ""
            Write-Host "  U# = Unarchive   D# = Delete permanently   Q = Back"
            Write-Host ""
            $cmd = Read-Host "  >"
            if (-not $cmd -or $cmd -eq 'q' -or $cmd -eq 'Q') { return }
            if ($cmd -match '^[uU](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $archived.Count) {
                    $entry = $archived[$idx]
                    $archived = @($archived | Where-Object { $_ -ne $entry })
                    Save-ArchivedSessions $archived
                    $sessions = Get-Sessions
                    $sessions = @($entry) + @($sessions)
                    Save-Sessions $sessions
                    Write-Host "  Unarchived: $($entry.Desc)" -ForegroundColor Green
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[dD](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $archived.Count) {
                    Write-Host "  This permanently deletes the conversation file and all associated data." -ForegroundColor Red
                    Write-Host "  This cannot be undone." -ForegroundColor Red
                    $confirm = Read-Host "  Type 'delete' to confirm"
                    if ($confirm -match '^delete$') {
                        $entry = $archived[$idx]
                        Do-DeleteSession $entry.Guid $entry.Dir
                        $archived = @($archived | Where-Object { $_ -ne $entry })
                        Save-ArchivedSessions $archived
                        Write-Host "  Deleted: $($entry.Desc)" -ForegroundColor Green
                    } else { Write-Host "  Cancelled." }
                } else { Write-Host "  Invalid number." }
            }
            else { Write-Host "  Unknown command." }
        }
    }

    function Do-EditList {
        while ($true) {
            $sessions = Get-Sessions
            Write-Host ""
            Write-Host "  === Edit Sessions ==="
            Write-Host ""
            for ($i = 0; $i -lt $sessions.Count; $i++) {
                Write-Host "  $($i+1). $($sessions[$i].Desc)  [$($sessions[$i].Dir)]"
            }
            Write-Host ""
            Write-Host "  R# = Rename   P# = Path   A# = Archive   D# = Delete   M#,# = Move   Q = Done"
            Write-Host ""
            $cmd = Read-Host "  >"
            if (-not $cmd -or $cmd -eq 'q' -or $cmd -eq 'Q') { return }
            if ($cmd -match '^[rR](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    $newName = Read-Host "  New name for '$($sessions[$idx].Desc)'"
                    if ($newName) {
                        $sessions[$idx].Desc = $newName
                        Save-Sessions $sessions
                    }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[pP](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    Write-Host "  Current: $($sessions[$idx].Dir)"
                    $newPath = Read-Host "  New path (Enter to keep)"
                    if ($newPath) {
                        if (-not (Test-Path $newPath)) {
                            Write-Host "  Path does not exist: $newPath"
                            continue
                        }
                        $guid = $sessions[$idx].Guid
                        $oldPath = $sessions[$idx].Dir
                        $oldKey = Get-ProjectKey $oldPath
                        $newKey = Get-ProjectKey $newPath
                        $claudeProj = "$env:USERPROFILE\.claude\projects"
                        $oldFile = "$claudeProj\$oldKey\$guid.jsonl"
                        $newDir = "$claudeProj\$newKey"
                        $newFile = "$newDir\$guid.jsonl"
                        if (Test-Path $oldFile) {
                            if (-not (Test-Path $newDir)) { New-Item -ItemType Directory -Path $newDir -Force | Out-Null }
                            Copy-Item $oldFile $newFile
                            Write-Host "  Session file copied to new project directory."
                        } else {
                            Write-Host "  Warning: Session file not found at old path. Resume may not work."
                        }
                        $sessions[$idx].Dir = $newPath
                        Save-Sessions $sessions
                        Sync-SessionIndex $newPath
                        Sync-SessionIndex $oldPath
                    }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[aA](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    $entry = $sessions[$idx]
                    $sessions = @($sessions | Where-Object { $_ -ne $entry })
                    Save-Sessions $sessions
                    $archived = Get-ArchivedSessions
                    $archived = @($archived) + @($entry)
                    Save-ArchivedSessions $archived
                    Write-Host "  Archived: $($entry.Desc)" -ForegroundColor Green
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[dD](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    Write-Host "  This permanently deletes the conversation file and all associated data." -ForegroundColor Red
                    Write-Host "  This cannot be undone." -ForegroundColor Red
                    $confirm = Read-Host "  Type 'delete' to confirm"
                    if ($confirm -match '^delete$') {
                        $entry = $sessions[$idx]
                        Do-DeleteSession $entry.Guid $entry.Dir
                        $sessions = @($sessions | Where-Object { $_ -ne $entry })
                        Save-Sessions $sessions
                        Write-Host "  Deleted: $($entry.Desc)" -ForegroundColor Green
                    } else { Write-Host "  Cancelled." }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[mM](\d+),(\d+)$') {
                $from = [int]$Matches[1] - 1
                $to = [int]$Matches[2] - 1
                if ($from -ge 0 -and $from -lt $sessions.Count -and $to -ge 0 -and $to -lt $sessions.Count) {
                    $item = $sessions[$from]
                    $list = [System.Collections.ArrayList]@($sessions)
                    $list.RemoveAt($from)
                    $list.Insert($to, $item)
                    $sessions = @($list)
                    Save-Sessions $sessions
                } else { Write-Host "  Invalid numbers." }
            }
            else { Write-Host "  Unknown command." }
        }
    }

    function Do-Trim($currentGuid) {
        if (-not (Test-Path $cmvExe)) {
            Write-Host "  cmv not found. Skipping trim."
            return
        }
        # Pre-trim: clean up stale .cmv-trim-tmp files (older than 5 minutes) in the current
        # project's dir. These are leftovers from prior failed CMV trims.
        $sessions = Get-Sessions
        $entry = $sessions | Where-Object { $_.Guid -eq $currentGuid } | Select-Object -First 1
        if ($entry) {
            $projKey = Get-ProjectKey $entry.Dir
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            if (Test-Path $projDirClaude) {
                $cutoff = (Get-Date).AddMinutes(-5)
                Get-ChildItem "$projDirClaude\*.cmv-trim-tmp" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff } |
                    ForEach-Object {
                        Write-Host "  Cleaned stale CMV temp file: $($_.Name)" -ForegroundColor DarkGray
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    }
            }
        }
        Write-Host "  Trimming session..."
        $trimStartedAt = Get-Date
        $trimOutput = & $cmvExe trim -s $currentGuid --skip-launch 2>&1 | Out-String
        $guidMatch = [regex]::Match($trimOutput, 'Session ID:\s*([0-9a-f-]+)')
        if (-not $guidMatch.Success) {
            Write-Host "  Trim failed or no new session ID found."
            $trimOutput.Split("`n") | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
            return
        }
        $newGuid = $guidMatch.Groups[1].Value
        # Update GUID in sessions.txt
        $sessions = Get-Sessions
        foreach ($s in $sessions) {
            if ($s.Guid -eq $currentGuid) { $s.Guid = $newGuid }
        }
        Save-Sessions $sessions
        # Verify trimmed JSONL landed in the expected project dir.
        # Previously we silently copied the file across project directories if it
        # showed up elsewhere. That hid CMV bugs and caused cross-project contamination.
        # Now we fail loud and let the user investigate.
        $sessions = Get-Sessions
        $entry = $sessions | Where-Object { $_.Guid -eq $newGuid } | Select-Object -First 1
        if ($entry) {
            $projKey = Get-ProjectKey $entry.Dir
            $expectedDir = "$env:USERPROFILE\.claude\projects\$projKey"
            $expectedFile = Join-Path $expectedDir "$newGuid.jsonl"
            if (-not (Test-Path $expectedFile)) {
                $actual = Get-ChildItem "$env:USERPROFILE\.claude\projects\*\$newGuid.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($actual) {
                    Write-Host ""
                    Write-Host "  CMV WROTE THE TRIMMED SESSION TO THE WRONG PROJECT" -ForegroundColor Red
                    Write-Host "  Expected: $expectedFile" -ForegroundColor Red
                    Write-Host "  Actual:   $($actual.FullName)" -ForegroundColor Red
                    Write-Host "  Investigate before resuming. ClaudeCM will NOT silently copy the file."
                } else {
                    Write-Host ""
                    Write-Host "  Trim claimed to create $newGuid but the file is not on disk." -ForegroundColor Red
                }
            }
        }
        $trimOutput.Split("`n") | Where-Object { $_ -notmatch 'Session ID:' -and $_.Trim() } | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
        # Post-trim: clean up any .cmv-trim-tmp files modified during this run that
        # CMV failed to clean up itself.
        if ($entry) {
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$(Get-ProjectKey $entry.Dir)"
            if (Test-Path $projDirClaude) {
                Get-ChildItem "$projDirClaude\*.cmv-trim-tmp" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge $trimStartedAt } |
                    ForEach-Object {
                        Write-Host "  CMV left a temp file behind: $($_.Name); removing." -ForegroundColor DarkGray
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    }
            }
            Sync-SessionIndex $entry.Dir
            $preTrimFile = Join-Path "$env:USERPROFILE\.claude\projects\$(Get-ProjectKey $entry.Dir)" "$currentGuid.jsonl"
            if (Test-Path $preTrimFile) {
                $destSubdir = Join-Path $backupDir (Split-Path $entry.Dir -Leaf)
                if (-not (Test-Path $destSubdir)) { New-Item -ItemType Directory -Path $destSubdir -Force | Out-Null }
                Move-Item $preTrimFile (Join-Path $destSubdir "$currentGuid.jsonl") -Force -ErrorAction SilentlyContinue
                $preTrimSidecar = Join-Path "$env:USERPROFILE\.claude\projects\$(Get-ProjectKey $entry.Dir)" $currentGuid
                if (Test-Path $preTrimSidecar) { Move-Item $preTrimSidecar (Join-Path $destSubdir $currentGuid) -Force -ErrorAction SilentlyContinue }
            }
        }
        Write-Host ""
        Write-Host "  Session trimmed. New ID: $newGuid"
        $script:trimNewGuid = $newGuid
    }

    function Do-Refresh($currentGuid) {
        $sessions = Get-Sessions
        $curSession = $sessions | Where-Object { $_.Guid -eq $currentGuid } | Select-Object -First 1
        $curDesc = "Unnamed"; if ($curSession) { $curDesc = $curSession.Desc }
        $curDir = (Get-Location).Path; if ($curSession) { $curDir = $curSession.Dir }
        Write-Host ""
        $newName = Read-Host "  Name for new session (Enter for '$curDesc')"
        if (-not $newName) { $newName = $curDesc }
        # --- Skeleton extraction ---
        $projKey = Get-ProjectKey $curDir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $oldJsonl = Join-Path $projDirClaude "$currentGuid.jsonl"
        # Per-operation scoped temp dir to avoid concurrent-refresh collisions
        $refreshTempRoot = Join-Path $cmDir "refresh-temp"
        if (-not (Test-Path $refreshTempRoot)) { New-Item -ItemType Directory -Path $refreshTempRoot -Force | Out-Null }
        # Best-effort cleanup of any per-op subdirs older than 24 hours
        $cleanCutoff = (Get-Date).AddHours(-24)
        Get-ChildItem $refreshTempRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cleanCutoff } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        $refreshOpId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$currentGuid"
        $refreshTempDir = Join-Path $refreshTempRoot $refreshOpId
        New-Item -ItemType Directory -Path $refreshTempDir -Force | Out-Null
        $skeletonContent = ""
        $transcriptPath = ""
        # Locate extract-skeleton.mjs: prefer alongside this script, then $env:CLAUDECM_HOME, then user-installed locations
        $extractScript = $null
        $candidates = @()
        if ($PSCommandPath) { $candidates += Join-Path (Split-Path $PSCommandPath -Parent) "extract-skeleton.mjs" }
        if ($env:CLAUDECM_HOME) { $candidates += Join-Path $env:CLAUDECM_HOME "extract-skeleton.mjs" }
        $candidates += @(
            "$env:USERPROFILE\.claudecm\extract-skeleton.mjs",
            "$env:USERPROFILE\.local\share\claudecm\extract-skeleton.mjs"
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c)) { $extractScript = $c; break }
        }
        if ((Test-Path $oldJsonl) -and $extractScript -and (Test-Path $extractScript)) {
            Write-Host ""
            Write-Host "  Extracting session skeleton..."
            $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
            if ($nodeExe) {
                & $nodeExe $extractScript $oldJsonl $curDesc $refreshTempDir 2>&1 | Out-Null
                $skelFile = Join-Path $refreshTempDir "$currentGuid-skeleton.md"
                $txFile = Join-Path $refreshTempDir "$currentGuid-transcript.md"
                if (Test-Path $skelFile) {
                    $skeletonContent = Get-Content $skelFile -Raw
                    Write-Host "  Skeleton extracted." -ForegroundColor Green
                }
                if (Test-Path $txFile) {
                    $transcriptPath = $txFile
                    $txSize = "{0:N0} KB" -f ((Get-Item $txFile).Length / 1KB)
                    Write-Host "  Filtered transcript: $txSize" -ForegroundColor Green
                }
            } else {
                Write-Host "  Node.js not found, skipping skeleton extraction." -ForegroundColor Yellow
            }
        } else {
            if (-not (Test-Path $oldJsonl)) {
                Write-Host "  Old session JSONL not found, skipping skeleton extraction." -ForegroundColor Yellow
            }
            if (-not $extractScript -or -not (Test-Path $extractScript)) {
                Write-Host "  extract-skeleton.mjs not found, skipping skeleton extraction." -ForegroundColor Yellow
            }
        }
        # --- Build recovery prompt ---
        $refreshPrompt = @"
Read your memories. This is a fresh session replacing a long previous conversation
on this project. Everything you need to know is in:

1) Your memory files (MEMORY.md and all linked files)
2) Any documentation in the project directory
3) The codebase itself (git log for history)
4) project_current_state.md in your memory if it exists
"@
        if ($skeletonContent -or $transcriptPath) {
            $refreshPrompt += "`n5) The structured extraction below, produced by mechanical analysis of the`n   conversation log"
            if ($transcriptPath) {
                $refreshPrompt += "`n6) A filtered transcript of the previous session (conversation text and tool call`n   summaries, no tool output) at:`n   $transcriptPath`n   Read this file and identify any key decisions, user corrections, or reasoning`n   that the skeleton below does not capture."
            }
        }
        $refreshPrompt += @"

IMPORTANT:
- The files listed below reflect the state at the end of the previous session.
  Re-read any file before modifying it, as it may have changed since then.
- The errors listed may or may not still be relevant. Verify before acting on them.
- Do not start any development until the user tells you to.
- Tell the user what you understand about the current state of the project,
  what works, what is pending, and what your behavioral rules are.
"@
        if ($skeletonContent) {
            $refreshPrompt += "`n`n--- ADD YOUR NOTES HERE (context, decisions, corrections, anything the skeleton missed) ---`n`n`n`n--- SKELETON START (review and edit as needed) ---`n`n$skeletonContent`n`n--- SKELETON END ---"
        }
        $promptFile = Join-Path $cmDir "refresh-prompt.tmp"
        $refreshPrompt | Set-Content $promptFile -Encoding UTF8
        $editPrompt = Read-Host "  Would you like to view/edit the compaction prompt and skeleton before proceeding? (Save and close when done) [y/N]"
        if ($editPrompt -eq 'y') {
            $proc = Start-Process notepad $promptFile -PassThru
            $proc.WaitForExit()
        }
        $promptText = Get-Content $promptFile -Raw
        Remove-Item $promptFile -ErrorAction SilentlyContinue
        # Run Claude headless from the session directory
        $refreshOrigDir = Get-Location
        Set-Location $curDir
        Write-Host ""
        Write-Host "  Creating fresh session, please wait..."
        $refreshJson = $promptText | & $claudeExe --dangerously-skip-permissions -p --output-format json 2>&1 | Out-String
        Write-Host "  Done."
        Set-Location $refreshOrigDir
        # Capture new session GUID authoritatively from the JSON output (no filesystem guessing).
        $freshGuid = $null
        try {
            $parsed = $refreshJson | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.session_id) { $freshGuid = $parsed.session_id }
        } catch {}
        if (-not $freshGuid) {
            Write-Host "  Warning: Refresh did not create a new session. The old session is unchanged." -ForegroundColor Yellow
            return
        }
        # Rewrite sessions: new at top, old "(old)" at bottom
        $sessions = Get-Sessions
        $oldEntry = $null
        $others = @()
        foreach ($s in $sessions) {
            if ($s.Guid -eq $currentGuid) {
                $baseDesc = $s.Desc -replace '\s*\(old(?:\s+\d+)?\)\s*$', ''
                $usedNums = @()
                foreach ($other in $sessions) {
                    if ($other.Guid -eq $currentGuid) { continue }
                    if ($other.Dir -ne $s.Dir) { continue }
                    $pat = '^' + [regex]::Escape($baseDesc) + '\s*\(old(?:\s+(\d+))?\)\s*$'
                    if ($other.Desc -match $pat) {
                        if ($Matches[1]) { $usedNums += [int]$Matches[1] } else { $usedNums += 1 }
                    }
                }
                if ($usedNums.Count -eq 0) {
                    $oldDesc = "$baseDesc (old)"
                } else {
                    $n = 1
                    while ($usedNums -contains $n) { $n++ }
                    if ($n -eq 1) { $oldDesc = "$baseDesc (old)" } else { $oldDesc = "$baseDesc (old $n)" }
                }
                $oldEntry = [PSCustomObject]@{ Guid=$s.Guid; Dir=$s.Dir; Desc=$oldDesc; Tokens=$s.Tokens }
            } else {
                $others += $s
            }
        }
        # Get token count for fresh session
        $freshTokens = ''
        if (Test-Path $cmvExe) {
            $benchOut = & $cmvExe benchmark -s $freshGuid --json 2>&1 | Out-String
            $tokMatch = [regex]::Match($benchOut, '"preTrimTokens"\s*:\s*(\d+)')
            if ($tokMatch.Success) { $freshTokens = $tokMatch.Groups[1].Value }
        }
        Sync-SessionIndex $curDir
        $freshEntry = [PSCustomObject]@{ Guid=$freshGuid; Dir=$curDir; Desc=$newName; Tokens=$freshTokens }
        $newSessions = @($freshEntry) + @($others)
        if ($oldEntry) { $newSessions += $oldEntry }
        Save-Sessions $newSessions
        Write-Host ""
        Write-Host "  Fresh session created: $newName"
        Write-Host "  Old session moved to bottom of list."
        # Clean up this operation's temp dir (best-effort)
        if (Test-Path $refreshTempDir) {
            Remove-Item $refreshTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Do-PostExit($knownGuid) {
        # Requires an unambiguous session GUID from the caller. The helpers
        # Invoke-FreshLaunchWithDetection (11.6.2) and Invoke-ResumeWithForkDetection
        # (11.6.1) capture the GUID via set-diff snapshot; every caller now passes
        # that GUID. Fallback "newest-in-project-key" scan was removed because it
        # picks stale pre-existing files when the caller couldn't produce a GUID
        # (user bailed at splash, launch produced nothing), which mis-registers.
        Write-Host ""
        Write-Host "  Session ended."
        Write-Host ""
        if (-not $knownGuid) { return }
        $guid = $knownGuid
        # ORDER MATTERS, and it is durable-state-first on purpose. Everything
        # that must survive the console dying (registration, token count, MRU
        # position, session index) happens BEFORE the snapshot spinner and
        # before any question. the operator closes the PowerShell window at this point
        # often enough that it has to be free to do so: the snapshot can take
        # up to two minutes and the trim question waits on a human. Nothing
        # after this line is allowed to hold state that has not been written.
        Save-ExitState $guid
        Save-ExitSnapshot $guid
        $sessions = Get-Sessions
        $curSession = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
        # Show session size and anti-bloat options
        $sizeDisplay = ""
        if ($curSession) {
            $info = Get-SessionInfo $curSession.Guid $curSession.Dir $curSession.Tokens
            $sizeDisplay = "$($info.Size) ($($info.Tokens))"
        }
        if ($sizeDisplay) {
            Write-Host ""
            Write-Host "  Current session: $sizeDisplay"
        }
        Offer-Trim $guid
        if ($script:trimNewGuid) { $guid = $script:trimNewGuid }
        # Anti-bloat: refresh (deeper clean)
        Write-Host ""
        $doRefresh = Read-Host "  Create a new compacted session, built from a structured rebuild of this one? [y/N]"
        if ($doRefresh -eq 'y') {
            Do-Refresh $guid
        }
    }

    function Save-ExitSnapshot($guid) {
        # Auto-snapshot with CMV (now that we have a guid, use -s instead of --latest).
        # Failure of the snapshot job is non-fatal: Do-PostExit's main purpose is
        # to update token counts and offer trim/refresh; snapshot is nice-to-have.
        # If the job crashes or times out, log it and continue.
        if (Test-Path $cmvExe) {
            try {
                $snapLabel = "auto-exit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                $job = Start-Job -ScriptBlock {
                    param($exe, $label, $sid)
                    & $exe snapshot $label -s $sid 2>&1
                } -ArgumentList $cmvExe, $snapLabel, $guid
                $spin = @('-', '\', '|', '/')
                $i = 0
                $spinDeadline = (Get-Date).AddMinutes(2)
                while ($job.State -eq 'Running') {
                    if ((Get-Date) -gt $spinDeadline) {
                        Write-Host "`r  Snapshot exceeded 2-minute timeout; skipping.  "
                        Stop-Job $job -ErrorAction SilentlyContinue
                        break
                    }
                    Write-Host "`r  $($spin[$i % 4]) Saving snapshot..." -NoNewline
                    Start-Sleep -Milliseconds 100
                    $i++
                }
                if ($job.State -eq 'Failed') {
                    Write-Host "`r  Snapshot job failed (non-fatal).        "
                } elseif ($job.State -eq 'Completed') {
                    Write-Host "`r  Done.                        "
                }
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "  Snapshot setup error (non-fatal): $($_.Exception.Message)"
            }
        }
    }

    function Save-ExitState($guid) {
        # Every write sessions.txt needs on exit, done before anything slow or
        # interactive. An unregistered session is registered under the folder
        # name FIRST and renamed afterwards if the operator answers, so closing
        # the window at the prompt costs a name, never the session itself.
        $sessions = Get-Sessions
        # Select-Object -First 1: a duplicated guid must not turn $existing into
        # an array, or Sync-SessionIndex is handed one and the row is doubled.
        $existing = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
        if (-not $existing) {
            $folderName = (Split-Path (Get-Location).Path -Leaf) -replace '-', ' '
            $folderName = (Get-Culture).TextInfo.ToTitleCase($folderName)
            $existing = [PSCustomObject]@{ Guid=$guid; Dir=(Get-Location).Path; Desc=$folderName; Tokens='' }
            Save-Sessions (@($existing) + @($sessions))
            Write-Host ""
            $desc = Read-Host "  Describe this session (Enter for '$folderName', 'skip' to skip)"
            if ($desc -eq 'skip') {
                # An explicit skip still means skip: take the row back out.
                # Only an ANSWERED skip does that, never a closed window.
                Save-Sessions @(Get-Sessions | Where-Object { $_.Guid -ne $guid })
                return
            }
            if ($desc) {
                $sessions = Get-Sessions
                foreach ($s in $sessions) { if ($s.Guid -eq $guid) { $s.Desc = $desc } }
                Save-Sessions $sessions
            }
            $sessions = Get-Sessions
            $existing = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
        }
        if (-not $existing) { return }
        # MRU position first, because it costs one atomic write and no waiting.
        # `cmv benchmark` takes a second or two on a large transcript, and that
        # is a second or two in which the window can close, so nothing that
        # matters is allowed to sit behind it.
        $sessions = @($existing) + @($sessions | Where-Object { $_.Guid -ne $guid })
        Save-Sessions $sessions
        Sync-SessionIndex $existing.Dir
        # Then the token count (use -s, never --latest). The rest of the report
        # is kept for Offer-Trim, which reads it instead of paying for a second
        # benchmark run.
        $script:exitBench = $null
        if (Test-Path $cmvExe) {
            $benchOut = & $cmvExe benchmark -s $guid --json 2>&1 | Out-String
            $tokMatch = [regex]::Match($benchOut, '"preTrimTokens"\s*:\s*(\d+)')
            if ($tokMatch.Success) {
                $sessions = Get-Sessions
                foreach ($s in $sessions) { if ($s.Guid -eq $guid) { $s.Tokens = $tokMatch.Groups[1].Value } }
                Save-Sessions $sessions
            }
            try { $script:exitBench = $benchOut | ConvertFrom-Json } catch { $script:exitBench = $null }
        }
    }

    function Offer-Trim($guid) {
        # Do NOT ask a question whose answer is always no. CMV's auto-trim hooks
        # (PostToolUse + PreCompact) stub oversized tool results in place all
        # session long, so by the time a session exits there is almost nothing
        # left for `cmv trim` to take: measured 2026-09-13 across four live
        # sessions, 2% to 5%. Worse, a trim starts a new session and throws away
        # the prompt cache, so cmv's own projections were NEGATIVE at every
        # horizon under 151 turns. Report the number, and only offer the trim
        # when it is actually worth taking.
        # Clear first: a stale value from an earlier exit in the same console
        # would otherwise be read as "this trim produced a new guid".
        $script:trimNewGuid = $null
        $b = $script:exitBench
        if ($b -and $null -ne $b.reductionPercent) {
            $pct = [int]$b.reductionPercent
            $be = if ($null -ne $b.breakEvenTurns) { [int]$b.breakEvenTurns } else { 0 }
            if ($pct -lt 10) {
                Write-Host ""
                Write-Host ("  Trim would recover {0}% ({1} of {2} tokens); auto-trim has already taken the rest." -f $pct, ($b.preTrimTokens - $b.postTrimTokens), $b.preTrimTokens)
                if ($be -gt 0) { Write-Host ("  It would not pay for the lost prompt cache for another {0} turns. Not offering it." -f $be) }
                return
            }
            Write-Host ""
            Write-Host ("  Trim would recover {0}%, breaking even after {1} turns." -f $pct, $be)
        }
        Write-Host ""
        $doTrim = Read-Host "  Trim this session? [y/N]"
        if ($doTrim -eq 'y') { Do-Trim $guid }
    }

    function Toggle-TalkMode {
        # The mirror of Toggle-DangerousMode. Same shape on purpose: one
        # script-scoped flag, per run, never written to disk, shared by every
        # entry point so it cannot be present at one prompt and missing at the
        # other, which is how D shipped broken the first time.
        $script:launchPlan = -not $script:launchPlan
        if ($script:launchPlan) { $script:launchBypass = $false }
        Write-Host ""
        if ($script:launchPlan) {
            Write-Host "  Talk mode ON. Launches start in plan mode: Claude can read and" -ForegroundColor Cyan
            Write-Host "  answer, and cannot change files until you leave plan mode." -ForegroundColor Cyan
            Write-Host "  Leaving it is one-way and deliberate. Lasts until you quit claudecm."
        } else {
            Write-Host "  Talk mode OFF. Launches start in auto again." -ForegroundColor Green
        }
    }

    function Toggle-DangerousMode {
        # Shared by every entry point, because the first version lived in one
        # of the two "Pick a session" prompts and the operator hit the other.
        $script:launchBypass = -not $script:launchBypass
        if ($script:launchBypass) { $script:launchPlan = $false }
        Write-Host ""
        if ($script:launchBypass) {
            Write-Host "  Dangerous mode ON. Launches will skip ALL permission checks:" -ForegroundColor Yellow
            Write-Host "  no auto-mode classifier, no plan mode, no prompts." -ForegroundColor Yellow
            Write-Host "  This lasts until you quit claudecm. It is never saved to disk."
        } else {
            Write-Host "  Dangerous mode OFF. Launches start in auto again." -ForegroundColor Green
        }
    }

    function Get-PermissionArgs {
        # THE ONE DECISION POINT for how an interactive session starts, so the
        # answer cannot drift between the four launch sites.
        #
        #   normal   --allow-dangerously-skip-permissions --permission-mode auto
        #            Starts in auto. The second flag turns nothing on; it only
        #            makes bypass reachable from the in-session mode cycle.
        #   D chosen --dangerously-skip-permissions
        #            Auto is not merely overridden, it is absent from the
        #            command line. No classifier, no plan mode, no prompts.
        #
        # $script:launchBypass is per RUN of claudecm and is never written to
        # disk. Quitting and starting claudecm again puts it back to normal, so
        # it cannot silently become the default on every project next week.
        #
        # Splatting is safe for THESE values and only these: spec 11.6 forbids
        # splatting free text because PowerShell 5.1 mangles arguments
        # containing spaces. Permission flags contain none. The display name,
        # which does contain spaces, stays positional.
        # EVERY FLAG AND EVERY VALUE IS ITS OWN ELEMENT. Splatting passes one
        # array element as one argv entry, so '--permission-mode auto' in a
        # single string arrives as the literal option "--permission-mode auto"
        # and claude exits with "unknown option". That shipped on 2026-09-14
        # and broke every resume until it was found.
        # `return ,@(...)` NOT `return @(...)`. PowerShell unwraps a
        # single-element array on return, so the one-flag branch came back as a
        # bare STRING, and splatting a string enumerates its characters: claude
        # received `-`, `-`, `d`, `a`, `n`, ... as 31 separate arguments,
        # ignored them, and started in its default mode. Dangerous mode looked
        # like it did nothing. The three-element branch never showed the fault
        # because an array of three survives the unwrap. Same defect class as
        # spec 14.3 and Get-Sessions; the comma operator is the fix there too.
        #   T chosen --permission-mode plan
        #            The mirror of D: a session for talking rather than doing.
        #            Plan mode is a ONE-WAY DOOR, and that is deliberate here.
        #            A hook cannot put a session back into it
        #            (anthropics/claude-code#14044), so leaving it is a thing
        #            the operator does on purpose rather than something that
        #            drifts. D wins if both are somehow set, because the more
        #            permissive choice is the one he made most recently.
        if ($script:launchBypass) { return ,@('--dangerously-skip-permissions') }
        if ($script:launchPlan)   { return ,@('--permission-mode', 'plan') }
        return ,@('--allow-dangerously-skip-permissions', '--permission-mode', 'auto')
    }

    function Invoke-FreshLaunchWithDetection($projectDir, $displayName, $passArgs, $rawDesc) {
        # Fresh launch (no --resume) with set-diff detection of the new session's GUID.
        # Sets $script:lastFreshExit and $script:lastFreshNewGuid. Same output-capture-safe
        # pattern as Invoke-ResumeWithForkDetection: NO return value, callers read script vars.
        # Immune to concurrent writers that touch or create other JSONLs mid-launch
        # except when two fresh launches race in the same project-key dir within one invocation.
        $projKey = Get-ProjectKey $projectDir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        $before = @{}
        if (Test-Path $projDirClaude) {
            Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match $uuidPattern } |
                ForEach-Object { $before[$_.BaseName] = $true }
        }
        # Only for genuinely-new sessions (rawDesc supplied): fire a detached background
        # process that waits, then registers the session if it crashed before exiting.
        # This process is fully independent of this console; it survives if this shell dies.
        try {
            $lateHelper = "$cmDir\register-late-guid.ps1"
            if ($rawDesc -and (Test-Path $lateHelper)) {
                # -ArgumentList rejects any empty-string element, so BeforeGuids is
                # only appended when non-empty (brand-new dirs have no 'before' set).
                # Values are wrapped in escaped quotes: Start-Process -ArgumentList does
                # not auto-quote array elements, so any value containing a space (session
                # names, or project dirs with a space in them) would otherwise be split apart.
                $spArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$lateHelper`"",
                    '-ProjDirClaude', "`"$projDirClaude`"", '-ProjectDir', "`"$projectDir`"",
                    '-Desc', "`"$rawDesc`"", '-SessionsFile', "`"$sessionsFile`"")
                $beforeArg = ($before.Keys -join ',')
                if ($beforeArg) { $spArgs += @('-BeforeGuids', "`"$beforeArg`"") }
                # Watch THIS shell's claude session until it ends, not a fixed
                # five minutes. The conversation file only appears when the first
                # message is sent; a slow opening prompt used to outlast the old
                # window and the session was never registered. See the helper.
                $spArgs += @('-WatchPid', "$PID")
                # pwsh, NEVER powershell.exe. Spawning powershell.exe flips the
                # console to a raster font and resizes the window: an unfixed
                # conhost defect (microsoft/terminal#367), measured on this
                # machine 2026-08-26 as 2 failures out of 2 against 0 out of 3
                # for pwsh. A hidden Start-Process most likely gets its own
                # console and never touches the caller's, so this particular
                # call was probably safe, but the cost of using pwsh is zero and
                # the cost of being wrong is a corrupted terminal. The test
                # suite asserts this module spawns no powershell.exe at all.
                Start-Process -FilePath 'pwsh' -WindowStyle Hidden -ArgumentList $spArgs | Out-Null
            }
        } catch {}
        # AUTO, NOT BYPASS. Changed 2026-09-11.
        #
        # Bypass exists so the operator is not pressing yes all day, and that need is
        # real. But it also switches off plan mode and the auto-mode
        # classifier, which are Claude Code's own protections against an
        # instance acting beyond what was asked. In bypass, "edits stay blocked
        # until you approve the plan" simply does not apply (anthropics/
        # claude-code#39687), so the machine had no authorization layer at all.
        #
        # Auto mode keeps the part he wants, no routine prompts, and restores
        # the part he was missing: a separate classifier model reviews each
        # action first and blocks anything that escalates beyond the request.
        # One model trained for the job beats the word lists tried here, which
        # measured a 13% leak on 100 of his own hand-labelled messages.
        #
        # INTERACTIVE ONLY. The two headless `-p` sites keep bypass: nobody is
        # there to answer if the classifier holds something, and each runs a
        # single scripted prompt, so the surface is small.
        #
        # --allow-dangerously-skip-permissions, added 2026-09-14. It does NOT
        # turn bypass on; it makes bypass SELECTABLE from the in-session mode
        # cycle, which it otherwise is not. The session still starts in auto.
        # The need is real: the auto-mode classifier refuses non-edit actions
        # mid-session and the refusal is sticky, and without this flag the only
        # way out is to kill the session and relaunch with the bypass flag,
        # which loses whatever was in flight. This is the escape hatch, chosen
        # deliberately per session rather than applied to every session.
        # @permFlags is SPLATTING (a variable), not @(...) which would pass the
        # whole array as one argument. The difference is silent and total.
        $permFlags = Get-PermissionArgs
        if ($passArgs -and $passArgs.Count -gt 0) {
            & $claudeExe @permFlags -n $displayName @passArgs
        } else {
            & $claudeExe @permFlags -n $displayName
        }
        $exitCode = $LASTEXITCODE
        $newGuid = $null
        # Detection must run regardless of exit code. The JSONL is written at session
        # start (within ~1s of launch), so it exists by the time we reach this block
        # whether claude exited cleanly (/exit), was Ctrl-C'd, was window-closed, or
        # crashed. Gating detection on $exitCode -eq 0 caused new sessions to silently
        # vanish from sessions.txt whenever the user exited any way other than /exit
        # (spec 14.4).
        if (Test-Path $projDirClaude) {
            $newFiles = @(Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match $uuidPattern -and -not $before.ContainsKey($_.BaseName) })
            if ($newFiles.Count -eq 1) {
                $newGuid = $newFiles[0].BaseName
            } elseif ($newFiles.Count -gt 1) {
                $newGuid = ($newFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).BaseName
            }
        }
        $script:lastFreshExit = $exitCode
        $script:lastFreshNewGuid = $newGuid
        $script:lastFreshAlreadyRegistered = $false
        if ($newGuid) {
            $already = Get-Sessions | Where-Object { $_.Guid -eq $newGuid }
            if ($already) { $script:lastFreshAlreadyRegistered = $true }
        }
    }

    function Test-CleanExitTail($jsonlPath) {
        # Returns $true if the tail of the JSONL shows a clean /exit (trailing
        # user "/exit" command). Claude Code's resume refuses these because the
        # last exchange has no assistant response, which its tail-scan treats as
        # an interrupted state.
        try {
            $tail = Get-Content $jsonlPath -Tail 10 -ErrorAction Stop
            foreach ($line in $tail) {
                if ($line -match '/exit</command-name>') { return $true }
            }
        } catch {}
        return $false
    }

    function Invoke-ResumeWithForkDetection($originalGuid, $projectDir, $displayName) {
        # Claude Code can fork a resumed session to a new JSONL (version upgrades across resumes,
        # deferred-tool recovery, etc). When that happens, the live file's basename differs from
        # the guid we passed to --resume. Detect the fork and update sessions.txt accordingly so
        # the predecessor doesn't become an orphan on next launch.
        $projKey = Get-ProjectKey $projectDir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $predJsonl = Join-Path $projDirClaude "$originalGuid.jsonl"
        $beforeNewest = $null
        if (Test-Path $projDirClaude) {
            $beforeNewest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        Write-Host ""
        Write-Host ""
        # Auto unless D was chosen. See the note at the new-session launch above.
        $permFlags = Get-PermissionArgs
        & $claudeExe @permFlags --resume $originalGuid -n $displayName
        $exitCode = $LASTEXITCODE
        $effectiveGuid = $originalGuid
        # Retry-with-prompt recovery. Claude Code's --resume scans the JSONL tail
        # for a completed exchange. A session that exited via /exit has a trailing
        # user command with no assistant response; Claude treats this as an
        # interrupted state and refuses. Offer the user a one-shot retry with an
        # initial prompt so Claude has something fresh to respond to.
        if ($exitCode -ne 0 -and (Test-Path $predJsonl) -and (Test-CleanExitTail $predJsonl)) {
            Write-Host ""
            Write-Host "  Claude refused to resume. This is a known quirk after a clean /exit."
            Write-Host "  The conversation is intact; Claude just needs an initial prompt to pick up."
            $retryAns = Read-Host "  Would you like to retry with a prompt that says `"please continue`"? [Y/n]"
            if ($retryAns -ne 'n' -and $retryAns -ne 'N') {
                & $claudeExe @permFlags --resume $originalGuid -n $displayName "please continue"
                $exitCode = $LASTEXITCODE
            }
        }
        if ($exitCode -eq 0 -and (Test-Path $projDirClaude)) {
            $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest -and $newest.BaseName -ne $originalGuid -and (-not $beforeNewest -or $newest.BaseName -ne $beforeNewest.BaseName)) {
                $sessions = Get-Sessions
                $found = $false
                foreach ($s in $sessions) {
                    if ($s.Guid -eq $originalGuid) { $s.Guid = $newest.BaseName; $s.Tokens = ''; $found = $true }
                }
                if ($found) { Save-Sessions $sessions }
                $effectiveGuid = $newest.BaseName
                $predFile = Join-Path $projDirClaude "$originalGuid.jsonl"
                if (Test-Path $predFile) {
                    $destSubdir = Join-Path $backupDir (Split-Path $projectDir -Leaf)
                    if (-not (Test-Path $destSubdir)) { New-Item -ItemType Directory -Path $destSubdir -Force | Out-Null }
                    Move-Item $predFile (Join-Path $destSubdir "$originalGuid.jsonl") -Force
                    $predGuidDir = Join-Path $projDirClaude $originalGuid
                    if (Test-Path $predGuidDir) { Move-Item $predGuidDir (Join-Path $destSubdir $originalGuid) -Force }
                    Sync-SessionIndex $projectDir
                }
            }
        }
        $script:lastResumeExit = $exitCode
        $script:lastResumeGuid = $effectiveGuid
    }

    function Move-SessionToTop($guid) {
        $cur = Get-Sessions
        $match = $cur | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
        if (-not $match) { return }
        $rest = $cur | Where-Object { $_.Guid -ne $guid }
        $new = @($match) + @($rest)
        Save-Sessions $new
    }

    function Do-Resume($pick, $sessions) {
        if ($pick -lt 1 -or $pick -gt $sessions.Count) {
            Write-Host "  Invalid selection."
            return
        }
        $sel = $sessions[$pick - 1]
        if (-not (Test-Path $sel.Dir)) {
            Write-Host "  Error: Project directory not found: $($sel.Dir)"
            return
        }
        Move-SessionToTop $sel.Guid
        $origDir = Get-Location
        Set-Location $sel.Dir
        $scanResult = Do-OrphanScan $sel.Dir $sel.Guid
        if ($scanResult -and $scanResult.Action -eq 'select') {
            $displayName = Get-SessionDisplayName $sel.Desc
            Invoke-ResumeWithForkDetection $scanResult.Guid $sel.Dir $displayName
            if ($script:lastResumeExit -eq 0) { Do-PostExit $script:lastResumeGuid }
            Set-Location $origDir
            return
        }
        $recover = Resolve-ResumeOrRecover $sel.Guid $sel.Dir $sel.Desc $sel.Tokens
        if ($recover.Action -eq 'cancel') { Set-Location $origDir; return }
        $displayName = Get-SessionDisplayName $sel.Desc
        if ($recover.Action -eq 'fresh') {
            # Do NOT delete the old entry before launch. After a successful launch,
            # detect the new session via set-diff snapshot (Invoke-FreshLaunchWithDetection).
            Invoke-FreshLaunchWithDetection $sel.Dir $displayName @() $null
            if ($script:lastFreshExit -eq 0 -and $script:lastFreshNewGuid) {
                # Swap GUID in place, preserve desc and dir, reset tokens.
                $sessions = Get-Sessions
                foreach ($s in $sessions) {
                    if ($s.Guid -eq $sel.Guid) { $s.Guid = $script:lastFreshNewGuid; $s.Tokens = '' }
                }
                Save-Sessions $sessions
                Do-PostExit $script:lastFreshNewGuid
            }
            Set-Location $origDir
            return
        }
        if ($recover.Action -eq 'primed') {
            Invoke-ResumeWithForkDetection $recover.Guid $sel.Dir $displayName
            if ($script:lastResumeExit -eq 0) { Do-PostExit $script:lastResumeGuid }
            Set-Location $origDir
            return
        }
        Invoke-ResumeWithForkDetection $sel.Guid $sel.Dir $displayName
        if ($script:lastResumeExit -eq 0) {
            Do-PostExit $script:lastResumeGuid
        } else {
            # Distinguish "JSONL is actually missing" from "Claude refused to resume but the file is there"
            $projKey = Get-ProjectKey $sel.Dir
            $jsonlPath = "$env:USERPROFILE\.claude\projects\$projKey\$($sel.Guid).jsonl"
            if (Test-Path $jsonlPath) {
                Write-Host ""
                Write-Host "  Claude refused to resume this session (file is on disk but Claude won't load it)." -ForegroundColor Yellow
                Write-Host "  Common causes: interrupted tool call, stale deferred-tool marker."
                Write-Host "  The session entry has NOT been deleted. You can try again later or investigate the JSONL."
            } else {
                Write-Host ""
                $delEntry = Read-Host "  Session JSONL is missing. Delete this entry? [Y/n]"
                if ($delEntry -ne 'n') {
                    $sessions = Get-Sessions
                    $sessions = @($sessions | Where-Object { $_.Guid -ne $sel.Guid })
                    Save-Sessions $sessions
                    Write-Host "  Entry removed."
                }
            }
        }
        Set-Location $origDir
    }

    # --- Main ---
    $firstArg = $args[0]

    # Dangerous mode as a command-line verb, consumed here so it never reaches
    # claude. Without this, `claudecm -D` fell through to the pass-through path
    # and claude read it as its own -d/--debug flag, which is what "debug mode
    # enabled" was. Consuming it means `--debug` is still the way to ask claude
    # for debug output; the short form now belongs to claudecm.
    # After the shift, dispatch continues exactly as if the verb was not typed,
    # so `claudecm -D` lands in the session list and `claudecm -D 5` resumes 5.
    if ($firstArg -match '^-{0,2}[dD]$') {
        Toggle-DangerousMode
        $args = @($args | Select-Object -Skip 1)
        $firstArg = $args[0]
    }

    # Talk mode as a command-line verb, consumed here for the same reason: a
    # bare -t must not reach claude, which has its own meaning for short flags.
    if ($firstArg -match '^-{0,2}[tT]$') {
        Toggle-TalkMode
        $args = @($args | Select-Object -Skip 1)
        $firstArg = $args[0]
    }

    # Search mode: show only the sessions whose name contains <text>.
    # The list has outgrown one screen, so this is how you find one without
    # scrolling. Numbers shown are positions in the FILTERED list.
    # All four forms, matching list mode's l / L / -l / -L. PowerShell's -eq is
    # case-insensitive so the upper-case arms are redundant here, but they are
    # spelled out to mirror the rest of this dispatch and the bash module, where
    # [[ == ]] IS case-sensitive and every arm is load-bearing.
    if ($firstArg -eq 's' -or $firstArg -eq 'S' -or $firstArg -eq '-s' -or $firstArg -eq '-S') {
        $term = [string]$args[1]
        if (-not $term.Trim()) {
            Write-Host ""
            Write-Host "  Usage: claudecm s <text>      (s, S, -s and -S all work)"
            Write-Host "  Lists only the sessions whose name contains <text>, case-insensitive."
            Write-Host ""
            return
        }
        $allSessions = Get-Sessions
        # NOT named $matches: that is a PowerShell automatic variable and the
        # -match operator below would overwrite it mid-loop.
        $hits = @($allSessions | Where-Object {
            $_.Desc -and $_.Desc.ToLower().Contains($term.ToLower())
        })
        if ($hits.Count -eq 0) {
            Write-Host ""
            Write-Host "  No sessions matching '$term'."
            Write-Host ""
            return
        }
        while ($true) {
            # Deliberately NOT Show-List: its footer advertises E, V and M,
            # and search mode does not accept them. A menu that offers a key
            # it will reject is the kind of quiet lie this tool exists to
            # avoid. Rendered here to match the bash module's search view.
            Write-Host ""
            Write-Host "  === Sessions matching '$term' ==="
            Write-Host ""
            $descWidth = 10
            foreach ($h in $hits) { if ($h.Desc.Length -gt $descWidth) { $descWidth = $h.Desc.Length } }
            $n = 0
            foreach ($h in $hits) {
                $n++
                $info = Get-SessionInfo $h.Guid $h.Dir $h.Tokens
                Write-Host ("  {0,2}. {1} {2,9}  {3,10}   {4}`t{5}" -f `
                    $n, $h.Desc.PadRight($descWidth + 2), $info.Size, $info.Tokens, $info.Date, $h.Dir)
            }
            Write-Host ""
            Write-Host ("  {0} of {1} sessions matching '{2}'" -f $hits.Count, $allSessions.Count, $term)
            $pick = Read-Host "  Pick a session (Enter to quit)"
            if (-not $pick -or $pick -eq 'q' -or $pick -eq 'Q') { return }
            # Search mode gets D too. It did not, which is half of why the
            # feature looked broken: the same prompt text, two code paths.
            if ($pick -match '^-{0,2}[dD]\w*\.?\s*(\d*)$') {
                Toggle-DangerousMode
                if ($Matches[1]) { $pick = $Matches[1] } else { continue }
            }
            if ($pick -match '^-{0,2}[tT]\w*\.?\s*(\d*)$') {
                Toggle-TalkMode
                if ($Matches[1]) { $pick = $Matches[1] } else { continue }
            }
            if ($pick -match '^\d+$') {
                # Do-Resume only INDEXES the array it is handed; every write
                # path inside it re-reads state with Get-Sessions. Passing the
                # filtered array is therefore safe and cannot truncate
                # sessions.txt.
                Do-Resume ([int]$pick) $hits
                return
            }
            # Deliberately no new-project fallback here. In search mode an
            # unrecognised entry means a mistyped number, never "create a
            # project called that".
            Write-Host "  Enter a number from the list, or press Enter to quit."
        }
    }

    # List mode (also default when invoked with no args)
    if (-not $firstArg -or $firstArg -eq 'l' -or $firstArg -eq 'L' -or $firstArg -eq '-l' -or $firstArg -eq '-L') {
        while ($true) {
            $sessions = Get-Sessions
            if ($sessions.Count -eq 0) {
                Write-Host ""
                Write-Host "  No saved sessions."
                Write-Host ""
                return
            }
            Show-List $sessions
            Write-Host ""
            $pick = Read-Host "  Pick a session (Enter to quit)"
            if (-not $pick -or $pick -eq 'q' -or $pick -eq 'Q') { return }
            if ($pick -eq 'e' -or $pick -eq 'E') {
                Do-EditList
                continue
            }
            if ($pick -eq 'v' -or $pick -eq 'V') {
                Do-ViewArchived
                continue
            }
            # D toggles dangerous mode for the rest of THIS run of claudecm.
            # `D 5` turns it on and resumes 5 in one step, which is the shape
            # this exists for: one project needs it, the others do not.
            if ($pick -match '^-{0,2}[dD]\w*\.?\s*(\d*)$') {
                Toggle-DangerousMode
                if ($Matches[1]) {
                    Do-Resume ([int]$Matches[1]) $sessions
                    return
                }
                continue
            }
            # T is the same shape for talk mode. `T 5` starts 5 in plan mode.
            if ($pick -match '^-{0,2}[tT]\w*\.?\s*(\d*)$') {
                Toggle-TalkMode
                if ($Matches[1]) {
                    Do-Resume ([int]$Matches[1]) $sessions
                    return
                }
                continue
            }
            if ($pick -eq 'm' -or $pick -eq 'M') {
                Write-Host ""
                Write-Host "  Current machine name: $machineName"
                $newMn = Read-Host "  New name (Enter to keep)"
                if ($newMn) {
                    $newMn | Set-Content $machineNameFile
                    $machineName = $newMn
                    Write-Host "  Machine name set to: $machineName" -ForegroundColor Green
                }
                continue
            }
            if ($pick -match '^\d+$') {
                Do-Resume ([int]$pick) $sessions
                return
            }
            # Non-numeric, non-command: this input would create a NEW project.
            # Confirm first. Stray/STT text plus a mistyped pick lands here and
            # would otherwise silently create a garbage-named project.
            Write-Host ""
            $confirmNew = Read-Host "  '$pick' is not a session number. Create a NEW project named '$pick'? [y/N]"
            if (("$confirmNew").Trim() -notmatch '^(y|yes)$') {
                Write-Host "  Cancelled. No project created."
                Write-Host ""
                continue
            }
            # Non-numeric, non-E: treat as new project title
            $safeDirName = $pick.ToLower() -replace '\s+', '-' -replace '[^a-z0-9_-]', ''
            $projBase = "$env:USERPROFILE\Documents\GitHub"
            $newProjDir = Join-Path $projBase $safeDirName
            $counter = 1
            while (Test-Path $newProjDir) {
                $newProjDir = Join-Path $projBase "$safeDirName($counter)"
                $counter++
            }
            New-Item -ItemType Directory -Path $newProjDir -Force | Out-Null
            Write-Host ""
            Write-Host "  Starting new session: $pick"
            Write-Host "  Project dir: $newProjDir"
            $origDir = Get-Location
            Set-Location $newProjDir
            $displayName = Get-SessionDisplayName $pick
            Invoke-FreshLaunchWithDetection $newProjDir $displayName @() $pick
            # Register on detected GUID alone, not exit code. See spec 14.4.
            if ($script:lastFreshNewGuid) {
                if (-not $script:lastFreshAlreadyRegistered) {
                    $sessions = Get-Sessions
                    $newEntry = [PSCustomObject]@{ Guid=$script:lastFreshNewGuid; Dir=$newProjDir; Desc=$pick; Tokens='' }
                    $sessions = @($newEntry) + @($sessions)
                    Save-Sessions $sessions
                }
            }
            Set-Location $origDir
            return
        }
        return
    }

    # Direct resume by number
    if ($firstArg -match '^\d+$') {
        $sessions = Get-Sessions
        if ($sessions.Count -eq 0) {
            Write-Host "  No saved sessions."
            return
        }
        Show-List $sessions ([int]$firstArg)
        Do-Resume ([int]$firstArg) $sessions
        return
    }

    # Normal mode (fresh launch in cwd, or pass-through to claude)
    $projDir = $null
    $passArgs = @()
    $i = 0
    # Strip leading 'n'/'N' if present (explicit "new" verb, mirrors old bare-claudecm behavior)
    if ($args.Count -gt 0 -and ($args[0] -eq 'n' -or $args[0] -eq 'N')) { $i = 1 }
    while ($i -lt $args.Count) {
        if ($args[$i] -eq '--proj' -and ($i + 1) -lt $args.Count) {
            $projDir = $args[$i + 1]
            $i += 2
        } else {
            $passArgs += $args[$i]
            $i++
        }
    }

    $origDir = Get-Location
    if ($projDir) {
        if (-not (Test-Path $projDir)) {
            Write-Host "Error: Directory not found: $projDir"
            return
        }
        Set-Location $projDir
    }

    # Check if current directory matches an existing session
    $curDir = (Get-Location).Path
    $sessions = Get-Sessions
    $match = $sessions | Where-Object { $_.Dir -eq $curDir } | Select-Object -First 1
    $preNamed = $null
    if ($passArgs.Count -eq 0) {
        if ($match) {
            $scanResult = Do-OrphanScan $curDir $match.Guid
            if ($scanResult -and $scanResult.Action -eq 'select') {
                if (-not (Test-Path $match.Dir)) {
                    Write-Host "  Error: Project directory not found: $($match.Dir)"
                    return
                }
                Set-Location $match.Dir
                $displayName = Get-SessionDisplayName $match.Desc
                Invoke-ResumeWithForkDetection $scanResult.Guid $match.Dir $displayName
                if ($script:lastResumeExit -eq 0) { Do-PostExit $script:lastResumeGuid }
                if ($projDir) { Set-Location $origDir }
                return
            }

            Write-Host ""
            Write-Host "  Session found: $($match.Desc)"
            $rename = Read-Host "  Rename? (Enter to keep)"
            if ($rename) {
                $match.Desc = $rename
                Save-Sessions $sessions
            }
            $useExisting = Read-Host "  Resume this session? [Y/n]"
            if ($useExisting -ne 'n') {
                if (-not (Test-Path $match.Dir)) {
                    Write-Host "  Error: Project directory not found: $($match.Dir)"
                    return
                }
                Set-Location $match.Dir
                $recover = Resolve-ResumeOrRecover $match.Guid $match.Dir $match.Desc $match.Tokens
                if ($recover.Action -eq 'cancel') { if ($projDir) { Set-Location $origDir }; return }
                $displayName = Get-SessionDisplayName $match.Desc
                if ($recover.Action -eq 'fresh') {
                    # Do NOT delete the old entry before launch. Detect new GUID via set-diff snapshot.
                    Invoke-FreshLaunchWithDetection $match.Dir $displayName @() $null
                    # Register on detected GUID alone, not exit code. See spec 14.4.
                    if ($script:lastFreshNewGuid) {
                        $sessions = Get-Sessions
                        foreach ($s in $sessions) {
                            if ($s.Guid -eq $match.Guid) { $s.Guid = $script:lastFreshNewGuid; $s.Tokens = '' }
                        }
                        Save-Sessions $sessions
                        Do-PostExit $script:lastFreshNewGuid
                    }
                    if ($projDir) { Set-Location $origDir }
                    return
                }
                if ($recover.Action -eq 'primed') {
                    Invoke-ResumeWithForkDetection $recover.Guid $match.Dir $displayName
                    if ($script:lastResumeExit -eq 0) { Do-PostExit $script:lastResumeGuid }
                    if ($projDir) { Set-Location $origDir }
                    return
                }
                Invoke-ResumeWithForkDetection $match.Guid $match.Dir $displayName
                if ($script:lastResumeExit -eq 0) {
                    Do-PostExit $script:lastResumeGuid
                } else {
                    $projKey = Get-ProjectKey $match.Dir
                    $jsonlPath = "$env:USERPROFILE\.claude\projects\$projKey\$($match.Guid).jsonl"
                    if (Test-Path $jsonlPath) {
                        Write-Host ""
                        Write-Host "  Claude refused to resume this session (file is on disk but Claude won't load it)." -ForegroundColor Yellow
                        Write-Host "  Common causes: interrupted tool call, stale deferred-tool marker."
                        Write-Host "  The session entry has NOT been deleted."
                    } else {
                        Write-Host ""
                        $delEntry = Read-Host "  Session JSONL is missing. Delete this entry? [Y/n]"
                        if ($delEntry -ne 'n') {
                            $sessions = @($sessions | Where-Object { $_.Guid -ne $match.Guid })
                            Save-Sessions $sessions
                            Write-Host "  Entry removed."
                        }
                    }
                }
                if ($projDir) { Set-Location $origDir }
                return
            }
        } else {
            Write-Host ""
            Write-Host "  No session entry found for this directory."
            $folderDefault = (Split-Path (Get-Location).Path -Leaf) -replace '-', ' '
            $folderDefault = (Get-Culture).TextInfo.ToTitleCase($folderDefault)
            $preNamed = Read-Host "  Create a name for this session (Enter for '$folderDefault', 'skip' to skip)"
            if ($preNamed -eq 'skip') { $preNamed = $null }
            elseif (-not $preNamed) { $preNamed = $folderDefault }
        }
    }

    $launchDesc = if ($preNamed) { $preNamed } elseif ($match) { $match.Desc } else { (Split-Path (Get-Location).Path -Leaf) }
    $displayName = Get-SessionDisplayName $launchDesc
    Invoke-FreshLaunchWithDetection $curDir $displayName $passArgs $preNamed
    if ($script:lastFreshExit -ne 0) {
        if ($projDir) { Set-Location $origDir }
        return
    }

    if ($preNamed) {
        # Session was pre-named before launch; register it then run post-exit.
        if ($script:lastFreshNewGuid) {
            if (-not $script:lastFreshAlreadyRegistered) {
                $sessions = Get-Sessions
                $newEntry = [PSCustomObject]@{ Guid=$script:lastFreshNewGuid; Dir=$curDir; Desc=$preNamed; Tokens='' }
                $sessions = @($newEntry) + @($sessions)
                Save-Sessions $sessions
            }
            Do-PostExit $script:lastFreshNewGuid
        }
    } elseif ($script:lastFreshNewGuid) {
        Do-PostExit $script:lastFreshNewGuid
    }

    if ($projDir) { Set-Location $origDir }
}

function lst { Get-ChildItem | Sort-Object LastWriteTime -Descending }

function grep {
    param(
        [Parameter(Position=0, Mandatory)][string]$Pattern,
        [Parameter(Position=1)][string]$Path,
        [Alias('r')][switch]$Recurse,
        [Alias('i')][switch]$CaseInsensitive
    )
    $slsArgs = @{ Pattern = $Pattern }
    if (-not $CaseInsensitive) { $slsArgs['CaseSensitive'] = $true }
    if ($Path) {
        Get-ChildItem -Path $Path -Recurse:$Recurse -File | Select-String @slsArgs
    } elseif ($Recurse) {
        Get-ChildItem -Recurse -File | Select-String @slsArgs
    } else {
        $input | Select-String @slsArgs
    }
}

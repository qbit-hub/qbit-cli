Set-StrictMode -Version Latest

$script:ContextTransferKind = 'qbit-ai-context-transfer'
$script:ContextOfflineKind = 'qbit-ai-context-offline'
$script:ContextTransferSecretPattern = @(
    ('-----BEGIN ' + '[A-Z ]*' + 'PRIVATE KEY-----'),
    ('\b' + 'Bear' + 'er\s+' + '[A-Za-z0-9._\-+/=]{8,}'),
    ('gl' + 'pat-' + '[A-Za-z0-9_\-]{8,}'),
    ('gh' + '[pousr]_' + '[A-Za-z0-9]{16,}'),
    ('s' + 'k-' + '[A-Za-z0-9]{16,}')
) -join '|'

function Get-ContextTransferDirectory {
    param([string]$RepoRoot)
    return (Join-Path $RepoRoot '.ai-bridge/context-transfer')
}

function Get-ContextOfflineMarkerPath {
    param([string]$RepoRoot)
    return (Join-Path $RepoRoot '.ai-bridge/context-offline.json')
}

function Get-ContextFileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })) }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Write-ContextJson {
    param([string]$Path, [object]$Value, [int]$Depth = 16)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $json = $Value | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Read-ContextJson {
    param([string]$Path, [string]$Label)
    try { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) }
    catch { throw "$Label is invalid JSON." }
}

function Assert-ContextCacheClean {
    param([string]$CachePath, [string]$Purpose)
    $dirty = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('status', '--porcelain')).Output
    if (-not [string]::IsNullOrWhiteSpace($dirty)) { throw "AI context cache must be clean before offline $Purpose." }
}

function Set-ImportedContextGitIdentity {
    param([string]$RepoRoot, [string]$CachePath)
    $cacheName = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('config','--get','user.name') -AllowFailure).Output
    $cacheEmail = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('config','--get','user.email') -AllowFailure).Output
    if (-not [string]::IsNullOrWhiteSpace($cacheName) -and -not [string]::IsNullOrWhiteSpace($cacheEmail)) { return }
    $memberName = (Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('config','--get','user.name') -AllowFailure).Output
    $memberEmail = (Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('config','--get','user.email') -AllowFailure).Output
    if (-not [string]::IsNullOrWhiteSpace($memberName) -and -not [string]::IsNullOrWhiteSpace($memberEmail)) {
        Invoke-Git -WorkingDirectory $CachePath -Arguments @('config','user.name',$memberName) | Out-Null
        Invoke-Git -WorkingDirectory $CachePath -Arguments @('config','user.email',$memberEmail) | Out-Null
    }
}

function Assert-ContextExportSafe {
    param([string]$CachePath)
    $cacheFull = [System.IO.Path]::GetFullPath($CachePath).TrimEnd([char[]]@([char]92,[char]47))
    $prefix = $cacheFull + [System.IO.Path]::DirectorySeparatorChar
    $entries = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('ls-files', '--stage')).Output -split "`r?`n"
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    foreach ($entry in $entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry -notmatch '^(\d{6})\s+[0-9a-fA-F]+\s+\d+\t(.+)$') { throw 'AI context export encountered an unrecognized Git index entry.' }
        $mode = $Matches[1]
        $relative = $Matches[2]
        if (@('100644','100755') -notcontains $mode) { throw "AI context export rejects non-regular tracked entries: $relative" }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $cacheFull $relative))
        if (-not (($candidate + [System.IO.Path]::DirectorySeparatorChar).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) { throw 'AI context export path escaped the context repository.' }
        $item = Get-Item -LiteralPath $candidate -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "AI context export rejects symlink/reparse entries: $relative" }
        try { $text = [System.IO.File]::ReadAllText($candidate, $strictUtf8) }
        catch { throw "AI context export only supports UTF-8 text context files: $relative" }
        if ($text -match $script:ContextTransferSecretPattern) { throw "AI context export refused secret-like material in tracked file: $relative" }
    }
}

function Export-ContextOfflineTransfer {
    param([string]$RepoRoot, [string]$CachePath, [object]$Config, [string]$Branch)
    if (-not (Test-Path -LiteralPath (Join-Path $CachePath '.git'))) { throw 'Central AI context cache must exist before offline export.' }
    $actualBranch = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','--abbrev-ref','HEAD')).Output
    if ($actualBranch -ne $Branch) { throw "AI context cache must remain on configured branch '$Branch'." }
    Assert-ContextCacheClean -CachePath $CachePath -Purpose 'export'
    Assert-ContextExportSafe -CachePath $CachePath

    $bridge = Join-Path $RepoRoot '.ai-bridge'
    $transfer = Get-ContextTransferDirectory -RepoRoot $RepoRoot
    $suffix = [guid]::NewGuid().ToString('N')
    $temp = Join-Path $bridge "context-transfer.tmp-$suffix"
    $backup = Join-Path $bridge "context-transfer.backup-$suffix"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $bundlePath = Join-Path $temp 'context.bundle'
    Invoke-Git -WorkingDirectory $CachePath -Arguments @('bundle','create',$bundlePath,$Branch) | Out-Null
    $verify = Invoke-Git -WorkingDirectory $CachePath -Arguments @('bundle','verify',$bundlePath) -AllowFailure
    if ($verify.ExitCode -ne 0) { throw 'Generated AI context bundle failed Git verification.' }

    $contextHead = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
    $memberHead = (Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse','HEAD')).Output
    $memberBranch = (Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse','--abbrev-ref','HEAD')).Output
    . (Join-Path $CachePath 'tooling/context-continuity.ps1')
    $ownerPaths = Get-ContinuityRecordPaths -Repository ([string]$Config.repository) -MemberRoot $RepoRoot
    $previous = Get-ContinuityPrevious -ContextRoot $CachePath -Repository ([string]$Config.repository) -MemberRoot $RepoRoot
    $fingerprint = Get-ContinuityFingerprint -Root $RepoRoot
    $receipt = $null; $continuity = $null
    if ($null -ne $previous.Manifest) {
        if ($previous.ReceiptSource -cne 'scoped') { throw 'Offline export requires a scoped owning checkpoint; checkpoint the reviewed owning Worktree before export.' }
        if ([string]$previous.Manifest.commit -cne $memberHead -or [string]$previous.Manifest.branch -cne $memberBranch -or
            [string]$previous.Manifest.worktreeFingerprint -cne $fingerprint) { throw 'Offline export source changed after its owning checkpoint; create a fresh checkpoint before export.' }
        $session = [string]$previous.Manifest.session
        if ($session -cnotmatch '^sessions/[0-9]{4}/[0-9]{2}/[A-Za-z0-9._-]+\.md$') { throw 'Offline export owning Session path is invalid.' }
        $receipt = [ordered]@{manifest=$ownerPaths.Manifest;state=$ownerPaths.State;handoff=$ownerPaths.Handoff;session=$session;checkpointId=[string]$previous.Manifest.checkpointId;payloadSha256=[string]$previous.Manifest.checkpointPayloadSha256}
        foreach ($pair in @(@($ownerPaths.Manifest,'manifestBlob'),@($ownerPaths.State,'stateBlob'),@($ownerPaths.Handoff,'handoffBlob'),@($session,'sessionBlob'))) {
            $receipt[$pair[1]] = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse',($contextHead+':'+$pair[0]))).Output
        }
        if ($previous.Manifest.PSObject.Properties.Name -contains 'continuity') { $continuity = $previous.Manifest.continuity }
    }
    $bundleHash = Get-ContextFileSha256 -Path $bundlePath
    $manifest = [ordered]@{
        schemaVersion = 2
        kind = $script:ContextTransferKind
        transferId = [guid]::NewGuid().ToString('N')
        createdAt = (Get-Date).ToString('o')
        project = [string]$Config.project
        repository = [string]$Config.repository
        contextBranch = $Branch
        contextRemote = [string]$Config.context.remote
        source = [ordered]@{ contextHead = $contextHead; memberHead = $memberHead; memberBranch = $memberBranch; memberWorktree=$RepoRoot; worktreeId=$ownerPaths.WorktreeId; worktreeFingerprint=$fingerprint; receipt=$receipt }
        bundle = [ordered]@{ file = 'context.bundle'; sha256 = $bundleHash; bytes = (Get-Item -LiteralPath $bundlePath).Length }
        continuity = $continuity
    }
    Write-ContextJson -Path (Join-Path $temp 'manifest.json') -Value $manifest

    try {
        if (Test-Path -LiteralPath $transfer) { Move-Item -LiteralPath $transfer -Destination $backup }
        Move-Item -LiteralPath $temp -Destination $transfer
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    } catch {
        if (-not (Test-Path -LiteralPath $transfer) -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $transfer }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    Write-Output "AI context offline export ready: $transfer"
}

function Assert-ContextTransferManifest {
    param([object]$Manifest, [object]$Config, [string]$Branch)
    $required = @('schemaVersion','kind','createdAt','project','repository','contextBranch','source','bundle','continuity')
    if ([int]$Manifest.schemaVersion -eq 2) { $required += @('transferId','contextRemote') }
    $names = @($Manifest.PSObject.Properties.Name)
    if ($names.Count -ne $required.Count -or @($required | Where-Object { $names -notcontains $_ }).Count -gt 0) { throw 'AI context transfer manifest shape is invalid.' }
    if ([int]$Manifest.schemaVersion -notin @(1,2) -or [string]$Manifest.kind -ne $script:ContextTransferKind) { throw 'Unsupported AI context transfer manifest.' }
    if ([int]$Manifest.schemaVersion -eq 1 -and $null -ne $Manifest.continuity -and [string]$Manifest.continuity.mode -eq 'tracked') { throw 'Legacy tracked offline transfer lacks scoped ownership proof; re-export with transfer schemaVersion 2.' }
    if ([int]$Manifest.schemaVersion -eq 2 -and ([string]$Manifest.transferId -cnotmatch '^[0-9a-f]{32}$' -or [string]$Manifest.contextRemote -cne [string]$Config.context.remote)) { throw 'AI context transfer identity/remote does not match this repository config.' }
    if ([string]$Manifest.project -ne [string]$Config.project) { throw 'AI context transfer project does not match this repository config.' }
    if ([string]$Manifest.repository -ne [string]$Config.repository) { throw 'AI context transfer repository does not match this repository config.' }
    if ([string]$Manifest.contextBranch -ne $Branch) { throw 'AI context transfer branch does not match this repository config.' }
    if ([string]$Manifest.source.contextHead -notmatch '^[0-9a-fA-F]{40,64}$') { throw 'AI context transfer source contextHead is invalid.' }
    if ([string]$Manifest.bundle.file -ne 'context.bundle') { throw 'AI context transfer bundle path is invalid.' }
    if ([string]$Manifest.bundle.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'AI context transfer bundle hash is invalid.' }
    if ([long]$Manifest.bundle.bytes -le 0) { throw 'AI context transfer bundle size is invalid.' }
}

function Write-ContextOfflineMarker {
    param([string]$RepoRoot, [object]$Config, [string]$Branch, [string]$Remote, [string]$SourceHead, [string]$CurrentHead, [string]$BundleHash, [object]$OwnershipTransfer = $null, [ValidateSet(1,2)][int]$SchemaVersion = 2)
    $marker = [ordered]@{
        schemaVersion = $SchemaVersion
        kind = $script:ContextOfflineKind
        importedAt = (Get-Date).ToString('o')
        project = [string]$Config.project
        repository = [string]$Config.repository
        contextBranch = $Branch
        contextRemote = $Remote
        sourceContextHead = $SourceHead
        currentContextHead = $CurrentHead
        bundleSha256 = $BundleHash
    }
    if ($SchemaVersion -eq 2) { $marker['ownershipTransfer'] = $OwnershipTransfer }
    Write-ContextJson -Path (Get-ContextOfflineMarkerPath -RepoRoot $RepoRoot) -Value $marker
}

function Import-ContextOfflineTransfer {
    param([string]$RepoRoot, [string]$CachePath, [object]$Config, [string]$Branch, [string]$Remote)
    $transfer = Get-ContextTransferDirectory -RepoRoot $RepoRoot
    $manifestPath = Join-Path $transfer 'manifest.json'
    $bundlePath = Join-Path $transfer 'context.bundle'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) { throw 'AI context offline transfer is incomplete; expected .ai-bridge/context-transfer/manifest.json and context.bundle.' }
    $manifest = Read-ContextJson -Path $manifestPath -Label 'AI context transfer manifest'
    Assert-ContextTransferManifest -Manifest $manifest -Config $Config -Branch $Branch
    if ((Get-Item -LiteralPath $bundlePath).Length -ne [long]$manifest.bundle.bytes) { throw 'AI context transfer bundle size does not match the manifest.' }
    $bundleHash = Get-ContextFileSha256 -Path $bundlePath
    if ($bundleHash -cne ([string]$manifest.bundle.sha256).ToLowerInvariant()) { throw 'AI context transfer bundle SHA-256 does not match the manifest.' }
    $verify = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('bundle','verify',$bundlePath) -AllowFailure
    if ($verify.ExitCode -ne 0) { throw 'AI context transfer Git bundle verification failed.' }
    $heads = (Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('bundle','list-heads',$bundlePath,"refs/heads/$Branch")).Output -split "`r?`n"
    $heads = @($heads | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($heads.Count -ne 1) { throw 'AI context transfer bundle does not contain exactly the configured context branch.' }
    $bundleHead = ($heads[0] -split '\s+')[0]
    $sourceHead = [string]$manifest.source.contextHead
    if ($bundleHead.ToLowerInvariant() -ne $sourceHead.ToLowerInvariant()) { throw 'AI context transfer bundle HEAD does not match the manifest provenance.' }

    if (Test-Path -LiteralPath (Join-Path $CachePath '.git')) {
        Assert-ContextCacheClean -CachePath $CachePath -Purpose 'import'
        $actualBranch = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','--abbrev-ref','HEAD')).Output
        if ($actualBranch -ne $Branch) { throw "AI context cache must remain on configured branch '$Branch'." }
        $current = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
        if ($current.ToLowerInvariant() -ne $sourceHead.ToLowerInvariant()) { throw 'AI context offline import conflicts with the existing context cache HEAD; destructive reconciliation was refused.' }
    } else {
        if (Test-Path -LiteralPath $CachePath) {
            $children = @(Get-ChildItem -LiteralPath $CachePath -Force -ErrorAction SilentlyContinue)
            if ($children.Count -gt 0) { throw 'AI context cache path exists but is not an empty import target.' }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $CachePath) -Force | Out-Null
        $clone = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('clone','--branch',$Branch,'--single-branch','--',$bundlePath,$CachePath) -AllowFailure
        if ($clone.ExitCode -ne 0) { throw 'Unable to import central AI context from the verified offline bundle.' }
        $current = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
        if ($current.ToLowerInvariant() -ne $sourceHead.ToLowerInvariant()) {
            Remove-Item -LiteralPath $CachePath -Recurse -Force -ErrorAction SilentlyContinue
            throw 'Imported AI context HEAD does not match transfer provenance.'
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $CachePath 'tooling/context-lifecycle.ps1') -PathType Leaf)) { throw 'Imported AI context bundle is missing PowerShell lifecycle tooling.' }
    $currentHead = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
    $ownershipTransfer = $null
    if ([int]$manifest.schemaVersion -eq 2) {
        . (Join-Path $CachePath 'tooling/context-continuity.ps1')
        $ownershipTransfer = New-ContinuityOfflineOwnershipTransfer -ContextRoot $CachePath -Repository ([string]$Config.repository) -MemberRoot $RepoRoot -Transfer $manifest -ManifestPath $manifestPath -BundlePath $bundlePath -Importing
    }
    # Do not alter an existing cache's origin/identity until every provenance
    # check passes. Rejected imports preserve the original Git configuration.
    Invoke-Git -WorkingDirectory $CachePath -Arguments @('remote','set-url','origin',$Remote) | Out-Null
    Invoke-Git -WorkingDirectory $CachePath -Arguments @('branch','--unset-upstream') -AllowFailure | Out-Null
    Set-ImportedContextGitIdentity -RepoRoot $RepoRoot -CachePath $CachePath
    Write-ContextOfflineMarker -RepoRoot $RepoRoot -Config $Config -Branch $Branch -Remote $Remote -SourceHead $sourceHead -CurrentHead $currentHead -BundleHash $bundleHash -OwnershipTransfer $ownershipTransfer -SchemaVersion ([int]$manifest.schemaVersion)
    Write-Output "AI context offline import ready: $currentHead"
}

function Get-ContextOfflineMarker {
    param([string]$RepoRoot, [string]$CachePath, [object]$Config, [string]$Branch, [string]$Remote)
    $path = Get-ContextOfflineMarkerPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $marker = Read-ContextJson -Path $path -Label 'AI context offline marker'
    $required = @('schemaVersion','kind','importedAt','project','repository','contextBranch','contextRemote','sourceContextHead','currentContextHead','bundleSha256')
    if ([int]$marker.schemaVersion -eq 2) { $required += 'ownershipTransfer' }
    $names = @($marker.PSObject.Properties.Name)
    if ($names.Count -ne $required.Count -or @($required | Where-Object { $names -notcontains $_ }).Count -gt 0 -or [int]$marker.schemaVersion -notin @(1,2) -or [string]$marker.kind -ne $script:ContextOfflineKind) { throw 'AI context offline marker is invalid.' }
    if ([string]$marker.project -ne [string]$Config.project -or [string]$marker.repository -ne [string]$Config.repository) { throw 'AI context offline marker does not match this repository config.' }
    if ([string]$marker.contextBranch -ne $Branch -or [string]$marker.contextRemote -ne $Remote) { throw 'AI context offline marker remote/branch does not match this repository config.' }
    if (-not (Test-Path -LiteralPath (Join-Path $CachePath '.git'))) { throw 'AI context offline marker exists but the imported context cache is missing.' }
    $head = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
    if ($head.ToLowerInvariant() -ne ([string]$marker.currentContextHead).ToLowerInvariant()) { throw 'AI context offline marker does not match the imported context cache HEAD.' }
    return $marker
}

function Update-ContextOfflineMarkerHead {
    param([string]$RepoRoot, [string]$CachePath, [object]$Config, [string]$Branch, [string]$Remote, [object]$Marker)
    $head = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
    $ownershipTransfer = if ($Marker.PSObject.Properties.Name -contains 'ownershipTransfer') { $Marker.ownershipTransfer } else { $null }
    Write-ContextOfflineMarker -RepoRoot $RepoRoot -Config $Config -Branch $Branch -Remote $Remote -SourceHead ([string]$Marker.sourceContextHead) -CurrentHead $head -BundleHash ([string]$Marker.bundleSha256) -OwnershipTransfer $ownershipTransfer -SchemaVersion ([int]$Marker.schemaVersion)
}

function Reconnect-ContextOffline {
    param([string]$RepoRoot, [string]$CachePath, [object]$Config, [string]$Branch, [string]$Remote)
    $marker = Get-ContextOfflineMarker -RepoRoot $RepoRoot -CachePath $CachePath -Config $Config -Branch $Branch -Remote $Remote
    if ($null -eq $marker) { throw 'AI context reconnect requires an imported offline context marker.' }
    if ([int]$marker.schemaVersion -eq 2) {
        . (Join-Path $CachePath 'tooling/context-continuity.ps1')
        Get-ContinuityOfflineOwnershipTransfer -ContextRoot $CachePath -Repository ([string]$Config.repository) -MemberRoot $RepoRoot | Out-Null
    }
    Assert-ContextCacheClean -CachePath $CachePath -Purpose 'reconnect'
    Invoke-Git -WorkingDirectory $CachePath -Arguments @('remote','set-url','origin',$Remote) | Out-Null
    $fetch = Invoke-GitNetwork -WorkingDirectory $CachePath -Arguments @('fetch','origin',$Branch) -Remote $Remote -AllowFailure
    if ($fetch.ExitCode -ne 0) { throw 'Unable to reconnect AI context remote; offline state was preserved.' }

    $remoteRef = "origin/$Branch"
    $remoteHeadResult = Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse',$remoteRef) -AllowFailure
    if ($remoteHeadResult.ExitCode -ne 0) { throw 'AI context reconnect could not resolve the configured remote branch; offline state was preserved.' }
    $remoteHead = $remoteHeadResult.Output
    $localHead = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
    $remoteIsAncestor = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('merge-base','--is-ancestor',$remoteHead,$localHead) -AllowFailure).ExitCode -eq 0
    $localIsAncestor = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('merge-base','--is-ancestor',$localHead,$remoteHead) -AllowFailure).ExitCode -eq 0

    if ($remoteIsAncestor) {
        $push = Invoke-GitNetwork -WorkingDirectory $CachePath -Arguments @('push','origin',"HEAD:$Branch") -Remote $Remote -AllowFailure
        if ($push.ExitCode -ne 0) {
            Invoke-GitNetwork -WorkingDirectory $CachePath -Arguments @('fetch','origin',$Branch) -Remote $Remote -AllowFailure | Out-Null
            throw 'AI context offline reconnect push was rejected because the remote changed; offline state was preserved for explicit reconciliation.'
        }
        Invoke-GitNetwork -WorkingDirectory $CachePath -Arguments @('fetch','origin',$Branch) -Remote $Remote -AllowFailure | Out-Null
    } elseif ($localIsAncestor) {
        $ff = Invoke-Git -WorkingDirectory $CachePath -Arguments @('merge','--ff-only',$remoteRef) -AllowFailure
        if ($ff.ExitCode -ne 0) { throw 'AI context offline reconnect fast-forward failed; offline state was preserved.' }
    } else {
        throw 'AI context offline reconciliation conflict: local and remote context histories diverged; automatic merge/rebase was refused.'
    }

    Invoke-Git -WorkingDirectory $CachePath -Arguments @('branch','--set-upstream-to',$remoteRef,$Branch) -AllowFailure | Out-Null
    Remove-Item -LiteralPath (Get-ContextOfflineMarkerPath -RepoRoot $RepoRoot) -Force
    $head = (Invoke-Git -WorkingDirectory $CachePath -Arguments @('rev-parse','HEAD')).Output
    Write-Output "AI context reconnected: $head"
}

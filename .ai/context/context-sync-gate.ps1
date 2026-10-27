#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$MemberPath,
  [ValidateSet('Start','Status','Verify','Checkpoint')][string]$Mode = 'Verify',
  [ValidateRange(1,1440)][int]$MaxAgeMinutes = 120,
  [ValidateRange(1,300)][int]$TimeoutSeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Fail([string]$Why) { throw "CONTEXT_UNSYNCED: $Why" }
function Quote-Argument([string]$Value) {
  return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Run-Checked([string]$Program,[string[]]$Arguments) {
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$Program
  $psi.Arguments=(@($Arguments|ForEach-Object {Quote-Argument $_}) -join ' ')
  $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
  $psi.StandardOutputEncoding=New-Object Text.UTF8Encoding($false,$true)
  $psi.StandardErrorEncoding=New-Object Text.UTF8Encoding($false,$true)
  $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT']='0'
  $proc=New-Object Diagnostics.Process
  $proc.StartInfo=$psi
  try {
    [void]$proc.Start()
    $out=$proc.StandardOutput.ReadToEndAsync(); $err=$proc.StandardError.ReadToEndAsync()
    if(-not $proc.WaitForExit($TimeoutSeconds*1000)) {
      # Kill the child tree as well, so a timed-out checkpoint cannot keep writing.
      & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
      Fail 'verification timed out; preserve the cache and inspect the pending checkpoint before retry'
    }
    if($proc.ExitCode -ne 0){Fail ("command failed ("+[IO.Path]::GetFileName($Program)+", exit "+$proc.ExitCode+"); inspect lifecycle status and pending checkpoint; check credentials, remote, or divergent history")}
    return $out.GetAwaiter().GetResult().Trim()
  } finally {$proc.Dispose()}
}
function Invoke-GitChecked([string[]]$ArgsList) {
  try {return Run-Checked (Get-Command git.exe -ErrorAction Stop).Source (@('-c','core.longpaths=true')+$ArgsList)}
  catch { $verb=if($ArgsList[0] -eq '-C'){$ArgsList[2]}else{$ArgsList[0]}; Fail ("Git "+$verb+" verification failed: "+$_.Exception.Message) }
}
function Lifecycle([string]$Root,[string]$Action) {
  $launcher=Join-Path $Root '.ai\context\context.ps1'
  if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { Fail "member launcher missing" }
  Run-Checked (Get-Command powershell.exe -ErrorAction Stop).Source @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,$Action) | Out-Null
}
function Assert-Synced([string]$Root,$Config,[datetime]$NotBefore,[bool]$Fresh) {
  $rtFile=Join-Path $Root '.ai-bridge\context-runtime.json'
  $mdFile=Join-Path $Root '.ai-bridge\context-runtime.md'
  foreach($p in @($rtFile,$mdFile)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Fail "runtime evidence missing" }
    $f=Get-Item -LiteralPath $p
    if ($f.Length -eq 0) { Fail "runtime evidence empty" }
    if ($Fresh -and $f.LastWriteTimeUtc -lt $NotBefore.AddSeconds(-3)) { Fail "start did not refresh runtime evidence" }
    $age=([datetime]::UtcNow-$f.LastWriteTimeUtc).TotalMinutes
    if($age -gt $MaxAgeMinutes -or $age -lt -5){Fail "runtime evidence stale"}
  }
  try { $rt=Get-Content -Encoding UTF8 -LiteralPath $rtFile -Raw | ConvertFrom-Json }
  catch { Fail "runtime JSON invalid" }
  if ($rt.schemaVersion -ne 1 -or $rt.project -ne $Config.project -or $rt.repository -ne $Config.repository) { Fail "runtime schema or member identity mismatch" }
  $runtimeTime=if($rt.generatedAt -is [DateTime]){[DateTimeOffset]$rt.generatedAt}else{[DateTimeOffset]::Parse([string]$rt.generatedAt,[Globalization.CultureInfo]::InvariantCulture)}
  $runtimeAge=([DateTimeOffset]::UtcNow-$runtimeTime).TotalMinutes
  if($runtimeAge -lt -5 -or $runtimeAge -gt $MaxAgeMinutes){Fail 'runtime timestamp stale or future dated'}
  if (-not $rt.member -or -not $rt.context -or -not $rt.membership) { Fail "runtime diagnostic structure incomplete" }
  if (-not $rt.membership.registered -or -not $rt.membership.projectMatches) { Fail "member not registered" }
  if ($rt.context.freshness -ne 'CURRENT_OR_FETCHED') { Fail "context freshness unhealthy" }
  $memberHead=Invoke-GitChecked @('-C',$Root,'rev-parse','HEAD')
  if ([string]$rt.member.head -ne $memberHead) { Fail "runtime member HEAD stale" }
  if([string]::IsNullOrWhiteSpace([string]$rt.member.fingerprint)){Fail 'current-source fingerprint missing'}
  if([IO.Path]::GetFullPath([string]$rt.member.root).TrimEnd('\') -ine $Root.TrimEnd('\')){Fail 'runtime Worktree identity mismatch'}
  $cache=Join-Path $Root ([string]$Config.context.cachePath)
  if (-not (Test-Path -LiteralPath $cache -PathType Container)) { Fail "context cache missing" }
  $head=Invoke-GitChecked @('-C',$cache,'rev-parse','HEAD')
  $origin=Invoke-GitChecked @('-C',$cache,'remote','get-url','origin')
  $remote=[string]$Config.context.remote
  if($remote -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://' -and $remote -notmatch '^[^\\/]+@[^:]+:'){
    if(-not [IO.Path]::IsPathRooted($remote)){$remote=Join-Path $Root $remote}
    $remote=[IO.Path]::GetFullPath($remote).TrimEnd('\','/')
    $origin=[IO.Path]::GetFullPath($origin).TrimEnd('\','/')
  }
  if($origin.TrimEnd('/') -ne $remote.TrimEnd('/')){Fail 'cache origin differs from canonical configured remote'}
  if ([string]$rt.context.head -ne $head) { Fail "runtime cache HEAD mismatched" }
  $dirty=Invoke-GitChecked @('-C',$cache,'status','--porcelain','--untracked-files=normal')
  if($dirty){Fail "context cache dirty"}
  $branch=[string]$Config.context.branch
  if ($branch -notmatch '^[a-zA-Z0-9._/-]+$' -or $branch -match '\.\.|//|^/|/$') { Fail "unsafe branch" }
  if (-not $remote -or $remote -match '^[a-z]+://[^/]*@') { Fail "unsafe central remote" }
  $ref='refs/heads/'+$branch
  $ls=Invoke-GitChecked @('ls-remote','--exit-code',$remote,$ref)
  $matches=@($ls -split '[\r\n]+' | Where-Object { $_ -match ('^([0-9a-f]{40})\s+'+[regex]::Escape($ref)+'$') })
  if($matches.Count -ne 1){Fail "remote head unavailable"}
  $remoteHead=($matches[0] -split '\s+')[0]
  if($remoteHead -ne $head){Fail "central published head differs from local cache"}
  return [pscustomobject]@{Root=$Root;Member=$Config.repository;Head=$head;RootHead=$memberHead;RootFingerprint=[string]$rt.member.fingerprint;RootBranch=[string]$rt.member.branch;RootDirty=[string]$rt.member.dirty}
}
function Resolve-ReceiptPaths([string]$Cache,[string]$Root,[string]$Repository) {
  $normalized=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([char]92,[char]47)).Replace([char]92,[char]47).ToLowerInvariant()
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$id='wt-'+(-join($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))|ForEach-Object{$_.ToString('x2')})).Substring(0,32)}finally{$sha.Dispose()}
  $manifest='manifests/worktrees/'+$Repository+'/'+$id+'.json'
  $state='state/worktrees/'+$Repository+'/'+$id+'.md'
  $handoff='handoffs/worktrees/'+$Repository+'/'+$id+'.md'
  if(Test-Path -LiteralPath (Join-Path $Cache $manifest) -PathType Leaf){
    return [pscustomobject]@{Manifest=$manifest;State=$state;Handoff=$handoff;WorktreeId=$id;Scoped=$true}
  }
  $legacy='manifests/repositories/'+$Repository+'.json'
  if(-not(Test-Path -LiteralPath (Join-Path $Cache $legacy) -PathType Leaf)){Fail 'published member manifest absent'}
  $record=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $Cache $legacy) -Raw|ConvertFrom-Json
  if(($record.PSObject.Properties.Name -contains 'worktreeId') -or ($record.PSObject.Properties.Name -contains 'receiptPaths')){Fail 'published Worktree receipt absent; repository summary is not current Worktree authority'}
  if([IO.Path]::GetFullPath([string]$record.memberWorktree).TrimEnd('\') -ine $Root.TrimEnd('\')){Fail 'published Manifest does not represent the current owning source state'}
  return [pscustomobject]@{Manifest=$legacy;State=('state/repositories/'+$Repository+'.md');Handoff=('handoffs/repositories/'+$Repository+'.md');WorktreeId=$id;Scoped=$false}
}
function Assert-PublishedValidationLedger([string]$Cache,[string]$Publication,[string]$CurrentHead,[string]$Repository,$Continuity) {
  # Derive this path independently: a Manifest cannot redirect validation proof
  # to an unrelated repository or replace append-only history with a new file.
  $relative='validation/repositories/'+$Repository+'.json'
  if($Continuity.PSObject.Properties.Name -notcontains 'validationLedgerPath' -or
     [string]$Continuity.validationLedgerPath -cne $relative){Fail 'published validation ledger path mismatch'}
  try {
    $published=Invoke-GitChecked @('-C',$Cache,'show',($Publication+':'+$relative)) | ConvertFrom-Json
    $current=Invoke-GitChecked @('-C',$Cache,'show',($CurrentHead+':'+$relative)) | ConvertFrom-Json
  } catch {Fail 'published validation ledger absent or invalid'}
  foreach($ledger in @($published,$current)){
    if($null -eq $ledger -or $ledger.PSObject.Properties.Name -notcontains 'schemaVersion' -or
       $ledger.PSObject.Properties.Name -notcontains 'repository' -or
       $ledger.PSObject.Properties.Name -notcontains 'entries' -or
       [int]$ledger.schemaVersion -ne 2 -or [string]$ledger.repository -cne $Repository -or
       $ledger.entries -isnot [array]){Fail 'published validation ledger schema or repository mismatch'}
  }
  $oldEntries=@($published.entries);$newEntries=@($current.entries)
  if($newEntries.Count -lt $oldEntries.Count){Fail 'validation ledger lost previously published entries'}
  for($index=0;$index -lt $oldEntries.Count;$index++){
    if(($oldEntries[$index]|ConvertTo-Json -Depth 30 -Compress) -cne
       ($newEntries[$index]|ConvertTo-Json -Depth 30 -Compress)){Fail 'validation ledger entries changed after publication'}
  }
  $seen=@{}
  foreach($entry in $newEntries){
    if($null -eq $entry -or $entry.PSObject.Properties.Name -notcontains 'id' -or
       [string]::IsNullOrWhiteSpace([string]$entry.id) -or $seen.ContainsKey([string]$entry.id)){
      Fail 'validation ledger entry identities missing or duplicated'
    }
    $seen[[string]$entry.id]=$true
  }
  # A sibling Worktree may append its own valid evidence. Historical entries
  # remain immutable; their validFor fingerprint is not this owner's source.
}
# The same validator is embedded in the central engine and strict member gate.
# It reads committed coordination evidence; it never manufactures an owner receipt.
function Invoke-ContinuityReviewGit([string]$Root,[string[]]$Arguments,[switch]$AllowFailure) {
    $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { $output=@(& git.exe -c core.longpaths=true -C $Root @Arguments 2>&1); $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$old }
    if($code -ne 0 -and -not $AllowFailure){throw 'CONTEXT_UNSYNCED: reviewed legacy Git provenance could not be verified.'}
    return [pscustomobject]@{Code=$code;Text=($output -join "`n").Trim().TrimStart([char]0xFEFF)}
}
function Test-ContinuityReviewWorkingBlob([string]$Root,[string]$Path,[string]$Blob) {
    if(-not(Test-Path -LiteralPath (Join-Path $Root $Path) -PathType Leaf)){return $false}
    # A clone may check out LF blobs as CRLF, while historical blobs may already
    # contain CRLF. Accept the exact raw or Git-cleaned blob, never trimmed text.
    $raw=(Invoke-ContinuityReviewGit $Root @('hash-object','--no-filters','--',$Path)).Text
    return $raw -ceq $Blob -or (Invoke-ContinuityReviewGit $Root @('hash-object','--',$Path)).Text -ceq $Blob
}
function Assert-ContinuityReviewKeys($Value,[string[]]$Keys) {
    if($null -eq $Value -or $Value -isnot [pscustomobject]){throw 'CONTEXT_UNSYNCED: reviewed legacy record shape is invalid.'}
    $actual=@($Value.PSObject.Properties.Name|Sort-Object);$expected=@($Keys|Sort-Object)
    if(($actual -join '|') -cne ($expected -join '|')){throw 'CONTEXT_UNSYNCED: reviewed legacy record has missing or unknown fields.'}
}
function Assert-ContinuityReviewPath([string]$Root,[string]$Relative) {
    if($Relative -notmatch '^[A-Za-z0-9._/-]+$' -or $Relative -match '(^|/)\.\.(/|$)|//|^/|/$|\\'){throw 'CONTEXT_UNSYNCED: reviewed legacy path is unsafe.'}
    $current=[IO.Path]::GetFullPath($Root)
    foreach($part in $Relative.Split('/')) {
        $current=Join-Path $current $part
        if((Test-Path -LiteralPath $current) -and (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'CONTEXT_UNSYNCED: reviewed legacy path traverses a reparse point.'}
    }
}
function Get-ContinuityReviewWorktreeId([string]$MemberRoot) {
    $normalized=[IO.Path]::GetFullPath($MemberRoot).TrimEnd([char[]]@([char]92,[char]47)).Replace([char]92,[char]47).ToLowerInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
    return 'wt-'+$digest.Substring(0,32)
}
function Get-ContinuityLegacyReview([string]$ContextRoot,[string]$Repository,[string]$MemberRoot) {
    if($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){throw 'CONTEXT_UNSYNCED: reviewed legacy repository identity is invalid.'}
    $relative='references/continuity-reconciliations/'+$Repository+'.json'
    Assert-ContinuityReviewPath $ContextRoot $relative
    $recordPath=Join-Path $ContextRoot $relative
    $blob=Invoke-ContinuityReviewGit $ContextRoot @('rev-parse',('HEAD:'+$relative)) -AllowFailure
    if($blob.Code -ne 0) {
        if(Test-Path -LiteralPath $recordPath){throw 'CONTEXT_UNSYNCED: legacy reconciliation must be canonically committed before enrollment.'}
        return $null
    }
    if(-not(Test-ContinuityReviewWorkingBlob $ContextRoot $relative $blob.Text)){throw 'CONTEXT_UNSYNCED: legacy reconciliation differs from its committed record.'}
    $record=(Invoke-ContinuityReviewGit $ContextRoot @('show',('HEAD:'+$relative))).Text|ConvertFrom-Json
    Assert-ContinuityReviewKeys $record @('schemaVersion','kind','project','repository','contextRemote','baseCommit','review','legacy','workstream','enrollments')
    if($record.schemaVersion -ne 1 -or [string]$record.kind -cne 'independent-root-enrollment' -or [string]$record.repository -cne $Repository){throw 'CONTEXT_UNSYNCED: reviewed legacy identity or schema is invalid.'}
    Assert-ContinuityReviewPath $MemberRoot '.ai/context/config.json'
    $config=Get-Content -LiteralPath (Join-Path $MemberRoot '.ai/context/config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$record.project -cne [string]$config.project -or [string]$record.contextRemote -cne [string]$config.context.remote -or
       [string]$record.contextRemote -cne (Invoke-ContinuityReviewGit $ContextRoot @('remote','get-url','origin')).Text){throw 'CONTEXT_UNSYNCED: reviewed legacy canonical project or remote differs.'}
    Assert-ContinuityReviewKeys $record.review @('decision','authority','provenance')
    if([string]$record.review.decision -cne 'preserve-unbound-and-enroll-independent-roots' -or
       [string]::IsNullOrWhiteSpace([string]$record.review.authority) -or $record.review.provenance -is [string] -or @($record.review.provenance).Count -eq 0){throw 'CONTEXT_UNSYNCED: explicit reviewed enrollment decision is required.'}
    foreach($item in @($record.review.provenance)){if($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)){throw 'CONTEXT_UNSYNCED: review provenance is incomplete.'}}
    # An enrollment record is immutable after its first canonical addition.
    $added=@((Invoke-ContinuityReviewGit $ContextRoot @('log','--reverse','--format=%H','--diff-filter=A','HEAD','--',$relative)).Text -split "`r?`n"|Where-Object {$_})
    if($added.Count -ne 1 -or $added[0] -notmatch '^[0-9a-f]{40,64}$' -or
       (Invoke-ContinuityReviewGit $ContextRoot @('rev-parse',($added[0]+':'+$relative))).Text -cne $blob.Text){throw 'CONTEXT_UNSYNCED: reviewed legacy record was replaced; preserve it for explicit reconciliation.'}
    $reviewCommit=$added[0]
    if([string]$record.baseCommit -notmatch '^[0-9a-f]{40,64}$' -or [string]$record.baseCommit -ceq $reviewCommit){throw 'CONTEXT_UNSYNCED: reviewed legacy base commit is invalid.'}
    $null=Invoke-ContinuityReviewGit $ContextRoot @('merge-base','--is-ancestor',[string]$record.baseCommit,$reviewCommit)
    $null=Invoke-ContinuityReviewGit $ContextRoot @('merge-base','--is-ancestor',$reviewCommit,'HEAD')
    $expectedPaths=@(('manifests/repositories/'+$Repository+'.json'),('state/repositories/'+$Repository+'.md'),('handoffs/repositories/'+$Repository+'.md'))
    if($record.legacy -is [string] -or @($record.legacy).Count -ne 3){throw 'CONTEXT_UNSYNCED: all three original legacy records must be preserved.'}
    $protected=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach($entry in @($record.legacy)) {
        Assert-ContinuityReviewKeys $entry @('path','blob')
        $path=[string]$entry.path
        if($expectedPaths -cnotcontains $path -or $seen.ContainsKey($path) -or [string]$entry.blob -notmatch '^[0-9a-f]{40,64}$'){throw 'CONTEXT_UNSYNCED: reviewed legacy protected paths are invalid.'}
        $seen[$path]=$true;Assert-ContinuityReviewPath $ContextRoot $path
        foreach($revision in @([string]$record.baseCommit,'HEAD')) {
            if((Invoke-ContinuityReviewGit $ContextRoot @('rev-parse',($revision+':'+$path))).Text -cne [string]$entry.blob){throw 'CONTEXT_UNSYNCED: protected legacy record changed from its reviewed Git blob.'}
        }
        if(-not(Test-ContinuityReviewWorkingBlob $ContextRoot $path ([string]$entry.blob))){throw 'CONTEXT_UNSYNCED: protected legacy working bytes changed.'}
        $protected.Add([pscustomobject]@{path=$path;blob=[string]$entry.blob})
    }
    $legacy=(Invoke-ContinuityReviewGit $ContextRoot @('show',('HEAD:'+ $expectedPaths[0]))).Text|ConvertFrom-Json
    if([string]$legacy.repository -cne $Repository -or ($legacy.PSObject.Properties.Name -contains 'memberWorktree') -or
       ($legacy.PSObject.Properties.Name -contains 'worktreeId') -or ($legacy.PSObject.Properties.Name -contains 'receiptPaths') -or
       -not($legacy.PSObject.Properties.Name -contains 'continuity') -or [string]$legacy.continuity.mode -cne 'tracked'){throw 'CONTEXT_UNSYNCED: reconciliation may preserve only genuinely unbound tracked legacy records.'}
    Assert-ContinuityReviewKeys $record.workstream @('id','sourceCommit','path','blob','disposition')
    $wsId=[string]$record.workstream.id;$wsPath=[string]$record.workstream.path
    if($wsId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $wsId -cne [string]$legacy.continuity.workstreamId -or
       $wsPath -cnotin @(('workstreams/active/'+$wsId+'.json'),('workstreams/archive/'+$wsId+'.json')) -or
       [string]$record.workstream.sourceCommit -notmatch '^[0-9a-f]{40,64}$' -or [string]$record.workstream.blob -notmatch '^[0-9a-f]{40,64}$'){throw 'CONTEXT_UNSYNCED: reviewed legacy workstream provenance is invalid.'}
    Assert-ContinuityReviewPath $ContextRoot $wsPath
    $null=Invoke-ContinuityReviewGit $ContextRoot @('merge-base','--is-ancestor',[string]$record.workstream.sourceCommit,$reviewCommit)
    foreach($revision in @([string]$record.workstream.sourceCommit,'HEAD')) {
        if((Invoke-ContinuityReviewGit $ContextRoot @('rev-parse',($revision+':'+$wsPath))).Text -cne [string]$record.workstream.blob){throw 'CONTEXT_UNSYNCED: reviewed legacy workstream Git blob changed.'}
    }
    if(-not(Test-ContinuityReviewWorkingBlob $ContextRoot $wsPath ([string]$record.workstream.blob))){throw 'CONTEXT_UNSYNCED: reviewed legacy workstream bytes changed.'}
    $ws=(Invoke-ContinuityReviewGit $ContextRoot @('show',('HEAD:'+$wsPath))).Text|ConvertFrom-Json
    if([string]$ws.id -cne $wsId -or -not($ws.PSObject.Properties.Name -contains 'lastCheckpoint') -or
       ($ws.lastCheckpoint.PSObject.Properties.Name -contains 'memberWorktree') -or ($ws.lastCheckpoint.PSObject.Properties.Name -contains 'worktreeId')){throw 'CONTEXT_UNSYNCED: a bound workstream cannot use unknown-owner enrollment.'}
    $terminal=@('COMPLETED','CANCELLED','SUPERSEDED') -ccontains [string]$ws.status
    if($terminal) {
        if([string]$record.workstream.disposition -cne 'historical-contributor-superseded' -or $wsPath -cne ('workstreams/archive/'+$wsId+'.json') -or
           $null -ne $ws.cursor.currentItemId -or @($ws.items|Where-Object {@('COMPLETED','CANCELLED','SUPERSEDED') -cnotcontains [string]$_.status}).Count -ne 0){throw 'CONTEXT_UNSYNCED: historical supersession requires exact terminal archive evidence.'}
    } elseif([string]$record.workstream.disposition -cne 'preserved-unbound-proposed' -or [string]$ws.status -cne 'PROPOSED' -or
             $wsPath -cne ('workstreams/active/'+$wsId+'.json') -or [string]$ws.lastCheckpoint.repository -cne $Repository -or
             [string]$ws.lastCheckpoint.session -cne [string]$legacy.session -or @($ws.items|Where-Object {[string]$_.status -cne 'PENDING'}).Count -ne 0) {
        throw 'CONTEXT_UNSYNCED: unresolved legacy work is not eligible for independent proposed-intent preservation.'
    }
    if($record.enrollments -is [string] -or @($record.enrollments).Count -eq 0){throw 'CONTEXT_UNSYNCED: explicit current roots must be reviewed.'}
    $currentId=Get-ContinuityReviewWorktreeId $MemberRoot;$enrollment=$null;$ids=@{};$targetIds=@{}
    foreach($entry in @($record.enrollments)) {
        Assert-ContinuityReviewKeys $entry @('memberWorktree','worktreeId','scope','workstreamId')
        if(-not[IO.Path]::IsPathRooted([string]$entry.memberWorktree) -or [string]$entry.worktreeId -cne (Get-ContinuityReviewWorktreeId ([string]$entry.memberWorktree)) -or
           $ids.ContainsKey([string]$entry.worktreeId) -or [string]$entry.scope -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
           [string]$entry.workstreamId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or [string]$entry.workstreamId -ceq $wsId -or $targetIds.ContainsKey([string]$entry.workstreamId)){throw 'CONTEXT_UNSYNCED: reviewed independent-root scope is invalid or duplicated.'}
        $ids[[string]$entry.worktreeId]=$true;$targetIds[[string]$entry.workstreamId]=$true
        if([string]$entry.worktreeId -ceq $currentId){$enrollment=$entry}
    }
    $proof=[pscustomobject]@{reviewPath=$relative;reviewBlob=$blob.Text;reviewCommit=$reviewCommit;baseCommit=[string]$record.baseCommit;files=@($protected|Sort-Object path);workstreamPath=$wsPath;workstreamBlob=[string]$record.workstream.blob}
    return [pscustomobject]@{Proof=$proof;Enrollment=$enrollment;Evidence=[pscustomobject]@{disposition=[string]$record.workstream.disposition;historicalOwnerRoot='UNKNOWN';receipt=$false;reviewPath=$relative;reviewBlob=$blob.Text;protectedFiles=$proof.files;workstream=$ws}}
}
# End shared reviewed legacy validator.

function Assert-PublishedCheckpoint([string]$Cache,$Current,$Config) {
  $receipt=Resolve-ReceiptPaths $Cache $Current.Root ([string]$Config.repository)
  $relative=$receipt.Manifest
  $manifest=Invoke-GitChecked @('-C',$Cache,'show',($Current.Head+':'+$relative)) | ConvertFrom-Json
  if($manifest.schemaVersion -ne 1 -or $manifest.repository -ne $Config.repository -or
     $manifest.project -ne $Config.project -or $manifest.commit -ne $Current.RootHead -or
     $manifest.worktreeFingerprint -ne $Current.RootFingerprint -or
     [string]$manifest.branch -ne $Current.RootBranch -or [string]$manifest.dirty -ne $Current.RootDirty -or
     [IO.Path]::GetFullPath([string]$manifest.memberWorktree).TrimEnd('\') -ine $Current.Root.TrimEnd('\')){
    Fail 'published Manifest does not represent the current owning source state'
  }
  if([string]$manifest.checkpointPayloadSha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$manifest.checkpointId -notmatch '^[a-fA-F0-9]{32}$'){Fail 'checkpoint identity or payload digest missing'}
  if($receipt.Scoped -and ([string]$manifest.worktreeId -cne $receipt.WorktreeId -or
     [string]$manifest.receiptPaths.manifest -cne $receipt.Manifest -or
     [string]$manifest.receiptPaths.state -cne $receipt.State -or
     [string]$manifest.receiptPaths.handoff -cne $receipt.Handoff)){Fail 'published Worktree receipt paths or identity mismatch'}
  $legacyReview=Get-ContinuityLegacyReview $Cache ([string]$Config.repository) $Current.Root
  $hasLegacyProof=$manifest.PSObject.Properties.Name -contains 'legacyPreservation'
  if(($null -ne $legacyReview) -ne $hasLegacyProof -or
     ($hasLegacyProof -and ($manifest.legacyPreservation|ConvertTo-Json -Depth 30 -Compress) -cne ($legacyReview.Proof|ConvertTo-Json -Depth 30 -Compress))){Fail 'published legacy preservation proof differs from its independently derived canonical review'}
  if(-not $manifest.continuity -or $manifest.continuity.schemaVersion -ne 2 -or @('snapshot','tracked') -notcontains [string]$manifest.continuity.mode){Fail 'published checkpoint requires Continuity v2'}
  $generated=if($manifest.generatedAt -is [DateTime]){[DateTimeOffset]$manifest.generatedAt}else{[DateTimeOffset]::Parse([string]$manifest.generatedAt,[Globalization.CultureInfo]::InvariantCulture)}
  $age=([DateTimeOffset]::UtcNow-$generated).TotalMinutes
  if($age -lt -5 -or $age -gt $MaxAgeMinutes){Fail 'published checkpoint expired or future dated'}
  $publication=Invoke-GitChecked @('-C',$Cache,'log','-1','--format=%H',$Current.Head,'--',$relative)
  if(-not $publication){Fail 'Manifest publication commit absent'}
  if($null -ne $legacyReview){
    $null=Invoke-GitChecked @('-C',$Cache,'merge-base','--is-ancestor',[string]$legacyReview.Proof.reviewCommit,$publication)
    $protectedPaths=@($legacyReview.Proof.files)+@([pscustomobject]@{path=$legacyReview.Proof.workstreamPath;blob=$legacyReview.Proof.workstreamBlob},[pscustomobject]@{path=$legacyReview.Proof.reviewPath;blob=$legacyReview.Proof.reviewBlob})
    foreach($protected in $protectedPaths){
      if((Invoke-GitChecked @('-C',$Cache,'rev-parse',($publication+':'+[string]$protected.path))) -cne [string]$protected.blob){Fail 'published checkpoint changed protected legacy bytes'}
    }
  }
  Assert-PublishedValidationLedger $Cache $publication $Current.Head ([string]$Config.repository) $manifest.continuity
  $record=$receipt.State
  $session=[string]$manifest.session
  if($session -notmatch '^sessions/[0-9]{4}/[0-9]{2}/[a-zA-Z0-9._-]+\.md$'){Fail 'invalid published Session path'}
  $changed=Invoke-GitChecked @('-C',$Cache,'diff-tree','--root','--no-commit-id','--name-only','-r',$publication)
  if(@($changed -split '[\r\n]+') -notcontains $record){Fail 'owning state and Manifest were not committed together'}
  $added=Invoke-GitChecked @('-C',$Cache,'diff-tree','--root','--no-commit-id','--diff-filter=A','--name-only','-r',$publication,'--',$session)
  if($added -ne $session){Fail 'Session was not newly created by Manifest publication'}
  $first=Invoke-GitChecked @('-C',$Cache,'log','--reverse','--format=%H','--diff-filter=A',$Current.Head,'--',$session)
  if($first -ne $publication){Fail 'reused historical Session'}
  $state=Invoke-GitChecked @('-C',$Cache,'show',($Current.Head+':'+$record))
  if(-not $state.Contains($session)){Fail 'owning state Session mismatch'}
  $boundPaths=@($record,$session)
  if($receipt.Scoped){
    if(@($changed -split '[\r\n]+') -notcontains $receipt.Handoff){Fail 'Worktree handoff was not committed with Manifest'}
    $handoffText=Invoke-GitChecked @('-C',$Cache,'show',($Current.Head+':'+$receipt.Handoff))
    if(-not $handoffText.Contains($session)){Fail 'Worktree handoff Session mismatch'}
    $boundPaths+=$receipt.Handoff
  }
  foreach($boundPath in $boundPaths){
    $publishedBlob=Invoke-GitChecked @('-C',$Cache,'rev-parse',($publication+':'+$boundPath))
    $currentBlob=Invoke-GitChecked @('-C',$Cache,'rev-parse',($Current.Head+':'+$boundPath))
    if($publishedBlob -ne $currentBlob){Fail 'checkpoint state or Session changed after the Manifest publication'}
  }
  $sessionText=Invoke-GitChecked @('-C',$Cache,'show',($publication+':'+$session))
  if(-not $sessionText.Contains(('Checkpoint ID: '+[string]$manifest.checkpointId)) -or
     -not $sessionText.ToLowerInvariant().Contains(('Checkpoint payload SHA256: '+[string]$manifest.checkpointPayloadSha256).ToLowerInvariant())){Fail 'Session checkpoint identity or payload digest mismatch'}
  $pendingPayload=Join-Path $Current.Root '.ai-bridge/context-checkpoint.json'
  if(Test-Path -LiteralPath $pendingPayload -PathType Leaf){
    if((Get-FileHash -LiteralPath $pendingPayload -Algorithm SHA256).Hash -ne [string]$manifest.checkpointPayloadSha256){Fail 'unpublished durable decisions or checkpoint payload remain pending'}
  }
  if($manifest.continuity.mode -eq 'tracked'){
    $wsPath=[string]$manifest.continuity.workstreamPath
    if($wsPath -notmatch '^workstreams/(active|archive)/[a-zA-Z0-9._-]+\.json$' -or @($changed -split '[\r\n]+') -notcontains $wsPath){Fail 'Workstream was not committed with Manifest'}
    $ws=Invoke-GitChecked @('-C',$Cache,'show',($Current.Head+':'+$wsPath)) | ConvertFrom-Json
    if((Invoke-GitChecked @('-C',$Cache,'rev-parse',($publication+':'+$wsPath))) -ne
       (Invoke-GitChecked @('-C',$Cache,'rev-parse',($Current.Head+':'+$wsPath)))){Fail 'Workstream changed after Manifest publication'}
    if($ws.id -ne $manifest.continuity.workstreamId -or $ws.status -ne $manifest.continuity.workstreamStatus -or
       $ws.cursor.currentItemId -ne $manifest.continuity.currentItemId -or $ws.lastCheckpoint.session -ne $session -or
       [string]::IsNullOrWhiteSpace([string]$ws.cursor.nextAction) -or -not $state.Contains([string]$ws.cursor.nextAction)){Fail 'published Workstream cursor or Session mismatch'}
    if($receipt.Scoped -and ([string]$ws.lastCheckpoint.worktreeId -cne $receipt.WorktreeId -or
       [IO.Path]::GetFullPath([string]$ws.lastCheckpoint.memberWorktree).TrimEnd('\') -ine $Current.Root.TrimEnd('\'))){Fail 'published Workstream belongs to another Worktree owner'}
  } elseif($manifest.continuity.workstreamId){Fail 'Snapshot has an active Workstream'}
  return $manifest
}
try {
  if (-not (Test-Path -LiteralPath $MemberPath -PathType Container)) { Fail "member root missing" }
  $root=(Resolve-Path -LiteralPath $MemberPath).Path
  $gitRoot=Invoke-GitChecked @('-C',$root,'rev-parse','--show-toplevel')
  if ([IO.Path]::GetFullPath($root).TrimEnd('\') -ine [IO.Path]::GetFullPath($gitRoot).TrimEnd('\')) { Fail "must target repository root" }
  $configFile=Join-Path $root '.ai\context\config.json'
  if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { Fail "configuration missing" }
  try { $cfg=Get-Content -Encoding UTF8 -LiteralPath $configFile -Raw|ConvertFrom-Json }
  catch { Fail "configuration malformed" }
  if($cfg.schemaVersion -ne 1 -or $cfg.project -notmatch '^[a-z0-9][a-z0-9._-]*$' -or $cfg.repository -notmatch '^[a-z0-9][a-z0-9._-]*$' -or -not $cfg.context -or -not $cfg.context.cachePath){Fail "configuration incomplete or unsupported"}
  $path=[string]$cfg.context.cachePath
  if([IO.Path]::IsPathRooted($path) -or $path -match '(^|[\\/])\.\.([\\/]|$)'){Fail "unsafe cache path"}
  $started=[datetime]::UtcNow
  if($Mode -eq 'Start'){
    Lifecycle $root 'start'
    $result=Assert-Synced $root $cfg $started $true
    Write-Host "CONTEXT_SYNC_OK: Start $($result.Member) $($result.Head)"
    exit 0
  }
  if($Mode -eq 'Status'){
    $result=Assert-Synced $root $cfg $started $false
    Write-Host "CONTEXT_STATUS_OK: $($result.Member) $($result.Head); milestone checkpoint not verified"
    exit 0
  }
  if($Mode -eq 'Verify'){
    # Require prior Start evidence, then independently regenerate current source.
    $null=Assert-Synced $root $cfg $started $false
    Lifecycle $root 'status'
    $result=Assert-Synced $root $cfg $started $true
    $null=Assert-PublishedCheckpoint (Join-Path $root $path) $result $cfg
    Write-Host "CONTEXT_SYNC_OK: Verify $($result.Member) $($result.Head)"
    exit 0
  }
  $payload=Join-Path $root '.ai-bridge\context-checkpoint.json'
  if(-not (Test-Path -LiteralPath $payload -PathType Leaf)){Fail "checkpoint payload missing"}
  try{$cp=Get-Content -Encoding UTF8 -LiteralPath $payload -Raw|ConvertFrom-Json}
  catch{Fail "checkpoint payload invalid JSON"}
  if($cp.schemaVersion -ne 2 -or $cp.repository -ne $cfg.repository -or -not $cp.continuity){
    Fail "schema v2 checkpoint and matching repository/continuity required"
  }
  $expectedPayloadHash=(Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
  $journalFile=Join-Path $root '.ai-bridge/context-checkpoint-pending.json'
  $retryJournal=$null
  if(Test-Path -LiteralPath $journalFile -PathType Leaf){
    $candidate=Get-Content -Encoding UTF8 -LiteralPath $journalFile -Raw | ConvertFrom-Json
    if($candidate.payloadSha256 -eq $expectedPayloadHash -and $candidate.repository -eq $cfg.repository -and
       [IO.Path]::GetFullPath([string]$candidate.memberRoot).TrimEnd('\') -ieq $root.TrimEnd('\')){$retryJournal=$candidate}
  }
  if($null -ne $retryJournal){
    # The engine validates exact journal/source/file/commit identity under its
    # exclusive lock. A partially published local HEAD need not equal remote yet.
    $before=[pscustomobject]@{Head=[string]$retryJournal.baseCommit}
  } else {$before=Assert-Synced $root $cfg $started $false}
  Lifecycle $root 'checkpoint'
  # Recompute member Git state after the publication, not from the previous
  # start/checkpoint runtime. This catches source edits after capture.
  Lifecycle $root 'status'
  $after=Assert-Synced $root $cfg $started $false
  if($before.Head -eq $after.Head){Fail "checkpoint did not produce a new commit"}
  $cache=Join-Path $root $path
  $receipt=Resolve-ReceiptPaths $cache $root ([string]$cfg.repository)
  $memberRecord=$receipt.State
  $record=Join-Path $cache $memberRecord
  if(-not (Test-Path -LiteralPath $record -PathType Leaf)){Fail "published member state missing"}
  # An unrelated Context writer can advance main while the member's state
  # record remains unchanged. New HEAD alone is never a checkpoint receipt.
  $ancestry=Invoke-GitChecked @('-C',$cache,'merge-base','--is-ancestor',$before.Head,$after.Head)
  $changedRecord=Invoke-GitChecked @('-C',$cache,'diff','--name-only',$before.Head,$after.Head,'--',$memberRecord)
  if($changedRecord -ne $memberRecord){
    Fail "published Context advanced without a changed state record for this member"
  }
  # Bind the publication to the checkpoint payload, not just an incidental
  # change to the member's status file. The canonical engine writes a per-member
  # manifest and a freshly added session with the exact checkpoint metadata.
  $manifestRelative=$receipt.Manifest
  $changedManifest=Invoke-GitChecked @('-C',$cache,'diff','--name-only',$before.Head,$after.Head,'--',$manifestRelative)
  if($changedManifest -ne $manifestRelative){Fail "member provenance manifest was not published"}
  $manifestFile=Join-Path $cache $manifestRelative
  if(-not(Test-Path -LiteralPath $manifestFile -PathType Leaf)){Fail "member provenance manifest absent"}
  try{$manifest=Get-Content -Encoding UTF8 -LiteralPath $manifestFile -Raw|ConvertFrom-Json}
  catch{Fail "member provenance manifest invalid JSON"}
  if([string]$manifest.checkpointPayloadSha256 -ne $expectedPayloadHash -or
     [string]$manifest.repository -ne [string]$cfg.repository -or
     [string]$manifest.commit -ne [string]$after.RootHead -or
     [string]::IsNullOrWhiteSpace([string]$after.RootFingerprint) -or
     [string]$manifest.worktreeFingerprint -ne [string]$after.RootFingerprint -or
     [string]$manifest.branch -ne [string]$after.RootBranch -or
     [string]$manifest.dirty -ne [string]$after.RootDirty -or
     [string]$manifest.scope -ne [string]$cp.scope -or
     [string]$manifest.status -ne [string]$cp.status){
    Fail "published member manifest does not match the submitted checkpoint"
  }
  if(-not $manifest.continuity -or [string]$manifest.continuity.mode -ne [string]$cp.continuity.mode){
    Fail "published Continuity mode does not match the submitted checkpoint"
  }
  $session=[string]$manifest.session
  if($session -notmatch '^sessions/[0-9]{4}/[0-9]{2}/[a-zA-Z0-9._-]+\.md$'){
    Fail "published checkpoint session path is invalid"
  }
  $addedSession=Invoke-GitChecked @('-C',$cache,'diff','--diff-filter=A','--name-only',$before.Head,$after.Head,'--',$session)
  if($addedSession -ne $session){Fail "published checkpoint did not create its declared session"}
  $stateText=Get-Content -Encoding UTF8 -LiteralPath $record -Raw
  if(-not $stateText.Contains([string]$cp.nextAction) -or -not $stateText.Contains($session)){
    Fail "published member state is not bound to this checkpoint next action and session"
  }
  $workstream=$cp.continuity.workstream
  if($null -ne $workstream){
    if([string]$manifest.continuity.workstreamId -ne [string]$workstream.id -or
       [string]$manifest.continuity.workstreamStatus -ne [string]$workstream.status -or
       [string]$manifest.continuity.currentItemId -ne [string]$workstream.cursor.currentItemId){
      Fail "published active Workstream/cursor does not match the submitted checkpoint"
    }
    $workstreamRelative=[string]$manifest.continuity.workstreamPath
    if($workstreamRelative -notmatch '^workstreams/(active|archive)/[a-zA-Z0-9._-]+\.json$'){
      Fail "published active Workstream path invalid"
    }
    $changedWorkstream=Invoke-GitChecked @('-C',$cache,'diff','--name-only',$before.Head,$after.Head,'--',$workstreamRelative)
    if($changedWorkstream -ne $workstreamRelative){Fail "declared Workstream was not published"}
    try{$publishedWorkstream=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $cache ($workstreamRelative.Replace('/','\'))) -Raw|ConvertFrom-Json}
    catch{Fail "published Workstream JSON invalid"}
    if([string]$publishedWorkstream.id -ne [string]$workstream.id -or
       [string]$publishedWorkstream.lastCheckpoint.session -ne $session -or
       [string]$publishedWorkstream.cursor.nextAction -ne [string]$cp.nextAction){
      Fail "published Workstream does not reference the expected session and cursor"
    }
  } elseif([string]$manifest.continuity.workstreamId){
    Fail "a snapshot checkpoint cannot publish an unrelated active Workstream"
  }
  $null=Assert-PublishedCheckpoint $cache $after $cfg
  Write-Host "CONTEXT_SYNC_OK: Checkpoint $($after.Member) $($after.Head)"
  exit 0
} catch {
  $message=[string]$_.Exception.Message
  if(-not $message.StartsWith('CONTEXT_UNSYNCED:')){$message='CONTEXT_UNSYNCED: invalid configuration, runtime, or checkpoint evidence; preserve local files and rerun Start/status after diagnosis'}
  [Console]::Error.WriteLine($message)
  exit 3
}

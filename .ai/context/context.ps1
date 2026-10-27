param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'status', 'checkpoint', 'audit', 'export', 'import', 'reconnect')]
    [string]$Action = 'start'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'context-transfer.ps1')

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -c core.longpaths=true -C $WorkingDirectory @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
    [pscustomobject]@{ ExitCode = $code; Output = ($output -join "`n").Trim() }
}

function Get-GitHubCredentialPrefix {
    param([string]$Remote)

    if ($Remote -notmatch '^https?://github\.com(?:/|$)') { return @() }
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $gh) { return @() }

    return @(
        '-c', 'credential.helper=',
        '-c', 'credential.helper=!gh auth git-credential'
    )
}

function Invoke-GitNetwork {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Remote,
        [switch]$NoWorkingDirectory,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($NoWorkingDirectory) {
            $output = @(& git -c core.longpaths=true @Arguments 2>&1)
        } else {
            $output = @(& git -c core.longpaths=true -C $WorkingDirectory @Arguments 2>&1)
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($code -ne 0) {
        $credentialPrefix = @(Get-GitHubCredentialPrefix -Remote $Remote)
        if ($credentialPrefix.Count -gt 0) {
            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                if ($NoWorkingDirectory) {
                    $output = @(& git -c core.longpaths=true @credentialPrefix @Arguments 2>&1)
                } else {
                    $output = @(& git -c core.longpaths=true @credentialPrefix -C $WorkingDirectory @Arguments 2>&1)
                }
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        }
    }

    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Git network command failed: git $($Arguments -join ' ')"
    }
    [pscustomobject]@{ ExitCode = $code; Output = ($output -join "`n").Trim() }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$configPath = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'AI context config is missing.'
}

$config = Get-Content -Encoding UTF8 -LiteralPath $configPath -Raw | ConvertFrom-Json
if ([int]$config.schemaVersion -ne 1) { throw 'Unsupported AI context config schemaVersion.' }

$configuredRemote = [string]$config.context.remote
$branch = [string]$config.context.branch
$cacheRelative = [string]$config.context.cachePath
if ([string]::IsNullOrWhiteSpace($configuredRemote) -or [string]::IsNullOrWhiteSpace($branch) -or [string]::IsNullOrWhiteSpace($cacheRelative)) {
    throw 'AI context config is incomplete.'
}
if ($configuredRemote -match '^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]*@') {
    throw 'AI context remote URL must not embed credentials.'
}
$remoteIsUrl = $configuredRemote -match '^[a-zA-Z][a-zA-Z0-9+.-]*://'
$remote = if ($remoteIsUrl) {
    $configuredRemote.TrimEnd('/')
} elseif ([System.IO.Path]::IsPathRooted($configuredRemote)) {
    [System.IO.Path]::GetFullPath($configuredRemote).TrimEnd([char[]]@('\','/'))
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $configuredRemote)).TrimEnd([char[]]@('\','/'))
}

if ([System.IO.Path]::IsPathRooted($cacheRelative)) {
    throw 'AI context cachePath must be repository-relative.'
}
$cachePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $cacheRelative))
$repoPrefix = $repoRoot.TrimEnd([char[]]@([char]92,[char]47)) + [System.IO.Path]::DirectorySeparatorChar
if (-not (($cachePath + [System.IO.Path]::DirectorySeparatorChar).StartsWith($repoPrefix,[System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'AI context cachePath must remain inside the member repository.'
}
$currentCachePath = $repoRoot
foreach ($segment in $cacheRelative.Replace([char]92,[char]47).Split('/')) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
    $currentCachePath = Join-Path $currentCachePath $segment
    if (Test-Path -LiteralPath $currentCachePath) {
        $item = Get-Item -LiteralPath $currentCachePath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'AI context cachePath must not traverse a reparse point.'
        }
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required for AI context lifecycle.'
}

if ($Action -eq 'import') {
    Import-ContextOfflineTransfer -RepoRoot $repoRoot -CachePath $cachePath -Config $config -Branch $branch -Remote $remote
    exit 0
}
if ($Action -eq 'export') {
    Export-ContextOfflineTransfer -RepoRoot $repoRoot -CachePath $cachePath -Config $config -Branch $branch
    exit 0
}
if ($Action -eq 'reconnect') {
    Reconnect-ContextOffline -RepoRoot $repoRoot -CachePath $cachePath -Config $config -Branch $branch -Remote $remote
    exit 0
}

$offlineMarker = Get-ContextOfflineMarker -RepoRoot $repoRoot -CachePath $cachePath -Config $config -Branch $branch -Remote $remote
if ($null -eq $offlineMarker) {
    if (-not (Test-Path -LiteralPath (Join-Path $cachePath '.git'))) {
        if (Test-Path -LiteralPath $cachePath) {
            $entries = @(Get-ChildItem -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -gt 0) {
                throw 'AI context cache path exists but is not a Git repository.'
            }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $cachePath) -Force | Out-Null
        $clone = Invoke-GitNetwork -WorkingDirectory $repoRoot -Arguments @('clone', '--branch', $branch, '--single-branch', '--', $remote, $cachePath) -Remote $remote -NoWorkingDirectory -AllowFailure
        if ($clone.ExitCode -ne 0) { throw 'Unable to clone central AI context. Check Git authentication/network access.' }
    } else {
        $actualRemoteRaw = (Invoke-Git -WorkingDirectory $cachePath -Arguments @('remote', 'get-url', 'origin')).Output
        $actualRemoteIsUrl = $actualRemoteRaw -match '^[a-zA-Z][a-zA-Z0-9+.-]*://'
        $actualRemote = if ($actualRemoteIsUrl) {
            $actualRemoteRaw.TrimEnd('/')
        } else {
            [System.IO.Path]::GetFullPath($actualRemoteRaw).TrimEnd([char[]]@('\','/'))
        }
        $actualBranch = (Invoke-Git -WorkingDirectory $cachePath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Output
        if ($actualBranch -ne $branch) {
            throw "AI context cache must remain on configured branch '$branch'."
        }

        $dirty = -not [string]::IsNullOrWhiteSpace((Invoke-Git -WorkingDirectory $cachePath -Arguments @('status', '--porcelain')).Output)
        if ($actualRemote -ne $remote) {
            if ($dirty) {
                throw 'AI context cache origin differs from the configured central remote and the cache is dirty; automatic origin migration was refused.'
            }

            Invoke-Git -WorkingDirectory $cachePath -Arguments @('remote', 'set-url', 'origin', $remote) | Out-Null
            $migrationFetch = Invoke-GitNetwork -WorkingDirectory $cachePath -Arguments @('fetch', 'origin', $branch) -Remote $remote -AllowFailure
            if ($migrationFetch.ExitCode -ne 0) {
                Invoke-Git -WorkingDirectory $cachePath -Arguments @('remote', 'set-url', 'origin', $actualRemoteRaw) | Out-Null
                throw 'AI context cache origin migration failed; the previous origin was restored.'
            }
        } else {
            Invoke-GitNetwork -WorkingDirectory $cachePath -Arguments @('fetch', 'origin', $branch) -Remote $remote | Out-Null
        }

        if ($dirty) {
            if ($Action -eq 'checkpoint' -and -not (Test-Path -LiteralPath (Join-Path $repoRoot '.ai-bridge/context-checkpoint-pending.json') -PathType Leaf)) {
                throw 'Automated checkpoint refused because the AI context cache has pre-existing uncommitted changes.'
            }
            Write-Warning 'AI context cache is dirty; refresh skipped and local context will be loaded read-only.'
        } else {
            $ff = Invoke-Git -WorkingDirectory $cachePath -Arguments @('merge', '--ff-only', "origin/$branch") -AllowFailure
            if ($ff.ExitCode -ne 0) {
                if ($Action -eq 'checkpoint') {
                    throw 'AI context cache diverged from origin; automated checkpoint cannot continue safely.'
                }
                Write-Warning 'AI context cache diverged from origin; destructive synchronization was refused. Local context will be loaded read-only.'
            }
        }
    }
} else {
    $actualBranch = (Invoke-Git -WorkingDirectory $cachePath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Output
    if ($actualBranch -ne $branch) { throw "AI context cache must remain on configured branch '$branch'." }
    $dirty = -not [string]::IsNullOrWhiteSpace((Invoke-Git -WorkingDirectory $cachePath -Arguments @('status', '--porcelain')).Output)
    if ($dirty -and $Action -eq 'checkpoint' -and -not (Test-Path -LiteralPath (Join-Path $repoRoot '.ai-bridge/context-checkpoint-pending.json') -PathType Leaf)) {
        throw 'Automated checkpoint refused because the imported AI context cache has pre-existing uncommitted changes.'
    }
}

$toolPath = Join-Path $cachePath 'tooling/context-lifecycle.ps1'
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    throw 'Central AI context tooling is missing. Refresh or re-import the central context repository.'
}

$toolArgs = @{ Action = $Action; RepositoryRoot = $repoRoot; ConfigPath = $configPath }
if ($null -ne $offlineMarker) { $toolArgs['Offline'] = $true }
& $toolPath @toolArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($null -ne $offlineMarker -and $Action -eq 'checkpoint') {
    Update-ContextOfflineMarkerHead -RepoRoot $repoRoot -CachePath $cachePath -Config $config -Branch $branch -Remote $remote -Marker $offlineMarker
}

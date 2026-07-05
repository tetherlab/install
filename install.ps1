#Requires -Version 5
<#
.SYNOPSIS
    Tether CLI installer for Windows (#635).

.DESCRIPTION
    Detects the architecture, resolves the latest release, downloads the
    matching .zip + its SHA256SUMS, VERIFIES the checksum (fail-closed),
    extracts tether.exe into a writable install dir, adds that dir to the USER
    PATH idempotently, and finally hands off to `tether onboard` (sign in →
    workspace → bootstrap) unless -NoLogin, $env:TETHER_NO_ONBOARD, CI, or a
    non-interactive console.

    Canonical install (once #643 provisions the host):
        irm https://get.tether.sh/install.ps1 | iex
    Until then, install via the GitHub-hosted raw URL of this script.

    TODO(#634): canonical host get.tether.sh not provisioned; install via the
                GitHub-hosted script URL for now.

.NOTES
    SECURITY (this is a pipe-to-shell installer — treat as security-critical):
      * The checksum is verified BEFORE tether.exe is extracted/installed, and
        any mismatch / missing line aborts (fail closed). No -SkipChecksum.
      * Nothing downloaded is ever Invoke-Expression'd — fetched bytes only land
        in files.
      * The resolved download host is fixed to the GitHub release host and the
        version is shape-validated before it is used in any URL.
      * PATH edits are idempotent and scoped to the USER environment only —
        never the Machine scope.
      * This script does NOT weaken execution policy at any scope. If running is
        blocked, invoke it as:
            powershell -ExecutionPolicy Bypass -File install.ps1
        (process-scoped only; the standard pipe-to-PowerShell idiom).

.PARAMETER Version
    Install this version instead of the latest release (e.g. 0.2.0).

.PARAMETER NoModifyPath
    Do not edit the USER PATH.

.PARAMETER NoLogin
    Do not sign in / onboard at the end.

.NOTES
    Set $env:TETHER_NO_ONBOARD to skip the post-install sign-in and workspace
    setup (the env-var opt-out, equivalent to -NoLogin).
#>

[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoModifyPath,
    [switch]$NoLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ───────────────────────────────────────────────────────────────

# TODO(#634): confirm canonical owner/repo slug before the public launch.
$Script:TetherRepo = if ($env:TETHER_REPO) { $env:TETHER_REPO } else { 'tetherlab/install' }
$Script:GitHub = 'https://github.com'

function Write-Info { param([string]$Message) Write-Host "tether-install: $Message" }
function Die { param([string]$Message) Write-Error "tether-install: $Message"; exit 1 }

# ── Arch detection ──────────────────────────────────────────────────────────

# Echo "x86_64" | "arm64"; die on anything else.
function Get-Arch {
    $a = if ($env:TETHER_ARCH) { $env:TETHER_ARCH } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($a) {
        'AMD64' { return 'x86_64' }
        'x86_64' { return 'x86_64' }
        'ARM64' { return 'arm64' }
        'arm64' { return 'arm64' }
        default { Die "unsupported architecture: $a (tether ships x86_64 and arm64 builds)" }
    }
}

# ── Artifact + URL construction ─────────────────────────────────────────────

# Windows ships a per-arch .zip.
# TODO(#634): Windows target not yet built by release.yml; artifact name follows
#             the documented msvc-zip convention.
function Get-ArtifactName {
    param([string]$Arch, [string]$Ver)
    switch ($Arch) {
        'x86_64' { return "tether-$Ver-x86_64-pc-windows-msvc.zip" }
        'arm64' { return "tether-$Ver-aarch64-pc-windows-msvc.zip" }
        default { Die "no artifact for arch $Arch" }
    }
}

# Reject a TETHER_REPO slug that isn't a plain `owner/repo`. The host is pinned
# to $GitHub, but an unvalidated slug could still path-traverse within github.com.
function Test-Repo {
    param([string]$Repo)
    if ($Repo -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -or $Repo -match '\.\.') {
        Die "TETHER_REPO must be a plain owner/repo slug, got: $Repo"
    }
}

# Reject a version that isn't plain semver (optionally a -pre / +build suffix),
# so a poisoned "latest" redirect can't inject an arbitrary host/path.
function Test-Version {
    param([string]$Ver)
    if ($Ver -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.\-]+)?$') {
        Die "refusing to use a malformed version string: $Ver"
    }
}

function Get-DownloadUrl {
    param([string]$Ver, [string]$Artifact)
    return "$($Script:GitHub)/$($Script:TetherRepo)/releases/download/v$Ver/$Artifact"
}

function Get-ChecksumsUrl {
    param([string]$Ver)
    return "$($Script:GitHub)/$($Script:TetherRepo)/releases/download/v$Ver/SHA256SUMS"
}

# Parse the bare version out of a /releases/tag/vX.Y.Z URL (pure; testable).
function Get-VersionFromTagUrl {
    param([string]$Url)
    if ($Url -match '/tag/v([0-9][0-9A-Za-z.\-+]*)/?$') {
        return $Matches[1]
    }
    return ''
}

# Resolve the latest version via the /releases/latest redirect's Location header.
# TODO(#634): no version manifest endpoint; resolving latest via the
#             releases/latest redirect.
function Resolve-LatestVersion {
    $url = "$($Script:GitHub)/$($Script:TetherRepo)/releases/latest"
    try {
        $resp = Invoke-WebRequest -Uri $url -MaximumRedirection 0 -UseBasicParsing -ErrorAction SilentlyContinue
    } catch {
        # A 302 surfaces as an exception in some PS versions; recover the
        # Location from the response on the error record.
        $resp = $_.Exception.Response
    }
    $location = $null
    if ($resp -and $resp.Headers -and $resp.Headers['Location']) {
        $location = [string]$resp.Headers['Location']
    } elseif ($resp -and $resp.Headers -and $resp.Headers.Location) {
        $location = [string]$resp.Headers.Location
    }
    if (-not $location) { Die 'could not resolve the latest version — pass -Version <X.Y.Z>' }
    # Defense in depth: the version is rebuilt from the pinned host/repo constants
    # regardless, but assert the redirect landed on our own releases path before
    # trusting anything parsed off it, so a hijacked redirect can't even reach
    # the parser.
    $expectedPrefix = "$($Script:GitHub)/$($Script:TetherRepo)/releases/"
    if (-not $location.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Die "latest-release redirect went somewhere unexpected ($location) — refusing it; pass -Version <X.Y.Z>"
    }
    return Get-VersionFromTagUrl -Url $location
}

# ── Checksum verification (fail-closed) ─────────────────────────────────────

# Verify $File's SHA-256 against the line for $Artifact in $SumsFile. Throws
# (fail closed) on a mismatch OR a missing line — never returns on failure.
function Test-Checksum {
    param([string]$File, [string]$Artifact, [string]$SumsFile)

    # The SHA256SUMS file must exist and be readable before we trust anything
    # parsed from it (defense in depth — Invoke-Main already fails closed if the
    # download 404s). A missing file would otherwise surface as a raw Get-Content
    # exception; make it the clean fail-closed message instead.
    if (-not (Test-Path -LiteralPath $SumsFile -PathType Leaf)) {
        Die "SHA256SUMS not found or unreadable ($SumsFile) — cannot verify, refusing to install (fail closed)"
    }

    $expected = $null
    foreach ($line in Get-Content -LiteralPath $SumsFile) {
        # "<hex>  <filename>" or "<hex> *<filename>" (binary marker).
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2) {
            $name = $parts[1].TrimStart('*').Trim()
            if ($name -eq $Artifact) { $expected = $parts[0].Trim(); break }
        }
    }
    if (-not $expected) {
        Die "no checksum line for $Artifact in SHA256SUMS — refusing to install (fail closed)"
    }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($expected.ToLower() -ne $actual.ToLower()) {
        Write-Error "tether-install: checksum mismatch for $Artifact"
        Write-Error "  expected: $expected"
        Write-Error "  actual:   $actual"
        Die 'refusing to install a tampered or corrupt download (fail closed)'
    }
}

# ── Install ─────────────────────────────────────────────────────────────────

function Resolve-InstallDir {
    if ($env:TETHER_INSTALL_DIR) { return $env:TETHER_INSTALL_DIR }
    return (Join-Path $env:USERPROFILE '.tether\bin')
}

# Safely extract a .zip into $Dest, validating every entry's resolved path stays
# under $Dest (zip-slip protection — Expand-Archive does not guard against `..\`
# traversal entries on older PowerShell/.NET). Uses System.IO.Compression so we
# control per-entry path resolution.
function Expand-ZipSafely {
    param([string]$Zip, [string]$Dest)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $destFull = [System.IO.Path]::GetFullPath($Dest)
    # Ensure the comparison prefix ends in a separator so "C:\a" can't match "C:\ab".
    $destPrefix = $destFull
    if (-not $destPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $destPrefix += [System.IO.Path]::DirectorySeparatorChar
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            # Directory entries have an empty Name; skip them (dirs are created lazily).
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $target = [System.IO.Path]::GetFullPath((Join-Path $Dest $entry.FullName))
            if (-not $target.StartsWith($destPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                Die "refusing to extract archive entry outside the target dir (zip-slip): $($entry.FullName)"
            }
            $parent = [System.IO.Path]::GetDirectoryName($target)
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $archive.Dispose()
    }
}

# Extract tether.exe from $Zip into $DestDir. Requires tether.exe at the archive
# ROOT (mirrors the sh path's root-only `tether` check) — never picks a nested
# tether.exe an archive author chose to bury elsewhere.
function Install-Binary {
    param([string]$Zip, [string]$DestDir)
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tether-extract-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Expand-ZipSafely -Zip $Zip -Dest $tmp
        $exePath = Join-Path $tmp 'tether.exe'
        if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
            Die "archive did not contain tether.exe at its root"
        }
        Copy-Item -LiteralPath $exePath -Destination (Join-Path $DestDir 'tether.exe') -Force
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ── PATH management (idempotent, USER scope) ────────────────────────────────

# Pure: is $Dir already a segment of the (semicolon-delimited) $PathValue?
# Case-insensitive, matching Windows PATH semantics.
function Test-PathContains {
    param([string]$Dir, [string]$PathValue)
    if (-not $PathValue) { return $false }
    foreach ($seg in $PathValue -split ';') {
        if ($seg -and ($seg.TrimEnd('\') -ieq $Dir.TrimEnd('\'))) { return $true }
    }
    return $false
}

# Add $Dir to the USER PATH idempotently — never the Machine scope, never the
# live process PATH globally. A no-op when already present.
function Add-ToUserPath {
    param([string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathContains -Dir $Dir -PathValue $userPath) {
        Write-Info "$Dir is already on the user PATH"
        return
    }
    $newPath = if ([string]::IsNullOrEmpty($userPath)) { $Dir } else { "$userPath;$Dir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Info "added $Dir to the user PATH"
    Write-Info "open a new shell to pick it up"
}

# ── main ────────────────────────────────────────────────────────────────────

function Invoke-Main {
    # Shape-validate the repo slug (overridable via $env:TETHER_REPO) before it
    # reaches any URL.
    Test-Repo -Repo $Script:TetherRepo

    $arch = Get-Arch
    Write-Info "detected windows/$arch"

    $ver = $Version
    if (-not $ver) {
        Write-Info 'resolving the latest release ...'
        $ver = Resolve-LatestVersion
        if (-not $ver) { Die 'could not resolve the latest version — pass -Version <X.Y.Z>' }
    }
    Test-Version -Ver $ver
    Write-Info "installing tether v$ver"

    $artifact = Get-ArtifactName -Arch $arch -Ver $ver
    $artUrl = Get-DownloadUrl -Ver $ver -Artifact $artifact
    $sumsUrl = Get-ChecksumsUrl -Ver $ver

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("tether-install-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $zip = Join-Path $work $artifact
        $sums = Join-Path $work 'SHA256SUMS'

        Write-Info "downloading $artifact ..."
        try {
            Invoke-WebRequest -Uri $artUrl -OutFile $zip -UseBasicParsing
        } catch {
            Die "download failed: $artUrl (is v$ver published for windows/$arch?)"
        }

        Write-Info 'downloading SHA256SUMS ...'
        # TODO(#634): release.yml does not yet publish SHA256SUMS, and the
        # Windows .zip is not built yet either. Until both land, this download
        # 404s and we fail closed by design. Do not add a -SkipChecksum hatch.
        try {
            Invoke-WebRequest -Uri $sumsUrl -OutFile $sums -UseBasicParsing
        } catch {
            Die "checksum file missing: $sumsUrl — cannot verify the download, refusing to install (fail closed; #634)"
        }

        Write-Info 'verifying checksum ...'
        Test-Checksum -File $zip -Artifact $artifact -SumsFile $sums

        $destDir = Resolve-InstallDir
        Write-Info "installing to $destDir\tether.exe ..."
        Install-Binary -Zip $zip -DestDir $destDir
        Write-Info "installed tether v$ver"

        if (-not $NoModifyPath) {
            Add-ToUserPath -Dir $destDir
        } else {
            Write-Info "skipping PATH edit (-NoModifyPath); add $destDir to PATH yourself"
        }

        # Final step: hand off to the binary's onboard chain (sign in →
        # choose/create a workspace → init repo → offer bootstrap), unless
        # suppressed, opted out, or non-interactive. Run the just-installed binary
        # by absolute path (PATH may not be live yet) and let ITS existing
        # auto-onboard chain drive the rest (we never reimplement it here).
        #
        # No /dev/tty dance on Windows: `irm … | iex` runs in the calling
        # PowerShell host with the terminal still attached as stdin (unlike Unix
        # pipe-to-sh, which wires fd 0 to the pipe), so we gate purely on
        # interactivity + the same opt-out env vars and invoke onboard directly;
        # the binary's onboard re-checks the console itself.
        #
        # NOTE: Windows `tether.exe` is not built by release.yml yet (pending #98 /
        # #634), so today this hand-off only runs once that artifact ships; the
        # gating logic is in place so no follow-up touches it then.
        $exePath = Join-Path $destDir 'tether.exe'
        if ($NoLogin) {
            Write-Info "skipping sign-in (-NoLogin). Run ``tether login`` to sign in."
        } elseif ($env:TETHER_NO_ONBOARD) {
            Write-Info "TETHER_NO_ONBOARD set — skipping sign-in. Run ``tether login`` to sign in."
        } elseif ($env:CI -eq 'true' -or $env:CI -eq '1') {
            Write-Info "CI detected — skipping sign-in. Run ``tether login`` to sign in."
        } elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            Write-Info 'signing you in ...'
            & $exePath onboard
            if ($LASTEXITCODE -ne 0) {
                Write-Info "onboarding did not complete — run ``tether login`` to retry."
            }
        } else {
            Write-Info "no interactive console — skipping sign-in. Run ``tether login`` to sign in."
        }

        Write-Info 'done.'
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Only auto-run when executed, not when dot-sourced for inspection/tests.
if ($env:TETHER_INSTALL_SOURCED -ne '1') {
    Invoke-Main
}

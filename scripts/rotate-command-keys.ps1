<#
.SYNOPSIS
  Apply a command-signing keyring to the fleet: distribution job, readiness
  group, and the (disabled) enforcement job — from one set of key values.

.DESCRIPTION
  The three manifests under configs/ each need the same key ids and public
  keys, and they must move together. Editing them by hand is how they drift:
  the group query stops matching the ring the job writes, the readiness group
  silently empties, and the enable job then reaches nobody — a failure whose
  symptom is "nothing happened", which is the hardest kind to notice.

  So the manifests ship with REPLACE- placeholders and this script injects the
  real values into temp copies, the same shape scripts/fleet-deploy.ps1 uses
  in the kanade repo. Nothing fleet-specific is committed, and the three
  consumers cannot disagree because they are filled from one invocation.

.PARAMETER BackendKid
  The backend signing key's id, as printed by
  `kanade-backend command-key-generate` on the backend host.

.PARAMETER BackendPublicKey
  Base64 public half printed alongside it.

.PARAMETER BreakGlassKid
  The break-glass key's id, from `kanade command-key break-glass`.

.PARAMETER BreakGlassPublicKey
  Base64 public half printed alongside it. NOT the private key — that one is
  shown once and belongs in a password manager plus a printed backup; it never
  appears in a manifest or on a command line.

.PARAMETER MaxAgeMins
  Freshness window for the break-glass key. Default 60. An hour rather than something
  tighter (it is really a +/- clock-skew tolerance, and the machines needing
  break-glass are the ones whose clocks are wrong).

.PARAMETER RingVersion
  Version stamped on the distribution job. MUST be bumped whenever the ring
  changes: the schedule uses `per_pc: once_per_version`, so the version is
  what re-arms the fleet. Leaving it unchanged means the new ring reaches
  nobody, silently.

.PARAMETER Apply
  Actually run the `kanade` commands. Without it the script prints what it
  would do and leaves the rendered manifests for inspection — the default,
  because this writes the fleet's trust root.

.EXAMPLE
  # See what would be applied (default):
  PS> .\scripts\rotate-command-keys.ps1 `
        -BackendKid backend-20260728 -BackendPublicKey 'poO5...t6c=' `
        -BreakGlassKid break-glass-20260730-1432 -BreakGlassPublicKey 'cbYZ...tw4=' `
        -RingVersion 0.2.0

.EXAMPLE
  # Apply it:
  PS> .\scripts\rotate-command-keys.ps1 ... -RingVersion 0.2.0 -Apply

.NOTES
  Does NOT enable enforcement. configs/schedules/enable-command-signing.yaml
  ships `enabled: false` and turning it on is a separate, deliberate edit —
  after the readiness group has been inspected.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackendKid,
    [Parameter(Mandatory)][string]$BackendPublicKey,
    [Parameter(Mandatory)][string]$BreakGlassKid,
    [Parameter(Mandatory)][string]$BreakGlassPublicKey,
    [int]$MaxAgeMins = 60,
    [Parameter(Mandatory)][string]$RingVersion,
    [string]$Server = '',
    [string]$BackendUrl = '',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command kanade -ErrorAction SilentlyContinue)) {
    throw "kanade CLI not found on PATH - install it before running this script."
}

# ---- validate the inputs before touching anything -------------------------
# Every one of these is silent later: a bad public key gives the right kid
# with wrong bytes, which refuses every command once enforcement is on and
# never self-heals (the reload path only fires for an UNKNOWN key, and this
# one is known).
function Assert-Base64Key {
    param([string]$Name, [string]$Value)
    try { $bytes = [Convert]::FromBase64String($Value) }
    catch { throw "$Name is not valid base64: $Value" }
    if ($bytes.Length -ne 32) {
        throw "$Name decodes to $($bytes.Length) bytes; an Ed25519 public key is 32. Did you paste the kid, or the private key?"
    }
}
Assert-Base64Key -Name 'BackendPublicKey'    -Value $BackendPublicKey
Assert-Base64Key -Name 'BreakGlassPublicKey' -Value $BreakGlassPublicKey

# The readiness group pins the backend key by `kid:fingerprint`, not by kid
# alone. Derived here rather than taken as a parameter: a
# fingerprint an operator types is a second chance to make the same mistake,
# and one that would agree with a mistyped ring instead of contradicting it.
#
# Must stay byte-identical to `kanade_shared::signing::fingerprint`: SHA-256
# over the raw 32-byte public key, first 8 bytes, lower hex. Disagree by one
# character and the group matches nobody — which reads as "no host is ready"
# rather than as an error.
function Get-KeyFingerprint {
    param([string]$Base64PublicKey)
    $bytes = [Convert]::FromBase64String($Base64PublicKey)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    -join ($hash[0..7] | ForEach-Object { $_.ToString('x2') })
}
$BackendFingerprint = Get-KeyFingerprint -Base64PublicKey $BackendPublicKey

if ($BackendKid -eq $BreakGlassKid) {
    throw "BackendKid and BreakGlassKid are both '$BackendKid'. A ring is keyed by id, so one would silently replace the other."
}
if ($BackendPublicKey -eq $BreakGlassPublicKey) {
    throw "the two public keys are identical - that is one key wearing two ids, which defeats having a separate break-glass credential."
}
if ($MaxAgeMins -le 0) {
    throw "-MaxAgeMins $MaxAgeMins would reject every signature the break-glass key makes."
}
foreach ($k in @($BackendKid, $BreakGlassKid)) {
    if ($k -match '["\\]') { throw "kid '$k' contains a quote or backslash; it is embedded in JSON inside a script and would not survive." }
}

# ---- render ----------------------------------------------------------------
# Listed in APPLY order, and rendered to `Out` names that carry the kind.
#
# The kind prefix is not cosmetic: configs/jobs/provision-command-keys.yaml and
# configs/schedules/provision-command-keys.yaml share a basename, so flattening
# them into one temp directory silently overwrote the job with the schedule —
# and the apply then pushed a schedule where a job belonged. Same for the
# enable pair.
#
# The group is created BEFORE the enable schedule that targets it; a schedule
# naming a group that does not exist yet is an error the operator has to unpick
# mid-apply.
$targets = @(
    @{ Name = 'provision-command-keys job';  Kind = 'job';      Out = 'job-provision-command-keys.yaml';        Src = "$repoRoot\configs\jobs\provision-command-keys.yaml" }
    @{ Name = 'command-signing-ready group'; Kind = 'group';    Out = 'group-command-signing-ready.yaml';       Src = "$repoRoot\configs\groups\command-signing-ready.yaml" }
    @{ Name = 'enable-command-signing job';  Kind = 'job';      Out = 'job-enable-command-signing.yaml';        Src = "$repoRoot\configs\jobs\enable-command-signing.yaml" }
    @{ Name = 'provision schedule';          Kind = 'schedule'; Out = 'schedule-provision-command-keys.yaml';   Src = "$repoRoot\configs\schedules\provision-command-keys.yaml" }
    @{ Name = 'enable schedule';             Kind = 'schedule'; Out = 'schedule-enable-command-signing.yaml';   Src = "$repoRoot\configs\schedules\enable-command-signing.yaml" }
)

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("kanade-ring-{0}" -f ([Guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
Write-Host "Rendering into $tmpDir"
Write-Host ''

$rendered = @()
foreach ($t in $targets) {
    if (-not (Test-Path $t.Src)) { throw "missing manifest: $($t.Src)" }
    $text = Get-Content -LiteralPath $t.Src -Raw
    $text = $text.
        Replace('REPLACE-backend-fingerprint',    $BackendFingerprint).
        Replace('REPLACE-backend-kid',            $BackendKid).
        Replace('REPLACE-backend-public-key',     $BackendPublicKey).
        Replace('REPLACE-break-glass-kid',        $BreakGlassKid).
        Replace('REPLACE-break-glass-public-key', $BreakGlassPublicKey).
        Replace('"max_age_secs":3600',            ('"max_age_secs":{0}' -f ($MaxAgeMins * 60)))
    if ($t.Src -like '*provision-command-keys.yaml' -and $t.Kind -eq 'job') {
        # Only the distribution job's version re-arms the fleet; leave the
        # enable job's own version alone so a ring rotation does not silently
        # re-run enforcement enabling too.
        $text = $text -replace '(?m)^version:.*$', "version: $RingVersion"
    }
    # The placeholders are deliberately un-base64-like so a missed one cannot
    # be mistaken for a key. Fail here rather than shipping a ring the agent
    # will reject after it has already been written to 500 registries.
    if ($text -match 'REPLACE-') {
        throw "unsubstituted placeholder left in $($t.Src) - the script and the manifest have drifted apart."
    }
    $dst = Join-Path $tmpDir $t.Out
    if (Test-Path $dst) { throw "two manifests would render to $($t.Out) - the Out names must be unique" }
    Set-Content -LiteralPath $dst -Value $text -Encoding utf8
    $rendered += @{ Name = $t.Name; Path = $dst; Kind = $t.Kind }
    Write-Host ("  {0,-28} -> {1}" -f $t.Name, $t.Out)
}

Write-Host ''
Write-Host "ring:      $BackendKid + $BreakGlassKid (break-glass window ${MaxAgeMins}m)"
# Worth one line of output because it is the only check that catches a mistyped
# -BackendPublicKey. The ring and the group's literal are both derived from
# that parameter, so they agree with each other even when it is wrong; the
# backend's own key is the independent witness. Compare against the `identity:`
# line printed by `kanade-backend command-key-generate`.
Write-Host "identity:  $BackendKid`:$BackendFingerprint  <- must equal the backend's own 'identity:' line"
Write-Host "job version: $RingVersion  <- bump this on EVERY ring change, or the schedule reaches nobody"
Write-Host ''

# ---- apply -----------------------------------------------------------------
$globals = @()
if ($Server)     { $globals += @('--server', $Server) }
if ($BackendUrl) { $globals += @('--backend-url', $BackendUrl) }

function Invoke-Kanade {
    param([string[]]$KanadeArgs)
    $line = 'kanade ' + (($globals + $KanadeArgs) -join ' ')
    if (-not $Apply) { Write-Host "  [dry-run] $line"; return }
    Write-Host "  $line"
    & kanade @($globals + $KanadeArgs)
    if ($LASTEXITCODE -ne 0) { throw "command failed (exit $LASTEXITCODE): $line" }
}

# `$rendered` preserves the order of `$targets`, which is the apply order, so
# this is a straight walk. Selecting by filename here is what produced a
# double-path argument earlier — the job and schedule pairs share a basename.
Write-Host '--- apply ---'
foreach ($r in $rendered) {
    switch ($r.Kind) {
        'job'      { Invoke-Kanade @('job', 'create', $r.Path) }
        'group'    { Invoke-Kanade @('group', 'def', 'create', $r.Path) }
        'schedule' { Invoke-Kanade @('schedule', 'create', $r.Path) }
        default    { throw "unknown manifest kind '$($r.Kind)' for $($r.Name)" }
    }
}

Write-Host ''
if (-not $Apply) {
    Write-Host "Dry run. Re-run with -Apply to write these to the fleet." -ForegroundColor Yellow
    Write-Host "Rendered manifests kept at $tmpDir for inspection."
} else {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmpDir
    Write-Host "Applied. Distribution starts on the schedule's next tick." -ForegroundColor Green
    Write-Host ''
    Write-Host "Next, in order:"
    Write-Host "  1. Watch coverage:  GET /api/agents -> command_keys per host"
    Write-Host "  2. Confirm the readiness group fills up (kanade group list command-signing-ready)"
    Write-Host "  3. Rehearse break-glass once before relying on it"
    Write-Host "  4. Only then: set enabled: true on configs/schedules/enable-command-signing.yaml"
}

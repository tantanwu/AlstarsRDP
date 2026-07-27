[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
}

function Read-StrictUtf8([string]$Path) {
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    return $encoding.GetString([System.IO.File]::ReadAllBytes($Path))
}

$textExtensions = @('.swift', '.m', '.mm', '.h', '.md', '.json', '.yml', '.yaml', '.plist', '.strings', '.sh', '.ps1', '.xcconfig')
Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $textExtensions -contains $_.Extension -and
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -notmatch '[\\/]Vendor[\\/](build|source)[\\/]'
} | ForEach-Object {
    try {
        $text = Read-StrictUtf8 $_.FullName
        $relative = $_.FullName.Substring($root.Length + 1)
        $extension = $_.Extension
        $trailingWhitespace = @([regex]::Matches($text, '(?m)[ \t]+$'))
        $invalidTrailingWhitespace = $trailingWhitespace | Where-Object {
            $extension -ne '.md' -or $_.Value -ne '  '
        }
        if ($invalidTrailingWhitespace.Count -gt 0) { Add-Failure "Trailing whitespace: $relative" }
        if ($_.Extension -eq '.sh') {
            if ($text.Contains("`r`n")) { Add-Failure "Shell script must use LF line endings: $relative" }
            if (-not $text.StartsWith("#!/usr/bin/env bash`n")) { Add-Failure "Invalid shell script shebang: $relative" }
        }
    }
    catch { Add-Failure "Invalid UTF-8: $($_.FullName.Substring($root.Length + 1))" }
}

$manifestPath = Join-Path $root 'Vendor/manifest.json'
try {
    $manifest = Read-StrictUtf8 $manifestPath | ConvertFrom-Json
    $freeRDP = @($manifest.dependencies | Where-Object name -eq 'FreeRDP')
    if ($freeRDP.Count -ne 1) { Add-Failure 'Vendor manifest must contain exactly one FreeRDP dependency.' }
    elseif ($freeRDP[0].commit -notmatch '^[0-9a-f]{40}$') { Add-Failure 'FreeRDP commit must be a 40-character lowercase SHA-1.' }
    elseif ($freeRDP[0].tagObject -notmatch '^[0-9a-f]{40}$') { Add-Failure 'FreeRDP tag object must be a 40-character lowercase SHA-1.' }
    elseif ($freeRDP[0].deploymentTarget -ne '11.0') { Add-Failure 'FreeRDP deployment target must remain macOS 11.0.' }
} catch {
    Add-Failure "Invalid Vendor/manifest.json: $($_.Exception.Message)"
}

foreach ($relative in @('Config/Info.plist', 'Config/RemoteDesktop.entitlements')) {
    try { [void][xml](Read-StrictUtf8 (Join-Path $root $relative)) }
    catch { Add-Failure "Invalid XML in ${relative}: $($_.Exception.Message)" }
}

$localizedPath = Join-Path $root 'Sources/App/Resources/zh-Hans.lproj/Localizable.strings'
$localizedText = Read-StrictUtf8 $localizedPath
$entryPattern = '(?m)^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";'
$localizedEntries = @([regex]::Matches($localizedText, $entryPattern))
$localizedKeys = [System.Collections.Generic.HashSet[string]]::new()
foreach ($entry in $localizedEntries) {
    $key = $entry.Groups[1].Value
    if (-not $localizedKeys.Add($key)) { Add-Failure "Duplicate localization key: $key" }
    $formatPattern = '%(?:\d+\$)?[-+0# ]*(?:\d+|\*)?(?:\.\d+)?[a-zA-Z@]'
    $sourceFormats = [regex]::Matches($key, $formatPattern).Value -join ','
    $translatedFormats = [regex]::Matches($entry.Groups[2].Value, $formatPattern).Value -join ','
    if ($sourceFormats -ne $translatedFormats) {
        Add-Failure "Localization placeholders differ for: $key"
    }
}

$usedKeys = [System.Collections.Generic.HashSet[string]]::new()
Get-ChildItem -LiteralPath (Join-Path $root 'Sources') -Recurse -File -Filter '*.swift' | ForEach-Object {
    $source = Read-StrictUtf8 $_.FullName
    foreach ($match in [regex]::Matches($source, 'NSLocalizedString\s*\(\s*"((?:[^"\\]|\\.)*)"')) {
        [void]$usedKeys.Add($match.Groups[1].Value)
    }
}
foreach ($key in $usedKeys) {
    if (-not $localizedKeys.Contains($key)) { Add-Failure "Missing zh-Hans localization: $key" }
}

$projectText = Read-StrictUtf8 (Join-Path $root 'project.yml')
if ($projectText -notmatch 'macOS:\s*"11\.0"') { Add-Failure 'project.yml must retain the macOS 11.0 deployment target.' }
if ($projectText -notmatch 'xcodeVersion:\s*"15\.4"') { Add-Failure 'project.yml must generate an Xcode 15.4-compatible project.' }
if ($projectText -notmatch 'ARCHS') {
    $baseConfig = Read-StrictUtf8 (Join-Path $root 'Config/Base.xcconfig')
    if ($baseConfig -notmatch 'ARCHS\s*=\s*arm64\s+x86_64') { Add-Failure 'Universal 2 architectures are not configured.' }
}
$generatedFrameworkPlists = [regex]::Matches($projectText, '(?m)^\s{8}GENERATE_INFOPLIST_FILE:\s*YES\s*$').Count
if ($generatedFrameworkPlists -lt 6) {
    Add-Failure 'Every application framework target must generate an Info.plist for code signing.'
}
$linkedNativeLibraries = [regex]::Matches(
    $projectText,
    '(?m)^\s*- framework: Vendor/build/universal/lib/[^\r\n]+\.dylib\r?\n\s+embed:\s*false\s*$'
).Count
if ($linkedNativeLibraries -ne 3) {
    Add-Failure 'RDPBridge native libraries must link without creating a nested runtime tree.'
}
if ($projectText -notmatch 'ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES:\s*NO') {
    Add-Failure 'The app must replace the default Swift runtime with the macOS 11 back-deployment runtime.'
}
if (-not $projectText.Contains('usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib')) {
    Add-Failure 'The macOS 11 Swift concurrency back-deployment runtime is not embedded.'
}

$sourceText = (Get-ChildItem -LiteralPath (Join-Path $root 'Sources') -Recurse -File | Where-Object {
    @('.swift', '.m', '.mm', '.h') -contains $_.Extension
} | ForEach-Object { Read-StrictUtf8 $_.FullName }) -join "`n"
if ($sourceText -match 'Data\s*\(\s*contentsOf\s*:') {
    Add-Failure 'Unbounded Data(contentsOf:) is forbidden in Sources; use BoundedFileReader.'
}
if ($sourceText -match 'String\s*\(\s*contentsOf\s*:') {
    Add-Failure 'Unbounded String(contentsOf:) is forbidden in Sources; use a bounded reader.'
}

$workflowFiles = Get-ChildItem -LiteralPath (Join-Path $root '.github/workflows') -File
foreach ($workflow in $workflowFiles) {
    $workflowText = Read-StrictUtf8 $workflow.FullName
    foreach ($match in [regex]::Matches($workflowText, '(?m)^\s*- uses:\s*([^@\s]+)@([^#\s]+)')) {
        if ($match.Groups[2].Value -notmatch '^[0-9a-f]{40}$') {
            Add-Failure "GitHub Action is not pinned to a full commit SHA: $($match.Groups[1].Value)@$($match.Groups[2].Value)"
        }
    }
}
$macOSWorkflow = Read-StrictUtf8 (Join-Path $root '.github/workflows/macos.yml')
if ($macOSWorkflow -notmatch 'DEVELOPER_DIR:\s*/Applications/Xcode_15\.4\.app/Contents/Developer') {
    Add-Failure 'The Universal 2 app job must use the macOS 11-compatible Xcode 15.4 toolchain.'
}
if ($macOSWorkflow -notmatch 'XCODEGEN_VERSION:\s*2\.41\.0') {
    Add-Failure 'The Universal 2 app job must pin XcodeGen 2.41.0.'
}
if ($macOSWorkflow -notmatch 'XCODEGEN_SHA256:\s*[0-9a-f]{64}') {
    Add-Failure 'The pinned XcodeGen archive must have a SHA-256 digest.'
}

$bootstrapText = Read-StrictUtf8 (Join-Path $root 'Tools/bootstrap-macos.sh')
$archiveText = Read-StrictUtf8 (Join-Path $root 'Tools/archive.sh')
if ($bootstrapText -notmatch 'cd \"\$\{root\}\"') { Add-Failure 'bootstrap-macos.sh must change to the repository root.' }
if ($archiveText -notmatch 'cd \"\$\{root\}\"') { Add-Failure 'archive.sh must change to the repository root.' }

$buildScript = Read-StrictUtf8 (Join-Path $root 'Tools/build-freerdp.sh')
foreach ($property in @('version', 'commit', 'tagObject', 'source', 'deploymentTarget')) {
    if ($buildScript -notmatch "dependencies\.0\.$property") {
        Add-Failure "build-freerdp.sh must read $property from Vendor/manifest.json."
    }
}
if ($buildScript -match '(?m)^(tag|commit|tag_object|source|deployment_target)=\"[^$]') {
    Add-Failure 'build-freerdp.sh must not duplicate dependency pins outside Vendor/manifest.json.'
}

$universalVerifier = Read-StrictUtf8 (Join-Path $root 'Tools/verify-universal.sh')
if ($universalVerifier -match 'spctl[^\r\n]*\|\|\s*true') {
    Add-Failure 'Gatekeeper failures must not be silently ignored.'
}
foreach ($requiredCheck in @('otool -L', '/opt/homebrew/', '/usr/local/', 'Vendor/build/', 'vtool', '-show-build')) {
    if (-not $universalVerifier.Contains($requiredCheck)) {
        Add-Failure "verify-universal.sh is missing runtime closure check: $requiredCheck"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Repository validation passed: text format, bounded I/O, JSON/plist, dependency pins, CI actions, localization, and deployment target checks."

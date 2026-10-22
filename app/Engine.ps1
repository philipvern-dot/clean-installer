# Clean Installer engine.
# Dot-source this file from the window. Running it directly is for tests
# and for the elevated leftover cleanup.

$script:WingetAdminContextProhibited = -1978335107
$script:AnsiPattern = [regex]::new("\x1b\[[0-9;]*[A-Za-z]")
$script:HeaderHint = [regex]::new('\bName\b.*\bId\b')

$script:GenericPublishers = @(
    'microsoft', 'google', 'mozilla', 'adobe', 'apple',
    'python software foundation', 'oracle', 'amazon'
)
$script:ProtectedFolderNames = @(
    'windows', 'windows.old', 'system32', 'syswow64', 'program files', 'program files (x86)',
    'programdata', 'users', 'documents', 'desktop', 'downloads', 'pictures', 'videos', 'music',
    'onedrive', 'favorites', 'contacts', 'searches', 'links', 'appdata', 'application data',
    'local', 'locallow', 'roaming', 'start menu', 'sendto', 'recent', 'templates', 'nethood',
    'cookies', 'common files', 'windowsapps', 'modifiablewindowsapps', 'temp', 'tmp', 'cache',
    'caches', 'packages', 'programs', 'package cache', 'fonts', 'assembly', 'winsxs', 'installer',
    'microsoft', 'windows nt', 'windows defender', 'node_modules', 'dotnet'
)
$script:FuzzyStopwords = @(
    'app', 'apps', 'application', 'windows', 'microsoft', 'update', 'updates', 'setup',
    'installer', 'program', 'programs', 'software', 'common', 'files', 'file', 'system',
    'driver', 'drivers', 'runtime', 'redist', 'redistributable', 'steam', 'machine', 'user',
    'x64', 'x86', 'arp', 'tool', 'tools', 'cache', 'temp', 'tmp', 'packages', 'local',
    'roaming', 'data', 'bin', 'code'
)
$script:BlockedRegVendors = @(
    'microsoft', 'windows', 'classes', 'policies', 'clients', 'wow6432node',
    'registeredapplications', 'odbc', 'google', 'mozilla', 'adobe', 'apple', 'oracle',
    'amazon', 'python', 'nvidia', 'intel', 'amd', 'realtek'
)
$script:RuntimeMarkers = @(
    'visual c++', 'redistributable', '.net runtime', '.net sdk', '.net desktop', 'asp.net',
    'webview', 'directx', 'windows sdk', 'vc_redist', 'microsoft edge update', 'edgewebview'
)
$script:DriverPublishers = @('nvidia', 'advanced micro devices', 'amd', 'intel', 'realtek', 'qualcomm', 'broadcom')
$script:GameStoreMarkers = @('steam app ', '\steamapps\common', '\epic games\', 'epicgames', 'xbox games', 'microsoft.xbox')
$script:UserAssistGuids = @(
    '{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}',
    '{F4E57C4B-2036-45F0-A9AB-443BCFE33D9F}'
)
# Shared tools other programs run in the background. Windows records a launch
# when you start a program yourself (UserAssist). Prefetch and BAM record real
# runs, including background runs, but a normal window cannot read them.
# A missing launch is not evidence these tools are unused.
$script:DependencyTools = @(
    @{ Label = 'FFmpeg'; Ids = @('gyan.ffmpeg', 'btbn.ffmpeg', 'ffmpeg.ffmpeg'); Names = @('ffmpeg') },
    @{ Label = 'ImageMagick'; Ids = @('imagemagick.imagemagick', 'imagemagick.q16', 'imagemagick.q8'); Names = @('imagemagick') },
    @{ Label = 'Ghostscript'; Ids = @('artifexsoftware.ghostscript', 'artifexsoftware.gplghostscript'); Names = @('ghostscript') },
    @{ Label = 'yt-dlp'; Ids = @('yt-dlp.yt-dlp'); Names = @('yt-dlp') },
    @{ Label = 'Deno'; Ids = @('denoland.deno'); Names = @('deno') },
    @{ Label = 'HandBrake CLI'; Ids = @('handbrake.handbrake.cli'); Names = @('handbrake cli', 'handbrakecli') }
)

function ConvertTo-Norm([string]$value) {
    if ([string]::IsNullOrEmpty($value)) { return '' }
    return ([regex]::Replace($value.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function ConvertTo-Arg([string]$value) {
    if ($null -eq $value) { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + ($value.Replace('"', '\"')) + '"'
}

function Format-CommandLine([string[]]$parts) {
    $quoted = foreach ($part in @($parts)) { ConvertTo-Arg ([string]$part) }
    return ($quoted -join ' ')
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal $identity
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    return $null
}

function Test-UserScopeId([string]$packageId) {
    return ([string]$packageId).ToUpperInvariant().StartsWith('ARP\USER\')
}

function Get-SteamAppNumber([string]$packageId) {
    $match = [regex]::Match([string]$packageId, 'steam app\s+(\d+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Test-SteamAppId([string]$packageId) {
    return $null -ne (Get-SteamAppNumber $packageId)
}

function Test-CatalogPackage($package) {
    $id = [string]$package.Id
    if ($id.ToUpperInvariant().StartsWith('ARP\')) { return $false }
    $source = [string]$package.Source
    if ([string]::IsNullOrWhiteSpace($source)) { return $false }
    if ($source.ToLowerInvariant() -eq 'arp') { return $false }
    return $true
}

function Get-WingetExtraFlags([string]$verb, [bool]$mutate, [bool]$autoAccept) {
    if ($mutate -and -not $autoAccept) { return @() }
    $flags = New-Object System.Collections.Generic.List[string]
    [void]$flags.Add('--disable-interactivity')
    [void]$flags.Add('--accept-source-agreements')
    if ($mutate -and $autoAccept) {
        if ($verb -eq 'install' -or $verb -eq 'upgrade') {
            [void]$flags.Add('--accept-package-agreements')
        }
        [void]$flags.Add('--silent')
    }
    return $flags.ToArray()
}

function New-WingetCommand {
    param(
        [string]$Verb,
        [string[]]$Argument,
        [bool]$Mutate,
        [bool]$AutoAccept
    )
    $winget = Get-WingetPath
    if (-not $winget) { throw 'winget was not found. Install App Installer from the Microsoft Store, then open Clean Installer again.' }
    $cmd = New-Object System.Collections.Generic.List[string]
    [void]$cmd.Add($winget)
    [void]$cmd.Add($Verb)
    foreach ($part in @($Argument)) {
        if (-not [string]::IsNullOrEmpty($part)) { [void]$cmd.Add([string]$part) }
    }
    foreach ($flag in @(Get-WingetExtraFlags $Verb $Mutate $AutoAccept)) {
        [void]$cmd.Add([string]$flag)
    }
    $steam = $false
    foreach ($part in @($Argument)) {
        if (Test-SteamAppId $part) { $steam = $true }
    }
    if ($Verb -eq 'uninstall' -and -not $steam) { [void]$cmd.Add('--purge') }
    return $cmd.ToArray()
}

function ConvertFrom-WingetLine([string]$line) {
    if ($null -eq $line) { return '' }
    return $script:AnsiPattern.Replace($line.Replace("`r", ''), '').TrimEnd()
}

function ConvertFrom-WingetTable([string]$text) {
    $packages = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($text -split "`n")) {
        [void]$lines.Add((ConvertFrom-WingetLine $raw))
    }
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($script:HeaderHint.IsMatch($lines[$i])) { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0) { return @() }
    $header = $lines[$headerIndex]
    $columns = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($header, '\S+')) {
        [void]$columns.Add([pscustomobject]@{ Name = $match.Value; Start = $match.Index })
    }
    if ($columns.Count -eq 0) { return @() }
    $started = $false
    for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $started) {
            $stripped = $line.Trim()
            $isRule = $stripped.Length -ge 8
            if ($isRule) {
                foreach ($ch in $stripped.ToCharArray()) {
                    $code = [int]$ch
                    if ($code -ne 45 -and $code -ne 0x2500) { $isRule = $false; break }
                }
            }
            if ($isRule) {
                $started = $true
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $started = $true
                $pkg = ConvertFrom-WingetRow $line $columns
                if ($pkg) { [void]$packages.Add($pkg) }
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($packages.Count -gt 0) { break }
            continue
        }
        $pkg = ConvertFrom-WingetRow $line $columns
        if ($null -eq $pkg) {
            if ($packages.Count -gt 0) { break }
            continue
        }
        [void]$packages.Add($pkg)
    }
    return $packages.ToArray()
}

function ConvertFrom-WingetRow([string]$line, $columns) {
    $values = @{}
    for ($index = 0; $index -lt $columns.Count; $index++) {
        $name = [string]$columns[$index].Name
        $start = [int]$columns[$index].Start
        $end = $line.Length
        if ($index + 1 -lt $columns.Count) { $end = [int]$columns[$index + 1].Start }
        $slice = ''
        if ($start -lt $line.Length) {
            $take = [Math]::Min($end, $line.Length) - $start
            if ($take -gt 0) { $slice = $line.Substring($start, $take).Trim() }
        }
        $values[$name] = $slice
    }
    $pkgId = [string]$values['Id']
    $name = [string]$values['Name']
    if ([string]::IsNullOrWhiteSpace($pkgId) -or [string]::IsNullOrWhiteSpace($name)) { return $null }
    if ($pkgId.ToLowerInvariant() -eq 'id' -or $pkgId -eq '---') { return $null }
    if ($pkgId -match '^-+$') { return $null }
    $pkg = [pscustomobject]@{
        Name = $name.Trim()
        Id = $pkgId.Trim()
        Version = [string]$values['Version']
        Available = [string]$values['Available']
        Source = [string]$values['Source']
        Match = [string]$values['Match']
        Note = ''
    }
    $pkg | Add-Member -NotePropertyName IsCatalog -NotePropertyValue (Test-CatalogPackage $pkg) -Force
    return $pkg
}

function ConvertFrom-WingetShow([string]$text) {
    $info = @{}
    if ([string]::IsNullOrWhiteSpace($text)) { return $info }
    $found = [regex]::Match($text, 'Found\s+(.+?)\s+\[([^\]]+)\]')
    if ($found.Success) {
        $info['Name'] = $found.Groups[1].Value.Trim()
        $info['Id'] = $found.Groups[2].Value.Trim()
    }
    foreach ($raw in ($text -split "`n")) {
        $line = ConvertFrom-WingetLine $raw
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(' ') -or $line.IndexOf(':') -lt 0) { continue }
        $index = $line.IndexOf(':')
        $key = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($key) -or $info.ContainsKey($key)) { continue }
        if (@('tags', 'documentation', 'installer', 'release notes') -contains $key.ToLowerInvariant()) { continue }
        $info[$key] = $value
    }
    return $info
}

function Test-OrphanedProduct([string]$output) {
    $text = [string]$output
    if ($text.ToLowerInvariant().Contains('unknown product')) { return $true }
    return [regex]::IsMatch($text, '\b1605\b')
}

function Test-AdminBlockedUserScope([int]$exitCode, [string]$output) {
    if ($exitCode -eq $script:WingetAdminContextProhibited) { return $true }
    $text = ([string]$output).ToLowerInvariant()
    return ($text.Contains('administrator context') -and $text.Contains('user scope'))
}

function Get-FirstUrl {
    param([string[]]$Candidates)
    foreach ($raw in @($Candidates)) {
        $url = ([string]$raw).Trim()
        if (-not ($url.StartsWith('http://') -or $url.StartsWith('https://'))) { continue }
        $bad = $false
        foreach ($ch in $url.ToCharArray()) {
            if ([char]::IsWhiteSpace($ch) -or [int]$ch -lt 32) { $bad = $true; break }
        }
        if ($bad) { continue }
        return $url
    }
    return ''
}

function New-PackageDetails($package, $showInfo, $arp, [string]$note) {
    if ($null -eq $showInfo) { $showInfo = @{} }
    $homepage = Get-FirstUrl @(
        [string]$showInfo['Homepage'],
        [string]$showInfo['Publisher Url'],
        $(if ($arp) { [string]$arp.HelpLink } else { '' }),
        $(if ($arp) { [string]$arp.UrlInfo } else { '' })
    )
    $publisher = [string]$showInfo['Publisher']
    if ([string]::IsNullOrWhiteSpace($publisher) -and $arp) { $publisher = [string]$arp.Publisher }
    $publisher = $publisher.Trim()
    $description = ([string]$showInfo['Description']).Trim()
    $version = ([string]$showInfo['Version']).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$package.Version }
    $location = ''
    if ($arp -and $arp.InstallLocation) { $location = [string]$arp.InstallLocation }
    $summary = $description
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = $note.Trim() }
    if ([string]::IsNullOrWhiteSpace($summary) -and $publisher) {
        $summary = "Published by $publisher. No catalog description was found."
    }
    if ([string]::IsNullOrWhiteSpace($summary)) {
        $summary = 'No description in winget or the uninstall registry. Search the web for more.'
    }
    $queryParts = New-Object System.Collections.Generic.List[string]
    [void]$queryParts.Add([string]$package.Name)
    if ($publisher) { [void]$queryParts.Add($publisher) }
    [void]$queryParts.Add('windows software')
    $search = 'https://duckduckgo.com/?q=' + [uri]::EscapeDataString(($queryParts -join ' '))
    $name = [string]$showInfo['Name']
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$package.Name }
    $id = [string]$showInfo['Id']
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$package.Id }
    return [pscustomobject]@{
        Name = $name
        Id = $id
        Version = $version
        Publisher = $publisher
        Description = $description
        Summary = $summary
        Homepage = $homepage
        InstallLocation = $location
        Source = [string]$package.Source
        Note = $note.Trim()
        SearchUrl = $search
    }
}

function Open-RegistryHive([string]$hiveName) {
    $hive = [Microsoft.Win32.RegistryHive]::CurrentUser
    if ($hiveName -eq 'HKLM') { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Read-RegistryValues([string]$hiveName, [string]$subkey) {
    $values = @{}
    $base = $null
    $key = $null
    try {
        $base = Open-RegistryHive $hiveName
        $key = $base.OpenSubKey($subkey)
        if ($null -eq $key) { return $values }
        foreach ($name in @($key.GetValueNames())) {
            try { $values[$name] = $key.GetValue($name) } catch { }
        }
    } catch {
    } finally {
        if ($key) { $key.Close() }
        if ($base) { $base.Close() }
    }
    return $values
}

function ConvertTo-CleanRegPath([string]$raw) {
    $text = [Environment]::ExpandEnvironmentVariables(([string]$raw).Trim().Trim('"')).Trim().Trim('"')
    return $text.TrimEnd('\', '/')
}

function Get-IconDirectory([string]$displayIcon) {
    if ([string]::IsNullOrWhiteSpace($displayIcon)) { return $null }
    $text = ConvertTo-CleanRegPath $displayIcon
    $text = [regex]::Replace($text, ',-?\d+$', '').Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if (Test-Path -LiteralPath $text -PathType Leaf) { return (Split-Path -Parent $text) }
    if (Test-Path -LiteralPath $text -PathType Container) { return $text }
    return $null
}

function Get-UninstallRecords {
    $records = [System.Collections.Generic.List[object]]::new()
    $roots = @(
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'HKCU'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    foreach ($root in $roots) {
        $base = $null
        $key = $null
        try {
            $base = Open-RegistryHive $root.Hive
            $key = $base.OpenSubKey($root.Path)
            if ($null -eq $key) { continue }
            foreach ($name in @($key.GetSubKeyNames())) {
                $values = Read-RegistryValues $root.Hive ($root.Path + '\' + $name)
                $installed = ConvertFrom-InstallDate $values['InstallDate']
                [void]$records.Add([pscustomobject]@{
                    DisplayName = [string]$values['DisplayName']
                    Publisher = [string]$values['Publisher']
                    InstallLocation = (ConvertTo-CleanRegPath ([string]$values['InstallLocation']))
                    DisplayIcon = [string]$values['DisplayIcon']
                    UninstallString = [string]$values['UninstallString']
                    KeyName = [string]$name
                    InstallDate = $installed
                    HelpLink = [string]$values['HelpLink']
                    UrlInfo = [string]$values['URLInfoAbout']
                    Hive = [string]$root.Hive
                    KeyPath = ($root.Path + '\' + $name)
                })
            }
        } catch {
        } finally {
            if ($key) { $key.Close() }
            if ($base) { $base.Close() }
        }
    }
    return $records.ToArray()
}

function ConvertFrom-InstallDate($raw) {
    if ($null -eq $raw) { return $null }
    $text = [string]$raw
    $text = $text.Trim()
    if ($text.Length -ne 8 -or $text -notmatch '^\d{8}$') { return $null }
    try { return [datetime]::ParseExact($text, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

function Convert-Rot13([string]$value) {
    if ($null -eq $value) { return '' }
    $chars = $value.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $code = [int]$chars[$i]
        if ($code -ge 65 -and $code -le 90) { $chars[$i] = [char](65 + (($code - 65 + 13) % 26)) }
        elseif ($code -ge 97 -and $code -le 122) { $chars[$i] = [char](97 + (($code - 97 + 13) % 26)) }
    }
    return -join $chars
}

function ConvertFrom-FileTime([byte[]]$raw) {
    if ($null -eq $raw -or $raw.Length -lt 8) { return $null }
    $value = [BitConverter]::ToInt64($raw, 0)
    if ($value -le 0) { return $null }
    try { $stamp = [datetime]::FromFileTime($value) } catch { return $null }
    if ($stamp.Year -lt 1990 -or $stamp.Year -gt 2100) { return $null }
    return $stamp
}

function Get-LaunchRecords {
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($guid in $script:UserAssistGuids) {
        $path = "Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\$guid\Count"
        $base = $null
        $key = $null
        try {
            $base = Open-RegistryHive 'HKCU'
            $key = $base.OpenSubKey($path)
            if ($null -eq $key) { continue }
            foreach ($name in @($key.GetValueNames())) {
                try {
                    $data = $key.GetValue($name)
                    $decoded = Convert-Rot13 $name
                    if ($decoded.StartsWith('UEME_')) { continue }
                    if ($data -isnot [byte[]] -or $data.Length -lt 68) { continue }
                    $slice = New-Object byte[] 8
                    [Array]::Copy($data, 60, $slice, 0, 8)
                    $last = ConvertFrom-FileTime $slice
                    if ($null -eq $last) { continue }
                    [void]$records.Add([pscustomobject]@{ Name = $decoded; LastUsed = $last })
                } catch { }
            }
        } catch {
        } finally {
            if ($key) { $key.Close() }
            if ($base) { $base.Close() }
        }
    }
    return $records.ToArray()
}

function Get-RulesPath {
    $app = $PSScriptRoot
    if (-not $app) { $app = Split-Path -Parent $MyInvocation.MyCommand.Path }
    return Join-Path $app 'data\known_problem.json'
}

function Read-ProblemRules([string]$path) {
    $rules = [pscustomobject]@{ Ids = @(); Publishers = @(); Names = @() }
    $target = $path
    if ([string]::IsNullOrWhiteSpace($target)) { $target = Get-RulesPath }
    if (-not (Test-Path -LiteralPath $target)) { return $rules }
    try { $data = Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $rules }
    foreach ($pair in @(
        @{ Key = 'ids'; Prop = 'Ids' },
        @{ Key = 'publishers'; Prop = 'Publishers' },
        @{ Key = 'names'; Prop = 'Names' }
    )) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @($data.($pair.Key))) {
            if ($null -eq $row) { continue }
            $match = ([string]$row.match).Trim()
            $reason = ([string]$row.reason).Trim()
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'known problem software' }
            if ($match) { [void]$items.Add([pscustomobject]@{ Match = $match; Reason = $reason }) }
        }
        $rules.($pair.Prop) = $items.ToArray()
    }
    return $rules
}

function Find-ArpRecord($package, $records) {
    if ($null -eq $records) { $records = @(Get-UninstallRecords) }
    $tail = ([string]$package.Id).Split('\')[-1].ToLowerInvariant()
    foreach ($record in @($records)) {
        if (([string]$record.KeyName).ToLowerInvariant() -eq $tail) { return $record }
    }
    $name = ConvertTo-Norm ([string]$package.Name)
    if ($name.Length -lt 4) { return $null }
    foreach ($record in @($records)) {
        if ((ConvertTo-Norm ([string]$record.DisplayName)) -eq $name) { return $record }
    }
    return $null
}

function Test-VendorHit([string]$text, [string]$vendor) {
    $vendor = $vendor.Trim().ToLowerInvariant()
    if (-not $vendor) { return $false }
    $pattern = '(?<![a-z0-9])' + [regex]::Escape($vendor) + '(?![a-z0-9])'
    return [regex]::IsMatch([string]$text, $pattern)
}

function Test-ToolName([string]$name, [string]$needle) {
    $name = [string]$name
    $needle = [string]$needle
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($needle)) { return $false }
    if ((ConvertTo-Norm $name) -eq (ConvertTo-Norm $needle)) { return $true }
    $lower = $name.ToLowerInvariant()
    $lowNeedle = $needle.ToLowerInvariant()
    if (-not $lower.StartsWith($lowNeedle)) { return $false }
    if ($lower.Length -eq $lowNeedle.Length) { return $true }
    $next = $lower[$lowNeedle.Length]
    if ($next -match '[a-z0-9]') { return $false }
    return $true
}

function Test-PackageIdHit([string]$id, [string]$needle) {
    $id = ([string]$id).ToLowerInvariant()
    $needle = ([string]$needle).ToLowerInvariant()
    if (-not $needle) { return $false }
    if ($id -eq $needle) { return $true }
    if ($id.StartsWith($needle + '.')) { return $true }
    if ($id.EndsWith('\' + $needle) -or $id.EndsWith('/' + $needle)) { return $true }
    return $false
}

function Get-DependencyTool($package, $arp) {
    if ($null -eq $package) { return $null }
    $id = [string]$package.Id
    $names = New-Object System.Collections.Generic.List[string]
    if ($package.Name) { [void]$names.Add([string]$package.Name) }
    if ($arp -and $arp.DisplayName) { [void]$names.Add([string]$arp.DisplayName) }
    foreach ($tool in @($script:DependencyTools)) {
        foreach ($needle in @($tool.Ids)) {
            if (Test-PackageIdHit $id $needle) { return [string]$tool.Label }
        }
        foreach ($needle in @($tool.Names)) {
            foreach ($name in $names) {
                if (Test-ToolName $name $needle) { return [string]$tool.Label }
            }
        }
    }
    return $null
}

function Get-DependencyUninstallNote($package, $arp) {
    $label = Get-DependencyTool $package $arp
    if (-not $label) { return '' }
    return "$label is a known dependency. Other programs run it in the background. Windows only records when you launch a program yourself, so a missing launch does not mean it is unused. Removing it can break those programs."
}

function Test-ProtectedPackage($package, $arp) {
    $parts = @(
        [string]$package.Name,
        [string]$package.Id,
        $(if ($arp) { [string]$arp.DisplayName } else { '' }),
        $(if ($arp) { [string]$arp.Publisher } else { '' }),
        $(if ($arp) { [string]$arp.InstallLocation } else { '' }),
        $(if ($arp) { [string]$arp.UninstallString } else { '' })
    )
    $blob = ($parts -join ' ').ToLowerInvariant()
    if (([string]$package.Id).ToLowerInvariant().Contains('steam app ')) { return $true }
    if ($blob.Contains('steam://uninstall')) { return $true }
    foreach ($marker in $script:GameStoreMarkers) {
        if ($blob.Contains($marker)) { return $true }
    }
    foreach ($marker in $script:RuntimeMarkers) {
        if ($blob.Contains($marker)) { return $true }
    }
    $publisher = ''
    if ($arp) { $publisher = ([string]$arp.Publisher).ToLowerInvariant() }
    $driverHit = $false
    foreach ($pub in $script:DriverPublishers) {
        if ((Test-VendorHit $publisher $pub) -or (Test-VendorHit $blob $pub)) { $driverHit = $true; break }
    }
    if ($driverHit) {
        foreach ($word in @('driver', 'graphics', 'audio', 'chipset', 'wlan', 'bluetooth', 'vga', 'display')) {
            if ($blob.Contains($word)) { return $true }
        }
    }
    $id = ([string]$package.Id).ToLowerInvariant()
    foreach ($prefix in @('nvidia.', 'amd.', 'intel.', 'microsoft.vcredist', 'microsoft.dotnet', 'microsoft.edgewebview')) {
        if ($id.StartsWith($prefix)) { return $true }
    }
    return $false
}

function Get-KnownProblemReason($package, $arp, $rules) {
    $pkgId = ([string]$package.Id).ToLowerInvariant()
    foreach ($rule in @($rules.Ids)) {
        $needle = ([string]$rule.Match).ToLowerInvariant()
        if (-not $needle) { continue }
        if ($pkgId -eq $needle -or $pkgId.StartsWith($needle + '.') -or $pkgId.EndsWith('.' + $needle) -or $pkgId.EndsWith('\' + $needle)) {
            return [string]$rule.Reason
        }
    }
    $name = ConvertTo-Norm ([string]$package.Name)
    $publisher = ''
    if ($arp) { $publisher = ConvertTo-Norm ([string]$arp.Publisher) }
    foreach ($rule in @($rules.Publishers)) {
        $needle = ConvertTo-Norm ([string]$rule.Match)
        if ($needle -and $publisher.Contains($needle)) { return [string]$rule.Reason }
    }
    foreach ($rule in @($rules.Names)) {
        $needle = ConvertTo-Norm ([string]$rule.Match)
        if ($needle.Length -ge 6 -and $name.Contains($needle)) { return [string]$rule.Reason }
        if ($arp -and $needle.Length -ge 6 -and (ConvertTo-Norm ([string]$arp.DisplayName)).Contains($needle)) {
            return [string]$rule.Reason
        }
    }
    return $null
}

function Get-LastUsed($package, $arp, $launches) {
    $needles = New-Object System.Collections.Generic.List[string]
    if ((ConvertTo-Norm ([string]$package.Name)).Length -ge 5) { [void]$needles.Add([string]$package.Name) }
    if ($arp) {
        if ($arp.InstallLocation) { [void]$needles.Add([string]$arp.InstallLocation) }
        $icon = ([string]$arp.DisplayIcon).Trim().Trim('"')
        $icon = [regex]::Replace($icon, ',-?\d+$', '')
        if ($icon) { [void]$needles.Add($icon) }
        if ((ConvertTo-Norm ([string]$arp.DisplayName)).Length -ge 5) { [void]$needles.Add([string]$arp.DisplayName) }
    }
    $best = $null
    foreach ($launch in @($launches)) {
        $hay = ([string]$launch.Name).ToLowerInvariant()
        foreach ($needle in $needles) {
            $n = $needle.ToLowerInvariant().Trim()
            if ($n.Length -lt 4) { continue }
            $file = ''
            try { $file = [IO.Path]::GetFileName($n).ToLowerInvariant() } catch { $file = '' }
            if ($hay.Contains($n) -or ($file -and $hay.Contains($file))) {
                if ($null -eq $best -or $launch.LastUsed -gt $best) { $best = $launch.LastUsed }
                break
            }
        }
    }
    return $best
}

function Test-LooksUnused($lastUsed, $arp, [datetime]$cutoff) {
    if ($null -ne $lastUsed) { return ($lastUsed -lt $cutoff) }
    if ($arp -and $arp.InstallDate -and $arp.InstallDate -lt $cutoff) { return $true }
    return $false
}

function Get-Suspects($packages, $arp, $launches, $rules, [int]$unusedMonths, [datetime]$now) {
    if ($null -eq $rules) { $rules = Read-ProblemRules '' }
    if ($unusedMonths -lt 1) { $unusedMonths = 1 }
    $cutoff = $now.AddDays(-1 * ($unusedMonths * 30))
    $suspects = [System.Collections.Generic.List[object]]::new()
    foreach ($package in @($packages)) {
        if ($null -eq $package) { continue }
        $hit = Find-ArpRecord $package $arp
        $last = Get-LastUsed $package $hit $launches
        $reasons = New-Object System.Collections.Generic.List[string]
        $problem = Get-KnownProblemReason $package $hit $rules
        if ($problem) { [void]$reasons.Add($problem) }
        $dependency = Get-DependencyTool $package $hit
        if (-not (Test-ProtectedPackage $package $hit) -and -not $dependency -and (Test-LooksUnused $last $hit $cutoff)) {
            if ($last) {
                [void]$reasons.Add('no recorded launches since ' + $last.ToString('yyyy-MM-dd'))
            } elseif ($hit -and $hit.InstallDate) {
                [void]$reasons.Add('no recorded launches; installed ' + $hit.InstallDate.ToString('yyyy-MM-dd'))
            } else {
                [void]$reasons.Add('no recorded launches in the last months')
            }
        }
        if ($reasons.Count -gt 0) {
            $rank = 1
            foreach ($reason in $reasons) {
                if ($reason -match 'known|OEM|PUP') { $rank = 0; break }
            }
            $sortDate = $last
            if ($null -eq $sortDate) { $sortDate = [datetime]'1601-01-01' }
            $label = 'no recorded launches'
            if ($last) { $label = $last.ToString('yyyy-MM-dd') }
            elseif ($hit -and $hit.InstallDate) { $label = 'no launches (installed ' + $hit.InstallDate.ToString('yyyy-MM-dd') + ')' }
            [void]$suspects.Add([pscustomobject]@{
                Package = $package
                Reasons = $reasons.ToArray()
                Why = ($reasons -join '; ')
                LastUsed = $last
                InstallDate = $(if ($hit) { $hit.InstallDate } else { $null })
                LastUsedLabel = $label
                Rank = $rank
                SortDate = $sortDate
            })
        }
    }
    $sorted = @($suspects | Sort-Object Rank, SortDate, @{ Expression = { [string]$_.Package.Name }; Ascending = $true })
    return $sorted
}

function Get-MatchNames($package, $showInfo) {
    if ($null -eq $showInfo) { $showInfo = @{} }
    $tail = ''
    $id = [string]$package.Id
    if ($id.Contains('\')) {
        $tail = $id.Split('\')[-1].Trim()
        if ((Test-SteamAppId $tail) -or (Test-SteamAppId $id)) { $tail = '' }
    }
    $catalogId = ''
    $idSuffix = ''
    if (-not $id.Contains('\')) {
        $catalogId = $id
        if ($id.Contains('.')) { $idSuffix = $id.Split('.')[-1] }
    }
    $raw = @(
        [string]$package.Name,
        $catalogId,
        $idSuffix,
        $tail,
        [string]$showInfo['Name'],
        [string]$showInfo['Moniker']
    )
    $names = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in $raw) {
        $item = ([string]$item).Trim()
        if (-not $item) { continue }
        $key = ConvertTo-Norm $item
        if ($key.Length -lt 3 -or $seen.ContainsKey($key)) { continue }
        if ($script:FuzzyStopwords -contains $key) { continue }
        $seen[$key] = $true
        [void]$names.Add($item)
    }
    return $names.ToArray()
}

function Get-NameHit([string]$candidate, [string[]]$names, [bool]$genericPublisher) {
    $cand = ConvertTo-Norm $candidate
    if ($cand.Length -lt 3 -or ($script:FuzzyStopwords -contains $cand)) { return $null }
    $generic = @{}
    foreach ($item in $script:GenericPublishers) { $generic[(ConvertTo-Norm $item)] = $true }
    foreach ($name in @($names)) {
        $key = ConvertTo-Norm $name
        if ($key.Length -lt 3 -or ($script:FuzzyStopwords -contains $key)) { continue }
        if ($genericPublisher -and $generic.ContainsKey($key)) { continue }
        if ($cand -eq $key) { return "exact name match ($name)" }
        if ($key.Length -ge 5 -and $cand.Contains($key)) { return "name match ($name)" }
    }
    return $null
}

function Test-GenericPublisher($showInfo) {
    $publisher = ConvertTo-Norm ([string]$showInfo['Publisher'])
    foreach ($item in $script:GenericPublishers) {
        if ($publisher -eq (ConvertTo-Norm $item)) { return $true }
    }
    return $false
}

function Test-UnderPath([string]$path, [string]$root) {
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($root)) { return '' }
    try {
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        $base = [IO.Path]::GetFullPath($root).TrimEnd('\')
    } catch { return '' }
    if ($full.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { return 'exact' }
    if ($full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'child' }
    return ''
}

function Test-SafeFilePath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return @{ Ok = $false; Reason = 'could not resolve path' } }
    $item = $null
    try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
    catch { return @{ Ok = $false; Reason = 'does not exist' } }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return @{ Ok = $false; Reason = 'symlink or junction' }
    }
    try { $resolved = [IO.Path]::GetFullPath($item.FullName).TrimEnd('\') }
    catch { return @{ Ok = $false; Reason = 'could not resolve path' } }
    if ([string]::IsNullOrWhiteSpace($resolved) -or -not $resolved.Contains('\')) {
        return @{ Ok = $false; Reason = 'path is a drive root' }
    }
    $lower = $resolved.ToLowerInvariant()
    if ($lower.Contains('\steamapps\') -or $lower.EndsWith('\steamapps')) {
        return @{ Ok = $false; Reason = 'Steam library folder' }
    }
    foreach ($pair in @(
        @{ Marker = '\epic games\'; Label = 'Epic Games library' },
        @{ Marker = '\gog galaxy\games\'; Label = 'GOG library' },
        @{ Marker = '\xboxgames\'; Label = 'Xbox game library' },
        @{ Marker = '\windowsapps\'; Label = 'Windows Store app folder' },
        @{ Marker = '\modifiablewindowsapps\'; Label = 'Windows Store app folder' }
    )) {
        if ($lower.Contains($pair.Marker)) { return @{ Ok = $false; Reason = $pair.Label } }
    }
    if ($lower.EndsWith('\microsoft\winget\packages') -or $lower.EndsWith('\microsoft\winget')) {
        return @{ Ok = $false; Reason = 'WinGet root' }
    }
    if ($item.PSIsContainer) {
        try {
            if (Test-Path -LiteralPath (Join-Path $resolved 'steamapps') -PathType Container) {
                return @{ Ok = $false; Reason = 'contains a Steam library' }
            }
        } catch {
            return @{ Ok = $false; Reason = 'could not inspect folder' }
        }
    }
    $windir = $env:WINDIR
    if ([string]::IsNullOrWhiteSpace($windir)) { $windir = 'C:\Windows' }
    $underWindows = Test-UnderPath $resolved $windir
    if ($underWindows) { return @{ Ok = $false; Reason = 'under the Windows directory' } }
    $leaf = [IO.Path]::GetFileName($resolved).ToLowerInvariant()
    if ($script:ProtectedFolderNames -contains $leaf) {
        return @{ Ok = $false; Reason = "protected folder name ($leaf)" }
    }
    $underAllowed = $false
    $relParts = @()
    foreach ($key in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramData', 'LOCALAPPDATA', 'APPDATA')) {
        $root = [Environment]::GetEnvironmentVariable($key)
        if (-not $root) { continue }
        $relation = Test-UnderPath $resolved $root
        if (-not $relation) { continue }
        if ($relation -eq 'exact') { return @{ Ok = $false; Reason = 'refuses to delete an allowed root itself' } }
        $underAllowed = $true
        $base = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $rel = $resolved.Substring($base.Length).TrimStart('\')
        $relParts = @($rel.Split('\'))
        if ($relParts.Count -eq 1) {
            foreach ($pub in $script:GenericPublishers) {
                if ($relParts[0].ToLowerInvariant() -eq $pub) {
                    return @{ Ok = $false; Reason = 'publisher folder is too broad' }
                }
            }
        }
        break
    }
    $profileRoot = ''
    try { $profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\') } catch { $profileRoot = '' }
    $relHome = $null
    if ($profileRoot) {
        $homeRelation = Test-UnderPath $resolved $profileRoot
        if ($homeRelation -eq 'exact') { return @{ Ok = $false; Reason = 'user profile root' } }
        if ($homeRelation -eq 'child') {
            $relHome = @($resolved.Substring($profileRoot.Length).TrimStart('\').Split('\'))
        }
    }
    if ($null -ne $relHome) {
        $top = $relHome[0].ToLowerInvariant()
        if (@('documents', 'desktop', 'downloads', 'pictures', 'videos', 'music', 'onedrive') -contains $top) {
            return @{ Ok = $false; Reason = 'user documents folder' }
        }
        if ($top -ne 'appdata' -and -not $underAllowed) {
            return @{ Ok = $false; Reason = 'inside the user profile but not AppData' }
        }
    }
    if (-not $underAllowed -and $null -eq $relHome) {
        return @{ Ok = $false; Reason = 'outside Program Files / AppData / ProgramData' }
    }
    return @{ Ok = $true; Reason = 'ok' }
}

function New-Leftover([string]$kind, [string]$path, [string]$reason, [string]$hive, [string]$regSubkey, [string]$fsPath) {
    return [pscustomobject]@{
        Kind = $kind
        Path = $path
        Reason = $reason
        Selected = $false
        Hive = $hive
        RegSubkey = $regSubkey
        FsPath = $fsPath
    }
}

function New-FolderLeftover([string]$path, [string]$reason) {
    if ([string]::IsNullOrWhiteSpace($path)) { return @() }
    $safety = Test-SafeFilePath $path
    if (-not $safety.Ok) { return @() }
    $kind = 'file'
    if (Test-Path -LiteralPath $path -PathType Container) { $kind = 'directory' }
    $full = $path
    try { $full = [IO.Path]::GetFullPath($path) } catch { }
    return @(New-Leftover $kind $path $reason '' '' $full)
}

function Test-RegistrySubkeyAllowed([string]$subkey) {
    $parts = @()
    foreach ($part in ([string]$subkey).Split('\')) {
        if ($part) { $parts += $part.ToLowerInvariant() }
    }
    $prefixes = @(
        @('software', 'microsoft', 'windows', 'currentversion', 'uninstall'),
        @('software', 'wow6432node', 'microsoft', 'windows', 'currentversion', 'uninstall')
    )
    foreach ($prefix in $prefixes) {
        if ($parts.Count -eq ($prefix.Count + 1)) {
            $same = $true
            for ($i = 0; $i -lt $prefix.Count; $i++) {
                if ($parts[$i] -ne $prefix[$i]) { $same = $false; break }
            }
            if ($same) {
                $leaf = $parts[-1]
                return ($leaf -and $leaf -ne '.' -and $leaf -ne '..')
            }
        }
    }
    if ($parts.Count -eq 2 -and $parts[0] -eq 'software') {
        return (Test-VendorKeyAllowed $parts[1])
    }
    if ($parts.Count -eq 3 -and $parts[0] -eq 'software' -and $parts[1] -eq 'wow6432node') {
        return (Test-VendorKeyAllowed $parts[2])
    }
    return $false
}

function Test-VendorKeyAllowed([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -lt 2) { return $false }
    if ($script:BlockedRegVendors -contains $name.ToLowerInvariant()) { return $false }
    return $true
}

function Test-LeftoverNeedsAdmin($item) {
    if ($item.Kind -eq 'registry') {
        if ($item.Hive -eq 'HKLM') { return $true }
        return ([string]$item.Path).ToUpperInvariant().StartsWith('HKLM\')
    }
    $raw = [string]$item.FsPath
    if (-not $raw) { $raw = [string]$item.Path }
    if (-not $raw) { return $false }
    foreach ($key in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramData')) {
        $root = [Environment]::GetEnvironmentVariable($key)
        if (-not $root) { continue }
        if (Test-UnderPath $raw $root) { return $true }
    }
    return $false
}

function ConvertTo-ItemArray($items) {
    # @() on a List[object] built with New-Object throws "Argument types do not match".
    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $items) { return $list.ToArray() }
    $many = ($items -is [System.Collections.IEnumerable]) -and ($items -isnot [string])
    if ($many) {
        foreach ($item in $items) {
            if ($null -ne $item) { [void]$list.Add($item) }
        }
    } else {
        [void]$list.Add($items)
    }
    return $list.ToArray()
}

function Set-LeftoverSelection($items, [bool]$trustUninstallKeys) {
    $list = ConvertTo-ItemArray $items
    foreach ($item in $list) {
        $uninstall = $false
        if ($item.Kind -eq 'registry' -and $item.RegSubkey -and ([string]$item.RegSubkey).ToLowerInvariant().Contains('\uninstall\')) {
            $uninstall = $true
        }
        $item.Selected = [bool]($trustUninstallKeys -and $uninstall)
    }
    return $list
}

function Find-Leftovers($package, $showInfo) {
    if ($null -eq $showInfo) { $showInfo = @{} }
    $names = @(Get-MatchNames $package $showInfo)
    $found = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($item in @(Find-UninstallLeftovers $names $package)) { Add-UniqueLeftover $found $seen $item }
    foreach ($item in @(Find-SoftwareLeftovers $names $showInfo)) { Add-UniqueLeftover $found $seen $item }
    foreach ($item in @(Find-FolderLeftovers $names $showInfo)) { Add-UniqueLeftover $found $seen $item }
    return $found.ToArray()
}

function Add-UniqueLeftover($found, $seen, $item) {
    if ($null -eq $item) { return }
    $key = [string]$item.FsPath
    if (-not $key) { $key = [string]$item.Path }
    if (-not $key -or $seen.ContainsKey($key.ToLowerInvariant())) { return }
    $seen[$key.ToLowerInvariant()] = $true
    [void]$found.Add($item)
}

function Find-UninstallLeftovers([string[]]$names, $package) {
    $items = [System.Collections.Generic.List[object]]::new()
    $roots = @(
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'HKCU'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    foreach ($root in $roots) {
        $base = $null
        $key = $null
        try {
            $base = Open-RegistryHive $root.Hive
            $key = $base.OpenSubKey($root.Path)
            if ($null -eq $key) { continue }
            foreach ($sub in @($key.GetSubKeyNames())) {
                $subpath = $root.Path + '\' + $sub
                $values = Read-RegistryValues $root.Hive $subpath
                $display = [string]$values['DisplayName']
                $candidate = $display
                if (-not $candidate) { $candidate = $sub }
                $reason = Get-NameHit $candidate $names $false
                if (-not $reason) { continue }
                [void]$items.Add((New-Leftover 'registry' ($root.Hive + '\' + $subpath) ("remaining uninstall entry - $reason") $root.Hive $subpath ''))
                $location = ConvertTo-CleanRegPath ([string]$values['InstallLocation'])
                if ($location) {
                    foreach ($folder in @(New-FolderLeftover $location 'InstallLocation from registry')) {
                        [void]$items.Add($folder)
                    }
                }
                $iconDir = Get-IconDirectory ([string]$values['DisplayIcon'])
                if ($iconDir) {
                    foreach ($folder in @(New-FolderLeftover $iconDir 'DisplayIcon folder from registry')) {
                        [void]$items.Add($folder)
                    }
                }
            }
        } catch {
        } finally {
            if ($key) { $key.Close() }
            if ($base) { $base.Close() }
        }
    }
    return $items.ToArray()
}

function Find-SoftwareLeftovers([string[]]$names, $showInfo) {
    $items = [System.Collections.Generic.List[object]]::new()
    $generic = Test-GenericPublisher $showInfo
    $roots = @(
        @{ Hive = 'HKCU'; Path = 'SOFTWARE' },
        @{ Hive = 'HKLM'; Path = 'SOFTWARE' },
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node' }
    )
    $genericNames = @{}
    foreach ($pub in $script:GenericPublishers) { $genericNames[(ConvertTo-Norm $pub)] = $true }
    foreach ($root in $roots) {
        $base = $null
        $key = $null
        try {
            $base = Open-RegistryHive $root.Hive
            $key = $base.OpenSubKey($root.Path)
            if ($null -eq $key) { continue }
            foreach ($sub in @($key.GetSubKeyNames())) {
                $reason = Get-NameHit $sub $names $generic
                if (-not $reason) { continue }
                if ($genericNames.ContainsKey((ConvertTo-Norm $sub))) { continue }
                $subpath = $root.Path + '\' + $sub
                [void]$items.Add((New-Leftover 'registry' ($root.Hive + '\' + $subpath) ("software key - $reason") $root.Hive $subpath ''))
            }
        } catch {
        } finally {
            if ($key) { $key.Close() }
            if ($base) { $base.Close() }
        }
    }
    return $items.ToArray()
}

function Get-CandidateFolders {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramData', 'LOCALAPPDATA', 'APPDATA')) {
        $value = [Environment]::GetEnvironmentVariable($key)
        if ($value) { [void]$roots.Add($value) }
    }
    if ($env:LOCALAPPDATA) {
        [void]$roots.Add((Join-Path $env:LOCALAPPDATA 'Programs'))
        [void]$roots.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'))
    }
    $folders = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try { $children = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop) }
        catch { continue }
        foreach ($child in $children) {
            try { $key = $child.FullName.ToLowerInvariant() } catch { continue }
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$folders.Add($child.FullName)
        }
    }
    return $folders.ToArray()
}

function Find-FolderLeftovers([string[]]$names, $showInfo) {
    $items = [System.Collections.Generic.List[object]]::new()
    $generic = Test-GenericPublisher $showInfo
    foreach ($folder in @(Get-CandidateFolders)) {
        $reason = Get-NameHit ([IO.Path]::GetFileName($folder)) $names $generic
        if (-not $reason) { continue }
        foreach ($left in @(New-FolderLeftover $folder $reason)) { [void]$items.Add($left) }
    }
    return $items.ToArray()
}

function Remove-Leftovers($items) {
    $results = New-Object System.Collections.Generic.List[string]
    foreach ($item in (ConvertTo-ItemArray $items)) {
        if ($null -eq $item) { continue }
        if ($item.Kind -eq 'registry') { [void]$results.Add((Remove-LeftoverRegistry $item)) }
        else { [void]$results.Add((Remove-LeftoverFile $item)) }
    }
    return $results.ToArray()
}

function Remove-LeftoverFile($item) {
    $path = [string]$item.FsPath
    if (-not $path) { $path = [string]$item.Path }
    $safety = Test-SafeFilePath $path
    if (-not $safety.Ok) { return "SKIP $path ($($safety.Reason))" }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        if (Test-Path -LiteralPath $path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        return "OK   recycle $path"
    } catch {
        $text = $_.Exception.Message
        if ($text -match 'denied|0x80070005') { $text = 'Access denied. This leftover needs Administrator.' }
        return "FAIL $path ($text)"
    }
}

function Remove-LeftoverRegistry($item) {
    if (-not $item.Hive -or -not $item.RegSubkey) { return "SKIP $($item.Path) (incomplete registry target)" }
    if (-not (Test-RegistrySubkeyAllowed $item.RegSubkey)) { return "SKIP $($item.Path) (registry path not allowed)" }
    $base = $null
    try {
        $base = Open-RegistryHive ([string]$item.Hive)
        $base.DeleteSubKeyTree([string]$item.RegSubkey, $false)
        return "OK   delete $($item.Path)"
    } catch {
        $text = $_.Exception.Message
        if ($text -match 'denied|Unauthorized|0x80070005') { $text = 'Access denied. This leftover needs Administrator.' }
        return "FAIL $($item.Path) ($text)"
    } finally {
        if ($base) { $base.Close() }
    }
}

function ConvertTo-JsonArray($items) {
    $list = @($items)
    if ($list.Count -eq 0 -or $null -eq $list[0]) { return '[]' }
    $parts = foreach ($item in $list) {
        if ($null -eq $item) { continue }
        ConvertTo-Json -InputObject $item -Depth 6 -Compress
    }
    return '[' + ($parts -join ',') + ']'
}

function ConvertFrom-JsonArray([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $parsed = $text | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function ConvertTo-LeftoverJson($items) {
    $rows = foreach ($item in (ConvertTo-ItemArray $items)) {
        [pscustomobject]@{
            kind = [string]$item.Kind
            path = [string]$item.Path
            reason = [string]$item.Reason
            selected = [bool]$item.Selected
            hive = [string]$item.Hive
            reg_subkey = [string]$item.RegSubkey
            fs_path = [string]$item.FsPath
        }
    }
    return ConvertTo-JsonArray $rows
}

function ConvertFrom-LeftoverJson([string]$text) {
    $rows = @(ConvertFrom-JsonArray $text)
    $items = foreach ($row in $rows) {
        if ($null -eq $row) { continue }
        New-Leftover ([string]$row.kind) ([string]$row.path) ([string]$row.reason) ([string]$row.hive) ([string]$row.reg_subkey) ([string]$row.fs_path)
    }
    return @($items)
}

function Invoke-CleanupFile([string]$inPath, [string]$outPath) {
    if (-not (Test-Path -LiteralPath $inPath)) { throw "Missing leftover list: $inPath" }
    $text = [IO.File]::ReadAllText($inPath)
    $items = @(ConvertFrom-LeftoverJson $text)
    $results = @(Remove-Leftovers $items)
    $pieces = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($results)) {
        [void]$pieces.Add((ConvertTo-Json -InputObject ([string]$line) -Compress))
    }
    [IO.File]::WriteAllText($outPath, ('[' + ($pieces -join ',') + ']'))
    foreach ($line in @($results)) { Write-Output $line }
}

function Invoke-RunCaptured([string]$specPath) {
    $spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $argv = @($spec.argv | ForEach-Object { [string]$_ })
    $logPath = [string]$spec.log
    $exitPath = [string]$spec.exit
    $interactive = [bool]$spec.interactive
    $code = 1
    try {
        if ($argv.Count -eq 0) { throw 'captured command must be winget' }
        $leaf = [IO.Path]::GetFileName($argv[0]).ToLowerInvariant()
        if (@('winget.exe', 'winget', 'winget.cmd', 'winget.bat') -notcontains $leaf) {
            throw 'captured command must be winget'
        }
        if ($interactive) {
            $proc = Start-Process -FilePath $argv[0] -ArgumentList ($argv | Select-Object -Skip 1) -PassThru -Wait
            $code = [int]$proc.ExitCode
        } else {
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $argv[0]
            $psi.Arguments = Format-CommandLine @($argv | Select-Object -Skip 1)
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            $proc = [Diagnostics.Process]::Start($psi)
            $output = $proc.StandardOutput.ReadToEnd()
            $err = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $code = [int]$proc.ExitCode
            if ($logPath) { [IO.File]::WriteAllText($logPath, ($output + $err)) }
        }
    } catch {
        $code = 1
        if ($logPath) {
            try { [IO.File]::WriteAllText($logPath, ('Failed to run command: ' + $_.Exception.Message + "`n")) } catch { }
        }
        Write-Error $_.Exception.Message
    } finally {
        if ($exitPath) {
            try { [IO.File]::WriteAllText($exitPath, [string]([int]$code)) } catch { }
        }
    }
    exit ([int]$code)
}

function Assert-Engine([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Invoke-EngineSelfTest {
    $search = @"
Name                               Id                        Version       Match         Source
-----------------------------------------------------------------------------------------------
7-Zip                              7zip.7zip                 26.03         Moniker: 7zip winget
Advanced Archive Password Recovery Elcomsoft.ArchivePassword 4.66.266.6965 Tag: 7zip     winget
NanaZip                            M2Team.NanaZip            7.0.1832.0    Tag: 7zip     winget
"@
    $rows = @(ConvertFrom-WingetTable $search)
    Assert-Engine ($rows.Count -ge 3) 'search table parsed too few rows'
    Assert-Engine ($rows[0].Name -eq '7-Zip') 'search name'
    Assert-Engine ($rows[0].Id -eq '7zip.7zip') 'search id'
    Assert-Engine ($rows[0].Version -eq '26.03') 'search version'
    Assert-Engine ($rows[0].Source -eq 'winget') 'search source'
    Assert-Engine ($rows[0].IsCatalog) 'search catalog'

    $list = @"
Name                  Id                                           Version     Source
--------------------------------------------------------------------------------------
AMD Ryzen Master      ARP\Machine\X64\AMD Ryzen Master             3.0.1.4819
Bambu Studio          Bambulab.Bambustudio                         02.08.02.61 winget
Git                   Git.Git                                      2.55.0.3    winget
"@
    $listed = @(ConvertFrom-WingetTable $list)
    $byId = @{}
    foreach ($row in $listed) { $byId[$row.Id] = $row }
    Assert-Engine ($byId.ContainsKey('Git.Git') -and $byId['Git.Git'].IsCatalog) 'git catalog'
    Assert-Engine ($byId.ContainsKey('ARP\Machine\X64\AMD Ryzen Master')) 'arp id'
    Assert-Engine (-not $byId['ARP\Machine\X64\AMD Ryzen Master'].IsCatalog) 'arp is not catalog'

    $upgrade = @"
Name                 Id                           Version   Available Source
----------------------------------------------------------------------------
Epic Games Launcher  EpicGames.EpicGamesLauncher  1.3.161.0 1.3.193.0 winget
HWiNFO 64            REALiX.HWiNFO                8.34      8.50      winget
4 upgrades available.
"@
    $up = @(ConvertFrom-WingetTable $upgrade)
    Assert-Engine ($up.Count -eq 2) ('upgrade count ' + $up.Count)
    Assert-Engine ($up[0].Available -eq '1.3.193.0') 'available version'
    Assert-Engine (@(ConvertFrom-WingetTable '').Count -eq 0) 'empty table'
    Assert-Engine (@(ConvertFrom-WingetTable 'No package found matching input criteria.').Count -eq 0) 'no package text'

    $show = @"
Found 7-Zip [7zip.7zip]
Version: 26.03
Publisher: Igor Pavlov
Description: A file archiver with a high compression ratio.
Moniker: 7zip
Homepage: https://7-zip.org/download.html
License: LGPL-2.1
"@
    $info = ConvertFrom-WingetShow $show
    Assert-Engine ($info['Name'] -eq '7-Zip') 'show name'
    Assert-Engine ($info['Publisher'] -eq 'Igor Pavlov') 'show publisher'
    $pkg = [pscustomobject]@{ Name = '7-Zip'; Id = '7zip.7zip'; Version = '26.03'; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    $details = New-PackageDetails $pkg $info $null ''
    Assert-Engine ($details.Summary.ToLowerInvariant().Contains('file archiver')) 'summary'
    Assert-Engine ($details.Homepage -eq 'https://7-zip.org/download.html') 'homepage'
    Assert-Engine ($details.SearchUrl.StartsWith('https://duckduckgo.com/?q=')) 'search url'
    Assert-Engine ((Get-FirstUrl @('', 'not-a-url', 'https://example.com/x')) -eq 'https://example.com/x') 'first url'
    Assert-Engine ((Get-FirstUrl @('ftp://x')) -eq '') 'ftp ignored'

    $silent = @(Get-WingetExtraFlags 'install' $true $true)
    Assert-Engine ($silent -contains '--silent' -and $silent -contains '--accept-package-agreements') 'install flags'
    Assert-Engine (@(Get-WingetExtraFlags 'install' $true $false).Count -eq 0) 'interactive flags'
    $readFlags = @(Get-WingetExtraFlags 'search' $false $false)
    Assert-Engine ($readFlags -contains '--accept-source-agreements' -and $readFlags -notcontains '--silent') 'read flags'
    $uninstallFlags = @(Get-WingetExtraFlags 'uninstall' $true $true)
    Assert-Engine ($uninstallFlags -contains '--silent' -and $uninstallFlags -notcontains '--accept-package-agreements') 'uninstall flags'
    Assert-Engine (Test-OrphanedProduct "Uninstall failed with exit code: 1605") '1605'
    Assert-Engine (-not (Test-OrphanedProduct 'Uninstall failed with exit code: 1603')) '1603'
    Assert-Engine (Test-UserScopeId 'ARP\User\X64\GameRanger') 'user scope'
    Assert-Engine (-not (Test-UserScopeId 'ARP\Machine\X64\{605108C1}')) 'machine scope'
    Assert-Engine (Test-SteamAppId 'ARP\Machine\X64\Steam App 945360') 'steam id'
    Assert-Engine ((Get-SteamAppNumber 'ARP\Machine\X64\Steam App 4565790') -eq '4565790') 'steam number'
    Assert-Engine (-not (Test-SteamAppId 'Valve.Steam')) 'valve steam client'
    Assert-Engine (Test-AdminBlockedUserScope $script:WingetAdminContextProhibited 'anything') 'admin code'

    Assert-Engine ((ConvertTo-Norm '7-Zip') -eq '7zip') 'norm'
    Assert-Engine (Test-RegistrySubkeyAllowed 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip') 'uninstall key'
    Assert-Engine (Test-RegistrySubkeyAllowed 'SOFTWARE\7-Zip') 'vendor key'
    Assert-Engine (-not (Test-RegistrySubkeyAllowed 'SOFTWARE')) 'software root'
    Assert-Engine (-not (Test-RegistrySubkeyAllowed 'SOFTWARE\Microsoft')) 'microsoft blocked'
    Assert-Engine (Test-RegistrySubkeyAllowed 'SOFTWARE\WOW6432Node\Angry IP Scanner') 'wow vendor'

    $homeSafe = Test-SafeFilePath $env:USERPROFILE
    Assert-Engine (-not $homeSafe.Ok) 'home unsafe'
    $docs = Join-Path $env:USERPROFILE 'Documents'
    if (Test-Path -LiteralPath $docs) {
        Assert-Engine (-not (Test-SafeFilePath $docs).Ok) 'documents unsafe'
    }
    Assert-Engine (-not (Test-SafeFilePath $env:WINDIR).Ok) 'windows unsafe'
    $pf = ${env:ProgramFiles}
    if ($pf) { Assert-Engine (-not (Test-SafeFilePath $pf).Ok) 'program files root' }
    Assert-Engine (-not (Test-SafeFilePath 'C:\definitely-not-a-real-clean-installer-path-xyz').Ok) 'missing path'
    Assert-Engine (-not (Test-SafeFilePath $env:TEMP).Ok) 'temp root'
    $programs = Join-Path $env:LOCALAPPDATA 'Programs'
    if (Test-Path -LiteralPath $programs) { Assert-Engine (-not (Test-SafeFilePath $programs).Ok) 'programs root' }

    $steamRoot = Join-Path $env:TEMP 'ci-selftest-steam'
    $steamApps = Join-Path $steamRoot 'steamapps\common'
    New-Item -ItemType Directory -Path $steamApps -Force | Out-Null
    try {
        $steamSafe = Test-SafeFilePath $steamRoot
        Assert-Engine (-not $steamSafe.Ok) 'steamapps container'
        Assert-Engine ($steamSafe.Reason -match 'Steam') 'steam reason'
    } finally {
        Remove-Item -LiteralPath $steamRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $game = [pscustomobject]@{ Name = 'Timberborn'; Id = 'ARP\Machine\X64\Steam App 1062090'; Version = ''; Source = ''; Available = ''; Match = ''; Note = '' }
    $gameNames = @(Get-MatchNames $game @{})
    Assert-Engine ($null -eq (Get-NameHit 'Steam' $gameNames $false)) 'steam token'
    Assert-Engine ($null -eq (Get-NameHit 'x64' $gameNames $false)) 'x64 token'
    Assert-Engine ($null -ne (Get-NameHit 'Timberborn' $gameNames $false)) 'game name'
    $code = [pscustomobject]@{ Name = 'Visual Studio Code'; Id = 'Microsoft.VisualStudioCode'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    $codeNames = @(Get-MatchNames $code @{ Publisher = 'Microsoft Corporation'; Moniker = 'vscode' })
    Assert-Engine ($null -eq (Get-NameHit 'Code' $codeNames $true)) 'code stopword'
    Assert-Engine ($null -eq (Get-NameHit 'Microsoft' $codeNames $true)) 'microsoft name'
    Assert-Engine ($null -ne (Get-NameHit 'Microsoft VS Code' $codeNames $true)) 'vscode moniker'
    $git = [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    $gitNames = @(Get-MatchNames $git @{})
    Assert-Engine ($null -ne (Get-NameHit 'Git' $gitNames $false)) 'git exact'
    Assert-Engine ($null -ne (Get-NameHit 'Git.Git_Microsoft.Winget.Source_8wekyb3d8bbwe' $gitNames $false)) 'winget folder'
    Assert-Engine ($null -eq (Get-NameHit 'GitHub' $gitNames $false)) 'github not git'

    $reg = New-Leftover 'registry' 'HKLM\SOFTWARE\WOW6432Node\Angry IP Scanner' 'test' 'HKLM' 'SOFTWARE\WOW6432Node\Angry IP Scanner' ''
    Assert-Engine (Test-LeftoverNeedsAdmin $reg) 'hklm admin'
    $hkcu = New-Leftover 'registry' 'HKCU\SOFTWARE\Angry IP Scanner' 'test' 'HKCU' 'SOFTWARE\Angry IP Scanner' ''
    Assert-Engine (-not (Test-LeftoverNeedsAdmin $hkcu)) 'hkcu user'
    $dir = New-Leftover 'directory' 'C:\Program Files\Angry IP Scanner' 'test' '' '' 'C:\Program Files\Angry IP Scanner'
    Assert-Engine (Test-LeftoverNeedsAdmin $dir) 'program files admin'
    $blocked = New-Leftover 'registry' 'HKCU\SOFTWARE\Microsoft' 'test' 'HKCU' 'SOFTWARE\Microsoft' ''
    $blockedResult = @(Remove-Leftovers @($blocked))
    Assert-Engine ($blockedResult[0].StartsWith('SKIP')) 'blocked microsoft key'

    $picked = @(
        (New-Leftover 'registry' 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip' 'exact' 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip' ''),
        (New-Leftover 'directory' 'C:\Program Files\7-Zip' 'InstallLocation from registry' '' '' 'C:\Program Files\7-Zip')
    )
    Set-LeftoverSelection $picked $true | Out-Null
    Assert-Engine ($picked[0].Selected -and -not $picked[1].Selected) 'ticks uninstall keys only'
    Set-LeftoverSelection $picked $false | Out-Null
    Assert-Engine (-not $picked[0].Selected -and -not $picked[1].Selected) 'failed uninstall ticks nothing'
    Assert-Engine (-not (New-Leftover 'file' 'x' 'y' '' '' 'x').Selected) 'new leftover unticked'
    $held = New-Object System.Collections.Generic.List[object]
    Set-LeftoverSelection $held $true | Out-Null
    $heldEntry = New-Leftover 'registry' 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Example' 'exact' 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Example' ''
    $heldFolder = New-Leftover 'directory' 'C:\Program Files\Example' 'folder' '' '' 'C:\Program Files\Example'
    [void]$held.Add($heldEntry)
    [void]$held.Add($heldFolder)
    Set-LeftoverSelection $held $true | Out-Null
    Assert-Engine ($heldEntry.Selected -and -not $heldFolder.Selected) 'object list selection'
    Assert-Engine ((ConvertTo-LeftoverJson $held).StartsWith('[')) 'object list json'

    $round = @(ConvertFrom-LeftoverJson (ConvertTo-LeftoverJson @($reg)))
    Assert-Engine ($round[0].Hive -eq 'HKLM' -and $round[0].RegSubkey -eq $reg.RegSubkey) 'json roundtrip'

    $sub = 'SOFTWARE\CleanInstallerSelfTest'
    $base = Open-RegistryHive 'HKCU'
    try { $base.CreateSubKey($sub).Close() } finally { $base.Close() }
    try {
        $probe = New-Leftover 'registry' "HKCU\$sub" 'test' 'HKCU' $sub ''
        $removed = @(Remove-Leftovers @($probe))
        Assert-Engine ($removed[0].StartsWith('OK')) ('cleanup ' + $removed[0])
        $check = Open-RegistryHive 'HKCU'
        try {
            $still = $check.OpenSubKey($sub)
            Assert-Engine ($null -eq $still) 'test key still present'
            if ($still) { $still.Close() }
        } finally { $check.Close() }
    } finally {
        $cleanup = Open-RegistryHive 'HKCU'
        try { $cleanup.DeleteSubKeyTree($sub, $false) } catch { } finally { $cleanup.Close() }
    }

    Assert-Engine ((Convert-Rot13 'Fgrnz') -eq 'Steam') 'rot13'
    $raw = [BitConverter]::GetBytes([int64]133000000000000000)
    $stamp = ConvertFrom-FileTime $raw
    Assert-Engine ($null -ne $stamp -and $stamp.Year -ge 2000) 'filetime'
    Assert-Engine ($null -eq (ConvertFrom-FileTime (New-Object byte[] 8))) 'zero filetime'

    $rules = Read-ProblemRules (Get-RulesPath)
    $iobit = [pscustomobject]@{ Name = 'Driver Booster'; Id = 'IObit.DriverBooster'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    Assert-Engine ((Get-KnownProblemReason $iobit $null $rules) -match 'PUP') 'iobit rule'
    $mcafee = [pscustomobject]@{ Name = 'McAfee LiveSafe'; Id = 'ARP\Machine\X64\McAfee'; Version = ''; Source = ''; Available = ''; Match = ''; Note = '' }
    $mcafeeArp = [pscustomobject]@{ DisplayName = 'McAfee LiveSafe'; Publisher = 'McAfee, LLC'; InstallLocation = ''; DisplayIcon = ''; UninstallString = ''; KeyName = 'McAfee'; InstallDate = $null; HelpLink = ''; UrlInfo = '' }
    Assert-Engine ((Get-KnownProblemReason $mcafee $mcafeeArp $rules) -match 'OEM') 'mcafee publisher'
    $candy = [pscustomobject]@{ Name = 'Candy Crush Saga'; Id = 'king.com.CandyCrushSaga'; Version = ''; Source = 'msstore'; Available = ''; Match = ''; Note = '' }
    Assert-Engine ((Get-KnownProblemReason $candy $null $rules) -match 'OEM store') 'candy name'
    $palworld = [pscustomobject]@{ Name = 'Palworld'; Id = 'ARP\Machine\X64\Steam App 1623730'; Version = ''; Source = ''; Available = ''; Match = ''; Note = '' }
    $palArp = [pscustomobject]@{ DisplayName = 'Palworld'; Publisher = ''; InstallLocation = 'D:\SteamLibrary\steamapps\common\Palworld'; DisplayIcon = ''; UninstallString = '"C:\Program Files (x86)\Steam\steam.exe" steam://uninstall/1623730'; KeyName = 'Steam App 1623730'; InstallDate = $null }
    Assert-Engine (Test-ProtectedPackage $palworld $palArp) 'steam protected'
    $vc = [pscustomobject]@{ Name = 'Microsoft Visual C++ 2015-2022 Redistributable (x64)'; Id = 'Microsoft.VCRedist.2015+.x64'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    Assert-Engine (Test-ProtectedPackage $vc $null) 'vcredist protected'

    $old = [pscustomobject]@{ Name = 'Old Trial Toolbar'; Id = 'Contoso.Toolbar'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    $oldArp = [pscustomobject]@{ DisplayName = 'Old Trial Toolbar'; Publisher = 'Contoso'; InstallLocation = ''; DisplayIcon = ''; UninstallString = ''; KeyName = 'Contoso.Toolbar'; InstallDate = [datetime]'2024-01-01' }
    $suspects = @(Get-Suspects @($old) @($oldArp) @() $rules 6 ([datetime]'2026-09-21'))
    Assert-Engine ($suspects.Count -eq 1) 'unused suspect'
    Assert-Engine ($suspects[0].Why -match 'no recorded launches') 'unused reason'
    $editor = [pscustomobject]@{ Name = 'Useful Editor'; Id = 'Contoso.UsefulEditor'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    $editorArp = [pscustomobject]@{ DisplayName = 'Useful Editor'; Publisher = 'Contoso'; InstallLocation = 'C:\Program Files\Useful Editor'; DisplayIcon = ''; UninstallString = ''; KeyName = 'Contoso.UsefulEditor'; InstallDate = [datetime]'2024-01-01' }
    $launches = @([pscustomobject]@{ Name = 'C:\Program Files\Useful Editor\editor.exe'; LastUsed = [datetime]'2026-09-01' })
    $recent = @(Get-Suspects @($editor) @($editorArp) $launches $rules 6 ([datetime]'2026-09-21'))
    Assert-Engine ($recent.Count -eq 0) 'recent launch is not unused'
    $ffmpeg = [pscustomobject]@{ Name = 'FFmpeg'; Id = 'Gyan.FFmpeg.Essentials'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    $ffmpegArp = [pscustomobject]@{ DisplayName = 'FFmpeg (Essentials Build)'; Publisher = 'Gyan'; InstallLocation = 'C:\ffmpeg'; DisplayIcon = ''; UninstallString = ''; KeyName = 'Gyan.FFmpeg.Essentials'; InstallDate = [datetime]'2024-01-01' }
    $ffmpegSuspects = @(Get-Suspects @($ffmpeg) @($ffmpegArp) @() $rules 6 ([datetime]'2026-09-21'))
    Assert-Engine ($ffmpegSuspects.Count -eq 0) 'ffmpeg is not an unused suspect'
    $ffmpegNote = Get-DependencyUninstallNote $ffmpeg $ffmpegArp
    Assert-Engine ($ffmpegNote -match 'known dependency' -and $ffmpegNote -match 'background' -and $ffmpegNote -match 'launch') 'ffmpeg uninstall note'
    $inventoryFfmpeg = [pscustomobject]@{ Name = 'FFmpeg'; Id = 'ARP\Machine\X64\FFmpeg'; Version = ''; Source = ''; Available = ''; Match = ''; Note = '' }
    Assert-Engine ((Get-DependencyTool $inventoryFfmpeg $null) -eq 'FFmpeg') 'inventory ffmpeg'
    $handBrake = [pscustomobject]@{ Name = 'HandBrake'; Id = 'HandBrake.HandBrake'; Version = ''; Source = 'winget'; Available = ''; Match = ''; Note = '' }
    Assert-Engine ($null -eq (Get-DependencyTool $handBrake $null)) 'handbrake gui is not the cli'
    Assert-Engine ((Get-DependencyTool ([pscustomobject]@{ Name = 'HandBrake CLI'; Id = 'ARP\Machine\X64\HandBrakeCLI' }) $null) -eq 'HandBrake CLI') 'handbrake cli'
    $denon = [pscustomobject]@{ Name = 'Denon AVR'; Id = 'ARP\Machine\X64\Denon'; Version = ''; Source = ''; Available = ''; Match = ''; Note = '' }
    Assert-Engine ($null -eq (Get-DependencyTool $denon $null)) 'denon is not deno'
    Assert-Engine ((Get-DependencyUninstallNote $editor $editorArp) -eq '') 'editor has no dependency note'

    $expanded = ConvertTo-CleanRegPath '"%SystemRoot%\System32"'
    Assert-Engine ($expanded.ToLowerInvariant().EndsWith('system32') -and $expanded -notmatch '%') 'expand install location'

    Write-Output 'SELFTEST OK'
}

if ($MyInvocation.InvocationName -ne '.') {
    $mode = ''
    $pathA = ''
    $pathB = ''
    for ($i = 0; $i -lt $args.Count; $i++) {
        $token = [string]$args[$i]
        if ($token -eq '-SelfTest') { $mode = 'self' }
        elseif ($token -eq '-CleanupLeftovers' -and ($i + 2) -lt $args.Count) {
            $mode = 'cleanup'
            $pathA = [string]$args[$i + 1]
            $pathB = [string]$args[$i + 2]
        } elseif ($token -eq '-RunCaptured' -and ($i + 1) -lt $args.Count) {
            $mode = 'captured'
            $pathA = [string]$args[$i + 1]
        }
    }
    if ($mode -eq 'self') {
        try { Invoke-EngineSelfTest; exit 0 } catch { Write-Output ("SELFTEST FAIL " + $_.Exception.Message); exit 1 }
    } elseif ($mode -eq 'cleanup') {
        try { Invoke-CleanupFile $pathA $pathB; exit 0 } catch { Write-Output ("CLEANUP FAIL " + $_.Exception.Message); exit 1 }
    } elseif ($mode -eq 'captured') {
        Invoke-RunCaptured $pathA
    }
}

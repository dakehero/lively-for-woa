[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Rid,

    [ValidateSet('Release', 'Msix')]
    [string] $Layout = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$payloadRoot = [IO.Path]::GetFullPath($Root)
$manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'release-projects.json') | ConvertFrom-Json
$projects = @($manifest.projects | Where-Object { $_.platformByRid.$Rid })

foreach ($entry in $manifest.projects) {
    [xml]$project = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $entry.project)
    $assemblyNameNode = $project.SelectSingleNode("//*[local-name()='AssemblyName']")
    $assemblyName = if ($null -ne $assemblyNameNode) { $assemblyNameNode.InnerText } else { [IO.Path]::GetFileNameWithoutExtension($entry.project) }
    $directory = if ($Layout -eq 'Msix' -and $entry.name -eq 'Lively.UI.WinUI') {
        $payloadRoot
    }
    elseif ($Layout -eq 'Msix') {
        Join-Path (Join-Path $payloadRoot 'Build') $entry.destination
    }
    else {
        Join-Path $payloadRoot $entry.destination
    }

    if ([string]::IsNullOrWhiteSpace([string]$entry.platformByRid.$Rid)) {
        if (Test-Path -LiteralPath $directory) {
            throw "Unsupported $Rid plugin directory: $directory"
        }
        continue
    }

    if (-not $entry.selfContained) {
        $frameworkNode = $project.SelectSingleNode("//*[local-name()='TargetFrameworkVersion']")
        if ($null -eq $frameworkNode -or $frameworkNode.InnerText -ne 'v4.8.1') {
            throw "$($entry.name) must target .NET Framework 4.8.1."
        }
        foreach ($name in @("$assemblyName.exe", "$assemblyName.exe.config")) {
            $file = Get-Item -LiteralPath (Join-Path $directory $name) -ErrorAction SilentlyContinue
            if ($null -eq $file -or $file.PSIsContainer -or $file.Length -eq 0) {
                throw "Missing .NET Framework application file: $(Join-Path $directory $name)"
            }
        }
        [xml]$config = Get-Content -Raw -LiteralPath (Join-Path $directory "$assemblyName.exe.config")
        if ($config.configuration.startup.supportedRuntime.sku -ne '.NETFramework,Version=v4.8.1') {
            throw "$assemblyName.exe.config does not require .NET Framework 4.8.1."
        }
        foreach ($name in @('coreclr.dll', "$assemblyName.runtimeconfig.json")) {
            if (Test-Path -LiteralPath (Join-Path $directory $name)) {
                throw "Stale modern .NET output in Framework helper: $(Join-Path $directory $name)"
            }
        }
        continue
    }

    $configPath = Join-Path $directory "$assemblyName.runtimeconfig.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Missing application runtime configuration: $configPath"
    }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json -AsHashtable
    $options = $config.runtimeOptions
    if ($options.ContainsKey('framework') -or $options.ContainsKey('frameworks')) {
        throw "$configPath depends on a globally installed .NET framework."
    }
    $frameworkNames = @($options.includedFrameworks | ForEach-Object { $_.name })
    if ('Microsoft.NETCore.App' -notin $frameworkNames) {
        throw "$configPath does not declare an included .NET runtime."
    }

    $requiredFiles = @("$assemblyName.exe", "$assemblyName.dll", "$assemblyName.deps.json",
        'hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'System.Private.CoreLib.dll')
    $desktopNode = $project.SelectSingleNode("//UseWPF[text()='true'] | //UseWindowsForms[text()='true']")
    if ($null -ne $desktopNode) {
        if ('Microsoft.WindowsDesktop.App' -notin $frameworkNames) {
            throw "$configPath does not include the required Windows Desktop runtime."
        }
        $requiredFiles += 'WindowsBase.dll'
        if ($null -ne $project.SelectSingleNode("//UseWPF[text()='true']")) { $requiredFiles += 'PresentationFramework.dll' }
        if ($null -ne $project.SelectSingleNode("//UseWindowsForms[text()='true']")) { $requiredFiles += 'System.Windows.Forms.dll' }
    }
    foreach ($name in $requiredFiles) {
        $file = Get-Item -LiteralPath (Join-Path $directory $name) -ErrorAction SilentlyContinue
        if ($null -eq $file -or $file.PSIsContainer -or $file.Length -eq 0) {
            throw "Missing or empty self-contained runtime file for $($entry.name): $(Join-Path $directory $name)"
        }
    }
}

Write-Output "PASS: all $($projects.Count) $Layout applications have the expected runtime layout."

$coreRoot = if ($Layout -eq 'Msix') { Join-Path $payloadRoot 'Build' } else { $payloadRoot }
$nativeFiles = @('plugins/mpv/mpv.exe', 'plugins/mpv/yt-dlp.exe',
    "plugins/libvlc/libvlc/$Rid/libvlc.dll", "plugins/libvlc/libvlc/$Rid/libvlccore.dll")
if ('Lively.Player.CefSharp' -in $projects.name) {
    $nativeFiles += @('plugins/cef/libcef.dll', 'plugins/cef/CefSharp.Core.Runtime.dll',
        'plugins/cef/CefSharp.BrowserSubprocess.exe')
}
foreach ($name in $nativeFiles) {
    $file = Get-Item -LiteralPath (Join-Path $coreRoot $name) -ErrorAction SilentlyContinue
    if ($null -eq $file -or $file.PSIsContainer -or $file.Length -eq 0) {
        throw "Missing native player binary: $name"
    }
}
if ($Layout -eq 'Msix' -and (Test-Path -LiteralPath (Join-Path $coreRoot 'plugins/UI'))) {
    throw 'MSIX contains a duplicate UI plugin.'
}
$wallpaperRoot = Join-Path $coreRoot 'Bundle/wallpapers'
if (-not (Test-Path -LiteralPath (Join-Path $wallpaperRoot '0.zip'))) {
    throw 'The payload has no default wallpaper bundle.'
}
$wallpapers = 0
$bundles = @(Get-ChildItem -LiteralPath $wallpaperRoot -Filter '*.zip' -File)
for ($index = 0; $index -lt $bundles.Count; $index++) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $wallpaperRoot "$index.zip"))
    try {
        $wallpapers += @($archive.Entries | Where-Object { $_.Name -eq 'LivelyInfo.json' }).Count
    } finally { $archive.Dispose() }
}
if ($wallpapers -eq 0) { throw 'Default wallpaper bundles contain no wallpaper records.' }

$expectedMachine = if ($Rid -eq 'win-arm64') { 0xaa64 } else { 0x8664 }
$crtPaths = if ($Layout -eq 'Msix') {
    @('Build/vcruntime140_cor3.dll', 'Build/plugins/wmf/vcruntime140_cor3.dll')
} else { @('vcruntime140_cor3.dll', 'plugins/wmf/vcruntime140_cor3.dll') }
$sdkCompanion = if ($Layout -eq 'Msix') { 'Microsoft.Windows.Workloads.Resources_ec.dll' }
    else { 'plugins/UI/Microsoft.Windows.Workloads.Resources_ec.dll' }

foreach ($item in Get-ChildItem -LiteralPath $payloadRoot -Recurse -Force) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Payload contains a reparse point: $($item.FullName)"
    }
    if ($item.PSIsContainer) { continue }
    if ($item.Name -match '^grpc_csharp_ext' -or $item.Name -eq 'Grpc.Core.dll') {
        throw "Payload contains the unused native gRPC runtime: $($item.FullName)"
    }
    if ($item.Extension -notin @('.exe', '.dll')) { continue }
    $relative = [IO.Path]::GetRelativePath($payloadRoot, $item.FullName).Replace('\', '/')
    $stream = [IO.File]::OpenRead($item.FullName)
    $reader = $null
    try {
        $reader = [Reflection.PortableExecutable.PEReader]::new($stream)
        $headers = $reader.PEHeaders
        $machine = [int]$headers.CoffHeader.Machine
        $pe = $headers.PEHeader
        if ($null -eq $pe) { throw "Not a Windows executable image: $relative" }
        $cor = $headers.CorHeader
        if ($machine -eq 0x14c -and $reader.HasMetadata -and $null -ne $cor -and
            ([int]$cor.Flags -band 1) -ne 0 -and ([int]$cor.Flags -band 2) -eq 0) {
            continue # Managed AnyCPU, not a native x86 image.
        }
        $hybrid = $machine -eq 0xa64e -or ($machine -eq 0xaa64 -and
            @($headers.SectionHeaders | Where-Object Name -eq '.a64xrm').Count -gt 0)
        if ($hybrid) {
            # Exact Microsoft runtime companions; do not allow arbitrary ARM64X files.
            if (($Rid -eq 'win-arm64' -and $relative -cin $crtPaths) -or
                ($Rid -eq 'win-x64' -and $relative -ceq $sdkCompanion)) { continue }
            throw "Unexpected hybrid executable: $relative"
        }
        $hasCode = @($headers.SectionHeaders | Where-Object {
            [long]$_.SectionCharacteristics -band 0x20000020
        }).Count -gt 0
        if ($pe.AddressOfEntryPoint -eq 0 -and $pe.SizeOfCode -eq 0 -and
            $pe.ImportTableDirectory.Size -eq 0 -and $pe.ExportTableDirectory.Size -eq 0 -and
            -not $hasCode) { continue }
        if ($machine -ne $expectedMachine) {
            throw ("Wrong architecture for {0}: {1} (0x{2:x4})" -f $Rid, $relative, $machine)
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stream.Dispose()
    }
}
Write-Output "PASS: $Rid payload architectures and default wallpaper bundles."

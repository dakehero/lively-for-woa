[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Rid,

    [ValidateSet('Release')]
    [string] $Configuration = 'Release',

    [string] $BundleRoot = (Join-Path $PSScriptRoot '../src/Lively/Lively/Bundle'),

    [string] $NativePluginsRoot,

    [string] $MSBuildPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts'))
$intermediateParent = [IO.Path]::GetFullPath((Join-Path $artifactsRoot 'intermediate'))
$releaseParent = [IO.Path]::GetFullPath((Join-Path $artifactsRoot 'release'))
$intermediateRoot = [IO.Path]::GetFullPath((Join-Path $intermediateParent $Rid))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $releaseParent $Rid))
$manifestPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'release-projects.json'))
$nativeMediaScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Stage-NativeMedia.ps1'))

function Reset-OwnedDirectory {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $ExpectedParent,

        [Parameter(Mandatory)]
        [string] $ExpectedLeaf
    )

    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $canonicalParent = [IO.Path]::GetFullPath($ExpectedParent)
    if ([IO.Path]::GetDirectoryName($canonicalPath) -ne $canonicalParent -or
        [IO.Path]::GetFileName($canonicalPath) -ne $ExpectedLeaf) {
        throw "Refusing to reset unexpected directory: $canonicalPath"
    }

    if (Test-Path -LiteralPath $canonicalPath) {
        Remove-Item -LiteralPath $canonicalPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $canonicalPath -Force | Out-Null
}

function Resolve-RepositoryFile {
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "Manifest project path must be relative: $RelativePath"
    }

    $canonicalPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $RelativePath))
    $repoPrefix = $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $canonicalPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest project escapes repository root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
        throw "Manifest project does not exist: $canonicalPath"
    }
    return $canonicalPath
}

function Resolve-StageDestination {
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "Manifest destination must be relative: $RelativePath"
    }

    $canonicalPath = [IO.Path]::GetFullPath((Join-Path $releaseRoot $RelativePath))
    $releasePrefix = $releaseRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($canonicalPath -ne $releaseRoot -and
        -not $canonicalPath.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest destination escapes release root: $RelativePath"
    }
    return $canonicalPath
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Release manifest is missing: $manifestPath"
}
if (-not (Test-Path -LiteralPath $nativeMediaScript -PathType Leaf)) {
    throw "Native media staging script is missing: $nativeMediaScript"
}

$BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
if (-not (Test-Path -LiteralPath (Join-Path $BundleRoot 'wallpapers/0.zip') -PathType Leaf)) {
    throw 'Default wallpapers are missing. Set BundleRoot to the original Bundle directory.'
}
if ($NativePluginsRoot -and -not (Test-Path -LiteralPath $NativePluginsRoot -PathType Container)) {
    throw "Native plugin directory does not exist: $NativePluginsRoot"
}
foreach ($source in @($BundleRoot, $NativePluginsRoot) | Where-Object { $_ }) {
    $sourcePath = [IO.Path]::GetFullPath($source)
    foreach ($output in @($releaseRoot, $intermediateRoot)) {
        if ($sourcePath -eq $output -or $sourcePath.StartsWith($output + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Input directory would be removed by this build: $sourcePath"
        }
    }
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.projects.Count -eq 0) {
    throw "Unsupported or empty release manifest: $manifestPath"
}
foreach ($entry in $manifest.projects) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.platformByRid.$Rid)) {
        Write-Warning "$($entry.name) is not included for $Rid. See build/README.md."
    }
}
$projects = @($manifest.projects | Where-Object { $_.platformByRid.$Rid })

if (-not $MSBuildPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $MSBuildPath = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    }
}
if (-not $MSBuildPath -or -not (Test-Path -LiteralPath $MSBuildPath -PathType Leaf)) {
    throw 'Visual Studio MSBuild is required for the .NET Framework helpers. Set MSBuildPath if detection fails.'
}

New-Item -ItemType Directory -Path $intermediateParent -Force | Out-Null
New-Item -ItemType Directory -Path $releaseParent -Force | Out-Null
Reset-OwnedDirectory -Path $intermediateRoot -ExpectedParent $intermediateParent -ExpectedLeaf $Rid
Reset-OwnedDirectory -Path $releaseRoot -ExpectedParent $releaseParent -ExpectedLeaf $Rid

foreach ($entry in $projects) {
    $projectPath = Resolve-RepositoryFile -RelativePath ([string]$entry.project)
    $destination = Resolve-StageDestination -RelativePath ([string]$entry.destination)
    $platform = [string]$entry.platformByRid.$Rid

    $publishRoot = [IO.Path]::GetFullPath((Join-Path $intermediateRoot ([string]$entry.name)))
    Reset-OwnedDirectory -Path $publishRoot -ExpectedParent $intermediateRoot -ExpectedLeaf ([string]$entry.name)

    Write-Output "Building $($entry.name) for $Rid ($platform)..."
    if ($entry.selfContained) {
        & dotnet publish $projectPath `
            -c $Configuration `
            -r $Rid `
            --self-contained true `
            -p:Platform=$platform `
            -p:LivelyManagedPublish=true `
            -o $publishRoot
    }
    else {
        & $MSBuildPath $projectPath /restore /t:Build `
            /p:Configuration=$Configuration /p:Platform=$platform `
            "/p:OutDir=$publishRoot/" /verbosity:minimal /nologo
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for '$($entry.name)' with exit code $LASTEXITCODE."
    }

    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Get-ChildItem -LiteralPath $publishRoot -Force | Copy-Item -Destination $destination -Recurse -Force
}

Copy-Item -LiteralPath $BundleRoot -Destination (Join-Path $releaseRoot 'Bundle') -Recurse
if ($NativePluginsRoot) {
    Get-ChildItem -LiteralPath $NativePluginsRoot -Force |
        Copy-Item -Destination (Join-Path $releaseRoot 'plugins') -Recurse -Force
}

& pwsh -NoProfile -File $nativeMediaScript `
    -Rid $Rid `
    -ReleaseRoot $releaseRoot `
    -IntermediateRoot (Join-Path $intermediateRoot 'NativeMedia')
if ($LASTEXITCODE -ne 0) {
    throw "Native media staging failed for $Rid with exit code $LASTEXITCODE."
}

& (Join-Path $PSScriptRoot 'Test-Deployment.ps1') -Root $releaseRoot -Rid $Rid

Write-Output "Release: $releaseRoot"

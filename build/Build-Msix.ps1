[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]] $Rid = @('win-x64', 'win-arm64'),
    [string] $BundleRoot = (Join-Path $PSScriptRoot '../src/Lively/Lively/Bundle'),
    [switch] $SkipReleaseBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactsRoot = Join-Path $repoRoot 'artifacts'
$msixRoot = Join-Path $artifactsRoot 'msix'
$packagesRoot = Join-Path $msixRoot 'packages'
$project = Join-Path $repoRoot 'src/Lively/Lively.UI.WinUI/Lively.UI.WinUI.csproj'
$sdkRoot = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Windows Kits/10/bin'
$sdkArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$makeAppx = Get-ChildItem -LiteralPath $sdkRoot -Directory |
    Where-Object Name -Match '^\d+\.\d+\.\d+\.\d+$' |
    Sort-Object { [Version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "$sdkArchitecture/makeappx.exe" } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $makeAppx) { throw "Windows SDK makeappx.exe for $sdkArchitecture was not found." }

if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($msixRoot)) -ne $artifactsRoot -or
    [IO.Path]::GetFileName($msixRoot) -ne 'msix') { throw 'Unexpected MSIX output directory.' }
if (Test-Path -LiteralPath $msixRoot) { Remove-Item -LiteralPath $msixRoot -Recurse -Force }
New-Item -ItemType Directory -Path $packagesRoot -Force | Out-Null
$identity = $null
$targets = @($Rid | Select-Object -Unique)

foreach ($target in $targets) {
    $platform = $target.Substring(4)
    $releaseRoot = Join-Path $artifactsRoot "release/$target"
    if (-not $SkipReleaseBuild) {
        & (Join-Path $PSScriptRoot 'Build-Release.ps1') -Rid $target -BundleRoot $BundleRoot
    }
    & (Join-Path $PSScriptRoot 'Test-Deployment.ps1') -Root $releaseRoot -Rid $target

    $packageBuildRoot = Join-Path $msixRoot "intermediate/$target"
    New-Item -ItemType Directory -Path $packageBuildRoot -Force | Out-Null
    & dotnet publish $project -c Release -r $target --self-contained true `
        -p:Platform=$platform -p:IsMsixRelease=true -p:LivelyReleaseRoot=$releaseRoot `
        -p:PublishProfile="win-$platform.pubxml" -p:AppxPackageDir="$packageBuildRoot/" `
        -p:AppxPackageSigningEnabled=false -p:GenerateTemporaryStoreCertificate=false `
        -p:AppxAutoIncrementPackageRevision=false
    if ($LASTEXITCODE -ne 0) { throw "MSIX publish failed for $target." }

    $packages = @(Get-ChildItem -LiteralPath $packageBuildRoot -Recurse -File -Filter '*.msix' |
        Where-Object { $_.FullName -notmatch '[\\/]Dependencies[\\/]' })
    if ($packages.Count -ne 1) { throw "Expected one $target application package, found $($packages.Count)." }
    $packagePath = Join-Path $packagesRoot "Lively-$target.msix"
    Copy-Item -LiteralPath $packages[0].FullName -Destination $packagePath
    $unpacked = Join-Path $msixRoot "unpacked/$target"
    & $makeAppx unpack /p $packagePath /d $unpacked /o
    if ($LASTEXITCODE -ne 0) { throw "Cannot unpack $target MSIX." }
    & (Join-Path $PSScriptRoot 'Test-Deployment.ps1') -Root $unpacked -Rid $target -Layout Msix

    [xml]$manifest = Get-Content -Raw -LiteralPath (Join-Path $unpacked 'AppxManifest.xml')
    $packageIdentity = $manifest.Package.Identity
    if ($packageIdentity.ProcessorArchitecture -ne $platform) { throw 'Incorrect MSIX architecture.' }
    $currentIdentity = "$($packageIdentity.Name)|$($packageIdentity.Publisher)|$($packageIdentity.Version)"
    if ($identity -and $identity -cne $currentIdentity) { throw 'MSIX identities differ between architectures.' }
    $identity = $currentIdentity
    if (-not $manifest.SelectSingleNode("//*[local-name()='Capability' and @Name='runFullTrust']") -or
        $manifest.SelectSingleNode("//*[local-name()='Capability' and @Name='allowElevation']")) {
        throw 'Unexpected MSIX capabilities.'
    }
    Write-Output "Unsigned MSIX: $packagePath"
}

if ($targets.Count -gt 1) {
    $bundle = Join-Path $msixRoot 'Lively-x64-arm64.msixbundle'
    & $makeAppx bundle /d $packagesRoot /p $bundle /o
    if ($LASTEXITCODE -ne 0) { throw 'MSIX bundle creation failed.' }
    Write-Output "Unsigned bundle: $bundle"
}

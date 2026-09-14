[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $ReleaseRoot,

    [Parameter(Mandatory)]
    [string] $IntermediateRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts'))
$cacheRoot = [IO.Path]::GetFullPath((Join-Path $artifactsRoot 'native-media-cache'))
$lockPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'native-media-lock.json'))
$releaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
$intermediateRoot = [IO.Path]::GetFullPath($IntermediateRoot)
$destinationRoot = [IO.Path]::GetFullPath((Join-Path $releaseRoot 'plugins\mpv'))

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Description
    )

    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $canonicalParent = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $prefix = $canonicalParent + [IO.Path]::DirectorySeparatorChar
    if (-not $canonicalPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escapes its owned parent: $canonicalPath"
    }
}

function Reset-OwnedDirectory {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Parent
    )

    Assert-ChildPath -Path $Path -Parent $Parent -Description 'Owned directory'
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Sha256,
        [Parameter(Mandatory)][string] $FileName
    )

    if ($Sha256 -notmatch '^[0-9a-f]{64}$' -or [IO.Path]::GetFileName($FileName) -ne $FileName) {
        throw "Invalid locked download metadata for $FileName."
    }
    $hashRoot = [IO.Path]::GetFullPath((Join-Path $cacheRoot $Sha256))
    Assert-ChildPath -Path $hashRoot -Parent $cacheRoot -Description 'Native media cache entry'
    New-Item -ItemType Directory -Path $hashRoot -Force | Out-Null
    $cachedPath = [IO.Path]::GetFullPath((Join-Path $hashRoot $FileName))
    Assert-ChildPath -Path $cachedPath -Parent $hashRoot -Description 'Native media cache file'

    if (Test-Path -LiteralPath $cachedPath -PathType Leaf) {
        if ((Get-Sha256 $cachedPath) -ceq $Sha256) {
            return $cachedPath
        }
        Remove-Item -LiteralPath $cachedPath -Force
    }

    $temporaryPath = "$cachedPath.$([Guid]::NewGuid().ToString('N')).download"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                if (Test-Path -LiteralPath $temporaryPath) {
                    Remove-Item -LiteralPath $temporaryPath -Force
                }
                Write-Host "Downloading $FileName (attempt $attempt/3)..."
                Invoke-WebRequest -Uri $Url -OutFile $temporaryPath
                $actualHash = Get-Sha256 $temporaryPath
                if ($actualHash -cne $Sha256) {
                    throw "SHA-256 mismatch for $FileName. Expected $Sha256, actual $actualHash."
                }
                Move-Item -LiteralPath $temporaryPath -Destination $cachedPath
                break
            }
            catch {
                if (Test-Path -LiteralPath $temporaryPath) {
                    Remove-Item -LiteralPath $temporaryPath -Force
                }
                if ($attempt -eq 3) {
                    throw
                }
                Write-Warning "Download failed for ${FileName}: $($_.Exception.Message). Retrying."
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    return $cachedPath
}

function Copy-VerifiedPayloadFile {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $RelativeDestination,
        [Parameter(Mandatory)][string] $Origin,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $ManifestFiles
    )

    $destination = [IO.Path]::GetFullPath((Join-Path $destinationRoot $RelativeDestination))
    Assert-ChildPath -Path $destination -Parent $destinationRoot -Description 'Native media staged file'
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
    $sourceHash = Get-Sha256 $Source
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $existingHash = Get-Sha256 $destination
        if ($existingHash -cne $sourceHash) {
            throw "Conflicting native media files target '$RelativeDestination' from '$Origin'."
        }
        return
    }

    Copy-Item -LiteralPath $Source -Destination $destination
    $ManifestFiles.Add([ordered]@{
        path = ($RelativeDestination -replace '\\', '/')
        sha256 = $sourceHash
        origin = $Origin
    })
}

Assert-ChildPath -Path $releaseRoot -Parent $artifactsRoot -Description 'Release root'
Assert-ChildPath -Path $intermediateRoot -Parent $artifactsRoot -Description 'Native media intermediate root'
if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
    throw "Release root does not exist: $releaseRoot"
}
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Native media lock does not exist: $lockPath"
}

$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
if ($lock.schemaVersion -ne 1) {
    throw "Unsupported native media lock schema: $($lock.schemaVersion)"
}
$entry = @($lock.msys2.entries | Where-Object rid -eq $Rid)
$ytDlp = @($lock.ytDlp.assets | Where-Object rid -eq $Rid)
if ($entry.Count -ne 1 -or $ytDlp.Count -ne 1) {
    throw "Native media lock must contain exactly one MSYS2 and yt-dlp entry for $Rid."
}

New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
Reset-OwnedDirectory -Path $intermediateRoot -Parent $artifactsRoot
Reset-OwnedDirectory -Path $destinationRoot -Parent $releaseRoot
$packagesRoot = Join-Path $intermediateRoot 'packages'
New-Item -ItemType Directory -Path $packagesRoot -Force | Out-Null
$manifestFiles = [Collections.Generic.List[object]]::new()

foreach ($package in $entry[0].packages) {
    $archive = Get-VerifiedDownload -Url ([string]$package.url) -Sha256 ([string]$package.sha256) -FileName ([string]$package.fileName)
    $packageRoot = [IO.Path]::GetFullPath((Join-Path $packagesRoot ([string]$package.name)))
    Reset-OwnedDirectory -Path $packageRoot -Parent $packagesRoot
    & tar.exe -xf $archive -C $packageRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract native media package '$($package.name)'."
    }

    $binRoot = Join-Path $packageRoot "$($entry[0].prefix)\bin"
    if (Test-Path -LiteralPath $binRoot -PathType Container) {
        foreach ($dll in Get-ChildItem -LiteralPath $binRoot -Filter '*.dll' -File) {
            Copy-VerifiedPayloadFile -Source $dll.FullName -RelativeDestination $dll.Name -Origin "msys2:$($package.name)" -ManifestFiles $manifestFiles
        }
    }

    if ($package.name -eq $entry[0].rootPackage) {
        $mpvPath = Join-Path $binRoot 'mpv.exe'
        if (-not (Test-Path -LiteralPath $mpvPath -PathType Leaf)) {
            throw "Root package '$($package.name)' does not contain mpv.exe."
        }
        Copy-VerifiedPayloadFile -Source $mpvPath -RelativeDestination 'mpv.exe' -Origin "msys2:$($package.name)" -ManifestFiles $manifestFiles
    }

    $runtimeDataRoot = Join-Path $packageRoot "$($entry[0].prefix)\share\mpv"
    if (Test-Path -LiteralPath $runtimeDataRoot -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $runtimeDataRoot -File -Recurse) {
            $relative = [IO.Path]::GetRelativePath($runtimeDataRoot, $file.FullName)
            Copy-VerifiedPayloadFile -Source $file.FullName -RelativeDestination (Join-Path 'share\mpv' $relative) -Origin "msys2:$($package.name)" -ManifestFiles $manifestFiles
        }
    }

    $licenseRoot = Join-Path $packageRoot "$($entry[0].prefix)\share\licenses"
    if (Test-Path -LiteralPath $licenseRoot -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $licenseRoot -File -Recurse) {
            $relative = [IO.Path]::GetRelativePath($licenseRoot, $file.FullName)
            Copy-VerifiedPayloadFile -Source $file.FullName -RelativeDestination (Join-Path 'licenses\msys2' $relative) -Origin "msys2:$($package.name)" -ManifestFiles $manifestFiles
        }
    }

    $packageInfo = Join-Path $packageRoot '.PKGINFO'
    if (-not (Test-Path -LiteralPath $packageInfo -PathType Leaf)) {
        throw "Package '$($package.name)' does not contain .PKGINFO."
    }
    Copy-VerifiedPayloadFile -Source $packageInfo -RelativeDestination "licenses\packages\$($package.name).PKGINFO" -Origin "msys2:$($package.name)" -ManifestFiles $manifestFiles
}

$ytDlpPath = Get-VerifiedDownload -Url ([string]$ytDlp[0].url) -Sha256 ([string]$ytDlp[0].sha256) -FileName ([string]$ytDlp[0].sourceFileName)
Copy-VerifiedPayloadFile -Source $ytDlpPath -RelativeDestination ([string]$ytDlp[0].stagedFileName) -Origin "yt-dlp:$($lock.ytDlp.version):$($ytDlp[0].sourceFileName)" -ManifestFiles $manifestFiles
Copy-VerifiedPayloadFile -Source $lockPath -RelativeDestination 'licenses\native-media-lock.json' -Origin 'lively:native-media-lock' -ManifestFiles $manifestFiles

$manifestPath = Join-Path $destinationRoot 'native-media-manifest.json'
$manifest = [ordered]@{
    schemaVersion = 1
    rid = $Rid
    mpvVersion = $lock.msys2.version
    ytDlpVersion = $lock.ytDlp.version
    lockSha256 = Get-Sha256 $lockPath
    files = @($manifestFiles | Sort-Object { $_.path })
}
$manifestJson = ($manifest | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"
[IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))

Write-Output "PASS: staged $($manifest.files.Count) verified native media files for $Rid."

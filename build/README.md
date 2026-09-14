# Building x64 and ARM64

Use PowerShell 7, a .NET 9-compatible SDK, Visual Studio MSBuild, the .NET
Framework 4.8.1 targeting pack, and the Windows SDK/WinUI build tools.

ARM64 builds use WebView2 and omit CEF. The CEF backend remains available on
x64; its source, settings and IPC are retained. `CefSharp.WinForms` 151.3.240
does not include the Framework ARM64 support merged in
[CefSharp #5267](https://github.com/cefsharp/CefSharp/pull/5267).
Enable the ARM64 entry only after updating and validating the official package.
No custom CefSharp build is required for this fork.

The default wallpapers are not stored in Git. Supply the original `Bundle`
directory containing `wallpapers/0.zip` and its subsequent numbered bundles.
The build fails if these files are missing.

```powershell
./build/Build-Release.ps1 -Rid win-arm64 -BundleRoot C:/LivelyAssets/Bundle
./build/Build-Release.ps1 -Rid win-x64 -BundleRoot C:/LivelyAssets/Bundle
```

Output is written to `artifacts/release/<RID>`. The script publishes the core
and WinUI with their .NET runtimes, builds the supported helpers with Visual Studio
MSBuild, then stages MPV, yt-dlp and the default wallpapers. The helpers require
the system .NET Framework 4.8.1 runtime; they are not self-contained. It replaces
only its own output directories for the selected RID. `-MSBuildPath` can override
MSBuild detection.

CefSharp (x64 only) and LibVLC use official native packages.
Their settings and IPC contracts are unchanged. LibVLC's native package also
requires an explicit MSBuild `Platform`; the release manifest supplies it.
The separate legacy `vlc.exe` backend is not bundled. Additional matching-architecture
plugin folders can be supplied with `-NativePluginsRoot`.

## MSIX

```powershell
# Package both previously built release directories.
./build/Build-Msix.ps1 -SkipReleaseBuild

# Or build and package one architecture.
./build/Build-Msix.ps1 -Rid win-arm64 -BundleRoot C:/LivelyAssets/Bundle
```

Packages are written to `artifacts/msix/packages`. Building both architectures
also produces `artifacts/msix/Lively-x64-arm64.msixbundle`. A single MSIX contains
one architecture; the bundle holds both.

These are unsigned development artifacts. The scripts do not install packages,
change certificate trust, or submit to the Store. Package identity is unchanged
from upstream; building successfully is not release certification.

The existing manual `Lively.UI.WinUI/Build` packaging layout still works when
`LivelyReleaseRoot` is not supplied.

## Native dependencies and checks

`native-media-lock.json` records the MPV dependency closure and yt-dlp binaries
for each RID, including source URLs, versions, SHA-256 hashes and license data.
`Stage-NativeMedia.ps1` verifies downloads and includes the packaged licenses.
When updating a native component, update its dependent packages and hashes
together, then test playback on the target architecture.

`Test-Deployment.ps1` checks the actual payload: core/UI self-contained runtimes,
Framework helper executables and runtime configurations, PE
architectures, default wallpaper records, and absence of the legacy native
gRPC runtime. Release and MSIX builds run it automatically. It does not prove
wallpaper rendering, upgrades, all backend features, or Store acceptance.

NuGet audit warnings remain enabled. Existing dependency advisories must be
reviewed separately before publishing a release.

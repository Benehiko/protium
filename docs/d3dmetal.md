# D3DMetal: what Apple actually ships

Verified against **Game Porting Toolkit 4.0 beta 2**, downloaded 2026-09-05.

## The download contains no Wine

Apple's toolkit DMG holds the shader converter, samples and `metal-cpp`. The
part that matters is a *nested* DMG, `Evaluation environment for Windows games
4.0 beta 2.dmg`, and its entire payload is:

```
redist/lib/external/D3DMetal.framework          67 MB
redist/lib/external/libd3dshared.dylib         240 KB
redist/lib/wine/x86_64-windows/   d3d10.dll d3d11.dll d3d12.dll dxgi.dll
                                  nvapi64.dll nvngx-on-metalfx.dll
redist/lib/wine/x86_64-unix/      the same names as .so, every one a symlink
                                  to ../../external/libd3dshared.dylib
```

That is the graphics bridge and nothing else: PE shims that a Wine prefix loads
as `d3d12.dll`, each paired with a unix-side module that is really one shared
library. **The layout must be preserved verbatim** when installing it, because
those symlinks are relative — `lib/wine/x86_64-unix/d3d12.so` resolves
`../../external/libd3dshared.dylib` against its own directory.

The `PackageContent` directory is empty in 4.0b2, despite the Read Me claiming
Wine build scripts are included, and `github.com/apple/game-porting-toolkit`
holds porting skills and samples rather than a Wine.

## Apple names the Wine halves it expects

Apple's own Read Me points at exactly two pre-built environments: Dean Greer's
(Gcenx) Homebrew casks, and CodeWeavers' CrossOver. Neither is a Wine *you*
control, which is why protium builds its own.

## D3DMetal is x86-64 only, and that decides the architecture

```
$ lipo -archs redist/lib/external/libd3dshared.dylib
x86_64
$ lipo -archs redist/lib/external/D3DMetal.framework/Versions/A/D3DMetal
x86_64
```

An arm64 process cannot load an x86-64 dylib, so the Wine that hosts D3DMetal
must itself be x86-64 and run under Rosetta 2. This is not a protium choice and
not a performance decision — it is forced. CrossOver reaches the same
conclusion: its shipped tree is `lib/wine/{x86_64-unix, x86_64-windows,
i386-windows}` with no arm64 at all.

## Versions are not interchangeable

The shim set changes between releases, so "D3DMetal" alone is never a
sufficient description of an environment:

| | CrossOver 26.3 (D3DMetal 3.0) | GPTK 4.0b2 |
| --- | --- | --- |
| `d3d12.dll` | ~108 KB | 192 KB |
| `d3d10.dll` | absent | present |
| `atidxx64.dll` | present | absent |
| nvngx | `nvngx.dll` | `nvngx-on-metalfx.dll` |

Anything that hooks or inspects the D3D12 shim — an overlay, a frame capture,
a mod runtime — is pinned to a version whether it knows it or not. Record which
one an observation was made against.

Apple documents an in-place swap, which doubles as a revert:

```
cd <wine>/lib
mv external external.old; mv wine wine.old
ditto "/Volumes/Evaluation environment for Windows games 4.0 beta 2/redist/lib/" .
```

## Environment variables

From Apple's Read Me, with the version each applies to:

| Variable | Effect |
| --- | --- |
| `D3DM_SUPPORT_DXR` | DirectX Raytracing; defaults on for M3 and later |
| `D3DM_ENABLE_METALFX` | converts DLSS calls to MetalFX where possible (macOS 26) |
| `D3DM_MTL4` | Metal 4 backend; default-on only from macOS 27, so macOS 26 uses Metal 3 |
| `D3DM_MAX_FPS` | frame-rate cap |
| `ROSETTA_ADVERTISE_AVX` | advertises AVX in cpuid to translated processes |

## Logging

D3DMetal logs to the unified system log under category `D3DMetal`, messages
prefixed `D3DM`:

```
log stream --predicate 'category == "D3DMetal"'
```

This is a first-party diagnostic channel, and it is the right first stop when
rendering or presentation misbehaves — earlier than guessing from a black
window.

## Licence

The redistributable is Apple's, under the licence in the DMG. protium installs
a copy you obtained yourself and never ships one.

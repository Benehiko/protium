# Why not Proton, and why not plain Wine

The short version: Proton cannot run on macOS, and Wine on macOS cannot render
Direct3D 12 without a proprietary Apple library. Everything protium does
follows from those two facts.

## Proton is Linux-only, and the escape hatches are closed

Proton is an ELF Wine driving DXVK and VKD3D-Proton over Vulkan. Apple ships
none of that. There is no macOS build and one cannot be produced by porting,
because the graphics stack it depends on is the part that does not exist.

Two ways around it are usually suggested. Both fail on current hardware:

* **Asahi Linux on bare metal** would give real Proton with a real Vulkan
  driver, but it does not support M3/M4-family Macs.
* **A Linux VM** fails earlier than graphics: Rosetta inside a Linux VM
  translates x86-64 only, and the Steam client is still 32-bit, so it never
  starts.

## Plain open-source Wine renders nothing

The blocker is Direct3D 12, and no open-source component translates it to
Metal:

| Component | Ceiling | Why it does not help |
| --- | --- | --- |
| WineD3D | Direct3D 11 | targets OpenGL, which macOS froze at 4.1 |
| VKD3D-Proton | Direct3D 12 | needs Vulkan features MoltenVK does not expose |
| DXMT | Direct3D 11 | wrong API generation |
| Wine's own libvkd3d | Direct3D 12 | far below VKD3D-Proton, and still needs Vulkan |

So a stock `wine-stable` will launch a D3D12 game's executable and show you
nothing. The missing piece is not Wine.

## What is actually missing is D3DMetal

D3DMetal is Apple's Direct3D-to-Metal translation layer, shipped in the Game
Porting Toolkit. It is proprietary, it is free to download, and it is the only
implementation of its kind. Commercial products that run Windows games on
macOS are all Wine plus D3DMetal; the money buys packaging and support, not a
different graphics stack.

That is the whole insight protium is built on. The expensive-sounding part —
the graphics translation — is the free part. The part everyone assumes is free
— Wine — is the part you have to build, and it turns out to be entirely
buildable from published sources. See [`wine-build.md`](wine-build.md).

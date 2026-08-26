# MT7612U / MT76x2U modules for NVIDIA L4T 36.4.3

Unofficial prebuilt ARM64 Linux kernel modules for MediaTek MT7612U USB Wi-Fi
adapters on NVIDIA Jetson Linux (L4T) 36.4.3.

These modules were built because the stock NVIDIA `5.15.148-tegra` kernel
configuration does not enable the in-tree MT76 driver. No driver source was
modified; the existing NVIDIA kernel source was built with the MT76 options
enabled as modules.

## Compatibility

These binaries are tied to the exact kernel ABI used to build them:

| Component | Required value |
| --- | --- |
| Architecture | `aarch64` |
| Kernel | `5.15.148-tegra` |
| `nvidia-l4t-core` | `36.4.3-20250107174145` |
| `nvidia-l4t-kernel` | `5.15.148-tegra-36.4.3-20250107174145` |
| `nvidia-l4t-kernel-headers` | `5.15.148-tegra-36.4.3-20250107174145` |
| Tested adapter | MediaTek `0e8d:7612` MT7612U |

Do not install these modules merely because another system reports kernel
`5.15.148`. NVIDIA enables `CONFIG_MODVERSIONS`, so symbol versions and the
complete kernel configuration must match. Rebuild the modules after any L4T or
kernel upgrade.

Check the target before installing:

```bash
cat /etc/nv_tegra_release
uname -m
uname -r
dpkg-query -W -f='${Package} ${Version}\n' \
  nvidia-l4t-core nvidia-l4t-kernel nvidia-l4t-kernel-headers
```

`lsb_release -a` identifies only the Ubuntu userspace. L4T is identified by
`/etc/nv_tegra_release` and the `nvidia-l4t-*` packages. The optional
`nvidia-jetpack` meta-package may be absent from vendor-customized images.

## Included modules

All six files are required and are under
`modules/5.15.148-tegra/aarch64/`:

- `mt76.ko`
- `mt76-usb.ko`
- `mt76x02-lib.ko`
- `mt76x02-usb.ko`
- `mt76x2-common.ko`
- `mt76x2u.ko`

Verify the download before installation:

```bash
sha256sum -c SHA256SUMS
```

## Firmware prerequisite

The kernel modules do not contain device firmware. Confirm these files already
exist on the Jetson:

```bash
ls -l /lib/firmware/mt7662.bin \
      /lib/firmware/mt7662_rom_patch.bin
```

They are normally supplied by the distribution's `linux-firmware` package. Do
not proceed until both files are available.

## Install

Run these commands on the Jetson, not on an x86 development machine:

```bash
KERNEL="$(uname -r)"
test "$KERNEL" = "5.15.148-tegra"

sudo install -d "/lib/modules/$KERNEL/updates/mt76"
sudo install -m 0644 modules/5.15.148-tegra/aarch64/*.ko \
  "/lib/modules/$KERNEL/updates/mt76/"
sudo depmod "$KERNEL"
sudo modprobe mt76x2u
```

The module includes the USB alias `v0E8Dp7612`, so subsequent insertion of that
adapter should load `mt76x2u` automatically. To request loading at every boot:

```bash
echo mt76x2u | sudo tee /etc/modules-load.d/mt76x2u.conf
```

If an older MT76 module is already loaded, copying a new `.ko` does not replace
the code currently in memory. Stop any network service using the adapter and
either unload the MT76 module stack before `modprobe`, or reboot at a suitable
maintenance time.

## Verify

```bash
modinfo mt76x2u | grep -E 'filename|alias.*0E8D.*7612|vermagic'
lsusb -t
iw dev
sudo dmesg | grep -iE 'mt76|mt7612|mt7662'
```

Expected `vermagic`:

```text
5.15.148-tegra SMP preempt mod_unload modversions aarch64
```

The adapter should appear in `lsusb -t` with `Driver=mt76x2u`, and `iw dev`
should show a new wireless interface.

## Secure Boot and module signing

These modules are unsigned. They work on the tested L4T system where kernel
module signature enforcement is disabled. They will not load when signature
enforcement is enabled unless signed with a key trusted by that system.

## Remove

Stop NetworkManager, `hostapd`, or any other service using the adapter first:

```bash
sudo modprobe -r mt76x2u mt76x2_common mt76x02_usb \
  mt76x02_lib mt76_usb mt76
sudo rm -rf /lib/modules/5.15.148-tegra/updates/mt76
sudo depmod 5.15.148-tegra
```

Do not unload a module while its interface is carrying an active control or
teleoperation connection.

## Build provenance

- Hardware used for the build and test: NVIDIA Jetson Orin NX in a Unitree G1
  PC2.
- NVIDIA source package: [Jetson Linux 36.4.3 Driver Package Sources](https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2).
- Kernel source inside that package: `Linux_for_Tegra/source/kernel_src.tbz2`,
  directory `kernel/kernel-jammy-src`.
- Upstream driver: [Linux MT76 wireless driver](https://github.com/torvalds/linux/tree/v5.15.148/drivers/net/wireless/mediatek/mt76).
- Module license reported by `modinfo`: `Dual BSD/GPL`.
- Build date of the matching NVIDIA kernel package: January 7, 2025.
- Binary build date: August 18, 2026.
- Build environment: Ubuntu 22.04.5 LTS, GCC 11.4.0, GNU binutils 2.38,
  and GNU Make 4.3.

Enabled configuration:

```text
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_MT76_CORE=m
CONFIG_MT76_LEDS=y
CONFIG_MT76_USB=m
CONFIG_MT76x02_LIB=m
CONFIG_MT76x02_USB=m
CONFIG_MT76x2_COMMON=m
CONFIG_MT76x2U=m
```

## Finding and extracting the NVIDIA kernel source

The official source archive for L4T 36.4.3 is `public_sources.tbz2` from the
[Jetson Linux 36.4.3 release](https://developer.nvidia.com/embedded/jetson-linux-r3643).
It is a bzip2-compressed tar archive containing several nested source archives.
The kernel archive can be found by listing the outer archive; extracting the
whole outer archive is unnecessary.

These are the commands used on PC2:

```bash
mkdir -p /home/unitree/pc2/mt76-build
cd /home/unitree/pc2/mt76-build

curl -fL -o public_sources.tbz2 \
  https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2
bzip2 -t public_sources.tbz2

tar -tjf public_sources.tbz2 | grep -E '(^|/)kernel_src[.]tbz2$'
# Linux_for_Tegra/source/kernel_src.tbz2

tar -xjf public_sources.tbz2 \
  Linux_for_Tegra/source/kernel_src.tbz2

mkdir -p source
tar -xjf Linux_for_Tegra/source/kernel_src.tbz2 -C source

test -d source/kernel/kernel-jammy-src
make -s -C source/kernel/kernel-jammy-src kernelversion
```

The first `tar` invocation only lists member names. The second selectively
extracts the approximately 149 MiB nested kernel archive. Only the final
command expands the kernel source, under `source/kernel/kernel-jammy-src`.
No throwaway extraction directory was needed to discover the member.

## Building for L4T 36.5 from a 36.4.3 Jetson

This is possible because both systems are aarch64. The build host's running
kernel does not need to match the target, but all target build inputs must
match each other exactly:

- L4T 36.5.0 source archive: `r36_release_v5.0`.
- Target kernel: `5.15.185-tegra`.
- Target production `.config` and `Module.symvers` from
  `nvidia-l4t-kernel-headers_5.15.185-tegra-36.5.0-20260115194252_arm64.deb`.
- An aarch64 compiler and the normal kernel build dependencies.

On Ubuntu, the preparation requires `curl`, `bzip2`, `dpkg`, and `kmod`; the
kernel build requires the usual `build-essential`, `bc`, `flex`, `bison`,
`libssl-dev`, `libelf-dev`, and `zstd` packages. NVIDIA documents the core
prerequisites in its [L4T 36.5 kernel customization guide](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Kernel/KernelCustomization.html).

Do not install the 36.5 header or kernel package on the running 36.4.3 robot.
Extract the header `.deb` into an isolated directory with `dpkg-deb -x`. The
target `Module.symvers` is essential because NVIDIA enables
`CONFIG_MODVERSIONS`.

The included script performs the isolated download and preparation, without
writing to `/lib/modules`:

```bash
./scripts/prepare_l4t_kernel_tree.sh \
  --work-dir /home/unitree/pc2/mt76-build-r36.5 \
  --jobs 8
```

Add `--build-mt76` to build and collect the six modules:

```bash
./scripts/prepare_l4t_kernel_tree.sh \
  --work-dir /home/unitree/pc2/mt76-build-r36.5 \
  --jobs 8 \
  --build-mt76
```

Output is written to:

```text
/home/unitree/pc2/mt76-build-r36.5/output/5.15.185-tegra/aarch64/
```

Those modules cannot be loaded on `5.15.148-tegra`; they are artifacts for a
machine actually running the matching `5.15.185-tegra` NVIDIA package. The
current r36.5 repository also contains L4T 36.5.2 with kernel
`5.15.199-tegra`, which is a different ABI and requires a separate build.

## Inspecting NVIDIA's Debian repositories without apt

For this source line:

```text
deb https://repo.download.nvidia.com/jetson/t234 r36.5 main
```

Debian repository fields map to the metadata URL as follows:

```text
BASE/dists/SUITE/COMPONENT/binary-ARCH/Packages.gz
```

Therefore the t234 ARM64 index is:

```text
https://repo.download.nvidia.com/jetson/t234/dists/r36.5/main/binary-arm64/Packages.gz
```

NVIDIA splits packages between `common` and `t234`, so query both indexes:

```bash
suite=r36.5
arch=arm64

for repo in common t234; do
  curl -fsSL \
    "https://repo.download.nvidia.com/jetson/$repo/dists/$suite/main/binary-$arch/Packages.gz" |
    gzip -dc |
    awk -v repo="$repo" '
      BEGIN { RS=""; FS="\n" }
      {
        package=""; version=""; size=""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Package: /) package=substr($i, 10)
          if ($i ~ /^Version: /) version=substr($i, 10)
          if ($i ~ /^Size: /) size=substr($i, 7)
        }
        if (package != "") print repo, package, version, size
      }
    '
done | sort -u
```

Print the complete metadata for all available kernel-header versions:

```bash
curl -fsSL \
  https://repo.download.nvidia.com/jetson/t234/dists/r36.5/main/binary-arm64/Packages.gz |
  gzip -dc |
  awk '
    BEGIN { RS=""; FS="\n" }
    {
      for (i = 1; i <= NF; i++)
        if ($i == "Package: nvidia-l4t-kernel-headers") {
          print $0 "\n"
          break
        }
    }
  '
```

Each stanza provides `Filename`, `Size`, and `SHA256`, allowing direct download
and verification without `apt`. `Packages.gz` is only the catalog. For full
repository authentication, also fetch and verify the suite's `InRelease` file
with NVIDIA's repository signing key before trusting package hashes.

## Licensing

The matching NVIDIA source contains MT76 files under GPL-2.0 and ISC SPDX
identifiers, while each resulting module reports `Dual BSD/GPL` through
`modinfo`. The exact license texts copied from that source package are in
[`LICENSE`](LICENSE) and [`LICENSES/ISC`](LICENSES/ISC).

The corresponding source and its per-file license terms remain authoritative.
This repository does not relicense NVIDIA's kernel source, the Linux kernel,
MT76, or device firmware. Firmware is not included.

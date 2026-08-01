#!/bin/sh -eu
# derive-dwl-installer.sh
#
# Builds a minimal dwl + havoc + firefox Wayland desktop on dérive Linux
# from scratch via the ports tree, replaying every fix discovered during
# the original build session so you don't have to re-debug all of it.
#
# Run as a user with doas configured. Expects git + internet already working
# (clone the ports tree yourself first if this is a totally fresh install,
# or let this script do it).
#
# NOTES ON THINGS THAT WON'T CARRY OVER FROM THE VM:
#   - The cursor-not-moving fix (VirtualBox USB Tablet -> PS/2 Mouse) is a
#     VM-only issue. On real hardware (your T420) this won't apply at all.
#   - VirtualBox's audio controller toggle obviously doesn't apply either.
#   - seatd is NOT set up as a boot-time service here (situation's service
#     format was never nailed down live). You'll need `doas seatd &`
#     manually each session until that's sorted, same as tonight.
#   - sndiod's dedicated user/group creation is included but unconfirmed
#     working end-to-end -- audio was deferred to be debugged live.

PORTS=/ports

echo "==> checking for ports tree"
if [ ! -d "$PORTS" ]; then
	doas git clone https://codeberg.org/derivelinux/ports "$PORTS"
fi
cd "$PORTS"

# ---------------------------------------------------------------------
# generic build helper: fetch, build, package, install a port as-is
# ---------------------------------------------------------------------
build_port() {
	dir="$1"
	echo "==> building $dir"
	cd "$PORTS/$dir"
	chmod +x ndmake.sh
	./ndmake.sh fetch
	./ndmake.sh make

	name=$(grep '^NAME=' ndmake.sh | head -1 | cut -d= -f2)
	version=$(grep '^VERSION=' ndmake.sh | head -1 | cut -d= -f2)
	release=$(grep '^RELEASE=' ndmake.sh | head -1 | cut -d= -f2)

	pkgdir=$(find /var/tmp/dtr -maxdepth 1 -iname "pkg-${name}-${version}" | head -1)
	[ -z "$pkgdir" ] && pkgdir=$(find /var/tmp/dtr -maxdepth 1 -iname "pkg-${name}-*" | head -1)
	pkgbase=$(basename "$pkgdir")

	cd /var/tmp/dtr
	spc create "$pkgbase" "${name}-${version}-${release}.spc.zstd"
	doas spc install "${name}-${version}-${release}.spc.zstd"
	cd "$PORTS"
}

# find the real installed path of a file regardless of prefix quirks
find_installed() {
	find / -maxdepth 6 -iname "$1" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------
# toolchain: python3, u-config, muon
# ---------------------------------------------------------------------
build_port lang/python3
build_port devel/u-config
build_port devel/muon

# ---------------------------------------------------------------------
# libarchive chain (muon's own deps, plus needed for the ports tree
# generally). needs a hand-fix afterward: the port's own install step
# writes a broken libarchive.pc (wrong includedir, missing -I flag).
# ---------------------------------------------------------------------
build_port lib/bzip2
build_port lib/expat
build_port lib/libarchive

echo "==> fixing broken libarchive.pc"
archivepc=$(find_installed 'libarchive.pc')
if [ -n "$archivepc" ]; then
	doas tee "$archivepc" > /dev/null << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/include

Name: libarchive
Description: library that can create and read several streaming archive formats
Version: 3.7.4
Cflags: -I${includedir}
Cflags.private: -DLIBARCHIVE_STATIC
Libs: -L${libdir} -larchive
Libs.private: -lz -lbz2 -lexpat
EOF
fi

# ---------------------------------------------------------------------
# tllist -- doesn't exist in the ports tree, write it from scratch.
# single header, no build step.
# ---------------------------------------------------------------------
echo "==> writing tllist port"
mkdir -p "$PORTS/lib/tllist"
cat > "$PORTS/lib/tllist/info" << 'EOF'
name: tllist
description: c99 typed linked list, in a single header file
license: MIT
upstream: https://codeberg.org/dnkl/tllist
version: 1.1.0
maintainer:
EOF
cat > "$PORTS/lib/tllist/ndmake.sh" << 'EOF'
#!/bin/sh -ue
NAME=tllist
VERSION=1.1.0
RELEASE=1
SOURCE="https://codeberg.org/dnkl/tllist/archive/${VERSION}.tar.gz"

build() {
	mkdir -p "$PKG$PREFIX/include"
	cp "$SRC/tllist/tllist.h" "$PKG$PREFIX/include/tllist.h"
}

. ${0%/*}/../../libsh/libdmake.sh
EOF
build_port lib/tllist

# ---------------------------------------------------------------------
# freetype chain: brotli, libpng, freetype (needs CPPFLAGS pre-set or
# its harfbuzz rebuild stage dies under `set -u`), fontconfig, pixman
# ---------------------------------------------------------------------
build_port lib/brotli
build_port lib/libpng

echo "==> building freetype (CPPFLAGS must be pre-set)"
export CPPFLAGS=""
build_port lib/freetype

build_port lib/fontconfig
build_port lib/pixman

# ---------------------------------------------------------------------
# fcft -- doesn't exist in ports tree either, write from scratch.
# uses BUILD_STYLE=meson which routes through muon/samu automatically.
# ---------------------------------------------------------------------
echo "==> writing fcft port"
mkdir -p "$PORTS/lib/fcft"
cat > "$PORTS/lib/fcft/info" << 'EOF'
name: fcft
description: simple library for font loading and glyph rasterization
license: MIT
upstream: https://codeberg.org/dnkl/fcft
version: 3.3.3
maintainer:
EOF
cat > "$PORTS/lib/fcft/deps" << 'EOF'
.u-config
/pixman
/freetype
/fontconfig
/tllist
EOF
cat > "$PORTS/lib/fcft/ndmake.sh" << 'EOF'
#!/bin/sh -ue
NAME=fcft
VERSION=3.3.3
RELEASE=1
SOURCE="https://codeberg.org/dnkl/fcft/archive/${VERSION}.tar.gz"
BUILD_STYLE=meson
BUILD_OPT="-Ddefault_library=static -Ddocs=disabled -Dsvg-backend=none -Dexamples=false"

. ${0%/*}/../../libsh/libdmake.sh
EOF
build_port lib/fcft

# ---------------------------------------------------------------------
# libffi (needed by wayland's build)
# ---------------------------------------------------------------------
build_port lib/libffi

# ---------------------------------------------------------------------
# wayland -- ships with VERSION/SOURCE mismatched (VERSION=1.26.0 but
# the hardcoded tarball URL is for 1.25.0). pin VERSION down to match
# what's actually fetchable.
# ---------------------------------------------------------------------
echo "==> patching wayland version mismatch"
cd "$PORTS/wl/wayland"
sed -i 's/^VERSION=1.26.0/VERSION=1.25.0/' ndmake.sh
build_port wl/wayland

# ---------------------------------------------------------------------
# wayland-protocols -- ships pinned to 1.47, but wlroots wants >=1.48.
# bump to 1.49 and fix the hardcoded URL to actually use ${VERSION}.
# ---------------------------------------------------------------------
echo "==> patching wayland-protocols version"
cd "$PORTS/lib/wayland-protocols"
sed -i 's/^VERSION=1.47/VERSION=1.49/' ndmake.sh
sed -i 's#SOURCE="https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.47/downloads/wayland-protocols-1.47.tar.xz"#SOURCE="https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/${VERSION}/downloads/wayland-protocols-${VERSION}.tar.xz"#' ndmake.sh
build_port lib/wayland-protocols

# ---------------------------------------------------------------------
# input stack
# ---------------------------------------------------------------------
build_port lib/xkeyboard-config
build_port lib/libxkbcommon
build_port wl/havoc

build_port lib/libevdev
build_port lib/mtdev

echo "==> patching libinput to enable udev support"
cd "$PORTS/lib/libinput"
sed -i 's/-Dudev=false/-Dudev=true/' ndmake.sh
build_port lib/libinput

build_port lib/hwdata
build_port lib/libdisplay-info
build_port lib/libudev-zero

# ---------------------------------------------------------------------
# seatd -- ships with no BUILD_STYLE/BUILD_OPT set at all, which
# produces an incomplete static libseat.a missing internal symbols
# (_logf, log_init, seatd_impl live in a separate libseat-private.a
# that the port never installs, and libseat.pc never lists it either).
# ---------------------------------------------------------------------
echo "==> patching seatd build style + fixing split static archive"
cd "$PORTS/lib/seatd"
awk '1;/^SOURCE=/{print "BUILD_STYLE=meson"; print "BUILD_OPT=\"-Ddefault_library=static\""}' ndmake.sh > ndmake.sh.new
mv ndmake.sh.new ndmake.sh
build_port lib/seatd

echo "==> installing missing libseat-private.a and fixing libseat.pc"
privatearchive=$(find /var/tmp/dtr -path '*seatd*/build/libseat-private.a' | head -1)
mainarchive=$(find_installed 'libseat.a')
if [ -n "$privatearchive" ] && [ -n "$mainarchive" ]; then
	libdir=$(dirname "$mainarchive")
	doas cp "$privatearchive" "$libdir/libseat-private.a"
fi
seatpc=$(find_installed 'libseat.pc')
if [ -n "$seatpc" ]; then
	doas sed -i 's/-lrt -lseat$/-lrt -lseat -lseat-private/' "$seatpc"
fi

build_port lib/libdrm

# ---------------------------------------------------------------------
# wlroots -- ships tracking git HEAD, which drifts out of API sync with
# dwl's main branch (which targets the latest tagged RELEASE). pin to
# a real release tarball instead. Also has a real upstream-adjacent bug:
# backend/libinput/{tablet_tool,tablet_pad}.c call udev_device_get_syspath
# and udev_device_unref without including <libudev.h> directly, relying
# on transitive inclusion that doesn't happen with libudev-zero. Patch
# both files after extraction, before compiling.
# ---------------------------------------------------------------------
echo "==> patching wlroots to pin a real release + fix missing udev include"
cd "$PORTS/lib/wlroots"
sed -i 's/^VERSION=git/VERSION=0.20.2/' ndmake.sh
sed -i 's#SOURCE="https://freedesktop.org/wlroots/wlroots.git"#SOURCE="https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/${VERSION}/wlroots-${VERSION}.tar.gz"#' ndmake.sh
sed -i 's/ -Dtests=false//' ndmake.sh

chmod +x ndmake.sh
./ndmake.sh fetch
./ndmake.sh extract

wlrootssrc=$(find /var/tmp/dtr -maxdepth 2 -iname 'wlroots-0.20.2' -type d | head -1)
if [ -n "$wlrootssrc" ]; then
	for f in "$wlrootssrc/backend/libinput/tablet_tool.c" "$wlrootssrc/backend/libinput/tablet_pad.c"; do
		if [ -f "$f" ] && ! grep -q '#include <libudev.h>' "$f"; then
			sed -i '/#include <libinput.h>/a #include <libudev.h>' "$f"
		fi
	done
fi

./ndmake.sh build

name=$(grep '^NAME=' ndmake.sh | head -1 | cut -d= -f2)
version=$(grep '^VERSION=' ndmake.sh | head -1 | cut -d= -f2)
release=$(grep '^RELEASE=' ndmake.sh | head -1 | cut -d= -f2)
pkgdir=$(find /var/tmp/dtr -maxdepth 1 -iname "pkg-${name}-${version}" | head -1)
cd /var/tmp/dtr
spc create "$(basename "$pkgdir")" "${name}-${version}-${release}.spc.zstd"
doas spc install "${name}-${version}-${release}.spc.zstd"
cd "$PORTS"

# ---------------------------------------------------------------------
# dwl -- needs the same xdg-shell-enum.h fix as wlroots ecosystem
# (wayland-protocols' meson enum-header mode doesn't emit the
# *_SINCE_VERSION macros that dwl's client.h / dwl.c expect), plus your
# config.h customizations: maroon/black colors, havoc as $TERMINAL,
# and an Alt+Shift+F keybind to launch firefox. MODKEY is already Alt
# by default in this fork.
# ---------------------------------------------------------------------
echo "==> patching xdg-shell-enum.h with missing SINCE_VERSION macros"
enumheader=$(find_installed 'xdg-shell-enum.h')
if [ -n "$enumheader" ] && ! grep -q 'XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION' "$enumheader"; then
	doas tee -a "$enumheader" > /dev/null << 'EOF'
#ifndef XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION
#define XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION 4
#endif
#ifndef XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION
#define XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION 5
#endif
EOF
fi

echo "==> building dwl with custom config.h"
cd "$PORTS/wl/dwl"
chmod +x ndmake.sh
./ndmake.sh fetch
./ndmake.sh extract

dwlsrc=$(find /var/tmp/dtr -maxdepth 1 -iname 'src-dwl-*' | head -1)
if [ -n "$dwlsrc" ] && [ -f "$dwlsrc/config.h" ]; then
	sed -i \
		-e 's/COLOR(0x222222ff)/COLOR(0x1a0505ff)/' \
		-e 's/COLOR(0x444444ff)/COLOR(0x4a1216ff)/' \
		-e 's/COLOR(0x005577ff)/COLOR(0x8b1a1eff)/' \
		-e 's/COLOR(0xff0000ff)/COLOR(0xd97706ff)/' \
		-e 's/"foot", NULL/"havoc", NULL/' \
		"$dwlsrc/config.h"

	if ! grep -q 'firefoxcmd' "$dwlsrc/config.h"; then
		awk '1;/static const char \*termcmd\[\]/{print "static const char *firefoxcmd[] = { \"firefox\", NULL };"}' \
			"$dwlsrc/config.h" > "$dwlsrc/config.h.new"
		mv "$dwlsrc/config.h.new" "$dwlsrc/config.h"

		awk '1;/v = termcmd/{print "    { MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_f,          spawn,          {.v = firefoxcmd} },"}' \
			"$dwlsrc/config.h" > "$dwlsrc/config.h.new"
		mv "$dwlsrc/config.h.new" "$dwlsrc/config.h"
	fi
fi

./ndmake.sh build

name=$(grep '^NAME=' ndmake.sh | head -1 | cut -d= -f2)
version=$(grep '^VERSION=' ndmake.sh | head -1 | cut -d= -f2)
release=$(grep '^RELEASE=' ndmake.sh | head -1 | cut -d= -f2)
pkgdir=$(find /var/tmp/dtr -maxdepth 1 -iname "pkg-${name}-${version}" | head -1)
cd /var/tmp/dtr
spc create "$(basename "$pkgdir")" "${name}-${version}-${release}.spc.zstd"
doas spc install "${name}-${version}-${release}.spc.zstd"
cd "$PORTS"

# ---------------------------------------------------------------------
# firefox bundle (AppBundleHUB's prebuilt DWARFS-mounted binary --
# no compilation, just needs libfuse to mount the image at runtime)
# ---------------------------------------------------------------------
build_port lib/libfuse
build_port bundles/firefox

# ---------------------------------------------------------------------
# fonts -- without this, everything renders as tofu boxes
# ---------------------------------------------------------------------
build_port fonts/dejavu-sans
doas fc-cache -f

# ---------------------------------------------------------------------
# audio -- sndio instead of PipeWire (fits the static/minimal ethos
# much better; PipeWire's dependency tree would fight this whole system)
# ---------------------------------------------------------------------
build_port lib/alsa-lib
build_port lib/sndio

echo "==> attempting sndiod system user setup (best-effort, unconfirmed)"
doas addgroup sndiod 2>/dev/null || true
doas adduser -S -D -H -h /var/empty -s /sbin/nologin -G sndiod sndiod 2>/dev/null || \
	echo "WARNING: sndiod user creation failed -- sort this out live, same as tonight"

# ---------------------------------------------------------------------
# XDG_RUNTIME_DIR persistence (fish config)
# ---------------------------------------------------------------------
echo "==> persisting XDG_RUNTIME_DIR in fish config"
FISHCONF="$HOME/.config/fish/config.fish"
mkdir -p "$(dirname "$FISHCONF")"
if ! grep -q 'XDG_RUNTIME_DIR' "$FISHCONF" 2>/dev/null; then
	cat >> "$FISHCONF" << 'EOF'

# set up XDG_RUNTIME_DIR for Wayland/dwl
if test -z "$XDG_RUNTIME_DIR"
    set -gx XDG_RUNTIME_DIR /run/user/(id -u)
    mkdir -p $XDG_RUNTIME_DIR
    chmod 0700 $XDG_RUNTIME_DIR
end
EOF
fi

echo ""
echo "=================================================================="
echo " done. before launching dwl, each session, you still need to run:"
echo ""
echo "   doas seatd &"
echo "   dwl"
echo ""
echo " seatd is NOT wired into boot-time init yet -- that's still open."
echo " Alt+Shift+Enter  -> havoc terminal"
echo " Alt+Shift+F      -> firefox"
echo "=================================================================="

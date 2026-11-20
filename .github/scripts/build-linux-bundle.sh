#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build a relocatable OpenOCD bundle for Linux.
#
# All USB/adapter libraries are built from source as shared libraries and
# shipped in <bundle>/lib; the openocd binary uses an $ORIGIN-relative RPATH,
# so the tarball can be extracted anywhere. Only glibc and libudev are taken
# from the host system at runtime.
#
# Usage: build-linux-bundle.sh <openocd-src> <work-dir>
# Output: <work-dir>/openocd-<version>-<arch>-linux.tar.gz (+ .sha256)

set -euo pipefail

OPENOCD_SRC=$(readlink -f "$1")
WORK=$(readlink -m "$2")

: "${LIBUSB1_VER:=1.0.27}"
: "${HIDAPI_VER:=0.14.0}"
: "${LIBFTDI_VER:=1.5}"
: "${LIBJAYLINK_VER:=0.3.1}"
: "${CAPSTONE_VER:=5.0.1}"
: "${JIMTCL_VER:=0.83}"
: "${MAKE_JOBS:=$(nproc)}"

ARCH=$(uname -m)
DL=$WORK/downloads
BUILD=$WORK/build
STAGE=$WORK/stage          # deps install here (headers, .pc, .so)

VERSION=$(git -C "$OPENOCD_SRC" describe --tags --match "v[0-9]*" --always 2>/dev/null || echo unknown)
NAME=openocd-${VERSION}-${ARCH}-linux
BUNDLE=$WORK/$NAME

rm -rf "$BUILD" "$STAGE" "$BUNDLE"
mkdir -p "$DL" "$BUILD" "$STAGE" "$BUNDLE"

export PKG_CONFIG_PATH=$STAGE/lib/pkgconfig:$STAGE/share/pkgconfig
export CPPFLAGS="-I$STAGE/include"
export LDFLAGS="-L$STAGE/lib"

fetch() { # url dest-name
	[ -f "$DL/$2" ] || curl -fsSL --retry 3 -o "$DL/$2" "$1"
	tar -C "$BUILD" -xf "$DL/$2"
}

# --- libusb ---------------------------------------------------------------
fetch "https://github.com/libusb/libusb/releases/download/v${LIBUSB1_VER}/libusb-${LIBUSB1_VER}.tar.bz2" libusb.tar.bz2
(cd "$BUILD/libusb-${LIBUSB1_VER}" &&
	./configure --prefix="$STAGE" --enable-shared --disable-static &&
	make -j"$MAKE_JOBS" && make install)

# --- hidapi (hidraw + libusb backends) -------------------------------------
fetch "https://github.com/libusb/hidapi/archive/hidapi-${HIDAPI_VER}.tar.gz" hidapi.tar.gz
cmake -S "$BUILD/hidapi-hidapi-${HIDAPI_VER}" -B "$BUILD/hidapi-build" \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$STAGE" \
	-DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$STAGE" -DHIDAPI_WITH_TESTS=OFF
cmake --build "$BUILD/hidapi-build" -j"$MAKE_JOBS" --target install

# --- libftdi ---------------------------------------------------------------
fetch "https://www.intra2net.com/en/developer/libftdi/download/libftdi1-${LIBFTDI_VER}.tar.bz2" libftdi.tar.bz2
cmake -S "$BUILD/libftdi1-${LIBFTDI_VER}" -B "$BUILD/libftdi-build" \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$STAGE" -DLIB_SUFFIX= \
	-DCMAKE_PREFIX_PATH="$STAGE" -DSTATICLIBS=OFF -DEXAMPLES=OFF \
	-DFTDI_EEPROM=OFF -DFTDIPP=OFF -DPYTHON_BINDINGS=OFF -DDOCUMENTATION=OFF
cmake --build "$BUILD/libftdi-build" -j"$MAKE_JOBS" --target install

# --- libjaylink -----------------------------------------------------------
fetch "https://gitlab.zapb.de/libjaylink/libjaylink/-/archive/${LIBJAYLINK_VER}/libjaylink-${LIBJAYLINK_VER}.tar.gz" libjaylink.tar.gz
(cd "$BUILD/libjaylink-${LIBJAYLINK_VER}" && ./autogen.sh &&
	./configure --prefix="$STAGE" --enable-shared --disable-static &&
	make -j"$MAKE_JOBS" && make install)

# --- capstone (static, core only) -----------------------------------------
fetch "https://github.com/capstone-engine/capstone/archive/refs/tags/${CAPSTONE_VER}.tar.gz" capstone.tar.gz
cmake -S "$BUILD/capstone-${CAPSTONE_VER}" -B "$BUILD/capstone-build" \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$STAGE" -DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
	-DCAPSTONE_BUILD_TESTS=OFF -DCAPSTONE_BUILD_CSTOOL=OFF
cmake --build "$BUILD/capstone-build" -j"$MAKE_JOBS" --target install

# --- jimtcl (static) ------------------------------------------------------
fetch "https://github.com/msteveb/jimtcl/archive/refs/tags/${JIMTCL_VER}.tar.gz" jimtcl.tar.gz
(cd "$BUILD/jimtcl-${JIMTCL_VER}" &&
	./configure --prefix="$STAGE" --with-ext=json --minimal --disable-ssl --disable-docs &&
	make -j"$MAKE_JOBS" && make install)

# --- openocd --------------------------------------------------------------
(cd "$OPENOCD_SRC" && [ -x configure ] || ./bootstrap nosubmodule)
mkdir -p "$BUILD/openocd"
(cd "$BUILD/openocd" &&
	"$OPENOCD_SRC/configure" --prefix=/usr --disable-werror --disable-doxygen-html &&
	make -j"$MAKE_JOBS" && make install-strip DESTDIR="$BUNDLE")

# Flatten /usr into the bundle root, ship the runtime libraries next to it.
mv "$BUNDLE/usr/"* "$BUNDLE/" && rmdir "$BUNDLE/usr"
mkdir -p "$BUNDLE/lib"
cp -a "$STAGE"/lib/lib{usb-1.0,hidapi-hidraw,hidapi-libusb,ftdi1,jaylink}.so* "$BUNDLE/lib/"
strip --strip-unneeded "$BUNDLE"/lib/*.so.* 2>/dev/null || true
patchelf --set-rpath '$ORIGIN/../lib' "$BUNDLE/bin/openocd"
# Dependency .so files also need to find each other (libftdi -> libusb).
for so in "$BUNDLE"/lib/*.so.*; do
	[ -L "$so" ] || patchelf --set-rpath '$ORIGIN' "$so"
done
cp "$OPENOCD_SRC/COPYING" "$BUNDLE/"
cat > "$BUNDLE/BUILDINFO" <<INFO
openocd: $VERSION ($(git -C "$OPENOCD_SRC" rev-parse HEAD 2>/dev/null || echo unknown))
built:   $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(. /etc/os-release && echo "$PRETTY_NAME") / glibc $(ldd --version | head -1 | awk '{print $NF}')
libusb $LIBUSB1_VER, hidapi $HIDAPI_VER, libftdi $LIBFTDI_VER, libjaylink $LIBJAYLINK_VER, capstone $CAPSTONE_VER, jimtcl $JIMTCL_VER
INFO

# Sanity check: binary runs and every library resolves from the bundle.
if ldd "$BUNDLE/bin/openocd" | grep -q 'not found'; then
	ldd "$BUNDLE/bin/openocd"; exit 1
fi
"$BUNDLE/bin/openocd" --version

tar -C "$WORK" -czf "$WORK/$NAME.tar.gz" "$NAME"
(cd "$WORK" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "BUNDLE=$WORK/$NAME.tar.gz"

#!/usr/bin/env/bash
set -eu
set -o pipefail

# -------------- helper functions --------------
getnumproc(){
	which getconf >/dev/null 2>/dev/null && {
		getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
	} || echo 1
}
numproc=$(getnumproc)

command_exists(){
	command -v "$1" >/dev/null 2>&1;
}
download(){
	if command_exists wget; then 
		wget -c "$1"
	elif command_exists curl; then
		curl -LO "$1"
	else
		echo "need wget or curl" <&2; exit 1
	fi
}

# ---------- user-configurable ----------
UNIX_WORKSPACE=$(cygpath -u "${GITHUB_WORKSPACE:-$PWD}")
INSTALL="${UNIX_WORKSPACE}/msys"
export PATH="$INSTALL/bin:$PATH"

BINUTILS_V=2.45
GCC_V=15.2.0
GLIBC_V=2.42
LINUX_V=6.16.2

TARGET=x86_64-pc-linux-gnu
TARGET32=i686-pc-linux-gnu
TARGETX32=x86_64-pc-linux-gnux32
BUILD=x86_64-pc-cygwin

# ---------- fetch sources ----------
test -f "binutils-${BINUTILS_V}.tar.gz"  || download "https://mirrors.cloud.tencent.com/gnu/binutils/binutils-${BINUTILS_V}.tar.gz"
test -d "binutils-${BINUTILS_V}"         || tar -xzf "binutils-${BINUTILS_V}.tar.gz"

test -f "gcc-${GCC_V}.tar.gz"            || download "https://mirrors.cloud.tencent.com/gnu/gcc/gcc-${GCC_V}/gcc-${GCC_V}.tar.gz"
test -d "gcc-${GCC_V}"                   || tar -xzf "gcc-${GCC_V}.tar.gz"

export MSYS=winsymlinks:native
test -f "glibc-${GLIBC_V}.tar.xz"        || download "https://mirrors.cloud.tencent.com/gnu/glibc/glibc-${GLIBC_V}.tar.xz"
test -d "glibc-${GLIBC_V}"               || tar -xf "glibc-${GLIBC_V}.tar.xz"

test -f "linux-${LINUX_V}.tar.xz"        || download "https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_V}.tar.xz"
test -d "linux-${LINUX_V}"               || tar -xf "linux-${LINUX_V}.tar.xz"

# ---------- build dirs ----------
mkdir -p build-binutils-stage1 build-gcc-stage1 build-glibc build-libstdc++ build-binutils-stage2 build-gcc-stage2

# ---------- enable case sensitivity (Windows-specific) ----------
if command_exists fsutil.exe; then
  fsutil.exe file setCaseSensitiveInfo "${UNIX_WORKSPACE}/build-glibc" enable || true
fi

# ----------  create a limited directory ----------

mkdir -pv ${INSTALL}/{bin,lib}

case $(uname -m) in
	x86_64) mkdir -pv ${INSTALL}/lib64 ;;
esac

mkdir -pv ${INSTALL}/lib{,x}32

# ======================================================================
# 1) binutils stage 1
# ======================================================================
pushd build-binutils-stage1
../binutils-${BINUTILS_V}/configure \
	--prefix=${INSTALL} \
	--build=${BUILD} \
	--host=${BUILD} \
	--target=${TARGET} \
	--with-sysroot=${INSTALL} \
	--disable-nls \
	--enable-gprofng=no \
	--disable-werror \
	--enable-new-dtags \
	--enable-default-hash-style=gnu

make -j"${numproc}"
make install
popd

# ======================================================================
# 2) GCC stage 1
# ======================================================================
pushd gcc-${GCC_V}
	./contrib/download_prerequisites
	
	sed -e '/m64=/s/lib64/lib/' \
      -e '/m32=/s/m32=.*/m32=..\/lib32$(call if_multiarch,:i386-linux-gnu)/' \
      -i.orig gcc/config/i386/t-linux64
	
	sed '/STACK_REALIGN_DEFAULT/s/0/(!TARGET_64BIT \&\& TARGET_SSE)/' \
        -i gcc/config/i386/i386.h
	
	sed -i 's|\.\./libiberty/pic/libiberty.a|../libiberty/libiberty.a|' c++tools/Makefile.in
popd

pushd build-gcc-stage1
	mlist=m64,m32,mx32
	../gcc-${GCC_V}/configure \
		--prefix=${INSTALL} \
		--build=${BUILD} \
		--host=${BUILD} \
		--target=${TARGET} \
		--with-sysroot=${INSTALL} \
		--with-glibc-version=2.42 \
		--with-newlib \
		--without-headers \
		--enable-default-pie \
		--enable-default-ssp \
		--enable-initfini-array \
		--disable-nls \
		--disable-shared \
		--enable-multilib \
		--with-multilib-list=${mlist}  \
		--disable-decimal-float \
		--disable-threads \
		--disable-libatomic \
		--disable-libgomp \
		--disable-libquadmath \
		--disable-libssp \
		--disable-libvtv \
		--disable-libstdcxx \
		--enable-languages=c,c++

	make -j"${numproc}"
	make install
popd

pushd gcc-${GCC_V}
	cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
      `dirname $($TARGET-gcc -print-libgcc-file-name)`/include/limits.h
popd

# ======================================================================
# 3) linux API headers
# ======================================================================
pushd linux-${LINUX_V}
  # Doesn't work on CYGWIN/MSYS
	# make mrproper | true
	
	make headers
	find usr/include -type f ! -name '*.h' -delete
	
	cp -rv usr/include ${INSTALL}
popd

# ======================================================================
# 4) glibc (multilib)
# ======================================================================
pushd glibc-${GLIBC_V}

# Apply LFS FHS patch if not already applied
if ! test -f ../glibc-${GLIBC_V}-fhs-applied; then
    set +e
    download "https://www.linuxfromscratch.org/patches/lfs/development/glibc-${GLIBC_V}-fhs-1.patch" || true
    set -e
    if test -f "glibc-${GLIBC_V}-fhs-1.patch"; then
        patch -Np1 -i "glibc-${GLIBC_V}-fhs-1.patch" || true
    fi
    touch ../glibc-${GLIBC_V}-fhs-applied
fi
popd

# Function to build glibc for a given host/ABI
build_glibc_multilib() {
    local host="$1"
    local libdir="$2"
    local cflags="$3"

    mkdir -pv build-glibc-${host}
    pushd build-glibc-${host}

    export CC="${host}-gcc ${cflags}"
    export CXX="${host}-g++ ${cflags}"
    export CFLAGS="-O2 -g ${cflags}"
    export CXXFLAGS="-O2 -g ${cflags}"

    echo "rootsbindir=${INSTALL}/sbin" > configparms

    ../glibc-${GLIBC_V}/configure \
        --prefix=${INSTALL} \
        --build=$(../glibc-${GLIBC_V}/scripts/config.guess) \
        --host=${host} \
        --disable-nscd \
        --with-headers=${INSTALL}/include \
        --libdir=${libdir} \
        --libexecdir=${libdir} \
        --enable-kernel=5.4

    make -j"${numproc}"
    make install

    popd
}

# Build all three glibc ABIs with correct host
build_glibc_multilib "${TARGET}"   "${INSTALL}/lib"    ""
build_glibc_multilib "${TARGET32}" "${INSTALL}/lib32"  "-m32"
build_glibc_multilib "${TARGETX32}" "${INSTALL}/libx32" "-mx32"

# Symlinks for runtime loaders
ln -svf ${INSTALL}/lib/ld-linux-x86-64.so.2   ${INSTALL}/lib64
ln -svf ${INSTALL}/lib32/ld-linux.so.2        ${INSTALL}/lib/ld-linux.so.2
ln -svf ${INSTALL}/libx32/ld-linux-x32.so.2  ${INSTALL}/lib/ld-linux-x32.so.2

# Install multilib stub headers
install -vm644 ${INSTALL}/include/gnu/{lib-names,stubs}-32.h  ${INSTALL}/include/gnu/
install -vm644 ${INSTALL}/include/gnu/{lib-names,stubs}-x32.h ${INSTALL}/include/gnu/

# ======================================================================
# 5) GCC libstdc++-v3
# ======================================================================
pushd build-libstdc++
	../gcc-${GCC_V}/libstdc++-v3/configure \
		--prefix=${INSTALL} \
		--build=$(../glibc-${GLIBC_V}/scripts/config.guess) \
		--enable-multilib \
		--disable-nls \
		--disable-libstdcxx-pch \
    --with-gxx-include-dir=${INSTALL}/${TARGET}/include/c++/15.2.0

	make -j"${numproc}"
	make install
	rm -v ${INSTALL}/lib/lib{stdc++{,exp,fs},supc++}.la
popd


# ======================================================================
# 6) Binutils Stage 2
# ======================================================================
pushd binutils-${BINUTILS_V}
	sed '6031s/$add_dir//' -i ltmain.sh
popd

pushd build-binutils-stage2
	../binutils-${BINUTILS_V}/configure \
		--prefix=${INSTALL} \
		--build=$(../binutils-${BINUTILS_V}/config.guess) \
		--host=${BUILD} \
		--disable-nls \
		--enable-shared \
		--enable-gprofng=no \
		--disable-werror \
		--enable-64-bit-bfd \
		--enable-new-dtags \
		--enable-default-hash-style

	make -j"${numproc}"
	make install
	rm -v ${INSTALL}/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
popd

# ======================================================================
# 7) GCC Stage 2
# ======================================================================
pushd gcc-${GCC_V}
	sed '/thread_header =/s/@.*@/gthr-posix.h/' \
      -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
popd

pushd build-gcc-stage2
	mlist=m64,m32,mx32
	../gcc-${GCC_V}/configure \
		--prefix=${INSTALL} \
		--build=$(../gcc-${GCC_V}/config.guess) \
		--host=${BUILD} \
		--with-build-sysroot=${INSTALL} \
		--enable-default-pie \
		--enable-default-ssp \
		--disable-nls \
		--enable-multilib \
		--with-multilib-list=${mlist} \
		--disable-libatomic \
		--disable-libgomp \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-libvtv \
		--enable-languages=c,c++ \
		LDFLAGS_FOR_TARGET=-L${PWD}/${TARGET}/libgcc
	
	make -j"${numproc}"
	make install
	
	ln -sv gcc ${INSTALL}/bin/cc
popd

# Copyright      2015 Денис Крыськов
# Distributed under the terms of the GNU General Public License v2

EAPI=5
inherit befriend-gcc check-reqs gcc-configure
HOMEPAGE=https://android.googlesource.com/toolchain/binutils
DESCRIPTION="Stage0 gcc compiler, built with hypnotized compiler"
LICENSE="GPL-3"

# While bionic-core/binutils supports sandbox, this .ebuild does not. Sorry
#  for unconvenience

# GCC build system is consistently broken with respect to prefix with spaces.
#  Therefore this .ebuild does not support $EPREFIX or $WORKDIR with spaces or
#  other symbols that break POSIX shell parameter passing

SRC_URI="mirror://gnu/gcc/gcc-$PV/gcc-$PV.tar.bz2
 http://www.mpfr.org/mpfr-current/mpfr-3.1.3.tar.xz
 http://www.multiprecision.org/mpc/download/mpc-1.0.2.tar.gz
"
# Failed to compile cloog with hypnotized compiler, therefore not including isl
#  and cloog bundles

KEYWORDS=amd64
SLOT=0
k=krisk0
DEPEND="
 || ( >=sys-devel/gcc-4.9 >=cross-x86_64-pc-linux-uclibc/gcc-4.9 )
 bionic-core/bionic bionic-core/gcc-specs bionic-core/binutils[-stage0]
 bionic-core/GNU_STL
 bionic-core/gmp
 "

CHECKREQS_DISK_BUILD=800M
src_unpack()
 {
  [ -z $LD_PRELOAD ] || die "Sorry, this .ebuild does not support sandbox"
  gcc-unpack
 }

src_prepare()
 {
  # patch libstdc++-v3 to match git repository
  #  android.googlesource.com/toolchain/gcc as seen 20 Nov 2015
  cd ../gCc/libstdc++-v3 || die "lost in `pwd`"
  triple=x86_64-linux-android
  root="$EPREFIX/usr/$triple"
  patch="$root/share/libstdc-20151120.diff.lzma"
  einfo "will apply patch $(basename $patch)"
  ( lzma -d < "$patch" | patch -p0 ) ||
   die "libstdc++-v3 patch failed"

  # patch other directories, too. Not all files are patched, so as to
  #  decrease patch file size
  cd ..
  patch="$FILESDIR/google-492.diff"
  einfo "will apply patch $patch"
  patch -p0 < "$patch" || die "google-492 patch failed"

  # limits.h generated by fixincludes is broken and does not define PAGE_SIZE,
  #  which breaks /usr/$triple/include/pthread.h, which breaks libgomp/env.c
  #  compilation. Looks like fixincludes needs to be fixed. We instead teach
  #  libgomp.h what he missed
  local l='#define PAGE_SIZE 4096'
  sed -i libgomp/libgomp.h -e "/^#include.*config.h/i $l" ||
   die "libgomp resists"

  # bionic linker does not support rpath, so we optimize link command-line
  for l in `find . -name Makefile.in -type f` ; do
   sed -i $l -e 's:-rpath.$.toolexeclibdir.::g'
  done

  # #if defined(__GLIBC_PREREQ) && __GLIBC_PREREQ(2, 10) cause problems, kill
  #  em all
  for l in `find . -name *.h -type f` ; do
   sed -i $l -e 's:#if.defined.__GLIBC_PREREQ..&&.*:#if 0:g'
  done

  # Call it 4.9a so there is no file collision with real nice gcc-4.9
  cd gcc
  echo 4.9a > BASE-VER
  
  # Inject -lgnustl_shared automagically into collect2 command-line
  ( cd cp; patch -p0 < "$FILESDIR/gnustl_automagic.diff" || 
     die "g++spec resists" )

  # pthread library is bundled with libc, don't need -lpthread
  cd config
  sed -i gnu-user.h -e 's+"%{pthread:-lpthread}."++' ||
   die "pthread directive resists"

  # to make /system/bin/linker64 happy, must use pie flag when compiling or
  #  linking. Directive like below published by Magnus Granberg 2014-07-31
  (
   echo '#define DRIVER_SELF_SPECS \'
   echo '"%{pie|fpie|fPIE|fno-pic|fno-PIC|fno-pie|fno-PIE| \'
   echo ' shared|static|nostdlib|nodefaultlibs|nostartfiles:;:-fPIE -pie}"'
  ) >> linux-android.h || die "linux-android.h resists"
  # strange thing: setup above does not seem to appear in specs, but it works

  # cc1 says
  #   #include <...> search starts here:
  #   /usr/x86_64-linux-android/lib64/../../x86_64-linux-android/include
  #  which is very good. However gcc ignores stdio.h which is right in
  #  this directory. So we add system include directory to specs
  local d=$EPREFIX/usr/$triple/include
  sed -i i386/gnu-user-common.h -e "s>{posix:-D_POSIX_SOURCE}>& -isystem $d>" ||
    die "POSIX_SOURCE resists"
  
  # turn off a loong subroutine that creates a loong libgcc setting; use -lgcc
  sed -i ../gcc.c -e \
   's:defined.ENABLE_SHARED_LIBGCC..&&.!defined.REAL_LIBGCC_SPEC.:0:g' \
   -e 's:=.LIBGCC_SPEC;:= "-lgcc";:g' || die "gcc|libgcc_spec resists"
 }

smarter-link-so()
# change hypnotizing scripts so they compile what we need
 {
  # Inject -L... directive into CC script, so our $CC has inherent knowledge
  #  of base libraries. Sometimes the lib64/ directory will be listed
  #  twice in resulting string sent to g++ (because it happens to be home of
  #  libgmp.so, too)

  old_ld=$S/hypnotized-gcc/bin/ld
  # use long random name for ld so it will be easy to find which executable
  #  is tied to the script
  wrapped_ld=$old_ld`date +%Y%m%d%H%m%s`$$

  local n=$(realpath $3)
  sed -e "s:$2:$n:" -i "$1" || die "changing $(basename $2) failed"
  cp "$2" $3 || die "copying $(basename $2) failed"
  local E=$EPREFIX
  # inject -fno-lto to both files; sometimes append -lgnustl_shared to link
  #  flag; use longer PATH string
  (
   sed -i $3 -e '/^exec/i c=$(echo "$b"|grep -c libbackend.a)'    &&
   sed -i $3 -e '/^exec/i [ $c == 0 ] || b="$b -lgnustl_shared"' &&
   sed -i $3 -e '/^exec/i b="-fno-lto $b"'                      &&
   sed -i $3 -e '/^exec/i echo "link-so final flags: $b"'       &&
   sed -i $1 -e 's:HYPNOTIZED $@:HYPNOTIZED -fno-lto $p:'        &&
   sed -i $1 -e '/.* PATH=/a p="$@"'                              &&
   sed -i $1 -e '/^p=/a w=$(echo "$p"|grep -c libbackend.a)'       &&
   sed -i $1 -e '/^w=/a [ $w == 0 ] || p="$p -lgnustl_shared"'     &&
   sed -i $1 -e "s+/system/bin'$+/system/bin:$E/bin:$E/usr/bin'+"  &&
   sed -i $3 -e "s>^#echo.*>PATH=$E/bin:$E/usr/bin>"
  ) || die "failed to refine hypnotizing scripts"

  # create wrapper around ld-stage1
  (
   cd "$S/hypnotized-gcc/bin"
   # dump ld parameters, insert full path before some .o files
   {
    echo '#!/bin/sh'
    # uncomment line below to see current directory and flags sent by GCC
    #printf '@e"@lcalled from `pwd`"\n@e"@loptions: $@"\n'
    echo 'p=$(echo $@|grep -c -- "-m elf_i386")'
    echo '[ $p == 0 ] && p=/system/lib64 || p=/system/lib32'
    echo 'o=$(echo $@|sed "s: crtbegin_so.o: $p/crtbegin_so.o:g")'
    echo 'o=$(echo $o|sed "s: crtend_so.o: $p/crtend_so.o:g")'
    echo 'o=$(echo $o|sed "s: crtend_android.o: $p/crtend_android.o:g")'
    echo 'o=$(echo $o|sed "s: crtbegin_dynamic.o: $p/crtbegin_dynamic.o:g")'
    # uncomment line below to see modified flags
    #echo '@e"@loPtions: $o"'
    echo "$EPREFIX/usr/$triple/bin/ld-stage1 \$o"
   } > $wrapped_ld
   sed -i $wrapped_ld -e 's:@e:echo :g' -e 's:@l:ld_stage1 :g'
   chmod +x $wrapped_ld
   rm -f ld ; ln -sf $wrapped_ld ld
   [ -x ld ] || die "ld not executabale, cwd=`pwd`"
  )

  # silence hypnotized.gcc and hypnotized.g++
  sed -e 's+echo "$0: from.*+#&+' -i hypnotized.g?? ||
   die 'failed to silence hypnotized.gcc'
 }

src_configure()
 {
  saved_PATH="$PATH"
  rm -rf *
  export CC=$(find-then-hypnotize-gcc 490)

  # $CC and link-so script are not smart enough to link gcc tools and libraries,
  #  must improve them
  local s="$EPREFIX/usr/$triple/share/link-so"
  smarter-link-so hypnotized.gcc "$s" hypnotized-gcc/link-so

  einfo "cooked CC script $CC"
  export CXX=$(hypnotize-gxx-too "$CC")

  einfo "cooked CXX script $CXX"
  # fake libsanbox stops working later, no use setting LD_LIBRARY_PATH here
  local o=${triple%android}gnu
  # Dressing prefix in apostrophes fails with message
  #  expected an absolute directory name for --prefix

  # Dressing include directory in apostrophes results in error
  #  configure: error: "'/usr/x86_64-linux-android/include'" shall be a valid
  #   directory

  # GCC build system is consistently broken with respect to prefix with
  #  spaces
  o="--target=$triple --host=$o --build=$o $(gcc-configure-options)"

  # our wrapper script failed to eat -DVERSION=\"0.18.1\" coming from cloog
  #  Makefile calling libtool:
  #   error: 0.18.1": No such file or directory
  # It means we can't compile cloog now
  o="$o --without-cloog"

  emake=`which emake`
  [ -z "$emake" ] && die "failed to find emake"
  export PATH="$S/hypnotized-gcc/bin:$EPREFIX/usr/bin:$EPREFIX/bin"
  export CFLAGS_FOR_TARGET="-fPIC -O2 -DTARGET_POSIX_IO -fno-short-enums"
  export CXXFLAGS_FOR_TARGET="$CFLAGS_FOR_TARGET"
  export LDFLAGS_FOR_TARGET=-L/system/lib64
  export LDFLAGS=$LDFLAGS_FOR_TARGET

  o="${o/enable-plugins/disable-plugins} --disable-lto"
  [ 0 ] ||
   {
    # this works sometimes. Sometimes it does not, xgcc fails to set path
    #  to crt_begin.o. Race condition?
    o=${o/ld-stage0/ld-stage1}
   } &&
   {
    # this is stupid but works all the time
    o=$(echo "$o"|sed "s>--with-ld=.*ld-stage0>--with-ld=$wrapped_ld>")
    # this only works if $WORKDIR has no spaces inside
   }

  o="$o --libdir=/usr/$triple/lib64"

  # SSP fails to compile with message
  #  multiple definition of `__stack_chk_fail_local'
  o="$o --disable-libssp"
  rm -rf "$gcc_srcdir/libssp"
  einfo "configure options: $o"
  "$gcc_srcdir/configure" $o || die "configure failed"
 }

src_compile()
 {
  # xgcc searches for libraries in many places but not in /system/lib{32,64}. We
  #  make him happy by copying some libraries to where he will find them
  local lib32="$S/$triple/lib64/gcc/$triple/4.9/32"
  (
   mkdir -p "$lib32" && cd "$lib32" && cp /system/lib32/*.o . &&
   cd .. && cp /system/lib64/*.o .
  ) || die "problem duplicating /system/lib.."

  # -DPKGVERSION="\"(GCC) \"" is ok for g++, but not for POSIX script wrapper
  #   around g++. Eliminating spaces inside such strings solves the problem
  "$emake" configure-gcc
  sed -i gcc/Makefile \
   -e 's:(GCC) :(GCC):' \
   -e 's:$(DEVPHASE_c), :$(DEVPHASE_c),:g' \
    || die 'healing gcc/Makefile failed'

  # right now, need no documentation
  local i
  local j
  for i in `find . -name Makefile -type f` ; do
   for j in doc info srcinfo ; do
    sed -i $i -e 's|^$j:.*|$j:|g' || die "$j in $i resists"
   done
   sed -i $i \
    -e 's:$\(INFOFILES\)::g' \
    -r -e 's-(doc/.*?:).*-\1-g' || die "INFOFILES resist"
  done
  # gcc/Makefile needs more care
  sed -i gcc/Makefile -e 's:doc/gcov.1.*gpl.7::' -e :doc/.*doc/gcov-tool.1:: ||
   die "MANFILES resists"

  "$emake"

  # gcc and g++ are using a wrong linker, need to recompile them
  cd gcc
  sed -i auto-host.h -e \
   "s>$wrapped_ld>$EPREFIX/usr/$triple/bin/${triple}-stage0-gcc-ld>" ||
    die "auto-host.h resists"
  rm -f gcc.o collect2.o
  i='xg++ cpp collect2 xgcc'
  # cannot just remove executables --- they are the compiler we are building
  touch -s 197001010000 $i
  # make install will remake the 4 executables since they are dated
 }

symlink-stub()
 {
  local t=/$EPREFIX/$(realpath . --relative-to $ED)
  einfo "symlink-stub(): will put sym-links into $t"
  [ -z $t ] && die "realpath says nothing"
  local d=$(realpath $1 --canonicalize-missing --relative-to $t)
  [ -z $d ] && die "realpath said nothing"
  einfo "symlink-stub(): way down: $d"
  for t in `ls $1/*.so` `ls $1/*.o` ; do
   ln -sf $d/$(basename $t)
  done
 }

src_install()
 {
  export PATH="$S/hypnotized-gcc/bin:$saved_PATH"
  # make fails to find some vtv_*.o files (such as vtv_start.o) and gets very
  #  upset. We make make forget he wanted to make the files
  (
   cd "$S/$triple/libgcc" &&
   sed -r -e 's: vtv_.*?\.o::g' -i `find . -type f -name Makefile`
  ) || die "vtv_*.o resist"

  # cannot stat '.libs/libsupc++.lai'. And it happens not always. Well, let's
  #  put .lai files here and there
  local i
  for i in `find . -name '*.la'` ; do
   [ -f ${i}i ] && einfo "${i}i already exists"
   [ -f ${i}i ] ||
    (
     einfo "creating ${i}i"
     cp -L $i ${i}i || die ".lai: cp $i failed"
    )
  done

  # parallel make install not always works
  emake DESTDIR="$ED" install ||
   einfo "make install failed, this happens sometimes, don't get upset"

  # I said no documentation! And what is that .py? Get lost
  cd "$ED/usr"
  rm -rf share include
  find . -name '*.py' -delete

  # .la files are broken (for instance, 32-bit libraries should not link to
  #  /system/lib64). We solve this little problem
  find . -name '*.la' -delete

  # they say statically linking to gnustl_shared might cause problems. Go
  #  away, problems
  find . -name 'libgnustl_shared.a' -delete

  # compiler needs ld
  cp $EPREFIX/usr/$triple/bin/ld-stage1 bin/$triple-stage0-gcc-ld ||
   die "ld-stage1 resists"

  # We planned to have everything under either /system or /usr/$triple/. However
  #  some files made in into /usr/bin and /usr/libexec. Thus we move the whole 
  #  tree
  mkdir q && mv $triple q/ && mv q $triple &&
   mv bin libexec $triple || die "mv to $triple/ failed"

  # All public .so are in one of 2 directories (which is /system/lib64 or 
  #  /usr/$triple/lib64 for 64-bit). Therefore GCC is not installing any of his 
  #  .so
  find . -name '*.so*' -delete

  QA_PRESTRIPPED='/usr/.*'

  # 64-bit libraries are in /usr/$triple/$triple/lib64; 32-bit in
  #  /usr/$triple/$triple/lib. And gcc is smart enough to look into these.
  #  We sym-link compiler stub and bionic libraries so collect2 finds them
  cd $triple/$triple/lib64
  symlink-stub /system/lib64
  cd ../lib
  symlink-stub /system/lib32

  unset k CHECKREQS_DISK_BUILD gcc_srcdir emake triple root patch saved_PATH \
   old_ld wrapped_ld
 }

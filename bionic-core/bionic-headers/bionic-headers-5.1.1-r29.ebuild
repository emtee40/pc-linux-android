# Copyright 2015 Денис Крыськов
# License: GNU General Public License (GPL)

EAPI=5

DESCRIPTION="Install core headers to $EPREFIX/usr/x86_64-linux-android/include"
a=android
B=bionic
TGT=/usr/x86_64-linux-$a
# Rename android-VER.zip -> bionic-VER.zip
HOMEPAGE=https://github.com/$a/platform_$B
SRC_URI="$HOMEPAGE/archive/${a}-${PV}_$PR.zip -> ${B}-${PV}_$PR.zip"
KEYWORDS=amd64
RESTRICT=mirror
RDEPEND=''
DEPEND=""      # just need compiled kernel sources in /usr/src/linux
SLOT=0
LICENSE=BSD
RESTRICT=mirror

S="$WORKDIR/$B"

src_unpack()
 {
  default
  mv platform_${B}* $B || die "no platform_${B}* in $A"
 }

src_prepare()
 {
  # sanity check on kernel sources
  K=/usr/src/linux
  [ -d $K/include/uapi/sound ] ||
   die "Are you sure you have a compiled kernel in $K?"

  # patch 3 scripts
  local t=libc/kernel/tools/generate_uapi_headers.sh
  mkdir -p ../external/kernel-headers/original
  local KH=`realpath ../external/kernel-headers/original`
  sed \
   -e s:"common":./: \
    -e "s:ANDROID_KERNEL_DIR=.*:ANDROID_KERNEL_DIR=\"$KH\":g" \
    -i $t || die "patching $t failed"

  t=libc/kernel/tools/update_all.py
  sed -e 's:source = .*:source=1:' -i $t || die "patching $t failed"

  t=libc/tools/gensyscalls.py
  sed -e "s:/tmp/:`pwd`/tmp/:" -i $t || die "patching $t failed"

  # remove duplicate definition of flock64
  sed -e 's:struct flock64:struct redefined_flock64:g' -i \
   libc/include/fcntl.h || die "failed to patch fcntl.h"

  # since we plan to define getpass() subroutine in libpthread.so, inject
  #  forward definition into pthread.h
  sed -i libc/include/pthread.h -e \
   '/__END_DECLS/i char* getpass(const char *);' || die 'pthread.h resists'
 }

src_compile()
 {
  local g=libc/kernel/tools/generate_uapi_headers.sh
  export ANDROID_BUILD_TOP="$WORKDIR"

  $g --skip-generation --use-kernel-dir $K || die "$g failed"

  local u=libc/kernel/tools/update_all.py
  $u || die "$u failed"

  g=libc/tools/gensyscalls.py
  $g || die "$g failed"
 }

src_install()
 {
  # If you know a shorter way of doing the same as code below, your patch is
  #  welcome
  local i="$ED/$TGT"
  mkdir -p "$i" ; cd "$i" ; rm -rf *
  local j
  for j in lib{c,m}/include libc/arch-x86_64/include ; do
   einfo "copying headers from $j"
   cp -r "$S/$j" . || die "copying directory $i failed"
  done
  cd include || die
  local root=$(pwd)
  for i in $(ls $S/libc/kernel/uapi) ; do
   j=libc/kernel/uapi/$i
   einfo "copying headers from $j"
   cp -r "$S/$j" . || die "cp uapi/$i . failed"
  done

  # need i386/elf_machdep.h to compile 32-bit code
  ( rm -rf i386 && mkdir i386 ) || die 'mkdir i386 failed'
  # take elf_machdep.h and all its friends
  for i in $(ls $S/libc/arch-x86/include/machine) ; do
   ( [ -f "$S/libc/arch-x86/include/machine/$i" ] &&
     cp "$S/libc/arch-x86/include/machine/$i" i386 ) ||
    die "failed to cp $i"
  done

  # /usr/x86_64-pc-linux-uclibc has termios.h in include/asm/termios.h
  # Our termios.h is currently in asm-x86/asm. We will move it
  ( cd asm-x86 ; cp -r asm .. ) || die "asm-x86 resists"
  [ -f asm/termios.h ] || die 'termios.h missing'
  ls |grep asm-|grep -v asm-generic|xargs rm -rf

  # machine/fenv.h is wanted by fenv.h --- no, bad idea, let it stay in
  #  i387/machine/ and amd64/machine
  #  cp amd64/machine/fenv.h machine/ || die "fenv.h resists"

  # Remove some noise
  for j in `find . -type f` ; do
   sed -e 's|/\* WARNING: .* \*/||g' -i $j
  done

  # File sys/stat.h is not POSIX.1.2008-compliant. Even worse, st_mtime is
  #  of type unsigned long but not time_t (which is signed long). This means
  #  that code converting pointer to q->st_mtime to pointer to time_t such as
  #  'localtime (&st->st_mtime)' fails to compile.

  # We don't make the header conform to POSIX.1.2008. We just make it so that
  #  some POSIX-compliant programs (such as GCC) compile
  sed -i $(find "$ED/$TGT" -type f -wholename '*/sys/stat.h') -e \
   's:unsigned long st_mtime;:long st_mtime;:g'

  # ndk/platforms/android-20/include/ctype.h looks like bionic
  #  libc/include/ctype.h, however they differ slightly. For instance,
  #  bionic does not define _CTYPE_N while ndk does not define _CTYPE_D. Lack of
  #  definition _CTYPE_N makes it impossible to compile gcc/libstdc++. We fix this
  #  we inserting _CTYPE_N definition
  sed -i $(find "$ED/$TGT" -type f -wholename '*/ctype.h') -e \
   '/#define\s_CTYPE_D/a #define _CTYPE_N _CTYPE_D'

  # __locate_t is a pointer under glibc but not a pointer according to
  #  xlocale.h. This breaks g++-v4 code such as
  #   void _S_create_c_locale(__c_locale&, const char*,__c_locale __old = 0);
  #  We fix this by making __locate_t pointer to empty struct
  sed -i "$root/xlocale.h" \
   -e 's|struct __locale_t;|typedef struct{int foo;}* __locale_t;|' \
   -e 's+typedef\sstruct\s__.*+typedef __locale_t locale_t;+' ||
    die "xlocale.h resists"

  unset K
 }

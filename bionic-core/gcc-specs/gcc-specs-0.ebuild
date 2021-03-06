# Copyright      2015 Денис Крыськов
# Distributed under the terms of the GNU General Public License v2

EAPI=5
DESCRIPTION="Auxillary files used to hypnotize gcc compiler"
HOMEPAGE=https://github.com/krisk0/pc-linux-android
KEYWORDS=amd64
SLOT=0
S="${WORKDIR}"

src_install()
 {
  local f=gcc.specs
  local d="$ED/usr/x86_64-linux-android/share"
  into /usr/x86_64-linux-android/share
  cp $FILESDIR/*specs "$d"
  dobin $FILESDIR/link-so
  mv "$d/bin/link-so" "$d/"
  rm -rf "$d/bin"
 }

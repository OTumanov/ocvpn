#!/usr/bin/env bash
# Сборка .deb из исходников (работает на любом Debian/Ubuntu с dpkg-deb).
# Не устанавливает и ничего не запускает — только собирает dist/ocvpn-*.deb
set -euo pipefail

VER="${1:-1.3.4}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$(mktemp -d /tmp/ocvpn-deb-XXXXXX)"
DIST="$REPO/dist"
trap 'rm -rf "$STAGE"' EXIT

PKGDIR="$STAGE/ocvpn_${VER}_all"
mkdir -p "$PKGDIR/DEBIAN" "$PKGDIR/usr/local/bin" \
         "$PKGDIR/lib/systemd/system" "$PKGDIR/usr/share/doc/ocvpn"
# dpkg-deb требует на DEBIAN права 0755..0775 (при umask 027 было бы 0750)
chmod 755 "$PKGDIR/DEBIAN"

sed "s/^Version:.*/Version: $VER/" "$REPO/packaging/debian/control" > "$PKGDIR/DEBIAN/control"
install -m 0755 "$REPO/packaging/debian/postinst" "$PKGDIR/DEBIAN/postinst"
install -m 0755 "$REPO/packaging/debian/prerm" "$PKGDIR/DEBIAN/prerm"
install -m 0755 "$REPO/ocvpn.sh" "$PKGDIR/usr/local/bin/ocvpn"
install -m 0644 "$REPO/packaging/debian/ocvpn.service" "$PKGDIR/lib/systemd/system/ocvpn.service"
install -m 0644 "$REPO/README.md" "$PKGDIR/usr/share/doc/ocvpn/README.md"
install -m 0644 "$REPO/LICENSE" "$PKGDIR/usr/share/doc/ocvpn/copyright" 2>/dev/null || true

mkdir -p "$DIST"
dpkg-deb --build "$PKGDIR" "$DIST/ocvpn-${VER}-all.deb"
echo "Готово: $DIST/ocvpn-${VER}-all.deb"
dpkg-deb -c "$DIST/ocvpn-${VER}-all.deb"

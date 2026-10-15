#!/bin/bash
# Run inside debian:13 from the repository root. Builds, into $1:
#   xd-spike-daemon_{1.0,2.0}-1_amd64.deb  the 5.1.0 binaries, Depends from dpkg-shlibdeps
#   xd-spike-odd_1.0~rc1+b1-1_all.deb      an empty package whose file name carries
#                                          Debian's '~' and '+', to see what GitHub
#                                          does to an asset name holding them
set -euo pipefail
dest=$1
apt-get update
apt-get install -y --no-install-recommends dpkg-dev

work=$(mktemp -d)
mkdir -p "$work/debian"
cat > "$work/debian/control" <<'EOF'
Source: xd-spike

Package: xd-spike-daemon
Architecture: amd64
EOF

stage() {
    local root=$1
    install -Dm755 out/ventulusd "$root/usr/bin/ventulusd"
    install -Dm755 out/ventulus-tray "$root/usr/bin/ventulus-tray"
}

stage "$work/probe"
depends=$(cd "$work" && dpkg-shlibdeps -O -e probe/usr/bin/ventulusd -e probe/usr/bin/ventulus-tray \
    | sed -n 's/^shlibs:Depends=//p')
echo "dpkg-shlibdeps Depends: $depends"

for v in 1.0-1 2.0-1; do
    root="$work/xd-spike-daemon_$v"
    stage "$root"
    mkdir -p "$root/DEBIAN"
    cat > "$root/DEBIAN/control" <<EOF
Package: xd-spike-daemon
Version: $v
Architecture: amd64
Maintainer: Ventulus packaging spike <spike@invalid>
Depends: $depends
Section: misc
Priority: optional
Description: Ventulus packaging spike (throwaway)
 Carries the ventulusd 5.1.0 binaries for a repository experiment. Not for use.
EOF
    dpkg-deb --root-owner-group --build "$root" "$dest/xd-spike-daemon_${v}_amd64.deb"
done

root="$work/xd-spike-odd"
mkdir -p "$root/DEBIAN" "$root/usr/share/doc/xd-spike-odd"
echo spike > "$root/usr/share/doc/xd-spike-odd/README"
cat > "$root/DEBIAN/control" <<'EOF'
Package: xd-spike-odd
Version: 1.0~rc1+b1-1
Architecture: all
Maintainer: Ventulus packaging spike <spike@invalid>
Section: misc
Priority: optional
Description: Ventulus packaging spike asset-name probe (throwaway)
 Empty package. Not for use.
EOF
dpkg-deb --root-owner-group --build "$root" "$dest/xd-spike-odd_1.0~rc1+b1-1_all.deb"
ls -l "$dest"

#!/bin/bash
# Flat APT repository on the assets of one GitHub release, as DEC-499 plans for
# pacman-repo's `repo` release. Runs on the runner host; clients are containers.
#
# Questions:
#  A1 apt follows github.com's 302 to release-assets.githubusercontent.com
#  A2 a signed InRelease (ed25519) verifies on Debian 13 (sqv) and Ubuntu 26.04
#  A3 one .deb built on Debian 13 installs on both
#  A4 a client sees a republish (assets replaced in place) and upgrades
#  A5 what a client sees mid-republish (new Packages, old InRelease)
#  A6 what GitHub does to an asset name holding '~' and '+'
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
TAG=apt-repo
BASE="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/"
clients=(debian:13 ubuntu:26.04)

table "APT flat repository on release assets"
sudo apt-get install -y --no-install-recommends apt-utils >/dev/null
make_key
gpg --export "$KEY_FPR" > xd-spike.gpg

debs=$(mktemp -d)
check "build the .debs in debian:13 (dpkg-shlibdeps Depends)" \
    docker run --rm -v "$PWD:/w" -v "$debs:/o" -w /w debian:13 bash spike/mkdeb.sh /o
note "Depends: $(dpkg-deb -f "$debs/xd-spike-daemon_1.0-1_amd64.deb" Depends)"

# index <dir>: Packages{,.gz,.xz}, Release, InRelease, Release.gpg for the .debs in <dir>.
index() {
    (
        cd "$1" || exit 1
        apt-ftparchive packages . | sed 's|^Filename: \./|Filename: |' > Packages
        gzip -9kf Packages
        xz -kf Packages
        apt-ftparchive \
            -o APT::FTPArchive::Release::Origin=xd-spike \
            -o APT::FTPArchive::Release::Label=xd-spike \
            -o APT::FTPArchive::Release::Architectures="amd64 all" \
            release . > Release
        rm -f InRelease Release.gpg
        gpg --batch --yes --clearsign -o InRelease Release
        gpg --batch --yes -abs -o Release.gpg Release
    )
}

repo=$(mktemp -d)
cp "$debs/xd-spike-daemon_1.0-1_amd64.deb" "$debs"/xd-spike-odd_*.deb "$repo/"
index "$repo"

gh release delete "$TAG" --yes --cleanup-tag >/dev/null 2>&1 || true
check "create release $TAG" gh release create "$TAG" --title "APT spike (throwaway)" \
    --notes "Throwaway APT flat-repository experiment. Not a real repository." --latest=false
check "upload v1 repository" gh release upload "$TAG" "$repo"/* xd-spike.gpg

stored=$(gh release view "$TAG" --json assets --jq '.assets[].name' | grep '^xd-spike-odd' || true)
note "A6: asset uploaded as xd-spike-odd_1.0~rc1+b1-1_all.deb is stored as: $stored"

redirect_host() {
    curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "${BASE}InRelease" | sed -E 's|(https://[^/]+)/.*|\1/…|'
}
note "A1: GET ${BASE}InRelease → $(redirect_host)"

# Clients: the distribution's ca-certificates first, then the spike source.
setup_client() {
    local img=$1 name=$2
    docker run -d --name "$name" -v "$PWD:/w:ro" "$img" sleep infinity >/dev/null
    docker exec "$name" bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null
        install -Dm644 /w/xd-spike.gpg /etc/apt/keyrings/xd-spike.gpg
        cat > /etc/apt/sources.list.d/xd-spike.sources <<EOF
Types: deb
URIs: '"$BASE"'
Suites: ./
Signed-By: /etc/apt/keyrings/xd-spike.gpg
EOF
        apt --version | head -1'
}

for img in "${clients[@]}"; do
    name=c-${img//[:.]/-}
    check "$img: client ready" setup_client "$img" "$name"
    check "$img A1/A2: apt-get update over the redirect, InRelease verified" \
        docker exec "$name" bash -euc 'apt-get update -o Debug::Acquire::https=true 2>&1 \
            | grep -E "^(Get|Hit|Ign|Err|W:|E:)|HTTP/1.1 30|^Location" | sed -E "s/\?.*//"; \
            apt-get update 2>&1 | grep -E "^(W|E):" && exit 1 || true'
    check "$img A3: install xd-spike-daemon 1.0-1 and run it" \
        docker exec "$name" bash -euc 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q xd-spike-daemon \
            && dpkg-query -W xd-spike-daemon && ventulusd --version && ventulus-tray --version'
    check "$img A6: install the package with ~ and + in its version" \
        docker exec "$name" bash -euc 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q xd-spike-odd \
            && dpkg-query -W xd-spike-odd'
done

# Republish: new .deb first, then the indices, InRelease last (the planned order).
cp "$debs/xd-spike-daemon_2.0-1_amd64.deb" "$repo/"
index "$repo"
check "upload the v2 .deb" gh release upload "$TAG" "$repo/xd-spike-daemon_2.0-1_amd64.deb"
start=$(date +%s)
check "replace Packages* (old InRelease still served)" \
    gh release upload "$TAG" --clobber "$repo/Packages" "$repo/Packages.gz" "$repo/Packages.xz"
mid=$(docker exec c-debian-13 apt-get update 2>&1 | grep -E '^(E|W):' | head -3 | tr '\n' ' ')
note "A5: apt-get update between the Packages and InRelease uploads: ${mid:-no error or warning}"
check "replace Release, Release.gpg, InRelease" \
    gh release upload "$TAG" --clobber "$repo/Release" "$repo/Release.gpg" "$repo/InRelease"
note "A5: index replacement window was $(( $(date +%s) - start )) s"

for img in "${clients[@]}"; do
    name=c-${img//[:.]/-}
    check "$img A4: apt-get update && upgrade reaches 2.0-1" \
        docker exec "$name" bash -euc 'apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q \
            && test "$(dpkg-query -W -f="\${Version}" xd-spike-daemon)" = 2.0-1'
done

finish

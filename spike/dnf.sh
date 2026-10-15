#!/bin/bash
# Signed DNF repository on GitHub Pages, as DEC-499 plans for pacman-repo.
# Runs on the runner host in several steps around two Pages deployments:
#   dnf.sh build <1|2>    build (and sign) the site for version N into ./site
#   dnf.sh client-v1 URL  a fedora:44 client installs 1.0
#   dnf.sh client-v2 URL  the same client upgrades right after the v2 deploy
#
# Questions:
#  D1 ed25519-signed RPMs and repomd.xml verify under dnf5 (gpgcheck, repo_gpgcheck),
#     and repo_gpgcheck really refuses metadata signed by another key
#  D2 an existing client upgrades right after a redeploy that drops the old metadata
#  D3 Pages' cache headers, and whether a stale repomd.xml is served after a deploy
#  D4 where Fedora 44 ships gpg and gpgv
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

export GNUPGHOME=$RUNNER_TEMP/gnupg
rpms=$RUNNER_TEMP/rpms
state=$RUNNER_TEMP/dnf-state
mkdir -p "$rpms" "$state"
client=dnfc

build() {
    local n=$1 version
    version="$n.0"
    table "DNF repository on Pages — build v$version"
    make_key
    gpg --armor --export "$KEY_FPR" > "$state/RPM-GPG-KEY-xd-spike"
    if [ ! -d "$state/wrong" ]; then
        # A second key, for the negative repo_gpgcheck test. A subshell, so the
        # signing key's GNUPGHOME and KEY_FPR are untouched.
        (
            GNUPGHOME=$state/wrong
            make_key >/dev/null
            gpg --armor --export > "$state/RPM-GPG-KEY-wrong"
        )
    fi

    sudo rm -rf site
    mkdir -p site/rpm
    check "build, sign and index xd-spike-daemon-$version in fedora:44" \
        docker run --rm -v "$PWD:/w" -v "$rpms:/rpms" -v "$GNUPGHOME:/gnupg" -v "$PWD/site:/site" \
            -e GNUPGHOME=/gnupg -e KEY_FPR="$KEY_FPR" -e VERSION="$version" \
            -e OWNER="$(id -u):$(id -g)" -w /w fedora:44 bash -euc '
            trap "chown -R \$OWNER /site /rpms /gnupg" EXIT
            dnf -y -q install rpm-build rpm-sign createrepo_c gnupg2 systemd-rpm-macros
            rpm --version; gpg --version | head -1
            mkdir -p /tmp/src && cp out/* /tmp/src/
            rpmbuild -bb --define "_sourcedir /tmp/src" --define "_rpmdir /tmp/rpms" \
                --define "spike_version $VERSION" spike/xd-spike-daemon.spec
            find /tmp/rpms -name "*.rpm" -exec cp {} /rpms/ \;
            rpmsign --define "_gpg_name $KEY_FPR" --addsign /rpms/*.rpm
            cp /rpms/*.rpm /site/rpm/
            createrepo_c --general-compress-type=zstd /site/rpm
            gpg --batch --yes --detach-sign --armor /site/rpm/repodata/repomd.xml
            {
                echo "D4: gnupg2 ships $(rpm -ql gnupg2 | grep -E "/s?bin/gpgv?$" | tr "\n" " ")"
                echo "D4: /usr/bin/gpgv is provided by: $(dnf -q repoquery --whatprovides /usr/bin/gpgv 2>/dev/null | tr "\n" " ")"
                echo "Requires: $(rpm -qp --requires /rpms/*-$VERSION-1.*.rpm | tr "\n" " ")"
                echo "Built: $(cd /site/rpm && ls *.rpm | tr "\n" " ")"
            } | tee /rpms/facts.txt'
    while read -r line; do note "$line"; done < "$rpms/facts.txt"
    cp "$state/RPM-GPG-KEY-xd-spike" "$state/RPM-GPG-KEY-wrong" site/rpm/
    # A copy whose repomd.xml no longer matches its signature (D1, tampering).
    cp -r site/rpm site/rpm-tampered
    sed -i 's|</repomd>|<!-- tampered --></repomd>|' site/rpm-tampered/repodata/repomd.xml
    ls -R site
    finish
}

repo_file() {
    local url=$1 id=$2 key=$3 dir=${4:-rpm}
    cat <<EOF
[$id]
name=$id (throwaway spike)
baseurl=${url%/}/$dir/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${url%/}/rpm/$key
EOF
}

headers() {
    curl -sI "${1%/}/rpm/repodata/repomd.xml" | grep -iE '^(cache-control|age|x-cache|etag|last-modified|x-served-by):' | tr -d '\r' | tr '\n' ' '
}

primary_href() {
    curl -s "${1%/}/rpm/repodata/repomd.xml" | grep -o 'href="repodata/[^"]*primary[^"]*"' | head -1
}

wait_for() {
    local url=$1 want=$2 i
    for i in $(seq 60); do
        [ "$(primary_href "$url")" = "$want" ] && { echo "served after $((i * 5)) s"; return 0; }
        sleep 5
    done
    return 1
}

client_v1() {
    local url=$1
    table "DNF repository on Pages — client, v1"
    local want
    want=$(grep -o 'href="repodata/[^"]*primary[^"]*"' site/rpm/repodata/repomd.xml | head -1)
    check "Pages serves the v1 repomd.xml" wait_for "$url" "$want"
    echo "$want" > "$state/v1-primary"
    note "D3: v1 repomd.xml headers: $(headers "$url")"
    docker run -d --name "$client" fedora:44 sleep infinity >/dev/null
    repo_file "$url" xd-spike RPM-GPG-KEY-xd-spike | docker exec -i "$client" tee /etc/yum.repos.d/xd-spike.repo
    check "D1: dnf5 installs xd-spike-daemon 1.0 with gpgcheck and repo_gpgcheck" \
        docker exec "$client" bash -euc 'dnf --version | head -2; dnf -y install xd-spike-daemon \
            && rpm -q xd-spike-daemon && ventulusd --version && rpm -q --qf "%{SIGPGP:pgpsig}\n" xd-spike-daemon'
    # Negative tests, each in a FRESH client so no earlier import of the right key
    # can satisfy the check (run 2: dnf5 printed a signature error, then loaded
    # the metadata and exited 0, in a client that already trusted the right key).
    #   wrong:    the repository under a key that did not sign it
    #   tampered: the right key, but repomd.xml no longer matches its signature
    # Each must fail to load the metadata AND fail to install.
    refused() {
        local id=$1 key=$2 dir=$3 c="dnf-$1" out rc=0 avail
        docker run -d --name "$c" fedora:44 sleep infinity >/dev/null
        repo_file "$url" "$id" "$key" "$dir" | docker exec -i "$c" tee "/etc/yum.repos.d/$id.repo" >/dev/null
        out=$(docker exec "$c" dnf -y --repo "$id" makecache --refresh 2>&1) || rc=$?
        echo "$out" | tail -12
        avail=$(docker exec "$c" dnf -q --repo "$id" repoquery xd-spike-daemon 2>&1 | tail -3)
        echo "makecache exit $rc; repoquery sees: ${avail:-nothing}"
        note "D1 $id: makecache exit $rc; repoquery sees: $(echo "${avail:-nothing}" | tr '\n' ' ')"
        if docker exec "$c" dnf -y --repo "$id" install xd-spike-daemon >/tmp/$c.install 2>&1; then
            note "D1 $id: dnf INSTALLED the package"
            return 1
        fi
        note "D1 $id: install refused: $(grep -iE 'signature|openpgp|gpg|key|error' /tmp/$c.install | head -2 | tr '\n' ' ' | cut -c1-300)"
        [ "$rc" != 0 ]
    }
    check "D1: metadata signed by another key is refused" refused xd-wrong RPM-GPG-KEY-wrong rpm
    check "D1: tampered repomd.xml under the right key is refused" refused xd-tampered RPM-GPG-KEY-xd-spike rpm-tampered
    finish
}

client_v2() {
    local url=$1 want old i ok=""
    table "DNF repository on Pages — client, after the v2 redeploy"
    want=$(grep -o 'href="repodata/[^"]*primary[^"]*"' site/rpm/repodata/repomd.xml | head -1)
    old=$(cat "$state/v1-primary")
    note "D3: first repomd.xml after the deploy: $( [ "$(primary_href "$url")" = "$want" ] && echo new || echo STALE ); headers: $(headers "$url")"
    for i in $(seq 24); do
        if docker exec "$client" dnf -y upgrade --refresh xd-spike-daemon >/tmp/dnf-upgrade.log 2>&1 \
            && docker exec "$client" rpm -q xd-spike-daemon | grep -q -- '-2\.0-'; then
            ok=$(( (i - 1) * 30 ))
            break
        fi
        tail -3 /tmp/dnf-upgrade.log
        sleep 30
    done
    cat /tmp/dnf-upgrade.log
    if [ -n "$ok" ]; then
        note "D2: the existing client upgraded to 2.0 ${ok} s after the deploy finished"
        echo "| ✅ | D2: existing client upgrades after a redeploy |" >> "$summary"
    else
        echo "| ❌ | D2: existing client did not upgrade within 12 min |" >> "$summary"
        failures=$((failures + 1))
    fi
    old_url="${url%/}/rpm/$(echo "$old" | sed -E 's/href="(.*)"/\1/')"
    note "D2: the v1 primary metadata now returns HTTP $(curl -s -o /dev/null -w '%{http_code}' "$old_url")"
    stale=0
    for i in $(seq 12); do
        [ "$(primary_href "$url")" = "$want" ] || stale=$((stale + 1))
        sleep 5
    done
    note "D3: stale repomd.xml in $stale of 12 fetches over the next minute"
    finish
}

case ${1:-} in
    build) build "$2" ;;
    client-v1) client_v1 "$2" ;;
    client-v2) client_v2 "$2" ;;
    *) echo "usage: $0 build N | client-v1 URL | client-v2 URL" >&2; exit 2 ;;
esac

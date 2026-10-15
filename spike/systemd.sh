#!/bin/bash
# The shipped, hardened ventulusd.service under systemd as PID 1 in a privileged
# podman container on a GitHub runner. Run as root: spike/systemd.sh <image>
#
# Questions:
#  S1 systemd boots in the container and the unit's sandbox directives apply
#     (Type=notify start reaches READY, GET /status answers on the socket)
#  S2 ExecStopPost replays a planted hand-back record on stop, restart and
#     SIGKILL, against a fake sysfs tree (VENTULUS_SYSFS_ROOT, test-only drop-in)
# No profile is active, so the daemon writes nothing to the runner's real /sys.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

img=$1
c=sd
table "systemd in a privileged container — $img"

case $img in
    debian:* | ubuntu:*)
        setup='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus curl ca-certificates procps >/dev/null'
        ;;
    fedora:*)
        setup='dnf -y -q install systemd curl procps-ng'
        ;;
esac

ctx=$(mktemp -d)
cat > "$ctx/Containerfile" <<EOF
FROM $img
RUN $setup
CMD ["/sbin/init"]
EOF
check "build the systemd image" podman build -q -t spike-systemd "$ctx"
check "start it with systemd as PID 1" \
    podman run -d --name "$c" --privileged --systemd=always -v "$PWD/out:/spike:ro" spike-systemd

booted() {
    local i s
    for i in $(seq 90); do
        s=$(podman exec "$c" systemctl is-system-running 2>/dev/null)
        case $s in running | degraded) echo "$s after ${i}s"; return 0 ;; esac
        sleep 1
    done
    echo "still: $s"
    return 1
}
check "systemd reaches running/degraded" booted
note "$(podman exec "$c" systemctl --version | head -1); failed units: $(podman exec "$c" systemctl --failed --plain --no-legend | awk '{print $1}' | tr '\n' ' ')"

check "install the 5.1.0 daemon, restore script, unit and config by hand" podman exec "$c" bash -euc '
    install -Dm755 /spike/ventulusd /usr/bin/ventulusd
    install -Dm755 /spike/ventulus-restore-auto.sh /usr/bin/ventulus-restore-auto
    install -Dm644 /spike/ventulusd.service /usr/lib/systemd/system/ventulusd.service
    install -Dm644 /spike/daemon.toml.example /etc/ventulus/daemon.toml
    systemctl daemon-reload'

check "S1: systemctl start ventulusd (Type=notify) succeeds" podman exec "$c" systemctl start ventulusd
check "S1: the unit is active" podman exec "$c" systemctl is-active ventulusd
check "S1: GET /status answers on /run/ventulus/ventulus.sock" podman exec "$c" bash -euc \
    'curl -sf --unix-socket /run/ventulus/ventulus.sock http://localhost/status | head -c 400; echo'
note "S1: $(podman exec "$c" systemctl show ventulusd -p Type,NotifyAccess,WatchdogUSec,NRestarts,Result | tr '\n' ' ')"
note "S1: journal warnings: $(podman exec "$c" journalctl -u ventulusd -o cat --no-pager -p warning | head -5 | tr '\n' ' ' | cut -c1-400)"
note "S1: sandbox: $(podman exec "$c" bash -c 'p=$(systemctl show -p MainPID --value ventulusd); grep -E "^(Seccomp|NoNewPrivs):" /proc/$p/status | tr "\n" " "; readlink /proc/$p/ns/net')"

check "S2: test-only drop-in points the restore script at a fake sysfs tree" podman exec "$c" bash -euc '
    mkdir -p /etc/systemd/system/ventulusd.service.d /srv/fakesys/devices/platform/spike.0/hwmon/hwmon9
    printf "[Service]\nEnvironment=VENTULUS_SYSFS_ROOT=/srv/fakesys\nReadWritePaths=/srv/fakesys\n" \
        > /etc/systemd/system/ventulusd.service.d/spike.conf
    systemctl daemon-reload
    systemctl restart ventulusd'

# replayed <how>: plant a record saying "this header was in mode 2", leave the
# header in manual mode (1) at duty 77, do <how>, then require mode 2 back and
# the record gone.
replayed() {
    podman exec "$c" bash -euc '
        h=/srv/fakesys/devices/platform/spike.0/hwmon/hwmon9
        systemctl is-active -q ventulusd || systemctl start ventulusd
        echo 1 > $h/pwm1_enable; echo 77 > $h/pwm1
        printf "# planted by the spike\n%s\t%s\tmode\t2\n" $h/pwm1_enable $h/pwm1 > /run/ventulus/hwmon-handback
        '"$1"'
        for i in $(seq 20); do [ "$(cat $h/pwm1_enable)" = 2 ] && break; sleep 0.5; done
        echo "pwm1_enable=$(cat $h/pwm1_enable) record=$(test -e /run/ventulus/hwmon-handback && echo present || echo removed)"
        test "$(cat $h/pwm1_enable)" = 2'
}
check "S2: systemctl stop replays the record" replayed 'systemctl stop ventulusd'
check "S2: systemctl restart replays the record" replayed 'systemctl restart ventulusd'
# Only the main process, as a crash or the OOM killer would: `systemctl kill`
# signals the whole cgroup by default, and in run 1 that also killed the
# ExecStopPost it had just started ("Control process exited, code=killed").
check "S2: SIGKILL of the main process replays the record (ExecStopPost after a crash)" \
    replayed 'kill -KILL "$(systemctl show -p MainPID --value ventulusd)"'
check "S2: after SIGKILL, Restart=on-failure brings the daemon back" podman exec "$c" bash -c '
    for i in $(seq 20); do systemctl is-active -q ventulusd && exit 0; sleep 1; done; systemctl status ventulusd --no-pager; exit 1'
note "S2: $(podman exec "$c" systemctl show ventulusd -p NRestarts | tr '\n' ' ')"

podman exec "$c" journalctl -u ventulusd --no-pager -n 80 || true
finish

#!/bin/bash
# A Fedora 44 cloud guest under KVM on a GitHub runner, SELinux enforcing,
# installing xd-spike-daemon from the spike's DNF repository on Pages.
# Usage: spike/kvm.sh <pages url>
#
# Questions:
#  K1 /dev/kvm can be enabled on a GitHub-hosted runner and a guest boots
#  K2 the rpm installs from the Pages repo; Fedora's preset leaves the unit disabled;
#     enabled and started it runs as unconfined_service_t with no AVC denials
#  K3 the hand-back replay works under SELinux enforcing
#  K4 after a reboot the enabled unit is active again, still no AVC denials
#  K5 dnf remove stops the unit and keeps an edited config as .rpmsave
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

url=${1%/}
image=Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2
mirror=https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images
vm=$(mktemp -d)
table "Fedora 44 KVM guest, SELinux enforcing"

enable_kvm() {
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
        | sudo tee /etc/udev/rules.d/99-kvm4all.rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=kvm
    ls -l /dev/kvm && test -w /dev/kvm
}
tools() {
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils >/dev/null
}
fetch() {
    curl -sSfL -o "$vm/$image" "$mirror/$image"
    curl -sSfL -o "$vm/CHECKSUM" "$mirror/Fedora-Cloud-44-1.7-x86_64-CHECKSUM"
    (cd "$vm" && grep "($image)" CHECKSUM | sed -E 's/^SHA256 \((.*)\) = (.*)$/\2  \1/' | sha256sum -c -)
}
boot() {
    ssh-keygen -q -t ed25519 -N '' -f "$vm/id"
    printf '#cloud-config\nusers:\n  - name: spike\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys: [%s]\n' \
        "$(cat "$vm/id.pub")" > "$vm/user-data"
    cloud-localds "$vm/seed.img" "$vm/user-data"
    qemu-img create -q -f qcow2 -b "$vm/$image" -F qcow2 "$vm/disk.qcow2" 10G
    qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
        -drive "file=$vm/disk.qcow2,if=virtio" -drive "file=$vm/seed.img,if=virtio,format=raw" \
        -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
        -display none -serial "file:$vm/serial.log" -daemonize
}
# g <command>: run in the guest; a script can come on stdin (g 'sudo bash -eux -s' <<EOF).
g() {
    ssh -q -i "$vm/id" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o BatchMode=yes spike@127.0.0.1 "$@"
}
wait_ssh() {
    local i
    for i in $(seq 60); do
        g true </dev/null 2>/dev/null && { echo "ssh up after $((i * 5)) s"; return 0; }
        sleep 5
    done
    tail -40 "$vm/serial.log"
    return 1
}
reboot_guest() {
    local before after
    before=$(g 'cat /proc/sys/kernel/random/boot_id' </dev/null)
    g 'sudo systemctl reboot' </dev/null || true
    sleep 15
    wait_ssh || return 1
    after=$(g 'cat /proc/sys/kernel/random/boot_id' </dev/null)
    echo "boot_id $before → $after"
    [ -n "$after" ] && [ "$before" != "$after" ]
}
no_ventulus_avcs() {
    local out
    out=$(g 'sudo ausearch -m AVC,USER_AVC,SELINUX_ERR -ts boot 2>&1' </dev/null)
    echo "$out" | tail -20
    ! echo "$out" | grep -qi ventulus
}

check "K1: enable /dev/kvm on the runner" enable_kvm
check "install qemu and cloud-localds" tools
check "download and checksum the cloud image" fetch
check "K1: boot the guest with -enable-kvm" boot
check "K1: the guest answers on ssh" wait_ssh
note "K1: guest $(g 'uname -r; getenforce; systemctl --version | head -1' </dev/null | tr '\n' ' ')"

check "K2: SELinux is enforcing" g 'test "$(getenforce)" = Enforcing' </dev/null
check "K2: dnf installs xd-spike-daemon from the Pages repository" g 'sudo bash -eux -s' <<EOF
cat > /etc/yum.repos.d/xd-spike.repo <<'REPO'
[xd-spike]
name=xd-spike (throwaway spike)
baseurl=$url/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$url/rpm/RPM-GPG-KEY-xd-spike
REPO
dnf -y -q --repo xd-spike install xd-spike-daemon
rpm -q xd-spike-daemon
EOF
note "K2: after install the unit is $(g 'systemctl is-enabled ventulusd; systemctl is-active ventulusd' </dev/null | tr '\n' '/') (Fedora's preset should leave it disabled/inactive)"
check "K2: enable --now" g 'sudo systemctl enable --now ventulusd && systemctl is-active ventulusd' </dev/null
note "K2: process context: $(g 'ps -eZ | grep -w ventulusd' </dev/null | awk '{print $1}')"
note "K2: file contexts: $(g 'ls -Z /usr/bin/ventulusd /usr/bin/ventulus-restore-auto /usr/lib/systemd/system/ventulusd.service' </dev/null | awk '{print $1}' | tr '\n' ' ')"
check "K2: GET /status answers" g 'curl -sf --unix-socket /run/ventulus/ventulus.sock http://localhost/status | head -c 300; echo' </dev/null
check "K2: no AVC denials naming ventulus" no_ventulus_avcs

check "K3: hand-back replay under SELinux enforcing (stop)" g 'sudo bash -eux -s' <<'EOF'
h=/srv/fakesys/devices/platform/spike.0/hwmon/hwmon9
mkdir -p /etc/systemd/system/ventulusd.service.d "$h"
printf '[Service]\nEnvironment=VENTULUS_SYSFS_ROOT=/srv/fakesys\nReadWritePaths=/srv/fakesys\n' \
    > /etc/systemd/system/ventulusd.service.d/spike.conf
systemctl daemon-reload
systemctl restart ventulusd
echo 1 > "$h/pwm1_enable"; echo 77 > "$h/pwm1"
printf '# planted by the spike\n%s\t%s\tmode\t2\n' "$h/pwm1_enable" "$h/pwm1" > /run/ventulus/hwmon-handback
systemctl stop ventulusd
cat "$h/pwm1_enable"
test "$(cat "$h/pwm1_enable")" = 2
rm -r /etc/systemd/system/ventulusd.service.d
systemctl daemon-reload
systemctl start ventulusd
EOF

check "K4: reboot, and the guest comes back" reboot_guest
check "K4: the enabled unit is active after the reboot" \
    g 'for i in $(seq 30); do systemctl is-active -q ventulusd && exit 0; sleep 1; done; systemctl status ventulusd --no-pager; exit 1' </dev/null
note "K4: process context after reboot: $(g 'ps -eZ | grep -w ventulusd' </dev/null | awk '{print $1}')"
check "K4: still no AVC denials naming ventulus" no_ventulus_avcs

check "K5: dnf remove stops the unit and keeps the edited config" g 'sudo bash -eux -s' <<'EOF'
echo '# edited by the spike' >> /etc/ventulus/daemon.toml
dnf -y -q remove xd-spike-daemon
if systemctl is-active -q ventulusd; then echo "still active after remove"; exit 1; fi
ls -l /etc/ventulus/
test -e /etc/ventulus/daemon.toml.rpmsave
EOF

g 'sudo journalctl -u ventulusd --no-pager -n 40' </dev/null || true
finish

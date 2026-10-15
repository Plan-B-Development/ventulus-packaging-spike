#!/bin/bash
# The GUI 5.1.0 test suite on one distribution's own Python and Qt packages, no
# pip. Runs as root inside the distribution's container; the suite itself runs
# as an unprivileged user, as a desktop user would.
#
# Questions:
#  G1 every runtime and test dependency exists as a distribution package
#  G2 the suite passes on them (Debian 13: Python 3.13, PySide6 6.8, pyqtgraph 0.13.7)
#  G3 which Qt binding pyqtgraph would pull in alongside PySide6
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

distro=$(. /etc/os-release && echo "$ID $VERSION_ID")
table "GUI suite on distribution packages — $distro"

case $distro in
    debian* | ubuntu*)
        deps() {
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -q --no-install-recommends git ca-certificates python3 \
                python3-pyside6.qtcore python3-pyside6.qtgui python3-pyside6.qtwidgets \
                python3-pyside6.qtnetwork python3-pyside6.qttest python3-pyside6.qtsvg \
                python3-pyqtgraph python3-numpy python3-httpx python3-colorama \
                python3-pytest python3-pytestqt python3-pytest-timeout python3-yaml \
                libegl1 libgl1 libxkbcommon0 fonts-dejavu-core fish zsh
            # Run 1: pyqtgraph needs PySide6.QtOpenGL on Ubuntu, and the app icon
            # (SVG) was null on Debian. Install whichever of these exist.
            local extra=() p
            for p in python3-pyside6.qtopengl python3-pyside6.qtopenglwidgets qt6-svg-plugins; do
                apt-cache show "$p" >/dev/null 2>&1 && extra+=("$p")
            done
            echo "extra packages available: ${extra[*]}"
            apt-get install -y -q --no-install-recommends "${extra[@]}"
            echo "Qt6 SVG packages: $(apt-cache search --names-only 'qt6.*svg' | cut -d' ' -f1 | tr '\n' ' ')"
            echo "python3-pyqtgraph Depends: $(apt-cache depends python3-pyqtgraph | grep -E '^\s+(\|)?Depends' | tr -s ' ' | tr '\n' ' ')"
        }
        ;;
    fedora*)
        deps() {
            dnf -y -q install --setopt=install_weak_deps=False git python3 python3-pyside6 \
                python3-pyqtgraph python3-numpy python3-httpx python3-colorama \
                python3-pytest python3-pytest-qt python3-pytest-timeout python3-pyyaml \
                mesa-libEGL mesa-libGL libxkbcommon dejavu-sans-fonts fish zsh
            echo "python3-pyqtgraph requires: $(rpm -q --requires python3-pyqtgraph | tr '\n' ' ')"
        }
        ;;
esac

check "G1: install the runtime and test dependencies from $distro" deps
note "G1: $(python3 -c 'import sys, PySide6, pyqtgraph, numpy, httpx; print(f"Python {sys.version.split()[0]}, PySide6 {PySide6.__version__}, pyqtgraph {pyqtgraph.__version__}, numpy {numpy.__version__}, httpx {httpx.__version__}")' 2>&1)"
note "G3: Qt bindings installed: $(python3 -c 'import importlib.util as u; print(" ".join(m for m in ("PyQt5", "PyQt6", "PySide2", "PySide6") if u.find_spec(m)))' 2>&1)"

check "fetch ventulus v5.1.0" git clone -q --depth 1 --branch v5.1.0 https://github.com/Plan-B-Development/ventulus.git /tmp/ventulus
# Run 1: without installed metadata the GUI's version is "dev", which turns the
# version-floor checks off, so their two tests fail. A package installs this
# .dist-info; the shim gives a checkout the same answer.
mkdir -p /tmp/ventulus/src/ventulus-5.1.0.dist-info
printf 'Metadata-Version: 2.1\nName: ventulus\nVersion: 5.1.0\n' > /tmp/ventulus/src/ventulus-5.1.0.dist-info/METADATA
note "G2: GUI version as the suite sees it: $(cd /tmp/ventulus && PYTHONPATH=src python3 -c 'from ventulus.constants import APP_VERSION; print(APP_VERSION)' 2>&1 | tail -1)"
useradd -m -s /bin/bash tester 2>/dev/null || true
chown -R tester: /tmp/ventulus
check "G2: the suite passes (offscreen, as an unprivileged user)" su tester -c \
    'cd /tmp/ventulus && QT_QPA_PLATFORM=offscreen PYTHONPATH=src python3 -m pytest tests -q -p no:cacheprovider --tb=short -o timeout=120 2>&1 | tail -60; exit ${PIPESTATUS[0]}'
finish

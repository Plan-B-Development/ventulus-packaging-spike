# ventulus-packaging-spike — throwaway

A short-lived experiment for Ventulus DEC-499 phase 0 (`XD-0`). It checks, on
GitHub's own runners, whether the planned Debian/Ubuntu/Fedora packaging can
work before any real packaging is written:

- a flat APT repository served from GitHub release assets (`apt` job);
- a signed DNF repository on GitHub Pages, including a redeploy (`dnf` job);
- the hardened `ventulusd.service` under systemd in privileged containers, with
  the hand-back replayed on stop, restart and SIGKILL (`systemd` job);
- a Fedora 44 KVM guest with SELinux enforcing, installing from the DNF
  repository and rebooting (`kvm` job);
- the GUI test suite on each distribution's own Python/Qt packages (`gui` job).

**Nothing here is a supported package or repository.** Every key is generated
inside a job and thrown away with it; the packages are named `xd-spike-*` and
carry the released 5.1.0 binaries only so the tests have something real to run.
This repository will be deleted when the experiment is over.

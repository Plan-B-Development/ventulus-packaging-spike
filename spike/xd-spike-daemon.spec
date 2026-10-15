# Throwaway: packages the prebuilt ventulusd 5.1.0 binaries so the spike has a
# real service to install. The real spec builds from source (DEC-499 phase 3).
%global debug_package %{nil}

Name:           xd-spike-daemon
Version:        %{spike_version}
Release:        1%{?dist}
Summary:        Ventulus packaging spike (throwaway)
License:        MIT
ExclusiveArch:  x86_64
Source0:        ventulusd
Source1:        ventulus-tray
Source2:        ventulus-restore-auto.sh
Source3:        ventulusd.service
Source4:        daemon.toml.example
BuildRequires:  systemd-rpm-macros
%{?systemd_requires}

%description
Carries the ventulusd 5.1.0 binaries for a repository experiment. Not for use.

%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_bindir}/ventulusd
install -Dm755 %{SOURCE1} %{buildroot}%{_bindir}/ventulus-tray
install -Dm755 %{SOURCE2} %{buildroot}%{_bindir}/ventulus-restore-auto
install -Dm644 %{SOURCE3} %{buildroot}%{_unitdir}/ventulusd.service
install -Dm644 %{SOURCE4} %{buildroot}%{_sysconfdir}/ventulus/daemon.toml

%post
%systemd_post ventulusd.service

%preun
%systemd_preun ventulusd.service

%postun
%systemd_postun_with_restart ventulusd.service

%files
%{_bindir}/ventulusd
%{_bindir}/ventulus-tray
%{_bindir}/ventulus-restore-auto
%{_unitdir}/ventulusd.service
%dir %{_sysconfdir}/ventulus
%config(noreplace) %{_sysconfdir}/ventulus/daemon.toml

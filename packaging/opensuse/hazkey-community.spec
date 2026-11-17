#
# spec file for package hazkey-community
#
# Copyright (c) 2026 presire
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.
#

# Swift toolchain from devel:tools:compiler. The SwiftPM vendor tarball
# (Source1) must be generated with exactly this version.
%define swift_version 6.4.1
%define __builder ninja
# Everything under %%{_libdir}/hazkey-community is private: the bundled Swift
# runtime and the llama.cpp/ggml libraries must neither be provided to nor
# requested from the rest of the distribution.
%global __provides_exclude_from ^%{_libdir}/hazkey-community/.*$
%global __requires_exclude ^lib(swift|_swift|Foundation|_Foundation|dispatch|BlocksRuntime|llama|ggml).*\\.so.*$
Name:           hazkey-community
Version:        0.2.47
Release:        0
Summary:        Japanese input method with neural kana-kanji conversion
# hazkey: MIT; AzooKeyKanaKanjiConverter, Jinja, llama.cpp: MIT;
# swift-* packages and the bundled Swift runtime: Apache-2.0 WITH Swift-exception;
# swift-tokenizers: Apache-2.0; SwiftyMarisa/marisa-trie: BSD-2-Clause OR LGPL-2.1-or-later;
# dictionaries: Apache-2.0 AND BSD-3-Clause AND CC0-1.0 AND Unicode-3.0;
# EfficientNGram tokenizer data: CC-BY-SA-4.0
License:        MIT AND Apache-2.0 AND Apache-2.0 WITH Swift-exception AND (BSD-2-Clause OR LGPL-2.1-or-later) AND BSD-3-Clause AND CC0-1.0 AND Unicode-3.0 AND CC-BY-SA-4.0 AND ICU AND NAIST-2003
URL:            https://github.com/presire/hazkey-community
# osc service manualrun (tar_scm with submodules + recompress)
Source0:        %{name}-%{version}.tar.zst
# ./make-swiftpm-vendor.sh (SwiftPM checkouts + workspace state, offline build)
Source1:        %{name}-swiftpm-vendor-%{version}.tar.zst
Source2:        make-swiftpm-vendor.sh
# Full ICU 76.1 notice, including double-conversion and embedded dictionary data.
# https://raw.githubusercontent.com/unicode-org/icu/release-76-1/LICENSE
Source3:        ICU-76.1-LICENSE.txt
BuildRequires:  cmake >= 3.21
BuildRequires:  fcitx5-devel >= 5.0.4
BuildRequires:  gcc-c++
BuildRequires:  gettext-tools
BuildRequires:  git-core
BuildRequires:  glslang-devel
BuildRequires:  hicolor-icon-theme
BuildRequires:  ninja
BuildRequires:  patchelf
BuildRequires:  pkgconfig
BuildRequires:  python3
BuildRequires:  qt6-base-devel >= 6.7
BuildRequires:  qt6-linguist-devel
BuildRequires:  shaderc
BuildRequires:  spirv-headers
BuildRequires:  swift-lang = %{swift_version}
BuildRequires:  vulkan-headers
BuildRequires:  zstd
BuildRequires:  pkgconfig(ibus-1.0)
BuildRequires:  pkgconfig(protobuf-lite) >= 3.12
BuildRequires:  pkgconfig(vulkan)
# SELinux module
BuildRequires:  bzip2
BuildRequires:  checkpolicy
BuildRequires:  policycoreutils
BuildRequires:  selinux-policy-devel
# swift-lang is only built for these; the package targets x86_64 only
ExclusiveArch:  x86_64

%description
Hazkey is a Japanese input method based on the azooKey kana-kanji
converter, with optional neural conversion (Zenzai) through llama.cpp
and a Vulkan backend.

This package contains the conversion server, the settings application
and the dictionaries shared by the Fcitx5 and IBus frontends.

%package -n fcitx5-hazkey-community
Summary:        Fcitx5 frontend for the Hazkey Japanese input method
Requires:       %{name} = %{version}-%{release}
Requires:       fcitx5

%description -n fcitx5-hazkey-community
Fcitx5 addon for Hazkey, a Japanese input method with neural
kana-kanji conversion.

%package -n ibus-hazkey-community
Summary:        IBus frontend for the Hazkey Japanese input method
Requires:       %{name} = %{version}-%{release}
Requires:       ibus

%description -n ibus-hazkey-community
IBus engine for Hazkey, a Japanese input method with neural
kana-kanji conversion.

%package selinux
Summary:        SELinux policy module for Hazkey
Requires:       %{name} = %{version}-%{release}
Requires:       selinux-policy-targeted
%selinux_requires
Requires(pre):  libselinux-utils
Requires(pre):  policycoreutils
Requires(preun): libselinux-utils
Requires(preun): policycoreutils
Requires(postun): libselinux-utils
Requires(postun): policycoreutils
Requires(posttrans): libselinux-utils
Requires(posttrans): policycoreutils
BuildArch:      noarch

%description selinux
SELinux policy module confining the Hazkey conversion server
(hazkey_community_exec_t) for the targeted policy.

%prep
%autosetup -p1
# SwiftPM scratch directory used by hazkey-server/build_swift.cmake
mkdir -p build/hazkey-server
tar -C build/hazkey-server -xf %{SOURCE1}

%build
export HOME=$PWD/.swift-home
# upstream CI: glslc spawns up to 16 jobs per shader batch otherwise
export GGML_VULKAN_SHADER_MAX_PARALLEL=1
# swift-build spawns the toolchain's clang by name; it is not in /usr/bin
export PATH=%{_libexecdir}/swift/%{swift_version}/bin:$PATH
# swift-lang's default (swiftbuild) build system fails on package access
# levels / -lobjc; SwiftPM's native build system works.
%cmake \
  -DENABLE_FCITX5=ON \
  -DENABLE_IBUS=ON \
  -DENABLE_SELINUX=ON \
  -DHAZKEY_SELINUX_POLICY_FLAVOR=redhat \
  -DHAZKEY_SERVER_STATIC_SWIFT_STDLIB=OFF \
  -DSWIFT_BUILD_SYSTEM=native \
  -DLLAMA_OPENSSL=OFF \
  -DGGML_VULKAN=ON
%cmake_build

%install
export HOME=$PWD/.swift-home
export PATH=%{_libexecdir}/swift/%{swift_version}/bin:$PATH
%cmake_install

# swift-lang ships no static Swift stdlib (libswiftCore.a), so the server is
# linked dynamically.  Bundle the Swift runtime it needs privately instead of
# depending on the whole toolchain at runtime.
privdir=%{buildroot}%{_libdir}/hazkey-community
server=$privdir/hazkey-community-server
swiftlib=$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')
mkdir -p $privdir/swift
queue=$(readelf -d $server | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
while [ -n "$queue" ]; do
  set -- $queue; lib=$1; shift; queue="$*"
  [ -e "$swiftlib/$lib" ] && [ ! -e "$privdir/swift/$lib" ] || continue
  install -m 0755 "$swiftlib/$lib" $privdir/swift/
  queue="$queue $(readelf -d "$swiftlib/$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
done
patchelf --set-rpath '$ORIGIN/swift:$ORIGIN:$ORIGIN/libllama' $server
# License/notice files of Swift and Foundation; swift-lang omits ICU notices.
cp -a %{_datadir}/licenses/swift-lang swift-runtime-licenses
cp -p %{_libexecdir}/swift/%{swift_version}/share/swift/LICENSE.txt swift-runtime-licenses/swift-LICENSE.txt
cp -p %{SOURCE3} swift-runtime-licenses/ICU-76.1-LICENSE.txt

bzip2 -9 %{buildroot}%{_datadir}/selinux/packages/hazkey_community.pp

%find_lang fcitx5-hazkey-community
%find_lang ibus-hazkey-community

%pre selinux
%selinux_relabel_pre -s targeted

%posttrans selinux
%selinux_modules_install -s targeted %{_datadir}/selinux/packages/hazkey_community.pp.bz2
%selinux_relabel_post -s targeted

%preun selinux
if [ "$1" -eq 0 ]; then
  %selinux_relabel_pre -s targeted
fi

%postun selinux
if [ "$1" -eq 0 ]; then
  %selinux_modules_uninstall -s targeted hazkey_community
  %selinux_relabel_post -s targeted
fi

%files
%license LICENSE ThirdPartyLicenses swift-runtime-licenses
%{_bindir}/hazkey-community-server
%{_bindir}/hazkey-community-settings
%{_libdir}/hazkey-community/
%{_datadir}/hazkey-community/
%{_datadir}/applications/hazkey-community-settings.desktop
%{_datadir}/icons/hicolor/*/apps/hazkey-community.*

%files -n fcitx5-hazkey-community -f fcitx5-hazkey-community.lang
%license LICENSE
%{_libdir}/fcitx5/fcitx5-hazkey-community.so
%{_datadir}/fcitx5/addon/hazkey-community.conf
%{_datadir}/fcitx5/inputmethod/hazkey-community.conf
%{_datadir}/metainfo/org.fcitx.Fcitx5.Addon.HazkeyCommunity.metainfo.xml

%files -n ibus-hazkey-community -f ibus-hazkey-community.lang
%license LICENSE
%{_libexecdir}/ibus-hazkey-community/
%{_datadir}/ibus/component/ibus-hazkey-community.xml

%files selinux
%license LICENSE
%dir %{_datadir}/selinux
%dir %{_datadir}/selinux/packages
%{_datadir}/selinux/packages/hazkey_community.pp.bz2
%dir %{_docdir}/%{name}
%doc %{_docdir}/%{name}/selinux/

%changelog

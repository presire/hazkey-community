# openSUSE Build Service packages

Hazkey Community is packaged for openSUSE in the OBS project `home:presire1:hazkey-community`.  
The packaging sources live in `packaging/opensuse/` in this repository and are mirrored into the OBS package;  
OBS is the build system, so the binaries are produced there and not from a local checkout.  

| Item | Value |
| --- | --- |
| OBS project | home:presire1:hazkey-community |
| OBS package | hazkey-community |
| Repositories | 16.0<br>16.1<br>openSUSE_Tumbleweed |
| Architectures | x86_64 (SELinux subpackage: noarch) |
| Build dependency repo | devel:tools:compiler (provides swift-lang) |

Published repositories:  

- <https://download.opensuse.org/repositories/home:/presire1:/hazkey-community/16.0/>  
- <https://download.opensuse.org/repositories/home:/presire1:/hazkey-community/16.1/>  
- <https://download.opensuse.org/repositories/home:/presire1:/hazkey-community/openSUSE_Tumbleweed/>  

## Packages

| Package | Contents |
| --- | --- |
| hazkey-community | Conversion server<br>settings application<br>dictionaries<br>libllama/ggml libraries<br>bundled Swift runtime |
| fcitx5-hazkey-community | Fcitx5 addon (requires fcitx5) |
| ibus-hazkey-community | IBus engine (requires ibus) |
| hazkey-community-selinux | SELinux policy module (noarch) |

Install one frontend only; both pull in the common package:  

```sh
sudo zypper addrepo -f https://download.opensuse.org/repositories/home:/presire1:/hazkey-community/16.1/ \
                       hazkey-community
sudo zypper install fcitx5-hazkey-community
sudo zypper install ibus-hazkey-community
```

## Swift toolchain

The conversion server is written in Swift, and the standard repositories do not contain a Swift toolchain.  
The build uses `swift-lang` from `devel:tools:compiler`,  
pinned to the version recorded in `%define swift_version` in `hazkey-community.spec`. (currently 6.4.1)  

Two properties of that package drive the spec:  

- It ships only the dynamic Swift runtime;  
  there is no `libswiftCore.a`, so `-static-stdlib` cannot be used.  
  The server is linked dynamically and  
  the required runtime libraries are installed privately to `%{_libdir}/hazkey-community/swift/`,  
  with the server's `RUNPATH` rewritten to `$ORIGIN/swift:$ORIGIN:$ORIGIN/libllama`.  
- Its `clang` lives in `%{_libexecdir}/swift/<version>/bin`, not in `/usr/bin`,  
  so the spec prepends that directory to `PATH`.  

The default SwiftPM build system (`swiftbuild`) fails with this toolchain,  
so the spec configures `-DSWIFT_BUILD_SYSTEM=native`.  

## Offline SwiftPM dependencies

OBS workers have no network access, so the packages pinned in `hazkey-server/Package.resolved` are resolved  
before committing and shipped as `hazkey-community-swiftpm-vendor-<version>.tar.zst`.  
The tarball holds a ready-made SwiftPM scratch directory (`checkouts/` plus `workspace-state.json`)  
that the spec unpacks to the `--scratch-path` used by `hazkey-server/build_swift.cmake`.  

The vendor state must be generated with the same Swift version as the OBS `swift-lang` package,  
otherwise SwiftPM may rewrite the workspace state and try to fetch:  

```sh
./packaging/opensuse/make-swiftpm-vendor.sh hazkey-community-<version>.tar.zst \
                                            ~/.local/share/swiftly/toolchains/6.4.1/usr/bin/swift
```

## Updating the OBS package

1. Tag the upstream release that should be packaged.  
2. Update `revision` and `version` in `_service` to the new commit and version.  
3. Add a changelog entry:  
   `osc vc` (or edit `hazkey-community.changes`)  
4. Regenerate the source archive:  
   `osc service manualrun`.  
5. Regenerate the SwiftPM vendor archive with the command above.  
6. Review `%files` against the install tree and commit.  
   `osc commit --noservice`

Keep `packaging/opensuse/` in this repository and the OBS package in sync;  
OBS does not build from GitHub, and pushing to GitHub alone does not update the package.  

## Licenses

`hazkey-community` bundles the Swift runtime and its ICU data,  
so the spec installs the matching license texts under `/usr/share/hazkey-community/swift-runtime-licenses/`.  
`ICU-76.1-LICENSE.txt` is the unmodified `LICENSE` from ICU release 76-1 and  
covers the third-party notices the release notes of that file require.  

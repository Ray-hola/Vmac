#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || {
    echo 'VMac requires an Apple Silicon Mac.' >&2
    exit 1
}
version=$(tr -d '\r\n' < VERSION)
build=${VMAC_BUILD_NUMBER:-34}
identity=${VMAC_SIGNING_IDENTITY:--}
destination=${VMAC_BUILD_OUTPUT:-$PWD/_output/VMac.app}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[0-9]+$ ]] || exit 2
[[ $destination == /*.app && ! -e $destination && ! -L $destination ]] || {
    echo 'VMAC_BUILD_OUTPUT must be a new, absolute .app path.' >&2
    exit 2
}

mkdir -p _output "$(dirname "$destination")"
stage=$(mktemp -d "$(dirname "$destination")/.vmac-build.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/VMac.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources"
export MACOSX_DEPLOYMENT_TARGET=14.0 SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
export CAGE_SIGNING_IDENTITY="$identity"
export CGO_ENABLED=1
export CGO_CFLAGS="${CGO_CFLAGS:-} -mmacosx-version-min=14.0 -DCAGE_NATIVE_VM_TEST=1"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -mmacosx-version-min=14.0"
export CLANG_MODULE_CACHE_PATH="$stage/module-cache"

npm --prefix ui ci --no-audit --no-fund
npm run --prefix ui build

lima_version=$(cat internal/limaembed/lima-version)
assets=internal/limaembed/assets
mkdir -p "$assets/Darwin" "$assets/templates/_images" "$assets/templates/_default"
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/lima-vm/lima/v2/pkg/version.Version=$lima_version" \
    -o "$stage/lima-guestagent" github.com/lima-vm/lima/v2/cmd/lima-guestagent
gzip -9 -n -c "$stage/lima-guestagent" > "$assets/Darwin/lima-guestagent.Darwin-aarch64.gz"
cp third_party/lima/templates/macos-*.yaml "$assets/templates/"
cp third_party/lima/templates/_images/macos-*.yaml "$assets/templates/_images/"
cp third_party/lima/templates/_default/mounts.yaml "$assets/templates/_default/"

# Keep the upstream module cache read-only. The native view borrows the raw VM
# pointer from the pinned binding while its owning Go process stays alive.
vz_module=github.com/Code-Hex/vz/v3
[[ $(go list -m -f '{{.Version}}' "$vz_module") == v3.7.1 ]]
go mod download "$vz_module"
cp -R "$(go list -m -f '{{.Dir}}' "$vz_module")" "$stage/vz"
chmod -R u+w "$stage/vz"
cat > "$stage/vz/vmac_view_darwin.go" <<'GO'
//go:build darwin && cgo

package vz

import (
    "unsafe"

    "github.com/Code-Hex/vz/v3/internal/objc"
)

func (v *VirtualMachine) CageViewObject() unsafe.Pointer { return objc.Ptr(v) }
GO
cp go.mod "$stage/vmac.mod"
cp go.sum "$stage/vmac.sum"
go mod edit -modfile "$stage/vmac.mod" -replace "$vz_module=$stage/vz"
export GOFLAGS="${GOFLAGS:-} -modfile=$stage/vmac.mod"
tags=cage_macos_only,yq_noxml,yq_nolua,yq_noini,yq_nohcl,yq_notoml,yq_noprops,yq_nocsv,yq_nouri,yq_nobase64,yq_nosh,yq_noshell
lima_ldflags="-X github.com/lima-vm/lima/v2/pkg/version.Version=$lima_version"
go build -trimpath -buildmode=c-archive -tags "$tags" -ldflags "$lima_ldflags" -o "$stage/libVMac.a" ./cmd/cage-embedded
go build -trimpath -tags "$tags" -ldflags "-s -w $lima_ldflags -X github.com/Ray-hola/Vmac/internal/version.Version=$version" \
    -o "$resources/vmac" ./cmd/cage
xcrun swiftc -sdk "$SDKROOT" -module-cache-path "$CLANG_MODULE_CACHE_PATH" -D CAGE_EMBEDDED_VM \
    -O -target arm64-apple-macosx14.0 -parse-as-library -framework Cocoa -framework WebKit -framework Security \
    -framework LocalAuthentication -framework Virtualization -framework IOKit -framework SystemConfiguration -lresolv -lc++ \
    desktop/Cage.swift desktop/GuestSidebar.swift desktop/MacKeyboard.swift desktop/NativeInput.swift desktop/Updates.swift \
    desktop/AccountDevice.swift desktop/MacGuestLogin.swift "$stage/libVMac.a" -o "$bundle/Contents/MacOS/VMac"

xcrun swiftc -sdk "$SDKROOT" -target arm64-apple-macosx14.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    desktop/VMacLogo.swift -o "$stage/render-logo"
"$stage/render-logo" "$stage/logo"
cp "$stage/logo/VMac.icns" "$stage/logo/VMacMark.pdf" "$resources/"

bash scripts/guest-os/package-macos-guest.sh "$resources/guest-os"
bash scripts/fetch-proxy-core.sh
cp _output/proxy-core/mihomo "$resources/"
mkdir -p "$resources/licenses/mihomo" "$resources/Mole"
cp _output/proxy-core/{LICENSE,NOTICE} "$resources/licenses/mihomo/"
cp assets/mole/{LICENSE,guard.sh,provenance.json} "$resources/Mole/"
node scripts/collect-app-licenses.mjs "$resources/licenses" --vmac

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>VMac</string>
<key>CFBundleDisplayName</key><string>VMac</string>
<key>CFBundleIdentifier</key><string>cn.ovenray.vmac</string>
<key>CFBundleExecutable</key><string>VMac</string>
<key>CFBundleIconFile</key><string>VMac.icns</string>
<key>CFBundleVersion</key><string>$build</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
sign=(codesign --force --sign "$identity")
if [[ $identity != - ]]; then sign+=(--timestamp --options runtime); fi
"${sign[@]}" --entitlements third_party/lima/vz.entitlements "$resources/vmac"
"${sign[@]}" "$resources/mihomo"
"${sign[@]}" --entitlements third_party/lima/vz.entitlements "$bundle"
codesign --verify --deep --strict "$bundle"
for check in verify-web-assets verify-vm-assets verify-macos-guest; do
    "$resources/vmac" "$check"
done
[[ ! -e $destination && ! -L $destination ]]
mv "$bundle" "$destination"
printf 'Built: %s\n' "$destination"

#!/bin/bash
# A non-interactive installer for release and local test packages.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

usage() {
    cat <<'EOF'
Usage:
  bash scripts/install-vmac.sh release VERSION TEAM_ID [ABSOLUTE_PATH/VMac.app]
  bash scripts/install-vmac.sh local LOCAL_ZIP SHA256 ABSOLUTE_PATH/VMac.app

The release mode uses VMac's GitHub Releases and verifies the expected Developer ID team and notarization.
The local mode accepts an explicitly SHA-256-pinned test ZIP. Close VMac and shut down its guest before replacing an installation.
EOF
}

fail() { printf '%s\n' "$1" >&2; exit 1; }
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'VMac 安装需要 Apple Silicon Mac。'
mode=${1:-}
version_pattern='^(0|[1-9][0-9]{0,7})\.(0|[1-9][0-9]{0,7})\.(0|[1-9][0-9]{0,7})$'
build_pattern='^(0|[1-9][0-9]{0,7})$'
case "$mode" in
    release)
        [[ $# == 3 || $# == 4 ]] || { usage >&2; exit 2; }
        release=$2 team=$3 target=${4:-/Applications/VMac.app}
        [[ $release =~ $version_pattern && $team =~ ^[A-Z0-9]{10}$ ]] || fail '请提供正式版本号和预期的 Developer ID 团队 ID。'
        ;;
    local)
        [[ $# == 4 ]] || { usage >&2; exit 2; }
        archive=$2 expected=$3 target=$4
        [[ -f $archive && $archive == *.zip && $expected =~ ^[0-9a-f]{64}$ ]] || fail '请提供本机 ZIP 和对应的 SHA-256。'
        archive="$(cd -P -- "$(dirname -- "$archive")" && pwd)/$(basename -- "$archive")"
        ;;
    *) usage >&2; exit 2 ;;
esac

[[ $target == /*/VMac.app && ! -L $target ]] || fail '目标必须是绝对路径下的 VMac.app。'
parent=$(dirname -- "$target")
[[ $(cd -P -- "$parent" && pwd) == "$parent" && -w $parent ]] || fail 'VMac 安装目录必须存在、可写且不经过符号链接。'
umask 077
lock="$parent/.vmac-install.lock"
[[ ! -L $lock && ( ! -e $lock || -f $lock ) ]] || fail '安装锁文件无效。'
exec 9>"$lock"
lockf -s -t 0 9 || fail '另一项 VMac 安装正在运行。'
stage=$(mktemp -d "$parent/.vmac-install.XXXXXXXX")
candidate="$stage/VMac.app"
backup=''
mounted=false
installing=false
committed=false
rename_item() { /usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or die "rename: $!\n"' -- "$1" "$2"; }
cleanup() {
    if $installing && ! $committed && [[ ! -e $candidate && -d $target && ! -L $target ]]; then
        rename_item "$target" "$candidate" || printf '无法将候选应用移回 %s\n' "$candidate" >&2
    fi
    if [[ -n $backup && -e $backup && ! -e $target && ! -L $target ]]; then
        rename_item "$backup" "$target" || printf '旧应用备份仍位于 %s\n' "$backup" >&2
    fi
    if $mounted && ! hdiutil detach "$stage/mount" >/dev/null 2>&1; then
        printf '磁盘映像仍挂载在 %s，临时目录已保留。\n' "$stage/mount" >&2
        return
    fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
verify_bundle() {
    local app=$1
    [[ -d $app && ! -L $app && $(plist_value "$app" CFBundleIdentifier) == cn.ovenray.vmac &&
       $(plist_value "$app" CFBundleExecutable) == VMac ]] || fail '安装包的应用身份无效。'
    codesign --verify --deep --strict -R '=identifier "cn.ovenray.vmac"' "$app"
    lipo "$app/Contents/MacOS/VMac" -verify_arch arm64
    [[ -x "$app/Contents/Resources/vmac" ]] || fail 'VMac 安装包缺少控制程序。'
}
verify_release() {
    local app=$1
    codesign --verify --deep --strict -R "=anchor apple generic and identifier \"cn.ovenray.vmac\" and certificate leaf[subject.OU] = \"$team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$app"
    spctl --assess --type execute "$app"
}

if [[ $mode == release ]]; then
    base="https://github.com/Ray-hola/Vmac/releases/download/v$release"
    name="VMac-$release-macos-arm64.dmg"
    archive="$stage/$name"
    curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 2 --max-time 45 \
        --max-filesize 65536 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
    expected=$(awk -v name="$name" '$2==name || $2=="*"name {if (NF != 2 || ++matches != 1) exit 1; hash=tolower($1)} END {if (matches != 1 || length(hash) != 64) exit 1; print hash}' "$stage/SHA256SUMS")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || fail '正式发布的 SHA-256 清单无效。'
    curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 2 --max-time 600 \
        --max-filesize 2147483648 "$base/$name" -o "$archive"
else
    # Verify the staged copy that will actually be unpacked.
    cp -- "$archive" "$stage/local.zip"
    archive="$stage/local.zip"
fi
actual=$(shasum -a 256 -- "$archive" | awk '{print $1}')
[[ $actual == "$expected" ]] || fail 'VMac 安装包的 SHA-256 不匹配。'

if [[ $mode == release ]]; then
    mkdir "$stage/mount"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$stage/mount" "$archive" >/dev/null
    mounted=true
    verify_bundle "$stage/mount/VMac.app"
    verify_release "$stage/mount/VMac.app"
    ditto "$stage/mount/VMac.app" "$candidate"
else
    ditto -x -k "$archive" "$stage"
fi
verify_bundle "$candidate"
new_version=$(plist_value "$candidate" CFBundleShortVersionString)
new_build=$(plist_value "$candidate" CFBundleVersion)
[[ $new_version =~ $version_pattern && $new_build =~ $build_pattern ]] || fail '安装包的版本号无效。'
if [[ $mode == release ]]; then
    [[ $new_version == "$release" ]] || fail '应用版本与指定的发布版本不匹配。'
    verify_release "$candidate"
fi

version_sort_key() {
    local major minor patch
    IFS=. read -r major minor patch <<< "$1"
    printf '%08d%08d%08d' "$major" "$minor" "$patch"
}

if [[ -e $target ]]; then
    verify_bundle "$target"
    old_version=$(plist_value "$target" CFBundleShortVersionString)
    old_build=$(plist_value "$target" CFBundleVersion)
    [[ $old_version =~ $version_pattern && $old_build =~ $build_pattern ]] || fail '当前应用的版本号无效。'
    old_team=$(codesign -dv "$target" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    if [[ $old_team != 'not set' ]]; then
        [[ $mode == release ]] || fail '正式签名的 VMac 必须使用正式发布安装包更新。'
        verify_release "$target"
    fi
    if [[ $(version_sort_key "$new_version") > $(version_sort_key "$old_version") ]] ||
        [[ $mode == local && $new_version == "$old_version" && $new_build -gt $old_build ]]; then
        :
    else
        fail '安装包必须比当前 VMac 更新。'
    fi
    if lsof -t "$target/Contents/MacOS/VMac" >/dev/null 2>&1; then
        fail 'VMac 正在运行。请先正常停止客机并退出应用。'
    fi
    for config in "$HOME/.vmac/config.json" "$HOME"/.vmac/vms/*/config.json; do
        [[ -f $config ]] || continue
        if ! result=$(VMAC_CONFIG="$config" CLAUDE_CAGE_CONFIG="$config" "$target/Contents/Resources/vmac" prepare-update --json); then
            detail=$(plutil -extract message raw -o - - <<< "$result" 2>/dev/null || true)
            fail "无法确认客机后台已停止。${detail:+ $detail}"
        fi
        [[ $(plutil -extract status raw -o - - <<< "$result") == prepared ]] || fail '客机或后台未停止，请保存工作并正常关闭后再更新。'
    done
    if lsof -t "$target/Contents/MacOS/VMac" >/dev/null 2>&1; then
        fail 'VMac 已重新打开，请先退出应用。'
    fi
    backup="$(mktemp -d "$parent/.vmac-previous.XXXXXXXX")/VMac.app"
    rename_item "$target" "$backup"
fi
installing=true
[[ ! -e $target && ! -L $target ]] && rename_item "$candidate" "$target" || fail 'VMac 安装未完成。'
codesign --verify --deep --strict -R '=identifier "cn.ovenray.vmac"' "$target" || fail '安装后的应用校验失败。'
committed=true
printf 'VMac %s（Build %s）已安装到 %s\n' "$new_version" "$new_build" "$target"
if [[ -n $backup ]]; then printf '旧应用备份 %s\n' "$backup"; fi

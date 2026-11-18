#!/bin/bash
# VMac adapter. The unmodified Mole engine lives beside this script in mole/.
# No clean main or automatic whole-disk cleanup is invoked.
set -euo pipefail
action="$1"
target="$2"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/mole/bin" && pwd)/clean.sh"
if should_protect_path "$target" || is_path_whitelisted "$target" || holds_compiled_model_cache "$target"; then
    echo 'Mole 保护此项目，已保留' >&2
    exit 1
fi
_mole_reset_process_snapshot
validate_path_for_deletion "$target" || { echo "${_MOLE_VALIDATION_REASON:-应用正在使用或无法确认状态}" >&2; exit 1; }
case "$action" in
    check) ;;
    trash)
        identity=$(mole_deletion_identity "$target")
        MOLE_DELETE_MODE=trash mole_delete "$target" false "$identity"
        ;;
    *) exit 1 ;;
esac

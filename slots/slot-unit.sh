#!/bin/bash
# slot-unit.sh <class>-<n> — systemd glue: split the unit instance name and exec slot-loop.
#
# Context: ghr-slot@.service (Linux/Proxmox host) is a template unit whose instance is `supabase-5`;
# systemd cannot split that itself, and slot-loop takes `<class> <n>`. Kept as a script rather than an
# inline `bash -c` in the unit so the `$` and `%` escaping rules of unit files do not apply.
#
# Dependencies: slot-loop (installed next to this script, or slot-loop.sh in the repo).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
  [ "$#" -eq 1 ] || { echo "usage: slot-unit <class>-<n>" >&2; exit 2; }
  [[ "$1" =~ ^(light|supabase)-([1-9][0-9]*)$ ]] || { echo "slot-unit: bad instance name: $1" >&2; exit 2; }
  local class=${BASH_REMATCH[1]} n=${BASH_REMATCH[2]} loop
  if [ -x "$HERE/slot-loop" ]; then loop="$HERE/slot-loop"; else loop="$HERE/slot-loop.sh"; fi
  exec "$loop" "$class" "$n"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

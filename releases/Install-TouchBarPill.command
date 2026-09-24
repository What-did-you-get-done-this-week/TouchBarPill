#!/bin/bash
# Quit TouchBarPill, drop old Desktop copies, install TouchBarPill.app, open it.
set -euo pipefail
DESKTOP="${HOME}/Desktop"
HERE="$(cd "$(dirname "$0")" && pwd)"

BUILD=""
for candidate in \
	"${HERE}/../build/TouchBarPill.app" \
	"${DESKTOP}/TouchBarPill-src/build/TouchBarPill.app" \
	"${HERE}/TouchBarPill.app"
do
	if [[ -d "${candidate}" ]]; then
		BUILD="${candidate}"
		break
	fi
done

if [[ -z "${BUILD}" ]]; then
	echo "No encuentro la build de TouchBarPill.app." >&2
	exit 1
fi

if pgrep -x TouchBarPill >/dev/null 2>&1; then
	killall TouchBarPill >/dev/null 2>&1 || true
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		pgrep -x TouchBarPill >/dev/null 2>&1 || break
		sleep 0.2
	done
fi

# Desktop listing is often denied, and this process may not be allowed to
# delete apps it did not create. A double-click from the user can.
remove_app() {
	local path="$1"
	[[ -e "${path}" ]] || return 0
	if rm -rf "${path}"; then
		return 0
	fi
	echo "No pude borrar ${path}." >&2
	return 0
}
TARGET="${DESKTOP}/TouchBarPill.app"
FALLBACK="${DESKTOP}/TouchBarPill-0.5.9.app"

shopt -s nullglob
for old in "${DESKTOP}"/TouchBarPill*.app; do
	[[ "${old}" == "${TARGET}" || "${old}" == "${FALLBACK}" ]] && continue
	remove_app "${old}"
done
for ver in 0.3.{0..9} 0.4.{0..12}; do
	remove_app "${DESKTOP}/TouchBarPill-${ver}.app"
done

if ditto "${BUILD}" "${TARGET}"; then
	xattr -dr com.apple.quarantine "${TARGET}" >/dev/null 2>&1 || true
	open "${TARGET}"
	echo "Instalada ${TARGET}"
	exit 0
fi

echo "No pude sustituir ${TARGET}." >&2
if ditto "${BUILD}" "${FALLBACK}"; then
	xattr -dr com.apple.quarantine "${FALLBACK}" >/dev/null 2>&1 || true
	open "${FALLBACK}"
	echo "Quedó ${FALLBACK}." >&2
	exit 0
fi
echo "No pude instalar ni ${TARGET} ni ${FALLBACK}." >&2
exit 1

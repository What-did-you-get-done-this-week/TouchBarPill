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

shopt -s nullglob
for old in "${DESKTOP}"/TouchBarPill*.app; do
	rm -rf "${old}"
done

ditto "${BUILD}" "${DESKTOP}/TouchBarPill.app"
xattr -dr com.apple.quarantine "${DESKTOP}/TouchBarPill.app" >/dev/null 2>&1 || true
open "${DESKTOP}/TouchBarPill.app"
echo "Instalada ${DESKTOP}/TouchBarPill.app"

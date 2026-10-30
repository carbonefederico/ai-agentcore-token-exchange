#!/usr/bin/env sh
# Register the JWT client-auth validator settings into PF's canonical config-store set.
# PF prunes config-store files that are absent from conf/data-default.zip, so a raw
# file dropped in data/config-store/ is deleted at every boot. Adding it to the zip
# makes PF treat it as first-class config (and extract it on boot).
set -e
ZIP="${SERVER_ROOT_DIR}/server/default/conf/data-default.zip"
SRC="${STAGING_DIR}/instance/server/default/data/config-store/oauth-credentials-validator.xml"
if test -f "${SRC}" && test -f "${ZIP}"; then
    if ! unzip -l "${ZIP}" 2>/dev/null | grep -q "config-store/oauth-credentials-validator.xml"; then
        ZIPDIR="$(mktemp -d)/config-store"
        mkdir -p "${ZIPDIR}"
        cp "${SRC}" "${ZIPDIR}/"
        (cd "$(dirname "${ZIPDIR}")" && zip -q "${ZIP}" "config-store/$(basename "${SRC}")")
        echo "registered oauth-credentials-validator.xml into data-default.zip"
    fi
fi

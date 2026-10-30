#!/usr/bin/env sh
# Profile override of the stock 07 hook: same merge behavior, plus registration of
# config-store files into data-default.zip (PF prunes any config-store file absent
# from the zip at every boot - see hooks/08 inline below for the mechanism).

test "${VERBOSE}" = "true" && set -x

# shellcheck source=./pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

# Check to see if there is an instance directory and files in it
if test -d "${STAGING_DIR}/instance" && test -n "$(ls -A "${STAGING_DIR}/instance")"; then
    # If this is a new server or the a SERVER_PROFILE_UPDATE is asked for
    # Then copy/overwrite files to SERVER_ROOT_DIR
    if test "${RUN_PLAN}" = "START" || test "${SERVER_PROFILE_UPDATE}" = "true"; then
        echo "merging ${STAGING_DIR}/instance to ${SERVER_ROOT_DIR}"
        copy_files "${STAGING_DIR}/instance" "${SERVER_ROOT_DIR}"
    else
        echo "no merge requested from ${STAGING_DIR}/instance to ${SERVER_ROOT_DIR} (SERVER_PROFILE_UPDATE=${SERVER_PROFILE_UPDATE})"
    fi
fi

# ---------------------------------------------------------------------
# Register extra config-store files into the canonical data-default.zip
# ---------------------------------------------------------------------
ZIP="${SERVER_ROOT_DIR}/server/default/conf/data-default.zip"
SRC="${STAGING_DIR}/instance/server/default/data/config-store"
if test -d "${SRC}" && test -f "${ZIP}"; then
    for f in "${SRC}"/*.xml; do
        test -f "$f" || continue
        name="$(basename "$f")"
        if ! unzip -l "${ZIP}" 2>/dev/null | grep -q "config-store/${name}"; then
            ZIPDIR="$(mktemp -d)/config-store"
            mkdir -p "${ZIPDIR}"
            cp "$f" "${ZIPDIR}/${name}"
            (cd "$(dirname "${ZIPDIR}")" && zip -q "${ZIP}" "config-store/${name}")
            echo "registered config-store/${name} into data-default.zip"
        fi
    done
fi

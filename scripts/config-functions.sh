#!/usr/bin/env bash
# Gemeinsame Hilfsfunktionen zur sicheren Erzeugung der Bash-Konfiguration.

config_copy_without_keys() {
    local source_file="$1" destination_file="$2"
    shift 2
    local keys_csv
    keys_csv="$(IFS=,; printf '%s' "$*")"

    awk -v keys="$keys_csv" '
        BEGIN {
            count = split(keys, names, ",")
            for (i = 1; i <= count; i++) remove[names[i]] = 1
        }
        skipping_array {
            if ($0 ~ /^[[:space:]]*\)[[:space:]]*$/) skipping_array = 0
            next
        }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            key = line
            sub(/=.*/, "", key)
            if (key in remove) {
                value = line
                sub(/^[^=]*=/, "", value)
                if (value ~ /^\([[:space:]]*$/) skipping_array = 1
                next
            }
            print
        }
    ' "$source_file" >"$destination_file"
}

config_append_scalar() {
    local destination_file="$1" name="$2" value="$3"
    printf '%s=%q\n' "$name" "$value" >>"$destination_file"
}

config_append_array() {
    local destination_file="$1" name="$2" raw="$3" item
    local -a items=()
    printf '%s=(\n' "$name" >>"$destination_file"
    IFS=':' read -r -a items <<<"$raw"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] && printf '    %q\n' "$item" >>"$destination_file"
    done
    printf ')\n' >>"$destination_file"
}

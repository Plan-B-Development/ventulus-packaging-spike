# Shared helpers. Source it; never execute it.
# Each check is recorded as a row of the job summary and the job carries on, so
# one run answers every question; the job fails at the end if any check failed.

summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
failures=0

# check <label> <command...>: run it, log its output in a fold, record the result.
check() {
    local label=$1 rc=0
    shift
    echo "::group::$label"
    "$@" || rc=$?
    echo "::endgroup::"
    if [ "$rc" = 0 ]; then
        echo "| ✅ | $label |" >> "$summary"
    else
        echo "| ❌ (exit $rc) | $label |" >> "$summary"
        failures=$((failures + 1))
    fi
    return 0
}

# note <text>: a free-text finding row.
note() {
    echo "| ℹ️ | $* |" >> "$summary"
    echo "NOTE: $*"
}

table() {
    printf '\n### %s\n\n| Result | Check |\n| --- | --- |\n' "$1" >> "$summary"
}

finish() {
    echo "failures: $failures"
    [ "$failures" = 0 ]
}

# Throwaway ed25519 signing key, the project key's algorithm; lives only in this
# job. Reuses the key already in $GNUPGHOME when the caller set one.
make_key() {
    export GNUPGHOME=${GNUPGHOME:-$(mktemp -d)}
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    if ! gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
        gpg --batch --pinentry-mode loopback --passphrase '' \
            --quick-gen-key 'xd-spike throwaway <spike@invalid>' ed25519 sign 2d
    fi
    KEY_FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
    export KEY_FPR
}

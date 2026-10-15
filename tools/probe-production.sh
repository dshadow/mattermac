#!/bin/bash
# Run from repository root. Secrets are transient; only sanitized stdout is saved.
set +x
set -euo pipefail
umask 077

if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' 'Usage: rtk proxy bash tools/probe-production.sh [--self-test]' \
        'Required env (prompted if absent): MATTERMOST_PROD_URL, MATTERMOST_PROD_USERNAME (or EMAIL), MATTERMOST_PROD_PASSWORD' \
        'Optional: MATTERMOST_PROD_MFA_CODE (six digits) OR MATTERMOST_PROD_TOTP_SECRET (Base32)' \
        'Without either MFA variable, interactive runs prompt for code; leave blank for password-only.' \
        'Output: tmp/phase0/production-report.txt. No production secrets or raw responses saved.'
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--self-test" ) ]]; then
    printf '%s\n' 'Unknown argument; use --help.' >&2
    exit 2
fi
if [[ ! -f tools/EnvironmentProbe.swift ]]; then
    printf '%s\n' 'Run from repository root.' >&2
    exit 2
fi

rtk mkdir -p tmp/phase0
rtk proxy swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -module-cache-path tmp/phase0/module-cache \
    tools/EnvironmentProbe.swift -o tmp/phase0/environment-probe
rtk proxy tmp/phase0/environment-probe --self-test
if [[ "${1:-}" == "--self-test" ]]; then exit 0; fi

trap 'unset MATTERMOST_PROD_PASSWORD MATTERMOST_PROD_MFA_CODE MATTERMOST_PROD_TOTP_SECRET' EXIT
if [[ -z "${MATTERMOST_PROD_URL:-}" ]]; then
    read -r -s -p 'Production HTTPS URL (hidden; include deployment subpath): ' MATTERMOST_PROD_URL
    printf '\n' >&2
fi
if [[ -z "${MATTERMOST_PROD_USERNAME:-}" && -z "${MATTERMOST_PROD_EMAIL:-}" ]]; then
    read -r -s -p 'Production login (hidden; username, email, or LDAP ID): ' MATTERMOST_PROD_USERNAME
    printf '\n' >&2
fi
if [[ -z "${MATTERMOST_PROD_PASSWORD:-}" ]]; then
    read -r -s -p 'Production password (hidden): ' MATTERMOST_PROD_PASSWORD
    printf '\n' >&2
fi
if [[ -z "${MATTERMOST_PROD_TOTP_SECRET+x}" && -z "${MATTERMOST_PROD_MFA_CODE+x}" && -t 0 ]]; then
    read -r -s -p 'Fresh six-digit MFA code (hidden; blank if account has no MFA): ' probe_mfa_code
    printf '\n' >&2
    if [[ -n "$probe_mfa_code" ]]; then export MATTERMOST_PROD_MFA_CODE="$probe_mfa_code"; fi
    unset probe_mfa_code
fi
export MATTERMOST_PROD_URL MATTERMOST_PROD_USERNAME MATTERMOST_PROD_PASSWORD
# EMAIL, MFA_CODE and TOTP_SECRET supplied by callers must already be exported.
# pipefail preserves probe failure, including failed logout, while keeping output.
rtk proxy tmp/phase0/environment-probe --production | rtk proxy tee tmp/phase0/production-report.txt

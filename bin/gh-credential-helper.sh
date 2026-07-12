#!/bin/bash
# monohost git credential helper.
#
# Supplies the read-only GitHub deploy token for github.com pulls, WITHOUT the
# token ever appearing in a remote URL, process arguments, or .git/config — git
# calls this helper and reads the values from stdout.
#
# Install: mh-admin-owned, mode 755, at /opt/monohost/bin/ (control plane —
# immutable to the deployer). It reads the token from a deployer-owned 600 file;
# if that file is absent/unreadable it emits nothing, so PUBLIC repos still work.
#
# Used as:  git -c credential.helper=/opt/monohost/bin/gh-credential-helper.sh ...

[ "${1:-}" = "get" ] || exit 0

TOKEN_FILE="/opt/monohost/secrets/github.token"
[ -r "$TOKEN_FILE" ] || exit 0

token="$(cat "$TOKEN_FILE")"
[ -n "$token" ] || exit 0

printf 'username=x-access-token\n'
printf 'password=%s\n' "$token"

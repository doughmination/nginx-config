#!/usr/bin/env bash
# One-time bootstrap helper for a from-scratch server: nginx refuses to start
# (and therefore `certbot --nginx` refuses to run) while vhosts point at
# /etc/letsencrypt paths that don't exist yet. This script temporarily swaps
# every real cert directive for the self-signed snippets/snakeoil.conf so
# nginx can start, then swaps them back once certbot has issued real certs.
#
# Usage (run from the nginx config root, e.g. /etc/nginx):
#   ./certbot-bootstrap.sh apply     # real certs -> snakeoil (do this first)
#   ...install nginx, `nginx -t` should now pass, start/reload nginx...
#   ...run certbot certonly (--nginx or --webroot) for each domain group...
#   ./certbot-bootstrap.sh restore   # snakeoil -> real certs
#   ...`nginx -t` && systemctl reload nginx...
#
# Safe to run `apply` or `restore` more than once — both are no-ops on files
# already in the target state. Delete this script once restore is done; it's
# a bootstrap tool, not something that needs to live in the repo long-term.

set -euo pipefail
cd "$(dirname "$0")"

MARKER='#__bootstrap__'
MODE="${1:-}"

if [[ "$MODE" != "apply" && "$MODE" != "restore" ]]; then
    echo "Usage: $0 {apply|restore}" >&2
    exit 1
fi

mapfile -t FILES < <(grep -rlE '^[[:space:]]*(ssl_certificate([[:space:]]|_key[[:space:]])|ssl_dhparam[[:space:]]|include[[:space:]]+.*options-ssl-nginx\.conf)|__bootstrap__' \
    sites-available/ snippets/ 2>/dev/null | grep -v '^snippets/snakeoil\.conf$' || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No files with ssl_certificate directives found under sites-available/ or snippets/."
    exit 0
fi

apply_one() {
    local f="$1"
    if grep -q "$MARKER" "$f"; then
        echo "  skip (already applied): $f"
        return
    fi
    awk -v marker="$MARKER" '
        /^[[:space:]]*(ssl_certificate([[:space:]]|_key[[:space:]])|ssl_dhparam[[:space:]]|include[[:space:]]+.*options-ssl-nginx\.conf)/ {
            match($0, /^[[:space:]]*/)
            last_indent = substr($0, RSTART, RLENGTH)
            print marker " " $0
            in_block = 1
            next
        }
        {
            if (in_block) {
                print last_indent "include snippets/snakeoil.conf; " marker
                in_block = 0
            }
            print $0
        }
        END {
            if (in_block) {
                print last_indent "include snippets/snakeoil.conf; " marker
            }
        }
    ' "$f" > "$f.bootstrap.tmp"
    mv "$f.bootstrap.tmp" "$f"
    echo "  applied: $f"
}

restore_one() {
    local f="$1"
    if ! grep -q "$MARKER" "$f"; then
        echo "  skip (not applied): $f"
        return
    fi
    awk -v marker="$MARKER" '
        index($0, marker " ") == 1 {
            print substr($0, length(marker " ") + 1)
            next
        }
        $0 ~ (marker "$") { next }
        { print $0 }
    ' "$f" > "$f.bootstrap.tmp"
    mv "$f.bootstrap.tmp" "$f"
    echo "  restored: $f"
}

echo "Mode: $MODE"
for f in "${FILES[@]}"; do
    if [[ "$MODE" == "apply" ]]; then
        apply_one "$f"
    else
        restore_one "$f"
    fi
done

echo "Done. Run 'nginx -t' next."

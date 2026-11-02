#!/bin/sh
# Reload nginx after certbot renewed a certificate.
# The certbot container (docker-compose.yml) runs `certbot renew --deploy-hook "touch /var/www/certbot/.renewed"` every 12 h; the hook only
# fires for a certificate that was really renewed. nginx keeps serving the old certificate from memory until it reloads, so without this
# a Let's Encrypt certificate would expire (90 days) in spite of being renewed on disk.
# Runs from the nginx image's /docker-entrypoint.d before nginx starts: it only forks a small watcher and returns.
MARK=/var/www/certbot/.renewed
EVERY=60

(
    last=$(stat -c %Y "$MARK" 2>/dev/null || echo 0)
    warned=0
    while :; do
        sleep "$EVERY"
        now=$(stat -c %Y "$MARK" 2>/dev/null || echo 0)
        [ "$now" = "$last" ] && continue
        # The renewal is remembered as handled only after a successful reload: a failure (a half-written vhost) must not hide the new
        # certificate for good, so it is retried every poll. A broken config is never reloaded: the old one keeps serving.
        if nginx -t >/dev/null 2>&1; then
            if nginx -s reload; then
                last=$now
                warned=0
                echo "[cert-reload] nginx reloaded after a certificate renewal"
            elif [ "$warned" = 0 ]; then
                warned=1
                echo "[cert-reload] 'nginx -s reload' failed, retrying every ${EVERY}s" >&2
            fi
        elif [ "$warned" = 0 ]; then
            warned=1
            echo "[cert-reload] certificate renewed but 'nginx -t' fails: NOT reloaded, retrying every ${EVERY}s" >&2
        fi
    done
) </dev/null &

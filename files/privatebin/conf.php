;<?php http_response_code(403); /*
; PrivateBin configuration. Deployed to /etc/privatebin/conf.php (wired up via
; CONFIG_PATH in the php-fpm pool); the webroot stays read-only and pastes
; live in /var/lib/privatebin/data.
; Reference: https://github.com/PrivateBin/PrivateBin/wiki/Configuration

[main]
name = "PrivateBin"
; Documents published from this box are mostly markdown; preselect it.
defaultformatter = "markdown"
languageselection = false

[expire]
default = "1week"

[traffic]
; Seconds between document creations per client IP — basic abuse damper for a
; publicly writable instance. Loopback is exempt so server-side tooling
; (pbincli via the privatebin skill) is never throttled when posting straight
; to 127.0.0.1:8095.
limit = 10
exempted = "127.0.0.1"
; All public requests arrive via cloudflared from 127.0.0.1; Cloudflare puts
; the real client address in CF-Connecting-IP (PrivateBin adds the HTTP_
; prefix itself). Requests without the header fall back to REMOTE_ADDR.
header = "CF_CONNECTING_IP"

[purge]
limit = 300
batchsize = 10

[model]
class = Filesystem
[model_options]
dir = "/var/lib/privatebin/data"

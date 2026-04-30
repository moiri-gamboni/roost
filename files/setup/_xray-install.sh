# Xray-core installer, factored out of files/setup/travel-vpn.sh so the same
# logic can be reused (e.g. by future auto-update integrations) without
# duplication. Sourced; not executed standalone.
#
# Expects these helpers from _setup-env.sh: `info`, `ok`, `skip`, `die`.
# Caller must have sourced _setup-env.sh before invoking xray_install.

xray_install() {
    local xray_bin=/usr/local/bin/xray
    local xray_version_pin=v26

    # --- Architecture → release-asset name ---
    local arch xray_asset
    arch=$(uname -m)
    case "$arch" in
        x86_64)  xray_asset=Xray-linux-64 ;;
        aarch64) xray_asset=Xray-linux-arm64-v8a ;;
        *) echo "Error: unsupported architecture $arch for Xray" >&2; return 1 ;;
    esac

    # `xray version` prints "Xray 26.3.27 (...)" in v26, but older builds used
    # "Xray v26.3.27". Strip a leading v from whatever comes out so the comparison
    # against the v-less pin works either way.
    local installed_version=""
    if [ -x "$xray_bin" ]; then
        installed_version=$("$xray_bin" version 2>/dev/null | awk 'NR==1 {print $2}' || true)
        installed_version="${installed_version#v}"
    fi

    if [[ -n "$installed_version" && "$installed_version" == ${xray_version_pin#v}.* ]]; then
        skip "Xray $installed_version already installed"
    else
        local target_tag tmpdir base expected actual geo
        info "Resolving latest Xray ${xray_version_pin}.x release..."
        # Prefer a ${xray_version_pin}.x release; fall back to latest if API filter returns empty.
        target_tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100" \
            | jq -r --arg pin "$xray_version_pin" \
                '[.[] | select(.prerelease == false) | select(.tag_name | startswith($pin + "."))] | first | .tag_name // empty')
        if [ -z "$target_tag" ]; then
            echo "Error: no ${xray_version_pin}.x release found on XTLS/Xray-core" >&2
            return 1
        fi

        info "Installing Xray $target_tag ($xray_asset)..."
        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' RETURN

        base="https://github.com/XTLS/Xray-core/releases/download/$target_tag"
        curl -fsSL -o "$tmpdir/$xray_asset.zip"      "$base/$xray_asset.zip"
        curl -fsSL -o "$tmpdir/$xray_asset.zip.dgst" "$base/$xray_asset.zip.dgst"

        expected=$(awk -F'= *' '/^SHA2-256=/ {print $2; exit}' "$tmpdir/$xray_asset.zip.dgst")
        if [ -z "$expected" ]; then
            echo "Error: could not read SHA2-256 from $xray_asset.zip.dgst" >&2
            return 1
        fi
        actual=$(sha256sum "$tmpdir/$xray_asset.zip" | awk '{print $1}')
        if [ "$expected" != "$actual" ]; then
            echo "Error: SHA256 mismatch for $xray_asset.zip" >&2
            echo "  expected: $expected" >&2
            echo "  actual:   $actual" >&2
            return 1
        fi

        # unzip is usually present, but install if missing for parity with the rest of the flow.
        command -v unzip >/dev/null || apt-get install -y unzip
        unzip -q -o "$tmpdir/$xray_asset.zip" -d "$tmpdir/extract"
        install -m 0755 -o root -g root "$tmpdir/extract/xray" "$xray_bin"

        # geo data ships alongside the binary; install where xray looks by default.
        install -d -m 0755 /usr/local/share/xray
        for geo in geoip.dat geosite.dat; do
            [ -f "$tmpdir/extract/$geo" ] && \
                install -m 0644 -o root -g root "$tmpdir/extract/$geo" "/usr/local/share/xray/$geo"
        done

        ok "Xray $("$xray_bin" version | awk 'NR==1 {print $2}') installed"
    fi

    # Drift guard: upstream Xray's own install scripts default to User=nobody.
    # If our service unit ever lands with the wrong User= (e.g. someone runs
    # the official installer alongside this), fail loudly so the proton-routing
    # fwmark match (--uid-owner xray in proton-routing.sh) doesn't silently
    # stop catching xray's egress.
    if [ -f /etc/systemd/system/xray.service ]; then
        grep -q '^User=xray$' /etc/systemd/system/xray.service \
            || die "xray.service User= directive is not 'xray'; refusing to proceed (proton-routing fwmark would break)"
    fi
}

#!/usr/bin/env bash
# Resolve an absolute path to the pixi binary.
#
# pixi's installer puts the binary in ~/.pixi/bin and adds that directory to PATH
# from a shell rc file. That covers an interactive login and nothing else: a run
# started over `ssh host 'command'`, from cron, or from a batch job gets a shell
# that never sources the rc, so a bare `pixi` is command-not-found even though it
# is installed. The delivery server is exactly that case -- pixi is at
# ~/.pixi/bin/pixi but absent from PATH in a non-interactive shell -- so the
# launchers cannot assume the bare name resolves.
#
# Same reasoning as scripts/find_singularity.sh: the callers need a real path,
# not whatever an interactive shell happened to set up.
#
# Usage:
#   source scripts/find_pixi.sh
#   PIXI="$(find_pixi)" || exit 1

find_pixi() {
    local exe

    # Already on PATH (interactive shell, or a site where it just is).
    if command -v pixi >/dev/null 2>&1; then
        command -v pixi
        return 0
    fi

    # The installer default, then the usual system-wide locations.
    for exe in "$HOME/.pixi/bin/pixi" /usr/local/bin/pixi /opt/pixi/bin/pixi; do
        if [[ -x "$exe" ]]; then
            printf '%s\n' "$exe"
            return 0
        fi
    done

    echo "Error: no pixi on PATH, and none at ~/.pixi/bin/pixi," \
         "/usr/local/bin/pixi or /opt/pixi/bin/pixi." >&2
    echo "Install it with: curl -fsSL https://pixi.sh/install.sh | bash" >&2
    return 1
}

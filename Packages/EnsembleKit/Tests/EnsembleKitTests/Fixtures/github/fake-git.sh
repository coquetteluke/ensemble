#!/bin/sh
# Records each git call's arguments (NUL-separated) in git-calls/NNNNN next to this script, then runs the real
# git. When ./ssh-shim names a stand-in ssh, git uses it for ssh remotes; without one, any push is refused, so
# a test can never reach a real server.
dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir/git-calls"
n=$(ls "$dir/git-calls" | wc -l | tr -d ' ')
f=$(printf '%s/git-calls/%05d' "$dir" $((n + 1)))
: > "$f"
for a in "$@"; do printf '%s\0' "$a" >> "$f"; done
if [ -f "$dir/ssh-shim" ]; then
  GIT_SSH_COMMAND=$(cat "$dir/ssh-shim")
  GIT_SSH_VARIANT=simple
  export GIT_SSH_COMMAND GIT_SSH_VARIANT
else
  for a in "$@"; do
    if [ "$a" = push ]; then echo "fake git: no ssh stand-in, push refused" >&2; exit 1; fi
  done
fi
exec /usr/bin/git "$@"

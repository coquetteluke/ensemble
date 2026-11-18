#!/bin/sh
# Stand-in for ssh in tests: never connects anywhere. git calls it (GIT_SSH_VARIANT=simple) as
# `ssh <host> "git-receive-pack '<path>'"`. It records "<host> <command>" in ssh-log next to this script, then
# runs that pack command against the local bare repository named in ./bare.
dir=$(cd "$(dirname "$0")" && pwd)
host="$1"
command="$2"
printf '%s %s\n' "$host" "$command" >> "$dir/ssh-log"
bare=$(cat "$dir/bare")
case "$command" in
  git-receive-pack*) exec /usr/bin/git receive-pack "$bare" ;;
  git-upload-pack*) exec /usr/bin/git upload-pack "$bare" ;;
  *) echo "fake ssh: unexpected command" >&2; exit 1 ;;
esac

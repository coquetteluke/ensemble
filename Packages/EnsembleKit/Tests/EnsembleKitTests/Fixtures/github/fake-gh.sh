#!/bin/sh
# Stand-in for the GitHub CLI in tests. Never contacts GitHub.
# Records each call's arguments (NUL-separated) in calls/NNNN and its folder in calls/NNNN.cwd next to this
# script, then prints responses/<key>.out to stdout and responses/<key>.err to stderr and exits with
# responses/<key>.code (default 0).
# Keys: version, auth_status, repo_view (or repo_view_<owner>_<name>), pr_list, pr_view, pr_create, pr_merge,
# run_view (or run_view_<id>).
dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir/calls"
n=$(ls "$dir/calls" | grep -vc '\.cwd$')
f=$(printf '%s/calls/%04d' "$dir" $((n + 1)))
: > "$f"
for a in "$@"; do printf '%s\0' "$a" >> "$f"; done
pwd -P > "$f.cwd"
case "$1" in
  --version) key=version ;;
  *) key="$1_$2" ;;
esac
if [ "$1" = run ] && [ "$2" = view ] && [ -f "$dir/responses/run_view_$3.out" ]; then key="run_view_$3"; fi
if [ "$1" = repo ] && [ "$2" = view ]; then
  repo=$(printf '%s' "$3" | tr '/' '_')
  [ -f "$dir/responses/repo_view_$repo.out" ] && key="repo_view_$repo"
fi
r="$dir/responses/$key"
[ -f "$r.out" ] && cat "$r.out"
[ -f "$r.err" ] && cat "$r.err" >&2
code=0
[ -f "$r.code" ] && code=$(cat "$r.code")
exit "$code"

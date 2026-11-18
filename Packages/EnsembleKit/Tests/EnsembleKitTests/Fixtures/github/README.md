# GitHub fixtures

`fake-gh.sh` stands in for the GitHub CLI in tests: it records its arguments and prints canned answers, so no
test ever reaches GitHub. `fake-git.sh` records git's arguments and runs the real `/usr/bin/git`. Pushes go
through `fake-ssh.sh`, which never connects anywhere and hands the pack to a local bare repository; without it
the wrapper refuses every push. Tests copy these into temporary folders (see `GitHubTestSupport.swift`).

The JSON files have the shape `gh pr list --json`, `gh repo view --json` and `gh run view --log-failed` print
for the fields Ensemble asks for. Names, links and accounts are made up (acme/widgets, octocat).

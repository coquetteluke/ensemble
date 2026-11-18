# `.ensemble/launch.json`: dev servers for the browser pane

A project can list its dev servers in `.ensemble/launch.json`. The browser pane (Option-Command-B) shows them under the dev servers button and on its empty page. Start runs the command in the session's folder, shows its output in the console, waits for the port to answer, then opens the page.

## Format

A JSON list of servers:

```json
[
  {"name": "web", "command": "npm run dev", "port": 5173},
  {"name": "docs", "command": ["python3", "-m", "http.server", "8000"], "port": 8000, "url": "/docs/"},
  {"name": "api", "command": "node server.js --port 3001", "port": 3001, "url": "http://127.0.0.1:3001/health"}
]
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Shown in the list and in the console. Up to 60 characters, unique in the file (ignoring case). |
| `command` | yes | The program and its arguments: one string, split into words as described below, or a list of strings used exactly as written. |
| `port` | yes | A whole number from 1 to 65535. Ensemble waits until `127.0.0.1` or `[::1]` accepts connections on it. |
| `url` | no | The page to open once the port answers. A path such as `/admin` (opened on `http://localhost:<port>`), or a full `http` or `https` address on this computer: `localhost`, a `.localhost` name, `127.0.0.1` or `[::1]`. Without it, `http://localhost:<port>/` opens. |

Entries with a problem are left out and the problem is listed under the servers. Unknown fields are reported and ignored. At most 20 servers are read, and the file may be at most 64 KB.

## How the command runs

There is no shell. Ensemble starts the program directly with Foundation's `Process`, in the session's folder, in a process group of its own.

- A string command is split into words like a shell would split them, and nothing else: spaces and tabs separate words, `'single quotes'` keep everything as written, `"double quotes"` keep everything except `\"` and `\\`, and a backslash outside quotes keeps the next character.
- Anything else a shell would act on is refused outside quotes, so what runs is exactly what you confirmed: `;` `|` `&` `<` `>` `(` `)` `` ` `` `$` `*` `?` `[` `]` `{` `}`, and `~` or `#` at the start of a word. `$` and backticks are refused inside double quotes too. Line breaks and other control characters are refused anywhere.
- A leading `NAME=value` is refused (setting variables needs a shell). Put settings in the program's own config, or in a script that the command runs.
- A program named without a slash is looked up in Ensemble's PATH plus `~/.local/bin`, `~/.bun/bin`, `~/.deno/bin`, `~/.volta/bin`, `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and `/bin`. A program with a slash is a path, relative to the folder unless it starts with `/` (for example `node_modules/.bin/vite`). Version managers that change PATH in your shell profile (nvm, asdf) are not loaded: give the full path to the program if it is not found.
- The environment is Ensemble's own, without `ANTHROPIC_*`, `CLAUDE*`, `OPENCODE*`, `GEMINI_*` and `ENSEMBLE_*` variables, with the PATH above and `BROWSER=none` so the server does not open your default browser.
- Standard input is empty. Standard output and error go to the console, without colour codes. Lines that mention an error or a failure are marked as errors, so Send to agent > Console errors includes them.

## Safety

- **Trusted folders only.** The file comes from the repository, so Start only works in folders you trust (the same list as the agents' trust card, `~/Library/Application Support/Ensemble/trusted-folders.json`). In other folders the pane lists the servers but does not run them, and offers Trust this folder.
- **Confirmed once per folder and command.** Before the first start, the pane shows the command, the program's full path, the folder and the port, and asks. Ensemble remembers the confirmation for that folder and those exact words (`~/Library/Application Support/Ensemble/dev-server-approvals.json`). If the command changes, for example after a pull, it asks again.
- **Port already in use.** If something already answers on the port, nothing starts and the pane offers to open the page that is there.
- **Stopping.** Stop signals the server's process group and every process it started (also ones that moved to a session of their own), waits three seconds, then kills what is left. When the command ends by itself, anything it left running in its group is stopped too, so a server never outlives its entry. Servers stop when their session is archived or deleted, and when Ensemble quits.
- **Pages.** The pane is an ordinary browser with a private, non-persistent data store per session: no cookies or sign-ins come in from Safari or go out. Only `http` and `https` pages load. `file:`, `data:`, `blob:`, `javascript:` and other schemes are refused, downloads are off, and pop-ups open in the same view. Pages open only from the address bar, a dev server, or links on the page itself, never from agent text.

## Not yet

- Agents cannot drive the browser (click, type, read the page) on their own. They see the page when you use Send to agent: a screenshot, the console errors, or an element you pick.
- No `env`, `cwd`, `args` or `autoPort` fields, and no automatic start with a session.

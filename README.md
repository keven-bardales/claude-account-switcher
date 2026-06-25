# claude-account-switcher

**Never start [Claude Code](https://www.claude.com/product/claude-code) with the wrong account again.**

Claude Code uses **one account per config directory**. If you have more than one
account (e.g. a personal one and a work one), it's easy to launch Claude with the
wrong account in the wrong project — and you usually notice halfway through.

This is a tiny PowerShell wrapper that, **every time you run `claude`**:

- resolves which account to use from the **folder / git repo** you're in (rules you set once),
- **shows you the account** and asks you to confirm before launching,
- passes all your flags through unchanged (`claude --dangerously-skip-permissions`, `claude -p ...`, etc.).

Personal is the **safe default**. Another account is used **only** where *you*
mapped it. So a personal project can never silently start with a work account.

```text
$ claude --dangerously-skip-permissions

  +-- Claude account --------------------------------
  | account : work [work]
  | why     : git org: your-work-org
  | config  : C:\Users\you\.claude-work
  +--------------------------------------------------
  Continue?  [Enter]=yes  /  n=no  /  type a profile name to override:
```

Hit **Enter** and Claude starts with that account. In a personal repo you'd see
`personal [personal]`. You always see the account before anything runs.

---

## How multiple accounts work

Claude Code reads its login + settings from a config directory (default `~/.claude`).
Point it at a different directory with the `CLAUDE_CONFIG_DIR` environment variable
and you get a fully separate account (own login, own settings, own plugins/MCPs).

This tool maps **folders / git orgs → profiles → config dirs**, and flips
`CLAUDE_CONFIG_DIR` for you (just for that launch), after you confirm.

---

## Requirements

- Windows **PowerShell 5.1+**
- [Claude Code](https://www.claude.com/product/claude-code) installed and on your `PATH`

---

## Install

```powershell
git clone https://github.com/keven-bardales/claude-account-switcher.git
cd claude-account-switcher
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer:

- copies `claude-cli.ps1` to `~/.claude-cli.ps1`,
- creates `~/.claude-accounts.json` from the example (if you don't have one),
- adds one dot-source line to your PowerShell `$PROFILE` (idempotent).

Then **open a new PowerShell window** (or run `. $PROFILE`) to activate it.

> Execution policy: dot-sourcing a local script needs `RemoteSigned` (or looser).
> Check with `Get-ExecutionPolicy`; if it's `Restricted`, run
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

---

## Configure

Everything lives in **one central file**, `~/.claude-accounts.json` — never in your repos.

```json
{
  "default": "personal",
  "profiles": {
    "personal": "",
    "work": "C:\\Users\\you\\.claude-work"
  },
  "byPath": {
    "C:\\Users\\you\\code\\a-specific-work-repo": "work",
    "C:\\Users\\you\\work": "work"
  },
  "byOrg": {
    "your-work-github-org": "work"
  }
}
```

- **`profiles`** — name → config dir. `""` means the default `~/.claude`.
  Give each non-default profile its own dir (e.g. `~/.claude-work`).
- **`byPath`** — map a folder (or a specific repo path) to a profile.
  Longest matching prefix wins, so a child folder inherits its parent.
- **`byOrg`** — map a GitHub **org/owner** (read from the repo's `git remote`)
  to a profile. Great for "all repos under this org use that account" — no
  per-repo files, no folder discipline.
- **`default`** — used when nothing matches. Keep it `personal`.

**Resolution order:** `byPath` → `byOrg` → `default`.

### Add a second account

```powershell
cca login work     # opens Claude in the 'work' profile so you can /login once
```

(Or just `cd` into a folder/repo that maps to it and run `claude`; if that
profile isn't logged in yet, Claude will prompt you.)

---

## Usage

Just run `claude` like always — the wrapper handles the rest.

### `cca` — config CLI

```text
cca which              show which account THIS folder resolves to
cca list               print ~/.claude-accounts.json
cca edit               open the config in Notepad
cca set <profile> [p]  map a folder (default: current) to a profile
cca login <profile>    open Claude in a profile so you can /login
cca init               (re)create a starter config
cca path               print the config file path
```

### Overrides & automation

- At the confirm prompt, **type a profile name** to override just that run.
- Set `CLAUDE_ACCOUNT_YES=1` to **skip the prompt** (scripts/CI). It uses the
  resolved account without asking. Piped/redirected input also auto-proceeds.

---

## Edge cases it handles

- **Config file missing or invalid JSON** → it warns and **asks** before falling
  back to personal (never silently picks something).
- **Profile not logged in** → it warns; Claude then prompts you to `/login`.
  If a session expires, Claude re-prompts on launch as usual.
- **Not in a git repo / unmapped folder** → safe default (`personal`).

---

## Notes

- Each profile is an isolated config dir, so **plugins / MCP servers are
  per-account**. Install what you want in each (`claude plugin install ...` with
  the profile active, or `cca login <profile>` then `/plugin`).
- Tools that store data **machine-globally** (outside the config dir) are shared
  across profiles automatically — handy for things like a memory store you want
  available no matter which account you're on.
- Want the strongest guarantee? Add a `SessionStart` hook to each profile that
  re-checks the expected account — a belt-and-suspenders catch if you ever launch
  Claude without the wrapper.

---

## License

[MIT](LICENSE)

# chat-env — the chat assistant's session directory

Deploys to `/home/pi/halftone-chat/env/`:

| This repo | On the Pi | What it is |
|---|---|---|
| `chat-env/CLAUDE.md` | `~/halftone-chat/env/CLAUDE.md` | The assistant's standing instructions |
| `chat-env/settings.json` | `~/halftone-chat/env/.claude/settings.json` | The permission allowlist |

Note the move into `.claude/` on the way over. The file is flat here so it is
obvious in a diff, and `claude` only reads it from `.claude/` relative to its
working directory.

`halftone-chat.service` sets `WorkingDirectory=` to this directory, which is
what makes both files load. **That line is a permission boundary, not a
convenience.** Point it elsewhere and the session runs under whatever settings
it finds there instead.

## Why this file exists

JSON has no comments, and an allowlist with no rationale beside it is a list
nobody can safely edit later — every entry looks equally arbitrary, so either
none get removed or the wrong one does. This is that rationale.

## The shape: default-deny

`defaultMode` is `dontAsk`, and the runner passes `--permission-mode dontAsk`
as well. There is no human at this session — it runs from a path unit with its
output going to a JSON file — so there is nobody to answer a prompt. `dontAsk`
means anything not matched by an `allow` rule is refused rather than queued
behind a dialog that will never be answered.

That makes the `allow` list the entire capability surface. It is short on
purpose.

## What is allowed, and why

**`Read`, `Glob`, `Grep`** — unrestricted, minus what `deny` takes back. This
assistant's whole job is to answer questions about this box: which unit failed,
what the config says, why the disk is full. A read grant scoped to a couple of
directories would produce an assistant that mostly says it cannot see the file
you are asking about.

**The Bash list** is enumerated rather than opened, and every entry on it but
one is a command that reports state and changes none:

| Rule | For |
|---|---|
| `systemctl status *`, `list-units *`, `list-timers *`, `is-active *`, `is-enabled *` | The question this assistant exists to answer |
| `journalctl *` | Why a unit failed, which is never in `status` alone |
| `df *`, `du *` | Disk, the Pi's most common real problem |
| `free *`, `uptime`, `ps aux`, `ps -ef` | Memory, load, what is running |
| `uname *`, `vcgencmd *` | Kernel and the Pi's own throttle/temperature readings |
| `ip addr`, `tailscale status` | Network, and whether the tailnet is up |
| `cat /proc/{loadavg,meminfo,uptime,stat,cpuinfo,version,diskstats}`, `ls *` | The long tail the above misses |
| `/home/pi/feed-worker/reddit-fetch.py`, `... *` | Reddit, which blocks generic fetchers. A read-only RSS reader is the only way a session sees a thread at all |
| `/home/pi/halftone-chat/bin/memory *` | The assistant's own memory store, and the one rule on this list that writes anything (2026-08-25; see *What is not here*) |

**`ps` and `/proc` are enumerated, not opened, and that is a security fix, not
fussiness.** `ps auxe` (and `ps eww <pid>`) print another process's
*environment*, and `cat /proc/<pid>/environ` reads it straight off the kernel —
either one hands back the collector's `COLLECTOR_API_TOKEN`, and later the mail
credentials, out of a sibling process that runs as the same user. So `ps *` and
`cat /proc/*` are gone: `ps` is pinned to the two argument-free listings, and
`/proc` to the handful of system-wide files that carry no secret. The per-PID
environ/cmdline/maps files are also named in `deny` below, so the `Read` tool
cannot reach them either.

Note the shapes. `systemctl status *` allows the whole `systemctl` verb space
only for `status`; `systemctl restart foo` matches no rule and is denied.
`uptime`, `ip addr` and `tailscale status` carry no `*` at all — they take no
argument worth passing, and a trailing wildcard on them would allow
`tailscale status; anything`.

The space before each `*` matters: `Bash(systemctl status *)` prefix-matches
`systemctl status ` with the space, so it cannot also match a hypothetical
`systemctl status-and-restart`.

## What is denied, and why

`deny` wins over `allow`, which is what makes these entries meaningful even
though `Read` is granted broadly above.

- **`charon-mail/secrets/**`** — the mail agent's API keys and its Gmail app password.
- **`halftone-collector/.env`** and **`~/**/.env`** — the collector's API token
  is in the first. Reading it would let an answer print the credential that
  guards the dashboard this answer is displayed on.
- **`~/**/.claude/**`** — including this session's own settings file. An agent
  that can read its own allowlist is one prompt away from explaining exactly
  which commands it may run to whoever asked, and the file is of no use in
  answering a question about the box.
- **`~/.ssh/**`** — private keys.
- **`halftone-chat/env/**`** — this directory. Same argument as `.claude/**`,
  one level out: `CLAUDE.md` is the standing instruction, and an assistant
  quoting its own prompt on request is a way to find the seams in it.
- **`/proc/*/environ`, `/proc/*/cmdline`, `/proc/*/maps`** — the per-process
  files that leak another service's secrets from memory. The `Bash` allowlist
  no longer reaches these (see the `ps`/`/proc` note above); denying them for
  the `Read` tool too closes the same hole from the other side.

**`WebFetch` and `WebSearch` are not on this list any more.** Theirs was the
one entry that was a product decision rather than a security one: this is an
assistant about *this box*, everything it needs is on local disk or comes out of
a command, and the moment it can fetch a page every answer it gives has a second
possible source the reader cannot distinguish from the first. The owner reversed
that on 2026-08-18 and `allow` carries both today, on the argument that a
question about the outside world is better checked than guessed at from training
data. What the deny rule used to enforce moved into the standing instructions,
which require a source link on any claim that came off the web. One consequence
worth knowing: a turn that fetches anything is marked, and `bin/memory` refuses
to write for the rest of that turn.

## What is not here

**No `Edit`, no `Write`, and exactly one `Bash` rule that mutates anything.**
Not by oversight: `dontAsk` means the absence is the denial. The one rule is
`bin/memory` (2026-08-25), the allowlisted CLI this session writes its own
memory store through, and it is a program rather than a grant on purpose: the
flock, the journal, the taint gate and the size caps live inside it where
prompt discipline cannot drift them, and it reaches nothing on disk but
`~/halftone-chat/memory/`. Otherwise this session reads the box and writes
prose, and the only other files that move during a turn are `chat-runner.py`'s:
the thread record, and this lane's marker under `memory/.taint/`.

That is a weaker guarantee than a fully read-only lane's, and the difference
is worth stating plainly: a lane whose settings allow no writes at all cannot
corrupt what a scheduled job depends on. This one has
`Bash`, and a shell is a shell — the containment here is the enumerated list
plus `dontAsk`, not a proof.

**And that list is the *only* wall, because this session runs as `pi`.** The
OS gives a `pi` process ambient read of every `pi` file and every
same-user `/proc`, so the allowlist above is what stands between a
prompt-injected instruction and the box's secrets. The enumeration closes the
paths we know (`ps`/`/proc/environ`), but "the allowlist is the whole defense"
is a property worth removing, not just narrowing. The way to remove it is to
run this unit as a dedicated low-privilege user instead of `pi`: then the
secrets become a *different owner's* files and are unreadable no matter what the
allowlist says. **That decision is still open**, and until it is made, treat
every `deny` entry here as load-bearing.

## Changing this file

Adding a rule widens what a model may run on the Pi with no human in the loop.
Two questions before adding one:

1. Does it change state? If yes, it does not belong here at all. The single
   exception on the list, `bin/memory`, was taken deliberately on 2026-08-25
   and is argued under *What is not here*. A second one is a new decision
   argued the same way, not a precedent this one set.
2. Can its argument be a whole shell command? If the answer needs a `*`
   immediately after a word with no space, reconsider the rule shape.

Deploying a change means copying it to `~/halftone-chat/env/.claude/` on the
Pi. There is no reload — settings are read when a session starts, and every
turn is a new session.

# TAGS.md — the @-tag vocabulary, and how to add to it

An `@`-tag is a word typed into the chat composer that points a turn somewhere
before it is answered. `@cmo what is the watchlist tracking?` sends the same
message it always did, with a short block above it naming the CMO's roots and
the files worth opening first. **A tag is a prompt change and nothing else.**
It grants no permission the session did not already have: every root a tag
names is already on `env/settings.json`'s `additionalDirectories` and every
tool a tag orders is already on the allowlist, which is why the table on the Pi
is allowed to be a table rather than a negotiation.

Two kinds, nine words:

| tag | kind | what it does |
| --- | --- | --- |
| `@cmo` | architecture | ground the answer in the CMO's files |
| `@mail` | architecture | read the mail pipeline's own state |
| `@jarvis` | architecture | read the jarvis workspace, days and jobs |
| `@messages` | architecture | today's messages + summaries |
| `@web` | directive | search the web before answering |
| `@files` | directive | search this box before answering |
| `@box` | directive | measure this machine before answering |
| `@cite` | directive | every claim names the file or url it stands on |
| `@today` | directive | read only the last 24 hours |

An **architecture** is a place: a root, what to call it in a sentence, and the
files inside it worth opening first. A **directive** is an order: one
imperative sentence saying what the turn owes before it is answered. They
render differently on the wire and are told apart by their type rather than by
their shape. Everything else about them -- the boundary rule, the box the
composer draws, the dedupe, the completion list, the chip in the transcript --
is the same for both.

## Where a tag is written down

Two places, one per side of the wire, and **that is the whole of it**.

### The Mac: `Sources/Chat/ChatTags.swift`

`ChatTags.registry` is an ordered array of `TagSpec(name:kind:hint:)`.
`vocabulary` is derived from it, and the scan, the boundary rule, the chip, the
folded sigil, the composer's counter word and the derived thread title all come
back to that one array.

The order is the completion list's order and it is a decision: architectures
first, then directives, each group in the order it shipped. Add to the end of
the group the new word belongs to.

The hint is one lowercase clause, condensed from the runner's own label or
imperative for the same tag rather than written fresh -- so the row in the list
and the block on the wire cannot come to say different things.

### The Pi: `halftone-collector/chat-runner.py`

`TAG_TARGETS` is a dict of `Architecture(root, label, files)`,
`Directive(line)`, or `Digest(root, label, build)` -- the third shape
`@messages` earned for its precomputed digest. It was already the shape this
doc is asking for before the
registry existed on the Mac, and it needed no change to become one:

* `TAG_RE` builds its own alternation out of `TAG_TARGETS`' keys, so a tag that
  exists is a tag that matches;
* `tagged_context` renders off the entry's *type*, so a directive that grew a
  second field would still be a directive;
* `turn_tags` dedupes and lowercases without knowing any name.

So the Pi side of a new tag is one dict entry. There is no second place, and
nothing here should invent one.

## The recipe

Adding a word is four steps, in this order. `@messages` was the ninth and
went in this way; the Pi half of it ships with the messages runner change.

1. **One `TAG_TARGETS` entry** in `halftone-collector/chat-runner.py`.
   An `Architecture` if it names a root; a `Directive` if it names an order.
   A directive's line is one imperative sentence, in the same voice as the
   four already there: what the turn owes, and what the answer stands on when
   it is done. No em dashes -- this repo writes `--`.

2. **One `TagSpec` entry** in `Sources/Chat/ChatTags.swift`, appended to its
   kind's group. `name` is the same lowercase word, spelled identically. Both
   sides now know the word, and they know it once each.

3. **Check the two halves against each other by hand.** They are one contract
   in two languages and nothing in this tree diffs them for you: read
   `ChatTags.registry` and `TAG_TARGETS` side by side and confirm the new word
   is in both, spelled identically, and that neither list holds a word the
   other does not. Then type the near misses into the composer -- the plural, a
   truncation, an address that contains the word, and the shouted form -- since
   those are what the boundary rule below has to keep refusing.

4. **Deploy the runner.** The Mac half ships with the app; the Pi half does
   not. Until the runner on the box is the one with the new entry in it, the
   composer raises a token the runner ignores, which is the one failure mode
   this contract exists to prevent. Putting a new runner on a live box is a
   change to a running service: back up the file it replaces, and get the
   operator's explicit OK first.

## The boundary rule, stated once

Both halves answer the same three questions the same way. The Pi's half is the
regex `(?<![\w.@-])@(cmo|mail|jarvis|messages|web|files|box|cite|today)\b` with
`IGNORECASE`; the Mac's half is a character scan with no regex in it, because a
second dialect of the same rule is a second thing to keep true.

* **`@` may not be an infix.** A word character, a `.`, a `-` or another `@` in
  front of it means this is an address or a path, not a tag.
  `you@cmo.example.com` is mail; `@@cmo` is a typo.
* **The name may not have more word on the end of it.** `@cmojunk` is a word
  that starts with a tag and is not one. `@cmo,` at the end of a clause is a
  tag with a comma after it.
* **Case is ignored and the name is reported lowercased.** `@CMO` is what a
  keyboard does at the start of a sentence.

The completion list is built from these same two helpers rather than from a
third reading of the rule, so a half-typed `x@we` offers nothing for the same
reason a finished `x@web` is not a tag.

## What is not in the recipe

* **No permission change.** If a new tag would need a root the session cannot
  already read or a tool it cannot already run, that is a change to
  `env/settings.json` and its own decision -- not a line in this table.
* **No new machinery on the Pi.** The dict is the registry. A tag that wants
  its own rendering is asking for a new shape, which is a design decision
  about `tagged_context` and not an entry; `Digest` (for `@messages`) is the
  one such decision taken so far.
* **No growth for its own sake.** Nine words is already more than a person
  keeps in their head, which is why the completion list exists. The set is a
  list somebody maintains, not an open namespace.

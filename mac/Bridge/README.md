# Charon Bridge

The Mac half of the Messages channel. It has no window: it runs at login, reads
new rows out of Messages, keeps only the chats you have allowed, pushes them to
the collector on the Pi, and performs the replies you confirm in Charon. The
contract it speaks is `MESSAGES-PROTOCOL.md`, at the root of `mac/`.

Charon.app never talks to this program and this program never talks to
Charon.app. Both talk to the Pi, the same way the mail tab does.

It drives one dependency, the `imsg` CLI (MIT, pinned at 0.14.1), which is the
only thing here that opens `chat.db` or sends through Messages. The Bridge
fetches it once into its own Application Support directory, checks the archive
and the executable against digests compiled into the app, and refuses to run
anything that does not match. imsg's licence is written beside the binary.

## Installing it

```
xcodegen generate
xcodebuild -project HalftoneMail.xcodeproj -scheme CharonBridge \
           -configuration Debug -derivedDataPath ./DerivedData build
cp -R "DerivedData/Build/Products/Debug/Charon Bridge.app" /Applications/
open "/Applications/Charon Bridge.app"
```

Copy it somewhere permanent before the first launch. That launch registers the
app as a login item at the path it is standing in, and a login item pointing at
a DerivedData folder is a login item that breaks on the next clean build.

The first launch is also the only time it shows anything: one alert naming the
two permissions, with a button that opens the right pane of System Settings,
and one probe of Messages so macOS raises its Automation prompt while you are
still there to answer it. Every launch after that is silent.

It needs no setup of its own. The collector address is the `baseURL` preference
Charon.app already writes, and the token is the Keychain item Charon.app
already holds (`com.example.charon.collector`, account `bearer`, put
there by `scripts/connect-live.sh`). Rotating the token is rotate and restart,
for both halves. With no token in the Keychain the Bridge logs one line and
sits idle rather than retrying against a door it has no key to.

## The permissions

**Full Disk Access**, to read. `~/Library/Messages/chat.db` is behind it, and
without it every read fails and the console shows the channel degraded.
System Settings, Privacy & Security, Full Disk Access, add `Charon Bridge`.
macOS only re-reads that list at launch, so quit and start the app again after
granting it.

**Automation, Messages**, to send. The first send raises a prompt; approve it,
or pre-approve under System Settings, Privacy & Security, Automation, Messages.
Without it reads carry on and sends fail, which is the right way round.

The Bridge only reports which of those two it has. It never asks for either one
except through the alert on its first launch.

**Contacts**, optional, so your chats show people instead of phone numbers.
Without it the channel still works and every conversation is titled by its
handle: `+14085550142` rather than `Nadia Sorin`. It is the one permission this
program asks for directly, once, on a normal launch, and only when macOS has
never been asked before. Decline and that is the end of it: there is no second
prompt and no reminder on the next launch. System Settings, Privacy & Security,
Contacts is where you change your mind either way, and the Bridge notices and
re-sends the chat list within seconds rather than making you wait for the next
refresh.

The prompt is raised here because the grant belongs to the app that is asked,
and the helper the Bridge spawns inherits it. The helper is what actually reads
the address book; the Bridge never opens it. Nothing is written to Contacts,
and nothing new leaves the Mac: a resolved name is attached to a conversation
that was already being sent to the Pi. The heartbeat reports `contacts` the
same way it reports the other two.

## Running it by hand

```
"/Applications/Charon Bridge.app/Contents/MacOS/Charon Bridge" --once
```

`--once` does one `status` and one heartbeat and exits. It is the quickest way
to see whether the helper is installed, whether the database is readable and
whether the Pi is answering.

```
Bridge/tests/run-dry.sh      # the whole program against a fake helper and a stub Pi
Bridge/tests/run-units.sh    # framing, records, keys, names, page counts, the allowlist
```

`--dry-run` needs `CHARON_IMSG_PATH` and `CHARON_COLLECTOR_URL` and refuses to
work without them. It drives the helper and the collector those name, prints
every request it makes as a JSON line on stdout with message text replaced by a
character count, and will not download the real helper, register a login item
or run osascript. `--exit-after <seconds>` stops a normal run on a clock, and
`--log-level error|warn|info|debug` sets how much reaches the log.

## Reading a chat's history

Allowing a conversation in Charon backfills it. The moment a chat turns
`read: true`, the Bridge reads that conversation's entire history once, in
pages, and sends it to the Pi. It happens once per chat: switching one off and
on again does not do it a second time.

Those rows arrive **already read and are never triaged**. A thread you switch
on today should not land as four thousand unread messages, and nobody wants a
verdict on a text from March. The live stream is untouched by any of it, so the
cursor never moves backwards and a history landing does not delay a message
arriving now. One chat is read at a time and the pages share the helper with
the live watch, so a nine-year thread slows the backfill rather than the
stream. Stop the Bridge halfway through one and it resumes from where it was.

Progress shows in three places: a line per chat in the log, counted and never
quoted, `backfill a3ce320ae80d4efe: 1,240 rows in 3 page(s)`; the heartbeat's
`backfill` object, which the console reads as chats pending, chats done and
rows sent; and `state.json`, which holds the resume point for each chat.

## Attachments

Photographs go up on their own. Everything else waits to be asked for.

Right after the collector acks a batch of live messages, the Bridge uploads
every attachment of those rows that is an image, is not bigger than **10 MB**,
and is still on this Mac. Nothing else goes by itself: not video, not files,
not a bigger photograph, and not a single attachment out of a conversation's
backfilled history however small it is. Those go when somebody taps `fetch` on
the tile in Charon, which files a want on the Pi that this program answers on
its next three-second poll.

The reason for the split is the same one the backfill has. A conversation
switched on today should not spend the evening pushing nine years of pictures
up a home connection, and the photograph somebody sent a minute ago is the one
the thread is about to draw.

**The bytes go to the Pi and nowhere else.** One `PUT` per file over the same
tailnet connection everything else here uses, with the same bearer token, to
`/v1/messages/attachment/<key>/<n>`. The route accepts **25 MB**; anything over
that is reported nowhere and logged once. A file Messages has aged off this Mac
is never attempted at all, and Charon draws it as `not on this Mac`.

**Nothing is transcoded.** A HEIC goes up as a HEIC, at whatever size the
camera wrote it. Charon.app decodes it on the other side, which is one of the
few things a Mac app gets for free.

**Nothing about a photograph is logged but its count.** `uploaded 2 photos
(3.1 MB)` is the whole of a successful cycle. Not the filename, which came off
somebody's camera, and not the path, which names this home directory.

An upload that fails is tried again on the next cycle with the same backoff the
stream uses. Five failures on one file and it is left alone and said once; the
want expires on the Pi a week later.

## Where its things are

```
~/Library/Application Support/Charon Bridge/
  imsg/0.14.1/imsg            the pinned helper, hashed again at every spawn
  imsg/0.14.1/LICENSE-imsg.txt
  state.json                  the acknowledged cursor, which database it belongs
                              to, and how far each chat's history has been read
  allowlist.json              the collector's config, as last seen
  outbox-seen.json            outbox ids already acted on
  attachments-seen.json       where the file behind each forwarded attachment
                              was, so a `fetch` on an old photograph can be
                              answered without asking the database again
  first-run                   written once the permissions alert has been shown
~/Library/Logs/Charon/bridge.log        rotated at 5 MB, three kept
```

`CHARON_BRIDGE_HOME` moves all of it, log included, which is how the tests run
without touching an install.

## Stopping it

System Settings, General, Login Items & Extensions. Turn `Charon Bridge` off
and quit it. Nothing else on the Mac depends on it: Charon.app keeps working,
and the console shows the Messages channel degraded with the reason.

To take it out entirely, delete the app, that login item, and the two
directories above. Revoking Full Disk Access is worth doing at the same time.

## What it will not do

**It never retries a send.** The app files a reply, the collector queues it,
the Bridge performs it once and reports what happened. An outcome the helper
cannot vouch for is reported as exactly that, `may_have_completed`, and left
alone. The Bridge keeps its result on disk and retries the report after an
outage or restart. The thread offers a manual retry only when the helper
confirmed that sending never started and retrying is safe.

**It enforces the allowlist before anything leaves this Mac.** A row from a
chat that is not marked read is dropped here, counted, and never named in the
log. A send is checked against the same list again before it is performed, even
though the collector has already refused the ones it should.

**It never logs a message body.** Not at debug, not in the dry run's trace, not
in an error. Every line that could carry a path has the home directory replaced
with `~` on its way into the log.

**It never uploads a photograph nobody has asked for except a new one.** The
rule is in the attachments section above and it is enforced here rather than on
the Pi: history is remembered and never sent, and everything that is not a
small image waits for a tap in Charon.

**It calls six methods and no others.** `status`, `chats.list`,
`watch.subscribe`, `watch.unsubscribe`, `messages.after`, `send`. Nothing that
needs a helper injected into Messages, and nothing that could write to a chat
other than sending the text you confirmed. The injection dylib that ships in
the archive is deleted rather than installed, so that stays true by
construction.

**It starts at now.** A first run has no cursor and subscribes from the present
moment. Turning the channel on never replays a history nobody asked for.
Allowing one conversation asks for that conversation's, and only that one's.

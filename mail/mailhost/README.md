# mailhost

Charon's own mailbox, on the Pi, at **charon@example.com**. This directory
is the inbound bridge and the ops artifacts around it: a Cloudflare Email
Worker, the loopback daemon it POSTs to, a systemd unit, a tunnel config, and
the runbook for standing the whole thing up.

Nothing in here reads mail. `mail-poller.py` still does that, over IMAP --
it just points at `mail.example.com` now.

## Why it is shaped like this

A home uplink cannot host an MX. Port 25 inbound is blocked by the ISP, there
is no reverse DNS, and a residential address on a receiving MX is a
deliverability argument nobody wins. Outbound is the same argument twice over.
So both directions go through somebody else's IP:

```
 in:  sender ─ MX ─ Cloudflare Email Routing ─ charon-mail-bridge (Worker)
                ─ https://mail-ingest.example.com/ingest ─ cloudflared
                ─ ingest.py ─ smtp 127.0.0.1:25 ─ Stalwart ─ the mailbox
                ─ mail-poller.py over IMAP 993, as before

out:  mail-actions.py ─ submission 465 ─ Stalwart ─ smtp2go (TLS + auth) ─ world
```

No port is opened on the router. The Pi's address is in no DNS record. The
tunnel is outbound-only and the two mail listeners are bound to loopback.

## Files

| File | Deployed to | Job |
|---|---|---|
| `worker/wrangler.toml` | Cloudflare (from the Mac) | Worker config: name, entrypoint, `INGEST_URL`. The token is never in it |
| `worker/src/worker.js` | Cloudflare (from the Mac) | Hands raw MIME to the tunnel; rejects when the POST fails, so the sender keeps the message |
| `ingest.py` | `~/charon-mail/mailhost/` | Loopback HTTP daemon: bearer check, size cap, envelope check, SMTP injection |
| `ingest-env.example` | `~/charon-mail/secrets/ingest-env` | The three variables the daemon reads. Names, never values |
| `mail-ingest.service` | `/etc/systemd/system/` | Runs the daemon, `Restart=always`, `EnvironmentFile=secrets/ingest-env` |
| `cloudflared-config.yml` | `/etc/cloudflared/config.yml` | One ingress rule to `127.0.0.1:8789`, then a 404 catch-all |

`example.com` is the mail domain and `<TUNNEL_ID>` is what
`cloudflared tunnel create` prints. Both appear verbatim in these files and
have to be replaced on the way to the Pi.

---

## 1. Prereqs

- The domain's nameservers pointed at Cloudflare and the zone **active**. Email
  Routing and DNS-01 both need a zone Cloudflare actually serves.
- A **zone-scoped** API token, `DNS:Edit` on that one zone, for Stalwart's ACME.
  Not the Global API Key: this token lives on the Pi in a config file, and its
  blast radius should stop at one zone's DNS.
- `wrangler` on the Mac, logged in (`wrangler login`) to the account holding
  that zone.
- The Pi's NVMe mounted, and Tailscale up. Both are load-bearing below.

## 2. Stalwart on the Pi

Summary and the decisions that matter; their docs are the reference for the
rest.

- Install the latest **aarch64** release. Data directory on the **NVMe**, not
  the microSD: mail is the only state on this box that cannot be re-derived
  from a repo, and the card is the part that dies.
- Run it as its own system user. Not `pi` -- the mail workers, the collector
  and the agent all run as `pi`, and the mail store is the one directory
  none of them should be able to write.
- Listeners, **all bound to 127.0.0.1**:
  - `993` imaps -- what `mail-poller.py` reads
  - `465` submissions -- what `mail-actions.py` sends through
  - `25` smtp -- local injection only, from `ingest.py`. Configure it to trust
    loopback: that trust is what lets the daemon inject with no credential, and
    it is safe only because nothing off this box can reach the port. No MX
    points here and the ISP blocks 25 inbound anyway.
- Bind the admin UI to the **tailnet IP only**, same rule the collector follows.
- Create the domain `example.com` and the agent's account in the admin UI.
  That account's address and password become `CHARON_MAIL_ADDRESS` and
  `CHARON_MAIL_PASSWORD` in `secrets/mail-env`.
- ACME: Let's Encrypt with **DNS-01** via the zone token, for
  `mail.example.com`. DNS-01 and not HTTP-01, because HTTP-01 needs port 80
  reachable from the internet and this box does not have that.
- Add to `/etc/hosts` on the Pi:

  ```
  127.0.0.1  mail.example.com
  ```

  The workers connect to the name on the certificate over loopback. TLS
  verification matches the name, not the address it resolves to, so this is
  what lets `CHARON_IMAP_HOST=mail.example.com` verify against a listener
  that is not published anywhere.
- Outbound: **smart-host relay everything through smtp2go**, TLS with auth,
  credentials from their dashboard. Stalwart delivering directly from a
  residential IP is mail that lands in spam or is refused at the door.

## 3. smtp2go

- Create the account and an SMTP user. Those credentials go into Stalwart's
  relay config and nowhere else.
- Verify the sender domain: add their SPF `include:` and their DKIM CNAMEs to
  the Cloudflare zone. This is the half that decides whether Charon's replies
  are read or filed as junk, and it is the half that is easy to skip.
- Add a DMARC record while watching:

  ```
  _dmarc.example.com  TXT  "v=DMARC1; p=none; rua=mailto:charon@example.com"
  ```

  `p=none` on purpose. Tighten it after the reports show alignment, not before.

## 4. The Worker

From the Mac, in `mailhost/worker/`:

```bash
wrangler secret put INGEST_TOKEN     # the same value as secrets/ingest-env
wrangler deploy
```

Then in the dashboard, **Email Routing**:

1. Enable it on the zone and add the MX records it asks for. Those MX records
   are the entire inbound path -- Stalwart never receives from the internet.
2. Route `charon@example.com` to the `charon-mail-bridge` worker.
3. Optionally a catch-all to the same worker. Useful, and it is also how a
   misdirected rule starts injecting somebody else's mail, which is what
   `MAIL_DOMAIN` in the daemon is the backstop for.

A deployed worker with no routing rule is a worker nothing ever calls; the
deploy step alone changes nothing.

## 5. The tunnel

On the Pi:

```bash
cloudflared tunnel login
cloudflared tunnel create charon-mail                       # prints <TUNNEL_ID>
cloudflared tunnel route dns charon-mail mail-ingest.example.com
sudo install -m 644 cloudflared-config.yml /etc/cloudflared/config.yml
sudoedit /etc/cloudflared/config.yml                        # fill in the two placeholders
sudo cloudflared service install
```

`service install` writes the systemd unit itself, which is why there is no
`.service` file for it in this directory. Install the config first: the
generated unit reads it at startup.

## 6. The ingest daemon

On the Pi:

```bash
install -m 600 ~/charon-mail/mailhost/ingest-env.example ~/charon-mail/secrets/ingest-env
python3 -c "import secrets; print(secrets.token_hex(24))"   # paste into INGEST_TOKEN
$EDITOR ~/charon-mail/secrets/ingest-env                      # token, port, MAIL_DOMAIN
sudo install -m 644 ~/charon-mail/mailhost/mail-ingest.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mail-ingest
```

Fill the env file before enabling. Without a 24-character token the daemon
refuses to start, and `Restart=always` turns that into a loop systemd gives up
on after five tries -- clear it with `sudo systemctl reset-failed mail-ingest`.

## 7. Enable order, and the consent line

Daemons first, the reactive units next, the timer **last**:

```bash
sudo systemctl enable --now stalwart          # 1. the mailbox exists
sudo systemctl enable --now cloudflared       # 2. the tunnel is up
sudo systemctl enable --now mail-ingest       # 3. mail can arrive
sudo systemctl enable --now charon-mail-triage.path
sudo systemctl enable --now charon-mail-actions.path
sudo systemctl enable --now charon-mail-poll.timer   # 4. LAST
```

The poller is the ignition. Until its timer is enabled nothing is read,
nothing is classified and nothing is drafted, so each layer below can be
watched on its own before the one above it is armed. The rule the rest of this
repo runs on does not change here: `charon-mail-actions.path` is the only unit
that can act outside the Pi, it acts on a record a human made by clicking SEND
twice, and no model is in that path.

Every one of these stops the same way, independently:

```bash
sudo systemctl disable --now <unit>
```

## 8. Verify

```bash
# On the Pi: both listeners answer, and the certificate is for the name the
# workers will connect to. Fails loudly if the /etc/hosts line or ACME is wrong.
openssl s_client -connect 127.0.0.1:993 -verify_hostname mail.example.com \
  -verify_return_error -brief </dev/null
openssl s_client -connect 127.0.0.1:465 -verify_hostname mail.example.com \
  -verify_return_error -brief </dev/null

# From the Mac: the tunnel and the daemon, in one request. {"ok":true} means
# both; 502 means the tunnel is up and the daemon is not; a DNS failure means
# `tunnel route dns` never ran.
curl -fsS https://mail-ingest.example.com/health

# Then send a real message from an external Gmail to charon@example.com and
# watch it land. One line per message, and refusals are logged too.
journalctl -u mail-ingest -f
#   2026-08-20T11:04:12  charon@example.com  18422 bytes  accepted
```

Last, on the Pi, read the folder names off the server rather than assuming
them:

```bash
python3 - <<'PY'
import getpass, imaplib
c = imaplib.IMAP4_SSL("mail.example.com", 993)
c.login("charon@example.com", getpass.getpass())
for line in c.list("", "*")[1]:
    print(line.decode())
c.logout()
PY
```

Put what that prints into `CHARON_ARCHIVE_FOLDER` and `CHARON_SENT_FOLDER` in
`secrets/mail-env`. `maillib` defaults to `Archive` and `Sent`, which are not
guaranteed to be this server's names, and a folder name that does not exist is
an archive that fails once per message with nothing else wrong.

## Where it breaks, and who owns it

| Symptom | Layer |
|---|---|
| `curl /health` fails DNS | `tunnel route dns` never ran |
| `curl /health` returns 502 | tunnel up, `mail-ingest` down or on another port |
| Sender gets "Temporary local delivery failure" | the Worker's POST failed: token mismatch, or the daemon returned 451 because Stalwart refused |
| Nothing in `journalctl -u mail-ingest`, sender sees nothing | Email Routing has no rule for the address, so the Worker never ran |
| `refused: not a <domain> recipient` in the journal | an Email Routing rule is pointing another domain's mail at this worker |
| Mail arrives, `mail/index` stays empty | the poller: `CHARON_IMAP_HOST`, the `/etc/hosts` line, or the timer is not enabled |
| Replies land in spam | smtp2go: SPF include and DKIM CNAMEs in the zone |

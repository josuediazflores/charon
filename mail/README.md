# mail

The Charon mail and messages programs. They all run on the Pi under
`/home/pi/charon-mail`: an IMAP poller, the triage worker that runs a model, the
actions worker that can send, the messages worker behind the iMessage channel,
the prompts they stand on in `mail-env/`, their systemd units, and the test
suites that check them.

Where to go next:

- The root `README.md` is the map. It carries the setup order (step 4 is mail,
  step 5 is messages), the model providers `llm.py` speaks, and the list of
  example values to replace before a first run.
- `MESSAGES.md` is the message store's contract: what the collector writes, the
  three verbs, and the invariants with the greps that hold them.
- `mailhost/README.md` is a standalone runbook for the optional inbound path,
  which gives the agent its own mailbox on your own domain.

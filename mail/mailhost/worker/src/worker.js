/**
 * Cloudflare Email Worker: mail for example.com, POSTed at the Pi.
 *
 * Email Routing runs this for every message it accepts, and this hands the raw
 * MIME to mailhost/ingest.py over the tunnel. Nothing is parsed, rewritten or
 * decided here: the bytes DKIM was computed over are the bytes that go, and
 * every rule about what is mail and what is not lives in Stalwart.
 *
 * Workers runtime, so no Node APIs and no dependencies.
 */
export default {
  async email(message, env, ctx) {
    const raw = await new Response(message.raw).arrayBuffer();

    let delivered = false;
    try {
      const res = await fetch(env.INGEST_URL, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${env.INGEST_TOKEN}`,
          "Content-Type": "message/rfc822",
          // The envelope, which is not in the message: RCPT TO is what says
          // which mailbox this is for, and a To: header is only what the
          // sender typed.
          "X-Envelope-From": message.from,
          "X-Envelope-To": message.to,
        },
        body: raw,
      });
      delivered = res.ok;
    } catch {
      // A dead tunnel, a rebooting Pi, a DNS blip. Same answer as a refusal.
      delivered = false;
    }

    if (!delivered) {
      // The one thing this must never do is accept a message it did not
      // deliver. Rejecting hands it back to the sending MTA with this reason,
      // which requeues and tries again for days; swallowing it would lose the
      // mail silently, and no queue on this side would be as good as the one
      // the sender already has.
      message.setReject("Temporary local delivery failure; please retry");
    }
  },
};

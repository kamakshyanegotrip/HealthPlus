# Deployment

**The run-book is `../DEPLOY.md`.** It covers all four processes in the order they have to be
brought up, with a check after each step.

This file used to describe the web app and the worker separately from the repo root's
document, which covered the pg-boss worker. Between them they described two of the four
processes, and after the R10 cutover several things they said were no longer true:

- `SUBJECT_HMAC_KEY` was listed as a variable to set. It does not exist any more —
  `SUBJECT_KEY_WRAPPING_KEY` replaced it, and setting the old one has no effect.
- `RED_FLAG_RULESET_VERSION` was listed. Nothing reads it; `safety.adopted_rule_set()` replaced
  it at R3.
- `POLICY_VERSION` was described as "not currently read by any code path". It is written into
  every row of `obs.response_audit`.
- `DATABASE_URL_REASONER` and `DATABASE_URL_REDFLAG` were not mentioned at all, and the app now
  refuses to start without them.
- It said to apply "the real database migrations (not `db/*.sql` — those are this repo's own
  stub schema)". `chat-pipeline/db/` no longer exists; `migrations/` is the only schema.

Two documents describing one deployment is how they came to disagree, so there is now one.

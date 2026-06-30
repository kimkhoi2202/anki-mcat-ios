# Self-hosted Anki sync server (Fly.io)

A version-matched Anki sync server for the AnkiSpeedrun iOS app. The app's sync
engine is built from Anki commit `b00308e5` (unmodified upstream `rslib`); this
server is pinned to the **same commit**, so the v11 sync protocol matches the
client exactly. (A version skew is what made AnkiWeb's older server reject our
full upload with `"missing original size"`.)

## Deploy
```bash
cd deploy/syncserver
fly apps create anki-mcat-sync
fly volumes create anki_data --size 1 --region iad -a anki-mcat-sync
# Set the sync account (username:password) — never commit this:
fly secrets set SYNC_USER1="anki:<password>" -a anki-mcat-sync
fly deploy -a anki-mcat-sync
```
The Rust build of the Anki core takes ~10–20 min on first deploy.

## Use from the app
In the app's Sync login: set **Custom sync server** to
`https://anki-mcat-sync.fly.dev/` and log in with the `SYNC_USER1` credentials.

## Notes
- `SYNC_PORT` (8080) and `SYNC_BASE` (`/anki_data`, the mounted volume) are fixed
  by `entrypoint.sh`; override users via additional `SYNC_USERn` secrets.
- To upgrade the engine version, bump the `--rev` in the Dockerfile to the new
  commit and `fly deploy` again.

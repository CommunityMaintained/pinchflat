> [!CAUTION]
> Unfortunately, I won't be able to provide any further work on Pinchflat or Tubeless for personal reasons. Here is a DB rollback script you can use to safely return to the original Pinchflat. No new images or updates will be provided. I'm sorry for any false hope I may have given you.

# Rolling back the database

> [!TIP]
> The rollback is necessary for Tubeless and recommended for Pinchflat forks.

`rollback.sh` reverses the 18 migrations from `20260618215000` to
`20260805120000`, so you can go return back to the original Pinchflat.

The script shows the migration plan and asks for a configramtion before making any changes. A backup is written next to the database automatically.

Stop Tubeless before running it.

You have a few options:

## Database on the host (bind mount)

- Needs `sqlite3` 3.35+ and `bash`
- Use this option if you have direct access to the database

```bash
docker stop tubeless
./rollback.sh /your/config/path/db/pinchflat.db
```

Then switch to the older image tag and start it again.

## Database in a named volume

- No dependencies option
- Start a throwaway container from the Tubeless image that runs the script instead of the app, so nothing else has the database open:
- Make sure you use the correct named volume

```bash
docker stop tubeless

docker run --rm -it \
  -v tubeless_config:/config \
  -v "$PWD/rollback.sh:/rollback.sh:ro" \
  ghcr.io/communitymaintained/tubeless:latest \
  bash /rollback.sh /config/db/pinchflat.db
```

The image already has `bash` and a recent `sqlite3`, so nothing needs installing.
Then start the older image against the same volume.

Podman: same commands with `podman` (add `:z` to the mounts if SELinux is
enforcing). Compose: `docker compose stop`, change the `image:` tag,
`docker compose up -d`.

## Finish up

**Switch the image tag before starting Tubeless again.** Migrations run on every boot, so starting the new image once more re-applies them and undoes the rollback.

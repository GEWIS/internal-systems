#!/bin/sh
# Ensures every "Organ - <name>" group has a team folder named <name> that the group
# can read, write, share and delete in. user_oidc creates the groups on login; the
# organ-folders sidecar in deployment.yaml runs this script every minute.
# Idempotent: groups that already have a folder are left untouched, so folders can be
# renamed or have their permissions changed in the admin UI.
set -eu

occ() { php -f /var/www/html/occ "$@"; }

# Skip quietly while Nextcloud is being installed, upgraded or in maintenance mode.
ready=$(php -r '
  $s = json_decode($argv[1], true);
  echo ($s["installed"] ?? false) && !($s["maintenance"] ?? true) && !($s["needsDbUpgrade"] ?? true) ? 1 : 0;
' "$(occ status --output=json)")
[ "$ready" = 1 ] || exit 0

groups=$(occ group:list 'Organ - ' --limit=10000 --output=json)
folders=$(occ groupfolders:list --output=json)

# One line per organ group without a folder: "<folder id or -> <gid>". A folder that
# already has the organ's name but no groups is left over from an interrupted run and
# gets reused; a name clash with a folder owned by other groups is reported, not taken.
todo=$(php -r '
  $prefix = "Organ - ";
  $covered = [];
  $byName = [];
  foreach (json_decode($argv[2], true) as $f) {
    $covered += $f["groups_list"];
    $byName[$f["mountPoint"]] = $f;
  }
  foreach (array_keys(json_decode($argv[1], true)) as $gid) {
    $gid = (string)$gid;
    if (!str_starts_with($gid, $prefix) || isset($covered[$gid])) {
      continue;
    }
    $existing = $byName[trim(substr($gid, strlen($prefix)))] ?? null;
    if ($existing === null) {
      echo "- $gid\n";
    } elseif ($existing["groups_list"] === []) {
      echo $existing["id"], " $gid\n";
    } else {
      fwrite(STDERR, "==> team folder \"{$existing["mountPoint"]}\" belongs to other groups, not assigning it to \"$gid\"\n");
    }
  }
' "$groups" "$folders")

printf '%s\n' "$todo" | while read -r id gid; do
  [ -n "$gid" ] || continue
  if [ "$id" = - ]; then
    id=$(occ groupfolders:create "${gid#Organ - }")
  fi
  occ groupfolders:group "$id" "$gid" read write share delete
  echo "==> team folder $id assigned to \"$gid\""
done

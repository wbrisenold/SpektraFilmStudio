# Oracle Free VM → iCloud Drive: Lightroom original migration

These are **server-side transfer tools**. Your personal Mac is **not the migration host**. They are supplied together with the editor patches in the parent ZIP. The `rclone` iCloud Drive backend is unofficial/experimental; an end-to-end pilot is mandatory. Do **not** remove originals from Lightroom until every file is verified and backed up.

## What is implemented

1. `transfer.py`: signed authorized direct-original HTTPS URLs → iCloud Drive via `rclone rcat`; streams in bounded chunks, records SQLite progress, compares expected Content-Length, optional supplied SHA-256, and remote size. Refuses to overwrite different remote files. Retries by reopening the URL rather than storing 2 TB on Oracle.
2. `bulk_zip_migrate.py`: official Adobe **Download all synced files** export archives → iCloud Drive. Downloads **one ~4 GB ZIP at a time onto the Oracle VM's staging disk**, streams each archive member to iCloud, validates ZIP CRC and remote size, then deletes the staged archive. It **never downloads the archive to your Mac**. The links you provide must point directly to the authorized ZIP bytes. The archive may include previews/XMP sidecars and latest edits; it does not reproduce Lightroom's cloud album hierarchy automatically.
3. `oracle-check.sh`: checks for Python, current rclone version, and authenticated iCloud Drive access.
4. Manifest templates and offline tests. No Apple ID, Adobe refresh token, 2FA code, or signed download URL is provided or stored in the ZIP.

## Set up on Oracle Linux / Ubuntu (after provisioning Always Free VM)

- Create a VM yourself in Oracle Cloud, staying within your account's Always Free allocation; capacity varies by region. Limit inbound ports. **You do not need to expose an HTTP transfer API to the internet**: the scripts run via SSH and connect out over HTTPS. Store authentication files with `chmod 600` and use a non-root user.
- Install a **current official rclone release (>=1.69)**, Python 3, and ca-certificates. Your Linux distribution's older rclone package might lack the iCloud backend.
- Run `rclone config`; create a remote named **`icloud`**, backend `iclouddrive`, service `drive`, authenticate with your real Apple ID and 2FA using rclone's interactive setup. Do not publish `rclone.conf`. The trust token may require renewal approximately every 30 days (`rclone config reconnect icloud:`). The backend is unofficial and might stop working if Apple changes its private API.
- Run `./oracle-check.sh`, then test a tiny non-sensitive file upload with `rclone rcat icloud:SpektraFilm-Library/pilot-test.txt`.

### Path A — Adobe's official bulk archive export (more accessible)

Request [Download all synced Lightroom files](https://lightroom.adobe.com/lightroom-library-download) in your Adobe account. Adobe prepares ZIP archives (often ~4 GB each). After completion, authorized download links arrive by email and expire; these tools **cannot automatically request Adobe exports** or discover expiring links from your private email. Obtain approved direct-download URLs from your own export. If Adobe provides login-only HTML links rather than direct HTTPS archive URLs, do not assume these will work from Oracle: test one archive. Use the manifest template (file permission `600`).

```bash
chmod 600 adobe-zips.json
python3 bulk_zip_migrate.py validate --manifest adobe-zips.json --allowed-host your-reviewed-adobe-download-host.example
python3 bulk_zip_migrate.py pilot --manifest adobe-zips.json --allowed-host your-reviewed-adobe-download-host.example
# Inspect actual RAW & XMP files in iCloud Drive before full migration.
python3 bulk_zip_migrate.py migrate --manifest adobe-zips.json --allowed-host your-reviewed-adobe-download-host.example
```

The `--allowed-host` value must be an actual host of a trusted Adobe-generated download link or approved CDN. Do not supply untrusted URLs. A ~4 GB ZIP requires **at least ~4.5 GB free disk** on the Oracle VM for that archive, even though the originals never touch your personal Mac. More space is recommended. Archive images/XMP are stored as individual iCloud Drive files, not a single ZIP; path traversal is rejected.

### Path B — authorized Lightroom Cloud original-file URLs

Requires an **Adobe-entitled Lightroom API integration** with accessible authorized *original* download URLs, not just a native-app registration. This package does not claim Adobe provides an original-download API endpoint without that entitlement, and will not treat JPEG renditions as RAW originals.

```bash
chmod 600 original-links.json
python3 transfer.py validate --manifest original-links.json
python3 transfer.py pilot --manifest original-links.json
python3 transfer.py migrate --manifest original-links.json
```

`ADOBE_ACCESS_TOKEN` can be supplied in the server environment for Adobe `lr.adobe.io` requests only. For alternate CDN redirect hosts, allow only audited suffixes with `--allowed-host`. Direct links containing signatures are secrets; never publish the manifest. Each failed file is retried by reopening its URL (it must still be valid). Storage path is `icloud:SpektraFilm-Library/Originals/...` by default.

## Risks / verification limits

- **iCloud is the permanent destination, not Oracle Object Storage**. VM disk is temporary (bulk archives only) and SQLite stores transfer status, not your RAWs. No B2 or R2 charges are necessary for these tools.
- Oracle's **10 TB/month free outbound allowance** may cover ~2 TB sent to iCloud, subject to other Oracle outbound use and VM/free-tier conditions. It does not grant 2 TB free iCloud storage.
- The rclone iCloud backend depends on Apple's private behavior and may fail for specific file types/sizes or after authentication changes. `rclone rcat --size` attempts streaming; actual backend buffering/spooling must be measured on the VM before a large migration. If it fails, stop: do not assume a full 2 TB transfer will work.
- **Size + source-side SHA-256 do not establish destination-side SHA-256 equality.** ZIP CRC checks the downloaded ZIP contents, and the script compares remote object sizes, but a true destination cryptographic audit would require reading back and hashing uploaded data (potentially another ~2 TB of traffic). Don't delete Adobe originals on size checks alone.
- iCloud Drive files remain accessible through macOS File Provider. macOS may cache a RAW internally before SpektraFilm copies it onto external scratch. The editor's external-scratch patch cannot guarantee zero internal iCloud File Provider caching.
- Lightroom edits/develop may not be exactly reproducible by the SpektraFilm engine. This migration preserves original files and any provided sidecars but **does not fully implement a Lightroom Cloud-to-SpektraFilm catalog mapper**.
- No Oracle account has been provisioned, no Apple/Adobe credentials were used, no end-to-end cloud transfer has been verified, and no full Intel Xcode build was performed.

Sources: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm · https://rclone.org/iclouddrive/ · https://rclone.org/commands/rclone_rcat/ · https://helpx.adobe.com/lightroom/web/share-your-work/review-and-download/download-all-synced-files.html

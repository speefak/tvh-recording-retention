# Tvheadend Recording Retention

A configurable retention management script for automatically managing **Tvheadend recordings**.

`tvh-recording-retention` automatically removes recordings according to configurable retention rules:

* Keep recordings for a defined number of days
* Keep only the latest X recordings
* Combine both retention methods

The script can also remove orphaned Tvheadend DVR log entries after recording files have been deleted.

---

## Features

* Automatic recording retention management
* Delete recordings older than a configured number of days
* Keep only the latest **X recordings**
* Combine age-based and count-based retention rules
* Individual retention rules for each recording name
* Supports `.ts`, `.mkv` and `.mp4` recordings
* Preview all recordings
* Displays all files selected for deletion
* 10-second cancellation period before deletion
* Automatically removes matching DVR log entries
* Removes previously orphaned DVR log entries
* Automatically detects the Tvheadend DVR log directory
* Safe Tvheadend service restart
* Detects active recordings
* Detects active DVB frontend usage
* Detects active Tvheadend network streams
* Test mode for checking the current busy/idle status
* Logging support

---

## Requirements

The script is designed for Linux systems running:

* Tvheadend
* Bash
* systemd

The following tools are used:

```text
find
grep
awk
sed
stat
numfmt
locate
fuser
nethogs
systemctl
```

### Install required packages

For active Tvheadend network stream detection:

```bash
sudo apt install nethogs
```

For automatic DVR log directory detection:

```bash
sudo apt install plocate
sudo updatedb
```

---

## Installation

Clone the repository:

```bash
git clone https://github.com/YOUR_USERNAME/tvh-recording-retention.git
cd tvh-recording-retention
```

Make the script executable:

```bash
chmod +x tvh-recording-retention.sh
```

Optional system-wide installation:

```bash
sudo cp tvh-recording-retention.sh /usr/local/bin/tvh-recording-retention
sudo chmod +x /usr/local/bin/tvh-recording-retention
```

---

## Configuration

The script automatically creates a default configuration file when it does not already exist.

Recommended configuration file:

```text
/var/lib/tvheadend/tvh-recording-retention.conf
```

Example:

```text
# Format:
# <Recording Name> <keep_days> <keep_count>

Tagesschau              3    0
Tagesthemen             3    0
Tatort                  0    5
Polizeiruf 110          0    5
Spacetime               0    0
```

### Configuration format

```text
<Recording Name> <keep_days> <keep_count>
```

### `keep_days`

Defines how many days recordings are retained.

Example:

```text
Tagesschau 3 0
```

Recordings older than 3 days are deleted.

Setting the value to `0` disables age-based deletion.

### `keep_count`

Defines how many of the newest recordings are retained.

Example:

```text
Tatort 0 5
```

Only the newest 5 matching recordings are retained.

Setting the value to `0` disables count-based retention.

---

## Usage

### Show help

```bash
./tvh-recording-retention.sh -h
```

---

### Run recording retention

```bash
sudo ./tvh-recording-retention.sh -r
```

The script:

1. Reads the configured retention rules
2. Searches for matching recordings
3. Applies age-based retention rules
4. Applies recording count limits
5. Displays a deletion summary
6. Waits 10 seconds before deletion
7. Allows cancellation by pressing any key
8. Deletes the selected recordings
9. Removes matching DVR log entries

---

### Clean orphaned DVR entries

```bash
sudo ./tvh-recording-retention.sh -o
```

This scans the Tvheadend DVR log directory and removes entries whose recording files no longer exist.

This is useful if recordings were manually deleted outside of Tvheadend.

---

### Test Tvheadend busy status

```bash
sudo ./tvh-recording-retention.sh -t
```

No changes are made.

The script checks whether Tvheadend is currently busy because of:

* an active recording
* an active DVB frontend
* active Tvheadend network traffic

Example:

```text
Status: BUSY — a restart would be skipped right now.
```

or:

```text
Status: IDLE — a restart would proceed right now.
```

---

### Edit configuration

```bash
./tvh-recording-retention.sh -e
```

The configuration file is opened with `nano`.

---

### Show configuration

```bash
./tvh-recording-retention.sh -s
```

---

### List recordings

```bash
./tvh-recording-retention.sh -l
```

Lists all supported recording files.

---

## Options

| Option | Description                     |
| ------ | ------------------------------- |
| `-r`   | Run recording retention cleanup |
| `-o`   | Remove orphaned DVR entries     |
| `-t`   | Test Tvheadend busy/idle status |
| `-e`   | Edit configuration              |
| `-s`   | Show configuration              |
| `-l`   | List all recordings             |
| `-h`   | Show help                       |

Options can be combined.

Example:

```bash
sudo ./tvh-recording-retention.sh -r -o
```

Processing order:

```text
1. Recording retention cleanup (-r)
2. Orphaned DVR cleanup (-o)
3. Configuration/display options
```

---

## DVR Entry Cleanup

Tvheadend stores DVR information separately from the actual recording files.

If a recording file is deleted manually, the corresponding DVR entry can remain visible in Tvheadend or TVHadmin-JS.

`tvh-recording-retention` automatically removes the matching DVR log entry when it deletes a recording.

The `-o` option can additionally scan all existing DVR entries and remove entries whose recording files no longer exist.

---

## Safe Tvheadend Restart

After DVR entries have been removed, Tvheadend may need to be restarted to refresh its DVR information.

Before restarting the service, the script checks whether Tvheadend is currently busy.

The restart is skipped when:

* a recording is actively being written
* a DVB frontend is currently in use
* Tvheadend is actively sending or receiving stream traffic

This helps prevent interruptions to recordings and active streams.

If Tvheadend is busy, the restart is skipped and can be performed during the next cleanup run.

---

## Logging

Recommended log file:

```text
/var/log/tvh-recording-retention.log
```

The log contains information about:

* processed retention rules
* recordings marked for deletion
* deleted recordings
* removed DVR entries
* orphaned DVR entries
* Tvheadend activity checks
* service restart decisions

---

## Automation with Cron

Example: Run the retention cleanup every day at 04:00.

Open the root crontab:

```bash
sudo crontab -e
```

Add:

```cron
0 4 * * * /usr/local/bin/tvh-recording-retention -r -o
```

Because the script may restart Tvheadend, it is recommended to schedule it during a time when recordings and streams are unlikely to be active.

The script checks the Tvheadend activity status before restarting the service.

---

## Important Notes

> **Warning:** Recording files selected by the retention rules are permanently deleted.

Before enabling automated execution:

1. Verify the recording directory.
2. Check the configuration rules.
3. Ensure recording names match your filenames.
4. Use `-l` to inspect existing recordings.
5. Run the script manually before creating a cron job.

Example:

```bash
sudo ./tvh-recording-retention.sh -r
```

Before deletion, the script displays all selected files and provides a 10-second cancellation period.

---

## Example Workflow

### 1. Configure retention rules

```bash
sudo ./tvh-recording-retention.sh -e
```

### 2. Check available recordings

```bash
./tvh-recording-retention.sh -l
```

### 3. Test Tvheadend activity detection

```bash
sudo ./tvh-recording-retention.sh -t
```

### 4. Run recording retention

```bash
sudo ./tvh-recording-retention.sh -r
```

### 5. Remove orphaned DVR entries

```bash
sudo ./tvh-recording-retention.sh -o
```

### Complete maintenance run

```bash
sudo ./tvh-recording-retention.sh -r -o
```

---

## Naming

The project uses the following naming scheme:

```text
Repository: tvh-recording-retention
Script:     tvh-recording-retention.sh
Config:     tvh-recording-retention.conf
Log:        tvh-recording-retention.log
```

---

## License

This project is licensed under:

**CC BY-NC**

You may use and modify this project for non-commercial purposes with appropriate attribution.

---

## Author

**Speefak**

---

## Changelog

### Version 1.2

* Improved Tvheadend restart status output
* Recording activity checks are always displayed and logged
* DVB frontend status checks are always displayed and logged
* Tvheadend network traffic checks are always displayed and logged

### Version 1.1

* Automatic DVR log directory detection
* Automatic removal of matching DVR entries
* Added orphaned DVR entry cleanup
* Added `-o` option
* Added `-t` diagnostic mode
* Improved root permission checks
* Added safe Tvheadend restart protection
* Active recording detection
* DVB frontend usage detection
* Per-process network traffic detection via `nethogs`

### Version 1.0

* Initial release
* Configurable retention by recording age
* Configurable retention by number of recordings retained


### Donations

If you find the adapter useful and would like to support future development:

```text
Bitcoin (BTC):
33AXe8Z8XBuGKx9eHHmGnvbawrNYjSgDcM

Ethereum (ETH):
0xa61d178EA84C2200A8617b51B4bCf98F87ff59Ff

Solana (SOL):
BDf5EgsN8fRUicYzeM8cuaNhL7zdty2qsEjmC2jA4Fm

Ripple (XRP):
rLHzPsX6oXkzU2qL12kHCH8G8cnZv1rBJh

Cardano (ADA):
addr1q8anur2wvvc6pv3cpp30vv05makyra8huh0lk0yhdk6hcnlrzr27g03klu862usxqsru794d03gzkk8n86ta34n85z0svn5ams

USDT:
0xa61d178EA84C2200A8617b51B4bCf98F87ff59Ff
```

Thank you for supporting open-source development.


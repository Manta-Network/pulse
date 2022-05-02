# pulse agent

the pulse agent is a systemd service that runs on substrate nodes to keep them synchronised with expected state.

it performs software and configuration updates to running nodes.

it consists of:

- `pulse-agent.service`:

  a systemd unit file which runs continuously after system startup and with a configurable wait between iterations

- `pulse-agent.sh`:

  a wrapper script which is triggered by the systemd unit file. its purpose is to download and run the latest version of the agent

- `pulse.sh`:

  the system maintenance script which synchronises system state

- `install-pulse-agent.sh`:

  the installer


## how it works

the service triggers a run of `pulse.sh` every 5 minutes (configured in `pulse-agent.service`).

`pulse.sh` checks for any local configuration that is out of sync with the expected state of the system as defined by the system config in this repository (under `/config/$(hostname -d)/$(hostname -f)`). any configuration found to be out of sync, is corrected during the run.

each run checks the following configuration items:

### watched paths

pulse ensures that the following paths contain an up to date copy of files that this repository hosts for the following filesystem paths:

- `/etc/sudoers.d`: sync user sudo config
- `/usr/share/keyrings`: sync package repository keyrings
- `/usr/local/bin`: sync script files (or possibly small binaries)
- `/etc/apt/sources.list.d`: sync apt repo.list files
- `/etc/nginx/sites-available`: sync nginx site, domain and cert configuration
- `/etc/systemd/system`: sync systemd unit files
- `/usr/lib/systemd/system`: sync systemd unit files

each watched path has a specific command or set of commands, that runs before and after a file is changed. for example, before a systemd unit file is changed, its service is stopped (`sudo systemctl stop ${unit}`), after the file has changed systemd is reloaded and the service is started (`sudo systemctl daemon-reload`, `sudo systemctl stop ${unit}`). the nature of the commands that run is specific to each watched path. consult the [code](https://github.com/Manta-Network/pulse/blob/main/agent/pulse.sh), look for: `pre change action`, `post change success action`, `post change failure action` and `post change action`.

### users

- pulse creates any users specified in /config/$(hostname -d)/$(hostname -f)/cloud-config.yml/users which do not already exist.
- pulse updates ${HOME}/.ssh/authorized_keys with values from `.users[*].ssh_authorized_keys`

### packages

- pulse installs packages specified in /config/$(hostname -d)/$(hostname -f)/cloud-config.yml/packages which are already installed.


## installation

pulse-agent is supported on recent versions of ubuntu and fedora. run the one-liner below from a terminal to install it, using an account that has sudo privileges.

```bash
curl \
  -sLH 'Cache-Control: no-cache, no-store' \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/agent/install-pulse-agent.sh | bash
```

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


## installation

pulse-agent is supported on recent versions of ubuntu and fedora. run the one-liner below from a terminal to install it, using an account that has sudo privileges.

```bash
curl \
  -sLH 'Cache-Control: no-cache, no-store' \
  https://raw.githubusercontent.com/Manta-Network/pulse/main/agent/install-pulse-agent.sh | bash
```

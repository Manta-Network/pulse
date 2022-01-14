# manta node observer

the node observer service is responsible for collecting information about the state of running services on manta and calamari parachain nodes as well as testnet relay nodes.

as the name implies, it observes only and does not interfere with or modify existing configuration.

the implementation includes:

- `observe.sh`, a bash script named which:
  - queries the aws running node lambdas for each manta aws account
    - [manta-ops](https://7p1eol9lz4.execute-api.us-east-1.amazonaws.com/prod/instances)
    - [manta-dev](https://mab48pe004.execute-api.us-east-1.amazonaws.com/prod/instances)
    - [manta-service](https://l7ff90u0lf.execute-api.us-east-1.amazonaws.com/prod/instances)
    - [manta-prod](https://hzhmt0krm0.execute-api.us-east-1.amazonaws.com/prod/instances)
  - checks what ip address is returned by a dns lookup of the node's fully quallified domain name
- `observe.service`, a systemd service unit descriptor which:
  - downloads the latest version of `observe.sh`
  - runs `observe.sh`
  - pauses for a configured duration
  - restarts and reruns in a continuous loop

the observer runs on kavula.pelagos.systems, a maintenance server. service logs are visible at: https://cockpit.kavula.pelagos.systems/system/services#/manta-node-observe.service

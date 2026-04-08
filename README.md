# dead_code_detector

Identifies unused Puppet classes and modules by cross-referencing class definitions on a Puppet Primary Server against catalog data in PuppetDB. Helps you keep your codebase clean by surfacing code that is no longer assigned to any node.

## Table of Contents

1. [Description](#description)
1. [Requirements](#requirements)
1. [Usage](#usage)
    * [Running the task](#running-the-task)
    * [Task parameters](#task-parameters)
    * [Output](#output)
1. [Limitations](#limitations)

## Description

`dead_code_detector` queries your Puppet Primary Server for all known class definitions in a given environment, then cross-references those against the classes actively appearing in catalogs recorded in PuppetDB. Any class that has never appeared in a catalog (within the configured staleness window) is considered unused.

The results are returned as a JSON report listing:

- **Unused classes** — classes defined on the server but not present in any active node's catalog.
- **Unused modules** — modules where every class they contain appears in the unused list.

## Requirements

- Puppet Enterprise with PuppetDB enabled.
- The task must be run **targeting the Primary Server** — it uses the node's own Puppet SSL certificates to authenticate against both the Puppet Server API and PuppetDB.
- The `pe_node_manager` or equivalent RBAC permission to run tasks on the Primary Server.

## Usage

### Running the task

Run the `dead_code_detector::generate` task targeting your **Primary Server** node via the PE console or the `puppet task` CLI.

**Using the PE Console:**

1. Navigate to **Tasks** in the PE console.
2. Select the `dead_code_detector::generate` task.
3. Set the target to your Primary Server.
4. Set any desired parameters (see below) and click **Run task**.

**Using the CLI:**

```bash
puppet task run dead_code_detector::generate \
  --nodes <your-primary-server-fqdn>
```

With optional parameters:

```bash
puppet task run dead_code_detector::generate \
  environment=development \
  stale_days=60 \
  --nodes <your-primary-server-fqdn>
```

### Task parameters

All parameters are optional. When omitted, the task uses sensible defaults derived from the target node's own Puppet configuration.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `puppetserver_host` | `String` | Target node certname | Hostname or IP of the Puppet Server |
| `puppetdb_host` | `String` | Target node certname | Hostname or IP of PuppetDB |
| `puppetserver_port` | `Integer` | `8140` | Puppet Server HTTPS port |
| `puppetdb_port` | `Integer` | `8081` | PuppetDB HTTPS port |
| `environment` | `String` | `production` | Puppet environment to analyse |
| `stale_days` | `Integer` | `30` | Exclude nodes whose last report is older than this many days |
| `cert` | `String` | Target node's Puppet certificate | Path to a PEM-encoded client certificate |
| `key` | `String` | Target node's Puppet private key | Path to a PEM-encoded client private key |
| `ca_cert` | `String` | `/etc/puppetlabs/puppet/ssl/certs/ca.pem` | Path to the PEM-encoded CA certificate |

### Output

The task returns a JSON object with two keys:

```json
{
  "unused_classes": [
    "mymodule::someclass",
    "otherapp::configure"
  ],
  "unused_modules": [
    "otherapp"
  ]
}
```

`unused_modules` lists only modules where **all** of their classes appear in the `unused_classes` list.

## Limitations

- **Classes only.** This tool currently detects unused *classes* and *modules whose classes are all unused*. It does not detect unused defined types, functions, facts, or other Puppet code constructs.
- **Catalog-based analysis.** Detection relies on catalog data in PuppetDB. Nodes that have not checked in within `stale_days` (default: 30) are excluded from the active set and their classes will not count as "in use". Adjust `stale_days` if your environment has infrequently reporting nodes you still want to account for.
- **Single environment.** Each task run analyses one environment at a time. Run the task multiple times with different `environment` values to cover all environments.
- **No remediation.** This tool is read-only and reports only. It does not remove or modify any code.

## Source

[https://github.com/klab-systems/dead_code_detector](https://github.com/klab-systems/dead_code_detector)

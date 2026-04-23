# dead_code_detector

Helps you keep your Puppet codebase clean by identifying code that is no longer in use. The primary entry point is the **`full_audit`** plan, which produces a complete dead code report covering classes, types, functions, templates, and static files in a single run. Six individual tasks are also available for targeted analysis.

Supports **Puppet Enterprise** (via PE Orchestrator or Puppet Bolt) and **Puppet Core / OpenVox** (via Puppet Bolt) as the task transport mechanism.

## Table of Contents

1. [Description](#description)
1. [Requirements](#requirements)
1. [How to use the module](#how-to-use-the-module)
    * [Puppet Enterprise (PE Orchestrator)](#puppet-enterprise-pe-orchestrator)
    * [Puppet Bolt (Puppet Enterprise, Puppet Core, OpenVox)](#puppet-bolt-puppet-enterprise-puppet-core-openvox)
1. [Task parameters](#task-parameters)
1. [Output](#output)
1. [Limitations](#limitations)

## Description

The primary entry point is the **`dead_code_detector::full_audit`** plan, which runs all five unused-* tasks against your Primary Server in sequence and returns a single combined JSON report covering classes, types, functions, templates, and static files in one pass.

Each task can also be run individually when a narrower scope is needed:

- **`dead_code_detector::unused_classes`** — queries your Puppet Primary Server for every class defined in an environment, then cross-references those against classes actively appearing in catalogs recorded in PuppetDB. Any class that has never appeared in a catalog (within the configured staleness window) is reported as unused, along with any modules where every class is unused.

- **`dead_code_detector::used_classes`** — the inverse report. Queries PuppetDB for every class applied across active nodes and ranks them by the number of nodes they appear on, highest first. Useful for understanding class adoption and identifying your most critical infrastructure code.

- **`dead_code_detector::unused_functions`** — static analysis task that scans the environment directory on the Primary Server to discover all module-defined functions, then searches for call sites across the codebase. Functions with no call sites are reported as unused. Built-in Puppet language functions are never included — discovery is scoped exclusively to module directories.

- **`dead_code_detector::unused_types`** — hybrid analysis task that discovers module-provided types via static filesystem scanning, then cross-references them against PuppetDB resource data. Handles two categories: Puppet-language defined types (`define` keyword) and native Ruby custom types (`Puppet::Type.newtype`). Reports each category separately.

- **`dead_code_detector::unused_templates`** — static analysis task that discovers all EPP and ERB template files under module `templates/` directories and searches for their canonical module references (`'mymod/path/to/file.epp'`) across the codebase. No PuppetDB connection is required. Matching is exact — Puppet always resolves module templates using the `'<module>/<relative_path>'` format.

- **`dead_code_detector::unused_files`** — static analysis task that discovers all static files under module `files/` directories and searches for their canonical `puppet:///modules/<mod>/<path>` URI across the codebase. No PuppetDB connection is required. Matching is exact by the same principle.

## Requirements

- Puppet Server with PuppetDB enabled (Puppet Enterprise or Puppet Core or OpenVox).
- All tasks must be run **targeting the Primary Server** — they use the node's own Puppet SSL certificates to authenticate against the Puppet Server API and PuppetDB.
- **Puppet Enterprise:** The `pe_node_manager` or equivalent RBAC permission to run tasks on the Primary Server via PE Orchestrator.
- **Puppet Core / OpenVox:** [Puppet Bolt](https://www.puppet.com/docs/bolt/) installed on the host you run commands from, with SSH access to the Primary Server.
- **Puppet Core / OpenVox — Puppet Server API access:** The `unused_classes` task (and the `full_audit` plan) queries the `/puppet/v3/environment_classes` endpoint on the Puppet Server, which is **denied by default** in `auth.conf`. You must explicitly permit access before running the task. This can be done using the [`puppetlabs-puppet_authorization`](https://forge.puppet.com/modules/puppetlabs/puppet_authorization) module, or manually by editing `/etc/puppetlabs/puppetserver/conf.d/auth.conf` to add an allow rule for that path.

## How to use the module

The recommended approach is to run the `full_audit` plan, which executes all five unused-* tasks in sequence and returns a single combined JSON report. Individual tasks can be run separately when a narrower scope is needed.

All tasks target your **Primary Server**. Most parameters are optional — when omitted, default values are derived from the Primary Server's own Puppet configuration.

---

### Puppet Enterprise (PE Orchestrator)

#### Using the PE Console

**Run the full audit plan:**

1. Navigate to **Plans** in the PE console.
2. Select `dead_code_detector::full_audit`.
3. Set the target to your Primary Server.
4. Set any desired parameters (see [Task parameters](#task-parameters)) and click **Run plan**.

**Run an individual task:**

1. Navigate to **Tasks** in the PE console.
2. Select the desired task (e.g. `dead_code_detector::unused_classes`).
3. Set the target to your Primary Server.
4. Set any desired parameters and click **Run task**.

#### Using the PE CLI

**Run the full audit plan:**

```bash
puppet plan run dead_code_detector::full_audit \
  --nodes <your-primary-server-fqdn>
```

With optional parameters:

```bash
puppet plan run dead_code_detector::full_audit \
  environment=development \
  stale_days=60 \
  --nodes <your-primary-server-fqdn>
```

**Run an individual task:**

```bash
puppet task run dead_code_detector::unused_classes \
  --nodes <your-primary-server-fqdn>
```

All tasks follow the same syntax. Replace `unused_classes` with the desired task name (`used_classes`, `unused_functions`, `unused_types`, `unused_templates`, `unused_files`) and pass any relevant parameters. See [Task parameters](#task-parameters) for the full reference.

---

### Puppet Bolt (Puppet Enterprise, Puppet Core, OpenVox)

Install the module on the Bolt host (add it to your `Puppetfile` or install directly):

```bash
bolt module add klabsystems-dead_code_detector
```

> **Note:** Bolt uses SSH to connect to the target by default. Ensure your Bolt [inventory](https://www.puppet.com/docs/bolt/latest/inventory_files.html) or transport configuration grants access to the Primary Server.

#### Run the full audit plan

```bash
bolt plan run dead_code_detector::full_audit \
  --targets <your-primary-server-fqdn>
```

With optional parameters:

```bash
bolt plan run dead_code_detector::full_audit \
  environment=development \
  stale_days=60 \
  --targets <your-primary-server-fqdn>
```

#### Run an individual task

```bash
bolt task run dead_code_detector::unused_classes \
  --targets <your-primary-server-fqdn>
```

All tasks follow the same syntax. Replace `unused_classes` with the desired task name and pass any relevant parameters. See [Task parameters](#task-parameters) for the full reference.

---

The `full_audit` plan prints a running summary as it progresses, then returns the combined report:

```
[ 1/5 ] Running unused_classes ...
[ 2/5 ] Running unused_types ...
[ 3/5 ] Running unused_functions ...
[ 4/5 ] Running unused_templates ...
[ 5/5 ] Running unused_files ...

Audit complete.
  Unused classes:         12
  Unused defined types:   3
  Unused custom types:    1
  Unused functions:       7
  Unused templates:       5
  Unused static files:    9
```

The return value is a single JSON object with a top-level key for each category:

```json
{
  "meta": {
    "environment": "production",
    "stale_days": 30,
    "generated_at": "2026-04-22T14:00:00Z",
    "target": "<your-primary-server-fqdn>"
  },
  "unused_classes":   { "classes": [...], "modules": [...] },
  "unused_types":     { "defined_types": [...], "custom_types": [...] },
  "unused_functions": { "functions": [...], "warnings": [...] },
  "unused_templates": { "templates": [...] },
  "unused_files":     { "files": [...] }
}
```

---

## Task parameters

All parameters are optional. When omitted, the task uses sensible defaults derived from the target node's own Puppet configuration.

**Common to `unused_classes`, `used_classes`, and `unused_types`:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `puppetdb_host` | `String` | Target node certname | Hostname or IP of PuppetDB |
| `puppetdb_port` | `Integer` | `8081` | PuppetDB HTTPS port |
| `environment` | `String` | `production` | Puppet environment to analyse |
| `stale_days` | `Integer` | `30` | Exclude nodes whose last report is older than this many days |
| `cert` | `String` | Target node's Puppet certificate | Path to a PEM-encoded client certificate |
| `key` | `String` | Target node's Puppet private key | Path to a PEM-encoded client private key |
| `ca_cert` | `String` | `/etc/puppetlabs/puppet/ssl/certs/ca.pem` | Path to the PEM-encoded CA certificate |

**`unused_classes` only:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `puppetserver_host` | `String` | Target node certname | Hostname or IP of the Puppet Server |
| `puppetserver_port` | `Integer` | `8140` | Puppet Server HTTPS port |

**`used_classes` only:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `top_n` | `Integer` | `0` (all) | Return only the top N most-used classes |

**`unused_functions`, `unused_templates`, `unused_files`:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `environment` | `String` | `production` | Puppet environment to analyse |
| `env_dir` | `String` | Derived from `puppet config print environmentpath` | Absolute path to the environment directory on the Primary Server |

**`unused_types` only:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `env_dir` | `String` | Derived from `puppet config print environmentpath` | Absolute path to the environment directory on the Primary Server |
| `modules_dir` | `String` | `<env_dir>/modules` | Absolute path to the modules directory to scan |

---

## Output

#### `unused_classes`

```json
{
  "meta": { "environment": "production", "stale_days": 30, "..." : "..." },
  "unused_classes": [
    "mymodule::someclass",
    "otherapp::configure"
  ],
  "unused_modules": [
    { "name": "otherapp", "unused_class_count": 1, "classes": ["otherapp::configure"] }
  ]
}
```

`unused_modules` lists only modules where **all** of their classes appear in the `unused_classes` list.

#### `used_classes`

```json
{
  "meta": { "environment": "production", "stale_days": 30, "top_n": 20, "..." : "..." },
  "ranked_classes": [
    { "class_name": "ntp",  "node_count": 847 },
    { "class_name": "sudo", "node_count": 831 }
  ]
}
```

`ranked_classes` is sorted by `node_count` descending.

#### `unused_functions`

```json
{
  "meta": { "environment": "production", "env_dir": "/etc/puppetlabs/code/environments/production", "generated_at": "..." },
  "unused_functions": [
    { "call_name": "mymod::helper", "qualified_name": "mymod::helper", "module_name": "mymod", "source_file": "...", "type": "pp_modern" }
  ],
  "used_functions": [
    { "call_name": "mymod::format", "qualified_name": "mymod::format", "module_name": "mymod", "source_file": "...", "type": "pp_modern" }
  ],
  "warnings": [
    "2 legacy Ruby function(s) detected (type: ruby_legacy). Legacy function names are unnamespaced..."
  ]
}
```

`warnings` is populated when legacy Ruby functions are found, as their unnamespaced call names carry a higher false-negative risk.

#### `unused_types`

```json
{
  "meta": { "environment": "production", "stale_days": 30, "..." : "..." },
  "unused_defined_types": [
    { "name": "mymod::mytype", "kind": "defined_type", "module_name": "mymod", "source_file": "..." }
  ],
  "unused_custom_types": [
    { "name": "myresource", "kind": "custom_type", "module_name": "mymod", "source_file": "..." }
  ]
}
```

`unused_defined_types` contains Puppet-language defined types (`define` keyword) with no instances in any active node's catalog within the staleness window. `unused_custom_types` contains native Ruby types (`Puppet::Type.newtype`) by the same criteria.

#### `unused_templates`

```json
{
  "meta": { "environment": "production", "env_dir": "/etc/puppetlabs/code/environments/production", "generated_at": "..." },
  "unused_templates": [
    { "reference": "mymod/subdir/banner.epp", "module_name": "mymod", "format": "epp", "source_file": "..." },
    { "reference": "legacymod/old_config.erb", "module_name": "legacymod", "format": "erb", "source_file": "..." }
  ],
  "used_templates": [
    { "reference": "mymod/motd.epp", "module_name": "mymod", "format": "epp", "source_file": "..." }
  ]
}
```

`unused_templates` contains every template file whose `'<module>/<relative_path>'` reference string appears in no manifest, function, or library file in the environment.

#### `unused_files`

```json
{
  "meta": { "environment": "production", "env_dir": "/etc/puppetlabs/code/environments/production", "generated_at": "..." },
  "unused_files": [
    { "uri": "puppet:///modules/mymod/config/app.conf", "module_name": "mymod", "source_file": "..." },
    { "uri": "puppet:///modules/legacymod/scripts/old_deploy.sh", "module_name": "legacymod", "source_file": "..." }
  ],
  "used_files": [
    { "uri": "puppet:///modules/mymod/motd", "module_name": "mymod", "source_file": "..." }
  ]
}
```

`unused_files` contains every static file whose `puppet:///modules/` URI appears in no source file in the environment. See the recursive directory caveat in [Limitations](#limitations).

---

## Limitations

- **Classes, types, functions, templates, and static files only.** Custom facts, defined resource titles, and other Puppet code constructs are not currently analysed.
- **Static file recursive directory caveat.** `unused_files` matches individual file URIs. Files inside a directory served with `recurse => true` via a directory-level URI will appear as unused. Review results in modules that use recursive file serving.
- **Static template analysis.** `unused_templates` scans source files for the canonical `'<module>/<path>'` reference string. Templates rendered via fully dynamic paths constructed at runtime (uncommon in real codebases) will appear as unused even if called.
- **Catalog-based class and type analysis.** Detection of unused classes and types relies on catalog data in PuppetDB. Nodes that have not checked in within `stale_days` (default: 30) are excluded from the active set and their classes will not count as "in use". Adjust `stale_days` if your environment has infrequently reporting nodes you still want to account for.
- **Static function analysis.** `unused_functions` cannot detect functions invoked via dynamic dispatch (e.g. `call($func_name)`). Such functions may appear as unused even if they are called at runtime.
- **Legacy function false negatives.** Legacy Ruby functions (pre-Puppet 4) use unnamespaced names. A function named `join` or `validate_string` may match unrelated strings in the codebase, suppressing an unused result. Review the `warnings` key in the output.
- **Single environment.** Each task run analyses one environment at a time. Run the task multiple times with different `environment` values to cover all environments.
- **No remediation.** This tool is read-only and reports only. It does not remove or modify any code.

## Source

[https://github.com/klab-systems/dead_code_detector](https://github.com/klab-systems/dead_code_detector)

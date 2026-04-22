# Changelog

All notable changes to this project will be documented in this file.

## Release 0.1.1 (2026-04-22)

**Documentation**

- Added Puppet Bolt usage instructions as an alternative transport to Puppet Enterprise Orchestrator.
- Clarified that the module supports both Puppet Enterprise and open-source Puppet Core.
- Updated Requirements section to cover Bolt-specific prerequisites (SSH access, Bolt installation).
- Added `bolt module install` and `bolt task run` examples, including optional parameter usage.

## Release 0.1.0

**Features**

- Initial release of `dead_code_detector`.
- Adds the `dead_code_detector::generate` task, which identifies unused Puppet classes and modules by querying the Puppet Server class API and cross-referencing against PuppetDB catalog data.
- Task must be run targeting the Puppet Primary Server, using the node's own SSL certificates for API authentication.
- Supports configurable parameters: `puppetserver_host`, `puppetdb_host`, `puppetserver_port`, `puppetdb_port`, `environment`, `stale_days`, `cert`, `key`, and `ca_cert`.
- Returns a JSON report with `unused_classes` and `unused_modules` keys.
- Supports Puppet Enterprise with PuppetDB via PE Orchestrator.

**Bugfixes**

**Known Issues**

- Detection is limited to classes and modules. Defined types, functions, facts, and other Puppet code constructs are not analysed.
- Analysis is scoped to a single environment per task run.

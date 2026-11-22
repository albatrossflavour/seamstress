# Changelog

All notable changes to this module are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module uses [semantic versioning](https://semver.org/).

## [0.1.0] - unreleased

First release.

- Builds a puppet-strings site for every environment of a control repo, from git (`source => 'git'`) or from code already on disk or in a tarball (`source => 'directory'`).
- Rebuilds only environments whose control-repo or module SHAs moved, runs puppet-strings once per module so a failure stays contained, and publishes each build by swapping a symlink.
- Keeps the last good build live when a build fails, with a banner on every page saying so.
- Client-side search across classes, defined types, resource types, functions, tasks, and plans.
- Read-only SSH deploy keys per repository URL or glob, and an optional Forge API key.
- Hardened systemd service and timer, optional nginx on 443, and an optional Prometheus textfile metric.

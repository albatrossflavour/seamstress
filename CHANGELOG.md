# Changelog

All notable changes to this module are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module uses [semantic versioning](https://semver.org/).

## [0.3.0] - unreleased

- The module is renamed from strings_site to seamstress. The class and its Hiera keys, the service account, the systemd units, the directories under `/opt`, `/etc`, `/var/lib`, `/var/www`, and `/etc/nginx`, the metric names, and the sign-in cookie all take the new name. Nothing moves an existing node across, so rebuild it, or remove what strings_site left behind before applying seamstress.
- `auth` puts the site behind a sign-in. `oidc` signs readers in through any OpenID Connect provider using oauth2-proxy, which the module downloads (checksum-verified), configures, and runs in a hardened systemd unit on 127.0.0.1, with nginx checking every request through `auth_request`. `basic` uses HTTP basic auth from `basic_auth_users`, password hashes only. The default, `none`, leaves the site open as before.
- The oauth2-proxy client secret can be Deferred, so it stays out of the catalogue, and the cookie secret is generated on the node and never passes through Puppet.
- `tls_cert` takes the PEM itself as well as a path, and `tls_key` takes a path, a Sensitive PEM, or a Deferred value, so a certificate and key can come from Hiera and eyaml.
- `/etc/nginx/seamstress` is now group-owned by nginx's worker group with mode 0710, so the workers can reach the htpasswd file. The key is still mode 0600 and root's alone.
- In directory mode, a module pinned to a full commit takes that commit as its SHA when `.r10k-deploy.json` records none. Code Manager can write `sha: null` for a pinned module it had nothing to resolve, so the comparison page showed the same commit as a difference between environments.

## [0.2.0] - unreleased

The site is now rendered from puppet-strings JSON rather than wrapping the YARD HTML, so every page shares one design.

- A page per class, defined type, resource type, provider, function, task, plan, type alias, and data type, with a parameter table (type, default, required, description), options, signatures, return types, highlighted examples, the source file and line, and the source.
- Cross-links: parameter types link to their type aliases, inline code naming an object links to it, and each object lists what it uses and what uses it.
- An environment dashboard with documentation coverage, documentation gaps by module, modules by source, and what changed since the previous build, recorded in `build.json` as `changes`.
- A module page with version, source, ref, resolved SHA, dependencies, supported platforms, and the README.
- A comparison page for any two environments, with `compare.json` beside it.
- A command palette (`/`, Ctrl-K, or Cmd-K) with fuzzy search over every module, object, and parameter, grouped by kind. The search index now includes modules and parameters.
- A sidebar tree, breadcrumbs, anchors and copy buttons, a new palette and type, light and dark themes, a phone layout, visible focus, and reduced motion.
- READMEs and docstrings go through a markdown renderer that escapes all HTML apart from a few bare inline tags and allows only safe link targets.
- puppet-strings runs once per module instead of twice, as only the JSON is needed. Cached documentation from 0.1.0 is rebuilt on the first run.
- The nginx Content-Security-Policy no longer allows inline script.
- A module whose documentation cannot be drawn is marked failed at the `render` stage while the rest of its environment publishes.
- CI: json is held below 3.0 on Ruby 3.2, where facterdb's jgrep 1.5.4 still calls `JSON.create_id=`, and CI runs on pushes to every branch.

## [0.1.0] - unreleased

First release.

- Builds a puppet-strings site for every environment of a control repo, from git (`source => 'git'`) or from code already on disk or in a tarball (`source => 'directory'`).
- Rebuilds only environments whose control-repo or module SHAs moved, runs puppet-strings once per module so a failure stays contained, and publishes each build by swapping a symlink.
- Keeps the last good build live when a build fails, with a banner on every page saying so.
- Client-side search across classes, defined types, resource types, functions, tasks, and plans.
- Read-only SSH deploy keys per repository URL or glob, and an optional Forge API key.
- Hardened systemd service and timer, optional nginx on 443, and an optional Prometheus textfile metric.

# strings_site

Builds and serves a searchable [puppet-strings](https://github.com/puppetlabs/puppet-strings) site for every module in every environment of a Puppet control repo. That covers the Forge modules, the git modules (private ones included), and the roles and profiles in the control repo itself.

## What you get

- A page for every class, defined type, resource type, provider, function, task, plan, type alias, and data type, drawn from each module's `puppet strings generate --format json` output. Each shows the summary and description, a table of parameters with their types, defaults, and whether they are required, every example with syntax highlighting, the function signatures and return types, the source file and line, and the source itself.
- Links between objects: a parameter's type links to its type alias, inline code that names a class or function links to it, and each page lists what the object uses (included classes, declared defined types and resource types, called functions) and what uses it, across modules.
- A dashboard per environment: module count, documentation coverage, the modules with missing summaries or parameter descriptions, how many modules come from the Forge, git, or the control repo, and what changed since the previous build.
- A page per module with its version, source, ref, resolved SHA, dependencies from `metadata.json` (linked to the module when the environment has it), supported platforms, and README.
- A comparison of any two environments, production against development by default, listing the modules whose version, resolved commit, ref, or source differ.
- A command palette on every page: press `/` or Ctrl-K (Cmd-K on a Mac) and type. It searches every module, object, and parameter in the environment with fuzzy matching, groups the results by kind, and goes straight to the object or the parameter's anchor.
- A sidebar tree of the environment's modules and their contents, breadcrumbs, a link anchor and copy button on every section, parameter, and code block, light and dark themes, a layout that works on a phone, and visible keyboard focus. Motion is kept to a minimum and switched off for anyone who asks their system for reduced motion.
- The control-repo commit and build time on every page, and a banner when the latest build of an environment failed and you're reading the previous good one.

The site is static files and loads nothing from anywhere else, so it works on a network with no internet access. The raw puppet-strings JSON for each module is published beside its page.

## How it works

A systemd timer runs the build every five minutes by default. Each run works out what every environment is made of and compares that with the last build. Only environments where something moved are rebuilt, and a module whose SHA didn't move reuses its documentation from the cache, so a typical run does almost nothing.

Each module gets its own puppet-strings run. A module that fails to document is marked as failed on the environment page and the rest of the environment still publishes.

Builds go into `builds/<environment>-<fingerprint>` under the docroot and go live by swapping a symlink, which is atomic. If an environment fails outright, say a Puppetfile that doesn't parse or a control repo that can't be reached, the previous build stays live. The failure goes to the journal, the unit exits non-zero, and the pages show the banner. Old builds, environments that no longer exist, and unused cache entries are pruned at the end of each run.

The build runs as a system user with no login shell. The unit is hardened with `ProtectSystem=strict`, `NoNewPrivileges`, and `PrivateTmp`, and can only write to the docroot and its own state directory.

### Sources

`git` (the default) polls the control repo with `git ls-remote`, reads the Puppetfile from each branch, and resolves each module itself: git modules to a commit, Forge modules to a release and its checksum. It needs read access to every repository the Puppetfile names, and it documents what is in git, so a branch-tracking module can briefly be ahead of what your deployment tool has put on disk.

`directory` reads environments that are already on disk, one directory per environment, such as the output of r10k or Code Manager. A tarball per environment is also supported, so any tool that can drop a file on the node can deliver code. When an environment has a `.r10k-deploy.json` the commit and module refs come from it. Otherwise versions come from each module's `metadata.json`. No git access or credentials are needed.

## Requirements

- Puppet 8 or 9 agent on the node: the build runs under Puppet's bundled Ruby, and puppet-strings is installed into it with the `puppet_gem` provider.
- RHEL 9 or 10 (or a rebuild of it), or Ubuntu 22.04 or 24.04.
- `puppetlabs/stdlib` and `puppet/systemd`.

The module doesn't manage the firewall. Open the port in whatever already manages yours.

## Usage

The smallest useful setup, for a public control repo:

```puppet
class { 'strings_site':
  control_repo => 'https://git.example.com/puppet/control-repo.git',
}
```

That builds every branch, serves the site on port 443 with the node's Puppet agent certificate, and polls every five minutes.

### Private modules

Give the service a read-only key for each repository, or a glob covering several. The most specific pattern that matches a URL wins, so per-repository deploy keys on one host work. Keys are written to the service user's `~/.ssh` with mode 0600 and never appear in the configuration file or the logs.

```puppet
class { 'strings_site':
  control_repo             => 'git@git.example.com:puppet/control-repo.git',
  deploy_keys              => {
    'git@git.example.com:puppet/*'               => Sensitive(lookup('strings_site::puppet_org_key')),
    'git@git.example.com:security/hardening.git' => Sensitive(lookup('strings_site::hardening_key')),
  },
  ssh_known_hosts          => ['git.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnly'],
  strict_host_key_checking => 'yes',
}
```

With no `ssh_known_hosts`, SSH trusts a host the first time it sees it (`accept-new`), so pinning the host keys is the safer setting.

### Choosing environments

`environments` is an allow-list and `exclude_environments` is a list of regular expressions applied after it. Both are empty by default, which builds everything. To skip short-lived branches made by deployment tooling:

```puppet
class { 'strings_site':
  control_repo         => 'git@git.example.com:puppet/control-repo.git',
  exclude_environments => ['^feature_', '^tmp_'],
}
```

### Code already on disk

```puppet
class { 'strings_site':
  source               => 'directory',
  code_dir             => '/srv/puppet/environments',
  tarballs             => { 'staging' => '/srv/drop/staging.tar.gz' },
  supplementary_groups => ['puppetcode'],
}
```

The service user needs to be able to read `code_dir` and the tarballs, which is what `supplementary_groups` is for. A tarball can hold the environment at its root or inside a single top-level directory.

### Metrics

Set `metrics_file` to a path in a node_exporter textfile collector directory that the service user can write to:

```puppet
class { 'strings_site':
  control_repo => 'git@git.example.com:puppet/control-repo.git',
  metrics_file => '/var/lib/node_exporter/textfile/strings_site.prom',
}
```

It writes four gauges:

| Metric | Meaning |
| --- | --- |
| `strings_site_last_success_timestamp_seconds` | Start of the last run in which every environment built or was already current |
| `strings_site_last_attempt_timestamp_seconds` | Start of the last run |
| `strings_site_failed_modules` | Modules whose documentation failed, across the live builds |
| `strings_site_failed_environments` | Environments whose latest build failed |

An alert on `time() - strings_site_last_success_timestamp_seconds` catches a site that has stopped updating.

### Your own web server

```puppet
class { 'strings_site':
  control_repo => 'git@git.example.com:puppet/control-repo.git',
  manage_nginx => false,
  docroot      => '/srv/www/strings',
}
```

Serve `docroot` as static files. The pages use relative links, so the site works under any path prefix. Send `status.json` with `Cache-Control: no-store` so the stale-build banner is current. The pages carry no inline script, so a Content-Security-Policy of `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'` works; inline styles carry the commit swatches and coverage bars.

## Parameters

Only `control_repo` (git mode) or `code_dir` or `tarballs` (directory mode) must be set. [REFERENCE.md](REFERENCE.md) has the full list with types.

| Parameter | Default | Purpose |
| --- | --- | --- |
| `source` | `git` | `git` or `directory` |
| `control_repo` | none | Control repo URL, git mode |
| `code_dir` | none | Directory of environments, directory mode |
| `tarballs` | `{}` | Environment name to tarball path, directory mode |
| `environments` | `[]` | Allow-list of environments; empty means all |
| `exclude_environments` | `[]` | Regular expressions of environments to skip |
| `local_module_dirs` | `['site-modules', 'site']` | Module directories inside the control repo |
| `deploy_keys` | `{}` | URL or glob to `Sensitive` SSH private key |
| `ssh_known_hosts` | `[]` | `known_hosts` lines for the service user |
| `strict_host_key_checking` | `accept-new` | `yes` or `accept-new` |
| `forge_url` | `https://forgeapi.puppet.com` | Forge API when a Puppetfile names none |
| `forge_token` | none | `Sensitive` Forge API key |
| `docroot` | `/var/www/strings_site` | Where the site is written and served from |
| `base_dir` | `/var/lib/strings_site` | Service home: state, keys, and cache |
| `install_dir` | `/opt/strings_site` | Build script, templates, and assets |
| `config_dir` | `/etc/strings_site` | Build configuration |
| `user`, `group` | `strings` | Service account |
| `supplementary_groups` | `[]` | Extra groups for the service |
| `manage_user` | `true` | Create the user and group |
| `poll_interval` | `5min` | systemd time span between runs |
| `strings_version` | `5.1.0` | puppet-strings gem version |
| `manage_git` | `true` | Install git |
| `ruby`, `puppet` | Puppet's own | Interpreter and `puppet` executable |
| `keep_builds` | `2` | Builds kept per environment, live one included |
| `module_timeout` | `600` | Seconds allowed per module |
| `metrics_file` | none | Prometheus textfile path |
| `site_title` | `Puppet module reference` | Name at the top of every page |
| `timer_enable` | `true` | Enable and start the timer |
| `manage_nginx` | `true` | Serve the site with nginx |
| `port` | `443` | nginx port |
| `server_name` | the node's FQDN | nginx server name |
| `tls_cert`, `tls_key` | the agent's certificate and key | PEM files nginx uses, copied into `/etc/nginx/strings_site` |

## Operating it

```shell
systemctl start strings_site.service     # build now
journalctl -u strings_site.service       # what the last runs did
sudo -u strings /opt/puppetlabs/puppet/bin/ruby /opt/strings_site/strings_site.rb \
  --config /etc/strings_site/config.json --force --environment production
```

`--force` rebuilds whatever it is pointed at, and `--environment` limits a run to one environment.

## Trust

A Puppetfile is Ruby, and the build evaluates it the same way r10k does. That is the same trust r10k already gives your control repo, and here it runs as the unprivileged service user inside the hardened unit. Credentials embedded in a URL are masked in logs and pages, but `deploy_keys` keeps the credential out of the URL and the configuration file altogether.

Documentation is treated as untrusted too. READMEs and docstrings are rendered by the build's own markdown renderer, which escapes everything, drops script and style blocks, keeps only a few attribute-free inline tags, allows links only to `http`, `https`, `mailto`, and relative targets, and turns images into links so a page never fetches from elsewhere. Only a module's `metadata.json` and README are read besides the puppet-strings output, and neither is published as it stands.

## Development

```shell
bundle install
bundle exec rake syntax lint metadata_lint rubocop spec
```

The build script's own tests are in `spec/unit/app`. They run the real script against throwaway git repositories and directories, with a stand-in for `puppet strings`, so they need neither Puppet nor the network. The renderer's tests draw a whole environment from the puppet-strings JSON in `spec/unit/app/fixtures`, which includes hostile markup on purpose (the README fixture is `.markdown` so markdownlint leaves it alone).

The build script is `files/app/strings_site.rb`. It loads the documentation model, renderer, markdown renderer, and highlighter from `files/app/lib`, and the page templates from `files/app/templates`.

## Licence

Apache 2.0. See [LICENSE](LICENSE).

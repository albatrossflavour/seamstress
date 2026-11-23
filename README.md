# seamstress

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
class { 'seamstress':
  control_repo => 'https://git.example.com/puppet/control-repo.git',
}
```

That builds every branch, serves the site on port 443 with the node's Puppet agent certificate, and polls every five minutes.

### Private modules

Give the service a read-only key for each repository, or a glob covering several. The most specific pattern that matches a URL wins, so per-repository deploy keys on one host work. Keys are written to the service user's `~/.ssh` with mode 0600 and never appear in the configuration file or the logs.

```puppet
class { 'seamstress':
  control_repo             => 'git@git.example.com:puppet/control-repo.git',
  deploy_keys              => {
    'git@git.example.com:puppet/*'               => Sensitive(lookup('seamstress::puppet_org_key')),
    'git@git.example.com:security/hardening.git' => Sensitive(lookup('seamstress::hardening_key')),
  },
  ssh_known_hosts          => ['git.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnly'],
  strict_host_key_checking => 'yes',
}
```

With no `ssh_known_hosts`, SSH trusts a host the first time it sees it (`accept-new`), so pinning the host keys is the safer setting.

### Choosing environments

`environments` is an allow-list and `exclude_environments` is a list of regular expressions applied after it. Both are empty by default, which builds everything. To skip short-lived branches made by deployment tooling:

```puppet
class { 'seamstress':
  control_repo         => 'git@git.example.com:puppet/control-repo.git',
  exclude_environments => ['^feature_', '^tmp_'],
}
```

### Code already on disk

```puppet
class { 'seamstress':
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
class { 'seamstress':
  control_repo => 'git@git.example.com:puppet/control-repo.git',
  metrics_file => '/var/lib/node_exporter/textfile/seamstress.prom',
}
```

It writes four gauges:

| Metric | Meaning |
| --- | --- |
| `seamstress_last_success_timestamp_seconds` | Start of the last run in which every environment built or was already current |
| `seamstress_last_attempt_timestamp_seconds` | Start of the last run |
| `seamstress_failed_modules` | Modules whose documentation failed, across the live builds |
| `seamstress_failed_environments` | Environments whose latest build failed |

An alert on `time() - seamstress_last_success_timestamp_seconds` catches a site that has stopped updating.

### Access control

By default anyone who can reach the site can read it. Set `auth` to `oidc` to sign readers in through your identity provider, or to `basic` for a username and password with nothing else to run. nginx enforces both, so both need `manage_nginx`. Every page is covered, `status.json` included.

#### Single sign-on with OpenID Connect

This is the recommended mode. The module downloads [oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy), checks the tarball against a pinned SHA-256, and runs it as its own user in a hardened systemd unit listening on 127.0.0.1. nginx asks it about every request with `auth_request`, and a reader with no session is sent to the identity provider and back.

Any OpenID Connect provider works: Keycloak, Entra ID, Okta, Google, Authentik, Dex, and the like. Register a confidential client (one with a client secret) on the provider, with this redirect URI:

```text
https://<server_name>/oauth2/callback
```

Add `:<port>` after the name if `port` is not 443. The client needs the `openid`, `email`, and `profile` scopes, and a groups claim in the ID token if you use `oidc_allowed_groups`.

```puppet
class { 'seamstress':
  control_repo        => 'git@git.example.com:puppet/control-repo.git',
  auth                => 'oidc',
  oidc_issuer_url     => 'https://login.example.com/realms/staff',
  oidc_client_id      => 'seamstress',
  oidc_client_secret  => Sensitive(lookup('seamstress::oidc_client_secret')),
  oidc_allowed_groups => ['puppet-admins'],
}
```

A Sensitive class parameter is still written to the catalogue in plaintext, where PuppetDB and catalogue reports can see it. To keep the client secret out of the catalogue altogether, pass a Deferred value that the agent resolves, for example `Deferred('node_decrypt', [$encrypted])` from node_encrypt or a Vault lookup function. It must resolve to the secret with no trailing newline.

The cookie secret is generated on the node the first time and never passes through Puppet. The session cookie is `__Host-seamstress`, so the browser only sends it over HTTPS to this exact host.

Other settings:

- `oidc_email_domains` limits sign-in to addresses in the listed domains. It defaults to any.
- `oidc_allow_unverified_email` lets in a user whose token says `email_verified` is false. oauth2-proxy answers those with a 403 after the provider has signed them in. authentik's default email scope sends false for everyone, so with authentik either set this, when `oidc_allowed_groups` decides who gets in, or give the provider an email scope mapping that asserts the address.
- `oidc_scope` and `oidc_groups_claim` cover providers that need `groups` asked for, or put groups in a claim with another name.
- `oidc_provider_ca_file` is a CA bundle on the node for a provider whose certificate comes from a private CA.
- `oauth2_proxy_download_base` points at a mirror for a node with no internet access. The mirror must keep the GitHub release layout, `<base>/v<version>/oauth2-proxy-v<version>.linux-<arch>.tar.gz`.
- To move to another oauth2-proxy release, set `oauth2_proxy_version` and `oauth2_proxy_checksums` together. The new version installs beside the old one.

oauth2-proxy runs on x86_64 and aarch64 nodes. Setting `auth` to anything else stops the unit and removes it along with `/etc/oauth2-proxy` and the secrets in it. Downloaded releases stay in `/opt/oauth2-proxy`.

#### Basic auth

For a small team, or anywhere an identity provider isn't available. Give each user a password hash, never the password:

```shell
openssl passwd -6
```

```puppet
class { 'seamstress':
  control_repo     => 'git@git.example.com:puppet/control-repo.git',
  auth             => 'basic',
  basic_auth_users => {
    'alice' => Sensitive('$6$Hk3xY2...'),
    'bob'   => Sensitive('$6$9fQm1L...'),
  },
}
```

sha512-crypt (`openssl passwd -6`), sha256-crypt (`openssl passwd -5`), yescrypt, bcrypt, and apr1 (`htpasswd -m`) hashes are accepted, and anything else fails the compile. The hashes are written to `/etc/nginx/seamstress/htpasswd`, readable only by root and nginx's workers.

#### Certificates from Hiera

`tls_cert` and `tls_key` take a path on the node or the PEM itself, so a certificate from your own CA can come from Hiera, with the key encrypted by hiera-eyaml:

```yaml
seamstress::tls_cert: |
  -----BEGIN CERTIFICATE-----
  MIIF...
  -----END CERTIFICATE-----
seamstress::tls_key: >
  ENC[PKCS7,MIIH...]
```

```puppet
class { 'seamstress':
  control_repo => 'git@git.example.com:puppet/control-repo.git',
  tls_key      => Sensitive(lookup('seamstress::tls_key')),
}
```

Put any intermediates after the leaf in `tls_cert`. As with the client secret, a Deferred `tls_key` keeps the key out of the catalogue.

### Hiera

```puppet
class { 'seamstress':
  control_repo  => 'git@git.example.com:puppet/control-repo.git',
  auth          => 'oidc',
  # ...
  hiera         => true,
  hiera_samples => {
    'A web server in Sydney' => {
      'trusted.extensions.pp_role'       => 'role::web',
      'trusted.extensions.pp_datacenter' => 'syd',
      'facts.os.family'                  => 'RedHat',
    },
  },
}
```

`hiera` adds a Hiera page to each environment. Pick a sample node and it shows every level of the hierarchy in order and whether the level has a data file for that node. Opened, a level lists the keys its file sets, with the ones a more specific level overrides struck through. A key can be searched for across the levels, and the page says what the node gets for it and from where.

It publishes the values in your data files to anyone who can read the site, so it's off by default and belongs behind `auth`. Encrypted (eyaml) values are left out when the site is built and nothing is decrypted, so no ciphertext is published either.

A sample node is a set of values for the hierarchy's variables, named as `hiera.yaml` writes them, and no node's facts are read. `hiera_samples` names some, and the reader can also fill the variables in by hand from the values the data files imply (`role/role::web.yaml` under `role/%{trusted.extensions.pp_role}.yaml` implies `role::web`).

Merged keys are merged when the site is built, by Puppet's own merge code and following the `lookup_options` in the environment's data, so `deep` with `knockout_prefix` or `merge_hash_arrays` comes out as it does in a catalogue.

What it doesn't do:

- It reads the `yaml_data` and `eyaml_lookup_key` backends, with `path` and `paths`. A level using another backend, or `glob`, `globs`, `mapped_paths`, or `uri`, is shown as one it cannot read.
- It reads the environment's hierarchy only. A module's own data and `lookup_options`, and the global layer, are not included, so a key no level sets may still have a value from a module.
- Interpolation inside a value (`%{lookup('x')}`, `%{alias('x')}`) is shown as written.
- `lookup_options` are taken from every data file at once, the more specific level winning, where Hiera resolves them for each node.

For the real answer for a real node, the page prints the `puppet lookup --explain` command to run on the primary.

The environment's `hiera.yaml` and data files have to be in what the site is built from. In git mode they are in the control repo. With `code_dir` they are in the deployed environment. A tarball has to include them.

### Your own web server

```puppet
class { 'seamstress':
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
| `docroot` | `/var/www/seamstress` | Where the site is written and served from |
| `base_dir` | `/var/lib/seamstress` | Service home: state, keys, and cache |
| `install_dir` | `/opt/seamstress` | Build script, templates, and assets |
| `config_dir` | `/etc/seamstress` | Build configuration |
| `user`, `group` | `seamstress` | Service account |
| `supplementary_groups` | `[]` | Extra groups for the service |
| `manage_user` | `true` | Create the user and group |
| `poll_interval` | `5min` | systemd time span between runs |
| `strings_version` | `5.1.0` | puppet-strings gem version |
| `manage_git` | `true` | Install git |
| `ruby`, `puppet` | Puppet's own | Interpreter and `puppet` executable |
| `keep_builds` | `2` | Builds kept per environment, live one included |
| `module_timeout` | `600` | Seconds allowed per module |
| `metrics_file` | none | Prometheus textfile path |
| `hiera` | `false` | Add a Hiera page to each environment |
| `hiera_samples` | `{}` | Named sample nodes for the Hiera page |
| `site_title` | `Puppet module reference` | Name at the top of every page |
| `timer_enable` | `true` | Enable and start the timer |
| `manage_nginx` | `true` | Serve the site with nginx |
| `port` | `443` | nginx port |
| `server_name` | the node's FQDN | nginx server name |
| `tls_cert`, `tls_key` | the agent's certificate and key | Paths or PEM content for nginx, written to `/etc/nginx/seamstress` |
| `auth` | `none` | `none`, `oidc`, or `basic` |
| `basic_auth_users` | `{}` | Username to `Sensitive` password hash, for `basic` |
| `basic_auth_realm` | `site_title` | Realm in the browser's sign-in prompt |
| `oidc_issuer_url` | none | Identity provider's issuer URL, for `oidc` |
| `oidc_client_id` | none | Client ID at the identity provider |
| `oidc_client_secret` | none | `Sensitive` or `Deferred` client secret |
| `oidc_allowed_groups` | `[]` | Groups allowed in (empty allows anyone the provider signs in) |
| `oidc_email_domains` | `['*']` | Email domains allowed in |
| `oidc_allow_unverified_email` | `false` | Let in users whose token says the email is unverified |
| `oidc_scope` | `openid email profile` | Scopes requested |
| `oidc_groups_claim` | `groups` | Claim holding the groups |
| `oidc_provider_ca_file` | none | CA bundle for a provider with a private CA |
| `oauth2_proxy_version` | `7.15.6` | oauth2-proxy release |
| `oauth2_proxy_checksums` | the 7.15.6 tarballs | SHA-256 per architecture |
| `oauth2_proxy_download_base` | GitHub releases | Where releases are fetched from |
| `oauth2_proxy_port` | `4180` | oauth2-proxy's port on 127.0.0.1 |

## Operating it

```shell
systemctl start seamstress.service     # build now
journalctl -u seamstress.service       # what the last runs did
sudo -u seamstress /opt/puppetlabs/puppet/bin/ruby /opt/seamstress/seamstress.rb \
  --config /etc/seamstress/config.json --force --environment production
```

`--force` rebuilds whatever it is pointed at, and `--environment` limits a run to one environment.

## Trust

A Puppetfile is Ruby, and the build evaluates it the same way r10k does. That is the same trust r10k already gives your control repo, and here it runs as the unprivileged service user inside the hardened unit. Credentials embedded in a URL are masked in logs and pages, but `deploy_keys` keeps the credential out of the URL and the configuration file altogether.

Documentation is treated as untrusted too. READMEs and docstrings are rendered by the build's own markdown renderer, which escapes everything, drops script and style blocks, keeps only a few attribute-free inline tags, allows links only to `http`, `https`, `mailto`, and relative targets, and turns images into links so a page never fetches from elsewhere. Only a module's `metadata.json` and README are read besides the puppet-strings output, and neither is published as it stands.

With `hiera` on, the environment's `hiera.yaml` and data files are read as YAML, never evaluated, and their values are published apart from the encrypted ones.

## Development

```shell
bundle install
bundle exec rake syntax lint metadata_lint rubocop spec
```

The build script's own tests are in `spec/unit/app`. They run the real script against throwaway git repositories and directories, with a stand-in for `puppet strings`, so they need neither Puppet nor the network. The renderer's tests draw a whole environment from the puppet-strings JSON in `spec/unit/app/fixtures`, which includes hostile markup on purpose (the README fixture is `.markdown` so markdownlint leaves it alone).

The build script is `files/app/seamstress.rb`. It loads the documentation model, renderer, markdown renderer, and highlighter from `files/app/lib`, and the page templates from `files/app/templates`.

## Licence

Apache 2.0. See [LICENSE](LICENSE).

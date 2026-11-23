# seamstress

Builds and serves a documentation site for a Puppet control repo, in two sections. Module documentation is a searchable [puppet-strings](https://github.com/puppetlabs/puppet-strings) reference for every module in every environment: the Forge modules, the git modules (private ones included), and the roles and profiles in the control repo itself. The Hiera Explorer, which is optional, shows what a node gets from each environment's Hiera data and from which level.

## What you get

- A page for every class, defined type, resource type, provider, function, task, plan, type alias, and data type, drawn from each module's `puppet strings generate --format json` output. Each shows the summary and description, a table of parameters with their types, defaults, and whether they are required, every example with syntax highlighting, the function signatures and return types, the source file and line, and the source itself.
- Links between objects: a parameter's type links to its type alias, inline code that names a class or function links to it, and each page lists what the object uses (included classes, declared defined types and resource types, called functions) and what uses it, across modules.
- A dashboard per environment: module count, documentation coverage, the modules with missing summaries or parameter descriptions, how many modules come from the Forge, git, or the control repo, and what changed since the previous build.
- A page per module with its version, source, ref, resolved SHA, dependencies from `metadata.json` (linked to the module when the environment has it), supported platforms, and README.
- A comparison of any two environments, production against development by default, listing the modules whose version, resolved commit, ref, or source differ.
- A command palette on every module documentation page: press `/` or Ctrl-K (Cmd-K on a Mac) and type. It searches every module, object, and parameter in the environment with fuzzy matching, groups the results by kind, and goes straight to the object or the parameter's anchor.
- A sidebar tree of the environment's modules and their contents beside the module documentation, breadcrumbs, a link anchor and copy button on every section, parameter, and code block, light and dark themes, a layout that works on a phone, and visible keyboard focus. Motion is kept to a minimum and switched off for anyone who asks their system for reduced motion.
- The control-repo commit and build time on every page of an environment, and a banner when the latest build of that environment failed and you're reading the previous good one.
- A bar across the top of every page with the environment, which is a menu of the environments when there is more than one, and a switch between the two sections. The base page says what the site is and flags any environment whose last build failed.
- The [Hiera Explorer](#hiera-explorer), if you turn it on: an environment's hierarchy level by level for a node you describe, the keys each level sets, and what wins.
- Sign-in, if you want it, through an OpenID Connect provider or HTTP basic auth. See [Access control](#access-control).

The site is static files and loads nothing from anywhere else, so it works on a network with no internet access. The raw puppet-strings JSON for each module is published beside its page.

## Requirements

- Puppet 8 agent on the node: the build runs under Puppet's bundled Ruby, and puppet-strings is installed into it with the `puppet_gem` provider.
- RHEL 9 or 10 (or a rebuild of it), or Ubuntu 22.04 or 24.04.
- `puppetlabs/stdlib` and `puppet/systemd`.

Things to know before you put it on a node:

- It installs and runs nginx itself, declaring the `nginx` package and service. On a node where another module manages nginx, set `manage_nginx => false` and see [Your own web server](#your-own-web-server).
- The module doesn't manage the firewall. Open the port in whatever already manages yours.
- The site itself needs no internet access, but installing it does: the puppet-strings gem comes from your gem source, git mode asks the Forge about each Forge module, and `auth => 'oidc'` downloads oauth2-proxy (from GitHub, or from `oauth2_proxy_download_base`).
- Nothing here has been tested with SELinux enforcing a policy stricter than the distribution's default.

## How it works

A systemd timer runs the build every five minutes by default. Each run works out what every environment is made of and compares that with the last build. Only environments where something moved are rebuilt, and a module whose SHA didn't move reuses its documentation from the cache, so a typical run does almost nothing.

Each module gets its own puppet-strings run. A module that fails to document is marked as failed on the environment page and the rest of the environment still publishes.

Builds go into `builds/<environment>-<fingerprint>` under the docroot and go live by swapping a symlink, which is atomic. If an environment fails outright, say a Puppetfile that doesn't parse or a control repo that can't be reached, the previous build stays live. The failure goes to the journal, the unit exits non-zero, and the pages show the banner. Old builds, environments that no longer exist, and cached documentation no build points at are pruned at the end of each run. The git mirrors and Forge downloads under the cache directory are kept.

The build runs as a system user with no login shell. The unit is hardened with `ProtectSystem=strict`, `NoNewPrivileges`, and `PrivateTmp`, and can only write to the docroot and its own state directory.

### Sources

`git` (the default) polls the control repo with `git ls-remote`, reads the Puppetfile from each branch, and resolves each module itself: git modules to a commit, Forge modules to a release and its checksum. It needs read access to every repository the Puppetfile names, and it documents what is in git, so a branch-tracking module can briefly be ahead of what your deployment tool has put on disk.

`directory` reads environments that are already on disk, one directory per environment, such as the output of r10k or Code Manager. A tarball per environment is also supported, so any tool that can drop a file on the node can deliver code. When an environment has a `.r10k-deploy.json` the commit and module refs come from it. Otherwise versions come from each module's `metadata.json`. No git access or credentials are needed.

## Usage

The smallest useful setup, for a public control repo:

```puppet
class { 'seamstress':
  control_repo => 'https://git.example.com/puppet/control-repo.git',
}
```

That builds every branch, serves the site on port 443 with the node's Puppet agent certificate, and polls every five minutes. Three things about those defaults:

- A browser will warn about the Puppet agent certificate, since your browser doesn't trust the Puppet CA. See [Certificates from Hiera](#certificates-from-hiera) for a certificate it does trust.
- The site is open to anyone who can reach the port, until you set `auth`.
- The distribution's default nginx site is left in place on port 80.

The first build starts when the timer first fires and documents every module, so it can take a few minutes. Follow it with `journalctl -fu seamstress.service`, then open `https://<the node's name>/`. Until that first build finishes there is nothing to serve.

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

By default SSH trusts a host the first time it sees it (`strict_host_key_checking => 'accept-new'`). Pinning the keys with `ssh_known_hosts` and `strict_host_key_checking => 'yes'`, as above, is safer. With `yes`, every host needs its key in `ssh_known_hosts` or the fetch fails.

A `Sensitive` class parameter keeps a value out of logs and reports, but it is still in the catalogue. That applies to `deploy_keys`, `forge_token`, and `basic_auth_users` here.

### Choosing environments

`environments` is an allow-list and `exclude_environments` is a list of regular expressions applied after it. Both are empty by default, which builds everything. In git mode an environment is named for its branch with every character that isn't a letter, digit, or underscore turned into `_`, as r10k does, so `feature/login` is `feature_login`, and the lists use that name.

If the two lists leave nothing of a source that has environments, the run stops with an error and removes nothing, since a mistyped name would otherwise empty the site. An entry in `environments` that matches nothing is logged as a warning. A source with no environments at all, where the site has some, is treated the same way, as a code directory that isn't mounted looks just like that. To skip short-lived branches made by deployment tooling:

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

The unit has a private `/tmp` and can't see `/home` or `/root`, so keep `code_dir` and tarballs somewhere else. To document the code a Puppet server has deployed, point `code_dir` at its environments directory and add the group that can read it to `supplementary_groups`.

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

Any OpenID Connect provider works: Keycloak, Entra ID, Okta, Google, authentik, Dex, and the like. Register a confidential client (one with a client secret) on the provider, with this redirect URI:

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

If the provider signs you in and you then get oauth2-proxy's 403 page, it is one of three things. The provider refused the request, which its own log will say (a client with no authorisation code grant does this). The token says the email is unverified, which `oidc_allow_unverified_email` covers. Or `oidc_allowed_groups` is set and no group arrived, because the provider only sends groups when the `groups` scope is asked for: add it to `oidc_scope`. `journalctl -u seamstress-oauth2-proxy.service` says which.

oauth2-proxy runs on x86_64 and aarch64 nodes, as the `seamstress-oauth2-proxy` user and unit, with its configuration in `/etc/seamstress-oauth2-proxy` and its releases in `/opt/seamstress-oauth2-proxy`. Those names are seamstress's own, so an oauth2-proxy the node already runs for something else is left alone. Setting `auth` to anything else stops the unit and removes it along with `/etc/seamstress-oauth2-proxy` and the secrets in it. Downloaded releases and the account stay.

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

### Certificates from Hiera

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

### Hiera Explorer

`hiera` adds a Hiera Explorer to each environment, as the site's second section: the bar at the top switches between it and the module documentation, and each environment's dashboard links to it. It has a page of its own, without the module tree, the search, or the compare link.

Pick a sample node and it shows every level of the hierarchy in order and whether the level has a data file for that node. Opened, a level lists the keys its file sets, with the ones a more specific level overrides struck through. A key can be searched for across the levels, and the page says what the node gets for it and from where.

```puppet
class { 'seamstress':
  control_repo        => 'git@git.example.com:puppet/control-repo.git',
  auth                => 'oidc',
  oidc_issuer_url     => 'https://login.example.com/realms/staff',
  oidc_client_id      => 'seamstress',
  oidc_client_secret  => Sensitive(lookup('seamstress::oidc_client_secret')),
  hiera               => true,
  hiera_samples       => {
    'A web server in Sydney' => {
      'trusted.extensions.pp_role'       => 'role::web',
      'trusted.extensions.pp_datacenter' => 'syd',
      'facts.os.family'                  => 'RedHat',
    },
  },
}
```

It publishes the values in your data files to anyone who can read the site, so it's off by default and belongs behind `auth`. A value with eyaml ciphertext anywhere in it is left out whole when the site is built, a key that is ciphertext is replaced by a made-up name, and nothing is decrypted, so no ciphertext is published.

A sample node is a set of values for the hierarchy's variables, named as `hiera.yaml` writes them, and no node's facts are read. `hiera_samples` names some, and each variable's field lists every value known for it, from the samples and from what the data files imply (`role/role::web.yaml` under `role/%{trusted.extensions.pp_role}.yaml` implies `role::web`), while still taking any text.

Merged keys are merged when the site is built, by Puppet's own merge code and following the `lookup_options` in the environment's data, so `deep` with `knockout_prefix` or `merge_hash_arrays` comes out as it does in a catalogue.

`hiera_values` adds values the files can't imply, such as the certnames and roles in your estate. The module doesn't talk to PuppetDB, so a profile gives them to it, for example:

```puppet
$nodes = puppetdb_query('inventory[certname, trusted.extensions.pp_role] { }')
class { 'seamstress':
  control_repo => 'git@git.example.com:puppet/control-repo.git',
  hiera        => true,
  hiera_values => {
    'trusted.certname'           => $nodes.map |$n| { $n['certname'] },
    'trusted.extensions.pp_role' => $nodes.map |$n| { $n['trusted.extensions.pp_role'] }.filter |$v| { $v =~ String[1] },
  },
}
```

They're published on the page with everything else, so leave it off if the list of your nodes shouldn't be. At most `hiera_values_limit` values are kept for a variable, 200 unless you change it, so a large estate's certnames don't swell the page. The first that many in sorted order are offered, the page says it has cut them, and any value can still be typed.

What it reads, and what it doesn't:

- It needs a version 5 `hiera.yaml` in the environment. An environment without one has no Explorer, and the build log says so. Where `hiera.yaml` leaves out `defaults` or `hierarchy`, the Explorer uses what Puppet does: `yaml_data` in `data`, and one level, `common.yaml`.
- It reads the `yaml_data` and `eyaml_lookup_key` backends, with `path` and `paths`. A level using another backend, or `glob`, `globs`, `mapped_paths`, `uri`, or `uris`, or whose `datadir` is interpolated or outside the environment, is shown as one it can't read.
- When a level it can't read, or one whose variable you've left empty, could change an answer, the page says so beside the answer and names the levels. For a key found by first match that means a level above the one it was found in. For a merged key it means any of them.
- A data file that is a symbolic link, or that resolves to somewhere outside the environment, is not read, and the page notes it.
- A data file that comes to an enormous size once its YAML aliases are followed is shown as empty, and a merged key set in so many files that every combination can't be worked out is shown unmerged, and the page notes both.
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
| `hiera` | `false` | Add a Hiera Explorer to each environment |
| `hiera_samples` | `{}` | Named sample nodes for the Hiera Explorer |
| `hiera_values` | `{}` | More values to offer for the Hiera Explorer's variables |
| `hiera_values_limit` | `200` | Most values from `hiera_values` offered for one variable |
| `site_title` | `seamstress` | Name in each page's title, as the browser tab shows it |
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
systemctl list-timers seamstress.timer  # when it last ran and when it runs next
systemctl start seamstress.service      # build now
journalctl -u seamstress.service        # what the last runs did
sudo -u seamstress /opt/puppetlabs/puppet/bin/ruby /opt/seamstress/seamstress.rb \
  --config /etc/seamstress/config.json --force --environment production
```

`--force` rebuilds whatever it is pointed at, `--environment` limits a run to one environment, `--debug` logs more, and `--version` prints the version.

- To see that it's working, read `status.json` at the top of the site, which has every environment's last build and last attempt, and the version. The same version is in every page's footer. With `metrics_file` set, alert on `seamstress_last_success_timestamp_seconds`.
- When a build fails, the pages say which stage failed and give one line of the reason, and the journal has the whole of it, with the command and its output.
- A module that fails to document doesn't fail the run. It shows on the environment's dashboard and in `seamstress_failed_modules`.
- A run exits 0 when every environment built or was already current, 1 when one failed or the environment lists left nothing to build, and 2 for a bad option, a missing configuration file, or an `--environment` the site doesn't have. A run limited by `--environment` doesn't move the last-success time, since it says nothing about the others.
- A change to the module itself (an upgrade, or a setting that changes the pages) rebuilds every environment on the next run. `site_title` is the exception: it shows on pages built after the change, so use `--force` to have it everywhere at once.
- A setting changed in Puppet takes effect on the timer's next run.

### Upgrading from strings_site

The module was called `strings_site` up to 0.2.0, and nothing moves a node across. Rebuilding the node is simplest. Otherwise, before applying seamstress, remove what strings_site left:

- the units `strings_site.service` and `strings_site.timer`, which will otherwise keep building;
- `/etc/nginx/conf.d/strings_site.conf`, which listens on the same port and name, and `/etc/nginx/strings_site`;
- `/opt/strings_site`, `/etc/strings_site`, `/var/lib/strings_site`, and `/var/www/strings_site`;
- the `strings` user and group.

Then rename the Hiera keys from `strings_site::*` to `seamstress::*`, and any alert on `strings_site_*` metrics to `seamstress_*`.

From seamstress 0.3.0 or 0.4.x with `auth => 'oidc'`: oauth2-proxy moved to names of its own in 0.5.0. The old `/etc/oauth2-proxy`, `/opt/oauth2-proxy`, and `oauth2-proxy` user and group are left where they are, and readers sign in again once. `/etc/oauth2-proxy` still holds the client secret, so remove all three if nothing else uses them.

### Removing it

There is no `ensure => absent`. Stop classifying the node with the class, then remove:

- the units `seamstress.service`, `seamstress.timer`, and `seamstress-oauth2-proxy.service`;
- `/etc/nginx/conf.d/seamstress.conf` and `/etc/nginx/seamstress`, then reload nginx;
- `/opt/seamstress`, `/etc/seamstress`, `/var/lib/seamstress`, `/var/www/seamstress`, `/etc/seamstress-oauth2-proxy`, and `/opt/seamstress-oauth2-proxy`;
- the `seamstress` and `seamstress-oauth2-proxy` users and groups;
- the `puppet-strings` gem from Puppet's Ruby, if nothing else uses it.

## Trust

A Puppetfile is Ruby, and the build evaluates it the same way r10k does. That is the same trust r10k already gives your control repo, and here it runs as the unprivileged service user inside the hardened unit. Credentials embedded in a URL are masked in logs and pages, but `deploy_keys` keeps the credential out of the URL and the configuration file altogether.

Documentation is treated as untrusted too. READMEs and docstrings are rendered by the build's own markdown renderer, which escapes everything, drops script and style blocks, keeps only a few attribute-free inline tags, allows links only to `http`, `https`, `mailto`, and relative targets, and turns images into links so a page never fetches from elsewhere. Only a module's `metadata.json` and README are read besides the puppet-strings output, and neither is published as it stands.

A module can't reach outside itself or run code in the build. Each module is documented from a copy that leaves out its symbolic links, anything that isn't a plain file or directory, and the `.yardopts` and `.document` files YARD would take options from. A module that is slow, enormous, or malformed fails on its own, and the rest of the environment publishes.

With `hiera` on, the environment's `hiera.yaml` and data files are read as YAML, never evaluated. Their values are published, apart from any with eyaml ciphertext in them. Data files that are symbolic links, or that lie outside the environment, are not read.

What a failed build publishes is the stage and one line of the reason, without the command or the paths on the node. The whole of it stays in the journal.

## Development

```shell
bundle install
bundle exec rake syntax lint metadata_lint rubocop spec
```

The build script's own tests are in `spec/unit/app`. They run the real script against throwaway git repositories and directories, with a stand-in for `puppet strings`, so they need neither Puppet nor the network. The renderer's tests draw a whole environment from the puppet-strings JSON in `spec/unit/app/fixtures`, which includes hostile markup on purpose (the README fixture is `.markdown` so markdownlint leaves it alone).

The build script is `files/app/seamstress.rb`. It loads the documentation model, renderer, markdown renderer, highlighter, and Hiera index from `files/app/lib`, and the page templates from `files/app/templates`. The Hiera Explorer's own script is `files/app/assets/hiera.js`.

## Licence

Apache 2.0. See [LICENSE](LICENSE).

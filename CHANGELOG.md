# Changelog

All notable changes to this module are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module uses [semantic versioning](https://semver.org/).

## [0.5.0] - unreleased

A review before the first release to the Forge found the following. Anyone running 0.3.0 or 0.4.x should move to this.

Security:

- A module could run code in the build. YARD takes options from a `.yardopts` or `.document` file in the module it is documenting, and those can load Ruby. Neither file is copied for the build now, and the build no longer uses the module's own directory as its home.
- A module could publish a file from outside itself. A `README.md` or `metadata.json` that was a symbolic link was read through to its target. A module is now documented from a copy without its symbolic links, or anything else that isn't a plain file or directory.
- The Hiera Explorer published eyaml ciphertext that sat inside a longer string, such as a connection string with an encrypted password, because only values that began with `ENC[` were left out. A value with ciphertext anywhere in it is now left out whole, and a key that is ciphertext is replaced by a made-up name.
- A Hiera data file that was a symbolic link, or lay outside the environment, was read and published. It is now skipped, with a note on the page.
- A parameter name could inject markup into a page through a heading's id. The id is now cut down to safe characters, and module and object URLs are escaped wherever a page prints them.
- A README with thousands of nested block quotes overflowed the stack, which nothing caught, and stopped every run. Nesting is capped, and a module that fails this way is marked failed while the run carries on.
- A Hiera data file whose YAML aliases expand to an enormous size is shown as empty, and the merged values worked out for one index are capped, so neither can exhaust the build.
- What a failed build publishes, on the pages and in `status.json`, is now the stage that failed and one line of the reason, without the command or the node's paths. The whole of it stays in the journal.

Changed, and needs a look when upgrading:

- With `auth => 'oidc'`, oauth2-proxy now runs as the `seamstress-oauth2-proxy` user, with its configuration in `/etc/seamstress-oauth2-proxy` and its releases in `/opt/seamstress-oauth2-proxy`. It used the generic `oauth2-proxy` names, and a default install, with `auth` off, removed `/etc/oauth2-proxy`, which could belong to an oauth2-proxy the node runs for something else. The module no longer touches the generic names. The old directories and account are left for you to remove, and readers sign in again once.
- If `environments` and `exclude_environments` leave nothing of a source that has environments, the run now stops with an error and removes nothing. A mistyped name used to remove every build and report success. An entry in `environments` that matches nothing is logged as a warning.
- `--environment` with a name the site doesn't have exits 2, and a run limited by `--environment` no longer moves the last-success time.
- `metadata.json` says Puppet 8 only, down from 8 or 9, since 8 is what the module is tested on.

Fixed:

- A `hiera.yaml` with no `defaults` or no `hierarchy` showed every level as unreadable. The Explorer now uses what Puppet does: `yaml_data` in `data`, and one level, `common.yaml`.
- The Explorer says so when a level it didn't read, or one whose variable was left empty, could change an answer, and names the levels. It used to state the answer as fact.
- The Explorer shows each level's name from `hiera.yaml`, labels the level that wins as well as the ones it overrides, prints the `puppet lookup` command for the key it resolved, and leaves a key with shell characters out of that command.
- An environment with `hiera` on and no `hiera.yaml` to read says so in the build log.
- On a phone the environment can be seen and changed, and the comparison is reachable from the sidebar and the base page.
- The package built for the Forge leaves out the tests and tooling.

## [0.4.1] - 2026-11-23

- seamstress's mark is an S in running stitch with the needle that is sewing it, drawn larger in the bar, and it is the browser tab's icon too.

## [0.4.0] - 2026-11-23

- `hiera` adds the Hiera Explorer to each environment, as the site's second section beside the module documentation. For a sample node it shows each level of the hierarchy, whether the level has data for the node, and the keys it sets, with what is overridden and what is merged. A key can be searched for across the levels. It has a page of its own, without the module tree, the search, or the compare link, and `/` goes to its key box. It is off by default because it publishes the values in the data files. Encrypted values are left out at build time and nothing is decrypted.
- `hiera_samples` names sample nodes for the Explorer. Each variable's field is a combo box that lists every value known for the variable, from the data files' names and the samples, and still takes any text. `hiera_values` adds more values to offer, such as the certnames and roles in the estate, which a profile can take from PuppetDB, and `hiera_values_limit` caps how many are kept for one variable, 200 by default.
- The bar at the top of every page carries seamstress's mark and name, the environment, and a switch between the two sections. The environment is a menu when there is more than one: choosing one goes to the same page there, or to that environment's dashboard when it has no such page.
- The base page says what seamstress is and nothing else, apart from a notice for any environment whose last build failed. It no longer lists the environments or links to the comparison. The sections open for the chosen environment, which is production, or the first by name, until the reader picks another, and the choice is remembered in the browser.
- `site_title` defaults to `seamstress`. It was `Puppet module reference`, from when the site was only that.
- A build is redone when the module's own script, templates, or assets change, not only when the code it documents or the version does. An upgrade that changed a template within a version left the old pages in place until the next deploy.
- Merged keys on the Hiera Explorer are merged at build time by Puppet's own merge code, so `deep` merges with `knockout_prefix` or `merge_hash_arrays` match a catalogue.
- The version in the page footers and `build.json` was still 0.2.0 in the 0.3.0 release. It now follows `metadata.json`, and a spec holds the two together.

## [0.3.0] - 2026-11-23

- The module is renamed from strings_site to seamstress. The class and its Hiera keys, the service account, the systemd units, the directories under `/opt`, `/etc`, `/var/lib`, `/var/www`, and `/etc/nginx`, the metric names, and the sign-in cookie all take the new name. Nothing moves an existing node across, so rebuild it, or remove what strings_site left behind before applying seamstress.
- `auth` puts the site behind a sign-in. `oidc` signs readers in through any OpenID Connect provider using oauth2-proxy, which the module downloads (checksum-verified), configures, and runs in a hardened systemd unit on 127.0.0.1, with nginx checking every request through `auth_request`. `basic` uses HTTP basic auth from `basic_auth_users`, password hashes only. The default, `none`, leaves the site open as before.
- The oauth2-proxy client secret can be Deferred, so it stays out of the catalogue, and the cookie secret is generated on the node and never passes through Puppet.
- `tls_cert` takes the PEM itself as well as a path, and `tls_key` takes a path, a Sensitive PEM, or a Deferred value, so a certificate and key can come from Hiera and eyaml.
- `/etc/nginx/seamstress` is now group-owned by nginx's worker group with mode 0710, so the workers can reach the htpasswd file. The key is still mode 0600 and root's alone.
- In directory mode, a module pinned to a full commit takes that commit as its SHA when `.r10k-deploy.json` records none. Code Manager can write `sha: null` for a pinned module it had nothing to resolve, so the comparison page showed the same commit as a difference between environments.
- A ref that is a full commit is drawn as a short SHA with the whole of it in the title, and a long branch or tag name wraps. A 40-character ref ran out of its column and over the resolved SHA on the module page.
- `oidc_allow_unverified_email` lets in a user whose token says `email_verified` is false. oauth2-proxy refuses those with a 403, and authentik's default email scope sends false for every user.
- With `auth => 'oidc'`, nginx gets 16k buffers for oauth2-proxy's answers and for request headers. The session cookie holds the provider's tokens, and a callback answer bigger than nginx's default buffer came back as a 502.

## [0.2.0] - 2026-11-22

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

## [0.1.0] - not tagged

The first version, as strings_site.

- Builds a puppet-strings site for every environment of a control repo, from git (`source => 'git'`) or from code already on disk or in a tarball (`source => 'directory'`).
- Rebuilds only environments whose control-repo or module SHAs moved, runs puppet-strings once per module so a failure stays contained, and publishes each build by swapping a symlink.
- Keeps the last good build live when a build fails, with a banner on every page saying so.
- Client-side search across classes, defined types, resource types, functions, tasks, and plans.
- Read-only SSH deploy keys per repository URL or glob, and an optional Forge API key.
- Hardened systemd service and timer, optional nginx on 443, and an optional Prometheus textfile metric.

/* seamstress: the Hiera page. Walks the hierarchy for a sample node over the
 * index the build wrote (hiera.json). The build did the merging, with
 * Puppet's own code, for every set of files that can apply together, so a
 * merged value here is read off, never worked out. Loaded only by that page. */
(function () {
  'use strict';

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      if (k === 'text') node.textContent = attrs[k];
      else if (k === 'class') node.className = attrs[k];
      else node.setAttribute(k, attrs[k]);
    });
    (children || []).forEach(function (c) { if (c) node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    return node;
  }

  function isEnc(v) { return !!v && typeof v === 'object' && v.__enc === true; }
  function isBig(v) { return !!v && typeof v === 'object' && !isEnc(v); }
  function own(obj, key) { return Object.prototype.hasOwnProperty.call(obj, key); }

  function scalar(v) {
    if (v === null || v === undefined) return '~';
    if (typeof v === 'string') return /^[\w.\/:@ -]+$/.test(v) && !/^(true|false|null|~|\d+)$/.test(v) ? v : JSON.stringify(v);
    return String(v);
  }

  // YAML-ish, with an encrypted value named and never shown.
  function render(v, indent) {
    indent = indent || '';
    if (isEnc(v)) return '‹encrypted›';
    if (!isBig(v)) return scalar(v);
    if (Array.isArray(v)) {
      if (!v.length) return '[]';
      return v.map(function (x) { return indent + '- ' + render(x, indent + '  ').replace(/^\s+/, ''); }).join('\n');
    }
    var keys = Object.keys(v);
    if (!keys.length) return '{}';
    return keys.map(function (k) {
      var x = v[k];
      var nested = isBig(x) && (Array.isArray(x) ? x.length : Object.keys(x).length);
      return indent + k + ':' + (nested ? '\n' + render(x, indent + '  ') : ' ' + render(x, indent + '  '));
    }).join('\n');
  }

  function describe(v) {
    if (isEnc(v)) return 'encrypted';
    if (!isBig(v)) return scalar(v);
    if (Array.isArray(v)) return 'a list of ' + v.length;
    var n = Object.keys(v).length;
    return n + (n === 1 ? ' setting' : ' settings');
  }

  // What a Hiera key, a certname, and an environment's name are made of. The
  // key box can be filled from the address, and what it holds is printed in
  // a command to paste on the primary, so nothing else is printed there.
  var KEY = /^\w[\w:.-]*$/;
  var NODE = /^\w[\w.-]*$/;
  // Only a backend that reads files has its path under the datadir.
  var FILE_BACKENDS = /^(yaml_data|json_data|hocon_data|eyaml_lookup_key)$/;

  function listed(ns) {
    return ns.length < 3 ? ns.join(' and ') : ns.slice(0, -1).join(', ') + ', and ' + ns[ns.length - 1];
  }

  function notRead(ns) {
    return (ns.length === 1 ? 'level ' + ns[0] + ' was' : 'levels ' + listed(ns) + ' were') + ' not read';
  }

  function valueNode(v) {
    if (v === undefined) return el('span', { class: 'muted', text: 'merged value not worked out' });
    if (isEnc(v)) return el('span', { class: 'hiera-enc', text: 'encrypted' });
    if (!isBig(v)) {
      var text = scalar(v);
      if (text.length <= 90) return el('span', { text: text });
      return el('details', {}, [el('summary', { text: text.slice(0, 60) + '…' }), el('pre', { text: text })]);
    }
    if (Array.isArray(v) && v.length && !v.some(isBig) && !v.some(isEnc) && v.map(scalar).join(', ').length <= 70) {
      return el('span', { text: v.map(scalar).join(', ') });
    }
    return el('details', {}, [el('summary', { text: describe(v).replace(/^a /, '') }), el('pre', { text: render(v) })]);
  }

  function start(page, index) {
    var q = function (name) { return page.querySelector('[data-hiera-' + name + ']'); };
    var vars = {};
    var named = '';
    var open = {};
    var allVars = [];
    index.levels.forEach(function (l) { l.vars.forEach(function (v) { if (allVars.indexOf(v) < 0) allVars.push(v); }); });

    var allKeys = (function () {
      var keys = {};
      Object.keys(index.data).forEach(function (f) { Object.keys(index.data[f]).forEach(function (k) { if (k !== 'lookup_options') keys[k] = true; }); });
      return Object.keys(keys).sort();
    }());

    function resolve(level) {
      var missing = [];
      var path = level.datadir + '/' + level.path.replace(/%\{([^}]+)\}/g, function (_, name) {
        name = name.trim();
        if (!vars[name]) missing.push(name);
        return vars[name] || '';
      });
      return { path: path, missing: missing, exists: level.readable && !missing.length && own(index.data, path) };
    }

    function optionsFor(key) {
      var opts = index.lookup_options[key];
      if (!opts) {
        Object.keys(index.lookup_options).some(function (pattern) {
          if (pattern.charAt(0) !== '^') return false;
          try { if (new RegExp(pattern).test(key)) { opts = index.lookup_options[pattern]; return true; } } catch (e) { /* not a pattern */ }
          return false;
        });
      }
      opts = opts || {};
      var merge = opts.merge || 'first';
      return { strategy: typeof merge === 'string' ? merge : (merge.strategy || 'first'), convert: opts.convert_to || null };
    }

    // The levels with no answer for this node: a backend the build did not
    // read, or a path with a variable the sample gives no value. On a real
    // node any of them could set a key.
    function unread() {
      var out = [];
      index.levels.forEach(function (level, i) { if (!level.readable || resolve(level).missing.length) out.push(i + 1); });
      return out;
    }

    // The levels that set key for this node, and what comes out. blind is the
    // unread levels that could change it: the ones above the level a
    // first-found key came from, and any at all for a key that merges.
    function lookup(key) {
      var opts = optionsFor(key);
      var hits = [];
      index.levels.forEach(function (level, i) {
        var r = resolve(level);
        if (r.exists && own(index.data[r.path], key)) hits.push({ n: i + 1, file: r.path, value: index.data[r.path][key] });
      });
      var blind = unread().filter(function (n) { return opts.strategy !== 'first' || !hits.length || n < hits[0].n; });
      var merged = opts.strategy !== 'first' && hits.length > 1;
      var value;
      if (hits.length && !merged) value = hits[0].value;
      else if (merged && index.merged[key]) value = index.merged[key][hits.map(function (h) { return h.file; }).join('\n')];
      return { key: key, hits: hits, found: hits.length > 0, merged: merged, value: value, strategy: opts.strategy, convert: opts.convert, blind: blind };
    }

    function fate(key, n) {
      var r = lookup(key);
      if (r.merged) return { cls: 'merged', text: r.strategy + ' merge, ' + r.hits.length + ' levels' };
      if (r.hits[0].n !== n) return { cls: 'lost', text: 'overridden at level ' + r.hits[0].n };
      var under = r.hits.slice(1).map(function (h) { return h.n; });
      return { cls: 'wins', text: under.length ? 'overrides level' + (under.length > 1 ? 's ' : ' ') + listed(under) : '' };
    }

    function drawNode() {
      var box = q('named');
      box.textContent = '';
      Object.keys(index.samples).forEach(function (name) {
        var b = el('button', { type: 'button', class: 'hiera-sample', 'aria-pressed': String(name === named), text: name });
        b.addEventListener('click', function () { named = name; vars = Object.assign({}, index.samples[name]); open = {}; drawNode(); refresh(); });
        box.appendChild(b);
      });
      var grid = q('vars');
      grid.textContent = '';
      allVars.forEach(function (name) { grid.appendChild(combo(name, box)); });
    }

    // Every value known for a variable: the ones the data files' names imply,
    // the ones the named samples give it, and any the site was configured with.
    function known(name) {
      var seen = [];
      var add = function (v) { if (v && seen.indexOf(v) < 0) seen.push(v); };
      index.levels.forEach(function (l) { l.files.forEach(function (f) { add(f.vars[name]); }); });
      Object.keys(index.samples).forEach(function (s) { add(index.samples[s][name]); });
      ((index.values || {})[name] || []).forEach(add);
      return seen.sort();
    }

    // A variable's field: free text, with a list of every known value that
    // opens from the caret or the arrow keys. Typing narrows the list, and a
    // value that is not on it is as good as one that is.
    function combo(name, named_box) {
      var values = known(name);
      var id = 'hiera-var-' + name.replace(/\W/g, '-');
      var dot = name.indexOf('.');
      var input = el('input', { type: 'text', value: vars[name] || '', spellcheck: 'false', autocomplete: 'off', 'aria-label': name,
        role: 'combobox', 'aria-expanded': 'false', 'aria-controls': id, 'aria-autocomplete': 'list' });
      var list = el('ul', { class: 'hiera-options', id: id, role: 'listbox', hidden: '' });
      var caret = el('button', { type: 'button', class: 'hiera-caret', tabindex: '-1', 'aria-label': 'Show the values for ' + name });
      var active = -1;

      function set(value) {
        input.value = value;
        vars[name] = value.trim();
        named = '';
        Array.prototype.forEach.call(named_box.children, function (b) { b.setAttribute('aria-pressed', 'false'); });
        refresh();
      }

      function close() {
        list.hidden = true;
        active = -1;
        input.setAttribute('aria-expanded', 'false');
      }

      // filter is what was typed, or nothing to show every value.
      function open(filter) {
        var text = (filter || '').toLowerCase();
        var shown = values.filter(function (v) { return v.toLowerCase().indexOf(text) >= 0; });
        list.textContent = '';
        shown.forEach(function (v) {
          var item = el('li', { role: 'option', text: v, 'aria-selected': String(v === input.value) });
          item.addEventListener('mousedown', function (ev) { ev.preventDefault(); set(v); close(); });
          list.appendChild(item);
        });
        list.hidden = !shown.length;
        active = -1;
        input.setAttribute('aria-expanded', String(!list.hidden));
      }

      function move(step) {
        var items = list.children;
        if (list.hidden || !items.length) { open(''); items = list.children; }
        if (!items.length) return;
        if (active >= 0) items[active].classList.remove('is-active');
        active = (active + step + items.length) % items.length;
        items[active].classList.add('is-active');
        items[active].scrollIntoView({ block: 'nearest' });
      }

      input.addEventListener('input', function () { set(input.value); open(input.value); });
      input.addEventListener('blur', close);
      input.addEventListener('keydown', function (ev) {
        if (ev.key === 'ArrowDown') { ev.preventDefault(); move(1); }
        else if (ev.key === 'ArrowUp') { ev.preventDefault(); move(-1); }
        else if (ev.key === 'Enter' && active >= 0) { ev.preventDefault(); set(list.children[active].textContent); close(); }
        else if (ev.key === 'Escape' && !list.hidden) { ev.preventDefault(); ev.stopPropagation(); close(); }
      });
      caret.addEventListener('mousedown', function (ev) {
        ev.preventDefault();
        if (list.hidden) { input.focus(); open(''); } else { close(); }
      });
      if (!values.length) caret.hidden = true;

      return el('label', {}, [
        el('span', {}, [el('b', { text: name.slice(0, dot + 1) }), name.slice(dot + 1),
          values.length ? el('i', { text: ' ' + values.length + ' known' }) : null]),
        el('span', { class: 'hiera-combo' }, [input, caret, list])
      ]);
    }

    function pathNode(level) {
      var node = el('span', { class: 'hiera-path' }, [level.readable || FILE_BACKENDS.test(level.backend) ? level.datadir + '/' : '']);
      level.path.split(/(%\{[^}]+\})/).forEach(function (part) {
        var m = /^%\{([^}]+)\}$/.exec(part);
        var name = m && m[1].trim();
        if (!m) node.appendChild(document.createTextNode(part));
        else if (vars[name]) node.appendChild(el('var', { text: vars[name], title: name }));
        else node.appendChild(el('var', { class: 'hiera-unset', text: '{' + name + '}', title: 'No value for ' + name }));
      });
      return node;
    }

    // The name hiera.yaml gives the entry a level comes from, which is what
    // puppet lookup --explain calls it.
    // An entry in hiera.yaml can list several paths, which all carry its name.
    // The name is shown on the first of them, and not at all when the whole
    // hierarchy is one entry, where it would only repeat down the page.
    var oneName = index.levels.every(function (l) { return l.name === index.levels[0].name; });

    function nameNode(level) {
      var at = index.levels.indexOf(level);
      if (!level.name || oneName || (at > 0 && index.levels[at - 1].name === level.name)) return null;
      return el('span', { class: 'hiera-level-name', text: level.name, title: 'Named "' + level.name + '" in hiera.yaml' });
    }

    function keyRow(key, value, n) {
      var f = fate(key, n);
      var cut = key.lastIndexOf('::');
      return el('li', { class: 'hiera-key hiera-key-' + f.cls }, [
        el('span', { class: 'hiera-key-name', text: cut > 0 ? key.slice(cut + 2) : key, title: key }),
        el('span', { class: 'hiera-value' }, [valueNode(value)]),
        el('span', { class: 'hiera-fate hiera-fate-' + f.cls, text: f.text })
      ]);
    }

    // The other files at a level, each a way to point the sample node at it.
    function others(level, current) {
      var rest = level.files.filter(function (f) { return f.file !== current; });
      if (!rest.length || !level.vars.length) return null;
      var p = el('p', { class: 'hiera-others' }, [rest.length === level.files.length ? 'Files at this level: ' : 'Other files at this level: ']);
      rest.forEach(function (f, i) {
        var b = el('button', { type: 'button', text: f.file.replace(/\.[^.\/]+$/, '').replace(/^.*\//, ''), title: 'Make the sample node match ' + f.file });
        b.addEventListener('click', function () {
          Object.keys(f.vars).forEach(function (k) { vars[k] = f.vars[k]; });
          named = '';
          drawNode();
          refresh();
        });
        p.appendChild(b);
        if (i < rest.length - 1) p.appendChild(document.createTextNode(', '));
      });
      return p;
    }

    function missLevel(level, n, r, find) {
      var why = !level.readable ? level.reason : (r.missing.length ? 'no value for ' + r.missing.join(', ') : 'no file');
      var head = [pathNode(level), nameNode(level), el('span', { class: 'hiera-say', text: why })];
      var more = others(level, r.path);
      var body = more
        ? el('details', { class: 'hiera-body' }, [el('summary', { class: 'hiera-head' }, [el('span', { class: 'hiera-twist' })].concat(head)), el('div', { class: 'hiera-open' }, [more])])
        : el('div', { class: 'hiera-body' }, [el('div', { class: 'hiera-head' }, head)]);
      return el('li', { class: 'hiera-level hiera-level-miss' + (find ? ' hiera-level-dim' : '') }, [el('span', { class: 'hiera-knot', text: String(n), 'aria-hidden': 'true' }), body]);
    }

    function drawStack() {
      var find = q('find').value.trim().toLowerCase();
      var stack = q('stack');
      stack.textContent = '';
      var matched = {};
      index.levels.forEach(function (level, i) {
        var n = i + 1;
        var r = resolve(level);
        if (!r.exists) { stack.appendChild(missLevel(level, n, r, find)); return; }

        var data = index.data[r.path];
        var keys = Object.keys(data).filter(function (k) { return k !== 'lookup_options'; }).sort();
        var shown = find ? keys.filter(function (k) { return k.toLowerCase().indexOf(find) >= 0; }) : keys;
        shown.forEach(function (k) { matched[k] = true; });
        var lost = keys.filter(function (k) { return fate(k, n).cls === 'lost'; }).length;
        var say = find ? (shown.length ? shown.length + (shown.length === 1 ? ' match' : ' matches') : 'no match')
          : keys.length + (keys.length === 1 ? ' key' : ' keys');

        var groups = {};
        shown.forEach(function (k) { var cut = k.lastIndexOf('::'); var g = cut > 0 ? k.slice(0, cut) : 'top level'; (groups[g] = groups[g] || []).push(k); });
        var body = el('div', { class: 'hiera-open' }, Object.keys(groups).sort().map(function (g) {
          return el('div', { class: 'hiera-group' }, [
            el('p', { class: 'hiera-group-name', text: g }),
            el('ul', { class: 'hiera-keys' }, groups[g].map(function (k) { return keyRow(k, data[k], n); }))
          ]);
        }));
        if (!find) body.appendChild(others(level, r.path) || el('span'));

        var details = el('details', { class: 'hiera-body' }, [
          el('summary', { class: 'hiera-head' }, [el('span', { class: 'hiera-twist' }), pathNode(level), nameNode(level),
            el('span', { class: 'hiera-say' }, [say, !find && lost ? el('span', { text: ', ' + lost + ' overridden' }) : null])]),
          body
        ]);
        if (find ? shown.length > 0 : open[n]) details.setAttribute('open', '');
        details.addEventListener('toggle', function () { if (!q('find').value.trim()) open[n] = details.open; });
        stack.appendChild(el('li', { class: 'hiera-level hiera-level-hit' + (find && !shown.length ? ' hiera-level-dim' : '') },
          [el('span', { class: 'hiera-knot', text: String(n), 'aria-hidden': 'true' }), details]));
      });

      var count = Object.keys(matched).length;
      var none = 'nothing sets that for this node' + (unread().length ? ' in the levels that were read' : '');
      q('count').textContent = find ? (count ? count + (count === 1 ? ' key' : ' keys') + ' for this node' : none) : '';
      return drawVerdict(find, Object.keys(matched));
    }

    // One key in view: say what the node gets and from where, and which
    // levels that were not read could make it something else. Returns the
    // key, or null when what was typed does not come down to one.
    function drawVerdict(find, keys) {
      var strip = q('verdict');
      var exact = keys.filter(function (k) { return k.toLowerCase() === find; })[0] || (keys.length === 1 ? keys[0] : null);
      strip.hidden = !find || !exact;
      strip.textContent = '';
      if (strip.hidden) return null;
      var r = lookup(exact);
      strip.appendChild(el('code', { text: exact }));
      strip.appendChild(el('span', { text: 'is' }));
      strip.appendChild(el('span', { class: 'hiera-verdict-value', text: r.value === undefined ? 'a merge this page did not work out' : describe(r.value) }));
      strip.appendChild(el('span', { class: 'hiera-verdict-how', text: r.merged
        ? r.strategy + ' merge of levels ' + r.hits.map(function (h) { return h.n; }).join(', ')
        : 'from level ' + r.hits[0].n + ', ' + r.hits[0].file }));
      if (r.convert) strip.appendChild(el('span', { class: 'hiera-verdict-how', text: 'converted to ' + r.convert }));
      if (r.blind.length) strip.appendChild(el('span', { class: 'hiera-verdict-caveat', text: notRead(r.blind) + ', and could change this' }));
      if (isBig(r.value)) strip.appendChild(el('details', {}, [el('summary', { text: r.merged ? 'Show the merged result' : 'Show it' }), el('pre', { text: render(r.value) })]));
      return exact;
    }

    function drawAll() {
      var body = q('all');
      body.textContent = '';
      var total = 0;
      var blind = [];
      allKeys.forEach(function (key) {
        var r = lookup(key);
        if (!r.found) return;
        total += 1;
        r.blind.forEach(function (n) { if (blind.indexOf(n) < 0) blind.push(n); });
        var from = r.merged ? r.hits.map(function (h) { return h.n; }).join(' + ') + ' (' + r.strategy + ')' : String(r.hits[0].n);
        body.appendChild(el('tr', {}, [el('td', { text: key }), el('td', { class: 'hiera-value' }, [valueNode(r.value)]),
          el('td', {}, [from, el('span', { class: 'muted', text: ' ' + r.hits[0].file })])]));
      });
      q('all-count').textContent = total + ' of the ' + allKeys.length + ' keys in the data';
      var caveat = q('all-caveat');
      caveat.hidden = !blind.length;
      caveat.textContent = blind.length ? notRead(blind.sort(function (a, b) { return a - b; })) + ', and could change some of these' : '';
    }

    // The command is for the key the page settled on, when what was typed
    // comes down to one, and otherwise for what was typed.
    function refresh() {
      var key = drawStack() || q('find').value.trim();
      var node = vars['trusted.certname'] || '';
      drawAll();
      q('cmd').textContent = 'puppet lookup ' + (KEY.test(key) ? key : '<key>') + ' --explain --node ' + (NODE.test(node) ? node : '<certname>') +
        ' --environment ' + (NODE.test(index.environment) ? index.environment : '<environment>');
    }

    allKeys.forEach(function (k) { page.querySelector('#hiera-keys').appendChild(el('option', { value: k })); });
    q('find').addEventListener('input', refresh);
    // "/" goes to the key box, as it goes to the search on the other pages.
    document.addEventListener('keydown', function (ev) {
      var typing = /^(INPUT|TEXTAREA|SELECT)$/.test((ev.target.tagName || ''));
      if (ev.key === '/' && !typing && !ev.ctrlKey && !ev.metaKey && !ev.altKey) {
        ev.preventDefault();
        q('find').focus();
      }
    });
    if (index.notes.length) {
      var notes = q('notes');
      notes.hidden = false;
      index.notes.forEach(function (n) { notes.appendChild(el('li', { text: n })); });
    }

    named = Object.keys(index.samples)[0] || '';
    vars = named ? Object.assign({}, index.samples[named]) : {};
    var params = new URLSearchParams(location.search);
    if (params.get('key')) q('find').value = params.get('key');
    drawNode();
    refresh();
    // Drawn, so there is something to show.
    q('ready').hidden = false;
  }

  document.addEventListener('DOMContentLoaded', function () {
    var page = document.querySelector('[data-hiera]');
    if (!page) return;
    fetch(page.getAttribute('data-hiera-src'), { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then(function (index) { start(page, index); })
      .catch(function (e) {
        var box = page.querySelector('[data-hiera-error]');
        box.hidden = false;
        box.textContent = 'The Hiera data could not be loaded (' + e.message + ').';
      });
  });
}());

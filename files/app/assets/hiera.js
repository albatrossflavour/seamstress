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

    // The levels that set key for this node, and what comes out.
    function lookup(key) {
      var opts = optionsFor(key);
      var hits = [];
      index.levels.forEach(function (level, i) {
        var r = resolve(level);
        if (r.exists && own(index.data[r.path], key)) hits.push({ n: i + 1, file: r.path, value: index.data[r.path][key] });
      });
      var merged = opts.strategy !== 'first' && hits.length > 1;
      var value;
      if (hits.length && !merged) value = hits[0].value;
      else if (merged && index.merged[key]) value = index.merged[key][hits.map(function (h) { return h.file; }).join('\n')];
      return { key: key, hits: hits, found: hits.length > 0, merged: merged, value: value, strategy: opts.strategy, convert: opts.convert };
    }

    function fate(key, n) {
      var r = lookup(key);
      if (r.merged) return { cls: 'merged', text: r.strategy + ' merge, ' + r.hits.length + ' levels' };
      if (r.hits[0].n === n) return { cls: 'wins', text: '' };
      return { cls: 'lost', text: 'overridden at level ' + r.hits[0].n };
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
      allVars.forEach(function (name) {
        var seen = [];
        index.levels.forEach(function (l) { l.files.forEach(function (f) { if (f.vars[name] && seen.indexOf(f.vars[name]) < 0) seen.push(f.vars[name]); }); });
        var id = 'hiera-var-' + name.replace(/\W/g, '-');
        var dot = name.indexOf('.');
        var input = el('input', { type: 'text', list: id, value: vars[name] || '', spellcheck: 'false', autocomplete: 'off', 'aria-label': name });
        input.addEventListener('input', function () {
          vars[name] = input.value.trim();
          named = '';
          Array.prototype.forEach.call(box.children, function (b) { b.setAttribute('aria-pressed', 'false'); });
          refresh();
        });
        grid.appendChild(el('label', {}, [
          el('span', {}, [el('b', { text: name.slice(0, dot + 1) }), name.slice(dot + 1)]),
          input,
          el('datalist', { id: id }, seen.sort().map(function (v) { return el('option', { value: v }); }))
        ]));
      });
    }

    function pathNode(level) {
      var node = el('span', { class: 'hiera-path' }, [level.datadir + '/']);
      level.path.split(/(%\{[^}]+\})/).forEach(function (part) {
        var m = /^%\{([^}]+)\}$/.exec(part);
        var name = m && m[1].trim();
        if (!m) node.appendChild(document.createTextNode(part));
        else if (vars[name]) node.appendChild(el('var', { text: vars[name], title: name }));
        else node.appendChild(el('var', { class: 'hiera-unset', text: '{' + name + '}', title: 'No value for ' + name }));
      });
      return node;
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
      var head = [pathNode(level), el('span', { class: 'hiera-say', text: why })];
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
          el('summary', { class: 'hiera-head' }, [el('span', { class: 'hiera-twist' }), pathNode(level),
            el('span', { class: 'hiera-say' }, [say, !find && lost ? el('span', { text: ', ' + lost + ' overridden' }) : null])]),
          body
        ]);
        if (find ? shown.length > 0 : open[n]) details.setAttribute('open', '');
        details.addEventListener('toggle', function () { if (!q('find').value.trim()) open[n] = details.open; });
        stack.appendChild(el('li', { class: 'hiera-level hiera-level-hit' + (find && !shown.length ? ' hiera-level-dim' : '') },
          [el('span', { class: 'hiera-knot', text: String(n), 'aria-hidden': 'true' }), details]));
      });

      var count = Object.keys(matched).length;
      q('count').textContent = find ? (count ? count + (count === 1 ? ' key' : ' keys') + ' for this node' : 'nothing sets that for this node') : '';
      drawVerdict(find, Object.keys(matched));
    }

    // One key in view: say what the node gets and from where.
    function drawVerdict(find, keys) {
      var strip = q('verdict');
      var exact = keys.filter(function (k) { return k.toLowerCase() === find; })[0] || (keys.length === 1 ? keys[0] : null);
      strip.hidden = !find || !exact;
      strip.textContent = '';
      if (strip.hidden) return;
      var r = lookup(exact);
      strip.appendChild(el('code', { text: exact }));
      strip.appendChild(el('span', { text: 'is' }));
      strip.appendChild(el('span', { class: 'hiera-verdict-value', text: r.value === undefined ? 'a merge this page did not work out' : describe(r.value) }));
      strip.appendChild(el('span', { class: 'hiera-verdict-how', text: r.merged
        ? r.strategy + ' merge of levels ' + r.hits.map(function (h) { return h.n; }).join(', ')
        : 'from level ' + r.hits[0].n + ', ' + r.hits[0].file }));
      if (r.convert) strip.appendChild(el('span', { class: 'hiera-verdict-how', text: 'converted to ' + r.convert }));
      if (isBig(r.value)) strip.appendChild(el('details', {}, [el('summary', { text: r.merged ? 'Show the merged result' : 'Show it' }), el('pre', { text: render(r.value) })]));
    }

    function drawAll() {
      var body = q('all');
      body.textContent = '';
      var total = 0;
      allKeys.forEach(function (key) {
        var r = lookup(key);
        if (!r.found) return;
        total += 1;
        var from = r.merged ? r.hits.map(function (h) { return h.n; }).join(' + ') + ' (' + r.strategy + ')' : String(r.hits[0].n);
        body.appendChild(el('tr', {}, [el('td', { text: key }), el('td', { class: 'hiera-value' }, [valueNode(r.value)]),
          el('td', {}, [from, el('span', { class: 'muted', text: ' ' + r.hits[0].file })])]));
      });
      q('all-count').textContent = total + ' of the ' + allKeys.length + ' keys in the data';
    }

    function refresh() {
      drawStack();
      drawAll();
      q('cmd').textContent = 'puppet lookup ' + (q('find').value.trim() || '<key>') + ' --explain --node ' + (vars['trusted.certname'] || '<certname>') + ' --environment ' + index.environment;
    }

    allKeys.forEach(function (k) { page.querySelector('#hiera-keys').appendChild(el('option', { value: k })); });
    q('find').addEventListener('input', refresh);
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

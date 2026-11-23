/* seamstress: theme switch, stale-build banner, command palette, sidebar,
 * copy buttons, and the environment comparison. No dependencies, and
 * nothing is fetched from anywhere but this site. Every page works without
 * it; this only adds to what the HTML already does. */
(function () {
  'use strict';

  var THEME_KEY = 'seamstress.theme';
  var THEMES = ['auto', 'light', 'dark'];

  function storedTheme() {
    try {
      var t = window.localStorage.getItem(THEME_KEY);
      return THEMES.indexOf(t) >= 0 ? t : 'auto';
    } catch (e) {
      return 'auto';
    }
  }

  function applyTheme(t) {
    var root = document.documentElement;
    if (t === 'auto') {
      root.removeAttribute('data-theme');
    } else {
      root.setAttribute('data-theme', t);
    }
  }

  // Runs before the body is parsed, so a chosen theme does not flash.
  applyTheme(storedTheme());

  function each(list, fn) {
    Array.prototype.forEach.call(list, fn);
  }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) {
      node.className = cls;
    }
    if (text !== undefined) {
      node.textContent = text;
    }
    return node;
  }

  function initTheme() {
    var buttons = document.querySelectorAll('[data-theme-toggle]');
    function label() {
      var t = storedTheme();
      each(buttons, function (b) {
        b.textContent = 'Theme: ' + t;
      });
    }
    each(buttons, function (b) {
      b.addEventListener('click', function () {
        var next = THEMES[(THEMES.indexOf(storedTheme()) + 1) % THEMES.length];
        try {
          window.localStorage.setItem(THEME_KEY, next);
        } catch (e) {
          /* storage blocked: the theme still changes for this page */
        }
        applyTheme(next);
        label();
      });
    });
    label();
  }

  function formatTime(iso) {
    if (!iso) {
      return '';
    }
    var d = new Date(iso);
    if (isNaN(d.getTime())) {
      return iso;
    }
    return d.toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
  }

  function getJSON(url) {
    return fetch(url, { cache: 'no-store' }).then(function (r) {
      if (!r.ok) {
        throw new Error(url + ' returned ' + r.status);
      }
      return r.json();
    });
  }

  // Shows the banner when this environment's latest build attempt failed
  // after the build being viewed was made.
  function initBanner() {
    var banners = document.querySelectorAll('[data-stale-banner]');
    var body = document.body;
    var env = body.getAttribute('data-env');
    if (!banners.length || !env) {
      return;
    }
    var root = body.getAttribute('data-root') || '';
    var built = body.getAttribute('data-built') || '';
    getJSON(root + 'status.json').then(function (status) {
      var e = status.environments && status.environments[env];
      var attempt = e && e.last_attempt;
      if (!attempt || attempt.status !== 'failed' || attempt.at <= built) {
        return;
      }
      var text = 'The build at ' + formatTime(attempt.at) +
        (attempt.commit ? ' for commit ' + attempt.commit.slice(0, 12) : '') +
        ' failed: ' + (attempt.error || 'no detail recorded') +
        '. You are reading the previous good build, from ' + formatTime(built) + '.';
      each(banners, function (b) {
        b.textContent = text;
        b.hidden = false;
      });
    }).catch(function () {
      /* status.json unavailable (file:// or a partial copy): no banner */
    });
  }

  // The search index of the page's environment, loaded once.
  var indexPromise = null;
  function searchBase() {
    return document.body.getAttribute('data-search-base') || '';
  }
  function loadIndex() {
    if (!indexPromise) {
      indexPromise = fetch(searchBase() + 'search.json').then(function (r) {
        if (!r.ok) {
          throw new Error('search.json returned ' + r.status);
        }
        return r.json();
      });
    }
    return indexPromise;
  }

  // Fuzzy match of a lower-cased term against text. Higher is better, -1
  // is no match. A substring scores far above a scattered subsequence,
  // and matches at the start of a name or a :: segment score highest.
  var SEP = /[:_\/\s.\-$]/;
  function fuzzy(term, text) {
    var t = text.toLowerCase();
    var at = t.indexOf(term);
    if (at >= 0) {
      var s = 1000 - at - (t.length - term.length);
      if (t === term) {
        s += 2000;
      } else if (at === 0) {
        s += 600;
      } else if (SEP.test(t.charAt(at - 1))) {
        s += 400;
      }
      return s;
    }
    var from = 0;
    var last = -2;
    var run = 0;
    var score = 0;
    for (var i = 0; i < term.length; i++) {
      var found = t.indexOf(term.charAt(i), from);
      if (found < 0) {
        return -1;
      }
      if (found === last + 1) {
        run += 1;
        score += 6 * run;
      } else {
        run = 0;
        score -= Math.min(found - from, 10);
      }
      if (found === 0 || SEP.test(t.charAt(found - 1))) {
        score += 12;
      }
      last = found;
      from = found + 1;
    }
    return score;
  }

  // Every term has to match the name, the object a parameter belongs to,
  // the module, or the summary.
  var KIND_WEIGHT = { parameter: -60, provider: -20, module: 30, environment: 40 };
  function scoreEntry(e, terms) {
    var total = 0;
    for (var i = 0; i < terms.length; i++) {
      var term = terms[i];
      var best = Math.max(
        fuzzy(term, e.n),
        e.p ? fuzzy(term, e.p) - 300 : -1,
        e.m ? fuzzy(term, e.m) - 500 : -1
      );
      if (best < 0 && e.s && term.length > 2 && e.s.toLowerCase().indexOf(term) >= 0) {
        best = 1;
      }
      if (best < 0) {
        return -1;
      }
      total += best;
    }
    return total + (KIND_WEIGHT[e.k] || 0);
  }

  var GROUP_ORDER = ['environment', 'module', 'class', 'defined type', 'resource type', 'function', 'task', 'plan',
    'type alias', 'data type', 'provider', 'parameter'];
  var GROUP_NAMES = {
    environment: 'Environments', module: 'Modules', 'class': 'Classes', 'defined type': 'Defined types',
    'resource type': 'Resource types', 'function': 'Functions', task: 'Tasks', plan: 'Plans',
    'type alias': 'Type aliases', 'data type': 'Data types', provider: 'Providers', parameter: 'Parameters'
  };
  var PER_GROUP = 7;

  function initPalette() {
    var box = document.querySelector('[data-palette]');
    if (!box || !document.body.getAttribute('data-search-env')) {
      return;
    }
    var input = box.querySelector('[data-palette-input]');
    var results = box.querySelector('[data-palette-results]');
    var status = box.querySelector('[data-palette-status]');
    var env = document.body.getAttribute('data-search-env');
    var extra = [];
    var options = [];
    var active = -1;
    var opener = null;

    // On the site index the environments are searchable too.
    each(document.querySelectorAll('a.env-name'), function (a) {
      extra.push({ n: a.textContent, k: 'environment', s: '', abs: a.getAttribute('href') });
    });

    function open() {
      opener = document.activeElement;
      box.hidden = false;
      document.documentElement.classList.add('palette-open');
      input.focus();
      input.select();
      render();
    }

    function close() {
      box.hidden = true;
      document.documentElement.classList.remove('palette-open');
      if (opener && opener.focus) {
        opener.focus();
      }
    }

    function setActive(i) {
      if (!options.length) {
        active = -1;
        input.removeAttribute('aria-activedescendant');
        return;
      }
      active = (i + options.length) % options.length;
      each(options, function (o, n) {
        o.setAttribute('aria-selected', n === active ? 'true' : 'false');
      });
      input.setAttribute('aria-activedescendant', options[active].id);
      options[active].scrollIntoView({ block: 'nearest' });
    }

    function href(e) {
      return e.abs || searchBase() + e.u;
    }

    function render() {
      var q = input.value.trim().toLowerCase();
      loadIndex().then(function (entries) {
        if (input.value.trim().toLowerCase() !== q) {
          return;
        }
        draw(q, extra.concat(entries));
      }).catch(function (err) {
        status.textContent = 'The search index for ' + env + ' could not be loaded (' + err.message + ').';
      });
    }

    function draw(q, entries) {
      results.textContent = '';
      options = [];
      var groups = {};
      var count = 0;
      if (!q) {
        status.textContent = 'Type to search ' + env + '. Arrow keys move, Enter opens, Esc closes.';
        entries.forEach(function (e) {
          if (e.k === 'module' || e.k === 'environment') {
            (groups[e.k] = groups[e.k] || []).push([0, e]);
          }
        });
      } else {
        var terms = q.split(/\s+/);
        entries.forEach(function (e) {
          var s = scoreEntry(e, terms);
          if (s >= 0) {
            (groups[e.k] = groups[e.k] || []).push([s, e]);
            count += 1;
          }
        });
        status.textContent = count === 0
          ? 'Nothing in ' + env + ' matches "' + input.value.trim() + '".'
          : count + (count === 1 ? ' match' : ' matches') + ' in ' + env + '.';
      }
      var order = GROUP_ORDER.filter(function (k) {
        return groups[k];
      });
      order.forEach(function (k) {
        groups[k].sort(function (a, b) {
          return b[0] - a[0] || a[1].n.localeCompare(b[1].n);
        });
      });
      if (q) {
        // The group holding the best match goes first.
        order.sort(function (a, b) {
          return groups[b][0][0] - groups[a][0][0];
        });
      }
      order.forEach(function (k) {
        var list = groups[k];
        var section = el('div', 'palette-group');
        section.setAttribute('role', 'group');
        var headId = 'pg-' + k.replace(/\s/g, '-');
        var head = el('p', 'palette-group-head', GROUP_NAMES[k] || k);
        head.id = headId;
        section.setAttribute('aria-labelledby', headId);
        section.appendChild(head);
        list.slice(0, q ? PER_GROUP : 40).forEach(function (pair) {
          var e = pair[1];
          var a = el('a', 'palette-option');
          a.href = href(e);
          a.id = 'po-' + options.length;
          a.setAttribute('role', 'option');
          a.setAttribute('tabindex', '-1');
          a.appendChild(el('span', 'po-name', e.n));
          var where = e.k === 'parameter' ? e.p : (e.k === 'module' || e.k === 'environment' ? '' : e.m);
          if (where) {
            a.appendChild(el('span', 'po-where', where));
          }
          if (e.s) {
            a.appendChild(el('span', 'po-summary', e.s));
          }
          a.addEventListener('mousemove', function () {
            if (options[active] !== a) {
              setActive(options.indexOf(a));
            }
          });
          options.push(a);
          section.appendChild(a);
        });
        if (q && list.length > PER_GROUP) {
          section.appendChild(el('p', 'palette-more', (list.length - PER_GROUP) + ' more. Add to the search to narrow it.'));
        }
        results.appendChild(section);
      });
      setActive(0);
    }

    input.addEventListener('input', render);
    input.addEventListener('keydown', function (ev) {
      if (ev.key === 'ArrowDown') {
        ev.preventDefault();
        setActive(active + 1);
      } else if (ev.key === 'ArrowUp') {
        ev.preventDefault();
        setActive(active - 1);
      } else if (ev.key === 'Enter' && options[active]) {
        ev.preventDefault();
        if (ev.metaKey || ev.ctrlKey) {
          window.open(options[active].href, '_blank', 'noopener');
        } else {
          window.location.href = options[active].href;
        }
      } else if (ev.key === 'Tab') {
        ev.preventDefault(); // focus stays in the dialog
      }
    });
    box.addEventListener('keydown', function (ev) {
      if (ev.key === 'Escape') {
        ev.preventDefault();
        close();
      }
    });
    each(box.querySelectorAll('[data-palette-close]'), function (n) {
      n.addEventListener('click', close);
    });
    each(document.querySelectorAll('[data-palette-open]'), function (b) {
      b.addEventListener('click', open);
    });
    document.addEventListener('keydown', function (ev) {
      var tag = (document.activeElement && document.activeElement.tagName) || '';
      var typing = tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA' || (document.activeElement && document.activeElement.isContentEditable);
      if ((ev.key === 'k' || ev.key === 'K') && (ev.metaKey || ev.ctrlKey) && !ev.altKey) {
        ev.preventDefault();
        if (box.hidden) {
          open();
        } else {
          close();
        }
      } else if (ev.key === '/' && !typing && box.hidden) {
        ev.preventDefault();
        open();
      }
    });
    // A bfcache restore after following a result shows the page as it was
    // left; the palette should not still be open over it.
    window.addEventListener('pageshow', function (ev) {
      if (ev.persisted && !box.hidden) {
        box.hidden = true;
        document.documentElement.classList.remove('palette-open');
      }
    });
    var params = new URLSearchParams(window.location.search);
    if (params.get('q')) {
      input.value = params.get('q');
      open();
    }
  }

  // Sidebar: the drawer on small screens, the current page kept in view,
  // and the rest of the tree filled in from the search index on demand.
  function initSidebar() {
    var nav = document.querySelector('[data-sidebar]');
    var toggle = document.querySelector('[data-menu-toggle]');
    if (!nav) {
      return;
    }
    if (toggle) {
      toggle.addEventListener('click', function () {
        var opened = document.documentElement.classList.toggle('nav-open');
        toggle.setAttribute('aria-expanded', opened ? 'true' : 'false');
        if (opened) {
          var first = nav.querySelector('a');
          if (first) {
            first.focus();
          }
        }
      });
      document.addEventListener('keydown', function (ev) {
        if (ev.key === 'Escape' && document.documentElement.classList.contains('nav-open')) {
          document.documentElement.classList.remove('nav-open');
          toggle.setAttribute('aria-expanded', 'false');
          toggle.focus();
        }
      });
    }

    var current = nav.querySelector('[aria-current="page"]');
    if (current && nav.scrollHeight > nav.clientHeight) {
      nav.scrollTop = Math.max(0, current.offsetTop - nav.clientHeight / 3);
    }

    function links(entries, mod, kind) {
      var ul = el('ul', 'tree-objs');
      entries.forEach(function (e) {
        if (e.m === mod && e.k === kind) {
          var li = el('li');
          var a = el('a', '', e.n);
          a.href = searchBase() + e.u;
          li.appendChild(a);
          ul.appendChild(li);
        }
      });
      return ul;
    }

    function fill(details) {
      var list = details.querySelector('ul[data-lazy]');
      if (!list) {
        return;
      }
      var mod = details.closest('[data-tree-mod]').getAttribute('data-tree-mod');
      var kind = details.getAttribute('data-tree-kind');
      loadIndex().then(function (entries) {
        list.replaceWith(links(entries, mod, kind));
      }).catch(function () {
        /* no index: the module page still lists everything */
      });
    }

    each(nav.querySelectorAll('details[data-tree-kind]'), function (d) {
      d.addEventListener('toggle', function () {
        if (d.open) {
          fill(d);
        }
      });
    });

    // Other modules get a button that opens their tree in place.
    each(nav.querySelectorAll('.tree-mod:not(.is-current)'), function (li) {
      var mod = li.getAttribute('data-tree-mod');
      var btn = el('button', 'tree-expand');
      btn.type = 'button';
      btn.setAttribute('aria-expanded', 'false');
      btn.setAttribute('aria-label', 'Show what ' + mod + ' contains');
      li.insertBefore(btn, li.firstChild);
      var built = null;
      btn.addEventListener('click', function () {
        var opened = btn.getAttribute('aria-expanded') !== 'true';
        btn.setAttribute('aria-expanded', opened ? 'true' : 'false');
        if (built) {
          built.hidden = !opened;
          return;
        }
        loadIndex().then(function (entries) {
          built = el('ul', 'tree-kinds');
          GROUP_ORDER.forEach(function (kind) {
            var ul = links(entries, mod, kind);
            if (!ul.children.length || kind === 'parameter' || kind === 'module') {
              return;
            }
            var item = el('li');
            var d = el('details');
            var s = el('summary', '', GROUP_NAMES[kind] + ' ');
            s.appendChild(el('span', 'count', String(ul.children.length)));
            d.appendChild(s);
            d.appendChild(ul);
            item.appendChild(d);
            built.appendChild(item);
          });
          li.appendChild(built);
        }).catch(function () {
          btn.hidden = true;
        });
      });
    });
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var area = el('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      var ok = false;
      try {
        ok = document.execCommand('copy');
      } catch (e) {
        ok = false;
      }
      document.body.removeChild(area);
      if (ok) {
        resolve();
      } else {
        reject(new Error('copy failed'));
      }
    });
  }

  function flash(node, text) {
    var old = node.getAttribute('data-label') || node.textContent;
    node.setAttribute('data-label', old);
    node.textContent = text;
    node.classList.add('is-done');
    window.setTimeout(function () {
      node.textContent = old;
      node.classList.remove('is-done');
    }, 1400);
  }

  // A copy button on every code block, and section anchors that copy
  // their link as well as following it.
  function initCopy() {
    each(document.querySelectorAll('pre.code'), function (pre) {
      var btn = el('button', 'copy', 'Copy');
      btn.type = 'button';
      btn.setAttribute('aria-label', 'Copy this code');
      btn.addEventListener('click', function () {
        copyText(pre.querySelector('code').textContent).then(function () {
          flash(btn, 'Copied');
        }, function () {
          flash(btn, 'Press Ctrl+C');
        });
      });
      var wrap = el('div', 'code-wrap');
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);
      wrap.appendChild(btn);
    });
    document.addEventListener('click', function (ev) {
      var a = ev.target.closest && ev.target.closest('a.anchor');
      if (!a) {
        return;
      }
      var url = window.location.href.split('#')[0] + a.getAttribute('href');
      copyText(url).then(function () {
        a.classList.add('is-copied');
        window.setTimeout(function () {
          a.classList.remove('is-copied');
        }, 1400);
      }, function () {
        /* the link still works as a link */
      });
    });
  }

  // The comparison page: any two environments, kept in the URL so the
  // back and forward buttons step through the comparisons made.
  function initCompare() {
    var page = document.querySelector('[data-compare]');
    if (!page) {
      return;
    }
    var selects = {
      left: page.querySelector('[data-compare-select="left"]'),
      right: page.querySelector('[data-compare-select="right"]')
    };
    var output = page.querySelector('[data-compare-output]');
    if (!selects.left || !output) {
      return;
    }
    var data = null;

    function cell(m) {
      var td = el('td');
      if (!m) {
        td.appendChild(el('span', 'none', 'not present'));
        return td;
      }
      if (m.version) {
        td.appendChild(document.createTextNode(m.version + ' '));
      }
      if (m.sha) {
        var span = el('span', 'sha');
        var sw = /^[0-9a-f]{6}/i.exec(m.sha);
        if (sw) {
          var dot = el('i', 'swatch');
          dot.style.setProperty('--swatch', '#' + sw[0]);
          dot.setAttribute('aria-hidden', 'true');
          span.appendChild(dot);
        }
        var code = el('code', '', m.sha.slice(0, 12));
        code.title = m.sha;
        span.appendChild(code);
        td.appendChild(span);
      } else if (m.ref) {
        td.appendChild(el('code', '', m.ref));
      }
      return td;
    }

    function draw(left, right) {
      var a = (data[left] || {}).modules || {};
      var b = (data[right] || {}).modules || {};
      var keys = ['version', 'sha', 'ref', 'kind', 'source'];
      var rows = [];
      var same = [];
      var counts = { changed: 0, added: 0, removed: 0 };
      Object.keys(a).concat(Object.keys(b)).filter(function (n, i, all) {
        return all.indexOf(n) === i;
      }).sort().forEach(function (n) {
        if (!a[n]) {
          counts.added += 1;
          rows.push([n, 'only in ' + right]);
        } else if (!b[n]) {
          counts.removed += 1;
          rows.push([n, 'only in ' + left]);
        } else {
          // A control-repo module's ref is the control repo's commit, so
          // only its tree SHA says whether the module itself moved.
          var control = a[n].kind === 'control' && b[n].kind === 'control';
          var diff = keys.filter(function (k) {
            return !(control && k === 'ref') && String(a[n][k] || '') !== String(b[n][k] || '');
          });
          if (diff.length) {
            counts.changed += 1;
            rows.push([n, diff.join(', ')]);
          } else {
            same.push(n);
          }
        }
      });
      output.textContent = '';
      output.appendChild(el('p', 'compare-summary', counts.changed + ' changed, ' + counts.added + ' only in ' + right +
        ', ' + counts.removed + ' only in ' + left + ', ' + same.length + ' the same.'));
      var wrap = el('div', 'table-wrap');
      var table = el('table', 'compare-table');
      var head = el('thead');
      var hr = el('tr');
      ['Module', 'Difference', left, right].forEach(function (t) {
        var th = el('th', '', t);
        th.scope = 'col';
        hr.appendChild(th);
      });
      head.appendChild(hr);
      table.appendChild(head);
      var body = el('tbody');
      if (!rows.length) {
        var tr0 = el('tr');
        var td0 = el('td', 'muted', 'The two environments have the same modules at the same commits.');
        td0.colSpan = 4;
        tr0.appendChild(td0);
        body.appendChild(tr0);
      }
      rows.forEach(function (r) {
        var tr = el('tr');
        var th = el('th');
        th.scope = 'row';
        th.setAttribute('data-label', 'Module');
        th.appendChild(el('code', '', r[0]));
        tr.appendChild(th);
        var what = el('td', '', r[1]);
        what.setAttribute('data-label', 'Difference');
        tr.appendChild(what);
        var l = cell(a[r[0]]);
        l.setAttribute('data-label', left);
        tr.appendChild(l);
        var rr = cell(b[r[0]]);
        rr.setAttribute('data-label', right);
        tr.appendChild(rr);
        body.appendChild(tr);
      });
      table.appendChild(body);
      wrap.appendChild(table);
      output.appendChild(wrap);
      if (same.length) {
        var det = el('details', 'same');
        det.appendChild(el('summary', '', same.length === 1 ? '1 module is the same in both' : same.length + ' modules are the same in both'));
        var p = el('p');
        same.forEach(function (n) {
          p.appendChild(el('code', '', n));
          p.appendChild(document.createTextNode(' '));
        });
        det.appendChild(p);
        output.appendChild(det);
      }
    }

    function fromURL() {
      var params = new URLSearchParams(window.location.search);
      return {
        left: params.get('from') || page.getAttribute('data-compare-left'),
        right: params.get('to') || page.getAttribute('data-compare-right')
      };
    }

    function show(pair) {
      if (!data[pair.left] || !data[pair.right]) {
        return;
      }
      selects.left.value = pair.left;
      selects.right.value = pair.right;
      draw(pair.left, pair.right);
    }

    getJSON('compare.json').then(function (d) {
      data = d;
      show(fromURL());
      ['left', 'right'].forEach(function (side) {
        selects[side].addEventListener('change', function () {
          var pair = { left: selects.left.value, right: selects.right.value };
          window.history.pushState(pair, '', '?from=' + encodeURIComponent(pair.left) + '&to=' + encodeURIComponent(pair.right));
          draw(pair.left, pair.right);
        });
      });
      window.addEventListener('popstate', function () {
        show(fromURL());
      });
    }).catch(function () {
      /* without compare.json the default comparison stays as written */
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    initTheme();
    initBanner();
    initPalette();
    initSidebar();
    initCopy();
    initCompare();
  });
})();

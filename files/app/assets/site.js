/* strings_site: theme switch, stale-build banner, and search.
 * No dependencies and no network calls beyond this site's own files. */
(function () {
  'use strict';

  var THEME_KEY = 'strings_site.theme';
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

  function initTheme() {
    var buttons = document.querySelectorAll('[data-theme-toggle]');
    function label() {
      var t = storedTheme();
      for (var i = 0; i < buttons.length; i++) {
        buttons[i].textContent = 'Theme: ' + t;
      }
    }
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].addEventListener('click', function () {
        var next = THEMES[(THEMES.indexOf(storedTheme()) + 1) % THEMES.length];
        try {
          window.localStorage.setItem(THEME_KEY, next);
        } catch (e) {
          /* storage blocked: the theme still changes for this page */
        }
        applyTheme(next);
        label();
      });
    }
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
    var ctx = document.querySelector('.ss-bar[data-env]') || document.body;
    var env = ctx.getAttribute('data-env');
    if (!banners.length || !env) {
      return;
    }
    var root = ctx.getAttribute('data-root') || '';
    var built = ctx.getAttribute('data-built') || '';
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
      for (var i = 0; i < banners.length; i++) {
        banners[i].textContent = text;
        banners[i].hidden = false;
      }
    }).catch(function () {
      /* status.json unavailable (file:// or a partial copy): no banner */
    });
  }

  // Ranks a hit: exact name, then name prefix, then last segment prefix,
  // then name substring, then summary substring.
  function score(entry, q) {
    var n = entry.n.toLowerCase();
    if (n === q) {
      return 0;
    }
    if (n.indexOf(q) === 0) {
      return 1;
    }
    var last = n.split('::').pop();
    if (last.indexOf(q) === 0) {
      return 2;
    }
    if (n.indexOf(q) >= 0) {
      return 3;
    }
    if (entry.m.toLowerCase().indexOf(q) >= 0) {
      return 4;
    }
    if (entry.s && entry.s.toLowerCase().indexOf(q) >= 0) {
      return 5;
    }
    return -1;
  }

  function initSearch() {
    var box = document.querySelector('[data-search]');
    if (!box) {
      return;
    }
    var input = box.querySelector('[data-search-input]');
    var select = box.querySelector('[data-search-env]');
    var status = box.querySelector('[data-search-status]');
    var list = box.querySelector('[data-search-results]');
    var kinds = box.querySelectorAll('[data-search-kinds] button');
    var base = box.getAttribute('data-search-root') || '';
    var fixed = input.getAttribute('data-search-fixed');
    var cache = {};
    var kind = '';
    var LIMIT = 60;

    function envName() {
      return select ? select.value : fixed;
    }

    // On the index, search.json lives under environments/<env>/; on an
    // environment page it sits beside the page.
    function envBase(env) {
      return base === '' ? '' : base + encodeURIComponent(env) + '/';
    }

    function load(env) {
      if (!cache[env]) {
        cache[env] = getJSON(envBase(env) + 'search.json');
      }
      return cache[env];
    }

    function render() {
      var q = input.value.trim().toLowerCase();
      var env = envName();
      list.textContent = '';
      if (!q) {
        status.textContent = '';
        return;
      }
      load(env).then(function (entries) {
        if (input.value.trim().toLowerCase() !== q || envName() !== env) {
          return;
        }
        var hits = [];
        for (var i = 0; i < entries.length; i++) {
          if (kind && entries[i].k !== kind) {
            continue;
          }
          var s = score(entries[i], q);
          if (s >= 0) {
            hits.push([s, entries[i]]);
          }
        }
        hits.sort(function (a, b) {
          return a[0] - b[0] || a[1].n.localeCompare(b[1].n);
        });
        status.textContent = hits.length === 0
          ? 'Nothing matches "' + input.value.trim() + '" in ' + env + '.'
          : hits.length + (hits.length === 1 ? ' match' : ' matches') + ' in ' + env +
            (hits.length > LIMIT ? ', showing the first ' + LIMIT : '') + '.';
        var frag = document.createDocumentFragment();
        hits.slice(0, LIMIT).forEach(function (h) {
          var e = h[1];
          var li = document.createElement('li');
          var a = document.createElement('a');
          a.href = envBase(env) + (e.u || 'modules/' + encodeURIComponent(e.m) + '/index.html');
          var name = document.createElement('span');
          name.className = 'hit-name';
          name.textContent = e.n;
          var where = document.createElement('span');
          where.className = 'hit-where';
          where.textContent = e.k + ' in ' + e.m;
          a.appendChild(name);
          a.appendChild(where);
          if (e.s) {
            var sum = document.createElement('span');
            sum.className = 'hit-summary';
            sum.textContent = e.s;
            a.appendChild(sum);
          }
          li.appendChild(a);
          frag.appendChild(li);
        });
        list.appendChild(frag);
      }).catch(function (err) {
        status.textContent = 'The search index for ' + env + ' could not be loaded (' + err.message + ').';
      });
    }

    input.addEventListener('input', render);
    if (select) {
      select.addEventListener('change', render);
    }
    for (var i = 0; i < kinds.length; i++) {
      kinds[i].addEventListener('click', function (ev) {
        kind = ev.currentTarget.getAttribute('data-kind');
        for (var j = 0; j < kinds.length; j++) {
          kinds[j].setAttribute('aria-pressed', kinds[j] === ev.currentTarget ? 'true' : 'false');
        }
        render();
      });
    }

    // Keyboard: / focuses the box, arrows move through results, Escape clears.
    document.addEventListener('keydown', function (ev) {
      var tag = (document.activeElement && document.activeElement.tagName) || '';
      if (ev.key === '/' && tag !== 'INPUT' && tag !== 'SELECT' && tag !== 'TEXTAREA') {
        ev.preventDefault();
        input.focus();
        return;
      }
      if (!box.contains(document.activeElement)) {
        return;
      }
      var links = list.querySelectorAll('a');
      var idx = Array.prototype.indexOf.call(links, document.activeElement);
      if (ev.key === 'ArrowDown' && links.length) {
        ev.preventDefault();
        links[Math.min(idx + 1, links.length - 1)].focus();
      } else if (ev.key === 'ArrowUp' && links.length) {
        ev.preventDefault();
        if (idx <= 0) {
          input.focus();
        } else {
          links[idx - 1].focus();
        }
      } else if (ev.key === 'Escape') {
        input.value = '';
        input.focus();
        render();
      }
    });

    var params = new URLSearchParams(window.location.search);
    if (params.get('q')) {
      input.value = params.get('q');
      render();
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    initTheme();
    initBanner();
    initSearch();
  });
})();

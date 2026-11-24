(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('content').textContent);
  const page = document.getElementById('page');
  const scroller = document.getElementById('scroller');
  const crumbs = document.getElementById('crumbs');
  const tools = document.getElementById('tools');
  const panel = document.getElementById('panel');
  const body = document.getElementById('panel-body');
  const audio = document.getElementById('narration');
  const sample = audio.getAttribute('src');
  const narrow = matchMedia('(max-width:680px)');
  const sizes = [15, 17, 20];
  const pref = {
    get(key) { try { return localStorage.getItem('jarvis-reader-' + key); } catch { return null; } },
    set(key, value) { try { localStorage.setItem('jarvis-reader-' + key, String(value)); } catch {} },
  };
  let font = Number(pref.get('font')) || 17;
  if (!sizes.includes(font)) font = 17;
  document.documentElement.style.setProperty('--reading-size', font + 'px');
  document.body.classList.toggle('rail-collapsed', pref.get('rail') === 'hidden');
  const jarvisNav = document.getElementById('jarvis-nav');
  jarvisNav.open = pref.get('jarvis-nav') !== 'closed';
  const saveNavState = () => pref.set('jarvis-nav', jarvisNav.open ? 'open' : 'closed');
  jarvisNav.addEventListener('toggle', saveNavState);
  window.addEventListener('pagehide', saveNavState);
  const iconPaths = {
    sound: '<path d="M3 10v4m4-8v12m5-16v20m5-16v12m4-8v4"/>',
    volume: '<path d="M4 9h4l5-4v14l-5-4H4zM17 8a6 6 0 0 1 0 8m3-11a10 10 0 0 1 0 14"/>',
    left: '<path d="M19 12H5m6-6-6 6 6 6"/>',
    right: '<path d="M5 12h14m-6-6 6 6-6 6"/>',
    play: '<path d="M6 3.6c0-.7.8-1.2 1.4-.8l13 8.4a1 1 0 0 1 0 1.6l-13 8.4c-.6.4-1.4 0-1.4-.8z"/>',
    pause: '<rect x="5" y="4" width="5" height="16" rx="1"/><rect x="14" y="4" width="5" height="16" rx="1"/>',
    code: '<path d="m8 7-5 5 5 5m8-10 5 5-5 5m-3-13-2 16"/>',
  };
  const icon = name => '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">' + iconPaths[name] + '</svg>';
  const escape = value => String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  const href = id => '#' + id;
  const known = id => id === 'brief' || id === 'tasks' || Object.hasOwn(data.docs, id);
  const routeAtLocation = () => {
    const id = location.hash.substring(1);
    return known(id) ? id : 'brief';
  };
  const routeTitle = id => id === 'brief' ? 'Daily Brief' : id === 'tasks' ? 'Overnight tasks' : data.docs[id].short;
  const back = (id, label) => '<a class="back" data-return href="' + href(id) + '">' + icon('left') + label + '</a>';
  const tool = (action, label, content) => '<button type="button" class="icon-btn" data-action="' + action + '" title="' + label + '" aria-label="' + label + '">' + content + '</button>';
  let route = '';
  let customURL = '';
  let recordingName = '';
  let audioError = '';
  let audioRequest = 0;
  let panelMode = '';
  let focusAfterPanel;
  const scrollByEntry = new Map();
  let entry = '';
  let restoring = false;
  const newKey = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  if ('scrollRestoration' in history) history.scrollRestoration = 'manual';

  function renderBrief() {
    page.innerHTML = '<section class="home" aria-label="Daily Brief"><div class="morning"><header>' +
      '<time class="date" datetime="2026-11-24">Tuesday, November 24, 2026</time>' +
      '<h1 class="morning-intro">I found two summer internships in Chicago.</h1></header>' +
      '<img class="orb" alt="Jarvis’s gold dithered orb" width="372" height="372">' +
      '<button type="button" class="listen" data-action="listen" id="listen"></button>' +
      '<div class="play-meta"><span id="clock" class="clock"></span><span class="mark" aria-hidden="true">·</span><button type="button" data-action="transcript">Transcript</button></div>' +
      '<p id="audio-error" class="play-error" role="status"></p></div></section>';
    page.querySelector('.orb').src = data.orb;
    updateAudio();
  }

  function renderTasks() {
    const report = (id, description, meta, cover) => '<a href="#report/' + id + '" class="task-link">' +
      (cover ? '<img class="cover" data-illustration width="1440" height="576" alt="">' : '') +
      '<div class="task-detail"><div><h3>' + data.docs['report/' + id].title + '</h3><p>' + description + '</p><small>' + meta + '</small></div><span class="arrow">' + icon('right') + '</span></div></a>';
    page.innerHTML = '<section class="index column">' + back('brief', 'Daily Brief') + '<h1>Overnight tasks</h1>' +
      '<section aria-label="Tuesday, November 24"><h2 class="date-rule">Tuesday, November 24</h2>' +
      report('chicago', 'Two openings added to your list. Maple Studio closes Friday.', 'Career · 2 sources · Résumés waiting for your master file', true) + '</section>' +
      '<section class="older" aria-label="Monday, November 23"><h2 class="date-rule">Monday, November 23</h2>' +
      report('microphone', 'Typing interrupted fewer clips with the microphone on its stand.', 'Voice · 2 trial notes', false) +
      '</section><p class="footnote">Sample reports for this design preview.</p></section>';
    loadIllustrations();
  }

  function loadIllustrations() {
    for (const image of page.querySelectorAll('[data-illustration]')) image.src = data.cover;
  }

  function renderDocument(id) {
    const doc = data.docs[id];
    const report = id.startsWith('report/');
    const source = history.state?.from;
    const origin = !report && source && known(source) && source !== id ? source : doc.back;
    const originLabel = routeTitle(origin);
    const meta = '<div class="meta"><span>' + doc.date + '</span><span class="slash" aria-hidden="true">/</span><span>' + doc.minutes + ' min read</span>' +
      (doc.stamp ? '<span class="stamp">' + doc.stamp + '</span>' : '') + '</div>';
    page.innerHTML = '<article class="column reader">' + back(origin, originLabel) + '<h1>' + escape(doc.title) + '</h1>' + meta +
      '<div class="prose">' + doc.html + '</div><footer class="report-footer"><span>' + (report ? 'Fictional overnight report' : 'Example project note') +
      '</span><button type="button" data-action="markdown" class="text-button">' + icon('code') + 'View Markdown</button></footer></article>';
    loadIllustrations();
  }

  function render(state, moveFocus) {
    const id = routeAtLocation();
    if (id === route && state?.key === entry) return;
    const previousRoute = route;
    if (entry && !restoring) scrollByEntry.set(entry, scroller.scrollTop);
    if (panel.open) panel.close();
    if (previousRoute === 'brief' && previousRoute !== id) { audioRequest++; audio.pause(); }
    document.body.classList.remove('rail-mobile-open');
    route = id;
    const navHash = id === 'brief' ? '#brief' : '#tasks';
    for (const link of jarvisNav.querySelectorAll('a')) {
      if (link.hash === navHash) link.setAttribute('aria-current', id === navHash.slice(1) ? 'page' : 'location');
      else link.removeAttribute('aria-current');
    }
    entry = state?.key || newKey();
    if (!state?.key || state.id !== id) history.replaceState({id, key: entry, y: 0}, '', href(id));
    const before = '<a href="#brief" class="crumb-brand">' + icon('sound') + 'Jarvis</a><span class="sep" aria-hidden="true">/</span>';
    const isDoc = Object.hasOwn(data.docs, id);
    const section = !isDoc ? routeTitle(id) : id.startsWith('report/') ? 'Task report' : 'Project note';
    crumbs.innerHTML = before + (isDoc ? '<a href="#tasks">Overnight tasks</a><span class="sep" aria-hidden="true">/</span>' : '') +
      '<span aria-current="page">' + section + '</span>';
    tools.innerHTML = id === 'brief' ? tool('audio', 'Audio options', icon('volume')) :
      isDoc ? tool('type', 'Reading size', '<span class="aa" aria-hidden="true">Aa</span>') : '';
    if (id === 'brief') renderBrief();
    else if (id === 'tasks') renderTasks();
    else renderDocument(id);
    document.title = (isDoc ? data.docs[id].title : section) + ' · Jarvis';
    if (moveFocus) scroller.focus({preventScroll: true});
    restoring = true;
    scroller.scrollTop = scrollByEntry.get(entry) ?? history.state?.y ?? 0;
    const currentEntry = entry;
    requestAnimationFrame(() => { if (entry === currentEntry) restoring = false; });
  }

  function navigate(id, returning) {
    if (!known(id)) return;
    if (id === route) {
      document.body.classList.remove('rail-mobile-open');
      scroller.scrollTop = 0;
      return;
    }
    scrollByEntry.set(entry, scroller.scrollTop);
    history.replaceState({...history.state, y:scroller.scrollTop}, '');
    if (returning && history.state?.from === id) { history.back(); return; }
    history.pushState({id, key:newKey(), from:route, y:0}, '', href(id));
    render(history.state, true);
  }

  function toggleRail() {
    if (narrow.matches) {
      const open = document.body.classList.toggle('rail-mobile-open');
      document.querySelector(open ? '.rail-toggle' : '.rail-open').focus();
    } else {
      const hidden = document.body.classList.toggle('rail-collapsed');
      pref.set('rail', hidden ? 'hidden' : 'visible');
      document.querySelector(hidden ? '.rail-open' : '.rail-toggle').focus();
    }
  }

  function formatTime(value) {
    const n = Number.isFinite(value) ? Math.floor(value) : 0;
    return Math.floor(n / 60) + ':' + String(n % 60).padStart(2, '0');
  }

  function updateAudio() {
    const listen = document.getElementById('listen');
    if (!listen) return;
    const playing = !audio.paused && !audio.ended;
    const action = playing ? 'Pause brief' : audio.ended ? 'Replay brief' : audio.currentTime > 0 ? 'Resume brief' : 'Play brief';
    if (listen.getAttribute('aria-label') !== action) {
      listen.setAttribute('aria-label', action);
      listen.innerHTML = icon(playing ? 'pause' : 'play') + '<span>' + action + '</span>';
    }
    document.getElementById('clock').textContent = formatTime(audio.currentTime) + ' / ' +
      (Number.isFinite(audio.duration) ? formatTime(audio.duration) : '…');
    document.getElementById('audio-error').textContent = audioError;
  }

  async function toggleAudio() {
    const request = ++audioRequest;
    audioError = '';
    if (!audio.paused && !audio.ended) { audio.pause(); updateAudio(); return; }
    if (audio.ended) audio.currentTime = 0;
    try { await audio.play(); }
    catch (error) {
      if (request !== audioRequest || error.name === 'AbortError') return;
      audioError = 'This recording couldn’t play. Open Audio options to choose another file or use the preview voice.';
    }
    updateAudio();
  }

  function changeRecording(file) {
    const previousURL = customURL;
    audioRequest++;
    audio.pause();
    customURL = file ? URL.createObjectURL(file) : '';
    recordingName = file?.name || '';
    audioError = '';
    audio.src = customURL || sample;
    audio.load();
    if (previousURL) URL.revokeObjectURL(previousURL);
    updateAudio();
    if (panel.open && panelMode === 'audio') audioOptions();
  }

  function openPanel(title, mode) {
    if (!panel.open) focusAfterPanel = document.activeElement;
    document.getElementById('panel-title').textContent = title;
    panelMode = mode;
    if (!panel.open) panel.showModal();
  }

  function jumpTo() {
    openPanel('Jump to', 'jump');
    body.innerHTML = '<form role="search"><input class="jump-query" type="search" aria-label="Find a destination" ' +
      'placeholder="Find a destination" autocomplete="off"><div class="jump-results"></div></form>';
    const form = body.querySelector('form');
    const input = form.querySelector('input');
    const results = form.querySelector('.jump-results');
    const destinations = [...jarvisNav.querySelectorAll('a')];
    function updateResults() {
      const query = input.value.trim().toLowerCase();
      results.innerHTML = destinations.filter(link => link.textContent.toLowerCase().includes(query))
        .map(link => '<a href="' + link.hash + '">' + escape(link.textContent) + '</a>').join('') ||
        '<p>No matching destinations</p>';
    }
    input.addEventListener('input', updateResults);
    form.addEventListener('submit', event => {
      event.preventDefault();
      results.querySelector('a')?.click();
    });
    updateResults();
    input.focus();
  }

  function audioOptions() {
    openPanel('Audio options', 'audio');
    body.innerHTML = '<p>Play the included preview voice or choose a saved ElevenLabs recording for this brief.</p>' +
      '<p class="recording" id="current-recording"></p><label for="recording-file"><small>Choose an audio file</small></label>' +
      '<input class="field" id="recording-file" type="file" accept="audio/*,.mp3,.m4a,.wav,.aac,.ogg,.flac">' +
      (customURL ? '<div class="choices"><button class="panel-btn" type="button" data-action="reset-audio">Use preview voice</button></div>' : '') +
      '<small id="file-status" role="status"></small>';
    document.getElementById('current-recording').textContent = recordingName || 'Current recording · Local preview voice';
    document.getElementById('file-status').textContent = audioError;
  }

  function readSettings() {
    openPanel('Reading size', 'type');
    body.innerHTML = '<p>Choose a text size for reports and linked notes.</p><div class="choices">' +
      sizes.map((size, i) => '<button type="button" class="panel-btn" data-size="' + size + '" aria-pressed="' + (font === size) + '">' + ['Compact', 'Standard', 'Large'][i] + '</button>').join('') + '</div>';
  }

  const actions = {
    listen: toggleAudio, rail: toggleRail, jump: jumpTo, audio: audioOptions, type: readSettings,
    close() { panel.close(); },
    'reset-audio'() { changeRecording(null); },
    transcript() {
      openPanel('Brief transcript', 'transcript');
      body.innerHTML = '<p>' + escape(data.script) + '</p><div class="choices"><a href="#report/chicago" class="panel-btn">Read the internship report</a></div>';
    },
    markdown() {
      openPanel('Markdown source', 'markdown');
      body.innerHTML = '<pre class="source-raw" tabindex="0"></pre>';
      body.querySelector('pre').textContent = data.docs[route].raw;
    },
  };

  document.addEventListener('click', event => {
    if (event.defaultPrevented) return;
    const size = event.target.closest('[data-size]');
    if (size) {
      font = Number(size.dataset.size);
      pref.set('font', font);
      document.documentElement.style.setProperty('--reading-size', font + 'px');
      for (const button of body.querySelectorAll('[data-size]')) button.setAttribute('aria-pressed', String(Number(button.dataset.size) === font));
      return;
    }
    const button = event.target.closest('[data-action]');
    if (button) { actions[button.dataset.action]?.(); return; }
    const link = event.target.closest('a[href^="#"]');
    if (link && event.button === 0 && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey) {
      event.preventDefault();
      if (panelMode === 'jump') {
        focusAfterPanel = null;
        panel.close();
        navigate(link.hash.slice(1), false);
        scroller.focus({preventScroll:true});
        return;
      }
      navigate(link.hash.slice(1), link.hasAttribute('data-return'));
    }
    if (event.target === panel && !event.target.closest('.panel-inner')) panel.close();
  });
  document.addEventListener('change', event => {
    if (event.target.id === 'recording-file' && event.target.files.length) changeRecording(event.target.files[0]);
  });
  document.addEventListener('keydown', event => {
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.code === 'KeyK' && !panel.open) {
      event.preventDefault(); jumpTo();
    }
    if ((event.metaKey || event.ctrlKey) && event.altKey && event.code === 'KeyS' && !panel.open) {
      event.preventDefault(); toggleRail();
    }
    if (event.key === 'Escape' && !panel.open && document.body.classList.contains('rail-mobile-open')) toggleRail();
  });
  panel.addEventListener('close', () => {
    panelMode = '';
    if (focusAfterPanel?.isConnected) focusAfterPanel.focus({preventScroll:true});
  });
  narrow.addEventListener('change', () => document.body.classList.remove('rail-mobile-open'));
  audio.addEventListener('error', () => {
    audioError = 'This recording couldn’t play. Open Audio options to choose another file or use the preview voice.';
    const status = document.getElementById('file-status');
    if (panel.open && status) status.textContent = audioError;
    updateAudio();
  });
  for (const evt of ['loadedmetadata','timeupdate','play','pause','ended','durationchange','emptied']) audio.addEventListener(evt, updateAudio);
  window.addEventListener('popstate', () => render(history.state, true));
  window.addEventListener('hashchange', () => render(history.state, true));
  render(history.state, false);
})();

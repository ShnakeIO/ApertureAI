// Guides module - handles the guides tab

const Guides = (() => {
  let guidesView = null;
  let guidesSearch = null;
  let guidesList = null;
  let guidesDetailTitle = null;
  let guidesDetailBody = null;
  let guidesSteps = null;
  let catalog = [];
  let selectedGuideId = null;

  function init() {
    guidesView = document.getElementById('guides-view');
    guidesSearch = document.getElementById('guides-search');
    guidesList = document.getElementById('guides-list');
    guidesDetailTitle = document.getElementById('guides-detail-title');
    guidesDetailBody = document.getElementById('guides-detail-body');
    guidesSteps = document.getElementById('guides-steps');

    // Back to chat
    document.getElementById('guides-back-btn').addEventListener('click', backToChat);

    // Escape key to go back
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && isVisible()) {
        backToChat();
      }
    });

    // Search
    guidesSearch.addEventListener('input', () => {
      rebuildList();
    });
  }

  function isVisible() {
    return guidesView && !guidesView.classList.contains('hidden');
  }

  function backToChat() {
    if (!isVisible()) return;
    const guideId = selectedGuideId;
    hide();
    if (guideId) {
      window.api.applyGuideContext(guideId);
    }
  }

  async function show() {
    // Load catalog
    catalog = await window.api.getGuidesCatalog();
    selectedGuideId = null;

    guidesView.classList.remove('hidden');
    document.getElementById('transcript').classList.add('hidden');
    document.getElementById('composer').classList.add('hidden');
    App.setStatus('Guides');
    guidesSearch.value = '';
    guidesSearch.focus();
    rebuildList();
    updateDetail(null);
  }

  function hide() {
    guidesView.classList.add('hidden');
    document.getElementById('transcript').classList.remove('hidden');
    document.getElementById('composer').classList.remove('hidden');
    App.restoreStatus();
    document.getElementById('input-field').focus();
  }

  function rebuildList() {
    guidesList.innerHTML = '';
    const query = (guidesSearch.value || '').trim().toLowerCase();

    const filtered = catalog.filter(guide => {
      if (!query) return true;
      const title = (guide.title || '').toLowerCase();
      const keywords = (guide.keywords || '').toLowerCase();
      return title.includes(query) || keywords.includes(query);
    });

    if (filtered.length === 0) {
      guidesList.innerHTML = '<div class="guides-no-match">No matching guides.</div>';
      selectedGuideId = null;
      updateDetail(null);
      return;
    }

    // If selected guide isn't visible, deselect
    if (selectedGuideId && !filtered.some(g => g.id === selectedGuideId)) {
      selectedGuideId = filtered[0].id;
    }
    if (!selectedGuideId) {
      selectedGuideId = filtered[0].id;
    }

    for (const guide of filtered) {
      const item = document.createElement('div');
      item.className = `guide-item${guide.id === selectedGuideId ? ' selected' : ''}`;

      const titleSpan = document.createElement('span');
      titleSpan.textContent = guide.title;
      item.appendChild(titleSpan);

      const indicator = document.createElement('span');
      indicator.className = 'guide-item-indicator';
      indicator.textContent = guide.id === selectedGuideId ? '\u2022' : '\u203A';
      item.appendChild(indicator);

      item.addEventListener('click', () => {
        selectedGuideId = guide.id;
        rebuildList();
        updateDetail(guide);
      });

      guidesList.appendChild(item);
    }

    const selectedGuide = filtered.find(g => g.id === selectedGuideId);
    updateDetail(selectedGuide || null);
  }

  function updateDetail(guide) {
    if (!guide) {
      guidesDetailTitle.textContent = 'Select a guide to get started';
      guidesSteps.innerHTML = '';
      guidesDetailBody.textContent = 'Choose a guide from the left list, then click it to load details.';
      return;
    }

    guidesDetailTitle.textContent = guide.title || '';
    guidesDetailBody.textContent = guide.content || '';

    // Visual steps
    guidesSteps.innerHTML = '';
    const steps = guide.quick_steps || [];
    for (let i = 0; i < Math.min(steps.length, 6); i++) {
      const card = document.createElement('div');
      card.className = 'step-card';

      const num = document.createElement('span');
      num.className = 'step-number';
      num.textContent = `${i + 1}`;
      card.appendChild(num);

      const text = document.createElement('span');
      text.textContent = steps[i];
      card.appendChild(text);

      guidesSteps.appendChild(card);
    }
  }

  return { init, show, hide, isVisible, backToChat };
})();

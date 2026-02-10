// Sidebar module - handles side panel, chat history, settings

const Sidebar = (() => {
  let overlay = null;
  let historyList = null;
  let settingsApi = null;
  let settingsModel = null;
  let settingsDrive = null;
  let visible = false;

  function init() {
    overlay = document.getElementById('side-panel-overlay');
    historyList = document.getElementById('history-list');
    settingsApi = document.getElementById('settings-api');
    settingsModel = document.getElementById('settings-model');
    settingsDrive = document.getElementById('settings-drive');

    // Close button
    document.getElementById('panel-close-btn').addEventListener('click', hide);

    // Dim overlay click to dismiss
    overlay.querySelector('.side-panel-dim').addEventListener('click', hide);

    // New chat
    document.getElementById('new-chat-btn').addEventListener('click', async () => {
      hide();
      const result = await window.api.newChat();
      if (result.welcomeMessage) {
        Chat.clearTranscript();
        Chat.addMessage(result.welcomeMessage, false);
        App.setStatus('Ready');
      }
    });

    // Guides button
    document.getElementById('panel-guides-btn').addEventListener('click', () => {
      hide();
      Guides.show();
    });

    // Settings button
    document.getElementById('panel-settings-btn').addEventListener('click', async () => {
      const settings = await window.api.getSettings();
      alert(
        `API key: ${settings.hasApiKey ? 'Configured' : 'Missing'}\n` +
        `Model: ${settings.model}\n` +
        `Google Drive: ${settings.hasDrive ? 'Connected' : 'Not configured'}\n` +
        `OneDrive: ${settings.hasOneDrive ? 'Connected' : 'Not configured'}`
      );
    });
  }

  function toggle() {
    if (visible) {
      hide();
    } else {
      show();
    }
  }

  async function show() {
    if (visible) return;
    visible = true;
    overlay.classList.remove('hidden');
    // Force reflow then animate
    overlay.offsetHeight;
    overlay.classList.add('visible');
    await refreshHistory();
    await refreshSettings();
  }

  function hide() {
    if (!visible) return;
    visible = false;
    overlay.classList.remove('visible');
    setTimeout(() => {
      overlay.classList.add('hidden');
    }, 350);
  }

  function relativeTimeString(timestamp) {
    const now = Date.now() / 1000;
    const diff = now - timestamp;
    if (diff < 60) return 'Just now';
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  }

  async function refreshHistory() {
    const history = await window.api.getHistory();
    historyList.innerHTML = '';

    if (!history || history.length === 0) {
      historyList.innerHTML = '<div class="history-empty">No previous chats yet.</div>';
      return;
    }

    for (const chat of history) {
      const row = document.createElement('div');
      row.className = `history-row${chat.isCurrent ? ' current' : ''}`;

      const titleEl = document.createElement('div');
      titleEl.className = 'history-title';
      titleEl.textContent = chat.title;
      row.appendChild(titleEl);

      const timeEl = document.createElement('div');
      timeEl.className = 'history-time';
      timeEl.textContent = relativeTimeString(chat.timestamp);
      row.appendChild(timeEl);

      if (!chat.isCurrent) {
        row.addEventListener('click', async () => {
          const result = await window.api.loadChat(chat.id);
          if (result.displayMessages) {
            Chat.clearTranscript();
            for (const msg of result.displayMessages) {
              Chat.addMessage(msg.text, msg.isUser);
            }
            App.setStatus('Ready');
            hide();
          }
        });
      }

      historyList.appendChild(row);
    }
  }

  async function refreshSettings() {
    const settings = await window.api.getSettings();
    settingsApi.textContent = `API Key: ${settings.hasApiKey ? '\u2713 Configured' : '\u2717 Missing'}`;
    settingsApi.className = `settings-row ${settings.hasApiKey ? 'configured' : 'missing'}`;
    settingsModel.textContent = `Model: ${settings.model}`;
    settingsModel.className = 'settings-row muted';
    const driveParts = [];
    if (settings.hasDrive) driveParts.push('Google Drive \u2713');
    if (settings.hasOneDrive) driveParts.push('OneDrive \u2713');
    if (driveParts.length > 0) {
      settingsDrive.textContent = `Storage: ${driveParts.join(', ')}`;
      settingsDrive.className = 'settings-row configured';
    } else {
      settingsDrive.textContent = 'Storage: \u25CB Not configured';
      settingsDrive.className = 'settings-row muted';
    }
  }

  return { init, toggle, show, hide, refreshHistory };
})();

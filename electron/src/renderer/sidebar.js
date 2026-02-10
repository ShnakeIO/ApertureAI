// Sidebar module - handles side panel, chat history, settings

const Sidebar = (() => {
  let overlay = null;
  let historyList = null;
  let settingsApi = null;
  let settingsModel = null;
  let settingsDrive = null;
  let settingsUpdaterStatus = null;
  let settingsUpdaterCheck = null;
  let settingsUpdaterError = null;
  let visible = false;

  function init() {
    overlay = document.getElementById('side-panel-overlay');
    historyList = document.getElementById('history-list');
    settingsApi = document.getElementById('settings-api');
    settingsModel = document.getElementById('settings-model');
    settingsDrive = document.getElementById('settings-drive');
    settingsUpdaterStatus = document.getElementById('settings-updater-status');
    settingsUpdaterCheck = document.getElementById('settings-updater-check');
    settingsUpdaterError = document.getElementById('settings-updater-error');

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
      const [settings, updater] = await Promise.all([
        window.api.getSettings(),
        window.api.getUpdaterStatus()
      ]);
      const updaterState = updater?.state || 'unknown';
      const updaterMessage = updater?.message || 'No updater message.';
      const updaterError = updater?.lastError || 'None';
      alert(
        `API key: ${settings.hasApiKey ? 'Configured' : 'Missing'}\n` +
        `Model: ${settings.model}\n` +
        `Google Drive: ${settings.hasDrive ? 'Connected' : 'Not configured'}\n` +
        `OneDrive: ${settings.hasOneDrive ? 'Connected' : 'Not configured'}\n` +
        `GitHub token: ${settings.hasGitHubToken ? 'Configured' : 'Missing'}\n` +
        `User config file: ${settings.userConfigPath || 'Unknown'}\n` +
        `Auto-update state: ${updaterState}\n` +
        `Auto-update: ${updaterMessage}\n` +
        `Last auto-update error: ${updaterError}`
      );
    });

    window.api.onUpdateStatus(() => {
      if (visible) {
        refreshSettings();
      }
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
    const [settings, updater] = await Promise.all([
      window.api.getSettings(),
      window.api.getUpdaterStatus()
    ]);

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

    if (!updater) {
      settingsUpdaterStatus.textContent = 'Auto Update: Unknown';
      settingsUpdaterStatus.className = 'settings-row missing';
      settingsUpdaterCheck.textContent = 'Updater Checks: Unknown';
      settingsUpdaterCheck.className = 'settings-row muted';
      settingsUpdaterError.textContent = 'Last Error: Unknown';
      settingsUpdaterError.className = 'settings-row missing wrap';
      return;
    }

    const tokenLabel = updater.hasGitHubToken ? 'token OK' : 'token missing';
    settingsUpdaterStatus.textContent = `Auto Update: ${updater.message || updater.state || 'Unknown'} (${tokenLabel})`;
    if (!updater.enabled || updater.state === 'disabled') {
      settingsUpdaterStatus.className = 'settings-row muted';
    } else if (updater.state === 'error') {
      settingsUpdaterStatus.className = 'settings-row missing';
    } else {
      settingsUpdaterStatus.className = 'settings-row configured';
    }

    const started = formatTime(updater.lastCheckStartedAt);
    const finished = formatTime(updater.lastCheckCompletedAt);
    settingsUpdaterCheck.textContent = `Updater Checks: #${updater.checkCount || 0} | start ${started} | finish ${finished}`;
    settingsUpdaterCheck.className = 'settings-row muted';

    if (updater.lastError) {
      settingsUpdaterError.textContent = `Last Error: ${updater.lastError}`;
      settingsUpdaterError.className = 'settings-row missing wrap';
    } else {
      settingsUpdaterError.textContent = 'Last Error: None';
      settingsUpdaterError.className = 'settings-row configured';
    }
  }

  function formatTime(isoText) {
    if (!isoText) return 'never';
    try {
      return new Date(isoText).toLocaleTimeString();
    } catch (err) {
      return 'invalid';
    }
  }

  return { init, toggle, show, hide, refreshHistory };
})();

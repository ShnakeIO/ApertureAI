// Sidebar module - handles side panel, chat history, settings

const Sidebar = (() => {
  let overlay = null;
  let historyList = null;
  let settingsSection = null;
  let settingsBody = null;
  let settingsToggleBtn = null;
  let settingsToggleIndicator = null;
  let panelUploadBtn = null;
  let settingsApi = null;
  let settingsModel = null;
  let settingsDrive = null;
  let settingsUpdaterStatus = null;
  let settingsUpdaterCheck = null;
  let settingsUpdaterError = null;
  let settingsFeedbackBtn = null;
  let settingsFeedbackList = null;
  let feedbackModal = null;
  let feedbackBackdrop = null;
  let feedbackCloseBtn = null;
  let feedbackType = null;
  let feedbackTitle = null;
  let feedbackDetails = null;
  let feedbackSubmitBtn = null;
  let feedbackStatus = null;
  let visible = false;
  let settingsExpanded = false;

  function init() {
    overlay = document.getElementById('side-panel-overlay');
    historyList = document.getElementById('history-list');
    settingsSection = document.getElementById('settings-section');
    settingsBody = document.getElementById('settings-body');
    settingsToggleBtn = document.getElementById('settings-toggle-btn');
    settingsToggleIndicator = document.getElementById('settings-toggle-indicator');
    panelUploadBtn = document.getElementById('panel-upload-btn');
    settingsApi = document.getElementById('settings-api');
    settingsModel = document.getElementById('settings-model');
    settingsDrive = document.getElementById('settings-drive');
    settingsUpdaterStatus = document.getElementById('settings-updater-status');
    settingsUpdaterCheck = document.getElementById('settings-updater-check');
    settingsUpdaterError = document.getElementById('settings-updater-error');
    settingsFeedbackBtn = document.getElementById('settings-feedback-btn');
    settingsFeedbackList = document.getElementById('settings-feedback-list');
    feedbackModal = document.getElementById('feedback-modal');
    feedbackBackdrop = document.getElementById('feedback-backdrop');
    feedbackCloseBtn = document.getElementById('feedback-close-btn');
    feedbackType = document.getElementById('feedback-type');
    feedbackTitle = document.getElementById('feedback-title');
    feedbackDetails = document.getElementById('feedback-details');
    feedbackSubmitBtn = document.getElementById('feedback-submit-btn');
    feedbackStatus = document.getElementById('feedback-status');

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

    panelUploadBtn.addEventListener('click', uploadKnowledgeFiles);

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
        `App version: ${settings.appVersion || 'unknown'}\n` +
        `GitHub token: ${settings.hasGitHubToken ? 'Configured' : 'Missing'}\n` +
        `Feedback doc: ${settings.feedbackConfigured ? 'Configured' : 'Not configured'}\n` +
        `User config file: ${settings.userConfigPath || 'Unknown'}\n` +
        `Auto-update state: ${updaterState}\n` +
        `Auto-update: ${updaterMessage}\n` +
        `Last auto-update error: ${updaterError}`
      );
    });

    settingsFeedbackBtn.addEventListener('click', openFeedbackModal);
    settingsToggleBtn.addEventListener('click', () => {
      setSettingsExpanded(!settingsExpanded);
    });
    feedbackBackdrop.addEventListener('click', closeFeedbackModal);
    feedbackCloseBtn.addEventListener('click', closeFeedbackModal);
    feedbackSubmitBtn.addEventListener('click', submitFeedback);

    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && feedbackModal && !feedbackModal.classList.contains('hidden')) {
        closeFeedbackModal();
      }
    });

    window.api.onUpdateStatus(() => {
      if (visible) {
        refreshSettings();
      }
    });

    setSettingsExpanded(false);
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
    setSettingsExpanded(false);
    closeFeedbackModal();
    overlay.classList.remove('visible');
    setTimeout(() => {
      overlay.classList.add('hidden');
    }, 350);
  }

  function setSettingsExpanded(expanded) {
    settingsExpanded = !!expanded;
    if (settingsExpanded) {
      settingsSection.classList.add('expanded');
      settingsSection.classList.remove('collapsed');
      settingsBody.classList.remove('hidden');
      settingsToggleIndicator.textContent = '▾';
      settingsToggleBtn.title = 'Collapse settings';
      return;
    }
    settingsSection.classList.remove('expanded');
    settingsSection.classList.add('collapsed');
    settingsBody.classList.add('hidden');
    settingsToggleIndicator.textContent = '▸';
    settingsToggleBtn.title = 'Expand settings';
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
    const [settings, updater, reports] = await Promise.all([
      window.api.getSettings(),
      window.api.getUpdaterStatus(),
      window.api.getFeedbackReports(8)
    ]);

    settingsApi.textContent = `API Key: ${settings.hasApiKey ? '\u2713 Configured' : '\u2717 Missing'}`;
    settingsApi.className = `settings-row ${settings.hasApiKey ? 'configured' : 'missing'}`;
    settingsModel.textContent = `Model: ${settings.model} | App: v${settings.appVersion || 'unknown'}`;
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
      renderFeedbackReports(reports);
      return;
    }

    const tokenLabel = updater.hasGitHubToken ? 'token OK' : 'no token (public repo)';
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

    renderFeedbackReports(reports);
  }

  function renderFeedbackReports(reports) {
    settingsFeedbackList.innerHTML = '';
    if (!Array.isArray(reports) || reports.length === 0) {
      settingsFeedbackList.innerHTML = '<div class="feedback-empty">No reports yet.</div>';
      return;
    }

    for (const report of reports) {
      const item = document.createElement('div');
      item.className = 'feedback-item';

      const title = document.createElement('div');
      title.className = 'feedback-item-title';
      const prefix = report.type === 'feature' ? 'Feature' : 'Bug';
      title.textContent = `${prefix}: ${report.title || 'Untitled report'}`;
      item.appendChild(title);

      const meta = document.createElement('div');
      const statusText = report.syncStatus === 'synced' ? 'synced to Google Doc' : `failed: ${report.syncError || 'unknown error'}`;
      meta.className = `feedback-item-meta${report.syncStatus === 'failed' ? ' failed' : ''}`;
      meta.textContent = `${formatTime(report.createdAt)} • ${statusText}`;
      item.appendChild(meta);

      settingsFeedbackList.appendChild(item);
    }
  }

  function openFeedbackModal() {
    setSettingsExpanded(true);
    feedbackType.value = 'bug';
    feedbackTitle.value = '';
    feedbackDetails.value = '';
    feedbackStatus.textContent = 'Sends to your configured Google Doc.';
    feedbackStatus.className = 'feedback-status muted';
    feedbackSubmitBtn.disabled = false;
    feedbackSubmitBtn.textContent = 'Send Report';
    feedbackModal.classList.remove('hidden');
    feedbackTitle.focus();
  }

  function closeFeedbackModal() {
    if (!feedbackModal) return;
    feedbackModal.classList.add('hidden');
  }

  async function submitFeedback() {
    const type = feedbackType.value === 'feature' ? 'feature' : 'bug';
    const title = feedbackTitle.value.trim();
    const details = feedbackDetails.value.trim();
    if (!title || !details) {
      feedbackStatus.textContent = 'Please fill out title and details.';
      feedbackStatus.className = 'feedback-status error';
      return;
    }

    feedbackSubmitBtn.disabled = true;
    feedbackSubmitBtn.textContent = 'Sending...';
    feedbackStatus.textContent = 'Sending report to Google Doc...';
    feedbackStatus.className = 'feedback-status muted';

    try {
      const result = await window.api.submitFeedback({ type, title, details });
      if (!result || !result.report) {
        throw new Error('Unexpected feedback response.');
      }

      if (result.ok) {
        feedbackStatus.textContent = 'Report sent successfully.';
        feedbackStatus.className = 'feedback-status success';
      } else {
        feedbackStatus.textContent = `Saved locally, but Google Doc sync failed: ${result.report.syncError || 'Unknown error'}`;
        feedbackStatus.className = 'feedback-status error';
      }

      await refreshSettings();

      if (result.ok) {
        setTimeout(() => {
          closeFeedbackModal();
        }, 700);
      } else {
        feedbackSubmitBtn.disabled = false;
        feedbackSubmitBtn.textContent = 'Send Report';
      }
    } catch (err) {
      feedbackStatus.textContent = `Failed to send: ${err.message || 'Unknown error'}`;
      feedbackStatus.className = 'feedback-status error';
      feedbackSubmitBtn.disabled = false;
      feedbackSubmitBtn.textContent = 'Send Report';
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

  async function uploadKnowledgeFiles() {
    if (!panelUploadBtn) return;

    panelUploadBtn.disabled = true;
    const originalLabel = panelUploadBtn.textContent;
    panelUploadBtn.textContent = '…';

    try {
      const result = await window.api.uploadKnowledgeFiles();
      if (!result || result.canceled) return;

      if (result.error) {
        alert(`Upload failed: ${result.error}`);
        return;
      }

      const uploaded = Array.isArray(result.uploaded) ? result.uploaded : [];
      const failed = Array.isArray(result.failed) ? result.failed : [];

      if (uploaded.length === 0 && failed.length === 0) {
        alert('No files were uploaded.');
        return;
      }

      let message = `Uploaded ${uploaded.length} file${uploaded.length === 1 ? '' : 's'} to the knowledge base.`;
      if (failed.length > 0) {
        const failedNames = failed.map(item => item.name).slice(0, 4).join(', ');
        message += `\nFailed ${failed.length}: ${failedNames}${failed.length > 4 ? ', ...' : ''}`;
      }
      alert(message);
    } catch (err) {
      alert(`Upload failed: ${err.message || 'Unknown error'}`);
    } finally {
      panelUploadBtn.disabled = false;
      panelUploadBtn.textContent = originalLabel;
    }
  }

  return { init, toggle, show, hide, refreshHistory };
})();

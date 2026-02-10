// Main app controller

const App = (() => {
  let inputField = null;
  let sendBtn = null;
  let statusLabel = null;
  let updateBanner = null;
  let updateText = null;
  let updateBtn = null;
  let requesting = false;
  let currentStatus = 'Ready';

  function init() {
    inputField = document.getElementById('input-field');
    sendBtn = document.getElementById('send-btn');
    statusLabel = document.getElementById('status-label');
    updateBanner = document.getElementById('update-banner');
    updateText = document.getElementById('update-text');
    updateBtn = document.getElementById('update-restart-btn');

    Chat.init();
    Sidebar.init();
    Guides.init();

    updateBtn.addEventListener('click', async () => {
      updateBtn.disabled = true;
      updateBtn.textContent = 'Updating...';
      await window.api.installUpdate();
    });

    // Sidebar toggle - also exits guides view
    document.getElementById('sidebar-toggle').addEventListener('click', () => {
      if (Guides.isVisible()) {
        Guides.backToChat();
      } else {
        Sidebar.toggle();
      }
    });

    // Send button
    sendBtn.addEventListener('click', sendMessage);

    // Enter to send
    inputField.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
      }
    });

    // IPC event listeners
    window.api.onThinking((text) => {
      Chat.updateThinking(text);
      setStatus(text, true);
    });

    window.api.onStateRestored((data) => {
      handleStartup(data);
    });

    window.api.onUpdateAvailable((version) => {
      updateBanner.classList.remove('hidden');
      updateText.textContent = `Please update. Version v${version} is available and downloading now.`;
      updateBtn.classList.remove('hidden');
      updateBtn.disabled = true;
      updateBtn.textContent = 'Downloading...';
    });

    window.api.onUpdateDownloaded((version) => {
      updateBanner.classList.remove('hidden');
      updateText.textContent = `Please update. Version v${version} is ready to install.`;
      updateBtn.classList.remove('hidden');
      updateBtn.disabled = false;
      updateBtn.textContent = 'Update Now';
    });

    window.api.onUpdateNotAvailable(() => {
      if (updateBanner.classList.contains('hidden')) return;
      if (updateBtn && !updateBtn.disabled) return;
      updateBanner.classList.add('hidden');
    });

    inputField.focus();
  }

  function handleStartup(data) {
    if (!data) return;

    // Display messages
    if (data.displayMessages) {
      Chat.clearTranscript();
      for (const msg of data.displayMessages) {
        Chat.addMessage(msg.text, msg.isUser);
      }
    }

    // Status
    setStatus(data.status || 'Ready', data.status === 'No API key');
  }

  async function sendMessage() {
    if (requesting) return;

    const text = inputField.value.trim();
    if (!text) return;

    Chat.addMessage(text, true);
    inputField.value = '';
    setRequesting(true);
    Chat.showThinking();

    try {
      const result = await window.api.sendMessage(text);
      Chat.removeThinking();

      if (result.error) {
        Chat.addMessage(`Error: ${result.error}`, false);
        setRequesting(false);
        return;
      }

      Chat.streamResponse(result.response, () => {
        setRequesting(false);
      });
    } catch (err) {
      Chat.removeThinking();
      Chat.addMessage(`Error: ${err.message}`, false);
      setRequesting(false);
    }
  }

  function setRequesting(isRequesting) {
    requesting = isRequesting;
    sendBtn.disabled = isRequesting;
    if (isRequesting) {
      setStatus('Thinking...', true);
    } else {
      setStatus('Ready');
      inputField.focus();
    }
  }

  function setStatus(text, isThinking) {
    currentStatus = text;
    statusLabel.textContent = text;
    statusLabel.className = 'header-status';
    if (text === 'No API key') {
      statusLabel.classList.add('error');
    } else if (isThinking) {
      statusLabel.classList.add('thinking');
    }
  }

  function restoreStatus() {
    if (requesting) {
      setStatus('Thinking...', true);
    } else {
      setStatus(currentStatus === 'Guides' ? 'Ready' : currentStatus);
    }
  }

  return { init, setStatus, restoreStatus };
})();

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
  App.init();
});

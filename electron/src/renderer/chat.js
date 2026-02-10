// Chat module - handles message bubbles, streaming, thinking indicator

const Chat = (() => {
  const URL_REGEX = /https?:\/\/[^\s<>"]+/g;
  const TRAILING_PUNCT = /[.,;:)\]}\!?*_`'\\>|]+$/;

  let transcriptInner = null;
  let transcript = null;
  let streamTimer = null;
  let streamFullText = '';
  let streamCursor = 0;
  let streamLabel = null;
  let streamCopyBtn = null;
  let streamLinkContainer = null;
  let streamCompletion = null;
  let thinkingRow = null;
  let thinkingTimer = null;
  let thinkingDotCount = 1;

  function init() {
    transcriptInner = document.getElementById('transcript-inner');
    transcript = document.getElementById('transcript');
  }

  function detectLinks(text) {
    if (!text) return [];
    const links = [];
    const seen = new Set();
    let match;
    const re = new RegExp(URL_REGEX.source, 'g');
    while ((match = re.exec(text)) !== null) {
      let url = match[0].replace(TRAILING_PUNCT, '');
      if (url && !seen.has(url)) {
        seen.add(url);
        links.push(url);
      }
    }
    return links;
  }

  function showLinkPopup(link, anchorEl) {
    // Remove any existing popup
    const old = document.querySelector('.link-popup');
    if (old) old.remove();

    const popup = document.createElement('div');
    popup.className = 'link-popup';

    const openBtn = document.createElement('button');
    openBtn.className = 'link-popup-btn';
    openBtn.textContent = 'Open';
    openBtn.addEventListener('click', () => {
      window.open(link, '_blank');
      popup.remove();
    });

    const copyBtn = document.createElement('button');
    copyBtn.className = 'link-popup-btn';
    copyBtn.textContent = 'Copy Link';
    copyBtn.addEventListener('click', () => {
      navigator.clipboard.writeText(link).then(() => {
        copyBtn.textContent = 'Copied!';
        setTimeout(() => popup.remove(), 600);
      });
    });

    popup.appendChild(openBtn);
    popup.appendChild(copyBtn);
    anchorEl.appendChild(popup);

    // Close popup when clicking outside
    const dismiss = (e) => {
      if (!popup.contains(e.target) && e.target !== anchorEl.querySelector('.link-btn')) {
        popup.remove();
        document.removeEventListener('click', dismiss, true);
      }
    };
    setTimeout(() => document.addEventListener('click', dismiss, true), 0);
  }

  function makeLinkButton(link) {
    const wrapper = document.createElement('div');
    wrapper.className = 'link-btn-wrapper';
    const btn = document.createElement('button');
    btn.className = 'link-btn';
    btn.textContent = link;
    btn.title = 'Click for options';
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      showLinkPopup(link, wrapper);
    });
    wrapper.appendChild(btn);
    return wrapper;
  }

  function createLinkButtons(links) {
    if (!links || links.length === 0) return null;
    const container = document.createElement('div');
    container.className = 'bubble-links';
    for (const link of links) {
      container.appendChild(makeLinkButton(link));
    }
    return container;
  }

  function addMessage(text, isUser) {
    const row = document.createElement('div');
    row.className = `message-row ${isUser ? 'user' : 'assistant'}`;

    const bubble = document.createElement('div');
    bubble.className = `bubble ${isUser ? 'user' : 'assistant'}`;

    if (!isUser) {
      // Copy button header
      const header = document.createElement('div');
      header.className = 'bubble-header';
      const copyBtn = document.createElement('button');
      copyBtn.className = 'copy-btn';
      copyBtn.textContent = 'Copy';
      copyBtn.addEventListener('click', () => {
        navigator.clipboard.writeText(text).then(() => {
          copyBtn.textContent = 'Copied!';
          setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1000);
        });
      });
      header.appendChild(copyBtn);
      bubble.appendChild(header);
    }

    const textEl = document.createElement('div');
    textEl.className = 'bubble-text';
    textEl.textContent = text;
    bubble.appendChild(textEl);

    if (!isUser) {
      const links = detectLinks(text);
      const linkContainer = createLinkButtons(links);
      if (linkContainer) {
        bubble.appendChild(linkContainer);
      }
    }

    row.appendChild(bubble);
    transcriptInner.appendChild(row);
    scrollToBottom();

    return { textEl, bubble };
  }

  function addMessageForStream() {
    const row = document.createElement('div');
    row.className = 'message-row assistant';

    const bubble = document.createElement('div');
    bubble.className = 'bubble assistant';

    const header = document.createElement('div');
    header.className = 'bubble-header';
    const copyBtn = document.createElement('button');
    copyBtn.className = 'copy-btn';
    copyBtn.textContent = 'Copy';
    header.appendChild(copyBtn);
    bubble.appendChild(header);

    const textEl = document.createElement('div');
    textEl.className = 'bubble-text';
    textEl.textContent = '';
    bubble.appendChild(textEl);

    const linkContainer = document.createElement('div');
    linkContainer.className = 'bubble-links';
    linkContainer.style.display = 'none';
    bubble.appendChild(linkContainer);

    row.appendChild(bubble);
    transcriptInner.appendChild(row);
    scrollToBottom();

    return { textEl, copyBtn, linkContainer };
  }

  function streamResponse(text, completion) {
    stopStreaming();

    const fullText = text || '';
    if (fullText.length === 0) {
      addMessage('No response text returned.', false);
      if (completion) completion();
      return;
    }

    const { textEl, copyBtn, linkContainer } = addMessageForStream();
    streamLabel = textEl;
    streamCopyBtn = copyBtn;
    streamLinkContainer = linkContainer;
    streamFullText = fullText;
    streamCursor = 0;
    streamCompletion = completion;

    // Set up copy button for full text
    copyBtn.addEventListener('click', () => {
      navigator.clipboard.writeText(streamFullText).then(() => {
        copyBtn.textContent = 'Copied!';
        setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1000);
      });
    });

    streamTimer = setInterval(tickStream, 20);
  }

  function tickStream() {
    if (!streamLabel || !streamFullText) {
      stopStreaming();
      return;
    }

    const length = streamFullText.length;
    if (streamCursor >= length) {
      // Done streaming
      const links = detectLinks(streamFullText);
      if (links.length > 0 && streamLinkContainer) {
        streamLinkContainer.style.display = '';
        for (const link of links) {
          streamLinkContainer.appendChild(makeLinkButton(link));
        }
      }
      scrollToBottom();
      const done = streamCompletion;
      stopStreaming();
      if (done) done();
      return;
    }

    const remaining = length - streamCursor;
    let step = 1;
    if (remaining > 2500) step = 6;
    else if (remaining > 1200) step = 4;
    else if (remaining > 600) step = 3;
    else if (remaining > 250) step = 2;

    streamCursor = Math.min(length, streamCursor + step);
    streamLabel.textContent = streamFullText.substring(0, streamCursor);

    if (streamCursor === length || (streamCursor % 48) === 0) {
      scrollToBottom();
    }
  }

  function stopStreaming() {
    if (streamTimer) {
      clearInterval(streamTimer);
      streamTimer = null;
    }
    streamLabel = null;
    streamFullText = '';
    streamCursor = 0;
    streamCompletion = null;
    streamCopyBtn = null;
    streamLinkContainer = null;
  }

  function showThinking() {
    removeThinking();
    const row = document.createElement('div');
    row.className = 'thinking-row';
    const bubble = document.createElement('div');
    bubble.className = 'thinking-bubble';
    bubble.textContent = 'Thinking .';
    row.appendChild(bubble);
    transcriptInner.appendChild(row);
    thinkingRow = row;
    thinkingDotCount = 1;
    scrollToBottom();

    thinkingTimer = setInterval(() => {
      thinkingDotCount = (thinkingDotCount % 3) + 1;
      const dots = '.'.repeat(thinkingDotCount);
      bubble.textContent = `Thinking ${dots}`;
    }, 500);
  }

  function updateThinking(text) {
    if (thinkingRow) {
      const bubble = thinkingRow.querySelector('.thinking-bubble');
      if (bubble) bubble.textContent = text;
    }
  }

  function removeThinking() {
    if (thinkingTimer) {
      clearInterval(thinkingTimer);
      thinkingTimer = null;
    }
    if (thinkingRow) {
      thinkingRow.remove();
      thinkingRow = null;
    }
  }

  function clearTranscript() {
    stopStreaming();
    removeThinking();
    if (transcriptInner) {
      transcriptInner.innerHTML = '';
    }
  }

  function scrollToBottom() {
    if (transcript) {
      transcript.scrollTop = transcript.scrollHeight;
    }
  }

  return {
    init,
    addMessage,
    streamResponse,
    stopStreaming,
    showThinking,
    updateThinking,
    removeThinking,
    clearTranscript,
    scrollToBottom
  };
})();

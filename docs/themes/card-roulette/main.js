(() => {
  const DECK = [
    {
      id: "obsidian",
      title: "黑曜石 · 储备",
      bank: "ATELIER NOIR",
      holder: "LIN WEI",
      expiry: "09/29",
      last4: "4821",
      brand: "visa",
      brandLabel: "VISA",
    },
    {
      id: "oxblood",
      title: "夜波尔多",
      bank: "MAISON ROUGE",
      holder: "CHEN YU",
      expiry: "03/28",
      last4: "7730",
      brand: "orbit",
      brandLabel: "ORBIT",
    },
    {
      id: "arctic",
      title: "极地钢",
      bank: "POLARIS BANK",
      holder: "AMY ZHOU",
      expiry: "11/30",
      last4: "1904",
      brand: "visa",
      brandLabel: "VISA",
    },
    {
      id: "jade",
      title: "青玉账本",
      bank: "QING LONG",
      holder: "WEI SHEN",
      expiry: "07/27",
      last4: "6642",
      brand: "aurum",
      brandLabel: "AURUM",
    },
    {
      id: "bronze",
      title: "琥珀金库",
      bank: "FORGE & CO",
      holder: "MARCO LI",
      expiry: "01/31",
      last4: "3318",
      brand: "orbit",
      brandLabel: "ORBIT",
    },
    {
      id: "navy",
      title: "墨海军蓝",
      bank: "NORTH PIER",
      holder: "HANA KO",
      expiry: "05/29",
      last4: "9055",
      brand: "visa",
      brandLabel: "VISA",
    },
    {
      id: "ivory",
      title: "象牙私行",
      bank: "ATELIER IVORY",
      holder: "EVA SUN",
      expiry: "12/28",
      last4: "2287",
      brand: "aurum",
      brandLabel: "AURUM",
    },
    {
      id: "copper",
      title: "红铜回路",
      bank: "RED CIRCUIT",
      holder: "JON PARK",
      expiry: "08/30",
      last4: "8146",
      brand: "orbit",
      brandLabel: "ORBIT",
    },
  ];

  const CARD_COUNT = DECK.length;
  // Curl of the coil, in degrees of rotateX. CURL_FIRST is the first neighbour;
  // beyond it the tilt eases toward CURL_LIMIT, which stays well under 90 so far
  // slots keep a readable band instead of going edge-on or flipping to their backface.
  // CURL_FIRST is tied to the coil radius: a card covers a fixed height, so a wider
  // coil means each card spans a smaller arc and the near tilt has to ease. Raising it
  // without shrinking COIL_SPAN starves the middle slots of projected height and the
  // paper background opens up between layers.
  const CURL_LIMIT = 74;
  const CURL_FIRST = 30;
  const CURL_RATE = Math.atanh(CURL_FIRST / CURL_LIMIT);
  // Spring compression. COIL_PITCH is the screen-Y gap to the first neighbour; every
  // slot past it packs sub-linearly toward COIL_SPAN, so the layers crowd as they recede.
  // COIL_SPAN alone sets the coil radius, but the crowding comes from the PITCH/SPAN
  // ratio, so the two must move together or a wider coil turns into a loose fan.
  const COIL_PITCH = 171;
  const COIL_SPAN = 305;
  const COIL_RATE = Math.atanh(COIL_PITCH / COIL_SPAN);
  const COIL_SQUASH = 0.04;
  const DEPTH_SINK = 26;
  // Fade hits zero exactly at the seam, so the wrap from bottom to top is invisible.
  const FADE_SLOTS = CARD_COUNT / 2;
  const FRONT_Z = 20;
  const FRONT_Z_BOOST = 26;
  const PIXELS_PER_SLOT = 132;
  const CLICK_SLOP_PX = 8;
  const MIN_TICK_GAP = 0.036;
  const CONTACTLESS_SVG = `
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
      <path d="M8.5 8.2c2.2 2.2 2.2 5.4 0 7.6"></path>
      <path d="M11.2 5.8c3.6 3.6 3.6 8.8 0 12.4"></path>
      <path d="M13.9 3.4c5 5 5 12.2 0 17.2"></path>
    </svg>
  `;

  const phone = document.getElementById("phone");
  const phoneSlot = document.getElementById("phoneSlot");
  const wheel = document.getElementById("wheel");
  const wheelScene = document.getElementById("wheelScene");
  const cardTitle = document.getElementById("cardTitle");
  const cardMeta = document.getElementById("cardMeta");
  const liveRegion = document.getElementById("liveRegion");
  const hint = document.getElementById("hint");

  const reduceMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  let reduceMotion = reduceMotionQuery.matches;
  let audioCtx = null;
  let lastTickAt = 0;

  let position = 0;
  let velocity = 0;
  let dragging = false;
  let pointerId = null;
  let lastClientY = 0;
  let pressClientX = 0;
  let pressClientY = 0;
  let didDrag = false;
  let lastMoveAt = 0;
  let samples = [];
  let lastTickIndex = 0;
  let activeIndex = 0;
  let snapFrom = 0;
  let snapTarget = 0;
  let snapStartedAt = 0;
  let snapDuration = 0;
  let snapping = false;
  let rafId = 0;
  let lastFrameAt = 0;
  const cardNodes = [];

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function wrapIndex(value) {
    return ((Math.round(value) % CARD_COUNT) + CARD_COUNT) % CARD_COUNT;
  }

  function wrapPosition(value) {
    let next = value;
    while (next >= CARD_COUNT) {
      next -= CARD_COUNT;
    }
    while (next < 0) {
      next += CARD_COUNT;
    }
    return next;
  }

  function shortestOffset(index, current) {
    let offset = index - current;
    offset -= Math.round(offset / CARD_COUNT) * CARD_COUNT;
    return offset;
  }

  function easeOutCubic(value) {
    return 1 - Math.pow(1 - value, 3);
  }

  function currentFloatIndex() {
    return position;
  }

  function brandMarkup(card) {
    if (card.brand === "orbit") {
      return `<span class="orb"></span><span class="orb"></span>`;
    }
    return card.brandLabel;
  }

  function createCard(card, index) {
    const article = document.createElement("article");
    article.className = `credit-card theme-${card.id}`;
    article.dataset.index = String(index);
    article.setAttribute("role", "option");
    article.innerHTML = `
      <div class="card-face card-front">
        <div class="card-metal"></div>
        <div class="card-grain"></div>
        <div class="card-sheen"></div>
        <div class="card-inner">
          <header class="card-top">
            <span class="bank">${card.bank}</span>
            <span class="contactless">${CONTACTLESS_SVG}</span>
          </header>
          <div class="chip" aria-hidden="true"></div>
          <p class="pan">••••&nbsp;&nbsp;••••&nbsp;&nbsp;••••&nbsp;&nbsp;${card.last4}</p>
          <footer class="card-bottom">
            <div class="field">
              <span class="label">持卡人</span>
              <span class="value name">${card.holder}</span>
            </div>
            <div class="field">
              <span class="label">有效期</span>
              <span class="value">${card.expiry}</span>
            </div>
            <div class="brand brand-${card.brand}">${brandMarkup(card)}</div>
          </footer>
        </div>
      </div>
      <div class="card-face card-back" aria-hidden="true">
        <div class="card-metal"></div>
        <div class="card-grain"></div>
        <div class="card-back-stripe"></div>
        <p class="card-back-bank">${card.bank}</p>
        <p class="card-back-pan">•••• ${card.last4}</p>
      </div>
    `;
    return article;
  }

  function ensureAudio() {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) {
      return null;
    }
    if (!audioCtx) {
      audioCtx = new AudioContextClass();
    }
    if (audioCtx.state === "suspended") {
      audioCtx.resume();
    }
    return audioCtx;
  }

  function playTick() {
    const context = ensureAudio();
    if (!context) {
      return;
    }
    const now = context.currentTime;
    if (now - lastTickAt < MIN_TICK_GAP) {
      return;
    }
    lastTickAt = now;

    const detune = 0.988 + Math.random() * 0.024;
    const limiter = context.createDynamicsCompressor();
    limiter.threshold.setValueAtTime(-18, now);
    limiter.knee.setValueAtTime(4, now);
    limiter.ratio.setValueAtTime(12, now);
    limiter.attack.setValueAtTime(0.001, now);
    limiter.release.setValueAtTime(0.06, now);

    const master = context.createGain();
    master.gain.setValueAtTime(0.0001, now);
    master.gain.exponentialRampToValueAtTime(0.48, now + 0.0012);
    master.gain.exponentialRampToValueAtTime(0.001, now + 0.028);

    const makeup = context.createGain();
    makeup.gain.setValueAtTime(1.7, now);

    master.connect(limiter);
    limiter.connect(makeup);
    makeup.connect(context.destination);

    const partials = [
      { frequency: 980, type: "sine", level: 0.7, decay: 0.028 },
      { frequency: 1320, type: "triangle", level: 0.28, decay: 0.022 },
      { frequency: 2480, type: "sine", level: 0.2, decay: 0.012 },
    ];

    for (let index = 0; index < partials.length; index += 1) {
      const partial = partials[index];
      const oscillator = context.createOscillator();
      const partialGain = context.createGain();
      oscillator.type = partial.type;
      oscillator.frequency.setValueAtTime(partial.frequency * detune, now);
      partialGain.gain.setValueAtTime(partial.level, now);
      partialGain.gain.exponentialRampToValueAtTime(0.001, now + partial.decay);
      oscillator.connect(partialGain);
      partialGain.connect(master);
      oscillator.start(now);
      oscillator.stop(now + partial.decay + 0.004);
    }

    const grainLength = Math.floor(context.sampleRate * 0.012);
    const grain = context.createBuffer(1, grainLength, context.sampleRate);
    const grainData = grain.getChannelData(0);
    for (let index = 0; index < grainLength; index += 1) {
      grainData[index] =
        (Math.random() * 2 - 1) * Math.exp(-index / (context.sampleRate * 0.0022));
    }
    const rustle = context.createBufferSource();
    rustle.buffer = grain;
    const bandpass = context.createBiquadFilter();
    bandpass.type = "bandpass";
    bandpass.frequency.value = 2100;
    bandpass.Q.value = 1.1;
    const rustleGain = context.createGain();
    rustleGain.gain.setValueAtTime(0.045, now);
    rustleGain.gain.exponentialRampToValueAtTime(0.001, now + 0.01);
    rustle.connect(bandpass);
    bandpass.connect(rustleGain);
    rustleGain.connect(master);
    rustle.start(now);
    rustle.stop(now + 0.012);
  }

  function updatePlate(index) {
    const card = DECK[index];
    cardTitle.textContent = card.title;
    cardMeta.textContent = `${card.bank} · ${card.last4}`;
    liveRegion.textContent = `当前卡片 ${card.title}`;
    cardNodes.forEach((node, nodeIndex) => {
      const selected = nodeIndex === index;
      node.classList.toggle("is-active", selected);
      node.setAttribute("aria-selected", selected ? "true" : "false");
    });
  }

  function checkTick() {
    const nextIndex = wrapIndex(currentFloatIndex());
    if (nextIndex !== lastTickIndex) {
      lastTickIndex = nextIndex;
      if (nextIndex !== activeIndex) {
        activeIndex = nextIndex;
        updatePlate(activeIndex);
      }
      playTick();
    }
  }

  function renderCards() {
    const current = currentFloatIndex();
    const curlScale = reduceMotion ? 0.4 : 1;
    const spanScale = reduceMotion ? 0.88 : 1;
    const depthOrder = [];

    cardNodes.forEach((node, index) => {
      const offset = shortestOffset(index, current);
      const absOffset = Math.abs(offset);
      const curl = Math.tanh(CURL_RATE * offset);
      const rotateX = -CURL_LIMIT * curl * curlScale;
      const translateY = COIL_SPAN * Math.tanh(COIL_RATE * offset) * spanScale;
      const fade = Math.max(0, 1 - absOffset / FADE_SLOTS);
      const frontBoost = Math.max(0, 1 - absOffset) * FRONT_Z_BOOST;
      const translateZ = FRONT_Z + frontBoost - DEPTH_SINK * Math.abs(curl);
      const scale = 0.96 + fade * 0.04;
      const squash = 1 - (1 - fade) * COIL_SQUASH;
      const opacity = 1 - Math.pow(1 - fade, 2.2);
      const brightness = 0.32 + fade * 0.68;
      const blur = reduceMotion ? 0 : (1 - fade) * 0.5;
      const zIndex = Math.round(1000 - absOffset * 100);

      node.style.setProperty("--tilt", String(rotateX));
      node.style.opacity = String(clamp(opacity, 0, 1));
      node.style.filter = `brightness(${clamp(brightness, 0.32, 1)}) blur(${blur}px)`;
      node.style.zIndex = String(zIndex);
      node.style.pointerEvents = "auto";
      node.setAttribute("aria-hidden", fade < 0.12 ? "true" : "false");
      node.style.transform = [
        "translate(-50%, -50%)",
        `translateY(${translateY}px)`,
        `translateZ(${translateZ}px)`,
        `rotateX(${rotateX}deg)`,
        `scale(${scale}, ${scale * squash})`,
      ].join(" ");
      depthOrder.push({ node, zIndex, absOffset });
    });

    depthOrder
      .sort((left, right) => left.zIndex - right.zIndex || right.absOffset - left.absOffset)
      .forEach((entry) => {
        wheel.appendChild(entry.node);
      });
  }

  function stopLoop() {
    if (rafId) {
      cancelAnimationFrame(rafId);
      rafId = 0;
    }
  }

  function startLoop() {
    if (rafId) {
      return;
    }
    lastFrameAt = performance.now();
    rafId = requestAnimationFrame(step);
  }

  function beginSnap(targetIndex) {
    const target = Math.round(targetIndex);
    const distance = Math.abs(target - position);
    snapFrom = position;
    snapTarget = target;
    snapStartedAt = performance.now();
    snapDuration = reduceMotion
      ? 140
      : clamp(200 + distance * 220, 220, 560);
    snapping = true;
    velocity = 0;
    startLoop();
  }

  function step(now) {
    const delta = Math.min(32, now - lastFrameAt);
    lastFrameAt = now;

    if (snapping) {
      const progress = Math.min(1, (now - snapStartedAt) / snapDuration);
      position = snapFrom + (snapTarget - snapFrom) * easeOutCubic(progress);
      if (progress >= 1) {
        position = wrapPosition(snapTarget);
        snapping = false;
        velocity = 0;
      }
    } else if (!dragging && !reduceMotion && Math.abs(velocity) > 0.002) {
      position += velocity * delta;
      velocity *= Math.pow(0.9, delta / 16);
      if (Math.abs(velocity) < 0.012) {
        beginSnap(position);
      }
    } else if (!dragging && !snapping) {
      const nearest = Math.round(position);
      if (Math.abs(nearest - position) > 0.02) {
        beginSnap(nearest);
      } else {
        position = wrapPosition(nearest);
        renderCards();
        checkTick();
        rafId = 0;
        return;
      }
    }

    renderCards();
    checkTick();

    if (dragging || snapping || Math.abs(velocity) > 0.002) {
      rafId = requestAnimationFrame(step);
    } else {
      rafId = 0;
    }
  }

  function sceneScaleY() {
    const rect = wheelScene.getBoundingClientRect();
    return rect.height / wheelScene.offsetHeight || 1;
  }

  function recordSample(clientY, time) {
    samples.push({ y: clientY, t: time, position });
    if (samples.length > 8) {
      samples.shift();
    }
  }

  function sampleVelocity() {
    if (samples.length < 2) {
      return 0;
    }
    const latest = samples[samples.length - 1];
    const cutoff = latest.t - 90;
    let earliest = samples[0];
    for (let i = 0; i < samples.length; i += 1) {
      if (samples[i].t >= cutoff) {
        earliest = samples[i];
        break;
      }
    }
    const elapsed = latest.t - earliest.t;
    if (elapsed < 12) {
      return 0;
    }
    return (latest.position - earliest.position) / elapsed;
  }

  function onPointerDown(event) {
    if (event.pointerType === "mouse" && event.button !== 0) {
      return;
    }
    ensureAudio();
    dragging = false;
    didDrag = false;
    snapping = false;
    velocity = 0;
    pointerId = event.pointerId;
    pressClientX = event.clientX;
    pressClientY = event.clientY;
    lastClientY = event.clientY;
    lastMoveAt = event.timeStamp;
    samples = [];
    recordSample(event.clientY, event.timeStamp);
    wheelScene.setPointerCapture(event.pointerId);
    event.preventDefault();
  }

  function onPointerMove(event) {
    if (event.pointerId !== pointerId) {
      return;
    }
    const travel = Math.hypot(event.clientX - pressClientX, event.clientY - pressClientY);
    if (!didDrag) {
      if (travel < CLICK_SLOP_PX) {
        return;
      }
      didDrag = true;
      dragging = true;
      lastClientY = pressClientY;
      wheelScene.classList.add("is-dragging");
      hint.classList.add("is-hidden");
      startLoop();
    }
    const localDelta = (event.clientY - lastClientY) / sceneScaleY();
    position += -localDelta / PIXELS_PER_SLOT;
    lastClientY = event.clientY;
    lastMoveAt = event.timeStamp;
    recordSample(event.clientY, event.timeStamp);
    event.preventDefault();
  }

  function onPointerUp(event) {
    if (event.pointerId !== pointerId) {
      return;
    }
    const wasDragging = didDrag;
    dragging = false;
    didDrag = false;
    pointerId = null;
    wheelScene.classList.remove("is-dragging");

    if (!wasDragging) {
      const card = cardFromEvent(event);
      if (card) {
        selectCardByIndex(Number(card.dataset.index));
      }
      return;
    }

    velocity = reduceMotion ? 0 : sampleVelocity();
    if (event.timeStamp - lastMoveAt > 140) {
      velocity = 0;
    }
    const projected = position + velocity * (reduceMotion ? 0 : 170);
    const target = Math.round(projected);
    if (reduceMotion || Math.abs(velocity) < 0.018) {
      beginSnap(target);
    } else {
      startLoop();
    }
  }

  function fitPhone() {
    const scale = Math.min(window.innerWidth / 390, window.innerHeight / 844, 1);
    phoneSlot.style.width = `${390 * scale}px`;
    phoneSlot.style.height = `${844 * scale}px`;
    phone.style.transform = `scale(${scale})`;
  }

  function selectCardByIndex(targetIndex) {
    if (!Number.isInteger(targetIndex) || targetIndex < 0 || targetIndex >= CARD_COUNT) {
      return;
    }
    ensureAudio();
    hint.classList.add("is-hidden");
    const delta = shortestOffset(targetIndex, position);
    if (Math.abs(delta) < 0.02) {
      return;
    }
    beginSnap(position + delta);
  }

  function cardFromEvent(event) {
    const fromTarget = event.target.closest ? event.target.closest(".credit-card") : null;
    if (fromTarget) {
      return fromTarget;
    }
    const stack = document.elementsFromPoint(event.clientX, event.clientY);
    return stack.find((node) => node.classList && node.classList.contains("credit-card")) || null;
  }

  function stepBy(delta) {
    ensureAudio();
    hint.classList.add("is-hidden");
    const base = snapping ? snapTarget : Math.round(position);
    beginSnap(base + delta);
  }

  function onKeyDown(event) {
    if (event.key === "ArrowUp" || event.key === "PageUp") {
      event.preventDefault();
      stepBy(-1);
    } else if (event.key === "ArrowDown" || event.key === "PageDown") {
      event.preventDefault();
      stepBy(1);
    }
  }

  function build() {
    DECK.forEach((card, index) => {
      const node = createCard(card, index);
      cardNodes.push(node);
      wheel.appendChild(node);
    });
    updatePlate(0);
    renderCards();
    fitPhone();
  }

  reduceMotionQuery.addEventListener("change", (event) => {
    reduceMotion = event.matches;
    renderCards();
  });

  wheelScene.addEventListener("pointerdown", onPointerDown);
  wheelScene.addEventListener("pointermove", onPointerMove);
  function onPointerCancel(event) {
    if (event.pointerId !== pointerId) {
      return;
    }
    dragging = false;
    didDrag = false;
    pointerId = null;
    wheelScene.classList.remove("is-dragging");
    beginSnap(Math.round(position));
  }

  wheelScene.addEventListener("pointerup", onPointerUp);
  wheelScene.addEventListener("pointercancel", onPointerCancel);
  wheelScene.addEventListener(
    "touchmove",
    (event) => {
      event.preventDefault();
    },
    { passive: false }
  );
  window.addEventListener("keydown", onKeyDown);
  window.addEventListener("resize", fitPhone);

  build();
})();

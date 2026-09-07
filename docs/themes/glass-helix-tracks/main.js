(() => {
  const TRACKS = [
    { id: "crave", title: "Crave You", artist: "Flight Facilities", duration: "4:12", hex: "#e8b84a", art: "sun" },
    { id: "twin", title: "Twin Flame", artist: "KAYTRANADA", duration: "3:28", hex: "#7c5cff", art: "orb" },
    { id: "summer", title: "Summer in NY", artist: "Sofi Tukker", duration: "3:05", hex: "#c6de4a", art: "grid" },
    { id: "better", title: "Better No", artist: "Louis the Child", duration: "2:54", hex: "#3d7cff", art: "wave" },
    { id: "delilah", title: "Delilah", artist: "Florence + The Machine", duration: "4:40", hex: "#e85a8a", art: "bloom" },
    { id: "sodium", title: "Sodium Light", artist: "Kite Room", duration: "3:41", hex: "#f27a3c", art: "bar" },
    { id: "after", title: "Afterimage", artist: "North Pier", duration: "5:02", hex: "#c9ced6", art: "ring" },
    { id: "glass", title: "Glass Corridor", artist: "Mira Vale", duration: "3:17", hex: "#6ee0c8", art: "shard" },
    { id: "second", title: "Second Body", artist: "Pale Circuit", duration: "4:08", hex: "#9b4dff", art: "tape" },
    { id: "low", title: "Low Tide Fax", artist: "June Static", duration: "2:46", hex: "#4ec3ff", art: "pulse" },
    { id: "amber", title: "Amber Relay", artist: "Holo Field", duration: "3:33", hex: "#f0c35a", art: "field" },
    { id: "paper", title: "Paper Moon Cut", artist: "Atelier Late", duration: "4:21", hex: "#ff5d7a", art: "cut" },
  ];

  const COUNT = TRACKS.length;
  const TILT_MIN = -70;
  const TILT_MAX = 70;
  const LOCK_PIXELS = 10;
  const CLICK_SLOP = 8;
  const FOCUS_DURATION = 420;
  const TILT_RESET_DURATION = 400;
  const DOUBLE_MS = 340;
  const DOUBLE_SLOP = 18;
  const TICK_MIN_MS = 32;
  const POS_TICK_STEP = 0.14;
  const TILT_TICK_STEP = 3.2;
  const PIXELS_PER_SLOT = 64;
  const PIXELS_PER_TILT = 1.35;
  const PIXELS_PER_SPACING = 2.4;
  const KEY_POSITION_STEP = 0.045;
  const KEY_TILT_STEP = 1.35;
  const KEY_SPACING_STEP = 0.9;
  const TRAIL_SCALE = 0.68;
  const TWIST_GAIN = 1.6;
  const TWIST_CAP_DEG = 70;
  const FLAT_TWIST_DEG = 52;
  const DEPTH_RATIO = 1.9;
  const SPRING_COMPRESSION = 0.7;
  const FLAT_RADIUS_GAIN = 1.15;
  const FLAT_SPREAD_END = 0.45;
  const FLAT_PITCH = 0.55;
  const FLAT_TRAIL = 0.6;
  const FLAT_DEPTH = 0.1;
  const FLAT_FUNNEL = 100;
  const FLAT_LEAN = 38;
  const FLAT_FLARE = 0.22;
  const RY_LIMIT = 7;
  const RY_NEIGHBOR_MAX = 5.5;
  const RZ_LIMIT = 7;
  const CARD_THICKNESS = 10;
  const PIERCE_MARGIN = 7;
  const PHONE_WIDTH = 390;
  const PHONE_HEIGHT = 844;
  const NARROW_BREAKPOINT = 430;

  const scene = document.getElementById("scene");
  const deck = document.getElementById("deck");
  const well = document.getElementById("well");
  const statusLabel = document.getElementById("statusLabel");
  const nowTitle = document.getElementById("nowTitle");
  const nowMeta = document.getElementById("nowMeta");
  const hint = document.getElementById("hint");
  const liveRegion = document.getElementById("liveRegion");
  const phoneSlot = document.getElementById("phoneSlot");
  const phone = document.getElementById("phone");
  const phoneScreen = document.getElementById("phoneScreen");
  const clock = document.getElementById("clock");
  const reduceMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");

  const cardNodes = [];
  const pressedKeys = new Set();

  let reduceMotion = reduceMotionQuery.matches;
  let position = 0;
  let positionVelocity = 0;
  let tiltAngle = 44;
  let focusAnim = null;
  let tiltResetAnim = null;
  let lastTap = null;
  let audioContext = null;
  let audioTickCount = 0;
  let lastTickAt = 0;
  let lastTickPosition = 0;
  let lastTickTilt = 44;
  let tiltVelocity = 0;
  let spacing = 96;
  let minSpacingCache = { key: "", value: 120 };
  let spacingVelocity = 0;
  let dragging = false;
  let pointerId = null;
  let lastClientX = 0;
  let lastClientY = 0;
  let lastMoveAt = 0;
  let samples = [];
  let lastFrameAt = 0;
  let lastFrontIndex = -1;
  let lastStatusText = "";
  let sceneWidth = 370;
  let sceneHeight = 780;
  let gestureAxis = null;
  let spacingSign = 0;
  let lockOriginX = 0;
  let lockOriginY = 0;

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function lerp(a, b, t) {
    return a + (b - a) * t;
  }

  function wrapSlot(index, offset) {
    let slot = index - offset;
    slot = ((slot % COUNT) + COUNT) % COUNT;
    if (slot > COUNT / 2) {
      slot -= COUNT;
    }
    return slot;
  }

  function nearestIndex(offset) {
    let best = 0;
    let bestAbs = Infinity;
    for (let index = 0; index < COUNT; index += 1) {
      const distance = Math.abs(wrapSlot(index, offset));
      if (distance < bestAbs) {
        bestAbs = distance;
        best = index;
      }
    }
    return best;
  }

  function isNarrowView() {
    return window.innerWidth <= NARROW_BREAKPOINT;
  }

  function fitPhone() {
    if (isNarrowView()) {
      phoneSlot.style.width = "100vw";
      phoneSlot.style.height = "100vh";
      phone.style.transform = "none";
      return;
    }
    const pad = 28;
    const scale = Math.min((window.innerWidth - pad) / PHONE_WIDTH, (window.innerHeight - pad) / PHONE_HEIGHT, 1);
    phoneSlot.style.width = `${PHONE_WIDTH * scale}px`;
    phoneSlot.style.height = `${PHONE_HEIGHT * scale}px`;
    phone.style.transform = `scale(${scale})`;
  }

  function syncClock() {
    const now = new Date();
    const hours = String(now.getHours()).padStart(2, "0");
    const minutes = String(now.getMinutes()).padStart(2, "0");
    clock.textContent = `${hours}:${minutes}`;
  }

  function hexToRgb(hex) {
    const value = hex.replace("#", "");
    return {
      r: parseInt(value.slice(0, 2), 16),
      g: parseInt(value.slice(2, 4), 16),
      b: parseInt(value.slice(4, 6), 16),
    };
  }

  function artSvg(kind, hex) {
    const ink = "rgba(255,255,255,0.86)";
    const dim = "rgba(255,255,255,0.22)";
    const shapes = {
      sun: `<circle cx="50" cy="50" r="18" fill="none" stroke="${ink}" stroke-width="5"/><circle cx="50" cy="50" r="6" fill="${ink}"/>`,
      orb: `<ellipse cx="42" cy="48" rx="22" ry="26" fill="${dim}"/><ellipse cx="62" cy="54" rx="18" ry="20" fill="${ink}" opacity=".55"/>`,
      grid: `<rect x="22" y="22" width="24" height="24" fill="${ink}"/><rect x="54" y="22" width="24" height="24" fill="${dim}"/><rect x="22" y="54" width="24" height="24" fill="${dim}"/><rect x="54" y="54" width="24" height="24" fill="${ink}"/>`,
      wave: `<path d="M14 58 C28 28, 40 28, 54 58 S80 88, 94 58" fill="none" stroke="${ink}" stroke-width="6"/>`,
      bloom: `<circle cx="50" cy="50" r="8" fill="${ink}"/><g fill="${dim}"><circle cx="50" cy="24" r="10"/><circle cx="50" cy="76" r="10"/><circle cx="24" cy="50" r="10"/><circle cx="76" cy="50" r="10"/></g>`,
      bar: `<rect x="22" y="28" width="10" height="48" fill="${ink}"/><rect x="40" y="18" width="10" height="64" fill="${dim}"/><rect x="58" y="34" width="10" height="40" fill="${ink}"/><rect x="76" y="24" width="10" height="54" fill="${dim}"/>`,
      ring: `<circle cx="50" cy="50" r="24" fill="none" stroke="${ink}" stroke-width="10"/><circle cx="50" cy="50" r="8" fill="${dim}"/>`,
      shard: `<polygon points="50,16 84,78 16,78" fill="${ink}" opacity=".85"/><polygon points="50,34 70,72 30,72" fill="${hex}"/>`,
      tape: `<rect x="16" y="28" width="68" height="10" fill="${ink}"/><rect x="16" y="46" width="68" height="8" fill="${dim}"/><rect x="16" y="62" width="68" height="10" fill="${ink}"/>`,
      pulse: `<rect x="22" y="22" width="56" height="56" rx="14" fill="none" stroke="${ink}" stroke-width="5"/><rect x="34" y="34" width="32" height="32" rx="8" fill="${dim}"/>`,
      field: `<g fill="${ink}"><circle cx="28" cy="30" r="4"/><circle cx="50" cy="24" r="5"/><circle cx="74" cy="32" r="4"/><circle cx="34" cy="52" r="5"/><circle cx="58" cy="50" r="4"/><circle cx="44" cy="74" r="5"/><circle cx="70" cy="70" r="4"/></g>`,
      cut: `<path d="M12 70 L70 12 L88 30 L30 88 Z" fill="${ink}" opacity=".8"/><rect x="18" y="58" width="48" height="8" transform="rotate(-42 42 62)" fill="${hex}"/>`,
    };
    return `<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">${shapes[kind]}</svg>`;
  }

  function cardMetrics() {
    const node = cardNodes[0];
    const width = node && node.offsetWidth ? node.offsetWidth : 310;
    const height = node && node.offsetHeight ? node.offsetHeight : Math.round((width * 53.98) / 85.6);
    return { width, height };
  }

  function rotateX(x, y, z, deg) {
    const rad = (deg * Math.PI) / 180;
    const cos = Math.cos(rad);
    const sin = Math.sin(rad);
    return { x, y: y * cos - z * sin, z: y * sin + z * cos };
  }

  function rotateY(x, y, z, deg) {
    const rad = (deg * Math.PI) / 180;
    const cos = Math.cos(rad);
    const sin = Math.sin(rad);
    return { x: x * cos + z * sin, y, z: -x * sin + z * cos };
  }

  function rotateZ(x, y, z, deg) {
    const rad = (deg * Math.PI) / 180;
    const cos = Math.cos(rad);
    const sin = Math.sin(rad);
    return { x: x * cos - y * sin, y: x * sin + y * cos, z };
  }

  function applyCardRotations(x, y, z, rx, ry, rz) {
    let point = rotateZ(x, y, z, rz);
    point = rotateY(point.x, point.y, point.z, ry);
    point = rotateX(point.x, point.y, point.z, rx);
    return point;
  }

  function invertCardRotations(x, y, z, rx, ry, rz) {
    let point = rotateX(x, y, z, -rx);
    point = rotateY(point.x, point.y, point.z, -ry);
    point = rotateZ(point.x, point.y, point.z, -rz);
    return point;
  }

  function yawForTheta(theta, ryAmp) {
    return clamp(Math.sin(theta) * ryAmp, -RY_LIMIT, RY_LIMIT);
  }

  function helixPoint(slot, pitch, params) {
    const theta = slot * params.twist;
    const flare = 1 + params.flare * Math.abs(slot);
    return {
      theta,
      x: params.helixRadius * flare * Math.sin(theta),
      y: slot * pitch,
      z: params.helixDepth * (Math.cos(theta) - 1) - Math.abs(slot) * params.funnel - slot * params.axisLean,
    };
  }

  function rawFrame(slot, pitch, params, faceSmooth) {
    const point = helixPoint(slot, pitch, params);
    const slotSign = slot === 0 ? 0 : slot > 0 ? 1 : -1;
    let rx = slotSign * 2.6 * params.rxAmp;
    let ry = yawForTheta(point.theta, params.ryAmp);
    let rz = clamp(Math.sin(point.theta) * params.rzAmp, -RZ_LIMIT, RZ_LIMIT);
    return {
      x: point.x,
      y: point.y,
      z: point.z,
      rx: rx * (1 - faceSmooth),
      ry: ry * (1 - faceSmooth),
      rz: rz * (1 - faceSmooth),
      scale: lerp(params.trailScale, 1, faceSmooth),
    };
  }

  function worldCorner(frame, localX, localY) {
    const rotated = applyCardRotations(localX * frame.scale, localY * frame.scale, 0, frame.rx, frame.ry, frame.rz);
    return { x: rotated.x + frame.x, y: rotated.y + frame.y, z: rotated.z + frame.z };
  }

  function cardCorners(frame, halfW, halfH) {
    return [
      worldCorner(frame, -halfW, -halfH),
      worldCorner(frame, halfW, -halfH),
      worldCorner(frame, halfW, halfH),
      worldCorner(frame, -halfW, halfH),
    ];
  }

  function segmentHitsCard(start, end, frame, halfW, halfH) {
    const localStart = invertCardRotations(start.x - frame.x, start.y - frame.y, start.z - frame.z, frame.rx, frame.ry, frame.rz);
    const localEnd = invertCardRotations(end.x - frame.x, end.y - frame.y, end.z - frame.z, frame.rx, frame.ry, frame.rz);
    const reachX = halfW * frame.scale + PIERCE_MARGIN;
    const reachY = halfH * frame.scale + PIERCE_MARGIN;
    const inside = (point) => Math.abs(point.x) <= reachX && Math.abs(point.y) <= reachY && Math.abs(point.z) <= CARD_THICKNESS;
    if (inside(localStart) || inside(localEnd)) {
      return true;
    }
    if (localStart.z * localEnd.z > 0) {
      return false;
    }
    const denom = localEnd.z - localStart.z;
    if (Math.abs(denom) < 1e-8) {
      return false;
    }
    const t = -localStart.z / denom;
    if (t < -0.02 || t > 1.02) {
      return false;
    }
    const hitX = localStart.x + (localEnd.x - localStart.x) * t;
    const hitY = localStart.y + (localEnd.y - localStart.y) * t;
    return Math.abs(hitX) <= reachX && Math.abs(hitY) <= reachY;
  }

  function pairIntersects(frameA, frameB, halfW, halfH) {
    const cornersA = cardCorners(frameA, halfW, halfH);
    const cornersB = cardCorners(frameB, halfW, halfH);
    for (let index = 0; index < 4; index += 1) {
      if (segmentHitsCard(cornersA[index], cornersA[(index + 1) % 4], frameB, halfW, halfH)) {
        return true;
      }
      if (segmentHitsCard(cornersB[index], cornersB[(index + 1) % 4], frameA, halfW, halfH)) {
        return true;
      }
    }
    return false;
  }

  function frameForPierce(slot, pitch, params, faceSmooth) {
    return rawFrame(slot, pitch, params, faceSmooth);
  }

  function helixHasPierce(pitch, params, width, height) {
    const halfW = width * 0.5;
    const halfH = height * 0.5;
    const phases = [-4, -3.5, -3, -2.5, -2, -1.5, -1, -0.5, 0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3];
    for (const phase of phases) {
      const current = frameForPierce(phase, pitch, params, 0);
      const next = frameForPierce(phase + 1, pitch, params, 0);
      if (pairIntersects(current, next, halfW, halfH)) {
        return true;
      }
    }
    const front = frameForPierce(0, pitch, params, 1);
    const above = frameForPierce(1, pitch, params, 0);
    const below = frameForPierce(-1, pitch, params, 0);
    if (pairIntersects(front, above, halfW, halfH) || pairIntersects(front, below, halfW, halfH)) {
      return true;
    }
    const midFace = 0.5 * 0.5 * (3 - 2 * 0.5);
    const midFront = frameForPierce(0.5, pitch, params, midFace);
    const midNext = frameForPierce(1.5, pitch, params, 0);
    const midPrev = frameForPierce(-0.5, pitch, params, 0);
    return pairIntersects(midFront, midNext, halfW, halfH) || pairIntersects(midFront, midPrev, halfW, halfH);
  }

  function computeMinSpacing() {
    const { width, height } = cardMetrics();
    const params = helixParams();
    const halfW = width * 0.5;
    const halfH = height * 0.5;
    const halfDiag = Math.hypot(halfW, halfH);
    const xzChord = 2 * params.helixRadius * Math.abs(Math.sin(params.twist * 0.5));
    const relRy = Math.min(RY_LIMIT, RY_NEIGHBOR_MAX, params.ryAmp);
    const cornerStab = halfW * Math.abs(Math.sin((relRy * Math.PI) / 180));
    const lateralClear = clamp((xzChord - width * 0.22) / Math.max(1, width * 0.55), 0, 1);
    const stacked = height * 0.86 + cornerStab;
    const loosened = height * 0.56 + cornerStab * 0.24;
    const closedForm = lerp(stacked, loosened, lateralClear);
    const pitchFromDist = Math.sqrt(Math.max(0, (halfDiag * 0.72 + cornerStab) * (halfDiag * 0.72 + cornerStab) - xzChord * xzChord));
    const floor = height * (0.52 + 0.22 * (1 - lateralClear));
    let pitch = Math.max(closedForm, pitchFromDist, floor) * SPRING_COMPRESSION * lerp(1, FLAT_PITCH, params.squash);

    if (helixHasPierce(pitch, params, width, height)) {
      let low = pitch;
      let high = Math.max(pitch * 1.1, height * 1.08);
      let guard = 0;
      while (helixHasPierce(high, params, width, height) && guard < 8) {
        high *= 1.12;
        guard += 1;
      }
      for (let step = 0; step < 11; step += 1) {
        const mid = (low + high) * 0.5;
        if (helixHasPierce(mid, params, width, height)) {
          low = mid;
        } else {
          high = mid;
        }
      }
      pitch = high;
    }

    return pitch * 1.03;
  }

  function minSpacing() {
    const { width, height } = cardMetrics();
    const params = helixParams();
    const key = `${width.toFixed(1)}|${height.toFixed(1)}|${params.twist.toFixed(4)}|${params.helixRadius.toFixed(2)}|${params.ryAmp.toFixed(2)}|${params.flatten.toFixed(3)}`;
    if (key === minSpacingCache.key) {
      return minSpacingCache.value;
    }
    const value = computeMinSpacing();
    minSpacingCache = { key, value };
    return value;
  }

  function maxSpacing() {
    const { height } = cardMetrics();
    return Math.max(minSpacing() + 28, Math.min(height * 2.05, sceneHeight / 2.35));
  }

  function clampSpacing(value) {
    return clamp(value, minSpacing(), maxSpacing());
  }

  function clampTilt(value) {
    return clamp(value, TILT_MIN, TILT_MAX);
  }

  function classifySector(dx, dy) {
    const angle = ((Math.atan2(dy, dx) * 180) / Math.PI + 360) % 360;
    return Math.round(angle / 45) % 8;
  }

  function axisFromSector(sector) {
    if (sector === 2 || sector === 6) {
      return { axis: "vertical", spacingSign: 0 };
    }
    if (sector === 0 || sector === 4) {
      return { axis: "horizontal", spacingSign: 0 };
    }
    return { axis: "spacing", spacingSign: sector === 1 || sector === 7 ? 1 : -1 };
  }

  function flattenPitchScale() {
    return lerp(1, FLAT_PITCH, helixParams().squash);
  }

  function effectiveSpacing() {
    return Math.max(spacing * flattenPitchScale(), minSpacing());
  }

  function helixParams() {
    const curveAmount = clamp(tiltAngle / TILT_MAX, -1, 1);
    const twistSign = curveAmount < 0 ? -1 : 1;
    const coilEnd = Math.min(TILT_MAX, TWIST_CAP_DEG / TWIST_GAIN);
    const twistUnit = clamp(Math.abs(tiltAngle) / coilEnd, 0, 1);
    const flatten = clamp((Math.abs(tiltAngle) - coilEnd) / Math.max(1, TILT_MAX - coilEnd), 0, 1);
    const spread = clamp(flatten / FLAT_SPREAD_END, 0, 1);
    const squash = clamp((flatten - FLAT_SPREAD_END) / (1 - FLAT_SPREAD_END), 0, 1);
    const twistDeg = lerp(TWIST_CAP_DEG, FLAT_TWIST_DEG, squash) * twistUnit;
    const twist = (twistSign * twistDeg * Math.PI) / 180;
    const eased = Math.pow(twistUnit, 0.55);
    const { width: cardWidth } = cardMetrics();
    const halfScene = Math.max(sceneWidth, 1) * 0.5;
    const swingCap = Math.min(halfScene * 0.9, cardWidth * 0.5);
    const minRadius = Math.min(swingCap, Math.max(120, cardWidth * 0.4));
    const maxRadius = Math.max(minRadius, swingCap);
    const helixRadius = lerp(lerp(minRadius, maxRadius, eased), maxRadius * FLAT_RADIUS_GAIN, spread);
    const helixDepth = helixRadius * DEPTH_RATIO * lerp(1, FLAT_DEPTH, spread);
    const trailScale = lerp(TRAIL_SCALE, FLAT_TRAIL, spread);
    const pairDelta = 2 * Math.abs(Math.sin(twist * 0.5));
    const rawRyAmp = lerp(3.2, 8, eased);
    const ryAmp = pairDelta > 1e-6 ? Math.min(rawRyAmp, RY_NEIGHBOR_MAX / pairDelta) : rawRyAmp;
    const rzAmp = lerp(1.6, 5.2, eased);
    const rxAmp = lerp(0.4, 0.85, twistUnit);
    return {
      curveAmount,
      twistSign,
      twist,
      flatten,
      squash,
      helixRadius,
      helixDepth,
      trailScale,
      flare: FLAT_FLARE * squash,
      funnel: FLAT_FUNNEL * spread,
      axisLean: FLAT_LEAN * spread,
      eased,
      ryAmp,
      rzAmp,
      rxAmp,
    };
  }

  function helixPose(slot, index, frontIndex) {
    const { width, height } = cardMetrics();
    const pitch = effectiveSpacing();
    const params = helixParams();
    const absSlot = Math.abs(slot);
    const isFront = index === frontIndex;
    const face = isFront ? clamp(1 - absSlot, 0, 1) : 0;
    const faceSmooth = face * face * (3 - 2 * face);
    const frame = rawFrame(slot, pitch, params, faceSmooth);
    const visibleSlots = 4;
    const fade = clamp(1 - Math.max(0, absSlot - (visibleSlots - 0.25)) / 0.9, 0, 1);

    return {
      x: frame.x,
      y: frame.y,
      z: frame.z,
      rx: frame.rx,
      ry: frame.ry,
      rz: frame.rz,
      scale: frame.scale,
      opacity: fade,
      cardHeight: height,
      cardWidth: width,
      theta: slot * params.twist,
      helixRadius: params.helixRadius,
      twist: params.twist,
      axisLean: params.axisLean,
      curveAmount: params.curveAmount,
      absSlot,
    };
  }

  function measureScene() {
    fitPhone();
    sceneWidth = scene.clientWidth || phoneScreen.clientWidth || 370;
    sceneHeight = scene.clientHeight || phoneScreen.clientHeight || 780;
    spacing = clampSpacing(spacing);
  }

  function createCard(track) {
    const node = document.createElement("article");
    node.className = "track-card";
    node.dataset.id = track.id;
    node.setAttribute("role", "option");
    node.style.setProperty("--tint", track.hex);
    node.innerHTML = `
      <div class="card-glass"></div>
      <div class="card-sheen"></div>
      <div class="card-body">
        <div class="art">${artSvg(track.art, track.hex)}</div>
        <div class="copy">
          <p class="title">${track.title}</p>
          <p class="artist">${track.artist}</p>
          <p class="meta-row"><span>${track.duration}</span><span class="meta-dot"></span><span>NIGHT REEL</span></p>
        </div>
      </div>
    `;
    return node;
  }

  function applyPose(node, pose) {
    const faded = pose.opacity < 0.03;
    node.style.opacity = faded ? "0" : pose.opacity.toFixed(3);
    node.style.visibility = faded ? "hidden" : "visible";
    node.style.pointerEvents = faded ? "none" : "auto";
    node.style.zIndex = String(Math.round(5400 + pose.z * 14));
    node.style.transform = `translate3d(${pose.x.toFixed(2)}px, ${pose.y.toFixed(2)}px, ${pose.z.toFixed(2)}px) rotateX(${pose.rx.toFixed(2)}deg) rotateY(${pose.ry.toFixed(2)}deg) rotateZ(${pose.rz.toFixed(2)}deg) scale(${pose.scale.toFixed(3)})`;
    const sheen = node.querySelector(".card-sheen");
    if (sheen) {
      sheen.style.setProperty("--sheen-angle", `${118 + pose.ry * 0.8}deg`);
    }
  }

  function spacingWord() {
    const { height } = cardMetrics();
    const unit = effectiveSpacing() / Math.max(1, height);
    if (unit < 0.85) {
      return "紧凑";
    }
    if (unit < 1.3) {
      return "适中";
    }
    return "舒展";
  }

  function visualTwistDeg() {
    return clamp(Math.round((helixParams().twist * 180) / Math.PI), -TWIST_CAP_DEG, TWIST_CAP_DEG);
  }

  function shortestFocusPosition(targetIndex) {
    let best = targetIndex;
    let bestDist = Infinity;
    const startLap = Math.floor(position / COUNT) - 2;
    for (let lap = startLap; lap <= startLap + 5; lap += 1) {
      const candidate = targetIndex + lap * COUNT;
      const dist = Math.abs(candidate - position);
      if (dist < bestDist) {
        bestDist = dist;
        best = candidate;
      }
    }
    return best;
  }

  function easeInOutCubic(unit) {
    return unit < 0.5 ? 4 * unit * unit * unit : 1 - Math.pow(-2 * unit + 2, 3) / 2;
  }

  function focusCardByIndex(targetIndex) {
    if (targetIndex < 0 || targetIndex >= COUNT) {
      return;
    }
    if (focusAnim) {
      focusAnim.queuedIndex = targetIndex;
      return;
    }
    if (nearestIndex(position) === targetIndex && Math.abs(wrapSlot(targetIndex, position)) < 0.03) {
      return;
    }
    positionVelocity = 0;
    const destination = shortestFocusPosition(targetIndex);
    focusAnim = {
      from: position,
      to: destination,
      start: performance.now(),
      duration: reduceMotion ? 1 : FOCUS_DURATION,
      queuedIndex: null,
    };
  }

  function stepFocus(now) {
    if (!focusAnim) {
      return;
    }
    const unit = clamp((now - focusAnim.start) / Math.max(1, focusAnim.duration), 0, 1);
    position = lerp(focusAnim.from, focusAnim.to, reduceMotion ? 1 : easeInOutCubic(unit));
    if (unit >= 1) {
      position = focusAnim.to;
      const queued = focusAnim.queuedIndex;
      focusAnim = null;
      if (queued !== null) {
        focusCardByIndex(queued);
      }
    }
  }

  function resetTiltToZero() {
    tiltVelocity = 0;
    if (Math.abs(tiltAngle) < 0.12) {
      tiltAngle = 0;
      tiltResetAnim = null;
      return;
    }
    tiltResetAnim = {
      from: tiltAngle,
      start: performance.now(),
      duration: reduceMotion ? 1 : TILT_RESET_DURATION,
    };
  }

  function stepTiltReset(now) {
    if (!tiltResetAnim) {
      return;
    }
    const unit = clamp((now - tiltResetAnim.start) / Math.max(1, tiltResetAnim.duration), 0, 1);
    tiltAngle = lerp(tiltResetAnim.from, 0, reduceMotion ? 1 : easeInOutCubic(unit));
    if (unit >= 1) {
      tiltAngle = 0;
      tiltResetAnim = null;
    }
  }

  function ensureAudio() {
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!AudioCtx) {
      return null;
    }
    if (!audioContext) {
      audioContext = new AudioCtx();
    }
    if (audioContext.state === "suspended") {
      audioContext.resume();
    }
    return audioContext;
  }

  function playGearTick(kind) {
    if (reduceMotion || document.hidden) {
      return;
    }
    const ctx = audioContext;
    if (!ctx || ctx.state !== "running") {
      return;
    }
    const now = ctx.currentTime;
    const duration = 0.036;
    const sampleCount = Math.max(32, Math.floor(ctx.sampleRate * duration));
    const buffer = ctx.createBuffer(1, sampleCount, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    for (let index = 0; index < sampleCount; index += 1) {
      const env = Math.pow(1 - index / sampleCount, 2.6);
      data[index] = (Math.random() * 2 - 1) * env;
    }
    const noise = ctx.createBufferSource();
    noise.buffer = buffer;
    const band = ctx.createBiquadFilter();
    band.type = "bandpass";
    band.frequency.value = (kind === "tilt" ? 2350 : 1850) + Math.random() * 640;
    band.Q.value = 7.2;
    const high = ctx.createBiquadFilter();
    high.type = "highpass";
    high.frequency.value = 820;
    const noiseGain = ctx.createGain();
    noiseGain.gain.setValueAtTime(0.0001, now);
    noiseGain.gain.exponentialRampToValueAtTime(0.078, now + 0.003);
    noiseGain.gain.exponentialRampToValueAtTime(0.0001, now + duration);
    const ping = ctx.createOscillator();
    ping.type = "triangle";
    ping.frequency.setValueAtTime(kind === "tilt" ? 1620 : 1320, now);
    ping.frequency.exponentialRampToValueAtTime(680, now + 0.028);
    const pingFilter = ctx.createBiquadFilter();
    pingFilter.type = "highpass";
    pingFilter.frequency.value = 640;
    const pingGain = ctx.createGain();
    pingGain.gain.setValueAtTime(0.022, now);
    pingGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.03);
    noise.connect(band);
    band.connect(high);
    high.connect(noiseGain);
    noiseGain.connect(ctx.destination);
    ping.connect(pingFilter);
    pingFilter.connect(pingGain);
    pingGain.connect(ctx.destination);
    noise.start(now);
    ping.start(now);
    noise.stop(now + duration);
    ping.stop(now + 0.034);
    audioTickCount += 1;
    scene.dataset.audioTicks = String(audioTickCount);
  }

  function maybeTickGear() {
    if (document.hidden || reduceMotion || !audioContext) {
      return;
    }
    const now = performance.now();
    if (now - lastTickAt < TICK_MIN_MS) {
      return;
    }
    const movedSlot = Math.abs(position - lastTickPosition) >= POS_TICK_STEP;
    const movedTilt = Math.abs(tiltAngle - lastTickTilt) >= TILT_TICK_STEP;
    if (!movedSlot && !movedTilt) {
      return;
    }
    lastTickAt = now;
    lastTickPosition = position;
    lastTickTilt = tiltAngle;
    playGearTick(movedSlot ? "scroll" : "tilt");
  }

  function pickCardAt(clientX, clientY) {
    const stack = document.elementsFromPoint(clientX, clientY);
    let best = null;
    let bestZ = -Infinity;
    for (const node of stack) {
      const card = node.closest && node.closest(".track-card");
      if (!card || card.style.visibility === "hidden") {
        continue;
      }
      if (Number(card.style.opacity || 1) < 0.08) {
        continue;
      }
      const depth = Number(card.dataset.z || 0);
      if (depth >= bestZ) {
        bestZ = depth;
        best = card;
      }
    }
    return best;
  }

  function updateStatusLabel() {
    const visualDeg = visualTwistDeg();
    const flatten = helixParams().flatten;
    const flatPart = flatten > 0.02 ? ` · 压扁 ${Math.round(flatten * 100)}%` : "";
    const text = `拧度 ${visualDeg}°${flatPart} · 螺距 ${spacingWord()}`;
    if (text === lastStatusText) {
      return;
    }
    lastStatusText = text;
    statusLabel.textContent = text;
  }

  function updateNowPlaying(frontIndex) {
    if (frontIndex === lastFrontIndex) {
      return;
    }
    lastFrontIndex = frontIndex;
    const track = TRACKS[frontIndex];
    nowTitle.textContent = track.title;
    nowMeta.textContent = `${track.artist}  ·  ${track.duration}`;
    liveRegion.textContent = `${track.title}，${track.artist}`;
    const rgb = hexToRgb(track.hex);
    well.style.setProperty("--well-tint", `rgba(${rgb.r}, ${rgb.g}, ${rgb.b}, 0.2)`);
    cardNodes.forEach((node, index) => {
      node.classList.toggle("is-front", index === frontIndex);
    });
  }

  function render() {
    tiltAngle = clampTilt(tiltAngle);
    const frontIndex = nearestIndex(position);
    let frontPose = helixPose(0, frontIndex, frontIndex);
    let maxAbsX = 0;

    for (let index = 0; index < COUNT; index += 1) {
      const slot = wrapSlot(index, position);
      const pose = helixPose(slot, index, frontIndex);
      maxAbsX = Math.max(maxAbsX, Math.abs(pose.x));
      applyPose(cardNodes[index], pose);
      cardNodes[index].dataset.slot = slot.toFixed(3);
      cardNodes[index].dataset.rx = pose.rx.toFixed(2);
      cardNodes[index].dataset.ry = pose.ry.toFixed(2);
      cardNodes[index].dataset.rz = pose.rz.toFixed(2);
      cardNodes[index].dataset.y = pose.y.toFixed(2);
      cardNodes[index].dataset.x = pose.x.toFixed(2);
      cardNodes[index].dataset.z = pose.z.toFixed(2);
      cardNodes[index].dataset.theta = pose.theta.toFixed(3);
      cardNodes[index].removeAttribute("data-strand");
      cardNodes[index].removeAttribute("data-strand-phase");
      if (index === frontIndex) {
        frontPose = pose;
      }
    }

    updateNowPlaying(frontIndex);
    updateStatusLabel();
    scene.dataset.tilt = String(Math.round(tiltAngle));
    scene.dataset.curveAmount = frontPose.curveAmount.toFixed(3);
    scene.dataset.twist = frontPose.twist.toFixed(3);
    scene.dataset.helixRadius = String(Math.round(frontPose.helixRadius));
    scene.dataset.axisLean = frontPose.axisLean.toFixed(2);
    scene.dataset.spacing = String(Math.round(spacing));
    scene.dataset.effectiveSpacing = String(Math.round(effectiveSpacing()));
    scene.dataset.minSpacing = String(Math.round(minSpacing()));
    scene.dataset.position = position.toFixed(3);
    scene.dataset.front = TRACKS[frontIndex].id;
    scene.dataset.frontSlot = wrapSlot(frontIndex, position).toFixed(3);
    scene.dataset.frontY = frontPose.y.toFixed(2);
    scene.dataset.frontRx = frontPose.rx.toFixed(2);
    scene.dataset.frontRy = frontPose.ry.toFixed(2);
    scene.dataset.frontRz = frontPose.rz.toFixed(2);
    scene.dataset.maxAbsX = String(Math.round(maxAbsX));
    scene.dataset.visualTwistDeg = String(visualTwistDeg());
    scene.dataset.phaseDeg = scene.dataset.visualTwistDeg;
    scene.dataset.twistPerPitch = (Math.abs(frontPose.twist) / Math.max(1, effectiveSpacing())).toFixed(5);
    scene.dataset.cardsPerTurn = (Math.abs(frontPose.twist) > 0.05 ? (Math.PI * 2) / Math.abs(frontPose.twist) : 99).toFixed(2);
  }

  function sampleVelocity() {
    if (samples.length < 2) {
      return { x: 0, y: 0 };
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
      return { x: 0, y: 0 };
    }
    return {
      x: (latest.x - earliest.x) / elapsed,
      y: (latest.y - earliest.y) / elapsed,
    };
  }

  function recordSample(clientX, clientY, time) {
    samples.push({ x: clientX, y: clientY, t: time });
    if (samples.length > 8) {
      samples.shift();
    }
  }

  function applyAxisDelta(axis, sign, dx, dy) {
    if (axis === "vertical") {
      position += -dy / PIXELS_PER_SLOT;
      return;
    }
    if (axis === "horizontal") {
      tiltAngle = clampTilt(tiltAngle + dx / PIXELS_PER_TILT);
      return;
    }
    const amount = Math.hypot(dx, dy);
    spacing = clampSpacing(spacing + (sign * amount) / PIXELS_PER_SPACING);
  }

  function snapPosition(delta) {
    const nearest = Math.round(position);
    const diff = nearest - position;
    if (Math.abs(diff) < 0.002) {
      position = nearest;
      return;
    }
    const ease = reduceMotion ? 1 : 1 - Math.pow(0.86, delta / 16);
    position += diff * clamp(ease, 0.12, 1);
  }

  function isHoldingVertical() {
    const up = pressedKeys.has("ArrowUp") || pressedKeys.has("KeyI") || pressedKeys.has("PageUp");
    const down = pressedKeys.has("ArrowDown") || pressedKeys.has("KeyK") || pressedKeys.has("PageDown");
    const left = pressedKeys.has("ArrowLeft") || pressedKeys.has("KeyJ");
    const right = pressedKeys.has("ArrowRight") || pressedKeys.has("KeyL");
    return (up || down) && !left && !right;
  }

  function applyHeldKeys(delta) {
    const up = pressedKeys.has("ArrowUp") || pressedKeys.has("KeyI") || pressedKeys.has("PageUp");
    const down = pressedKeys.has("ArrowDown") || pressedKeys.has("KeyK") || pressedKeys.has("PageDown");
    const left = pressedKeys.has("ArrowLeft") || pressedKeys.has("KeyJ");
    const right = pressedKeys.has("ArrowRight") || pressedKeys.has("KeyL");
    const widen = pressedKeys.has("KeyE") || pressedKeys.has("Equal");
    const tighten = pressedKeys.has("KeyQ") || pressedKeys.has("Minus");
    const scale = delta / 16;

    if (widen) {
      spacing = clampSpacing(spacing + KEY_SPACING_STEP * 1.4 * scale);
    }
    if (tighten) {
      spacing = clampSpacing(spacing - KEY_SPACING_STEP * 1.4 * scale);
    }

    if ((up || down) && (left || right)) {
      const sign = right ? 1 : -1;
      spacing = clampSpacing(spacing + sign * KEY_SPACING_STEP * scale);
      return;
    }
    if (left || right) {
      tiltAngle = clampTilt(tiltAngle + (right ? 1 : -1) * KEY_TILT_STEP * scale);
      return;
    }
    if (up || down) {
      position += (down ? 1 : -1) * KEY_POSITION_STEP * scale;
    }
  }

  function step(now) {
    const delta = Math.min(32, now - lastFrameAt);
    lastFrameAt = now;

    if (!focusAnim && !tiltResetAnim) {
      applyHeldKeys(delta);
    }
    if (dragging) {
      if (focusAnim) {
        focusAnim = null;
      }
      if (tiltResetAnim) {
        tiltResetAnim = null;
      }
    }
    if (tiltResetAnim) {
      stepTiltReset(now);
    }
    if (focusAnim) {
      stepFocus(now);
    } else if (!dragging && !reduceMotion && !tiltResetAnim) {
      if (Math.abs(positionVelocity) > 0.0008) {
        position += positionVelocity * delta;
        positionVelocity *= Math.pow(0.9, delta / 16);
        if (Math.abs(positionVelocity) < 0.0008) {
          positionVelocity = 0;
        }
      }
      if (Math.abs(tiltVelocity) > 0.0008) {
        tiltAngle = clampTilt(tiltAngle + tiltVelocity * delta);
        tiltVelocity *= Math.pow(0.88, delta / 16);
        if (Math.abs(tiltVelocity) < 0.0008) {
          tiltVelocity = 0;
        }
      }
      if (Math.abs(spacingVelocity) > 0.004) {
        spacing = clampSpacing(spacing + spacingVelocity * delta);
        spacingVelocity *= Math.pow(0.9, delta / 16);
        if (Math.abs(spacingVelocity) < 0.004) {
          spacingVelocity = 0;
        }
      }
      if (!isHoldingVertical() && Math.abs(positionVelocity) < 0.0012) {
        snapPosition(delta);
      }
    } else if (!dragging && reduceMotion) {
      position = Math.round(position);
    }

    maybeTickGear();
    render();
    requestAnimationFrame(step);
  }

  function gestureTarget() {
    return phoneScreen || scene;
  }

  function onPointerDown(event) {
    if (event.pointerType === "mouse" && event.button !== 0) {
      return;
    }
    ensureAudio();
    dragging = true;
    positionVelocity = 0;
    tiltVelocity = 0;
    spacingVelocity = 0;
    gestureAxis = null;
    spacingSign = 0;
    pointerId = event.pointerId;
    lastClientX = event.clientX;
    lastClientY = event.clientY;
    lockOriginX = event.clientX;
    lockOriginY = event.clientY;
    lastMoveAt = event.timeStamp;
    samples = [];
    recordSample(event.clientX, event.clientY, event.timeStamp);
    scene.classList.add("is-dragging");
    hint.classList.add("is-hidden");
    try {
      gestureTarget().setPointerCapture(event.pointerId);
    } catch (_error) {
      /* synthetic or already-released pointers */
    }
    event.preventDefault();
  }

  function onPointerMove(event) {
    if (!dragging || event.pointerId !== pointerId) {
      return;
    }
    const dx = event.clientX - lastClientX;
    const dy = event.clientY - lastClientY;
    if (!gestureAxis) {
      const lockDx = event.clientX - lockOriginX;
      const lockDy = event.clientY - lockOriginY;
      if (Math.hypot(lockDx, lockDy) >= LOCK_PIXELS) {
        const classified = axisFromSector(classifySector(lockDx, lockDy));
        gestureAxis = classified.axis;
        spacingSign = classified.spacingSign;
      }
    }
    if (gestureAxis) {
      applyAxisDelta(gestureAxis, spacingSign, dx, dy);
    }
    lastClientX = event.clientX;
    lastClientY = event.clientY;
    lastMoveAt = event.timeStamp;
    recordSample(event.clientX, event.clientY, event.timeStamp);
    event.preventDefault();
  }

  function onPointerUp(event) {
    if (!dragging || event.pointerId !== pointerId) {
      return;
    }
    const travel = Math.hypot(event.clientX - lockOriginX, event.clientY - lockOriginY);
    const wasClick = !gestureAxis && travel < CLICK_SLOP;
    dragging = false;
    pointerId = null;
    scene.classList.remove("is-dragging");
    if (wasClick) {
      positionVelocity = 0;
      tiltVelocity = 0;
      spacingVelocity = 0;
      const card = pickCardAt(event.clientX, event.clientY);
      const tap = { t: event.timeStamp, x: event.clientX, y: event.clientY, onCard: Boolean(card) };
      const isDouble =
        lastTap &&
        tap.t - lastTap.t <= DOUBLE_MS &&
        Math.hypot(tap.x - lastTap.x, tap.y - lastTap.y) <= DOUBLE_SLOP;
      if (card) {
        lastTap = tap;
        const index = cardNodes.indexOf(card);
        if (index >= 0) {
          focusCardByIndex(index);
        }
      } else if (isDouble && !lastTap.onCard) {
        lastTap = null;
        resetTiltToZero();
      } else {
        lastTap = tap;
      }
      gestureAxis = null;
      return;
    }
    if (reduceMotion || event.timeStamp - lastMoveAt > 140) {
      positionVelocity = 0;
      tiltVelocity = 0;
      spacingVelocity = 0;
      gestureAxis = null;
      return;
    }
    const sampled = sampleVelocity();
    if (gestureAxis === "vertical") {
      positionVelocity = -sampled.y / PIXELS_PER_SLOT;
    } else if (gestureAxis === "horizontal") {
      tiltVelocity = sampled.x / PIXELS_PER_TILT;
    } else if (gestureAxis === "spacing") {
      spacingVelocity = (spacingSign * Math.hypot(sampled.x, sampled.y)) / PIXELS_PER_SPACING;
    }
    gestureAxis = null;
  }

  function onKeyDown(event) {
    const watched = [
      "ArrowUp",
      "ArrowDown",
      "ArrowLeft",
      "ArrowRight",
      "PageUp",
      "PageDown",
      "KeyQ",
      "KeyE",
      "KeyI",
      "KeyJ",
      "KeyK",
      "KeyL",
      "Equal",
      "Minus",
    ];
    const code = event.code;
    if (!watched.includes(event.key) && !watched.includes(code)) {
      return;
    }
    event.preventDefault();
    pressedKeys.add(event.key);
    pressedKeys.add(code);
    hint.classList.add("is-hidden");
  }

  function onKeyUp(event) {
    pressedKeys.delete(event.key);
    pressedKeys.delete(event.code);
  }

  function build() {
    TRACKS.forEach((track) => {
      const node = createCard(track);
      cardNodes.push(node);
      deck.appendChild(node);
    });
    scene.tabIndex = 0;
    fitPhone();
    measureScene();
    spacing = minSpacing();
    scene.__setHelix = (nextTilt, nextSpacing) => {
      if (Number.isFinite(nextTilt)) {
        tiltAngle = clampTilt(nextTilt);
      }
      if (Number.isFinite(nextSpacing)) {
        spacing = clampSpacing(nextSpacing);
      }
    };
    scene.__focusCard = focusCardByIndex;
    scene.__resetTilt = resetTiltToZero;
    Object.defineProperty(scene, "__audioTicks", {
      get() {
        return audioTickCount;
      },
    });
    Object.defineProperty(scene, "__audioState", {
      get() {
        return audioContext ? audioContext.state : "none";
      },
    });
    syncClock();
    updateNowPlaying(0);
    render();
  }

  reduceMotionQuery.addEventListener("change", (event) => {
    reduceMotion = event.matches;
    positionVelocity = 0;
    tiltVelocity = 0;
    spacingVelocity = 0;
  });

  const surface = gestureTarget();
  surface.addEventListener("pointerdown", onPointerDown);
  surface.addEventListener("pointermove", onPointerMove);
  surface.addEventListener("pointerup", onPointerUp);
  surface.addEventListener("pointercancel", onPointerUp);
  window.addEventListener("keydown", onKeyDown);
  window.addEventListener("keyup", onKeyUp);
  window.addEventListener("blur", () => pressedKeys.clear());
  window.addEventListener("resize", measureScene);
  setInterval(syncClock, 30000);

  build();
  lastFrameAt = performance.now();
  requestAnimationFrame(step);
})();

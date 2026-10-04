(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ── Particle wave background ─────────────────────────────────────────────
  const canvas = document.getElementById("particles");
  const ctx = canvas?.getContext("2d");

  let particles = [];
  let width = 0;
  let height = 0;
  let dpr = 1;
  let particleRaf = 0;
  let time = 0;

  function resizeCanvas() {
    if (!canvas || !ctx) return;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = window.innerWidth;
    height = window.innerHeight;
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    seedParticles();
  }

  function seedParticles() {
    const count = Math.min(140, Math.floor((width * height) / 14000));
    particles = Array.from({ length: count }, (_, i) => ({
      x: Math.random() * width,
      y: Math.random() * height,
      baseY: 0,
      size: 0.6 + Math.random() * 1.8,
      speed: 0.15 + Math.random() * 0.45,
      phase: Math.random() * Math.PI * 2,
      amp: 12 + Math.random() * 36,
      opacity: 0.12 + Math.random() * 0.35,
      drift: (Math.random() - 0.5) * 0.25,
    }));
    particles.forEach((p) => {
      p.baseY = p.y;
    });
  }

  function drawParticles(ts) {
    if (!ctx) return;
    time = ts * 0.001;
    ctx.clearRect(0, 0, width, height);

    for (const p of particles) {
      const wave =
        Math.sin(time * 0.55 + p.phase + p.x * 0.004) * p.amp +
        Math.sin(time * 0.9 + p.phase * 1.7) * (p.amp * 0.35);

      p.x += p.speed + Math.sin(time + p.phase) * 0.08;
      p.y = p.baseY + wave;
      p.baseY += p.drift;

      if (p.x > width + 8) {
        p.x = -8;
        p.baseY = Math.random() * height;
      }
      if (p.baseY < -40) p.baseY = height + 20;
      if (p.baseY > height + 40) p.baseY = -20;

      ctx.beginPath();
      ctx.fillStyle = `rgba(255, 255, 255, ${p.opacity})`;
      ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
      ctx.fill();
    }

    // Soft connecting lines for nearby particles (subtle wave mesh)
    ctx.lineWidth = 0.6;
    for (let i = 0; i < particles.length; i++) {
      const a = particles[i];
      for (let j = i + 1; j < particles.length; j++) {
        const b = particles[j];
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        const dist = Math.hypot(dx, dy);
        if (dist < 90) {
          const alpha = (1 - dist / 90) * 0.08;
          ctx.strokeStyle = `rgba(255, 255, 255, ${alpha})`;
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x, b.y);
          ctx.stroke();
        }
      }
    }

    particleRaf = requestAnimationFrame(drawParticles);
  }

  if (canvas && ctx && !reduceMotion) {
    resizeCanvas();
    window.addEventListener("resize", resizeCanvas);
    particleRaf = requestAnimationFrame(drawParticles);
  } else if (canvas && ctx) {
    resizeCanvas();
    // Static soft dots when reduced motion is preferred
    for (const p of particles) {
      ctx.beginPath();
      ctx.fillStyle = `rgba(255, 255, 255, ${p.opacity * 0.7})`;
      ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // ── Focus ball demo (mirrors StudyingView metrics) ───────────────────────
  const ballEl = document.getElementById("focus-ball");
  const emptyEl = document.getElementById("ball-empty");
  const glowEl = document.querySelector(".ball-glow");
  const ringEl = document.querySelector(".focus-ring");
  const timerEl = document.querySelector(".timer-progress");
  const statusEl = document.getElementById("status-text");
  const driftsEl = document.getElementById("metric-drifts");
  const ballMetricEl = document.getElementById("metric-ball");
  const focusEl = document.getElementById("metric-focus");

  if (!ballEl || !driftsEl || !ballMetricEl || !focusEl) return;

  const CIRC = 2 * Math.PI * 120; // r=120
  if (timerEl) {
    timerEl.style.strokeDasharray = String(CIRC);
  }

  let ballSize = 1;
  let warningSize = 0;
  let isWarning = false;
  let drifts = 0;
  let focusScore = 1;
  let timerProgress = 1;
  let mode = "focus"; // focus | shrink | recover | warning | hold
  let modeUntil = performance.now() + 2800;
  let lastTs = performance.now();

  function setWarningUI(on) {
    ballEl.classList.toggle("is-warning", on);
    glowEl?.classList.toggle("is-warning", on);
    ringEl?.classList.toggle("is-warning", on);
    timerEl?.classList.toggle("is-warning", on);
    statusEl?.classList.toggle("is-warning", on);
  }

  function pickNextMode(now) {
    if (mode === "warning") {
      mode = "hold";
      modeUntil = now + 1600;
      return;
    }
    if (mode === "hold") {
      // Come back: clear red, recover white
      isWarning = false;
      warningSize = 0;
      setWarningUI(false);
      mode = "recover";
      modeUntil = now + 3200 + Math.random() * 1200;
      statusEl.textContent = "Focusing on: Calculus";
      return;
    }

    const roll = Math.random();
    if (ballSize < 0.08 && roll < 0.55) {
      // White gone → red warning expands
      isWarning = true;
      warningSize = 0.05;
      ballSize = 0;
      setWarningUI(true);
      drifts += 1;
      mode = "warning";
      modeUntil = now + 2800 + Math.random() * 1200;
      statusEl.textContent = "Attention fading… come back";
      return;
    }

    if (roll < 0.42) {
      mode = "shrink";
      modeUntil = now + 2200 + Math.random() * 2200;
      if (Math.random() < 0.55) drifts += 1;
      statusEl.textContent = "Drift detected";
    } else if (roll < 0.78) {
      mode = "recover";
      modeUntil = now + 2400 + Math.random() * 1800;
      statusEl.textContent = "Focusing on: Calculus";
    } else {
      mode = "focus";
      modeUntil = now + 1800 + Math.random() * 1600;
      statusEl.textContent = "Focusing on: Calculus";
    }
  }

  function tick(ts) {
    const dt = Math.min(0.05, (ts - lastTs) / 1000);
    lastTs = ts;

    if (ts >= modeUntil) {
      pickNextMode(ts);
    }

    if (isWarning) {
      // Red expands in stepped stages (like the app)
      const grow = mode === "warning" ? 0.38 : 0.08;
      warningSize = Math.min(1, warningSize + grow * dt);
      focusScore = Math.max(0.05, focusScore - 0.35 * dt);
      timerProgress = Math.max(0.08, timerProgress - 0.015 * dt);
    } else if (mode === "shrink") {
      // Dramatic shrink
      ballSize = Math.max(0, ballSize - (0.22 + Math.random() * 0.08) * dt);
      focusScore = Math.max(0.12, focusScore - 0.18 * dt);
      timerProgress = Math.max(0.15, timerProgress - 0.012 * dt);
    } else if (mode === "recover") {
      ballSize = Math.min(1, ballSize + 0.28 * dt);
      focusScore = Math.min(1, focusScore + 0.16 * dt);
      timerProgress = Math.min(1, timerProgress + 0.01 * dt);
    } else {
      // Idle focus: gentle breathing around full
      ballSize = Math.min(1, ballSize + 0.12 * dt);
      focusScore = Math.min(1, focusScore + 0.05 * dt);
      const breath = 0.97 + Math.sin(ts * 0.0022) * 0.03;
      ballSize = Math.min(1, Math.max(ballSize, breath * 0.98));
    }

    const displaySize = isWarning ? warningSize : ballSize;
    const scale = Math.max(0.001, displaySize);

    ballEl.style.transform = `scale(${scale})`;
    ballEl.style.opacity = displaySize <= 0.02 && !isWarning ? "0" : "1";

    if (emptyEl) {
      emptyEl.classList.toggle("visible", displaySize <= 0.02 && !isWarning);
    }

    if (glowEl) {
      glowEl.style.opacity = String(0.35 + 0.65 * displaySize);
    }

    if (timerEl) {
      timerEl.style.strokeDashoffset = String(CIRC * (1 - timerProgress));
    }

    // Match StudyingView: Drifts / Ball / Focus
    driftsEl.textContent = String(drifts);
    ballMetricEl.textContent = `${Math.round(displaySize * 100)}%`;
    focusEl.textContent = `${Math.round(focusScore * 100)}%`;

    if (!reduceMotion) {
      requestAnimationFrame(tick);
    }
  }

  // Initial paint
  ballEl.style.transform = "scale(1)";
  if (timerEl) timerEl.style.strokeDashoffset = "0";

  if (reduceMotion) {
    // Static mid-session snapshot
    ballEl.style.transform = "scale(0.72)";
    driftsEl.textContent = "2";
    ballMetricEl.textContent = "72%";
    focusEl.textContent = "81%";
  } else {
    requestAnimationFrame(tick);
  }

  // Avoid unused warning if canvas loop never started
  void particleRaf;
})();

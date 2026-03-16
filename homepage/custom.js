(async function () {
  const INTERVAL_MS = 10000;
  const FADE_MS = 2000;
  const PRELOAD_AHEAD = 3;

  // Fetch image manifest
  let images;
  try {
    const res = await fetch("/images/images.json?t=" + Date.now());
    images = await res.json();
  } catch (e) {
    console.log("bg-rotate: failed to fetch images.json", e);
    return;
  }
  if (!images.length) {
    console.log("bg-rotate: no images found");
    return;
  }

  // Shuffle (Fisher-Yates)
  for (let i = images.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [images[i], images[j]] = [images[j], images[i]];
  }

  // Find Homepage's background div
  const bgDiv = [...document.querySelectorAll("*")].find((el) =>
    getComputedStyle(el).backgroundImage.includes("/images/")
  );
  if (!bgDiv) {
    console.log("bg-rotate: background div not found");
    return;
  }

  const pos = getComputedStyle(bgDiv).position;
  if (pos === "static") bgDiv.style.position = "relative";
  bgDiv.style.overflow = "hidden";

  // Recreate the dark overlay that Homepage normally bakes into the background
  const gradient = document.createElement("div");
  gradient.style.cssText =
    "position:absolute;inset:0;background:rgba(10,10,10,0.7);z-index:1;";
  bgDiv.appendChild(gradient);

  let current = 0;
  let currentEl = null;

  // Preload helper
  function preload(src) {
    return new Promise((resolve) => {
      const img = new Image();
      img.onload = resolve;
      img.onerror = resolve;
      img.src = src;
    });
  }

  // Preload first batch
  for (let i = 0; i < Math.min(PRELOAD_AHEAD + 1, images.length); i++) {
    await preload(images[i]);
  }

  function show(index, fade) {
    const el = document.createElement("div");
    el.style.cssText = `
      position:absolute;inset:0;z-index:0;
      background:url("${images[index]}") center/cover no-repeat;
      opacity:0;
    `;
    bgDiv.insertBefore(el, gradient);

    if (fade) {
      el.getBoundingClientRect();
      el.style.transition = `opacity ${FADE_MS}ms ease-in-out`;
    }
    el.style.opacity = "1";

    // Remove original background on first show
    if (!currentEl) {
      bgDiv.style.backgroundImage = "none";
    }

    const old = currentEl;
    if (old) {
      setTimeout(() => old.remove(), fade ? FADE_MS : 0);
    }
    currentEl = el;
  }

  // Show first image instantly
  show(0, false);

  async function next() {
    current = (current + 1) % images.length;
    show(current, true);

    // Preload upcoming images
    const ahead = (current + PRELOAD_AHEAD) % images.length;
    preload(images[ahead]);
  }

  setInterval(next, INTERVAL_MS);

  console.log(`bg-rotate: started with ${images.length} images, ${INTERVAL_MS / 1000}s interval`);
})();

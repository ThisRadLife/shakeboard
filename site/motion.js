(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (reduceMotion.matches || !("IntersectionObserver" in window)) return;

  const root = document.documentElement;
  root.classList.add("js-motion");

  const features = [...document.querySelectorAll(".feature-sticker")];
  const frames = [...document.querySelectorAll(".punk-frame")];
  const privacySections = [...document.querySelectorAll(".privacy-copy section")];
  const arrows = [...document.querySelectorAll(".arrow")];
  const targets = [...features, ...frames, ...privacySections, ...arrows];

  features.forEach((card, index) => {
    card.style.setProperty("--reveal-delay", `${(index % 4) * 90}ms`);
  });
  frames.forEach((frame, index) => {
    frame.style.setProperty("--reveal-delay", `${(index % 2) * 180}ms`);
  });

  const observer = new IntersectionObserver((entries) => {
    if (document.hidden) return;
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-in");
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.3 });

  targets.forEach((target) => observer.observe(target));
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      targets.filter((target) => !target.classList.contains("is-in"))
        .forEach((target) => observer.observe(target));
    }
  });
})();

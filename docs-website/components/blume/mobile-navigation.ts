const desktop = window.matchMedia("(min-width: 64rem)");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const root = document.documentElement;
const header = document.querySelector<HTMLElement>("[data-blume-header]");
const drawer = document.querySelector<HTMLElement>("[data-blume-nav-drawer]");
const gestureZone = document.querySelector<HTMLElement>(
  "[data-blume-nav-gesture-zone]"
);
const toggle = header?.querySelector<HTMLButtonElement>(
  "[data-blume-nav-toggle]"
);
const overlay = [...document.querySelectorAll<HTMLButtonElement>(
  "[data-blume-nav-toggle]"
)].find((button) => !button.closest("[data-blume-header]"));

const DRAWER_ID = "blume-mobile-navigation";
const DIRECTION_LOCK_PX = 8;
const MINIMUM_TRAVEL_PX = 24;
const DIRECTION_RATIO = 1.25;
const PROJECTION_MS = 180;
const VELOCITY_WINDOW_MS = 80;
const MINIMUM_SETTLE_MS = 120;
const MAXIMUM_SETTLE_MS = 220;
const MINIMUM_SETTLE_VELOCITY = 0.6;
const CLICK_SUPPRESSION_MS = 500;

interface VelocitySample {
  time: number;
  x: number;
}

interface DragState {
  active: boolean;
  initialOpen: boolean;
  pointerId: number;
  samples: VelocitySample[];
  source: HTMLElement;
  startX: number;
  startTranslation: number;
  startY: number;
  translation: number;
  velocityX: number;
  width: number;
}

let drag: DragState | undefined;
let frame: number | undefined;
let headerFrame: number | undefined;
let closeTimer: number | undefined;
let clickSuppressionTimer: number | undefined;
let suppressedClickSurface: HTMLElement | undefined;
let locked = false;
let previousBodyOverflow = "";
let returnFocus: HTMLElement | null = null;

const isOpen = () => root.hasAttribute("data-blume-nav-open");

const clamp = (value: number, minimum: number, maximum: number) =>
  Math.max(minimum, Math.min(maximum, value));

const clearClickSuppression = () => {
  window.clearTimeout(clickSuppressionTimer);
  clickSuppressionTimer = undefined;
  suppressedClickSurface = undefined;
};

const suppressNextClickFrom = (surface: HTMLElement) => {
  clearClickSuppression();
  suppressedClickSurface = surface;
  clickSuppressionTimer = window.setTimeout(
    clearClickSuppression,
    CLICK_SUPPRESSION_MS
  );
};

const updateToggle = (open: boolean) => {
  if (!toggle) {
    return;
  }

  toggle.setAttribute("aria-expanded", String(open));
  toggle.setAttribute(
    "aria-label",
    open
      ? (toggle.dataset.blumeNavCloseLabel ?? "Close navigation")
      : (toggle.dataset.blumeNavOpenLabel ?? "Toggle navigation")
  );
};

const measureHeader = () => {
  if (headerFrame !== undefined) {
    return;
  }

  headerFrame = requestAnimationFrame(() => {
    headerFrame = undefined;
    if (header) {
      root.style.setProperty(
        "--blume-drawer-top",
        `${Math.max(0, header.getBoundingClientRect().bottom)}px`
      );
    }
  });
};

const lockScroll = () => {
  if (locked) {
    return;
  }

  previousBodyOverflow = document.body.style.overflow;
  document.body.style.overflow = "hidden";
  locked = true;
};

const unlockScroll = () => {
  if (!locked) {
    return;
  }

  document.body.style.overflow = previousBodyOverflow;
  locked = false;
};

const clearDragStyles = () => {
  root.removeAttribute("data-blume-nav-dragging");
  root.style.removeProperty("--blume-nav-drag-x");
  root.style.removeProperty("--blume-nav-overlay-progress");
};

const setSettleDuration = (duration: number) => {
  root.style.setProperty(
    "--blume-nav-settle-ms",
    `${Math.max(0, Math.round(duration))}ms`
  );
};

const finishClosing = (restoreFocus: boolean) => {
  window.clearTimeout(closeTimer);
  closeTimer = undefined;
  root.removeAttribute("data-blume-nav-open");
  root.removeAttribute("data-blume-nav-closing");
  clearDragStyles();
  unlockScroll();

  if (
    restoreFocus &&
    toggle &&
    returnFocus &&
    (drawer?.contains(document.activeElement) ||
      document.activeElement === document.body)
  ) {
    toggle.focus({ preventScroll: true });
  }
  returnFocus = null;
};

const openNavigation = (
  focusDrawer = false,
  settleDuration = MAXIMUM_SETTLE_MS
) => {
  window.clearTimeout(closeTimer);
  closeTimer = undefined;
  setSettleDuration(settleDuration);
  root.removeAttribute("data-blume-nav-closing");
  clearDragStyles();
  measureHeader();
  root.setAttribute("data-blume-nav-open", "");
  lockScroll();
  updateToggle(true);

  if (focusDrawer && drawer) {
    returnFocus =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : toggle ?? null;
    requestAnimationFrame(() => {
      drawer
        .querySelector<HTMLElement>(
          'a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])'
        )
        ?.focus({ preventScroll: true });
    });
  }
};

const closeNavigation = ({
  immediate = false,
  restoreFocus = false,
  settleDuration = MAXIMUM_SETTLE_MS,
}: {
  immediate?: boolean;
  restoreFocus?: boolean;
  settleDuration?: number;
} = {}) => {
  if (!(isOpen() || root.hasAttribute("data-blume-nav-dragging"))) {
    return;
  }

  const duration = immediate ? 0 : settleDuration;
  setSettleDuration(duration);
  updateToggle(false);
  root.setAttribute("data-blume-nav-closing", "");
  root.removeAttribute("data-blume-nav-dragging");
  root.style.setProperty("--blume-nav-overlay-progress", "0");

  if (immediate || reducedMotion.matches) {
    finishClosing(restoreFocus);
    return;
  }

  closeTimer = window.setTimeout(
    () => finishClosing(restoreFocus),
    duration
  );
};

const applyDrag = () => {
  frame = undefined;
  if (!drag) {
    return;
  }

  const progress = 1 - drag.translation / drag.width;
  root.style.setProperty("--blume-nav-drag-x", `${drag.translation}px`);
  root.style.setProperty(
    "--blume-nav-overlay-progress",
    String(Math.max(0, Math.min(1, progress)))
  );
};

const scheduleDrag = () => {
  if (frame === undefined) {
    frame = requestAnimationFrame(applyDrag);
  }
};

const getDrawerTranslation = (width: number) => {
  if (!drawer) {
    return isOpen() ? 0 : width;
  }

  const transform = window.getComputedStyle(drawer).transform;
  if (transform === "none") {
    return isOpen() ? 0 : width;
  }

  try {
    return clamp(new DOMMatrixReadOnly(transform).m41, 0, width);
  } catch {
    const values = transform
      .slice(transform.indexOf("(") + 1, -1)
      .split(",")
      .map(Number);
    const translation = values?.length === 6 ? values[4] : values?.[12];
    return clamp(translation ?? (isOpen() ? 0 : width), 0, width);
  }
};

const updateVelocity = (event: PointerEvent) => {
  if (!drag) {
    return;
  }

  const coalesced = event.getCoalescedEvents?.() ?? [];
  const points = [...coalesced];
  const latest = points.at(-1);
  if (
    !latest ||
    latest.timeStamp !== event.timeStamp ||
    latest.clientX !== event.clientX
  ) {
    points.push(event);
  }

  for (const point of points) {
    if (Number.isFinite(point.clientX) && Number.isFinite(point.timeStamp)) {
      drag.samples.push({ time: point.timeStamp, x: point.clientX });
    }
  }

  const newestTime = drag.samples.at(-1)?.time ?? event.timeStamp;
  const cutoffTime = newestTime - VELOCITY_WINDOW_MS;
  while (
    drag.samples.length > 0 &&
    drag.samples[0].time < cutoffTime
  ) {
    drag.samples.shift();
  }

  const first = drag.samples[0];
  const last = drag.samples.at(-1);
  if (first && last && last.time > first.time) {
    drag.velocityX = (last.x - first.x) / (last.time - first.time);
  } else {
    drag.velocityX = 0;
  }
};

const getSettleDuration = (
  translation: number,
  targetTranslation: number,
  velocityX: number,
  width: number
) => {
  if (reducedMotion.matches) {
    return 0;
  }

  const remaining = Math.abs(targetTranslation - translation);
  if (remaining < 1 || width <= 0) {
    return 0;
  }

  const distanceDuration = MAXIMUM_SETTLE_MS * (remaining / width);
  const velocityDuration =
    remaining / Math.max(Math.abs(velocityX), MINIMUM_SETTLE_VELOCITY);
  return clamp(
    Math.min(distanceDuration, velocityDuration),
    MINIMUM_SETTLE_MS,
    MAXIMUM_SETTLE_MS
  );
};

const beginDrag = (event: PointerEvent, initialOpen: boolean) => {
  clearClickSuppression();
  if (
    desktop.matches ||
    !event.isPrimary ||
    event.pointerType === "mouse" ||
    (initialOpen ? !isOpen() : isOpen())
  ) {
    return;
  }

  const source = event.currentTarget;
  if (!(source instanceof HTMLElement) || !drawer) {
    return;
  }

  const width = drawer.getBoundingClientRect().width;
  if (width <= 0) {
    return;
  }

  drag = {
    active: false,
    initialOpen,
    pointerId: event.pointerId,
    samples: [{ time: event.timeStamp, x: event.clientX }],
    source,
    startX: event.clientX,
    startTranslation: initialOpen ? 0 : width,
    startY: event.clientY,
    translation: initialOpen ? 0 : width,
    velocityX: 0,
    width,
  };
};

const moveDrag = (event: PointerEvent) => {
  if (!drag || drag.pointerId !== event.pointerId) {
    return;
  }

  const dx = event.clientX - drag.startX;
  const dy = event.clientY - drag.startY;

  if (!drag.active) {
    const horizontal = Math.abs(dx);
    const vertical = Math.abs(dy);
    if (Math.max(horizontal, vertical) < DIRECTION_LOCK_PX) {
      return;
    }
    if (
      horizontal <= vertical * DIRECTION_RATIO ||
      (drag.initialOpen ? dx <= 0 : dx >= 0)
    ) {
      suppressNextClickFrom(drag.source);
      drag = undefined;
      return;
    }

    const currentTranslation = getDrawerTranslation(drag.width);
    drag.active = true;
    drag.startTranslation = currentTranslation;
    drag.translation = clamp(currentTranslation + dx, 0, drag.width);
    drag.source.setPointerCapture(event.pointerId);
    openNavigation(false);
    root.setAttribute("data-blume-nav-dragging", "");
    root.removeAttribute("data-blume-nav-closing");
    suppressNextClickFrom(drag.source);
    applyDrag();
  }

  event.preventDefault();
  updateVelocity(event);
  drag.translation = clamp(
    drag.startTranslation + dx,
    0,
    drag.width
  );
  scheduleDrag();
};

const endDrag = (event: PointerEvent, cancelled = false) => {
  if (!drag || drag.pointerId !== event.pointerId) {
    return;
  }

  const finished = drag;
  if (frame !== undefined) {
    cancelAnimationFrame(frame);
    frame = undefined;
    applyDrag();
  }
  drawer?.getBoundingClientRect();
  drag = undefined;

  if (!finished.active) {
    return;
  }

  if (finished.source.hasPointerCapture(event.pointerId)) {
    finished.source.releasePointerCapture(event.pointerId);
  }

  const travelled = Math.abs(event.clientX - finished.startX);
  const projectedTranslation = Math.max(
    0,
    Math.min(
      finished.width,
      finished.translation + finished.velocityX * PROJECTION_MS
    )
  );
  const projectedProgress = 1 - projectedTranslation / finished.width;
  const shouldOpen =
    cancelled || travelled < MINIMUM_TRAVEL_PX
      ? finished.initialOpen
      : projectedProgress >= 0.5;
  const settleDuration = getSettleDuration(
    finished.translation,
    shouldOpen ? 0 : finished.width,
    finished.velocityX,
    finished.width
  );

  if (shouldOpen) {
    openNavigation(false, settleDuration);
  } else {
    closeNavigation({
      restoreFocus: finished.initialOpen,
      settleDuration,
    });
  }
};

const handlePointerCancel = (event: PointerEvent) => endDrag(event, true);

const cancelActiveDrag = () => {
  if (!drag) {
    return;
  }

  const cancelled = drag;
  drag = undefined;
  if (frame !== undefined) {
    cancelAnimationFrame(frame);
    frame = undefined;
  }
  if (cancelled.source.hasPointerCapture(cancelled.pointerId)) {
    cancelled.source.releasePointerCapture(cancelled.pointerId);
  }

  if (cancelled.initialOpen) {
    openNavigation(false, 0);
  } else {
    closeNavigation({ immediate: true });
  }
};

const attachGestureSurface = (
  surface: HTMLElement | undefined,
  initialOpen: boolean
) => {
  if (!surface) {
    return;
  }

  surface.addEventListener("pointerdown", (event) =>
    beginDrag(event, initialOpen)
  );
  surface.addEventListener("pointermove", moveDrag);
  surface.addEventListener("pointerup", endDrag);
  surface.addEventListener("pointercancel", handlePointerCancel);
  surface.addEventListener("lostpointercapture", handlePointerCancel);
};

if (drawer && toggle) {
  drawer.id = DRAWER_ID;
  toggle.setAttribute("aria-controls", DRAWER_ID);
  updateToggle(false);
  measureHeader();

  attachGestureSurface(gestureZone ?? undefined, false);
  attachGestureSurface(drawer, true);
  attachGestureSurface(overlay, true);

  document.addEventListener(
    "click",
    (event) => {
      const target = event.target;
      if (
        !suppressedClickSurface ||
        !(target instanceof Node) ||
        !suppressedClickSurface.contains(target)
      ) {
        return;
      }

      event.preventDefault();
      event.stopImmediatePropagation();
      clearClickSuppression();
    },
    true
  );

  document.addEventListener("click", (event) => {
    const target = event.target;
    if (!(target instanceof Element)) {
      return;
    }

    const themeToggle = target.closest("[data-blume-theme-toggle]");
    if (themeToggle) {
      const next = root.dataset.theme === "dark" ? "light" : "dark";
      const style = document.createElement("style");
      style.textContent =
        "*,*::before,*::after{transition:none!important}";
      document.head.appendChild(style);
      root.dataset.theme = next;
      localStorage.setItem("blume-theme", next);
      window.getComputedStyle(root).opacity;
      window.setTimeout(() => style.remove(), 1);
      return;
    }

    const navigationToggle = target.closest("[data-blume-nav-toggle]");
    if (navigationToggle) {
      if (isOpen()) {
        closeNavigation({
          restoreFocus: navigationToggle !== overlay,
        });
      } else {
        openNavigation(navigationToggle === toggle);
      }
      return;
    }

    const bannerDismiss = target.closest("[data-blume-banner-dismiss]");
    if (bannerDismiss) {
      const banner = bannerDismiss.closest("[data-blume-banner]");
      const key = banner?.getAttribute("data-banner-key");
      if (key) {
        localStorage.setItem(`blume-banner:${key}`, "1");
      }
      root.setAttribute("data-blume-banner-hidden", "");
      measureHeader();
      return;
    }

    if (isOpen() && drawer.contains(target) && target.closest("a[href]")) {
      closeNavigation({ immediate: true });
    }
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && isOpen()) {
      event.preventDefault();
      closeNavigation({ restoreFocus: true });
    }
  });

  const handleViewportChange = () => {
    cancelActiveDrag();
    if (desktop.matches) {
      closeNavigation({ immediate: true });
    }
    measureHeader();
  };

  window.addEventListener("resize", handleViewportChange);
  window.addEventListener("orientationchange", handleViewportChange);
  window.addEventListener("scroll", measureHeader, { passive: true });
  window.visualViewport?.addEventListener("resize", measureHeader);
  window.visualViewport?.addEventListener("scroll", measureHeader);
  window.addEventListener("pagehide", () => {
    cancelActiveDrag();
    closeNavigation({ immediate: true });
  });
  window.addEventListener("pageshow", () => {
    cancelActiveDrag();
    closeNavigation({ immediate: true });
    measureHeader();
  });
}

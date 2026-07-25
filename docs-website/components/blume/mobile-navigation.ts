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
const SETTLE_MS = 220;

interface DragState {
  active: boolean;
  initialOpen: boolean;
  lastTime: number;
  lastX: number;
  pointerId: number;
  source: HTMLElement;
  startX: number;
  startY: number;
  translation: number;
  velocityX: number;
  width: number;
}

let drag: DragState | undefined;
let frame: number | undefined;
let headerFrame: number | undefined;
let closeTimer: number | undefined;
let suppressDrawerClick = false;
let locked = false;
let previousBodyOverflow = "";
let returnFocus: HTMLElement | null = null;

const isOpen = () => root.hasAttribute("data-blume-nav-open");

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

const openNavigation = (focusDrawer = false) => {
  window.clearTimeout(closeTimer);
  closeTimer = undefined;
  root.removeAttribute("data-blume-nav-closing");
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
}: {
  immediate?: boolean;
  restoreFocus?: boolean;
} = {}) => {
  if (!(isOpen() || root.hasAttribute("data-blume-nav-dragging"))) {
    return;
  }

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
    SETTLE_MS
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

const beginDrag = (event: PointerEvent, initialOpen: boolean) => {
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
    lastTime: event.timeStamp,
    lastX: event.clientX,
    pointerId: event.pointerId,
    source,
    startX: event.clientX,
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
      drag = undefined;
      return;
    }

    drag.active = true;
    drag.source.setPointerCapture(event.pointerId);
    if (!drag.initialOpen) {
      openNavigation(false);
    }
    root.setAttribute("data-blume-nav-dragging", "");
    root.removeAttribute("data-blume-nav-closing");
  }

  event.preventDefault();
  const elapsed = Math.max(1, event.timeStamp - drag.lastTime);
  const instantaneousVelocity = (event.clientX - drag.lastX) / elapsed;
  drag.velocityX = drag.velocityX * 0.7 + instantaneousVelocity * 0.3;
  drag.lastX = event.clientX;
  drag.lastTime = event.timeStamp;
  drag.translation = Math.max(
    0,
    Math.min(drag.width, drag.initialOpen ? dx : drag.width + dx)
  );
  suppressDrawerClick = drag.initialOpen;
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

  if (shouldOpen) {
    root.removeAttribute("data-blume-nav-dragging");
    root.style.removeProperty("--blume-nav-drag-x");
    root.style.removeProperty("--blume-nav-overlay-progress");
    openNavigation(false);
  } else {
    closeNavigation({ restoreFocus: finished.initialOpen });
  }
};

const handlePointerCancel = (event: PointerEvent) => endDrag(event, true);

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

  document.addEventListener("click", (event) => {
    const target = event.target;
    if (!(target instanceof Element)) {
      return;
    }

    if (
      suppressDrawerClick &&
      drawer.contains(target) &&
      target.closest("a, button")
    ) {
      event.preventDefault();
      event.stopPropagation();
      suppressDrawerClick = false;
      return;
    }
    suppressDrawerClick = false;

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
    closeNavigation({ immediate: true });
  });
  window.addEventListener("pageshow", () => {
    closeNavigation({ immediate: true });
    measureHeader();
  });
}

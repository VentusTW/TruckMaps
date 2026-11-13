/* TruckMaps – wspólny kod strony: tłumaczenia, nagłówek, stopka, formatowanie kwot.
 * Wszystkie teksty są w assets/js/i18n-<język>.js (window.I18N[język]); tutaj tylko klucze. */
(function () {
  "use strict";

  // Dane kontaktowe są wymyślone (przykładowe) – podmienić przed publikacją.
  const CONTACT = {
    company: "TruckMaps sp. z o.o.",
    street: "ul. Kierowców 12",
    city: "45-001 Opole",
    country: "PL",
    phone: "+48 77 400 12 34",
    phoneSales: "+48 77 400 12 35",
    email: "kontakt@truckmaps.example",
    sales: "sprzedaz@truckmaps.example",
    support: "pomoc@truckmaps.example",
  };

  const LANGS = ["pl", "en"];
  const STORAGE_LANG = "tm_lang";

  function store(key, value) {
    try {
      if (value === undefined) return localStorage.getItem(key);
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    } catch (e) {
      return null;
    }
    return null;
  }

  function detectLang() {
    const saved = store(STORAGE_LANG);
    if (saved && LANGS.includes(saved)) return saved;
    const nav = (navigator.language || "pl").slice(0, 2).toLowerCase();
    return LANGS.includes(nav) ? nav : "en";
  }

  let lang = detectLang();

  function dict() {
    return (window.I18N && window.I18N[lang]) || window.I18N.pl;
  }

  function lookup(key, source) {
    return key.split(".").reduce((obj, part) => (obj == null ? undefined : obj[part]), source);
  }

  /** Tekst po kluczu; {nazwa} zastępowane wartościami z vars. Brak tłumaczenia → polski → klucz. */
  function t(key, vars) {
    let value = lookup(key, dict());
    if (value === undefined) value = lookup(key, window.I18N.pl);
    if (value === undefined) return key;
    if (typeof value !== "string") return value;
    if (!vars) return value;
    return value.replace(/\{(\w+)\}/g, (m, name) => (vars[name] !== undefined ? vars[name] : m));
  }

  /** Liczba mnoga wg reguł języka: klucz.one / .few / .many / .other. */
  function tp(key, n, vars) {
    const forms = lookup(key, dict()) || lookup(key, window.I18N.pl) || {};
    const rule = new Intl.PluralRules(dict().meta.locale).select(n);
    const template = forms[rule] || forms.other || key;
    return template.replace(/\{(\w+)\}/g, (m, name) => {
      if (name === "n") return n.toLocaleString(dict().meta.locale);
      return vars && vars[name] !== undefined ? vars[name] : m;
    });
  }

  function currency() {
    return dict().meta.currency;
  }

  function money(amount, cur) {
    return new Intl.NumberFormat(dict().meta.locale, {
      style: "currency",
      currency: cur || currency(),
      minimumFractionDigits: amount % 1 === 0 ? 0 : 2,
      maximumFractionDigits: 2,
    }).format(amount);
  }

  function date(d) {
    return new Intl.DateTimeFormat(dict().meta.locale, { day: "numeric", month: "long", year: "numeric" }).format(d);
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  // Proste ikony liniowe (własne), bez zewnętrznych bibliotek.
  const ICONS = {
    route: '<circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="6" r="2.5"/><path d="M8.5 18H15a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h6.5"/>',
    shield: '<path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z"/><path d="M9 12l2 2 4-4"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    coins: '<ellipse cx="12" cy="6" rx="7" ry="3"/><path d="M5 6v6c0 1.7 3.1 3 7 3s7-1.3 7-3V6"/><path d="M5 12v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/>',
    truck: '<path d="M2 6h11v10H2z"/><path d="M13 9h4l4 4v3h-8"/><circle cx="6" cy="18" r="2"/><circle cx="17" cy="18" r="2"/>',
    doc: '<path d="M6 2h8l5 5v15H6z"/><path d="M14 2v5h5M9 13h7M9 17h7"/>',
    parking: '<rect x="4" y="3" width="16" height="18" rx="3"/><path d="M10 17V7h3a3 3 0 0 1 0 6h-3"/>',
    users: '<circle cx="9" cy="8" r="3.5"/><path d="M2 20c0-3.9 3.1-6 7-6s7 2.1 7 6"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14c2.4.6 4 2.6 4 6"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18"/>',
    chart: '<path d="M3 21h18"/><path d="M6 17v-5M11 17V7M16 17v-8M21 17V4"/>',
    box: '<path d="M3 7l9-4 9 4v10l-9 4-9-4z"/><path d="M3 7l9 4 9-4M12 11v10"/>',
    phone: '<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',
    map: '<path d="M9 4L3 6v14l6-2 6 2 6-2V4l-6 2z"/><path d="M9 4v14M15 6v14"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    pin: '<path d="M12 22s7-6.5 7-12a7 7 0 0 0-14 0c0 5.5 7 12 7 12z"/><circle cx="12" cy="10" r="2.5"/>',
    headset: '<path d="M4 14v-2a8 8 0 0 1 16 0v2"/><rect x="3" y="14" width="4" height="6" rx="1.5"/><rect x="17" y="14" width="4" height="6" rx="1.5"/>',
  };

  function icon(name, size) {
    const s = size || 22;
    return `<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ICONS.route}</svg>`;
  }

  const NAV = [
    ["index.html", "nav.home"],
    ["funkcje.html", "nav.features"],
    ["cennik.html", "nav.pricing"],
    ["tokeny.html", "nav.tokens"],
    ["kontakt.html", "nav.contact"],
  ];

  function currentPage() {
    const file = location.pathname.split("/").pop() || "index.html";
    return file.startsWith("cennik-") ? "cennik.html" : file;
  }

  function renderHeader() {
    const host = document.getElementById("site-header");
    if (!host) return;
    const page = currentPage();
    const links = NAV.map(
      ([href, key]) => `<li><a href="${href}"${href === page ? ' aria-current="page"' : ""}>${escapeHtml(t(key))}</a></li>`
    ).join("") + `<li class="nav-signup"><a href="rejestracja.html">${escapeHtml(t("nav.signup"))}</a></li>`;
    const options = LANGS.map(
      (code) => `<option value="${code}"${code === lang ? " selected" : ""}>${escapeHtml(window.I18N[code].meta.name)}</option>`
    ).join("");
    host.className = "site-header";
    host.innerHTML = `
      <nav class="container nav" aria-label="${escapeHtml(t("nav.menu"))}">
        <a class="logo" href="index.html"><span class="logo-mark">${icon("route", 20).replace('stroke="currentColor"', 'stroke="#fff"')}</span>TruckMaps</a>
        <button class="menu-toggle" type="button" aria-expanded="false" aria-controls="nav-links">${escapeHtml(t("nav.menu"))}</button>
        <ul class="nav-links" id="nav-links">${links}</ul>
        <div class="nav-tools">
          <select class="lang-select" aria-label="${escapeHtml(t("nav.language"))}">${options}</select>
          <a class="btn btn-primary btn-sm" href="rejestracja.html">${escapeHtml(t("nav.signup"))}</a>
        </div>
      </nav>`;
    host.querySelector(".lang-select").addEventListener("change", (e) => setLang(e.target.value));
    const toggle = host.querySelector(".menu-toggle");
    toggle.addEventListener("click", () => {
      const list = host.querySelector(".nav-links");
      const open = list.classList.toggle("open");
      toggle.setAttribute("aria-expanded", String(open));
    });
  }

  function renderFooter() {
    const host = document.getElementById("site-footer");
    if (!host) return;
    host.className = "site-footer";
    host.innerHTML = `
      <div class="container">
        <div class="footer-grid">
          <div>
            <a class="logo" href="index.html" style="color:#fff">TruckMaps</a>
            <p class="small" style="margin-top:10px">${escapeHtml(t("footer.tagline"))}</p>
          </div>
          <div>
            <h4>${escapeHtml(t("footer.product"))}</h4>
            <ul>
              <li><a href="funkcje.html">${escapeHtml(t("nav.features"))}</a></li>
              <li><a href="cennik-kierowca.html">${escapeHtml(t("groups.driver.name"))}</a></li>
              <li><a href="cennik-przedsiebiorca.html">${escapeHtml(t("groups.owner.name"))}</a></li>
              <li><a href="cennik-spedytor.html">${escapeHtml(t("groups.forwarder.name"))}</a></li>
              <li><a href="cennik-dyspozytor.html">${escapeHtml(t("groups.dispatcher.name"))}</a></li>
              <li><a href="tokeny.html">${escapeHtml(t("nav.tokens"))}</a></li>
            </ul>
          </div>
          <div>
            <h4>${escapeHtml(t("footer.company"))}</h4>
            <ul>
              <li><a href="kontakt.html">${escapeHtml(t("nav.contact"))}</a></li>
              <li><a href="regulamin.html">${escapeHtml(t("footer.terms"))}</a></li>
              <li><a href="prywatnosc.html">${escapeHtml(t("footer.privacy"))}</a></li>
              <li><a href="konto.html">${escapeHtml(t("footer.account"))}</a></li>
            </ul>
          </div>
          <div>
            <h4>${escapeHtml(t("footer.contact"))}</h4>
            <ul>
              <li>${escapeHtml(CONTACT.company)}</li>
              <li>${escapeHtml(CONTACT.street)}, ${escapeHtml(CONTACT.city)}</li>
              <li><a href="tel:${CONTACT.phone.replace(/\s/g, "")}">${escapeHtml(CONTACT.phone)}</a></li>
              <li><a href="mailto:${CONTACT.email}">${escapeHtml(CONTACT.email)}</a></li>
            </ul>
          </div>
        </div>
        <div class="footer-bottom">
          <span>© ${new Date().getFullYear()} ${escapeHtml(CONTACT.company)}. ${escapeHtml(t("footer.rights"))}</span>
          <span>${escapeHtml(t("meta.vatNote"))}</span>
        </div>
      </div>`;
  }

  /** Wypełnia elementy z atrybutami data-i18n*, data-icon i data-contact. */
  function applyTranslations(root) {
    const scope = root || document;
    scope.querySelectorAll("[data-i18n]").forEach((el) => {
      el.textContent = t(el.dataset.i18n);
    });
    scope.querySelectorAll("[data-i18n-html]").forEach((el) => {
      el.innerHTML = t(el.dataset.i18nHtml);
    });
    scope.querySelectorAll("[data-i18n-attr]").forEach((el) => {
      el.dataset.i18nAttr.split(";").forEach((pair) => {
        const [attr, key] = pair.split(":");
        if (attr && key) el.setAttribute(attr.trim(), t(key.trim()));
      });
    });
    scope.querySelectorAll("[data-i18n-list]").forEach((el) => {
      const items = t(el.dataset.i18nList);
      el.innerHTML = Array.isArray(items) ? items.map((item) => `<li>${item}</li>`).join("") : "";
    });
    scope.querySelectorAll("[data-i18n-sections]").forEach((el) => {
      const sections = t(el.dataset.i18nSections);
      if (!Array.isArray(sections)) return;
      el.innerHTML = sections
        .map((s) => {
          const paragraphs = (s.p || []).map((p) => `<p>${p}</p>`).join("");
          const list = s.items ? `<ul>${s.items.map((i) => `<li>${i}</li>`).join("")}</ul>` : "";
          return `<h2>${escapeHtml(s.h)}</h2>${paragraphs}${list}`;
        })
        .join("");
    });
    scope.querySelectorAll("[data-i18n-cards]").forEach((el) => {
      const items = t(el.dataset.i18nCards);
      if (!Array.isArray(items)) return;
      el.innerHTML = items
        .map((i) => `<div class="card"><div class="icon">${icon(i.icon)}</div><h3>${escapeHtml(i.title)}</h3><p class="muted">${escapeHtml(i.text)}</p></div>`)
        .join("");
    });
    scope.querySelectorAll("[data-i18n-stats]").forEach((el) => {
      const items = t(el.dataset.i18nStats);
      if (!Array.isArray(items)) return;
      el.innerHTML = items.map((i) => `<div class="stat"><b>${escapeHtml(i.value)}</b><span class="muted">${escapeHtml(i.label)}</span></div>`).join("");
    });
    scope.querySelectorAll("[data-i18n-steps]").forEach((el) => {
      const items = t(el.dataset.i18nSteps);
      if (!Array.isArray(items)) return;
      el.innerHTML = items.map((i) => `<li><h3>${escapeHtml(i.title)}</h3><p class="muted small">${escapeHtml(i.text)}</p></li>`).join("");
    });
    scope.querySelectorAll("[data-i18n-faq]").forEach((el) => {
      const items = t(el.dataset.i18nFaq);
      if (!Array.isArray(items)) return;
      el.innerHTML = items
        .map((i) => `<details class="card" style="margin-bottom:12px"><summary><strong>${escapeHtml(i.q)}</strong></summary><p class="muted" style="margin:10px 0 0">${escapeHtml(i.a)}</p></details>`)
        .join("");
    });
    scope.querySelectorAll("[data-i18n-options]").forEach((el) => {
      const items = t(el.dataset.i18nOptions);
      if (!items || typeof items !== "object") return;
      const keep = el.value;
      const entries = Array.isArray(items) ? items.map((v) => [v, v]) : Object.entries(items);
      el.innerHTML = entries.map(([v, label]) => `<option value="${escapeHtml(v)}">${escapeHtml(label)}</option>`).join("");
      if (keep && [...el.options].some((o) => o.value === keep)) el.value = keep;
    });
    scope.querySelectorAll("[data-icon]").forEach((el) => {
      el.innerHTML = icon(el.dataset.icon);
    });
    scope.querySelectorAll("[data-contact]").forEach((el) => {
      const key = el.dataset.contact;
      const value = CONTACT[key] || "";
      if (el.tagName === "A") {
        el.href = key.startsWith("phone") ? `tel:${value.replace(/\s/g, "")}` : `mailto:${value}`;
      }
      el.textContent = value;
    });
  }

  function render() {
    document.documentElement.lang = lang;
    renderHeader();
    renderFooter();
    applyTranslations();
    document.dispatchEvent(new CustomEvent("tm:render", { detail: { lang } }));
  }

  function setLang(code) {
    if (!LANGS.includes(code)) return;
    lang = code;
    store(STORAGE_LANG, code);
    render();
  }

  window.TM = { t, tp, money, date, currency, icon, escapeHtml, store, CONTACT, applyTranslations, get lang() { return lang; } };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", render);
  else render();
})();

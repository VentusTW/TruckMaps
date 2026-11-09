/* TruckMaps – cennik: plany, okresy płatności i tokeny.
 * Cena = szacowany miesięczny koszt planu (EUR, netto) × 1,30, przeliczona na walutę i zaokrąglona
 * w górę do „,99”. Skąd koszty: docs/CENNIK_KALKULACJA.md. Teksty planów: i18n-*.js → plans.<grupa>.<plan>. */
(function () {
  "use strict";

  const MARKUP = 1.3; // koszty + 30%
  const RATES = { EUR: 1, PLN: 4.3 }; // kurs do aktualizacji przez administratora

  // Okresy subskrypcji: płatne z góry za cały okres; upust rośnie z długością okresu.
  const BILLING = {
    monthly: { months: 1, discount: 0 },
    semiannual: { months: 6, discount: 0.08 },
    annual: { months: 12, discount: 0.15 },
  };

  // Składniki kosztu (EUR / mies.): infrastruktura, dane i licencje, wsparcie, rozwój i utrzymanie,
  // sprzedaż i marketing, płatności / księgowość / prawo, pula tokenów w cenie planu (liczba × TOKEN_COST).
  const COST_PARTS = ["infra", "data", "support", "dev", "marketing", "admin", "tokens"];

  const GROUPS = {
    driver: {
      page: "cennik-kierowca.html",
      plans: [
        { id: "start", cost: null, limits: { vehicles: 1, routes: 30 } },
        { id: "startplus", cost: [0.35, 0.1, 0.3, 0.8, 0.3, 0.25], limits: { vehicles: 1 } },
        { id: "plus", cost: [0.4, 0.3, 0.5, 1.3, 0.7, 0.4], limits: { vehicles: 2 } },
        { id: "pro", cost: [0.9, 0.8, 0.8, 2.6, 1.2, 0.7], popular: true, limits: { vehicles: 3 } },
        { id: "days", tokens: 1 },
      ],
    },
    owner: {
      page: "cennik-przedsiebiorca.html",
      plans: [
        { id: "small", cost: [3, 1, 5, 9, 4, 2], limits: { office: 2, drivers: 5, vehicles: 5, trailers: 5 } },
        { id: "fleet", cost: [6, 3, 9, 18, 6, 4, 4.5], popular: true, limits: { office: 3, drivers: 10, vehicles: 10, trailers: 10 } },
        { id: "pro", cost: [18, 16, 20, 45, 10, 9, 9], limits: { office: 5, drivers: 25, vehicles: 25, trailers: 25 } },
        { id: "business", cost: [40, 35, 40, 90, 15, 18, 22.5], limits: { office: 10, drivers: 60, vehicles: 60, trailers: 60 } },
      ],
    },
    forwarder: {
      page: "cennik-spedytor.html",
      plans: [
        { id: "solo", cost: [1, 0.5, 2.5, 4.5, 2.5, 1], limits: { office: 1, carriers: 3 } },
        { id: "start", cost: [1.5, 1, 4, 7, 3, 1.5], limits: { office: 2, carriers: 5 } },
        { id: "standard", cost: [3, 2, 8, 15, 5, 3], popular: true, limits: { office: 4, carriers: 15 } },
        { id: "pro", cost: [8, 12, 15, 30, 8, 6], limits: { office: 8, carriers: 50 } },
      ],
    },
    dispatcher: {
      page: "cennik-dyspozytor.html",
      plans: [
        { id: "start", cost: [2, 1, 3, 6, 2.5, 1.5], limits: { seats: 1, vehicles: 10 } },
        { id: "standard", cost: [4, 4, 5, 12, 4, 2], popular: true, limits: { seats: 1, vehicles: 25 } },
        { id: "pro", cost: [9, 10, 9, 24, 6, 4], limits: { seats: 2, vehicles: 60 } },
        { id: "center", cost: [20, 22, 20, 50, 10, 8], limits: { seats: 5, vehicles: 150 } },
      ],
    },
  };

  // Dodatki ponad limit planu – koszt EUR / mies. za sztukę; cena jak plan (× 1,30, do „,99”),
  // ten sam okres i upust co plan. Liczenie: pojazd = pojazd z napędem (ciągnik, solówka, bus);
  // naczepy i przyczepy osobno (przedsiębiorca), pojazd przewoźnika = cały zestaw (spedytor).
  // Dodatkowy kierowca ma plan kierowcy z planu firmy (Start+ / Plus / Pro) – koszt tego planu
  // bez udziału w marketingu i płatnościach.
  const ADDONS = {
    driver: [{ id: "dvehicle", cost: 0.4, plans: ["plus", "pro"] }],
    owner: [
      { id: "driver", cost: { small: 1.55, fleet: 2.5, pro: 5.1, business: 5.1 } },
      { id: "vehicle", cost: 1.7 },
      { id: "trailer", cost: 0.3 },
      { id: "office", cost: 2.5 },
    ],
    forwarder: [
      { id: "office", cost: 2.5 },
      { id: "carrier", cost: 0.4 },
    ],
    dispatcher: [
      { id: "seat", cost: 6 },
      { id: "vehicle", cost: 1.7 },
    ],
  };
  const ADDON_MAX = 500;

  // Tokeny: 1 token ≈ 1 dzień planu Kierowca Pro, 1 pojazd na 1 dzień, 1 dokument; ważne 12 miesięcy.
  const TOKEN_COST = 0.45; // EUR, koszt jednego tokena
  const TOKEN_STEPS = [
    [10, 0],
    [25, 0.04],
    [50, 0.08],
    [100, 0.12],
    [250, 0.16],
    [500, 0.2],
  ];
  const TOKEN_MAX_DISCOUNT = 0.2; // pułap upustu – cena tokena nie spada poniżej kosztu
  const TOKEN_PACKS = [10, 25, 50, 100, 250, 500, 1000];
  const TOKEN_MIN = 10;
  const TOKEN_MAX = 5000;

  const t = (...a) => window.TM.t(...a);
  const tp = (...a) => window.TM.tp(...a);
  const money = (...a) => window.TM.money(...a);
  const esc = (s) => window.TM.escapeHtml(s);

  function niceUp(value) {
    // w górę do „,99” i nigdy poniżej wartości (20,12 → 20,99; 169,00 → 169,99)
    return Math.ceil(value + 0.01 - 1e-9) - 0.01;
  }

  function round2(value) {
    return Math.round(value * 100) / 100;
  }

  function findPlan(group, id) {
    const g = GROUPS[group];
    return g ? g.plans.find((p) => p.id === id) : undefined;
  }

  function planCost(plan) {
    return plan.cost ? plan.cost.reduce((a, b) => a + b, 0) : 0;
  }

  /** Cena miesięczna przy płatności co miesiąc. */
  function monthlyPrice(plan, cur) {
    if (!plan.cost) return 0;
    return niceUp(planCost(plan) * MARKUP * RATES[cur]);
  }

  /** Kwota za cały okres i jej równowartość miesięczna. */
  function periodPrice(plan, cur, billing) {
    const b = BILLING[billing] || BILLING.monthly;
    const total = round2(monthlyPrice(plan, cur) * b.months * (1 - b.discount));
    return { total, perMonth: round2(total / b.months), months: b.months, discount: b.discount };
  }

  function addonsFor(group, planId) {
    return (ADDONS[group] || []).filter(
      (a) => (!a.plans || a.plans.includes(planId)) && (typeof a.cost !== "object" || a.cost[planId] !== undefined)
    );
  }

  /** Cena dodatku za sztukę przy płatności co miesiąc. */
  function addonMonthly(addon, planId, cur) {
    const cost = typeof addon.cost === "object" ? addon.cost[planId] : addon.cost;
    return niceUp(cost * MARKUP * RATES[cur]);
  }

  /** Kwota za qty sztuk dodatku za cały okres i jej równowartość miesięczna. */
  function addonPeriod(addon, planId, cur, billingKey, qty) {
    const b = BILLING[billingKey] || BILLING.monthly;
    const total = round2(addonMonthly(addon, planId, cur) * (qty || 1) * b.months * (1 - b.discount));
    return { total, perMonth: round2(total / b.months) };
  }

  function tokenDiscount(qty) {
    let d = 0;
    TOKEN_STEPS.forEach(([min, disc]) => {
      if (qty >= min) d = disc;
    });
    return Math.min(d, TOKEN_MAX_DISCOUNT);
  }

  function tokenUnit(cur) {
    return TOKEN_COST * MARKUP * RATES[cur];
  }

  function tokenPrice(qty, cur) {
    const d = tokenDiscount(qty);
    const total = Math.ceil(qty * tokenUnit(cur) * (1 - d) * 100 - 1e-6) / 100;
    return { total, perToken: round2(total / qty), discount: d };
  }

  function minMonthly(group, cur) {
    const prices = GROUPS[group].plans.filter((p) => p.cost).map((p) => periodPrice(p, cur, "annual").perMonth);
    return Math.min(...prices);
  }

  function limitTags(plan) {
    if (!plan.limits) return "";
    const tags = Object.entries(plan.limits).map(([k, n]) => `<span>${esc(tp(`limits.${k}`, n))}</span>`);
    return `<div class="limits">${tags.join("")}</div>`;
  }

  function registerHref(group, plan, billing) {
    const params = new URLSearchParams({ group, plan: plan.id });
    if (plan.cost) params.set("billing", billing);
    return `rejestracja.html?${params}`;
  }

  function planCard(group, plan, billing, cur) {
    const base = `plans.${group}.${plan.id}`;
    const features = t(`${base}.features`);
    const list = Array.isArray(features) ? features.map((f) => `<li>${esc(f)}</li>`).join("") : "";
    const note = t(`${base}.note`) !== `${base}.note` ? `<p class="small muted">${esc(t(`${base}.note`))}</p>` : "";
    let price;
    let priceNote;
    let button;
    if (plan.tokens) {
      price = `<b>${esc(money(tokenPrice(TOKEN_PACKS[TOKEN_PACKS.length - 1], cur).perToken * plan.tokens))}</b> <span>${esc(t("pricing.perDayFrom"))}</span>`;
      priceNote = esc(t("pricing.tokenPlanNote"));
      button = `<a class="btn btn-ghost btn-block" href="tokeny.html">${esc(t("pricing.buyTokens"))}</a>`;
    } else if (!plan.cost) {
      price = `<b>${esc(money(0))}</b>`;
      priceNote = esc(t("pricing.freeForever"));
      button = `<a class="btn btn-ghost btn-block" href="${registerHref(group, plan, billing)}">${esc(t("pricing.startFree"))}</a>`;
    } else {
      const p = periodPrice(plan, cur, billing);
      price = `<b>${esc(money(p.perMonth))}</b> <span>${esc(t("common.perMonth"))}</span>`;
      priceNote =
        billing === "monthly"
          ? esc(t("billing.noteMonthly"))
          : esc(t(`billing.note_${billing}`, { total: money(p.total), old: money(monthlyPrice(plan, cur) * p.months) }));
      const cls = plan.popular ? "btn-primary" : "btn-ghost";
      button = `<a class="btn ${cls} btn-block" href="${registerHref(group, plan, billing)}">${esc(t("pricing.choose"))}</a>`;
    }
    return `
      <article class="plan${plan.popular ? " popular" : ""}">
        ${plan.popular ? `<span class="ribbon">${esc(t("pricing.popular"))}</span>` : ""}
        <h3>${esc(t(`${base}.name`))}</h3>
        <p class="for">${esc(t(`${base}.for`))}</p>
        <div class="price">${price}</div>
        <div class="price-note">${priceNote}</div>
        ${limitTags(plan)}
        <ul class="check-list">${list}</ul>
        ${note}
        ${button}
      </article>`;
  }

  // ---------- Strona grupy (cennik-*.html) ----------
  let billing = "annual";

  function renderBillingToggle(host) {
    host.innerHTML = Object.keys(BILLING)
      .map((key) => {
        const d = BILLING[key].discount;
        const tag = d ? `<span class="save-tag">−${Math.round(d * 100)}%</span>` : "";
        return `<button type="button" data-billing="${key}" aria-pressed="${key === billing}">${esc(t(`billing.${key}`))}${tag}</button>`;
      })
      .join("");
    host.querySelectorAll("button").forEach((btn) =>
      btn.addEventListener("click", () => {
        billing = btn.dataset.billing;
        renderGroupPage();
      })
    );
  }

  function renderGroupPage() {
    const host = document.querySelector("[data-plans]");
    if (!host) return;
    const group = host.dataset.plans;
    const cur = window.TM.currency();
    const toggle = document.querySelector("[data-billing-toggle]");
    if (toggle) renderBillingToggle(toggle);
    host.innerHTML = GROUPS[group].plans.map((p) => planCard(group, p, billing, cur)).join("");
    renderAddons(group, cur);
  }

  function renderAddons(group, cur) {
    const host = document.querySelector("[data-addons]");
    if (!host) return;
    const paid = GROUPS[group].plans.filter((p) => p.cost);
    const perMonth = esc(t("common.perMonth"));
    host.innerHTML = (ADDONS[group] || [])
      .map((a) => {
        const planIds = typeof a.cost === "object" ? paid.map((p) => p.id).filter((id) => a.cost[id] !== undefined) : null;
        const price = planIds
          ? planIds
              .map((id) => `${esc(t(`plans.${group}.${id}.name`))}: <strong>${esc(money(addonPeriod(a, id, cur, billing).perMonth))}</strong> ${perMonth}`)
              .join("<br>")
          : `<strong>${esc(money(addonPeriod(a, a.plans ? a.plans[0] : paid[0].id, cur, billing).perMonth))}</strong> ${perMonth}`;
        const only = a.plans
          ? `<div class="small muted">${esc(t("addons.onlyIn", { plans: a.plans.map((id) => t(`plans.${group}.${id}.name`)).join(", ") }))}</div>`
          : "";
        return `<tr><td><strong>${esc(t(`addons.items.${a.id}.name`))}</strong><div class="small muted">${esc(t(`addons.items.${a.id}.desc`))}</div>${only}</td><td>${price}</td></tr>`;
      })
      .join("");
    const note = document.querySelector("[data-addons-note]");
    if (note) note.textContent = t(`addons.count.${group}`);
    const period = document.querySelector("[data-addons-billing]");
    if (period) period.textContent = t("addons.billingNote", { period: t(`billing.${billing}`).toLowerCase() });
  }

  // ---------- Przegląd cennika (cennik.html) ----------
  function renderOverview() {
    document.querySelectorAll("[data-from-price]").forEach((el) => {
      const cur = window.TM.currency();
      el.textContent = t("pricing.fromPerMonth", { price: money(minMonthly(el.dataset.fromPrice, cur)) });
    });
    const table = document.querySelector("[data-billing-table]");
    if (table) {
      const cur = window.TM.currency();
      const sample = findPlan("owner", "fleet");
      table.innerHTML = Object.keys(BILLING)
        .map((key) => {
          const p = periodPrice(sample, cur, key);
          const disc = BILLING[key].discount ? `−${Math.round(BILLING[key].discount * 100)}%` : "—";
          return `<tr><td>${esc(t(`billing.${key}`))}</td><td>${esc(t(`billing.desc_${key}`))}</td><td>${disc}</td><td>${esc(money(p.perMonth))} ${esc(t("common.perMonth"))}</td></tr>`;
        })
        .join("");
    }
  }

  // ---------- Tokeny (tokeny.html) ----------
  function renderTokens() {
    const packs = document.querySelector("[data-token-packs]");
    const cur = window.TM.currency();
    if (packs) {
      packs.innerHTML = TOKEN_PACKS.map((qty) => {
        const p = tokenPrice(qty, cur);
        const disc = p.discount ? esc(t("tokens.discount", { p: Math.round(p.discount * 100) })) : "&nbsp;";
        return `
          <div class="pack">
            <div class="qty">${qty.toLocaleString(window.TM.t("meta.locale"))}</div>
            <div class="muted small">${esc(tp("tokens.count", qty))}</div>
            <b>${esc(money(p.total))}</b>
            <div class="small muted">${esc(t("tokens.perToken", { price: money(p.perToken) }))}</div>
            <div class="disc">${disc}</div>
            <a class="btn btn-ghost btn-sm" href="rejestracja.html?tokens=${qty}">${esc(t("tokens.buy"))}</a>
          </div>`;
      }).join("");
    }
    const steps = document.querySelector("[data-token-steps]");
    if (steps) {
      steps.innerHTML = TOKEN_STEPS.map(([min, d], i) => {
        const next = TOKEN_STEPS[i + 1];
        const range = next ? `${min}–${next[0] - 1}` : t("tokens.andMore", { n: min });
        return `<tr><td>${esc(range)}</td><td>${d ? `−${Math.round(d * 100)}%` : "—"}</td><td>${esc(money(round2(tokenUnit(cur) * (1 - d))))}</td></tr>`;
      }).join("");
    }
    const cap = document.querySelector("[data-token-cap]");
    if (cap) cap.textContent = t("tokens.cap", { p: Math.round(TOKEN_MAX_DISCOUNT * 100) });
    updateCalculator();
  }

  function updateCalculator() {
    const range = document.querySelector("[data-token-range]");
    if (!range) return;
    const input = document.querySelector("[data-token-input]");
    const cur = window.TM.currency();
    const qty = Math.max(TOKEN_MIN, Math.min(TOKEN_MAX, parseInt(input.value || range.value, 10) || TOKEN_MIN));
    const p = tokenPrice(qty, cur);
    document.querySelector("[data-calc-total]").textContent = money(p.total);
    document.querySelector("[data-calc-detail]").textContent = t("tokens.calcDetail", {
      n: qty,
      price: money(p.perToken),
      p: Math.round(p.discount * 100),
    });
    document.querySelector("[data-calc-buy]").href = `rejestracja.html?tokens=${qty}`;
  }

  function bindCalculator() {
    const range = document.querySelector("[data-token-range]");
    const input = document.querySelector("[data-token-input]");
    if (!range || !input) return;
    range.min = TOKEN_MIN;
    range.max = 1000;
    input.min = TOKEN_MIN;
    input.max = TOKEN_MAX;
    range.addEventListener("input", () => {
      input.value = range.value;
      updateCalculator();
    });
    input.addEventListener("input", () => {
      range.value = Math.min(1000, parseInt(input.value, 10) || TOKEN_MIN);
      updateCalculator();
    });
  }

  window.TMPricing = {
    GROUPS,
    BILLING,
    COST_PARTS,
    MARKUP,
    TOKEN_MIN,
    TOKEN_MAX,
    findPlan,
    planCost,
    monthlyPrice,
    periodPrice,
    tokenPrice,
    tokenDiscount,
    ADDON_MAX,
    addonsFor,
    addonMonthly,
    addonPeriod,
  };

  document.addEventListener("DOMContentLoaded", bindCalculator);
  document.addEventListener("tm:render", () => {
    renderGroupPage();
    renderOverview();
    renderTokens();
  });
})();

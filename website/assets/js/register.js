/* TruckMaps – zakładanie konta przed zakupem (rejestracja.html) i stan konta (konto.html).
 * Zasada: konto z płatnym planem lub tokenami musi mieć pierwszą wpłatę w ciągu 10 dni,
 * inaczej jest usuwane. Konto darmowe (Kierowca Start) nie ma terminu.
 * TODO: wysyłka do serwera (POST /api/accounts) – na razie wniosek zapisywany tylko w przeglądarce. */
(function () {
  "use strict";

  const PAYMENT_DAYS = 10;
  const STORAGE_KEY = "tm_account";
  const t = (...a) => window.TM.t(...a);
  const tp = (...a) => window.TM.tp(...a);
  const money = (...a) => window.TM.money(...a);
  const esc = (s) => window.TM.escapeHtml(s);
  const P = () => window.TMPricing;

  const params = new URLSearchParams(location.search);
  const state = {
    group: params.get("group") || (params.get("tokens") ? "driver" : "owner"),
    plan: params.get("plan") || "",
    billing: params.get("billing") || "annual",
    tokens: parseInt(params.get("tokens") || "0", 10) || 0,
  };
  if (state.tokens && !state.plan) state.plan = "tokens";

  function loadAccount() {
    try {
      const raw = window.TM.store(STORAGE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (e) {
      return null;
    }
  }

  /** Co klient kupuje i ile wynosi pierwsza wpłata. */
  function selection() {
    const cur = window.TM.currency();
    if (state.plan === "tokens") {
      const qty = Math.max(P().TOKEN_MIN, Math.min(P().TOKEN_MAX, state.tokens || P().TOKEN_MIN));
      return { kind: "tokens", qty, amount: P().tokenPrice(qty, cur).total, cur, paid: true };
    }
    const plan = P().findPlan(state.group, state.plan);
    if (!plan || plan.tokens) return { kind: "none", cur, paid: false };
    if (!plan.cost) return { kind: "free", plan, amount: 0, cur, paid: false };
    const p = P().periodPrice(plan, cur, state.billing);
    return { kind: "plan", plan, amount: p.total, perMonth: p.perMonth, cur, paid: true };
  }

  // ---------- Formularz ----------
  function fillGroupSelect(form) {
    const sel = form.elements.group;
    sel.innerHTML = Object.keys(P().GROUPS)
      .map((g) => `<option value="${g}"${g === state.group ? " selected" : ""}>${esc(t(`groups.${g}.name`))}</option>`)
      .join("");
  }

  function fillPlanSelect(form) {
    const sel = form.elements.plan;
    const plans = P().GROUPS[state.group].plans.filter((p) => !p.tokens);
    if (!plans.some((p) => p.id === state.plan) && state.plan !== "tokens") {
      state.plan = (plans.find((p) => p.popular) || plans[0]).id;
    }
    const options = plans.map(
      (p) => `<option value="${p.id}"${p.id === state.plan ? " selected" : ""}>${esc(t(`plans.${state.group}.${p.id}.name`))}</option>`
    );
    options.push(`<option value="tokens"${state.plan === "tokens" ? " selected" : ""}>${esc(t("register.tokensOnly"))}</option>`);
    sel.innerHTML = options.join("");
  }

  function fillBillingSelect(form) {
    const sel = form.elements.billing;
    sel.innerHTML = Object.keys(P().BILLING)
      .map((b) => {
        const d = P().BILLING[b].discount;
        const label = t(`billing.${b}`) + (d ? ` (−${Math.round(d * 100)}%)` : "");
        return `<option value="${b}"${b === state.billing ? " selected" : ""}>${esc(label)}</option>`;
      })
      .join("");
  }

  function updateVisibility(form) {
    const sel = selection();
    form.querySelector("[data-row-billing]").classList.toggle("hidden", sel.kind !== "plan");
    form.querySelector("[data-row-tokens]").classList.toggle("hidden", sel.kind !== "tokens");
    const companyNeeded = state.group !== "driver";
    form.querySelector("[data-row-company]").classList.toggle("hidden", !companyNeeded);
    form.elements.company.required = companyNeeded;
    form.querySelector("[data-row-deadline]").classList.toggle("hidden", !sel.paid);
    form.elements.deadline.required = sel.paid;
  }

  function deadlineDate() {
    const d = new Date();
    d.setDate(d.getDate() + PAYMENT_DAYS);
    return d;
  }

  function renderSummary() {
    const host = document.querySelector("[data-summary]");
    if (!host) return;
    const sel = selection();
    const rows = [[t("register.sumType"), t(`groups.${state.group}.name`)]];
    if (sel.kind === "plan") {
      rows.push([t("register.sumPlan"), t(`plans.${state.group}.${sel.plan.id}.name`)]);
      rows.push([t("register.sumBilling"), t(`billing.${state.billing}`)]);
      rows.push([t("register.sumPerMonth"), money(sel.perMonth)]);
    } else if (sel.kind === "tokens") {
      rows.push([t("register.sumPlan"), t("register.tokensOnly")]);
      rows.push([t("register.sumTokens"), tp("tokens.amount", sel.qty)]);
    } else if (sel.kind === "free") {
      rows.push([t("register.sumPlan"), t(`plans.${state.group}.${sel.plan.id}.name`)]);
    }
    rows.push([t("register.sumFirstPayment"), money(sel.amount || 0)]);
    const deadline = sel.paid
      ? `<div class="info warn small"><strong>${esc(t("register.deadlineTitle", { days: PAYMENT_DAYS }))}</strong><br>${esc(
          t("register.deadlineText", { date: window.TM.date(deadlineDate()) })
        )}</div>`
      : `<div class="info small">${esc(t("register.freeNoDeadline"))}</div>`;
    host.innerHTML = `
      <h3>${esc(t("register.summary"))}</h3>
      <dl>${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>
      <p class="small muted">${esc(t("meta.vatNote"))}</p>
      ${deadline}`;
  }

  function refresh(form) {
    fillGroupSelect(form);
    fillPlanSelect(form);
    fillBillingSelect(form);
    form.elements.tokens.value = state.tokens || 100;
    form.elements.tokens.min = P().TOKEN_MIN;
    form.elements.tokens.max = P().TOKEN_MAX;
    updateVisibility(form);
    renderSummary();
    const deadlineLabel = form.querySelector("[data-deadline-label]");
    if (deadlineLabel) deadlineLabel.textContent = t("register.ackDeadline", { days: PAYMENT_DAYS });
  }

  function showError(form, name, message) {
    const el = form.querySelector(`[data-error="${name}"]`);
    if (el) el.textContent = message || "";
  }

  function validate(form) {
    let ok = true;
    form.querySelectorAll("[data-error]").forEach((el) => (el.textContent = ""));
    const f = form.elements;
    const required = ["firstName", "lastName", "email", "phone"];
    if (f.company.required) required.push("company");
    required.forEach((name) => {
      if (!f[name].value.trim()) {
        showError(form, name, t("register.errRequired"));
        ok = false;
      }
    });
    if (f.email.value && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(f.email.value.trim())) {
      showError(form, "email", t("register.errEmail"));
      ok = false;
    }
    if (f.phone.value && !/^\+?[0-9 ()-]{7,20}$/.test(f.phone.value.trim())) {
      showError(form, "phone", t("register.errPhone"));
      ok = false;
    }
    const nip = f.nip.value.replace(/[\s-]/g, "");
    if (nip && !/^[A-Z]{0,2}[0-9A-Z]{8,12}$/i.test(nip)) {
      showError(form, "nip", t("register.errNip"));
      ok = false;
    }
    if (!f.terms.checked) {
      showError(form, "terms", t("register.errTerms"));
      ok = false;
    }
    if (f.deadline.required && !f.deadline.checked) {
      showError(form, "deadline", t("register.errDeadline"));
      ok = false;
    }
    return ok;
  }

  function bindForm() {
    const form = document.querySelector("[data-register-form]");
    if (!form) return;
    form.elements.group.addEventListener("change", (e) => {
      state.group = e.target.value;
      state.plan = "";
      refresh(form);
    });
    form.elements.plan.addEventListener("change", (e) => {
      state.plan = e.target.value;
      if (state.plan === "tokens" && !state.tokens) state.tokens = 100;
      updateVisibility(form);
      renderSummary();
    });
    form.elements.billing.addEventListener("change", (e) => {
      state.billing = e.target.value;
      renderSummary();
    });
    form.elements.tokens.addEventListener("input", (e) => {
      state.tokens = parseInt(e.target.value, 10) || 0;
      renderSummary();
    });
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      if (!validate(form)) {
        const first = form.querySelector("[data-error]:not(:empty)");
        if (first) first.scrollIntoView({ behavior: "smooth", block: "center" });
        return;
      }
      const sel = selection();
      const f = form.elements;
      const account = {
        createdAt: new Date().toISOString(),
        deadline: sel.paid ? deadlineDate().toISOString() : null,
        group: state.group,
        plan: state.plan,
        billing: sel.kind === "plan" ? state.billing : null,
        tokens: sel.kind === "tokens" ? sel.qty : null,
        amount: sel.amount || 0,
        currency: sel.cur,
        firstName: f.firstName.value.trim(),
        lastName: f.lastName.value.trim(),
        company: f.company.required ? f.company.value.trim() : "",
        nip: f.nip.value.trim(),
        email: f.email.value.trim(),
        phone: f.phone.value.trim(),
        country: f.country.value,
        marketing: f.marketing.checked,
        lang: window.TM.lang,
      };
      window.TM.store(STORAGE_KEY, JSON.stringify(account));
      location.href = "konto.html";
    });
    document.addEventListener("tm:render", () => refresh(form));
  }

  // ---------- Stan konta ----------
  function renderAccount() {
    const host = document.querySelector("[data-account]");
    if (!host) return;
    const acc = loadAccount();
    const empty = document.querySelector("[data-account-empty]");
    if (!acc) {
      host.classList.add("hidden");
      empty.classList.remove("hidden");
      return;
    }
    empty.classList.add("hidden");
    host.classList.remove("hidden");
    const planName =
      acc.plan === "tokens" ? `${t("register.tokensOnly")} – ${tp("tokens.amount", acc.tokens)}` : t(`plans.${acc.group}.${acc.plan}.name`);
    const rows = [
      [t("account.holder"), `${acc.firstName} ${acc.lastName}`],
      [t("account.email"), acc.email],
      [t("register.sumType"), t(`groups.${acc.group}.name`)],
      [t("register.sumPlan"), planName],
    ];
    if (acc.billing) rows.push([t("register.sumBilling"), t(`billing.${acc.billing}`)]);
    rows.push([t("register.sumFirstPayment"), money(acc.amount, acc.currency)]);
    host.querySelector("[data-account-rows]").innerHTML = rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("");

    const status = host.querySelector("[data-account-status]");
    const payBox = host.querySelector("[data-pay-box]");
    if (!acc.deadline) {
      status.innerHTML = `<div class="info">${esc(t("account.freeActive"))}</div>`;
      payBox.classList.add("hidden");
      return;
    }
    const deadline = new Date(acc.deadline);
    const msLeft = deadline - new Date();
    if (msLeft <= 0) {
      status.innerHTML = `<div class="info warn"><strong>${esc(t("account.expiredTitle"))}</strong><br>${esc(t("account.expiredText"))}</div>`;
      payBox.classList.add("hidden");
      return;
    }
    const days = Math.floor(msLeft / 86400000);
    const hours = Math.floor((msLeft % 86400000) / 3600000);
    status.innerHTML = `
      <p class="muted">${esc(t("account.timeLeft"))}</p>
      <div class="deadline">${esc(tp("account.days", days))} ${esc(tp("account.hours", hours))}</div>
      <p>${esc(t("account.deadlineText", { date: window.TM.date(deadline) }))}</p>`;
    payBox.classList.remove("hidden");
  }

  function bindAccount() {
    const pay = document.querySelector("[data-pay]");
    if (pay) {
      pay.addEventListener("click", () => {
        document.querySelector("[data-pay-info]").classList.remove("hidden");
      });
    }
    const cancel = document.querySelector("[data-cancel]");
    if (cancel) {
      cancel.addEventListener("click", () => {
        if (window.confirm(t("account.cancelConfirm"))) {
          window.TM.store(STORAGE_KEY, null);
          renderAccount();
        }
      });
    }
    document.addEventListener("tm:render", renderAccount);
  }

  bindForm();
  bindAccount();
})();
